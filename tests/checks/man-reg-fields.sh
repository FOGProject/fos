#!/bin/bash
#
# Assertion harness for regfields= in bin/fog.man.reg (fogproject#2189).
#
#   tests/checks/man-reg-fields.sh [path/to/fog.man.reg]
#
# regfields= on an iPXE menu entry names the prompts full registration asks,
# so a classroom can register with only hostname, group and image:
#
#   - without regfields, every y/N question is asked as before;
#   - with regfields, a listed field is asked with no y/N question, and any
#     other field is skipped without reading a key;
#   - with regfields, groups and images are picked from a whiptail list built
#     from the server's listing, and the pick reaches the POST as base64;
#   - Esc in the list leaves the field empty;
#   - with no whiptail, or nothing listed, the typed-ID prompt is used.
#
# fog.man.reg is a top-level script, so its functions are cut out by their own
# braces and evaluated alone, as man-reg-login.sh does. callServer answers with
# fixtures/grouplisting.txt, which is a capture of the server's
# service/grouplisting.php (literal \t and \n escapes, no trailing newline).
# whiptail and setIDs are stubbed and record what they were given.
#
# Pass an older fog.man.reg to watch this fail on unfixed code.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin/fog.man.reg}"
[[ -f $SCRIPT ]] || { echo "ERROR: cannot find $SCRIPT" >&2; exit 2; }
LISTING="$(cat "$HERE/fixtures/grouplisting.txt")"

for fn in checkAndSet regShows wantField askIDs; do
    body=$(awk -v fn="$fn" '$0 == fn "() {" {on=1} on {print} on && /^\}$/ {exit}' "$SCRIPT")
    if [[ -z $body ]]; then
        echo "FAIL: no $fn() in $SCRIPT"
        exit 1
    fi
    eval "$body"
done

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

WTLOG=$(mktemp)
trap 'rm -f "$WTLOG"' EXIT
callServer() {
    CALLED="$1"
    serverBody="$LISTING"
    serverReason=""
}
# Runs inside $( ), so it records to a file. The reply goes to stderr, as
# whiptail prints its choice there.
whiptail() {
    printf '%s\n' "$@" > "$WTLOG"
    printf '%s' "$WT_REPLY" >&2
    return "${WT_RC:-0}"
}
setIDs() {
    SETIDS="$1 $2 $3"
    printf -v "$1" '%s' "typed"
}
reset() {
    unset regfields picked
    WT_REPLY=""
    WT_RC=0
    SETIDS=""
    CALLED=""
    : > "$WTLOG"
}

# ---- 1. no regfields: the y/N question is asked, as before ------------------
reset
out=$(wantField group "Would you like to associate this host with groups?" <<<$'maybe\ny')
rc=$?
check "$rc" 0 'without regfields, "y" after an invalid answer returns 0'
check "$(grep -c 'Invalid input' <<<"$out")" 1 'without regfields, an invalid answer is refused once'
wantField group "q" <<<"" >/dev/null
check "$?" 1 'without regfields, Enter means no'
regShows primaryuser
check "$?" 0 'without regfields, every field shows'

# ---- 2. regfields: listed fields asked, others skipped, no key read ---------
reset
regfields="Group,image"
wantField group "q" </dev/null >/dev/null
check "$?" 0 'a listed field is asked, case-insensitively'
out=$(wantField domain "q" <<<"y")
check "$?" 1 'an unlisted field is skipped even when the operator would say y'
check "$out" '' 'an unlisted field prints no question'
regfields="group,image,deploy,domain"
wantField deploy "Would you like to deploy image to this computer now?" <<<"" >/dev/null
check "$?" 1 'a listed deploy still asks y/N, and Enter means no'
out=$(wantField domain "Would you like this host to join a domain?" <<<"y")
check "$?" 0 'a listed domain still asks y/N, and y means yes'
check "$(grep -c '(y/N)' <<<"$out")" 1 'a listed domain prints its y/N question'
regfields="Group,image"
regShows other1
check "$?" 1 'an unlisted text field does not show'
regShows image
check "$?" 0 'a listed text field shows'
regfields="grouping"
regShows group
check "$?" 1 'a name is matched whole, not as a prefix'

# ---- 3. single pick from the server listing ---------------------------------
reset
regfields="group,image"
WT_REPLY="22"
askIDs picked image "" </dev/null 2>/dev/null
check "$CALLED" "service/imagelisting.php" 'the image list comes from imagelisting.php'
check "$(printf '%s' "$picked" | base64 -d)" "22" 'the picked image ID reaches the POST as base64'
check "$(grep -c -- '--menu' "$WTLOG")" 1 'a single field uses a menu'
check "$(grep -cx "I'm a little teapot" "$WTLOG")" 1 "an entry name with an apostrophe reaches the list whole"
check "$(grep -cx 'Computer -> Example.com' "$WTLOG")" 1 'an entry name with spaces and > reaches the list whole'
check "$(grep -cx '28' "$WTLOG")" 1 'the list tags carry the IDs'
check "$SETIDS" '' 'the typed-ID prompt is not used when whiptail lists entries'

# ---- 4. several picks for groups --------------------------------------------
reset
regfields="group"
WT_REPLY=$'28\n18\n'
askIDs picked group true </dev/null 2>/dev/null
check "$(printf '%s' "$picked" | base64 -d)" "28,18" 'several groups reach the POST comma-separated'
check "$(grep -c -- '--checklist' "$WTLOG")" 1 'a several-value field uses a checklist'
check "$(grep -cx 'OFF' "$WTLOG")" 4 'every checklist entry starts unmarked'

# ---- 5. Esc leaves the field empty ------------------------------------------
reset
regfields="image"
WT_RC=255
askIDs picked image "" </dev/null 2>/dev/null
check "$picked" '' 'Esc leaves the field empty'

# ---- 6. fallbacks to the typed-ID prompt ------------------------------------
reset
askIDs picked group true </dev/null
check "$SETIDS" 'picked group true' 'without regfields, the typed-ID prompt is used'
check "$CALLED" '' 'without regfields, nothing is fetched up front'
reset
regfields="group"
LISTING="There are no groups on this server"
askIDs picked group true </dev/null
check "$SETIDS" 'picked group true' 'with nothing listed, the typed-ID prompt shows the server message'
reset
regfields="group"
unset -f whiptail
PATH=/nonexistent askIDs picked group true </dev/null
check "$SETIDS" 'picked group true' 'with no whiptail, the typed-ID prompt is used'

if [[ $fails -gt 0 ]]; then
    exit 1
fi
echo "PASS man-reg-fields"
exit 0
