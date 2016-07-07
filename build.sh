#!/bin/bash
brVersion="2016.05"
kernelVersion="4.5.4"
brURL="https://buildroot.org/downloads/buildroot-$brVersion.tar.bz2"
kernelURL="https://www.kernel.org/pub/linux/kernel/v4.x/linux-$kernelVersion.tar.gz"
deps="subversion git mercurial meld build-essential rsync libncurses-dev gcc-multilib"
buildKernel="none"
buildFS="none"
arch="none"
confirm="y"
echo -n "Please wait while we check your and or install dependencies........"
apt-get install $deps -y > /dev/null
echo "Done"
echo -n "Checking for CLI options........"

while [[ $# > 0 ]]
do
key="$1"

case $key in
    -k|--kernel)
    buildKernel="y"
    ;;
    -f|--filesystem)
    buildFS="y"
    ;;
    -a|--arch)
    arch="$2"
    shift # past argument
    ;;
    -n|--noconfirm)
    confirm="n"
    shift # past argument
    ;;
    -v|--version)
    kernelVersion="$2"
    shift # past argument
    ;;
    *)
         printHelp
    ;;
esac
shift # past argument or value
done
function printHelp() {
 echo "Invalid input.  Possible options:
		-a|--arch [x64|x86] (required) pick the architecture to build
		-f|--filesystem (optional) Build the FOG file system
		-k|--kernel (optional) Build the FOG kernel
		-v|--version (optional) Specify a kernel version to build
		-n|--noconfirm (optional) Build systems without confirmation"
}
echo "Done"
if [ "$arch" == "none" ]; then
	printHelp
	echo "None or not all paramters passed.  Defaulting to asking Questions!"
read -p "What architecture would you like to use? [x86|x64]?" arch
read -p "Would you like to build the kernel? [y|n]?" buildKernel
read -p "Would you like to build the file system [y|n]?" buildFS
fi

echo "Preparing the build environment please wait........"
if [ ! -f "arch" ]; then
	echo $arch > arch
fi
currentArch=$(cat arch)
if [ "$buildFS" == "y" ]; then
	if [ ! -d "buildsource" ]; then
		mkdir buildsource
		echo -n "Downloading Build Root Source Package........"
		wget $brURL -O buildroot.tar.bz2 > /dev/null
		echo "Done"
		echo -n "Expanding Build Root Sources........"
		tar xf buildroot.tar.bz2
		cp -R buildroot-$brVersion/* buildsource
		rm -R buildroot-$brVersion
		echo "Done"
		echo -n "Adding Custom Packages to Build Root........"
		
		#oldPackages=$(cat buildsource/package/Config.in)
		cat Buildroot/package/newConf.in >> buildsource/package/Config.in
		rsync -avPrI Buildroot/ buildsource > /dev/null
		#echo $newPackages$oldPackages > buildsource/package/Config.in
		echo "Done"
		
	fi
	cp configs/fs$arch.config buildsource/.config
	cd buildsource
	echo "your working dir is $PWD"
	#cp ../fs$arch.config .config
	if [ "$arch" != "$currentArch" ]; then
		echo -n "Different architecture detected so we must clean........"
		make clean -j $(nproc) > /dev/null
		echo "Done"
		echo -n "Copying over Config file........"
		echo "Done"
	fi	 
	if [ "$confirm" != "n" ]; then
		read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
		if [ "$config" == "y" ]; then
			make menuconfig -j $(nproc)
		fi
		read -p "We are ready to build are you [y|n]?" ready
		if [ "$ready" == "y" ]; then
			echo "This make take a long time. Get some coffee, you'll be here a while!"			
			make -j $(nproc)
		fi
	else
		make -j $(nproc)
	fi
	cd ..
	if [ "$arch" == "x64" ]; then
		cp buildsource/output/images/rootfs.cpio.xz dist/init32.xz
	else
		cp buildsource/output/images/rootfs.cpio.xz dist/init.xz
	fi
	
fi
if [ "$buildKernel" == "y" ]; then
	if [ ! -d "kernelsource" ]; then
		mkdir kernelsource
		echo -n "Downloading Kernel Source Package........"
		wget $kernelURL -O kernel.tar.gz > /dev/null
		echo "Done"
		echo -n "Expanding Kernel Sources........"
		tar xf kernel.tar.gz
		cp -R linux-$kernelVersion/* kernelsource
		rm -R linux-$kernelVersion
		echo "Done"
	fi
	cd kernelsource
	echo -n "Cloning Linux-Firmware in directory........"
	git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git > /dev/null 2>&1
	echo "Done"
	echo "your working dir is $PWD"
	cp ../configs/kernel$arch.config .config
	if [ "$arch" != "$currentArch" ]; then
		echo -n "Different architecture detected so we must clean........"
		make clean -j $(nproc) > /dev/null
		echo "Done"
	fi
	if [ "$confirm" != "n" ]; then
		read -p "We are ready to build. Would you like to edit the config file [y|n]?" config
			if [ "$config" == "y" ]; then
				if [ "$arch" == "x64" ]; then
					make menuconfig -j $(nproc)
				else
					make ARCH=i386 menuconfig -j $(nproc)
				fi
			fi
			read -p "We are ready to build are you [y|n]?" ready
			if [ "$ready" == "y" ]; then
				echo "This make take a long time. Get some coffee, you'll be here a while!"		
				if [ "$arch" == "x64" ]; then
					make bzImage -j $(nproc)
				else
					make ARCH=i386 bzImage -j $(nproc)
				fi
			fi
	else
		if [ "$arch" == "x64" ]; then
			make bzImage -j $(nproc)
		else
			make ARCH=i386 bzImage -j $(nproc)
		fi
	fi
	if [ "$arch" == "x64" ]; then
		cp arch/x86/boot/bzImage ../dist/bzImage
	else
		cp arch/x86/boot/bzImage ../dist/bzImage32
	fi
cd ..
fi
echo $arch > arch
