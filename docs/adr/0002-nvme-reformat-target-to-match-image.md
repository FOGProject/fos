# Auto-reformat an NVMe target to match the image's sector size

ADR-0001 established that FOS refuses a deploy when the image's logical sector
size does not match the target disk's, because the geometry can't be translated
on the fly. This ADR covers the one case that *is* tractable: an NVMe namespace
that already exposes an LBA format at the image's sector size can simply be
switched to it. When a mismatch is hit on such a target, FOS **low-level
reformats the namespace to match the image and continues the deploy**, after a
60-second cancelable countdown. The ADR-0001 refusal remains the fallback for
every case a reformat can't fix (non-NVMe targets, or NVMe with no matching
metadata-free LBA format).

## How it works

`validateImageSectorSize()` calls `nvmeReformatToSectorSize()` before it refuses.
That function returns 0 (deploy proceeds) only after a reformat is confirmed to
have taken effect, and non-zero (caller refuses) otherwise. It:

1. Returns non-zero immediately unless the disk name matches `*nvme*`.
2. Parses `nvme id-ns` and selects the first **metadata-free** (`ms:0`) LBA
   format whose block size (`2^lbads`) equals the image's sector size. No match
   → non-zero.
3. Prints the warning and runs a 60-second `power-off-to-cancel` countdown.
4. Runs `nvme format --lbaf=N --force`. If the command fails → non-zero.
5. Re-reads the geometry (`runPartprobe` + `blockdev --getss`) and returns 0
   only if the target now actually reports the image's sector size; otherwise
   non-zero.

## Why auto-reformat, not opt-in

The alternative was to detect the reformattable case and stop, telling the
operator to reformat manually or set a flag. We rejected that: the deploy is
already going to erase the disk, the reformat is the only way this image will
ever boot on this hardware, and requiring a manual `nvme format` step off in a
shell defeats the point of an imaging appliance. Making it automatic — with a
loud, cancelable window — keeps the common "just deploy it" path working while
still giving the operator a chance to abort.

## Why the 60-second countdown

The reformat is a **low-level, irreversible** operation that destroys the
namespace. We mirror `fog.wipe`'s existing safety idiom (a 60-second
`usleep`-driven countdown with a "power off to cancel" prompt) rather than
inventing a new confirmation mechanism or reformatting silently. Silent would be
surprising and unrecoverable; a prompt requiring keyboard input can't work on an
unattended/PXE deploy. The timed window is the same trade-off FOS already made
for wiping a disk, applied to the same class of action.

## Why metadata-free formats only

Many NVMe drives expose 4096-byte LBA formats that also carry metadata
(`ms>0`, used for protection information / T10-PI). Switching a namespace into a
metadata format changes more than the logical block size and can leave the
device in a state the image was never captured for. We only ever select `ms:0`
formats; if the only matching-size format carries metadata, we treat it as no
match and fall back to the refusal.

## Consequences

- A cross-sector-size deploy that used to be impossible now "just works" on NVMe
  hardware that has a matching LBA format — at the cost of a low-level reformat
  the operator has 60 seconds to stop.
- True-4Kn NVMe drives with no 512-byte LBAF (and the reverse) still can't be
  helped and still refuse, exactly as under ADR-0001.
- The feature is entirely self-contained in FOS; it needs no FOG-server changes.
