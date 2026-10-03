#!/usr/bin/env bash
#
# The build, check and install steps of the jayos-denoise package.
#
#   steps.sh pin                          print the plugin commit this tree pins
#   steps.sh checkout <plugin-tree>       check that commit out, and prove it is out
#   steps.sh fetch <plugin-tree>          cargo fetch, locked, for this host only
#   steps.sh build <plugin-tree>          build the plugin with the full model
#   steps.sh check <plugin-tree>          prove what was built, run the fork's tests,
#                                         and check this tree's engine
#   steps.sh package <plugin-tree> <pkgdir>
#                                         install everything under <pkgdir>
#
# <plugin-tree> is a clone of ismailivanov/DeepFilterNetPlus. Exit 0 when the
# step did what it says, 1 when it did not, with a line on stderr saying why.
#
# WHY A SCRIPT, AND NOT THE STEPS WRITTEN INTO A RECIPE
#
# Two recipes build this package. packaging/arch/PKGBUILD builds the checkout
# it sits in; JayOS's pkgbuilds/jayos-denoise/PKGBUILD fetches this
# repository's main branch and builds that. Two recipes that each spelled out
# the cargo flags, the model proofs and the file list would drift, and the
# drift that matters is silent: a flag changed in one recipe builds the
# low-latency model in the other. So both call this, and the only thing either
# recipe owns is where its sources come from. JayOS installs from main, so a
# change to how the package is built is made here, once, and reaches JayOS's
# next build without a change over there.
#
# The verbs and their arguments are the interface JayOS's recipe calls, and
# contract/steps.txt lists them. Renaming one breaks JayOS's build.
#
# THE PIN
#
# One place: the _commit= line of packaging/arch/PKGBUILD, which that recipe
# needs as a literal for its source=() line. JayOS's recipe clones the fork
# with no fragment and `checkout` moves it to this commit, so bumping the pin
# here is the whole of a bump, for both. Read as text, never sourced, from a
# comment-stripped copy, and refused unless it is exactly one line of forty
# lowercase hex digits: a short id or a tag is a pin git does not verify.
#
# WHY THIS FORK, WHY --no-default-features, WHAT A BUILD COSTS
#
# docs/DEEPFILTERNET.md, which has the reasoning and the numbers; what
# follows says only what each step does and why it is written the way it is.

set -uo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
RECIPE="$ROOT/packaging/arch/PKGBUILD"
SO_NAME="libdeep_filter_ladspa.so"

die() { echo "steps.sh: $*" >&2; exit 1; }

usage() {
    echo "usage: steps.sh pin | checkout|fetch|build|check <plugin-tree> | package <plugin-tree> <pkgdir>" >&2
    exit 1
}

pinned_commit() {
    local lines
    [[ -f "$RECIPE" ]] || die "no $RECIPE to read the pin from"
    lines=$(sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*#/d' "$RECIPE" \
            | sed -n -E 's/^[[:space:]]*_commit=([^[:space:]]*)[[:space:]]*$/\1/p')
    [[ -n "$lines" ]] || die "$RECIPE has no _commit= line"
    [[ "$lines" != *$'\n'* ]] || die "$RECIPE assigns _commit on more than one line"
    lines=${lines//\'/}
    lines=${lines//\"/}
    [[ "$lines" =~ ^[0-9a-f]{40}$ ]] \
        || die "$RECIPE's _commit is '$lines', not a full forty-digit commit id"
    printf '%s\n' "$lines"
}

# The tree a step was handed, which every step but `pin` needs.
tree_arg() { # tree_arg <path>
    [[ -n "${1:-}" ]] || usage
    [[ -d "$1" ]] || die "no plugin tree at $1"
    realpath "$1"
}

# The toolchain name is for rustup, which is what JayOS's toolchain stage
# installs; a plain rust package ignores it. CARGO_TARGET_DIR under the tree
# even when the building user set one globally, so check and package find the
# .so where they look and a `makepkg -C` cleans it.
cargo_env() { # cargo_env <tree>
    export RUSTUP_TOOLCHAIN=stable
    export CARGO_TARGET_DIR="$1/target"
}

step_checkout() {
    local tree pin head
    tree=$(tree_arg "${1:-}") || exit 1
    pin=$(pinned_commit) || exit 1
    # makepkg's clone of a git source holds every ref of its mirror, so the
    # commit is there without the network whenever the fork still has it
    # reachable -- v1.0.2 is the tag that names it. A recipe that already
    # asked makepkg for #commit= gets a checkout of the same commit, which is
    # then proved like any other.
    git -C "$tree" -c advice.detachedHead=false checkout --quiet --detach "$pin" 2>/dev/null \
        || die "commit $pin is not in $tree; the fork no longer has it, or the clone is not of the fork"
    head=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || die "git could not say what $tree holds"
    [[ "$head" == "$pin" ]] || die "$tree is at $head after checking out $pin"
}

step_fetch() {
    local tree host
    tree=$(tree_arg "${1:-}") || exit 1
    cargo_env "$tree"
    # The lockfile is the pin for everything the commit id does not cover:
    # --locked refuses to resolve anything Cargo.lock does not already name,
    # and the host target keeps the fetch to what this machine builds.
    host=$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')
    [[ -n "$host" ]] || die "rustc did not say which target this host is; is a toolchain selected? (rustup default stable)"
    ( cd "$tree" && cargo fetch --locked --target "$host" ) || die "cargo fetch failed"
}

step_build() {
    local tree
    tree=$(tree_arg "${1:-}") || exit 1
    cargo_env "$tree"
    # --release, not the workspace's release-lto profile: that one has
    # panic = "abort", and the plugin catches the panic an unsupported host
    # sample rate raises and turns it into a logged refusal -- an aborting
    # panic would take the sound server down instead. --no-default-features
    # is the full model; docs/DEEPFILTERNET.md says why, and check proves it.
    ( cd "$tree" && cargo build --frozen --release -p deep-filter-ladspa --no-default-features ) \
        || die "cargo build failed"
}

# Does the built .so carry this file, byte for byte?
#
# libDF embeds the model with include_bytes!, so the tarball the build chose
# is inside the .so. Every gzip stream starts 1f 8b 08, which is the anchor:
# each place the .so has those three bytes is compared, by hash, against the
# whole tarball. sha256sum, tail and head rather than cmp, so the check needs
# nothing makepkg does not already need; cmp would make diffutils a
# checkdepends of both recipes.
embeds() { # embeds <so> <tarball>
    local so=$1 want size off
    want=$(sha256sum < "$2") || return 1
    size=$(stat -c %s "$2") || return 1
    for off in $(LC_ALL=C grep -aboF $'\x1f\x8b\x08' "$so" | cut -d: -f1); do
        [[ $(tail -c +$((off + 1)) "$so" | head -c "$size" | sha256sum) == "$want" ]] \
            && return 0
    done
    return 1
}

# Could embeds() find this tarball, if the .so carried it? Only if it is
# there and opens with the anchor embeds() searches by -- which an empty file
# does not, and an empty file is the one embeds() would otherwise match at
# every anchor, comparing zero bytes. od rather than a byte compare, for the
# reason embeds() gives: coreutils, which makepkg already needs.
findable() { # findable <tarball>
    [[ -f "$1" && $(head -c 3 "$1" | od -An -tx1 | tr -d ' \n') == 1f8b08 ]]
}

# 0 when every NEEDED entry of the .so belongs to glibc or gcc-libs, the two
# packages depends= names.
#
# A SUBSET, not an equal list: a toolchain that drops the loader (TLSDESC) or
# libm is still covered, while a libstdc++ or libhdf5 that nothing in
# depends= installs is not. An empty list fails too -- a readelf that read
# nothing would otherwise pass as "nothing outside". ld-linux-x86-64.so.2 is
# there for __tls_get_addr, which Rust std's thread-locals call from a shared
# object; the sentence that once said "libc, libm and libgcc_s, and nothing
# more" left it out.
links_only_depends() { # links_only_depends <so>
    local needed outside
    needed=$(readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p') || true
    if [[ -z "$needed" ]]; then
        echo "readelf read no NEEDED entry from ${1##*/}" >&2
        return 1
    fi
    outside=$(grep -vxE 'libc\.so\.6|libm\.so\.6|libgcc_s\.so\.1|ld-linux-x86-64\.so\.2' <<<"$needed") || true
    if [[ -n "$outside" ]]; then
        echo "${1##*/} links what depends= does not install: ${outside//$'\n'/ }" >&2
        return 1
    fi
}

check_plugin() { # check_plugin <tree>
    local tree=$1 so ftree syms
    so="$tree/target/release/$SO_NAME"
    [[ -f "$so" ]] || die "no $so; build first"
    cargo_env "$tree"

    # The resolved feature tree, not a comment's word for it -- INVERTED on
    # deep_filter, the crate whose features pick the model. A forward tree
    # never prints an edge the root crate's own feature table adds, and
    # ladspa/Cargo.toml's `default-model-ll = ["deep_filter/default-model-ll"]`
    # is such an edge: with the default features on, the low-latency build,
    # the forward tree still showed only `default-model` and both greps below
    # passed. The inverted tree lists every feature deep_filter ends up with,
    # whoever turned it on.
    #
    # Fixed-string greps: cargo tree marks a repeated node with a trailing
    # "(*)", so a $-anchored pattern misses a line that is there, and the
    # closing quote is part of the string because "default-model" is a prefix
    # of "default-model-ll". The `deep_filter ` prefix is part of it too: the
    # inverted tree also prints the ladspa crate's own feature of the same
    # name as the reason for one.
    ftree=$(cd "$tree" && cargo tree --frozen -e features -p deep-filter-ladspa \
                --no-default-features -i deep_filter) || die "cargo tree failed"
    grep -qF 'deep_filter feature "default-model"' <<<"$ftree" \
        || die "the full-model feature is not in the resolved feature tree"
    ! grep -qF 'deep_filter feature "default-model-ll"' <<<"$ftree" \
        || die "the low-latency model feature is in the resolved feature tree"

    # And the product, because the tree above is cargo run with this step's
    # flags, not the build's: a flag added to the build line alone would
    # change the .so and leave the tree as it was. The full model has to be
    # found and the low-latency one must not be; the positive half is what
    # stops a comparison that can never match -- a changed anchor, a changed
    # way of embedding -- from passing as an absence.
    #
    # It cannot do that for a low-latency tarball embeds() could never find.
    # Gone from models/ -- renamed upstream at a bumped pin, say -- or not a
    # gzip stream, "the .so does not carry it" is true of every .so there is;
    # and an empty full-model tarball is "carried" by any .so with an anchor
    # in it. So both have to be findable before either answer counts. Without
    # this, all three of those passed: RUN, against stand-ins, in
    # tests/shell/test-steps.sh, whose cases for them are what hold this.
    local m
    for m in DeepFilterNet3_onnx.tar.gz DeepFilterNet3_ll_onnx.tar.gz; do
        findable "$tree/models/$m" \
            || die "$tree/models/$m is missing, empty or not a gzip stream, so whether $SO_NAME carries it cannot be told"
    done
    embeds "$so" "$tree/models/DeepFilterNet3_onnx.tar.gz" \
        || die "$SO_NAME does not carry the full model"
    ! embeds "$so" "$tree/models/DeepFilterNet3_ll_onnx.tar.gz" \
        || die "$SO_NAME carries the low-latency model"

    # The symbol EasyEffects dlopens the file for. A cdylib that built but
    # exports no descriptor installs cleanly and loads as "not a LADSPA
    # plugin"; nm -D reads the dynamic table, which is what dlsym resolves.
    # Read whole before it is searched: piped into `grep -q`, which stops at
    # the first match, nm takes a SIGPIPE writing the rest, and under this
    # script's pipefail that 141 failed a .so that does export the symbol --
    # RUN, against the built plugin, which exports 117.
    syms=$(nm -D "$so") || die "nm could not read the dynamic symbols of $SO_NAME"
    grep -q ' T ladspa_descriptor$' <<<"$syms" \
        || die "$SO_NAME exports no ladspa_descriptor"

    links_only_depends "$so" || exit 1

    # The fork's own tests, three in ladspa/tests/no_rt_blocking.rs: the
    # real-time callback never blocks, mono and stereo, and an unsupported
    # host sample rate is refused before a model is built -- the caught panic
    # the --release choice protects. Compiling the harness adds about two
    # minutes; the tests themselves run in two seconds.
    ( cd "$tree" && cargo test --frozen --release -p deep-filter-ladspa --no-default-features ) \
        || die "the fork's tests failed"
}

# What can be said about the engine without EasyEffects: it parses, it knows
# its strengths, and every preset it would write is JSON. The engine's
# behaviour against a daemon is tests/shell's, which needs python3 and socat
# for its fakes -- more than a package build should ask for.
check_engine() {
    local s names
    bash -n "$ROOT/src/jayos-denoise" || die "src/jayos-denoise does not parse"
    bash -n "$ROOT/src/easyeffects-lib.sh" || die "src/easyeffects-lib.sh does not parse"
    names=$("$ROOT/src/jayos-denoise" strengths) || die "jayos-denoise strengths failed"
    [[ -n "$names" ]] || die "jayos-denoise names no strengths"
    for s in $names; do
        "$ROOT/src/jayos-denoise" preset "$s" | jq -e '.input["deepfilternet#0"].bypass == false' >/dev/null \
            || die "the $s preset is not JSON with the filter on"
        "$ROOT/src/jayos-denoise" preset "$s" off | jq -e '.input["deepfilternet#0"].bypass == true' >/dev/null \
            || die "the $s preset, off, is not JSON with the filter bypassed"
    done
}

step_check() {
    local tree
    tree=$(tree_arg "${1:-}") || exit 1
    check_plugin "$tree"
    check_engine
}

step_package() {
    local tree pkgdir lib
    tree=$(tree_arg "${1:-}") || exit 1
    [[ -n "${2:-}" ]] || usage
    pkgdir=$2
    lib="$pkgdir/usr/lib/jayos-denoise"

    # /usr/lib/ladspa is on EasyEffects' default search path, so no
    # LADSPA_PATH needs setting anywhere; the engine's library looks in the
    # same places. 755 is the mode every shared object under /usr/lib has.
    install -Dm755 "$tree/target/release/$SO_NAME" -t "$pkgdir/usr/lib/ladspa/" \
        || die "could not install $SO_NAME; build first"

    # The engine beside its library, and /usr/bin naming it by a relative
    # link: the engine finds the library through realpath, so the one
    # directory holds both whichever name it was started by.
    install -Dm755 "$ROOT/src/jayos-denoise" "$lib/jayos-denoise" || die "could not install the engine"
    install -Dm644 "$ROOT/src/easyeffects-lib.sh" "$lib/easyeffects-lib.sh" || die "could not install the library"
    install -d "$pkgdir/usr/bin" || die "could not make $pkgdir/usr/bin"
    ln -sfn ../lib/jayos-denoise/jayos-denoise "$pkgdir/usr/bin/jayos-denoise" || die "could not link the engine"

    # The contract, for a machine that wants to compare what it runs against
    # what a desktop built on this vendored.
    install -d "$pkgdir/usr/share/jayos-denoise/contract" || die "could not make the contract directory"
    install -m644 "$ROOT"/contract/* "$pkgdir/usr/share/jayos-denoise/contract/" || die "could not install the contract"

    # This repository's licence and its account of what came from elsewhere;
    # then the plugin's, which is dual-licensed at the user's option: its
    # LICENSE is the one-paragraph "either, at your option", and the two
    # texts it names go beside it.
    install -Dm644 "$ROOT/LICENSE" "$ROOT/THIRD_PARTY.md" -t "$pkgdir/usr/share/licenses/jayos-denoise/" \
        || die "could not install the licence"
    install -Dm644 "$tree/LICENSE" "$tree/LICENSE-MIT" "$tree/LICENSE-APACHE" \
        -t "$pkgdir/usr/share/licenses/jayos-denoise/DeepFilterNetPlus/" \
        || die "could not install the plugin's licences"
    install -Dm644 "$ROOT/README.md" "$ROOT/docs/DEEPFILTERNET.md" -t "$pkgdir/usr/share/doc/jayos-denoise/" \
        || die "could not install the documentation"
}

case "${1:-}" in
    pin)      pinned_commit ;;
    checkout) step_checkout "${2:-}" ;;
    fetch)    step_fetch "${2:-}" ;;
    build)    step_build "${2:-}" ;;
    check)    step_check "${2:-}" ;;
    package)  step_package "${2:-}" "${3:-}" ;;
    *)        usage ;;
esac
