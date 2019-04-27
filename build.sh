#!/bin/bash
Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [x86|x64|arm|arm64] (optional) pick the architecture to build. Default is to build for all."
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
brURL="https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.bz2"
kernelURL="https://www.kernel.org/pub/linux/kernel/v4.x/linux-$KERNEL_VERSION.tar.xz"
debDeps="git meld build-essential rsync libncurses5-dev bison flex gcc-arm-linux-gnueabi gcc-aarch64-linux-gnu"
rhelDeps="git meld rsync ncurses-devel bison flex gcc-arm-linux-gnu gcc-aarch64-linux-gnu"
[[ -z $arch ]] && arch="x64 x86 arm arm64"
[[ -z $buildPath ]] && buildPath=$(dirname $(readlink -f $0))
[[ -z $confirm ]] && confirm="y"
echo "Checking packages needed for building"
if grep -iqE "Debian" /proc/version ; then
    os="deb"
    eabi="eabi"
    pkgmgr="dpkg -s"
elif grep -iqE "Red Hat|Redhat" /proc/version ; then
    os="rhel"
    eabi=""
    pkgmgr="rpm -qi"
fi
osDeps=${os}Deps
for pkg in ${!osDeps}
do
    $pkgmgr $pkg >/dev/null 2>&1
    if [[ $? != 0 ]]; then
        echo " * Package $pkg missing!"
        fail=1
    fi
done
if [[ $fail == 1 ]]; then
    echo "Package(s) missing, can't build, exiting now."
    exit 1
fi

cd $buildPath || exit 1


function buildFilesystem() {
    local arch="$1"
    [[ -z $BUILDROOT_VERSION ]] && echo "No buildroot version, set environment BUILDROOT_VERSION" && exit 1
    echo "Preparing buildroot $arch build"
    if [[ ! -d fssource$arch ]]; then
        if [[ ! -f buildroot-$BUILDROOT_VERSION.tar.bz2 ]]; then
            dots "Downloading buildroot source package"
            wget -q $brURL
            echo "Done"
        fi
        dots "Extracting buildroot sources"
        tar xjf buildroot-$BUILDROOT_VERSION.tar.bz2
        mv buildroot-$BUILDROOT_VERSION fssource$arch
        echo "Done"
    fi
    dots "Preparing code"
    cd fssource$arch
    if [[ ! -f .packConfDone ]]; then
        cat ../Buildroot/package/newConf.in >> package/Config.in
        touch .packConfDone
    fi
    rsync -avPrI ../Buildroot/ . > /dev/null
    if [[ ! -f .config ]]; then
        cp ../configs/fs$arch.config .config
        case "${arch}" in
            x64)
                make oldconfig
                ;;
            x86)
                make ARCH=i486 oldconfig
                ;;
            arm)
                echo Skipping
                #make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- oldconfig
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
                arm)
                    echo Skipping
                    #make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- menuconfig
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
                    echo Skipping
                    #make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- oldconfig
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
        arm)
            echo Skipping
            #make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- -j $(nproc) >buildroot$arch.log 2>&1
            #status=$?
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
    case "${arch}" in
        x*)
            compiledfile="fssource$arch/output/images/rootfs.ext2.xz"
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
    if [[ $arch != 'arm' ]]; then
        [[ ! -f $compiledfile ]] && echo 'File not found.' || cp $compiledfile $initfile
    fi
}

function buildKernel() {
    local arch="$1"
    [[ -z $KERNEL_VERSION ]] && echo "No kernel version, set environment KERNEL_VERSION" && exit 1
    echo "Preparing kernel $arch build:"
    [[ -d kernelsource$arch ]] && rm -rf kernelsource$arch
    if [[ ! -f linux-$KERNEL_VERSION.tar.xz ]]; then
        dots "Downloading kernel source"
        wget -q $kernelURL
        echo "Done"
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
    if [[ -f ../patch/kernel/linux-$KERNEL_VERSION.patch ]]; then
        dots "Applying patch(es)"
	echo
        patch -p1 < ../patch/kernel/linux-$KERNEL_VERSION.patch
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
	fi
    else
        echo " * Did not find a patch file matching the exact kernel version $KERNEL_VERSION."
	latest=$(ls -1r ../patch/kernel/linux*.patch | head -1)
	dots "Trying to apply $latest"
	echo
	patch -p1 < $latest
        if [[ $? -ne 0 ]]; then
            echo "Failed"
            exit 1
	fi
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- menuconfig
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
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- oldconfig
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
                arm)
                    make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- -j $(nproc) Image
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
            arm)
                make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- oldconfig
                make ARCH=arm CROSS_COMPILE=arm-linux-gnu${eabi}- -j $(nproc) Image
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
    case "$arch" in
        x64)
            compiledfile="kernelsource$arch/arch/x86/boot/bzImage"
            cp $compiledfile dist/bzImage
            ;;
        x86)
            compiledfile="kernelsource$arch/arch/x86/boot/bzImage"
            cp $compiledfile dist/bzImage32
            ;;
        arm)
            compiledfile="kernelsource$arch/arch/$arch/boot/Image"
            cp $compiledfile dist/arm_Image32
            ;;
        arm64)
            compiledfile="kernelsource$arch/arch/$arch/boot/Image"
            cp $compiledfile dist/arm_Image
            ;;
    esac
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
