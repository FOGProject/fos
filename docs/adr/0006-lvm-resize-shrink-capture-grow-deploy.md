# Resize LVM images: shrink LV filesystems at capture, refit the VG at deploy

Phase 1 ([ADR-0004](0004-lvm-per-lv-capture-and-deploy.md)) captures and
deploys LVM stacks faithfully — but only at their original size. The PV
partition is pinned in `d1.fixed_size_partitions`, so an LVM image cannot
deploy to a smaller disk at all, extra space on a larger disk is left
unallocated, and a disk whose only Linux data partition is the PV fails
resizable capture with "No resizable partitions found". We decided FOS will
**shrink each LV's filesystem at capture and record per-LV minimum sizes in
the sidecar, let the existing sfdisk fill engine scale the PV partition
between that minimum and the target disk's capacity, and refit the volume
group to whatever partition size deploy actually produced** — completing the
Phase 2 scope ADR-0004 reserved.

## Capture: same trust model as plain partitions

Resizable capture already writes to the source machine on every run: ext
filesystems are shrunk with `resize2fs -M`, partitions are shrunk and
restored, filesystems re-expanded. LV shrinking is the same procedure run
against `/dev/<vg>/<lv>` instead of `/dev/sdXN`:

1. `shrinkPartition()` gains an `lvm` case dispatching to
   `shrinkLVMPartition`. Unsupported topologies (per the ADR-0004 probe,
   now shared as `probeLVMPartition`) append the partition to
   `d1.fixed_size_partitions` — the same mid-flight demotion the NTFS
   failure path uses — and everything behaves exactly as Phase 1.
2. For each **ext** LV: `e2fsck`, compute minimum via `resize2fs -P` plus
   the same percent slack the plain-partition path uses, `resize2fs -M`,
   `e2fsck`. Other filesystems (xfs and f2fs cannot shrink; btrfs-on-LVM is
   rare enough that shrinking it is not worth the mount dance) and swap
   keep their original size as their minimum. The LV itself is **not**
   reduced (`lvreduce` on the source is risk without benefit — partclone
   captures used blocks of the shrunk filesystem either way).
3. Minimums are handed to the capture step via `/tmp/<part>.lvmmin`:
   one line per LV plus a `PARTMIN` line — the PV partition minimum:
   `pe_start` + every LV's minimum rounded up to whole extents + one spare
   extent, capped at the original PV size.
4. After `fog.upload` saves `d1.minimum.partitions`, new helper
   `applyLVMMinimumSizes` rewrites the PV entry's `size=` in that dump to
   `PARTMIN` (converted into the dump's logical-sector units). Starts are
   left alone — the fill engine repacks them at deploy. On disks with no
   supported PV the helper is a no-op.
5. The sidecar becomes `LVMFORMAT 2`: the `PV` line gains a minimum-size
   column and each `LV` line gains a minimum-size column after the size.
   `mps`/`mpa` captures never run the shrink path, so their format-2
   sidecars record minimum = original — honestly stating those images only
   fit same-or-larger targets, which is what those image types mean.
6. `expandPartition()` gains the matching `lvm` case
   (`expandLVMPartition`): activate the VG, `resize2fs` each ext LV back to
   the LV boundary, deactivate. On the source this undoes step 2; on the
   deploy target it grows each filesystem into its (possibly extended) LV.

With the PV no longer forcibly fixed, fstype `lvm` joins the resizable set
in `beginUpload`'s classification and partition count — a disk that is only
EFI + PV now satisfies imgType `n` (`skiplvm=1` still yields fstype
`imager`, which stays fixed, preserving the escape hatch unchanged).

## Deploy: three cases keyed off the actual partition size

The fill engine sizes the PV partition somewhere between the recorded
minimum and proportional-fill of the target disk. `restoreLVMPartition`
compares the actual partition (`blockdev --getsz`, 512-byte sectors — the
same unit `pvs`/`lvs --units s` report) against the recorded PV size:

- **Equal** — byte-for-byte the Phase 1 path: `pvcreate --uuid
  --restorefile` + `vgcfgrestore`. Every UUID preserved.
- **Larger** — Phase 1 path, then `pvresize` to claim the new space and
  `lvextend` distributing the free extents across non-swap LVs
  proportionally to their original sizes (the same policy the sfdisk fill
  engine applies to partitions); swap LVs stay at original size. Every
  UUID still preserved.
- **Smaller** — `vgcfgrestore` cannot apply metadata describing more
  extents than the PV has, so the stack is rebuilt: `pvcreate --uuid`
  (PV UUID preserved), `vgcreate` with the original extent size,
  `lvcreate` per LV in sidecar order at minimum-plus-proportional-share
  sizes. VG and LV UUIDs regenerate; VG/LV **names**, the PV UUID,
  filesystem UUIDs (partclone restores them), and swap UUIDs (`mkswap
  -U`) are all preserved, which is what fstab/GRUB/initramfs actually
  reference. Rebuilding at *computed sizes with real LVM tools* is
  deliberately chosen over authoring adjusted metadata text for
  `vgcfgrestore` — hand-edited metadata was CloneDeploy's bug factory.
  A target below the recorded minimum refuses with a clear message
  before anything is written.

Deploys of format-1 images keep Phase 1 behavior in every respect: the PV
is in their `d1.fixed_size_partitions`, so the fill engine never shrinks it
and `expandPartition` skips it; a format-1 sidecar reaching the
smaller-target branch anyway refuses, telling the user to recapture with a
current FOS. Format 2 is refused by Phase 1 FOS builds with the existing
"captured with a newer LVM format, update FOS" error, so a format-2 image
can never be half-understood by an older client.

All failure modes stay fatal per
[ADR-0003](0003-fail-loud-on-partition-table-failure.md) — a proportional
computation that cannot fit the minimums into the actual VG (`vg_free_count`
is consulted, not assumed) stops the task rather than truncating an LV.

## Known gaps (deliberate)

- **Only ext filesystems shrink.** xfs/f2fs cannot shrink by design; btrfs
  and NTFS inside LVs are captured at full size (their minimum = original).
  They still *grow* on larger targets only in the LV dimension, not the
  filesystem — growing non-ext filesystems inside LVs can be added to
  `expandLVMPartition` case-by-case if demand appears.
- **Swap LVs never resize.** Original size on every target. Grow-with-RAM
  policies are the admin's job post-deploy.
- **Smaller targets regenerate VG/LV UUIDs.** Documented behavior of the
  rebuild path; systems referencing `/dev/mapper/<vg>-<lv>` names or
  filesystem UUIDs (the norm) are unaffected. Same-or-larger targets keep
  every UUID.
- Multi-PV, non-linear, whole-disk-PV, and multicast gaps carry over from
  ADR-0004 unchanged.
