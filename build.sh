#!/bin/bash
Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [x86|x64] pick the architecture to build. Defaults to x64"
    echo -e "\t\t-f --filesystm (optional) Build the FOG filesystem"
    echo -e "\t\t-k --kernel (optional) Build the FOG kernel"
    echo -e "\t\t-v --version (optional) Specify a kernel version to build"
    echo -e "\t\t-n --noconfirm (optional) Build systems without confirmation"
    echo -e "\t\t-h --help -? Display this message"
}
[[ -n $arch ]] && unset $arch
optspec="?hknfh-:a:v:"
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
                kernel)
                    buildKernel="y"
                    ;;
                filesystem)
                    buildFS="y"
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
        k)
            buildKernel="y"
            ;;
        f)
            buildFS="y"
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
brVersion="2017.02.1"
[[ -z $kernelVersion ]] && kernelVersion="4.5.4"
brURL="https://buildroot.org/downloads/buildroot-$brVersion.tar.bz2"
kernelURL="https://www.kernel.org/pub/linux/kernel/v4.x/linux-$kernelVersion.tar.gz"
deps="subversion git mercurial meld build-essential rsync libncurses-dev gcc-multilib"
[[ -z $buildKernel ]] && buildKernel="none"
[[ -z $buildFS ]] && buildFS="none"
[[ -z $confirm ]] && confirm="y"
#echo -n "Please wait while we check your and or install dependencies........"
#apt-get install $deps -y > /dev/null
#echo "Done"
#echo "# Preparing the build environment please wait #"
[[ ! -f "arch" ]] && echo $arch > arch
currentArch=$(cat arch)
if [[ $buildFS == 'y' ]]; then
    if [[ ! -d initsource$arch ]]; then
        echo -n "Downloading Build Root Source Package........"
        wget $brURL -qO buildroot.tar.bz2 > /dev/null
        echo "Done"
        echo -n "Expanding Build Root Sources........"
        tar xf buildroot.tar.bz2
        mv buildroot-$brVersion initsource$arch
        echo "Done"
    fi
    echo -n "Adding Custom Packages to Build Root........"
    #oldPackages=$(cat initsource$arch/package/Config.in)
    if [[ ! -f initsource$arch/.packConfDone ]]; then
        cat Buildroot/package/newConf.in >> initsource$arch/package/Config.in
        touch initsource$arch/.packConfDone
    fi
    rsync -avPrI Buildroot/ initsource$arch > /dev/null
    #echo $newPackages$oldPackages > initsource$arch/package/Config.in
    echo "Done"
    cp configs/fs$arch.config initsource$arch/.config
    cd initsource$arch
    echo "your working dir is $PWD"
    #cp ../fs$arch.config .config
    if [[ $arch != $currentArch ]]; then
        echo -n "Different architecture detected so we must clean........"
        make clean
        echo "Done"
        echo -n "Copying over Config file........"
        echo "Done"
    fi
    if [[ $confirm != n ]]; then
        read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
        [[ $config == y ]] && make menuconfig
        read -p "We are ready to build are you [y|n]?" ready
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            make
        fi
    fi
    make
    cd ..
    [[ ! -d dist ]] && mkdir dist
    compiledfile="initsource$arch/output/images/rootfs.ext4.xz"
    [[ $arch == x64 ]] && initfile='dist/init.xz' || initfile='dist/init32.xz'
    [[ ! -f $compiledfile ]] && echo 'File not found.' || cp $compiledfile $initfile
fi
if [[ $buildKernel == y ]]; then
    if [[ ! -d kernelsource ]]; then
        mkdir kernelsource
        echo -n "Downloading Kernel Source Package........"
        wget $kernelURL -qO kernel.tar.gz >/dev/null
        echo "Done"
        echo -n "Expanding Kernel Sources........"
        tar xzf kernel.tar.gz
        mv linux-$kernelVersion kernelsource
        echo "Done"
    fi
    cd kernelsource
    echo -n "Cloning Linux-Firmware in directory........"
    git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git > /dev/null 2>&1
    echo "Done"
    echo "your working dir is $PWD"
    cp ../configs/kernel$arch.config .config
    if [[ $arch != $currentArch ]]; then
        echo -n "Different architecture detected so we must clean........"
        make clean -j $(nproc) > /dev/null
        echo "Done"
    fi
    if [[ $confirm != n ]]; then
        read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            [[ $arch == x64 ]] && make menuconfig -j $(nproc) || make ARCH=i386 menuconfig -j $(nproc)
	else
            [[ $arch == x64 ]] && make oldconfig || make ARCH=i386 oldconfig
        fi
        read -p "We are ready to build are you [y|n]?" ready
        if [[ $ready ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            [[ $arch == x64 ]] && make -j $(nproc) bzImage || make ARCH=i386 -j $(nproc) bzImage
        fi
    else
        [[ $arch == x64 ]] && make -j $(nproc) bzImage || make ARCH=i386 -j $(nproc) bzImage
    fi
    [[ ! -d ../dist ]] && mkdir ../dist
    [[ $arch == x64 ]] && cp arch/x86/boot/bzImage ../dist/bzImage || cp arch/x86/boot/bzImage ../dist/bzImage32
    cd ..
fi
echo $arch > arch
