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
