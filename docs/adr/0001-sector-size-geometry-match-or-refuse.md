# Refuse a deploy on logical-sector-size mismatch instead of translating

A captured image bakes in the source disk's **logical sector size**: the
partition table stores offsets and sizes in LBA units of that size, and each
captured filesystem records it in its own metadata (e.g. NTFS `$Boot`
`bytes_per_sector`). partclone restores a filesystem verbatim and does not
rewrite that geometry, so deploying a 512-byte-logical image onto a
4096-byte-logical disk (or the reverse) produces a partition table and
filesystems whose declared geometry contradicts the device — unmountable and
unbootable. We decided FOS will **detect the mismatch and refuse the deploy with
an actionable message** rather than attempt to translate geometry on the fly.

## Why not translate

Rewriting LBA units in the partition table is only the surface of it. Every
bootable filesystem would also need its internal geometry rewritten
consistently, bootloaders re-pointed, and any embedded absolute sector
references fixed up — per filesystem, per OS. That is not something partclone
does or that we can do reliably for an arbitrary captured image. A deploy that
"succeeds" but silently produces an unbootable disk is worse than a clean
refusal, so we refuse.

The answer for the tractable case (NVMe drives that expose both a 512- and a
4096-byte LBA format) is to reformat the *target* to match the image's sector
size with `nvme format` before deploying — matching geometry rather than
translating it. This change is the safety net that landed first; the reformat
was added on top of it and is documented in
[ADR-0002](0002-nvme-reformat-target-to-match-image.md).

## How it works

`validateImageSectorSize()` (in `funcs.sh`) runs once per target disk inside
`restorePartitionTablesAndBootLoaders()`, after the `nombr` skip and before the
first destructive write (`clearPartitionTables`). It compares the target's
logical sector size (`blockdev --getss`) against the size recorded in the stored
sfdisk dump's `sector-size:` line (checked in the same
minimum → original → legacy precedence the restore path uses). It acts **only
when both sizes are known and differ**: it first tries to make the target match
by reformatting an NVMe namespace to the image's sector size (see
[ADR-0002](0002-nvme-reformat-target-to-match-image.md)), and only refuses —
calling the existing fatal `handleError` — when that isn't possible. If either
side is unknown — `blockdev` can't read the target, or the dump records no
source size — it returns without erroring, so it never introduces a new failure
on a path that works today.

## Known gaps (deliberate)

This is a safety net, not full coverage. It hooks the partition-table restore
path only, so these cases are **not** guarded:

- **Raw `dd` whole-disk images (`imgType=dd`).** dd capture stores no source
  geometry at all, so a mismatch cannot be detected without adding new
  capture-side metadata. Out of scope here.
- **Single-partition / `nombr` restores.** These intentionally skip the
  partition-table rewrite (and therefore this check) because they restore into a
  table the operator already laid down.
- **Images captured before util-linux 2.35 (~2020).** `sfdisk -d` did not emit
  the `sector-size:` line until then, so an older dump — including a genuine 4Kn
  one — records no source size and cannot be checked. We allow rather than guess:
  guessing 512 would wrongly refuse a matching 4Kn→4Kn deploy that works today.
  Every image FOS has produced for years carries the line, so this only affects
  images captured by long-obsolete FOS releases.

These gaps are acceptable for a first cut: the common, high-value case
(deploying a resizable or multi-partition image onto a whole disk) is covered,
and the refusal is honest about what it protects.
