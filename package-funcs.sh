#!/bin/bash
#
# Shared helpers for FOG's own Buildroot packages.
#
# Sourced by build.sh (which seeds the download directory before a build) and by
# bump-package.sh (which rewrites a package's version and hashes). Neither can
# source the other -- build.sh runs a whole build when executed -- so the parsing
# that both depend on lives here, once. tests/checks/package-mirrors.sh sources
# this file directly.
#
# Nothing here runs at source time; it only defines things.

# Progress helper shared by build.sh and bump-package.sh, so both print the same
# " * doing something.........Done" shape.
function dots() {
    local pad
    pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}
# All five of FOG's own Buildroot packages have exactly one download source
# each, and Buildroot cannot give them a second one.
#
# sources.buildroot.net -- the backup mirror that covers every other package in
# the tree -- only carries packages that exist upstream in Buildroot, and none
# of these do. That is why the failing logs show it 404 rather than help. A
# package gets exactly one _SITE, so upstream is all there is, and three of
# these sites are small personal or project hosts.
#
# It has already cost two release builds. The 2026-08-03 run died when
# cabextract-1.11.tar.gz briefly 404'd; the 2026-08-17 experimental run died
# when every address of www.cabextract.org.uk timed out on port 80 from
# GitHub's runners. The same sites are routinely blocked by corporate egress
# filtering, which is the local-build version of the same failure.
#
# So the mirror list lives out here. Seed the download directory before
# Buildroot looks at it: dl-wrapper keeps a file that is already present when it
# matches the package's .hash file, and exits without touching the network at
# all. Every candidate is checked against the sha256 in that same .hash before
# it is kept, so a mirror cannot substitute different bytes for upstream's --
# and a cached tarball that no longer matches is replaced rather than trusted.
#
# Only mirrors verified byte-identical to upstream are listed. Debian is absent
# for chntpw and partclone because it legitimately repacks both (a .zip to
# .tar.gz, and a .tar.xz); Fedora is absent for partimage because it has no copy.
#
# Best effort on purpose: if every mirror fails, leave the directory alone and
# let Buildroot run its normal download, so the error the user ends up reading
# is Buildroot's own rather than one invented here.
#
# @V@ is the package version and @F@ the source filename, both read from the
# package's own .mk so a version bump cannot leave a stale URL here. @FEDORA@
# expands to the Fedora lookaside cache, which is addressed by sha512 and is
# never pruned -- the one mirror that cannot quietly lose an old release the way
# Debian's pool does once it moves on.
FOS_PACKAGE_MIRRORS=(
    "cabextract  https://deb.debian.org/debian/pool/main/c/cabextract/cabextract_@V@.orig.tar.gz  @FEDORA@"
    "chntpw      @FEDORA@"
    "testdisk    https://deb.debian.org/debian/pool/main/t/testdisk/testdisk_@V@.orig.tar.bz2  @FEDORA@"
    "partimage   https://deb.debian.org/debian/pool/main/p/partimage/partimage_@V@.orig.tar.bz2"
    "partclone   @FEDORA@"
)

# Reads $1_VERSION / $1_SOURCE / $1_SITE out of a package's .mk and echoes the
# resolved "version source upstream-url". Parsing rather than restating them
# here is what keeps a version bump from silently leaving this file behind.
# Handles `=`, `:=` and `?=`, and expands Buildroot's github macro, which is how
# partclone names its site.
function readPackageVars() {
    local pkg="$1" mk="$2"
    local upper version source site ghUser ghRepo ghVer args

    upper=$(echo "$pkg" | tr '[:lower:]' '[:upper:]')
    version=$(sed -n "s/^${upper}_VERSION[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p" "$mk" | head -1)
    source=$(sed -n "s/^${upper}_SOURCE[[:space:]]*[:?]*=[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p" "$mk" | head -1)
    site=$(sed -n "s/^${upper}_SITE[[:space:]]*[:?]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$mk" | head -1)
    [[ -z $version || -z $source || -z $site ]] && return 1

    # Expand $(<PKG>_VERSION) first, in both, so that by the time the github
    # macro is parsed below its arguments hold no parentheses of their own --
    # otherwise trimming at the closing paren cuts the version off mid-way.
    source=${source//"\$(${upper}_VERSION)"/$version}
    site=${site//"\$(${upper}_VERSION)"/$version}

    if [[ $site == *'$(call github,'* ]]; then
        args=${site#*'$(call github,'}
        args=${args%%)*}
        IFS=, read -r ghUser ghRepo ghVer <<< "$args"
        site="https://github.com/${ghUser// /}/${ghRepo// /}/archive/${ghVer// /}"
    fi

    echo "$version $source ${site%/}/$source"
}

# Seeds one package's tarball into $DL_DIR from upstream or a verified mirror.
function seedPackage() {
    local dlDir="$1" pkg="$2"; shift 2
    local pkgDir="../Buildroot/package/$pkg"
    local vars version source upstream sha256 sha512 target tmp url host m
    local -a mirrors

    [[ -f $pkgDir/$pkg.mk && -f $pkgDir/$pkg.hash ]] || return 0

    vars=$(readPackageVars "$pkg" "$pkgDir/$pkg.mk") || {
        echo " * WARNING: Couldn't read $pkg's version/source/site, leaving its download to Buildroot!"
        return 0
    }
    read -r version source upstream <<< "$vars"

    # Matched on the filename column, not just the algorithm: a .hash may carry
    # lines for more than one release, and picking the first sha256 in the file
    # would silently check the current tarball against a previous version's hash
    # -- every mirror would "fail" and the fallback would quietly stop working
    # while the build still passed on Buildroot's own download.
    sha256=$(awk -v f="$source" '$1 == "sha256" && $3 == f { print $2; exit }' "$pkgDir/$pkg.hash")
    sha512=$(awk -v f="$source" '$1 == "sha512" && $3 == f { print $2; exit }' "$pkgDir/$pkg.hash")
    if [[ -z $sha256 ]]; then
        echo " * WARNING: $pkg.hash has no sha256, leaving its download to Buildroot!"
        return 0
    fi

    target="$dlDir/$pkg/$source"
    if [[ -f $target ]] && echo "$sha256  $target" | sha256sum --check --status; then
        return 0
    fi

    mirrors=("$upstream")
    for m in "$@"; do
        if [[ $m == "@FEDORA@" ]]; then
            [[ -n $sha512 ]] || continue
            m="https://src.fedoraproject.org/repo/pkgs/$pkg/$source/sha512/$sha512/$source"
        else
            m=${m//@V@/$version}
            m=${m//@F@/$source}
        fi
        mirrors+=("$m")
    done

    mkdir -p "$dlDir/$pkg" || return 0
    tmp=$(mktemp "$dlDir/$pkg/.$source.XXXXXX") || return 0

    for url in "${mirrors[@]}"; do
        host="${url#*://}"
        host="${host%%/*}"
        dots "Fetching $pkg from $host"
        if wget -q --tries=2 --timeout=20 -O "$tmp" "$url" &&
            echo "$sha256  $tmp" | sha256sum --check --status; then
            mv -f "$tmp" "$target"
            echo "Done"
            return 0
        fi
        echo "Failed"
    done

    rm -f "$tmp"
    echo " * WARNING: No mirror served $source, leaving its download to Buildroot!"
    return 0
}

# Walks the table above. Never fails the build -- see the comment on the table.
function seedFragileSources() {
    local dlDir="$1" entry
    for entry in "${FOS_PACKAGE_MIRRORS[@]}"; do
        # shellcheck disable=SC2086
        seedPackage "$dlDir" $entry
    done
    return 0
}