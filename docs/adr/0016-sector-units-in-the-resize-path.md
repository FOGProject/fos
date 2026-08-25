# Sector units belong to every sfdisk action, and last-lba belongs to the disk

Capturing a resizable image from a 4Kn disk aborted with sfdisk's `Last LBA
specified by script is out of range`, reported as
`sfdisk failed to apply the partition table to /dev/vda (applySfdiskPartitions)`.
Two unit errors in the capture-time shrink caused it, and a third decision — that
a shrink may rewrite the disk's own `last-lba` — is what turned them into a
refused table rather than a slightly wrong one. All three are settled here.

The important part of the diagnosis: **this was not a regression.** The same
broken table was computed on every 4Kn capture for years. Until ADR-0003 made
`applySfdiskPartitions()` fatal, sfdisk rejected it into a `majorDebugEcho` and
capture carried on with the partition table untouched — so a 4Kn "resizable"
capture silently produced an unshrunk table and nobody knew. Reverting to an
older init does not fix this; it re-hides it.

## The three decisions

### 1. `diskSize` is rescaled for every action, not just `filldisk`

`processSfdisk()` converts `blockdev --getsz` (always 512-byte units) into the
disk's logical-sector unit, because that is the unit the partition table it is
about to rewrite is expressed in. That conversion was introduced for the deploy
path and guarded with `if [[ $action == filldisk ]]`, which left `resize` — the
capture path — reading a 64 GiB 4Kn disk as 134217728 sectors instead of
16777216.

The guard is gone. Every action gets the rescale, because every action compares
against `diskSize`: `check_overlap()` uses it as the bound for "does this
partition fit on the disk", and with a value eight times too large that check
cannot fail no matter how wrong the layout is. The rescale is an exact no-op on
512-byte-sector disks (`disk_size * 512 / 512`), so this is not a behaviour
change there.

### 2. `SECTOR_SIZE` and `LOGICAL_SECTOR_SIZE` are different numbers

`SECTOR_SIZE` is not the sector size, despite the name. `fill_disk()` uses it
only as a size-alignment quantum — `p_size -= p_size % SECTOR_SIZE` — and it is
deliberately scaled to hold 256 KiB of granularity in whatever unit the disk
uses: 512 sectors on a 512-byte disk, 64 on a 4Kn one. ADR-0002 explains why:
a 1 MiB `bios_grub` is 256 sectors on 4Kn, and a 4096-sector quantum rounds it
to zero and corrupts the table.

`resize_partition()` was using that same variable as a **unit divisor**, to turn
the byte count it is passed into a sector count. On a 512-byte disk the two
meanings coincide, which is exactly why the bug survived: `sizePos / 512` is
right for a 512-byte disk and eight times too large for a 4Kn one.

So the raw logical sector size now travels as its own awk variable,
`LOGICAL_SECTOR_SIZE`, and `SECTOR_SIZE` keeps the one meaning it is documented
to have. **Do not merge them again.** One variable that means an alignment
quantum in one function and a unit divisor in another is a bug that only shows
up on hardware most people do not have.

The conversion **rounds up**:
`(sizePos + LOGICAL_SECTOR_SIZE - 1) / LOGICAL_SECTOR_SIZE`. By the time the
partition is resized the filesystem inside it has already been shrunk to
`sizePos` bytes, so a partition rounded *down* is smaller than its own contents.
The cost of rounding up is at most one sector. Note this also changes 512-byte
disks for a request that is not a multiple of 512 — `extfs` reaches here with
`size + percentage`, which is under no obligation to be — and by one sector in
the safe direction.

### 3. A capture-time shrink never recomputes `last-lba`

`resize_partition()` used to overwrite the dumped `last-lba` with
`diskSize - firstlba`. That is wrong in principle regardless of units: `last-lba`
describes where the *disk* ends, `sfdisk -d` read it from the very disk the table
is about to be written back to, and shrinking one partition does not move the end
of a disk. It is now passed through untouched.

Both failure modes it caused are worth recording:

- With `diskSize` in 512-byte units on a 4Kn disk it named a last-usable LBA
  eight times past the end of the disk, and sfdisk refused the whole script at
  the header stage — the reported bug.
- Even with correct units it was still wrong on a 512-byte GPT disk:
  `diskSize - 2048` against a true last-usable of `diskSize - 34` silently
  reserved 1 MiB of tail. That never surfaced only because the apply used to fail
  silently; post-ADR-0003 it would abort a capture whose last partition reached
  into that megabyte.

`fill_disk()`'s own `lastlba = diskSize - firstlba` is a **different case and
stays.** There we are computing a table for a disk whose size we were told rather
than one we read a table from, and the value has to agree with the `disk_end`
clamp in the same function (see the comment at that clamp). The two assignments
look identical and are not.

## Consequences

- A 4Kn resizable capture now actually shrinks the partition, for the first time.
  That means the deploy-side fill for 4Kn — correct since ADR-0002 but almost
  certainly never exercised on real 4Kn hardware — starts being reached in
  earnest. A 4Kn image is worth round-tripping (capture *and* deploy) before it
  is trusted.
- `tests/checks/resize-engine.sh` is the guard, and is the capture-side sibling
  of `tests/checks/fill-engine.sh`. It pins the passthrough, the divisor, the
  rounding direction, and that a valid 4Kn shrink reaches the sfdisk write.
- `tests/checks/mbr-extended.sh`'s resize case had encoded the old flooring
  behaviour (`10000000 / 512`) and now expects the rounded-up value. It is the
  only in-tree assertion the rounding change moved.

## Alternatives rejected

**Revert ADR-0003's fail-loud apply.** It would restore the observed "working"
March behaviour, and that behaviour is a 4Kn capture that quietly does not
shrink. The refusal was the only reason anyone found out.

**Reuse `SECTOR_SIZE` for the divisor by moving the existing rescale out of the
`filldisk` guard.** The smallest diff, and it works — because on the disks where
the two meanings differ the rescaled quantum (64) happens to be wrong in a
different way than 512 is. Keeping one name for two quantities is what hid this;
it would hide the next one too.

**Fix the units and keep recomputing `last-lba`.** Fixes the reported abort and
leaves the 512-byte tail reservation in place as a latent fail-loud trigger on
any barely-fitting image.
