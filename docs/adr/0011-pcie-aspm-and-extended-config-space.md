# 0011 — The kernel must be able to control PCIe ASPM

## Status

Implemented in the kernel configs; **awaiting hardware validation** on the
reporter's Dell OptiPlex 3070 (RTL8168h rev 15) before release.

Reported as slow UEFI imaging (~1.2 GB/min against 6–10 GB/min on the same
machine booted legacy/BIOS) on the FOG forums, topic 18212. The same hardware
and the same symptoms are Debian bug #1110193, filed July 2025.

## Context

FOS turned off two kernel symbols in 2016 (commit `b56b8d9`) that are
`default y` upstream:

```
# CONFIG_PCI_MMCONFIG is not set     (x64 only; x86 kept it =y)
# CONFIG_PCIEASPM is not set         (all three arches)
```

Nothing noticed for nine years, because the out-of-tree Realtek vendor drivers
(`r8168`, `r8125`, `r8126`) did their own ASPM management and never asked the
PCI core for anything. The `r8168` driver in particular is built here with
`-DCONFIG_DYNAMIC_ASPM`: it counts in-flight packets and calls
`rtl8168_hw_aspm_clkreq_enable(tp, false)` whenever traffic crosses a
threshold, so ASPM was effectively switched off for the entire duration of an
image regardless of what the kernel did or did not support.

Commit `bc9ee24` ("Switch x64/arm64 kernels to in-kernel r8169…", ADR-less,
refs FOGProject/fos#108) dropped the vendor drivers in favour of the in-kernel
`r8169`. That was the right call for the MAC-brick bug it fixed, but it removed
the cover that had been hiding the missing symbols.

### Why the missing symbols are worse than "a feature is absent"

`r8169` does not manage ASPM itself. It asks the PCI core to, once, at probe:

```c
/* Disable ASPM L1 as that cause random device stop working
 * problems as well as full system hangs for some PCIe devices users.
 */
if (rtl_aspm_is_safe(tp)) {
        dev_info(&pdev->dev, "System vendor flags ASPM as safe\n");
        rc = 0;
} else {
        rc = pci_disable_link_state(pdev, PCIE_LINK_STATE_L1);
}
tp->aspm_manageable = !rc;
```

With `CONFIG_PCIEASPM=n`, `pci_disable_link_state()` is an inline stub in
`include/linux/pci.h` that **returns 0** — success. So `rc == 0`, and
`tp->aspm_manageable` is set to *true*: the driver concludes the OS is managing
ASPM and that L1 has been disabled, when in fact the kernel contains no ASPM
code at all and nothing was disabled.

`rtl_hw_start()` then acts on that belief on every link-up:

```c
rtl_enable_exit_l1(tp);
rtl_hw_aspm_clkreq_enable(tp, true);
```

and inside that function, gated on `tp->aspm_manageable`, the driver sets
`ASPM_en` in Config5, `ClkReqEn` in Config2, and — for exactly the reporter's
chip generation, `RTL_GIGA_MAC_VER_46` (RTL8168h/8111h), which is the first arm
of the `VER_46 ... VER_48` case — writes:

```c
/* chip can trigger L1.2 */
r8168_mac_ocp_modify(tp, 0xe092, 0x00ff, BIT(2));
```

The net effect is that the NIC is actively told to use ASPM and to trigger
L1.2, by a driver that thinks the OS has L1 disabled, on a kernel that cannot
touch ASPM at all. Nothing is logged.

The second symbol compounds it. On x86, `pci_ext_cfg_avail()` returns non-zero
only if `raw_pci_ext_ops` is set, and only `CONFIG_PCI_MMCONFIG` sets it. With
it off, every device's `cfg_size` is capped at 256 bytes, so the **L1 PM
Substates extended capability — the register block where L1.1 and L1.2 are
actually controlled — is unreachable**. Even a kernel that could disable plain
L1 could not clear the substates. This is also the origin of the one message
the reporter did see:

```
r8169: No native access to PCI extended config space, falling back to CSI
```

which comes from `rtl_csi_mod()` and is really reporting the missing
`PCI_MMCONFIG`, not an ASPM problem per se. The CSI fallback itself works.

### Why UEFI and legacy differ on the same machine

ASPM is negotiated by both ends of a link and is programmed by platform
firmware at init. The Dell firmware's native UEFI path enables L1/L1.1/L1.2 on
the root port; the CSM/legacy path leaves them off. Because the kernel has no
ASPM code and cannot see the L1SS capability, whatever the firmware chose
simply *persists* for the life of the imaging run. Legacy boot was never fast
because legacy is better — it was fast because the firmware happened to leave
ASPM off.

This also explains the direction of the loss. Deploy (server → client) is
client-**receive**: the link goes idle between server bursts, drops into L1.2,
and pays a multi-tens-of-microseconds exit latency on every wake. Capture
(client → server) is client-**transmit**, host-driven and keeps the link busy,
which is why the reporter's uploads still ran at ~15 GB/min.

### The workaround that does not work

The standard field advice for this class of bug is `pcie_aspm=off` on the
kernel command line. On a FOS kernel that is a **no-op**: the `__setup()` that
registers the parameter lives inside the `#ifdef CONFIG_PCIEASPM` in
`drivers/pci/pcie/aspm.c` (the file is compiled, but essentially all of it is
inside that guard). The parameter is silently ignored. This had to be fixed in
the config; it could not be left to a kernel argument.

## Decision

Enable, on all three arches:

```
CONFIG_PCIEASPM=y
CONFIG_PCIEASPM_DEFAULT=y
```

and additionally on x64 (x86 already had it, arm64 has no such symbol and
reaches extended config space through its own ECAM host controller):

```
CONFIG_PCI_MMCONFIG=y
```

Both are needed, and neither is sufficient alone: `PCIEASPM` without
`PCI_MMCONFIG` can disable plain L1 via the standard capability but cannot see
L1SS to clear the substates; `PCI_MMCONFIG` without `PCIEASPM` makes the
registers reachable but leaves no code to act on them and leaves the stub still
lying to `r8169`.

**Policy is `DEFAULT`, not `PERFORMANCE`.** `DEFAULT` keeps the firmware's link
settings and gives each driver a working `pci_disable_link_state()` to make its
own chip-specific call — which is precisely what `r8169` does, including
honouring `rtl_aspm_is_safe()` for boards whose vendor has certified ASPM 1.2
as safe (OCP `0xc0b2`). `PERFORMANCE` would disable ASPM on every link on every
machine regardless of driver. That is a defensible choice for a short-lived,
mains-powered imaging init and is the obvious escalation if other NICs turn out
to have the same problem, but it is a larger behavioural change across the
whole fleet to fix a bug that the smaller one fixes, so it is not the default
today.

The power-saving policies (`POWERSAVE`, `POWER_SUPERSAVE`) are forbidden by
`tests/checks/pcie-aspm-config.sh`. They *enable* ASPM on links whose firmware
left it off, which on an imaging init is all cost and no benefit — and would
have made this bug appear on legacy boots too.

## Consequences

- Deploys onto RTL8168h and its relatives should return to line rate under
  UEFI. **This is the claim that needs validating on real hardware**; it is
  derived from source, not yet measured.
- The `falling back to CSI` notice disappears, and `r8169` uses native ECAM for
  its `0x070f` (ASPM entry latency) and `0x0890` (ZRXDC timeout) writes.
- Other drivers that call `pci_disable_link_state()` — several NIC and NVMe
  drivers do — get a real answer instead of a stub's lie for the first time on
  FOS. This is a fleet-wide behavioural change and the main reason to watch the
  first release carrying it.
- Extended config space becoming visible means AER/L1SS/other extended
  capabilities are now parsed at enumeration. `CONFIG_PCIEAER` stays off, so
  this is visibility only, not new error handling.
- Kernel size grows marginally (ASPM core plus MMCONFIG arch code).

## Validating on hardware

Read-only, no rebuild required, and it confirms or kills the whole theory in
about a minute. Boot the affected machine to a FOS shell (FOG debug mode);
`pciutils` and `ethtool` are both in the init. With `NN:NN.N` the Realtek
function from `lspci -nn | grep -i ethernet`, and its upstream root port from
`lspci -t`:

```sh
setpci -s <nic>  CAP_EXP+10.w     # Link Control; bits 1:0 = ASPM Control
setpci -s <port> CAP_EXP+10.w     # 0=disabled, 1=L0s, 2=L1, 3=L0s+L1
```

Do this once booted UEFI and once booted legacy on the same machine. The
prediction is that UEFI reads back `2` or `3` and legacy reads back `0`. That
alone confirms the mechanism, because it is the only difference the kernel is
currently unable to correct.

To prove the fix without a rebuild, clear ASPM control on both ends of the link
and re-run the deploy. Two details are load-bearing: the write is **masked to
bits 1:0** (`0000:0003`), because a bare `=0000` would also clear Common Clock
Configuration, Clock PM and Extended Sync in the same register — clearing CCC
on a live link without a retrain is its own bug — and the **endpoint is cleared
before the root port**, per PCIe r6.2 sec 7.5.3.7 ("when disabling ASPM L1,
software must disable it in the Downstream component prior to disabling it in
the Upstream component"), which is the same order `pcie_config_aspm_link()`
uses:

```sh
setpci -s <nic>  CAP_EXP+10.w=0000:0003
setpci -s <port> CAP_EXP+10.w=0000:0003
```

Throughput returning to 6–10 GB/min is the proof. Note this is a
before/after-within-one-boot test, not a fix — `Link Control` lives in standard
config space, so it works even on today's kernel, which is what makes it a
usable diagnostic.

## References

- FOG forums topic 18212 — original report, Dell OptiPlex 3070, RTL8168h rev 15
- Debian bug #1110193 — same chip, same symptoms, worked around by switching
  off `r8169`
- `bc9ee24` — the r8169 switch that exposed this; `b56b8d9` (2016) — where the
  symbols were turned off
- ADR-0010 — the `make oldconfig` silent-drop trap, and why the check harness
  inspects the post-`oldconfig` `.config`
