#!/bin/bash
#
# Assertion harness for the arm64 kernel's platform support -- Broadcom /
# Raspberry Pi, and the generic arm64 symbols a non-Pi board needs.
#
#   tests/checks/arm64-platform-config.sh        # check the committed config
#   tests/checks/arm64-platform-config.sh -b     # also check post-oldconfig
#                                                # kernelsourcearm64/.config
#
# Why this exists. configs/kernelarm64.config was added in 2018 by a
# contributor who said outright they could not test it, and every kernel bump
# since has carried it forward through `make oldconfig`. That preserves
# whatever was there and adds nothing, so the config still described no ARM
# platform at all: no CONFIG_ARCH_BCM, no PL011 UART, no generic ECAM host
# bridge, and no ACPI. It could not boot a Raspberry Pi, and with neither ACPI
# nor PL011 it could not usefully boot an arm64 server or a QEMU virt guest
# either. See docs/adr/0015-arm64-platform-support.md.
#
# What makes this worth a harness rather than a comment is that the failure is
# silent in both directions. Kconfig DROPS a symbol whose dependency is unmet
# rather than complaining -- CONFIG_SERIAL_8250_BCM2835AUX vanishes without
# CONFIG_SERIAL_8250_SHARE_IRQ, and CONFIG_DMA_BCM2835 vanishes without
# CONFIG_DMADEVICES, both of which happened on the first pass here. And at the
# other end a missing driver produces no error either: the Pi just stops, the
# way it did for the forum report that started this (topic 18229).
#
# The -b mode is the one that actually proves anything, because it inspects the
# config Kconfig produced rather than the one we wrote (the ADR-0010 trap).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."

checkBuilt=0
[[ ${1:-} == -b ]] && checkBuilt=1

# ARCH_BCM2835 is the umbrella for BCM2837/2711/2712 -- Pi 3, Pi 4/400/CM4 and
# Pi 5. Nothing below is even offered by Kconfig without it.
REQUIRED=(
    CONFIG_ARCH_BCM=y
    CONFIG_ARCH_BCM2835=y

    # Generic arm64. ACPI is how an SBSA server describes itself, ECAM is how
    # PCI is reached on QEMU virt and most boards, and PL011 is the UART on
    # nearly every arm64 platform including the Pi's primary port.
    CONFIG_ACPI=y
    CONFIG_PCI_HOST_GENERIC=y
    CONFIG_SERIAL_AMBA_PL011=y
    CONFIG_SERIAL_AMBA_PL011_CONSOLE=y

    # The Pi's mini-UART, which is where console=serial0 lands by default.
    # SHARE_IRQ and EXTENDED are its dependencies and are listed because
    # dropping either takes BCM2835AUX with it, without a word.
    CONFIG_SERIAL_8250_EXTENDED=y
    CONFIG_SERIAL_8250_SHARE_IRQ=y
    CONFIG_SERIAL_8250_BCM2835AUX=y

    # The VideoCore firmware chain. Clocks and power domains on a Pi are owned
    # by the firmware and reached over the mailbox, so without these the SoC
    # comes up unclocked and nothing downstream probes.
    CONFIG_MAILBOX=y
    CONFIG_BCM2835_MBOX=y
    CONFIG_RASPBERRYPI_FIRMWARE=y
    CONFIG_CLK_RASPBERRYPI=y
    CONFIG_RASPBERRYPI_POWER=y
    CONFIG_PINCTRL_BCM2835=y

    # The SD card is the thing being imaged. SDHOST (MMC_BCM2835) drives it
    # over DMA, hence DMADEVICES.
    CONFIG_MMC_SDHCI_IPROC=y
    CONFIG_MMC_BCM2835=y
    CONFIG_DMADEVICES=y
    CONFIG_DMA_BCM2835=y

    # NICs, in model order: genet is Pi 3B+/4 onboard, lan78xx and smsc95xx
    # are the USB-attached ones on earlier boards, macb is RP1's
    # "raspberrypi,rp1-gem" on the Pi 5.
    CONFIG_BCMGENET=y
    CONFIG_MDIO_BCM_UNIMAC=y
    CONFIG_USB_LAN78XX=y
    CONFIG_USB_NET_SMSC95XX=y
    CONFIG_MACB=y

    # Pi 4 puts its xHCI behind this bridge and Pi 5 puts everything behind it.
    CONFIG_PCIE_BRCMSTB=y
    CONFIG_USB_DWC2=y
    CONFIG_USB_DWC2_HOST=y

    # FOS reboots at the end of every task and on a Pi that goes through the
    # SoC watchdog. Without it a client finishes its job and then sits there,
    # which reads to the operator as a hang in the imaging code.
    CONFIG_WATCHDOG=y
    CONFIG_BCM2835_WDT=y

    # Pi 5 / RP1. The southbridge publishes its children through a devicetree
    # overlay applied at runtime once the PCIe endpoint is up, which is why
    # OF_OVERLAY and PCI_DYNAMIC_OF_NODES appear here and nowhere else.
    CONFIG_OF_OVERLAY=y
    CONFIG_PCI_DYNAMIC_OF_NODES=y
    CONFIG_MISC_RP1=y
    CONFIG_COMMON_CLK_RP1=y
    CONFIG_PINCTRL_RP1=y

    # Display. Everywhere else FOS builds without DRM and leans on a
    # framebuffer the firmware set up -- FB_EFI/FB_VESA off EFI GOP on a PC.
    # That does not survive on a Pi: our own bcm2711-rpi-4-b.dtb carries
    # brcm,bcm2711-hdmi0/1 but no simple-framebuffer node, and the node the
    # VideoCore firmware would otherwise inject is suppressed the moment
    # config.txt enables the vc4-kms-v3d overlay -- which current Raspberry Pi
    # OS ships enabled. The result is a board with no console at all, which is
    # indistinguishable from an early hang and is exactly how forums topic
    # 18229 presented. See docs/adr/0017-arm64-display-vc4.md.
    #
    # DRM_VC4 depends on SND && SND_SOC (HDMI audio is integral to the driver)
    # and on PM. Miss any one and Kconfig drops DRM_VC4 without a word, so they
    # are listed here for the same reason SHARE_IRQ is listed above -- both
    # were dropped exactly this way while writing the change.
    #
    # DRM_V3D is deliberately absent: it is the 3D accelerator and buys a
    # console nothing.
    CONFIG_DRM=y
    CONFIG_DRM_VC4=y
    CONFIG_DRM_FBDEV_EMULATION=y
    CONFIG_FRAMEBUFFER_CONSOLE=y
    CONFIG_PM=y
    CONFIG_SND=y
    CONFIG_SND_SOC=y
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
    echo "  checked $label"
}

checkConfig "configs/kernelarm64.config" "$REPO/configs/kernelarm64.config"

# A device tree is not optional on a board with no EFI/ACPI, so the arm64
# build has to produce one. Asserted against build.sh rather than a config
# because it is a make target, and it is asserted here rather than in a
# build harness of its own because "can this boot a Pi" is one question.
if ! grep -qE 'arch == arm64 \]\] && ktarget=.*\bdtbs\b' "$REPO/build.sh"; then
    echo "FAIL [build.sh] arm64 kernel target does not build dtbs"
    fails=$((fails + 1))
else
    echo "  checked build.sh arm64 dtbs target"
fi

if [[ $checkBuilt -eq 1 ]]; then
    f="$REPO/kernelsourcearm64/.config"
    if [[ -f $f ]]; then
        checkConfig "kernelsourcearm64/.config (post-oldconfig)" "$f"
    else
        echo
        echo "NOTE: -b given but no kernelsourcearm64/.config found -- nothing"
        echo "      post-oldconfig was checked. Build first, then re-run."
    fi
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: $checked config(s) carry arm64 platform support"
    exit 0
fi
echo "FAILED: $fails problem(s) across $checked config(s)"
exit 1
