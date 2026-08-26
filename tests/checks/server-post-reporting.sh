#!/bin/bash
#
# Assertion harness for postToServer() and the two completion scripts that use
# it.
#
#   tests/checks/server-post-reporting.sh   # run all cases, non-zero on failure
#
# fog.imgcomplete waits for a literal "##" and printed whatever it got when that
# did not arrive. When the server died mid-request the body was EMPTY, so the
# client printed
#
#   * Error returned:
#
# with nothing after it, eleven times, and there was nothing to diagnose from
# the machine in front of you. That is exactly how fogproject GH-1380 presented:
# a capture that had already been renamed into place never reached Complete,
# while the server was taking an uncatchable PHP memory-exhaustion fatal on every
# attempt. A PHP fatal is not catchable, so no server-side handler could turn it
# into a message -- the client is the only place that gap can be closed.
#
# fog.nonimgcomplete was worse: it printed no error text at all, ever.
#
# postToServer() tells four outcomes apart that used to look identical:
#
#   curl could not connect       - transport, nothing reached the server
#   HTTP >= 400                  - it answered, and refused
#   HTTP 2xx with an empty body  - it accepted and returned nothing, which for
#                                  PHP means a fatal, and the reason is in the
#                                  web server's PHP error log, NOT on screen
#   HTTP 2xx with a body         - a real message
#
# The trap this harness exists to hold shut is the one that was WRITTEN and
# caught here during development: postToServer sets variables rather than
# echoing them, because a caller needs both the body and the description, and
# `x=$(postToServer ...)` runs in a SUBSHELL where every variable it set is
# discarded. That version looked correct, passed a read-through, and would have
# reported an empty reason for every failure -- reintroducing the exact bug it
# was written to fix. Case 6 drives it, and cases 7-8 pin both call sites.
#
# Mechanism mirrors tests/checks/error-report.sh: source a sandbox copy of the
# library with its hardcoded /usr/share/fog/lib path rewritten, and PATH-shadow
# curl with a stub that emulates -w '\n%{http_code}' from the environment.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"
REPO_BIN="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# curl double. Emulates exactly the one thing postToServer depends on: with
# -w '\n%{http_code}' the status arrives on its own trailing line after the
# body. FAKE_BODY may be empty or multi-line; FAKE_CURL_RC drives the transport
# arm, in which case nothing is written at all, as real curl does on a connect
# failure.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SANDBOX/curl.argv"
[[ ${FAKE_CURL_RC:-0} -ne 0 ]] && exit "$FAKE_CURL_RC"
printf '%s' "${FAKE_BODY-}"
printf '\n%s' "${FAKE_CODE:-200}"
exit 0
EOF
chmod +x "$STUBBIN/curl"
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/usleep"
chmod +x "$STUBBIN/usleep"

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1))
    fi
}

# Drives postToServer in THIS shell -- not a subshell -- and prints the three
# variables plus the return code on one line each, so a case can assert on what
# the caller would actually see.
drive() {
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        export FAKE_CURL_RC FAKE_CODE FAKE_BODY
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        postToServer "http://fog.example/service/Post_Stage2.php" "mac=00:11:22:33:44:55"
        rc=$?
        printf 'RC=%s\n' "$rc"
        printf 'STATUS=%s\n' "$serverStatus"
        printf 'REASON=%s\n' "$serverReason"
        printf 'BODY=%s\n' "$serverBody"
    )
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

# --- 1. transport failure -------------------------------------------------
out=$(FAKE_CURL_RC=7 drive)
err=""
[[ $(field RC "$out") == 1 ]] || err="rc=$(field RC "$out")"
reason=$(field REASON "$out")
grep -q 'could not reach' <<<"$reason" || err="$err reason=$reason"
grep -q 'curl exit 7' <<<"$reason" || err="$err no-exit-code"
note "1. a connect failure names the URL and curl's exit status" "$err"

# --- 2. HTTP error status -------------------------------------------------
out=$(FAKE_CURL_RC=0 FAKE_CODE=500 FAKE_BODY="Internal Server Error" drive)
err=""
[[ $(field RC "$out") == 1 ]] || err="rc=$(field RC "$out")"
reason=$(field REASON "$out")
grep -q 'HTTP 500' <<<"$reason" || err="$err reason=$reason"
note "2. an HTTP >= 400 answer is reported as a status, not as its body" "$err"

# --- 3. the GH-1380 case: 200 with an empty body --------------------------
out=$(FAKE_CURL_RC=0 FAKE_CODE=200 FAKE_BODY="" drive)
err=""
[[ $(field RC "$out") == 1 ]] || err="rc=$(field RC "$out")"
# Asserted on the REASON field, not on the whole capture: matching anywhere in
# the output passes when the description is ECHOED rather than assigned, which
# is the very shape that discards it in a subshell.
reason=$(field REASON "$out")
grep -qi 'EMPTY body' <<<"$reason" || err="$err no-empty-mention"
grep -qi 'PHP error log' <<<"$reason" || err="$err does-not-point-at-the-log"
[[ -z $(field BODY "$out") ]] || err="$err body=$(field BODY "$out")"
note "3. an empty 200 says so, and points at the PHP error log" "$err"

# --- 4. the success shape -------------------------------------------------
out=$(FAKE_CURL_RC=0 FAKE_CODE=200 FAKE_BODY="##" drive)
err=""
[[ $(field RC "$out") == 0 ]] || err="rc=$(field RC "$out")"
[[ $(field BODY "$out") == "##" ]] || err="$err body=$(field BODY "$out")"
[[ -z $(field REASON "$out") ]] || err="$err reason-set-on-success"
note "4. a real answer returns 0, with the body intact and no reason" "$err"

# --- 5. a multi-line body survives the status split -----------------------
out=$(FAKE_CURL_RC=0 FAKE_CODE=200 FAKE_BODY=$'line one\nline two' drive)
err=""
grep -q '^BODY=line one$' <<<"$out" || err="first line lost"
note "5. only the LAST newline is the status separator" "$err"

# --- 6. the variables reach the caller ------------------------------------
# The bug this whole file exists to hold shut. If postToServer is ever changed
# back to echoing its description, or a caller wraps it in $( ), serverReason is
# empty in the caller and the client prints a blank error again.
out=$(
    set +u
    export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX" FAKE_CODE=200 FAKE_BODY=""
    . "$SANDBOX/funcs.sh" >/dev/null 2>&1
    postToServer "http://fog.example/x.php" "a=b"
    # Deliberately read AFTER the call returns, in the calling scope.
    printf 'SEEN=%s\n' "${serverReason:-<empty>}"
)
err=""
[[ $(field SEEN "$out") != "<empty>" ]] || err="caller saw no reason"
note "6. the caller can read serverReason after the call returns" "$err"

# --- 7/8. both call sites, whole-line anchored ----------------------------
# Anchored on the whole call line rather than grepping for the function name: a
# name grep passes when the call has been wrapped in $( ), which is the failure
# mode being guarded.
for f in fog.imgcomplete fog.nonimgcomplete; do
    err=""
    [[ -f $REPO_BIN/$f ]] || { note "7. $f exists" "missing"; continue; }
    if grep -Eq '^[[:space:]]*[A-Za-z_]+=\$\(postToServer' "$REPO_BIN/$f"; then
        err="calls postToServer inside \$( ), which discards its variables"
    elif ! grep -Eq '^[[:space:]]*postToServer ' "$REPO_BIN/$f"; then
        err="does not call postToServer directly"
    elif ! grep -q 'serverReason' "$REPO_BIN/$f"; then
        err="never prints serverReason, so a failure still says nothing"
    fi
    note "7. $f calls postToServer directly and prints its reason" "$err"
done

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
