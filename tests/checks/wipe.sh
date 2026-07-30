#!/bin/bash
#
# Assertion harness for wipeDisk() and its helpers in funcs.sh.
#
#   tests/checks/wipe.sh        # run all cases, exit non-zero on any failure
#
# The behaviour under test is "which erase primitive did we actually issue, and
# did we refuse when it failed" -- a pass/fail assertion a single golden output
# stream can't express, so this is a sibling to the golden harness rather than a
# case inside it. See docs/adr/0008-secure-wipe-by-device-class.md
#
# The regression that motivated it: `nvme format` with no --ses sends SES=0
# ("no secure erase requested"), which reformats namespace metadata without any
# guarantee that user data is erased. Several cases below assert that no wipe
# path can ever issue a format without an explicit --ses.
#
# Mechanism mirrors tests/checks/sector-size.sh: source a sandbox copy of the
# library with its hardcoded paths rewritten, PATH-shadow the external tools with
# deterministic stubs that log their argv, and override handleError AFTER sourcing
# so a refusal is observable instead of exiting the test.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- sandbox copy of the library with host-absolute paths rewritten ---
# /sys/block is rewritten into the sandbox so diskClass() reads a fake sysfs we
# control (rotational flag) instead of the dev machine's real disks.
cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    -e "s#/sys/block#$SANDBOX/sys/block#g" \
    -e "s#/sys/class/scsi_host#$SANDBOX/sys/class/scsi_host#g" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

# Fake sysfs: sda is rotational (hdd), sdb is not (ssd). sdz has no entry at all,
# exercising the "kernel doesn't say" -> unknown path.
mkdir -p "$SANDBOX/sys/block/sda/queue" "$SANDBOX/sys/block/sdb/queue"
echo 1 > "$SANDBOX/sys/block/sda/queue/rotational"
echo 0 > "$SANDBOX/sys/block/sdb/queue/rotational"

# --- deterministic stubs; each logs its full argv to $SANDBOX/calls ---
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# nvme-cli double. id-ctrl reports $FAKE_SANICAP/$FAKE_FNA so a test can model a
# drive that does or does not advertise sanitize/crypto-erase. format fails if
# $FAKE_FMT_FAIL. sanitize fails to start if $FAKE_SAN_START_FAIL. sanitize-log
# replays whitespace-separated $FAKE_SSTAT_SEQ values, one per poll, so a test can
# model in-progress -> completed, or a mid-sanitize failure.
#
# The JSON below is the REAL nvme-cli 2.x shape, transcribed from the source that
# emits it (nvme-print-json.c:json_sanitize_log, unchanged between 2.15 -- what
# Buildroot pins -- and 2.16). Getting this wrong is not hypothetical: this stub
# used to emit an invented flat {"sstat":2,"sprog":N}, every case here passed
# against it, and the real parse failed on the first poll of a real drive, because
# the payload is nested under a device key and sstat is an object whose status is
# a string. A stub that encodes our assumption tests nothing. If these fields ever
# need to change, change them to match captured output from a real drive.
cat > "$STUBBIN/nvme" <<'EOF'
#!/bin/bash
echo "nvme $*" >> "$SANDBOX/calls"
case "$1" in
    id-ctrl)
        # id-ctrl really is flat at the root, unlike sanitize-log.
        printf '{"sanicap":%s,"fna":%s}\n' "${FAKE_SANICAP:-0}" "${FAKE_FNA:-0}"
        ;;
    format)
        [[ -n $FAKE_FMT_FAIL ]] && { echo "NVMe status: SANITIZE_IN_PROGRESS(1d)" >&2; exit 1; }
        ;;
    sanitize)
        # --sanact=1 is Exit Failure Mode (recovery), not an erase; it must still
        # work when $FAKE_SAN_START_FAIL models an erase being refused. It fails
        # only under its own knob, $FAKE_SAN_EXIT_FAIL.
        if [[ $* == *"--sanact=1"* ]]; then
            [[ -n $FAKE_SAN_EXIT_FAIL ]] && { echo "NVMe status: INTERNAL(6)" >&2; exit 1; }
            exit 0
        fi
        [[ -n $FAKE_SAN_START_FAIL ]] && { echo "NVMe status: INVALID_FIELD(2)" >&2; exit 1; }
        : > "$SANDBOX/san_started"
        ;;
    sanitize-log)
        n=0
        [[ -f $SANDBOX/pollcount ]] && n=$(<"$SANDBOX/pollcount")
        set -- $FAKE_SSTAT_SEQ
        idx=$((n + 1)); echo "$idx" > "$SANDBOX/pollcount"
        eval "val=\${$idx}"
        [[ -z $val ]] && val="${@: -1}"
        [[ $val == "BADLOG" ]] && { echo '{}'; exit 0; }
        printf '{"/dev/nvme0":{"sprog":32768,"sstat":{"media_verification_canceled":0,"global_erased":0,"no_cmplted_passes":0,"status":"(%s) stub status."},"cdw10_info":2}}\n' "$val"
        ;;
esac
exit 0
EOF
chmod +x "$STUBBIN/nvme"

# jq parses the nvme JSON, and the harness needs a real one: the sanitize log is
# nested and its status is a string, which a sed-based shim cannot honestly
# extract. A shim that half-parses would be the same trap as the flat-JSON stub
# above -- it would pass while the real thing failed. Require the real tool.
command -v jq >/dev/null 2>&1 || { echo "ERROR: this harness needs jq (FOS ships BR2_PACKAGE_JQ)" >&2; exit 2; }

# shred/dd doubles: log argv, fail if the matching FAKE_*_FAIL knob is set.
for tool in shred dd; do
    cat > "$STUBBIN/$tool" <<EOF
#!/bin/bash
echo "$tool \$*" >> "\$SANDBOX/calls"
varname="FAKE_\$(echo $tool | tr '[:lower:]' '[:upper:]')_FAIL"
[[ -n \${!varname} ]] && exit 1
exit 0
EOF
    chmod +x "$STUBBIN/$tool"
done

# No-op double for the pacing sleep so the poll loop runs instantly.
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/usleep"
chmod +x "$STUBBIN/usleep"

PASS=0
FAIL=0

# run_case <name> <disk> <mode> <expect: ok|fail> [want_call] [forbid_call]
# want_call, if given, must appear in the logged tool calls; forbid_call must NOT.
# Both are substring matches against the stub call log.
run_case() {
    local name="$1" disk="$2" mode="$3" expect="$4" want_call="$5" forbid_call="$6"
    local out calls got
    rm -f "$SANDBOX/calls" "$SANDBOX/pollcount" "$SANDBOX/san_started"
    out="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX="$SANDBOX"
        export FAKE_SANICAP FAKE_FNA FAKE_FMT_FAIL FAKE_SAN_START_FAIL FAKE_SAN_EXIT_FAIL FAKE_SSTAT_SEQ FAKE_SHRED_FAIL FAKE_DD_FAIL
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT: $*"; }
        if wipeDisk "$disk" "$mode"; then echo "RC:ok"; else echo "RC:fail"; fi
    )"
    calls="$(cat "$SANDBOX/calls" 2>/dev/null)"
    if [[ $out == *"RC:ok"* ]]; then got="ok"; else got="fail"; fi
    local why=""
    [[ $got != "$expect" ]] && why="expected $expect, got $got"
    [[ -n $want_call && $calls != *"$want_call"* ]] && why="${why:+$why; }missing call \"$want_call\""
    [[ -n $forbid_call && $calls == *"$forbid_call"* ]] && why="${why:+$why; }made forbidden call \"$forbid_call\""
    if [[ -z $why ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name ($why)"
        echo "      calls: $(printf '%s' "$calls" | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

new_case() { FAKE_SANICAP=0; FAKE_FNA=0; FAKE_FMT_FAIL=""; FAKE_SAN_START_FAIL=""; FAKE_SAN_EXIT_FAIL=""; FAKE_SSTAT_SEQ="1"; FAKE_SHRED_FAIL=""; FAKE_DD_FAIL=""; }

# --- device classification ---

new_case
CLASS_OUT="$(export PATH="$STUBBIN:$PATH"; set +u; . "$SANDBOX/funcs.sh"; \
    echo "$(diskClass /dev/nvme0n1) $(diskClass /dev/sda) $(diskClass /dev/sdb) $(diskClass /dev/sdz)")"
if [[ $CLASS_OUT == "nvme hdd ssd unknown" ]]; then
    echo "PASS: diskClass maps nvme/rotational/non-rotational/no-sysfs"
    PASS=$((PASS + 1))
else
    echo "FAIL: diskClass (got \"$CLASS_OUT\", want \"nvme hdd ssd unknown\")"
    FAIL=$((FAIL + 1))
fi

CTRL_OUT="$(export PATH="$STUBBIN:$PATH"; set +u; . "$SANDBOX/funcs.sh"; \
    echo "$(nvmeCtrlOf /dev/nvme0n1) $(nvmeCtrlOf /dev/nvme12n3)")"
if [[ $CTRL_OUT == "/dev/nvme0 /dev/nvme12" ]]; then
    echo "PASS: nvmeCtrlOf derives the controller from the namespace"
    PASS=$((PASS + 1))
else
    echo "FAIL: nvmeCtrlOf (got \"$CTRL_OUT\", want \"/dev/nvme0 /dev/nvme12\")"
    FAIL=$((FAIL + 1))
fi

# --- NVMe: the erase must always carry an explicit --ses ---

# 1. The core regression. A normal NVMe wipe must issue --ses=1 (user data
# erase). SES=0 is "no secure erase requested" and erases nothing.
new_case
run_case "nvme normal -> format --ses=1" /dev/nvme0n1 normal ok "format /dev/nvme0n1 --ses=1"

# 2. Drive advertising crypto erase (FNA bit 2) on a fast wipe -> --ses=2.
new_case; FAKE_FNA=4
run_case "nvme fast with crypto support -> format --ses=2" /dev/nvme0n1 fast ok "format /dev/nvme0n1 --ses=2"

# 3. Drive WITHOUT crypto erase on a fast wipe must fall back to --ses=1, never
# to a bare format.
new_case; FAKE_FNA=0
run_case "nvme fast without crypto support -> falls back to --ses=1" /dev/nvme0n1 fast ok \
    "format /dev/nvme0n1 --ses=1"

# 4. Full wipe on a drive advertising block erase (SANICAP bit 1) -> sanitize.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 2 1"
run_case "nvme full with sanitize support -> sanitize --sanact=2" /dev/nvme0n1 full ok \
    "sanitize /dev/nvme0 --sanact=2"

# 5. Full wipe on a drive with NO sanitize support -> format --ses=1, and no
# sanitize is ever issued.
new_case; FAKE_SANICAP=0
run_case "nvme full without sanitize support -> format --ses=1, no sanitize" /dev/nvme0n1 full ok \
    "format /dev/nvme0n1 --ses=1" "sanitize"

# 6. Sanitize command rejected at start -> fall back to format --ses=1 and still
# succeed (both are a real erase, so the fallback is safe).
new_case; FAKE_SANICAP=2; FAKE_SAN_START_FAIL=1
run_case "nvme full, sanitize rejected -> falls back to format --ses=1" /dev/nvme0n1 full ok \
    "format /dev/nvme0n1 --ses=1"

# 7. Sanitize starts then reports failure (sstat 3). A failed sanitize leaves the
# controller aborting commands with "Sanitize Failed" (0x1c) until a recovery
# action completes, so the format fallback is only reachable after Exit Failure
# Mode (--sanact=1) is issued.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 3"
run_case "nvme full, sanitize fails mid-run -> exits failure mode first" /dev/nvme0n1 full ok \
    "sanitize /dev/nvme0 --sanact=1"

# 7b. ...and then does fall back to a real erase.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 3"
run_case "nvme full, sanitize fails mid-run -> falls back to format --ses=1" /dev/nvme0n1 full ok \
    "format /dev/nvme0n1 --ses=1"

# 7c. If the failure mode cannot be cleared, a format would just be rejected too,
# so we must refuse rather than issue one and report its failure as the wipe's.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 3"; FAKE_SAN_EXIT_FAIL=1
run_case "nvme full, failure mode won't clear -> refuse, no format" /dev/nvme0n1 full fail "" "format"

# 8. Sanitize completes with forced deallocation (sstat 4) -> success.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 4"
run_case "nvme full, sanitize completes with forced dealloc -> ok" /dev/nvme0n1 full ok \
    "sanitize /dev/nvme0 --sanact=2"

# 8b. A confirmed sanitize must never be followed by a format. The drive is
# already erased; the only reason to issue one would be a misread log.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 2 1"
run_case "nvme full, sanitize completes -> no format afterwards" /dev/nvme0n1 full ok "" "format"

# 9. Unreadable sanitize log AFTER the sanitize started. The regression this
# harness missed: the log parse failed on the first poll, the code called that
# "sanitize failed", and fell back to a format that the controller rejects with
# "Sanitize In Progress" (0x1d) -- then told the operator the disk still held its
# data while it was in fact being erased. Must refuse, and must NOT issue a
# format: once a sanitize is running, no format can be meaningful.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="2 BADLOG"
run_case "nvme full, unreadable log mid-sanitize -> refuse, no format" /dev/nvme0n1 full fail "" "format"

# 9b. The same, unreadable from the very first poll -- the exact shape of the
# field-name mismatch that shipped.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="BADLOG"
run_case "nvme full, log unreadable from first poll -> refuse, no format" /dev/nvme0n1 full fail "" "format"

# 9c. An unconfirmable sanitize must not tell the operator the data survived.
# That claim was wrong precisely when it mattered most.
new_case; FAKE_SANICAP=2; FAKE_SSTAT_SEQ="BADLOG"
UNCONF_OUT="$(
    set +u; export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
    export FAKE_SANICAP FAKE_SSTAT_SEQ
    . "$SANDBOX/funcs.sh"; wipeDisk /dev/nvme0n1 full
)"
if [[ $UNCONF_OUT == *"could not be confirmed"* && $UNCONF_OUT == *"nvme sanitize-log /dev/nvme0"* ]]; then
    echo "PASS: unconfirmable sanitize reports unknown, not \"data intact\""
    PASS=$((PASS + 1))
else
    echo "FAIL: unconfirmable sanitize did not tell the operator how to check the drive"
    FAIL=$((FAIL + 1))
fi

# 10. The format itself fails -> refuse. This is the fail-loud case: the old code
# ignored the exit status and printed "Wiping complete."
new_case; FAKE_FMT_FAIL=1
run_case "nvme format fails -> refuse" /dev/nvme0n1 normal fail

# --- non-NVMe classes ---

# 11. Rotational disk, full -> 3-pass shred with a zero pass.
new_case
run_case "hdd full -> shred -n 3 -z" /dev/sda full ok "shred -f -v -z -n 3 /dev/sda"

# 12. Rotational disk, normal -> single-pass shred.
new_case
run_case "hdd normal -> shred -n 1" /dev/sda normal ok "shred -f -v -n 1 /dev/sda"

# 13. Rotational disk, fast -> zeros over the metadata only.
new_case
run_case "hdd fast -> dd zeros" /dev/sda fast ok "dd if=/dev/zero of=/dev/sda"

# 14. shred failing -> refuse rather than report a completed wipe.
new_case; FAKE_SHRED_FAIL=1
run_case "hdd full, shred fails -> refuse" /dev/sda full fail

# 15. dd failing -> refuse.
new_case; FAKE_DD_FAIL=1
run_case "hdd fast, dd fails -> refuse" /dev/sda fast fail

# 16. A SATA SSD is still overwritten (deferred work), but the operator must be
# told the overwrite is not a guaranteed erase.
new_case
SSD_OUT="$(
    set +u; export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
    . "$SANDBOX/funcs.sh"; wipeDisk /dev/sdb full
)"
if [[ $SSD_OUT == *"NOT a guaranteed erase"* ]]; then
    echo "PASS: ssd normal/full warns the overwrite is not a guaranteed erase"
    PASS=$((PASS + 1))
else
    echo "FAIL: ssd wipe did not warn about wear levelling"
    FAIL=$((FAIL + 1))
fi

# 17. An unknown-class device is treated as possibly-flash and warned about too.
new_case
UNK_OUT="$(
    set +u; export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
    . "$SANDBOX/funcs.sh"; wipeDisk /dev/sdz normal
)"
if [[ $UNK_OUT == *"NOT a guaranteed erase"* ]]; then
    echo "PASS: unknown-class device warns like an ssd"
    PASS=$((PASS + 1))
else
    echo "FAIL: unknown-class device did not warn"
    FAIL=$((FAIL + 1))
fi

# 18. A rotational disk must NOT get the SSD warning -- overwriting really does
# erase it, and a warning everywhere would train operators to ignore it.
new_case
HDD_OUT="$(
    set +u; export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
    . "$SANDBOX/funcs.sh"; wipeDisk /dev/sda full
)"
if [[ $HDD_OUT != *"NOT a guaranteed erase"* ]]; then
    echo "PASS: hdd wipe does not emit the ssd warning"
    PASS=$((PASS + 1))
else
    echo "FAIL: hdd wipe wrongly emitted the ssd warning"
    FAIL=$((FAIL + 1))
fi

# --- mode validation ---

# 19. An unknown mode must refuse, not silently do nothing. The old case
# statement fell through and still reported "Wiping complete."
new_case
run_case "unknown mode -> refuse, touch nothing" /dev/sda bogus fail "" "shred"

# 20. An empty mode (malformed task) must refuse rather than default to wiping.
new_case
run_case "empty mode -> refuse, touch nothing" /dev/sda "" fail "" "shred"

# 21. Mode validation must sit AHEAD of the nvme dispatch. nvmeSecureErase treats
# any mode it doesn't recognise as "not full, not fast" and issues a format
# --ses=1, so an unknown mode on an NVMe target would erase the drive even though
# the same mode refuses on /dev/sda. Guards that asymmetry.
new_case
run_case "unknown mode on nvme -> refuse, no format" /dev/nvme0n1 bogus fail "" "format"

# 22. Same for an empty mode on NVMe.
new_case
run_case "empty mode on nvme -> refuse, no format" /dev/nvme0n1 "" fail "" "format"

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
