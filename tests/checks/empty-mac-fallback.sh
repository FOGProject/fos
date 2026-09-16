#!/bin/bash
#
# Assertion harness for what $mac is when the server did not send one.
#
#   tests/checks/empty-mac-fallback.sh
#
# $mac is how FOS names itself to the server for a whole run. reportToServer()
# posts it to service/taskerror.php, fog.statusreporter posts it to
# service/progress.php, and secureboot-funcs.sh reports enrollment with it.
# Empty, every one of those is rejected or silently ignored -- and
# taskerror.php acks identically whatever happened, so a machine can spend an
# entire failed deploy talking to a server that discards every word.
#
# FOG 1.5 servers do send it empty. BootMenu::falseTasking() builds the kernel
# line with "mac=$mac" and never assigns $mac, so every task started from the
# iPXE menu for a machine with no host row boots with mac= empty
# (FOGProject/fogproject#1767). FOS is not branched -- one init runs against
# every server version in the field -- so a server-side fix reaches only
# servers that took it, and this is the half that covers the rest.
#
# Nothing else recovers it, which is the part worth pinning. falseTasking()
# does emit capone=1, and fog.capone opens with its own
# `export mac=$(getMACAddresses)` -- but it also emits type=down, and bin/fog
# branches on $mode, which is unset on this path. So the run is fog.download,
# fog.capone never executes, and fog.download's save/restore around the
# inventory call puts the empty value back.
#
# Mechanism mirrors tests/checks/error-report.sh: source a sandbox copy of the
# library with its hardcoded absolute paths rewritten to fixtures. Three of
# them matter here and all three are rewritten rather than PATH-shadowed,
# because funcs.sh names them absolutely: /proc/cmdline (the kernel arguments),
# /sbin/ip (the NICs), and /tmp/hinfo.txt (the USB boot override).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
    -e "s#/proc/cmdline#$SANDBOX/cmdline#g" \
    -e "s#/sbin/ip #$SANDBOX/bin/ip #g" \
    -e "s#/tmp/hinfo\.txt#$SANDBOX/hinfo.txt#g" \
    "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

# Every rewrite has to have landed, or a case would pass by reading the real
# host instead of the fixture -- which on a developer's machine still produces
# a plausible MAC, and would make case 1 green whatever funcs.sh did.
for path in /proc/cmdline /sbin/ip /tmp/hinfo.txt; do
    if grep -Fq -- "$path" "$SANDBOX/funcs.sh"; then
        echo "ERROR: $path survived the sandbox rewrite; this harness would read the real host" >&2
        exit 2
    fi
done

mkdir -p "$SANDBOX/bin"

# ip double. The two invocations getMACAddresses makes, answered in the shape
# FOS's OWN busybox produces -- not this host's.
#
# That distinction is the whole reason this block is long. getMACAddresses
# joins the `-0 addr` output in pairs and takes field 11, which is the MAC
# only when the header line has exactly nine fields. Fedora's iproute2 prints
# `group default` there and Fedora's busybox prints `state UP`; against either
# of those, field 11 is "default" or "1000" and the function returns junk. FOS
# builds busybox without those, so its header is
#
#     2: eth0: <FLAGS> mtu 1500 qdisc htb qlen 1000
#
# and field 11 lands on the MAC. Verified by extracting /bin/busybox from a
# shipped init.xz (BusyBox v1.37.0) and running it, rather than from the ip on
# whatever machine this harness runs on -- a stub built from the host's format
# would make every case below fail against correct code.
#
# Records that it ran, so a case can assert it did NOT.
cat > "$SANDBOX/bin/ip" <<EOF
#!/bin/bash
echo "called" >> "$SANDBOX/ip.called"
case "\$*" in
    "-4 -o addr")
        printf '%s\n' \\
            '1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever' \\
            '2: eth0    inet 10.0.0.50/24 brd 10.0.0.255 scope global eth0\\       valid_lft forever preferred_lft forever'
        ;;
    "-0 addr")
        printf '%s\n' \\
            '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue qlen 1000' \\
            '    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00' \\
            '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc htb qlen 1000' \\
            '    link/ether 02:00:00:00:0e:11 brd ff:ff:ff:ff:ff:ff'
        ;;
esac
exit 0
EOF
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

# source_with <cmdline contents> -- sources the sandbox library against a
# fixture kernel command line and prints the resulting $mac. A subshell, so
# each case starts from an environment carrying nothing from the last one.
source_with() {
    printf '%s\n' "$1" > "$SANDBOX/cmdline"
    rm -f "$SANDBOX/ip.called"
    (
        set +u
        . "$SANDBOX/funcs.sh" >/dev/null 2>&1
        printf '%s' "$mac"
    )
}

BASE="loglevel=4 initrd=init.xz root=/dev/ram0 rw web=http://fog.example/fog/ type=down"

# 1. The case this exists for. A false tasking's kernel line carries mac= with
#    nothing after it, and the awk in the import loop drops an empty value
#    outright -- so $mac is not merely empty, it is never set at all.
got="$(source_with "$BASE mac= storageip=10.0.0.1 capone=1")"
why=""
[[ -z $got ]] && why="\$mac is still empty, so every report this run sends is anonymous"
[[ -n $got && $got != *"02:00:00:00:0e:11"* ]] && why="\$mac is '$got', which is not what the NICs report"
note "an empty mac= on the kernel line is answered from the NICs" "$why"

# 2. Same, for a kernel line with no mac= at all. The 1.5 server emits the
#    empty form, but the two are indistinguishable by the time the import loop
#    has run, and a future caller could omit it entirely.
got="$(source_with "$BASE storageip=10.0.0.1")"
why=""
[[ $got != *"02:00:00:00:0e:11"* ]] && why="\$mac is '$got' with no mac= argument present"
note "a missing mac= argument is answered the same way" "$why"

# 3. A server that DID send one wins, and the NICs are not consulted at all.
#    This is the normal tasking, and it is every run but the broken one -- the
#    server's answer is authoritative (it is the host's registered MAC, which
#    is not necessarily the booting NIC's) and a lookup here would be pure
#    cost on the hot path.
got="$(source_with "$BASE mac=aa:bb:cc:dd:ee:ff storageip=10.0.0.1")"
why=""
[[ $got != "aa:bb:cc:dd:ee:ff" ]] && why="the server's mac= became '$got'"
[[ -f $SANDBOX/ip.called ]] && why="${why:+$why; }the NICs were queried even though the server sent a MAC"
note "a mac= the server sent is kept, and costs no lookup" "$why"

# 4. USB boot keeps its own answer. /tmp/hinfo.txt is fetched from the server
#    by bin/fog and sourced by the import preamble, and it carries the kernel
#    arguments a USB boot has no PXE chain to receive. Resolving the fallback
#    before that source would overwrite a value the server chose.
printf 'mac=de:ad:be:ef:00:01\n' > "$SANDBOX/hinfo.txt"
got="$(source_with "$BASE boottype=usb storageip=10.0.0.1")"
rm -f "$SANDBOX/hinfo.txt"
why=""
[[ $got != "de:ad:be:ef:00:01" ]] && why="the USB boot's own hinfo.txt MAC became '$got'"
note "a USB boot's hinfo.txt answer is not overwritten" "$why"

# 5. Exported, not just set. Every fog.* entry point runs helpers in subshells
#    and child scripts (fog.download backgrounds fog.statusreporter), and a
#    plain assignment would leave those with nothing -- which is the same
#    symptom this fixes, one process further down.
got="$(
    set +u
    printf '%s\n' "$BASE mac= storageip=10.0.0.1" > "$SANDBOX/cmdline"
    . "$SANDBOX/funcs.sh" >/dev/null 2>&1
    bash -c 'printf "%s" "$mac"'
)"
why=""
[[ $got != *"02:00:00:00:0e:11"* ]] && why="a child process sees '$got'"
note "the resolved MAC is exported to child processes" "$why"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
