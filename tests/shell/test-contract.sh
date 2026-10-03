#!/usr/bin/env bash
#
# tools/contract.sh and tools/check.sh, run against scratch copies of this
# tree.
#
#   tests/shell/test-contract.sh
#
# Exit 0: every case that ran passed. 1: a case failed. 2: could not run --
# no jq, without which contract.sh itself answers 2 and nothing below could
# tell a stale contract from a missing tool. One case depends on the machine
# rather than on a tool: EasyEffects installed beside bash and jq is
# simulated by overlaying a fake onto that directory in a private mount
# namespace, and where `unshare -rm` or an overlay mount is refused it is a
# counted skip, named in the tally, that leaves the status alone.
#
# WHAT THIS PROVES
#
# contract.sh: that the contract as committed is what the code produces; that
# a changed number names the preset files it changes and no others; that a
# new strength names its missing presets; that each generated file, deleted,
# is named; that a file nothing produces is named; that a hand edit to a
# generated file is caught and one to README.md is not; that --write repairs
# all of those at once, keeps README.md byte for byte and removes a preset
# the code no longer produces; that a generator that cannot run is a failure
# (1) and clobbers nothing, even under --write; that no jq is 2, not 0 and
# not 1, and writes nothing; and that EasyEffects installed beside bash and
# jq changes nothing.
#
# check.sh: that outside a git checkout its syntax step finds every script
# and parses each (a syntax error is named), rather than reporting clean over
# nothing; that inside one it parses untracked scripts too, skips ignored
# ones and does not report a deleted tracked file; that a suite exiting 2
# makes it 2, a failing one 1, both together 1, one killed by a signal 1, and
# no suites at all 2; and that a stale contract fails it.
#
# Every case copies the tree first -- contract.sh and check.sh derive their
# root from their own path, so a copy's scripts read and write the copy --
# and every mutation is checked to have changed the file before its case is
# believed: a sed that matched nothing would leave a copy that passes and a
# case that "fails as expected" for no reason at all.
#
# check.sh is run over STUB suites, not this tree's: the real ones would
# include this one, which would copy the tree and run check.sh again, without
# end.
#
# WHAT IT DOES NOT PROVE: that jayos's vendored copy of contract/ matches
# (jayos's tools/test-easyeffects.sh holds its side), or anything about a
# real EasyEffects. The overlay case is the only one that needs privileges,
# and it was RUN as root here; as an ordinary user it needs unprivileged user
# namespaces, which is read, not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v jq >/dev/null 2>&1 || {
    echo "  contract not exercised: jq is not installed"
    exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/denoise-contract-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK=$(realpath "$WORK")
mkdir -p "$WORK/tmp"

# No system or global git configuration, and no walking above $WORK: a copy
# meant to be outside a checkout must not land in whatever repository
# $TMPDIR sits inside, or the "outside git" cases test the other branch.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES="$WORK"

PASS=0
FAIL=0
SKIP=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP + 1)); }

# ── copies ───────────────────────────────────────────────────────────────────

# This tree without .git and without what makepkg leaves in packaging/arch --
# the fork's clone and its target/ run to gigabytes, and contract.sh and
# check.sh read none of it.
# A tree without the two scripts under test is a defect in the tree (1); a
# copy that came out without them is this suite failing to start (2).
for f in tools/contract.sh tools/check.sh; do
    [[ -f "$ROOT/$f" ]] || { echo "  $f is missing from this tree"; exit 1; }
done
PRISTINE="$WORK/pristine"
mkdir -p "$PRISTINE"
( cd "$ROOT" && find . \( -path ./.git -o -path ./packaging/arch/src -o -path ./packaging/arch/pkg \
        -o -path ./packaging/arch/DeepFilterNetPlus -o -name '*.pkg.tar*' \) -prune \
        -o \( -type f -o -type l \) -print0 \
  | xargs -0 cp -a --parents -t "$PRISTINE" )
[[ -f "$PRISTINE/tools/contract.sh" && -f "$PRISTINE/tools/check.sh" ]] || {
    echo "  contract not exercised: could not copy the tree into $PRISTINE" >&2
    exit 2
}

# A directory of its own from mktemp, not a counter: fresh runs inside
# $(...), where a counter's increment dies with the subshell, and every case
# then shared -- and piled its mutation onto -- the first case's copy.
fresh() { # fresh: a new copy of the pristine tree; prints its path
    local d
    d=$(mktemp -d "$WORK/case.XXXXXX") && cp -a "$PRISTINE/." "$d/" && printf '%s' "$d"
}

# mutate <file> <sed -E script>: 1, and a failure, when the file did not
# change -- the case would otherwise run over an unmutated copy.
mutate() {
    local before
    before=$(cat "$1" 2>/dev/null)
    sed -E -i "$2" "$1"
    if [[ "$(cat "$1")" == "$before" ]]; then
        bad "the mutation '$2' changed nothing in ${1#"$WORK"/}; this case examined nothing"
        return 1
    fi
}

# contract <dir> [args]: run that copy's contract.sh; OUT and STATUS.
contract() {
    local dir=$1
    shift
    OUT=$(TMPDIR="$WORK/tmp" bash "$dir/tools/contract.sh" "$@" 2>&1)
    STATUS=$?
}

# The "contract/<file> ..." lines, sorted: what a compare said was wrong.
problems() { grep -E '^  contract/' <<<"$OUT" | sed -E 's/^  //' | sort; }

# expect <description> <status> <problem lines, newline-separated, or "">
expect() {
    local want
    want=$(sort <<<"$3" | sed '/^$/d')
    if [[ "$STATUS" == "$2" && "$(problems)" == "$want" ]]; then
        pass "$1"
    else
        bad "$1 -- exit $STATUS (wanted $2)"
        diff <(printf '%s\n' "$want") <(problems) | sed -n 's/^\([<>]\)/         \1/p' | head -12
        sed -n '1,6s/^/         | /p' <<<"$OUT"
    fi
}

# says <description> <fixed string>: OUT holds it.
says() {
    if grep -qF -- "$2" <<<"$OUT"; then
        pass "$1"
    else
        bad "$1 -- the output does not say '$2'"
        sed -n '1,6s/^/         | /p' <<<"$OUT"
    fi
}

same_tree() { diff -r "$1" "$2" >/dev/null 2>&1; }

GENERATED=()
for f in "$PRISTINE"/contract/*; do
    [[ "${f##*/}" == README.md ]] || GENERATED+=("${f##*/}")
done

# ── contract.sh ──────────────────────────────────────────────────────────────

echo "tools/contract.sh"

D=$(fresh)
contract "$D"
expect "the contract as committed is what the code produces" 0 ""
says "and says so" "contract/ is current"
if (( STATUS != 0 )); then
    # So that each case below measures its own change, not this tree's
    # staleness -- which the case above has already reported.
    contract "$PRISTINE" --write
    echo "         (the cases below start from a rewritten copy)"
fi
if (( ${#GENERATED[@]} >= 8 )); then
    pass "contract/ holds ${#GENERATED[@]} generated files besides README.md"
else
    bad "contract/ holds ${#GENERATED[@]} generated files; the cases below would examine almost nothing"
fi

# A NUMBER behind one strength: exactly that strength's two presets, and the
# diff shows the new number. 31.5 rather than an integer because a jq before
# 1.7 prints 31.0 as 31, and the cases below grep for the number as written.
D=$(fresh)
if mutate "$D/src/jayos-denoise" 's/^([[:space:]]+gentle\)[[:space:]]+ATTEN=)[0-9.]+/\131.5/'; then
    contract "$D"
    expect "a changed number in strength_params names gentle's two presets, and nothing else" 1 \
        "contract/preset.gentle.json differs from what the code produces
contract/preset.gentle.off.json differs from what the code produces"
    says "and shows the new number" "31.5"
    says "and says how to repair it" "regenerate with tools/contract.sh --write"
fi

# A NEW STRENGTH: its two presets are missing, and the list differs.
D=$(fresh)
if mutate "$D/src/jayos-denoise" '/^[[:space:]]+maximum\)/a\        extreme)  ATTEN=100.0; MIN_T=-15.0; MAX_ERB=35.0; MAX_DF=35.0; BUFFER=1; BETA=0.05 ;;'; then
    if grep -qx extreme <<<"$(bash "$D/src/jayos-denoise" strengths 2>/dev/null)"; then
        contract "$D"
        expect "a new strength arm names its two missing presets and the changed list" 1 \
            "contract/preset.extreme.json is missing
contract/preset.extreme.off.json is missing
contract/strengths.txt differs from what the code produces"
    else
        bad "the engine does not list the added arm; this case examined nothing"
    fi
fi

# EACH generated file, deleted, is named -- and is the only one named.
missing_named=0
for name in "${GENERATED[@]}"; do
    D=$(fresh)
    rm -f "$D/contract/$name"
    contract "$D"
    if [[ "$STATUS" == 1 && "$(problems)" == "contract/$name is missing" ]]; then
        missing_named=$((missing_named + 1))
    else
        bad "contract/$name deleted: exit $STATUS, and: $(problems | tr '\n' ';')"
    fi
done
if (( missing_named == ${#GENERATED[@]} && missing_named > 0 )); then
    pass "each of the $missing_named generated files, deleted, fails the compare and is the one named"
fi

D=$(fresh)
echo "a note" > "$D/contract/notes.txt"
contract "$D"
expect "a file the code does not produce is named" 1 "contract/notes.txt is produced by nothing"

D=$(fresh)
echo "volume" >> "$D/contract/status-keys.txt"
contract "$D"
expect "a hand edit to a generated file is caught" 1 \
    "contract/status-keys.txt differs from what the code produces"

D=$(fresh)
echo "A line somebody added." >> "$D/contract/README.md"
contract "$D"
expect "README.md is the one hand-written file: editing it is not staleness" 0 ""

# --WRITE repairs every kind of wrong above at once, and keeps README.md.
D=$(fresh)
if mutate "$D/src/jayos-denoise" 's/^([[:space:]]+gentle\)[[:space:]]+ATTEN=)[0-9.]+/\131.5/'; then
    echo "a note" > "$D/contract/notes.txt"
    rm -f "$D/contract/facts.txt"
    echo "volume" >> "$D/contract/status-keys.txt"
    echo "A line somebody added." >> "$D/contract/README.md"
    cp "$D/contract/README.md" "$WORK/readme.kept"
    contract "$D" --write
    if [[ "$STATUS" == 0 ]] && grep -qF "contract/ rewritten from the code" <<<"$OUT"; then
        pass "--write over a changed number, a stray, a deleted and an edited file exits 0"
    else
        bad "--write exited $STATUS: $OUT"
    fi
    contract "$D"
    expect "and the compare after it is clean" 0 ""
    if cmp -s "$WORK/readme.kept" "$D/contract/README.md"; then
        pass "README.md is kept byte for byte, the added line with it"
    else
        bad "--write changed README.md"
    fi
    [[ ! -e "$D/contract/notes.txt" ]] && pass "the stray file is gone" || bad "--write left contract/notes.txt"
    if cmp -s "$PRISTINE/contract/facts.txt" "$D/contract/facts.txt" \
       && cmp -s "$PRISTINE/contract/status-keys.txt" "$D/contract/status-keys.txt"; then
        pass "the deleted and the hand-edited files are back as the code makes them"
    else
        bad "facts.txt or status-keys.txt differs from the pristine copy's after --write"
    fi
    if grep -q '"attenuation-limit": 31.5' "$D/contract/preset.gentle.json"; then
        pass "and gentle's preset carries the new number"
    else
        bad "contract/preset.gentle.json after --write does not carry 31.5"
    fi
fi

# --WRITE REMOVES what the code no longer produces.
D=$(fresh)
if mutate "$D/src/jayos-denoise" '/^[[:space:]]+maximum\)/d'; then
    contract "$D" --write
    if [[ "$STATUS" == 0 && ! -e "$D/contract/preset.maximum.json" && ! -e "$D/contract/preset.maximum.off.json" ]]; then
        pass "--write after a strength is removed deletes its two presets"
    else
        bad "--write after removing maximum: exit $STATUS, and $(ls "$D/contract" | tr '\n' ' ')"
    fi
    if [[ "$(grep -v '^#' "$D/contract/strengths.txt" | tr '\n' ' ')" == "gentle balanced " ]]; then
        pass "and strengths.txt lists the two that are left"
    else
        bad "strengths.txt after --write: $(tr '\n' ' ' < "$D/contract/strengths.txt")"
    fi
fi

# A GENERATOR THAT CANNOT RUN is a failure, and clobbers nothing: generate()
# dies before --write's branch is reached, so the committed contract stays.
D=$(fresh)
rm -f "$D/src/easyeffects-lib.sh"
cp -a "$D/contract" "$WORK/contract.before"
contract "$D"
if [[ "$STATUS" == 1 ]]; then
    pass "an engine that cannot run fails the compare (1), not 'current' and not 'could not run'"
else
    bad "an engine without its library: contract.sh exited $STATUS"
fi
says "and says which step failed" "contract.sh: jayos-denoise strengths failed"
contract "$D" --write
if [[ "$STATUS" == 1 ]] && same_tree "$WORK/contract.before" "$D/contract"; then
    pass "--write with that engine fails too, and leaves contract/ exactly as it was"
else
    bad "--write with a broken engine exited $STATUS or changed contract/"
fi
rm -rf "$WORK/contract.before"

# NO JQ is 2 -- not 0, which would say current, and not 1, which would say
# stale -- and writes nothing. The PATH is every executable this one has
# with jq subtracted, jayos's tools/lib/absent.sh technique (copied, not
# sourced -- this repository does not have that file): a PATH written as a
# short list would leave jq wherever the list includes /usr/bin, which on
# the machine this is for is where jq is.
path_without() { # path_without <absolute dir> <tool>...
    local dir=$1 d
    shift
    (( $# )) && [[ "$dir" == /* ]] || return 1
    rm -rf "$dir"
    mkdir -p "$dir" || return 1
    local -a dirs
    IFS=: read -ra dirs <<<"$PATH"
    for d in "${dirs[@]}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        # One ln per directory. It does not replace a name an earlier
        # directory linked, so the first on PATH wins, as execution would.
        ln -s "$d"/* "$dir/" 2>/dev/null
    done
    for d in "$@"; do
        rm -f "$dir/$d"
    done
    [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]
}
NOJQ="$WORK/path-without-jq"
if path_without "$NOJQ" jq && ! PATH="$NOJQ" command -v jq >/dev/null 2>&1 \
   && PATH="$NOJQ" command -v bash >/dev/null 2>&1; then
    D=$(fresh)
    cp -a "$D/contract" "$WORK/contract.before"
    OUT=$(env PATH="$NOJQ" TMPDIR="$WORK/tmp" bash "$D/tools/contract.sh" 2>&1); STATUS=$?
    if [[ "$STATUS" == 2 ]] && grep -qF "not exercised: jq is not installed" <<<"$OUT"; then
        pass "with no jq on PATH the compare exits 2 and says it was not exercised"
    else
        bad "with no jq on PATH the compare exited $STATUS: $OUT"
    fi
    OUT=$(env PATH="$NOJQ" TMPDIR="$WORK/tmp" bash "$D/tools/contract.sh" --write 2>&1); STATUS=$?
    if [[ "$STATUS" == 2 ]] && same_tree "$WORK/contract.before" "$D/contract"; then
        pass "and --write exits 2 and writes nothing"
    else
        bad "with no jq on PATH --write exited $STATUS or changed contract/"
    fi
    rm -rf "$WORK/contract.before"
else
    bad "could not build a PATH without jq that still has bash; the no-jq cases examined nothing"
fi

# EASYEFFECTS INSTALLED BESIDE BASH AND JQ. status-keys.txt is made by
# running `status` with easyeffects off PATH, and the first way of doing
# that dropped every directory holding it -- /usr/bin, on the machine this
# is for -- which took bash with it: exit 1 on every Arch machine with
# EasyEffects installed, exit 0 everywhere else, this container included.
# So the case puts a fake easyeffects INTO bash's directory, through an
# overlay in a private mount namespace that nothing outside it sees.
BINDIR=$(dirname "$(command -v bash)")
mkdir -p "$WORK/ee"
printf '#!/bin/sh\nexit 0\n' > "$WORK/ee/easyeffects"
chmod +x "$WORK/ee/easyeffects"
overlay() { # overlay <command...>: run it with $WORK/ee laid over $BINDIR
    unshare -rm bash -c 'mount -t overlay overlay -o "lowerdir=$1:$2" "$2" || exit 97; shift 2; "$@"' \
        _ "$WORK/ee" "$BINDIR" "$@"
}
if ! command -v unshare >/dev/null 2>&1; then
    skip "contract with easyeffects in $BINDIR not exercised: no unshare"
elif ! overlay true 2>/dev/null; then
    skip "contract with easyeffects in $BINDIR not exercised: unshare -rm or an overlay mount was refused"
else
    seen=$(overlay bash -c 'command -v easyeffects')
    if [[ "$seen" != "$BINDIR/easyeffects" ]]; then
        bad "inside the overlay easyeffects resolves to '$seen', not $BINDIR; this case examined nothing"
    else
        D=$(fresh)
        OUT=$(overlay env TMPDIR="$WORK/tmp" bash "$D/tools/contract.sh" 2>&1); STATUS=$?
        expect "with easyeffects in $BINDIR, beside bash and jq, the contract is still current" 0 ""
    fi
fi

# ── check.sh ─────────────────────────────────────────────────────────────────

echo
echo "tools/check.sh"

# A copy whose tests/shell holds stubs exiting with the given statuses, one
# suite per status, named test-s<status>-<n>.sh.
stubbed() { # stubbed <status>...: prints the copy's path
    local d s i=0
    d=$(fresh)
    rm -f "$d"/tests/shell/*.sh
    mkdir -p "$d/tests/shell"
    for s in "$@"; do
        i=$((i + 1))
        printf '#!/usr/bin/env bash\nexit %s\n' "$s" > "$d/tests/shell/test-s$s-$i.sh"
    done
    printf '%s' "$d"
}

checksh() { # checksh <dir>: OUT and STATUS
    OUT=$(cd "$1" && TMPDIR="$WORK/tmp" bash tools/check.sh 2>&1)
    STATUS=$?
}

status_is() { # status_is <description> <status>
    if [[ "$STATUS" == "$2" ]]; then
        pass "$1"
    else
        bad "$1 -- exit $STATUS (wanted $2)"
        tail -6 <<<"$OUT" | sed 's/^/         | /'
    fi
}

lacks_line() { # lacks_line <description> <fixed string>
    if grep -qF -- "$2" <<<"$OUT"; then
        bad "$1 -- the output says '$2'"
    else
        pass "$1"
    fi
}

# only_syntax_error <description> <file as check.sh names it>: the syntax
# step named that file and no other. Exactly one, because a copy holding a
# second broken file would fail check.sh for that one, and a case asserting
# only the status would pass for the wrong reason -- which is how the first
# inside-git version of these cases passed over the check.sh they were
# written to replace (the deleted tracked file below was its other error).
only_syntax_error() {
    local got
    got=$(grep -E '^  syntax error in ' <<<"$OUT")
    if [[ "$got" == "  syntax error in $2" ]]; then
        pass "$1"
    else
        bad "$1 -- the syntax errors named are: ${got:-none}"
    fi
}

only_syntax_error_none() {
    local got
    got=$(grep -E '^  syntax error in ' <<<"$OUT")
    if [[ -z "$got" ]]; then
        pass "and no syntax error is named: not the ignored file, not the deleted one"
    else
        bad "syntax errors named where none should be: $(tr '\n' ';' <<<"$got")"
    fi
}

# Every script a syntax step should find in <dir>: the .sh files, the
# engine and the recipe -- counted here by name, not by check.sh's own find.
scripts_in() {
    local n
    n=$(find "$1" -type f -name '*.sh' | wc -l)
    [[ -f "$1/src/jayos-denoise" ]] && n=$((n + 1))
    [[ -f "$1/packaging/arch/PKGBUILD" ]] && n=$((n + 1))
    printf '%s' "$n"
}

# OUTSIDE GIT: where `git ls-files` lists nothing, the step must still find
# the scripts and parse them.
D=$(stubbed 0)
if [[ "$(git -C "$D" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
    bad "the copy at $D is inside a git work tree; the outside-git cases examined nothing"
else
    checksh "$D"
    status_is "outside git, over a clean copy, check.sh exits 0" 0
    says "and ends 'ok, nothing to fix'" "ok, nothing to fix"
    want=$(scripts_in "$D")
    got=$(sed -n -E 's/^  ([0-9]+) files parse$/\1/p' <<<"$OUT")
    if [[ -n "$got" && "$got" == "$want" ]] && (( want >= 5 )); then
        pass "and its syntax step parsed all $want scripts there are"
    else
        bad "the syntax step parsed '${got:-none}' files where the copy has $want scripts"
    fi

    # A syntax error in each arm of check.sh's find: the recipe is found by
    # its path, a new script by its name. Both must be named -- which is
    # what shows the files are parsed, not merely counted.
    D=$(stubbed 0)
    echo 'package() {' >> "$D/packaging/arch/PKGBUILD"
    checksh "$D"
    status_is "outside git, a syntax error in packaging/arch/PKGBUILD fails check.sh" 1
    only_syntax_error "and it is the one named" "./packaging/arch/PKGBUILD"
    says "as the shell syntax step's failure" "FAILED: shell syntax"

    D=$(stubbed 0)
    printf 'if then\n' > "$D/tools/new.sh"
    checksh "$D"
    status_is "outside git, a syntax error in a new tools/new.sh fails check.sh" 1
    only_syntax_error "and it is the one named" "./tools/new.sh"
fi

D=$(stubbed 0 2)
checksh "$D"
status_is "a suite exiting 2 makes check.sh exit 2" 2
says "and it is listed as not exercised" "not exercised: tests/shell/test-s2-2.sh"
lacks_line "and nothing is listed as failed" "FAILED:"
lacks_line "and it does not end clean" "ok, nothing to fix"

D=$(stubbed 0 1)
checksh "$D"
status_is "a suite exiting 1 makes check.sh exit 1" 1
says "and it is listed as failed" "FAILED: tests/shell/test-s1-2.sh"

D=$(stubbed 2 1)
checksh "$D"
status_is "a suite exiting 2 and another exiting 1 make check.sh exit 1" 1
says "and the 2 is still listed as not exercised" "not exercised: tests/shell/test-s2-1.sh"

D=$(stubbed 141)
checksh "$D"
status_is "a suite killed by SIGPIPE (141) is a failure" 1

D=$(stubbed)
checksh "$D"
status_is "no suites at all makes check.sh exit 2" 2
says "and says nothing was examined there" "no suites under tests/shell; nothing was examined there"

D=$(stubbed 0)
echo "a note" > "$D/contract/notes.txt"
checksh "$D"
status_is "a stale contract fails check.sh" 1
says "and is listed as the contract's failure" "FAILED: contract"

# INSIDE GIT: tracked scripts and untracked ones, not ignored ones, and not a
# tracked file deleted from the work tree.
if ! command -v git >/dev/null 2>&1; then
    skip "check.sh inside a git checkout not exercised: no git"
else
    D=$(stubbed 0)
    : > "$D/tools/tracked-then-deleted.sh"
    if git -C "$D" init -q && git -C "$D" add -A \
       && git -C "$D" -c user.name=test -c user.email=test@example.invalid commit -qm copy; then
        rm -f "$D/tools/tracked-then-deleted.sh"
        printf 'echo fine\n' > "$D/tools/untracked.sh"
        mkdir -p "$D/packaging/arch/src"
        printf 'if then\n' > "$D/packaging/arch/src/ignored.sh"
        checksh "$D"
        status_is "inside git, untracked good, ignored broken and tracked-deleted scripts: exit 0" 0
        only_syntax_error_none
        # The index's .sh files, less the deleted one, plus the untracked
        # one, plus the engine and the recipe; not the ignored one.
        want=$(( $(git -C "$D" ls-files '*.sh' | wc -l) - 1 + 1 + 2 ))
        got=$(sed -n -E 's/^  ([0-9]+) files parse$/\1/p' <<<"$OUT")
        if [[ "$got" == "$want" ]]; then
            pass "and it parsed the $want scripts git knows of, untracked included"
        else
            bad "inside git the syntax step parsed '${got:-none}' files, wanted $want"
        fi

        # The deleted file back, so the untracked one is the only thing that
        # can fail this run.
        git -C "$D" checkout -q -- tools/tracked-then-deleted.sh
        printf 'if then\n' > "$D/tools/untracked.sh"
        checksh "$D"
        status_is "inside git, a syntax error in an untracked script fails check.sh" 1
        only_syntax_error "and it is the one named" "tools/untracked.sh"
    else
        bad "could not commit the copy into a scratch repository; the inside-git cases examined nothing"
    fi
fi

echo
SKIPPED=""
(( SKIP > 0 )) && SKIPPED=", $SKIP not exercised"
printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$SKIPPED"
(( FAIL == 0 ))
