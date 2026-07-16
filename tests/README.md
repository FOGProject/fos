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
tests/checks/wipe.sh          # wipeDisk() issues the right erase primitive per
                              # device class (NVMe/SSD/HDD) and mode
                              # (fast/normal/full), never issues an `nvme format`
                              # without an explicit --ses, warns that overwriting
                              # an SSD is not a guaranteed erase, and refuses
                              # instead of reporting a wipe that did not run
```

Like the golden harness, these source a sandbox copy of the library with its
hardcoded paths rewritten and the external tools stubbed, so they run on any
host without hardware.
