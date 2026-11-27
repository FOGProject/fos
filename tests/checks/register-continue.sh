#!/bin/bash
#
# Assertion harness for continueIntoTask() in funcs.sh and its two callers,
# fog.man.reg and fog.auto.reg (FOG forum 18086).
#
#   tests/checks/register-continue.sh   # run all cases, non-zero on failure
#
# A host that registers with "deploy now" used to reboot, and the next PXE boot
# started the deploy. When the server says the next boot would be the same boot
# (samebootok=1: no host or task type kernel, init or kernel arguments to apply),
# FOS skips the reboot and runs the deploy in the same session.
#
# What has to hold:
#
#   * samebootok=1 runs fog.download with the host's task variables, and with
#     mode empty. mode=manreg is still on the kernel command line, and bin/fog
#     would otherwise send the sub-script back into registration. funcs.sh
#     re-reads the kernel command line in every script, so the override has to
#     live in a file that funcs.sh sources AFTER it (/tmp/hinfo.continue).
#   * every other answer falls back to today's behavior (return, then reboot):
#     samebootok=0, no samebootok line (an old server), a key or hostinfo call
#     that fails, and a Secure Boot enrollment that wrote firmware state this
#     boot (sbEnrollWrote=1) -- that state only takes effect after a reboot.
#   * the function never fails the registration: it always returns 0.
#   * fog.man.reg continues only when the person chose "deploy now"; fog.auto.reg
#     continues after its Secure Boot step.
#
# Mechanism mirrors tests/checks/server-post-reporting.sh: a sandbox copy of
# funcs.sh with its hardcoded paths rewritten, PATH-shadowed fog.curl, dmidecode
# and fog.download, and callServer stubbed so each case controls the key reply.
# The fog.download double sources the sandbox funcs.sh itself, as the real one
# does, and records what it sees -- that is the check on the override.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay"
REPO_LIB="$OVERLAY/usr/share/fog/lib"
REPO_BIN="$OVERLAY/bin"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

export SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MAC="02:00:00:00:0E:11"
# What FOGCore::createSecToken() returns: bin2hex(random_bytes(64)), 128 hex digits.
KEY="$(printf 'ab%.0s' {1..64})"

# The kernel command line of a manual registration: mode=manreg is what the
# sub-script must NOT inherit.
CMDLINE="$SANDBOX/cmdline"
printf 'loglevel=3 web=http://fog.example/fog/ mac=%s mode=manreg\n' "$MAC" > "$CMDLINE"

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    -e "s#/proc/cmdline#$CMDLINE#g" \
    -e "s#/tmp/hinfo\.#$SANDBOX/hinfo.#g" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
printf '#!/bin/bash\nprintf "%%s" "44454C4C-4C00-1034-8044-C4C04F435431"\n' > "$STUBBIN/dmidecode"
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/usleep"

# fog.curl double: writes the hostinfo fixture a case chose to the -o file and
# records the post data, so a case can see whether the call was made at all.
cat > "$STUBBIN/fog.curl" <<'EOF'
#!/bin/bash
out=""
data=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out="$2"; shift ;;
        --data) data="$2"; shift ;;
    esac
    shift
done
printf '%s\n' "$data" >> "$SANDBOX/hostinfo.calls"
[[ ${FAKE_HINFO_RC:-0} -ne 0 ]] && exit "$FAKE_HINFO_RC"
[[ -n $out ]] && printf '%s\n' "$FAKE_HINFO" > "$out"
exit 0
EOF

# fog.download double: a separate process, as bin/fog starts the real one. It
# sources the library the way every FOS script does, then records what a deploy
# would have seen.
cat > "$STUBBIN/fog.download" <<'EOF'
#!/bin/bash
. "$SANDBOX/funcs.sh" >/dev/null 2>&1
printf 'mode=[%s] storage=[%s] type=[%s] img=[%s] desc=[%s]\n' \
    "$mode" "$storage" "$type" "$img" "$hostdesc" > "$SANDBOX/download.ran"
EOF
chmod +x "$STUBBIN/dmidecode" "$STUBBIN/usleep" "$STUBBIN/fog.curl" "$STUBBIN/fog.download"

# What service/hostinfo.php prints: one `[[ -z $x ]] && export x=...` line per
# field, values through escapeshellarg (so an apostrophe is '\'' ).
hinfo() {
    cat <<EOF
[[ -z \$mac ]] && export mac='$MAC'
[[ -z \$storage ]] && export storage='10.0.0.5:/images/'
[[ -z \$img ]] && export img='win10'
[[ -z \$type ]] && export type='down'
[[ -z \$hostdesc ]] && export hostdesc='a b'\\''c'
[[ -z \$samebootok ]] && export samebootok='$1'
EOF
}

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1))
    fi
}

# run <hinfo text> [var=value ...] -- drives continueIntoTask in a subshell and
# prints its return code. FAKE_KEY / FAKE_KEY_RC steer the hostgetkey reply.
run() {
    local hi="$1"; shift
    rm -f "$SANDBOX/download.ran" "$SANDBOX/hostinfo.calls" "$SANDBOX/keycalls" \
          "$SANDBOX/hinfo.txt" "$SANDBOX/hinfo.continue"
    (
        set +u
        export PATH="$STUBBIN:$PATH"
        export FAKE_HINFO="$hi" FAKE_HINFO_RC
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        getMACAddresses() { echo "$MAC"; }
        callServer() {
            printf '%s %s\n' "$1" "$2" >> "$SANDBOX/keycalls"
            serverBody="${FAKE_KEY-$KEY}"
            serverReason="stubbed"
            return "${FAKE_KEY_RC:-0}"
        }
        web="http://fog.example/fog/"
        for kv in "$@"; do export "$kv"; done
        # An empty web must be tested as empty, not as the cmdline's value.
        [[ " $* " == *" web= "* ]] && web=""
        continueIntoTask >/dev/null 2>&1
        echo $?
    )
}

# --- 1. samebootok=1 continues into the deploy ---------------------------
rc=$(run "$(hinfo 1)")
err=""
[[ -f $SANDBOX/download.ran ]] || err="fog.download was not run"
got=$(cat "$SANDBOX/download.ran" 2>/dev/null)
[[ $got == "mode=[] storage=[10.0.0.5:/images/] type=[down] img=[win10] desc=[a b'c]" ]] \
    || err="$err; the deploy saw: $got"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "1. samebootok=1 runs fog.download with the host's variables and mode empty" "$err"

# --- 2. the key and hostinfo calls are made the way bin/fog makes them -----
err=""
b64=$(echo "$MAC" | base64)
grep -Fxq "http://fog.example/fog/status/hostgetkey.php mac=$b64" "$SANDBOX/keycalls" 2>/dev/null \
    || err="hostgetkey was not asked for the base64 MAC: $(cat "$SANDBOX/keycalls" 2>/dev/null)"
grep -Fxq "sysuuid=44454c4c-4c00-1034-8044-c4c04f435431&mac=$MAC&hosttoken=$KEY" "$SANDBOX/hostinfo.calls" 2>/dev/null \
    || err="$err; hostinfo did not get the key: $(cat "$SANDBOX/hostinfo.calls" 2>/dev/null)"
note "2. the key is fetched with the MAC and sent to hostinfo" "$err"

# --- 3. samebootok=0 falls back --------------------------------------------
rc=$(run "$(hinfo 0)")
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran although the boot is not equivalent"
[[ -f $SANDBOX/hinfo.continue ]] && err="$err; hinfo.continue was left behind"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "3. samebootok=0 returns without running the deploy" "$err"

# --- 4. an old server has no samebootok line -------------------------------
old=$(hinfo 1 | grep -v samebootok)
rc=$(run "$old")
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran against a server that never said the boot is equivalent"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "4. a hostinfo with no samebootok line returns without running the deploy" "$err"

# --- 5. hostinfo refused (no task) ----------------------------------------
rc=$(run "Invalid tasking!")
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran on an error body"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "5. an error body from hostinfo returns without running the deploy" "$err"

# --- 6. Secure Boot enrollment wrote firmware state this boot -------------
rc=$(run "$(hinfo 1)" sbEnrollWrote=1)
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran after firmware state was written"
[[ -f $SANDBOX/hinfo.continue ]] && err="$err; hinfo.continue was left behind"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "6. sbEnrollWrote=1 returns without running the deploy" "$err"

rc=$(run "$(hinfo 1)" sbEnrollWrote=0)
err=""
[[ -f $SANDBOX/download.ran ]] || err="sbEnrollWrote=0 blocked the deploy"
note "6b. sbEnrollWrote=0 does not block it" "$err"

# --- 7. no key ------------------------------------------------------------
rc=$(run "$(hinfo 1)" FAKE_KEY=)
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran with no key"
[[ -f $SANDBOX/hostinfo.calls ]] && err="$err; hostinfo was asked without a key"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "7. an empty key stops before hostinfo" "$err"

FAKE_KEY_RC=1
rc=$(run "$(hinfo 1)")
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran after the key call failed"
[[ -f $SANDBOX/hostinfo.calls ]] && err="$err; hostinfo was asked after the key call failed"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "7b. a failed key call stops before hostinfo" "$err"
FAKE_KEY_RC=0

# --- 8. hostinfo request fails --------------------------------------------
FAKE_HINFO_RC=22
rc=$(run "$(hinfo 1)")
err=""
[[ -f $SANDBOX/download.ran ]] && err="fog.download ran after the hostinfo request failed"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "8. a failed hostinfo request returns without running the deploy" "$err"
FAKE_HINFO_RC=0

# --- 9. no server configured ----------------------------------------------
rc=$(run "$(hinfo 1)" web=)
err=""
[[ -f $SANDBOX/keycalls ]] && err="a server call was made with no \$web"
[[ -f $SANDBOX/download.ran ]] && err="$err; fog.download ran"
[[ $rc == 0 ]] || err="$err; returned $rc"
note "9. no \$web means no attempt" "$err"

# --- 10. a normal boot is unaffected by the new library line ---------------
out=$(
    set +u
    export PATH="$STUBBIN:$PATH"
    rm -f "$SANDBOX/hinfo.continue"
    . "$SANDBOX/funcs.sh" >/dev/null 2>&1
    echo "mode=[$mode]"
)
err=""
[[ $out == "mode=[manreg]" ]] || err="the kernel command line was not read: $out"
note "10. with no hinfo.continue the kernel command line wins" "$err"

# --- 13. a refusal body is not a key ---------------------------------------
# hostgetkey.php answers its refusals as 200 with text. Matching the token
# shape (128 hex digits) rather than the refusal strings covers all of them.
for bad in "Invalid Tasking" "Host Invalid" "Host token is currently in use" "${KEY}0" "${KEY:1}"; do
    rc=$(run "$(hinfo 1)" "FAKE_KEY=$bad")
    err=""
    [[ -f $SANDBOX/hostinfo.calls ]] && err="hostinfo was asked with '$bad' as the key"
    [[ -f $SANDBOX/download.ran ]] && err="$err; fog.download ran"
    [[ $rc == 0 ]] || err="$err; returned $rc"
    note "13. a key reply of '${bad:0:30}' stops before hostinfo" "$err"
done

# --- 14. the credential files ----------------------------------------------
# hostinfo.php can carry the AD join password, so neither file may be readable
# by others, and the reply is deleted once the continue file replaces it.
modeof() { stat -c %a "$1" 2>/dev/null; }
# run() deletes its files on entry only, so after it returns they are still
# here. The umask is the usual one, to show the code does not depend on it.
( umask 022; run "$(hinfo 1)" >/dev/null )
err=""
[[ $(modeof "$SANDBOX/hinfo.continue") == 600 ]] || err="hinfo.continue mode is '$(modeof "$SANDBOX/hinfo.continue")'"
[[ -e $SANDBOX/hinfo.txt ]] && err="$err; hinfo.txt was left behind after a continue"
note "14. hinfo.continue is 0600 and hinfo.txt is removed after a continue" "$err"

for hi in "$(hinfo 0)" "Invalid tasking!"; do
    run "$hi" >/dev/null
    err=""
    [[ -e $SANDBOX/hinfo.txt ]] && err="hinfo.txt was left behind"
    note "14b. hinfo.txt is removed when the deploy does not continue (${hi:0:16})" "$err"
done
run "$(hinfo 1)" sbEnrollWrote=1 >/dev/null
err=""
[[ -e $SANDBOX/hinfo.txt ]] && err="hinfo.txt was left behind"
note "14c. hinfo.txt is removed when firmware state was written" "$err"

# --- 15. fetchHostInfo, used by both paths -----------------------------------
# A reply file that already exists with a loose mode must not keep it, and the
# umask of the caller must not matter.
fetch() {
    (
        set +u
        umask 022
        export PATH="$STUBBIN:$PATH" FAKE_HINFO="$(hinfo 1)" FAKE_HINFO_RC
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        getMACAddresses() { echo "$MAC"; }
        callServer() { serverBody="${FAKE_KEY-$KEY}"; serverReason="stubbed"; return 0; }
        web="http://fog.example/fog/"
        "$@"
    )
}
rm -f "$SANDBOX/hinfo.txt"; : > "$SANDBOX/hinfo.txt"; chmod 644 "$SANDBOX/hinfo.txt"
fetch fetchHostInfo >/dev/null 2>&1
err=""
[[ $(modeof "$SANDBOX/hinfo.txt") == 600 ]] || err="hinfo.txt mode is '$(modeof "$SANDBOX/hinfo.txt")'"
grep -q "samebootok" "$SANDBOX/hinfo.txt" 2>/dev/null || err="$err; the reply was not written"
note "15. fetchHostInfo writes the reply 0600, replacing a looser file" "$err"

# --- 16. the USB boot path still sources the reply ---------------------------
# The block is cut out of bin/fog by its braces, so the shipped lines run. Its
# own refusal handling stays what it was: it prints a message and carries on.
USBBLOCK=$(awk '/^if \[\[ \$boottype == usb/ {on=1} on {print} on && /^fi$/ {exit}' "$REPO_BIN/fog" \
    | sed "s#/tmp/hinfo\\.#$SANDBOX/hinfo.#g")
[[ -n $USBBLOCK ]] || { echo "FAIL: no USB block in bin/fog"; exit 1; }
usb() {
    # $1 = key reply
    rm -f "$SANDBOX/hinfo.txt" "$SANDBOX/hostinfo.calls"
    (
        set +u
        umask 022
        export PATH="$STUBBIN:$PATH" FAKE_HINFO="$(hinfo 1)" FAKE_HINFO_RC FAKE_KEY="$1"
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        getMACAddresses() { echo "$MAC"; }
        callServer() { serverBody="$FAKE_KEY"; serverReason="stubbed"; return 0; }
        unset storage
        web="http://fog.example/fog/"; boottype=usb
        eval "$USBBLOCK"
        printf 'storage=[%s] mac=[%s]\n' "$storage" "$mac"
    )
}
out=$(usb "$KEY")
err=""
[[ $out == *"storage=[10.0.0.5:/images/]"* ]] || err="the reply was not sourced: $out"
[[ $out == *"mac=[$MAC]"* ]] || err="$err; mac was not set: $out"
[[ $(modeof "$SANDBOX/hinfo.txt") == 600 ]] || err="$err; hinfo.txt mode is '$(modeof "$SANDBOX/hinfo.txt")'"
note "16. the USB path sources the reply, and the reply file is 0600" "$err"

out=$(usb "Invalid Tasking")
err=""
[[ -f $SANDBOX/hostinfo.calls ]] || err="the USB path stopped at a refusal; it must carry on as before"
note "16b. the USB path still carries on after a refusal" "$err"

out=$(usb "")
err=""
[[ $out == *"Could not get this host's key"* ]] || err="no message for a missing key: $out"
note "16c. the USB path still says when the key could not be fetched" "$err"

# --- 11/12. the callers, whole-line anchored -------------------------------
MAN="$REPO_BIN/fog.man.reg"
AUTO="$REPO_BIN/fog.auto.reg"

err=""
grep -Fxq '[[ $realdoimage == "$(echo -n 1 | base64)" ]] && continueIntoTask' "$MAN" \
    || err="fog.man.reg does not continue on exactly the deploy-now answer"
sbline=$(grep -n '^sbEnrollAtRegistration$' "$MAN" | cut -d: -f1)
ctline=$(grep -n 'continueIntoTask$' "$MAN" | cut -d: -f1)
[[ -n $sbline && -n $ctline && $ctline -gt $sbline ]] \
    || err="$err; the continue is not after sbEnrollAtRegistration (sb=$sbline ct=$ctline)"
note "11. fog.man.reg continues only on deploy-now, after Secure Boot" "$err"

err=""
grep -q 'This host will reboot and deployment will start' "$MAN" \
    && err="fog.man.reg still promises a reboot"
grep -Fq 'Deployment will start (this host may reboot first)' "$MAN" \
    || err="$err; the new message is missing"
note "11b. fog.man.reg no longer promises a reboot" "$err"

err=""
grep -Fxq 'continueIntoTask' "$AUTO" || err="fog.auto.reg does not call continueIntoTask"
sbline=$(grep -n '^sbEnrollAtRegistration$' "$AUTO" | cut -d: -f1)
ctline=$(grep -n '^continueIntoTask$' "$AUTO" | cut -d: -f1)
[[ -n $sbline && -n $ctline && $ctline -gt $sbline ]] \
    || err="$err; the continue is not after sbEnrollAtRegistration (sb=$sbline ct=$ctline)"
note "12. fog.auto.reg continues after Secure Boot" "$err"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
