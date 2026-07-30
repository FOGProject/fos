# Non-NVMe sector-size mismatches stay refusal-only, with device-class advice

ADR-0001 refuses a deploy when the image's logical sector size doesn't match the
target disk's; ADR-0002 carved out the one tractable exception, low-level
reformatting an NVMe namespace that exposes a matching LBA format. The natural
follow-up question is whether the same trick extends to the other storage
classes FOS deploys to — eMMC/SD, UFS, SATA, SAS, USB-attached, and virtual
disks. We surveyed each class and decided: **no other class gets an automatic
reformat.** The mismatch stays a refusal everywhere but NVMe, and instead the
refusal message gains one device-class-specific line
(`sectorSizeMismatchHint()`) telling the operator whether this target's sector
size could *ever* change and where the fix actually lives.

## The survey, class by class

What made ADR-0002 tractable on NVMe was the combination of: a standardized,
in-band command (`nvme format`), broad device support, an immediate effect, and
a way to verify the new geometry before proceeding. No other class has all four.

- **eMMC / SD (`mmcblk*`).** The MMC/SD specifications fix sector addressing at
  512 bytes and the Linux mmc block driver exposes exactly that. There is no
  LBA-format concept and no command to change it — not a gap in our tooling, a
  property of the hardware class. The only mismatch these can hit is a
  4096-byte image deployed *to* them, and the only fix is capture-side.

- **UFS (SCSI disks on a `ufshcd` host).** The mirror image: JEDEC UFS mandates
  a minimum 4096-byte logical block, set per-LU in the configuration descriptor
  at provisioning time. Rewriting that means reprovisioning the device — it
  destroys every LU, is commonly one-time-locked by the OEM
  (`bConfigDescrLock`), and can permanently brick a soldered-down part. An
  imaging appliance has no business issuing it. Note the common *capture-side*
  flow already works: an image captured on a UFS machine (4096) deploying to an
  NVMe target is exactly what ADR-0002 handles.

- **SATA.** A real mechanism exists — ACS-4 SET SECTOR CONFIGURATION
  ("FastFormat"), reachable via `hdparm --set-sector-size`, and FOS ships a
  new-enough hdparm. Rejected anyway: only a slice of enterprise
  512e/4Kn-convertible drives implement it, and drives generally require a
  power cycle or link reset before the new size is visible. That breaks the
  format → re-read → confirm → continue sequence ADR-0002 depends on: a
  post-format verification that can't see the new size yet would mean we
  destroyed the disk and *then* refused. If field demand ever materializes,
  this is the one class worth revisiting.

- **SAS.** `sg_format` can re-sector many enterprise SAS drives, but FOS
  doesn't ship sg3_utils (`sdparm` cannot issue FORMAT UNIT), a full format can
  run for hours on spinning media, and SAS deploy targets are a rounding error
  in the install base.

- **USB-attached and virtual disks (`sd*` behind usb-storage/uas, `vd*`,
  `xvd*`).** The USB bridge chip or the hypervisor dictates the logical size;
  nothing can change it from inside the guest OS. For virtual disks there is at
  least an operator-reachable knob — the disk's `logical_block_size` property
  in QEMU/libvirt — so the hint points there.

## What we did instead

`validateImageSectorSize()` already tries the NVMe reformat and falls back to
the ADR-0001 refusal. `sectorSizeMismatchHint()` now classifies the target
(device name for `mmcblk*`/`nvme*`/`vd*`/`xvd*`; the SCSI host driver's
`proc_name` in sysfs to spot `ufshcd`, since UFS surfaces as a plain `sd*`
disk) and appends one line to the refusal:

- eMMC/SD and UFS: the size is **fixed in hardware**; only a matching-geometry
  image can ever deploy here — recapture is the fix.
- NVMe that still refused: the drive **exposes no metadata-free LBA format** at
  the image's size, so the ADR-0002 reformat couldn't help.
- Virtual disks: the size is set by the **hypervisor** and can be changed in
  the VM configuration.
- Everything else (plain SATA/SAS/USB): no extra line; the generic remedy in
  the refusal already says all we know.

Classification failing (no sysfs entry, unrecognized name) just omits the line;
it can never block or alter the refusal decision itself.

## Consequences

- Refusal behavior is unchanged everywhere; this only adds explanation. The
  operator staring at a refused deploy on an eMMC tablet now learns the target
  can never match, instead of wondering which side to "fix."
- The per-class reasoning is recorded here so the "can't we just reformat it
  like NVMe?" question has a written answer.
- Revisit trigger for SATA FastFormat: shipped hdparm supports it today; what's
  missing is confidence in in-band re-read after the command and evidence of
  real fleets that need it.
