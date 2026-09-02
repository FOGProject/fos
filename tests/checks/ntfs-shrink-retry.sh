#!/bin/bash
#
# Assertion harness for the NTFS branch of shrinkPartition() in funcs.sh: what
# happens when the ntfsresize dry run fails with "No space left on device".
#
#   tests/checks/ntfs-shrink-retry.sh   # run all cases, exit non-zero on any failure
#
# ntfsresize relocates every cluster past the new end into the space before it.
# On a Windows 11 volume the file that records those relocations can run out of
# runlist room before the data runs out of clusters, and ntfsresize reports that
# as ENOSPC (ntfs-3g issue #142, fogproject issue #789) even though the target
# has hundreds of MB free. The fixed 500 MB floor from commit 916cd69 was not
# enough for the reporter's volume: 10832 MB in use, 5323 MB of relocations
# needed, and the dry run failed at 11318 MB. A bigger target means fewer
# relocations, so shrinkPartition now doubles the slack and retries until the
# dry run passes, capped at the volume's present size.
#
# What this harness locks:
#
#   1. An ENOSPC dry run is retried at a strictly larger size until one passes,
#      and the real resize (and the partition resize) use the size that passed.
#   2. Any other dry-run failure still aborts on the first try. Retrying past a
#      genuine error would only waste a consistency check per pass.
#   3. When no target below the current volume size fits, the partition is
#      recorded as fixed size and left alone. No abort, no resize, and
#      ntfsresize is never asked for a target at or past the volume size.
#   4. A dry run that passes first time takes the original target, so the
#      unaffected majority of captures sees no change.
#
# Mechanism mirrors tests/checks/sector-size.sh: source a sandbox copy of the
# library, PATH-shadow ntfsresize with a double that records every size it was
# asked for, and override the funcs.sh helpers shrinkPartition calls that touch
# hardware. handleError is overridden AFTER sourcing so an abort is observable.

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

# The reporter's volume: 64 GiB device, 10832 MB in use. The -i probe reports
# the minimum ntfsresize believes it can reach; the 500 MB / 5 % slack goes on
# top of that in shrinkPartition.
VOLUME_BYTES=67719131648
MIN_BYTES=10777000000

# ntfsresize double.
#   -fivP <part>       the size probe: current size and the minimum.
#   -fns <N>k <part>   dry run: passes iff N KiB >= $FAKE_FITS_BYTES, else fails
#                      with the reporter's exact ENOSPC lines -- or, when
#                      $FAKE_OTHER_ERROR is set, with an unrelated error.
#   -fs <N>k <part>    the real resize: always passes.
# Every call is appended to $SANDBOX/calls as "<mode> <bytes>".
cat > "$STUBBIN/ntfsresize" <<'STUB'
#!/bin/bash
mode="$1"
case "$mode" in
    -fivP)
        printf 'Current volume size: %s bytes (67720 MB)\n' "$VOLUME_BYTES"
        printf 'Space in use       : 10832 MB (16.0%%)\n'
        printf 'You might resize at %s bytes or 10777 MB (freeing 56943 MB).\n' "$MIN_BYTES"
        exit 0
        ;;
    -fns|-fs)
        kib="${2%k}"
        bytes=$(( kib * 1024 ))
        echo "$mode $bytes" >> "$SANDBOX/calls"
        [[ $mode == -fs ]] && exit 0
        if [[ -n $FAKE_OTHER_ERROR ]]; then
            echo "ERROR: Cluster accounting failed at 12345 (0x3039): missing cluster in \$Bitmap"
            exit 1
        fi
        if [[ $bytes -ge $FAKE_FITS_BYTES ]]; then
            echo "The read-only test run ended successfully."
            exit 0
        fi
        echo "Relocating needed data ..."
        echo "Failed to make room for attribute: No space left on device"
        echo "Could not add attribute extent: No space left on device"
        echo "ERROR(28): Could not update runlist for attribute 0x80 in inode 151601: No space left on device"
        exit 1
        ;;
esac
exit 1
STUB
chmod +x "$STUBBIN/ntfsresize"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ -n $2 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }

# run_shrink <fits_bytes> [other_error] -- drive shrinkPartition over /dev/sda3.
# Leaves the console output in $OUT, the ntfsresize call log in $CALLS, the
# bytes handed to resizePartition in $RESIZED and the fixed-size file in $FIXED.
run_shrink() {
    rm -f "$SANDBOX/calls" "$SANDBOX/resized"
    mkdir -p "$SANDBOX/images"
    : > "$SANDBOX/images/d1.fixed_size_partitions"
    : > "$SANDBOX/images/d1.original.fstypes"
    OUT="$(
        set +u
        export PATH="$STUBBIN:$PATH" SANDBOX="$SANDBOX"
        export VOLUME_BYTES="$VOLUME_BYTES" MIN_BYTES="$MIN_BYTES"
        export FAKE_FITS_BYTES="$1" FAKE_OTHER_ERROR="$2"
        . "$SANDBOX/funcs.sh"
        handleError() { echo "ABORT: $*"; exit 1; }
        debugPause() { :; }
        dots() { printf ' * %s...' "$1"; }
        fsTypeSetting() { fstype="ntfs"; }
        getDiskFromPartition() { disk="/dev/sda"; }
        getPartitionNumber() { part_number=3; }
        getPartBlockSize() { printf -v "$2" '%s' 512; }
        resizePartition() { echo "$2" > "$SANDBOX/resized"; }
        resetFlag() { :; }
        percent=5
        osid=9
        win7partcnt=0
        imagePath="$SANDBOX/images"
        shrinkPartition /dev/sda3 "$SANDBOX/images/d1.original.fstypes" ""
        echo "RETURNED"
    )"
    CALLS="$(cat "$SANDBOX/calls" 2>/dev/null)"
    RESIZED="$(cat "$SANDBOX/resized" 2>/dev/null)"
    FIXED="$(tr -d '\0' < "$SANDBOX/images/d1.fixed_size_partitions")"
}
dryruns()   { printf '%s\n' "$CALLS" | awk '$1 == "-fns" {print $2}'; }
realruns()  { printf '%s\n' "$CALLS" | awk '$1 == "-fs"  {print $2}'; }

# ---------------------------------------------------------------------------
# 1. The reporter's case: the first target is ~11.3 GB and nothing under 14 GB
#    fits. Each retry must ask for strictly more than the last, the loop must
#    stop at the first size that passes, and that size is what the real resize
#    and the partition are cut to.
FITS=$(( 14 * 1000 * 1000 * 1000 ))
run_shrink "$FITS"
n=$(dryruns | wc -l)
monotonic=1; prev=0
for b in $(dryruns); do [[ $b -gt $prev ]] || monotonic=0; prev=$b; done
last=$(dryruns | tail -1)
real=$(realruns)
if [[ $OUT != *ABORT* && $OUT == *RETURNED* && $n -gt 1 && $monotonic -eq 1 \
      && $last -ge $FITS && $(dryruns | tail -2 | head -1) -lt $FITS \
      && $real == "$last" && $RESIZED == "$last" ]]; then
    pass "ENOSPC dry run retried at growing sizes ($n tries, $(dryruns | tr '\n' ' ')) and resized at $real"
else
    fail "ENOSPC retry" "tries=$n monotonic=$monotonic last=$last real=$real resized=$RESIZED
calls: $(printf '%s' "$CALLS" | tr '\n' '|')
$OUT"
fi

# ---------------------------------------------------------------------------
# 2. A dry run that fails for any other reason aborts on the first try.
run_shrink "$FITS" yes
n=$(dryruns | wc -l)
if [[ $OUT == *"ABORT: Resize test failed"* && $n -eq 1 && -z $(realruns) ]]; then
    pass "non-ENOSPC dry-run failure aborts after one try"
else
    fail "non-ENOSPC abort" "tries=$n real=$(realruns | tr '\n' ' ')
$OUT"
fi

# ---------------------------------------------------------------------------
# 3. Nothing below the volume's present size fits: the partition is recorded
#    as fixed size and left alone, and ntfsresize is never asked for a target
#    at or past the volume size (that would be no shrink at all).
run_shrink $(( VOLUME_BYTES + 1 ))
biggest=$(dryruns | sort -n | tail -1)
if [[ $OUT != *ABORT* && $OUT == *RETURNED* && $FIXED == *:3* && -z $(realruns) \
      && -z $RESIZED && $biggest -lt $VOLUME_BYTES ]]; then
    pass "never fits: recorded fixed size after $(dryruns | wc -l) tries, largest ask $biggest < volume $VOLUME_BYTES"
else
    fail "never fits" "fixed='$FIXED' real='$(realruns | tr '\n' ' ')' resized='$RESIZED' biggest=$biggest
$OUT"
fi

# ---------------------------------------------------------------------------
# 4. Passes first time: one dry run at the original target (minimum plus the
#    5 % slack, which here exceeds the 500 MB floor), one real resize at it.
WANT_KIB=$(awk -v s="$MIN_BYTES" 'BEGIN{printf "%.0f\n", (s + 5/100*s)/1024}')
run_shrink 0
n=$(dryruns | wc -l)
first=$(dryruns | head -1)
if [[ $OUT != *ABORT* && $n -eq 1 && $first -eq $(( WANT_KIB * 1024 )) && $(realruns) == "$first" ]]; then
    pass "fits first time: one dry run and one resize at ${WANT_KIB}k"
else
    fail "fits first time" "tries=$n first=$first want=$(( WANT_KIB * 1024 )) real=$(realruns | tr '\n' ' ')
$OUT"
fi

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
