#!/bin/bash

[[ -z $KERNEL_VERSION ]] && KERNEL_VERSION='6.1.89'
[[ -z $BUILDROOT_VERSION ]] && BUILDROOT_VERSION='2024.02.1'

Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [x86|x64|arm64] (optional) pick the architecture to build. Default is to build for all."
    echo -e "\t\t-f --filesystem-only (optional) Build the FOG filesystem but not the kernel."
    echo -e "\t\t-k --kernel-only (optional) Build the FOG kernel but not the filesystem."
    echo -e "\t\t-p --path (optional) Specify a path to download and build the sources."
    echo -e "\t\t-n --noconfirm (optional) Build systems without confirmation."
    echo -e "\t\t-h --help -? Display this message."
}
[[ -n $arch ]] && unset $arch
optspec="?hknfh-:a:v:p:"
while getopts "$optspec" o; do
    case "${o}" in
        -)
            case $OPTARG in
                help)
                    Usage
                    exit 0
                    ;;
                arch)
                    val="${!OPTIND}"; OPTIND=$(($OPTIND + 1))
                    if [[ -z $val ]]; then
                        echo "Option --${OPTARG} requires a value"
                        Usage
                        exit 2
                    fi
                    hasa=1
                    arch=$val
                    ;;
                arch=*)
                    val=${OPTARG#*=}
                    opt=${OPTARG%=$val}
                    if [[ -z $val ]]; then
                        echo "Option --${opt} requires a value"
                        Usage
                        exit 2
                    fi
                    hasa=1
                    arch=$val
                    ;;
                path)
                    val="${!OPTIND}"; OPTIND=$(($OPTIND + 1))
                    if [[ -z $val ]]; then
                        echo "Option --${OPTARG} requires a value"
                        Usage
                        exit 2
                    fi
                    buildPath=${val}
                    ;;
                path=*)
                    val=${OPTARG#*=}
                    opt=${OPTARG%=$val}
                    if [[ -z $val ]]; then
                        echo "Option --${opt} requires a value"
                        Usage
                        exit 2
                    fi
                    buildPath=${val}
                    ;;
                kernel-only)
                    buildKernelOnly="y"
                    ;;
                filesystem-only)
                    buildFSOnly="y"
                    ;;
                noconfirm)
                    confirm="n"
                    ;;
                *)
                    if [[ $OPTERR == 1 && ${optspec:0:1} != : ]]; then
                        echo "Unknown option: --${OPTARG}"
                        Usage
                        exit 1
                    fi
                    ;;
            esac
            ;;
        h|'?')
            Usage
            exit 0
            ;;
        a)
            hasa=1
            arch=${OPTARG}
            ;;
        p)
            buildPath=${OPTARG}
            ;;
        k)
            buildKernelOnly="y"
            ;;
        f)
            buildFSOnly="y"
            ;;
        n)
            confirm="n"
            ;;
        :)
            echo "Option -${OPTARG} requires a value"
            Usage
            exit 2
            ;;
        *)
            if [[ ${OPTERR} -eq 1 && ${optspec:0:1} != : ]]; then
                echo "Unknown option: -${OPTARG}"
                Usage
                exit 1
            fi
            ;;
    esac
done
debDeps="tar xz-utils git meld build-essential bc rsync libncurses5-dev bison flex gcc-aarch64-linux-gnu libelf-dev file cpio"
rhelDeps="epel-release tar xz git meld gcc gcc-c++ kernel-devel make bc rsync ncurses-devel bison flex gcc-aarch64-linux-gnu elfutils-libelf-devel file cpio perl-English perl-ExtUtils-MakeMaker perl-Thread-Queue perl-FindBin perl-IPC-Cmd"
[[ -z $arch ]] && arch="x64 x86 arm64"
[[ -z $buildPath ]] && buildPath=$(dirname $(readlink -f $0))
[[ -z $confirm ]] && confirm="y"
echo "Checking packages needed for building"
if grep -iqE "Debian|Ubuntu" /etc/os-release ; then
    os="deb"
    eabi="eabi"
    pkgmgr() {
        dpkg -l
    }
elif grep -iqE "Red Hat|Redhat" /etc/os-release ; then
    os="rhel"
    eabi=""
    pkgmgr() {
        rpm -qa --qf "ii %{NAME}\n"
    }
fi
osDeps=${os}Deps
missing=""
for pkg in ${!osDeps}
do
    pkgmgr | awk '{print $2}' | cut -d':' -f1 | grep -qe "^${pkg}$"
    if [[ $? != 0 ]]; then
        missing="${missing} ${pkg}"
        fail=1
    fi
done
if [[ $fail == 1 ]]; then
    echo "Package(s) missing, exiting now, please install packages:${missing}"
    exit 1
fi

cd $buildPath || exit 1


function buildFilesystem() {
    local arch="$1"
    brURL="https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.xz"
    echo "Preparing buildroot $BUILDROOT_VERSION on $arch build:"
    if [[ ! -d fssource$arch ]]; then
        if [[ ! -f buildroot-$BUILDROOT_VERSION.tar.xz ]]; then
            dots "Downloading buildroot source package"
            wget -q $brURL && echo "Done"
            if [[ $? -ne 0 ]]; then
                echo "Failed"
                exit 1
            fi
        fi
        dots "Extracting buildroot sources"
        tar xJf buildroot-$BUILDROOT_VERSION.tar.xz
        mv buildroot-$BUILDROOT_VERSION fssource$arch
        echo "Done"
    fi
    cd fssource$arch
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
        cp ../configs/fs$arch.config .config
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
        read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
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
        read -p "We are ready to build are you [y|n]?" ready
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
            make >buildroot$arch.log 2>&1
            status=$?
            ;;
        x86)
            make ARCH=i486 >buildroot$arch.log 2>&1
            status=$?
            ;;
        arm64)
            make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- >buildroot$arch.log 2>&1
            status=$?
            ;;
        *)
            make >buildroot$arch.log 2>&1
            status=$?
            ;;
    esac
    kill $PING_LOOP_PID
    [[ $status -gt 0 ]] && tail buildroot$arch.log && exit $status
    cd ..
    [[ ! -d dist ]] && mkdir dist
    cd dist
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
    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp $compiledfile $initfile && sha256sum $initfile > ${initfile}.sha256
    cd ..
}

function buildKernel() {
    local arch="$1"
    kernelURL="https://www.kernel.org/pub/linux/kernel/v${KERNEL_VERSION:0:1}.x/linux-$KERNEL_VERSION.tar.xz"
    echo "Preparing kernel $KERNEL_VERSION on $arch build:"
    [[ -d kernelsource$arch ]] && rm -rf kernelsource$arch
    if [[ ! -f linux-$KERNEL_VERSION.tar.xz ]]; then
        dots "Downloading kernel source"
        wget -q $kernelURL && echo "Done"
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
        fi
    fi
    dots "Extracting kernel source"
    tar xJf linux-$KERNEL_VERSION.tar.xz
    mv linux-$KERNEL_VERSION kernelsource$arch
    echo "Done"
    dots "Preparing kernel source"
    cd kernelsource$arch
    make mrproper
    cp ../configs/kernel$arch.config .config
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
    dots "Cloning Linux firmware repository"
    git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git >/dev/null 2>&1
    echo "Done"
    if [[ $confirm != n ]]; then
        read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
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
        read -p "We are ready to build are you [y|n]?" ready
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            case "${arch}" in
                x64)
                    make -j $(nproc) bzImage
                    status=$?
                    ;;
                x86)
                    make ARCH=i386 -j $(nproc) bzImage
                    status=$?
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) Image
                    status=$?
                    ;;
                *)
                    make -j $(nproc) bzImage
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
                make -j $(nproc) bzImage
                status=$?
                ;;
            x86)
                make ARCH=i386 oldconfig
                make ARCH=i386 -j $(nproc) bzImage
                status=$?
                ;;
            arm64)
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) Image
                status=$?
                ;;
            *)
                make oldconfig
                make -j $(nproc) bzImage
                status=$?
                ;;
        esac
    fi
    [[ $status -gt 0 ]] && exit $status
    cd ..
    mkdir -p dist
    cd dist
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
    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp $compiledfile $kernelfile && sha256sum $kernelfile > ${kernelfile}.sha256
    cd ..
}

dots() {
    local pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}



for buildArch in $arch
do
    if [[ -z $buildKernelOnly ]]; then
        buildFilesystem $buildArch
    fi
    if [[ -z $buildFSOnly ]]; then
        buildKernel $buildArch
    fi
done
