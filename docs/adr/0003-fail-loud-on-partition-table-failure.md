# Abort the run when the partition table can't be computed or applied

The partition-restore path had three places where a failure was swallowed and
init continued anyway: a computed layout could be inconsistent, or the write to
disk could fail, and FOS would still proceed to the partclone restore. The
result was a half-imaged or silently-wrong disk that reported success. We decided
these are **fatal**: each now stops the run at the point of failure with a
message, instead of continuing.

## What changed

Three sites, all in the fill/restore path:

- **`applySfdiskPartitions()`** (`partition-funcs.sh`). A non-zero exit from the
  `sfdisk` write went to `majorDebugEcho` — visible only in debug mode, otherwise
  discarded. It now calls the fatal `handleError` and includes sfdisk's captured
  stderr. This function is the single apply point for every caller (fill, restore,
  resize, move, shrink), so the change covers all of them.
- **`fillSfdiskWithPartitions()`** (`partition-funcs.sh`). The old code applied
  the computed table only `[[ $status -eq 0 ]]` and, when the fill engine failed,
  simply skipped the apply and continued — leaving whatever table was already on
  the disk. It now `handleError`s on a non-zero status before reaching the apply,
  so a disk that the image can't fit stops the deploy instead of being restored
  onto a stale or wrong table.
- **`fill_disk()` / the `END` block** (`procsfdisk.awk`). An inconsistent computed
  table (overlap, or a partition pushed past the disk) printed an `ERROR` banner
  into the emitted output but the awk still exited `0`, so the caller applied it.
  The `END` block now propagates a non-zero exit (`if (rc != 0) exit(1)`), which
  is the `status` that `fillSfdiskWithPartitions` above now refuses on.

## Why hard-abort, and the trade-off

The alternative was to keep warning and continuing. We rejected it because the
failure modes here are silent: a dropped or overlapping partition, or an sfdisk
write that didn't take, produces a disk that looks imaged but isn't bootable — and
the operator finds out only when the machine won't start, far from the cause. A
hard stop at the failing step is more honest and far easier to diagnose.

The cost is that a hard-abort turns any *benign* non-zero exit into a failed
deploy that would previously have completed. That risk was the specific target of
an adversarial review of this change: it hunted for a real path where `sfdisk` or
the awk returns non-zero while the table actually applied fine — a busy-disk
`BLKRRPART` re-read, an odd util-linux 2.41.3 exit — and none survived
verification. The kernel partition-table *re-read* (which genuinely can lag on a
busy disk) is handled separately by `runPartprobe`, not by sfdisk's own exit
code, so it isn't caught by this abort. We accept the residual risk: a spurious
refusal is recoverable and loud, a silent mis-image is neither.

## Verification

`tests/checks/fill-engine.sh` locks all three: an unusable computed table makes
the awk exit non-zero and `fillSfdiskWithPartitions` abort before any write, and
a failing `sfdisk` stub makes `applySfdiskPartitions` abort. A negative-control
run (each fix reverted) confirms every one of those cases goes red without the
change.

This hardening rides with the sector-size fill fixes it protects — the 4Kn
disk-size rescale and the GPT backup-header clamp in the same fill engine — which
support the geometry-matching work in
[ADR-0001](0001-sector-size-geometry-match-or-refuse.md) and
[ADR-0002](0002-nvme-reformat-target-to-match-image.md).
