# Capture LVM volumes per-LV with sidecar metadata instead of a raw PV blob

Today a partition holding an LVM2 physical volume falls through
`fsTypeSetting()`'s default case to `partclone.imager`, which has no
used-block map for `LVM2_member` and so captures the entire PV byte-for-byte:
a 500 GB PV with 20 GB of data produces a ~500 GB read (and a large image),
and the deployed partition can never be resized because the LVM metadata
inside it describes fixed extent positions. We decided FOS will **detect LVM
physical volumes at capture, image each logical volume individually with the
matching partclone type, and store the volume-group layout as sidecar
metadata; at deploy it recreates the PV/VG/LVs (preserving every UUID) and
restores each LV's filesystem into place.** The PV partition itself is never
sector-imaged.

This is Phase 1: faithful per-LV capture and deploy at original sizes. LV
shrink/expand (resizing the layout to fit smaller or larger target disks) is
Phase 2 and builds on the metadata this phase records.

## The pattern: swap partitions, not a new pipeline

FOS already has a partition type whose content is not sector-imaged: swap.
Capture records the swap UUID in a sidecar file (`d1.original.swapuuids`),
the partition is pinned fixed-size through the resize engine, and deploy
regenerates it with `mkswap -U`. LVM follows the same shape:

- **Capture** writes two sidecar files per PV partition and one partclone
  image per logical volume; no `d1pN.img` is written for the partition.
- **The resize engine is untouched.** fstype `lvm` is not in the resizable
  list, so the PV partition lands in `d1.fixed_size_partitions`
  automatically and the sfdisk scaler keeps it at its original size — the
  extent count the recorded metadata describes stays valid.
- **Deploy** recreates the LVM stack inside the (identically sized)
  partition and restores each LV, the way `makeSwapSystem` recreates swap.

Logical-volume device paths (`/dev/<vg>/<lv>`) never enter the
partition-name machinery (`getPartitions`, `getPartitionNumber`, the sfdisk
awk engine) — they are handled in their own loop keyed off the sidecar. This
is the specific failure mode of the earlier in-tree attempt (the unused
helpers around `getLVM`) and of several CloneDeploy bugs: `/dev/mapper`
names do not survive code that assumes `/dev/sdXN`.

## How it works

**Detection.** `fsTypeSetting()` maps blkid's `LVM2_member` to fstype
`lvm`. Detection is by content, not partition type ID — CloneDeploy keyed
off type `8e`/`8E00` and missed PVs living on plainly-typed partitions,
which is the common case on modern GPT installs. Booting with `skiplvm=1`
on the kernel command line maps it to `imager` instead, which is exactly
today's raw-blob behavior — the escape hatch if per-LV capture misbehaves
in the field.

**Capture** (`saveLVMPartition`, dispatched from `savePartition`'s new
`lvm` case, so it applies to `n`, `mps`, and `mpa` image types alike):

1. Find the VG on the PV and activate it (`vgchange -ay`). Phase 1 capture
   never writes to the source — no LV shrinking — so a capture cannot
   damage the machine being imaged.
2. Guard the supported topology: exactly one VG on the PV, the VG spans
   only that one PV, and every LV is linear. Anything else (multi-disk
   VGs, thin pools, RAID/cache/snapshot LVs) falls back to the raw
   `partclone.imager` blob with a loud warning — the pre-change behavior,
   not a failure.
3. Write `d<disk>p<part>.lvm`, a versioned, whitespace-delimited schema:
   the PV UUID and size, the VG name/UUID/extent size, and one line per LV
   with name, UUID, size in sectors, detected fstype, image file name, and
   swap UUID where applicable. This file is what deploy iterates and what
   Phase 2 resize will extend. (LVM restricts VG/LV names to
   `[a-zA-Z0-9+_.-]`, so whitespace splitting is safe.)
4. Write `d<disk>p<part>.lvm.vgcfg` via `vgcfgbackup` — LVM's own complete
   metadata description (segments, extent maps, all UUIDs).
5. For each LV: swap LVs get their UUID recorded and no image; every other
   LV is captured with `partclone.<fstype>` (used blocks only) through the
   same `uploadFormat` pipeline as normal partitions, to
   `d<disk>p<part>.<lvname>.img`. Devices are addressed as
   `/dev/<vg>/<lv>`, sidestepping `/dev/mapper` hyphen-escaping entirely.
6. Deactivate the VG.

**Deploy** (`restoreLVMPartition`): `getValidRestorePartitions()` and
`restorePartition()` treat a readable `.lvm` sidecar as that partition's
image. The restore deactivates any VGs a previous life of the target left
active, wipes stale signatures from the partition, then runs LVM's own
disaster-recovery procedure: `pvcreate --uuid <pvuuid> --restorefile` +
`vgcfgrestore` — valid because the partition was recreated at its original
size, so the extent geometry in the backup still fits. This restores the
PV, VG, and every LV with their original UUIDs and exact segment layout in
two commands; CloneDeploy instead rebuilt the stack with `lvcreate` and
patched UUIDs back in with `vgcfgbackup` + sed, which loses non-linear
segment detail and was a source of bugs. Then each LV is restored with
`writeImage`, swap LVs are regenerated with `mkswap -U`, and the VG is
deactivated so the deployed OS boots from a clean state. `fstab`/`crypttab`
and bootloader references survive because every UUID (PV, VG, LV,
filesystem, swap) matches the source.

Failures at deploy are fatal (`handleError`), per
[ADR-0003](0003-fail-loud-on-partition-table-failure.md): a machine that
boots into a half-restored VG is worse than a task that stops with a
message.

## Why not keep the raw blob and add resize on top

Extent positions inside a PV are absolute. Any plan that grows or shrinks
the partition around a byte-identical blob corrupts the VG; resize
fundamentally requires understanding the layout, which means per-LV
imaging is the prerequisite for everything else. Per-LV capture also fixes
the immediate pain — image size and capture time proportional to used
space, not PV size — even before resize exists.

## Known gaps (deliberate)

- **No LV resize yet.** The PV partition is fixed-size on deploy even onto
  a much larger disk; extra space is left unallocated after the partition.
  Phase 2 adds LV filesystem shrink at capture (recorded minimums) and
  `pvresize`/`lvextend`/filesystem-grow at deploy.
- **Single-PV VGs only.** A VG spanning multiple PVs (or a PV carrying no
  VG, or sharing it) falls back to raw-blob capture, which is today's
  behavior and restores correctly only under `mpa`'s byte-identical
  whole-set restore.
- **Linear LVs only.** Thin pools, RAID/mirror LVs, caches, and snapshots
  fall back to the raw blob. A LUKS container *inside* an LV is fine — it
  is captured per-LV via `partclone.imager` (raw, but LV-sized).
- **No multicast.** The multicast sender enumerates image files
  server-side and knows nothing of per-LV files; an LVM deploy over
  multicast refuses with a clear message rather than hanging. Unicast
  only until the server side learns the layout.
- **Whole-disk PVs** (PV directly on `/dev/sdb`, no partition table) are
  not detected — `getPartitions` never yields the bare disk. Unchanged
  from today.
- **imgType `n` still requires one resizable non-LVM partition** on the
  disk ("No resizable partitions found" otherwise). Standard installs
  satisfy this with the ext4 `/boot`; a disk that is *only* EFI + PV needs
  `mps`/`mpa`. Lifting this is a Phase 2 concern.
- **Old images deploy unchanged.** A pre-Phase-1 image has no `.lvm`
  sidecar and a real `d1pN.img`, so deploy takes the existing raw path.
  New images deployed by an old FOS client would skip the PV ("Partition
  File Missing") — matching FOG's existing stance that clients and images
  move forward together.
