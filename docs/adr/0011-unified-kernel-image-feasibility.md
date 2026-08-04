# 0011 — Adopting a UKI is feasible, gated on redesigning FOS's boot-time config channel

## Status

Proposed. This settles the question ADR 0010 raised and left open
("Settle the initrd question before going further") and answers
FOGProject/fogproject#995's gate ("nothing else here is worth starting until
this is answered"). It is a decision, not an implementation — no code has
changed. The redesign it recommends, and the lockdown-activation patch ADR
0010 is gated behind it, are both separate future work.

## Context

FOS boots as `bzImage` plus a kernel command line built dynamically by iPXE,
per host, per task — `web=` (FOG server URL), `mode=`, `type=`, host identity —
plus an unsigned ext2 `init.xz`. This is not incidental: it is FOS's only
channel for task selection. `funcs.sh:9-13` re-parses `/proc/cmdline` into
exported env vars every time a subshell needs them, and `etc/init.d/S40network`,
`bin/fog.checkin`, `bin/fog.capone`, `bin/fog.sysinfo` each independently
re-parse it again. Nothing downstream knows what to do without it.

A UKI's `.cmdline` PE section is fixed at build/sign time, covered by the same
signature as the kernel and initrd. Stapling FOS's current cmdline into a UKI
verbatim is a contradiction — it would have to stay dynamic and unsigned to do
its job, which defeats the point of signing it at all. That contradiction is
exactly why this question had to be settled before writing the
lockdown-on-Secure-Boot patch: a signed kernel that still boots off an
attacker-shaped cmdline and initrd buys nothing.

## Findings

**1. UKI addons do not require FOS to run systemd.** Per the UAPI Group's UKI
specification and `systemd-stub`'s own docs, the stub is boot-stage-only code
that runs "before transitioning into the Linux kernel environment"; addon
files are parsed and verified by the stub itself, before the kernel — let
alone any init system — starts. `systemd-stub` ≠ `systemd-boot` ≠ systemd as
PID 1. FOS could adopt a UKI, and even the addon mechanism, while keeping
BusyBox init untouched at runtime. The only new dependency is the stub binary
glued onto the kernel and `ukify`/`objcopy` as host-side build tooling — not a
runtime one. This was the one plausible hard blocker and it isn't one.

**2. `rhboot/shim-review` does not literally require a UKI.** Its actual
docs ask submitters to "address how secure boot is enforced in \[their\] boot
stack and how \[their\] boot stack prevents execution of unauthenticated
code" — UKI is one accepted answer, not the requirement itself. ADR 0010
already reached the same conclusion independently. What a reviewer will
actually push on is FOS's specific current shape: a signed kernel that hands
control to an initrd and cmdline supplied by whatever answered DHCP, which is
most of the way back to the bypass Secure Boot exists to prevent — UKI is the
straightforward fix for *that* shape, even though nothing mandates it by name.

**3. Real precedent exists for "generic signed image, config fetched after
boot."** Talos Linux boots a single signed UKI (shim → signed systemd-boot →
signed UKI) into what it calls "maintenance mode," with no per-node config
baked in, then an operator pushes node-specific config over an authenticated
network call after boot. This is the closest real-world analogue to the shape
FOS would need, and it is not a pattern FOS would be inventing from scratch.
Kairos and Flatcar take a related but distinct approach — dynamic config as
*data* consumed by already-trusted userspace, rather than dynamic *cmdline*
driving the kernel's own security posture — which is a materially different
(weaker, for this purpose) trust boundary and not the one recommended below.
FOS already carries a smaller version of the same idea internally: USB boot
(where iPXE cannot inject a cmdline at all) already fetches config over the
network keyed by MAC/system UUID and sources it at runtime —
`bin/fog:4-11` POSTs to `hostinfo.php`, writes the response to
`/tmp/hinfo.txt`, and sources it before dispatch. That path still depends on
`$web` already being known (see below), but it is evidence the general shape
already works in this codebase, not just at Talos's scale.

**4. Adopting a UKI does not touch the custom kernel.** A UKI is an assembly
step on top of the *same* `bzImage` `build.sh` already produces — it changes
nothing about kernel configuration, the built-in Realtek drivers, the Intel
VMD patch, or the no-external-modules build. Those are Kconfig/source-tree
concerns; the UKI only staples the finished kernel binary, the initrd, and a
cmdline into one signed PE file. The two reasons FOS carries a custom kernel
at all (ADR 0010) are unaffected by anything in this ADR.

## Decision

**Go**, via a generic-signed-UKI-plus-runtime-checkin redesign, not a
per-boot signed addon:

- **Base UKI**: FOS's kernel + initrd + a fixed, minimal cmdline — no `mode=`,
  `type=`, host identity, or `web=` — signed once per FOS release, identical
  for every deployment and every boot. This is the artifact `build.sh` would
  produce and sign, replacing today's separate `bzImage`/`init.xz` signing.
- **Server-known task data moves into the existing checkin round-trip.**
  `bin/fog.checkin:50-72` already POSTs `mac`/`type`/`sysuuid` to
  `${web}service/Pre_Stage1.php` and blocks until the server answers `##@GO` —
  the shape of an authenticated runtime handshake already exists. Extend that
  response from a bare `##@GO` into a real payload carrying `mode`, `type`,
  image id, and other data the FOG server already decides. Everything
  downstream just reads the environment `funcs.sh:9-13` currently populates
  from `/proc/cmdline` — not the cmdline directly — so replacing that one
  export point is enough to cover `$mode`/`$type`/image-id-class variables
  without touching the dozens of files (`$web` alone appears in 18) that
  merely consume the resulting env vars. This covers the data the *server*
  decides. It does **not** cover the two subclasses below.
- **`web=` cannot be solved by the checkin redesign at all, and is not a
  coin flip between two equally-fine options.** `S40network:48` calls
  `curl "${web}"/index.php` immediately after DHCP just to confirm the network
  came up — before `fog.checkin` or any runtime round-trip is reachable. A
  runtime checkin cannot supply the address of the server it needs to reach to
  perform that checkin. This has to be solved by something present *before*
  any network call: a signed per-deployment addon UKI carrying just `web=`
  (signed with that FOG install's own key, reusing #961's infrastructure), or
  deriving it from the DHCP/PXE next-server field already received during
  network boot. Left as a follow-up spike, but not optional the way the
  wording above might imply — some such mechanism is required.
- **Boot-menu flags chosen by a human are a separate, unaddressed subclass.**
  `$isdebug`, `$keymap`, `$mdraid`, `$chkdsk`, `$mc`, `$setmacto` (used in
  `S40network`, `fog.checkin`, `S99fog`, `partition-funcs.sh`, and elsewhere)
  are picked at iPXE's interactive boot menu, before any FOG-server round-trip
  and independent of whatever task the server has scheduled. "Move task
  selection into checkin" does not cover these, because the server has no way
  to know what a human just chose in the menu unless iPXE tells it first —
  which means a second, separate network call (from iPXE, at menu-selection
  time, keyed by MAC) reporting the choice so the server can hand it back
  during the later checkin. That call has the same `web=`-bootstrap
  dependency as everything else here. This subclass needs its own design pass
  before implementation starts; this ADR does not resolve it.

## What this does not resolve

- **The `web=` bootstrap mechanism** — two candidates named above, neither
  chosen, and not optional (some such mechanism is required, since nothing
  else here can bootstrap it). Needs a short, separate spike before
  implementation starts.
- **The boot-menu-flags subclass** (`isdebug`, `keymap`, `mdraid`, `chkdsk`,
  `mc`, `setmacto`, …) — needs its own design pass; "move task selection to
  checkin" does not cover data a human chooses at the iPXE menu rather than
  data the FOG server already knows.
- **`fog.checkin`'s TLS is unverified today** (`curl -k`). That is not a new
  problem this ADR introduces, but the channel becomes more load-bearing once
  it also carries task selection, not just image content — worth tightening
  as companion hardening, not a blocker to adopting UKI itself.
- **This is a two-repo change.** FOGProject/fogproject's iPXE-generation logic
  and `Pre_Stage1.php` (or its successor) need corresponding updates to stop
  building a per-host cmdline and start answering the extended checkin instead.
  That work is out of scope here but has to land in lockstep with anything
  done in this repo.
- **Nothing has been built or booted.** Per the precedent ADR 0003 and ADR
  0010 both set, this conclusion should not be treated as de-risked until a
  real x64 build actually produces and boots a signed UKI end-to-end, and a
  machine images successfully off of it.
- **The lockdown-on-Secure-Boot patch itself** (ADR 0010) remains separate,
  future work. This ADR unblocks it; it does not implement it.

## Consequences

- Unblocks ADR 0010's lockdown-activation patch and the shim-review
  application tracked in FOGProject/fogproject#995 — but only once the
  runtime-checkin redesign above is actually built, not on the strength of
  this decision alone.
- Shrinks what iPXE has to construct at boot: today, a full host-specific
  cmdline per boot; after, chainloading one fixed signed UKI for every host.
  That is a net simplification on the fogproject side, not purely a security
  tax paid for shim-review's benefit.
- Adds a new build-time dependency: assembling the UKI (kernel + initrd + PE
  sections) requires stub/tooling (`ukify`, `objcopy`) beyond the kernel's own
  `CONFIG_EFI_STUB`, which `build.sh` does not currently carry.

## References

- FOGProject/fogproject#995 (successor to the now-closed #962), the tracking
  issue this ADR answers.
- ADR 0010 (`secure-boot-kernel-hardening`), "Settle the initrd question
  before going further."
- UAPI Group Unified Kernel Image specification —
  <https://uapi-group.org/specifications/specs/unified_kernel_image/>
- `systemd-stub(7)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html>
- `rhboot/shim-review` — <https://github.com/rhboot/shim-review>
- Talos Linux, Secure Boot on bare metal —
  <https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/bare-metal-platforms/secureboot>
- `bin/fog.checkin:50-72`, `usr/share/fog/lib/funcs.sh:9-13` — the existing
  runtime-checkin and cmdline-parsing code this decision builds on.
