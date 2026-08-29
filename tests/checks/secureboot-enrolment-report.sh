#!/bin/bash
#
# Assertion harness for sbReport() and the three exits that call it.
#
#   tests/checks/secureboot-enrolment-report.sh
#
# What it proves: that a Secure Boot enrolment task tells the FOG server WHICH
# of its three outcomes it reached, and that failing to tell it never fails the
# task.
#
# fog.enrollsb has three exits and every one of them ends with the same
# argument-free `. /bin/fog.nonimgcomplete`, so from the server all three look
# identical -- the task completed:
#
#   db       the machine was in Setup Mode, `db` was written, it IS enrolled
#   trusted  it already trusted this certificate; nothing was enrolled here,
#            and nothing observed how the trust got there
#   mok      a request was STAGED. The machine is NOT enrolled and will not
#            boot with Secure Boot on until a human confirms it at MokManager
#
# Recording the third as an enrolment is a lie an administrator acts on: they
# turn Secure Boot on in firmware and the machine stops booting. Case 4 is the
# one that holds that shut, and it is anchored on the whole call line -- a grep
# for "sbReport" alone passes when the argument has been changed to "db", which
# is the exact regression worth catching.
#
# The other half is that this must never be able to fail a task. The enrolment
# has already happened by the time sbReport runs; a server that is too old to
# have the endpoint answers 404, and one that is unreachable answers nothing.
# In both cases the machine is enrolled and the task must still complete. So
# sbReport returns 0 unconditionally, says on screen what went wrong, and says
# it in words that do not read as an enrolment failure -- cases 5 to 8.
#
# Mechanism mirrors tests/checks/server-post-reporting.sh: source sandbox
# copies of funcs.sh (for callServer) and secureboot-funcs.sh with their
# absolute paths rewritten, and PATH-shadow curl with a stub that emulates
# -w '\n%{http_code}' from the environment and logs its argv.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"
REPO_BIN="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin"

for f in funcs.sh secureboot-funcs.sh; do
    [[ -f $REPO_LIB/$f ]] || { echo "ERROR: cannot find $f under $REPO_LIB" >&2; exit 2; }
done
[[ -f $REPO_BIN/fog.enrollsb ]] || { echo "ERROR: cannot find fog.enrollsb under $REPO_BIN" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX

mkdir -p "$SANDBOX/proc" "$SANDBOX/bin"
: > "$SANDBOX/proc/mounts"

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

# Same ordering rule as tests/checks/secureboot.sh: the /tmp rule must run
# before the /sys and /proc ones, because $SANDBOX is itself under /tmp.
sed -e "s#\"/tmp/#\"$SANDBOX/#g" \
    -e "s#/sys/firmware/efi#$SANDBOX/sys/firmware/efi#g" \
    -e "s#/proc/mounts#$SANDBOX/proc/mounts#g" \
    "$REPO_LIB/secureboot-funcs.sh" > "$SANDBOX/secureboot-funcs.sh"

STUBBIN="$SANDBOX/bin"
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SANDBOX/curl.argv"
[[ ${FAKE_CURL_RC:-0} -ne 0 ]] && exit "$FAKE_CURL_RC"
printf '%s' "${FAKE_BODY-}"
printf '\n%s' "${FAKE_CODE:-200}"
exit 0
EOF
chmod +x "$STUBBIN/curl"

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1))
    fi
}

# Drives sbReport with the environment a real task has: web and mac come from
# the kernel command line, and sbState() reads the sandbox firmware. Prints the
# return code so a case can assert the task is never failed.
drive() {
    (
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        export FAKE_CURL_RC FAKE_CODE FAKE_BODY
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        . "$SANDBOX/secureboot-funcs.sh" >/dev/null 2>&1
        web="http://fog.example/fog/"
        mac="00:11:22:33:44:55"
        sbReport "$@"
        printf '\nRC=%s\n' "$?"
    )
}

argv() { grep -Fxq -- "$1" "$SANDBOX/curl.argv"; }

# --- 1. the happy path posts everything the server needs ------------------
rm -f "$SANDBOX/curl.argv"
out=$(FAKE_CODE=200 FAKE_BODY="##ok" drive "db" "AA:BB")
err=""
[[ $out == *"RC=0"* ]] || err="rc not 0"
argv "http://fog.example/fog/service/secureboot.report.php" \
    || err="$err; wrong url: $(grep -c . "$SANDBOX/curl.argv") args"
data=$(grep -m1 'result=' "$SANDBOX/curl.argv")
[[ $data == *"mac=00:11:22:33:44:55"* ]] || err="$err; no mac"
[[ $data == *"result=db"* ]] || err="$err; no result"
[[ $data == *"cert=AA:BB"* ]] || err="$err; no cert"
[[ $data == *"sbstate="* ]] || err="$err; no sbstate"
note "1. a report posts mac, result, cert and state to the endpoint" "$err"

# --- 2. it is a POST, not a GET -------------------------------------------
# The endpoint reads INPUT_POST only. A call that lost its data argument would
# still reach a 200 and look fine from here.
err=""
argv "--data" || err="--data not on the argv"
note "2. the report is a POST carrying its body" "$err"

# --- 3. nothing is posted when there is nothing to say --------------------
# Guards against a half-populated row: a blank fingerprint stored against a
# host reads as "enrolled, certificate unknown", which is worse than no record
# because it cannot be told apart from a real enrolment whose cert was cleared.
for args in '"db" ""' '"" "AA:BB"'; do
    rm -f "$SANDBOX/curl.argv"
    eval "out=\$(FAKE_CODE=200 FAKE_BODY='##ok' drive $args)"
    err=""
    [[ -e $SANDBOX/curl.argv ]] && err="posted anyway"
    [[ $out == *"RC=0"* ]] || err="$err; rc not 0"
    note "3. sbReport($args) posts nothing and still returns 0" "$err"
done

# --- 4-8. a failure to record must never fail the task --------------------
# Each arm returns 0 and says something. The wording matters as much as the
# status: "enrolment failed" sends the next person to a firmware screen that is
# perfectly fine, so the message has to name the RECORDING as the thing that
# did not happen.
for arm in "unreachable:FAKE_CURL_RC=7" "http404:FAKE_CODE=404" \
           "emptybody:FAKE_CODE=200 FAKE_BODY=" "wrongbody:FAKE_CODE=200 FAKE_BODY=##notasking"; do
    name=${arm%%:*}
    env=${arm#*:}
    rm -f "$SANDBOX/curl.argv"
    out=$(eval "$env drive 'db' 'AA:BB'")
    err=""
    [[ $out == *"RC=0"* ]] || err="rc not 0 -- this would fail the task"
    grep -qi 'could not be recorded' <<<"$out" || err="$err; said nothing"
    grep -qi 'enrolment succeeded' <<<"$out" \
        || err="$err; does not say the enrolment itself was fine"
    note "4. $name: reports the problem and still returns 0" "$err"
done

# --- 9. a successful report is quiet --------------------------------------
# Noise on the happy path is not free: this text lands on the screen of a
# machine somebody is watching, directly under a banner that already told them
# what happened.
out=$(FAKE_CODE=200 FAKE_BODY="##ok" drive "db" "AA:BB")
err=""
grep -qi 'could not be recorded' <<<"$out" && err="complained on success"
note "9. a successful report prints nothing" "$err"

# --- 10. every exit in fog.enrollsb reports, and reports the right thing --
# Whole-line anchored, for the same reason tests/checks/server-post-reporting.sh
# anchors its call sites: a grep for the function name alone passes when the
# argument has been changed, and the argument is the entire point.
err=""
for want in 'sbReport "trusted" "$fingerprint"' \
            'sbReport "db" "$fingerprint"' \
            'sbReport "mok" "$fingerprint"'; do
    grep -Fq "$want" "$REPO_BIN/fog.enrollsb" || err="$err; missing: $want"
done
note "10. all three exits report their own outcome" "$err"

# --- 11. the staged-MOK exit must not claim an enrolment ------------------
# THE assertion in this file. Everything else is plumbing; this is the one that
# stops FOG telling an administrator a machine is enrolled when it is not.
err=""
staged=$(awk '/^sbReport /{ last=$0 } END { print last }' "$REPO_BIN/fog.enrollsb")
[[ $staged == 'sbReport "mok" "$fingerprint"' ]] \
    || err="the last exit reports [$staged], not a staged MOK"
note "11. the staged-MOK exit reports 'mok', never 'db'" "$err"

# --- 12. the report happens BEFORE the task is completed ------------------
# Order is load-bearing: fog.nonimgcomplete is what clears the task, and a
# report that arrives after it is refused -- the endpoint requires the enrolment
# task to still be in flight, so that a caller who merely knows a MAC cannot
# stamp an enrolment onto a host that was never asked to enrol.
err=""
last_report=""
while read -r n line; do
    case $line in
        'sbReport '*)
            last_report=$n
            ;;
        '. /bin/fog.nonimgcomplete'*)
            [[ -n $last_report ]] \
                || err="$err; the completion at line $n has no report before it"
            # CONSUMED, not merely remembered. Without this the report belonging
            # to the PREVIOUS exit satisfies the next one, and moving a report
            # below its own completion passes -- which is the whole failure this
            # case exists to catch. It was green until the mutation was run.
            last_report=""
            ;;
    esac
done < <(grep -n '^[[:space:]]*\(sbReport \|\. /bin/fog\.nonimgcomplete\)' \
    "$REPO_BIN/fog.enrollsb" | sed 's/:[[:space:]]*/ /')
note "12. each exit reports before completing the task" "$err"

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
