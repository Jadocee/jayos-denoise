#!/usr/bin/env bash
#
# The build, check and install steps of the jayos-denoise package.
#
#   steps.sh pin                          print the plugin commit this tree pins
#   steps.sh checkout <plugin-tree>       check that commit out, prove it is out, and
#                                         apply packaging/patches/ to it
#   steps.sh fetch <plugin-tree>          cargo fetch, locked, for this host only: the
#                                         plugin's crates, then this tree's rust/
#   steps.sh build <plugin-tree>          build the plugin with the full model, and this
#                                         tree's two programs
#   steps.sh check <plugin-tree>          prove what was built, run the fork's tests,
#                                         check this tree's engine, and test its programs
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
# THE PATCHES
#
# packaging/patches/*.patch, in name order, onto the pinned commit, by
# `checkout`; `check` proves the tree it checks is that commit with every one
# of them in it and nothing else. They are this package's changes to the
# plugin, each with its reason in its own header, and docs/DEEPFILTERNET.md
# names them. A bump of the pin is the _commit= line and whatever patch no
# longer applies to the new commit: the checkout stops on that one, naming
# it, before anything is fetched.
#
# WHY THIS FORK, WHY --no-default-features, WHAT A BUILD COSTS
#
# docs/DEEPFILTERNET.md, which has the reasoning and the numbers; what
# follows says only what each step does and why it is written the way it is.
#
# THE TWO PROGRAMS
#
# rust/ is this tree's own Cargo workspace: jayos-audio-state and
# jayos-equalizer-preset, which came here from JayOS with the rest of its
# audio code (rust/crates/jayos-audio-tools/README.md). They ride the
# plugin's four verbs rather than verbs of their own, so that neither recipe
# changes for them -- JayOS's builds from main and calls exactly the forms
# contract/steps.txt lists -- and a package can never be built with the
# plugin and without the programs JayOS's volume popup runs.

set -uo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
RECIPE="$ROOT/packaging/arch/PKGBUILD"
PATCHES="$ROOT/packaging/patches"
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

# The patches, one path per line, in the order they apply: the glob's, in the
# C locale's byte order, so the order is the names' on every machine and not
# whatever the building user's collation makes of them.
patch_list() {
    local LC_ALL=C p
    for p in "$PATCHES"/*.patch; do
        [[ -f "$p" ]] && printf '%s\n' "$p"
    done
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

# MOLD LINKS WHAT THIS BUILDS -- the plugin, its tests and the two programs --
# by JayOS's owner's call of 2026-11-13, "use https://github.com/rui314/mold
# for building rust". As a link argument to the C compiler rustc drives, which
# takes over from Rust's own LLD (rust/.cargo/config.toml says how, and what
# was run to show it), and through RUSTFLAGS rather than a cargo config:
# makepkg.conf sets RUSTFLAGS, and cargo takes that in place of every config's
# flags, the fork's and rust/'s alike. Appended to what is there, once, so
# makepkg's own flags stay and a second step in one shell does not repeat it.
#
# Refused before cargo where mold is missing: both recipes name it among their
# makedepends, so a build without it is one makepkg did not prepare, and its
# first link would fail minutes into the build. Only the steps that link ask;
# fetch downloads and links nothing.
MOLD_FLAG="-C link-arg=-fuse-ld=mold"
link_with_mold() {
    command -v ld.mold >/dev/null 2>&1 \
        || die "mold is not installed, and this build links with it (pacman -S mold)"
    [[ " ${RUSTFLAGS:-} " == *" $MOLD_FLAG "* ]] || export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$MOLD_FLAG"
}

# This tree's workspace, and the two programs it builds. Their target
# directory is rust/target for cargo_env's reasons: in the clone makepkg made,
# under srcdir, where check and package find the programs and `makepkg -C`
# cleans them, whatever the building user set globally. Each cargo call over
# it runs in a subshell, so that the plugin's CARGO_TARGET_DIR, exported in
# the same step, is never the one these build into.
TOOLS="$ROOT/rust"
TOOL_BINS=(jayos-audio-state jayos-equalizer-preset)
tools_dir() {
    [[ -f "$TOOLS/Cargo.toml" && -f "$TOOLS/Cargo.lock" ]] \
        || die "no rust/Cargo.toml and Cargo.lock in $ROOT, so the programs cannot be built"
}
tools_cargo() { # tools_cargo <cargo args>...
    ( cd "$TOOLS" && RUSTUP_TOOLCHAIN=stable CARGO_TARGET_DIR="$TOOLS/target" cargo "$@" )
}

step_checkout() {
    local tree pin head
    tree=$(tree_arg "${1:-}") || exit 1
    pin=$(pinned_commit) || exit 1
    # makepkg's working copy of a git source is a shared clone (`git clone
    # -s`) of its mirror, so it reads every object the mirror fetched
    # through objects/info/alternates, not only what its own branches and
    # tags reach. That makepkg clones that way is READ (libmakepkg's
    # source/git.sh); the alternates half is RUN with git alone: a shared
    # clone of a --mirror, holding only refs/heads and refs/remotes, checked
    # out a commit that only the mirror's refs/pull/1/head reached. So the
    # pinned commit is there without the network whenever the fork still
    # has it reachable from any ref -- v1.0.2 is the tag that names it. A
    # recipe that already asked makepkg for #commit= gets a checkout of the
    # same commit, which is then proved like any other.
    #
    # --force puts every tracked file back to the commit, so the patches
    # below always go onto the pin itself: a second prepare() over the same
    # srcdir hands this a clone it has already patched, whose HEAD the
    # checkout does not move, and a patch applied over itself is refused.
    # Asking each patch whether it is already there instead is no answer --
    # git apply --reverse --check reads a patch against the tree as it is,
    # so the first of two patches to one file reads as absent once the
    # second is in (RUN, git 2.43). Untracked files, cargo's target/ among
    # them, are left alone.
    git -C "$tree" -c advice.detachedHead=false checkout --quiet --force --detach "$pin" 2>/dev/null \
        || die "commit $pin is not in $tree; the fork no longer has it, or the clone is not of the fork"
    head=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || die "git could not say what $tree holds"
    [[ "$head" == "$pin" ]] || die "$tree is at $head after checking out $pin"

    # In order, each checked against the tree the ones before it made, so a
    # patch to a file an earlier one changed is read the way it was written.
    # One that does not apply stops here, before the fetch, naming itself: a
    # patch written for the commit before a bump.
    local p name
    while IFS= read -r p; do
        name=${p#"$ROOT/"}
        git -C "$tree" apply --check "$p" 2>/dev/null \
            || die "$name does not apply to $pin, after the patches before it; a patch written for another commit has to be refreshed for this one"
        git -C "$tree" apply "$p" || die "git could not apply $name to $tree"
    done < <(patch_list)
}

# 0 when the tracked files of <tree> are exactly <commit> with every patch
# applied in order. The patches go into a scratch index made from the commit,
# never into the tree, and the tree is compared with that index: a patch
# missing, one left out of the middle, or any other change to a tracked file
# is a difference. Untracked files -- the build's target/ -- are not
# compared. One at a time, as checkout applies them: `git apply --check` with
# several patches reads each against the tree alone, and refused two that
# apply in order (RUN, git 2.43).
carries_patches() { # carries_patches <tree> <commit>
    local tree=$1 commit=$2 dir p rc=0
    dir=$(mktemp -d) || return 1
    GIT_INDEX_FILE="$dir/index" git -C "$tree" read-tree "$commit" 2>/dev/null || rc=1
    while (( rc == 0 )) && IFS= read -r p; do
        GIT_INDEX_FILE="$dir/index" git -C "$tree" apply --cached "$p" 2>/dev/null || rc=1
    done < <(patch_list)
    (( rc == 0 )) && { GIT_INDEX_FILE="$dir/index" git -C "$tree" diff --quiet 2>/dev/null || rc=1; }
    rm -rf "$dir"
    return "$rc"
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
    # The programs' crates the same way, so build can be --frozen: makepkg's
    # build() may run where prepare() had the network and it has none.
    tools_dir
    tools_cargo fetch --locked --target "$host" || die "cargo fetch failed for rust/"
}

step_build() {
    local tree
    tree=$(tree_arg "${1:-}") || exit 1
    cargo_env "$tree"
    link_with_mold
    # --release, not the workspace's release-lto profile: that one has
    # panic = "abort", and the plugin catches the panic an unsupported host
    # sample rate raises and turns it into a logged refusal -- an aborting
    # panic would take the sound server down instead. --no-default-features
    # is the full model; docs/DEEPFILTERNET.md says why, and check proves it.
    ( cd "$tree" && cargo build --frozen --release -p deep-filter-ladspa --no-default-features ) \
        || die "cargo build failed"
    # The workspace's own release profile, JayOS's settings: fat LTO and one
    # codegen unit for programs whose point is to start fast, and
    # panic = "abort", which the plugin cannot have and these want -- a
    # helper that fails exits, and nothing catches a panic in them.
    tools_dir
    tools_cargo build --frozen --release -p jayos-audio-tools --bins \
        || die "cargo build failed for rust/"
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

# 0 when every NEEDED entry of the .so belongs to glibc or gcc-libs, the
# plugin's share of depends= (the rest are the engine's, and
# tests/shell/test-packaging.sh ties each to a command the engine runs).
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
    local tree=$1 so ftree syms pin
    so="$tree/target/release/$SO_NAME"
    [[ -f "$so" ]] || die "no $so; build first"
    cargo_env "$tree"

    # The tree is the pin with every patch in it and nothing else: what was
    # built from it is the plugin this package is, and the fork's tests below
    # run over the patched source, the patches' own tests among them. A
    # recipe that let makepkg's #commit= checkout stand and never ran
    # `checkout` would otherwise build the fork as it is and pass.
    if [[ -n "$(patch_list)" ]]; then
        pin=$(pinned_commit) || exit 1
        carries_patches "$tree" "$pin" \
            || die "$tree is not commit $pin with packaging/patches/ applied, and only that; checkout makes it so"
    fi

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
    # RUN, against the built plugin, whose nm -D list is 117 lines: two of
    # them exported (ladspa_descriptor and get_ladspa_descriptor), the
    # other 115 imports.
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

# What can be said about the engine without PipeWire: the engine, the 1.x
# command and the library parse, the two commands name the same strengths,
# and the host configuration written for each is balanced and names the
# plugin's mono label and the source the desktop records from, with that
# strength's attenuation. Whether PipeWire loads it is tests/shell/test-host.sh's,
# which needs a running PipeWire and WirePlumber -- more than a package
# build should ask for.
config_balanced() { # config_balanced <text>: brackets balance outside strings and comments
    awk '
        { gsub(/"[^"]*"/, ""); sub(/#.*/, "") }
        { for (i = 1; i <= length($0); i++) {
              c = substr($0, i, 1)
              if (c == "{" || c == "[") depth++
              if (c == "}" || c == "]") { depth--; if (depth < 0) bad = 1 }
          } }
        END { exit (bad || depth != 0) }
    ' <<<"$1"
}

check_engine() {
    local s names shim conf atten
    bash -n "$ROOT/src/jayos-audio" || die "src/jayos-audio does not parse"
    bash -n "$ROOT/src/jayos-denoise" || die "src/jayos-denoise does not parse"
    bash -n "$ROOT/src/easyeffects-lib.sh" || die "src/easyeffects-lib.sh does not parse"
    bash -n "$ROOT/src/easyeffects.sh" || die "src/easyeffects.sh does not parse"
    names=$("$ROOT/src/jayos-audio" denoise strengths) || die "jayos-audio denoise strengths failed"
    [[ -n "$names" ]] || die "jayos-audio names no strengths"
    shim=$("$ROOT/src/jayos-denoise" strengths) || die "jayos-denoise strengths failed"
    [[ "$shim" == "$names" ]] || die "jayos-denoise names other strengths than jayos-audio"
    for s in $names; do
        conf=$("$ROOT/src/jayos-audio" denoise config "$s") || die "the $s configuration could not be written"
        config_balanced "$conf" || die "the $s configuration's brackets do not balance"
        grep -Eq '^[[:space:]]*label[[:space:]]+= deep_filter_mono$' <<<"$conf" \
            || die "the $s configuration does not name deep_filter_mono"
        grep -Eq '^[[:space:]]*node\.name[[:space:]]+= "jayos_denoise_source"$' <<<"$conf" \
            || die "the $s configuration does not name jayos_denoise_source"
        atten=$(sed -n 's/^[[:space:]]*"Attenuation Limit (dB)"[[:space:]]*= \([0-9.]*\)$/\1/p' <<<"$conf")
        [[ "$atten" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "the $s configuration sets no attenuation"
    done
}

# The programs: what they link, their unit tests, and the built
# jayos-audio-state run whole against fake pactl, wpctl and pw-dump.
#
# The NEEDED check is the plugin's, for the same reason: a program that
# links a library depends= does not install runs on the build machine and
# nowhere else. The unit tests are the dev profile's, not the release
# build's -- tests ignore panic = "abort", and LTO over a test harness would
# double the step for nothing they test. And tests/shell/test-audio-state.sh
# over the release binary, because the unit tests cover every pure function
# and none of main(), which is where the decisions are that JayOS's popup
# shows: three mis-wirings of main() passed every unit test (that suite's
# header). Its exit 2 is a failure here as well: it is the suite saying it
# examined nothing, and the binary it was handed was just built.
check_tools() {
    local b suite="$ROOT/tests/shell/test-audio-state.sh"
    tools_dir
    for b in "${TOOL_BINS[@]}"; do
        [[ -f "$TOOLS/target/release/$b" ]] || die "no $TOOLS/target/release/$b; build first"
        links_only_depends "$TOOLS/target/release/$b" || exit 1
    done
    tools_cargo test --frozen --workspace || die "the programs' tests failed"
    [[ -f "$suite" ]] || die "no $suite to run the built jayos-audio-state against"
    JAYOS_AUDIO_STATE_BIN="$TOOLS/target/release/jayos-audio-state" bash "$suite" \
        || die "tests/shell/test-audio-state.sh failed against the built jayos-audio-state"
}

step_check() {
    local tree
    tree=$(tree_arg "${1:-}") || exit 1
    # The tests link as the build did, and with the same flags, so cargo
    # reuses what build compiled rather than building its 145 or so crates again.
    link_with_mold
    check_plugin "$tree"
    check_engine
    check_tools
}

step_package() {
    local tree pkgdir lib share f
    tree=$(tree_arg "${1:-}") || exit 1
    [[ -n "${2:-}" ]] || usage
    pkgdir=$2
    lib="$pkgdir/usr/lib/jayos-audio"
    share="$pkgdir/usr/share"

    # /usr/lib/ladspa is on EasyEffects' default search path and the one the
    # engine looks in first after /usr/local, so no LADSPA_PATH needs setting
    # anywhere. 755 is the mode every shared object under /usr/lib has.
    install -Dm755 "$tree/target/release/$SO_NAME" -t "$pkgdir/usr/lib/ladspa/" \
        || die "could not install $SO_NAME; build first"

    # The engine, the 1.x command beside it, EasyEffects' verbs that
    # `jayos-audio easyeffects` hands on (moved here from JayOS), the library
    # both use, and VERSION, which `jayos-audio version` reads beside itself.
    # /usr/bin names the two commands by relative links: each finds the
    # others through realpath, whichever name it was started by.
    install -Dm755 "$ROOT/src/jayos-audio" "$lib/jayos-audio" || die "could not install the engine"
    install -Dm755 "$ROOT/src/jayos-denoise" "$lib/jayos-denoise" || die "could not install jayos-denoise"
    install -Dm644 "$ROOT/src/easyeffects-lib.sh" "$lib/easyeffects-lib.sh" || die "could not install the library"
    install -Dm644 "$ROOT/src/easyeffects.sh" "$lib/easyeffects.sh" || die "could not install easyeffects.sh"
    install -Dm644 "$ROOT/VERSION" "$lib/VERSION" || die "could not install VERSION"
    install -d "$pkgdir/usr/bin" || die "could not make $pkgdir/usr/bin"
    ln -sfn ../lib/jayos-audio/jayos-audio "$pkgdir/usr/bin/jayos-audio" || die "could not link the engine"
    ln -sfn ../lib/jayos-audio/jayos-denoise "$pkgdir/usr/bin/jayos-denoise" || die "could not link jayos-denoise"

    # The two programs, in /usr/bin itself: JayOS runs them by that path
    # (its paths.sh's QS_PKG_BIN, and Paths.qml's pkgBinDir), and they find
    # nothing beside themselves, so no link is needed.
    local b
    for b in "${TOOL_BINS[@]}"; do
        install -Dm755 "$TOOLS/target/release/$b" -t "$pkgdir/usr/bin/" \
            || die "could not install $b; build first"
    done

    # The noise-suppression host's unit, a user unit, where systemd's user
    # manager reads a package's own.
    install -Dm644 "$ROOT/systemd/jayos-audio-denoise.service" -t "$pkgdir/usr/lib/systemd/user/" \
        || die "could not install the unit"

    # PipeWire's and WirePlumber's drop-ins, in their packages' own
    # directories: read before /etc and ~/.config, so that a file of a
    # person's own, at a later name, wins (each file says what it is for).
    while IFS= read -r f; do
        install -Dm644 "$ROOT/share/$f" "$share/$f" || die "could not install share/$f"
    done < <(cd "$ROOT/share" && find . -type f -name '*.conf' | sed 's|^\./||' | LC_ALL=C sort)

    # The contract, for a machine that wants to compare what it runs against
    # what a desktop built on this vendored.
    install -d "$share/jayos-audio/contract" || die "could not make the contract directory"
    install -m644 "$ROOT"/contract/* "$share/jayos-audio/contract/" || die "could not install the contract"

    # This repository's licence and its account of what came from elsewhere;
    # then the plugin's, which is dual-licensed at the user's option: its
    # LICENSE is the one-paragraph "either, at your option", and the two
    # texts it names go beside it.
    install -Dm644 "$ROOT/LICENSE" "$ROOT/THIRD_PARTY.md" -t "$share/licenses/jayos-audio/" \
        || die "could not install the licence"
    install -Dm644 "$tree/LICENSE" "$tree/LICENSE-MIT" "$tree/LICENSE-APACHE" \
        -t "$share/licenses/jayos-audio/DeepFilterNetPlus/" \
        || die "could not install the plugin's licences"
    install -Dm644 "$ROOT/README.md" "$ROOT/docs/AUDIO.md" "$ROOT/docs/DEEPFILTERNET.md" -t "$share/doc/jayos-audio/" \
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
