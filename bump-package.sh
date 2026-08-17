#!/bin/bash
#
# Bump one of FOG's own Buildroot packages to a new version, rewriting its
# version and its hashes together.
#
#   ./bump-package.sh cabextract 1.12
#   ./bump-package.sh cabextract 1.12 --dry-run
#   ./bump-package.sh --check                 # verify every package's hashes
#
# The two must move together. The version decides the source filename, Buildroot
# looks the hash up by that filename, and a bump that leaves the .hash behind
# aborts the build with "ERROR: No hash found for <file>" -- correct, but
# potentially fifty minutes into a release. Doing both by hand is easy to get
# half-right, so this does both or neither.
#
# The bytes come from the package's own upstream site, never from a mirror.
# Mirrors exist so a build can survive upstream being unreachable; they are not
# an authority on what upstream published, and a mirror will not have a release
# upstream just made. If upstream cannot be reached this refuses rather than
# pinning bytes it cannot attribute -- with --from to override when you have
# your own trusted copy.
#
# See CLAUDE.md, "Package sources and hashes", for the surrounding rules.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=package-funcs.sh
source "$HERE/package-funcs.sh"

PKGROOT="$HERE/Buildroot/package"

usage() {
    cat <<EOF
Usage: $0 <package> <new-version> [--dry-run] [--from <url>]
       $0 --check [<package>]

  <package>       one of: $(cd "$PKGROOT" && ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ')
  <new-version>   the version to move to, e.g. 1.12
  --dry-run       report what would change without writing anything
  --from <url>    take the tarball from this URL instead of the package's
                  upstream site. Use only for a copy you trust -- it becomes
                  the hash every future build is checked against.
  --check         re-download each package's current tarball and confirm the
                  committed hashes still match. Network-dependent, which is why
                  it is not part of tests/checks/package-mirrors.sh.
EOF
    exit "${1:-0}"
}

# Rewrites "<PKG>_VERSION <assignment> <value>" in place, preserving whichever
# of `=`, `:=` or `?=` and whatever spacing the file already uses -- these .mk
# files are not consistent with each other and reformatting them would bury the
# real change in noise.
setVersion() {
    local mk="$1" upper="$2" version="$3"
    sed -i -E "s|^(${upper}_VERSION[[:space:]]*[:?]?=[[:space:]]*)[^[:space:]]+|\1${version}|" "$mk"
}

# Replaces the hash lines for $old with lines for $new, leaving the comment
# header and any unrelated lines untouched. Stale lines are replaced rather than
# appended to: both Buildroot and seedPackage() select on the filename column,
# so leaving the old ones would be inert but misleading.
setHashes() {
    local hashFile="$1" old="$2" new="$3" sha256="$4" sha512="$5" tmp
    tmp=$(mktemp) || return 1
    awk -v old="$old" -v new="$new" -v s256="$sha256" -v s512="$sha512" '
        $1 == "sha256" && $3 == old { print "sha256  " s256 "  " new; done256 = 1; next }
        $1 == "sha512" && $3 == old { print "sha512  " s512 "  " new; done512 = 1; next }
        { print }
        END {
            if (!done256) print "sha256  " s256 "  " new
            if (!done512 && s512 != "") print "sha512  " s512 "  " new
        }
    ' "$hashFile" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$hashFile"
}

# Downloads $1 to $2. Kept separate so --check and the bump share one path.
fetch() {
    wget -q --tries=3 --timeout=30 -O "$2" "$1"
}

# Re-downloads a package's current tarball and compares it to the committed
# hashes. Answers the one question the offline harness cannot.
checkPackage() {
    local pkg="$1" vars version source upstream want got tmp rc=0

    vars=$(readPackageVars "$pkg" "$PKGROOT/$pkg/$pkg.mk") || {
        echo " * $pkg: could not read its .mk" >&2
        return 1
    }
    read -r version source upstream <<< "$vars"
    want=$(awk -v f="$source" '$1 == "sha256" && $3 == f { print $2; exit }' "$PKGROOT/$pkg/$pkg.hash" 2>/dev/null)
    if [[ -z $want ]]; then
        echo " * $pkg $version: no sha256 in $pkg.hash for $source" >&2
        return 1
    fi

    tmp=$(mktemp) || return 1
    dots "Checking $pkg $version"
    if ! fetch "$upstream" "$tmp"; then
        echo "Unreachable"
        rm -f "$tmp"
        return 1
    fi
    got=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [[ $got == "$want" ]]; then
        echo "OK"
    else
        echo "MISMATCH"
        echo "     expected $want" >&2
        echo "     got      $got" >&2
        rc=1
    fi
    rm -f "$tmp"
    return $rc
}

# --- argument handling ---------------------------------------------------

[[ $# -eq 0 ]] && usage 1

if [[ $1 == --check ]]; then
    shift
    rc=0
    if [[ $# -gt 0 ]]; then
        checkPackage "$1" || rc=1
    else
        for entry in "${FOS_PACKAGE_MIRRORS[@]}"; do
            read -r p _ <<< "$entry"
            checkPackage "$p" || rc=1
        done
    fi
    exit $rc
fi

[[ $1 == -h || $1 == --help ]] && usage 0
[[ $# -lt 2 ]] && usage 1

pkg="$1"
newVersion="$2"
shift 2
dryRun="n"
fromUrl=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dryRun="y"; shift ;;
        --from)    fromUrl="${2:-}"; [[ -z $fromUrl ]] && usage 1; shift 2 ;;
        *)         echo "Error: unknown option '$1'." >&2; usage 1 ;;
    esac
done

mk="$PKGROOT/$pkg/$pkg.mk"
hashFile="$PKGROOT/$pkg/$pkg.hash"
if [[ ! -f $mk ]]; then
    echo "Error: no such package '$pkg' (looked for $mk)." >&2
    exit 1
fi
if [[ ! -f $hashFile ]]; then
    echo "Error: $pkg has no .hash file. Create one before bumping it, so the" >&2
    echo "       new bytes are pinned rather than taken on trust." >&2
    exit 1
fi

upper=$(echo "$pkg" | tr '[:lower:]' '[:upper:]')

# --- resolve before and after -------------------------------------------

before=$(readPackageVars "$pkg" "$mk") || { echo "Error: could not parse $mk." >&2; exit 1; }
read -r oldVersion oldSource _ <<< "$before"

if [[ $oldVersion == "$newVersion" ]]; then
    echo "$pkg is already at $newVersion; nothing to do."
    exit 0
fi

# Work on a copy so the tree is never left half-bumped: the .mk has to change
# before the new source name and URL can be derived from it, but the download
# that follows is the step most likely to fail.
backup=$(mktemp) || exit 1
cp "$mk" "$backup"
restore() { cp "$backup" "$mk"; rm -f "$backup"; }
trap 'restore' EXIT

setVersion "$mk" "$upper" "$newVersion"
after=$(readPackageVars "$pkg" "$mk") || { echo "Error: $mk no longer parses after the version change." >&2; exit 1; }
read -r gotVersion newSource newUpstream <<< "$after"
if [[ $gotVersion != "$newVersion" ]]; then
    echo "Error: tried to set ${upper}_VERSION to $newVersion but it reads '$gotVersion'." >&2
    exit 1
fi

url="${fromUrl:-$newUpstream}"

echo "$pkg: $oldVersion -> $newVersion"
echo "  source: $oldSource -> $newSource"
echo "  from:   $url"
[[ -n $fromUrl ]] && echo "  (--from given: these bytes are taken on your authority, not upstream's)"

# --- fetch and hash ------------------------------------------------------

tmp=$(mktemp) || exit 1
trap 'restore; rm -f "$tmp"' EXIT

dots "Fetching $newSource"
if ! fetch "$url" "$tmp"; then
    echo "Failed"
    echo >&2
    echo "Error: could not fetch $url" >&2
    if [[ -z $fromUrl ]]; then
        echo "       A mirror is not used as a fallback here on purpose: it cannot" >&2
        echo "       establish what upstream published, and will not have a release" >&2
        echo "       upstream has only just made. Retry, or pass --from <url> with a" >&2
        echo "       copy you trust." >&2
    fi
    echo "       $mk has been left at $oldVersion." >&2
    exit 1
fi
echo "Done"

sha256=$(sha256sum "$tmp" | cut -d' ' -f1)
sha512=$(sha512sum "$tmp" | cut -d' ' -f1)
size=$(stat -c%s "$tmp")
echo "  size:   $size bytes"
echo "  sha256: $sha256"
echo "  sha512: $sha512"

# Informational only. A mirror that already carries the new release and agrees
# is a useful second opinion; one that lags is normal and not a problem, which
# is why neither outcome changes the result.
entry=$(printf '%s\n' "${FOS_PACKAGE_MIRRORS[@]}" | grep "^${pkg}[[:space:]]" || true)
if [[ -n $entry ]]; then
    read -r _ mirrorTemplates <<< "$entry"
    for m in $mirrorTemplates; do
        if [[ $m == "@FEDORA@" ]]; then
            m="https://src.fedoraproject.org/repo/pkgs/$pkg/$newSource/sha512/$sha512/$newSource"
        else
            m=${m//@V@/$newVersion}
            m=${m//@F@/$newSource}
        fi
        host="${m#*://}"; host="${host%%/*}"
        mtmp=$(mktemp) || continue
        dots "Cross-checking $host"
        if fetch "$m" "$mtmp" && [[ $(sha256sum "$mtmp" | cut -d' ' -f1) == "$sha256" ]]; then
            echo "Agrees"
        else
            echo "No copy yet"
        fi
        rm -f "$mtmp"
    done
fi

# --- write ---------------------------------------------------------------

if [[ $dryRun == "y" ]]; then
    echo
    echo "--dry-run: nothing written. $mk left at $oldVersion."
    exit 0
fi

if ! setHashes "$hashFile" "$oldSource" "$newSource" "$sha256" "$sha512"; then
    echo "Error: could not rewrite $hashFile." >&2
    exit 1
fi

# Both files are now correct, so keep the .mk change rather than restoring it.
rm -f "$backup" "$tmp"
trap - EXIT

echo
echo "Updated:"
echo "  $mk"
echo "  $hashFile"

# Hash lines are rewritten mechanically; prose is not. partclone.hash, for one,
# names the tag and commit its bytes were checked against, and that reasoning
# does not carry over to a new release -- leaving it there would describe
# verification that never happened for these bytes.
stale=$(grep -n "^#" "$hashFile" | grep -F "$oldVersion" || true)
if [[ -n $stale ]]; then
    echo
    echo "Note: comments in $hashFile still mention $oldVersion:"
    sed 's/^/      /' <<< "$stale"
    echo "      Rewrite them; the verification they describe was for the old bytes."
fi
echo
echo "Next: run tests/checks/package-mirrors.sh, then build the filesystem once"
echo "      so the new tarball is actually fetched and verified end to end."
