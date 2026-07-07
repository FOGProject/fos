#!/bin/bash
#
# Assertion harness for the whole-disk fill engine: processSfdisk() +
# fillSfdiskWithPartitions() in partition-funcs.sh and fill_disk() in
# procsfdisk.awk.
#
#   tests/checks/fill-engine.sh        # run all cases, exit non-zero on any failure
#
# The golden harness (tests/golden/) proves one fixed table stays byte-identical;
# it can't express the invariants that matter when the target geometry differs
# from the captured image. This harness drives the REAL awk through the REAL
# shell entry points to lock three behaviours that have no other in-tree coverage:
#
#   1. Sector-size awareness (processSfdisk, filldisk only). blockdev --getsz
#      always reports 512-byte units; on a 4Kn (getss=4096) target the disk size
#      is rescaled into the image's logical-sector unit and the fill's alignment
#      quantum (SECTOR_SIZE) is rescaled with it. If SECTOR_SIZE were left at 512
#      a 1 MiB partition (256 sectors on 4Kn) aligns to 0 and is silently dropped;
#      if diskSize were not rescaled every resizable partition inflates ~8x and
#      runs off the end. A 512n target must be an exact no-op.
#
#   2. The GPT backup-header clamp (fill_disk). The last partition may not run
#      past diskSize - firstlba, the last-usable LBA that holds the backup GPT
#      header/entry array. A barely-fits image whose partitions all floor back to
#      their captured sizes used to end exactly at diskSize, 34 sectors into that
#      reserved area, while check_overlap still reported "consistent".
#
#   3. Fail-loud on an unusable table. An inconsistent computed table makes the
#      awk exit non-zero; processSfdisk propagates that exit (the awk is its last
#      command) and fillSfdiskWithPartitions aborts via handleError instead of
#      applying a corrupt table. applySfdiskPartitions likewise aborts when the
#      real sfdisk write fails rather than swallowing it into a debug line.
#
# Mechanism mirrors tests/checks/sector-size.sh: source a sandbox copy of the
# library with the awk path rewritten to the in-tree script, PATH-shadow blockdev
# (and, for the apply path, flock/sfdisk) with deterministic stubs, and override
# the funcs.sh helpers the entry points call. handleError is overridden AFTER
# sourcing so an abort is observable (it still exits the case subshell, as the
# real one exits init).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/partition-funcs.sh ]] || { echo "ERROR: cannot find partition-funcs.sh under $REPO_LIB" >&2; exit 2; }
[[ -f $REPO_LIB/procsfdisk.awk ]] || { echo "ERROR: cannot find procsfdisk.awk under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Sandbox copy of the library with the hardcoded awk path rewritten to the in-tree
# script, invoked via `awk -f` so the test does not depend on the file's mode bit.
REALAWK="$REPO_LIB/procsfdisk.awk"
sed -e "s#/usr/share/fog/lib/procsfdisk\.awk#awk -f $REALAWK#g" \
    "$REPO_LIB/partition-funcs.sh" > "$SANDBOX/partition-funcs.sh"

# --- deterministic stubs for the external tools the entry points shell out to ---
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# blockdev: --getsz is the 512-byte-unit disk size, --getss the logical sector
# size, --getpbsz the physical block size. All three come from the per-case FAKE_*
# globals so a case can model any geometry.
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

# flock <lockpath> <cmd...>: drop the lock argument and run the command, so the
# real applySfdiskPartitions plumbing (flock $disk sfdisk $disk < file) exercises
# the sfdisk stub with the table on stdin.
cat > "$STUBBIN/flock" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$STUBBIN/flock"

# sfdisk double: consume the table on stdin, record that a write was attempted,
# and exit $FAKE_SFDISK_RC so a case can model the write succeeding or failing.
cat > "$STUBBIN/sfdisk" <<'EOF'
#!/bin/bash
cat >/dev/null 2>&1
: > "$SANDBOX/applied"
exit ${FAKE_SFDISK_RC:-0}
EOF
chmod +x "$STUBBIN/sfdisk"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ -n $2 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }

# --- parse helpers over $OUT (the emitted "sfdisk -d" table) ---
# display_output prints:  <dev> : start=%12d, size=%12d, <type...>
pstart() { printf '%s\n' "$OUT" | sed -n "s#^$1 : start= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
psize()  { printf '%s\n' "$OUT" | sed -n "s#^$1 : .*size= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
pend()   { echo $(( $(pstart "$1") + $(psize "$1") )); }

# run_fill <dumpfile> <getsz> <getss> <fixedList> -- run processSfdisk filldisk on
# a target with the given geometry; leaves the emitted table in $OUT and the awk's
# (== processSfdisk's) exit in $RC.
run_fill() {
    local dump="$1" getsz="$2" getss="$3" fixed="$4"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export FAKE_GETSZ="$getsz" FAKE_GETSS="$getss" FAKE_GETPBSZ="$getss"
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        handleWarning() { :; }
        getPartBlockSize() { printf -v "$2" '%s' "$FAKE_GETPBSZ"; }
        runPartprobe() { :; }
        majorDebugEcho() { :; }; majorDebugPause() { :; }; majorDebugShowCurrentPartitionTable() { :; }
        ismajordebug=0
        disk="/dev/sdb"                        # processSfdisk reads the global $disk
        processSfdisk "$dump" filldisk "/dev/sdb" "$getsz" "$fixed" "$dump"
    )"
    RC=$?
}

# ---------------------------------------------------------------------------
# 1. 512n comfortable GPT fill: exact no-op on the sector-size scaling, valid
#    table, last partition inside the last-usable LBA.
DISK512=83886080                               # 40 GiB in 512-byte units
END512=$(( DISK512 - 34 ))
cat > "$SANDBOX/d.512" <<EOF
label: gpt
device: /dev/sdb
unit: sectors
first-lba: 34
last-lba: $END512
sector-size: 512

/dev/sdb1 : start=        2048, size=      204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/sdb2 : start=      206848, size=     1048576, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
/dev/sdb3 : start=     1255424, size=    10485760, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
run_fill "$SANDBOX/d.512" "$DISK512" 512 ""
if [[ $RC -eq 0 && $OUT == *"consistent"* && $OUT != *ERROR* \
      && $(psize /dev/sdb1) -gt 0 && $(pend /dev/sdb3) -le $END512 ]]; then
    pass "512n GPT fill: valid table, sdb3 end $(pend /dev/sdb3) <= last-usable $END512"
else
    fail "512n GPT fill" "rc=$RC sdb1=$(psize /dev/sdb1) sdb3_end=$(pend /dev/sdb3) end=$END512
$OUT"
fi

# ---------------------------------------------------------------------------
# 2. 4Kn fill: getsz is 8x the logical size, getss=4096. processSfdisk must
#    rescale diskSize into 4K units and drop SECTOR_SIZE to 64 so the 1 MiB
#    (256-sector) partition survives instead of aligning to 0. All partitions
#    resizable so sdb1 actually goes through the alignment quantum.
DISK4K_512=2097152                             # 1 GiB in 512-byte units
DISK4K=$(( DISK4K_512 / 8 ))                   # 262144, in 4K units
END4K=$(( DISK4K - 6 ))
cat > "$SANDBOX/d.4k" <<EOF
label: gpt
device: /dev/sdb
unit: sectors
first-lba: 6
last-lba: $END4K
sector-size: 4096

/dev/sdb1 : start=         256, size=         256, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/sdb2 : start=         512, size=       25600, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
/dev/sdb3 : start=       26112, size=      131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
run_fill "$SANDBOX/d.4k" "$DISK4K_512" 4096 ""
sdb1sz=$(psize /dev/sdb1)
if [[ $RC -eq 0 && $OUT == *"consistent"* && $OUT != *ERROR* \
      && $sdb1sz -gt 0 && $(( sdb1sz % 64 )) -eq 0 && $(pend /dev/sdb3) -le $END4K ]]; then
    pass "4Kn fill: 256-sector partition survived (size=$sdb1sz), sdb3 end $(pend /dev/sdb3) <= $END4K"
else
    fail "4Kn fill (Edit C sector-size scaling)" "rc=$RC sdb1=$sdb1sz sdb3_end=$(pend /dev/sdb3) end=$END4K
$OUT"
fi

# ---------------------------------------------------------------------------
# 3. Barely-fits GPT: every partition floors back to its captured size so the
#    last one would end exactly at diskSize without the clamp. It must instead
#    stop at or before diskSize - firstlba.
DISKBF=20969472
ENDBF=$(( DISKBF - 34 ))
cat > "$SANDBOX/d.bf" <<EOF
label: gpt
device: /dev/sdb
unit: sectors
first-lba: 34
last-lba: $ENDBF
sector-size: 512

/dev/sdb1 : start=        2048, size=        2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/sdb2 : start=        4096, size=      204800, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
/dev/sdb3 : start=      208896, size=    20760576, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
run_fill "$SANDBOX/d.bf" "$DISKBF" 512 ""
if [[ $RC -eq 0 && $OUT == *"consistent"* && $OUT != *ERROR* \
      && $(pend /dev/sdb3) -le $ENDBF ]]; then
    pass "barely-fits GPT clamp: sdb3 end $(pend /dev/sdb3) <= last-usable $ENDBF (not into backup GPT)"
else
    fail "barely-fits GPT clamp" "rc=$RC sdb3_end=$(pend /dev/sdb3) end=$ENDBF diskSize=$DISKBF
$OUT"
fi

# ---------------------------------------------------------------------------
# 4. MBR (dos) fill: no first-lba, so disk_end == diskSize and the clamp is a
#    no-op; the table must still be valid and inside the disk.
cat > "$SANDBOX/d.mbr" <<EOF
label: dos
device: /dev/sdb
unit: sectors

/dev/sdb1 : start=        2048, size=      204800, type=83
/dev/sdb2 : start=      206848, size=     2097152, type=83
/dev/sdb3 : start=     2304000, size=    18665472, type=83
EOF
run_fill "$SANDBOX/d.mbr" "$DISKBF" 512 ""
if [[ $RC -eq 0 && $OUT == *"consistent"* && $OUT != *ERROR* \
      && $(pend /dev/sdb3) -le $DISKBF ]]; then
    pass "MBR fill: valid table, sdb3 end $(pend /dev/sdb3) <= disk $DISKBF"
else
    fail "MBR fill" "rc=$RC sdb3_end=$(pend /dev/sdb3) disk=$DISKBF
$OUT"
fi

# ---------------------------------------------------------------------------
# 5. Inconsistent table -> awk exits non-zero -> processSfdisk propagates it.
#    Three fixed partitions whose cumulative captured sizes march a start past
#    the end of the disk, which check_overlap rejects.
cat > "$SANDBOX/d.bad" <<EOF
label: dos
device: /dev/sdb
unit: sectors

/dev/sdb1 : start=        2048, size=       90000, type=83
/dev/sdb2 : start=       92048, size=       90000, type=83
/dev/sdb3 : start=      182048, size=        2048, type=83
EOF
run_fill "$SANDBOX/d.bad" 100000 512 "1:2:3"
if [[ $RC -ne 0 && $OUT == *ERROR* ]]; then
    pass "inconsistent fill: awk exit $RC (non-zero) and reported an error"
else
    fail "inconsistent fill should exit non-zero" "rc=$RC
$OUT"
fi

# ---------------------------------------------------------------------------
# Fail-loud propagation through the shell entry points.
# ---------------------------------------------------------------------------

# apply_case <name> <sfdisk_rc> <expect: abort|noabort> -- run applySfdiskPartitions
# against a stub sfdisk that exits $sfdisk_rc.
apply_case() {
    local name="$1" rc="$2" expect="$3" got
    printf 'label: dos\n/dev/sdb1 : start=2048, size=2048, type=83\n' > "$SANDBOX/table"
    local out
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX="$SANDBOX" FAKE_SFDISK_RC="$rc"
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        majorDebugEcho() { :; }
        applySfdiskPartitions "/dev/sdb" "$SANDBOX/table"
        echo "RETURNED"
    )"
    [[ $out == *"ABORT:"* ]] && got="abort" || got="noabort"
    if [[ $got == "$expect" ]]; then
        pass "$name (expected $expect)"
    else
        fail "$name" "expected $expect, got $got: $(printf '%s' "$out" | tr '\n' '|')"
    fi
}

# 6. sfdisk write fails -> hard abort instead of a swallowed debug line.
apply_case "applySfdiskPartitions aborts when sfdisk write fails" 1 abort
# 7. sfdisk write succeeds -> no spurious abort.
apply_case "applySfdiskPartitions succeeds silently on a good write" 0 noabort

# fill_case <name> <dumpfile> <getsz> <fixed> <expect: abort|noabort> -- run the
# full fillSfdiskWithPartitions; a computed table that is inconsistent must abort
# before any sfdisk write, a good one must reach the write.
fill_case() {
    local name="$1" dump="$2" getsz="$3" fixed="$4" expect="$5" got
    rm -f "$SANDBOX/applied"
    local out
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX="$SANDBOX" FAKE_GETSZ="$getsz" FAKE_GETSS=512 FAKE_GETPBSZ=512 FAKE_SFDISK_RC=0
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        handleWarning() { :; }
        getPartBlockSize() { printf -v "$2" '%s' 512; }
        runPartprobe() { :; }
        majorDebugEcho() { :; }; majorDebugPause() { :; }; majorDebugShowCurrentPartitionTable() { :; }
        ismajordebug=0
        fillSfdiskWithPartitions "/dev/sdb" "$dump" "$dump" "$fixed" "$dump"
        echo "RETURNED"
    )"
    [[ $out == *"ABORT:"* ]] && got="abort" || got="noabort"
    local applied="no"; [[ -f "$SANDBOX/applied" ]] && applied="yes"
    if [[ $got == "$expect" ]]; then
        # An abort must happen before the write; a non-abort must reach the write.
        if { [[ $expect == abort && $applied == no ]] || [[ $expect == noabort && $applied == yes ]]; }; then
            pass "$name (expected $expect, applied=$applied)"
        else
            fail "$name" "abort/apply mismatch: got $got applied=$applied"
        fi
    else
        fail "$name" "expected $expect, got $got applied=$applied: $(printf '%s' "$out" | tr '\n' '|')"
    fi
}

# 8. Unusable computed table -> abort before writing anything.
fill_case "fillSfdiskWithPartitions aborts on an unusable layout" "$SANDBOX/d.bad" 100000 "1:2:3" abort
# 9. Valid computed table -> proceed to the sfdisk write.
fill_case "fillSfdiskWithPartitions applies a valid layout" "$SANDBOX/d.512" "$DISK512" "" noabort

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
