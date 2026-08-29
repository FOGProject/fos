#!/bin/bash
#
# Assertion harness for the Secure Boot hardening symbols in configs/kernel*.config.
#
#   tests/checks/secureboot-config.sh        # check the committed configs
#   tests/checks/secureboot-config.sh -b     # also check post-oldconfig .config
#                                            # in any kernelsource<arch>/ present
#
# Why this exists. build.sh copies configs/kernel<arch>.config to .config and
# runs `make oldconfig`, which SILENTLY DROPS any symbol whose dependencies are
# not met. A hand-edited config can therefore look completely correct in git and
# still produce a kernel with lockdown missing, and nothing anywhere says so.
# That failure would only surface as a Secure Boot client behaving differently
# from the one you tested. See docs/adr/0010-secure-boot-kernel-hardening.md
#
# The -b mode is the one that actually proves anything, because it inspects the
# config Kconfig produced rather than the one we wrote. Run it after a build.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."

checkBuilt=0
[[ ${1:-} == -b ]] && checkBuilt=1

# Symbols that must be present and enabled for a Secure Boot capable kernel.
# LOAD_UEFI_KEYS is what imports the firmware's db/MokList into the platform
# keyring; without it the kernel cannot see the key the shim validated against.
REQUIRED=(
    CONFIG_SECURITY=y
    CONFIG_SECURITYFS=y
    CONFIG_SECURITY_LOCKDOWN_LSM=y
    CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
    CONFIG_INTEGRITY=y
    CONFIG_INTEGRITY_SIGNATURE=y
    CONFIG_INTEGRITY_ASYMMETRIC_KEYS=y
    CONFIG_INTEGRITY_PLATFORM_KEYRING=y
    CONFIG_LOAD_UEFI_KEYS=y
    CONFIG_ASYMMETRIC_KEY_TYPE=y
    CONFIG_ASYMMETRIC_PUBLIC_KEY_SUBTYPE=y
    CONFIG_X509_CERTIFICATE_PARSER=y
    CONFIG_PKCS7_MESSAGE_PARSER=y
    CONFIG_SYSTEM_TRUSTED_KEYRING=y
    CONFIG_SECONDARY_TRUSTED_KEYRING=y
    CONFIG_SYSTEM_BLACKLIST_KEYRING=y
    CONFIG_EFI_STUB=y
)

# Symbols that must NOT be enabled. kexec_load() is unconditionally blocked by
# lockdown and FOS never uses it. FORCE_INTEGRITY would lock the kernel down on
# every boot, including the overwhelming majority that never turn Secure Boot
# on -- see the ADR for why that is the wrong default here.
FORBIDDEN=(
    CONFIG_KEXEC=y
    CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y
    CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y
)

fails=0
checked=0

checkConfig() {
    local label="$1" file="$2" sym
    [[ -f $file ]] || return 0
    checked=$((checked + 1))
    for sym in "${REQUIRED[@]}"; do
        if ! grep -qxF "$sym" "$file"; then
            echo "FAIL [$label] missing: $sym"
            fails=$((fails + 1))
        fi
    done
    for sym in "${FORBIDDEN[@]}"; do
        if grep -qxF "$sym" "$file"; then
            echo "FAIL [$label] must not be set: $sym"
            fails=$((fails + 1))
        fi
    done
    # The lockdown LSM only initializes if it is in the ordered LSM list.
    if ! grep -q '^CONFIG_LSM=.*lockdown' "$file"; then
        echo "FAIL [$label] CONFIG_LSM does not include lockdown"
        fails=$((fails + 1))
    fi
    echo "  checked $label"
}

for arch in x64 x86 arm64; do
    checkConfig "configs/kernel${arch}.config" "$REPO/configs/kernel${arch}.config"
done

if [[ $checkBuilt -eq 1 ]]; then
    built=0
    for arch in x64 x86 arm64; do
        f="$REPO/kernelsource${arch}/.config"
        if [[ -f $f ]]; then
            built=1
            checkConfig "kernelsource${arch}/.config (post-oldconfig)" "$f"
        fi
    done
    if [[ $built -eq 0 ]]; then
        echo
        echo "NOTE: -b given but no kernelsource<arch>/.config found -- nothing"
        echo "      post-oldconfig was checked. Build first, then re-run."
    fi
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: $checked config(s) carry the Secure Boot hardening symbols"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
