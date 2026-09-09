# Multicast streams identify themselves

udpcast carries no metadata. The server chains one `udp-sender` per image
file on a shared portbase, FOS opens one `udp-receiver` per file it expects,
and the Nth receiver gets the Nth stream. [ADR-0007](0007-multicast-lvm-sidecar-order-contract.md)
recorded that property and handled one of its consequences — version skew
across per-LV image files — with a capability probe. It did not address the
other: **position is the only thing binding a stream to a partition, and
nothing detects when the two sides stop agreeing on it.**

We decided **every stream is prefixed with a fixed 128-byte record naming the
image file it carries, and a receiver refuses a stream that is not the one it
asked for, before any of it reaches partclone.**

## The failure this closes

fogproject issue #1742. A host was reset while its multicast task kept
running; the sender chain does not rewind, so the rebooted client opened its
first receiver against the sender already on the second file and stayed one
stream behind. Partition 2's image was written to partition 1 and partition
3's was offered to partition 2.

Only the second of those was noticed, and only by accident: partclone
compares the incoming source size against the target device and refuses when
the target is smaller (105 MB EFI partition, 135 MB MSR source). The first
went the other way — a 100 MiB image onto a 300 MiB partition — and produced
no error at all. **A larger target means the wrong filesystem is written and
the deploy reports success.** That is the half worth fixing; the noisy half
was already survivable.

partclone's own check cannot be tightened into a fix, because for a resizable
image a target larger than the source is legitimate and routine. The
comparison that would mean something is against the size the partition had in
the *image*, and nothing on the wire says which partition that is.

## Why a header and not per-stream ports

The obvious structural fix is to give sender *i* and receiver *i* their own
portbase so no other pair can meet. It was rejected on two counts.

FOS would have to derive the same stream index the server used, and for split
and per-LV images that index is not the partition number. ADR-0007 refused
exactly this re-derivation for exactly this reason: a divergence is not a
crash but a silent data-placement bug. Naming the file instead means both
sides reach the same string from their own layout, and neither counts the
other's streams.

The port budget also does not survive it. Sessions currently reserve two
ports each out of a window (`FOG_UDPCAST_STARTINGPORT` plus twice
`FOG_MULTICAST_MAX_SESSIONS`) that the installer opens in the firewall as a
matching range in `lib/common/config.sh`. Per-stream ports multiply that by
the partition count, and the two definitions have to move together or
multicast breaks on any firewalled server — a pairing nothing enforces.

## The naming rule, and why it is not uniform

The id is the image file basename, except that a stream carrying several
files is named by the stem its files share:

| On the wire | Layout | Client asks for | Id |
|---|---|---|---|
| `d1p2.img` | flat partition | the name | `d1p2.img` |
| `d1p1.img.000`, `.001` | split chunks | `d1p1.img*` | `d1p1.img` |
| `d1p2.img.000` | split, one chunk | `d1p2.img*` | `d1p2.img` |
| `sys.img.000`, `.001` | **one** partition | `sys.img.*` | `sys.img` |
| `rec.img.000` / `.001` | **two** partitions | each by name | `rec.img.000` |

The `sys`/`rec` asymmetry is FOS's own and predates this: `sys.img.*` is one
partition spread over several files, `rec.img.NNN` is one partition each.
The server already mirrors it when it decides what to concatenate (#897), so
the id is decided at the same place, in the branch that already knows the
answer, rather than re-derived afterward from a filename.

The client reaches the same string by taking the basename of what it was
about to restore and dropping a trailing `*` and `.`. That argument was
already being passed to `writeImage` and discarded on the multicast path —
it is now the assertion.

## Fixed width, read a byte at a time

The client reads the header with a single `dd bs=1 count=128` on a file
descriptor it holds open on the receiver. A count of bytes is the only thing
a pipe lets it read without consuming payload, so the record cannot be
variable-length or newline-delimited. `bs=1` because a pipe may return a
short read, and over-reading would eat the front of the image.

The read happens before the decompressor is started, so a refusal leaves the
target partition untouched.

## Skew

FOS probes `getversion.php?caps=1` for an `mcstreamid` token and strips the
header only when the server advertises it — a server that does not prepend
one must not have 128 bytes taken off its payload. The call is checked before
its answer is interpreted, so an unreachable server does not read as "no
header" (the GH-1266 shape, same as the `mclvm` probe beside it).

The reverse pairing, a new server against an old FOS, feeds 128 bytes of
header into the decompressor and fails cleanly there. It is not silent
corruption, which is the property that matters, and in practice FOS is served
by the server it is talking to.

## Known gaps

- **This detects, it does not prevent.** A desynced client still ends its
  deploy with an error rather than a correct image. Refusing a client that
  tries to join a session already past its first stream would remove the
  common trigger, and is not done here.
- **The 128-byte width is duplicated**, as a constant on the server and a
  `dd` count here. Both are pinned by their own repo's checks, but nothing
  compares them across the two.

## Amendments

**2026-09-09 — both gaps above are closed.**

*Prevention.* fogproject #1744 refuses the join instead of catching it
later. A host whose task has already checked in, to a session that already
has clients, is turned away in `TaskQueue::checkIn()` — the point
`fog.checkin` blocks on, before `fog.download` touches the disk. That
removes the common trigger. The header still covers the rest: a receiver
that opens late, or a sender chain that moves on for any other reason.

*The duplicated width.* #179 makes the width a property of the record
version rather than a free number. **A `FOGMC1` record is 128 bytes.** Each
repo pins that pair, not the number alone, so a width change that keeps the
magic fails a check on the side that changed. Changing the width therefore
means bumping the magic, and an old client then meets `FOGMC2`, fails the
tag test, and names the version it cannot read — instead of mis-framing the
stream.

`checkStreamIdentity()` names the magic and the width once each, and the
`dd` counts the named value. The assertion harness reads both out of the
shipped function and builds every fixture from them, so a fixture can no
longer agree with a stale belief about the format — which is what the
restated `printf 'FOGMC1 %-120s\n'` did, and why a server-side change used
to leave the suite green. Where a fogproject checkout is on the same
machine, the harness compares the server's constants directly and says when
it could not.
