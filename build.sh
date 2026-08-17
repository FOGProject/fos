#!/bin/bash

source ./dependencies.sh

[[ -z $KERNEL_VERSION ]] && KERNEL_VERSION='6.18.38'
[[ -z $BUILDROOT_VERSION ]] && BUILDROOT_VERSION='2026.02.1'

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
    echo -e "\t\t-v --verbose (optional) Show make output on screen for filesystem builds as well as write it to the log file."
    echo -e "\t\t   --fs-download-only (optional) Only download Buildroot source packages for each filesystem."
    echo -e "\t\t   --sign-key (optional) Private key used to sign the kernel for UEFI Secure Boot."
    echo -e "\t\t   --sign-cert (optional) Certificate matching --sign-key, PEM or DER."
    echo -e "\t\t                Both are required together."
    echo -e "\t\t                Can also be given as \$FOS_SIGN_KEY / \$FOS_SIGN_CERT."
    echo -e "\t\t-h --help -? Display this message."
    exit 0
}
[[ -n "$arch" ]] && unset "$arch"

shortopts="?hkfnia:p:v"
longopts="help,kernel-only,filesystem-only,noconfirm,install-dep,arch:,path:,verbose,fs-download-only,sign-key:,sign-cert:"

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
        --fs-download-only)
            fsDownloadOnly="y"
            buildFSOnly="y"
            confirm="n"
            shift
            ;;
        -v | --verbose)
            verbose="y"
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
        --sign-key)
            signKey=$2
            shift 2
            ;;
        --sign-cert)
            signCert=$2
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
[[ -z $verbose ]] && verbose="n"
[[ -z $fsDownloadOnly ]] && fsDownloadOnly="n"
[[ -z $signKey ]] && signKey="$FOS_SIGN_KEY"
[[ -z $signCert ]] && signCert="$FOS_SIGN_CERT"

# Signing is entirely opt-in: with neither set, every artifact is produced
# exactly as it always was. Half a pair is always a mistake, so refuse it rather
# than silently shipping an unsigned kernel someone believes is signed.
if [[ -n $signKey || -n $signCert ]]; then
    if [[ -z $signKey || -z $signCert ]]; then
        echo "Error: --sign-key and --sign-cert must be given together."
        Usage
    fi
    for f in "$signKey" "$signCert"; do
        if [[ ! -r $f ]]; then
            echo "Error: cannot read signing file '$f'."
            exit 1
        fi
    done
    if ! command -v sbsign >/dev/null 2>&1; then
        echo "Error: sbsign not found. Install sbsigntool (Debian/Ubuntu) or sbsigntools (RHEL/Fedora)."
        exit 1
    fi
    # sbsign reads certificates with OpenSSL's PEM_read_bio_X509 and rejects
    # DER outright, while mokutil and MokManager -- the tools that enrol the
    # same certificate on a client -- want DER. Anyone following the Secure
    # Boot how-to therefore ends up holding one of each, with nothing telling
    # them which tool takes which, and handing over the wrong one produces:
    #
    #   Can't load certificate from file 'MOK.der'
    #   error:0480006C:PEM routines:get_name:no start line
    #
    # which never mentions the format. Accept either and convert here, so the
    # flag behaves the way --secure-boot-cert does in the installer.
    if openssl x509 -in "$signCert" -inform pem -noout >/dev/null 2>&1; then
        signCertPem="$signCert"
    else
        signCertPem=$(mktemp) || { echo "Error: could not create a temporary file."; exit 1; }
        # The certificate is public, so a world-readable temp file leaks
        # nothing -- it is the private key beside it that matters. Removed on
        # exit regardless of how the build ends.
        trap 'rm -f "$signCertPem"' EXIT
        if ! openssl x509 -in "$signCert" -inform der -outform pem \
                -out "$signCertPem" 2>/dev/null; then
            echo "Error: '$signCert' is not a readable certificate (tried PEM and DER)."
            exit 1
        fi
        echo " * Converted DER certificate '$signCert' to PEM for signing."
    fi
fi

checkDependencies
installDependencies "$installDep"

cd "$buildPath" || exit 1


# Echo the ARCH / CROSS_COMPILE make flags for an architecture in a given build
# domain. The kernel and filesystem builds use different 32-bit (i386 vs i486)
# and arm64 (arm64 vs aarch64) ARCH values, so the domain (fs|kernel) selects
# the correct set. x64 and any unknown arch get no extra flags.
function makeFlags() {
    local arch="$1" domain="$2"
    case "$arch" in
        x86)
            [[ $domain == kernel ]] && echo "ARCH=i386" || echo "ARCH=i486"
            ;;
        arm64)
            [[ $domain == kernel ]] && echo "ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-" || echo "ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-"
            ;;
        *)
            : # x64 and default: no extra flags
            ;;
    esac
}

# All five of FOG's own Buildroot packages have exactly one download source
# each, and Buildroot cannot give them a second one.
#
# sources.buildroot.net -- the backup mirror that covers every other package in
# the tree -- only carries packages that exist upstream in Buildroot, and none
# of these do. That is why the failing logs show it 404 rather than help. A
# package gets exactly one _SITE, so upstream is all there is, and three of
# these sites are small personal or project hosts.
#
# It has already cost two release builds. The 2026-08-03 run died when
# cabextract-1.11.tar.gz briefly 404'd; the 2026-08-17 experimental run died
# when every address of www.cabextract.org.uk timed out on port 80 from
# GitHub's runners. The same sites are routinely blocked by corporate egress
# filtering, which is the local-build version of the same failure.
#
# So the mirror list lives out here. Seed the download directory before
# Buildroot looks at it: dl-wrapper keeps a file that is already present when it
# matches the package's .hash file, and exits without touching the network at
# all. Every candidate is checked against the sha256 in that same .hash before
# it is kept, so a mirror cannot substitute different bytes for upstream's --
# and a cached tarball that no longer matches is replaced rather than trusted.
#
# Only mirrors verified byte-identical to upstream are listed. Debian is absent
# for chntpw and partclone because it legitimately repacks both (a .zip to
# .tar.gz, and a .tar.xz); Fedora is absent for partimage because it has no copy.
#
# Best effort on purpose: if every mirror fails, leave the directory alone and
# let Buildroot run its normal download, so the error the user ends up reading
# is Buildroot's own rather than one invented here.
#
# @V@ is the package version and @F@ the source filename, both read from the
# package's own .mk so a version bump cannot leave a stale URL here. @FEDORA@
# expands to the Fedora lookaside cache, which is addressed by sha512 and is
# never pruned -- the one mirror that cannot quietly lose an old release the way
# Debian's pool does once it moves on.
FOS_PACKAGE_MIRRORS=(
    "cabextract  https://deb.debian.org/debian/pool/main/c/cabextract/cabextract_@V@.orig.tar.gz  @FEDORA@"
    "chntpw      @FEDORA@"
    "testdisk    https://deb.debian.org/debian/pool/main/t/testdisk/testdisk_@V@.orig.tar.bz2  @FEDORA@"
    "partimage   https://deb.debian.org/debian/pool/main/p/partimage/partimage_@V@.orig.tar.bz2"
    "partclone   @FEDORA@"
)

# Reads $1_VERSION / $1_SOURCE / $1_SITE out of a package's .mk and echoes the
# resolved "version source upstream-url". Parsing rather than restating them
# here is what keeps a version bump from silently leaving this file behind.
# Handles `=`, `:=` and `?=`, and expands Buildroot's github macro, which is how
# partclone names its site.
function readPackageVars() {
    local pkg="$1" mk="$2"
    local upper version source site ghUser ghRepo ghVer args

    upper=$(echo "$pkg" | tr '[:lower:]' '[:upper:]')
    version=$(sed -n "s/^${upper}_VERSION[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p" "$mk" | head -1)
    source=$(sed -n "s/^${upper}_SOURCE[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p" "$mk" | head -1)
    site=$(sed -n "s/^${upper}_SITE[[:space:]]*[:?]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$mk" | head -1)
    [[ -z $version || -z $source || -z $site ]] && return 1

    # Expand $(<PKG>_VERSION) first, in both, so that by the time the github
    # macro is parsed below its arguments hold no parentheses of their own --
    # otherwise trimming at the closing paren cuts the version off mid-way.
    source=${source//"\$(${upper}_VERSION)"/$version}
    site=${site//"\$(${upper}_VERSION)"/$version}

    if [[ $site == *'$(call github,'* ]]; then
        args=${site#*'$(call github,'}
        args=${args%%)*}
        IFS=, read -r ghUser ghRepo ghVer <<< "$args"
        site="https://github.com/${ghUser// /}/${ghRepo// /}/archive/${ghVer// /}"
    fi

    echo "$version $source ${site%/}/$source"
}

# Seeds one package's tarball into $DL_DIR from upstream or a verified mirror.
function seedPackage() {
    local dlDir="$1" pkg="$2"; shift 2
    local pkgDir="../Buildroot/package/$pkg"
    local vars version source upstream sha256 sha512 target tmp url host m
    local -a mirrors

    [[ -f $pkgDir/$pkg.mk && -f $pkgDir/$pkg.hash ]] || return 0

    vars=$(readPackageVars "$pkg" "$pkgDir/$pkg.mk") || {
        echo " * WARNING: Couldn't read $pkg's version/source/site, leaving its download to Buildroot!"
        return 0
    }
    read -r version source upstream <<< "$vars"

    # Matched on the filename column, not just the algorithm: a .hash may carry
    # lines for more than one release, and picking the first sha256 in the file
    # would silently check the current tarball against a previous version's hash
    # -- every mirror would "fail" and the fallback would quietly stop working
    # while the build still passed on Buildroot's own download.
    sha256=$(awk -v f="$source" '$1 == "sha256" && $3 == f { print $2; exit }' "$pkgDir/$pkg.hash")
    sha512=$(awk -v f="$source" '$1 == "sha512" && $3 == f { print $2; exit }' "$pkgDir/$pkg.hash")
    if [[ -z $sha256 ]]; then
        echo " * WARNING: $pkg.hash has no sha256, leaving its download to Buildroot!"
        return 0
    fi

    target="$dlDir/$pkg/$source"
    if [[ -f $target ]] && echo "$sha256  $target" | sha256sum --check --status; then
        return 0
    fi

    mirrors=("$upstream")
    for m in "$@"; do
        if [[ $m == "@FEDORA@" ]]; then
            [[ -n $sha512 ]] || continue
            m="https://src.fedoraproject.org/repo/pkgs/$pkg/$source/sha512/$sha512/$source"
        else
            m=${m//@V@/$version}
            m=${m//@F@/$source}
        fi
        mirrors+=("$m")
    done

    mkdir -p "$dlDir/$pkg" || return 0
    tmp=$(mktemp "$dlDir/$pkg/.$source.XXXXXX") || return 0

    for url in "${mirrors[@]}"; do
        host="${url#*://}"
        host="${host%%/*}"
        dots "Fetching $pkg from $host"
        if wget -q --tries=2 --timeout=20 -O "$tmp" "$url" &&
            echo "$sha256  $tmp" | sha256sum --check --status; then
            mv -f "$tmp" "$target"
            echo "Done"
            return 0
        fi
        echo "Failed"
    done

    rm -f "$tmp"
    echo " * WARNING: No mirror served $source, leaving its download to Buildroot!"
    return 0
}

# Walks the table above. Never fails the build -- see the comment on the table.
function seedFragileSources() {
    local dlDir="$1" entry
    for entry in "${FOS_PACKAGE_MIRRORS[@]}"; do
        # shellcheck disable=SC2086
        seedPackage "$dlDir" $entry
    done
    return 0
}

function buildFilesystem() {
    local arch="$1"
    local fsflags dlDir
    fsflags=$(makeFlags "$arch" fs)
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
        # Guarded by a marker file, the same way .packConfDone guards the
        # Config.in append just below. Without it build.sh only ever worked
        # against a freshly downloaded tree: a second run re-applies an
        # already-applied patch, every hunk is rejected, and the hard exit
        # below aborts before anything is built. That makes an incremental
        # rebuild -- the normal loop when changing a config symbol or an
        # overlay file -- impossible, and the failure reads like a corrupt
        # patch rather than a re-run.
        if [[ -f .fsPatchDone ]]; then
            echo " * Filesystem patch already applied, skipping"
        else
            dots " * Applying filesystem patch"
            echo
            patch -p1 < ../patch/filesystem/fs.patch
            if [[ $? -ne 0 ]]; then
                echo "Failed"
                exit 1
            fi
            touch .fsPatchDone
            echo "Done"
        fi
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
        # shellcheck disable=SC2086
        make $fsflags oldconfig
    fi
    echo "Done"

    # Ask Buildroot itself where downloads land rather than re-deriving
    # BR2_DL_DIR from configs/fs$arch.config, so the seed can never write to a
    # directory the build then ignores.
    dlDir=$(make -s printvars VARS=DL_DIR 2>/dev/null | sed -n 's/^DL_DIR=//p')
    if [[ -n $dlDir ]]; then
        seedFragileSources "$dlDir"
    else
        echo " * WARNING: Couldn't determine Buildroot's download directory, skipping the package mirror seed!"
    fi

    if [[ $fsDownloadOnly == "y" ]]; then
        echo "Downloading Buildroot source packages for $arch ..."
        make source
        status=$?
        [[ $status -gt 0 ]] && echo "Failed to download source packages for $arch." && exit $status
        cd ..
        echo "$arch filesystem packages downloaded. Exiting."
        return 0
    fi

    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            # shellcheck disable=SC2086
            make $fsflags menuconfig
        else
            echo "Ok, running make oldconfig instead to ensure the config is clean."
            # shellcheck disable=SC2086
            make $fsflags oldconfig
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == n ]]; then
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    fi

    if [[ $verbose == "y" ]]; then
        # shellcheck disable=SC2086
        make $fsflags | tee "buildroot$arch.log"
        status=${PIPESTATUS[0]}
    else
        bash -c "while true; do echo \$(date) - building ...; sleep 30s; done" &
        PING_LOOP_PID=$!
        # shellcheck disable=SC2086
        make $fsflags > "buildroot$arch.log" 2>&1
        status=$?
        kill $PING_LOOP_PID
    fi

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

# Sign a built kernel in place for UEFI Secure Boot. No-op unless --sign-key and
# --sign-cert were given. Must run before the artifact is checksummed so the
# published sha256 covers the signed image, not the one we threw away.
#
# sbsign will not cleanly re-sign an already-signed image, so it writes to a
# temp file and replaces the original only on success. A signing failure is
# fatal: a build that quietly emits an unsigned kernel is worse than no build,
# because it fails later at the client with a Security Policy Violation.
function signKernel() {
    local kernelfile="$1"
    local sberr
    [[ -z $signKey ]] && return 0
    dots "Signing $kernelfile for Secure Boot"
    # $signCertPem, not $signCert: the latter may be the DER copy the admin
    # enrols with, which sbsign cannot read. See the conversion above.
    #
    # sbsign's stderr is captured rather than discarded. It was going to
    # /dev/null, which meant the one line explaining WHY signing failed --
    # unreadable key, wrong passphrase, malformed image -- was thrown away and
    # the operator got only "could not sign".
    if ! sberr=$(sbsign --key "$signKey" --cert "$signCertPem" \
            --output "${kernelfile}.signed" "$kernelfile" 2>&1 >/dev/null); then
        echo "Failed"
        echo " * sbsign could not sign $kernelfile"
        [[ -n $sberr ]] && sed 's/^/   /' <<<"$sberr"
        rm -f "${kernelfile}.signed"
        exit 1
    fi
    mv -f "${kernelfile}.signed" "$kernelfile"
    echo "Done"
}

function buildKernel() {
    local arch="$1"
    local kflags ktarget
    kflags=$(makeFlags "$arch" kernel)
    ktarget=bzImage
    [[ $arch == arm64 ]] && ktarget=Image
    kernelURL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION:0:1}.x/linux-$KERNEL_VERSION.tar.xz"
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
        # Same re-run guard as the filesystem patch above. `make mrproper`
        # clears build artifacts and .config but does not revert source edits,
        # so the patch survives it and a second kernel build would otherwise
        # abort on rejected hunks.
        if [[ -f .kernelPatchDone ]]; then
            echo " * Kernel patch already applied, skipping"
        else
            dots " * Applying patch"
            echo
            patch -p1 < ../patch/kernel/linux.patch
            if [[ $? -ne 0 ]]; then
                echo "Failed"
                exit 1
            fi
            touch .kernelPatchDone
        fi
    else
        echo " * WARNING: Did not find a patch file building vanilla kernel without patches!"
    fi
    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            # shellcheck disable=SC2086
            make $kflags menuconfig
        else
            echo "Ok, running make oldconfig instead to ensure the config is clean."
            # shellcheck disable=SC2086
            make $kflags oldconfig
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            # shellcheck disable=SC2086
            make $kflags -j "$(nproc)" $ktarget
            status=$?
        else
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
        [[ $status -gt 0 ]] && exit $status
    else
        # shellcheck disable=SC2086
        make $kflags oldconfig
        # shellcheck disable=SC2086
        make $kflags -j "$(nproc)" $ktarget
        status=$?
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
    [[ ! -f $compiledfile ]] && echo 'File not found.' || { cp "$compiledfile" "$kernelfile" && signKernel "$kernelfile" && sha256sum "$kernelfile" > "${kernelfile}.sha256"; }
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
