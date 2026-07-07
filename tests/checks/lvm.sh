#!/bin/bash
#
# Assertion harness for the LVM per-LV capture/deploy and resize paths in
# funcs.sh (docs/adr/0004, docs/adr/0006): saveLVMPartition,
# restoreLVMPartition, shrinkLVMPartition, expandLVMPartition,
# growLVMPartition, rebuildLVMPartition, applyLVMMinimumSizes, and the
# dispatch points that route an LVM2_member partition into them.
#
#   tests/checks/lvm.sh        # run all cases, exit non-zero on any failure
#
# Mechanism mirrors tests/checks/sector-size.sh: source a sandbox copy of the
# library with its hardcoded paths rewritten, and PATH-shadow every external
# tool (pvs/vgs/lvs/vgchange/partclone/...) with deterministic stubs that log
# their invocations to a calls file. handleError is overridden AFTER sourcing
# to echo "ABORT:" and exit the case subshell, so a refusal is observable.
#
# The LV device paths /dev/<vg>/<lv> are rewritten to live under the sandbox
# so the -e existence checks can be satisfied with plain files, no root needed.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- sandbox copy of the library with host-absolute paths rewritten ---
cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    -e "s#lvdev=\"/dev/#lvdev=\"$SANDBOX/dev/#g" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"
# The lvdev rewrite is what lets LV existence checks pass without root; if the
# source stops matching it, every case below would silently test nothing.
# (shrinkLVMPartition, expandLVMPartition, saveLVMPartition, restoreLVMPartition)
rewrites=$(grep -c "lvdev=\"$SANDBOX/dev/" "$SANDBOX/funcs.sh")
[[ $rewrites -eq 4 ]] || { echo "ERROR: expected 4 lvdev rewrites, got $rewrites (funcs.sh changed shape?)" >&2; exit 2; }

# --- deterministic stubs for the external tools (via PATH) ---
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# pvs/vgs/lvs report the fake topology from FAKE_* environment knobs; each
# stub answers based on the field requested with -o, like the real tool.
cat > "$STUBBIN/pvs" <<'EOF'
#!/bin/bash
echo "pvs $*" >> "$CALLS"
prev=""; field=""
for a in "$@"; do [[ $prev == "-o" ]] && field="$a"; prev="$a"; done
case $field in
    vg_name) echo "  $FAKE_VG" ;;
    pv_uuid) echo "  $FAKE_PVUUID" ;;
    pv_size) echo "  $FAKE_PVSIZE" ;;
    pe_start) echo "  $FAKE_PESTART" ;;
esac
exit 0
EOF
cat > "$STUBBIN/vgs" <<'EOF'
#!/bin/bash
echo "vgs $*" >> "$CALLS"
prev=""; field=""
for a in "$@"; do [[ $prev == "-o" ]] && field="$a"; prev="$a"; done
case $field in
    pv_count) echo "  $FAKE_PVCOUNT" ;;
    vg_uuid) echo "  $FAKE_VGUUID" ;;
    vg_extent_size) echo "  $FAKE_EXTENT" ;;
    vg_free_count) echo "  $FAKE_FREE" ;;
esac
exit 0
EOF
cat > "$STUBBIN/lvs" <<'EOF'
#!/bin/bash
echo "lvs $*" >> "$CALLS"
prev=""; field=""
for a in "$@"; do [[ $prev == "-o" ]] && field="$a"; prev="$a"; done
case $field in
    lv_layout) printf '%s\n' "$FAKE_LAYOUTS" ;;
    lv_name,lv_uuid,lv_size) printf '%s\n' "$FAKE_LVS" ;;
    lv_name,lv_size) printf '%s\n' "$FAKE_LVS" | awk '{print "  "$1" "$3}' ;;
    lv_name) printf '%s\n' "$FAKE_LVS" | awk '{print "  "$1}' ;;
esac
exit 0
EOF

# blkid: fsTypeSetting and the swap-UUID reader key off "FS_TYPE="/"FS_UUID="
# lines; the map file pairs a device path with its filesystem type.
cat > "$STUBBIN/blkid" <<'EOF'
#!/bin/bash
echo "blkid $*" >> "$CALLS"
for last in "$@"; do :; done
fs=$(awk -v d="$last" '$1==d {print $2}' "$SANDBOX/blkid.map")
[[ -n $fs ]] && echo "ID_FS_TYPE=$fs"
[[ $fs == swap ]] && echo "ID_FS_UUID=$FAKE_SWAPUUID"
exit 0
EOF

# partclone capture doubles: write a marker through the -O fifo so the real
# uploadFormat pipeline (with zstdmt stubbed to cat) produces a real file.
for pc in partclone.extfs partclone.imager; do
    cat > "$STUBBIN/$pc" <<'EOF'
#!/bin/bash
me="${0##*/}"
echo "$me $*" >> "$CALLS"
out=""; prev=""
for a in "$@"; do [[ $prev == "-O" ]] && out="$a"; prev="$a"; done
[[ -n $out ]] && echo "IMGDATA" > "$out"
exit 0
EOF
done

# partclone.restore must drain stdin or the writeImage pipeline dies on SIGPIPE.
cat > "$STUBBIN/partclone.restore" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "partclone.restore $*" >> "$CALLS"
exit 0
EOF

# zstdmt passes data through unchanged in both directions (compress at capture,
# -dc at restore), so image files hold the partclone stub's marker verbatim.
printf '#!/bin/bash\nexec cat\n' > "$STUBBIN/zstdmt"

cat > "$STUBBIN/vgcfgbackup" <<'EOF'
#!/bin/bash
echo "vgcfgbackup $*" >> "$CALLS"
out=""; prev=""
for a in "$@"; do [[ $prev == "-f" ]] && out="$a"; prev="$a"; done
[[ -n $out ]] && echo "# fake vgcfg backup" > "$out"
exit 0
EOF

# getPartitions consumer (getValidRestorePartitions cases): one fake partition.
cat > "$STUBBIN/lsblk" <<'EOF'
#!/bin/bash
echo "lsblk $*" >> "$CALLS"
echo "/dev/sdb3 part"
exit 0
EOF

# resize2fs: -P reports the fake minimum block count, everything else is a
# logged no-op (the shrink/expand calls themselves).
cat > "$STUBBIN/resize2fs" <<'EOF'
#!/bin/bash
echo "resize2fs $*" >> "$CALLS"
for a in "$@"; do
    [[ $a == "-P" ]] && { echo "Estimated minimum size of the filesystem: $FAKE_EXTMIN"; break; }
done
exit 0
EOF

# dumpe2fs -h: only the block-size line matters to shrinkLVMPartition.
cat > "$STUBBIN/dumpe2fs" <<'EOF'
#!/bin/bash
echo "dumpe2fs $*" >> "$CALLS"
echo "Block size:               $FAKE_BLOCKSIZE"
exit 0
EOF

# blockdev --getsz is how restoreLVMPartition sizes the deploy target.
cat > "$STUBBIN/blockdev" <<'EOF'
#!/bin/bash
echo "blockdev $*" >> "$CALLS"
[[ $1 == "--getsz" ]] && echo "$FAKE_PARTSIZE"
exit 0
EOF

# lvcreate creates the LV device node like the real tool would, so the
# restore loop's -e existence check only passes if the rebuild ran first.
cat > "$STUBBIN/lvcreate" <<'EOF'
#!/bin/bash
echo "lvcreate $*" >> "$CALLS"
name=""; prev=""; vg=""
for a in "$@"; do [[ $prev == "-n" ]] && name="$a"; prev="$a"; vg="$a"; done
[[ -n $name && -n $vg ]] && { mkdir -p "$SANDBOX/dev/$vg"; touch "$SANDBOX/dev/$vg/$name"; }
exit 0
EOF

# Log-and-succeed doubles for everything else the paths shell out to.
for tool in vgscan vgchange pvcreate vgcfgrestore pvresize lvextend vgcreate \
            e2fsck wipefs mkswap udevadm umount usleep; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$tool" > "$STUBBIN/$tool"
done
chmod +x "$STUBBIN"/*

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
dump_out() { echo "      out: $(printf '%s' "$OUT" | tr '\n' '|')"; }

assert_out() { [[ $OUT == *"$2"* ]] && ok "$1" || { ko "$1 (output missing: $2)"; dump_out; }; }
assert_not_out() { [[ $OUT != *"$2"* ]] && ok "$1" || { ko "$1 (output should not contain: $2)"; dump_out; }; }
assert_file() { [[ -f $2 ]] && ok "$1" || ko "$1 (missing file: $2)"; }
assert_no_file() { [[ ! -e $2 ]] && ok "$1" || ko "$1 (file should not exist: $2)"; }
# Passes if one logged tool invocation contains every needle.
assert_call() {
    local name="$1" line n hit=0
    shift
    while IFS= read -r line; do
        hit=1
        for n in "$@"; do [[ $line == *"$n"* ]] || { hit=0; break; }; done
        [[ $hit -eq 1 ]] && break
    done < "$CALLS"
    [[ $hit -eq 1 ]] && ok "$name" || ko "$name (no logged call matching: $*)"
}
assert_no_call() { ! grep -qF "$2" "$CALLS" 2>/dev/null && ok "$1" || ko "$1 (unexpected call: $2)"; }

# Fresh image dir, calls log, fake /dev tree, and a supported default topology
# (single-PV VG "fakevg" with a linear ext4 root and a swap LV) per case.
# The default sizes give exact integer arithmetic everywhere: extent size
# 8192 sectors (4 MiB), root 20971520 (10 GiB), swap 4194304 (2 GiB),
# PV 41940992 (~20 GiB), pe_start 2048; the minimum ext root is 262144
# 4 KiB blocks (1 GiB), which at percent=25 shrinks to exactly 2621440
# sectors (320 extents).
new_case() {
    IMGDIR="$SANDBOX/img.$1"
    rm -rf "$IMGDIR"
    mkdir -p "$IMGDIR"
    CALLS="$IMGDIR/calls.log"
    : > "$CALLS"
    rm -rf "$SANDBOX/dev"
    mkdir -p "$SANDBOX/dev/fakevg"
    : > "$SANDBOX/blkid.map"
    rm -f /tmp/pigz1 /tmp/sdb3.lvmmin /tmp/lvmmindump.tmp
    FAKE_VG="fakevg"
    FAKE_PVUUID="PVUUID-test"
    FAKE_PVSIZE="41940992.00"
    FAKE_PVCOUNT="1"
    FAKE_VGUUID="VGUUID-test"
    FAKE_EXTENT="8192.00"
    FAKE_PESTART="2048.00"
    FAKE_LAYOUTS=$'  linear\n  linear'
    FAKE_LVS=$'  root ROOT-uuid 20971520.00\n  swap_1 SWAP-uuid 4194304.00'
    FAKE_SWAPUUID="SWAPUUID-test"
    FAKE_PARTSIZE="41940992"
    FAKE_FREE="0"
    FAKE_EXTMIN="262144"
    FAKE_BLOCKSIZE="4096"
}

# Standard supported-source fixtures on top of new_case.
lvm_source() {
    printf '%s ext4\n%s swap\n%s LVM2_member\n' \
        "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/swap_1" /dev/sdb3 > "$SANDBOX/blkid.map"
    touch "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/swap_1"
}

# A captured image set in $IMGDIR as an older (Phase 1, format 1) FOS left it:
# no minimum-size columns.
lvm_image() {
    cat > "$IMGDIR/d1p3.lvm" <<'SIDE'
LVMFORMAT 1
PV PVUUID-test /dev/sdb3 41940992
VG fakevg VGUUID-test 8192
LV root ROOT-uuid 20971520 extfs d1p3.root.img -
LV swap_1 SWAP-uuid 4194304 swap - SWAPUUID-test
SIDE
    echo "# fake vgcfg backup" > "$IMGDIR/d1p3.lvm.vgcfg"
    echo "IMGDATA" > "$IMGDIR/d1p3.root.img"
    touch "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/swap_1"
}

# A captured image set as a current (format 2) capture with a shrunken root
# and home leaves it. Minimum extents: root 320, home 128, swap 512; PV
# minimum = 2048 + (320+128+512+1)*8192 = 7874560 sectors.
lvm_image2() {
    cat > "$IMGDIR/d1p3.lvm" <<'SIDE'
LVMFORMAT 2
PV PVUUID-test /dev/sdb3 41940992 7874560
VG fakevg VGUUID-test 8192
LV root ROOT-uuid 20971520 2621440 extfs d1p3.root.img -
LV home HOME-uuid 8388608 1048576 extfs d1p3.home.img -
LV swap_1 SWAP-uuid 4194304 4194304 swap - SWAPUUID-test
SIDE
    echo "# fake vgcfg backup" > "$IMGDIR/d1p3.lvm.vgcfg"
    echo "IMGDATA" > "$IMGDIR/d1p3.root.img"
    echo "IMGDATA" > "$IMGDIR/d1p3.home.img"
    touch "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/home" "$SANDBOX/dev/fakevg/swap_1"
}

# Run $1 with the library sourced and the imaging globals a deploy/capture
# would have. handleError is overridden AFTER sourcing so a refusal prints
# ABORT and ends only the case subshell.
run() {
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX CALLS
        export FAKE_VG FAKE_PVUUID FAKE_PVSIZE FAKE_PVCOUNT FAKE_VGUUID FAKE_EXTENT
        export FAKE_LAYOUTS FAKE_LVS FAKE_SWAPUUID
        export FAKE_PESTART FAKE_PARTSIZE FAKE_FREE FAKE_EXTMIN FAKE_BLOCKSIZE
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        imgFormat=5
        imgPartitionType="all"
        imgType="n"
        osid=50
        storage="STUBSTORE"
        img="STUBIMG"
        percent=25
        eval "$1"
        echo "RETURNED"
    )"
}

# ============================================================
# Detection
# ============================================================

# 1. An LVM2 PV maps to fstype "lvm"...
new_case 1
echo "/dev/sdb3 LVM2_member" > "$SANDBOX/blkid.map"
run 'fsTypeSetting /dev/sdb3; echo "FSTYPE=$fstype"'
assert_out "LVM2_member maps to fstype lvm" "FSTYPE=lvm"

# 2. ...unless skiplvm=1 reverts it to the raw-blob imager path.
new_case 2
echo "/dev/sdb3 LVM2_member" > "$SANDBOX/blkid.map"
run 'skiplvm=1; fsTypeSetting /dev/sdb3; echo "FSTYPE=$fstype"'
assert_out "skiplvm=1 maps LVM2_member to imager" "FSTYPE=imager"

# ============================================================
# Capture
# ============================================================

# 3. Supported topology through the real savePartition dispatch: exact sidecar
# schema, vgcfg backup, one image per non-swap LV, swap recorded not imaged,
# no raw d1p3.img, VG left deactivated. With no minfile (non-resizable
# capture) every minimum column defaults to the original size.
new_case 3
lvm_source
run 'savePartition /dev/sdb3 1 "$IMGDIR"'
assert_out "capture completes" "RETURNED"
cat > "$SANDBOX/expected.lvm" <<'SIDE'
LVMFORMAT 2
PV PVUUID-test /dev/sdb3 41940992 41940992
VG fakevg VGUUID-test 8192
LV root ROOT-uuid 20971520 20971520 extfs d1p3.root.img -
LV swap_1 SWAP-uuid 4194304 4194304 swap - SWAPUUID-test
SIDE
if diff -u "$SANDBOX/expected.lvm" "$IMGDIR/d1p3.lvm"; then
    ok "sidecar schema is byte-exact"
else
    ko "sidecar schema differs (see diff above)"
fi
assert_file "vgcfg backup written" "$IMGDIR/d1p3.lvm.vgcfg"
assert_file "root LV image written" "$IMGDIR/d1p3.root.img"
assert_no_file "swap LV not imaged" "$IMGDIR/d1p3.swap_1.img"
assert_no_file "no raw PV blob on supported topology" "$IMGDIR/d1p3.img"
assert_call "root LV captured with partclone.extfs" "partclone.extfs" "$SANDBOX/dev/fakevg/root"
assert_call "VG activated for capture" "vgchange -ay fakevg"
assert_call "VG deactivated after capture" "vgchange -an fakevg"

# 4. PV without a VG: fall back to the raw imager blob, loudly.
new_case 4
FAKE_VG=""
run 'saveLVMPartition /dev/sdb3 1 "$IMGDIR"'
assert_out "no-VG capture falls back" "Falling back to raw capture"
assert_file "no-VG fallback writes raw blob" "$IMGDIR/d1p3.img"
assert_no_file "no-VG fallback writes no sidecar" "$IMGDIR/d1p3.lvm"
assert_call "no-VG fallback captures the PV raw" "partclone.imager" "/dev/sdb3"

# 5. VG spanning multiple PVs: fall back.
new_case 5
FAKE_PVCOUNT="2"
run 'saveLVMPartition /dev/sdb3 1 "$IMGDIR"'
assert_out "multi-PV capture falls back" "spans 2 physical volumes"
assert_file "multi-PV fallback writes raw blob" "$IMGDIR/d1p3.img"
assert_no_file "multi-PV fallback writes no sidecar" "$IMGDIR/d1p3.lvm"

# 6. Non-linear LV (thin pool): fall back.
new_case 6
FAKE_LAYOUTS=$'  linear\n  thin,pool'
run 'saveLVMPartition /dev/sdb3 1 "$IMGDIR"'
assert_out "non-linear capture falls back" "non-linear"
assert_file "non-linear fallback writes raw blob" "$IMGDIR/d1p3.img"
assert_no_file "non-linear fallback writes no sidecar" "$IMGDIR/d1p3.lvm"

# 7. A PV nested inside an LV is captured raw per-LV (imager), not recursed into.
new_case 7
FAKE_LVS="  data DATA-uuid 8388608.00"
printf '%s LVM2_member\n' "$SANDBOX/dev/fakevg/data" > "$SANDBOX/blkid.map"
touch "$SANDBOX/dev/fakevg/data"
run 'saveLVMPartition /dev/sdb3 1 "$IMGDIR"'
assert_out "nested-PV capture completes" "RETURNED"
assert_call "nested PV captured with imager" "partclone.imager" "$SANDBOX/dev/fakevg/data"
assert_out_line=$(grep "^LV data" "$IMGDIR/d1p3.lvm" 2>/dev/null)
[[ $assert_out_line == "LV data DATA-uuid 8388608 8388608 imager d1p3.data.img -" ]] \
    && ok "nested PV recorded as imager in sidecar" \
    || ko "nested PV sidecar line wrong: '$assert_out_line'"

# ============================================================
# Capture-side shrink (resizable images, docs/adr/0006)
# ============================================================

# 15. Shrink through the real shrinkPartition dispatch: the ext LV's
# filesystem is shrunk and the minfile records the per-LV and PARTMIN
# minimums. root: 262144 blocks * 4096 = 1 GiB, +25% slack = 2621440
# sectors; swap is not shrinkable so it keeps 4194304; PARTMIN =
# 2048 + (320+512+1)*8192 = 6825984.
new_case 15
lvm_source
run 'imagePath="$IMGDIR"; shrinkPartition /dev/sdb3 "$IMGDIR/fstypes" ""'
assert_out "shrink completes" "RETURNED"
assert_call "ext LV checked before shrink" "e2fsck" "$SANDBOX/dev/fakevg/root"
assert_call "ext LV filesystem shrunk" "resize2fs" "$SANDBOX/dev/fakevg/root" "-M"
assert_no_call "swap LV not shrunk" "resize2fs $SANDBOX/dev/fakevg/swap_1"
assert_call "VG activated for shrink" "vgchange -ay fakevg"
assert_call "VG deactivated after shrink" "vgchange -an fakevg"
cat > "$SANDBOX/expected.lvmmin" <<'MIN'
LV root 2621440
LV swap_1 4194304
PARTMIN 6825984
MIN
if diff -u "$SANDBOX/expected.lvmmin" /tmp/sdb3.lvmmin; then
    ok "minfile records exact per-LV and PARTMIN minimums"
else
    ko "minfile differs (see diff above)"
fi

# 16. Shrink then capture: the minfile's minimums land in the format-2
# sidecar's minimum columns, byte-exact.
new_case 16
lvm_source
run 'imagePath="$IMGDIR"; shrinkPartition /dev/sdb3 "$IMGDIR/fstypes" ""; savePartition /dev/sdb3 1 "$IMGDIR"'
assert_out "shrink+capture completes" "RETURNED"
cat > "$SANDBOX/expected.lvm" <<'SIDE'
LVMFORMAT 2
PV PVUUID-test /dev/sdb3 41940992 6825984
VG fakevg VGUUID-test 8192
LV root ROOT-uuid 20971520 2621440 extfs d1p3.root.img -
LV swap_1 SWAP-uuid 4194304 4194304 swap - SWAPUUID-test
SIDE
if diff -u "$SANDBOX/expected.lvm" "$IMGDIR/d1p3.lvm"; then
    ok "shrunken sidecar schema is byte-exact"
else
    ko "shrunken sidecar schema differs (see diff above)"
fi

# 17. Unsupported topology at shrink time: demoted to the fixed-size list
# (Phase 1 behavior), no minfile, no filesystem touched.
new_case 17
FAKE_VG=""
echo "/dev/sdb3 LVM2_member" > "$SANDBOX/blkid.map"
echo "1:2" > "$IMGDIR/d1.fixed_size_partitions"
run 'imagePath="$IMGDIR"; shrinkLVMPartition /dev/sdb3'
assert_out "unsupported topology is not shrunk" "Not shrinking (/dev/sdb3) trying fixed size"
assert_out "demotion names the cause" "no volume group found"
fixedlist=$(cat "$IMGDIR/d1.fixed_size_partitions" 2>/dev/null)
[[ $fixedlist == "1:2:3" ]] \
    && ok "PV partition demoted to the fixed-size list" \
    || ko "fixed-size list wrong: '$fixedlist'"
assert_no_file "no minfile for unsupported topology" /tmp/sdb3.lvmmin
assert_no_call "unsupported topology never resizes" "resize2fs"

# 18. applyLVMMinimumSizes rewrites only the PV partition's size in the
# minimum sfdisk dump (512-byte-sector dump: same unit as PARTMIN).
new_case 18
cat > /tmp/sdb3.lvmmin <<'MIN'
LV root 2621440
LV swap_1 4194304
PARTMIN 6825984
MIN
cat > "$IMGDIR/d1.minimum.partitions" <<'DUMP'
label: gpt
sector-size: 512

/dev/sdb1 : start=2048, size=1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/sdb3 : start=1050624, size=41940992, type=E6D6D379-F507-44C2-A23C-238F2A3DF928
DUMP
run 'applyLVMMinimumSizes /dev/sdb 1 "$IMGDIR"'
assert_out "minimum-dump rewrite completes" "RETURNED"
assert_out "rewrite is announced" "Recording LVM minimum size for (/dev/sdb3)"
grep -q "^/dev/sdb3 : start=1050624, size=6825984," "$IMGDIR/d1.minimum.partitions" \
    && ok "PV minimum size recorded in the dump" \
    || ko "PV line not rewritten: '$(grep sdb3 "$IMGDIR/d1.minimum.partitions")'"
grep -q "^/dev/sdb1 : start=2048, size=1048576," "$IMGDIR/d1.minimum.partitions" \
    && ok "other partitions left untouched" \
    || ko "sdb1 line changed: '$(grep sdb1 "$IMGDIR/d1.minimum.partitions")'"

# 19. Same rewrite on a 4096-byte-sector dump: PARTMIN is 512-byte sectors,
# the dump's size= is in its own logical sectors (6825984/8 = 853248).
new_case 19
cat > /tmp/sdb3.lvmmin <<'MIN'
PARTMIN 6825984
MIN
cat > "$IMGDIR/d1.minimum.partitions" <<'DUMP'
label: gpt
sector-size: 4096

/dev/sdb3 : start=131328, size=5242624, type=E6D6D379-F507-44C2-A23C-238F2A3DF928
DUMP
run 'applyLVMMinimumSizes /dev/sdb 1 "$IMGDIR"'
grep -q "^/dev/sdb3 : start=131328, size=853248," "$IMGDIR/d1.minimum.partitions" \
    && ok "PARTMIN converted to the dump's 4096-byte sectors" \
    || ko "4Kn PV line wrong: '$(grep sdb3 "$IMGDIR/d1.minimum.partitions")'"

# 20. No minfile (nothing was shrunk): the dump is left byte-identical.
new_case 20
cat > "$IMGDIR/d1.minimum.partitions" <<'DUMP'
label: gpt
sector-size: 512

/dev/sdb3 : start=1050624, size=41940992, type=E6D6D379-F507-44C2-A23C-238F2A3DF928
DUMP
cp "$IMGDIR/d1.minimum.partitions" "$SANDBOX/dump.before"
run 'applyLVMMinimumSizes /dev/sdb 1 "$IMGDIR"'
assert_out "no-minfile pass completes" "RETURNED"
assert_not_out "no rewrite announced without a minfile" "Recording LVM minimum size"
diff -q "$SANDBOX/dump.before" "$IMGDIR/d1.minimum.partitions" >/dev/null \
    && ok "dump untouched without a minfile" \
    || ko "dump changed without a minfile"

# ============================================================
# Deploy
# ============================================================

# 8. Full dispatch through restorePartition, format-1 image on a same-size
# target: sidecar present routes to the LVM restore; PV/VG recreated from
# the backup, LVs restored, swap regenerated with its UUID, VG left
# deactivated.
new_case 8
lvm_image
run 'restorePartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "restore completes" "RETURNED"
assert_call "stale signatures wiped" "wipefs" "/dev/sdb3"
assert_call "PV recreated with original UUID from backup" "pvcreate" "--uuid PVUUID-test" "--restorefile" "/dev/sdb3"
assert_call "VG metadata restored" "vgcfgrestore" "fakevg"
assert_call "VG activated for restore" "vgchange -ay fakevg"
assert_call "root LV restored with partclone" "partclone.restore"
assert_call "swap LV regenerated with original UUID" "mkswap" "-U SWAPUUID-test" "$SANDBOX/dev/fakevg/swap_1"
assert_call "VG deactivated after restore" "vgchange -an fakevg"

# 9. Multicast deploy refuses instead of hanging the whole session.
new_case 9
lvm_image
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" yes'
assert_out "multicast LVM deploy refuses" "ABORT:"
assert_out "multicast refusal names the cause" "Multicast"
assert_no_call "multicast refusal touches nothing" "pvcreate"

# 10. A sidecar from a newer FOS (unknown format version) refuses.
new_case 10
lvm_image
sed -i 's/^LVMFORMAT 1$/LVMFORMAT 3/' "$IMGDIR/d1p3.lvm"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "unknown sidecar format refuses" "ABORT:"
assert_out "format refusal names the cause" "newer LVM format"

# 11. Sidecar present but the vgcfg metadata backup missing: refuse before
# touching the disk.
new_case 11
lvm_image
rm -f "$IMGDIR/d1p3.lvm.vgcfg"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "missing vgcfg backup refuses" "ABORT:"
assert_out "vgcfg refusal names the cause" "metadata backup missing"
assert_no_call "vgcfg refusal touches nothing" "wipefs"

# 12. An LV's image file missing from the store: fatal, not skipped.
new_case 12
lvm_image
rm -f "$IMGDIR/d1p3.root.img"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "missing LV image refuses" "ABORT:"
assert_out "missing-image refusal names the cause" "Logical volume image missing"

# ============================================================
# Deploy-side resize (docs/adr/0006)
# ============================================================

# 21. Format-2 image on a same-size target: the exact Phase 1 vgcfgrestore
# path, no grow, no rebuild.
new_case 21
lvm_image2
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "same-size deploy completes" "RETURNED"
assert_call "PV recreated with original UUID from backup" "pvcreate" "--uuid PVUUID-test" "--restorefile"
assert_call "VG metadata restored" "vgcfgrestore" "fakevg"
assert_no_call "same-size deploy does not grow the PV" "pvresize"
assert_no_call "same-size deploy does not extend LVs" "lvextend"
assert_no_call "same-size deploy does not rebuild the VG" "vgcreate"
assert_call "home LV restored" "partclone.restore" "$SANDBOX/dev/fakevg/home"
assert_call "swap regenerated with original UUID" "mkswap" "-U SWAPUUID-test"

# 22. Format-2 image on a larger target: vgcfgrestore first (all UUIDs kept),
# then the PV grows and the free extents are split among the non-swap LVs
# proportionally to their original sizes. 1024 free extents at 5:2
# (root 20971520 : home 8388608) = 731 for root, remainder 293 for home,
# nothing for swap.
new_case 22
lvm_image2
FAKE_PARTSIZE="50331648"
FAKE_FREE="1024"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "larger-target deploy completes" "RETURNED"
assert_call "restored from metadata first" "vgcfgrestore" "fakevg"
assert_call "PV grown into the target" "pvresize" "/dev/sdb3"
assert_call "root gets its proportional share" "lvextend" "-l +731" "/dev/fakevg/root"
assert_call "home takes the remainder" "lvextend" "-l +293" "/dev/fakevg/home"
if grep "lvextend" "$CALLS" | grep -q "swap_1"; then
    ko "swap LV must not be grown"
else
    ok "swap LV stays at its original size"
fi

# 23. Format-2 image on a smaller (but big-enough) target: the stack is
# rebuilt with standard tools at the recorded minimums plus a proportional
# share of the surplus. 2047 free extents - 960 minimum = 1087 surplus:
# root 320+776=1096, home 128+311=439, swap keeps its original 512.
# The LV device nodes are removed first so the case proves lvcreate ran
# before the restore loop's existence checks.
new_case 23
lvm_image2
rm -f "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/home" "$SANDBOX/dev/fakevg/swap_1"
FAKE_PARTSIZE="16777216"
FAKE_FREE="2047"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "smaller-target deploy completes" "RETURNED"
assert_call "PV recreated with original UUID, no metadata file" "pvcreate" "--norestorefile" "--uuid PVUUID-test"
assert_call "VG recreated with the original extent size" "vgcreate" "-s 8192s" "fakevg" "/dev/sdb3"
assert_no_call "rebuild does not apply the oversized metadata" "vgcfgrestore"
assert_call "root rebuilt at minimum plus its surplus share" "lvcreate" "-l 1096" "-n root"
assert_call "home rebuilt at minimum plus the remainder" "lvcreate" "-l 439" "-n home"
assert_call "swap rebuilt at its original size" "lvcreate" "-l 512" "-n swap_1"
assert_call "root restored into the rebuilt LV" "partclone.restore" "$SANDBOX/dev/fakevg/root"
assert_call "swap regenerated with original UUID" "mkswap" "-U SWAPUUID-test"
assert_call "VG deactivated after restore" "vgchange -an fakevg"

# 24. Format-2 image on a target below the recorded minimum: refuse before
# anything on the disk is touched.
new_case 24
lvm_image2
FAKE_PARTSIZE="6000000"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "below-minimum target refuses" "ABORT:"
assert_out "refusal names the recorded minimum" "smaller than the minimum this image can shrink to (7874560 sectors)"
assert_no_call "below-minimum refusal wipes nothing" "wipefs"
assert_no_call "below-minimum refusal creates nothing" "pvcreate"

# 25. Format-1 image (no recorded minimums) on a smaller target: refuse
# before anything on the disk is touched.
new_case 25
lvm_image
FAKE_PARTSIZE="16777216"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "format-1 image on smaller target refuses" "ABORT:"
assert_out "refusal explains the missing minimums" "records no LVM minimum sizes"
assert_no_call "format-1 refusal wipes nothing" "wipefs"

# 26. Format-1 image on a larger target: restores at the original size and
# leaves the extra space unallocated (Phase 1 behavior — format 1 has no
# original sizes to distribute by). Also exercises the 7-field line parse.
new_case 26
lvm_image
FAKE_PARTSIZE="50331648"
run 'restoreLVMPartition /dev/sdb3 1 "$IMGDIR" ""'
assert_out "format-1 larger-target deploy completes" "RETURNED"
assert_call "restored from metadata at original size" "vgcfgrestore" "fakevg"
assert_no_call "format-1 extra space stays unallocated" "pvresize"
assert_no_call "format-1 LVs are not grown" "lvextend"
assert_call "format-1 fields parse after the shuffle" "mkswap" "-U SWAPUUID-test"

# ============================================================
# Deploy-side expand
# ============================================================

# 27. expandPartition dispatch: ext LVs are grown out to their LV boundary,
# swap is untouched, VG left deactivated. (Also runs on the source after
# capture to undo the shrink.)
new_case 27
lvm_source
run 'expandPartition /dev/sdb3 ""'
assert_out "expand completes" "RETURNED"
assert_call "ext LV grown to its boundary" "resize2fs" "$SANDBOX/dev/fakevg/root"
assert_no_call "swap LV not resized" "resize2fs $SANDBOX/dev/fakevg/swap_1"
assert_call "VG activated for expand" "vgchange -ay fakevg"
assert_call "VG deactivated after expand" "vgchange -an fakevg"

# 28. Unsupported topology at expand time (raw-captured PV): skipped loudly.
new_case 28
FAKE_VG=""
echo "/dev/sdb3 LVM2_member" > "$SANDBOX/blkid.map"
run 'expandPartition /dev/sdb3 ""'
assert_out "unsupported topology is not expanded" "Not expanding (/dev/sdb3)"
assert_no_call "unsupported expand never resizes" "resize2fs"

# ============================================================
# Valid-partition discovery
# ============================================================

# 13. A partition with only a .lvm sidecar (no dNpM.img) is a valid restore
# target; an empty image dir is not.
new_case 13
lvm_image
run 'getValidRestorePartitions /dev/sdb 1 "$IMGDIR"; echo "RESTOREPARTS=[$restoreparts]"'
assert_out "sidecar-only partition is valid for restore" "RESTOREPARTS=[/dev/sdb3]"
new_case 13b
run 'getValidRestorePartitions /dev/sdb 1 "$IMGDIR"; echo "RESTOREPARTS=[$restoreparts]"'
assert_out "empty image dir yields no valid partitions" "RESTOREPARTS=[]"

# 14. Regression guard: a plain dNpM.img partition is still valid.
new_case 14
echo "IMGDATA" > "$IMGDIR/d1p3.img"
run 'getValidRestorePartitions /dev/sdb 1 "$IMGDIR"; echo "RESTOREPARTS=[$restoreparts]"'
assert_out "plain image partition is still valid" "RESTOREPARTS=[/dev/sdb3]"

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
