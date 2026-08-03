# Secure Boot enrolment: stage a MOK request, enrol into db, never pretend either is automatic

FOG generates a Secure Boot signing key by default and signs the FOS kernels
with it on every install and upgrade. What it has never had is a way to get that
certificate **trusted on more than a handful of machines**. Both delivery routes
end at a human at a keyboard: the USB enrolment kit (`fog-enroll-mok.sh` on a
stock Ubuntu/Debian live image) and PXE menu item 14, which chains MokManager
directly and still needs `MOK.der` on local FAT media because MokManager has no
network stack.

This ADR records why the obvious fix is impossible, what is possible instead,
and which of the two the code is allowed to describe as automatic.

## MOK enrolment cannot be automated, and no tooling changes that

`mokutil --import` writes the `MokNew` UEFI variable, which is
runtime-accessible. `MokList` — the store shim actually consults when deciding
whether to load a binary — is **boot-services-only**. The running OS physically
cannot write it after ExitBootServices. Only MokManager, executing in boot
services before the OS starts, can promote `MokNew` into `MokList`, and it
demands the one-time password as proof that a human is present.

That is shim's entire security model. If the OS could enrol a key silently,
Secure Boot would mean nothing, because the first thing any malware would do is
enrol its own. There is no `--yes` flag, there is no environment variable, and
there should not be one. Any future change that appears to have found a way
around this has almost certainly found a bug, and the correct response is to
report it upstream rather than to depend on it.

**Consequence for this codebase:** `sbStageMok()` is named for what it does. It
stages a request. It does not enrol anything, no message in `fog.enrollsb` may
claim it did, and the task reports "pending", not "enrolled".

## What *can* be automated: db in Setup Mode

`db`, `KEK` and `PK` are authenticated variables. Their write policy follows the
presence of a **PK**, not the Secure Boot enforcement bit. While the platform is
in **Setup Mode** (PK absent), writes are unauthenticated, and from FOS that is
a plain write to `efivarfs` — a four-byte attribute prefix and a payload, no
signing tooling required on the client at all.

This distinction is easy to get wrong and expensive when it is:

> **Secure Boot being switched off does NOT make `db` writable.** A machine in
> User Mode with enforcement disabled still has a PK, and every `db` write on it
> requires a KEK-signed authenticated update. Only Setup Mode helps.

`sbState()` therefore reports `setup` and `disabled` as different answers rather
than collapsing them into a boolean, and `tests/checks/secureboot.sh` asserts
that separation directly. Conflating them would make the db path attempt a write
that silently fails on every machine whose owner merely toggled Secure Boot off
in firmware.

The chicken-and-egg resolves in our favour: for a FOS task to run at all, Secure
Boot must already be off or FOG's key already trusted — which is exactly the
state a machine is in when this task is worth running.

## The client needs no signing tools

`efitools` and `sbsigntool` are not Buildroot packages, and adding them was
considered and rejected. The `.auth` blobs are built on the **server**, where the
signing key already lives and where `sbsign` is already a dependency. FOS writes
bytes it was handed. This keeps the private key on exactly one machine and keeps
the init small, and it mirrors the split the existing `fog-sign-kernel` sudo
helper already established.

`mokutil` *is* a stock Buildroot package and is now enabled on all three
architectures. It pulls in `efivar`, `keyutils` and `libxcrypt` by `select`.

## Non-interactive mokutil

A task has no terminal, so the usual password prompt is fatal to automation.
`--generate-hash=<pw>` prints a SHA-512 crypt string without prompting, and
`--import --hash-file <f>` consumes it: `update_request()` in mokutil takes the
hash-file branch and never reaches `get_password()`. Both are documented
options, verified against mokutil 0.7.2 — the version Buildroot builds.

The password **must not** travel on an `--import` argv, where it would be
visible in `ps` output and in any command log. `tests/checks/secureboot.sh`
case 18 asserts this, because a regression that reverted to piping would still
pass a naive "did the import run" check.

The password is not a secret. It authenticates nothing at rest; it exists so the
person answering MokManager is demonstrably the person who requested the
enrolment. It therefore has to be *shown* to the technician. `$sbmokpw` sets one
password fleet-wide, which is the difference between typing the same six
characters down a row of machines and reading a different random string off each
screen.

## Fail loud, per ADR-0003

`mokutil` can exit 0 having staged nothing. `sbStageMok()` re-reads
`--list-new` rather than trusting the exit status, because a request that
silently did not stage sends a technician to reboot a machine that boots
straight past MokManager with no explanation — the same class of silent success
[ADR-0003](0003-fail-loud-on-partition-table-failure.md) removed from the
partition path and [ADR-0008](0008-secure-wipe-by-device-class.md) removed from
the wipe path.

A BIOS/CSM boot, or UEFI with unmountable efivarfs, aborts rather than reporting
a success that enrolled nothing.

## Why the shipped `db` baseline is Microsoft's certificates

*(Decided here, implemented in Phase 2.)*

The db path replaces the platform PK, so what goes into `db` alongside FOG's
certificate is the load-bearing decision. It will be Microsoft's published
certificates — KEK CA 2011, Windows Production PCA 2011, UEFI CA 2011, and the
2023 generation.

The decisive reason is **not** Windows compatibility. It is FOG itself.
`downloadipxesecureboot()` in the fogproject installer notes that the Secure
Boot iPXE binaries are *"signed by keys FOG does not hold: Microsoft's, for the
shim, and iPXE's."* FOG's own chain is `shimx64.efi` → signed iPXE → FOG-signed
kernel, and that shim is signed by **Microsoft Corporation UEFI CA 2011**. A
`db` without that CA breaks FOG's own Secure Boot PXE boot: we would enrol the
key and break the thing we enrolled it for.

**Rejected as the baseline: capturing each machine's factory keyset.** It reads
`db`/`KEK`/`dbx` from efivarfs and restores them afterwards, which sounds
strictly safer and is not:

- It has no answer for the first machine of any model.
- It depends on an ordering the admin cannot recover from getting wrong. Once
  "clear all keys" has been done in firmware, the factory keyset is gone.
- Restoring a `dbx` captured at an older BIOS **re-trusts bootloaders revoked
  since**. That is a security regression, and a silent one.

Capture survives as *optional enrichment* (Phase 3): its real value is narrower
than it first appears — preserving OEM-specific `db` entries so vendor tooling
(Dell SupportAssist OS Recovery, HP Sure Recover, Lenovo diagnostics) keeps
working. Losing those is visible and non-destructive, so it warrants a warning,
not a refusal.

`dbx` is deliberately **not** baked into the shipped bundle. A stale revocation
list shipped by FOG is worse than none, and it would make FOG responsible for
keeping it current. The intent is to fetch the current UEFI revocation list at
install time and refuse to write an older `dbx` over a newer one.

## What stays manual, and why that is acceptable

Entering Setup Mode and enabling Secure Boot are firmware operations. They
collapse into **one BIOS visit**: set "Secure Boot: Enabled" and "Clear all
keys" together, and the machine reboots in Setup Mode with enforcement pending.
FOS enrols, and the next boot is Secure Boot active with FOG trusted.

Automating even that is possible but vendor-specific — `cctk` (Dell Command |
Configure) has a Linux build and could run from inside FOS; Redfish
(`/redfish/v1/Systems/{id}/SecureBoot`) does it fully out-of-band on server
hardware with no client boot at all. Deliberately out of scope here: it is a
per-vendor integration surface, not a property of the enrolment mechanism.

## Consequences

- A new library, `secureboot-funcs.sh`, rather than more of `funcs.sh`. It
  shares no state, vocabulary or failure modes with the imaging engine.
- A new entry point, `bin/fog.enrollsb`, and `mode=enrollsb` in `bin/fog`.
- `rootfs_overlay/etc/fstab` mounted efivarfs with type `efivars`, which is not
  a mountable filesystem type — it was the old `CONFIG_EFI_VARS` sysfs interface
  at `/sys/firmware/efi/vars`. The entry silently failed under the `mount -a` in
  `inittab` and FOS had no EFI variable access at all. Fixed to `efivarfs`.
- 32-bit UEFI gets no MOK path: no signed 32-bit shim exists (already noted in
  `_enrollSecureBootChoice`). The db path would still work there.

## Not yet validated on hardware

Writing `PK`/`KEK`/`db` is not reversible from the OS — getting it wrong needs a
firmware trip to recover. The Phase 1 MOK staging path is reversible
(`mokutil --revoke-import`) and much lower risk, which is why it ships first.
Phase 2 wants per-model hardware validation before it is relied on.
