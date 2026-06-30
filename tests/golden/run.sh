#!/bin/bash
#
# Golden-output differential harness for the FOS shared libraries.
#
# It drives the deterministic, refactor-targeted functions in funcs.sh over a
# fixed battery of inputs and emits one canonical output stream. The point is to
# prove that the DRY refactors in later commits change no observable output:
#
#   tests/golden/run.sh capture   # write fixtures/golden.txt (run BEFORE a refactor)
#   tests/golden/run.sh check     # regenerate and diff against the committed fixture
#   tests/golden/run.sh print     # just dump the current output to stdout
#
# Covered (per the DRY plan):
#   - every *FileName() output string
#   - the doInventory dmidecode block and the base64 encode block
#   - the changeHostname registry EOFREG file contents
#
# This harness lives OUTSIDE rootfs_overlay, so it never enters the init.
#
# Mechanism: funcs.sh hardcodes /usr/share/fog/lib paths and calls hardware
# tools. We copy the library into a temp sandbox with those absolute paths
# rewritten, stub the external tools deterministically, then source and call the
# real functions. Baseline and candidate runs execute on the same host with the
# same stubs, so any host-specific value (e.g. /proc/meminfo) cancels out.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"
FIXTURE="$HERE/fixtures/golden.txt"

[[ -f $REPO_LIB/funcs.sh ]] || { echo "ERROR: cannot find funcs.sh under $REPO_LIB" >&2; exit 2; }

# Emit the canonical golden stream to stdout. Runs entirely in a subshell so the
# sandbox, stubs and sourced globals never leak back to the caller.
generate() (
    set +u
    local SANDBOX STUBBIN
    SANDBOX="$(mktemp -d)"
    trap 'rm -rf "$SANDBOX"' EXIT
    STUBBIN="$SANDBOX/bin"
    mkdir -p "$STUBBIN"

    # --- sandbox copy of the library with host-absolute paths rewritten ---
    cp "$REPO_LIB/partition-funcs.sh" "$SANDBOX/partition-funcs.sh"
    # Fixed meminfo so the inventory 'mem' line is machine-independent.
    printf 'MemTotal:       16384000 kB\n' > "$SANDBOX/meminfo"
    sed -e "s#^\. /usr/share/fog/lib/partition-funcs\.sh#. $SANDBOX/partition-funcs.sh#" \
        -e "s#/usr/share/fog/lib/EOFREG#$SANDBOX/EOFREG#g" \
        -e "s#/proc/meminfo#$SANDBOX/meminfo#g" \
        "$REPO_LIB/funcs.sh" > "$SANDBOX/funcs.sh"

    # --- deterministic stubs for external executables (via PATH) ---
    mkstub() { printf '#!/bin/bash\n%s\n' "$2" > "$STUBBIN/$1"; chmod +x "$STUBBIN/$1"; }
    mkstub dmidecode 'echo "dmi[$*]"'
    mkstub hdparm 'echo " Model=STUBDISK, FwRev=1.0, SerialNo=SN123"'
    mkstub smartctl 'exit 0'
    mkstub lshw 'echo "[{\"vendor\":\"StubVendor\",\"product\":\"StubGPU\"}]"'
    mkstub ntfs-3g 'exit 0'
    mkstub umount 'exit 0'
    mkstub mkdir 'exit 0'
    mkstub reged "cp '$SANDBOX/EOFREG' '$SANDBOX/EOFREG.captured' 2>/dev/null; exit 0"
    PATH="$STUBBIN:$PATH"

    # --- stubs for the library's own helpers we don't want to execute ---
    handleError() { echo "HANDLEERROR: $*"; }
    handleWarning() { echo "HANDLEWARNING: $*"; }
    debugPause() { :; }
    dots() { :; }
    hasGRUB() { hasGRUB=0; }

    # shellcheck disable=SC1090
    . "$SANDBOX/funcs.sh"

    # ============================================================
    echo "=== FileName helpers ==="
    local ip dn
    for pair in "/net/dev/foo:1" "/images/host name:2" "/mnt/img:10"; do
        ip="${pair%:*}"; dn="${pair##*:}"
        swapUUIDFileName "$ip" "$dn"
        echo "swapUUIDFileName($ip,$dn)=$swapuuidfilename"
        sfdiskPartitionFileName "$ip" "$dn"
        echo "sfdiskPartitionFileName($ip,$dn)=$sfdiskoriginalpartitionfilename"
        sfdiskLegacyOriginalPartitionFileName "$ip" "$dn"
        echo "sfdiskLegacyOriginalPartitionFileName($ip,$dn)=$sfdisklegacyoriginalpartitionfilename"
        sfdiskMinimumPartitionFileName "$ip" "$dn"
        echo "sfdiskMinimumPartitionFileName($ip,$dn)=$sfdiskminimumpartitionfilename"
        sfdiskOriginalPartitionFileName "$ip" "$dn"
        echo "sfdiskOriginalPartitionFileName($ip,$dn)=$sfdiskoriginalpartitionfilename"
        fixedSizePartitionsFileName "$ip" "$dn"
        echo "fixedSizePartitionsFileName($ip,$dn)=$fixed_size_file"
        hasGrubFileName "$ip" "$dn"
        echo "hasGrubFileName($ip,$dn)=$hasgrubfilename"
        hasGrubFileName "$ip" "$dn" sgdisk
        echo "hasGrubFileName($ip,$dn,sgdisk)=$hasgrubfilename"
        EBRFileName "$ip" "$dn" 5
        echo "EBRFileName($ip,$dn,5)=$ebrfilename"
        EBRFileName "$ip" "$dn" ""
        echo "EBRFileName($ip,$dn,empty)=$ebrfilename"
        tmpEBRFileName "$dn" 5
        echo "tmpEBRFileName($dn,5)=$tmpebrfilename"
        type=up; mbrout=""
        MBRFileName "$ip" "$dn" mbrout
        echo "MBRFileName.up($ip,$dn)=$mbrout"
        type=up; mbrout=""
        MBRFileName "$ip" "$dn" mbrout sgdisk
        echo "MBRFileName.up.sgdisk($ip,$dn)=$mbrout"
    done

    # ============================================================
    echo "=== doInventory (dmidecode + base64 blocks) ==="
    hd="/dev/stubdisk"
    doInventory
    local v n64
    for v in sysman sysproduct sysversion sysserial sysuuid systype biosversion \
             biosvendor biosdate mbman mbproductname mbversion mbserial mbasset \
             cpuman cpuversion cpucurrent cpumax mem hdinfo caseman casever \
             caseserial caseasset \
             inventory_graphics_vendor inventory_graphics_product; do
        n64="${v}64"
        echo "$v=${!v}"
        echo "${v}64=${!n64}"
    done

    # ============================================================
    echo "=== changeHostname EOFREG ==="
    REG_LOCAL_MACHINE_7="$SANDBOX/regfile"
    : > "$SANDBOX/regfile"
    hostname="GOLDENHOST"
    hostearly=1
    osid=2
    changeHostname "/dev/stubpart" >/dev/null 2>&1
    if [[ -f $SANDBOX/EOFREG.captured ]]; then
        cat "$SANDBOX/EOFREG.captured"
    else
        echo "EOFREG NOT CAPTURED"
    fi
)

mode="${1:-print}"
case "$mode" in
    print)
        generate
        ;;
    capture)
        mkdir -p "$(dirname "$FIXTURE")"
        generate > "$FIXTURE"
        echo "Captured golden fixture -> $FIXTURE ($(wc -l < "$FIXTURE") lines)"
        ;;
    check)
        [[ -f $FIXTURE ]] || { echo "ERROR: no fixture at $FIXTURE (run 'capture' first)" >&2; exit 2; }
        tmp="$(mktemp)"
        generate > "$tmp"
        if diff -u "$FIXTURE" "$tmp"; then
            echo "OK: output is byte-identical to the golden fixture."
            rm -f "$tmp"
        else
            echo "FAIL: output differs from the golden fixture (see diff above)." >&2
            rm -f "$tmp"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {capture|check|print}" >&2
        exit 2
        ;;
esac
