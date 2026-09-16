# Add Microsoft's 2023 CAs to db in User Mode

Windows servicing is replacing the Windows boot manager with one signed by
**Windows UEFI CA 2023**. An image captured after that change carries the new
boot manager on its EFI system partition. A target whose firmware `db` holds
only the 2011 Microsoft CAs refuses it. Shim reports
`Verification failed: Security Policy Violation`, and the firmware's own boot
path finds nothing it can start.

We decided **`fog.enrollsb` adds the 2023 CAs to `db` on a machine in User
Mode, by applying Microsoft's own signed db updates as append writes.**

## The failure this closes

Forums topic 18246. Dell OptiPlex 3000 thin clients, Secure Boot on, FOG's
certificate already enrolled through MokManager. The golden machine was
installed with Secure Boot on and had taken the Windows servicing update. Every
deployed target failed to boot Windows until the admin turned Secure Boot off
and ran `bcdboot`, which rewrote the boot files with a boot manager the
firmware accepted. The next re-image broke it again. FOG wrote the disk
correctly; the target firmware did not trust it.

The cause is not confirmed on that hardware yet. The symptoms match exactly,
and Microsoft's KB5025885 describes this failure for media and images used on a
device that has not received the db update.

## Why FOS can do it

`db` is an authenticated variable. In User Mode, a write needs a signature
from a key in `KEK`. ADR-0009 says a running OS cannot bootstrap its own trust,
and that stays true: this path adds **Microsoft's** CAs, signed by
**Microsoft's** key, which the firmware already trusts.

Microsoft publishes each 2023 CA as a signed db update in
`microsoft/secureboot_objects` (`PostSignedObjects/Optional/DB/`). Each is an
`EFI_VARIABLE_AUTHENTICATION_2` signed by **Microsoft Corporation KEK CA 2011**,
which is in `KEK` on nearly every PC. Windows servicing and fwupd apply the same
files the same way.

FOS ships them in `/usr/share/fog/secureboot/`, byte-identical to that repo
(`MANIFEST` lists the sources and hashes). The CA certificates are the same
bytes the FOG server pins in `packages/secureboot/mscerts`.

## The rules

- **Append, never replace.** The write carries attribute `0x67`
  (`0x27 | APPEND_WRITE`). Microsoft signed the update with the append bit set,
  and the signature covers the attributes. So a `0x27` write of the same payload
  fails the signature check, and nothing is added. OVMF refused it in the lab
  run below. A firmware that skipped that check would replace `db` with one CA.
- **Only where the 2011 counterpart is trusted.** Windows UEFI CA 2023 needs
  Microsoft Windows Production PCA 2011 in `db`. Microsoft UEFI CA 2023 and the
  Option ROM UEFI CA 2023 need Microsoft Corporation UEFI CA 2011. This is
  Microsoft's own rule. A machine whose owner removed Windows or third-party
  trust does not get it back from FOG.
- **Check `KEK` before any write.** Without Microsoft's KEK the firmware rejects
  every update, so the task warns and continues with FOG's own enrollment
  instead of failing.
- **Confirm from the firmware.** After each write, `db` is re-read and the CA's
  bytes are searched for. A write the firmware accepted but did not apply is a
  failure (ADR-0003), not a success.
- **Setup Mode skips this.** `sbEnrollDb` writes a `db` that already carries all
  three 2023 CAs.
- **Runs before the "already trusted" exit.** The machine in the forum post
  already trusted FOG's certificate. A check placed after that exit would never
  run on it.
- **Only in `fog.enrollsb`**, never during a deploy. Changing firmware inside an
  imaging task is a behavior change nobody asked for.

## Not done

- **`dbx`.** Revoking the 2011 Windows CA is Microsoft's later stage and can make
  older media unbootable. FOS does not touch `dbx`.
- **`KEK` 2023.** Adding Microsoft Corporation KEK 2K CA 2023 needs a
  PK-signed update, and every OEM signs its own. There is no single file to ship.
- **A deploy-time warning** that the image's boot manager needs a CA the target
  lacks. It would name the cause at the moment it happens. Left for a follow-up.

## Validation

Run on 2026-09-16 on OVMF (edk2-ovmf 20260508, QEMU q35 with SMM, so the
variable store is firmware-protected). The rig is `/images/claude-lab/sb-2023ca`.
A factory-like key set was enrolled first: `db` with the two 2011 Microsoft CAs
and the lab kernel's signer, `KEK` with Microsoft Corporation KEK CA 2011 only,
and a lab `PK`. Then, in User Mode with Secure Boot enforcing:

| Check | Result |
|---|---|
| `sbMsDbUpdate` | rc 0, all three 2023 CAs added; `db` 3,974 → 8,467 bytes |
| 2011 CAs and the lab signer after the append | still present; the kernel booted again |
| Same payload with one byte changed | refused |
| Same payload written with `0x27` | refused, `db` unchanged |
| Reboot | 2023 CAs persist; a second run adds nothing |

## Risk

Some firmware handles append writes badly, which is one reason Microsoft rolled
this out in stages. A rejected write leaves `db` unchanged. A firmware that
accepts the write and then misbehaves is only visible on physical hardware, and
none has run this yet.

Guarded by `tests/checks/secureboot.sh`, cases 41–50, which use the shipped
Microsoft files rather than stand-ins.
