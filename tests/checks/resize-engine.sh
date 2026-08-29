#!/bin/bash
#
# Assertion harness for the capture-time partition shrink: processSfdisk() +
# resizeSfdiskPartition() in partition-funcs.sh and resize_partition() in
# procsfdisk.awk.
#
#   tests/checks/resize-engine.sh      # run all cases, exit non-zero on any failure
#
# tests/checks/fill-engine.sh covers the DEPLOY side (action=filldisk). Nothing
# covered the CAPTURE side until ADR-0016, and that is where the 4Kn bug lived:
# processSfdisk rescaled its sector units for filldisk only, so on a 4Kn disk the
# resize action received diskSize in 512-byte units and divided a byte count by an
# alignment quantum. The table it emitted named a last-lba eight times past the end
# of the disk, sfdisk refused it, and until ADR-0003 made the apply fail loud that
# refusal was swallowed into a debug line -- the shrink simply never happened.
#
# What this harness locks:
#
#   1. last-lba is passed through, not recomputed. It describes where the disk
#      ends; shrinking one partition does not move that. The emitted value must
#      equal the dump's, and must lie inside the disk in the TABLE's own unit --
#      the assertion the original bug would have failed.
#   2. The byte-count argument is divided by the LOGICAL sector size, so a 4Kn
#      shrink asks for an eighth of the sectors a 512-byte one would, not eight
#      times too many.
#   3. That division rounds UP. The filesystem has already been shrunk to sizePos
#      bytes, so a partition rounded down is smaller than the filesystem in it.
#   4. A valid 4Kn resize reaches the sfdisk write instead of aborting, and a
#      refused write still aborts.
#
# Mechanism mirrors tests/checks/fill-engine.sh: a sandbox copy of the library with
# the hardcoded awk path rewritten to the in-tree script, blockdev/flock/sfdisk
# PATH-shadowed with deterministic stubs, and the funcs.sh helpers the entry points
# call overridden. handleError is overridden AFTER sourcing so an abort is
# observable (it still exits the case subshell, as the real one exits init).

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

# blockdev: --getsz is always in 512-byte units (that is the whole trap this
# harness exists for), --getss the logical sector size.
cat > "$STUBBIN/blockdev" <<'STUB'
#!/bin/bash
case "$1" in
    --getsz)   printf '%s\n' "$FAKE_GETSZ" ;;
    --getss)   printf '%s\n' "$FAKE_GETSS" ;;
    --getpbsz) printf '%s\n' "$FAKE_GETPBSZ" ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/blockdev"

cat > "$STUBBIN/flock" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
chmod +x "$STUBBIN/flock"

# sfdisk double: keep the table it was handed so a case can assert on what would
# really have been written, and exit $FAKE_SFDISK_RC.
cat > "$STUBBIN/sfdisk" <<'STUB'
#!/bin/bash
cat > "$SANDBOX/applied" 2>/dev/null
exit ${FAKE_SFDISK_RC:-0}
STUB
chmod +x "$STUBBIN/sfdisk"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ -n $2 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }

# --- parse helpers over $OUT (the emitted "sfdisk -d" table) ---
psize()    { printf '%s\n' "$OUT" | sed -n "s#^$1 : .*size= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
pstart()   { printf '%s\n' "$OUT" | sed -n "s#^$1 : start= *\([0-9]\{1,\}\).*#\1#p" | head -1; }
plastlba() { printf '%s\n' "$OUT" | sed -n 's#^last-lba: *\([0-9]\{1,\}\).*#\1#p' | head -1; }

# run_resize <dumpfile> <getsz> <getss> <part> <bytes> -- drive processSfdisk's
# resize action over a disk with the given geometry. Leaves the emitted table in
# $OUT and processSfdisk's exit in $RC.
run_resize() {
    local dump="$1" getsz="$2" getss="$3" part="$4" bytes="$5"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export FAKE_GETSZ="$getsz" FAKE_GETSS="$getss" FAKE_GETPBSZ="$getss"
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        handleWarning() { :; }
        getPartBlockSize() { printf -v "$2" '%s' "$FAKE_GETPBSZ"; }
        runPartprobe() { :; }
        majorDebugEcho() { :; }; majorDebugPause() { :; }
        ismajordebug=0
        disk="/dev/vda"                        # processSfdisk reads the global $disk
        processSfdisk "$dump" resize "$part" "$bytes"
    )"
    RC=$?
}

# ---------------------------------------------------------------------------
# Fixtures. Both describe the same 64 GiB disk, one as 512-byte sectors and one
# as 4Kn -- the geometry from the bug report.
DISK4K=16777216                                # 64 GiB in 4096-byte units
GETSZ4K=$(( DISK4K * 8 ))                      # what blockdev --getsz reports
LAST4K=$(( DISK4K - 6 ))
cat > "$SANDBOX/d.4k" <<EOF
label: gpt
label-id: EE9A77DD-0E9D-4825-BBA0-702095906226
device: /dev/vda
unit: sectors
first-lba: 6
last-lba: $LAST4K
sector-size: 4096

/dev/vda1 : start=         256, size=      262144, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC
/dev/vda2 : start=      262400, size=      262144, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/vda3 : start=      524544, size=      262144, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE
/dev/vda4 : start=      786688, size=    15990272, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
EOF

DISK512=134217728                              # the same 64 GiB in 512-byte units
LAST512=$(( DISK512 - 34 ))
cat > "$SANDBOX/d.512" <<EOF
label: gpt
label-id: EE9A77DD-0E9D-4825-BBA0-702095906227
device: /dev/vda
unit: sectors
first-lba: 34
last-lba: $LAST512
sector-size: 512

/dev/vda1 : start=        2048, size=     2097152, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC
/dev/vda2 : start=     2099200, size=     2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/vda3 : start=     4196352, size=     2097152, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE
/dev/vda4 : start=     6293504, size=   127922176, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
EOF

# ---------------------------------------------------------------------------
# 1. 4Kn: the emitted last-lba is the dump's, and lies inside the disk measured
#    in the table's own unit. Recomputing it as diskSize - firstlba with diskSize
#    in 512-byte units produced 134217722 for this disk, which is what sfdisk
#    rejected with "Last LBA specified by script is out of range".
BYTES30G=32212254720                           # 30 GiB, an exact multiple of 4096
run_resize "$SANDBOX/d.4k" "$GETSZ4K" 4096 /dev/vda4 "$BYTES30G"
got=$(plastlba)
if [[ $RC -eq 0 && $got == "$LAST4K" && $got -le $DISK4K ]]; then
    pass "4Kn resize: last-lba passed through ($got), inside the disk ($DISK4K)"
else
    fail "4Kn resize last-lba" "rc=$RC last-lba=$got expected=$LAST4K diskSize=$DISK4K
$OUT"
fi

# ---------------------------------------------------------------------------
# 2. 4Kn: the byte count is divided by the LOGICAL sector size. Dividing by
#    SECTOR_SIZE (512, or the 64-sector alignment quantum) gives eight or 512
#    times this.
WANT=$(( BYTES30G / 4096 ))
got=$(psize /dev/vda4)
if [[ $got == "$WANT" ]]; then
    pass "4Kn resize: size $got sectors == $BYTES30G bytes / 4096"
else
    fail "4Kn resize size" "got $got, expected $WANT (eight times would be $(( WANT * 8 )))
$OUT"
fi

# The shrunk partition has to still fit inside the disk it was cut from -- the
# end-to-end invariant that both of the above bugs broke.
end=$(( $(pstart /dev/vda4) + got ))
if [[ $end -le $LAST4K ]]; then
    pass "4Kn resize: vda4 ends at $end, within last-usable $LAST4K"
else
    fail "4Kn resize fit" "vda4 ends at $end, past last-usable $LAST4K"
fi

# ---------------------------------------------------------------------------
# 3. 4Kn: a byte count that is not a whole number of sectors rounds UP. ext
#    filesystems reach here with sizeextresize = size + percentage, which is
#    under no obligation to land on a sector boundary; rounding down would leave
#    the partition smaller than the filesystem already shrunk into it.
BYTESODD=$(( BYTES30G + 1 ))
run_resize "$SANDBOX/d.4k" "$GETSZ4K" 4096 /dev/vda4 "$BYTESODD"
got=$(psize /dev/vda4)
if [[ $got == "$(( WANT + 1 ))" && $(( got * 4096 )) -ge $BYTESODD ]]; then
    pass "4Kn resize: $BYTESODD bytes rounded up to $got sectors ($(( got * 4096 )) bytes)"
else
    fail "4Kn resize rounding" "got $got for $BYTESODD bytes; want $(( WANT + 1 )) and size*4096 >= bytes
$OUT"
fi

# ---------------------------------------------------------------------------
# 4. 512n keeps the divisor it always effectively had -- the sector size -- and
#    gains the same last-lba passthrough. Before ADR-0016 this emitted
#    diskSize - 34, which on this disk is 2014 sectors short of the truth:
#    silently reserved tail that a barely-fitting image could need.
run_resize "$SANDBOX/d.512" "$DISK512" 512 /dev/vda4 "$BYTES30G"
got=$(psize /dev/vda4)
gotlast=$(plastlba)
if [[ $RC -eq 0 && $got == "$(( BYTES30G / 512 ))" && $gotlast == "$LAST512" ]]; then
    pass "512n resize: size $got sectors, last-lba $gotlast passed through"
else
    fail "512n resize" "rc=$RC size=$got (want $(( BYTES30G / 512 ))) last-lba=$gotlast (want $LAST512)
$OUT"
fi

# ---------------------------------------------------------------------------
# 5. End to end through resizeSfdiskPartition: a valid 4Kn shrink must reach the
#    sfdisk write rather than abort, and what reaches sfdisk must be the table
#    with the in-range last-lba. This is the case the bug report failed on.
# resize_case <name> <dump> <getsz> <getss> <part> <bytes> <abort|noabort> <yes|no>
# The last argument is whether the sfdisk write should have been ATTEMPTED. It is
# not implied by the abort expectation: a bad layout aborts before sfdisk is ever
# run, while a refused write aborts precisely because it was.
resize_case() {
    local name="$1" dump="$2" getsz="$3" getss="$4" part="$5" bytes="$6" expect="$7" expect_applied="$8"
    rm -f "$SANDBOX/applied"
    local out got
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        export FAKE_GETSZ="$getsz" FAKE_GETSS="$getss" FAKE_GETPBSZ="$getss"
        . "$SANDBOX/partition-funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        handleWarning() { :; }
        getPartBlockSize() { printf -v "$2" '%s' "$FAKE_GETPBSZ"; }
        getDiskFromPartition() { disk="/dev/vda"; }
        # Stand in for reading the table off the disk: hand back the fixture.
        RESIZE_DUMP="$dump"
        saveSfdiskPartitions() { cp "$RESIZE_DUMP" "$2"; }
        runPartprobe() { :; }
        majorDebugEcho() { :; }; majorDebugPause() { :; }
        ismajordebug=0
        resizeSfdiskPartition "$part" "$bytes" "/images/dev/stub"
        echo "RETURNED"
    )"
    [[ $out == *"ABORT:"* ]] && got="abort" || got="noabort"
    local applied="no"; [[ -f "$SANDBOX/applied" ]] && applied="yes"
    if [[ $got != "$expect" ]]; then
        fail "$name" "expected $expect, got $got applied=$applied: $(printf '%s' "$out" | tr '\n' '|')"
        return
    fi
    if [[ $applied != "$expect_applied" ]]; then
        fail "$name" "expected the sfdisk write attempted=$expect_applied, got $applied"
        return
    fi
    pass "$name (expected $expect, write attempted=$applied)"
}

resize_case "resizeSfdiskPartition applies a 4Kn shrink" \
    "$SANDBOX/d.4k" "$GETSZ4K" 4096 /dev/vda4 "$BYTES30G" noabort yes

# What sfdisk was handed must name a last-lba the disk actually has; a table
# sfdisk would reject is not a table this harness should call applied.
appliedlast=$(sed -n 's#^last-lba: *\([0-9]\{1,\}\).*#\1#p' "$SANDBOX/applied" 2>/dev/null | head -1)
if [[ -n $appliedlast && $appliedlast -le $DISK4K ]]; then
    pass "4Kn shrink: table handed to sfdisk names last-lba $appliedlast (<= $DISK4K)"
else
    fail "4Kn shrink applied table" "last-lba in written table: '${appliedlast:-none}' vs disk $DISK4K"
fi

# 6. A failing sfdisk write still aborts (ADR-0003) -- the behavior that turned
#    this silent no-op into a visible failure in the first place.
FAKE_SFDISK_RC=1 resize_case "resizeSfdiskPartition aborts when sfdisk refuses the table" \
    "$SANDBOX/d.4k" "$GETSZ4K" 4096 /dev/vda4 "$BYTES30G" abort yes

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
