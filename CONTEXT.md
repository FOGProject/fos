# FOS — Context Glossary

A shared vocabulary for the FOS (FOG Operating System) imaging environment.
Glossary only — no implementation details, no decisions. Decisions that are hard
to reverse live in `docs/adr/`.

## Sector geometry

- **512n** — Drive with 512-byte *physical* and 512-byte *logical* sectors.
  Legacy geometry. The OS issues 512-byte I/O.

- **512e** — Drive with 4096-byte *physical* sectors but 512-byte *logical*
  sectors (512-emulation). The overwhelming majority of "4K" SSDs/NVMe. The OS
  still sees 512-byte logical sectors, so anything captured on 512n deploys onto
  512e unchanged. For imaging purposes, 512e behaves as 512.

- **4Kn** — Drive with 4096-byte *physical* and 4096-byte *logical* sectors
  ("4K native"). The OS issues 4096-byte I/O and cannot do sub-4K logical
  access. Rare: mostly enterprise SAS and NVMe reformatted to a 4K LBA format.

- **Logical sector size** — The sector size the OS/filesystem sees and addresses
  by. This is the number that matters for imaging: it is baked into partition
  tables (LBA units) and filesystem metadata at capture time.

- **LBA format (LBAF)** — On NVMe, a drive-supported sector-size mode. Many
  NVMe drives expose both a 512-byte and a 4096-byte LBAF and can be switched
  between them with `nvme format` (destructive). SATA drives generally cannot
  change their logical sector size.

## Imaging model

- **Geometry mismatch** — The core problem: a captured image's partition table
  (LBA units) and filesystem metadata (e.g. NTFS `$Boot` `bytes_per_sector`)
  encode the *source drive's logical sector size*. Deploying onto a target with a
  different logical sector size produces a filesystem whose declared geometry
  contradicts the device, so the OS will not mount/boot. Applies in both
  directions (512→4Kn and 4Kn→512).

- **partclone image** — FOG's filesystem-aware capture format for supported
  filesystems (NTFS, ext, etc.). Stores used blocks plus the filesystem's own
  metadata. It restores the filesystem verbatim; it does **not** rewrite the
  filesystem's sector/cluster geometry, which is why geometry mismatch is not
  fixed by the restore path.
