# An extended partition is a container: order the table by partition number, and never image the container

FOG could neither capture nor deploy an MBR disk carrying an extended partition
with logical partitions inside it
([#150](https://github.com/FOGProject/fos/issues/150)). The reporter's disk had
ten partitions — three primaries, the third an LBA extended, plus six logicals —
and capture died before a single byte was uploaded:

```
>>> Created a new DOS (MBR) disklabel with disk identifier 0xc4eae1bb.
/dev/sda1: Extended partition does not exists. Failed to add logical partition.
Failed to add #1 partition: Invalid argument
Leaving.
```

That is two independent defects wearing one bug report. Both are recorded here
because both are the kind of mistake that looks correct in review and in most
testing.

## 1. The emitted partition table was in gawk's hash order

`display_output()` in `procsfdisk.awk` walked the partition array with

```awk
for (pName in partition_names) {
```

`for (i in array)` has **no defined order** in awk. `sfdisk` consumes a script
top to bottom and derives each partition's number from the device name on the
line, so a logical partition (>= 5) reaching `sfdisk` before the extended
partition that contains it fails in `add_logical()` with the message above, and
the entire write is abandoned. The device named in that message is not the
offending line — it is `sfdisk`'s prompt for the next slot it was going to fill,
which is why the error says `/dev/sda1` about a fault caused by `/dev/sda10`.

**This hid for years because gawk's hash order happens to match insertion order
for `/dev/sdaN` while N <= 9.** Every table with nine or fewer partitions came
out correct by accident. Add a tenth and `/dev/sda10` hashes to the front, and
the accident stops. There was never a case where the code was right; there were
only inputs whose hash order flattered it.

The fix orders every `partition_names` traversal by partition number
(`by_partition_number()` via `PROCINFO["sorted_in"]`), which is both what sfdisk
requires and what the rest of the script was written assuming. Two traversals
needed care rather than a blanket setting:

- `fill_disk()`'s "find the next partition" scan infers a partition's original
  size from where its neighbour starts, so it needs the same by-number order.
- the `ordered_starts` walk that assigns new start positions accumulates
  `curr_start` as it goes and must follow `asort()`'s ascending *index* order.
  It was relying on hash order too, so it is now pinned explicitly to
  `@ind_num_asc` rather than left to chance.

Because capture's shrink step writes a resized table back to the source disk,
this defect broke **capture**, not just deploy — which is why the reporter never
got an image at all.

### Two more, found on the deploy side of the same engine

- **No room for the EBRs.** Each logical partition is introduced by an EBR
  sector living in the gap immediately before it. `fill_disk()` reserved
  `MIN_START` per logical in `original_fixed`, but nothing ever *spent* it when
  assigning starts, so the fill packed logicals end to end and sfdisk hit
  `No free sectors available`. The reservation and the spending now agree.
- **The container was scaled like data.** An extended partition holds no
  content of its own; its extent is defined by what is inside it. `fill_disk()`
  ran its captured size through the same proportional grow/shrink as a
  filesystem partition, which walked the container's end past the end of the
  target disk on any grow-to-fit deploy. Its size is now **derived** after the
  logicals are placed, as `last_logical_end - ext_start`. Deriving it late also
  means it inherits the disk-end clamp applied to the last logical for free, so
  the container can never extend past `disk_end`.

### The consistency check that never ran

`check_overlap()` has a branch meant to assert that a logical partition sits
wholly inside its container. It was guarded on `p_number > 4` — where `p_number`
is the *container's* own partition number, and an extended partition is always a
primary, so it is never > 4. The check has therefore never executed. It is now
guarded on `new_part_number > 4`, the number of the partition being tested.

This is a previously-dead safety net going live, and that is deliberate: with
the fill engine corrected the check cannot fire on a table this code produces,
so its only job is to catch the next regression in this area before it reaches
a disk (the same reasoning as [ADR-0003](0003-fail-loud-on-partition-table-failure.md)).

## 2. The extended partition was captured, and restored, as content

Linux exposes an extended partition as a block device covering only the ~1 KB
EBR window at the front of the container. Anything written to that device lands
on the EBR chain.

`savePartition()` dispatched on `$fstype` before testing the partition type:

```bash
case $fstype in
    ...
    imager)     # <-- an extended partition always lands here
        ...
    *)
        case $parttype in
            0x5|0xf)   # <-- unreachable
```

An extended partition has no filesystem, so `fsTypeSetting()` resolves it to
`imager` and the `imager` arm matched first. The extended-partition arm below it
could never be reached. FOG therefore captured the container's EBR window as a
`d<disk>p<part>.img`, and on deploy `restorePartition()` wrote it back — over the
chain `fillDiskWithPartitions` had just built from the partition table. Every
logical partition after the first ceased to exist mid-restore, and the next
`writeImage` failed:

```
 * Restoring EBR for (/dev/sda3).....................Done
 * Processing Partition: /dev/sda5 (5)
partclone.c,open_target,1818: open /dev/sda6 error(2)
```

which is precisely what the reporter described from his own manual workaround.

Capture now tests for the container **before** the `$fstype` dispatch and writes
only the `.ebr` sidecar.

Deploy's guard is keyed off the **partition type, not off the absence of a
`.img`**, and that distinction is the load-bearing part. The pre-existing
fallback only consulted the `.ebr` sidecar when no image file was found — but
*every image captured before this fix still carries one*, and those are exactly
the images that break. A guard that defers to the file would keep failing on the
entire existing image library. The type is authoritative; the file is not.

## Consequences

- Images captured before this fix keep a stale `d<disk>p<part>.img` for their
  extended partition. They do not need re-capturing: the deploy-side guard
  ignores it. Re-capturing does remove it.
- `partitionIsDosExtended()` in `funcs.sh` is left alone. It has no callers and
  its `dos)` branch returns "no" for exactly the scheme it is meant to detect,
  so it is inverted as well as dead; the live paths use the `getPartType` +
  `0x5|0xf` test that was already in the code beside them. Removing it is a
  separate cleanup.
- `tests/checks/mbr-extended.sh` covers all of the above. Where a real `sfdisk`
  is on the host it also *applies* each computed table to a sparse file, which
  is the only assertion that proves sfdisk accepts the layout rather than that
  the numbers look plausible. 10 of its cases fail against the pre-fix tree.

## Validation

Verified end to end against a FOG 1.6 server, not only in the harness: a 16 GiB
MBR disk with the reporter's shape (3 primaries including an LBA extended, plus
6 logicals) was captured, then deployed onto a 24 GiB disk. All ten partitions
came back, every logical inside the container with its EBR gap intact, and all
eight payload checksums matched the source byte for byte.

The lab disk was synthetic — built with `sfdisk` + `mke2fs -d` rather than
installed by an OS — so it exercises the geometry and the data path but not, for
example, a bootloader in the extended chain or a vendor's unusual EBR layout.
The reporter's own disk is a Debian 13 install; a pass there is still worth
having.
