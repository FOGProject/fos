#!/bin/bash
#
# Assertion harness for the PCIe ASPM / extended-config-space symbols in
# configs/kernel*.config.
#
#   tests/checks/pcie-aspm-config.sh        # check the committed configs
#   tests/checks/pcie-aspm-config.sh -b     # also check post-oldconfig .config
#                                           # in any kernelsource<arch>/ present
#
# Why this exists. Both CONFIG_PCIEASPM and CONFIG_PCI_MMCONFIG are `default y`
# upstream; FOS explicitly turned them off in 2016 and nothing noticed for nine
# years, because the out-of-tree Realtek vendor drivers managed ASPM themselves.
# Switching to the in-kernel r8169 (FOGProject/fos#108) removed that cover and
# turned the missing symbols into a 10x download-throughput loss on RTL8168h.
# See docs/adr/0011-pcie-aspm-and-extended-config-space.md for the full chain.
#
# The failure mode is silent in the worst way: with CONFIG_PCIEASPM=n,
# pci_disable_link_state() is an inline stub that RETURNS SUCCESS (0). r8169
# reads that as "the OS controls ASPM", sets tp->aspm_manageable = true, and
# then enables ASPM and L1.2 triggering in the chip -- while the kernel has no
# ASPM code at all and never disabled anything. Nothing is logged. The only
# externally visible hint is r8169's "No native access to PCI extended config
# space, falling back to CSI" notice, which is really reporting the *other*
# missing symbol.
#
# Note also that with CONFIG_PCIEASPM=n the `pcie_aspm=off` kernel command-line
# parameter does not exist -- the __setup() that registers it lives inside the
# #ifdef in drivers/pci/pcie/aspm.c. The usual field workaround is a no-op on a
# FOS kernel, so this cannot be left to a kernel argument.
#
# The -b mode is the one that actually proves anything, because it inspects the
# config Kconfig produced rather than the one we wrote -- `make oldconfig`
# silently drops symbols whose dependencies are unmet (the ADR-0010 trap).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."

checkBuilt=0
[[ ${1:-} == -b ]] && checkBuilt=1

# PCIEASPM gives the kernel the ASPM code at all, so that a driver calling
# pci_disable_link_state() gets a real answer instead of a stub's lie.
# PCIEPORTBUS is what binds the PCIe port service driver ASPM works through.
REQUIRED_ALL=(
    CONFIG_PCIEASPM=y
    CONFIG_PCIEPORTBUS=y
)

# PCI_MMCONFIG is x86-only (arch/x86/Kconfig); arm64 reaches extended config
# space through its own ECAM host controller and has no such symbol. Without it
# on x86, pci_ext_cfg_avail() returns 0, every device's cfg_size is capped at
# 256 bytes, and the L1 PM Substates extended capability -- which is where L1.1
# and L1.2 are actually controlled -- becomes invisible to the ASPM core.
REQUIRED_X86=(
    CONFIG_PCI_MMCONFIG=y
)

# Exactly one ASPM policy must be selected. DEFAULT keeps the firmware's link
# settings and lets each driver make its own chip-specific call, which is what
# r8169 does via rtl_aspm_is_safe(). PERFORMANCE would disable ASPM on every
# link regardless of driver; it is a legitimate alternative for an imaging init
# and is discussed in the ADR, so accept either rather than pinning one here.
POLICY_OK=(
    CONFIG_PCIEASPM_DEFAULT=y
    CONFIG_PCIEASPM_PERFORMANCE=y
)

# Power-saving policies actively enable ASPM on links whose firmware left it
# off. On a short-lived, mains-powered imaging init there is nothing to gain
# and a repeat of this bug to lose.
FORBIDDEN=(
    CONFIG_PCIEASPM_POWERSAVE=y
    CONFIG_PCIEASPM_POWER_SUPERSAVE=y
)

fails=0
checked=0

checkConfig() {
    local label="$1" file="$2" arch="$3" sym hits
    [[ -f $file ]] || return 0
    checked=$((checked + 1))
    for sym in "${REQUIRED_ALL[@]}"; do
        if ! grep -qxF "$sym" "$file"; then
            echo "FAIL [$label] missing: $sym"
            fails=$((fails + 1))
        fi
    done
    if [[ $arch != arm64 ]]; then
        for sym in "${REQUIRED_X86[@]}"; do
            if ! grep -qxF "$sym" "$file"; then
                echo "FAIL [$label] missing: $sym"
                fails=$((fails + 1))
            fi
        done
    fi
    for sym in "${FORBIDDEN[@]}"; do
        if grep -qxF "$sym" "$file"; then
            echo "FAIL [$label] must not be set: $sym"
            fails=$((fails + 1))
        fi
    done
    hits=0
    for sym in "${POLICY_OK[@]}"; do
        grep -qxF "$sym" "$file" && hits=$((hits + 1))
    done
    if [[ $hits -ne 1 ]]; then
        echo "FAIL [$label] expected exactly one of ${POLICY_OK[*]}, found $hits"
        fails=$((fails + 1))
    fi
    echo "  checked $label"
}

for arch in x64 x86 arm64; do
    checkConfig "configs/kernel${arch}.config" \
                "$REPO/configs/kernel${arch}.config" "$arch"
done

if [[ $checkBuilt -eq 1 ]]; then
    built=0
    for arch in x64 x86 arm64; do
        f="$REPO/kernelsource${arch}/.config"
        if [[ -f $f ]]; then
            built=1
            checkConfig "kernelsource${arch}/.config (post-oldconfig)" "$f" "$arch"
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
    echo "PASS: $checked config(s) can control PCIe ASPM"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
