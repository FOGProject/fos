#!/bin/bash
#
# Assertion harness for the resolv.conf lines of the udhcpc6 script.
#
#   tests/checks/udhcpc6-resolv.sh
#
# Why this exists. The script used to tag each line with its interface:
#
#     nameserver fd71:6a85:f038:0001:0000:0000:0000:0001 # eno1
#
# glibc reads only the first word after "nameserver", so curl worked. busybox
# nslookup reads everything up to the end of the line as the address, and
# failed (fogproject#2152, reported on physical hardware):
#
#     nslookup: bad address 'fd71:6a85:f038:0001:0000:0000:0000:0001 # eno1'
#
# The lines now carry no tag. The script records the lines it wrote in a state
# file, and removes exactly those lines on the next run and on "deconfig".
# Lines from the IPv4 script, which keep their tag, must survive.
#
# Mechanism: copy the script with its file paths moved into a sandbox, and run
# it the way udhcpc6 does: the action as $1, the lease in the environment.
#
# DEFAULT6=<path> runs another copy of the script. It is how this harness was
# made to fail with the tagged lines.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DEFAULT6:-$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/udhcpc/default6.script}"

[[ -f $SCRIPT ]] || { echo "ERROR: cannot find default6.script at $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/run"

sed -e "s#/etc/resolv.conf#$SANDBOX/resolv.conf#g" \
    -e "s#/var/run/#$SANDBOX/run/#g" \
    -e "s#/sbin/ip #$SANDBOX/bin/ip #g" "$SCRIPT" > "$SANDBOX/default6.script"

# Every rewrite has to land, or a case would write the host's own files.
for path in /etc/resolv.conf /var/run/ /sbin/ip; do
    if grep -Fq -- "$path" "$SANDBOX/default6.script"; then
        echo "ERROR: $path survived the sandbox rewrite" >&2
        exit 2
    fi
done

# ip stub: the script adds and deletes the leased address. Nothing to check there.
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/ip"
chmod +x "$SANDBOX/bin/ip"

PASS=0
FAIL=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $1 ($2)"
        FAIL=$((FAIL + 1))
    fi
}

# run <action> <dns> <search> -- runs the script once for interface eno1.
run() {
    env -i PATH="$PATH" interface=eno1 dns="$2" search="$3" \
        sh "$SANDBOX/default6.script" "$1" >/dev/null 2>&1
}

V4_NS="nameserver 192.168.0.1 # eno1"
V4_SEARCH="search v4.test # eno1"
printf '%s\n%s\n' "$V4_SEARCH" "$V4_NS" > "$SANDBOX/resolv.conf"

# 1. bound: every nameserver line is "nameserver <address>" and nothing else.
run bound "fd71:6a85:f038:1::1 fd71:6a85:f038:1::2" "v6.test"
why=""
bad=$(grep '^nameserver' "$SANDBOX/resolv.conf" | grep -v "^$V4_NS\$" | awk 'NF != 2')
[[ -n $bad ]] && why="a nameserver line has more than an address: $bad"
grep -qx 'nameserver fd71:6a85:f038:1::1' "$SANDBOX/resolv.conf" \
    && grep -qx 'nameserver fd71:6a85:f038:1::2' "$SANDBOX/resolv.conf" \
    || why="${why:-the DHCPv6 DNS servers are missing: $(cat "$SANDBOX/resolv.conf")}"
grep -qx 'search v6.test' "$SANDBOX/resolv.conf" \
    || why="${why:-the search line is missing or tagged: $(cat "$SANDBOX/resolv.conf")}"
note "bound writes untagged nameserver and search lines" "$why"

# 2. The IPv4 lines survive bound.
why=""
grep -qxF "$V4_NS" "$SANDBOX/resolv.conf" && grep -qxF "$V4_SEARCH" "$SANDBOX/resolv.conf" \
    || why="the IPv4 lines are gone: $(cat "$SANDBOX/resolv.conf")"
note "bound keeps the lines of the IPv4 script" "$why"

# 3. renew with a new server: the old DHCPv6 lines go, the new one is there once.
run renew "fd71:6a85:f038:1::3" ""
why=""
grep -q 'fd71:6a85:f038:1::1\|fd71:6a85:f038:1::2\|v6.test' "$SANDBOX/resolv.conf" \
    && why="old DHCPv6 lines survived the renew: $(cat "$SANDBOX/resolv.conf")"
[[ $(grep -cx 'nameserver fd71:6a85:f038:1::3' "$SANDBOX/resolv.conf") -ne 1 ]] \
    && why="${why:-the new server is not there exactly once: $(cat "$SANDBOX/resolv.conf")}"
grep -qxF "$V4_NS" "$SANDBOX/resolv.conf" || why="${why:-the renew removed the IPv4 line}"
note "renew replaces only the DHCPv6 lines" "$why"

# 4. deconfig: the DHCPv6 lines go, the IPv4 lines stay.
run deconfig "" ""
why=""
grep -q 'fd71' "$SANDBOX/resolv.conf" && why="DHCPv6 lines survived deconfig: $(cat "$SANDBOX/resolv.conf")"
grep -qxF "$V4_NS" "$SANDBOX/resolv.conf" && grep -qxF "$V4_SEARCH" "$SANDBOX/resolv.conf" \
    || why="${why:-deconfig removed the IPv4 lines: $(cat "$SANDBOX/resolv.conf")}"
note "deconfig removes only the DHCPv6 lines" "$why"

# 5. deconfig with nothing recorded changes nothing.
before=$(cat "$SANDBOX/resolv.conf")
run deconfig "" ""
why=""
[[ $(cat "$SANDBOX/resolv.conf") != "$before" ]] && why="resolv.conf changed: $(cat "$SANDBOX/resolv.conf")"
note "deconfig with no DHCPv6 lines changes nothing" "$why"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
