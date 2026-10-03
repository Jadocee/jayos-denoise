#!/usr/bin/env bash
#
# Everything this repository checks, in one run.
#
#   tools/check.sh
#
# Exit 0: everything ran and passed. 1: something failed. 2: nothing failed but
# something could not run -- no jq, no socat, no python3 -- which is a
# different answer from "clean" and is reported as one. A check that examined
# nothing must not be counted as a check that found nothing.
#
# The same three statuses as jayos's suites, because jayos's installer reads
# its own suites' answers the same way and holds its side of the contract to
# the copy of contract/ it vendors from here.
#
# The plugin is not built here. packaging/steps.sh's `check` is what proves a
# built plugin, and it runs inside a package build, where the plugin is; what
# this runs is everything that needs no Rust toolchain and no network.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FAILED=()
SKIPPED=()

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# run <name> <command...>: 0 passes, 2 is "could not run", anything else fails.
run() {
    local name="$1"
    shift
    "$@"
    case $? in
        0) ;;
        2) SKIPPED+=("$name") ;;
        *) FAILED+=("$name") ;;
    esac
}

# The scripts git knows of, tracked or not yet added, or every script in the
# tree outside a git checkout -- where `git ls-files` lists nothing, and a
# syntax step over nothing would report clean having examined nothing.
#
# Untracked as well as tracked, minus what .gitignore names (makepkg's src/,
# pkg/ and the fork's mirror): tracked alone skipped every file not yet
# added, so a new script with a syntax error passed this step, and every
# suite under tests/shell was parsed by nothing until its first commit --
# RUN, in the checkout this was found in, where `git ls-files` listed six
# files and none of tests/. A tracked file deleted from the work tree is
# listed too, and is skipped below rather than reported as a syntax error.
# tests/shell/test-contract.sh holds both, and the outside-git branch.
scripts() {
    # "true", not merely exit 0: inside a .git directory it exits 0 and
    # prints "false", and ls-files there lists nothing.
    if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
        git ls-files --cached --others --exclude-standard \
            '*.sh' 'src/jayos-denoise' 'packaging/arch/PKGBUILD'
    else
        find . -path ./packaging/arch/src -prune -o -type f \
            \( -name '*.sh' -o -path ./src/jayos-denoise -o -path ./packaging/arch/PKGBUILD \) -print
    fi
}

step "shell syntax"
syntax() {
    local f bad=0 n=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        bash -n "$f" || { echo "  syntax error in $f"; bad=1; }
    done < <(scripts)
    if (( n == 0 )); then
        echo "  no scripts found; this step examined nothing"
        return 2
    fi
    echo "  $n files parse"
    return "$bad"
}
run "shell syntax" syntax

step "contract"
run "contract" bash tools/contract.sh

# nullglob, so a tree with no suites runs none rather than one named by the
# unexpanded pattern -- which failed as "No such file or directory" -- and the
# count says so: no suites is "examined nothing", not "nothing failed".
shopt -s nullglob
suites=(tests/shell/test-*.sh)
shopt -u nullglob
if (( ${#suites[@]} == 0 )); then
    echo "  no suites under tests/shell; nothing was examined there"
    SKIPPED+=("tests/shell")
fi
for suite in ${suites[@]+"${suites[@]}"}; do
    step "$suite"
    run "$suite" bash "$suite"
done

echo
if (( ${#FAILED[@]} )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
fi
if (( ${#SKIPPED[@]} )); then
    printf 'not exercised: %s\n' "${SKIPPED[@]}"
fi
if (( ${#FAILED[@]} )); then
    exit 1
elif (( ${#SKIPPED[@]} )); then
    exit 2
fi
echo "ok, nothing to fix"
