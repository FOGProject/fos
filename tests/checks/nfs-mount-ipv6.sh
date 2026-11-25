#!/bin/bash
#
# Assertion harness: no FOS NFS mount sets proto=.
#
#   tests/checks/nfs-mount-ipv6.sh
#
# Why this exists. The kernel rejects proto=tcp with an IPv6 server address:
# mount(2) returns "Invalid argument". Seen in the IPv6 lab (fogproject#2152):
#
#     mount: mounting [fd00:f06:0:1::1]:/images/dev/ on /images failed: Invalid argument
#
# FOS's busybox resolves the server and passes the option string to the
# kernel. With no proto= option, the kernel uses TCP over the family of the
# server address: tcp for IPv4, tcp6 for IPv6. The FOS kernel has no NFS over
# UDP (CONFIG_NFS_DISABLE_UDP_SUPPORT=y), so no UDP fallback can occur.
# Checked with FOS's own busybox on a host with the same export:
#
#     -o nolock,proto=tcp   [v6]:/path   Invalid argument
#     -o nolock             [v6]:/path   mounts, proto=tcp6
#     -o nolock             v4:/path     mounts, proto=tcp
#
# This also covers a server name with only an AAAA record, which no
# bracket check on storage= can see.
#
# The check is a grep, like nfs-mount-type.sh: the invariant is the option
# text that reaches the kernel. It finds the mounts by their NFS-only nolock
# option, so a new NFS mount is checked without a change here.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${FOS_BIN:-$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin}"

fails=0
checked=0

while IFS=: read -r file line text; do
    checked=$((checked + 1))
    if [[ $text == *"proto="* ]]; then
        echo "FAIL [$(basename "$file"):$line] NFS mount sets proto=, which breaks an IPv6 server"
        echo "       $(echo "$text" | sed 's/^[[:space:]]*//')"
        fails=$((fails + 1))
    else
        echo "  checked $(basename "$file"):$line"
    fi
done < <(grep -rn '^[[:space:]]*\(if \)\{0,1\}mount .*nolock' "$BIN")

if [[ $checked -eq 0 ]]; then
    echo "FAIL: found no nolock mounts at all -- has the storage mount moved?"
    exit 1
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: $checked NFS mount(s) leave proto= to the kernel"
    exit 0
fi
echo "FAILED: $fails of $checked NFS mount(s) set proto="
exit 1
