# 0012 — A Microsoft-signed FOG shim: the long game, recorded before it's lost

## Status

Proposed. Research recorded, no work started. This is the only route that
removes Secure Boot enrolment entirely rather than automating it further; it
is a multi-month, ongoing-cost undertaking and should be weighed as one before
anyone starts.

## Context

Every path in [ADR-0009](0009-secure-boot-enrolment-paths.md) — MOK staging,
Setup Mode `db` writes, out-of-band BMC — asks for something at the machine:
a technician's confirmation, a firmware visit, or a BMC that happens to expose
the right API. All of them exist because FOG's certificate has to become
trusted *somewhere*, and only Microsoft's signature is trusted everywhere by
default. A shim of FOG's own, signed by Microsoft with FOG's certificate baked
in as the vendor certificate, is the only way to make a FOG-signed kernel boot
out of the box on stock hardware with no enrolment step at all.

This is tracked upstream as FOGProject/fogproject#995 (successor to the
now-closed #962, which did the initial investigation). Nothing here has been
started; this ADR exists so the research already done in those two issues
lives in this repo too, rather than only in GitHub.

## The gate, already settled

#995 states its own precondition directly: "nothing else here is worth
starting until \[the UKI question\] is answered." FOS boots as `bzImage` plus
a per-host cmdline built dynamically by iPXE, plus an unsigned ext2 initrd — a
signed kernel handing control to an initrd and cmdline supplied by whatever
answered DHCP is close to the exact thing shim exists to prevent, and a
reviewer will push hard on that shape.

[ADR-0011](0011-unified-kernel-image-feasibility.md) answers this: **Go**, via
a generic signed UKI (fixed minimal cmdline, no per-host data) plus moving task
selection into the existing `fog.checkin` round-trip. That decision is
proposed, not built or booted end-to-end — this ADR does not re-litigate it,
only builds on top of it. Nothing below is worth starting until ADR-0011's
redesign actually ships.

## Why `ipxe/shim` cannot be reused

Worth stating plainly so it isn't attempted and rediscovered as a dead end.
`ipxe/shim` trusts exactly one thing — the iPXE Secure Boot CA — and derives
its second stage from its own filename (the tarball ships `ipxe-shim.efi` and
`snponly-shim.efi` as symlinks to one `shimx64.efi` for exactly this reason).
There is no downstream hook, by design: a shim that loaded any binary calling
itself iPXE would be worthless as a security boundary. Nothing FOG builds can
satisfy it. A Microsoft-signed FOG shim means building and maintaining FOG's
own fork of `rhboot/shim`, with FOG's own vendor certificate compiled in —
not repurposing iPXE's.

## Precedent not to follow

[abotzung/foguefi](https://github.com/abotzung/foguefi) looks like it solves
this but sidesteps it instead: it downloads Canonical's pre-signed
`shimx64.efi` + `grubx64.efi` + Ubuntu's signed kernel, and carries FOG's
imaging logic in an unsigned initrd. There is no FOS kernel anywhere in that
chain, iPXE is dropped entirely, and the project is archived with unfinished
docs. It demonstrates that *a* signed chain can be made to boot something,
not that FOG's own kernel can be trusted anywhere without either MOK/Setup
Mode enrolment or exactly the shim-signing work this ADR describes.

## Remaining checklist, from #995

- [x] Kernel config groundwork — FOGProject/fos#131 (lockdown LSM built in,
      left inactive; see ADR-0010)
- [ ] The lockdown-on-Secure-Boot activation patch. Both halves are
      downstream-only in kernel 6.18: `security_lock_kernel_down()` is not in
      mainline, nor is `efi_enabled(EFI_SECURE_BOOT)`. ADR-0010 has the hook
      point and a smaller single-file alternative.
- [ ] The UKI/runtime-checkin redesign itself (ADR-0011) — decided, not built.
- [ ] SBAT metadata, signing infrastructure, key custody — not started.
- [ ] `rhboot/shim-review` submission — not started.

## The real cost, stated plainly

Worth weighing honestly before any of the checklist above is started, because
the last item does not go away:

- An EV certificate from the Microsoft Hardware Dev Center.
- HSM or smartcard key custody for that certificate.
- A named security contact with a PGP key.
- A build from the shim 16.1 tarball using a frozen-toolchain Dockerfile.
- A vendor SBAT entry.
- A signed kernel that actually enforces lockdown (the ADR-0010 patch above).
- A volunteer-run review, two to three months minimum.
- **Permanent CVE and hash-revocation duty afterward.** This is the part to
  weigh most honestly: it is not a project that finishes.

## A clarification worth stating explicitly

#962/#995 record that fleet-scale `db` enrolment via firmware tooling is
"mostly a dead end" as a *general* answer on stock OEM hardware: `db`/`dbx`
updates must be signed by the currently-trusted `PK`/`KEK`, and on unmodified
OEM firmware that key belongs to Microsoft or the OEM, not FOG. Dell genuinely
exposes programmable custom-mode `PK`/`KEK`/`db` import via Dell Command |
Configure and iDRAC; Lenovo's ThinkBIOS Config can clear `PK` into Setup Mode
but unattended cert push is unconfirmed; HP consumer lines have no enrolment
mode at all, and HP commercial is unconfirmed.

This is a **different scenario** from a machine that has already been through
ADR-0009 Path 1, where FOG's own `PK`/`KEK` is now the one installed — on such
a machine FOG legitimately holds the signing key for future `db` updates, and
those updates are a signature check, not a firmware-tooling problem. The two
should not be conflated: "fleet-scale enrolment on stock OEM hardware is a
dead end" and "a FOG-owned platform can take further signed updates with no
Setup Mode revisit" are both true, about different machines.

## Consequences

- No code changes from this ADR alone. It records research that otherwise
  exists only in FOGProject/fogproject#995 and #962.
- Nothing here is actionable until ADR-0011's UKI/runtime-checkin redesign is
  actually built and boots on real hardware, and until ADR-0010's
  lockdown-activation patch exists.
- Starting the shim-review submission itself is an organizational commitment
  (key custody, a standing security contact, ongoing revocation duty), not
  purely an engineering task, and should be decided as such rather than as a
  natural next step once the technical prerequisites land.

## References

- FOGProject/fogproject#995 — "Secure Boot: a FOG vendor shim signed by
  Microsoft — settle the UKI question first"
- FOGProject/fogproject#962 (closed) — the parent tracking issue; source of
  the `ipxe/shim` and `foguefi` findings and the OEM-tooling survey
- [ADR-0009](0009-secure-boot-enrolment-paths.md) — the enrolment paths this
  would eventually make unnecessary for new installs
- [ADR-0010](0010-secure-boot-kernel-hardening.md) — the lockdown-activation
  patch this depends on
- [ADR-0011](0011-unified-kernel-image-feasibility.md) — the UKI gate this
  depends on, already decided
- `rhboot/shim-review` — <https://github.com/rhboot/shim-review>
