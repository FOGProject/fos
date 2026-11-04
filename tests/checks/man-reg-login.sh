#!/bin/bash
#
# Assertion harness for fogLogin() in bin/fog.man.reg.
#
#   tests/checks/man-reg-login.sh [path/to/fog.man.reg]
#
# The registration screen asks for a FOG GUI login before domain join and
# before imaging. The server copies the domain join account onto a new host
# only for a signed-in operator (FOGProject/fogproject#2054, GHSA-97vv-f7hc-rp5m),
# so what this function sends and keeps is security relevant:
#
#   - a password with spaces, glob characters, a backslash, or spelled -n
#     reaches the server byte for byte;
#   - one accepted login is not asked for again;
#   - three rejections return 1 and leave no credential for the POST;
#   - the plaintext password does not outlive the function.
#
# fog.man.reg is a top-level script, not a library, so the function is cut
# out of it by its own braces and evaluated alone. callServer is stubbed: it
# records each body it is given and answers from a queue.
#
# Pass an older fog.man.reg to watch this fail on unfixed code.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin/fog.man.reg}"
[[ -f $SCRIPT ]] || { echo "ERROR: cannot find $SCRIPT" >&2; exit 2; }

body=$(awk '/^fogLogin\(\) \{$/ {on=1} on {print} on && /^\}$/ {exit}' "$SCRIPT")
if [[ -z $body ]]; then
    echo "FAIL: no fogLogin() in $SCRIPT"
    exit 1
fi
eval "$body"

fails=0
check() {
    if [[ $1 == "$2" ]]; then
        return 0
    fi
    echo "FAIL: $3"
    echo "      expected: $2"
    echo "      got:      $1"
    fails=$((fails + 1))
}

# Stub. ANSWERS is the queue of replies; CALLS counts requests; LASTBODY is
# the most recent POST body.
callServer() {
    CALLS=$((CALLS + 1))
    LASTBODY="$2"
    serverBody="${ANSWERS[0]}"
    serverReason=""
    ANSWERS=("${ANSWERS[@]:1}")
}
reset() {
    fogAuthed=""
    user64=""
    pass64=""
    username=""
    password=""
    CALLS=0
    LASTBODY=""
}

# ---- 1. awkward password, accepted first time --------------------------------
reset
ANSWERS=('#!ok')
# Inner runs of spaces, glob characters and a backslash must survive. Edge
# blanks are trimmed on purpose: the web UI trims every posted value, so a
# stored password never has them.
pw='a  b*? \x -n'
fogLogin >/dev/null <<<"fog admin"$'\n'"  $pw  "
rc=$?
check "$rc" 0 'an accepted login returns 0'
check "$fogAuthed" 1 'an accepted login sets fogAuthed'
check "$(printf '%s' "$pass64" | base64 -d)" "$pw" 'the password reaches the server byte for byte, edge blanks trimmed'
check "$(printf '%s' "$user64" | base64 -d)" 'fog admin' 'the username reaches the server byte for byte'
check "$password" '' 'the plaintext password does not outlive fogLogin()'
check "$username" '' 'the plaintext username does not outlive fogLogin()'

# ---- 2. asked once ----------------------------------------------------------
before=$CALLS
fogLogin >/dev/null </dev/null
check "$?" 0 'a second call after an accepted login returns 0'
check "$CALLS" "$before" 'a second call after an accepted login asks the server nothing'

# ---- 3. three rejections ----------------------------------------------------
reset
ANSWERS=('#!il' '#!rl' '#!il')
fogLogin >/dev/null <<<$'u\np\nu\np\nu\np'
rc=$?
check "$rc" 1 'three rejections return 1'
check "$CALLS" 3 'three rejections make exactly three tries'
check "$fogAuthed" '' 'three rejections leave fogAuthed unset'
check "$user64$pass64" '' 'three rejections leave no credential for the registration POST'

# ---- 4. a long password is one base64 line ----------------------------------
reset
ANSWERS=('#!ok')
long=$(printf 'x%.0s' {1..100})
fogLogin >/dev/null <<<"u"$'\n'"$long"
check "$(printf '%s' "$pass64" | tr -cd '\n' | wc -c | tr -d ' ')" 0 'a long password encodes to one line'
check "$(printf '%s' "$pass64" | base64 -d)" "$long" 'a long password reaches the server intact'

if [[ $fails -gt 0 ]]; then
    exit 1
fi
echo "PASS man-reg-login"
exit 0
