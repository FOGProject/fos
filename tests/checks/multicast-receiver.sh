#!/bin/bash
#
# Assertion harness for the multicast receiver's start timeout (fos#48).
#
#   tests/checks/multicast-receiver.sh
#
# Why this exists. writeImage() ran udp-receiver with no --start-timeout, so
# a host that booted after its udp-sender had started, or had given up
# waiting for it, sat at "waiting" forever. The FOG server already sends
# mcastMaxWait=<minutes> on the kernel command line; FOS ignored it.
#
# The receiver is given max(mcastMaxWait*60, 600) + 120 seconds. The server's
# sender waits mcastMaxWait*60 s for the first partition stream and
# max(600, mcastMaxWait*60) s for each later one, so a shorter receiver
# timeout would abandon a session that is still healthy. udp-receiver applies
# the timeout only before the first data packet, so it never interrupts a
# running transfer.
#
# When the timeout fires the receiver ends the stream with no bytes. In the
# stream-identity path that used to surface as "stream mismatch: expected X
# but the server is sending ''", which names the wrong problem; it now says
# no sender answered. ADR-0003: the task ends, it does not continue.
#
# The real writeImage() and checkStreamIdentity() are lifted from the shipped
# file and run in a sandbox. udp-receiver is a PATH-shadowed stub that
# records its argv, so what is asserted is the command line FOS builds.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCS="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib/funcs.sh"

fails=0
checked=0

ck() {
    checked=$((checked + 1))
    if [[ $2 != 1 ]]; then
        echo "FAIL $1"
        fails=$((fails + 1))
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The real functions, with the hardcoded /tmp paths moved into the sandbox.
for fn in mcStartTimeout checkStreamIdentity writeImage; do
    awk "/^$fn\\(\\) *\\{/,/^\\}/" "$FUNCS"
done | sed "s#/tmp/#$tmp/#g" > "$tmp/fns.sh"
grep -q 'start-timeout' "$tmp/fns.sh"
ck "the functions were extracted from the shipped file" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Records its argv, then ends having sent nothing -- which is exactly what a
# receiver that hit --start-timeout does.
cat > "$tmp/bin/udp-receiver" <<STUB
#!/bin/bash
echo "\$*" > "$tmp/argv"
exit 1
STUB
printf '#!/bin/bash\ncat\n' > "$tmp/bin/zstdmt"
# Like the real one, fails on an empty input.
printf '#!/bin/bash\n[[ -n $(cat) ]]\n' > "$tmp/bin/partclone.restore"
chmod +x "$tmp/bin/"*

# $1 = mcastMaxWait ("-" for unset), $2 = mcstreamidcap
# Leaves the argv in $tmp/argv and the handleError text in $tmp/msg.
run_case() {
    rm -f "$tmp/argv" "$tmp/msg" "$tmp/pigz1" "$tmp/mcraw"
    (
        PATH="$tmp/bin:$PATH"
        handleError() { printf '%s\n' "$1" > "$tmp/msg"; exit 42; }
        mcStreamIdSupported() { :; }
        port=9000 storageip=10.0.0.1 imgFormat=5 mcstreamidcap="$2"
        [[ $1 != - ]] && mcastMaxWait="$1"
        . "$tmp/fns.sh"
        writeImage 'd1p1.img' /dev/null yes
    ) >/dev/null 2>&1
    # The receiver runs in the background; give it a moment to record.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -s $tmp/argv ]] && break
        sleep 0.1
    done
}

argv() { cat "$tmp/argv" 2>/dev/null; }

for path in yes no; do
    label="stream-identity path"
    [[ $path == no ]] && label="legacy path"

    run_case 10 "$path"
    ck "$label: mcastMaxWait=10 passes --start-timeout 720" \
        "$([[ $(argv) == *"--start-timeout 720"* ]] && echo 1 || echo 0)"

    run_case 30 "$path"
    ck "$label: mcastMaxWait=30 passes --start-timeout 1920" \
        "$([[ $(argv) == *"--start-timeout 1920"* ]] && echo 1 || echo 0)"

    # Below ten minutes the later-stream wait of 600 s is the longer one.
    run_case 5 "$path"
    ck "$label: mcastMaxWait=5 is floored at 600 s plus slack (720)" \
        "$([[ $(argv) == *"--start-timeout 720"* ]] && echo 1 || echo 0)"

    # A leading zero must be decimal, not octal.
    run_case 010 "$path"
    ck "$label: mcastMaxWait=010 is read as decimal (720)" \
        "$([[ $(argv) == *"--start-timeout 720"* ]] && echo 1 || echo 0)"

    run_case - "$path"
    ck "$label: no mcastMaxWait passes no --start-timeout" \
        "$([[ -s $tmp/argv && $(argv) != *start-timeout* ]] && echo 1 || echo 0)"

    for bad in abc 0 -5 1.5 ''; do
        run_case "$bad" "$path"
        ck "$label: mcastMaxWait='$bad' passes no --start-timeout" \
            "$([[ -s $tmp/argv && $(argv) != *start-timeout* ]] && echo 1 || echo 0)"
    done

    # The rest of the command line is untouched.
    run_case 10 "$path"
    ck "$label: the portbase and rendezvous address are still passed" \
        "$([[ $(argv) == *"--portbase 9000"* && $(argv) == *"--mcast-rdv-address 10.0.0.1"* ]] && echo 1 || echo 0)"
done

# --- an empty receiver output ------------------------------------------

run_case 10 yes
ck "an empty stream ends the task through handleError" \
    "$([[ -s $tmp/msg ]] && echo 1 || echo 0)"
ck "the message says no sender answered, naming the port and the timeout" \
    "$([[ $(cat "$tmp/msg" 2>/dev/null) == *"No multicast sender answered on port 9000 within 720 seconds"* ]] && echo 1 || echo 0)"
ck "the message is not reported as a stream mismatch" \
    "$([[ $(cat "$tmp/msg" 2>/dev/null) != *mismatch* ]] && echo 1 || echo 0)"

run_case - yes
ck "an empty stream without a timeout still says no sender answered" \
    "$([[ $(cat "$tmp/msg" 2>/dev/null) == *"No multicast sender answered on port 9000."* ]] && echo 1 || echo 0)"

# A real mismatch must still be reported as one.
printf 'FOGMC1 %-120s\n' 'd1p3.img' > "$tmp/stream"
msg=$(
    handleError() { printf '%s\n' "$1"; exit 42; }
    port=9000
    . "$tmp/fns.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p2.img' 720
)
ck "a wrong header is still a stream mismatch" \
    "$([[ $msg == *mismatch* ]] && echo 1 || echo 0)"

# Legacy path: the receiver ending with no data starves partclone, whose
# failure is already fatal.
run_case 10 no
ck "legacy path: a receiver that sends nothing still ends the task" \
    "$([[ -s $tmp/msg ]] && echo 1 || echo 0)"

if [[ $fails -gt 0 ]]; then
    echo "multicast-receiver: $fails of $checked checks failed"
    exit 1
fi
echo "multicast-receiver: $checked checks passed"
exit 0
