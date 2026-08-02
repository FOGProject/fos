# 0009 — Secure Boot kernel hardening, and why lockdown is not yet activated

## Status

Partially implemented. The kernel configuration is in place; the code that
*activates* lockdown when Secure Boot is on is deliberately not, and the reason
is recorded below so the next person does not have to rediscover it.

## Context

A site that mandates UEFI Secure Boot must sign the FOS kernel with its own key
and enrol that key per machine. FOG automates the signing
(`build.sh --sign-key`, plus the installer side in FOGProject/fogproject), but
signing only gets the kernel *loaded*. It says nothing about what the kernel
then permits.

The reason that matters is not academic. If FOG ever wants its own
Microsoft-signed shim — the only route to Secure Boot working out of the box,
rather than after a per-machine visit — `rhboot/shim-review` asks directly:

> How does your signed kernel enforce lockdown when your system runs with
> Secure Boot enabled?

A signed kernel that does not enforce lockdown is a Secure Boot bypass: anyone
can boot it on any machine that trusts the signer and then use `/dev/mem`,
`iopl()` or `kexec_load()` to do whatever they like to a kernel the firmware
just vouched for. That is why reviewers ask, and it is the single largest gap
between FOS today and a kernel anyone would sign for general use.

Two things about FOS make this easier than it usually is:

- **There are no modules.** `# CONFIG_MODULES is not set`; the config is 1829
  `=y` and zero `=m`. The out-of-tree Realtek drivers are not external modules
  either — `addKernelPackages()` copies them into the source tree and appends
  to `Kconfig`/`Makefile`, so they are built in and covered by the kernel's own
  signature. This answers shim-review's other recurring question, about
  ephemeral per-build module-signing keys, with "we build no modules".
- **`CONFIG_EFI_STUB=y` already.** Under Secure Boot the kernel is started by
  the firmware's loader rather than iPXE's, which requires the stub.

## Decision

Enable the lockdown LSM and the platform keyring infrastructure in all three
architecture configs, but **do not force lockdown on**:

- `CONFIG_SECURITY=y`, `CONFIG_SECURITYFS=y` — neither was set, so the lockdown
  LSM could not even be selected.
- `CONFIG_SECURITY_LOCKDOWN_LSM=y` and `_EARLY=y`. The early variant matters
  because some boot parameters are parsed before LSM init would otherwise run.
- `CONFIG_LSM="lockdown,integrity"`. An LSM that is built but absent from the
  ordered list never initialises. Set explicitly rather than left for
  `oldconfig` to default, because the upstream default string names LSMs this
  kernel does not build.
- `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y` — see below.
- `CONFIG_ASYMMETRIC_KEY_TYPE=y` and the keyrings
  (`SYSTEM_TRUSTED_KEYRING`, `SECONDARY_TRUSTED_KEYRING`,
  `SYSTEM_BLACKLIST_KEYRING`, `INTEGRITY_PLATFORM_KEYRING`,
  `LOAD_UEFI_KEYS`). `LOAD_UEFI_KEYS` is the one that imports the firmware's
  `db` and `MokList` into the platform keyring; without it the kernel cannot
  see the key the shim just validated against.
- `# CONFIG_KEXEC is not set`. The old `kexec_load()` syscall is
  unconditionally blocked by lockdown and FOS never uses it, so removing it
  beats leaving it to be refused at runtime.

### Why not `LOCK_DOWN_KERNEL_FORCE_INTEGRITY`

It would be one line and it would activate lockdown today. It is the wrong
default anyway, because it locks the kernel down on **every** boot — including
the overwhelming majority of FOG deployments that never turn Secure Boot on.
Lockdown blocks `/dev/mem`, `/dev/port`, `iopl`/`ioperm`, raw PCI BAR access
and direct MSR access. FOS's hardware inventory is the obvious thing at risk:
modern `dmidecode` prefers `/sys/firmware/dmi/tables/`, but anything that falls
back to `/dev/mem` would start failing for users who gained nothing in return.

Distributions all resolve this the same way: build the LSM in, leave it
inactive, and activate it at boot **only when the firmware reports Secure Boot
is on**. That is the behaviour FOS wants.

## The part that is not done, and what it actually takes

Activating lockdown from the Secure Boot state is **not upstream**. It is a
downstream patch every distribution carries, and the investigation below is
recorded because the shape of it is not obvious from the outside:

- `security_lock_kernel_down()` — the function Fedora's and Ubuntu's patches
  call — **does not exist in mainline 6.18**. `include/linux/security.h`
  exports only `security_locked_down()`, the query. The distro patches add the
  setter to the LSM infrastructure, touching `include/linux/security.h`,
  `security/security.c` and `include/linux/lsm_hook_defs.h`.
- `efi_enabled(EFI_SECURE_BOOT)` **also does not exist in mainline 6.18**;
  `EFI_SECURE_BOOT` is a downstream flag. Upstream x86 keeps the state in
  `boot_params.secure_boot` and, in `setup_arch()`
  (`arch/x86/kernel/setup.c`), only *prints* it:

  ```c
  if (efi_enabled(EFI_BOOT)) {
          switch (boot_params.secure_boot) {
          case efi_secureboot_mode_enabled:
                  pr_info("Secure boot enabled\n");
  ```

  That `case` is exactly where the distro patches insert the lockdown call.
- A smaller alternative exists: `lockdown_lsm_init()` in
  `security/lockdown/lockdown.c` already calls a **file-local**
  `lock_kernel_down()` for the FORCE_* options, so a single-file patch there
  could activate lockdown without touching LSM infrastructure at all. It still
  needs an architecture-neutral way to read the Secure Boot state at LSM init
  time, which is the unsolved part.

This was left unwritten on purpose. `build.sh` applies `patch/kernel/linux.patch`
with `patch -p1` and **exits non-zero if it fails**, so a patch that does not
apply cleanly breaks every build for everyone, and takes the Intel VMD patch
down with it. A multi-file, architecture-specific kernel patch that has never
been compiled or booted does not belong in that file. Whoever picks this up
should build and boot it first.

### Settle the initrd question before going further

FOS boots as `bzImage` plus a network-supplied kernel command line (`mode=`,
`type=`) plus an unsigned ext2 `init.xz`. shim-review does not literally
mandate a Unified Kernel Image — lockdown in integrity mode is the accepted
mitigation, and UKIs are mentioned only in passing — but for a payload shaped
like this one a reviewer will push hard, because a signed kernel that accepts
an arbitrary command line and an unverified initrd is most of the way back to
the bypass lockdown is supposed to prevent.

That question is worth answering **before** anyone writes the lockdown patch.
If FOG cannot move to a UKI, an application for its own shim probably is not
winnable, and the patch buys nothing on its own.

## Consequences

- The configs are inert for now: lockdown is compiled in but never activated,
  so behaviour is unchanged for every existing user. That is the point — this
  lands the reviewable, testable half without a flag day.
- `CONFIG_SECURITY=y` pulls a lot of new Kconfig into the build. The three
  configs are hand-edited and `make oldconfig` **silently drops symbols whose
  dependencies are not met**, so a config can look right in git and produce a
  kernel that is missing lockdown entirely. `tests/checks/secureboot-config.sh`
  asserts the symbols are present, and with `-b` re-checks the `.config`
  Kconfig actually produced after a build. Run it with `-b` after building.
- **This has not been built or booted.** No kernel was compiled while making
  this change. Before merging: build all three architectures, boot with Secure
  Boot off and image a machine end to end, and confirm the Realtek NICs and
  Intel VMD NVMe still work — those two are the entire reason FOS carries a
  custom kernel, and `CONFIG_SECURITY`/keyring churn is exactly the kind of
  change that could disturb them.

## References

- `rhboot/shim-review` — <https://github.com/rhboot/shim-review>
- Lockdown LSM — <https://lwn.net/Articles/791863/>,
  `man 7 kernel_lockdown`
- ADR 0003, for the "fail loud rather than continue" principle this follows in
  refusing to ship an untested patch.
