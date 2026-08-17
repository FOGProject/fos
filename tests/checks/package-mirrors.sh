#!/bin/bash
#
# Assertion harness for build.sh's package-mirror seeding.
#
#   tests/checks/package-mirrors.sh   # run all cases, exit non-zero on any failure
#
# What is under test is "which mirror did we fall through to, and did we refuse
# bytes that don't match the hash" -- pass/fail behaviour a golden output stream
# can't express, so this is a checks/ harness rather than a golden case.
#
# The regression that motivated it: all five of FOG's own Buildroot packages
# have exactly one download source each. sources.buildroot.net only carries
# packages that exist upstream in Buildroot, and none of these do, so Buildroot's
# usual backup mirror 404s for them. cabextract proved the cost twice -- it
# 404'd during the 2026-08-03 release build and timed out from GitHub's runners
# during the 2026-08-17 experimental build, each time discarding a six-job,
# ~50-minute release. seedFragileSources() is the mirror list Buildroot itself
# has nowhere to put.
#
# Mechanism mirrors tests/checks/wipe.sh: source the real functions, PATH-shadow
# the external tool (wget) with a deterministic stub, and exercise them.
#
# Fully offline, deliberately. The seeding cases run against a synthetic package
# whose .mk/.hash describe a locally generated fixture, so no case here touches
# the network and none depends on any upstream still serving a given release.
# What that cannot cover is whether the *committed* hashes still match the *real*
# tarballs -- that needs the network, so it belongs in a build, not here. The
# last two groups assert what can be checked offline about the shipped files.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../.."
BUILD_SH="$REPO/build.sh"
PKGROOT="$REPO/Buildroot/package"

[[ -f $BUILD_SH ]] || { echo "ERROR: cannot find build.sh at $BUILD_SH" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

failures=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }
check() { if [[ $1 == 0 ]]; then pass "$2"; else fail "$2"; fi; }

# --- the code under test ---
# The package helpers live in their own file precisely so this harness (and
# bump-package.sh) can source them: build.sh runs a whole build when executed.
LIB="$REPO/package-funcs.sh"
[[ -f $LIB ]] || { echo "ERROR: cannot find package-funcs.sh at $LIB" >&2; exit 2; }
# shellcheck source=../../package-funcs.sh
source "$LIB"
for want in readPackageVars seedPackage seedFragileSources dots; do
    if ! declare -F "$want" >/dev/null; then
        echo "ERROR: package-funcs.sh did not define $want" >&2
        exit 2
    fi
done
[[ ${#FOS_PACKAGE_MIRRORS[@]} -gt 0 ]] || { echo "ERROR: FOS_PACKAGE_MIRRORS is empty" >&2; exit 2; }

# ============================================================================
echo "== readPackageVars() against the real package files =="
# ============================================================================
# These are the values the seeding is built on, and getting one wrong is silent:
# a bad URL just looks like an unreachable mirror. The github case matters most
# -- partclone's site is a $(call github,...) macro whose version argument
# carries its own parentheses, which naive trimming cuts off mid-expansion.

cd "$PKGROOT/.." || exit 2   # so ../Buildroot/package/<pkg> resolves as in build.sh
mkdir -p "$SANDBOX/cwd"

expect_vars() {
    local pkg="$1" wantVer="$2" wantSrc="$3" wantUrl="$4" got
    got=$(readPackageVars "$pkg" "$PKGROOT/$pkg/$pkg.mk")
    if [[ $got == "$wantVer $wantSrc $wantUrl" ]]; then
        pass "$pkg resolves to $wantUrl"
    else
        fail "$pkg resolved to '$got', wanted '$wantVer $wantSrc $wantUrl'"
    fi
}

expect_vars cabextract 1.11 cabextract-1.11.tar.gz \
    https://www.cabextract.org.uk/cabextract-1.11.tar.gz
expect_vars chntpw 140201 chntpw-source-140201.zip \
    https://pogostick.net/~pnh/ntpasswd/chntpw-source-140201.zip
expect_vars testdisk 7.2 testdisk-7.2.tar.bz2 \
    https://www.cgsecurity.org/testdisk-7.2.tar.bz2
expect_vars partimage 0.6.9 partimage-0.6.9.tar.bz2 \
    https://downloads.sourceforge.net/project/partimage/stable/0.6.9/partimage-0.6.9.tar.bz2
# The github macro, and `:=` vs `=` assignment, are both exercised above.
expect_vars partclone 0.3.47 partclone-0.3.47.tar.gz \
    https://github.com/Thomas-Tsai/partclone/archive/0.3.47/partclone-0.3.47.tar.gz

# ============================================================================
echo "== seedPackage() behaviour =="
# ============================================================================
# Against a synthetic package, so these cases stay offline and independent of
# what any real upstream is serving today.

VERSION=9.9
PKG=fixturepkg
TARBALL="$PKG-$VERSION.tar.gz"
PKGDIR="$SANDBOX/Buildroot/package/$PKG"
mkdir -p "$PKGDIR" "$SANDBOX/cwd"

FIXTURE="$SANDBOX/fixture.tar.gz"
head -c 65536 /dev/zero | tr '\0' 'F' > "$FIXTURE"
FIX_SHA256=$(sha256sum "$FIXTURE" | cut -d' ' -f1)
FIX_SHA512=$(sha512sum "$FIXTURE" | cut -d' ' -f1)

cat > "$PKGDIR/$PKG.mk" <<EOF
${PKG^^}_VERSION = $VERSION
${PKG^^}_SOURCE = $PKG-\$(${PKG^^}_VERSION).tar.gz
${PKG^^}_SITE = https://upstream.invalid/pub
EOF
write_hash() {
    : > "$PKGDIR/$PKG.hash"
    echo "sha256  $FIX_SHA256  $TARBALL" >> "$PKGDIR/$PKG.hash"
    [[ $1 == with-sha512 ]] && echo "sha512  $FIX_SHA512  $TARBALL" >> "$PKGDIR/$PKG.hash"
    return 0
}
write_hash with-sha512

# wget stub: serves the fixture, except for hosts named in $BLOCK (connection
# failure) or $TAMPER (a 200 carrying the wrong bytes). Logs every URL asked
# for, so a case can assert which mirrors were tried and in what order.
STUBBIN="$SANDBOX/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/wget" <<'EOF'
#!/bin/bash
url="${!#}"; out=""; prev=""
for a in "$@"; do [[ $prev == "-O" ]] && out="$a"; prev="$a"; done
echo "$url" >> "$STUB_LOG"
for h in $BLOCK;  do [[ $url == *"$h"* ]] && exit 4; done
for h in $TAMPER; do [[ $url == *"$h"* ]] && { printf 'wrong-bytes' > "$out"; exit 0; } done
cp "$STUB_FIXTURE" "$out"
EOF
chmod +x "$STUBBIN/wget"
export PATH="$STUBBIN:$PATH"
export STUB_FIXTURE="$FIXTURE"

cd "$SANDBOX/cwd" || exit 2   # ../Buildroot/package/<pkg> now points at the sandbox

UPSTREAM=upstream.invalid
DEBIAN=deb.debian.org
FEDORA=src.fedoraproject.org
MIRRORS=("https://$DEBIAN/debian/pool/main/f/$PKG/${PKG}_@V@.orig.tar.gz" "@FEDORA@")

seed() {
    DL="$SANDBOX/dl-$1"
    export STUB_LOG="$SANDBOX/log-$1"
    rm -rf "$DL"; : > "$STUB_LOG"
    SEED_OUT="$SANDBOX/out-$1"
    seedPackage "$DL" "$PKG" "${MIRRORS[@]}" > "$SEED_OUT" 2>&1
    SEED_RC=$?
    SEEDED="$DL/$PKG/$TARBALL"
}
is_fixture() { [[ -f $1 ]] && [[ $(sha256sum "$1" | cut -d' ' -f1) == "$FIX_SHA256" ]]; }

# 1. Upstream answers: it is tried first and nothing else is touched.
seed upstream
is_fixture "$SEEDED"; check $? "seeds from upstream when upstream answers"
[[ $(wc -l < "$STUB_LOG") -eq 1 && $(head -1 "$STUB_LOG") == *"$UPSTREAM"* ]]
check $? "tries upstream first and stops there"
[[ -z $(find "$DL/$PKG" -name '.*' -type f) ]]
check $? "leaves no temporary files behind"

# 2. An already-correct cached tarball is not re-fetched. This is what makes the
#    Actions ~/.buildroot-dl cache worth having.
before=$(stat -c %Y "$SEEDED")
export STUB_LOG="$SANDBOX/log-cached"; : > "$STUB_LOG"
seedPackage "$DL" "$PKG" "${MIRRORS[@]}" >/dev/null 2>&1
[[ $(stat -c %Y "$SEEDED") == "$before" && ! -s $STUB_LOG ]]
check $? "leaves an already-valid cached tarball alone, with no network call"

# 3. A cached tarball that no longer matches is replaced, not trusted -- a
#    corrupt entry in the Actions cache must not become a corrupt build.
printf 'stale-garbage' > "$SEEDED"
export STUB_LOG="$SANDBOX/log-repair"; : > "$STUB_LOG"
seedPackage "$DL" "$PKG" "${MIRRORS[@]}" >/dev/null 2>&1
is_fixture "$SEEDED"; check $? "replaces a cached tarball whose hash no longer matches"

# 4. The failure that actually happened: upstream unreachable.
BLOCK="$UPSTREAM" seed fallback1
is_fixture "$SEEDED"; check $? "falls through to the first mirror when upstream is unreachable"
grep -q "${PKG}_$VERSION.orig.tar.gz" "$STUB_LOG"
check $? "substitutes @V@ with the version read from the .mk"

# 5. Two down, the lookaside covers.
BLOCK="$UPSTREAM $DEBIAN" seed fallback2
is_fixture "$SEEDED"; check $? "falls through to the Fedora lookaside when the first mirror is down too"
grep -q "$FEDORA/repo/pkgs/$PKG/$TARBALL/sha512/$FIX_SHA512/$TARBALL" "$STUB_LOG"
check $? "addresses the Fedora lookaside by the sha512 from the .hash"

# 6. Everything down: warn, clean up, hand back to Buildroot. Returning non-zero
#    would abort the build before Buildroot ever got its own attempt.
BLOCK="$UPSTREAM $DEBIAN $FEDORA" seed alldown
[[ $SEED_RC -eq 0 ]]; check $? "returns 0 when every source is down, leaving the download to Buildroot"
[[ ! -f $SEEDED && -z $(find "$DL" -type f 2>/dev/null) ]]
check $? "leaves nothing behind when every source is down"
grep -q "WARNING" "$SEED_OUT"; check $? "warns when every source is down"

# 7. A mirror serving the wrong bytes is never cached, whatever the reason.
TAMPER="$UPSTREAM" seed tampered
is_fixture "$SEEDED"; check $? "rejects a source serving the wrong bytes and keeps looking"

# 8. Without a sha512 the lookaside URL cannot be built, so that mirror is
#    dropped rather than requested with an empty hash path (which would 404).
write_hash sha256-only
BLOCK="$UPSTREAM $DEBIAN" seed nosha512
[[ ! -f $SEEDED ]] && ! grep -q "$FEDORA" "$STUB_LOG"
check $? "drops the Fedora mirror when the .hash has no sha512, rather than building a broken URL"
write_hash with-sha512

# 9. A package with no .hash at all is skipped rather than seeded unverified.
mv "$PKGDIR/$PKG.hash" "$SANDBOX/held.hash"
seed nohash
[[ ! -f $SEEDED && ! -s $STUB_LOG ]]
check $? "skips a package with no .hash rather than seeding it unverified"
mv "$SANDBOX/held.hash" "$PKGDIR/$PKG.hash"

# ============================================================================
echo "== shipped package files =="
# ============================================================================
# Offline assertions about the real files, guarding the invariants above that a
# well-meaning cleanup would otherwise quietly break.

cd "$PKGROOT/.." || exit 2
for entry in "${FOS_PACKAGE_MIRRORS[@]}"; do
    read -r pkg rest <<< "$entry"
    hash="$PKGROOT/$pkg/$pkg.hash"
    mk="$PKGROOT/$pkg/$pkg.mk"

    grep -qE '^sha256[[:space:]]' "$hash" 2>/dev/null
    check $? "$pkg.hash carries a sha256 (seeding is skipped entirely without it)"

    # The hash must be for the file this package currently resolves to. A
    # version bump that forgets its .hash fails the build with Buildroot's
    # "No hash found for <file>" -- loud, but ~50 minutes into a release. This
    # catches it here instead, and also catches a bump that adds new lines while
    # leaving stale ones behind.
    read -r _ src _ <<< "$(readPackageVars "$pkg" "$mk")"
    awk -v f="$src" '$1 == "sha256" && $3 == f { found = 1 } END { exit !found }' "$hash"
    check $? "$pkg.hash has a sha256 for $src, the file its .mk resolves to"

    # Only packages whose table entry uses the lookaside need the sha512.
    if [[ $rest == *"@FEDORA@"* ]]; then
        awk -v f="$src" '$1 == "sha512" && $3 == f { found = 1 } END { exit !found }' "$hash"
        check $? "$pkg.hash carries a sha512 for $src (its Fedora lookaside URL is built from it)"
    fi

    # Either a plain https site or the github macro, which resolves to https.
    grep -qE "^${pkg^^}_SITE[[:space:]]*:?=[[:space:]]*(https://|\\\$\(call github,)" "$mk"
    check $? "$pkg.mk fetches over https, not the http that egress filtering drops"
done

# ============================================================================
echo "== bump-package.sh =="
# ============================================================================
# The helper exists so a version and its hashes cannot move independently, which
# is the one mistake the .hash files make expensive. These cases drive it with
# the same wget stub, against a copy of the tree so nothing real is rewritten.

BUMP="$REPO/bump-package.sh"
if [[ ! -x $BUMP ]]; then
    fail "bump-package.sh is missing or not executable"
else
    BUMPTREE="$SANDBOX/bumptree"
    mkdir -p "$BUMPTREE/Buildroot"
    cp "$REPO/package-funcs.sh" "$BUMP" "$BUMPTREE/"
    cp -r "$PKGROOT" "$BUMPTREE/Buildroot/package"

    MK="$BUMPTREE/Buildroot/package/cabextract/cabextract.mk"
    HASH="$BUMPTREE/Buildroot/package/cabextract/cabextract.hash"
    export STUB_LOG="$SANDBOX/log-bump"; : > "$STUB_LOG"

    # A bump rewrites both files, and replaces the old hash lines rather than
    # leaving them beside the new ones.
    ( cd "$BUMPTREE" && ./bump-package.sh cabextract 9.9 ) > "$SANDBOX/bump.out" 2>&1
    bumpRc=$?
    [[ $bumpRc -eq 0 ]]; check $? "bumps a package when the new tarball is fetchable"
    grep -q '^CABEXTRACT_VERSION=9.9' "$MK"
    check $? "writes the new version into the .mk"
    awk '$1 == "sha256" && $3 == "cabextract-9.9.tar.gz" { f = 1 } END { exit !f }' "$HASH"
    check $? "writes a sha256 for the new filename"
    ! grep -q 'cabextract-1.11.tar.gz' "$HASH"
    check $? "removes the superseded hash lines instead of leaving them behind"
    grep -qc '^#' "$HASH"
    check $? "keeps the .hash comment header"
    # The seeding and the bump must agree on which line to read, or a bumped
    # package silently loses its mirrors.
    ( cd "$BUMPTREE/Buildroot" && readPackageVars cabextract "package/cabextract/cabextract.mk" ) \
        | grep -q 'cabextract-9.9.tar.gz'
    check $? "leaves the package resolving to the new source filename"

    # A failed download must not leave the tree half-bumped -- a .mk on the new
    # version with a .hash still on the old one is exactly the broken state the
    # helper exists to prevent.
    before=$(cat "$MK")
    ( cd "$BUMPTREE" && BLOCK="cabextract.org.uk" ./bump-package.sh cabextract 8.8 ) >/dev/null 2>&1
    bumpRc=$?
    [[ $bumpRc -ne 0 ]]; check $? "fails when the new tarball cannot be fetched"
    [[ $(cat "$MK") == "$before" ]]
    check $? "restores the .mk when the download fails, leaving no half-bump"

    # --dry-run reports without writing.
    before=$(cat "$MK"); beforeHash=$(cat "$HASH")
    ( cd "$BUMPTREE" && ./bump-package.sh cabextract 7.7 --dry-run ) >/dev/null 2>&1
    [[ $(cat "$MK") == "$before" && $(cat "$HASH") == "$beforeHash" ]]
    check $? "--dry-run changes nothing on disk"

    ( cd "$BUMPTREE" && ./bump-package.sh nosuchpkg 1.0 ) >/dev/null 2>&1
    [[ $? -ne 0 ]]; check $? "refuses an unknown package"
fi

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
