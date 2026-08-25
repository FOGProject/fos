# 0015 — Wi-Fi imaging is feasible; Wi-Fi PXE boot is the firmware's to give

## Status

Proposed. Research recorded, no work started. This ADR answers a question that
has been asked and re-answered verbally for years without ever being written
down, and it splits into two halves with opposite answers — one of which is
not FOG's to fix at all. Nothing here has been built or booted.

## Context

"Can FOG image over Wi-Fi, out of the box?" is a recurring request: laptops
that ship with no Ethernet port, fleets that have no wired drop at the bench,
and the specific case of registering a large batch of Wi-Fi-only machines
before imaging them by some other means. The answer given each time is an
ad-hoc "not supported, use a USB-Ethernet dongle", occasionally accompanied by
a one-off debug kernel built by hand to find out which firmware a particular
card wanted.

None of that reasoning lives in either repository. Before this ADR,
`grep -rinE 'wifi|wlan|wireless|80211|ssid'` over this repo returned exactly
one hit — an incidental string inside the out-of-tree `r8168` vendor driver —
and over FOGProject/fogproject, two Font Awesome `fa-wifi` icons in the
subnetgroup plugin. The recurring answer is also incomplete: part of the
request is genuinely achievable and part of it genuinely is not, and saying
"not supported" flattens the difference.

The question has to be split before it can be answered:

- **Part A — Wi-Fi *network boot*.** Firmware → iPXE → `bzImage` + `init.xz`,
  over the air, with no wire involved.
- **Part B — Wi-Fi *imaging*.** Once a kernel and init are running, FOS
  associates to a wireless network and moves the image over it.

These are independent. Part B does not require Part A — a USB stick, a
USB-Ethernet dongle for the boot only, or firmware-native Wi-Fi boot all get
you to a running FOS.

## Findings

**1. iPXE has no wireless driver for any hardware built in the last fifteen
years, and is not going to.** Upstream's entire 802.11 driver set is `ath5k`,
`ath9k`, `rtl8180`, `rtl8185`, `prism2_plx` and `prism2_pci`. On the AX211
request (ipxe/ipxe#959) the maintainers were explicit about why that will not
change: iPXE drivers are "written from scratch in C based on hardware
reference manuals", sometimes under NDA, and "most wifi nics do require binary
blobs, so that makes them unlikely to get any support." Their own
recommendation is a USB NIC or phone tethering.

FOG's build has it switched off regardless. `IWMGMT_CMD` — the `iwstat`/
`iwlist` commands, i.e. the only way to script an association — is commented
out in both `fog-ipxe/src/config/general.h:141` and
`src-efi/config/general.h:106`. `CRYPTO_80211_WPA` and `CRYPTO_80211_WPA2` are
`#define`d (`general.h:368-370`) but are inert without the 802.11 core beneath
them. The build output confirms it rather than merely implying it: the linked-
object baselines in `fog-ipxe/tools/linked-objects/*.txt` contain zero
`net80211`, `sec80211`, `ath*` or `rtl*wifi` objects. The `eap.o`, `eap_md5.o`
and `eapol.o` that *are* linked are **wired** 802.1X, not Wi-Fi — an easy
misread. `tools/check-linked-objects.sh` fails CI on any change to that set,
so this is a deliberate, guarded baseline.

**2. The only working wireless first stage is the platform firmware's own, and
FOG already supports it by doing nothing.** Where the firmware implements
UEFI Wi-Fi — Lenovo's `UEFI WI-FI Network Boot` (WMI name `WiFiNetworkBoot`,
default **off**, and documented as requiring Secure Boot to be enabled), Dell's
HTTPS Boot (documented for wired *and* wireless), some HP models — it brings
the radio up itself and presents an ordinary UEFI Simple Network Protocol.
FOG's existing `snponly.efi`/`snp.efi` ride on that **unmodified**. There is no
FOG-side code to write.

What it costs instead is per-machine setup: the SSID (and any credential) typed
into firmware setup or pushed by vendor WMI tooling, Secure Boot on — which
entangles this with ADR 0009/0010/0012 — and hardware that happens to implement
the feature at all. So Part A's FOG-side work is a documented, verified recipe,
not code.

**3. FOS has no wireless stack whatsoever, in any arch.** Kernel:
`# CONFIG_WIRELESS is not set`, `# CONFIG_RFKILL is not set`,
`# CONFIG_WLAN is not set` (`configs/kernelx64.config:1044,1045,2070`, and the
x86/arm64 equivalents). Because `CONFIG_WIRELESS=n`, Kconfig elides the
entire subtree — `CFG80211`, `MAC80211` and `LIB80211` do not appear in the
config files at all, which makes their absence easy to misread as "not yet
reviewed" rather than "off".

Userspace, all three Buildroot configs:
`# BR2_PACKAGE_WPA_SUPPLICANT is not set` (`fsx64.config:2525`),
`# BR2_PACKAGE_IW is not set` (:2352),
`# BR2_PACKAGE_WIRELESS_REGDB is not set` (:2522),
`# BR2_PACKAGE_WIRELESS_TOOLS is not set` (:2523),
`# BR2_PACKAGE_RFKILL is not set` (:3965), and
`# BR2_PACKAGE_LIBNL is not set` (:1860) — that last one matters, because
`wpa_supplicant`'s `nl80211` driver depends on it, so enabling the supplicant
pulls in a new library rather than just a binary.

**4. `CONFIG_MODULES=n` means every driver is built in, and that decides the
firmware question — which is open.** `# CONFIG_MODULES is not set`
(`kernelx64.config:781`, x86:759, arm64:679). There is no `modprobe` escape
hatch: each supported chipset is `=y` in the single `bzImage`.

FOS ships firmware *inside the kernel* today —
`CONFIG_EXTRA_FIRMWARE="bnx2x/… tigon/… rtl_nic/*.fw"` with
`CONFIG_EXTRA_FIRMWARE_DIR="linux-firmware"` (`kernelx64.config:1155-1169`) —
and `build.sh:378-390` already clones the whole `linux-firmware` tree onto the
build host, so naming another blob is a one-line config edit. Meanwhile
`/lib/firmware` in the rootfs is empty (`# BR2_PACKAGE_LINUX_FIRMWARE is not
set`, `fsx64.config:929`; no `lib/firmware` anywhere under `rootfs_overlay/`),
and `# CONFIG_FW_LOADER_USER_HELPER_FALLBACK is not set`.

The trap: FOS boots a **classic initrd on a ramdisk block device, not an
initramfs** — `root=/dev/ram0 rw ramdisk_size=275000 rootfstype=ext4`
(`create-usb-image.sh:134`; the server builds the same shape at
`bootmenu.class.php:462-481`). An initramfs is unpacked by a `rootfs_initcall`
and is therefore visible to a built-in driver probing at `device_initcall`; a
ramdisk root mounted afterward is not. So the ordinary Buildroot route —
`BR2_PACKAGE_LINUX_FIRMWARE_*` populating `/lib/firmware` — **cannot be assumed
to work here and must be settled by a real build before anyone designs around
it.** `CONFIG_EXTRA_FIRMWARE` is the mechanism already proven in this tree, and
is the one to reach for first.

**5. Three size ceilings, and firmware is what threatens all of them.**
`BR2_TARGET_ROOTFS_EXT2_SIZE="256M"` is a hard build-time ceiling on the
uncompressed init; exceeding it fails the build outright. The ramdisk is sized
to match (`ramdisk_size=275000`, driven server-side by
`FOG_KERNEL_RAMDISK_SIZE`), so raising it is a two-repo change, and the
uncompressed size is charged to the RAM of every machine that images.
`create-usb-image.sh:27-28` builds a **128 MB** FAT image holding `bzImage` +
`init.xz` + memdisk/memtest/iPXE — the tightest concrete number in the repo,
and it constrains the `CONFIG_EXTRA_FIRMWARE` route as well, since that route
grows `bzImage` (which is also what gets signed for Secure Boot). Broad
`linux-firmware` coverage is hundreds of megabytes and is not an option by
either route; a curated per-chipset list is mandatory, and its size cost has to
be measured, not estimated.

**6. One loop in `S40network` makes a wireless NIC useless even if everything
above were solved.** The carrier poll at `etc/init.d/S40network:39-44` waits up
to 35 seconds on `/sys/class/net/$iface/carrier` and `continue`s past the
interface if it never reads 1. An unassociated wlan interface never will. The
interface *enumeration* just above (:28-29) is fine — it filters on
`link/ether`, which `wlan0` does present — so the failure is specifically the
carrier gate, not discovery.

The success test that follows must be **kept**, not replaced by an association
check. `S40network:48-54` requires both `udhcpc` and
`curl -Ikfso /dev/null "${web}"/index.php` to succeed, and the comment there
already argues why: "the link to web is kind of important, just exiting on dhcp
request is not sufficient." That is even more true over the air, where
association and DHCP can both succeed onto a network that cannot reach the FOG
server.

**7. The network model — not the FOS code — decides whether there is a
credential-bootstrap problem at all.** On a WPA2/3-PSK network, Wi-Fi
credentials are needed *before* the first network round-trip, which places them
in precisely the class ADR 0011 carved out for `web=`: "a runtime checkin
cannot supply the address of the server it needs to reach to perform that
checkin." The extended-checkin redesign ADR 0011 recommends for `mode=`/`type=`
/image-id cannot carry them either, for the identical reason.

On an **open (or OWE) imaging SSID with a MAC ACL**, that problem largely
evaporates: the only thing FOS needs before its first round-trip is the SSID
*name*, which is deployment-wide, not a secret, and fine as a global setting on
the kernel command line. No per-host encrypted column, no dependency on ADR
0011's unresolved `web=` spike.

Four things about that model are worth stating so they are not rediscovered:

- **Hiding the SSID buys nothing and costs reliability.** A hidden network is
  revealed by the client's own probe requests and by any association; meanwhile
  it forces active probing, which is worse on 5 GHz DFS channels where passive
  scanning is mandated. Broadcast it.
- **A MAC ACL is weak authentication, but it is not *newly* weak here.** FOG's
  boot chain is already MAC-identified and unauthenticated —
  `HostManager::getHostByMacAddresses()` matches any non-pending MAC, and
  sysuuid-based resolution is deliberately commented out in
  `fogbase.class.php:540-567`. This does not lower the bar below wired PXE,
  *provided* it is a segregated imaging SSID/VLAN rather than the corporate
  network.
- **Open air is genuinely worse than open wire**, and this is the one place the
  wireless path is less safe than the wired one it mirrors. Cleartext PXE on a
  switch requires physical access; over the air, anyone in range can capture
  entire disk images and whatever is inside them. **OWE / WPA3-Enhanced Open**
  is the fix that preserves the zero-credential property — unauthenticated
  encryption, nothing to distribute. It costs keeping `wpa_supplicant`
  (plus `libnl`, plus the WPA3 option) in the init rather than getting by with
  bare `iw`; that is a small price and it should be paid.
- **A MAC ACL inverts badly for first touch.** The ACL needs the wireless MAC
  before the machine can reach FOG, but registration is how FOG learns MACs. The
  model therefore fits **re-imaging known hosts** well and **first-time
  registration** poorly — which is exactly the case that generates the requests.
  It needs a pre-populated ACL from an asset list, or a time-boxed open
  registration window.

The expedient PSK channel — `wifissid=`/`wifipsk=` through the existing
`+_+`-encoded cmdline parser, carried by per-host `hostKernelArgs` or global
`FOG_KERNEL_ARGS` — works today with zero server change and is the right way to
*prototype*. It is not shippable as a design: the PSK travels in the `boot.php`
response (plaintext unless `httpproto` is `https`), sits world-readable in
`/proc/cmdline` for anything running in the init, and is `eval`'d unquoted at
`S40network:17` and `funcs.sh:12`, so a passphrase containing shell
metacharacters is a command injection.

**8. Host identity needs no schema change.**
`HostManager::getHostByMacAddresses()` (`hostmanager.class.php:192-253`)
resolves a host from *any* of its non-pending MACs, and the `hostMAC`
association table (`macaddressassociation.class.php:35-44`) already carries N
MACs per host with `hmPrimary` and `hmIgnoreImaging` flags. Registering the
wireless MAC as an additional MAC is the entire answer. `setmacto=` is likewise
already wired end to end (`bootmenu.class.php:224,466` → `S40network:56-67`).

**9. Multicast over 802.11 is a non-starter, and should be refused rather than
allowed to fail slowly.** udpcast's rendezvous
(`multicasttask.class.php:688-745`: `--min-receivers`, `--max-wait`,
`--rexmit-hello-interval`) assumes a reliable-ish L2. 802.11 multicast is sent
unacknowledged at the basic rate and is commonly filtered or unicast-converted
by APs. Unicast NFS is the only viable transport, and even that is tuned for a
switch: `bin/fog.mount` uses `nolock,proto=tcp,rsize=32768,wsize=32768,intr,
noatime` with no `vers=`, `timeo=`, `retrans=` or `soft`.

## Decision

**Part A: no.** FOG will not pursue wireless network boot inside its own stack.
The driver situation in iPXE is not a gap FOG can close, and the guarded
linked-object baseline says so in the build. FOG's contribution is instead a
documented, verified recipe for firmware-native UEFI Wi-Fi boot — which needs
no code — plus the two fallbacks that work today: USB-stick boot via
`create-usb-image.sh`, and a USB-Ethernet adapter for the boot only.

**Part B: yes, feasible, in phases, and unsupported until it has actually been
built and measured.**

- **Phase 0 (this ADR).** Record the analysis. Follow-up: FOGProject/fog-docs
  `docs/kb/reference/hardware.md:31-32` currently says only "Wireless is not
  used for imaging"; it should name the firmware-boot path and the two
  fallbacks, and link here.
- **Phase 1 — spike, explicitly unsupported.** One chipset family on an
  experimental branch. Intel `iwlwifi`/`iwlmvm` is the highest-value pick: AX2xx
  is what ships in the Ethernet-less laptops that generate these requests.
  Kernel: `CONFIG_WIRELESS`, `CFG80211`, `MAC80211`, `RFKILL`, `WLAN` and the
  driver `=y`; firmware via `CONFIG_EXTRA_FIRMWARE` per Finding 4. Buildroot:
  `WPA_SUPPLICANT` (`_NL80211`, `_CLI`, `_PASSPHRASE`, `_WPA3`), `LIBNL`, `IW`,
  `WIRELESS_REGDB`, `RFKILL`. `S40network`: a wireless branch **ahead of** the
  carrier gate — detect `/sys/class/net/$iface/phy80211`, rfkill-unblock, write
  a supplicant config, start `wpa_supplicant -B -Dnl80211`, poll `wpa_cli
  status` for `COMPLETED`, then fall through to the existing udhcpc + `curl`
  probe unchanged. `K40network` gains a `wpa_cli terminate`. Network model: an
  open/OWE MAC-ACL'd imaging SSID, so the only input is a broadcast SSID name.
  Deliverables are measurements, not opinions: does it associate, does it image,
  what throughput, and what did `init.xz` and `bzImage` actually grow by.
- **Phase 2 — decide whether PSK is in scope at all.** Only sites unwilling to
  stand up a separate open/OWE SSID need it, and only that path is blocked on
  ADR 0011's `web=` spike. A v1 can ship without it. Decide deliberately rather
  than by default, and do not build a second bootstrap channel — if PSK is in
  scope, it rides whatever ADR 0011 settles on.
- **Phase 3 — productionize.** Widen the chipset matrix against measured size
  cost. Add `tests/checks/wireless-config.sh` modelled on
  `pcie-aspm-config.sh`/`secureboot-config.sh`, **including the `-b`
  post-`oldconfig` mode** — ADR 0010's trap applies directly here, since
  `CONFIG_WIRELESS`/`CFG80211`/`MAC80211` have real dependency chains and
  `make oldconfig` silently drops symbols whose dependencies are unmet. Refuse
  multicast on a wireless interface, per the ADR-0003 fail-loud principle and
  the ADR-0007 precedent of refusing multicast for LVM images. Tune the NFS
  mount options. On the server side, a global Wi-Fi SSID setting is a one-line
  `INSERT IGNORE INTO globalSettings` migration with no PHP change, since the
  settings page renders plain settings automatically; per-host columns are
  needed only if Phase 2 puts PSK in scope, following the `hostSecTokenPrev`
  guarded-migration template and the `hostADPass` encryption precedent.

## What this does not resolve

- **Which firmware mechanism actually works** (Finding 4). Nothing should be
  designed around `/lib/firmware` in the rootfs until a real build has proven
  a built-in driver can load from it across the ramdisk-root boundary.
- **The size budget.** Whether a useful chipset matrix fits under the 256 M
  ext2 ceiling and the 128 MB USB FAT image is an empirical question that
  Phase 1 answers and this ADR does not.
- **PSK credential delivery**, which stays in ADR 0011's `web=` class and
  inherits that ADR's unresolved spike.
- **First-touch registration under a MAC ACL** (Finding 7) — an operational
  problem with no FOG-side answer, and the one that most directly affects the
  people asking.
- **WPA2/3-Enterprise (802.1X with per-machine certificates)**, out of scope
  entirely.
- **Nothing has been built or booted.** Per the precedent ADR 0003, 0010 and
  0011 all set, this conclusion is not de-risked until a real build associates
  and images a machine end to end.

## Consequences

- Replaces a recurring verbal "not supported" with a cited answer that
  distinguishes the achievable half from the unachievable one, and gives people
  asking about Ethernet-less laptops three things that work today (firmware
  Wi-Fi boot, USB stick, USB NIC) instead of one dismissal.
- Commits FOG to *not* chasing wireless support in iPXE, which is a real
  decision and should stop the question being reopened without new evidence.
- Supporting Wi-Fi imaging means owning a wireless chipset support matrix — an
  ongoing maintenance cost of a kind this repo does not currently carry for any
  device class, and one that competes directly with the init and kernel size
  budgets.
- Being *supported* is not the same as being *advised*. The shared-medium
  objection made on the forums is correct: Wi-Fi imaging will be slower than
  wired and can degrade the wireless network for everyone else. Any
  documentation of this feature has to keep saying so.

## References

- ADR 0011 (`0011-unified-kernel-image-feasibility.md`) — the boot-time config
  channel, and why `web=`-class data cannot come from the runtime checkin.
- ADR 0010 (`0010-secure-boot-kernel-hardening.md`) — the `make oldconfig`
  silently-drops-unmet-symbols trap, and the `-b` test pattern that catches it.
- ADR 0003 (`0003-fail-loud-on-partition-table-failure.md`) and ADR 0007
  (`0007-multicast-lvm-sidecar-order-contract.md`) — the fail-loud and
  refuse-multicast precedents.
- ADR 0009 (`0009-secure-boot-enrolment-paths.md`) and ADR 0012
  (`0012-fog-vendor-shim-signed-by-microsoft.md`) — Secure Boot, which
  firmware-native Wi-Fi boot requires.
- ipxe/ipxe#959 — "Do iPXE support Wireless NIC Wi-Fi 6E AX211?", the
  maintainers' position on wireless drivers.
- iPXE hardware drivers list — <https://ipxe.org/appnote/hardware_drivers>
- Lenovo BIOS setting reference (`WiFiNetworkBoot`) —
  <https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/network/>
- Dell HTTPS Boot user's guide — wired and wireless network boot.
- `etc/init.d/S40network:28-54`, `usr/share/fog/lib/funcs.sh:9-13`,
  `configs/kernel*.config`, `configs/fs*.config`, `create-usb-image.sh:27-28,134`,
  `build.sh:378-390` — the FOS-side evidence for Findings 3 through 6.
- `fog-ipxe/src/config/general.h:141`, `src-efi/config/general.h:106`,
  `tools/linked-objects/*.txt` — the iPXE-side evidence for Finding 1.
