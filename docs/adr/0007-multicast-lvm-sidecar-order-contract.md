# Multicast LVM deploy: the sidecar is the stream-ordering contract

Per-LV LVM images ([ADR-0004](0004-lvm-per-lv-capture-and-deploy.md),
[ADR-0006](0006-lvm-resize-shrink-capture-grow-deploy.md)) refuse multicast
deploy — a gap ADR-0004 recorded as deliberate. The refusal exists because
udpcast synchronizes by nothing but order: the server chains one
`udp-sender --file <path>;` per image file on a shared portbase, the client
opens one `udp-receiver` per file it expects, and the Nth receiver gets the
Nth file. No filename, size, or checksum crosses the wire. Per-LV images add
a variable number of files per partition, so both sides must agree on the
sequence or partclone restores one LV's filesystem onto another. We decided
**both sides derive the stream order from the same `dNpM.lvm` sidecar: the
server emits each LVM partition's LV image files in sidecar line order where
the partition's `dNpM.img` would have gone, the client keeps restoring in
sidecar line order and simply passes the multicast flag through to
`writeImage`, and a capability probe against `getversion.php` refuses the
deploy against a server too old to know about per-LV files.**

## What makes this small: multicast already mounts NFS

`fog.download` sources `fog.mount` unconditionally, so multicast clients
mount the image directory over NFS exactly like unicast ones — that is how
partition tables, sfdisk dumps, and MBRs already reach multicast deploys.
Everything `restoreLVMPartition` does besides bulk data — reading the
sidecar and vgcfg backup, the size refusals, `pvcreate`/`vgcfgrestore`, the
grow and rebuild paths, `mkswap` — works untouched. Only the partclone
streams need udpcast, and `writeImage`'s multicast branch already ignores
its file argument (the path only orders and existence-checks). The client
change is: delete the refusal, pass `"$mc"` to `writeImage` in the LV loop.
The existence check on each LV image file stays — it runs against NFS and
catches a mismatched image before a receiver opens.

Timing needs no care either: all metadata work happens before the
partition's first receiver opens and between LV restores the loop proceeds
immediately, well inside udp-sender's 600-second inter-file wait.

## Why sidecar order and not a sort

The alternative is what flat images do: the server `natcasesort()`s the
filenames and the client iterates partitions in device order, which happens
to match. Extending that to LV files means FOS replicating PHP's
case-insensitive natural sort in shell — and any divergence (`Data` vs
`backup`, `lv2` vs `lv10`, locale collation) is not a crash but a silent
data-placement bug. Ordering by the sidecar makes divergence structurally
impossible: both sides read the same lines of the same file, skip the same
swap and `-` entries, and the client already restores in that order today.
Overall stream order becomes: disks ascending, partitions ascending (as
today), LVs in sidecar order within an LVM partition.

## Server change (fogproject, `working-1.6`)

`multicasttask.class.php` currently enumerates with
`sscanf($filename, 'd1p%d.%s')` keeping only `$ext == 'img'` — because `%s`
is greedy, `d1p3.root.img` parses as ext `root.img` and per-LV files are
silently dropped (harmless today only because the client refuses first).
The rework, in the three branches that enumerate `dNpM` files (image type
1's DirectoryIterator default branch, type 2, type 3):

- Flat `dNpM.img` files keep sort key (disk, partition, 0). For each
  `dNpM.lvm` sidecar, parse its `LV` lines and append the named image
  files under key (disk, partition, LV line index). The image filename is
  field 7 in an `LVMFORMAT 2` sidecar and field 6 in format 1 — the same
  header-keyed shift the client does; swap LVs and `-` entries have no
  file and are skipped by both sides for the same reason.
- The single-partition filter (`/^d[0-9]p$partid\.img$/`) also admits that
  partition's LV files.
- For images with no sidecars the produced order must be **identical** to
  today's `natcasesort()` output — flat multicast must be provably
  unchanged.

The multicast manager needs nothing: completion is task-state and
process-exit driven, not per-file.

## Version skew: refuse, don't hang, never misassign

The dangerous pairing is new FOS against an old server. The old server
sends nothing for the LVM partition, so unless that partition is the last
thing restored, the client's first LV receiver joins the session of the
*next flat partition's* file and partclone writes the wrong filesystem into
the LV. (Old FOS against a new server merely refuses at the client, as
today.)

The guard is a capability probe, not a version comparison — version strings
diverge across betas and backports, and the probe must key on the feature,
not the release. `getversion.php` is a chain of `isset($_REQUEST[...])`
branches falling through to `echo FOG_VERSION`; `working-1.6` adds a
`caps` branch returning a space-separated token list including `mclvm`. In
`restoreLVMPartition`'s multicast path, before anything touches the target,
FOS curls `${web}service/getversion.php?caps=1` and refuses with a clear
"server does not support multicast LVM deploy" unless the response contains
the token. An old server answers the same query with its version string —
no token, clean refusal, disk untouched. (The `url` proxy branch in
`getversion.php` whitelists query keys; `caps` joins `client`/`clientver`
there so node-to-node forwarding keeps working.)

## Known gaps (deliberate)

- **Split images stay out.** The current enumerator drops `.img.000`
  split pieces for flat images too — split-file multicast is already
  unsupported. Per-LV files inherit that; not widened here.
- **A refusing client stalls the session** (below-minimum target, the
  capability refusal, sector-size mismatch) until udp-sender's max-wait —
  pre-existing multicast behavior for any client-side abort, unchanged.
- **Verification needs a real multicast rig.** The shell harness pins the
  client behavior and the enumerator can be desk-checked against fixture
  directories, but the ordering contract is only proven end-to-end by a
  server and at least two receivers on a shared segment. Ordering bugs are
  data-placement bugs, so this ships behind the same community-validation
  bar as ADR-0004/0006 — with the capability probe ensuring the failure
  mode of every skew pairing is a refusal, not corruption.
