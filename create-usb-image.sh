#!/bin/bash

set -e

dl_url=$1

if [ -z "$dl_url" ]; then
    echo "Usage: $0 <base URL for downloading bzImage and init.xz>"
    echo "Example: $0 https://github.com/fogproject/fos/releases/download/20231208"
    exit 1
fi

# Which FOG server branch the memdisk/memtest binaries and the iPXE version pin
# are read from. Overridable so a stick can be built to match a 1.6 server.
fog_branch="${FOG_BRANCH:-dev-branch}"
fp_raw="https://github.com/FOGProject/fogproject/raw/refs/heads/${fog_branch}/packages"
ipxe_url="https://github.com/FOGProject/fog-ipxe/releases/download"
# Only used if the version pin cannot be read; keep in step with fogproject's
# FOG_IPXE_VERSION when bumping it there.
ipxe_fallback="v2.0.0-fog.2"

if [ -f /tmp/fogkern.img ]; then
    echo Nuking old FOG Debug image
    rm -f /tmp/fos-usb.img
fi

echo Make a blank 128MB disk image
dd if=/dev/zero of=/tmp/fos-usb.img bs=1M count=128

echo Make the partition table, partition and set it bootable.
parted --script /tmp/fos-usb.img mklabel msdos mkpart p fat32 1 128 set 1 boot on

echo Map the partitions from the image file
kpartx -a -s /tmp/fos-usb.img
LOOPDEV=$(losetup -a | grep "/tmp/fos-usb.img" | grep -o "loop[0-9]*")

echo Make an vfat filesystem on the first partition.
mkfs -t vfat -n GRUB /dev/mapper/${LOOPDEV}p1

echo Mount the filesystem via loopback
mount /dev/mapper/${LOOPDEV}p1 /mnt

echo Install GRUB
grub-install --removable --no-nvram --no-uefi-secure-boot --efi-directory=/mnt --boot-directory=/mnt/boot --target=x86_64-efi

echo Download the FOG kernels and inits
wget -P /mnt/boot/ ${dl_url}/bzImage
wget -P /mnt/boot/ ${dl_url}/init.xz
wget -P /mnt/boot/ ${fp_raw}/web/service/ipxe/memdisk
wget -P /mnt/boot/ ${fp_raw}/web/service/ipxe/memtest.bin

echo Download the iPXE binaries for the Jumpstart menu entries
# ipxe.krn and ipxe.efi used to be committed to fogproject at packages/tftp/.
# iPXE now lives in its own repository and ships as a release tarball, so
# packages/tftp is a gitignored staging directory the FOG installer fills at
# runtime -- fetching those two paths from git returns 404, and because this
# script runs under `set -e` that aborted the whole build. Take them from the
# same release asset the installer uses, pinned to the same version the FOG
# server pins, so a stick built here chains the iPXE build its server expects.
# See fogproject GH-959.
ipxe_ver=$(wget -qO- ${fp_raw}/web/lib/fog/system.class.php \
    | awk -F"'" '/FOG_IPXE_VERSION/{print $4}' | tr -d '[:space:]')
if [ -z "$ipxe_ver" ]; then
    echo "Could not read FOG_IPXE_VERSION from ${fog_branch}, using ${ipxe_fallback}" >&2
    ipxe_ver="$ipxe_fallback"
fi
echo "Using iPXE ${ipxe_ver}"

ipxe_tar="fog-ipxe-${ipxe_ver}.tar.gz"
ipxe_tmp=$(mktemp -d)
# Checksum the tarball rather than trusting the transfer. A truncated download
# would otherwise produce a stick that looks built and fails to boot.
wget -P "$ipxe_tmp" "${ipxe_url}/${ipxe_ver}/${ipxe_tar}"
wget -P "$ipxe_tmp" "${ipxe_url}/${ipxe_ver}/${ipxe_tar}.sha256"
(cd "$ipxe_tmp" && sha256sum -c "${ipxe_tar}.sha256")
# The tarball is the whole TFTP staging tree; the USB menu only needs the two
# top-level binaries that grub entries 7 and 8 boot.
tar -xzf "${ipxe_tmp}/${ipxe_tar}" -C /mnt/boot/ ./ipxe.krn ./ipxe.efi
rm -rf "$ipxe_tmp"

cat > /mnt/boot/README.txt << 'EOF'

!! IMPORTANT !! Change the myfogip variable in the boot/grub/grub.cfg file to the IP address of your FOG server first!

This is the FOG USB image. It is designed to register machines,  as well as deploy and capture images from a FOG server on machines that have trouble with PXE.

To use this image, you will need to create a bootable USB stick. You can use the following command to write this image to a USB stick:

dd if=fos-usb.img of=/dev/sdX bs=1M

Where /dev/sdX is the device name of your USB stick. Be very careful with this command, as it can destroy data on your hard drive if you specify the wrong device.

Once you have written the image to the USB stick, you can boot the target system from the USB stick. The system will boot into a FOG menu that will allow you to capture an image, deploy an image, register a host, or run a memory test.

CHANGING THE FOG SERVER ADDRESS

boot/grub/grub.cfg on this drive is a plain text file, not baked into the bootloader binary. Plug the USB stick into any PC, mount its (only) FAT32 partition, and edit boot/grub/grub.cfg with any text editor:

  set myfogip=http://fog

Change "fog" to the IP address or hostname of your FOG server, save, and re-insert the stick. No need to recreate the image.

BOOT MENU OPTIONS

1. FOG Image Deploy/Capture    - normal imaging menu, same as PXE
2. Full Host Registration and Inventory
3. Quick Registration and Inventory
4. Client System Information (Compatibility)
5. Run Memtest86+
6. FOG Debug Kernel            - verbose logging, for troubleshooting
7. FOG iPXE Jumpstart BIOS
8. FOG iPXE Jumpstart EFI

EOF

echo Create the grub configuration file
cat > /mnt/boot/grub/grub.cfg << 'EOF'

set myfogip=http://fog
set myimage=/boot/bzImage
set myinits=/boot/init.xz
set myloglevel=4
set timeout=-1
insmod all_video

menuentry "1. FOG Image Deploy/Capture" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$myfogip/fog/ boottype=usb consoleblank=0 rootfstype=ext4
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "2. Perform Full Host Registration and Inventory" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$myfogip/fog/ boottype=usb consoleblank=0 rootfstype=ext4 mode=manreg
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "3. Quick Registration and Inventory" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$myfogip/fog/ boottype=usb consoleblank=0 rootfstype=ext4 mode=autoreg
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "4. Client System Information (Compatibility)" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$myfogip/fog/ boottype=usb consoleblank=0 rootfstype=ext4 mode=sysinfo
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "5. Run Memtest86+" {
 linux /boot/memdisk iso raw
 initrd /boot/memtest.bin
}

menuentry "6. FOG Debug Kernel" {
 echo loading the kernel
 linux  $myimage loglevel=7 init=/sbin/init root=/dev/ram0 rw ramdisk_size=275000 keymap= boottype=usb consoleblank=0 rootfstype=ext4 isdebug=yes
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "7. FOG iPXE Jumpstart BIOS" {
 echo loading the kernel
 linux16  /boot/ipxe.krn
 echo booting iPXE...
}

menuentry "8. FOG iPXE Jumpstart EFI" {
 echo chain loading the kernel
 insmod chain
 chainloader /boot/ipxe.efi
 echo booting iPXE-efi...
}

EOF

echo Unmount the loopback
umount /mnt

echo Unmap the image
kpartx -d /tmp/fos-usb.img