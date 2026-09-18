#!/bin/bash
#
# Assertion harness for fog.statusreporter -- what actually reaches
# service/progress.php while a task is imaging.
#
#   tests/checks/status-reporting.sh   # run all cases, non-zero on failure
#
# fog.statusreporter is the only producer of imaging progress. partclone writes
# /tmp/status.fog whole on every UI tick (FOG's own partclone patch, see
# Buildroot/package/partclone/), this forwards it, and service/progress.php
# turns it into the percentage and the elapsed/remaining columns on the task
# list. Nothing else posts there.
#
# It treated that snapshot file as a stream, and three defects came out of that
# single misreading. Each case below drives one of them, because all three are
# invisible from the console -- the imaging screen looks identical whether the
# server is being told anything or not, which is how they survived.
#
#   Truncation. The reporter did `cat /dev/null > /tmp/status.fog` after every
#   read. partclone rewrites the file itself with fopen(..., "w"), so this
#   bought nothing, and a read landing between the truncation and the next tick
#   found it EMPTY and posted an empty status -- which the server then discarded
#   silently, because progress.php requires six @-separated fields and says
#   nothing when it does not get them. Case 3 pins that the file survives a
#   read; cases 5 and 6 pin that a payload the server would discard is not sent
#   at all.
#
#   Unconditional posting. A post went out every three seconds whether or not
#   the value had changed, and each one costs the server a host lookup, a task
#   load, an image load and a save. Multiplied by every client in a multicast.
#   Case 4 pins that an unchanged value is not re-sent; case 7 pins that it is
#   still re-sent eventually, because a client that has gone quiet and one that
#   has stalled have to be distinguishable in the server's log. That is not
#   hypothetical: forum topic 18247 is a deploy that ends 48 seconds after its
#   last progress post, and the gap is the whole diagnosis.
#
#   The `continue` that skipped the sleep. `[[ -z $mac ]] && continue` jumped
#   past the usleep at the bottom of the loop, so a task that reached it span at
#   100% CPU for its whole duration. funcs.sh recovers the MAC now
#   (fogproject#1767) so nothing reaches it, which is exactly why the shape has
#   to be pinned rather than left to be rediscovered: case 8 drives an empty MAC
#   and case 9 refuses a `continue` anywhere in the loop at all.
#
# Mechanism mirrors tests/checks/server-post-reporting.sh: a sandbox copy of the
# script with its hardcoded /tmp path rewritten, PATH-shadowed curl, dmidecode
# and usleep. The timing constants are rewritten per run so the assertions take
# seconds rather than the half-minute the shipped values would need; the loop
# itself is the shipped one, running for real.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BIN="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin"
REPORTER="$REPO_BIN/fog.statusreporter"

[[ -f $REPORTER ]] || { echo "ERROR: cannot find fog.statusreporter under $REPO_BIN" >&2; exit 2; }

export SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

STATUSFILE="$SANDBOX/status.fog"
POSTLOG="$SANDBOX/posts"
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"

# curl double. Records one line per argument and a terminator, so a case can
# count posts and read back exactly what was sent.
cat > "$STUBBIN/curl" <<'EOF'
#!/bin/bash
{
    printf '%s\n' "$@"
    printf -- '--end--\n'
} >> "$SANDBOX/posts"
exit 0
EOF
chmod +x "$STUBBIN/curl"

printf '#!/bin/bash\nprintf "%%s" "44454C4C-4C00-1034-8044-C4C04F435431"\n' > "$STUBBIN/dmidecode"
chmod +x "$STUBBIN/dmidecode"

# usleep is not present on every developer machine, and the argument is
# microseconds. Whole seconds are enough: the shipped poll is one second.
cat > "$STUBBIN/usleep" <<'EOF'
#!/bin/bash
exec sleep "$(( ${1:-0} / 1000000 ))"
EOF
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

VALID1='108.53MB/min@00:01:23@00:04:17@12.50 GiB@44.20 GiB@ 28.28@47458910208'
VALID2='131.07MB/min@00:02:31@00:03:02@21.80 GiB@44.20 GiB@ 49.32@47458910208'

# A sandbox copy of the reporter with the /tmp path and the three timing
# constants rewritten. Everything else -- the loop, the guards, the curl line --
# is the shipped code.
#
# $1 minpostsecs  $2 keepalivesecs
buildReporter() {
    sed -e "s#^statusfile=.*#statusfile=\"$STATUSFILE\"#" \
        -e "s#^minpostsecs=.*#minpostsecs=$1#" \
        -e "s#^keepalivesecs=.*#keepalivesecs=$2#" \
        "$REPORTER" > "$SANDBOX/fog.statusreporter"
}

REPORTER_PID=""
startReporter() {
    local mac="${1-00:11:22:33:44:55}"
    : > "$POSTLOG"
    PATH="$STUBBIN:$PATH" bash "$SANDBOX/fog.statusreporter" "$mac" "http://fog.example/fog/" &
    REPORTER_PID=$!
}
stopReporter() {
    [[ -n $REPORTER_PID ]] && kill "$REPORTER_PID" 2>/dev/null
    wait "$REPORTER_PID" 2>/dev/null
    REPORTER_PID=""
}

postCount() {
    # grep -c prints 0 and exits 1 on no match, so the count is read from the
    # substitution rather than from the exit status.
    local n
    n=$(grep -c -- '--end--' "$POSTLOG" 2>/dev/null)
    echo "${n:-0}"
}
# The decoded status of the Nth post.
postStatus() {
    local n="$1"
    awk -v want="$n" '
        /^status=/ { c++; if (c == want) { sub(/^status=/, ""); print; exit } }
    ' "$POSTLOG" | base64 -d 2>/dev/null
}

# ---------------------------------------------------------------- cases 1-4
# One run covering the normal life of a restore: a first value, a changed
# value, and a value that has not moved.
buildReporter 0 999
printf '%s\n' "$VALID1" > "$STATUSFILE"
startReporter
sleep 2

count=$(postCount)
[[ $count -ge 1 ]] \
    && note "1. a valid status line is posted" "" \
    || note "1. a valid status line is posted" "posts=$count"

got=$(postStatus 1)
[[ $got == "$VALID1" ]] \
    && note "2. the payload decodes to the producer's line" "" \
    || note "2. the payload decodes to the producer's line" "got '$got'"

onfile=$(cat "$STATUSFILE")
[[ $onfile == "$VALID1" ]] \
    && note "3. the producer's file is not truncated by the read" "" \
    || note "3. the producer's file is not truncated by the read" "file now '$onfile'"

printf '%s\n' "$VALID2" > "$STATUSFILE"
sleep 2
after_change=$(postCount)
got=$(postStatus "$after_change")
[[ $got == "$VALID2" ]] \
    && note "4a. a changed value is posted" "" \
    || note "4a. a changed value is posted" "last post was '$got'"

sleep 3
[[ $(postCount) -eq $after_change ]] \
    && note "4b. an unchanged value is not re-posted" "" \
    || note "4b. an unchanged value is not re-posted" "posts went $after_change -> $(postCount)"
stopReporter

# ------------------------------------------------------------------ case 5
# A partial line -- what a read that lands mid-write returns.
buildReporter 0 999
printf '108.53MB/min@00:01:23@00:04' > "$STATUSFILE"
startReporter
sleep 2
[[ $(postCount) -eq 0 ]] \
    && note "5. a short line the server would discard is not sent" "" \
    || note "5. a short line the server would discard is not sent" "posts=$(postCount)"
stopReporter

# ------------------------------------------------------------------ case 6
buildReporter 0 999
: > "$STATUSFILE"
startReporter
sleep 2
[[ $(postCount) -eq 0 ]] \
    && note "6. an empty producer file posts nothing" "" \
    || note "6. an empty producer file posts nothing" "posts=$(postCount)"
stopReporter

# ------------------------------------------------------------------ case 7
# Keepalive: the value has not changed, but the client is still alive and the
# server's log has to show it.
buildReporter 0 2
printf '%s\n' "$VALID1" > "$STATUSFILE"
startReporter
sleep 5
[[ $(postCount) -ge 2 ]] \
    && note "7. an unchanged value is re-posted on the keepalive interval" "" \
    || note "7. an unchanged value is re-posted on the keepalive interval" "posts=$(postCount)"
stopReporter

# ------------------------------------------------------------------ case 8
# No MAC: nothing is posted, and -- the part that matters -- the loop is still
# sleeping rather than spinning, so it is alive and has not burned a core.
buildReporter 0 999
printf '%s\n' "$VALID1" > "$STATUSFILE"
startReporter ""
sleep 2
nomac_posts=$(postCount)
alive=""
kill -0 "$REPORTER_PID" 2>/dev/null && alive=yes
# utime + stime + cutime + cstime, in clock ticks, from /proc rather than from
# `ps -o time=`. ps reports the shell's OWN cpu time, and a spinning loop spends
# nearly all of its time in the `tail` it forks each pass -- a child whose time
# lands in cutime/cstime. Measured against a deliberately reintroduced
# `continue`, ps showed 00:00:00 for a loop burning a core, so the assertion
# passed on the defect it exists to catch.
cputicks=$(awk '{print $14 + $15 + $16 + $17}' "/proc/$REPORTER_PID/stat" 2>/dev/null)
stopReporter
[[ $nomac_posts -eq 0 ]] \
    && note "8a. an empty MAC posts nothing" "" \
    || note "8a. an empty MAC posts nothing" "posts=$nomac_posts"
# 100 ticks is one second of cpu across a two second wait. A loop that sleeps
# spends a handful; a loop that spins spends everything it is given.
[[ $alive == yes && -n $cputicks && $cputicks -lt 100 ]] \
    && note "8b. an empty MAC does not spin the loop" "" \
    || note "8b. an empty MAC does not spin the loop" "alive='$alive' cputicks='$cputicks'"

# ------------------------------------------------------------------ case 9
# Source-level guards. The `continue` is the defect's shape rather than any one
# instance of it, and --max-time is what stops a wedged connection from holding
# the loop with nothing on screen.
loopbody=$(awk '/^while :; do/,/^done/' "$REPORTER")
grep -q '\bcontinue\b' <<< "$loopbody" \
    && note "9a. the poll loop contains no continue" "found one; it would skip the sleep" \
    || note "9a. the poll loop contains no continue" ""

grep -q -- '--max-time' "$REPORTER" \
    && note "9b. the post carries a timeout" "" \
    || note "9b. the post carries a timeout" "no --max-time"

grep -q -- '--data-urlencode "status=' "$REPORTER" \
    && note "9c. the status field is url-encoded" "" \
    || note "9c. the status field is url-encoded" "status is sent raw"

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
