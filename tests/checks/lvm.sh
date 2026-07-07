#!/bin/bash
#
# Assertion harness for the LVM per-LV capture/deploy path in funcs.sh
# (docs/adr/0004): saveLVMPartition, restoreLVMPartition, and the dispatch
# points that route an LVM2_member partition into them.
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
rewrites=$(grep -c "lvdev=\"$SANDBOX/dev/" "$SANDBOX/funcs.sh")
[[ $rewrites -eq 2 ]] || { echo "ERROR: expected 2 lvdev rewrites, got $rewrites (funcs.sh changed shape?)" >&2; exit 2; }

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

# Log-and-succeed doubles for everything else the paths shell out to.
for tool in vgscan vgchange pvcreate vgcfgrestore wipefs mkswap udevadm umount blockdev usleep; do
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
new_case() {
    IMGDIR="$SANDBOX/img.$1"
    rm -rf "$IMGDIR"
    mkdir -p "$IMGDIR"
    CALLS="$IMGDIR/calls.log"
    : > "$CALLS"
    rm -rf "$SANDBOX/dev"
    mkdir -p "$SANDBOX/dev/fakevg"
    : > "$SANDBOX/blkid.map"
    rm -f /tmp/pigz1
    FAKE_VG="fakevg"
    FAKE_PVUUID="PVUUID-test"
    FAKE_PVSIZE="41940992.00"
    FAKE_PVCOUNT="1"
    FAKE_VGUUID="VGUUID-test"
    FAKE_EXTENT="8192.00"
    FAKE_LAYOUTS=$'  linear\n  linear'
    FAKE_LVS=$'  root ROOT-uuid 20971520.00\n  swap_1 SWAP-uuid 4194304.00'
    FAKE_SWAPUUID="SWAPUUID-test"
}

# Standard supported-source fixtures on top of new_case.
lvm_source() {
    printf '%s ext4\n%s swap\n%s LVM2_member\n' \
        "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/swap_1" /dev/sdb3 > "$SANDBOX/blkid.map"
    touch "$SANDBOX/dev/fakevg/root" "$SANDBOX/dev/fakevg/swap_1"
}

# A captured image set in $IMGDIR, as saveLVMPartition would leave it.
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
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        imgFormat=5
        imgPartitionType="all"
        imgType="n"
        osid=50
        storage="STUBSTORE"
        img="STUBIMG"
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
# no raw d1p3.img, VG left deactivated.
new_case 3
lvm_source
run 'savePartition /dev/sdb3 1 "$IMGDIR"'
assert_out "capture completes" "RETURNED"
cat > "$SANDBOX/expected.lvm" <<'SIDE'
LVMFORMAT 1
PV PVUUID-test /dev/sdb3 41940992
VG fakevg VGUUID-test 8192
LV root ROOT-uuid 20971520 extfs d1p3.root.img -
LV swap_1 SWAP-uuid 4194304 swap - SWAPUUID-test
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
[[ $assert_out_line == "LV data DATA-uuid 8388608 imager d1p3.data.img -" ]] \
    && ok "nested PV recorded as imager in sidecar" \
    || ko "nested PV sidecar line wrong: '$assert_out_line'"

# ============================================================
# Deploy
# ============================================================

# 8. Full dispatch through restorePartition: sidecar present routes to the LVM
# restore; PV/VG recreated from the backup, LVs restored, swap regenerated
# with its UUID, VG left deactivated.
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
sed -i 's/^LVMFORMAT 1$/LVMFORMAT 2/' "$IMGDIR/d1p3.lvm"
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
