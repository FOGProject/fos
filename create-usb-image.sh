#!/bin/bash

set -e

targetrelease=$1

if [ -z "$targetrelease" ]; then
    echo "Usage: $0 <release>"
    echo "Example: $0 20231208"
    exit 1
fi

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
wget -P /mnt/boot/ https://github.com/geek-at/fos/releases/download/$targetrelease/bzImage
wget -P /mnt/boot/ https://github.com/geek-at/fos/releases/download/$targetrelease/init.xz
wget -P /mnt/boot/ https://github.com/FOGProject/fogproject/blob/dev-branch/packages/web/service/ipxe/memdisk
wget -P /mnt/boot/ https://github.com/FOGProject/fogproject/blob/dev-branch/packages/web/service/ipxe/memtest.bin
wget -P /mnt/boot/ https://github.com/FOGProject/fogproject/blob/dev-branch/packages/tftp/ipxe.krn
wget -P /mnt/boot/ https://github.com/FOGProject/fogproject/blob/dev-branch/packages/tftp/ipxe.efi

cat > /mnt/boot/README.txt << 'EOF'

!! IMPORTANT !! Change the myfogip variable in the boot/grub/grub.cfg file to the IP address of your FOG server first!

This is the FOG USB image. It is designed to register machines,  as well as deploy and capture images from a FOG server on machines that have trouble with PXE.

To use this image, you will need to create a bootable USB stick. You can use the following command to write this image to a USB stick:

dd if=fos-usb.img of=/dev/sdX bs=1M

Where /dev/sdX is the device name of your USB stick. Be very careful with this command, as it can destroy data on your hard drive if you specify the wrong device.

Once you have written the image to the USB stick, you can boot the target system from the USB stick. The system will boot into a FOG menu that will allow you to capture an image, deploy an image, register a host, or run a memory test.

EOF

echo Create the grub configuration file
cat > /mnt/boot/grub/grub.cfg << 'EOF'

set myfogip=http://change-this-to-your-fog-ip
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