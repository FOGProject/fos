#!/bin/bash
#
# Assertion harness for getAddress() in S40network, the IPv6 boot path.
#
#   tests/checks/network-ipv6-fallback.sh
#
# The FOG boot menu puts ipv6boot=1 on the kernel line when the client reached
# the server over IPv6. Then S40network makes three IPv6 attempts. If they all
# fail, it must run the same three IPv4 DHCP attempts as a boot without
# ipv6boot=1. A network with IPv4 only, a router with no IPv6, or a DHCPv6
# server that is down must not leave the client without an address.
#
# Mechanism: extract the helper functions of S40network (everything before the
# "Enable loopback interface" line) and source them. The script itself runs a
# whole boot, so it cannot be sourced. ip, udhcpc and udhcpc6 are rewritten to
# stubs that log every call. sleep, killall and pidof are shell functions.
#
# S40NETWORK=<path> reads another copy of the script. It is how this harness
# was made to fail with a deliberately broken getAddress().

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${S40NETWORK:-$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/etc/init.d/S40network}"

[[ -f $SCRIPT ]] || { echo "ERROR: cannot find S40network at $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

awk '/^# Enable loopback interface/ {exit} {print}' "$SCRIPT" \
    | sed -e "s#/sbin/ip #$SANDBOX/bin/ip #g" \
          -e "s#/sbin/udhcpc #$SANDBOX/bin/udhcpc #g" \
          -e "s#/usr/bin/udhcpc6 #$SANDBOX/bin/udhcpc6 #g" \
          -e "s#^ipv6Conf=.*#ipv6Conf=$SANDBOX/conf#" > "$SANDBOX/funcs.sh"

# Every rewrite has to land, or a case would run the real binary of the host
# or write the host's own IPv6 switches.
for path in /sbin/ip /sbin/udhcpc /usr/bin/udhcpc6 /proc/sys/net/ipv6; do
    if grep -Fq -- "$path" "$SANDBOX/funcs.sh"; then
        echo "ERROR: $path survived the sandbox rewrite" >&2
        exit 2
    fi
done
if ! grep -q '^getAddress()' "$SANDBOX/funcs.sh"; then
    echo "ERROR: getAddress() not found before the main script" >&2
    exit 2
fi

# ip stub. A link-local address is always there. A global address is there only
# when the case creates the file "global".
cat > "$SANDBOX/bin/ip" <<EOF
#!/bin/bash
case "\$*" in
    *"scope link"*)
        echo '2: eth0    inet6 fe80::1/64 scope link \\       valid_lft forever preferred_lft forever' ;;
    *"scope global"*)
        # "late": the address shows from the 8th check on. A 5-second wait
        # makes 7 checks and misses it. That is a leased address still in
        # duplicate address detection.
        if [[ -f "$SANDBOX/late" ]]; then
            n=\$(( \$(cat "$SANDBOX/late") + 1 ))
            echo \$n > "$SANDBOX/late"
            [[ \$n -ge 8 ]] && touch "$SANDBOX/global"
        fi
        [[ -f "$SANDBOX/global" ]] && echo '2: eth0    inet6 2001:db8::5/64 scope global \\       valid_lft forever preferred_lft forever' ;;
esac
exit 0
EOF
# udhcpc stub. Logs the call. Gives no address.
cat > "$SANDBOX/bin/udhcpc" <<EOF
#!/bin/bash
echo "udhcpc \$*" >> "$SANDBOX/calls"
exit 0
EOF
# udhcpc6 stub. Logs the call. A stateful request (no -l) creates the global
# address when the case creates the file "lease". The exit status is in "rc6".
cat > "$SANDBOX/bin/udhcpc6" <<EOF
#!/bin/bash
echo "udhcpc6 \$*" >> "$SANDBOX/calls"
[[ \$* != *" -l"* && -f "$SANDBOX/lease" ]] && touch "$SANDBOX/global"
exit \$(cat "$SANDBOX/rc6" 2>/dev/null || echo 1)
EOF
chmod +x "$SANDBOX/bin/"*

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

# run_case <ipv6boot value> <attempt> <state words> -- runs getAddress once.
# State words: global (SLAAC address is there), lease (a stateful request
# gives an address), rc6ok (udhcpc6 exits 0). Prints "<status>" on the first
# line and the logged calls after it.
run_case() {
    local boot=$1 attempt=$2 state=$3
    rm -rf "$SANDBOX/calls" "$SANDBOX/global" "$SANDBOX/lease" "$SANDBOX/rc6" "$SANDBOX/conf" "$SANDBOX/late"
    [[ $state == *late* ]] && echo 0 > "$SANDBOX/late"
    # A kernel with IPv6: the interface switch exists and starts at off.
    mkdir -p "$SANDBOX/conf/eth0"
    echo 1 > "$SANDBOX/conf/eth0/disable_ipv6"
    [[ $state == *global* ]] && touch "$SANDBOX/global"
    [[ $state == *lease* ]] && touch "$SANDBOX/lease"
    [[ $state == *rc6ok* ]] && echo 0 > "$SANDBOX/rc6"
    (
        ipv6boot=$boot
        . "$SANDBOX/funcs.sh"
        sleep() { :; }
        # Logged, so a case can see a stop of the lease's client.
        killall() { echo "killall $*" >> "$SANDBOX/calls"; }
        pidof() { return 1; }
        getAddress eth0 "$attempt" >/dev/null 2>&1
        echo "$?"
        cat "$SANDBOX/calls" 2>/dev/null
    )
}

calls_of() { sed -n '2,$p' <<<"$1" | grep -c "^$2"; }
status_of() { head -n1 <<<"$1"; }
# The number of killall calls after the first stateful udhcpc6 call: a stop
# of the client that holds the lease.
kills_after_lease() {
    sed -n '2,$p' <<<"$1" | awk '/^udhcpc6 / && !/ -l/ {seen=1; next} seen && /^killall/ {n++} END {print n+0}'
}

# 1. A boot without ipv6boot starts with IPv4 DHCP only, as before this
# feature, and leaves IPv6 off.
for a in 1 2 3; do
    out="$(run_case "" $a "")"
    why=""
    [[ $(calls_of "$out" "udhcpc ") -ne 1 || $(calls_of "$out" udhcpc6) -ne 0 ]] \
        && why="expected one udhcpc call and no udhcpc6 call, got: $out"
    [[ $(cat "$SANDBOX/conf/eth0/disable_ipv6") != 1 ]] && why="attempt $a turned IPv6 on"
    note "no ipv6boot, attempt $a: IPv4 DHCP only, IPv6 stays off" "$why"
done

# 1b. Without ipv6boot, attempts 4 to 6 fall back to IPv6 after IPv4 failed.
for a in 4 5 6; do
    out="$(run_case "" $a "")"
    why=""
    [[ $(calls_of "$out" udhcpc6) -lt 1 ]] && why="attempt $a never asked for DHCPv6: $out"
    [[ $(calls_of "$out" "udhcpc ") -ne 0 ]] && why="attempt $a ran IPv4 DHCP again"
    [[ $(cat "$SANDBOX/conf/eth0/disable_ipv6" 2>/dev/null) != 0 ]] \
        && why="attempt $a did not turn IPv6 on for the interface"
    note "no ipv6boot, IPv4 failed, attempt $a: IPv6 fallback runs" "$why"
done

# 2. ipv6boot=1 and no IPv6 address: IPv6 attempts 1 to 3 fail and run no IPv4 DHCP.
for a in 1 2 3; do
    out="$(run_case 1 $a "")"
    why=""
    [[ $(status_of "$out") -eq 0 ]] && why="attempt $a returned success with no IPv6 address"
    [[ $(calls_of "$out" udhcpc6) -lt 1 ]] && why="attempt $a never asked for DHCPv6"
    [[ $(calls_of "$out" "udhcpc ") -ne 0 ]] \
        && why="attempt $a ran IPv4 DHCP, so the IPv6 attempts end early"
    note "ipv6boot=1, no IPv6 address, attempt $a: IPv6 only" "$why"
done

# 3. The case this exists for: IPv6 failed, so attempts 4 to 6 run IPv4 DHCP.
for a in 4 5 6; do
    out="$(run_case 1 $a "")"
    why=""
    [[ $(calls_of "$out" "udhcpc ") -ne 1 ]] \
        && why="attempt $a did not run IPv4 DHCP, so the client gets no address: $out"
    [[ $(calls_of "$out" udhcpc6) -ne 0 ]] && why="attempt $a ran DHCPv6 again"
    note "ipv6boot=1, no IPv6 address, attempt $a: IPv4 fallback runs" "$why"
done

# 3b. An IPv4 attempt stops the IPv6 client before IPv4 DHCP. The client's exit
# removes its DNS servers. They carry no interface tag, so the IPv4 client
# cannot remove them (udhcpc6-resolv.sh).
out="$(run_case 1 4 "")"
why=""
first=$(sed -n '2p' <<<"$out")
[[ $first != "killall udhcpc6" ]] && why="the first call was not a stop of udhcpc6: $out"
note "IPv4 attempt after IPv6 stops the IPv6 client first" "$why"

# 3c. The IPv4 attempt turns IPv6 off again on each interface an IPv6 attempt
# turned on. Otherwise the interface keeps its address. A name with an AAAA
# record can then resolve to it. lo, all and default keep their values.
out="$(
    rm -rf "$SANDBOX/calls" "$SANDBOX/conf"
    for d in all default lo eth0 eth1; do mkdir -p "$SANDBOX/conf/$d"; done
    echo 1 > "$SANDBOX/conf/all/disable_ipv6"
    echo 1 > "$SANDBOX/conf/default/disable_ipv6"
    echo 0 > "$SANDBOX/conf/lo/disable_ipv6"
    echo 0 > "$SANDBOX/conf/eth0/disable_ipv6"
    echo 0 > "$SANDBOX/conf/eth1/disable_ipv6"
    ipv6boot=1
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { :; }
    pidof() { return 1; }
    getAddress eth1 4 >/dev/null 2>&1
    for d in all default lo eth0 eth1; do printf '%s=%s ' $d "$(cat "$SANDBOX/conf/$d/disable_ipv6")"; done
)"
why=""
[[ $out != "all=1 default=1 lo=0 eth0=1 eth1=1 " ]] && why="got: $out"
note "IPv4 attempt after IPv6 turns IPv6 off again, lo stays on" "$why"

# 3d. An ordinary IPv4 boot turned no IPv6 on, so its IPv4 attempt writes no switch.
out="$(
    rm -rf "$SANDBOX/calls" "$SANDBOX/conf"
    for d in all lo eth0; do mkdir -p "$SANDBOX/conf/$d"; done
    echo 1 > "$SANDBOX/conf/all/disable_ipv6"
    echo 0 > "$SANDBOX/conf/lo/disable_ipv6"
    echo 1 > "$SANDBOX/conf/eth0/disable_ipv6"
    touch -d '2000-01-01' "$SANDBOX"/conf/*/disable_ipv6
    ipv6boot=
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { :; }
    pidof() { return 1; }
    getAddress eth0 1 >/dev/null 2>&1
    find "$SANDBOX/conf" -name disable_ipv6 -newermt '2001-01-01'
)"
why=""
[[ -n $out ]] && why="an ordinary IPv4 attempt wrote: $out"
note "ordinary IPv4 attempt writes no IPv6 switch" "$why"

# 4. A DHCPv6-only network: the stateful request gives the address.
out="$(run_case 1 1 "lease rc6ok")"
why=""
[[ $(status_of "$out") -ne 0 ]] && why="returned failure although the lease gave an address"
[[ $(calls_of "$out" udhcpc6) -ne 1 ]] \
    && why="expected exactly one stateful udhcpc6 call, got: $out"
[[ $out == *" -l"* ]] && why="ran the stateless request after a stateful lease"
[[ $(kills_after_lease "$out") -ne 0 ]] && why="stopped the client that holds the lease: $out"
note "ipv6boot=1, DHCPv6-only network: stateful lease is enough" "$why"

# 4b. A lease whose address never becomes usable: fail, and do not start a
# second client next to the one that holds the lease.
out="$(run_case 1 1 "rc6ok")"
why=""
[[ $(status_of "$out") -eq 0 ]] && why="returned success with no usable address"
[[ $(calls_of "$out" udhcpc6) -ne 1 ]] && why="expected exactly one udhcpc6 call, got: $out"
[[ $out == *" -l"* ]] && why="started a stateless client next to the lease's client"
note "ipv6boot=1, lease with no usable address: fail, one client" "$why"

# 4c. A lease whose address becomes usable only after several checks: keep
# the lease's client and succeed. Stopping it would release the address.
out="$(run_case 1 1 "rc6ok late")"
why=""
[[ $(status_of "$out") -ne 0 ]] && why="returned failure although the leased address became usable"
[[ $out == *" -l"* ]] && why="stopped the lease's client and ran a stateless request: $out"
[[ $(kills_after_lease "$out") -ne 0 ]] && why="stopped the client that holds the lease: $out"
note "ipv6boot=1, lease with a late address: the lease's client is kept" "$why"

# 5. A SLAAC network where the DHCPv6 server does not answer: the address is enough.
out="$(run_case 1 1 "global")"
why=""
[[ $(status_of "$out") -ne 0 ]] && why="returned failure although SLAAC gave an address"
[[ $out != *"udhcpc6 "*" -l"* ]] && why="no stateless request for the DNS servers: $out"
[[ $(calls_of "$out" "udhcpc ") -ne 0 ]] && why="ran IPv4 DHCP although IPv6 worked"
note "ipv6boot=1, SLAAC network: stateless request, no IPv4" "$why"

# 6. The main loop makes six attempts with ipv6boot=1 and three without.
why=""
grep -q '^ipv4Attempts=3$' "$SCRIPT" \
    && grep -q '^ipv6Attempts=3$' "$SCRIPT" \
    && grep -q '^ *attempts=\$((ipv4Attempts + ipv6Attempts))$' "$SCRIPT" \
    || why="the attempt count is not 3 + 3"
note "the retry loop has three attempts per family" "$why"

# 7. stopUdhcpc6 waits until the old client has exited. The old client is
# still there for the first two checks, then gone.
checks=$(
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { return 0; }
    n=0
    pidof() { n=$((n + 1)); [[ $n -le 2 ]]; }
    stopUdhcpc6
    echo "$n"
)
why=""
[[ $checks -ne 3 ]] && why="expected three pidof checks (two running, one gone), got $checks"
note "stopUdhcpc6 waits for the old udhcpc6 to exit" "$why"

# 8. An old udhcpc6 that never exits: the wait stops at the time limit.
checks=$(
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { return 0; }
    n=0
    # Gone after 100 checks, so a wait with no limit fails here, not hangs.
    pidof() { n=$((n + 1)); [[ $n -lt 100 ]]; }
    stopUdhcpc6
    echo "$n"
)
why=""
[[ $checks -gt 5 ]] && why="the wait did not stop at its limit: $checks pidof checks"
note "stopUdhcpc6 gives up on a udhcpc6 that never exits" "$why"

# 9. No udhcpc6 runs (killall finds nothing): no wait at all.
checks=$(
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { return 1; }
    n=0
    pidof() { n=$((n + 1)); return 0; }
    stopUdhcpc6
    echo "$n"
)
why=""
[[ $checks -ne 0 ]] && why="waited although no udhcpc6 ran: $checks pidof checks"
note "stopUdhcpc6 does not wait when no udhcpc6 runs" "$why"

# 10. The kernel's IPv6 is off, on every boot, before any interface goes up.
# So a router advertisement cannot give a boot that IPv4 serves an IPv6
# address. Only an IPv6 attempt turns it on (cases 1, 1b).
why=""
# The only guard allowed on the writes is "this kernel has IPv6".
guard=$(grep -n '^if \[\[ -d \$ipv6Conf \]\]; then$' "$SCRIPT" | head -n1 | cut -d: -f1)
off=$(grep -n '^    echo 1 > "\$ipv6Conf/all/disable_ipv6"$' "$SCRIPT" | head -n1 | cut -d: -f1)
def=$(grep -n '^    echo 1 > "\$ipv6Conf/default/disable_ipv6"$' "$SCRIPT" | head -n1 | cut -d: -f1)
up=$(grep -n 'ip link set \$iface up' "$SCRIPT" | head -n1 | cut -d: -f1)
if [[ -z $guard || -z $off || -z $def || -z $up ]]; then
    why="the guarded disable_ipv6 writes or the link-up line is missing"
elif [[ $off -ne $((guard + 2)) || $def -ne $((guard + 1)) ]]; then
    why="the disable_ipv6 writes are not directly under the IPv6 guard"
elif [[ ! ( $off -lt $up && $def -lt $up ) ]]; then
    why="IPv6 is not turned off before the first interface goes up (all $off, default $def, up $up)"
fi
note "kernel IPv6 is off before any interface goes up" "$why"

# 11. A kernel without IPv6 (no switch for the interface): the IPv6 attempt
# fails at once and runs no DHCPv6.
out="$(
    rm -rf "$SANDBOX/calls" "$SANDBOX/conf"
    ipv6boot=1
    . "$SANDBOX/funcs.sh"
    sleep() { :; }
    killall() { :; }
    pidof() { return 1; }
    getAddress eth0 1 >/dev/null 2>&1
    echo "$?"
    cat "$SANDBOX/calls" 2>/dev/null
)"
why=""
[[ $(status_of "$out") -eq 0 ]] && why="returned success with no IPv6 in the kernel"
[[ $(calls_of "$out" udhcpc6) -ne 0 ]] && why="ran DHCPv6 with no IPv6 in the kernel"
note "kernel without IPv6: the IPv6 attempt fails at once" "$why"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
