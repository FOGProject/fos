#!/bin/bash
#
# Assertion harness for the multicast stream identity check.
#
#   tests/checks/multicast-stream-identity.sh
#
# Why this exists. udpcast carries no metadata. The server chains one
# udp-sender per image file on a shared portbase, FOS opens one udp-receiver
# per file it expects, and the Nth receiver gets the Nth stream. Position is
# the only thing binding a stream to a partition.
#
# So a client that reboots mid-session -- or whose receiver opens after a
# sender has already stopped waiting for it -- lands one stream out of step,
# and every partition after that point is restored from the wrong image.
# partclone objects only when the target partition is SMALLER than the
# source; when it is larger the wrong filesystem is written and the deploy
# reports success. fogproject issue #1742 records a run where partition 3's
# image went onto partition 2 (caught, 105 MB target vs 135 MB source) after
# partition 2's had already gone onto partition 1 (not caught, 300 MB target).
#
# The server now prefixes every stream with a fixed 128-byte record naming
# the image file it carries, and checkStreamIdentity() refuses a stream that
# is not the one this partition asked for -- before the receiver's bytes
# reach partclone, so a refusal leaves the target untouched.
#
# Two halves are pinned here. The wiring is grepped, because the ordering of
# "open the receiver, read the header, only then start the restore" is what
# makes a refusal safe and there is nothing to execute that would show it.
# The naming rule is EXECUTED against the real function, because it is not
# uniform and the asymmetry is the whole point:
#
#   d1p2.img       flat partition        asked for by name -> verbatim
#   d1p1.img*      split chunks          asked for by glob -> stem
#   sys.img.*      ONE partition, N files                  -> stem
#   rec.img.000    ONE partition, one file each            -> verbatim
#
# Both sides reach the same string from their own layout, so neither has to
# re-derive the other's ordinal -- and any divergence is a refusal, never a
# misplaced filesystem.

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

# --- the wiring -------------------------------------------------------

grep -q 'exec 9</tmp/mcraw' "$FUNCS"
ck "the receiver's output is opened on fd 9 before the restore" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

grep -q 'checkStreamIdentity "\$file"' "$FUNCS"
ck "writeImage checks the stream against the file it was asked for" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# The header must be read, and refused, BEFORE anything is piped onward --
# a check after `cat <&9` starts would already have fed partclone.
if [[ $(grep -n 'checkStreamIdentity "\$file"' "$FUNCS" | head -1 | cut -d: -f1) -lt \
      $(grep -n 'cat <&9 >/tmp/pigz1' "$FUNCS" | head -1 | cut -d: -f1) ]]; then
    ck "the header is checked before any payload is forwarded" 1
else
    ck "the header is checked before any payload is forwarded" 0
fi

grep -q 'mcstreamidcap == yes' "$FUNCS"
ck "the header is only stripped when the server advertises it" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# A server that does not prepend a header must keep its old, unstripped
# path, or 128 bytes of payload go missing.
grep -q 'udp-receiver --nokbd --portbase \$port --ttl 32 --mcast-rdv-address \$rdvaddress 2>/dev/null >/tmp/pigz1 &' "$FUNCS"
ck "an unadvertised server still gets the direct receiver" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Same shape as the mclvm probe and fogproject GH-1266: an unreachable
# server must not read as "no header", which is a claim about the server's
# version drawn from a dead network.
grep -q 'if ! callServer "${web}service/getversion.php?caps=1"; then' "$FUNCS"
ck "the capability call is checked before its answer is read" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# --- the naming rule, executed ----------------------------------------

# The real function, lifted from the shipped file rather than restated.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^checkStreamIdentity\(\) \{/,/^\}/' "$FUNCS" > "$tmp/fn.sh"
grep -q 'FOGMC1' "$tmp/fn.sh"
ck "the function was extracted from the shipped file" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# $1 = name the server put in the header, $2 = what the client asks for,
# $3 = expected outcome (accept|refuse)
identity_case() {
    local sent="$1" wanted="$2" expect="$3" rc=0
    printf 'FOGMC1 %-120s\n' "$sent" > "$tmp/stream"
    printf 'PAYLOAD' >> "$tmp/stream"
    (
        handleError() { exit 42; }
        . "$tmp/fn.sh"
        exec 9<"$tmp/stream"
        checkStreamIdentity "$wanted"
    ) >/dev/null 2>&1 || rc=$?
    if [[ $expect == accept ]]; then
        ck "$sent accepted for $wanted" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
    else
        ck "$sent refused for $wanted" "$([[ $rc -eq 42 ]] && echo 1 || echo 0)"
    fi
}

identity_case 'd1p2.img'    'd1p2.img'                accept
identity_case 'd1p2.img'    '/net/dev/foo/d1p2.img'   accept
identity_case 'd1p1.img'    'd1p1.img*'               accept
identity_case 'sys.img'     'sys.img.*'               accept
identity_case 'rec.img.000' 'rec.img.000'             accept
# The desync from #1742: partition 3's stream offered to partition 2.
identity_case 'd1p3.img'    'd1p2.img'                refuse
identity_case 'rec.img.001' 'rec.img.000'             refuse
# A stem must not satisfy a request for one specific chunked partition of
# the legacy layout, or rec.img.000 and rec.img.001 become interchangeable.
identity_case 'rec.img'     'rec.img.000'             refuse

# An unheadered stream must be refused outright rather than treated as
# payload -- this is the new-client/old-server pairing.
printf 'partclone-image and then some binary rubbish' > "$tmp/stream"
rc=0
(
    handleError() { exit 42; }
    . "$tmp/fn.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p1.img'
) >/dev/null 2>&1 || rc=$?
ck "a stream with no header is refused" "$([[ $rc -eq 42 ]] && echo 1 || echo 0)"

# Exactly 128 bytes come off the front: one byte more or less and the
# payload handed to partclone is corrupt.
printf 'FOGMC1 %-120s\n' 'd1p1.img' > "$tmp/stream"
printf 'PAYLOADSTARTSHERE' >> "$tmp/stream"
rest=$(
    handleError() { exit 42; }
    . "$tmp/fn.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p1.img' >/dev/null 2>&1
    cat <&9
)
ck "the header consumes exactly 128 bytes" "$([[ $rest == PAYLOADSTARTSHERE ]] && echo 1 || echo 0)"

if [[ $fails -gt 0 ]]; then
    echo "multicast-stream-identity: $fails of $checked checks failed"
    exit 1
fi
echo "multicast-stream-identity: $checked checks passed"
exit 0
