#!/bin/bash
#
# Assertion harness for MBR tables carrying an extended partition with logical
# partitions inside it (FOS issue #150).
#
#   tests/checks/mbr-extended.sh   # run all cases, exit non-zero on any failure
#
# sfdisk consumes a script top to bottom and takes each partition number from
# the device name on the line, so an extended-partition layout only survives a
# round trip if the emitted table obeys three rules that nothing else in the
# suite covers:
#
#   1. Emission order. procsfdisk.awk collects partitions in an associative
#      array and display_output() walked it with `for (name in array)`, which
#      gawk leaves unordered. It happens to match input order for /dev/sdaN
#      with N <= 9, so the bug hid until a table had ten partitions and
#      /dev/sda10 hashed to the front -- sfdisk then met a logical partition
#      before the extended one that contains it and abandoned the whole write
#      with "Extended partition does not exists. Failed to add logical
#      partition." That killed capture (the shrink step applies a resized
#      table) before a single byte was uploaded.
#
#   2. EBR room between logicals. Each logical partition is introduced by an
#      EBR sector living in the gap immediately before it. fill_disk() reserved
#      MIN_START per logical in its fixed-space budget but never spent it when
#      assigning starts, so the fill packed logicals end to end and sfdisk hit
#      "No free sectors available".
#
#   3. The extended partition is a container, not data. Its size has to be
#      derived from where its logicals land. Scaling it proportionally like a
#      data partition (what fill_disk used to do) walked its end past the end
#      of the disk on any grow-to-fit deploy.
#
# Mechanism mirrors tests/checks/fill-engine.sh: source a sandbox copy of
# partition-funcs.sh with the awk path rewritten to the in-tree script, and
# PATH-shadow blockdev with a deterministic stub. Where a real sfdisk is
# available the computed table is additionally applied to a sparse file, which
# is the only assertion that proves sfdisk itself accepts the layout.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/partition-funcs.sh ]] || { echo "ERROR: cannot find partition-funcs.sh under $REPO_LIB" >&2; exit 2; }
[[ -f $REPO_LIB/procsfdisk.awk ]] || { echo "ERROR: cannot find procsfdisk.awk under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

REALAWK="$REPO_LIB/procsfdisk.awk"
sed -e "s#/usr/share/fog/lib/procsfdisk\.awk#awk -f $REALAWK#g" \
    "$REPO_LIB/partition-funcs.sh" > "$SANDBOX/partition-funcs.sh"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/blockdev" <<'EOF'
#!/bin/bash
case "$1" in
    --getsz)   printf '%s\n' "$FAKE_GETSZ" ;;
    --getss)   printf '%s\n' "$FAKE_GETSS" ;;
    --getpbsz) printf '%s\n' "$FAKE_GETPBSZ" ;;
esac
exit 0
EOF
chmod +x "$STUBBIN/blockdev"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ -n $2 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# --- parse helpers over $OUT (the emitted "sfdisk -d" table) ---
pstart() { printf '%s\n' "$OUT" | sed -n "s#^$1 : start= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
psize()  { printf '%s\n' "$OUT" | sed -n "s#^$1 : .*size= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
pend()   { echo $(( $(pstart "$1") + $(psize "$1") )); }
# The partition numbers of the emitted lines, in emission order.
porder() { printf '%s\n' "$OUT" | sed -n 's#^/dev/sda\([0-9]\{1,\}\) : .*#\1#p' | tr '\n' ' '; }

# run_proc <dumpfile> <action> <target> <sizePos> <getsz> <fixed> -- drive the real
# processSfdisk; leaves the emitted table in $OUT and its exit status in $RC.
run_proc() {
    local dump="$1" action="$2" target="$3" sizepos="$4" getsz="$5" fixed="$6"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export FAKE_GETSZ="$getsz" FAKE_GETSS=512 FAKE_GETPBSZ=512
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        handleWarning() { :; }
        getPartBlockSize() { printf -v "$2" '%s' 512; }
        runPartprobe() { :; }
        majorDebugEcho() { :; }; majorDebugPause() { :; }; majorDebugShowCurrentPartitionTable() { :; }
        ismajordebug=0
        disk="/dev/sda"                        # processSfdisk reads the global $disk
        processSfdisk "$dump" "$action" "$target" "$sizepos" "$fixed" "$dump"
    )"
    RC=$?
}

# apply_for_real <name> -- write $OUT to a sparse file with a real sfdisk. Proves
# the layout is one sfdisk will actually accept, which is the failure the issue
# reported. Skipped where sfdisk or a sparse file is unavailable.
apply_for_real() {
    local name="$1" sectors="$2" img="$SANDBOX/apply.img" out
    if ! command -v sfdisk >/dev/null 2>&1 || ! command -v truncate >/dev/null 2>&1; then
        skip "$name (no sfdisk/truncate on this host)"
        return
    fi
    rm -f "$img"
    if ! truncate -s $(( sectors * 512 )) "$img" 2>/dev/null; then
        skip "$name (cannot create a sparse file in $SANDBOX)"
        return
    fi
    # Retarget the table at the image file and drop the awk's "# ..." commentary,
    # which sfdisk would report as an unknown script header.
    printf '%s\n' "$OUT" | grep -v '^#' | sed "s#/dev/sda#$img#g" > "$SANDBOX/apply.table"
    out="$(sfdisk "$img" < "$SANDBOX/apply.table" 2>&1)"
    local rc=$?
    rm -f "$img"
    if [[ $rc -eq 0 && $out != *"Failed to add"* && $out != *"Leaving."* ]]; then
        pass "$name (real sfdisk accepted the table)"
    else
        fail "$name" "sfdisk rc=$rc: $(printf '%s' "$out" | grep -iE 'fail|error|leaving' | tr '\n' '|')"
    fi
}

# The layout from issue #150: three primaries (the third an LBA extended) plus
# six logicals, ten partitions in total on an 80 GiB disk.
DISK80=167772160
cat > "$SANDBOX/d.ext" <<'EOF'
label: dos
label-id: 0xc4eae1bb
device: /dev/sda
unit: sectors
sector-size: 512

/dev/sda1 : start=        2048, size=     2097152, type=b
/dev/sda2 : start=     2099200, size=     4194304, type=83
/dev/sda3 : start=     6293504, size=   161478656, type=f
/dev/sda5 : start=     6295552, size=    21116928, type=83
/dev/sda6 : start=    27414528, size=    50223104, type=83
/dev/sda7 : start=    77639680, size=    19529728, type=83
/dev/sda8 : start=    97171456, size=     9762816, type=83
/dev/sda9 : start=   106936320, size=    11616256, type=83
/dev/sda10 : start=   118554624, size=    49217536, type=83
EOF

# ---------------------------------------------------------------------------
# 1. Capture path (resize). The shrink step writes the resized table back to the
#    source disk, so its emission order is what actually broke the upload.
run_proc "$SANDBOX/d.ext" resize /dev/sda6 10000000 "$DISK80" ""
if [[ $RC -eq 0 && "$(porder)" == "1 2 3 5 6 7 8 9 10 " ]]; then
    pass "resize emits ascending partition numbers (extended before its logicals)"
else
    fail "resize emission order" "rc=$RC order='$(porder)'
$OUT"
fi
apply_for_real "resize output applies to a real disk" "$DISK80"

# 2. The resize itself still lands on the requested partition, and only on it.
#    10000000 bytes is not a whole number of 512-byte sectors, and the byte ->
#    sector conversion rounds UP (ADR-0016): the filesystem has already been
#    shrunk to that byte size, so flooring would leave the partition smaller
#    than the filesystem inside it. Hence (bytes + 511) / 512, not bytes / 512.
WANTSDA6=$(( (10000000 + 511) / 512 ))
if [[ $(psize /dev/sda6) -eq $WANTSDA6 && $(psize /dev/sda5) -eq 21116928 \
      && $(psize /dev/sda10) -eq 49217536 ]]; then
    pass "resize shrinks only the target logical partition"
else
    fail "resize target" "sda6=$(psize /dev/sda6) (want $WANTSDA6) sda5=$(psize /dev/sda5) sda10=$(psize /dev/sda10)"
fi

# ---------------------------------------------------------------------------
# check_extended_layout -- shared assertions for a filled table: emission order,
# every logical inside the container, the container ending exactly at the last
# logical, an EBR gap before every logical, and nothing past the end of the disk.
check_extended_layout() {
    local name="$1" disksize="$2"
    local errs="" prev_end=0 n last_end=0
    [[ "$(porder)" == "1 2 3 5 6 7 8 9 10 " ]] || errs="$errs order='$(porder)';"
    local ext_start=$(pstart /dev/sda3) ext_end=$(pend /dev/sda3)
    for n in 5 6 7 8 9 10; do
        local s=$(pstart "/dev/sda$n") e=$(pend "/dev/sda$n")
        [[ $s -ge $ext_start && $e -le $ext_end ]] || errs="$errs sda$n ($s-$e) outside extended ($ext_start-$ext_end);"
        # Every logical needs at least one free sector before it for its EBR:
        # the first inside the container, the rest after the previous logical.
        local floor=$ext_start
        [[ $prev_end -gt 0 ]] && floor=$prev_end
        [[ $s -gt $floor ]] || errs="$errs sda$n start $s leaves no EBR room after $floor;"
        prev_end=$e
        last_end=$e
    done
    [[ $ext_end -eq $last_end ]] || errs="$errs extended ends $ext_end, last logical ends $last_end;"
    [[ $ext_end -le $disksize ]] || errs="$errs extended ends $ext_end past disk $disksize;"
    if [[ $RC -eq 0 && $OUT == *"consistent"* && $OUT != *ERROR* && -z $errs ]]; then
        pass "$name"
    else
        fail "$name" "rc=$RC $errs
$OUT"
    fi
}

# 3. Deploy onto a larger disk: everything grows to fit and the container follows.
DISK120=251658240
run_proc "$SANDBOX/d.ext" filldisk /dev/sda "$DISK120" "$DISK120" "1"
check_extended_layout "filldisk onto a larger disk keeps a usable extended layout" "$DISK120"
apply_for_real "filldisk (larger disk) output applies to a real disk" "$DISK120"

# 4. Deploy onto an identical disk: the source layout has to come back intact.
run_proc "$SANDBOX/d.ext" filldisk /dev/sda "$DISK80" "$DISK80" "1"
check_extended_layout "filldisk onto an identical disk keeps a usable extended layout" "$DISK80"
if [[ $(pstart /dev/sda5) -eq 6295552 && $(psize /dev/sda5) -eq 21116928 \
      && $(pstart /dev/sda10) -eq 118554624 && $(psize /dev/sda10) -eq 49217536 ]]; then
    pass "filldisk onto an identical disk reproduces the captured logical partitions"
else
    fail "filldisk identical-disk fidelity" "sda5=$(pstart /dev/sda5)+$(psize /dev/sda5) sda10=$(pstart /dev/sda10)+$(psize /dev/sda10)"
fi
apply_for_real "filldisk (identical disk) output applies to a real disk" "$DISK80"

# 5. Deploy onto a disk the image cannot fit: abort rather than write a table
#    whose partitions run off the end (ADR-0003).
DISK40=83886080
run_proc "$SANDBOX/d.ext" filldisk /dev/sda "$DISK40" "$DISK40" "1"
if [[ $RC -ne 0 && $OUT == *ERROR* ]]; then
    pass "filldisk onto a too-small disk exits non-zero instead of emitting a bad table"
else
    fail "filldisk too-small disk should fail loud" "rc=$RC
$OUT"
fi

# ---------------------------------------------------------------------------
# 6. The nine-partition case that always worked must keep working -- this is the
#    layout gawk's hash order happened to emit in the right sequence, so it is
#    the regression guard for the ordering change.
cat > "$SANDBOX/d.ext9" <<'EOF'
label: dos
label-id: 0xc4eae1bb
device: /dev/sda
unit: sectors
sector-size: 512

/dev/sda1 : start=        2048, size=     2097152, type=b
/dev/sda2 : start=     2099200, size=     4194304, type=83
/dev/sda3 : start=     6293504, size=   161478656, type=f
/dev/sda5 : start=     6295552, size=    21116928, type=83
/dev/sda6 : start=    27414528, size=    50223104, type=83
/dev/sda7 : start=    77639680, size=    19529728, type=83
/dev/sda8 : start=    97171456, size=     9762816, type=83
/dev/sda9 : start=   106936320, size=    60835840, type=83
EOF
run_proc "$SANDBOX/d.ext9" resize /dev/sda6 10000000 "$DISK80" ""
if [[ $RC -eq 0 && "$(porder)" == "1 2 3 5 6 7 8 9 " ]]; then
    pass "nine-partition extended layout still emits in order"
else
    fail "nine-partition emission order" "rc=$RC order='$(porder)'
$OUT"
fi
apply_for_real "nine-partition resize output applies to a real disk" "$DISK80"

# ---------------------------------------------------------------------------
# 7. Containment backstop. check_overlap() is meant to reject a logical
#    partition that does not sit wholly inside its extended container, but the
#    test was guarded on the container's own partition number being > 4 -- which
#    an extended partition, always a primary, never is. With the guard fixed, a
#    resize that would push a logical past the end of its container is refused
#    (resize_partition leaves the size alone) instead of being emitted.
cat > "$SANDBOX/d.small" <<'EOF'
label: dos
label-id: 0xc4eae1bb
device: /dev/sda
unit: sectors
sector-size: 512

/dev/sda1 : start=        2048, size=     2097152, type=b
/dev/sda3 : start=     6293504, size=    20000000, type=f
/dev/sda5 : start=     6295552, size=    10000000, type=83
EOF
# 20000000 * 512 requested for sda5 -> 20000000 sectors, ending 26295552, which
# is 2048 sectors past the container's end (6293504 + 20000000 = 26293504).
run_proc "$SANDBOX/d.small" resize /dev/sda5 $(( 20000000 * 512 )) "$DISK80" ""
if [[ $(psize /dev/sda5) -eq 10000000 ]]; then
    pass "resize past the end of the extended container is refused"
else
    fail "extended containment backstop" "sda5 size=$(psize /dev/sda5) (expected the original 10000000)
$OUT"
fi

# A resize that stays inside the container is still allowed.
run_proc "$SANDBOX/d.small" resize /dev/sda5 $(( 15000000 * 512 )) "$DISK80" ""
if [[ $(psize /dev/sda5) -eq 15000000 ]]; then
    pass "resize that stays inside the extended container is allowed"
else
    fail "in-container resize" "sda5 size=$(psize /dev/sda5) (expected 15000000)
$OUT"
fi

# ---------------------------------------------------------------------------
# The extended partition is a container, not content (funcs.sh).
#
# Linux exposes an extended partition as the 1 KB EBR window at the front of the
# container, so anything written there lands on the EBR chain. savePartition
# used to reach it: an extended partition has no FS_TYPE, fsTypeSetting resolves
# that to "imager", and the imager branch matched before the extended-partition
# branch further down -- so the container was captured as a d<disk>p<part>.img
# and restorePartition wrote it back over the chain sfdisk had just built,
# taking every logical partition after the first with it.
#
# These cases drive the real savePartition/restorePartition out of funcs.sh with
# blkid stubbed to describe an extended partition (no FS_TYPE, PART_ENTRY_TYPE
# 0xf) and partclone stubbed to record any invocation.
# ---------------------------------------------------------------------------

FUNCS_OK=1
[[ -f $REPO_LIB/funcs.sh ]] || FUNCS_OK=0
if [[ $FUNCS_OK -eq 0 ]]; then
    skip "funcs.sh extended-partition cases (funcs.sh not found)"
else
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"
cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"

CALLS="$SANDBOX/calls"
IMGDIR="$SANDBOX/img"
mkdir -p "$IMGDIR"

# blkid: fsTypeSetting reads FS_TYPE, getPartType reads PART_ENTRY_TYPE. The map
# pairs a device with "<fstype-or-none> <parttype>"; "none" emits no FS_TYPE at
# all, which is what a real extended partition looks like.
cat > "$STUBBIN/blkid" <<'EOF'
#!/bin/bash
for last in "$@"; do :; done
fs=$(awk -v d="$last" '$1==d {print $2}' "$SANDBOX/blkid.map")
pt=$(awk -v d="$last" '$1==d {print $3}' "$SANDBOX/blkid.map")
[[ -n $fs && $fs != none ]] && echo "ID_FS_TYPE=$fs"
[[ -n $pt ]] && echo "ID_PART_ENTRY_TYPE=$pt"
exit 0
EOF
chmod +x "$STUBBIN/blkid"

for pc in partclone.extfs partclone.imager partclone.restore; do
    cat > "$STUBBIN/$pc" <<'EOF'
#!/bin/bash
echo "${0##*/} $*" >> "$CALLS"
out=""; prev=""
for a in "$@"; do [[ $prev == "-O" ]] && out="$a"; prev="$a"; done
[[ -n $out ]] && echo "IMGDATA" > "$out"
exit 0
EOF
    chmod +x "$STUBBIN/$pc"
done

printf '/dev/sda3 none 0xf\n/dev/sda6 ext4 0x83\n' > "$SANDBOX/blkid.map"

# run_funcs <shell snippet> -- source the sandboxed funcs.sh and evaluate it,
# leaving the recorded external calls in $CALLS and the output in $OUT.
run_funcs() {
    : > "$CALLS"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX CALLS
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        # Record rather than perform the two things a partition restore does.
        writeImage() { echo "writeImage $*" >> "$CALLS"; }
        runPartprobe() { :; }
        uploadFormat() { :; }
        getServerDiskSpaceAvailable() { echo "lots"; }
        imgFormat=5; imgPartitionType="all"; imgType="n"; osid=50
        storage="STUBSTORE"; img="STUBIMG"
        eval "$1"
        echo "RETURNED"
    )"
}

# 8. Capture: the container gets a sidecar, and partclone is never invoked on it.
run_funcs 'savePartition /dev/sda3 1 "'"$IMGDIR"'"'
if [[ $OUT == *"Not capturing content of extended partition"* ]] \
   && [[ -e $IMGDIR/d1p3.ebr ]] && ! grep -q "^partclone" "$CALLS" 2>/dev/null; then
    pass "savePartition writes only the EBR sidecar for an extended partition"
else
    fail "savePartition on an extended partition" "ebr=$([[ -e $IMGDIR/d1p3.ebr ]] && echo yes || echo no) calls='$(tr '\n' '|' < "$CALLS")' out=$(tr '\n' '|' <<<"$OUT")"
fi

# 9. A real filesystem on a logical partition still goes through partclone.
run_funcs 'savePartition /dev/sda6 1 "'"$IMGDIR"'"'
if grep -q "^partclone.extfs" "$CALLS" 2>/dev/null; then
    pass "savePartition still captures a logical ext partition with partclone"
else
    fail "savePartition on a normal logical partition" "calls='$(tr '\n' '|' < "$CALLS")'"
fi

# 10. Deploy: an image that still carries a d1p3.img for the container -- every
#     image captured before this fix does -- must not have it written back.
: > "$IMGDIR/d1p3.img"
run_funcs 'restorePartition /dev/sda3 1 "'"$IMGDIR"'" ""'
if [[ $OUT == *"Not deploying content of extended partition"* ]] \
   && ! grep -q "^writeImage" "$CALLS" 2>/dev/null; then
    pass "restorePartition refuses to write an image into an extended partition"
else
    fail "restorePartition on an extended partition" "calls='$(tr '\n' '|' < "$CALLS")' out=$(tr '\n' '|' <<<"$OUT")"
fi

# 11. A normal partition still gets its image written.
: > "$IMGDIR/d1p6.img"
run_funcs 'restorePartition /dev/sda6 1 "'"$IMGDIR"'" ""'
if grep -q "^writeImage .*d1p6.img" "$CALLS" 2>/dev/null; then
    pass "restorePartition still writes the image for a logical partition"
else
    fail "restorePartition on a normal logical partition" "calls='$(tr '\n' '|' < "$CALLS")'"
fi
fi

echo "----"
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
