#!/bin/bash
#
# Assertion harness for the OS class (ADR-0022, fos#204).
#
#   tests/checks/os-class.sh   # run all cases, exit non-zero on any failure
#
# FOS used to branch on lists of osids (`[5-7]|9|10|11`) at 20 sites, and
# determineOS() aborted on any id it did not know. Now determineOS() resolves
# one global, osClass, from the osid and the optional server family, and every
# site branches on osClass.
#
# Case one is the truth table. For each site it holds the osid list the site
# had BEFORE the change. These lists come from the source on origin/master
# (559abc1), not from the rewritten code. The harness takes the osClass
# patterns out of the real rewritten source, runs both against every known
# osid (1-11, 50, 51, 99) with the family empty and with the seeded family, and
# asserts that both take the same branch. A site that sits in no list (win98
# in most of them) takes "no branch" in both.
#
# Case two covers determineOS() itself: frozen ids, new ids that resolve from
# the family, the server-wins conflict, and every error.
#
# Case three covers the call sites that pass the family, and asserts that the
# osid comparisons are gone from everything outside determineOS().
#
# Mechanism mirrors tests/checks/ntfs-shrink-retry.sh: source a sandbox copy of
# the library and override handleError AFTER sourcing so an abort is
# observable.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay"
REPO_LIB="$OVERLAY/usr/share/fog/lib"
BIN="$OVERLAY/bin"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ -n $2 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }
eq() { # eq <label> <got> <want>
    if [[ $2 == "$3" ]]; then pass; else fail "$1" "got '$2', want '$3'"; fi
}

# ---------------------------------------------------------------------------
# determineOS driver. Prints "ABORT" or "<osClass>|<osname>|<mbrfile>".
# ---------------------------------------------------------------------------
dos() {
    (
        set +u
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT"; exit 1; }
        osClass=""; osname=""; mbrfile=""
        if [[ $# -ge 2 ]]; then determineOS "$1" "$2"; else determineOS "$1"; fi
        echo "$osClass|$osname|$mbrfile"
    )
}

# ---------------------------------------------------------------------------
# Case one: the truth table.
# ---------------------------------------------------------------------------
IDS="1 2 3 4 5 6 7 8 9 10 11 50 51 99"
# An independent copy of determineOS()'s fallback table. Update it together
# with determineOS(), or the harness will not notice the table changed.
seeded() {
    case $1 in
        [1-7]|9|10|11) echo windows ;;
        8) echo macos ;;
        50|51) echo linux ;;
        99) echo other ;;
    esac
}

# Resolve every (id, family) once. CLS["id|family"]=class
declare -A CLS
for id in $IDS; do
    for fam in "" "$(seeded "$id")"; do
        r="$(dos "$id" "$fam")"
        CLS["$id|$fam"]="${r%%|*}"
    done
done

# scope <file> <function>   the function's text, or the whole file
scope() {
    if [[ -z $2 ]]; then
        cat "$1"
    else
        awk -v f="$2" '$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "$1"
    fi
}

# arms <occurrence>   the depth-one arm patterns of the nth `case $osClass in`
arms() {
    awk -v occ="$1" '
        /case \$osClass in[[:space:]]*$/ && !on { n++; if (n == occ) { on = 1; depth = 1; next } }
        on && /^[[:space:]]*case .* in[[:space:]]*$/ { depth++; next }
        on && /^[[:space:]]*esac/ { depth--; if (!depth) exit; next }
        on && depth == 1 && /^[[:space:]]*[^[:space:]()]+\)[[:space:]]*$/ {
            sub(/^[[:space:]]+/, ""); sub(/\)[[:space:]]*$/, ""); print
        }'
}

# cond <occurrence>   the first test of the nth `[[ $osClass ... ]]`
cond() {
    local t
    t="$(grep -oE '\[\[ \$osClass (==|!=) [^ ]+ ' | awk -v n="$1" 'NR == n')"
    [[ -n $t ]] && echo "${t}]]"
}

# armOf <value> <pattern>...   index of the first matching arm, or -1
armOf() {
    local v="$1" i=0 p
    shift
    for p in "$@"; do
        # eval, because `|` in an expanded pattern is literal, not alternation.
        if eval "case \$v in $p) true ;; *) false ;; esac"; then
            echo $i
            return
        fi
        i=$((i + 1))
    done
    echo -1
}

# condOf <expr> <osid> <osClass>   1 when the test is true
condOf() { ( osid="$2"; osClass="$3"; eval "$1" ) && echo 1 || echo 0; }

tableRows=0

# Known divergences, as "<site>|<osid>" = "<base branch>:<new branch>".
# completeTasking() on the base tested `[[ $osid == +([1-2]|4|[5-7]|9|10|11) ]]`.
# The `+( )` repeats the group, so it also matched 51 ("5" then "1") and 99
# ("9" then "9"), which no one listed. osid 50 does not match. 50 and 51 share
# the class linux, so a class test cannot keep that accident for 51. The new
# test is the listed Windows classes plus `other`, so 99 keeps its branch. Only
# 51 is known to diverge: completeTasking no longer runs changeHostname on its
# NTFS partitions after a deploy.
declare -A KNOWN
KNOWN["funcs completeTasking|51"]="1:0"
# site <label> <file> <function> <case|cond> <occurrence> <base>...
#   base is the list of arm patterns (case), or the test (cond), as written
#   on origin/master, with $osid.
site() {
    local label="$1" file="$2" func="$3" kind="$4" occ="$5"
    shift 5
    local src new id fam cls b n
    src="$(scope "$file" "$func")"
    if [[ $kind == case ]]; then
        mapfile -t new < <(arms "$occ" <<< "$src")
        if [[ ${#new[@]} -ne $# ]]; then
            fail "$label: found ${#new[@]} osClass arms, the base had $#" "arms: ${new[*]}"
            return
        fi
    else
        new="$(cond "$occ" <<< "$src")"
        if [[ -z $new ]]; then
            fail "$label: no osClass test found"
            return
        fi
    fi
    for id in $IDS; do
        for fam in "" "$(seeded "$id")"; do
            cls="${CLS["$id|$fam"]}"
            if [[ -z $cls ]]; then
                fail "$label: osid $id family '$fam' has no osClass"
                continue
            fi
            if [[ $kind == case ]]; then
                b="$(armOf "$id" "$@")"
                n="$(armOf "$cls" "${new[@]}")"
            else
                b="$(condOf "$1" "$id" "")"
                n="$(condOf "$new" "" "$cls")"
            fi
            tableRows=$((tableRows + 1))
            if [[ $b == "$n" ]]; then
                pass
            elif [[ -n ${KNOWN["$label|$id"]} && $b == "${KNOWN["$label|$id"]%%:*}" && $n == "${KNOWN["$label|$id"]##*:}" ]]; then
                # A divergence that is understood and named, not a silent one.
                echo "NOTE: $label: osid $id takes branch $n, the base took $b (known, see KNOWN)"
                pass
            else
                fail "$label: osid $id family '$fam' (osClass $cls) took branch $n, the base took $b"
            fi
        done
    done
}

F="$REPO_LIB/funcs.sh"
site "funcs validResizeOS"        "$F" validResizeOS                    cond 1 '[[ $osid != @([1-2]|4|[5-7]|9|10|11|50|51) ]]'
site "funcs shrinkPartition case" "$F" shrinkPartition                  case 1 '[1-2]|4' '[5-7]|9|10|11'
site "funcs shrinkPartition vista" "$F" shrinkPartition                 cond 1 '[[ $osid -eq 2 ]]'
site "funcs getValidRestorePartitions" "$F" getValidRestorePartitions   case 1 '[1-2]' '4|[5-7]|9|10|11' '*'
site "funcs changeHostname"       "$F" changeHostname                   case 1 '1' '2|4|[5-7]|9|10|11'
site "funcs fixWin7boot"          "$F" fixWin7boot                      cond 1 '[[ $osid != [5-7] ]]'
site "funcs clearMountedDevices"  "$F" clearMountedDevices              case 1 '4|[5-7]|9|10|11'
site "funcs removePageFile"       "$F" removePageFile                   case 1 '[1-2]|4|[5-7]|9|10|11|50|51'
site "funcs completeTasking"      "$F" completeTasking                  cond 1 '[[ $osid == +([1-2]|4|[5-7]|9|10|11) ]]'
site "funcs handleError"          "$F" handleError                      case 1 '[1-2]|4|[5-7]|9|10|11|50|51'
site "funcs savePartitionTablesAndBootLoaders" "$F" savePartitionTablesAndBootLoaders case 1 '4|50|51'
site "funcs restorePartitionTablesAndBootLoaders" "$F" restorePartitionTablesAndBootLoaders case 1 '50|51' '*'
site "funcs restorePartition"     "$F" restorePartition                 case 1 '[1-2]' '4|8|50|51|99' '[5-7]|9|10|11'
site "funcs performRestore"       "$F" performRestore                   cond 1 '[[ $osid == +([5-7]) ]]'
site "partition-funcs processSfdisk" "$REPO_LIB/partition-funcs.sh" processSfdisk case 1 '[1-2]'
site "fog.download preparePartitions" "$BIN/fog.download" ""            case 1 '4|50|51' '[1-2]' '[5-7]|9|10|11'
site "fog.download restore"       "$BIN/fog.download" ""                case 2 '[1-2]' '[5-7]|9|10|11' '4|50|51'
# fog.upload keeps [4-7] where the other sites use [5-7]; that stays.
site "fog.upload win7partcnt"     "$BIN/fog.upload" ""                  cond 1 '[[ $osid == @([1-2]|[4-7]|9|10|11) ]]'
site "fog.upload fixed parts"     "$BIN/fog.upload" ""                  case 1 '[4-7]|9|10|11|50|51'
site "fog.upload vista"           "$BIN/fog.upload" ""                  cond 2 '[[ $osid -eq 2 ]]'

# The truth table must have looked at something: 20 sites, 28 pairs each.
eq "truth table size" "$tableRows" 560

# validResizeOS run for real, once per class.
resize() {
    ( set +u; . "$SANDBOX/funcs.sh"; handleError() { echo ABORT; exit 1; }
      osClass="$1"; osname=x; osid=x; validResizeOS; echo OK )
}
for c in xp vista winother win7 winmodern linux; do eq "validResizeOS accepts $c" "$(resize "$c")" OK; done
for c in win98 mac other; do eq "validResizeOS refuses $c" "$(resize "$c")" ABORT; done

# ---------------------------------------------------------------------------
# Case two: determineOS().
# ---------------------------------------------------------------------------
# frozen ids: class, and the family argument is ignored, not validated.
for pair in 1:xp 2:vista 3:win98 4:winother 5:win7 6:win7 7:win7; do
    id="${pair%%:*}"; want="${pair##*:}"
    eq "osid $id, no family" "$(dos "$id" | cut -d'|' -f1)" "$want"
    eq "osid $id, family linux is ignored" "$(dos "$id" linux | cut -d'|' -f1)" "$want"
    eq "osid $id, family bogus is ignored" "$(dos "$id" bogus | cut -d'|' -f1)" "$want"
done

# ids FOS knows resolve without a family (today's inits against an old server).
for pair in 8:mac 9:winmodern 10:winmodern 11:winmodern 50:linux 51:linux 99:other; do
    id="${pair%%:*}"; want="${pair##*:}"
    eq "osid $id, no family (built-in fallback)" "$(dos "$id" | cut -d'|' -f1)" "$want"
done

# osname and mbrfile for known ids are untouched.
eq "osid 1 text"  "$(dos 1)"  "xp|Windows XP|/usr/share/fog/mbr/xp.mbr"
eq "osid 2 text"  "$(dos 2)"  "vista|Windows Vista|/usr/share/fog/mbr/vista.mbr"
eq "osid 3 text"  "$(dos 3)"  "win98|Windows 98|"
eq "osid 4 text"  "$(dos 4)"  "winother|Windows (Other)|"
eq "osid 5 text"  "$(dos 5)"  "win7|Windows 7|/usr/share/fog/mbr/win7.mbr"
eq "osid 6 text"  "$(dos 6)"  "win7|Windows 8|/usr/share/fog/mbr/win8.mbr"
eq "osid 7 text"  "$(dos 7)"  "win7|Windows 8.1|/usr/share/fog/mbr/win8.mbr"
eq "osid 8 text"  "$(dos 8)"  "mac|Apple Mac OS|"
eq "osid 9 text"  "$(dos 9)"  "winmodern|Windows 10|"
eq "osid 10 text" "$(dos 10)" "winmodern|Windows 11|"
eq "osid 11 text" "$(dos 11)" "winmodern|Windows Server|"
eq "osid 50 text" "$(dos 50)" "linux|Linux|"
eq "osid 51 text" "$(dos 51)" "linux|Chromium OS|"
eq "osid 99 text" "$(dos 99)" "other|Other OS|"

# new ids resolve from the family alone, with no handleError.
eq "12 windows" "$(dos 12 windows)" "winmodern|Windows (osid 12)|"
eq "13 linux"   "$(dos 13 linux)"   "linux|Linux (osid 13)|"
eq "14 macos"   "$(dos 14 macos)"   "mac|macOS (osid 14)|"
eq "15 other"   "$(dos 15 other)"   "other|Other OS (osid 15)|"

# the server's family wins over the built-in fallback.
eq "9 linux"   "$(dos 9 linux | cut -d'|' -f1)"   linux
eq "50 windows" "$(dos 50 windows | cut -d'|' -f1)" winmodern
eq "99 macos"  "$(dos 99 macos | cut -d'|' -f1)"  mac

# errors.
eq "12, no family aborts"        "$(dos 12)"        ABORT
eq "12, empty family aborts"     "$(dos 12 "")"     ABORT
eq "12 bogus aborts"             "$(dos 12 bogus)"  ABORT
eq "9 bogus aborts"              "$(dos 9 bogus)"   ABORT
eq "no osid aborts"              "$(dos "")"        ABORT

# ---------------------------------------------------------------------------
# Case three: callers, and no osid comparison left outside determineOS().
# ---------------------------------------------------------------------------
grep -qF 'determineOS "$osid" "$osfamily"' "$BIN/fog.checkin"
eq "fog.checkin passes the family" $? 0
grep -qF 'determineOS "$osid" "$osfamily"' "$BIN/fog.debug"
eq "fog.debug passes the family" $? 0
# Capone sends the family as the eighth field of each image line.
eq "fog.capone read lines name osfamily eighth" \
    "$(grep -cE '^\s*read img osid imgType imgPartitionType imgFormat storage storageip osfamily <<< ' "$BIN/fog.capone")" 2
eq "fog.capone passes the family to determineOS" "$(grep -cF 'determineOS "$osid" "$osfamily"' "$BIN/fog.capone")" 2
eq "fog.capone has no bare determineOS" "$(grep -cE 'determineOS "\$osid"\s*$' "$BIN/fog.capone")" 0
# Run the awk and read text from fog.capone itself, not a copy.
CAPONE="$BIN/fog.capone"
capone_pipe() { # capone_pipe <n> <decoded line>: the nth awk/read pair, prints the eight variables
    (
        linedecode="$2"
        awkline="$(grep '^\s*awk_returned_vars=' "$CAPONE" | awk -v n="$1" 'NR == n')"
        readline="$(grep '^\s*read img osid' "$CAPONE" | awk -v n="$1" 'NR == n')"
        [[ -n $awkline && -n $readline ]] || { echo "NOEXTRACT"; exit 1; }
        eval "$awkline"
        eval "$readline"
        echo "$img|$osid|$imgType|$imgPartitionType|$imgFormat|$storage|$storageip|$osfamily"
    )
}
# Both the listing loop and the selection loop carry their own awk and read.
eq "fog.capone awk lines carrying \$8" "$(grep -cE '^\s*awk_returned_vars=.*\\\$8' "$CAPONE")" 2
for n in 1 2; do
    awkno="$(grep -n '^\s*awk_returned_vars=' "$CAPONE" | awk -v n="$n" 'NR == n' | cut -d: -f1)"
    if [[ -z $awkno ]]; then fail "extract awk_returned_vars pair $n from fog.capone"; continue; fi
    eq "capone line with eight fields (pair $n, fog.capone:$awkno)" \
        "$(capone_pipe "$n" 'win11|10|n|1|2|10.0.0.1:/images|10.0.0.1|windows')" \
        'win11|10|n|1|2|10.0.0.1:/images|10.0.0.1|windows'
    eq "capone line with seven fields (pair $n, fog.capone:$awkno)" \
        "$(capone_pipe "$n" 'win11|10|n|1|2|10.0.0.1:/images|10.0.0.1')" \
        'win11|10|n|1|2|10.0.0.1:/images|10.0.0.1|'
done
# The handoff to fog -> fog.download -> fog.checkin carries the chosen family.
grep -qxF 'export osfamily' "$BIN/fog.capone"
eq "fog.capone exports osfamily" $? 0
exp="$(grep -nxF 'export osfamily' "$BIN/fog.capone" | cut -d: -f1)"
run="$(grep -nE '^\s*(exec )?fog( |$)|/bin/fog( |$)' "$BIN/fog.capone" | tail -1 | cut -d: -f1)"
if [[ -n $exp && -n $run && $exp -lt $run ]]; then pass; else fail "fog.capone exports osfamily before it runs fog" "export line '$exp', fog line '$run'"; fi

# No osid comparison outside determineOS().
left=0
for f in "$REPO_LIB/funcs.sh" "$REPO_LIB/partition-funcs.sh" "$BIN"/fog.*; do
    n="$(awk '/^determineOS\(\) \{/ {skip=1} !skip {print} skip && /^\}/ {skip=0}' "$f" \
        | grep -cE 'case \$osid|\[\[ \$osid (==|!=|-eq)')"
    left=$((left + n))
done
eq "no osid comparison outside determineOS()" "$left" 0

echo "os-class: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
