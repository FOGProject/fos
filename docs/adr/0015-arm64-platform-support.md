# 0015 — The arm64 kernel must describe an actual ARM platform

## Status

Implemented in `configs/kernelarm64.config` and `build.sh`. **Not validated on
hardware** — nobody on the project has a Pi in front of them yet.

What is proven: `./build.sh -nka arm64` completes, every symbol in the
fragment survives Kconfig's own `oldconfig` (checked with
`tests/checks/arm64-platform-config.sh -b` against the post-`oldconfig`
`.config`, which is the only check that means anything per ADR-0010), and the
build emits `arm_Image` plus device trees for Pi 2 through Pi 5.

Also proven, under `qemu-system-aarch64 -M virt` (QEMU 10.2, 2026-08-25),
booting the **released** `arm_init.cpio.gz` from FOG 1.6 — the same bytes that
shipped, not a rebuild:

- The released `arm_Image` produces **no console output at all** on that
  machine. There is no PL011 driver in it, so there is nothing to print to.
  That is the second bug in this ADR, demonstrated.
- The kernel from this branch unpacks the same gzip initramfs ("Trying to
  unpack rootfs image as initramfs… Freeing initrd memory: 52576K… Run /init
  as init process") and boots through to FOS userspace: syslogd, klogd, udevd,
  haveged, then `S40network`.
- With a virtio NIC attached it enumerates PCI, brings up eth0 and takes a DHCP
  lease. Worth noting that `CONFIG_PCI_HOST_GENERIC` was off before this
  change, so the released kernel has no PCI bus on that machine and therefore
  no NIC at all.

What is **not** proven: any of the Broadcom code paths. QEMU's `raspi4b` model
is too incomplete to serve — it disables `bcm2711-pcie`, `bcm2711-genet-v5`,
`bcm2711-rng200` and `bcm2711-thermal` out of the DTB and never reaches a
console. Real Pi hardware is the only way to validate that half, and nobody on
the project has one. Treat this ADR as unfinished until someone reports back.

Prompted by FOG forums topic 18229, where someone tried to capture a Pi 4 over
U-Boot, found FOS's arm64 kernel had no driver for the Pi's onboard NIC, and
substituted the stock Raspberry Pi `kernel8.img` to get any further.

## Context

`configs/kernelarm64.config` was added in March 2018 (`4fb7fb2`, "Add ARM
Support") by a contributor whose own commit message says:

> NOTE: I have only tested this on arm64. I don't have any arm32 machines to
> test this on, and so I make no promises

Every kernel bump since has carried it forward with `make oldconfig`, which
preserves what is there and adds nothing. Eight years later the config still
described no ARM platform at all:

```
# CONFIG_ARCH_BCM is not set          -> no Broadcom SoC, so no Raspberry Pi
# CONFIG_ACPI is not set              -> no SBSA/server discovery
# CONFIG_PCI_HOST_GENERIC is not set  -> no ECAM, so no PCI on QEMU virt
# CONFIG_SERIAL_AMBA_PL011 is not set -> no PL011, the standard ARM UART
```

That is not a Pi problem, it is an arm64 problem. With neither ACPI nor PL011
this kernel had no console and no device enumeration on essentially any real
arm64 machine; `CONFIG_CC_VERSION_TEXT` in the committed file even named the
*native* x86 gcc, which is what a config edited on the build host and never
regenerated under `CROSS_COMPILE` looks like. Virtio was on, so an arm64 VM
would at least find its disk and NIC — but with no console to watch it on.

A separate defect in the same area, fixed alongside: the kernel had
`# CONFIG_RD_GZIP is not set` while the init we publish is `arm_init.cpio.gz`.
Confirmed against the released binary with `extract-ikconfig`, so the shipped
arm64 kernel/init pair could not boot each other at all. That is now guarded by
`tests/checks/initrd-format.sh`.

## Decision

Enable Broadcom/Raspberry Pi support and the generic arm64 symbols, by merging
a fragment onto the existing config with Kconfig resolving dependencies —
**not** by hand-editing symbols, and **not** by rebasing on mainline's
`arch/arm64/configs/defconfig`.

```sh
cd kernelsourcearm64
scripts/kconfig/merge_config.sh -m ../configs/kernelarm64.config arm64-platform.frag
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

The fragment is reproduced at the end of this ADR. `ARCH_BCM2835` is the
umbrella for BCM2837/2711/2712, so one symbol covers Pi 3, Pi 4/400/CM4 and
Pi 5; the rest are drivers that Kconfig would otherwise leave at their
defaults, which for almost every Broadcom driver is `n` even with the platform
selected.

### Why not rebase on mainline's arm64 defconfig

It is the obvious move — `defconfig` is the multiplatform config, it already
has `ARCH_BCM2835=y`, and every distro builds from it. It was rejected because
FOS's kernel is not a distro kernel in the one way that matters here: it is
built with `CONFIG_MODULES=n`, because the init is the root filesystem and
carries no `/lib/modules`. `defconfig` marks most drivers `=m`, and
`olddefconfig` with `MODULES=n` **drops** an `=m` symbol rather than promoting
it, so a rebase means mechanically rewriting `=m` to `=y` and then auditing
several hundred symbols to find what silently failed to convert. That is a much
larger surface to get wrong than the ~40 symbols actually needed, against a
base config whose FOS-specific decisions (ADR-0010's lockdown symbols,
ADR-0013's ASPM policy, the filesystem and NIC selection) are all load-bearing
and would have had to be re-established one at a time.

Merging onto the existing config inverts the risk: everything FOS chose is kept
by construction, and the diff is auditable. It was — comparing the `=y` sets
before and after, exactly two symbols were lost, `CONFIG_BROKEN_GAS_INST` and
`CONFIG_CC_CAN_LINK`, both toolchain probe results that Kconfig recomputes on
every build.

The cost of this choice is that the config stays a FOS artifact rather than a
thin delta over upstream, so the next person adding a platform does this again
rather than picking up whatever `defconfig` gained meanwhile. That is the right
trade while `MODULES=n` holds; if FOS ever ships modules, revisit it.

### Two symbols Kconfig dropped without a word

Worth recording because they are the whole argument for the harness:

- `CONFIG_SERIAL_8250_BCM2835AUX` — the Pi's mini-UART, and the console
  `console=serial0` lands on by default — depends on
  `CONFIG_SERIAL_8250_SHARE_IRQ`, which lives under `SERIAL_8250_EXTENDED`.
  Both were off. The symbol disappeared from the merged config with no message.
- `CONFIG_DMA_BCM2835` needs `CONFIG_DMADEVICES`, which was off. Same silence.
  Without it `MMC_BCM2835` cannot drive the SD card.

Same trap as ADR-0010: `make oldconfig` never tells you it dropped something.

### Device trees

`build.sh` now builds the `dtbs` target alongside `Image` for arm64 and
publishes `dist/arm_dtbs.tar.gz`, paths relative to `arch/arm64/boot/dts` so a
Pi 4's tree unpacks as `broadcom/bcm2711-rpi-4-b.dtb`.

A board with no EFI/ACPI has no other way to tell the kernel what it is. On a
Pi the VideoCore firmware supplies a correct DTB and U-Boot can pass that
through, which is the better path when it is available — but it is only
available on that one boot flow, so the trees are shipped for the flows where
it is not.

`make dtbs` builds only the platforms the config enables, so the tarball
tracks the kernel rather than the source tree. As built today that is twelve
Broadcom trees (Pi 2, 3, 3A+, 3B+, Zero 2 W, CM3, 4B, 400, CM4, 5B, 5B-D and
the Pi 5 RP1 overlay) at 51 KB, and it grows on its own if another `ARCH_*`
is ever enabled.

The FOG server does not consume this artifact yet; see below.

## Consequences

- The arm64 `Image` did **not** grow, which is worth stating plainly so nobody
  reads it as a claim that 128 extra symbols are free. Built here it is
  28,353,024 bytes against the 29,070,176 of the released 6.18.38 `arm_Image`
  in FOG 1.6 — but that one was built by the CI runner with a different
  compiler, so the ~700 KB is a toolchain difference of unknown sign wrapped
  around a config difference, not a measurement of this change. The honest
  statement is that the size is unchanged to within the noise of who compiled
  it. It is a netboot artifact fetched once per client either way.
- `CONFIG_ACPI=y` brings the ACPI subsystem in on a kernel that previously had
  none. On a device-tree platform such as the Pi it is inert — arm64 picks DT
  or ACPI from what the firmware presents.
- Pi 5 support pulls in `MISC_RP1` and with it `OF_OVERLAY` and
  `PCI_DYNAMIC_OF_NODES`, because RP1 publishes its children through a
  devicetree overlay applied at runtime once its PCIe endpoint is up. Runtime
  overlay application is new to this kernel.
- Guarded by `tests/checks/arm64-platform-config.sh`. Run it with `-b` after a
  build to check the config Kconfig actually produced, which is the only check
  that proves anything.

### What this does not fix

**FOG still cannot image a Raspberry Pi.** This ADR is the FOS half only. The
server half does not exist:

- `bootmenu.class.php` emits iPXE `kernel …` lines. A Pi boots U-Boot, which
  needs a generated `boot.scr`, a DTB served over TFTP, and a `uInitrd` wrapper
  around the init. None of that is generated anywhere.
- The kernel-argument builder assumes an iPXE client throughout, and the
  capture flow assumes a registered host with a queued task. Hand-writing
  arguments, as the forum report did, gets as far as `fog.checkin` looping
  forever waiting for `##@GO`.
- The kernel/init upload whitelist (`route.class.php`, and the 1.5 equivalent)
  accepts exactly `arm_Image` and `arm_init.cpio.gz`. `arm_dtbs.tar.gz` has
  nowhere to be uploaded to.

So the honest position after this change is: the kernel can now run on a Pi,
and FOG cannot yet ask it to.

## The fragment

```
# --- SoC platform ---
CONFIG_ARCH_BCM=y
CONFIG_ARCH_BCM2835=y
CONFIG_ACPI=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_PCIE_BRCMSTB=y

# --- console ---
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_8250_EXTENDED=y
CONFIG_SERIAL_8250_SHARE_IRQ=y
CONFIG_SERIAL_8250_BCM2835AUX=y
CONFIG_SERIAL_8250_DW=y
CONFIG_SERIAL_OF_PLATFORM=y

# --- Pi core plumbing ---
CONFIG_MAILBOX=y
CONFIG_BCM2835_MBOX=y
CONFIG_RASPBERRYPI_FIRMWARE=y
CONFIG_CLK_RASPBERRYPI=y
CONFIG_RASPBERRYPI_POWER=y
CONFIG_PINCTRL_BCM2835=y
CONFIG_DMADEVICES=y
CONFIG_DMA_BCM2835=y
CONFIG_MFD_SYSCON=y
CONFIG_GPIO_RASPBERRYPI_EXP=y
CONFIG_WATCHDOG=y
CONFIG_BCM2835_WDT=y
CONFIG_HW_RANDOM_BCM2835=y
CONFIG_BCM2711_THERMAL=y

# --- storage ---
CONFIG_MMC_SDHCI_IPROC=y
CONFIG_MMC_BCM2835=y

# --- network ---
CONFIG_NET_VENDOR_BROADCOM=y
CONFIG_BCMGENET=y
CONFIG_USB_USBNET=y
CONFIG_USB_LAN78XX=y
CONFIG_USB_NET_SMSC95XX=y
CONFIG_NET_VENDOR_CADENCE=y
CONFIG_MACB=y

# --- USB ---
CONFIG_USB_DWC2=y
CONFIG_USB_DWC2_HOST=y

# --- Pi 5 (BCM2712 / RP1) ---
CONFIG_OF_OVERLAY=y
CONFIG_PCI_DYNAMIC_OF_NODES=y
CONFIG_MISC_RP1=y
CONFIG_COMMON_CLK_RP1=y
CONFIG_PINCTRL_RP1=y
```
