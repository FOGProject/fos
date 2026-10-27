# An initramfs for every arch

The x64 and x86 inits were ext2 filesystem images (`rootfs.ext2.xz`). The
kernel boots such an image through the classic initrd path: it copies the
bytes to `/initrd.image`, identifies the format at offset 0, writes the image
into `/dev/ram0`, and mounts that as `root=/dev/ram0`. arm64 already shipped a
cpio initramfs (`arm_init.cpio.gz`).

We decided **every arch ships a cpio initramfs. x64 and x86 now build
`rootfs.cpio.xz`, published under the same names, `init.xz` and `init_32.xz`.**

## Why

Mainline is removing the classic initrd path:

- v7.0 removed its `linuxrc` half
  ([vfs initrd pull](https://lkml.iu.edu/hypermail/linux/kernel/2602.0/09468.html),
  [series](https://lkml.iu.edu/2511.2/11639.html)).
- 7.2 logs "using deprecated initrd support, will be removed in January 2027;
  use initramfs instead" on every boot (`init/do_mounts_initrd.c`). 6.18.59
  logs "will be removed soon".
- Initramfs is not affected.

A kernel after the removal cannot boot an ext2 init at all. The 6.18 LTS line
keeps the path, so stable FOS is not broken today. Any move to a 7.x kernel,
such as the fos#110 experiment, needs this first.

fos#75 is the second reason. Its panic, "RAMDISK: Couldn't find valid RAM disk
image starting at 0", comes from `init/do_mounts_rd.c`, the classic loader.
An initramfs is unpacked by different code (`init/initramfs.c`) and never
reaches that function. Whether this fixes fos#75 is **not yet known**: the
reporters' machines are the only test.

## Compatibility

- **Server:** nothing changes. With an initramfs that contains `/init`, the
  kernel runs it and ignores `root=/dev/ram0`, `ramdisk_size=` and
  `rootfstype=ext4`, which FOG's boot menus and `create-usb-image.sh` still
  send. Buildroot adds that `/init`; it execs `/sbin/init`.
- **Kernel:** the 6.18 kernels FOS ships unpack an xz initramfs
  (`CONFIG_RD_XZ=y`, `CONFIG_BLK_DEV_INITRD=y`). An older FOS kernel paired
  with a new init also works, for the same reason.
- **The root filesystem** is now the kernel's rootfs (ramfs while `root=` is
  on the command line, `init/do_mounts.c` `init_rootfs()`) instead of a
  256 MiB ext2 ram disk. Nothing large is written there: logs rotate, and
  the scripts write a few small files under `/etc` and `/usr/share/fog/lib`.
  `inittab`'s `remount,rw /` still succeeds.

## /tmp is capped, from the setting the server already sends

`/tmp` was never on the ram disk; fstab mounts it as tmpfs. But every kernel
config had `CONFIG_SHMEM` off, and without it the kernel registers "tmpfs" as
ramfs, which ignores `size=`. So `/tmp` had no limit before this ADR either:
a runaway write grew until the client ran out of memory. `df` printing 0 for
`/tmp` on a live boot is how this was found.

- All three kernel configs now build `CONFIG_SHMEM` and `CONFIG_TMPFS`.
- fstab gives `/tmp` `size=256m` as a default.
- `etc/init.d/S00tmpsize` resizes `/tmp` from `ramdisk_size=` on the kernel
  command line. The server fills that from **FOG_KERNEL_RAMDISK_SIZE** (KB,
  default 275000). That setting sized the ext2 ram disk; an initramfs has no
  ram disk, so the same setting now sizes `/tmp`, and every FOG server, old
  or new, already sends it. An admin who wants 512 MiB or 1 GiB sets it there.
- The size is clamped to at least 64 MiB and at most half of physical
  memory. A larger tmpfs would cap nothing. A missing or non-numeric value
  keeps 256 MiB.

Guarded by `tests/checks/tmp-size.sh`.

## Customizing the init

The long-standing forum method -- `xz -d`, loop-mount the ext2 image, edit,
unmount, `xz -C crc32` -- does not work on a cpio: there is no filesystem to
mount. Two methods replace it:

- **Append an overlay (preferred).** The kernel unpacks concatenated cpio
  archives in order, and a later file replaces an earlier one. Put only the
  changed files in a small cpio and append it:

  ```
  cd overlay && find . | cpio -o -H newc -R 0:0 | xz -9 --check=crc32 > ../overlay.cpio.xz
  cat init.xz overlay.cpio.xz > init-custom.xz
  ```

  No root, no repack of the whole init, and the same overlay re-applies to
  every new release unchanged. Verified in QEMU on 6.18.59: a script added
  this way ran at boot.
- **Unpack and repack**, for removing files: `xz -dc init.xz | cpio -idm` as
  root, edit, then `find . | cpio -o -H newc | xz -9 --check=crc32`.

`--check=crc32` is required either way, as it was before: the kernel's xz
decoder supports only CRC32 or no check, not xz's default CRC64
(`Documentation/staging/xz.rst`).

Postinit scripts on the storage node (`/images/postinitscripts`) need no
change; they never touched the init file.

## What would make us revisit this

A machine that boots the ext2 init but not the initramfs. The experimental
release exists to find one before this reaches Latest.

## Guard

`tests/checks/initrd-format.sh` fails when any arch ships a non-cpio artifact,
and still pairs each artifact's compression with the kernel's decompressor.
