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

`bump-package.sh` moves one of FOG's own Buildroot packages to a new version,
rewriting its `_VERSION` and its `.hash` together (see the next section):

```sh
./bump-package.sh cabextract 1.12            # bump, fetching from upstream
./bump-package.sh cabextract 1.12 --dry-run  # report, write nothing
./bump-package.sh --check                    # re-verify every committed hash
```

`create-usb-image.sh` builds a bootable USB image from released
kernel/init artifacts (used by the `make_usb.yml` release workflow, not part
of the normal dev loop). `release.sh` is used for cutting releases.

CI (`.github/workflows/create_release.yml`, `create_experimental_release.yml`)
builds every arch/kernel-vs-filesystem combination in parallel via
`./build.sh --install-dep -n[fk]a <arch>` and publishes a GitHub release; do
not change the `RELEASE_NAME`/tag format, FOG's Kernel Update page parses it.

## Package sources and hashes (read before bumping a package version)

The five packages under `Buildroot/package/` (`cabextract`, `chntpw`,
`testdisk`, `partimage`, `partclone`) are FOG's own additions. None exists
upstream in Buildroot, so `sources.buildroot.net` — the backup mirror that
covers every other package in the tree — has never carried them and 404s
instead of helping. Buildroot allows a package exactly one `_SITE`, so upstream
is the only source it knows about. That cost two release builds (2026-08-03 and
2026-08-17, both cabextract) and is the usual cause of a local build failing
behind corporate egress filtering.

`seedFragileSources()` is the mirror list Buildroot has nowhere to put. It lives
in `package-funcs.sh` alongside the `.mk` parsing, because `build.sh`,
`bump-package.sh` and the test harness all need it and `build.sh` cannot be
sourced (it runs a whole build). It seeds `$DL_DIR` before Buildroot looks at it, which works because
`dl-wrapper` keeps a file that is already present *when it matches the
package's `.hash`* and exits without touching the network. It runs for a plain
local build as well as `--fs-download-only`.

Rules that matter when touching any of this:

- **Use `./bump-package.sh <pkg> <version>` rather than editing by hand.** The
  version determines the source filename and Buildroot looks the hash up *by
  filename*, so the two have to move together; without a matching line the
  build aborts with `ERROR: No hash found for <file>` — loud, but potentially
  ~50 minutes into a release. The helper fetches the new tarball from the
  package's own upstream site, rewrites both files, and restores the `.mk` if
  the download fails so the tree is never left half-bumped. It will not fall
  back to a mirror for this: a mirror cannot establish what upstream published
  and will not carry a release upstream has only just made, so it refuses
  instead, with `--from <url>` to override for a copy you trust.
  `tests/checks/package-mirrors.sh` catches a mismatch in seconds either way;
  run it after any version change.
- **Replace stale hash lines, don't accumulate them.** Both Buildroot and
  `seedPackage()` select on the filename column, so a leftover line for an
  older release is inert rather than harmful — but a *new* line for the wrong
  filename means no hash matches, which is the abort above.
- **Keep the `sha512` line.** It is not redundant with the `sha256`: for every
  package whose mirror list includes `@FEDORA@`, `build.sh` builds the Fedora
  lookaside URL out of it, because that cache is addressed by sha512. Deleting
  it as a duplicate silently removes a mirror. `partimage` is the exception —
  it has no Fedora copy, so its sha512 is verification only.
- **Only add a mirror you have verified byte-identical to upstream.** The
  current table is deliberately not uniform: Debian is absent for `chntpw` and
  `partclone` because it repacks both (`.zip` → `.tar.gz`, and `.tar.xz`), and
  Fedora is absent for `partimage` because it has no copy. A mirror serving
  different bytes is not a mirror, and the hash check will reject it anyway.
- **`partclone`'s tarball is generated by GitHub, not uploaded by upstream.**
  It is whatever `git archive` produces for the tag, so its hash cannot be
  taken from a repack or regenerated locally — get the bytes from the
  `github.com/Thomas-Tsai/partclone/archive/<version>/` URL itself (or Fedora's
  lookaside, whose spec fetches exactly that URL).
- **Rewrite the `.hash` prose yourself after a bump.** The helper replaces hash
  lines mechanically but leaves comments alone, and some of them describe how
  *those specific bytes* were verified — `partclone.hash` names the tag and
  commit its archive was checked against. It warns when the old version is
  still mentioned; take the warning seriously rather than leaving a comment
  that describes verification which never happened for the new bytes.
- **Keep `_SITE` on https.** Plain HTTP is what egress filtering drops, and it
  is what timed out on GitHub's runners.

## Tests

There is no test suite for the kernel/Buildroot build itself — the only
tests are dev-only shell harnesses in `tests/`, covering the two shared
libraries, the kernel configs, and `build.sh`'s package-download fallback.
They live outside `rootfs_overlay`, so they never enter the built init. See
`tests/README.md` for full details.

```sh
tests/golden/run.sh capture   # (re)write the golden fixture — run BEFORE a refactor
tests/golden/run.sh check     # regenerate output and diff against the committed fixture
tests/golden/run.sh print     # dump current output to stdout, no comparison

tests/checks/sector-size.sh   # validateImageSectorSize() refusal/reformat behavior
tests/checks/fill-engine.sh   # sfdisk fill engine: 4Kn rescaling, GPT clamp, abort-on-unusable-table
tests/checks/resize-engine.sh # capture-time shrink: 4Kn units, last-lba passthrough, round-up (ADR-0016)
tests/checks/mbr-extended.sh  # MBR extended/logical layouts: emission order, EBR gaps, container sizing
tests/checks/wipe.sh          # wipeDisk() erase-primitive-per-device-class correctness
tests/checks/lvm.sh           # per-LV LVM capture/deploy/resize paths
tests/checks/secureboot.sh    # firmware-state detection, non-interactive MOK staging, Setup Mode db writes

tests/checks/secureboot-config.sh   # kernel configs carry the Secure Boot hardening symbols (ADR-0010)
tests/checks/pcie-aspm-config.sh    # kernel configs can control PCIe ASPM (ADR-0013)
tests/checks/initrd-format.sh       # each arch's kernel can unpack the init build.sh ships
tests/checks/arm64-platform-config.sh  # arm64 kernel describes a real ARM platform (ADR-0015)

tests/checks/nfs-mount-type.sh       # FOS's NFS mounts name -t nfs instead of relying on busybox inference

tests/checks/package-mirrors.sh     # build.sh's package mirror fallback and hash enforcement
```

The four config harnesses (`*-config.sh` and `initrd-format.sh`) assert on
`configs/kernel*.config` rather than on shell code; pass `-b` to also inspect
the post-`oldconfig` `.config` in any `kernelsource<arch>/` present, which is
the check that actually proves the symbol survived Kconfig.

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
- **0009 — Secure Boot enrollment.** shim's `MokList` is a boot-services-only
  variable, so the running OS *cannot* enroll a MOK — only MokManager can, behind
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
  initializes, and `CONFIG_LOAD_UEFI_KEYS` is what imports the firmware's `db`
  and `MokList` into the platform keyring. The trap this ADR exists for:
  `make oldconfig` **silently drops** any symbol whose dependencies are unmet,
  so a config can look right in git and produce a kernel missing lockdown
  entirely — which is why `tests/checks/secureboot-config.sh -b` inspects the
  post-`oldconfig` `.config` rather than the one we wrote.
- **0011 — UKI feasibility.** Settles the question ADR 0010 left open:
  adopting a Unified Kernel Image is feasible and does not require FOS to run
  systemd (the addon mechanism is boot-stage-only), and does not touch the
  custom kernel itself (Realtek drivers, Intel VMD, module-free build). It is
  gated on redesigning FOS's boot-time config channel, which splits into three
  subclasses, only the first of which this ADR actually solves: server-known
  task data (`mode=`, `type=`, image id) can move into an extended version of
  the runtime checkin `bin/fog.checkin` already performs; the `web=` server
  address **cannot** — `S40network` needs it before any network round-trip is
  reachable, so it needs a signed addon or DHCP-derived discovery instead, not
  a coin-flip choice; and boot-menu flags a human picks at iPXE (`isdebug`,
  `keymap`, `mdraid`, `chkdsk`, `mc`, `setmacto`) aren't server-known data at
  all and need their own design pass. See the ADR for the full analysis.
- **0012 — Microsoft-signed FOG shim (proposed, unstarted).** The only way to
  remove Secure Boot enrollment entirely rather than automate it further —
  gated on ADR-0011's redesign actually shipping, and on the still-inactive
  ADR-0010 lockdown patch. `ipxe/shim` cannot be repurposed for this (it
  trusts exactly one thing, derives its second stage from its own filename,
  and has no downstream hook by design); it requires FOG's own shim fork with
  FOG's certificate as the vendor cert, an EV cert from the Microsoft Hardware
  Dev Center, HSM/smartcard key custody, and a `rhboot/shim-review`
  submission — which carries **permanent** CVE/hash-revocation duty
  afterward, not a one-time cost. Tracked upstream as
  FOGProject/fogproject#995.
- **0013 — PCIe ASPM.** `CONFIG_PCIEASPM` and (on x86) `CONFIG_PCI_MMCONFIG`
  must stay enabled, and the ASPM policy must stay `DEFAULT` or `PERFORMANCE` —
  never a power-saving one. Both symbols are `default y` upstream and were off
  in FOS from 2016 until this ADR; the out-of-tree Realtek vendor drivers hid
  that by managing ASPM themselves, so switching to in-kernel `r8169` turned it
  into a 5x deploy-throughput loss on RTL8168h under UEFI (1.2 → 6.5 GB/min,
  measured). The trap: with `CONFIG_PCIEASPM=n`, `pci_disable_link_state()` is
  a stub that **returns success**, so `r8169` believes the OS disabled L1, sets
  `aspm_manageable`, and then enables ASPM and L1.2 in the chip — silently.
  Without `CONFIG_PCI_MMCONFIG` the L1-substates extended capability is not even
  reachable (that is what the `falling back to CSI` notice reports), and
  `pcie_aspm=off` on the command line does nothing because the `__setup()` that
  registers it is compiled out. Guarded by `tests/checks/pcie-aspm-config.sh`.
- **0014 — MBR extended partitions.** Two invariants for a DOS table carrying an
  extended partition. First, **`procsfdisk.awk` must emit partitions in ascending
  partition number**: sfdisk applies a script top to bottom and takes the number
  from the device name, so a logical reaching it before its container aborts the
  whole write. `for (name in array)` is unordered in awk and only *looked* right
  because gawk's hash order matches insertion order for `/dev/sdaN` while N <= 9
  — ten partitions is where it broke. Every `partition_names` traversal is now
  ordered explicitly; the `ordered_starts` walk is pinned to `@ind_num_asc`
  because it accumulates `curr_start` and needs asort's index order instead.
  Second, **an extended partition is a container, never content**: Linux exposes
  it as the ~1 KB EBR window, so imaging it and writing it back destroys the EBR
  chain and every logical after the first disappears mid-deploy. Capture tests
  for it *before* the `$fstype` dispatch (it has no filesystem, so
  `fsTypeSetting` calls it `imager` and the old check below that was
  unreachable); deploy keys its skip off the partition **type**, not off a
  missing `.img`, because every image captured before this fix still carries one.
  The container's size is derived from where its logicals land, never scaled.
  Guarded by `tests/checks/mbr-extended.sh`.
- **0015 — arm64 platform support.** `configs/kernelarm64.config` was added in
  2018 by someone who said they could not test it, and eight years of `make
  oldconfig` carried it forward without ever adding an ARM platform: no
  `CONFIG_ARCH_BCM`, no ACPI, no `PCI_HOST_GENERIC`, no PL011 UART. It could
  not boot a Raspberry Pi and had no console on an arm64 server either. Now
  carries Broadcom/Pi support (Pi 3 through Pi 5, `ARCH_BCM2835` being the
  umbrella for BCM2837/2711/2712) plus the generic arm64 symbols, merged as a
  fragment onto the existing config rather than rebased on mainline's
  `defconfig` — because FOS builds `CONFIG_MODULES=n` and `olddefconfig` drops
  `=m` symbols instead of promoting them. `build.sh` also builds `dtbs` and
  publishes `arm_dtbs.tar.gz`. Two symbols were dropped silently by Kconfig on
  the first pass (`SERIAL_8250_BCM2835AUX` wants `SERIAL_8250_SHARE_IRQ`,
  `DMA_BCM2835` wants `DMADEVICES`), which is the ADR-0010 trap again. **The
  server half does not exist** — FOG emits iPXE, not U-Boot `boot.scr`, so a Pi
  still cannot be imaged end to end. Guarded by
  `tests/checks/arm64-platform-config.sh`.
- **0016 — sector units in the resize path.** `processSfdisk()` converted
  `blockdev --getsz`'s 512-byte units into the disk's logical-sector unit for
  `action=filldisk` only, so the capture-time shrink read a 4Kn disk as eight
  times its real size; and `resize_partition()` divided its **byte** argument by
  `SECTOR_SIZE`, which is an *alignment quantum*, not a sector size — the two
  coincide only on 512-byte disks, which is why this survived for years. The raw
  logical sector size now travels as its own `LOGICAL_SECTOR_SIZE`: **do not
  merge it back into `SECTOR_SIZE`.** The conversion rounds **up**, because the
  filesystem has already been shrunk to that byte count. Third invariant: a
  capture-time shrink **never recomputes `last-lba`** — it describes where the
  disk ends, `sfdisk -d` read it from that same disk, and shrinking a partition
  does not move it; `fill_disk()`'s identical-looking assignment is a different
  case and stays. The trap this ADR exists for: none of this was a regression.
  The same broken table was computed on every 4Kn capture for years, and
  ADR-0003's fail-loud apply is the only reason anyone found out — so reverting
  to an older init re-hides it rather than fixing it. Guarded by
  `tests/checks/resize-engine.sh`.
- **0017 — arm64 display / vc4.** FOS builds no DRM anywhere and attaches
  `fbcon` to a framebuffer the *firmware* set up — `FB_EFI`/`FB_VESA` off EFI
  GOP on a PC, which is guaranteed there. On a Pi it is not: mainline's
  `bcm2711-rpi-4-b.dtb` that `arm_dtbs.tar.gz` ships has the
  `brcm,bcm2711-hdmi0/1` nodes only vc4 binds to and **no**
  `simple-framebuffer`, and the node the VideoCore firmware would inject into
  *its own* DTB is suppressed as soon as `config.txt` enables `vc4-kms-v3d` —
  which current Raspberry Pi OS ships enabled. A Pi therefore had no console at
  all, and a healthy boot was indistinguishable from an early hang, which is
  what made forums topic 18229 unreadable. `CONFIG_DRM_VC4` now builds in, at a
  measured `Image` cost of +1,067,008 bytes (+3.8%); `DRM_V3D` stays off, being
  the 3D accelerator. The trap this ADR exists for is ADR-0010's again and it
  fired twice: `DRM_VC4` `depends on SND && SND_SOC` (HDMI audio is integral)
  and on `PM`, all three excluded by FOS, and missing any one makes
  `oldconfig` drop the driver **silently** — so assert it is *linked*
  (`nm vmlinux | grep vc4_`), never merely configured. Validated on real
  hardware 2026-08-27: first end-to-end FOS capture on a Raspberry Pi, which
  also first-exercised ADR-0015 and the `mount -t nfs` fix off QEMU. Guarded by
  `tests/checks/arm64-platform-config.sh`.

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
