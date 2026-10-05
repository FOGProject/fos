#!/bin/bash
#
# Assertion harness for the one external tool FOS calls that busybox does not
# supply: wipefs.
#
#   tests/checks/wipefs-binary-present.sh
#
# Why this exists. restoreLVM() in funcs.sh clears stale filesystem and RAID
# signatures off the target partition before it recreates the physical volume:
#
#     wipefs -a "$part" >/dev/null 2>&1
#
# For as long as that line has existed, no FOS image has contained wipefs.
# BR2_PACKAGE_UTIL_LINUX_WIPEFS was "not set" in all three filesystem configs,
# and busybox has no wipefs applet to fall back on, so the call was always
# "command not found" -- discarded along with its exit status by the redirect,
# leaving the stale signatures the line exists to remove. It also means an
# operator told to run wipefs by hand, in a debug shell or from support
# instructions, gets nothing (forum 18253).
#
# tests/checks/lvm.sh cannot catch this. It PATH-shadows every external tool
# with a logging stub, wipefs among them, so it proves the call is issued and
# is structurally blind to whether the image has anything to issue it to.
# That is the right design for an assertion about control flow, and it is why
# "is this binary built at all" needs a separate check against the configs.
#
# Scoped to wipefs on purpose. Most util-linux applets are deliberately "not
# set" here because busybox provides them -- mount, losetup, fdisk, blkid --
# so a sweep asserting every applet FOS invokes would fail on symbols that are
# correctly off. wipefs is the one with no busybox counterpart.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
LIB="$REPO/Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"

fails=0
checked=0

# Only assert the symbol while something still calls the tool. If the wipefs
# call is ever replaced, this check should stop demanding the package rather
# than pin a dependency nothing uses.
callers=$(grep -rlw wipefs "$LIB" "$REPO/Buildroot/board/FOG/FOS/rootfs_overlay/bin" 2>/dev/null)
if [[ -z $callers ]]; then
    echo "SKIP: nothing under the rootfs overlay calls wipefs any more"
    exit 0
fi
echo "  called from: $(printf '%s\n' "$callers" | sed "s#^$REPO/##" | tr '\n' ' ')"

for arch in x64 x86 arm64; do
    f="$REPO/configs/fs${arch}.config"
    [[ -f $f ]] || continue
    checked=$((checked + 1))
    if grep -qxF 'BR2_PACKAGE_UTIL_LINUX_WIPEFS=y' "$f"; then
        echo "  checked configs/fs${arch}.config"
    else
        echo "FAIL [configs/fs${arch}.config] wipefs is called but" \
             "BR2_PACKAGE_UTIL_LINUX_WIPEFS is not set"
        fails=$((fails + 1))
    fi
done

# util-linux has to be building its binaries at all, or the applet symbol above
# selects nothing.
for arch in x64 x86 arm64; do
    f="$REPO/configs/fs${arch}.config"
    [[ -f $f ]] || continue
    if ! grep -qxF 'BR2_PACKAGE_UTIL_LINUX_BINARIES=y' "$f"; then
        echo "FAIL [configs/fs${arch}.config] BR2_PACKAGE_UTIL_LINUX_BINARIES" \
             "is not set, so no util-linux applet is built"
        fails=$((fails + 1))
    fi
done

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: wipefs is built into $checked config(s) that call it"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
