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

# --- the record version owns the width --------------------------------

# Read both out of the shipped function. Everything below builds its
# fixtures from these, so a fixture cannot agree with a stale belief about
# the format -- which is what the old restated `printf 'FOGMC1 %-120s\n'`
# did, and why a server-side width change left this suite green (#179).
hdr_magic=$(sed -n 's/^[[:space:]]*local mcHeaderMagic="\([^"]*\)".*/\1/p' "$tmp/fn.sh" | head -1)
hdr_bytes=$(sed -n 's/^[[:space:]]*local mcHeaderBytes=\([0-9][0-9]*\).*/\1/p' "$tmp/fn.sh" | head -1)

ck "the record magic is named in one place" "$([[ -n $hdr_magic ]] && echo 1 || echo 0)"
ck "the record width is named in one place" "$([[ -n $hdr_bytes ]] && echo 1 || echo 0)"

# The read must use that name. A literal count here would be a second copy
# of the width inside the very function that owns it.
grep -q 'dd bs=1 count=\$mcHeaderBytes' "$tmp/fn.sh"
ck "the header read counts \$mcHeaderBytes, not a literal" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# THE CONTRACT. The width is a property of the record version, because
# nothing on the wire carries it. Changing one without the other lets a
# server mis-frame an old client silently. If you are here because this
# failed: bump the magic as well, on both sides, and old clients will
# refuse by name instead.
ck "FOGMC1 records are 128 bytes -- change the width, change the magic" \
    "$([[ $hdr_magic == FOGMC1 && $hdr_bytes -eq 128 ]] && echo 1 || echo 0)"

# 7 bytes of "FOGMC1 " and one newline wrap the padded name.
hdr_pad=$((hdr_bytes - ${#hdr_magic} - 2))
hdr_fmt="$hdr_magic %-${hdr_pad}s\n"

# $1 = name the server put in the header, $2 = what the client asks for,
# $3 = expected outcome (accept|refuse)
identity_case() {
    local sent="$1" wanted="$2" expect="$3" rc=0
    printf "$hdr_fmt" "$sent" > "$tmp/stream"
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
printf "$hdr_fmt" 'd1p1.img' > "$tmp/stream"
printf 'PAYLOADSTARTSHERE' >> "$tmp/stream"
rest=$(
    handleError() { exit 42; }
    . "$tmp/fn.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p1.img' >/dev/null 2>&1
    cat <&9
)
ck "the header consumes exactly $hdr_bytes bytes" "$([[ $rest == PAYLOADSTARTSHERE ]] && echo 1 || echo 0)"

# --- a record version this client cannot read --------------------------

# This is what makes bumping the magic a SAFE way to change the width: an
# old client meets the new version, refuses, and names it. Without this the
# only alternative to the pair above is a silent mis-frame.
hdr_next="FOGMC$(( ${hdr_magic#FOGMC} + 1 ))"
printf "$hdr_next %-${hdr_pad}s\n" 'd1p1.img' > "$tmp/stream"
printf 'PAYLOAD' >> "$tmp/stream"
rc=0
msg=$(
    handleError() { printf '%s\n' "$1"; exit 42; }
    . "$tmp/fn.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p1.img'
) || rc=$?
ck "a $hdr_next record is refused by a $hdr_magic client" "$([[ $rc -eq 42 ]] && echo 1 || echo 0)"
ck "and the refusal names the version it met" "$([[ $msg == *$hdr_next* ]] && echo 1 || echo 0)"

# An unheadered stream must NOT be reported as a version skew -- it starts
# with image bytes, and echoing those would print binary to the console.
printf 'partclone-image and then some binary rubbish' > "$tmp/stream"
msg=$(
    handleError() { printf '%s\n' "$1"; exit 42; }
    . "$tmp/fn.sh"
    exec 9<"$tmp/stream"
    checkStreamIdentity 'd1p1.img'
) || true
ck "an unheadered stream is not reported as a version skew" \
    "$([[ $msg != *"carries"* ]] && echo 1 || echo 0)"

# --- the server side, when a checkout is reachable ---------------------

# fogproject writes the header this file reads. Compare the two directly
# when both trees are on the machine. The pair check above is what CI
# enforces -- a width change that keeps the magic fails on whichever side
# changed -- so this is the extra confirmation, not the gate. It SAYS when
# it did not run: a cross-repo check that skips in silence is the gap #179
# closes.
fogtree=""
for cand in "${FOGPROJECT_TREE:-}" "$HERE/../../../fogproject" "$HOME/fogproject"; do
    if [[ -n $cand && -r "$cand/packages/web/src/Service/MulticastTask.php" ]]; then
        fogtree="$cand"
        break
    fi
done
if [[ -n $fogtree ]]; then
    mctask="$fogtree/packages/web/src/Service/MulticastTask.php"
    srv_fmt=$(sed -n "s/^[[:space:]]*const STREAM_HEADER_FORMAT = '\(.*\)';$/\1/p" "$mctask" | head -1)
    srv_bytes=$(sed -n 's/^[[:space:]]*const STREAM_HEADER_BYTES = \([0-9][0-9]*\);$/\1/p' "$mctask" | head -1)
    ck "the server's header constants were read from $fogtree" \
        "$([[ -n $srv_fmt && -n $srv_bytes ]] && echo 1 || echo 0)"
    ck "the server writes $hdr_magic records" \
        "$([[ $srv_fmt == "$hdr_magic "* ]] && echo 1 || echo 0)"
    ck "the server's width matches the width read here" \
        "$([[ $srv_bytes -eq $hdr_bytes ]] && echo 1 || echo 0)"
    # And the server's own format has to expand to the width it declares,
    # or the constant is right and the bytes on the wire are not.
    srv_rendered=$(printf "$srv_fmt" 'd1p1.img' | wc -c)
    ck "the server's format expands to $srv_bytes bytes" \
        "$([[ $srv_rendered -eq $srv_bytes ]] && echo 1 || echo 0)"
else
    echo "note: no fogproject checkout found; the server-side width was not compared"
    echo "      (set FOGPROJECT_TREE to compare)"
fi

if [[ $fails -gt 0 ]]; then
    echo "multicast-stream-identity: $fails of $checked checks failed"
    exit 1
fi
echo "multicast-stream-identity: $checked checks passed"
exit 0
