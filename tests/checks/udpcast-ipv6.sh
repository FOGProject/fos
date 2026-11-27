#!/bin/bash
#
# Assertion harness: FOS's udpcast can receive a multicast image over IPv6.
#
#   tests/checks/udpcast-ipv6.sh
#
# Why this exists. Buildroot's udpcast 20250223 is IPv4 only. FOS builds udpcast
# from the FOGProject/udpcast release instead. That release carries the IPv6
# dual stack port and a generated configure. If the build goes back to the
# upstream tarball, or the old FOS patches return, it silently stays IPv4 only
# or fails to apply. The rendezvous address also has to reach udp-receiver
# bare: udpcast rejects "[fd00::1]".
#
# Three assertions:
#   (a) udpcast.mk fetches the FOGProject/udpcast release, udpcast.hash pins
#       that tarball, and FOS carries no udpcast patch of its own
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

# (a) the release source, its hash, and no leftover patches
if grep -q '^UDPCAST_SITE = .*github\.com/FOGProject/udpcast/releases/download' "$PKG/udpcast.mk" 2>/dev/null; then
    echo "  checked udpcast.mk: UDPCAST_SITE is the FOGProject/udpcast release"
else
    echo "FAIL [udpcast.mk] UDPCAST_SITE is not github.com/FOGProject/udpcast/releases/download, so the build stays IPv4 only"
    fails=$((fails + 1))
fi
version="$(sed -n 's/^UDPCAST_VERSION = //p' "$PKG/udpcast.mk" 2>/dev/null | head -n 1)"
if [[ -n $version ]] && grep -Eq "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+udpcast-${version}\.tar\.gz\$" "$PKG/udpcast.hash" 2>/dev/null; then
    echo "  checked udpcast.hash: sha256 line for udpcast-$version.tar.gz"
else
    echo "FAIL [udpcast.hash] no sha256 line for udpcast-${version:-<no UDPCAST_VERSION>}.tar.gz"
    fails=$((fails + 1))
fi
# FOS carries no udpcast patch. Buildroot's own 0001 (musl) is not in this
# directory. A change to udpcast goes to FOGProject/udpcast, so a patch here is
# a second copy: the old 0002-0004 are already in the release and would apply twice.
patches="$(compgen -G "$PKG/*.patch")"
if [[ -n $patches ]]; then
    echo "FAIL [udpcast] patch file(s) in $PKG; change FOGProject/udpcast instead:"
    printf '    %s\n' $patches
    fails=$((fails + 1))
else
    echo "  checked no FOS udpcast patches"
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
    echo "PASS: udpcast release source, hash, no old patches, receiver text and bracket strip"
    exit 0
fi
echo "FAILED: $fails udpcast IPv6 check(s)"
exit 1
