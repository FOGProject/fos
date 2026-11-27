#!/bin/bash
#
# Assertion harness for the boot token (FOG forum 18086).
#
#   tests/checks/boot-token-reporting.sh   # run all cases, non-zero on failure
#
# A deploy started for an unregistered or pending host is a task with no host.
# The server finds it by a single-use token it put on the kernel command line
# as fogtoken=. FOS has to carry that token on every call that reaches a task:
# check-in, progress, completion, the blame report and the error report. A call
# that leaves it off is looked up by MAC alone, finds no host, and is refused --
# so the run shows no progress and never completes.
#
# Four things have to hold, and each has a case here:
#
#   * every reporting call sends fogtoken when it is set, and sends nothing of
#     the kind when it is not (a registered host has no token);
#   * a capone task with a token still checks out, because the server needs the
#     completion call to finish the hostless task -- without a token capone
#     still exits at once;
#   * a capone task with a token still checks in, for the same reason;
#   * the token never prints on the console, because the error screen shows the
#     kernel command line to whoever is standing at the machine.
#
# Mechanism mirrors tests/checks/server-post-reporting.sh and
# tests/checks/status-reporting.sh: a sandbox copy of funcs.sh with its hardcoded
# paths rewritten, PATH-shadowed curl, dmidecode and usleep, and the shipped
# scripts driven with callServer stubbed where the call is what is under test.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay"
REPO_LIB="$OVERLAY/usr/share/fog/lib"
REPO_BIN="$OVERLAY/bin"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

export SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

TOKEN="5f3b9e7c1a2d4b68"
MAC="02:00:00:00:0E:11"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
# fog.curl is shipped code between the call site and the curl double. Its TLS
# state is seeded "verified", so it adds no probe call of its own.
sed "s#^statefile=.*#statefile=\"$SANDBOX/fog.tls\"#" "$REPO_BIN/fog.curl" > "$STUBBIN/fog.curl"
chmod +x "$STUBBIN/fog.curl"
echo verified > "$SANDBOX/fog.tls"

# curl double: one argument per line, a terminator after each call.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
{
    printf '%s\n' "$@"
    printf -- '--end--\n'
} >> "$SANDBOX/curl.argv"
exit 0
EOF
chmod +x "$STUBBIN/curl"
printf '#!/bin/bash\nprintf "%%s" "44454C4C-4C00-1034-8044-C4C04F435431"\n' > "$STUBBIN/dmidecode"
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/usleep"
chmod +x "$STUBBIN/dmidecode" "$STUBBIN/usleep"

# A cmdline fixture. The token sits in the middle with arguments after it so the
# library's own `sed 's/ad.*=.* //g'` cannot hide it by accident; it contains no
# "ad" for the same reason.
CMDLINE="$SANDBOX/cmdline"
printf 'loglevel=3 web=http://fog.example/fog/ fogtoken=%s type=down capone=1 mode=\n' "$TOKEN" > "$CMDLINE"

# Sandbox copy of the library: the partition library, the cmdline, the
# post-download script and the completion script all point into the sandbox.
cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    -e "s#/proc/cmdline#$CMDLINE#g" \
    -e "s#\. /bin/fog\.imgcomplete#. $SANDBOX/fog.imgcomplete#" \
    -e "s#/images/postdownloadscripts/#$SANDBOX/no-postdownload/#g" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"
printf 'touch "%s/imgcomplete.ran"\n' "$SANDBOX" > "$SANDBOX/fog.imgcomplete"

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1))
    fi
}

# --- stubs for the scripts that are driven whole --------------------------
# Defined as text so each case can eval them in its own subshell. callServer
# records the URL and the post data and answers with $STUB_ANSWER.
STUBS='
callServer() { printf "%s %s\n" "$1" "$2" >> "$SANDBOX/calls"; serverBody="$STUB_ANSWER"; serverReason=""; return 0; }
dots() { :; }
debugPause() { :; }
sec2string() { :; }
handleError() { printf "handleError: %s\n" "$1" >> "$SANDBOX/calls"; return 0; }
'

# lastPost <script-name-fragment> -- the post data of the last recorded call
# whose URL contains the fragment.
lastPost() {
    grep -F -- "$1" "$SANDBOX/calls" 2>/dev/null | tail -1 | cut -d' ' -f2-
}

# --- 1/2. fog.checkin -----------------------------------------------------
# fog.checkin runs the whole boot preamble before it reaches checkin(), so the
# case cuts out the part that matters: from the function to the end of the file
# (the php_post choice, the post string and the capone guard).
checkinTail=$(awk '/^checkin\(\) \{$/ {on=1} on {print}' "$REPO_BIN/fog.checkin")
[[ -n $checkinTail ]] || { echo "FAIL: no checkin() in fog.checkin"; exit 1; }

runCheckin() {
    # $1 fogtoken  $2 capone
    rm -f "$SANDBOX/calls"
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX" STUB_ANSWER="##@GO"
        eval "$STUBS"
        mac="$MAC"; type=down; mc=no; web="http://fog.example/fog/"
        fogtoken="$1"; capone="$2"
        eval "$checkinTail"
    ) >/dev/null 2>&1
}

runCheckin "$TOKEN" ""
err=""
[[ $(lastPost Pre_Stage1.php) == *"&fogtoken=$TOKEN" ]] || err="post was '$(lastPost Pre_Stage1.php)'"
note "1. check-in carries the token" "$err"

runCheckin "" ""
err=""
[[ -n $(lastPost Pre_Stage1.php) ]] || err="no check-in at all"
[[ $(lastPost Pre_Stage1.php) == *fogtoken* ]] && err="$err a registered host posted a token field"
note "2. check-in sends no token field when there is none" "$err"

# --- 3/4. the capone guard in fog.checkin ---------------------------------
runCheckin "" 1
err=""
[[ -f $SANDBOX/calls ]] && err="capone with no token checked in: $(cat "$SANDBOX/calls")"
note "3. capone without a token still skips check-in" "$err"

runCheckin "$TOKEN" 1
err=""
[[ $(lastPost Pre_Stage1.php) == *"&fogtoken=$TOKEN" ]] || err="post was '$(lastPost Pre_Stage1.php)'"
note "4. capone with a token checks in, so the hostless task starts" "$err"

# --- 5. fog.statusreporter ------------------------------------------------
STATUSFILE="$SANDBOX/status.fog"
VALID='108.53MB/min@00:01:23@00:04:17@12.50 GiB@44.20 GiB@ 28.28@47458910208'
sed -e "s#^statusfile=.*#statusfile=\"$STATUSFILE\"#" \
    -e "s#^minpostsecs=.*#minpostsecs=0#" \
    "$REPO_BIN/fog.statusreporter" > "$SANDBOX/fog.statusreporter"
runReporter() {
    # $@ the arguments after <mac> <web>
    rm -f "$SANDBOX/curl.argv"
    printf '%s\n' "$VALID" > "$STATUSFILE"
    PATH="$STUBBIN:$PATH" bash "$SANDBOX/fog.statusreporter" "$MAC" "http://fog.example/fog/" "$@" &
    local pid=$!
    sleep 2
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}
runReporter "$TOKEN"
err=""
grep -Fxq -- "fogtoken=$TOKEN" "$SANDBOX/curl.argv" 2>/dev/null || err="no fogtoken argument on the progress post"
grep -Fxq -- "--data-urlencode" "$SANDBOX/curl.argv" 2>/dev/null || err="$err; no url-encoded field at all"
note "5a. progress carries the token as an encoded field" "$err"

runReporter
err=""
[[ -f $SANDBOX/curl.argv ]] || err="reporter posted nothing"
grep -q 'fogtoken' "$SANDBOX/curl.argv" 2>/dev/null && err="$err; a registered host posted a token field"
note "5b. progress sends no token field when there is none" "$err"

# --- 6. the callers hand the token to the reporter ------------------------
for f in fog.download fog.upload; do
    err=""
    grep -Eq '^fog\.statusreporter "\$mac" "\$web" "\$fogtoken" & disown$' "$REPO_BIN/$f" \
        || err="does not pass \"\$fogtoken\" as the third argument"
    note "6. $f starts the reporter with the token" "$err"
done

# --- 7. fog.imgcomplete ---------------------------------------------------
runImgcomplete() {
    # $1 type  $2 fogtoken
    rm -f "$SANDBOX/calls"
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX" STUB_ANSWER="##"
        eval "$STUBS"
        mac="$MAC"; type="$1"; osid=5; web="http://fog.example/fog/"; fogtoken="$2"
        . "$REPO_BIN/fog.imgcomplete"
    ) >/dev/null 2>&1
}
runImgcomplete down "$TOKEN"
err=""
[[ $(lastPost Post_Stage3.php) == *"&fogtoken=$TOKEN" ]] || err="deploy post was '$(lastPost Post_Stage3.php)'"
note "7a. a deploy completion carries the token" "$err"
runImgcomplete up "$TOKEN"
err=""
[[ $(lastPost Post_Stage2.php) == *"&fogtoken=$TOKEN" ]] || err="capture post was '$(lastPost Post_Stage2.php)'"
note "7b. a capture completion carries the token" "$err"
runImgcomplete down ""
err=""
[[ -n $(lastPost Post_Stage3.php) ]] || err="no completion at all"
[[ $(lastPost Post_Stage3.php) == *fogtoken* ]] && err="$err a registered host posted a token field"
note "7c. a completion sends no token field when there is none" "$err"

# --- 8. completeTasking with capone ---------------------------------------
runComplete() {
    # $1 fogtoken
    rm -f "$SANDBOX/imgcomplete.ran"
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        killStatusReporter() { :; }
        type=down; capone=1; fogtoken="$1"
        completeTasking
        # Reached only if completeTasking did not exit: a capone task must.
        touch "$SANDBOX/fell.through"
    ) >/dev/null 2>&1
    echo $?
}
rm -f "$SANDBOX/fell.through"
rc=$(runComplete "")
err=""
[[ -f $SANDBOX/imgcomplete.ran ]] && err="capone without a token completed against the server"
[[ -f $SANDBOX/fell.through ]] && err="$err capone fell through into the registered-host tail"
note "8a. capone without a token exits without completing" "$err"
rc=$(runComplete "$TOKEN")
err=""
[[ -f $SANDBOX/imgcomplete.ran ]] || err="capone with a token did not complete, so the hostless task never ends"
[[ -f $SANDBOX/fell.through ]] && err="$err capone fell through into the registered-host tail"
note "8b. capone with a token completes, then exits" "$err"

# --- 9. reportToServer ----------------------------------------------------
runReport() {
    # $1 fogtoken
    rm -f "$SANDBOX/curl.argv"
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        web="http://fog.example/fog/"; mac="$MAC"; sysuuid="u"; fogtoken="$1"
        reportToServer error "boom"
    ) >/dev/null 2>&1
}
runReport "$TOKEN"
err=""
grep -Fxq -- "fogtoken=$TOKEN" "$SANDBOX/curl.argv" 2>/dev/null || err="no fogtoken argument on the error report"
grep -Fxq -- "mac=$MAC" "$SANDBOX/curl.argv" 2>/dev/null || err="$err; mac lost"
grep -Fxq -- "text=boom" "$SANDBOX/curl.argv" 2>/dev/null || err="$err; text lost"
note "9a. the error report carries the token" "$err"
runReport ""
err=""
[[ -f $SANDBOX/curl.argv ]] || err="no report sent"
grep -q 'fogtoken' "$SANDBOX/curl.argv" 2>/dev/null && err="$err; a registered host posted a token field"
note "9b. the error report sends no token field when there is none" "$err"

# --- 10. fog.checkmount (the blame report) --------------------------------
# /images/.mntcheck is the file the script tests; the sandbox copy points it at
# a path that cannot exist so the failure branch runs on any machine.
sed "s#/images/\.mntcheck#$SANDBOX/no-mntcheck#" "$REPO_BIN/fog.checkmount" > "$SANDBOX/fog.checkmount"
rm -f "$SANDBOX/calls"
(
    set +u
    export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX" STUB_ANSWER="##"
    eval "$STUBS"
    mac="$MAC"; type=down; web="http://fog.example/fog/"; fogtoken="$TOKEN"
    . "$SANDBOX/fog.checkmount"
) >/dev/null 2>&1
err=""
[[ $(lastPost blame.php) == *"&fogtoken=$TOKEN" ]] || err="blame post was '$(lastPost blame.php)'"
note "10a. the blame report carries the token" "$err"
rm -f "$SANDBOX/calls"
(
    set +u
    export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX" STUB_ANSWER="##"
    eval "$STUBS"
    mac="$MAC"; type=down; web="http://fog.example/fog/"; fogtoken=""
    . "$SANDBOX/fog.checkmount"
) >/dev/null 2>&1
err=""
[[ -n $(lastPost blame.php) ]] || err="no blame report at all"
[[ $(lastPost blame.php) == *fogtoken* ]] && err="$err a registered host posted a token field"
note "10b. the blame report sends no token field when there is none" "$err"

# --- 11. handleError does not print the token ------------------------------
# The error screen prints the kernel command line to whoever is at the machine,
# and the token is a credential for one active task.
out=$(
    set +u
    export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
    . "$SANDBOX/funcs.sh" >/dev/null 2>&1
    web=""; isdebug=""
    handleError "boom"
)
err=""
[[ $out == *"$TOKEN"* ]] && err="the error screen prints the token"
[[ $out == *"type=down"* ]] || err="$err; the rest of the command line stopped printing"
[[ $out == *"fogtoken="* ]] || err="$err; the argument is not shown masked"
note "11. the error screen masks the token on the kernel command line" "$err"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
