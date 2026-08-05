# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

FOS (FOG Operating System) is the Linux-based init/kernel environment that FOG
imaging clients PXE-boot into. This repo does not contain the built OS — it
contains Buildroot configs/overlays and a kernel source patch that `build.sh`
uses to produce the init (filesystem) and kernel images consumed by
[FOGProject/fogproject](https://github.com/FOGProject/fogproject).

Nearly all imaging logic (capture, deploy, resize, wipe, LVM handling) lives
in two shell libraries under
`Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib/`:

- **`funcs.sh`** (~3600 lines) — the bulk of the imaging logic: partition
  save/restore, LVM capture/deploy/resize, disk wiping, hostname/registry
  changes, hardware inventory, sector-size validation/NVMe reformatting,
  error handling (`handleError`/`handleWarning`), filename helpers
  (`*FileName()`), etc.
- **`partition-funcs.sh`** (~790 lines) — the sfdisk-based partition
  table save/restore/fill/resize engine, EBR and swap-UUID handling, backed by
  `procsfdisk.awk` for the actual table-filling arithmetic.

Everything else under `rootfs_overlay/bin/fog.*` is a thin entry point
(`fog.download`, `fog.upload`, `fog.wipe`, `fog.inventory`, …) that sources
`funcs.sh`/`partition-funcs.sh` and calls into it. `bin/fog` is the top-level
dispatcher invoked by `etc/init.d/S99fog` at boot, branching on the `$mode`
(wipe/checkdisk/inventory/…) or `$type` (down/up) kernel command-line
variables.

## Build commands

`build.sh` builds both the Buildroot-based filesystem (init) and the Linux
kernel, for one or all of `x64`, `x86`, `arm64`. It downloads Buildroot and
kernel sources into the repo root (`fssource<arch>/`, `kernelsource<arch>/`)
the first time, applies `patch/filesystem/fs.patch` and `patch/kernel/linux.patch`
if present, and writes output into `dist/`.

```sh
./build.sh -n                # build everything (all archs, no confirmation prompts)
./build.sh -nf               # filesystem/init only, all archs
./build.sh -nfa x64           # filesystem/init only, x64
./build.sh -nk                # kernel only, all archs
./build.sh -nka arm64          # kernel only, arm64
./build.sh -i                 # attempt to install build dependencies first
./build.sh --fs-download-only # just download Buildroot source packages
./build.sh -h                 # full flag reference
```

Without `-n`/`--noconfirm`, the script pauses interactively to offer
`menuconfig` before each build. `dependencies.sh` (sourced by `build.sh`)
checks/installs required packages for Debian/Ubuntu and RHEL/Rocky/Fedora.

Buildroot filesystem configs live in `configs/fs{x64,x86,arm64}.config`;
kernel configs in `configs/kernel{x64,x86,arm64}.config`. Extra kernel driver
sources/configs to merge into the kernel tree live in
`KernelPackages/drivers/`.

`create-usb-image.sh` builds a bootable USB image from released
kernel/init artifacts (used by the `make_usb.yml` release workflow, not part
of the normal dev loop). `release.sh` is used for cutting releases.

CI (`.github/workflows/create_release.yml`, `create_experimental_release.yml`)
builds every arch/kernel-vs-filesystem combination in parallel via
`./build.sh --install-dep -n[fk]a <arch>` and publishes a GitHub release; do
not change the `RELEASE_NAME`/tag format, FOG's Kernel Update page parses it.

## Tests

There is no test suite for the kernel/Buildroot build itself — the only
tests are dev-only shell harnesses in `tests/`, covering the two shared
libraries. They live outside `rootfs_overlay`, so they never enter the built
init. See `tests/README.md` for full details.

```sh
tests/golden/run.sh capture   # (re)write the golden fixture — run BEFORE a refactor
tests/golden/run.sh check     # regenerate output and diff against the committed fixture
tests/golden/run.sh print     # dump current output to stdout, no comparison

tests/checks/sector-size.sh   # validateImageSectorSize() refusal/reformat behavior
tests/checks/fill-engine.sh   # sfdisk fill engine: 4Kn rescaling, GPT clamp, abort-on-unusable-table
tests/checks/wipe.sh          # wipeDisk() erase-primitive-per-device-class correctness
tests/checks/lvm.sh           # per-LV LVM capture/deploy/resize paths
tests/checks/secureboot.sh    # firmware-state detection, non-interactive MOK staging, Setup Mode db writes

tests/checks/secureboot-config.sh   # kernel configs carry the Secure Boot hardening symbols (ADR-0010)
tests/checks/pcie-aspm-config.sh    # kernel configs can control PCIe ASPM (ADR-0011)
```

The two `*-config.sh` harnesses assert on `configs/kernel*.config` rather than
on shell code; pass `-b` to also inspect the post-`oldconfig` `.config` in any
`kernelsource<arch>/` present, which is the check that actually proves the
symbol survived Kconfig.

Both harness families work the same way: they copy `funcs.sh`/
`partition-funcs.sh` into a temp sandbox, rewrite the hardcoded
`/usr/share/fog/lib` paths, PATH-shadow external tools (`blockdev`, `nvme`,
`shred`, `pvs`/`vgs`/`lvs`, …) with deterministic stubs, then source and
exercise the real functions — so they run on any host without real hardware
or root. `golden/` proves refactors of deterministic output-producing
functions change nothing observable; `checks/` asserts pass/fail behavior
(does it abort, does it issue the right command) that a single output stream
can't express. When touching either library, run the relevant harness(es)
before and after your change.

## Architecture notes and hard-won invariants

Design decisions with the reasoning behind them are recorded as ADRs in
`docs/adr/` — read the relevant one before changing behavior in these areas,
and add a new ADR for any similarly hard-to-reverse decision:

- **0001/0002/0005 — sector-size (512n/512e/4Kn) geometry.** A captured
  image's partition table and filesystem metadata bake in the source disk's
  *logical* sector size; deploying onto a target with a different logical
  sector size produces an unbootable disk, and FOS cannot safely translate
  that geometry. `validateImageSectorSize()` in `funcs.sh` refuses such a
  deploy — except on NVMe targets that expose a matching metadata-free LBA
  format, where it auto-reformats the namespace (with a 60s cancelable
  countdown) rather than refusing. Every other device class (eMMC/UFS/SATA/
  SAS/USB/virtual) stays refusal-only; the refusal message gets a
  class-specific hint instead. See `docs/CONTEXT.md` for the 512n/512e/4Kn
  vocabulary itself.
- **0003 — fail loud, never silently continue.** Partition-table
  compute/apply failures (`applySfdiskPartitions`, `fillSfdiskWithPartitions`,
  the `procsfdisk.awk` fill engine) are fatal (`handleError`) rather than
  logged-and-continued. A deploy that "succeeds" onto a half-written or wrong
  table is worse than one that stops with a message. This same principle
  governs the wipe path (0008) and the LVM paths (0004/0006): any new failure
  mode in these areas should abort, not warn-and-proceed.
- **0004/0006/0007 — LVM.** An LVM physical-volume partition is captured
  per-logical-volume (not as a raw PV blob) with a `d<disk>p<part>.lvm`
  sidecar plus a `vgcfgbackup`-produced `.lvm.vgcfg` describing the VG/LV
  layout; deploy recreates the PV/VG/LVs and restores each LV, preserving
  every UUID where possible. LV device paths (`/dev/<vg>/<lv>`) are handled in
  their own code path and must never be threaded through the `/dev/sdXN`
  partition-name machinery (`getPartitions`, `getPartitionNumber`, the sfdisk
  awk). ext filesystems inside LVs can shrink/grow at capture/deploy to fit
  different target sizes; other filesystem types and swap LVs keep their
  original size. LVM images currently refuse multicast deploy unless both
  client and server understand the `.lvm` sidecar ordering contract.
- **0008 — secure wipe.** The erase primitive `wipeDisk()` selects is keyed
  off **device class** (`diskClass()`: nvme / ssd / hdd / unknown from
  `/sys/block/*/queue/rotational`), never off a name match alone, and the
  return status of every erase command is checked — a wipe that didn't
  actually run must never report success. A bare `nvme format` with no
  `--ses` flag must never be issued (it doesn't guarantee erasure); prefer
  `sanitize` when supported, falling back to `format --ses=1` only when no
  sanitize is in progress or unrecoverably failed.
- **0009 — Secure Boot enrolment.** shim's `MokList` is a boot-services-only
  variable, so the running OS *cannot* enrol a MOK — only MokManager can, behind
  a physical-presence password. `secureboot-funcs.sh`/`fog.enrollsb` therefore
  **stage** a request and must never report that they enrolled anything. The
  automatable path is writing `db` while the platform is in **Setup Mode**; note
  that Secure Boot merely being switched *off* does not make `db` writable (the
  write policy follows the presence of a PK), so `sbState()` keeps `setup` and
  `disabled` as distinct answers. Signing tooling stays on the server — FOS
  writes `.auth` bytes it was handed, and no private key ever reaches the init.
  Four things in `sbWriteEfiAuthVar()`/`sbEnrollDb()` are load-bearing and fail
  *silently* if changed: `db` uses `EFI_IMAGE_SECURITY_DATABASE_GUID` while
  `PK`/`KEK` use the global GUID; the attribute prefix is `0x27` (the
  authenticated-write bit is not optional); efivarfs needs prefix and payload in
  a single `write()`; and `PK` is written **last**, because writing it leaves
  Setup Mode and any write after it must be signature-checked.
- **0010 — Secure Boot kernel hardening.** The lockdown LSM and the platform
  keyring are built into all three arch configs but lockdown is **not activated**
  (`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`) — activating it is downstream-only
  work gated on the vendor-shim question. `CONFIG_LSM` is set explicitly rather
  than left to `oldconfig`, because an LSM missing from the ordered list never
  initialises, and `CONFIG_LOAD_UEFI_KEYS` is what imports the firmware's `db`
  and `MokList` into the platform keyring. The trap this ADR exists for:
  `make oldconfig` **silently drops** any symbol whose dependencies are unmet,
  so a config can look right in git and produce a kernel missing lockdown
  entirely — which is why `tests/checks/secureboot-config.sh -b` inspects the
  post-`oldconfig` `.config` rather than the one we wrote.
- **0011 — PCIe ASPM.** `CONFIG_PCIEASPM` and (on x86) `CONFIG_PCI_MMCONFIG`
  must stay enabled, and the ASPM policy must stay `DEFAULT` or `PERFORMANCE` —
  never a power-saving one. Both symbols are `default y` upstream and were off
  in FOS from 2016 until this ADR; the out-of-tree Realtek vendor drivers hid
  that by managing ASPM themselves, so switching to in-kernel `r8169` turned it
  into a 10x deploy-throughput loss on RTL8168h under UEFI. The trap: with
  `CONFIG_PCIEASPM=n`, `pci_disable_link_state()` is a stub that **returns
  success**, so `r8169` believes the OS disabled L1, sets `aspm_manageable`,
  and then enables ASPM and L1.2 in the chip — silently. Without
  `CONFIG_PCI_MMCONFIG` the L1-substates extended capability is not even
  reachable (that is what the `falling back to CSI` notice reports), and
  `pcie_aspm=off` on the command line does nothing because the `__setup()` that
  registers it is compiled out. Guarded by `tests/checks/pcie-aspm-config.sh`.

General conventions to preserve when editing `funcs.sh`/`partition-funcs.sh`:

- Both libraries hardcode `/usr/share/fog/lib` as their own path and expect to
  run inside the built init; the only way to unit-test them off-target is the
  sandbox-and-stub mechanism the `tests/` harnesses already use — follow that
  pattern for new tests rather than inventing another.
- Fatal conditions go through `handleError` (aborts the task); recoverable/
  informational ones through `handleWarning`. New failure paths in the
  partition, wipe, or LVM code should be fatal per the ADR-0003 precedent
  unless there's a specific reason to just warn.
- `*FileName()` helper functions are the single source of truth for on-disk
  sidecar/metadata filenames — reuse them rather than constructing paths
  inline.
