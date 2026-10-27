#!/bin/bash
#
# Assertion harness for the /tmp size cap (ADR-0021).
#
#   tests/checks/tmp-size.sh        # check the committed configs
#   tests/checks/tmp-size.sh -b     # also check post-oldconfig .config
#                                   # in any kernelsource<arch>/ present
#
# Why this exists. Every kernel config had CONFIG_SHMEM off, and without it
# the kernel registers "tmpfs" as plain ramfs: fstab's tmpfs /tmp accepted a
# size= and enforced nothing, so a runaway write to /tmp grew until the client
# ran out of memory. df printed 0 for /tmp, which is what gave it away. The
# ext2 ram disk never bounded /tmp either; it only bounded the root.
#
# Three things have to hold together, and each is checked here: the kernel
# builds real tmpfs (SHMEM and TMPFS, and -b proves they survived oldconfig);
# fstab gives /tmp a size= default; and S00tmpsize turns ramdisk_size= (the
# server's FOG_KERNEL_RAMDISK_SIZE) into a size that is clamped to sane
# bounds. The last is run as shipped, through its own "print" mode.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
OVERLAY="$REPO/Buildroot/board/FOG/FOS/rootfs_overlay"
SCRIPT="$OVERLAY/etc/init.d/S00tmpsize"

checkBuilt=0
[[ ${1:-} == -b ]] && checkBuilt=1

fails=0
checked=0
ck() {
    checked=$((checked + 1))
    if [[ $2 != 1 ]]; then
        echo "FAIL $1"
        fails=$((fails + 1))
    fi
}
eq() { [[ $1 == "$2" ]] && echo 1 || echo 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# size <cmdline> <MemTotal kB, or "none">
size() {
    echo "$1" > "$tmp/cmdline"
    if [[ $2 == none ]]; then
        rm -f "$tmp/meminfo"
    else
        printf 'MemTotal:       %s kB\nMemFree:        1 kB\n' "$2" > "$tmp/meminfo"
    fi
    FOG_CMDLINE="$tmp/cmdline" FOG_MEMINFO="$tmp/meminfo" "$SCRIPT" print
}

BASE="loglevel=4 initrd=init.xz root=/dev/ram0 rw"
ck "1 FOG's default 275000 on a 4 GiB client" "$(eq "$(size "$BASE ramdisk_size=275000 web=x" 4000000)" 275000)"
ck "2 no ramdisk_size keeps 256 MiB" "$(eq "$(size "$BASE web=x" 4000000)" 262144)"
ck "3 a 1 GiB setting on a 1 GiB client is half of RAM" "$(eq "$(size "$BASE ramdisk_size=1048576" 990264)" 495132)"
ck "4 a 512 MiB setting on 8 GiB is honored" "$(eq "$(size "$BASE ramdisk_size=524288" 8000000)" 524288)"
ck "5 below 64 MiB is raised to 64 MiB" "$(eq "$(size "$BASE ramdisk_size=1000" 4000000)" 65536)"
ck "6 non-numeric keeps the default" "$(eq "$(size "$BASE ramdisk_size=abc" 4000000)" 262144)"
ck "7 trailing garbage keeps the default" "$(eq "$(size "$BASE ramdisk_size=275000x" 4000000)" 262144)"
ck "8 empty value keeps the default" "$(eq "$(size "$BASE ramdisk_size=" 4000000)" 262144)"
ck "9 unreadable meminfo: no clamp, setting kept" "$(eq "$(size "$BASE ramdisk_size=524288" none)" 524288)"
ck "10 a name that merely ends in ramdisk_size is ignored" "$(eq "$(size "$BASE xramdisk_size=999999" 4000000)" 262144)"

ck "11 S00tmpsize is executable (rcS runs it as \$i start)" "$([[ -x $SCRIPT ]] && echo 1 || echo 0)"
grep -qE '^tmpfs[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]+[^[:space:]]*size=' "$OVERLAY/etc/fstab"
ck "12 fstab gives /tmp a size= default" "$(eq $? 0)"

# The kernel half: without these, every size= above is ignored.
kernelHasTmpfs() {
    local label="$1" file="$2" sym
    [[ -f $file ]] || return 0
    for sym in CONFIG_SHMEM=y CONFIG_TMPFS=y; do
        grep -qxF "$sym" "$file"
        ck "13 [$label] carries $sym" "$(eq $? 0)"
    done
}
for arch in x64 x86 arm64; do
    kernelHasTmpfs "configs/kernel${arch}.config" "$REPO/configs/kernel${arch}.config"
    [[ $checkBuilt -eq 1 ]] && kernelHasTmpfs "kernelsource${arch}/.config" "$REPO/kernelsource${arch}/.config"
done

echo
echo "passed: $((checked - fails))   failed: $fails"
[[ $fails -eq 0 ]]
