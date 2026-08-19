# FOS dev test harnesses

Dev-only tests. They live outside `Buildroot/board/FOG/FOS/rootfs_overlay`, so
nothing here ever enters the built init.

## golden/ — output differential harness

Proves that refactors of the shared libraries (`funcs.sh`,
`partition-funcs.sh`) change no observable output. It drives the
deterministic, refactor-targeted functions over a fixed battery of inputs and
compares the result against a committed fixture:

```sh
tests/golden/run.sh capture   # write fixtures/golden.txt (run BEFORE a refactor)
tests/golden/run.sh check     # regenerate and assert byte-identical to the fixture
tests/golden/run.sh print     # dump current output to stdout
```

Covered: every `*FileName()` output string, the `doInventory` dmidecode and
base64 blocks, and the `changeHostname` registry `EOFREG` file contents.

The library hardcodes `/usr/share/fog/lib` paths and calls hardware tools, so
the harness sources a sandbox copy with those paths rewritten and the external
tools stubbed deterministically. The fixture is therefore machine-independent.

Workflow for a refactor: run `check` on a clean tree (should pass against the
committed fixture), make the change, run `check` again — it must still pass.

## checks/ — assertion harnesses

Pass/fail assertions for behaviour that a single golden output stream can't
express (e.g. "does this function abort or not?"). Each script runs a battery of
cases and exits non-zero if any fail.

```sh
tests/checks/sector-size.sh   # validateImageSectorSize() refuses on a
                              # logical-sector-size mismatch, allows on match,
                              # reformats an NVMe target to the image's sector
                              # size when it exposes a matching LBA format, and
                              # names the device class (eMMC/UFS/virtual/NVMe)
                              # in the refusal when the target's size is fixed
tests/checks/fill-engine.sh   # the whole-disk fill engine (processSfdisk +
                              # fillSfdiskWithPartitions + fill_disk in the awk):
                              # 4Kn sector-size rescaling keeps a small partition
                              # alive, the GPT backup-header clamp holds, and an
                              # unusable computed table aborts instead of being
                              # written
tests/checks/mbr-extended.sh  # MBR tables carrying an extended partition with
                              # logicals inside it (issue #150): the emitted
                              # table is ordered by partition number so sfdisk
                              # never meets a logical before its container, each
                              # logical keeps a gap for its EBR, the container is
                              # sized from its contents rather than scaled, and
                              # savePartition/restorePartition treat it as a
                              # container rather than partclone'ing it. Where a
                              # real sfdisk is present each computed table is
                              # also applied to a sparse file
tests/checks/error-report.sh  # the failure report handleError() sends to
                              # service/taskerror.php (fogproject#1206): it goes
                              # to the right URL with mac, sysuuid and the
                              # message, it is time bounded and url-encoded, the
                              # "\n" the callers embed is expanded before
                              # sending, nothing it does reaches the operator's
                              # console, a failed report still lets handleError
                              # reach its reboot notice, and no $web means no
                              # attempt at all
tests/checks/wipe.sh          # wipeDisk() issues the right erase primitive per
                              # device class (NVMe/SSD/HDD) and mode
                              # (fast/normal/full), never issues an `nvme format`
                              # without an explicit --ses, warns that overwriting
                              # an SSD is not a guaranteed erase, and refuses
                              # instead of reporting a wipe that did not run
tests/checks/secureboot.sh    # secureboot-funcs.sh: derives the right firmware
                              # state from efivarfs (keeping Setup Mode distinct
                              # from "Secure Boot merely off"), rejects a
                              # non-certificate download, and stages the MOK
                              # request non-interactively without ever putting
                              # the one-time password on a mokutil argv --
                              # refusing when mokutil exits 0 having staged
                              # nothing. Also covers the Setup Mode db path:
                              # db goes to the image-security GUID and not the
                              # global one, the attribute prefix carries the
                              # authenticated-write bit, the variable is written
                              # in a single full-block dd, PK is written LAST,
                              # a failed download writes nothing at all, and a
                              # SetupMode that does not flip 1 -> 0 is a refusal
                              # rather than a success
tests/checks/secureboot-config.sh
                              # configs/kernel*.config carry the Secure Boot
                              # hardening symbols (lockdown LSM in CONFIG_LSM,
                              # platform keyring, no CONFIG_KEXEC). See ADR-0010
tests/checks/pcie-aspm-config.sh
                              # configs/kernel*.config leave the kernel able to
                              # control PCIe ASPM: CONFIG_PCIEASPM, CONFIG_PCI_
                              # MMCONFIG on x86, a non-power-saving ASPM policy.
                              # Without these, pci_disable_link_state() is a stub
                              # that reports success, and r8169 enables ASPM and
                              # L1.2 on the NIC believing the OS disabled L1 --
                              # a ~5x deploy throughput loss. See ADR-0013
tests/checks/package-mirrors.sh
                              # build.sh's package-mirror seeding: resolves each
                              # package's version/source/site out of its own .mk
                              # (including Buildroot's github macro), falls
                              # through upstream -> Debian -> Fedora lookaside,
                              # refuses a source serving bytes that don't match
                              # the package's .hash, repairs rather than trusts a
                              # cached tarball whose hash no longer matches,
                              # skips a package that has no .hash, and returns 0
                              # when every source is down so Buildroot still gets
                              # its own attempt. Also covers bump-package.sh:
                              # a bump rewrites version and hashes together and
                              # drops the superseded lines, a failed download
                              # restores the .mk rather than leaving a half-bump,
                              # and --dry-run writes nothing
```

Like the golden harness, the library harnesses source a sandbox copy of the
library with its hardcoded paths rewritten and the external tools stubbed, so
they run on any host without hardware.

`package-mirrors.sh` is the one harness that tests `build.sh` rather than
anything shipped in the init. It follows the same sandbox-and-stub pattern —
the functions come from `package-funcs.sh` (they live there rather than in
`build.sh`, which would run a whole build if sourced), `wget` is PATH-shadowed,
and the seeding cases run against
a synthetic package whose `.mk`/`.hash` describe a locally generated fixture.
That last part is what keeps it offline: no case touches the network, and none
depends on any upstream still serving a given release. Whether the *committed*
hashes still match the *real* tarballs is a question only a build can answer.

The URL-resolution and shipped-file groups do read the real
`Buildroot/package/*/` files, since both are pure text checks — that each
package's site resolves to the URL Buildroot will actually request, and that
every mirrored package still carries the hashes its mirrors are addressed by.

The two `*-config.sh` harnesses are different: they assert on the kernel
configs rather than on shell code, and take `-b` to additionally inspect the
post-`oldconfig` `.config` in any `kernelsource<arch>/` present. That mode is
the one that proves anything, because `make oldconfig` silently drops symbols
whose dependencies are unmet — a config can look correct in git and still build
a kernel without the feature.
