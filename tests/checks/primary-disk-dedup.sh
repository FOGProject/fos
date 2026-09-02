#!/bin/bash
#
# Assertion harness for getHardDisk() in funcs.sh when Host Primary Disk is
# set: the named disk goes first and every other disk follows exactly once.
#
#   tests/checks/primary-disk-dedup.sh   # run all cases, exit non-zero on any failure
#
# fogproject issue #743: with a multi-disk-all image and Host Primary Disk set
# to /dev/sda, FOS captured /dev/sda, then captured it again as the "next"
# disk, and on deploy wrote it back twice. getHardDisk() builds the device
# pool from lsblk one device per LINE, then tried to drop a matched device
# from the pool with a sed that only matches it with a SPACE on each side.
# The pattern never matched, nothing was removed, and the final
# `disks="$disks $devs"` appended the matched disk a second time.
#
# What this harness locks:
#
#   1. fdrive naming the first-enumerated disk yields each disk once, the
#      named one first.
#   2. fdrive naming a later disk moves it to the front and the rest keep
#      their enumeration order, still once each.
#   3. A comma-separated fdrive naming two disks yields them in the order
#      given, with the remainder after.
#   4. With no fdrive, the kernel arguments largesize=1 and smallsize=1 pick
#      the largest and the smallest disk by capacity (fogproject #817), and
#      neither picks the first enumerated.
#
# Mechanism mirrors tests/checks/ntfs-shrink-retry.sh: source a sandbox copy
# of the library and PATH-shadow lsblk, blockdev and blkid with doubles that
# describe a fixed three-disk machine whose first-enumerated disk is neither
# the largest nor the smallest, so each automatic choice lands on a
# different device.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# lsblk double. The pool query (-dpno KNAME,SIZE) lists three disks, one per
# line, the way the real tool does. The per-device SERIAL,WWN query answers
# with empty values so only the path can match a spec.
cat > "$STUBBIN/lsblk" <<'STUB'
#!/bin/bash
case "$*" in
    *KNAME,SIZE*)
        printf '/dev/sda 1T\n/dev/sdb 500G\n/dev/nvme0n1 2T\n'
        ;;
    *SERIAL,WWN*)
        printf 'SERIAL="" WWN=""\n'
        ;;
esac
STUB
cat > "$STUBBIN/blockdev" <<'STUB'
#!/bin/bash
case "$2" in
    /dev/sda) echo 1000204886016 ;;
    /dev/sdb) echo 500107862016 ;;
    *)        echo 2000398934016 ;;
esac
STUB
cat > "$STUBBIN/blkid" <<'STUB'
#!/bin/bash
exit 2
STUB
chmod +x "$STUBBIN"/*
export PATH="$STUBBIN:$PATH"

# shellcheck disable=SC1090
. "$SANDBOX/funcs.sh" >/dev/null 2>&1
handleError() { echo "handleError: $*" >&2; return 1; }

fail=0
check() {
    local name="$1" spec="$2" want="$3"
    fdrive="$spec"
    imgType="mpa"
    type="up"
    hd=""; disks=""
    getHardDisk 2>/dev/null
    if [[ "$disks" == "$want" && "$hd" == "${want%% *}" ]]; then
        echo "ok    $name"
    else
        echo "FAIL  $name: fdrive='$spec' gave disks='$disks' hd='$hd', wanted '$want'"
        fail=1
    fi
}

check "first-enumerated disk named once"   "/dev/sda"          "/dev/sda /dev/sdb /dev/nvme0n1"
check "later disk moves to the front"      "/dev/sdb"          "/dev/sdb /dev/sda /dev/nvme0n1"
check "two specs keep their given order"   "/dev/nvme0n1,/dev/sda" "/dev/nvme0n1 /dev/sda /dev/sdb"

# Automatic choice: single-disk image, no Host Primary Disk.
auto() {
    local name="$1" want="$2"
    fdrive=""; imgType="n"; type="up"
    largesize="$3"; smallsize="$4"
    hd=""; disks=""
    getHardDisk 2>/dev/null
    if [[ "$hd" == "$want" && "$disks" == "$want" ]]; then
        echo "ok    $name"
    else
        echo "FAIL  $name: largesize='$3' smallsize='$4' gave hd='$hd' disks='$disks', wanted '$want'"
        fail=1
    fi
}
auto "no argument takes the first enumerated" "/dev/sda"     "" ""
auto "largesize=1 takes the largest"          "/dev/nvme0n1" "1" ""
auto "smallsize=1 takes the smallest"         "/dev/sdb"     "" "1"

[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
