# Pick the wipe primitive from the device class, and fail loud when it doesn't run

`fog.wipe` had two defects that together meant an operator could be told a disk
was erased when it demonstrably was not.

**The NVMe path never erased anything.** The code was:

```bash
[[ $hd == *[Nn][Vv][Mm][Ee]* ]] && wipemode="nvme"
...
nvme format $hd --force
```

`nvme format`'s Secure Erase Settings (`--ses`) field **defaults to 0 — "no
secure erase operation requested"**. That reformats the namespace's LBA metadata
and returns in seconds, but the NVMe specification does not require the
controller to erase user data. Many drives do deallocate blocks on format, and a
deallocated read commonly returns zeros — which is exactly why this looked
correct in testing. That behaviour is implementation-defined per drive, not
guaranteed, and "reads back as zeros" is not "the data is gone from the NAND".
Every NVMe wipe FOG has performed through this path should be assumed
non-erasing.

This is a **regression of a fix, not a never-implemented feature**, and the
distinction matters for how much of this code to trust. The NVMe path came from
[#61](https://github.com/FOGProject/fos/issues/61) (closed as fixed
2023-02-28), whose reasoning was sound — "UEFI does not freeze an NVMe. NVMe
drives have their own way to format using `nvme-cli`" is exactly right, and is
still the basis of what this ADR does. The approach was correct; a single flag
was missing. What the pre-#61 code did on NVMe was `shred`: slow, hard on the
drive, and the reason #61 was opened — but it erased. So the 2023 change traded
a real wipe for a fast one, and the speed was mistaken for the improvement. It
has been believed fixed for three years.

**Nothing checked whether the wipe ran.** No branch of the `case` inspected an
exit status. A failed `nvme format`, a `shred` that died on a bad sector, an
unknown `wipemode` that matched no branch at all — each fell through to
`echo "Wiping complete."` and `fog.nonimgcomplete`, which reported success to the
server. This is the same class of silent failure that
[ADR-0003](0003-fail-loud-on-partition-table-failure.md) removed from the
partition path, with a worse consequence: a mis-imaged disk is discovered when
the machine won't boot, whereas a disk wrongly believed wiped is discovered by
whoever finds the data on it.

**The mode override made it worse.** `wipemode="nvme"` was forced for any NVMe
target *before* the `case`, so an operator who explicitly chose `full` — the
strongest option offered — got the metadata-only format instead of the 3-pass
shred. The strongest choice silently became the weakest.

## What changed

The wipe primitive is now selected from the **device class**, not from a name
match, in `wipeDisk()` (`funcs.sh`). `fog.wipe` is reduced to safety countdown,
one call, and a `handleError` when it returns non-zero.

| class | `fast` | `normal` | `full` |
|---|---|---|---|
| nvme | `format --ses=2` (crypto erase) if FNA bit 2, else `--ses=1` | `format --ses=1` | `sanitize --sanact=2` if SANICAP bit 1, else `format --ses=1`; see the fallback rules below |
| ssd / unknown | `dd` zeros over metadata | `shred -n 1` **+ warning** | `shred -n 3 -z` **+ warning** |
| hdd | `dd` zeros over metadata | `shred -n 1` | `shred -n 3 -z` |

Class comes from `diskClass()`: `*nvme*` by name, otherwise the kernel's
`/sys/block/<dev>/queue/rotational` flag, and `unknown` when the kernel doesn't
say. `unknown` is treated as possibly-flash — it gets the SSD warning — because
the failure that matters is assuming flash is a platter, not the reverse.

`fast` is honestly labelled a metadata-only wipe on every non-NVMe class. It
destroys the partition table so the disk looks blank; it never claims to be a
secure erase. On NVMe it is a real erase, because a crypto erase is both
instantaneous and complete.

## Why format `--ses=1` is the floor, and sanitize only the preference

`format --ses=1` (user data erase) is the fallback everywhere because every
compliant NVMe controller supports it, it is synchronous, its exit status is
meaningful, and NIST SP 800-88r1 counts it as *Purge* for NVMe.

`sanitize` is preferred for `full` because it is strictly more thorough: format
`--ses=1` guarantees the namespace's user data, while sanitize covers the whole
controller including over-provisioned and unmapped blocks that no namespace-level
operation can address. It is not the floor because support is optional (gated on
SANICAP), it is asynchronous and must be polled, and — importantly — **sanitize
cannot be canceled once started**: it persists across power cycles and the drive
stays busy until it finishes. That last point breaks `fog.wipe`'s
power-off-to-cancel idiom, so the countdown must complete before sanitize is
issued, and the operator is told so on screen.

Falling back from sanitize to `format --ses=1` is safe *because both are a real
erase*. The fallback downgrades thoroughness, never to "no erase" — and the path
taken is printed. We probe SANICAP **before** issuing sanitize precisely so that
an unsupported drive never starts one.

But the fallback is only available **while no sanitize is running**, and this is
a hard rule rather than a preference. Once the controller accepts a sanitize it
will reject `format` with `SANITIZE_IN_PROGRESS (0x1d)` — the fallback cannot
succeed, so attempting it converts a probably-fine wipe into a reported failure.
`nvmeSanitize()` therefore has a three-value contract:

| rc | meaning | caller must |
|---|---|---|
| 0 | sanitize confirmed complete (SSTAT 1 or 4) | return success |
| 1 | no sanitize is running — rejected outright, or failed and failure mode cleared | fall back to `format --ses=1` |
| 2 | sanitize started but its outcome is unconfirmable | **not** fall back, and **not** claim the data survived |

Only rc 1 may fall back. The rc 2 case is the interesting one: because a sanitize
cannot be canceled and resumes across power cycles, a drive whose log we can no
longer read is not "unwiped" — it is *unknown*, and most likely still working.
Reporting either "erased" or "still holds its data" would be a guess. FOS prints
neither, and instead tells the operator to read `nvme sanitize-log` on the drive
itself, where SSTAT 1 or 4 is proof of completion.

Recovering from a *failed* sanitize (SSTAT 3) needs one extra step before the
fallback is legal. Status `0x1c` is defined as "the most recent sanitize
operation failed and **no recovery action has been successfully completed**",
which blocks `format` just as an in-progress sanitize does. `nvmeSanitize()`
issues `sanitize --sanact=1` (Exit Failure Mode) and only returns rc 1 if that
clears; if it doesn't, the drive is left alone and the wipe refuses.

A bare `nvme format` with no `--ses` is never issued by any path.
`tests/checks/wipe.sh` asserts this directly, and a negative-control run
(restoring the old `nvme format --force`) turns six cases red.

## Why the SATA SSD path still overwrites — a known, deliberate gap

`shred` on a SATA SSD is not a guaranteed erase, for the same reason the NVMe
format wasn't: wear levelling means the LBAs being overwritten are not the NAND
cells holding the old data, and over-provisioned blocks are never addressable at
all. The correct primitive is ATA SANITIZE (`hdparm --sanitize-block-erase` /
`--sanitize-crypto-scramble`) or ATA Secure Erase.

We did not implement it here, and the overwrite remains. Two reasons. First,
removing the existing behaviour without a working replacement would leave SATA
SSD users with less than they have today. Second — and this is the substantive
one — **the obstacle has already been investigated twice, and it is not merely
awkward.**

[#40](https://github.com/FOGProject/fos/issues/40) (2020) proposed exactly this
and was closed after testing found the SSD in `frozen` state despite advertising
`enhanced erase` support. [#61](https://github.com/FOGProject/fos/issues/61)
(2023) revisited it and reached the sharper conclusion:

> SSDs are frozen at boot from the UEFI, the way to unfreeze them would be to
> suspend the computer. Suspending the computer of course does not work on FOS
> since it is a login shell. SSDs will have to keep using `shred` and `dd`.

That is the real blocker, and it is worth stating precisely: the standard
unfreeze trick is a suspend-to-RAM cycle, and **FOS has no suspend to offer** —
it is a login shell in an initramfs, not a system with a power-management stack.
So the ATA path is not a matter of finding time to write it. It needs a way to
unfreeze the drive that FOS can actually perform, and that is an open problem, not
an unwritten function. Anyone picking this up should start at #40 and #61 rather
than from scratch.

So the honest position for this ADR is: **NVMe is fixed, SATA SSD is disclosed.**
An operator wiping a SATA SSD now gets a loud, explicit warning that the
overwrite may leave data recoverable and that the drive's own secure erase is the
real remedy. Telling the truth about a gap beats papering over it, and beats
removing a wipe that is at least better than nothing. Rotational disks
deliberately do *not* get this warning: overwriting genuinely erases them, and a
warning shown everywhere is a warning operators learn to ignore.

## Consequences

- **The NVMe wipe now takes real time.** `format --ses=1` is minutes and
  `sanitize` can be much longer, where the old no-op format returned in seconds.
  Operators used to a "wipe" finishing almost instantly will notice; that speed
  was the bug.
- **`full` on NVMe may be uncancelable** once sanitize starts. The 60-second
  countdown is the cancel window.
- **A failed wipe is now a failed task.** Runs that previously reported success
  while erasing nothing will now `handleError` and reboot. This is the point of
  the change, but it will surface as new "failures" that were always failures.
- **An unknown or empty `wipemode` now refuses** instead of doing nothing and
  reporting success. It is deliberately not defaulted to `normal`: guessing a
  destructive action on malformed input is its own hazard. The FOG server only
  ever sends `fast`/`normal`/`full` (`commons/schema.php`), so this should not
  fire in practice; the legacy `fastwipe` alias is still accepted.
- **No FOG-server change is needed.** The mode values and the `Post_Wipe.php`
  contract are unchanged.

## Verification

`tests/checks/wipe.sh` locks the mapping table above, asserts that no path ever
issues a format without an explicit `--ses`, and asserts that every primitive's
failure refuses rather than reports completion. Negative-control runs confirm
each fix is load-bearing: restoring the bare `nvme format --force` fails 6 cases,
swallowing the format exit status fails 2, swallowing `shred`'s exit status fails
1, moving the mode validation back behind the NVMe dispatch fails 4, reverting the
sanitize-log parse fails 5, and allowing a format fallback after a sanitize has
started fails 3.

That last control guards a non-obvious ordering constraint found while writing
these tests. `nvmeSecureErase()` treats any mode it does not recognise as
"neither full nor fast" and issues `format --ses=1`, so with the validation
placed after the class dispatch — the natural reading order — an unknown mode
refused on `/dev/sda` but *erased* `/dev/nvme0n1`. The mode check must stay ahead
of the dispatch, and the two NVMe cases pin it there.

## The sanitize poll was wrong, and the stub hid it

The caveat originally recorded here — that the harness "cannot prove the
`sanitize-log` JSON field names match every nvme-cli build" — fired on the first
hardware test. It is worth keeping the post-mortem rather than just the fix.

The poll parsed `jq -r '.sstat // empty'`, expecting `{"sstat":2,"sprog":32768}`.
What nvme-cli actually emits is three things different at once:

```json
{"/dev/nvme0":{"sprog":32768,"sstat":{"status":"(2) Sanitize in Progress.", ...}}}
```

The object is nested under a device-name key, `sstat` is an object rather than an
integer, and the status is a *string* with the code in parentheses. So `.sstat`
was null on the very first poll, `nvmeSanitize()` bailed, the code fell back to
`format`, the controller rejected it with `0x1d`, and the operator was told **"This
disk still holds its data"** about a drive that was — as far as anyone can tell —
sanitizing correctly. The one message worse than a wrong wipe is a wrong verdict
about a wipe, and this produced the exact inversion.

The important part is why 24 green tests didn't catch it: **the stub was written
from the same assumption as the parser.** It printed the flat shape I believed
nvme-cli emitted, so the tests confirmed the code agreed with me, not with
nvme-cli. A test double authored from the same misreading as the code under test
proves nothing, and does it convincingly. The stub is now transcribed from
`json_sanitize_log()` in nvme-cli's `nvme-print-json.c` (identical in 2.15, which
FOS ships, and 2.16), and the harness hard-requires real `jq` rather than a sed
shim that would reintroduce the same "half-right parser" hazard.

Verified against the emitting source, not against a drive: `id-ctrl` really is
flat (`sanicap` and `fna` sit at the root), so those probes needed no change.

**Still not validated on real hardware.** The harness stubs `nvme-cli`, so it
proves which commands FOS issues and how it reacts to their exit statuses; it
cannot prove that a physical drive erases. The corrected polling loop has been
reasoned from nvme-cli's source and pinned by tests, but has still not completed a
real sanitize end to end. It wants a pass on NVMe hardware before this is relied
on — and the lesson above is that its previous version wanted one too.
