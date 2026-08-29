# The arm64 kernel drives the Pi's display itself, instead of trusting the firmware to

Reported as forums topic 18229.

A Raspberry Pi 4 booting FOS stopped on the firmware's four-raspberry splash and
produced no text at all — no kernel messages, no FOS, nothing to type into. It
looked exactly like an early hang, and was diagnosed as one twice. It was not.
The kernel was running fine and had no way to say so.

`configs/kernelarm64.config` now carries `CONFIG_DRM`, `CONFIG_DRM_VC4` and
`CONFIG_DRM_FBDEV_EMULATION`, so the kernel programs the Pi's HDMI block itself.

## Why the existing approach doesn't reach a Pi

FOS builds no DRM on any architecture. It has never needed to: `CONFIG_FB_EFI`
and `CONFIG_FB_VESA` attach `fbcon` to a linear framebuffer the *firmware*
already set up, and on a PC that is guaranteed — every UEFI implementation
publishes a GOP. The same three lines are in `kernelx64.config` today and are
the reason an x86 client has a console.

The Pi looks like it should work the same way, and this is the trap: the
VideoCore firmware does publish a `simple-framebuffer` node, `CONFIG_FB_SIMPLE`
is already enabled, and the pieces appear to line up. Two things break it.

- **Our own device tree cannot carry that node.** `arm_dtbs.tar.gz` ships
  mainline's `broadcom/bcm2711-rpi-4-b.dtb`, which has `brcm,bcm2711-hdmi0` and
  `brcm,bcm2711-hdmi1` — nodes only the vc4 driver binds to — and **zero**
  `simple-framebuffer` nodes. The firmware injects that node into *the DTB it
  hands the bootloader*; a DTB fetched over TFTP has never been through the
  firmware and never will.
- **Even the firmware's DTB stops carrying it once KMS is on.** The
  `vc4-kms-v3d` overlay tells the firmware not to set the display up, because a
  KMS driver is expected to. Current Raspberry Pi OS ships that overlay enabled,
  so the fallback is absent on exactly the machines most likely to be tested.

So on a Pi the firmware-framebuffer assumption fails in both directions, and the
failure is silent in the worst way: a healthy boot and a dead one render
identically, which is what made the original report unreadable and cost two
rounds of wrong diagnosis.

## What it costs, measured

`Image` grows from 28,353,024 to 29,420,032 bytes — **+1,067,008, +3.8%** —
measured on matched local builds, same box and same toolchain. The published CI
pair moved 30,253,568 → 31,386,112, agreeing to within 0.1 percentage points.

`CONFIG_DRM_V3D` is deliberately **not** enabled. It is the 3D accelerator; a
console does not use it.

## The dependency trap, which is the part worth remembering

`CONFIG_DRM_VC4=y` cannot be switched on by itself. From
`drivers/gpu/drm/vc4/Kconfig` it `depends on DRM`, on `SND && SND_SOC` — HDMI
audio is integral to the driver, not optional — and on `PM`. FOS deliberately
excludes all three.

Miss any one and `make oldconfig` **drops `CONFIG_DRM_VC4` with no error at
all**, leaving a config that reads correctly in git and a kernel with no display
driver. This is the ADR-0010 trap, and it fired twice while making this change:
once for `SND`/`SND_SOC`, then again for `PM`. Each time the only evidence was
the symbol quietly absent from the generated `.config`.

Two habits follow, and neither is optional here:

- Assert on the symbol being **linked**, not configured. `nm vmlinux | grep
  vc4_` returning 378 symbols is proof; `CONFIG_DRM_VC4=y` in a file is not.
- `tests/checks/arm64-platform-config.sh` lists `PM`, `SND` and `SND_SOC`
  alongside `DRM_VC4` for the same reason it already lists
  `SERIAL_8250_SHARE_IRQ` alongside `SERIAL_8250_BCM2835AUX`: the dependency is
  the thing that silently removes the driver, so the dependency is what gets
  guarded. Run it with `-b` — that mode inspects the config Kconfig *produced*,
  which is the only one that can prove the symbol survived.

## Validation

Confirmed on real hardware by the reporter, 2026-08-27, against
`EXP_20260827-114033`: HDMI initialized, FOS reached userspace, and Partclone
captured `/dev/sda` to the FOG server. That is the first end-to-end FOS imaging
run on a Raspberry Pi, and it also became the first real-hardware exercise of
ADR-0015's platform support and of the `mount -t nfs` fix, both of which had
only ever run under QEMU and in VirtualBox.

One reporting note recorded because it will recur: passing the raw
`arm_init.cpio.gz` to `booti` failed with `Wrong Ramdisk Image Format` until it
was given a size. U-Boot reads a bare address as a legacy uImage and demands a
header; `booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}`
passes it as a raw initrd. Wrapping with `mkimage -C none` works too and is what
the reporter used — `-C none` matters, since `-C gzip` would have U-Boot
decompress it and the kernel's own gzip support would go untested.
