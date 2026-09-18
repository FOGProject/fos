#!/bin/bash
#
# Source-level gate on FOG's partclone patch -- the producer end of imaging
# progress.
#
#   tests/checks/partclone-status-patch.sh   # non-zero on failure
#
# Buildroot/package/partclone/partclone-*.patch adds fogLogStatusFile() to
# partclone's progress.c. That function is the only writer of /tmp/status.fog,
# which fog.statusreporter then forwards to service/progress.php
# (tests/checks/status-reporting.sh covers the forwarding half).
#
# Three properties are pinned here, because none of them is visible from a
# successful build or a successful deploy.
#
#   No exit() in the function. It used to call exit(0) when it could not open
#   the status file. That quits partclone with a SUCCESS status in the middle of
#   a restore: funcs.sh reads $exitcode after the partclone pipeline, sees 0,
#   and records a partially written partition as a completed deploy. /tmp in FOS
#   is a ramdisk, so a full one is enough to reach it. Progress reporting is
#   best effort and must never end the restore.
#
#   No sprintf() taking a converted string as its FORMAT argument. The function
#   used to write `sprintf(total_str, filesize_conv(...))`, which reads the
#   converted size as a format string -- a % in it would consume an argument
#   that was never passed.
#
#   Hunk headers that match their own bodies. The added code is `+` lines inside
#   a unified diff, so editing it by hand moves line counts that nothing else
#   recomputes. `patch` will often apply a wrong count anyway and silently drop
#   or duplicate lines; git apply refuses outright. Either way the failure lands
#   in the middle of a Buildroot build, far from the edit.
#
# This is a text check by design. The compile half is the build itself: the
# patch is applied by Buildroot, and progress.c does not compile if it is wrong.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGDIR="$HERE/../../Buildroot/package/partclone"

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1))
    fi
}

mapfile -t PATCHES < <(find "$PKGDIR" -maxdepth 1 -name 'partclone-*.patch' | sort)
[[ ${#PATCHES[@]} -gt 0 ]] || { echo "ERROR: no partclone patch found under $PKGDIR" >&2; exit 2; }

# The added lines of fogLogStatusFile(), with the diff's leading + removed.
fogFunction() {
    awk '
        /^\+void fogLogStatusFile/ { inside = 1 }
        inside { sub(/^\+/, ""); print }
        inside && /^}/ { exit }
    ' "$1"
}

for patch in "${PATCHES[@]}"; do
    name=$(basename "$patch")
    body=$(fogFunction "$patch")

    [[ -n $body ]] \
        && note "$name: adds fogLogStatusFile()" "" \
        || note "$name: adds fogLogStatusFile()" "function not found in the patch"

    # ------------------------------------------------------------ case 1
    grep -q '\bexit[[:space:]]*(' <<< "$body" \
        && note "$name: fogLogStatusFile() never exits" "an exit() would end the restore with that status" \
        || note "$name: fogLogStatusFile() never exits" ""

    # The open has to fail into a return, or the following code runs on a NULL
    # FILE *. Checked separately from case 1 so removing the exit without
    # replacing it cannot pass.
    awk '/fopen/ { f = 1 } f && /return;/ { found = 1 } END { exit !found }' <<< "$body" \
        && note "$name: a failed open returns" "" \
        || note "$name: a failed open returns" "no return after the fopen check"

    # ------------------------------------------------------------ case 2
    grep -q 'sprintf[[:space:]]*([^,]*,[[:space:]]*[A-Za-z_][A-Za-z_0-9]*[[:space:]]*(' <<< "$body" \
        && note "$name: no computed sprintf format" "a call's return value is being used as the format string" \
        || note "$name: no computed sprintf format" ""

    # ------------------------------------------------------------ case 3
    # Every @@ header's counts against the lines that follow it.
    mismatch=$(awk '
        function check() {
            if (!h) return
            if (oldc != oldn || newc != newn)
                printf "%s: says -%d,+%d, body has -%d,+%d\n", h, oldn, newn, oldc, newc
        }
        /^@@ / {
            check()
            h = $0
            oldn = 1; newn = 1
            if (match($2, /,/)) oldn = substr($2, RSTART + 1) + 0
            if (match($3, /,/)) newn = substr($3, RSTART + 1) + 0
            oldc = 0; newc = 0
            next
        }
        /^(diff --git|--- |\+\+\+ |index )/ { check(); h = ""; next }
        h && /^ /  { oldc++; newc++; next }
        h && /^-/  { oldc++; next }
        h && /^\+/ { newc++; next }
        h && /^\\/ { next }
        h          { check(); h = "" }
        END { check() }
    ' "$patch")
    [[ -z $mismatch ]] \
        && note "$name: hunk headers match their bodies" "" \
        || note "$name: hunk headers match their bodies" "${mismatch//$'\n'/; }"
done

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
