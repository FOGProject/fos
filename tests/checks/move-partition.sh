#!/bin/bash
#
# Assertion harness for movePartition() in funcs.sh: the capture-time step
# that closes the gap a shrink leaves before the next partition (resizable
# images on GPT disks only).
#
#   tests/checks/move-partition.sh   # run all cases, exit non-zero on any failure
#
# fos#189: movePartition() looked each partition up in the sfdisk dump with a
# substring grep. On a Debian or Ubuntu cloud image the disk carries sda1,
# sda14 and sda15, so `grep /dev/sda1` returned three lines. The start and the
# size became multi-line, calculate() failed, the empty result read as 0, and
# FOS tried to move sda14 "forward" to sector 0. The capture aborted and left
# the source disk shrunk.
#
# What this harness locks:
#
#   1. The Debian cloud layout (sda14 and sda15 physically BEFORE sda1) moves
#      nothing and raises nothing: each lookup returns one line.
#   2. A layout with a real gap (sda1 shrunk, sda10 and sda11 after it) moves
#      sda10 to the exact sector after the end of sda1, and nothing else.
#
# Both fixtures are real `sfdisk -d` output, captured from disk images
# partitioned with util-linux sfdisk 2.41, with the image file name rewritten
# to /dev/sda. That is the shape the lookup parses: "<device> : start=...".
#
# Mechanism mirrors tests/checks/primary-disk-dedup.sh: source a sandbox copy
# of the library, PATH-shadow flock and sfdisk, and override the helpers that
# touch /sys or write a table. processSfdisk is recorded, not run: the move
# arithmetic in procsfdisk.awk is not what this harness is about.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

cat > "$SANDBOX/debian-cloud.sfdisk" <<'DUMP'
label: gpt
label-id: 5D92393C-4AE2-47D4-9662-82F33F30EF4A
device: /dev/sda
unit: sectors
first-lba: 34
last-lba: 41943006
sector-size: 512

/dev/sda1 : start=      262144, size=     4194304, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=8CA6ABC7-ABB3-4E13-8736-69FBC76412CF
/dev/sda14 : start=        2048, size=        6144, type=21686148-6449-6E6F-744E-656564454649, uuid=CAF09960-4156-4DBB-B780-15E547F2B1C3
/dev/sda15 : start=        8192, size=      253952, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=0CE37D93-AD0C-46AD-B69A-EC572FCC6D41
DUMP

cat > "$SANDBOX/gap.sfdisk" <<'DUMP'
label: gpt
label-id: 1952293F-C775-49F3-9622-D96C98BA3B54
device: /dev/sda
unit: sectors
first-lba: 2048
last-lba: 41943006
sector-size: 512

/dev/sda1 : start=        2048, size=     1048576, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=8F228301-F3DD-4221-A44C-E0BC43B790E8
/dev/sda10 : start=     8390656, size=     2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=F3A1467C-7885-4992-8A99-C31CF3C5A612
/dev/sda11 : start=    10487808, size=     2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=4EE52B85-E95E-434A-8D5B-9C35F05619BF
DUMP

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/flock" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
# sfdisk double: `sfdisk -d <disk>` prints the case's fixture.
cat > "$STUBBIN/sfdisk" <<'STUB'
#!/bin/bash
cat "$FAKE_DUMP"
STUB
chmod +x "$STUBBIN"/*
export PATH="$STUBBIN:$PATH"

# shellcheck disable=SC1090
. "$SANDBOX/funcs.sh" >/dev/null 2>&1
getDiskFromPartition() { disk=/dev/sda; }
processSfdisk() { echo "$3 $4" >> "$SANDBOX/moves"; }
applySfdiskPartitions() { :; }
handleError() { echo "handleError: $*" >> "$SANDBOX/errors"; }

fail=0
# Run movePartition over the partitions in the order fog.upload uses
# (sort -V), and compare the recorded moves with the expected list.
check() {
    local name="$1" dump="$2" parts="$3" want="$4"
    export FAKE_DUMP="$SANDBOX/$dump"
    rm -f "$SANDBOX/moves" "$SANDBOX/errors" "$SANDBOX/stderr"
    local prevPart="" part
    for part in $parts; do
        movePartition "$part" "$prevPart" >/dev/null 2>>"$SANDBOX/stderr"
        prevPart="$part"
    done
    local got errors
    got="$(cat "$SANDBOX/moves" 2>/dev/null)"
    errors="$(cat "$SANDBOX/errors" "$SANDBOX/stderr" 2>/dev/null)"
    if [[ "$got" == "$want" && -z $errors ]]; then
        echo "ok    $name"
    else
        echo "FAIL  $name: moves='${got//$'\n'/; }' wanted='$want' errors='${errors//$'\n'/; }'"
        fail=1
    fi
}

check "Debian cloud layout (sda1/sda14/sda15) moves nothing" \
    debian-cloud.sfdisk "/dev/sda1 /dev/sda14 /dev/sda15" ""
check "sda10 moves to the end of sda1, sda11 stays" \
    gap.sfdisk "/dev/sda1 /dev/sda10 /dev/sda11" "/dev/sda10 1050624"

[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
