#!/bin/bash
#
# Assertion harness for fixparts, which runFixparts() in funcs.sh calls when
# sfdisk cannot apply a saved or computed partition table (fos#194):
#
#   tests/checks/fixparts-binary-present.sh
#
# Why this exists. Buildroot's gptfdisk package builds gdisk, sgdisk and
# cgdisk only. It has no option for fixparts. FOS used to carry its own copy
# of the package that added one, and 89c901f (2023-12-07) deleted that copy
# during a Buildroot update. Kconfig then dropped BR2_PACKAGE_GPTFDISK_FIXPARTS
# without a word, and every init since has shipped without the binary. The
# call fails with "command not found", so a capture or deploy that needs the
# repair stops at "Could not fix partition layout (runFixparts)".
#
# The fix lives in patch/filesystem/fs.patch, which adds the option to
# Buildroot's gptfdisk package. So this check asserts both halves: the patch
# still defines the symbol and the build target, and each config sets it. A
# config symbol with no Kconfig definition is the exact 2023 failure.
#
# Like wipefs-binary-present.sh, this cannot prove the binary is in a built
# init. Inspect output/target/usr/sbin/fixparts in a fssource<arch>/ for that.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
OVERLAY="$REPO/Buildroot/board/FOG/FOS/rootfs_overlay"
PATCH="$REPO/patch/filesystem/fs.patch"

fails=0
checked=0

# Only assert the package while something still calls the tool.
callers=$(grep -rlw fixparts "$OVERLAY/usr/share/fog/lib" "$OVERLAY/bin" 2>/dev/null)
if [[ -z $callers ]]; then
    echo "SKIP: nothing under the rootfs overlay calls fixparts any more"
    exit 0
fi
echo "  called from: $(printf '%s\n' "$callers" | sed "s#^$REPO/##" | tr '\n' ' ')"

if ! grep -qxF '+config BR2_PACKAGE_GPTFDISK_FIXPARTS' "$PATCH"; then
    echo "FAIL [patch/filesystem/fs.patch] does not define" \
         "BR2_PACKAGE_GPTFDISK_FIXPARTS, so Kconfig drops it from every config"
    fails=$((fails + 1))
fi
if ! grep -qxF '+GPTFDISK_TARGETS_$(BR2_PACKAGE_GPTFDISK_FIXPARTS) += fixparts' "$PATCH"; then
    echo "FAIL [patch/filesystem/fs.patch] does not add fixparts to" \
         "GPTFDISK_TARGETS, so the symbol builds nothing"
    fails=$((fails + 1))
fi

for arch in x64 x86 arm64; do
    f="$REPO/configs/fs${arch}.config"
    [[ -f $f ]] || continue
    checked=$((checked + 1))
    if grep -qxF 'BR2_PACKAGE_GPTFDISK_FIXPARTS=y' "$f"; then
        echo "  checked configs/fs${arch}.config"
    else
        echo "FAIL [configs/fs${arch}.config] fixparts is called but" \
             "BR2_PACKAGE_GPTFDISK_FIXPARTS is not set"
        fails=$((fails + 1))
    fi
done

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: fixparts is built into $checked config(s) that call it"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
