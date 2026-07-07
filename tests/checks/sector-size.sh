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

# --- deterministic stubs for the external tools the function shells out to ---
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# blockdev: --getss returns the target's logical sector size. Before a reformat
# that is $FAKE_SS (empty emulates blockdev failing to read the target); once the
# nvme stub has dropped the "formatted" marker it returns $FAKE_SS_AFTER, so a
# test can model the sector size changing (or not) as a result of nvme format.
# --rereadpt (used by runPartprobe after a reformat) is a no-op that succeeds.
cat > "$STUBBIN/blockdev" <<'EOF'
#!/bin/bash
if [[ "$1" == "--getss" ]]; then
    if [[ -f "$SANDBOX/formatted" ]]; then printf '%s\n' "$FAKE_SS_AFTER"; else printf '%s\n' "$FAKE_SS"; fi
fi
exit 0
EOF
chmod +x "$STUBBIN/blockdev"

# nvme-cli double: id-ns lists the configured LBA formats ($FAKE_LBAFS); format
# drops a marker so the blockdev stub reports the reformatted size, unless
# $FAKE_FMT_FAIL is set (simulating a failed low-level format).
cat > "$STUBBIN/nvme" <<'EOF'
#!/bin/bash
case "$1" in
    id-ns) printf '%s\n' "$FAKE_LBAFS" ;;
    format)
        [[ -n $FAKE_FMT_FAIL ]] && exit 1
        : > "$SANDBOX/formatted"
        ;;
esac
exit 0
EOF
chmod +x "$STUBBIN/nvme"

# No-op doubles for the countdown sleep and the tools runPartprobe calls, so the
# reformat path runs instantly and touches nothing on the host.
for tool in usleep udevadm umount; do
    printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/$tool"
    chmod +x "$STUBBIN/$tool"
done

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

# run_case <name> <target_ss> <expect: abort|noabort> [disk] -- then the caller
# has already populated $IMGDIR with the dump file(s) for this case. The optional
# disk defaults to a non-NVMe /dev/sdb; pass /dev/nvme0n1 to exercise the reformat
# path. The FAKE_LBAFS / FAKE_FMT_FAIL / FAKE_SS_AFTER globals (cleared by
# new_imgdir) drive the nvme stub for reformat cases.
run_case() {
    local name="$1" target_ss="$2" expect="$3" disk="${4:-/dev/sdb}"
    local out got
    rm -f "$SANDBOX/formatted"
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX="$SANDBOX"
        export FAKE_SS="$target_ss"
        export FAKE_SS_AFTER FAKE_LBAFS FAKE_FMT_FAIL
        . "$SANDBOX/funcs.sh"
        # Override AFTER sourcing so the real fatal handleError doesn't exit us.
        handleError() { echo "ABORT: $*"; }
        validateImageSectorSize "$disk" "1" "$IMGDIR"
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

# Each case gets a fresh image dir so leftover dumps can't cross-contaminate, and
# the reformat-stub knobs are reset so a prior case can't leak into this one.
new_imgdir() {
    IMGDIR="$SANDBOX/img.$1"; rm -rf "$IMGDIR"; mkdir -p "$IMGDIR"
    FAKE_LBAFS=""; FAKE_FMT_FAIL=""; FAKE_SS_AFTER=""
}

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

# --- NVMe reformat path: a mismatch on an NVMe target that exposes a matching
# --- LBA format is resolved by reformatting instead of refused. ---

# 11. NVMe target with a matching metadata-free (ms:0) LBA format: reformat the
# namespace to the image's sector size and allow. 4096 image onto a 512 NVMe that
# also exposes a 4096 format -> reformat -> allow.
new_imgdir 11; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)\nlbaf  1 : ms:0   lbads:12 rp:0x2 '
FAKE_SS_AFTER=4096
run_case "nvme mismatch with matching lbaf -> reformat -> allow" 512 noabort /dev/nvme0n1

# 12. NVMe target but no matching LBA format (only 512 exposed): can't reformat to
# 4096, so fall back to the refusal.
new_imgdir 12; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)'
run_case "nvme mismatch, no matching lbaf -> refuse" 512 abort /dev/nvme0n1

# 13. NVMe target whose only 4096 format carries metadata (ms:8): we never switch
# a namespace into a metadata/PI format, so fall back to the refusal. FAKE_SS_AFTER
# is set so that if the ms:0 gate were dropped and we DID reformat into lbaf 1, the
# size would look correct and wrongly allow -- the abort proves the gate holds.
new_imgdir 13; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)\nlbaf  1 : ms:8   lbads:12 rp:0x2 '
FAKE_SS_AFTER=4096
run_case "nvme mismatch, only metadata lbaf matches -> refuse" 512 abort /dev/nvme0n1

# 14. Non-NVMe target: even with a matching format advertised, a SATA disk can't
# be nvme-formatted, so a mismatch still refuses. Guards the nvme-only gate.
new_imgdir 14; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)\nlbaf  1 : ms:0   lbads:12 rp:0x2 '
FAKE_SS_AFTER=4096
run_case "non-nvme mismatch is never reformatted -> refuse" 512 abort /dev/sdb

# 15. NVMe reformat command itself fails: never proceed on a half-formatted disk.
new_imgdir 15; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)\nlbaf  1 : ms:0   lbads:12 rp:0x2 '
FAKE_FMT_FAIL=1
run_case "nvme format fails -> refuse" 512 abort /dev/nvme0n1

# 16. NVMe reformat reports success but the sector size did not actually change:
# verify the new geometry before proceeding, else refuse.
new_imgdir 16; write_dump "$IMGDIR/d1.minimum.partitions" 4096
FAKE_LBAFS=$'lbaf  0 : ms:0   lbads:9  rp:0x1 (in use)\nlbaf  1 : ms:0   lbads:12 rp:0x2 '
FAKE_SS_AFTER=512
run_case "nvme format did not change sector size -> refuse" 512 abort /dev/nvme0n1

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
