#!/bin/bash
#
# Gate: FOS's own source carries US spellings.
#
#   tests/checks/us-spelling.sh    # exit non-zero on any UK spelling in scope
#
# Tom asked for US spellings throughout. The tree was swept once (#168); this is
# what stops it drifting back, one echo line at a time, the way it drifted in.
# It matters more here than in most repos because these strings are read off a
# screen by a technician standing at a machine mid-enrollment.
#
# WHY A WHOLE-TREE SCAN RATHER THAN A DIFF
#
# The obvious shape is "check only the lines this pull request adds". It needs a
# base ref, and a shallow clone has no merge-base -- so the check would find
# nothing to look at and pass, for a reason that has nothing to do with
# spelling, silently and forever. A gate that can only report success is worse
# than no gate, because it also reports "verified". Scanning the whole tree
# needs no ref and cannot skip, and is only possible because the sweep already
# made the tree clean.
#
# Mirrors fogproject's tests/us-spelling.test.php, including the word list and
# the two-pattern boundary handling. Keep them in step.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# FOS's own source. Buildroot's vendored tree is out -- upstream's spellings are
# not ours to correct.
SCOPE=(
    Buildroot/board/FOG/FOS/rootfs_overlay
    tests
    docs
    README.md
)

# Read by a machine or by another repository, so the UK spelling is load
# bearing. Blanked out of the line before the words below are looked for.
ALLOWED=(
    # Three files here and one in fogproject reference this ADR by name.
    '0009-secure-boot-enrolment-paths'
)

# An explicit list, not a blanket -ise -> -ize rule: advertise, exercise,
# surprise and otherwise are -ise in both dialects. `enrolled` and `enrolling`
# are absent on purpose -- both dialects double the l there.
UK=(
    enrolment enrolments enrol enrols
    recognise recognised recognises recognising recognisable unrecognised
    normalise normalised normalises normalising normalisation normaliser
    behaviour behaviours behavioural
    colour colours coloured colouring
    cancelled cancelling
    labelled labelling relabelled relabelling unlabelled signalling
    modelled travelled
    catalogue licence centre centres
    neighbour neighbours neighbouring
    initialise initialised initialises initialisation initialiser
    authorise authorised authorisation
    serialise serialised serialising
    organise organised organising organisation
    minimise minimised maximise maximised optimise optimised
    utilise utilised utilising prioritise summarise summarised
    specialise specialised
    favour favours favourable
    defence offence fulfil whilst
    grey greyed
    analyse analysed analyses analyser
    afterwards towards amongst
    judgement judgements ageing
    artefact artefacts programme programmes
)

# Lookbehind is required for the boundary rules below, so this needs PCRE.
# Refuses rather than degrading to a weaker pattern: a check that quietly
# matches less is the failure this file exists to prevent.
if ! echo x | grep -qP 'x' 2>/dev/null; then
    printf 'FAIL: grep has no -P (PCRE) support; cannot run this check.\n' >&2
    exit 1
fi

# git ls-files --cached --others --exclude-standard, not a find: tracked files,
# plus new ones a developer has written but not staged, minus anything ignored.
mapfile -t files < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -- "${SCOPE[@]}" 2>/dev/null)

# Per SCOPE entry, not just a total. git exits 0 quite happily on a checkout
# where a path has moved or where an ignore rule now swallows it, and the result
# would be "0 file(s) scanned, no UK spellings in scope" -- green, and
# meaningless. A total still passes when one directory of the four drops out, so
# the floor is per path.
empty=()
for want in "${SCOPE[@]}"; do
    found=0
    for f in "${files[@]}"; do
        if [[ $f == "$want" || $f == "$want"/* ]]; then
            found=1
            break
        fi
    done
    [[ $found -eq 0 ]] && empty+=("$want")
done
if [[ ${#empty[@]} -gt 0 ]]; then
    printf 'FAIL: these scope paths matched no files -- moved, renamed or\n' >&2
    printf 'newly ignored? Fix SCOPE; do not delete the entry to go green.\n' >&2
    printf '  %s\n' "${empty[@]}" >&2
    exit 1
fi

# Two patterns, because one right-hand boundary cannot serve both shapes.
#
# WORD/camelCase -- lower or Title case. Left edge is "not preceded by a letter,
# OR on a camelCase hump". Right edge is "not followed by a lower-case letter",
# which keeps `enrol` from firing inside `enrolled` and `enrollment`.
#
# ALL CAPS -- for shell constants. Here the right edge must reject an upper-case
# letter too, or `ENROL` matches inside `ENROLL_SECUREBOOT` and the check fails
# on a correctly spelled name. `ENROLMENT_MODE` still matches: `_` is not a
# letter.
#
# Both are case-SENSITIVE. Adding -i would also fold the [a-z]/[A-Z] in the
# boundary assertions, collapsing the camelCase hump into "letter, letter" --
# i.e. no boundary at all.
cased=''
upper=''
for w in "${UK[@]}"; do
    cased="${cased}|${w^}|${w}"
    upper="${upper}|${w^^}"
done
cased="${cased#|}"
upper="${upper#|}"
P_WORD="(?:(?<![A-Za-z])|(?<=[a-z])(?=[A-Z]))(${cased})(?![a-z])"
P_CAPS="(?<![A-Za-z])(${upper})(?![A-Za-z])"

sedscript=''
for a in "${ALLOWED[@]}"; do
    sedscript="${sedscript}s|$(printf '%s' "$a" | sed 's/[|\\.*^$[]/\\&/g')||g;"
done

problems=0
scanned=0
for f in "${files[@]}"; do
    path="$ROOT/$f"
    [[ -f $path ]] || continue
    # This file names every UK spelling there is; it cannot scan itself.
    [[ $path -ef ${BASH_SOURCE[0]} ]] && continue
    # Skip binaries.
    grep -qI '' "$path" 2>/dev/null || continue
    scanned=$((scanned + 1))
    while IFS= read -r hit; do
        [[ -z $hit ]] && continue
        printf '%s:%s\n' "$f" "$hit"
        problems=$((problems + 1))
    done < <(sed "$sedscript" "$path" 2>/dev/null | grep -nP -o "$P_WORD|$P_CAPS" 2>/dev/null)
done

if [[ $problems -gt 0 ]]; then
    printf '\nFAIL: %d UK spelling(s) in scope.\n' "$problems" >&2
    printf 'Use the US form. If a machine reads the string and the UK spelling\n' >&2
    printf 'is load bearing, add it to ALLOWED above with the reason -- do not\n' >&2
    printf 'remove the word from UK.\n' >&2
    exit 1
fi

printf 'us-spelling: %d file(s) scanned, no UK spellings in scope\n' "$scanned"
