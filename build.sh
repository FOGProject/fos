#!/bin/bash

source ./dependencies.sh

[[ -z $KERNEL_VERSION ]] && KERNEL_VERSION='6.12.25'
[[ -z $BUILDROOT_VERSION ]] && BUILDROOT_VERSION='2025.02'

declare -ar ARCHITECTURES=("x64" "x86" "arm64")
PIPE_JOINED_ARCHITECTURES=$(IFS="|"; echo "${ARCHITECTURES[@]}"; unset IFS)

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [$PIPE_JOINED_ARCHITECTURES] (optional) pick the architecture to build. Default is to build for all."
    echo -e "\t\t-f --filesystem-only (optional) Build the FOG filesystem but not the kernel."
    echo -e "\t\t-k --kernel-only (optional) Build the FOG kernel but not the filesystem."
    echo -e "\t\t-p --path (optional) Specify a path to download and build the sources."
    echo -e "\t\t-n --noconfirm (optional) Build systems without confirmation."
    echo -e "\t\t-i --install-dep (optional) Attempt to install dependencies."
    echo -e "\t\t-h --help -? Display this message."
    exit 0
}
[[ -n "$arch" ]] && unset "$arch"

shortopts="?hkfnia:p:"
longopts="help,kernel-only,filesystem-only,noconfirm,install-dep,arch:,path:"

optargs=$(getopt -o "$shortopts" -l "$longopts" -n "$0" -- "$@")
[[ $? -ne 0 ]] && Usage

eval set -- "$optargs"

while :; do
    case $1 in
        -\? | -h | --help)
            Usage
            ;;
        -k | --kernel-only)
            buildKernelOnly="y"
            shift
            ;;
        -f | --filesystem-only)
            buildFSOnly="y"
            shift
            ;;
        -n | --noconfirm)
            confirm="n"
            shift
            ;;
        -i | --install-dep)
            installDep="y"
            shift
            ;;
        -a | --arch)
            arch=$2
            if ! echo "${ARCHITECTURES[@]}" | grep -w "$arch" >/dev/null; then
                echo "Error: Invalid architecture specified. Valid options are: $PIPE_JOINED_ARCHITECTURES"
                Usage
            fi
            shift 2
            ;;
        -p | --path)
            buildPath=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Invalid option."
            Usage
            ;;
    esac
done


[[ -z $arch ]] && arch="${ARCHITECTURES[*]}"
[[ -z $buildPath ]] && buildPath="$(dirname "$(readlink -f "$0")")"
[[ -z $confirm ]] && confirm="y"
[[ -z $installDep ]] && installDep="n"

checkDependencies
installDependencies "$installDep"

cd "$buildPath" || exit 1


function buildFilesystem() {
    local arch="$1"
    brURL="https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.xz"
    echo "Preparing buildroot $BUILDROOT_VERSION on $arch build:"
    if [[ ! -d fssource$arch ]]; then
        if [[ ! -f buildroot-$BUILDROOT_VERSION.tar.xz ]]; then
            dots "Downloading buildroot source package"
            wget -q "$brURL" && echo "Done"
            if [[ $? -ne 0 ]]; then
                echo "Failed"
                exit 1
            fi
        fi
        dots "Extracting buildroot sources"
        tar xJf "buildroot-$BUILDROOT_VERSION.tar.xz"
        mv "buildroot-$BUILDROOT_VERSION" "fssource$arch"
        echo "Done"
    fi
    cd "fssource$arch" || { echo "Couldn't change directory to fssource$arch"; exit 1; }
    if [[ -f ../patch/filesystem/fs.patch ]]; then
        dots " * Applying filesystem patch"
        echo
        patch -p1 < ../patch/filesystem/fs.patch
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
        fi
        echo "Done"
    else
        echo " * WARNING: Did not find any patch file(s), building filesystem without patches!"
    fi
    dots "Preparing code"
    if [[ ! -f .packConfDone ]]; then
        cat ../Buildroot/package/newConf.in >> package/Config.in
        touch .packConfDone
    fi
    rsync -avPrI ../Buildroot/ . > /dev/null
    sed -i "s/^export initversion=[0-9][0-9]*$/export initversion=$(date +%Y%m%d)/" board/FOG/FOS/rootfs_overlay/usr/share/fog/lib/funcs.sh
    if [[ ! -f .config ]]; then
        cp "../configs/fs$arch.config" .config
        case "${arch}" in
            x64)
                make oldconfig
                ;;
            x86)
                make ARCH=i486 oldconfig
                ;;
            arm64)
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                ;;
            *)
                make oldconfig
                ;;
        esac
    fi
    echo "Done"
    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            case "${arch}" in
                x64)
                    make menuconfig
                    ;;
                x86)
                    make ARCH=i486 menuconfig
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
                    ;;
                *)
                    make menuconfig
                    ;;
            esac
        else
            echo "Ok, running make oldconfig instead to ensure the config is clean."
            case "${arch}" in
                x64)
                    make oldconfig
                    ;;
                x86)
                    make ARCH=i486 oldconfig
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                    ;;
                *)
                    make oldconfig
                    ;;
            esac
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == n ]]; then
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    fi
    bash -c "while true; do echo \$(date) - building ...; sleep 30s; done" &
    PING_LOOP_PID=$!
    case "${arch}" in
        x64)
            make > "buildroot$arch.log" 2>&1
            status=$?
            ;;
        x86)
            make ARCH=i486 > "buildroot$arch.log" 2>&1
            status=$?
            ;;
        arm64)
            make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- > "buildroot$arch.log" 2>&1
            status=$?
            ;;
        *)
            make > "buildroot$arch.log" 2>&1
            status=$?
            ;;
    esac
    kill $PING_LOOP_PID
    [[ $status -gt 0 ]] && tail "buildroot$arch.log" && exit $status
    cd ..
    [[ ! -d dist ]] && mkdir dist
    cd dist || { echo "Couldn't change directory to dist"; exit 1; }
    case "${arch}" in
        x64)
            compiledfile="../fssource$arch/output/images/rootfs.ext2.xz"
            initfile='init.xz'
            ;;
        x86)
            compiledfile="../fssource$arch/output/images/rootfs.ext2.xz"
            initfile='init_32.xz'
            ;;
        arm64)
            compiledfile="../fssource$arch/output/images/rootfs.cpio.gz"
            initfile='arm_init.cpio.gz'
            ;;
    esac
    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp "$compiledfile" "$initfile" && sha256sum "$initfile" > "${initfile}.sha256"
    cd ..
}

function buildKernel() {
    local arch="$1"
    kernelURL="https://www.kernel.org/pub/linux/kernel/v${KERNEL_VERSION:0:1}.x/linux-$KERNEL_VERSION.tar.xz"
    echo "Preparing kernel $KERNEL_VERSION on $arch build:"
    [[ -d kernelsource$arch ]] && rm -rf "kernelsource$arch"
    if [[ ! -f linux-$KERNEL_VERSION.tar.xz ]]; then
        dots "Downloading kernel source"
        wget -q "$kernelURL" && echo "Done"
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
        fi
    fi
    dots "Extracting kernel source"
    tar xJf "linux-$KERNEL_VERSION.tar.xz"
    mv "linux-$KERNEL_VERSION" "kernelsource$arch"
    echo "Done"

    dots "Adding kernel packages"
    addKernelPackages
    echo "Done"

    if [[ ! -d linux-firmware ]]; then
        dots "Cloning Linux firmware repository"
        git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git >/dev/null 2>&1
        echo "Done"
    else
        dots "Updating Linux firmware repository"
        cd linux-firmware || { echo "Couldn't change directory to linux-firmware"; exit 1; }
        git pull --rebase >/dev/null 2>&1
        cd ..
        echo "Done"
    fi
    dots "Copying firmware files"
    cp -r linux-firmware "kernelsource$arch/"
    echo "Done"

    dots "Preparing kernel source"
    cd "kernelsource$arch" || { echo "Couldn't change directory to kernelsource$arch"; exit 2; }
    make mrproper
    cp "../configs/kernel$arch.config" .config
    echo "Done"
    if [[ -f ../patch/kernel/linux.patch ]]; then
        dots " * Applying patch"
        echo
        patch -p1 < ../patch/kernel/linux.patch
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
        fi
    else
        echo " * WARNING: Did not find a patch file building vanilla kernel without patches!"
    fi
    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            case "${arch}" in
                x64)
                    make menuconfig
                    ;;
                x86)
                    make ARCH=i386 menuconfig
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
                    ;;
                *)
                    make menuconfig
                    ;;
            esac
        else
            echo "Ok, running make oldconfig instead to ensure the config is clean."
            case "${arch}" in
                x64)
                    make oldconfig
                    ;;
                x86)
                    make ARCH=i386 oldconfig
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                    ;;
                *)
                    make oldconfig
                    ;;
            esac
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            case "${arch}" in
                x64)
                    make -j "$(nproc)" bzImage
                    status=$?
                    ;;
                x86)
                    make ARCH=i386 -j "$(nproc)" bzImage
                    status=$?
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)" Image
                    status=$?
                    ;;
                *)
                    make -j "$(nproc)" bzImage
                    status=$?
                    ;;
            esac
        else
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
        [[ $status -gt 0 ]] && exit $status
    else
        case "${arch}" in
            x64)
                make oldconfig
                make -j "$(nproc)" bzImage
                status=$?
                ;;
            x86)
                make ARCH=i386 oldconfig
                make ARCH=i386 -j "$(nproc)" bzImage
                status=$?
                ;;
            arm64)
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)" Image
                status=$?
                ;;
            *)
                make oldconfig
                make -j "$(nproc)" bzImage
                status=$?
                ;;
        esac
    fi
    [[ $status -gt 0 ]] && exit $status
    cd ..
    mkdir -p dist
    cd dist || { echo "Couldn't change directory to dist"; exit 1; }
    case "$arch" in
        x64)
            compiledfile="../kernelsource$arch/arch/x86/boot/bzImage"
            kernelfile='bzImage'
            ;;
        x86)
            compiledfile="../kernelsource$arch/arch/x86/boot/bzImage"
            kernelfile='bzImage32'
            ;;
        arm64)
            compiledfile="../kernelsource$arch/arch/$arch/boot/Image"
            kernelfile='arm_Image'
            ;;
    esac
    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp "$compiledfile" "$kernelfile" && sha256sum "$kernelfile" > "${kernelfile}.sha256"
    cd ..
}

function dots() {
    local pad
    pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}

function addKernelPackages() {
    local source_kernel_package_dir="$PROJECT_DIRECTORY/KernelPackages"
    local target_kernel_dir="$PROJECT_DIRECTORY/kernelsource$arch"

    find "$source_kernel_package_dir" -type f | while read -r source_file; do
        # Get the relative path from the package directory to the source file
        local relative_path="${source_file#"$source_kernel_package_dir"/}"

        # Find the corresponding destination path
        local destination_file="$target_kernel_dir/$relative_path"
        local destination_dir
        destination_dir="$(dirname "$destination_file")"

        mkdir -p "$destination_dir"

        # Append if the destination file exists, otherwise copy
        if [[ -e "$destination_file" ]]; then
            cat "$source_file" >> "$destination_file"
        else
            cp "$source_file" "$destination_file"
        fi
    done
}


for buildArch in $arch
do
    if [[ -z $buildKernelOnly ]]; then
        buildFilesystem "$buildArch"
    fi
    if [[ -z $buildFSOnly ]]; then
        buildKernel "$buildArch"
    fi
done
