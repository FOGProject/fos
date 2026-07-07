#!/bin/bash
#
# Assertion harness for validateImageSectorSize() in funcs.sh.
#
#   tests/checks/sector-size.sh        # run all cases, exit non-zero on any failure
#
# validateImageSectorSize() refuses a deploy when the target disk's logical
# sector size (blockdev --getss) does not match the size recorded in the stored
# sfdisk dump's "sector-size:" line. A single golden output stream can't express
# a pass/fail (abort vs no-op) assertion, so this is a sibling to the golden
# harness rather than a case inside it.
#
# Mechanism mirrors tests/golden/run.sh: source a sandbox copy of the library
# with its hardcoded /usr/share/fog/lib paths rewritten, and PATH-shadow the
# external tools (here, blockdev) with deterministic stubs. handleError is the
# real fatal function until we source it; we override it AFTER sourcing so a
# refusal is observable instead of exiting the test.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- sandbox copy of the library with host-absolute paths rewritten ---
cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

# --- deterministic stub for blockdev (--getss echoes $FAKE_SS) ---
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/blockdev" <<'EOF'
#!/bin/bash
# Only --getss is used by validateImageSectorSize. Echo the configured size;
# an empty FAKE_SS emulates blockdev failing to read the target.
[[ "$1" == "--getss" ]] && printf '%s\n' "$FAKE_SS"
exit 0
EOF
chmod +x "$STUBBIN/blockdev"

# Write a minimal but realistic sfdisk -d dump into $1. If $2 is non-empty it is
# used as the sector-size value; if empty, the sector-size line is omitted (as a
# legacy pre-sector-size sfdisk dump would be).
write_dump() {
    local file="$1" ss="$2"
    {
        echo "label: gpt"
        echo "device: /dev/sdb"
        echo "unit: sectors"
        echo "first-lba: 34"
        [[ -n $ss ]] && echo "sector-size: $ss"
        echo ""
        echo "/dev/sdb1 : start=        2048, size=     2048000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    } > "$file"
}

PASS=0
FAIL=0

# run_case <name> <target_ss> <expect: abort|noabort> -- then the caller has
# already populated $IMGDIR with the dump file(s) for this case.
run_case() {
    local name="$1" target_ss="$2" expect="$3"
    local out got
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export FAKE_SS="$target_ss"
        . "$SANDBOX/funcs.sh"
        # Override AFTER sourcing so the real fatal handleError doesn't exit us.
        handleError() { echo "ABORT: $*"; }
        validateImageSectorSize "/dev/sdb" "1" "$IMGDIR"
        echo "RETURNED"
    )"
    if [[ $out == *"ABORT:"* ]]; then got="abort"; else got="noabort"; fi
    if [[ $got == "$expect" ]]; then
        echo "PASS: $name (expected $expect)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (expected $expect, got $got)"
        echo "      output: $(printf '%s' "$out" | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

# Each case gets a fresh image dir so leftover dumps can't cross-contaminate.
new_imgdir() { IMGDIR="$SANDBOX/img.$1"; rm -rf "$IMGDIR"; mkdir -p "$IMGDIR"; }

# 1. Match: 512 image onto 512 disk -> allow.
new_imgdir 1; write_dump "$IMGDIR/d1.minimum.partitions" 512
run_case "match 512->512" 512 noabort

# 2. Mismatch: 4Kn image onto 512 disk -> refuse.
new_imgdir 2; write_dump "$IMGDIR/d1.minimum.partitions" 4096
run_case "mismatch 4096-image -> 512-disk" 512 abort

# 3. Mismatch other direction: 512 image onto 4Kn disk -> refuse.
new_imgdir 3; write_dump "$IMGDIR/d1.minimum.partitions" 512
run_case "mismatch 512-image -> 4096-disk" 4096 abort

# 4. No dump at all (dd-style / missing metadata): source unknown -> allow.
new_imgdir 4
run_case "no dump -> source unknown -> allow" 512 noabort

# 5. Dump present but no sector-size line (pre-util-linux-2.35 sfdisk): source
# unknown -> allow, even though the target is 512.
new_imgdir 5; write_dump "$IMGDIR/d1.minimum.partitions" ""
run_case "dump without sector-size -> source unknown -> allow" 512 noabort

# 6. blockdev can't read the target size: never introduce a new failure -> allow.
new_imgdir 6; write_dump "$IMGDIR/d1.minimum.partitions" 4096
run_case "unreadable target sector size -> no-op" "" noabort

# 7. Precedence: minimum (4096) must win over original (512). Target 4096 -> allow.
new_imgdir 7
write_dump "$IMGDIR/d1.partitions" 512
write_dump "$IMGDIR/d1.minimum.partitions" 4096
run_case "minimum file wins over original" 4096 noabort

# 8. Legacy fallback: only the legacy original file exists (4096) onto 512 -> refuse.
new_imgdir 8; write_dump "$IMGDIR/d1.original.partitions" 4096
run_case "legacy original file is read" 512 abort

# 9. A pre-util-linux-2.35 4Kn image (dump has no sector-size line) onto a 4Kn
# target must NOT be refused: guessing 512 would wrongly block a deploy that
# works. Source unknown -> allow. (Guards against the default-512 regression.)
new_imgdir 9; write_dump "$IMGDIR/d1.minimum.partitions" ""
run_case "no sector-size line -> allow onto 4096-disk" 4096 noabort

# 10. Middle precedence tier exercised alone: d<N>.partitions is the only dump
# (the standard case for a non-resizable image). 4096 image onto 512 -> refuse.
new_imgdir 10; write_dump "$IMGDIR/d1.partitions" 4096
run_case "d<N>.partitions is read when it is the only dump" 512 abort

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
