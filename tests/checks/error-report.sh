#!/bin/bash
#
# Assertion harness for the failure report handleError() sends.
#
#   tests/checks/error-report.sh   # run all cases, exit non-zero on any failure
#
# handleError() used to print its banner and exit, reporting nothing to the
# server, so a real imaging failure was invisible to FOG: HOST_IMAGE_FAIL could
# not fire and the notification plugins registered for it had never run
# (fogproject#1206). It now POSTs to service/taskerror.php.
#
# What matters here is not that the report arrives -- that is the server's
# harness -- but that trying to send it cannot change what the person standing
# at the machine sees. So the assertions are about the shape of the call and
# about handleError still finishing when the call does not: time bounded, output
# discarded, exit status ignored, skipped when there is no server to talk to.
#
# Mechanism mirrors tests/checks/sector-size.sh: source a sandbox copy of the
# library with its hardcoded /usr/share/fog/lib path rewritten, and PATH-shadow
# the external tools with deterministic stubs. curl is the stub that matters --
# it records its argv rather than making a request.
#
# One thing here is asserted as behaviour rather than as implementation: no FOS
# script sets errexit today, so the `|| :` on the curl is defensive and cannot
# be isolated by a case. Case 5 pins what actually matters instead -- that
# handleError still reaches its reboot notice when the report fails -- which
# stays true however that is achieved.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# curl double: records one line per argument into $SANDBOX/curl.argv, then exits
# with $FAKE_CURL_RC. Recording argv rather than a flattened string is what lets
# a case tell "--data-urlencode error=a b" from two separate arguments.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
: > "$SANDBOX/curl.called"
printf '%s\n' "$@" > "$SANDBOX/curl.argv"
echo "curl stdout must not reach the console"
echo "curl stderr must not reach the console" >&2
exit "${FAKE_CURL_RC:-0}"
EOF
chmod +x "$STUBBIN/curl"

# The reboot countdown, so a case runs instantly rather than in a minute.
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/usleep"
chmod +x "$STUBBIN/usleep"

PASS=0
FAIL=0

# arg_present <exact argument> -- true if curl received it as one whole argument.
arg_present() { grep -Fxq -- "$1" "$SANDBOX/curl.argv" 2>/dev/null; }

note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"
        FAIL=$((FAIL + 1))
        [[ -f $SANDBOX/curl.argv ]] && echo "      argv: $(tr '\n' '|' < "$SANDBOX/curl.argv")"
    fi
}

# run_handle_error <message> -- drives handleError in a subshell with the
# environment a case has set, and captures everything it wrote to the console.
# handleError ends in `exit 1`, which is why this has to be a subshell.
run_handle_error() {
    rm -f "$SANDBOX/curl.called" "$SANDBOX/curl.argv"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH"
        export SANDBOX="$SANDBOX"
        export FAKE_CURL_RC
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        web="$CASE_WEB"
        mac="$CASE_MAC"
        sysuuid="$CASE_UUID"
        isdebug=""
        handleError "$1"
    )" 2>&1
}

CASE_WEB="http://fog.example/fog/"
CASE_MAC="02:00:00:00:0E:11"
CASE_UUID="4c4c4544-0044-0000-8000-000000000000"

# 1. The report is sent, to the right place, with the right fields.
FAKE_CURL_RC=0
run_handle_error "Could not mount images folder (fog.mount)"
why=""
[[ -f $SANDBOX/curl.called ]] || why="curl was not called at all"
arg_present "http://fog.example/fog/service/taskerror.php" || why="${why:+$why; }wrong or missing endpoint URL"
arg_present "mac=02:00:00:00:0E:11" || why="${why:+$why; }mac not sent"
arg_present "sysuuid=4c4c4544-0044-0000-8000-000000000000" || why="${why:+$why; }sysuuid not sent"
arg_present "error=Could not mount images folder (fog.mount)" || why="${why:+$why; }error text not sent as one argument"
note "reports to service/taskerror.php with mac, sysuuid and the message" "$why"

# 2. Bounded, and encoded rather than concatenated into the body.
why=""
arg_present "--max-time" || why="no --max-time, so an unreachable server adds to the wait before the reboot"
grep -Fxq -- "--data-urlencode" "$SANDBOX/curl.argv" || why="${why:+$why; }fields are not url-encoded, so a message containing & splits into extra fields"
note "the call is time bounded and its fields are encoded" "$why"

# 3. The escapes the callers embed become real newlines before sending. Every
#    caller writes "...(\$0)\n   Args Passed: \$*", and sending the two literal
#    characters would put a visible backslash-n in an admin's notification.
FAKE_CURL_RC=0
run_handle_error 'Could not mount images folder ($0)\n   Args Passed: --target /images'
sent="$(grep -F -- 'error=' "$SANDBOX/curl.argv" | head -1)"
why=""
[[ $sent == *'\n'* ]] && why="the literal two characters \\n were sent instead of a newline"
[[ $(grep -c . <<< "$(printf '%s' "$sent")") -lt 1 ]] && why="${why:+$why; }nothing was sent"
note "message escapes are expanded before sending" "$why"

# 4. Nothing the report does may reach the console. The operator's screen is the
#    whole reason handleError exists.
FAKE_CURL_RC=0
run_handle_error "Could not mount images folder (fog.mount)"
why=""
[[ $OUT == *"curl stdout must not reach the console"* ]] && why="curl stdout is printed to the operator"
[[ $OUT == *"curl stderr must not reach the console"* ]] && why="${why:+$why; }curl stderr is printed to the operator"
[[ $OUT != *"An error has been detected"* ]] && why="${why:+$why; }the error banner itself stopped being printed"
[[ $OUT != *"Could not mount images folder"* ]] && why="${why:+$why; }the message itself stopped being printed"
note "the report is silent and the banner is unaffected" "$why"

# 5. A failing curl must not change anything. errexit anywhere up the call chain
#    plus a bare curl would abort handleError before it printed the reboot
#    notice -- the machine would just sit there.
FAKE_CURL_RC=7
run_handle_error "Could not mount images folder (fog.mount)"
why=""
[[ $OUT != *"An error has been detected"* ]] && why="the banner was not printed"
[[ $OUT != *"Computer will reboot"* ]] && why="${why:+$why; }handleError did not reach the reboot notice after curl failed"
note "a failed report does not stop handleError finishing" "$why"

# 6. No server configured -- registration paths and debug shells run without
#    \$web -- must not try at all. curl would resolve "service/taskerror.php" as
#    a relative URL and fail slowly.
CASE_WEB=""
FAKE_CURL_RC=0
run_handle_error "Could not mount images folder (fog.mount)"
why=""
[[ -f $SANDBOX/curl.called ]] && why="curl was called with no \$web set"
[[ $OUT != *"An error has been detected"* ]] && why="${why:+$why; }the banner was not printed"
note "no \$web means no attempt" "$why"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
