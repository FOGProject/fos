#!/bin/bash
#
# Assertion harness pairing each arch's init artifact with the decompressor its
# kernel actually carries.
#
#   tests/checks/initrd-format.sh        # check the committed configs
#   tests/checks/initrd-format.sh -b     # also check post-oldconfig .config
#                                        # in any kernelsource<arch>/ present
#
# Why this exists. build.sh publishes a *different* init image per arch --
# rootfs.ext2.xz for x64/x86, rootfs.cpio.gz for arm64 -- and each of those
# compressions needs its own CONFIG_RD_* symbol in the kernel that has to unpack
# it. Nothing in the tree tied the two ends together, and they drifted: the
# arm64 kernel shipped with `# CONFIG_RD_GZIP is not set` while the arm64 init
# shipped as gzip. Confirmed against the released binary, not just the config --
# extract-ikconfig on a distributed arm_Image reports RD_GZIP off, and
# arm_init.cpio.gz begins 1f 8b 08. That pair cannot boot at all.
#
# The failure is late, remote and unhelpful: the kernel prints "Initramfs
# unpacking failed: invalid magic at start of compressed archive", carries on
# with an empty rootfs, then panics on "Unable to mount root fs". Nobody sees it
# until a client PXE-boots, and CONFIG_RD_GZIP is `default y` upstream so the
# config reads as an accident rather than a decision.
#
# The same check covers CONFIG_MODULES, for the same reason one step further
# out: the init is the root filesystem and has no /lib/modules, so a kernel
# built modular loses every =m driver silently. That matters most right after a
# config is regenerated from a distro defconfig, where =m is the norm.
#
# Both ends are derived rather than hardcoded, so this keeps holding if build.sh
# changes format: the artifact comes from build.sh's own buildFilesystem case
# block, and the required symbols come from that filename's extension. The
# Buildroot side is checked too -- an image type/compression that fs<arch>.config
# does not enable is one build.sh copies but Buildroot never produced.
#
# The -b mode is the one that actually proves anything, because it inspects the
# config Kconfig produced rather than the one we wrote -- `make oldconfig`
# silently drops symbols whose dependencies are unmet (the ADR-0010 trap).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."

checkBuilt=0
[[ ${1:-} == -b ]] && checkBuilt=1

# extension | Buildroot compression suffix | kernel RD_/DECOMPRESS_ suffix
#
# An artifact with no compression extension needs no decompressor, and is
# spelled with a "-" in the last two columns.
COMPRESSIONS=(
    "gz|GZIP|GZIP"
    "xz|XZ|XZ"
    "zst|ZSTD|ZSTD"
    "lz4|LZ4|LZ4"
    "lzo|LZO|LZO"
    "bz2|BZIP2|BZIP2"
    "lzma|LZMA|LZMA"
    "cpio|-|-"
    "ext2|-|-"
)

fails=0
checked=0

# Pull the init image build.sh publishes for an arch out of buildFilesystem's
# case block. buildKernel has a case block over the same arch labels, so the
# fssource path is what separates the two.
artifactFor() {
    local arch="$1"
    awk -v arch="$arch" '
        $0 ~ "^[[:space:]]*"arch"\\)[[:space:]]*$" { inarch = 1; next }
        inarch && /compiledfile="\.\.\/fssource/ {
            n = split($0, p, "/")
            sub(/".*$/, "", p[n])
            print p[n]
            exit
        }
        inarch && /^[[:space:]]*;;[[:space:]]*$/ { inarch = 0 }
    ' "$REPO/build.sh"
}

# rootfs.cpio.gz -> "cpio gz"; rootfs.ext2.xz -> "ext2 xz"
imageAndCompression() {
    local file="$1"
    echo "${file#rootfs.}" | tr '.' ' '
}

lookupCompression() {
    local ext="$1" row
    for row in "${COMPRESSIONS[@]}"; do
        [[ ${row%%|*} == "$ext" ]] && { echo "${row#*|}"; return 0; }
    done
    return 1
}

# The Buildroot half: fs<arch>.config must actually be producing the image
# build.sh goes on to copy. It routinely enables more than one image type
# (fsarm64.config builds both ext2 and cpio), so this is not redundant with the
# kernel check -- it catches build.sh naming an artifact nothing emits.
checkBuildroot() {
    local arch="$1" imgtype="$2" brsuffix="$3"
    local file="$REPO/configs/fs${arch}.config"
    local base="BR2_TARGET_ROOTFS_$(echo "$imgtype" | tr '[:lower:]' '[:upper:]')"
    [[ -f $file ]] || { echo "FAIL [configs/fs${arch}.config] not found"; fails=$((fails + 1)); return; }
    if ! grep -qxF "${base}=y" "$file"; then
        echo "FAIL [configs/fs${arch}.config] missing: ${base}=y"
        fails=$((fails + 1))
    fi
    [[ $brsuffix == - ]] && return
    if ! grep -qxF "${base}_${brsuffix}=y" "$file"; then
        echo "FAIL [configs/fs${arch}.config] missing: ${base}_${brsuffix}=y"
        fails=$((fails + 1))
    fi
}

# The kernel half. RD_* is what gates the decompressor being linked in at all;
# DECOMPRESS_* is the symbol RD_* selects, asserted separately because a config
# can carry one without the other after hand-editing.
checkKernel() {
    local label="$1" file="$2" rdsuffix="$3"
    [[ -f $file ]] || return 0
    checked=$((checked + 1))
    if ! grep -qxF "CONFIG_BLK_DEV_INITRD=y" "$file"; then
        echo "FAIL [$label] missing: CONFIG_BLK_DEV_INITRD=y"
        fails=$((fails + 1))
    fi
    # The init IS the root filesystem and it carries no /lib/modules, so a
    # modular kernel loses every driver built as =m with nothing logged. This
    # is not a style preference -- it is the reason the configs can be
    # regenerated from a distro-style defconfig at all, since those set
    # CONFIG_MODULES=y and mark most drivers =m.
    if ! grep -qxF "# CONFIG_MODULES is not set" "$file"; then
        echo "FAIL [$label] CONFIG_MODULES must be off: the init has no /lib/modules"
        fails=$((fails + 1))
    fi
    if [[ $rdsuffix != - ]]; then
        local sym
        for sym in "CONFIG_RD_${rdsuffix}=y" "CONFIG_DECOMPRESS_${rdsuffix}=y"; do
            if ! grep -qxF "$sym" "$file"; then
                echo "FAIL [$label] missing: $sym"
                fails=$((fails + 1))
            fi
        done
    fi
    echo "  checked $label"
}

for arch in x64 x86 arm64; do
    artifact=$(artifactFor "$arch")
    if [[ -z $artifact ]]; then
        echo "FAIL [build.sh] no filesystem artifact found for arch $arch"
        fails=$((fails + 1))
        continue
    fi
    read -r imgtype ext <<<"$(imageAndCompression "$artifact")"
    # An uncompressed artifact (rootfs.cpio) leaves ext empty; the image type
    # itself then carries the "-" row.
    [[ -z $ext ]] && ext="$imgtype"
    if ! row=$(lookupCompression "$ext"); then
        echo "FAIL [build.sh] unknown compression '.$ext' on $artifact (arch $arch)"
        fails=$((fails + 1))
        continue
    fi
    brsuffix="${row%%|*}"
    rdsuffix="${row#*|}"
    echo "arch $arch ships $artifact"
    checkBuildroot "$arch" "$imgtype" "$brsuffix"
    checkKernel "configs/kernel${arch}.config" \
                "$REPO/configs/kernel${arch}.config" "$rdsuffix"
    if [[ $checkBuilt -eq 1 ]]; then
        f="$REPO/kernelsource${arch}/.config"
        [[ -f $f ]] && checkKernel "kernelsource${arch}/.config (post-oldconfig)" \
                                   "$f" "$rdsuffix" && built=1
    fi
done

if [[ $checkBuilt -eq 1 && ${built:-0} -eq 0 ]]; then
    echo
    echo "NOTE: -b given but no kernelsource<arch>/.config found -- nothing"
    echo "      post-oldconfig was checked. Build first, then re-run."
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: $checked config(s) can unpack the init they ship with"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
