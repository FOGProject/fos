#!/bin/bash
#
# Imaging performance test (fos#55). A deploy moves an image through three
# stages -- the network (NFS read from the storage node), the CPU (zstd or
# pigz decompression) and the target disk -- and runs no faster than the
# slowest one. These functions time each stage on its own so the slowest can
# be named. bin/fog.perftest runs them; tests/checks/perftest.sh exercises
# them off-target.
#
# Every rate is reported in UNCOMPRESSED megabytes per second, the unit
# partclone's own GB/min display uses. The network and CPU stages move
# compressed bytes, so they are scaled by the sample's compression ratio;
# without that, a 2:1 image would make the network look half as fast as it
# is next to the disk.

# Megabytes (10^6 bytes) per second from a byte count and a duration in
# nanoseconds. Integer only: bash has no floating point, and a whole MB/s is
# all the comparison needs. A zero duration yields 0 rather than dividing by
# zero.
perfRate() {
    local bytes="$1" ns="$2"
    [[ -z $bytes || -z $ns || $ns -le 0 ]] && { echo 0; return; }
    echo $(( bytes * 1000 / ns ))
}

# GB/min from MB/s, to one decimal place, for the line people compare with
# partclone's display.
perfGBmin() {
    local mbps="$1"
    local tenths=$(( mbps * 60 / 100 ))
    echo "$(( tenths / 10 )).$(( tenths % 10 ))"
}

# The NFS source of the stored images, from the storage= a non-imaging task
# receives. The server sends such a task <ip>:/<node path>/dev/, the capture
# share; the stored images are its parent. Anything not ending in dev/ is
# returned as it is.
perfImageRoot() {
    local s="${1%/}"
    [[ $s == */dev ]] && s="${s%/dev}"
    echo "$s/"
}

# The largest captured image file under the mounted storage root, or nothing.
# Captured partitions are d<disk>p<part>.img (pigz, one file) or
# d<disk>p<part>.img.NNN (zstd, split into 200M pieces). Captures still in
# progress sit one level deeper, at dev/<mac>/, which the glob's depth never
# reaches: a half-written file says nothing about the images a deploy reads.
perfPickSample() {
    local root="$1" f size best="" bestsize=0
    # A glob, not find: the init carries busybox find, which has no -printf.
    for f in "$root"/*/d*p*.img "$root"/*/d*p*.img.[0-9][0-9][0-9]; do
        [[ -f $f ]] || continue
        size=$(stat -c %s "$f" 2>/dev/null)
        [[ -n $size && $size -gt $bestsize ]] && { best=$f; bestsize=$size; }
    done
    echo "$best"
}

# zstd, gzip or unknown, from the first four bytes. pigz writes ordinary gzip.
perfFormat() {
    local magic
    magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    case $magic in
        28b52ffd) echo zstd ;;
        1f8b*) echo gzip ;;
        *) echo unknown ;;
    esac
}

# The decompressor a deploy uses for a given format, matching writeImage():
# zstdmt -dc for zstd images, pigz -dc for gzip ones.
perfDecompressor() {
    case $1 in
        zstd) echo "zstdmt -dc" ;;
        gzip) echo "pigz -dc" ;;
    esac
}

# Reads up to <mib> MiB from <src> into /dev/null and sets PERF_BYTES and
# PERF_NS. <direct> = 1 adds iflag=direct, which bypasses the page cache so a
# disk read measures the disk and not RAM. Returns dd's status.
perfReadTest() {
    local src="$1" mib="$2" direct="$3" flag="" start end out rc
    [[ $direct == 1 ]] && flag="iflag=direct"
    start=$(date +%s%N)
    out=$(dd if="$src" of=/dev/null bs=1M count="$mib" $flag 2>&1)
    rc=$?
    end=$(date +%s%N)
    PERF_NS=$(( end - start ))
    # dd's summary line starts with the byte count it actually moved, which is
    # less than <mib> MiB when the source is shorter.
    PERF_BYTES=$(echo "$out" | awk '/bytes/ {print $1; exit}')
    [[ -z $PERF_BYTES ]] && PERF_BYTES=0
    return $rc
}

# Decompresses <sample> (a compressed fragment already in RAM) with the
# deploy's own decompressor and sets PERF_IN, PERF_OUT and PERF_NS. The
# fragment ends mid-stream, so the decompressor's exit status is expected to
# be non-zero and is ignored; what it produced before the cut is what is
# measured.
perfDecompressTest() {
    local sample="$1" fmt="$2" cmd start end
    cmd=$(perfDecompressor "$fmt")
    PERF_IN=$(stat -c %s "$sample" 2>/dev/null)
    [[ -z $cmd || -z $PERF_IN ]] && { PERF_OUT=0; PERF_NS=0; return 1; }
    start=$(date +%s%N)
    PERF_OUT=$($cmd < "$sample" 2>/dev/null | wc -c)
    end=$(date +%s%N)
    PERF_NS=$(( end - start ))
    return 0
}

# Uncompressed output bytes per compressed input byte, times 100, so a 2.5:1
# image gives 250. 100 (no scaling) when either count is missing.
perfRatio100() {
    local in="$1" out="$2"
    [[ -z $in || -z $out || $in -le 0 || $out -le 0 ]] && { echo 100; return; }
    echo $(( out * 100 / in ))
}

# A compressed-byte rate scaled to the uncompressed bytes it unpacks to.
perfScale() {
    echo $(( $1 * $2 / 100 ))
}

# Names the slowest of the stages that were measured. Arguments are
# uncompressed MB/s for disk, network and cpu; an empty or 0 value means the
# stage was not measured and is left out.
perfBottleneck() {
    local -a names=(disk network cpu)
    local -a rates=("$1" "$2" "$3")
    local i best="" bestrate=""
    for i in 0 1 2; do
        [[ -z ${rates[$i]} || ${rates[$i]} -le 0 ]] && continue
        if [[ -z $bestrate || ${rates[$i]} -lt $bestrate ]]; then
            best=${names[$i]}
            bestrate=${rates[$i]}
        fi
    done
    echo "$best"
}
