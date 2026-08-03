#!/bin/bash
#
# Assertion harness for secureboot-funcs.sh.
#
#   tests/checks/secureboot.sh   # run all cases, exit non-zero on any failure
#
# What it proves: which firmware state FOS derives from efivarfs, and that the
# MOK staging path issues the right mokutil commands and refuses loudly when
# any of them does not do what it claimed. See
# docs/adr/0009-secure-boot-enrolment-paths.md
#
# Two properties here matter more than the rest:
#
#   - The one-time password must NEVER appear on a mokutil --import argv. It
#     travels via --hash-file, already hashed. A regression that reverted to
#     piping it would still pass a naive "did the import run" check.
#   - mokutil can exit 0 having staged nothing. sbStageMok re-reads --list-new
#     rather than trusting the status, because a request that silently did not
#     stage sends a technician to reboot a machine that boots straight past
#     MokManager with no explanation.
#
# Mechanism mirrors tests/checks/wipe.sh: source a sandbox copy of the library
# with its absolute paths rewritten into the sandbox, PATH-shadow the external
# tools with stubs that log their argv, and define handleError so a refusal is
# observable instead of exiting the test.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/secureboot-funcs.sh ]] || { echo "ERROR: cannot find secureboot-funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX

mkdir -p "$SANDBOX/proc" "$SANDBOX/bin"
: > "$SANDBOX/proc/mounts"

# /sys/firmware/efi and /proc/mounts are rewritten into the sandbox so state
# detection reads a fake firmware we control rather than this dev machine's.
# /tmp/.mokpwhash likewise, so a run never touches the host's /tmp.
sed -e "s#/sys/firmware/efi#$SANDBOX/sys/firmware/efi#g" \
    -e "s#/proc/mounts#$SANDBOX/proc/mounts#g" \
    -e "s#/tmp/.mokpwhash#$SANDBOX/mokpwhash#g" \
    "$REPO_LIB/secureboot-funcs.sh" > "$SANDBOX/secureboot-funcs.sh"

STUBBIN="$SANDBOX/bin"

# mokutil double. Logs argv, and each subcommand fails only under its own knob
# so a test can isolate one link of the chain.
cat > "$STUBBIN/mokutil" <<'EOF'
#!/bin/bash
echo "mokutil $*" >> "$SANDBOX/calls"
case "$1" in
    --generate-hash=*)
        [[ -n $FAKE_GENHASH_FAIL ]] && exit 1
        # A real SHA-512 crypt string shape. $FAKE_GENHASH_GARBAGE models
        # mokutil emitting something unparseable rather than failing outright.
        if [[ -n $FAKE_GENHASH_GARBAGE ]]; then
            echo "not-a-crypt-string"
        else
            echo '$6$abcdefghijklmnop$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx'
        fi
        ;;
    --import)
        [[ -n $FAKE_IMPORT_FAIL ]] && exit 1
        [[ -z $FAKE_IMPORT_NOOP ]] && : > "$SANDBOX/staged"
        ;;
    --list-new)
        [[ -f $SANDBOX/staged ]] && echo "[key 1]"
        ;;
    --test-key)
        [[ -n $FAKE_KEY_ENROLLED ]] && echo "SHA256 ... is already enrolled"
        ;;
    --db)
        echo "${FAKE_DB_OUT:-nothing here}"
        ;;
esac
exit 0
EOF

# curl double: writes whatever $FAKE_CURL_BODY says into the -o target.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$SANDBOX/calls"
dest=""
while [[ $# -gt 0 ]]; do
    [[ $1 == -o ]] && { dest="$2"; shift 2; continue; }
    shift
done
[[ -z $dest ]] && exit 0
case "${FAKE_CURL_BODY:-der}" in
    der)   printf '\x30\x82\x01\x0a\x02\x01\x00' > "$dest" ;;
    html)  printf '<!DOCTYPE html><h1>404</h1>'  > "$dest" ;;
    empty) : > "$dest" ;;
esac
exit 0
EOF

# mount double: records the efivarfs mount into the fake /proc/mounts.
cat > "$STUBBIN/mount" <<'EOF'
#!/bin/bash
echo "mount $*" >> "$SANDBOX/calls"
[[ -n $FAKE_MOUNT_FAIL ]] && exit 1
for a in "$@"; do
    case "$a" in
        "$SANDBOX"/sys/firmware/efi/efivars) echo "efivarfs $a efivarfs rw 0 0" >> "$SANDBOX/proc/mounts" ;;
    esac
done
exit 0
EOF

chmod 755 "$STUBBIN"/*

PASS=0
FAIL=0

# Build a fake firmware. $1 = SetupMode byte, $2 = SecureBoot byte; either may
# be "-" to leave that variable absent. Pass "noefi" as $1 for a BIOS machine.
make_firmware() {
    rm -rf "$SANDBOX/sys" >/dev/null 2>&1
    : > "$SANDBOX/proc/mounts"
    [[ $1 == noefi ]] && return 0
    local dir="$SANDBOX/sys/firmware/efi/efivars"
    mkdir -p "$dir"
    local guid="8be4df61-93ca-11d2-aa0d-00e098032b8c"
    # efivarfs layout: 4-byte LE attribute mask, then the data. Writing the
    # prefix is the point -- a reader that forgets it gets the attributes back
    # instead of the value, and 0x07 would read as "SetupMode=7".
    [[ $1 != - ]] && printf '\x07\x00\x00\x00'"$(printf '\\x%02x' "$1")" > "$dir/SetupMode-$guid"
    [[ $2 != - ]] && printf '\x07\x00\x00\x00'"$(printf '\\x%02x' "$2")" > "$dir/SecureBoot-$guid"
    [[ -z $FAKE_UNMOUNTED ]] && echo "efivarfs $dir efivarfs rw 0 0" >> "$SANDBOX/proc/mounts"
    return 0
}

# Run a snippet against the sandboxed library and echo its stdout.
lib() {
    (
        export PATH="$STUBBIN:$PATH"
        set +u
        handleError() { echo "HANDLEERROR: $1"; exit 90; }
        handleWarning() { echo "HANDLEWARNING: $1"; }
        web="http://fog.example/fog/"
        . "$SANDBOX/secureboot-funcs.sh"
        eval "$1"
    )
}

check() {
    local name="$1" got="$2" want="$3"
    if [[ $got == "$want" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (got \"$got\", want \"$want\")"
        FAIL=$((FAIL + 1))
    fi
}

new_case() {
    FAKE_GENHASH_FAIL=""; FAKE_GENHASH_GARBAGE=""; FAKE_IMPORT_FAIL=""
    FAKE_IMPORT_NOOP=""; FAKE_KEY_ENROLLED=""; FAKE_DB_OUT=""
    FAKE_CURL_BODY="der"; FAKE_MOUNT_FAIL=""; FAKE_UNMOUNTED=""
    export FAKE_GENHASH_FAIL FAKE_GENHASH_GARBAGE FAKE_IMPORT_FAIL \
           FAKE_IMPORT_NOOP FAKE_KEY_ENROLLED FAKE_DB_OUT FAKE_CURL_BODY \
           FAKE_MOUNT_FAIL FAKE_UNMOUNTED
    rm -f "$SANDBOX/calls" "$SANDBOX/staged" "$SANDBOX/mokpwhash" >/dev/null 2>&1
    : > "$SANDBOX/calls"
}

# --- firmware state detection ---

# 1. A BIOS/CSM boot has no /sys/firmware/efi at all. Secure Boot is not a
# concept there, and the task must say so rather than guess.
new_case; make_firmware noefi
check "no /sys/firmware/efi -> nonefi" "$(lib 'sbState')" "nonefi"

# 2. Setup Mode is the state the automatic db path needs, so it has to be
# distinguishable from merely "Secure Boot is off".
new_case; make_firmware 1 0
check "SetupMode=1 -> setup" "$(lib 'sbState')" "setup"

# 3. Secure Boot actively enforcing.
new_case; make_firmware 0 1
check "SetupMode=0 SecureBoot=1 -> enforcing" "$(lib 'sbState')" "enforcing"

# 4. User Mode with enforcement off. NOT the same as setup: db stays unwritable
# because the write policy follows the presence of a PK, not the enforcement
# bit. Conflating these two would make Phase 2 attempt a db write that silently
# fails on every machine whose owner merely toggled Secure Boot off.
new_case; make_firmware 0 0
check "SetupMode=0 SecureBoot=0 -> disabled" "$(lib 'sbState')" "disabled"

# 5. Setup Mode wins even with SecureBoot=1 -- firmware can report both during
# a key-clearing cycle, and the writable state is the one that matters.
new_case; make_firmware 1 1
check "SetupMode=1 SecureBoot=1 -> setup" "$(lib 'sbState')" "setup"

# 6. UEFI present but efivarfs will not mount: distinct from nonefi, because it
# is our problem to fix rather than the machine's nature.
new_case; FAKE_UNMOUNTED=1; FAKE_MOUNT_FAIL=1; export FAKE_UNMOUNTED FAKE_MOUNT_FAIL
make_firmware 0 1
check "efivarfs will not mount -> noefivars" "$(lib 'sbState')" "noefivars"

# 7. Unmounted but mountable: sbEnsureEfiVars mounts it and detection proceeds.
new_case; FAKE_UNMOUNTED=1; export FAKE_UNMOUNTED
make_firmware 0 1
check "efivarfs unmounted but mountable -> mounts, then enforcing" "$(lib 'sbState')" "enforcing"

# 8. The 4-byte attribute prefix must be skipped. Reading from offset 0 would
# return the attribute mask (7) instead of the value.
new_case; make_firmware 1 0
check "sbEfiFlag skips the 4-byte attribute prefix" "$(lib 'sbEfiFlag SetupMode')" "1"

# 9. An absent variable is not an error -- firmware need not expose every one.
new_case; make_firmware - 1
check "absent SetupMode -> falls through to SecureBoot" "$(lib 'sbState')" "enforcing"

# --- certificate fetch ---

# 10. A 404 still writes a body, so "the file exists" proves nothing. DER starts
# with an ASN.1 SEQUENCE tag (0x30); an HTML error page does not.
new_case; make_firmware 0 1; FAKE_CURL_BODY=html; export FAKE_CURL_BODY
check "HTML error page is rejected, not treated as a certificate" \
    "$(lib 'sbFetchCert "$SANDBOX/c.der" && echo ok || echo refused')" "refused"

# 11. An empty body is likewise not a certificate.
new_case; make_firmware 0 1; FAKE_CURL_BODY=empty; export FAKE_CURL_BODY
check "empty download is rejected" \
    "$(lib 'sbFetchCert "$SANDBOX/c.der" && echo ok || echo refused')" "refused"

# 12. A real DER body is accepted.
new_case; make_firmware 0 1
check "DER body is accepted" \
    "$(lib 'sbFetchCert "$SANDBOX/c.der" && echo ok || echo refused')" "ok"

# 13. The fingerprint is the SHA-256 of the DER bytes, formatted the way the
# server's Secure Boot page prints it -- the two are compared by eye.
new_case; make_firmware 0 1
printf '\x30\x82\x01\x0a' > "$SANDBOX/fp.der"
WANT_FP="$(sha256sum "$SANDBOX/fp.der" | awk '{print toupper($1)}' | sed 's/../&:/g;s/:$//')"
check "fingerprint is colon-separated uppercase SHA-256 of the DER" \
    "$(lib 'sbCertFingerprint "$SANDBOX/fp.der"')" "$WANT_FP"

# --- already-trusted detection ---

# 14. A key already in the MOK list must short-circuit, or every run sends a
# technician to a blue screen to re-enrol something already trusted.
new_case; make_firmware 0 1; FAKE_KEY_ENROLLED=1; export FAKE_KEY_ENROLLED
check "already-enrolled MOK is detected" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "trusted"

# 15. A machine enrolled through the Phase 2 db path has NO MOK entry, so the
# MOK check alone would wrongly stage a request on it.
new_case; make_firmware 0 1
printf '\x30\x82\x01\x0a' > "$SANDBOX/fp.der"
FAKE_DB_OUT="$(sha256sum "$SANDBOX/fp.der" | awk '{print toupper($1)}')"; export FAKE_DB_OUT
check "key present in db (no MOK entry) is detected as trusted" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "trusted"

# 16. Neither list -> not trusted.
new_case; make_firmware 0 1
check "key in neither MOK nor db -> untrusted" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "untrusted"

# --- MOK staging ---

# 17. Happy path.
new_case; make_firmware 0 1
check "17. staging succeeds on the happy path" \
    "$(lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null && echo ok || echo refused')" "ok"

# 18. The password must reach mokutil ONLY as a pre-computed hash file. If it
# ever appears on an --import argv it is visible in ps output and in any
# command log, and the change that put it there has reverted the whole reason
# --generate-hash/--hash-file are used.
new_case; make_firmware 0 1
lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null' >/dev/null 2>&1
IMPORT_LINE="$(grep -- '--import' "$SANDBOX/calls" 2>/dev/null)"
if [[ -n $IMPORT_LINE && $IMPORT_LINE == *"--hash-file"* && $IMPORT_LINE != *hunter2* ]]; then
    echo "PASS: 18. password never appears on the --import argv"
    PASS=$((PASS + 1))
else
    echo "FAIL: 18. password leaked onto --import argv or --hash-file missing (\"$IMPORT_LINE\")"
    FAIL=$((FAIL + 1))
fi

# 19. --generate-hash must be the non-interactive =PASSWORD form. The bare form
# prompts on a terminal that does not exist in a task, and the task would hang
# until the 60s handleError timeout with no indication why.
new_case; make_firmware 0 1
lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null' >/dev/null 2>&1
if grep -q -- '--generate-hash=hunter2' "$SANDBOX/calls" 2>/dev/null; then
    echo "PASS: 19. generate-hash uses the non-interactive =PASSWORD form"
    PASS=$((PASS + 1))
else
    echo "FAIL: 19. generate-hash was not called in its non-interactive form"
    FAIL=$((FAIL + 1))
fi

# 20. Hash generation failing must refuse, and must NOT go on to import.
new_case; make_firmware 0 1; FAKE_GENHASH_FAIL=1; export FAKE_GENHASH_FAIL
GOT="$(lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null && echo ok || echo refused')"
if [[ $GOT == refused ]] && ! grep -q -- '--import' "$SANDBOX/calls" 2>/dev/null; then
    echo "PASS: 20. hash generation failure refuses without importing"
    PASS=$((PASS + 1))
else
    echo "FAIL: 20. hash generation failure did not refuse cleanly (got \"$GOT\")"
    FAIL=$((FAIL + 1))
fi

# 21. An unparseable hash must be caught here, not handed to mokutil to fail on
# later with "Failed to parse the string" after the request is half-built.
new_case; make_firmware 0 1; FAKE_GENHASH_GARBAGE=1; export FAKE_GENHASH_GARBAGE
GOT="$(lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null && echo ok || echo refused')"
if [[ $GOT == refused ]] && ! grep -q -- '--import' "$SANDBOX/calls" 2>/dev/null; then
    echo "PASS: 21. malformed hash refuses without importing"
    PASS=$((PASS + 1))
else
    echo "FAIL: 21. malformed hash did not refuse cleanly (got \"$GOT\")"
    FAIL=$((FAIL + 1))
fi

# 22. A failing import must refuse.
new_case; make_firmware 0 1; FAKE_IMPORT_FAIL=1; export FAKE_IMPORT_FAIL
check "22. failing import refuses" \
    "$(lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null && echo ok || echo refused')" "refused"

# 23. THE silent-failure guard. mokutil exits 0 but staged nothing. Trusting the
# exit status here reports a pending enrolment that does not exist, and the
# technician reboots into a normal boot with no explanation.
new_case; make_firmware 0 1; FAKE_IMPORT_NOOP=1; export FAKE_IMPORT_NOOP
check "23. import exits 0 but stages nothing -> refuse" \
    "$(lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null && echo ok || echo refused')" "refused"

# 24. The hash file must not be left behind. It is a crypt string for a password
# the technician is about to type, and /tmp is world-readable.
new_case; make_firmware 0 1
lib 'sbStageMok "$SANDBOX/fp.der" hunter2 >/dev/null' >/dev/null 2>&1
if [[ ! -f $SANDBOX/mokpwhash ]]; then
    echo "PASS: 24. hash file is removed after staging"
    PASS=$((PASS + 1))
else
    echo "FAIL: 24. hash file left behind at $SANDBOX/mokpwhash"
    FAIL=$((FAIL + 1))
fi

# --- password selection ---

# 25. A fleet-wide password lets a technician type the same thing down a row of
# machines instead of reading a different string off each screen.
new_case; make_firmware 0 1
check "25. \$sbmokpw is used when set" "$(lib 'sbmokpw=fleetpw; sbMokPassword')" "fleetpw"

# 26. Without one, a usable password is still produced -- the task must not
# depend on a setting the admin may never have seen.
new_case; make_firmware 0 1
GOT="$(lib 'sbMokPassword')"
if [[ ${#GOT} -eq 8 && $GOT =~ ^[A-HJ-NP-Z2-9]+$ ]]; then
    echo "PASS: 26. random fallback password is 8 unambiguous characters"
    PASS=$((PASS + 1))
else
    echo "FAIL: 26. random fallback password was \"$GOT\""
    FAIL=$((FAIL + 1))
fi

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
