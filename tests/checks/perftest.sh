#!/bin/bash
#
# Assertion harness for the Performance Test task (fos#55).
#
#   tests/checks/perftest.sh
#
# fog.perftest times the disk, the network and the CPU separately and names
# the slowest. What can go wrong without real hardware is the arithmetic and
# the choices around it: the unit conversion, the image it samples, the share
# it mounts, the decompressor it times, and which stage it blames. Those live
# in perftest-funcs.sh, which this sources as shipped.
#
# The decompression cases use the host's real zstdmt and pigz on a really
# truncated stream, because a deploy's sample is cut mid-stream and the
# decompressor's behavior there is the thing being relied on.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay"
LIB="$OVERLAY/usr/share/fog/lib/perftest-funcs.sh"

fails=0
checked=0

ck() {
    checked=$((checked + 1))
    if [[ $2 != 1 ]]; then
        echo "FAIL $1"
        fails=$((fails + 1))
    fi
}
eq() { [[ $1 == "$2" ]] && echo 1 || echo 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

. "$LIB"

# 1. Rates: 10^9 bytes in one second is 1000 MB/s; no duration is 0, not a
#    division error.
ck "1a perfRate 1e9 B / 1 s = 1000" "$(eq "$(perfRate 1000000000 1000000000)" 1000)"
ck "1b perfRate with 0 ns = 0" "$(eq "$(perfRate 5000 0)" 0)"
ck "1c perfGBmin 1000 MB/s = 60.0" "$(eq "$(perfGBmin 1000)" 60.0)"
ck "1d perfGBmin 125 MB/s = 7.5" "$(eq "$(perfGBmin 125)" 7.5)"

# 2. The share: a non-imaging task is sent <node>/dev/, and the stored images
#    are its parent. A path without dev/ is left alone.
ck "2a dev/ share maps to its parent" "$(eq "$(perfImageRoot 10.0.0.1:/images/dev/)" 10.0.0.1:/images/)"
ck "2b no trailing slash too" "$(eq "$(perfImageRoot 10.0.0.1:/opt/fog/images/dev)" 10.0.0.1:/opt/fog/images/)"
ck "2c images root unchanged" "$(eq "$(perfImageRoot 10.0.0.1:/images/)" 10.0.0.1:/images/)"
ck "2d a dir merely ending in dev is not stripped" "$(eq "$(perfImageRoot 10.0.0.1:/srv/imagesdev/)" 10.0.0.1:/srv/imagesdev/)"

# 3. The sample: the largest stored image file, never one under dev/ (a
#    capture in progress), split zstd pieces included.
root="$tmp/images"
mkdir -p "$root/dev/001122334455" "$root/win10" "$root/win11"
head -c 300000 /dev/zero > "$root/dev/001122334455/d1p2.img.000"
head -c 1000 /dev/zero > "$root/win10/d1p2.img"
head -c 5000 /dev/zero > "$root/win11/d1p3.img.001"
head -c 9000 /dev/zero > "$root/win11/d1p3.mbr"
ck "3a largest stored image, dev/ skipped" "$(eq "$(perfPickSample "$root")" "$root/win11/d1p3.img.001")"
mkdir -p "$tmp/empty"
ck "3b no images gives nothing" "$(eq "$(perfPickSample "$tmp/empty")" "")"

# 4. Format from magic bytes, using real compressor output.
head -c 4000000 /dev/urandom | base64 > "$tmp/plain"
zstd -q -c "$tmp/plain" > "$tmp/s.zst"
pigz -c "$tmp/plain" > "$tmp/s.gz"
ck "4a zstd detected" "$(eq "$(perfFormat "$tmp/s.zst")" zstd)"
ck "4b pigz/gzip detected" "$(eq "$(perfFormat "$tmp/s.gz")" gzip)"
ck "4c anything else is unknown" "$(eq "$(perfFormat "$tmp/plain")" unknown)"
ck "4d zstd uses the deploy's zstdmt -dc" "$(eq "$(perfDecompressor zstd)" "zstdmt -dc")"
ck "4e gzip uses the deploy's pigz -dc" "$(eq "$(perfDecompressor gzip)" "pigz -dc")"

# 5. Decompression of a sample cut mid-stream still yields its output, and
#    more output than input for compressible data.
for f in zst gz; do
    head -c 1000000 "$tmp/s.$f" > "$tmp/cut.$f"
    fmt=$([[ $f == zst ]] && echo zstd || echo gzip)
    perfDecompressTest "$tmp/cut.$f" "$fmt"
    ck "5a $fmt cut stream: input counted" "$(eq "$PERF_IN" 1000000)"
    ck "5b $fmt cut stream: output > input" "$([[ $PERF_OUT -gt $PERF_IN ]] && echo 1 || echo 0)"
    ck "5c $fmt cut stream: timed" "$([[ $PERF_NS -gt 0 ]] && echo 1 || echo 0)"
done
perfDecompressTest "$tmp/plain" unknown
ck "5d unknown format is refused" "$(eq "$?" 1)"

# 6. Ratio and scaling: the network rate moves compressed bytes and is scaled
#    to uncompressed, the unit the disk is measured in.
ck "6a ratio 2.5:1 is 250" "$(eq "$(perfRatio100 1000 2500)" 250)"
ck "6b missing counts give 100" "$(eq "$(perfRatio100 0 2500)" 100)"
ck "6c 100 MB/s compressed at 2.5:1 is 250" "$(eq "$(perfScale 100 250)" 250)"

# 7. The bottleneck is the slowest MEASURED stage.
ck "7a network slowest" "$(eq "$(perfBottleneck 500 100 300)" network)"
ck "7b cpu slowest" "$(eq "$(perfBottleneck 500 400 300)" cpu)"
ck "7c unmeasured stages are ignored" "$(eq "$(perfBottleneck 500 0 "")" disk)"
ck "7d nothing measured names nothing" "$(eq "$(perfBottleneck 0 0 0)" "")"

# 8. A read shorter than asked reports the bytes actually moved.
head -c 3145728 /dev/zero > "$tmp/three"
perfReadTest "$tmp/three" 8 0
ck "8a short source: bytes actually read" "$(eq "$PERF_BYTES" 3145728)"
ck "8b short source: timed" "$([[ $PERF_NS -gt 0 ]] && echo 1 || echo 0)"

# 9. The task itself: dispatched by bin/fog, executable, mounts read-only,
#    reports before it completes the task.
grep -qE '^\s+perftest\)' "$OVERLAY/bin/fog" && grep -q 'fog.perftest' "$OVERLAY/bin/fog"
ck "9a bin/fog dispatches mode=perftest" "$(eq $? 0)"
ck "9b fog.perftest is executable" "$([[ -x $OVERLAY/bin/fog.perftest ]] && echo 1 || echo 0)"
grep -qE 'mount -t nfs -o ro,' "$OVERLAY/bin/fog.perftest"
ck "9c storage is mounted read-only" "$(eq $? 0)"
report=$(grep -n 'service/perftest.php' "$OVERLAY/bin/fog.perftest" | cut -d: -f1)
complete=$(grep -n 'fog.nonimgcomplete' "$OVERLAY/bin/fog.perftest" | cut -d: -f1)
ck "9d result is reported before the task completes" "$([[ -n $report && -n $complete && $report -lt $complete ]] && echo 1 || echo 0)"

echo
echo "passed: $((checked - fails))   failed: $fails"
[[ $fails -eq 0 ]]
