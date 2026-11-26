#!/bin/bash
#
# Assertion harness: FOS's udpcast can receive a multicast image over IPv6.
#
#   tests/checks/udpcast-ipv6.sh
#
# Why this exists. Buildroot's udpcast 20250223 is IPv4 only. FOS carries three
# patches that add IPv6 dual stack, and the build has to apply them and run
# autoreconf, because patch 0004 changes configure.ac. Without autoreconf the
# build succeeds and silently stays IPv4 only. The rendezvous address also has
# to reach udp-receiver bare: udpcast rejects "[fd00::1]".
#
# Three assertions:
#   (a) the three patches exist and udpcast.mk sets UDPCAST_AUTORECONF = YES
#   (b) a built udp-receiver carries the IPv6 text. Skipped when no build exists.
#   (c) the bracket strip in writeImage(), taken from funcs.sh itself, maps
#       [fd00::1] to fd00::1 and leaves fd00::1 and 10.0.0.1 unchanged
#
# Overrides, used to make each assertion fail against a changed copy:
#   UDPCAST_PKG=<dir>      the Buildroot/package/udpcast directory
#   FUNCS=<path>           another funcs.sh
#   UDP_RECEIVER=<path>    a built udp-receiver (default: the fssourcex64 output)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
PKG="${UDPCAST_PKG:-$ROOT/Buildroot/package/udpcast}"
FUNCS="${FUNCS:-$ROOT/Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib/funcs.sh}"
RECEIVER="${UDP_RECEIVER:-$ROOT/fssourcex64/output/target/usr/sbin/udp-receiver}"

fails=0

# (a) patches and autoreconf
for n in 0002 0003 0004; do
    if compgen -G "$PKG/$n-*.patch" >/dev/null; then
        echo "  checked patch $n present"
    else
        echo "FAIL [udpcast] patch $n is missing from $PKG"
        fails=$((fails + 1))
    fi
done
if grep -qx 'UDPCAST_AUTORECONF = YES' "$PKG/udpcast.mk" 2>/dev/null; then
    echo "  checked udpcast.mk: UDPCAST_AUTORECONF = YES"
else
    echo "FAIL [udpcast.mk] UDPCAST_AUTORECONF = YES is missing, so the build stays IPv4 only"
    fails=$((fails + 1))
fi

# (b) the built receiver
if [[ -f $RECEIVER ]]; then
    if grep -aq 'No suitable IPv6 network interface found' "$RECEIVER"; then
        echo "  checked $RECEIVER: IPv6 text present"
    else
        echo "FAIL [udp-receiver] no IPv6 support in $RECEIVER"
        fails=$((fails + 1))
    fi
else
    echo "  SKIP built udp-receiver: none at $RECEIVER (set UDP_RECEIVER=<path>)"
fi

# (c) the bracket strip, run from funcs.sh itself
line="$(grep -F 'rdvaddress="${rdvaddress:1:-1}"' "$FUNCS" | head -n 1)"
if [[ -z $line ]]; then
    echo "FAIL [funcs.sh] no bracket strip of rdvaddress found"
    fails=$((fails + 1))
else
    while read -r in want; do
        rdvaddress="$in"
        eval "$line"
        if [[ $rdvaddress == "$want" ]]; then
            echo "  checked rdvaddress $in -> $rdvaddress"
        else
            echo "FAIL [funcs.sh] rdvaddress $in became '$rdvaddress', want '$want'"
            fails=$((fails + 1))
        fi
    done <<'EOF'
[fd00::1] fd00::1
fd00::1 fd00::1
10.0.0.1 10.0.0.1
EOF
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: udpcast IPv6 patches, autoreconf, receiver text and bracket strip"
    exit 0
fi
echo "FAILED: $fails udpcast IPv6 check(s)"
exit 1
