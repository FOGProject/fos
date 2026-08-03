# Secure Boot enrolment: only Setup Mode scales, because FOS cannot bootstrap its own trust

FOG generates a Secure Boot signing key by default and signs the FOS kernels
with it on every install and upgrade. What it has never had is a way to get that
certificate **trusted on more than a handful of machines**. Both existing routes
end at a human at a keyboard: the USB enrolment kit (`fog-enroll-mok.sh` on a
stock Ubuntu/Debian live image) and PXE menu item 14, which chains MokManager
directly and still needs `MOK.der` on local FAT media because MokManager has no
network stack.

This ADR records the constraint that governs every possible design here, which
of the available paths survive it, and — importantly — a design this ADR
originally got wrong.

## The governing constraint: trust cannot bootstrap itself

**Whatever performs the enrolment must already be trusted by the firmware.**
Every viable design is a different answer to "trusted by what?", and every
non-viable design is one that forgot to ask.

Two independent walls enforce this.

### Wall 1 — MOK enrolment always requires a human

`mokutil --import` writes the `MokNew` UEFI variable, which is
runtime-accessible. `MokList` — the store shim actually consults when deciding
whether to load a binary — is **boot-services-only**. The running OS physically
cannot write it after ExitBootServices. Only MokManager, executing in boot
services before the OS starts, can promote `MokNew` into `MokList`, and it
demands a one-time password as proof that a human is present.

That is shim's entire security model. If the OS could enrol a key silently,
Secure Boot would mean nothing, because the first thing any malware would do is
enrol its own. There is no `--yes` flag and there should not be one. Any future
change that appears to have found a way around this has almost certainly found a
bug; report it upstream rather than depend on it.

**Consequence for this codebase:** `sbStageMok()` is named for what it does. It
stages a request. It does not enrol anything, no message in `fog.enrollsb` may
claim it did, and the task reports "pending", not "enrolled".

### Wall 2 — FOS itself is not loadable until the key is already trusted

**This is the correction.** An earlier revision of this ADR assumed FOS could
boot on a Secure-Boot-enforcing machine and stage a MOK request there, turning a
prepared-USB-media visit into a scheduled task. That assumption was false, and
it survived 26 passing harness cases because no unit test can observe firmware
policy.

Measured on real firmware (VirtualBox 7.2 EFI, Secure Boot enforcing, MokList
empty — 2026-08-03):

```
NBP filename is secureboot/snponly-shimx64.efi     <- MS-signed, accepted
Fetching Netboot Image secureboot/snponly.efi      <- iPXE-signed, accepted
iPXE 2.0.0 ... http://<server>/fog/service/ipxe/boot.php... ok
bzImage... ok
Verification failed: Security Policy Violation
init.xz... ok
Verification failed: Security Policy Violation
Could not boot: Error 0x7f04819a
```

**iPXE verifies the kernel *and* the initrd through shim.** The signed chain
loads fine right up to the point where FOG's own artefacts are checked against a
MokList that does not yet contain FOG's certificate, and both are refused.

So FOS can never be the thing that establishes trust in FOG's key on a machine
that is enforcing Secure Boot. The task that would enrol the key cannot run on
the machine that needs it enrolled.

## The three paths that survive, ranked

Each is a different source of pre-existing trust.

### 1. Setup Mode — no trust required (the fleet answer)

`db`, `KEK` and `PK` are authenticated variables whose write policy follows the
presence of a **PK**, not the Secure Boot enforcement bit. While the platform is
in **Setup Mode** (PK absent) writes are unauthenticated, nothing is enforcing,
so FOS loads normally and can write FOG's certificate straight into `db` — a
plain `efivarfs` write of a four-byte attribute prefix and a payload, with no
signing tooling on the client at all.

No MokManager, no password, no blue screen, no prepared media. The cost is one
firmware visit to clear the platform keys, and that visit can be the same one
where the tech enables Secure Boot — so it is one BIOS screen, once, per machine,
ever.

This distinction is easy to get wrong and expensive when it is:

> **Secure Boot being switched off does NOT make `db` writable.** A machine in
> User Mode with enforcement disabled still has a PK, and every `db` write on it
> requires a KEK-signed authenticated update. Only Setup Mode helps.

`sbState()` therefore reports `setup` and `disabled` as different answers rather
than collapsing them into a boolean, and `tests/checks/secureboot.sh` asserts
that separation directly.

#### How the write is actually done, and the four ways to get it wrong

Implemented as `sbFetchAuthVar()` / `sbWriteEfiAuthVar()` / `sbEnrollDb()`. Each
of the following is a decision with a failure mode that firmware accepts
silently, so each has a dedicated assertion in the harness:

- **Namespace.** `db` and `dbx` live under `EFI_IMAGE_SECURITY_DATABASE_GUID`
  (`d719b2cb-…`); `PK` and `KEK` live under `EFI_GLOBAL_VARIABLE`
  (`8be4df61-…`). Writing `db` under the global GUID creates a junk variable the
  firmware ignores — and efivarfs accepts the write, so it looks like it worked.
  The two GUIDs are separate constants, not one default with an exception.
- **Attributes `0x27`** = `NV|BS|RT|TIME_BASED_AUTHENTICATED_WRITE_ACCESS`, as a
  four-byte little-endian prefix. Drop the authenticated bit and the firmware
  stores the payload as raw data instead of applying it as a signed update.
- **One `write()`.** efivarfs requires the attribute prefix and the payload in a
  single write; a split write is rejected outright. Hence `dd bs=<total>
  count=1 iflag=fullblock` over a pre-concatenated file, not `cat a b > var` —
  `cat` happens to do one write at these sizes, but that is a property of its
  buffer, not a guarantee. Existing entries carry the kernel's immutable flag,
  cleared with `chattr -i` first.
- **Order: `db`, `KEK`, `PK` — PK last.** Writing `PK` is what takes the platform
  out of Setup Mode; from that moment every further write must carry a signature
  the firmware checks. `PK` first makes the `db` and `KEK` writes bounce, leaving
  a machine that enforces Secure Boot and trusts nothing — recoverable only at
  the firmware screen. This is the single most damaging ordering mistake
  available in this file.

All three blobs are downloaded before any is written: a web server hiccup should
cost a retry, not leave a platform mid-enrolment.

### 2. Out-of-band (Redfish / vendor BMC) — the only zero-touch tier

On hardware with a BMC, `/redfish/v1/Systems/{id}/SecureBoot` and its
`SecureBootDatabases` collection let the server write `db` with the client
powered off. No boot, no OS, no physical presence — authenticated by BMC
credentials instead. Dell `cctk` is the equivalent for desktops where a trusted
OS is already running.

This is the only path that is genuinely automated end to end, and it should be
described as the zero-touch tier rather than as a "follow-on".

### 3. Borrowed trust (MS-signed live Linux) — the existing USB kit

Ubuntu/Debian live boots under enforcing Secure Boot because Microsoft signed
*its* shim, so mokutil runs there. This is what `fog-enroll-mok.sh` already does.
It still ends at MokManager. It remains the answer for a machine that cannot be
put into Setup Mode.

## Where the staged-MOK task (`fog.enrollsb`) actually fits

Given Wall 2, this task is **not** the fleet answer and must not be presented as
one. Its honest scope is: **machines that currently have Secure Boot off and are
going to have it turned on.**

That is a real and common case — plenty of sites disable Secure Boot precisely so
they can use FOG, and want it back on afterwards. There, the task stages the key
with no USB media, no live image and no fingerprint transcription, and the tech
confirms once at MokManager. That is a genuine improvement on the USB kit for
that case, and nothing more.

On an enforcing machine the task cannot run at all, so no in-code guard is
needed — the failure happens in iPXE, before FOS exists. `fog.enrollsb` still
reports Setup Mode explicitly when it sees it, because that machine is a
candidate for path 1 and the operator should be told so.

## Non-interactive mokutil (validated)

A task has no terminal, so the usual password prompt is fatal to automation.
`--generate-hash=<pw>` prints a SHA-512 crypt string without prompting, and
`--import --hash-file` consumes it: `update_request()` in mokutil takes the
hash-file branch and never reaches `get_password()`. Both are documented
options, verified against mokutil 0.7.2 — the version Buildroot builds.

Confirmed on hardware: after the task ran, the client's NVRAM carried `MokNew`
and `MokAuth`, with FOG's exact 810-byte DER certificate at offset 44 of the
854-byte `MokNew` (44 bytes being the `EFI_SIGNATURE_LIST` header plus owner
GUID), and shim displayed "Shim UEFI key management" on the next boot.

The password **must not** travel on an `--import` argv, where it would be visible
in `ps` output and any command log. `tests/checks/secureboot.sh` case 18 asserts
this, because a regression to piping would still pass a naive "did the import
run" check.

The password is not a secret. It authenticates nothing at rest; it exists so the
person answering MokManager is demonstrably the person who requested the
enrolment. `$sbmokpw` sets one password fleet-wide.

## Fail loud, per ADR-0003

`mokutil` can exit 0 having staged nothing. `sbStageMok()` re-reads `--list-new`
rather than trusting the exit status, because a request that silently did not
stage sends a technician to reboot a machine that boots straight past MokManager
with no explanation — the same class of silent success
[ADR-0003](0003-fail-loud-on-partition-table-failure.md) removed from the
partition path and [ADR-0008](0008-secure-wipe-by-device-class.md) from the wipe
path.

A BIOS/CSM boot, or UEFI with unmountable efivarfs, aborts rather than reporting
a success that enrolled nothing.

The Setup Mode path has the same shape of guard, because `dd` can write bytes
into efivarfs that the firmware then declines to apply. `sbEnrollDb()` therefore
re-reads `SetupMode` and requires it to have flipped `1 → 0` before reporting
success: that is the firmware confirming it accepted the `PK`, and it is the only
confirmation available before a reboot (`SecureBoot` stays `0` until the next
POST computes it). An enrolment that failed part-way stops before the `PK` write,
so the machine is still in Setup Mode and still boots whatever it booted before —
`fog.enrollsb` says so explicitly, because "Secure Boot enrolment failed"
otherwise reads like the machine may now be unbootable.

## Why the `db` baseline is Microsoft's certificates

Path 1 replaces the platform PK, so what goes into `db` alongside FOG's
certificate is load-bearing. It is Microsoft's published certificates — KEK
CA 2011, Windows Production PCA 2011, UEFI CA 2011, plus the 2023 generation —
vendored in fogproject at `packages/secureboot/mscerts/` with a MANIFEST
recording each source URL and sha256.

The decisive reason is **not** Windows compatibility, it is FOG itself. The chain
measured above is `shimx64.efi` → signed iPXE → FOG-signed kernel, and that shim
is signed by **Microsoft Corporation UEFI CA 2011**. A `db` without that CA
breaks FOG's own Secure Boot PXE boot — we would enrol the key and break the
thing we enrolled it for.

**Rejected as the baseline: capturing each machine's factory keyset.** No answer
for the first machine of a model; depends on an ordering the admin cannot recover
from getting wrong (once "clear all keys" is done the factory keyset is gone);
and restoring a `dbx` captured at an older BIOS re-trusts bootloaders revoked
since. Capture survives as *optional enrichment* — preserving OEM-specific `db`
entries so vendor tooling (Dell SupportAssist OS Recovery, HP Sure Recover,
Lenovo diagnostics) keeps working. Losing those is visible and non-destructive,
so it warrants a warning, not a refusal.

`dbx` is deliberately **not** baked into the shipped bundle. A stale revocation
list shipped by FOG is worse than none and would make FOG responsible for keeping
it current.

## Consequences

- A new library, `secureboot-funcs.sh`, rather than more of `funcs.sh`. It shares
  no state, vocabulary or failure modes with the imaging engine.
- A new entry point, `bin/fog.enrollsb`, and `mode=enrollsb` in `bin/fog`. It
  picks its path from `sbState()`: `setup` takes the automatic `db` route and
  finishes; anything else stages a MOK request for a human to confirm.
- No new Buildroot packages for path 1. It needs `coreutils` (GNU `dd`,
  `iflag=fullblock`), `e2fsprogs` (`chattr`) and `curl`, all already in the FOS
  configs. Deliberately no signing tooling on the client: the server signs the
  updates, the client only writes them.
- `rootfs_overlay/etc/fstab` mounted efivarfs with type `efivars`, which is not a
  mountable filesystem type — it was the old `CONFIG_EFI_VARS` sysfs interface at
  `/sys/firmware/efi/vars`. The entry silently failed under the `mount -a` in
  `inittab` and FOS had no EFI variable access at all. Fixed to `efivarfs`, and
  confirmed against real firmware: the attribute mask on `SetupMode` is `0x06`
  (BS|RT, no NV bit), i.e. these variables are volatile and readable only from a
  booted OS — which is why detection lives in FOS and not on the server.
- 32-bit UEFI gets no MOK path: no signed 32-bit shim exists (already noted in
  `_enrollSecureBootChoice`). Path 1 would still work there.

## Hardware validation

**Path 1 validated end to end on 2026-08-03** (VirtualBox 7.2 EFI, platform keys
cleared to enter Setup Mode). The task enrolled with nobody at the keyboard, and
the firmware afterwards held exactly what it should:

- `db` — Microsoft's five db CAs plus FOG's signing certificate
- `KEK` — Microsoft's two KEK CAs plus this server's KEK
- `PK` — this server's PK alone

Secure Boot was then switched **on**, and the same machine PXE-booted FOG's
signed chain: `bzImage... ok`, `init.xz... ok`, where before enrolment both were
refused with `Verification failed: Security Policy Violation`. That is the whole
feature demonstrated in one line.

Still open: per-model validation on physical firmware. Writing `PK`/`KEK`/`db` is
not reversible from the OS, so a model that rejects the update needs a firmware
trip to recover.

### What the harness can and cannot prove

Worth stating plainly, because this ADR has now recorded **two** things that
passed every test and were still wrong.

The cases prove the **bytes and the sequence**: the right namespace, the right
attribute mask, one write, `PK` last, no writes after a failed download, and a
refusal when `SetupMode` does not flip. They cannot prove that a given firmware
*accepts* the update — that is a property of the machine.

They also cannot prove that an external tool's output looks the way this code
assumes. `sbCertTrusted()` used to grep `mokutil --db` for the certificate's
SHA-256; mokutil prints a **SHA1** fingerprint there, so the match could never
fire. The stub in the harness had been written to emit the SHA-256 the code was
looking for, so **the test agreed with the bug** and reported success for a
fortnight. On the first machine whose `db` already held the certificate, the task
skipped its short-circuit, tried to stage a MOK, was refused by mokutil (which
will not stage a request for a certificate already in `db`), and aborted.

The fix is a rule, not a patch: **answer from the data where a spec defines it,
and from the tool only where the tool owns the format.** db membership is now
decided by searching the variable for the certificate's own bytes — the UEFI
signature-list layout is published and cannot drift. MokList membership still
goes through `mokutil`, but against strings read out of the binary rather than
imagined. See also the `test-doubles-from-source` note: a double built from a
guess is a second copy of the guess, not a check on it.
