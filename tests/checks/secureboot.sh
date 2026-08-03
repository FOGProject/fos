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
# One rule covers every quoted /tmp path the library writes to (.mokpwhash,
# .sbauth.*, the downloaded *.auth files) so a run never touches the host's /tmp.
#
# It MUST run before the /sys and /proc rules. $SANDBOX is itself under /tmp, so
# a rule that has already rewritten a path to "$SANDBOX/sys/..." leaves a line
# that this rule would match again and prefix a second time.
sed -e "s#\"/tmp/#\"$SANDBOX/#g" \
    -e "s#/sys/firmware/efi#$SANDBOX/sys/firmware/efi#g" \
    -e "s#/proc/mounts#$SANDBOX/proc/mounts#g" \
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
        # VERBATIM mokutil 0.7.2 output. Taken from the format strings in the
        # binary, NOT invented: an earlier version of this stub printed a
        # SHA-256 and the phrase "is already enrolled", which is what
        # sbCertTrusted was grepping for -- so the stub and the bug agreed with
        # each other and the case passed while the real thing failed on
        # hardware. If this ever needs changing, read it out of mokutil again.
        if [[ -n $FAKE_KEY_ENROLLED ]]; then
            echo "CA of $2 is already enrolled"
        elif [[ -n $FAKE_KEY_IN_DB ]]; then
            echo "$2 is already in db"
        else
            echo "$2 is not enrolled"
        fi
        ;;
esac
exit 0
EOF

# curl double: writes whatever $FAKE_CURL_BODY says into the -o target. A .auth
# URL gets an authenticated-variable body instead of a certificate, so one stub
# serves both fetch paths; $FAKE_AUTH_FAIL names one variable whose download
# should fail, which is how the "fetch everything before writing anything"
# property gets tested.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$SANDBOX/calls"
dest=""; url=""
while [[ $# -gt 0 ]]; do
    [[ $1 == -o ]] && { dest="$2"; shift 2; continue; }
    url="$1"; shift
done
[[ -z $dest ]] && exit 0
if [[ $url == *.auth ]]; then
    name="${url##*/}"; name="${name%.auth}"
    if [[ -n $FAKE_AUTH_FAIL && $name == "$FAKE_AUTH_FAIL" ]]; then
        printf '<!DOCTYPE html><h1>404</h1>' > "$dest"
        exit 0
    fi
    if [[ -n $FAKE_AUTH_GARBAGE && $name == "$FAKE_AUTH_GARBAGE" ]]; then
        # Full length, plausible shape, wrong magic: a truncated or mangled
        # download rather than an error page.
        head -c 64 /dev/zero > "$dest"
        exit 0
    fi
    # 16-byte EFI_TIME, dwLength, wRevision=0x0200, wCertificateType=0x0EF1,
    # then filler standing in for the GUID and PKCS#7 blob. Only the four bytes
    # at offset 20 are load-bearing for the validator under test.
    {
        printf '\xea\x07\x08\x03\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        printf '\x30\x00\x00\x00\x00\x02\xf1\x0e'
        printf 'AUTHBODY-%s-PADDINGPADDINGPADDING' "$name"
    } > "$dest"
    exit 0
fi
case "${FAKE_CURL_BODY:-der}" in
    der)   printf '\x30\x82\x01\x0a\x02\x01\x00' > "$dest" ;;
    html)  printf '<!DOCTYPE html><h1>404</h1>'  > "$dest" ;;
    empty) : > "$dest" ;;
esac
exit 0
EOF

# chattr double. The real one cannot run on the tmpfs sandbox, and the call is
# fire-and-forget in the library, so the stub exists to make "did it clear the
# immutable flag before writing" observable at all.
cat > "$STUBBIN/chattr" <<'EOF'
#!/bin/bash
echo "chattr $*" >> "$SANDBOX/calls"
exit 0
EOF

# dd double: logs argv, then hands off to the real dd so the variable file ends
# up with the bytes actually written. $FAKE_DD_FAIL names one variable whose
# write should fail, so an abort mid-sequence can be tested.
cat > "$STUBBIN/dd" <<'EOF'
#!/bin/bash
echo "dd $*" >> "$SANDBOX/calls"
out=""
for a in "$@"; do
    [[ $a == of=* ]] && out="${a#of=}"
done
if [[ -n $FAKE_DD_FAIL && ${out##*/} == "$FAKE_DD_FAIL"-* ]]; then
    exit 1
fi
/usr/bin/dd "$@" || exit 1
# Writing a PK is what takes a platform out of Setup Mode. Modelling that here
# is the only way to test that sbEnrollDb confirms the enrolment from the
# firmware rather than from dd's exit status.
if [[ ${out##*/} == PK-* && -z $FAKE_PK_KEEPS_SETUP ]]; then
    guid="8be4df61-93ca-11d2-aa0d-00e098032b8c"
    printf '\x07\x00\x00\x00\x00' > "${out%/*}/SetupMode-$guid"
fi
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

# Build a db variable holding $1 inside an EFI_SIGNATURE_LIST, the way firmware
# stores it: 4-byte efivarfs attribute prefix, then a 16-byte EFI_CERT_X509_GUID,
# SignatureListSize, SignatureHeaderSize(0), SignatureSize, then a 16-byte owner
# GUID followed by the DER. Built out of the real layout rather than a
# placeholder, because the code under test searches for the certificate's bytes
# and a fake shape would prove nothing.
make_db_with_cert() {
    local cert="$1"
    local dir="$SANDBOX/sys/firmware/efi/efivars"
    local guid="d719b2cb-3d3a-4596-a3bc-dad00e67656f"
    mkdir -p "$dir"
    local certsz sigsz listsz
    certsz=$(stat -c %s "$cert")
    sigsz=$((certsz + 16))
    listsz=$((sigsz + 28))
    {
        printf '\x27\x00\x00\x00'
        printf '\xa1\x59\xc0\xa5\xe4\x94\xa7\x4a\x87\xb5\xab\x15\x5c\x2b\xf0\x72'
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
            $((listsz & 255)) $(((listsz >> 8) & 255)) $(((listsz >> 16) & 255)) $(((listsz >> 24) & 255)))"
        printf '\x00\x00\x00\x00'
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
            $((sigsz & 255)) $(((sigsz >> 8) & 255)) $(((sigsz >> 16) & 255)) $(((sigsz >> 24) & 255)))"
        printf '\x44\xe4\x62\xf0\xc9\x51\xe8\x41\x8e\xa3\xd4\x40\x7a\xe3\x8e\x04'
        cat "$cert"
    } > "$dir/db-$guid"
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
    FAKE_IMPORT_NOOP=""; FAKE_KEY_ENROLLED=""; FAKE_KEY_IN_DB=""
    FAKE_CURL_BODY="der"; FAKE_MOUNT_FAIL=""; FAKE_UNMOUNTED=""
    FAKE_AUTH_FAIL=""; FAKE_DD_FAIL=""; FAKE_PK_KEEPS_SETUP=""
    FAKE_AUTH_GARBAGE=""
    export FAKE_GENHASH_FAIL FAKE_GENHASH_GARBAGE FAKE_IMPORT_FAIL \
           FAKE_IMPORT_NOOP FAKE_KEY_ENROLLED FAKE_KEY_IN_DB FAKE_CURL_BODY \
           FAKE_MOUNT_FAIL FAKE_UNMOUNTED FAKE_AUTH_FAIL FAKE_DD_FAIL \
           FAKE_PK_KEEPS_SETUP FAKE_AUTH_GARBAGE
    rm -f "$SANDBOX/calls" "$SANDBOX/staged" "$SANDBOX/.mokpwhash" >/dev/null 2>&1
    rm -f "$SANDBOX"/*.auth "$SANDBOX"/.sbauth.* >/dev/null 2>&1
    : > "$SANDBOX/calls"
}

# The two namespaces db/KEK/PK live in. Kept here as literals rather than read
# from the library, so a test failure means the library changed, not that the
# test followed it.
GLOBAL_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
SECURITY_GUID="d719b2cb-3d3a-4596-a3bc-dad00e67656f"
EFIVARS="$SANDBOX/sys/firmware/efi/efivars"

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

# 15. THE REGRESSION THIS FILE EXISTS FOR. A machine enrolled through the Setup
# Mode path has the certificate in db and NO MOK entry at all. This case passed
# for a fortnight against a stub that printed the SHA-256 the (wrong) code was
# grepping for; mokutil actually prints a SHA1 there, so on real hardware the
# task went on to stage a MOK, which mokutil refused because the certificate was
# already in db, and the task aborted.
#
# So this now answers the question the way the firmware does: put the
# certificate's real bytes inside a real EFI_SIGNATURE_LIST in a real db
# variable, and require sbCertTrusted to find them. mokutil is told the key is
# NOT enrolled, so only the db path can satisfy it.
new_case; make_firmware 0 1
printf '\x30\x82\x01\x0a\xde\xad\xbe\xef' > "$SANDBOX/fp.der"
make_db_with_cert "$SANDBOX/fp.der"
check "15. certificate present in db (no MOK entry) is detected as trusted" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "trusted"

# 15b. mokutil's own db verdict is the fallback for firmware whose db this code
# cannot read directly. Matched on the string mokutil really prints.
new_case; make_firmware 0 1; FAKE_KEY_IN_DB=1; export FAKE_KEY_IN_DB
check "15b. mokutil \"is already in db\" is honoured" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "trusted"

# 15c. A DIFFERENT certificate in db must not read as trusted -- otherwise the
# byte search is matching something incidental rather than this certificate.
new_case; make_firmware 0 1
printf '\x30\x82\x01\x0a\xde\xad\xbe\xef' > "$SANDBOX/other.der"
make_db_with_cert "$SANDBOX/other.der"
printf '\x30\x82\x01\x0a\xca\xfe\xba\xbe' > "$SANDBOX/fp.der"
check "15c. a different certificate in db does not read as trusted" \
    "$(lib 'sbCertTrusted "$SANDBOX/fp.der" && echo trusted || echo untrusted')" "untrusted"

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
if [[ ! -f $SANDBOX/.mokpwhash ]]; then
    echo "PASS: 24. hash file is removed after staging"
    PASS=$((PASS + 1))
else
    echo "FAIL: 24. hash file left behind at $SANDBOX/.mokpwhash"
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

# --- the Setup Mode (db) path ---

# 27. A signed variable update is recognised by its
# EFI_VARIABLE_AUTHENTICATION_2 header, not by being non-empty.
new_case; make_firmware 1 0
check "27. a well-formed .auth is accepted" \
    "$(lib 'sbFetchAuthVar db "$SANDBOX/x.auth" && echo ok || echo refused')" "ok"

# 28. An HTML error page is longer than the header it would have to match, so a
# size check alone would pass it. A client that wrote one into db would enrol
# nothing and report success.
new_case; make_firmware 1 0; FAKE_AUTH_FAIL=db; export FAKE_AUTH_FAIL
check "28. an HTML error page is not mistaken for a .auth" \
    "$(lib 'sbFetchAuthVar db "$SANDBOX/x.auth" && echo ok || echo refused')" "refused"

# 29. Right length, wrong magic -- models a truncated or mangled download.
new_case; make_firmware 1 0; FAKE_AUTH_GARBAGE=db; export FAKE_AUTH_GARBAGE
check "29. a body with the wrong wRevision/wCertificateType is refused" \
    "$(lib 'sbFetchAuthVar db "$SANDBOX/x.auth" && echo ok || echo refused')" "refused"

# 30. THE namespace trap. db and dbx live under
# EFI_IMAGE_SECURITY_DATABASE_GUID, while PK/KEK live under the global GUID.
# Writing "db" under the global GUID creates a junk variable that firmware
# ignores -- and efivarfs accepts the write, so it looks like it worked.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
if [[ -s $EFIVARS/db-$SECURITY_GUID && ! -e $EFIVARS/db-$GLOBAL_GUID ]]; then
    echo "PASS: 30. db is written under the image-security GUID, not the global one"
    PASS=$((PASS + 1))
else
    echo "FAIL: 30. db went to the wrong namespace"
    FAIL=$((FAIL + 1))
fi

# 31. KEK and PK go under the global GUID.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
if [[ -s $EFIVARS/KEK-$GLOBAL_GUID && -s $EFIVARS/PK-$GLOBAL_GUID ]]; then
    echo "PASS: 31. KEK and PK are written under the global GUID"
    PASS=$((PASS + 1))
else
    echo "FAIL: 31. KEK/PK went to the wrong namespace"
    FAIL=$((FAIL + 1))
fi

# 32. Write ORDER, and it is not cosmetic. Writing PK is what leaves Setup Mode;
# after that every write must carry a signature the firmware checks. PK first
# would make the db and KEK writes bounce, leaving a machine that enforces
# Secure Boot and trusts nothing -- recoverable only at the firmware screen.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
ORDER="$(grep '^dd ' "$SANDBOX/calls" | sed -n 's#.*of=[^ ]*/\([A-Za-z]*\)-.*#\1#p' | tr '\n' ' ')"
check "32. write order is db, KEK, PK (PK last)" "$ORDER" "db KEK PK "

# 33. The 4-byte attribute prefix must be 0x27 little-endian:
# NV|BS|RT|TIME_BASED_AUTHENTICATED_WRITE_ACCESS. Drop the authenticated bit and
# the firmware stores the payload as raw data instead of applying it as a signed
# update -- which efivarfs accepts without complaint.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
check "33. attribute prefix is 0x27 little-endian" \
    "$(od -An -tx1 -N4 "$EFIVARS/db-$SECURITY_GUID" 2>/dev/null | tr -d '[:space:]')" "27000000"

# 34. The .auth body must follow the prefix verbatim. A reader that re-encoded
# or padded it would produce a signature the firmware rejects.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
if od -An -c "$EFIVARS/db-$SECURITY_GUID" 2>/dev/null | tr -d ' \n' | grep -q 'AUTHBODY-db'; then
    echo "PASS: 34. the .auth payload is written verbatim after the prefix"
    PASS=$((PASS + 1))
else
    echo "FAIL: 34. the .auth payload was not written through intact"
    FAIL=$((FAIL + 1))
fi

# 35. efivarfs requires the prefix and payload in ONE write(). bs=<total size>
# with count=1 and iflag=fullblock is what guarantees that; a short read
# otherwise splits it into two writes and the firmware rejects the lot.
new_case; make_firmware 1 0
lib 'sbEnrollDb' >/dev/null 2>&1
DDLINE="$(grep -m1 '^dd .*db-' "$SANDBOX/calls")"
if [[ $DDLINE == *"count=1"* && $DDLINE == *"iflag=fullblock"* && $DDLINE == *"bs="* ]]; then
    echo "PASS: 35. the variable is written as a single full-block dd"
    PASS=$((PASS + 1))
else
    echo "FAIL: 35. dd was not invoked as a single full block (\"$DDLINE\")"
    FAIL=$((FAIL + 1))
fi

# 36. The kernel marks existing efivarfs entries immutable so a stray rm cannot
# brick the firmware. Updating one means clearing that first.
new_case; make_firmware 1 0
mkdir -p "$EFIVARS"; printf '\x27\x00\x00\x00old' > "$EFIVARS/db-$SECURITY_GUID"
lib 'sbEnrollDb' >/dev/null 2>&1
if grep -q -- "chattr -i .*db-$SECURITY_GUID" "$SANDBOX/calls"; then
    echo "PASS: 36. the immutable flag is cleared before rewriting an existing variable"
    PASS=$((PASS + 1))
else
    echo "FAIL: 36. chattr -i was not issued for an existing variable"
    FAIL=$((FAIL + 1))
fi

# 37. Every blob is downloaded BEFORE any is written. A web server hiccup partway
# through should cost nothing; leaving a platform mid-enrolment over one is a
# far worse trade than re-running the fetch.
new_case; make_firmware 1 0; FAKE_AUTH_FAIL=PK; export FAKE_AUTH_FAIL
GOT="$(lib 'sbEnrollDb && echo ok || echo refused')"
if [[ $GOT == refused ]] && ! grep -q '^dd ' "$SANDBOX/calls"; then
    echo "PASS: 37. a failed download writes no variables at all"
    PASS=$((PASS + 1))
else
    echo "FAIL: 37. a failed download still reached the write stage (got \"$GOT\")"
    FAIL=$((FAIL + 1))
fi

# 38. A failure mid-sequence must stop before PK. Stopping there is what keeps
# the machine in Setup Mode -- still booting whatever it booted before, rather
# than enforcing against a half-written database.
new_case; make_firmware 1 0; FAKE_DD_FAIL=KEK; export FAKE_DD_FAIL
GOT="$(lib 'sbEnrollDb && echo ok || echo refused')"
if [[ $GOT == refused ]] && [[ ! -e $EFIVARS/PK-$GLOBAL_GUID ]]; then
    echo "PASS: 38. a mid-sequence failure aborts before the PK write"
    PASS=$((PASS + 1))
else
    echo "FAIL: 38. a failed KEK write did not stop the PK write (got \"$GOT\")"
    FAIL=$((FAIL + 1))
fi

# 39. THE silent-failure guard for this path, mirroring case 23. dd can write
# bytes into efivarfs that the firmware then declines to apply. SetupMode
# flipping 1 -> 0 is the firmware confirming it took the PK, and it is the only
# confirmation available before a reboot.
new_case; make_firmware 1 0; FAKE_PK_KEEPS_SETUP=1; export FAKE_PK_KEEPS_SETUP
check "39. writes succeed but SetupMode stays 1 -> refuse" \
    "$(lib 'sbEnrollDb && echo ok || echo refused')" "refused"

# 40. Happy path: all three written, firmware left Setup Mode.
new_case; make_firmware 1 0
check "40. enrolment succeeds when the firmware leaves Setup Mode" \
    "$(lib 'sbEnrollDb && echo ok || echo refused')" "ok"

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
