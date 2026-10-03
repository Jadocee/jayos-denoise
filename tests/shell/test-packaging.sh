#!/usr/bin/env bash
#
# The checkout recipe, packaging/arch/PKGBUILD, without makepkg.
#
#   tests/shell/test-packaging.sh
#
# Exit 0: every case passed. 1: a case failed. There is no exit 2: nothing
# here needs more than bash, sed, grep and coreutils, so there is no machine
# that can start this suite and not run all of it.
#
# makepkg is an Arch tool and this suite has to run where it is not. So the
# recipe is sourced and read the way makepkg reads it, and each of its
# functions is called the way makepkg calls one -- under errexit and errtrace,
# with startdir, srcdir and pkgdir set -- in a scratch tree whose
# packaging/steps.sh is a stub that records what it was asked and fails when
# told to. The stub, not the real script, because what the recipe owns is
# where its sources come from and which steps it calls in what order; every
# build flag, proof and installed path is packaging/steps.sh's, and
# tests/shell/test-steps.sh holds those against fakes.
#
# What this does NOT prove, and is read rather than run: that makepkg accepts
# the file (no makepkg or namcap here), that the source=() line clones, and
# that makepkg's run_function_safe gives a function the same errexit and
# errtrace that `bash -eE` gives it here.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPE="$ROOT/packaging/arch/PKGBUILD"
STEPS_TXT="$ROOT/contract/steps.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/denoise-packaging-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Sourced in a subshell for each question, so nothing it sets leaks into the
# next case. startdir is the real one here; the function runs below point it
# at a scratch tree instead.
recipe() { ( set +u; startdir="$ROOT/packaging/arch"; source "$RECIPE"; eval "$1" ); }

# The recipe with its comments stripped, for the questions a sourced recipe
# cannot answer (how many lines assign the pin, which steps the text calls).
# Without the strip, the header's own `_commit` prose and a commented-out
# `_steps` line would satisfy the checks written to find the real ones. A `#`
# counts as a comment only at the start of a line or after a space, which is
# also what keeps source=()'s `.git#commit=` intact.
CODE=$(sed -E 's/(^|[[:space:]])#.*$//' "$RECIPE")

# has <array-name> <value>: is <value> one of the recipe's <array-name>?
has() { recipe "for v in \"\${$1[@]}\"; do [[ \$v == '$2' ]] && exit 0; done; exit 1"; }

echo "the recipe"

if bash -n "$RECIPE"; then
    pass "it parses"
else
    bad "it does not parse"
fi

# Every function the recipe defines is one this suite runs below, or one of
# the two helpers they share. A pkgver() or a split package_*() added later
# would otherwise be a function makepkg calls and nothing here has ever run.
fns=$(env -i PATH="$PATH" bash --norc --noprofile -c \
          'startdir=$1; source "$2"; declare -F | sed "s/^declare -f //"' _ "$ROOT/packaging/arch" "$RECIPE" \
      | sort | tr '\n' ' ')
if [[ "$fns" == "_steps _tree build check package prepare " ]]; then
    pass "its functions are prepare, build, check and package, and the two helpers they share"
else
    bad "its functions are '$fns'; this suite runs prepare, build, check and package and knows of no others"
fi

if [[ "$(recipe 'printf %s "$pkgname"')" == "jayos-denoise" ]]; then
    pass "pkgname is jayos-denoise"
else
    bad "pkgname is '$(recipe 'printf %s "$pkgname"')', not jayos-denoise"
fi

# THE VERSION IS VERSION's. Written out rather than computed -- the recipe
# says why a pkgver() would rewrite it on every build -- so it is held here.
version=$(tr -d '[:space:]' < "$ROOT/VERSION")
pkgver=$(recipe 'printf %s "$pkgver"')
if [[ -n "$version" && "$pkgver" == "$version" ]]; then
    pass "pkgver is VERSION ($version)"
else
    bad "pkgver '$pkgver' is not VERSION '$version'"
fi

# THE PIN, read three ways that have to agree: this suite's own reading of
# the text, bash's (the sourced value, which is what source=() expands), and
# packaging/steps.sh's (what JayOS's recipe checks out). The text is read
# here rather than trusted to `steps.sh pin`, so a fault in that reader
# cannot hide a fault in the line; tests/shell/test-steps.sh holds the reader.
pin_lines=$(grep -E '^[[:space:]]*_commit=' <<<"$CODE")
pin_count=$(grep -c . <<<"$pin_lines")
pin_text=$(sed -E "s/^[[:space:]]*_commit=//; s/[[:space:]]+\$//; s/['\"]//g" <<<"$pin_lines")
if [[ "$pin_count" -eq 1 ]]; then
    pass "_commit is assigned on exactly one line"
else
    bad "_commit is assigned on $pin_count lines; steps.sh refuses anything but one"
fi
if [[ "$pin_count" -eq 1 && "$pin_text" =~ ^[0-9a-f]{40}$ ]]; then
    pass "_commit is forty lowercase hex digits ($pin_text)"
else
    bad "_commit reads '$pin_text', not a full forty-digit commit id"
fi
pin_sourced=$(recipe 'printf %s "$_commit"')
pin_steps=$(bash "$ROOT/packaging/steps.sh" pin 2>"$WORK/pin.err")
if [[ -n "$pin_text" && "$pin_sourced" == "$pin_text" && "$pin_steps" == "$pin_text" ]]; then
    pass "the sourced \$_commit and \`steps.sh pin\` are that same commit"
else
    bad "the pin disagrees: text '$pin_text', sourced '$pin_sourced', steps.sh pin '$pin_steps' $(cat "$WORK/pin.err")"
fi

# THE SOURCE: the fork, under the folder name both recipes and steps.sh use,
# at the pin -- through $_commit, so the pin stays one literal and a bump
# cannot move one line and not the other.
want_source="DeepFilterNetPlus::git+https://github.com/ismailivanov/DeepFilterNetPlus.git#commit=$pin_text"
sources=$(recipe 'printf "%s\n" "${source[@]}"')
if [[ "$sources" == "$want_source" ]]; then
    pass "source=() is the one fork clone, folder DeepFilterNetPlus, at #commit=\$_commit"
else
    bad "source=() is '$sources', not '$want_source'"
fi
if grep -qF '#commit=$_commit"' <<<"$CODE"; then
    pass "and it names the commit through \$_commit, not as a second literal"
else
    bad "source=() does not take its #commit= from \$_commit"
fi
# SKIP for a git source is the convention, not a hole: makepkg cannot
# checksum a clone, and git verifies every object against the commit id.
if [[ "$(recipe 'printf "%s\n" "${sha256sums[@]}"')" == "SKIP" ]]; then
    pass "sha256sums=() is SKIP, one entry for the one source"
else
    bad "sha256sums=() is '$(recipe 'printf "%s " "${sha256sums[@]}"')', not the one SKIP"
fi

if [[ "$(recipe 'printf "%s\n" "${arch[@]}"')" == "x86_64" ]]; then
    pass "arch=() is x86_64"
else
    bad "arch=() is '$(recipe 'printf "%s " "${arch[@]}"')', not x86_64"
fi

# Every packaging of the plugin provides and conflicts on this name, the
# retired deepfilternet-ladspa recipe in JayOS among them: without both, the
# two packages would each own /usr/lib/ladspa/libdeep_filter_ladspa.so.
for a in provides conflicts; do
    if has "$a" libdeep_filter_ladspa; then
        pass "$a=() names libdeep_filter_ladspa"
    else
        bad "$a=() does not name libdeep_filter_ladspa"
    fi
done

# The recipe's own header says why each of these is there; what is held here
# is that they are.
for o in '!lto' '!debug'; do
    if has options "$o"; then
        pass "options=() has $o"
    else
        bad "options=() lacks $o"
    fi
done
for m in cargo git; do
    if has makedepends "$m"; then
        pass "makedepends=() has $m"
    else
        bad "makedepends=() lacks $m"
    fi
done
# packaging/steps.sh's links_only_depends passes a .so whose NEEDED entries
# all belong to these two, and says so by naming them: a depends= without
# them would make that proof a proof about packages nothing installs.
for d in glibc gcc-libs; do
    if has depends "$d"; then
        pass "depends=() has $d, which steps.sh's NEEDED check is written against"
    else
        bad "depends=() lacks $d, which steps.sh's NEEDED check assumes it names"
    fi
done

echo
echo "every step the recipe calls is one steps.sh offers"

# contract/steps.txt is generated from steps.sh's dispatch by
# tools/contract.sh, which fails when the two differ; so a verb the recipe
# calls that is not listed there is a verb steps.sh answers with its usage.
declare -A SIG=()
while read -r verb rest; do
    [[ -z "$verb" || "$verb" == \#* ]] && continue
    SIG[$verb]=$rest
done < "$STEPS_TXT"
if (( ${#SIG[@]} > 0 )); then
    pass "contract/steps.txt lists ${#SIG[@]} verbs"
else
    bad "contract/steps.txt lists no verbs, so nothing below can be held to it"
fi
used=$(grep -oE '_steps[[:space:]]+[a-z]+' <<<"$CODE" | awk '{print $2}' | sort -u)
if [[ -n "$used" ]]; then
    pass "the recipe calls steps.sh's $(paste -sd' ' <<<"$used")"
else
    bad "the recipe calls no step at all"
fi
for verb in $used; do
    if [[ -v SIG[$verb] ]]; then
        pass "$verb is in contract/steps.txt"
    else
        bad "the recipe calls '$verb', which contract/steps.txt does not list"
    fi
done

echo
echo "each function, run as makepkg runs it, against a recording steps.sh"

# The scratch checkout the recipe will think it sits in. startdir is its
# packaging/arch, so _tree resolves two directories up to $TREE, and the
# steps.sh there is the stub. The stub is reached only through that
# resolution: had _tree resolved anywhere else, the real steps.sh would have
# refused a srcdir that does not exist and nothing would be recorded.
TREE="$WORK/tree"
STARTDIR="$TREE/packaging/arch"
SRCDIR="$WORK/build/src"
PKGDIR="$WORK/build/pkg"
mkdir -p "$STARTDIR" "$SRCDIR" "$PKGDIR"
cp "$RECIPE" "$STARTDIR/PKGBUILD"
# %q, so two arguments and one argument with a space in it cannot record the
# same line.
cat > "$TREE/packaging/steps.sh" <<STUB
#!/usr/bin/env bash
# A stand-in for packaging/steps.sh: records each call, fails the verb named
# in fail-verb.
{ printf '%q ' "\$@"; printf '\n'; } >> "$WORK/calls"
[[ "\$1" == "\$(cat "$WORK/fail-verb" 2>/dev/null)" ]] && exit 1
exit 0
STUB

# The line the stub records for <verb>, with steps.txt's placeholders filled
# the way the recipe is meant to fill them: <plugin-tree> is the fork's clone
# under srcdir, <pkgdir> is pkgdir. A placeholder this does not know fails,
# so a verb that grows an argument fails here until someone says what it is.
expect_call() { # expect_call <verb>
    local args=("$1") a
    [[ -v SIG[$1] ]] || return 1
    for a in ${SIG[$1]}; do
        case $a in
            "<plugin-tree>") args+=("$SRCDIR/DeepFilterNetPlus") ;;
            "<pkgdir>")      args+=("$PKGDIR") ;;
            *) return 1 ;;
        esac
    done
    printf '%q ' "${args[@]}"
    printf '\n'
}

# run_fn <function> [<verb to fail>]: the function, in a fresh bash under
# errexit and errtrace, from srcdir, as makepkg runs it. Its status is the
# status of that bash -- the function is a plain statement there, so errexit
# applies; called under `if` or `||` inside, errexit would be off.
run_fn() {
    : > "$WORK/calls"
    printf '%s' "${2:-}" > "$WORK/fail-verb"
    ( cd "$SRCDIR" && bash -eE -c \
        'startdir=$1 srcdir=$2 pkgdir=$3; source "$4"; '"$1" \
        _ "$STARTDIR" "$SRCDIR" "$PKGDIR" "$STARTDIR/PKGBUILD" ) >/dev/null 2>"$WORK/fn.err"
}

# Which steps each function calls, in order. prepare's order is the point of
# its case: fetch against a clone still at the default branch would fetch
# that branch's lockfile, not the pin's.
declare -A STEPS_OF=(
    [prepare]="checkout fetch"
    [build]="build"
    [check]="check"
    [package]="package"
)

for fn in prepare build check package; do
    want=""
    ok=1
    for verb in ${STEPS_OF[$fn]}; do
        line=$(expect_call "$verb") || { ok=0; break; }
        want+="$line"$'\n'
    done
    if (( ! ok )); then
        bad "$fn(): contract/steps.txt does not say how to call '$verb'"
        continue
    fi

    run_fn "$fn"
    rc=$?
    got=$(cat "$WORK/calls")
    if (( rc == 0 )) && [[ "$got"$'\n' == "$want" ]]; then
        said=""
        for verb in ${STEPS_OF[$fn]}; do said+="${said:+, then }$verb ${SIG[$verb]}"; done
        pass "$fn() calls $said"
    else
        bad "$fn() exited $rc and called: $(tr '\n' ';' <<<"$got") -- wanted: $(tr '\n' ';' <<<"$want") $(cat "$WORK/fn.err")"
    fi

    # Each step it calls, failing in turn: the function has to fail with it,
    # and nothing after the failed step may run. A recipe that wrote
    # `_steps checkout ... || true`, or ran fetch before checkout, would
    # build whatever the clone's default branch holds.
    upto=""
    for verb in ${STEPS_OF[$fn]}; do
        upto+=$(expect_call "$verb")$'\n'
        run_fn "$fn" "$verb"
        rc=$?
        got=$(cat "$WORK/calls")
        if (( rc != 0 )) && [[ "$got"$'\n' == "$upto" ]]; then
            pass "$fn() fails when steps.sh $verb fails, and calls nothing after it"
        else
            bad "$fn() exited $rc with steps.sh $verb failing, having called: $(tr '\n' ';' <<<"$got")"
        fi
    done
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
