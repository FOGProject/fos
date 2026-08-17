#!/bin/bash
#
# Assertion harness for seedCabextract() in build.sh.
#
#   tests/checks/cabextract-mirrors.sh   # run all cases, exit non-zero on any failure
#
# What is under test is "which mirror did we fall through to, and did we refuse
# bytes that don't match the hash" -- pass/fail behaviour a golden output stream
# can't express, so this is a checks/ harness rather than a golden case.
#
# The regression that motivated it: cabextract is one of FOG's own Buildroot
# packages, so sources.buildroot.net has never carried it, and Buildroot allows a
# package exactly one _SITE. That left www.cabextract.org.uk as the only source
# for the package, and it is not dependable -- it 404'd during the 2026-08-03
# release build and every one of its addresses timed out from GitHub's runners
# during the 2026-08-17 experimental build, each time discarding a six-job,
# ~50-minute release. seedCabextract() is the mirror list that Buildroot itself
# has nowhere to put.
#
# Mechanism mirrors tests/checks/wipe.sh: extract the functions into a sandbox,
# PATH-shadow the external tool (wget) with a deterministic stub, and exercise
# the real function.
#
# Fully offline, deliberately. The stub serves a locally generated fixture and
# the sandbox gets its own cabextract.mk/.hash describing that fixture, so no
# case here touches the network and none of them depends on upstream still
# serving cabextract 1.11. What that cannot cover is whether the *committed*
# hash still matches the *real* tarball -- that needs the network, so it belongs
# in a build, not here. The last two cases assert what can be checked offline
# about the shipped files instead.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
BUILD_SH="$REPO/build.sh"
REAL_PKG="$REPO/Buildroot/package/cabextract"

[[ -f $BUILD_SH ]] || { echo "ERROR: cannot find build.sh at $BUILD_SH" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

failures=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
check() { if [[ $1 == 0 ]]; then pass "$2"; else fail "$2"; fi; }

# --- the functions under test, lifted out of build.sh ---
# build.sh runs a whole build when executed, so the two functions are extracted
# rather than sourced. If either header ever changes shape this stops finding
# them, which the guard below turns into a loud failure instead of a silent
# zero-case pass.
{
    sed -n '/^function dots()/,/^}/p' "$BUILD_SH"
    sed -n '/^function seedCabextract()/,/^}/p' "$BUILD_SH"
} > "$SANDBOX/lib.sh"
if ! grep -q '^function seedCabextract()' "$SANDBOX/lib.sh"; then
    echo "ERROR: could not extract seedCabextract() from build.sh" >&2
    exit 2
fi
# shellcheck disable=SC1091
source "$SANDBOX/lib.sh"

# --- fixture, and a package dir that describes it ---
# seedCabextract() reads the version out of cabextract.mk and the hashes out of
# cabextract.hash, and resolves them at ../Buildroot/package/cabextract relative
# to the Buildroot tree it is called from. Giving the sandbox its own pair is
# what keeps this test offline: the "tarball" is 64KB of deterministic bytes.
VERSION=9.9
TARBALL="cabextract-$VERSION.tar.gz"
PKGDIR="$SANDBOX/Buildroot/package/cabextract"
mkdir -p "$PKGDIR" "$SANDBOX/fssourcex64"

FIXTURE="$SANDBOX/fixture.tar.gz"
head -c 65536 /dev/zero | tr '\0' 'F' > "$FIXTURE"
FIX_SHA256=$(sha256sum "$FIXTURE" | cut -d' ' -f1)
FIX_SHA512=$(sha512sum "$FIXTURE" | cut -d' ' -f1)

cat > "$PKGDIR/cabextract.mk" <<EOF
CABEXTRACT_SITE=https://www.cabextract.org.uk
CABEXTRACT_VERSION=$VERSION
EOF
write_hash() {
    : > "$PKGDIR/cabextract.hash"
    echo "sha256  $FIX_SHA256  $TARBALL" >> "$PKGDIR/cabextract.hash"
    [[ $1 == with-sha512 ]] && echo "sha512  $FIX_SHA512  $TARBALL" >> "$PKGDIR/cabextract.hash"
    return 0
}
write_hash with-sha512

# --- wget stub ---
# Serves the fixture, except for hosts named in $BLOCK (connection failure, the
# 2026-08-17 mode) or $TAMPER (a 200 carrying the wrong bytes). Every URL it is
# asked for is logged so a case can assert which mirrors were actually tried.
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/wget" <<'EOF'
#!/bin/bash
url="${!#}"; out=""; prev=""
for a in "$@"; do [[ $prev == "-O" ]] && out="$a"; prev="$a"; done
echo "$url" >> "$STUB_LOG"
for h in $BLOCK; do
    [[ $url == *"$h"* ]] && exit 4
done
for h in $TAMPER; do
    [[ $url == *"$h"* ]] && { printf 'wrong-bytes' > "$out"; exit 0; }
done
cp "$STUB_FIXTURE" "$out"
EOF
chmod +x "$STUBBIN/wget"
export PATH="$STUBBIN:$PATH"
export STUB_FIXTURE="$FIXTURE"

# seedCabextract() resolves its package dir relative to the working directory,
# the same way build.sh calls it from inside fssource<arch>.
cd "$SANDBOX/fssourcex64" || exit 2

UPSTREAM=www.cabextract.org.uk
DEBIAN=deb.debian.org
FEDORA=src.fedoraproject.org

# Runs one case with a clean download dir and a clean stub log.
# Usage: seed <case-name>; then inspect $DL/$TARBALL and $STUB_LOG.
seed() {
    DL="$SANDBOX/dl-$1"
    export STUB_LOG="$SANDBOX/log-$1"
    rm -rf "$DL"; : > "$STUB_LOG"
    shift
    seedCabextract "$DL" > "$SANDBOX/out-$$" 2>&1
    SEED_RC=$?
    SEED_OUT="$SANDBOX/out-$$"
    SEEDED="$DL/cabextract/$TARBALL"
}
is_fixture() { [[ -f $1 ]] && [[ $(sha256sum "$1" | cut -d' ' -f1) == "$FIX_SHA256" ]]; }

echo "== seedCabextract() =="

# 1. Happy path: upstream is tried first and its bytes are kept.
seed upstream
is_fixture "$SEEDED"; check $? "seeds the tarball when upstream answers"
[[ $(wc -l < "$STUB_LOG") -eq 1 && $(head -1 "$STUB_LOG") == *"$UPSTREAM"* ]]
check $? "tries upstream first and stops there"
[[ -z $(find "$DL/cabextract" -name '.*' -type f) ]]
check $? "leaves no temporary files behind"

# 2. A cached tarball that is already correct is not re-fetched. This is the
#    case that makes the GH Actions ~/.buildroot-dl cache worth having.
before=$(stat -c %Y "$SEEDED")
export STUB_LOG="$SANDBOX/log-cached"; : > "$STUB_LOG"
seedCabextract "$DL" >/dev/null 2>&1
[[ $(stat -c %Y "$SEEDED") == "$before" && ! -s $STUB_LOG ]]
check $? "leaves an already-valid cached tarball alone, with no network call"

# 3. A cached tarball that does NOT match is replaced rather than trusted --
#    a corrupt entry in the Actions cache must not become a corrupt build.
printf 'stale-garbage' > "$SEEDED"
export STUB_LOG="$SANDBOX/log-repair"; : > "$STUB_LOG"
seedCabextract "$DL" >/dev/null 2>&1
is_fixture "$SEEDED"; check $? "replaces a cached tarball whose hash no longer matches"

# 4. The failure that actually happened: upstream unreachable, Debian covers.
BLOCK="$UPSTREAM" seed fallback1
is_fixture "$SEEDED"; check $? "falls through to Debian when upstream is unreachable"

# 5. Two down, Fedora's lookaside covers.
BLOCK="$UPSTREAM $DEBIAN" seed fallback2
is_fixture "$SEEDED"; check $? "falls through to the Fedora lookaside when Debian is down too"
grep -q "$FEDORA/repo/pkgs/cabextract/$TARBALL/sha512/$FIX_SHA512/" "$STUB_LOG"
check $? "addresses the Fedora lookaside by the sha512 from cabextract.hash"

# 6. Everything down: warn, clean up, and hand back to Buildroot. Returning
#    non-zero here would abort the build before Buildroot ever got its own try.
BLOCK="$UPSTREAM $DEBIAN $FEDORA" seed alldown
[[ $SEED_RC -eq 0 ]]; check $? "returns 0 when every mirror is down, leaving the download to Buildroot"
[[ ! -f $SEEDED && -z $(find "$DL" -type f 2>/dev/null) ]]
check $? "leaves nothing behind when every mirror is down"
grep -q "WARNING" "$SEED_OUT"; check $? "warns when every mirror is down"

# 7. A mirror serving the wrong bytes must never be cached, whatever the reason.
TAMPER="$UPSTREAM" seed tampered
is_fixture "$SEEDED"; check $? "rejects a mirror serving the wrong bytes and keeps looking"

# 8. Without a sha512 line the Fedora URL cannot be built, so the mirror is
#    dropped rather than requested with an empty hash path (which would 404).
#    This is why cabextract.hash carries a sha512 it does not strictly need.
write_hash sha256-only
BLOCK="$UPSTREAM $DEBIAN" seed nosha512
[[ ! -f $SEEDED ]] && ! grep -q "$FEDORA" "$STUB_LOG"
check $? "drops the Fedora mirror when cabextract.hash has no sha512, rather than building a broken URL"
write_hash with-sha512

echo "== shipped package files =="

# Offline assertions about the real files, guarding the two invariants above
# that a well-meaning cleanup would otherwise quietly break.
grep -qE '^sha256[[:space:]]' "$REAL_PKG/cabextract.hash"
check $? "cabextract.hash carries a sha256 (Buildroot refuses to verify without it)"
grep -qE '^sha512[[:space:]]' "$REAL_PKG/cabextract.hash"
check $? "cabextract.hash carries a sha512 (build.sh builds the Fedora URL from it)"
grep -q '^CABEXTRACT_SITE=https://' "$REAL_PKG/cabextract.mk"
check $? "cabextract.mk fetches over https, not the http that egress filtering drops"

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
