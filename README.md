# FOG Operating System (FOS)
This is the operating system environment used for imaging with FOG. This is a linux based operating system with all the scripts and programs required for perform imaging tasks.

# What does this repository do?
Builds FOS inits as well as kernels used by FOG.

# What do we need?
1. You'll need a Debian or Red Hat based operating system.
2. You'll need to install git on your system.
3. You'll need to clone the fos repository.

# How do I get the fos repository?
Pull the fos repository with:

```
git clone https://github.com/fogproject/fos
```

# How to build?
To build the FOS inits and/or kernels we use the `build.sh` script.


#### Build script options:
The `build.sh` script has usage flags that are used to build the inits/kernels. You can run `build.sh -h` or `build.sh --help` to see all the flags.


#### NOTES:
1. This repository does not contain FOS or the kernels, it contains all the files needed to build the inits and kernels.
2. `/path/to/fos/repo` is not the real path, this is the path to the cloned repository on the machine you plan to run this on. Typically this would be something like `~/fos`. This path <ins>**will**</ins> need to be changed to build.

---

#### Build Everything
```
/path/to/fos/repo/build.sh -n
```
#### Build all inits only
```
/path/to/fos/repo/build.sh -nf
```
#### Build 64 bit (x64) init
```
/path/to/fos/repo/build.sh -nfa x64
```
#### Build 32 bit (x86) init
```
/path/to/fos/repo/build.sh -nfa x86
```
#### Build ARM 64 bit init
```
/path/to/fos/repo/build.sh -nfa arm64
```
#### Build all kernels only
```
/path/to/fos/repo/build.sh -nk
```
#### Build 64 bit (x64) kernel
```
/path/to/fos/repo/build.sh -nka x64
```
#### Build 32 bit (x86) kernel
```
/path/to/fos/repo/build.sh -nka x86
```
#### Build ARM 64 bit kernel
```
/path/to/fos/repo/build.sh -nka arm64
```

# USB Boot Image
Some machines can't PXE boot reliably. `create-usb-image.sh` builds a bootable USB image (`fos-usb.img`) that boots straight into the same FOG menu (deploy/capture, registration, memtest, debug kernel) without needing PXE at all.

Every release published on GitHub automatically gets a `fos-usb.img` attached via the `make_usb.yml` workflow — you normally don't need to build it yourself.

#### Writing the image to a USB stick
```
dd if=fos-usb.img of=/dev/sdX bs=1M
```
Replace `/dev/sdX` with your USB stick's device name. Double-check this — writing to the wrong device destroys its data.

#### Pointing it at your FOG server
The image defaults to `http://fog` as the FOG server address. Edit `boot/grub/grub.cfg` on the USB stick's FAT32 partition (any OS, any text editor) and change:
```
set myfogip=http://fog
```
to your FOG server's actual IP or hostname. This can be done any time after writing the image — no need to rebuild it.

#### Building it manually
```
./create-usb-image.sh <base URL for downloading bzImage and init.xz>
```
Requires `grub-efi-amd64`, `parted`, and `kpartx`. Produces `/tmp/fos-usb.img`.
