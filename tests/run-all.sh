#!/usr/bin/env sh
#
# Runs every FOS dev test and reports one line each.
#
# The convention these tests already follow -- standalone scripts, exit 0 for
# pass and non-zero for fail, no framework and no hardware -- was documented in
# tests/README.md but had no runner, so "the FOS tests pass" meant a human
# remembering sixteen commands and reading sixteen summaries. It also meant
# there was nothing for CI to call: fos has four workflows and all of them are
# release or dispatch, so until now not one of these assertions had ever run
# anywhere but on a maintainer's laptop.
#
# Modelled on fogproject's tests/run-all.sh, deliberately: the two projects are
# maintained by the same people and a suite that reports differently in each is
# a suite people read less carefully.
#
# Usage: sh tests/run-all.sh
# Exit status 0 = every test passed, 1 = at least one failed.

testdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# gawk, not any awk. procsfdisk.awk uses asort() and PROCINFO and funcs.sh uses
# gensub(), all of which are gawk extensions -- so this is a requirement of the
# CODE, not of the harness. Measured with `gawk --traditional`, three checks
# (fill-engine, mbr-extended, resize-engine) fail without them, and they fail as
# wrong ARITHMETIC rather than as a syntax error: asort() is simply an unknown
# function whose absence reorders a partition table. That reads as a broken
# partition engine rather than as a missing package, which is why this refuses
# up front instead of letting the suite report it.
#
# Debian and Ubuntu ship mawk as the default awk, so this fires on a stock
# runner and on plenty of developer machines.
# gensub() is the probe rather than asort() or PROCINFO because it is the only
# one of the three whose absence is a hard error: a missing asort() is an
# unknown function call, and PROCINFO in a non-gawk awk is just an empty array.
if ! awk 'BEGIN { exit (gensub(/a/, "b", "g", "aa") == "bb") ? 0 : 1 }' </dev/null 2>/dev/null; then
    printf 'ERROR: awk on this system is not gawk.\n' >&2
    printf '       FOS uses asort(), PROCINFO and gensub(), which are gawk\n' >&2
    printf '       extensions. Install gawk (Debian/Ubuntu: apt install gawk).\n' >&2
    exit 2
fi

pass=0
fail=0
failed=''

run_one() {
    name=$1
    shift

    # Output is captured rather than streamed so a passing test contributes one
    # line instead of its own hundred; a failing one gets its output replayed in
    # full below, which is when it is actually wanted.
    out=$("$@" 2>&1)
    status=$?

    if [ $status -eq 0 ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1))
        failed="$failed $name"
        printf 'FAIL  %s (exit %d)\n' "$name" "$status"
        printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

# bash, not sh. Every check carries a #!/bin/bash shebang and uses bash-only
# constructs -- [[ ]], arrays, ${BASH_SOURCE[0]}, ${var//pat/rep} -- because the
# code they exercise (funcs.sh, partition-funcs.sh) is itself bash and cannot be
# sourced by anything else. Running them with `sh` works only where /bin/sh
# happens to BE bash; on Debian and Ubuntu it is dash, and there they die on
# "Bad substitution" before running a single assertion, which reads as a failing
# suite rather than a mis-invoked one.
for t in "$testdir"/checks/*.sh; do
    [ -f "$t" ] || continue
    run_one "$(basename "$t")" bash "$t"
done

# The golden harness is a different shape -- one command with a subcommand, and
# `check` is the only one that asserts anything. `capture` overwrites the
# fixture, which would make the suite unconditionally green, so it is never what
# a runner calls.
if [ -x "$testdir/golden/run.sh" ]; then
    run_one 'golden/run.sh check' "$testdir/golden/run.sh" check
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"

if [ $fail -gt 0 ]; then
    printf 'failed:%s\n' "$failed" >&2
    exit 1
fi

exit 0
