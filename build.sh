#!/bin/bash
Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [x86|x64|arm|arm64] (optional) pick the architecture to build. Default is to build for all."
    echo -e "\t\t-f --filesystem-only (optional) Build the FOG filesystem but not the kernel."
    echo -e "\t\t-k --kernel-only (optional) Build the FOG kernel but not the filesystem."
    echo -e "\t\t-v --version (optional) Specify a kernel version to build."
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
                version)
                    val="${!OPTIND}"; OPTIND=$(($OPTIND + 1))
                    if [[ -z $val ]]; then
                        echo "Option --${OPTARG} requires a value"
                        Usage
                        exit 2
                    fi
                    kernelVersion=${val}
                    ;;
                version=*)
                    val=${OPTARG#*=}
                    opt=${OPTARG%=$val}
                    if [[ -z $val ]]; then
                        echo "Option --${opt} requires a value"
                        Usage
                        exit 2
                    fi
                    kernelVersion=${val}
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
        v)
            kernelVersion=${OPTARG}
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
brVersion="2017.11.2"
[[ -z $kernelVersion ]] && kernelVersion="4.15.2"
brURL="https://buildroot.org/downloads/buildroot-$brVersion.tar.bz2"
kernelURL="https://www.kernel.org/pub/linux/kernel/v4.x/linux-$kernelVersion.tar.xz"
deps="subversion git mercurial meld build-essential rsync libncurses-dev gcc-multilib"
[[ -z $arch ]] && arch="x64 x86 arm arm64"
[[ -z $buildPath ]] && buildPath=$(dirname $(readlink -f $0))
[[ -z $confirm ]] && confirm="y"
#echo -n "Please wait while we check your and or install dependencies........"
#apt-get install $deps -y > /dev/null
#echo "Done"
#echo "# Preparing the build environment please wait #"
mkdir -p $buildPath && cd $buildPath || exit 1


function buildFilesystem() {
    local arch="$1"
    echo "Building FS for arch $arch"
    if [[ ! -d fssource$arch ]]; then
        if [[ ! -f buildroot-$brVersion.tar.bz2 ]]; then
            echo -n "Downloading Build Root Source Package........"
            wget -q $brURL
            echo "Done"
        fi
        echo -n "Expanding Build Root Sources........"
        tar xjf buildroot-$brVersion.tar.bz2
        mv buildroot-$brVersion fssource$arch
        echo "Done"
        echo -n "Adding Custom Packages to Build Root........"
        if [[ ! -f fssource$arch/.packConfDone ]]; then
            cat Buildroot/package/newConf.in >> fssource$arch/package/Config.in
            touch fssource$arch/.packConfDone
        fi
        rsync -avPrI Buildroot/ fssource$arch > /dev/null
        echo "Done"
    else
        echo "Build directory fssource$arch already exists, will reuse it."
        echo -n "Ensuring changes are accounted for....."
        rsync -avPrI Buildroot/ fssource$arch > /dev/null
        echo "Done"
    fi
    if [[ -f fssource$arch/.config ]]; then
        echo "Configuration fssource$arch/.config already exists, will reuse it."
    else
        echo -n "Copying our buildroot configuration to start with........"
        cp configs/fs$arch.config fssource$arch/.config
        echo "Done"
    fi
    cd fssource$arch
    echo "your working dir is $PWD"
    bash -c "while true; do echo \$(date) - building ...; sleep 30s; done" &
    PING_LOOP_PID=$!
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- menuconfig
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- oldconfig
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
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            case "${arch}" in
                x64)
                    make -j $(nproc) >buildroot$arch.log 2>&1
                    status=$?
                    [[ $status -gt 0 ]] && exit $status
                    ;;
                x86)
                    make ARCH=i486 -j $(nproc) >buildroot$arch.log 2>&1
                    status=$?
                    [[ $status -gt 0 ]] && exit $status
                    ;;
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j $(nproc) >buildroot$arch.log 2>&1
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnueabi- -j $(nproc) >buildroot$arch.log 2>&1
                    ;;
                *)
                    make -j $(nproc) > buildroot$arch.log
                    status=$?
                    [[ $status -gt 0 ]] && exit $status
                    ;;
            esac
        else
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    else
        case "${arch}" in
            x64)
                make oldconfig
                make -j $(nproc) >buildroot$arch.log 2>&1
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
            x86)
                make ARCH=i486 oldconfig
                make ARCH=i486 -j $(nproc) >buildroot$arch.log 2>&1
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
            arm)
                make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- oldconfig
                make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j $(nproc) >buildroot$arch.log 2>&1
                ;;
            arm64)
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) >buildroot$arch.log 2>&1
                ;;
            *)
                make oldconfig
                make -j $(nproc) >buildroot$arch.log 2>&1
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
        esac
    fi
    cd ..
    kill $PING_LOOP_PID
    [[ ! -d dist ]] && mkdir dist
    case "${arch}" in
        x*)
	    compiledfile="fssource$arch/output/images/rootfs.ext4.xz"
            ;;
        arm*)
	    compiledfile="fssource$arch/output/images/rootfs.cpio.gz"
            ;;
    esac
    case "${arch}" in
        x64)
            initfile='dist/init.xz'
            ;;
        x86)
            initfile='dist/init_32.xz'
            ;;
        arm)
            initfile='dist/arm_init_32.cpio.gz'
            ;;
        arm64)
            initfile='dist/arm_init.cpio.gz'
            ;;
    esac

    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp $compiledfile $initfile
}

function buildKernel() {
    local arch="$1"
    echo "Building kernel for $arch"
    if [[ ! -d kernelsource$arch ]]; then
        if [[ ! -f linux-$kernelVersion.tar.xz ]]; then
            echo -n "Downloading Kernel Source Package........"
            wget -q $kernelURL
            echo "Done"
        fi
        echo -n "Expanding Kernel Sources........"
        tar -xJf linux-$kernelVersion.tar.xz
        mv linux-$kernelVersion kernelsource$arch
        echo "Done"
        cd kernelsource$arch
        if [[ ! -d linux-firmware ]]; then
            echo -n "Cloning Linux-Firmware in directory........"
            git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git > /dev/null 2>&1
            echo "Done"
        fi
        make mrproper
    else
        echo "Build directory kernelsource$arch already exists, will attempt to reuse it."
        if [[ ! -f linux-$kernelVersion.tar.xz ]]; then
            echo    "Kernel files where not present"
            echo -n "Removing kernelsource$arch..............."
            rm -rf kernelsource$arch
            echo "Done"
            echo -n "Downloading Kernel Source Package........"
            wget -q $kernelURL
            echo "Done"
            echo -n "Expanding Kernel Sources........"
            tar -xJF linux-$kernelVersion.tar.xz
            mv linux-$kernelVersion/* kernelsource$arch/
            echo "Done"
        fi
        cd kernelsource$arch
        if [[ ! -d linux-firmware ]]; then
            echo -n "Cloning Linux-Firmware in directory......"
            git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git >/dev/null 2>&1
            echo "Done"
        fi
    fi
    if [[ -f .config ]]; then
        echo "Configuration kernelsource$arch/.config already exists, will reuse it."
    else
        echo -n "Copying our buildroot configuration to start with........"
        cp ../configs/kernel$arch.config .config
        echo "Done"
    fi
    echo "your working dir is $PWD"
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- menuconfig
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- oldconfig
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
                    [[ $status -gt 0 ]] && exit $status
                    ;;
                x86)
                    make ARCH=i386 -j $(nproc) bzImage
                    [[ $status -gt 0 ]] && exit $status
                    ;;
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j $(nproc) Image
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) Image
                    ;;
                *)
                    make -j $(nproc) bzImage
                    status=$?
                    [[ $status -gt 0 ]] && exit $status
                    ;;
            esac
        else
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    else
        case "${arch}" in
            x64)
                make oldconfig
                make -j $(nproc) bzImage
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
            x86)
                make ARCH=i386 oldconfig
                make ARCH=i386 -j $(nproc) bzImage
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
            arm)
                make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- oldconfig
                make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j $(nproc) Image
                ;;
            arm64)
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) Image
                ;;
            *)
                make oldconfig
                make -j $(nproc) bzImage
                status=$?
                [[ $status -gt 0 ]] && exit $status
                ;;
        esac
    fi
    cd ..
    mkdir -p dist
    case "$arch" in
        arm)
            compiledfile="kernelsource$arch/arch/$arch/boot/Image"
            cp $compiledfile dist/arm_Image32
            ;;
        arm64)
            compiledfile="kernelsource$arch/arch/$arch/boot/Image"
            cp $compiledfile dist/arm_Image
            ;;
        x64)
            compiledfile="kernelsource$arch/arch/x86/boot/bzImage"
            cp $compiledfile dist/bzImage32
            ;;
        x86)
            compiledfile="kernelsource$arch/arch/x86/boot/bzImage"
            cp $compiledfile dist/bzImage
            ;;
    esac
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
