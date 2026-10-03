#!/usr/bin/env bash
#
# packaging/steps.sh, against fakes.
#
#   tests/shell/test-steps.sh
#
# Exit 0: every case passed. 1: a case failed. 2: could not run -- no git
# (the checkout cases need a real repository), no jq (check's engine half and
# the installed engine's status run it), or no gzip (the model stand-ins are
# real gzip streams) -- which is not the same answer as "nothing is wrong" and
# must not be reported as one.
#
# WHAT IS REAL AND WHAT IS FAKED
#
# steps.sh is copied into a scratch checkout beside a scratch
# packaging/arch/PKGBUILD, src/, contract/ and documents, so the ROOT it
# derives and the pin it reads are the scratch ones and no case can read or
# write this repository. git, gzip, the sha256sum/tail/head behind embeds(),
# install(1), jq and the engine are real. cargo, rustc, nm and readelf are
# fakes first on PATH: they record the arguments and the environment steps.sh
# gave them, and print what a case puts in front of them -- feature trees cut
# from a real `cargo tree` of the pinned fork, symbol and NEEDED lists shaped
# like the real plugin's.
#
# Each failure case changes ONE thing from a configuration that passes, and
# asserts the sentence steps.sh dies with, not only the status: a fixture
# that failed for some other reason would otherwise pass every "it fails"
# case while proving none of them.
#
# What this does NOT prove: that the real cargo builds the fork, that the
# real .so carries the full model, that the fork's own tests pass. Those are
# `steps.sh check` against a real build of the pin, which needs the fork's
# sources, a Rust toolchain and about two minutes; this suite needs none of
# them. That run is RUN by hand, not here.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for tool in git jq gzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$(basename "$0"): $tool is not installed; these tests cannot run" >&2
        exit 2
    }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/denoise-steps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK=$(realpath "$WORK")

PASS=0
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# git that cannot see anything but what a case made: no global or system
# configuration (a signing hook or a template there would change a commit),
# and no walking above $WORK, so a case that hands steps.sh a plain directory
# cannot land in whatever repository $TMPDIR happens to sit inside.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES="$WORK"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# THE SCRATCH CHECKOUT. Documents and licences are stand-ins with distinct
# text, so the byte comparisons below also catch one file installed under
# another's name; README.md and docs/DEEPFILTERNET.md are not real files here
# because this repository's may not exist yet, and package has to fail
# cleanly without them -- which is one of its cases.
REPO="$WORK/repo"
mkdir -p "$REPO/packaging/arch" "$REPO/src" "$REPO/contract" "$REPO/docs"
cp "$ROOT/packaging/steps.sh" "$REPO/packaging/steps.sh"
cp "$ROOT/src/jayos-denoise" "$ROOT/src/easyeffects-lib.sh" "$REPO/src/"
cp "$ROOT"/contract/* "$REPO/contract/"
printf 'stand-in: this repository'"'"'s licence\n' > "$REPO/LICENSE"
printf 'stand-in: third-party notices\n' > "$REPO/THIRD_PARTY.md"
printf 'stand-in: the readme\n' > "$REPO/README.md"
printf 'stand-in: the DeepFilterNet document\n' > "$REPO/docs/DEEPFILTERNET.md"
STEPS="$REPO/packaging/steps.sh"
PIN_FILE="$REPO/packaging/arch/PKGBUILD"

# THE FAKES. They find their control files beside themselves, so nothing
# has to be exported to reach them through steps.sh.
F="$WORK/fake"
mkdir -p "$WORK/bin" "$F"

cat > "$WORK/bin/cargo" <<'FAKE'
#!/usr/bin/env bash
# cargo: records argv and the environment it was run with, prints tree.out
# for `tree`, and exits with status.<subcommand> (0 when there is none).
F="$(dirname "$0")/../fake"
{ printf '%q ' "$@"; printf '\n'; } >> "$F/cargo.argv"
printf '%s RUSTUP_TOOLCHAIN=%s CARGO_TARGET_DIR=%s PWD=%s\n' \
    "$1" "${RUSTUP_TOOLCHAIN-<unset>}" "${CARGO_TARGET_DIR-<unset>}" "$PWD" >> "$F/cargo.env"
[[ "$1" == tree ]] && cat "$F/tree.out"
s=0; [[ -f "$F/status.$1" ]] && s=$(<"$F/status.$1")
exit "$s"
FAKE

cat > "$WORK/bin/rustc" <<'FAKE'
#!/usr/bin/env bash
# rustc: prints rustc.out (what `rustc -vV` would) and exits with status.rustc.
F="$(dirname "$0")/../fake"
{ printf '%q ' "$@"; printf '\n'; } >> "$F/rustc.argv"
cat "$F/rustc.out"
s=0; [[ -f "$F/status.rustc" ]] && s=$(<"$F/status.rustc")
exit "$s"
FAKE

# nm hands its output to cat by exec, so it is ONE process writing the whole
# list, as the real nm is: a SIGPIPE part-way through ends it with 141, which
# is the failure the large-output case exists to provoke.
cat > "$WORK/bin/nm" <<'FAKE'
#!/usr/bin/env bash
# nm: prints nm.out, or exits with status.nm and prints nothing.
F="$(dirname "$0")/../fake"
{ printf '%q ' "$@"; printf '\n'; } >> "$F/nm.argv"
[[ -f "$F/status.nm" ]] && exit "$(<"$F/status.nm")"
exec cat "$F/nm.out"
FAKE

cat > "$WORK/bin/readelf" <<'FAKE'
#!/usr/bin/env bash
# readelf: prints readelf.out.
F="$(dirname "$0")/../fake"
{ printf '%q ' "$@"; printf '\n'; } >> "$F/readelf.argv"
cat "$F/readelf.out"
FAKE
chmod 755 "$WORK/bin"/*

# steps <verb> [args...]: the scratch steps.sh, fakes first on PATH.
# Sets RC, OUT (stdout) and ERR (stderr).
steps() {
    OUT=$(PATH="$WORK/bin:$PATH" bash "$STEPS" "$@" 2>"$WORK/err")
    RC=$?
    ERR=$(<"$WORK/err")
}
oneline() { tr '\n' ' ' <<<"$1"; }
expect_ok() { # expect_ok <label>
    if (( RC == 0 )); then pass "$1"; else bad "$1: exit $RC: $(oneline "$ERR")"; fi
}
# Exactly 1, which is steps.sh's "did not do what it says"; a 141 or a 127
# is a crash that happens to be non-zero, not the refusal under test.
expect_fail() { # expect_fail <label> <fragment of the sentence steps.sh dies with>
    if (( RC == 1 )) && [[ "$ERR" == *"$2"* ]]; then
        pass "$1"
    else
        bad "$1: exit $RC, wanted 1 saying '$2'; stderr: $(oneline "$ERR")"
    fi
}

H1=d97178d739dffc9f862315cad83f79d40580dc3d
H2=0123456789abcdef0123456789abcdef01234567

echo "pin: the _commit= line, read as text"

pin_case() { # pin_case <label> <PKGBUILD text> ok <commit> | fail <fragment>
    printf '%s\n' "$2" > "$PIN_FILE"
    steps pin
    if [[ "$3" == ok ]]; then
        if (( RC == 0 )) && [[ "$OUT" == "$4" ]]; then
            pass "$1"
        else
            bad "$1: exit $RC, printed '$OUT', wanted '$4'; stderr: $(oneline "$ERR")"
        fi
    else
        expect_fail "$1" "$4"
    fi
}

pin_case "one line of forty lowercase hex digits is the pin" \
    "_commit=$H1" ok "$H1"
pin_case "two lines assigning it are refused" \
    "_commit=$H1"$'\n'"_commit=$H2" fail "more than one line"
pin_case "a short id is refused" \
    "_commit=${H1:0:7}" fail "not a full forty-digit commit id"
pin_case "a tag name is refused" \
    "_commit=v1.0.2" fail "not a full forty-digit commit id"
pin_case "forty-one digits are refused" \
    "_commit=${H1}0" fail "not a full forty-digit commit id"
pin_case "upper-case hex is refused" \
    "_commit=${H1^^}" fail "not a full forty-digit commit id"
pin_case "a commented-out _commit= is not read, at column 0, after '# ', or indented" \
    "#_commit=$H2"$'\n'"# _commit=$H2"$'\n'"    # _commit=$H2"$'\n'"_commit=$H1" ok "$H1"
pin_case "and commented-out lines alone are no pin" \
    "# _commit=$H1"$'\n'"#_commit=$H1" fail "has no _commit= line"
pin_case "a trailing comment is not part of the value" \
    "_commit=$H1  # v1.0.2, peeled" ok "$H1"
pin_case "single quotes are allowed" \
    "_commit='$H1'" ok "$H1"
pin_case "double quotes are allowed, with a trailing comment" \
    "_commit=\"$H1\" # pinned" ok "$H1"
pin_case "source=()'s #commit=\$_commit is not a second assignment" \
    "_commit=$H1"$'\n'"source=(\"X::git+https://example.invalid/x.git#commit=\$_commit\")" ok "$H1"
rm -f "$PIN_FILE"
steps pin
expect_fail "no PKGBUILD is a refusal, not an empty pin" "to read the pin from"

# The real recipe, with only its pin replaced: the header's prose mentions
# _commit on several lines, and none of them may count.
pin_to() { sed -E "s/^_commit=.*/_commit=$1/" "$ROOT/packaging/arch/PKGBUILD" > "$PIN_FILE"; }
pin_to "$H2"
steps pin
if (( RC == 0 )) && [[ "$OUT" == "$H2" ]]; then
    pass "the real recipe's header prose about _commit is not read as a pin"
else
    bad "the real recipe, re-pinned to $H2, reads as '$OUT' (exit $RC): $(oneline "$ERR")"
fi

echo
echo "checkout: the pin, detached, proved"

# A fork with three commits, HEAD on the last; the pin is the middle one, so
# a checkout that did nothing, or that went to a branch tip, is visible.
FORK="$WORK/fork"
mkdir -p "$FORK"
git -C "$FORK" -c init.defaultBranch=main init -q
for n in 1 2 3; do
    printf 'commit %s\n' "$n" > "$FORK/file"
    git -C "$FORK" add file
    git -C "$FORK" commit -q -m "commit $n"
done
C2=$(git -C "$FORK" rev-parse HEAD~1)
C3=$(git -C "$FORK" rev-parse HEAD)

pin_to "$C2"
steps checkout "$FORK"
expect_ok "checkout moves the clone to the pin"
if [[ "$(git -C "$FORK" rev-parse HEAD)" == "$C2" && "$C2" != "$C3" ]]; then
    pass "HEAD is the pinned commit, not the branch tip"
else
    bad "HEAD is $(git -C "$FORK" rev-parse HEAD), not the pin $C2"
fi
if ! git -C "$FORK" symbolic-ref -q HEAD >/dev/null; then
    pass "and detached, so no branch claims to be the pin"
else
    bad "HEAD is on $(git -C "$FORK" symbolic-ref -q HEAD), not detached"
fi
# makepkg's own #commit= checkout has already put the checkout recipe's
# clone there; the step has to accept that, and prove it like any other.
steps checkout "$FORK"
expect_ok "a clone already at the pin is checked out again and passes"

pin_to "$H2"
steps checkout "$FORK"
expect_fail "a pin the clone does not hold fails, saying so" "commit $H2 is not in"
if [[ "$(git -C "$FORK" rev-parse HEAD)" == "$C2" ]]; then
    pass "and leaves the clone where it was"
else
    bad "the failed checkout moved HEAD to $(git -C "$FORK" rev-parse HEAD)"
fi

pin_to "$C2"
mkdir -p "$WORK/plain"
steps checkout "$WORK/plain"
expect_fail "a directory that is not a git clone fails" "is not in"
steps checkout "$WORK/no-such-dir"
expect_fail "a directory that does not exist fails" "no plugin tree at"
steps checkout
expect_fail "no tree at all is a usage error" "usage:"

echo
echo "fetch and build: cargo's arguments and environment"

HOST=x86_64-jayostest-linux-gnu
RUSTC_OK="rustc 1.90.0 (fake)
binary: rustc
commit-hash: 0000000000000000000000000000000000000000
host: $HOST
release: 1.90.0"
TREE=$(realpath "$FORK")

reset_cargo() {
    rm -f "$F"/status.* "$F"/*.argv "$F/cargo.env"
    printf '%s\n' "$RUSTC_OK" > "$F/rustc.out"
}

# A target directory and a toolchain the building user set globally, which
# steps.sh has to override: check and package look for the .so under the
# tree, and the toolchain is the one JayOS's toolchain stage installs.
reset_cargo
( export CARGO_TARGET_DIR="$WORK/elsewhere" RUSTUP_TOOLCHAIN=nightly
  steps fetch "$FORK"
  printf '%s' "$RC" > "$WORK/rc"; printf '%s' "$ERR" > "$WORK/errsave" )
RC=$(<"$WORK/rc"); ERR=$(<"$WORK/errsave")
expect_ok "fetch runs"
# The host is one no machine has, so a fetch that wrote its target down, or
# asked anything but rustc, cannot match it.
want="fetch --locked --target $HOST "
if [[ "$(cat "$F/cargo.argv" 2>/dev/null)" == "$want" ]]; then
    pass "fetch is \`cargo fetch --locked --target <the host rustc -vV names>\`"
else
    bad "fetch ran cargo as '$(cat "$F/cargo.argv" 2>/dev/null)', not '$want'"
fi
want="fetch RUSTUP_TOOLCHAIN=stable CARGO_TARGET_DIR=$TREE/target PWD=$TREE"
if [[ "$(cat "$F/cargo.env" 2>/dev/null)" == "$want" ]]; then
    pass "in the tree, with RUSTUP_TOOLCHAIN=stable and CARGO_TARGET_DIR=<tree>/target over the caller's"
else
    bad "fetch ran cargo with '$(cat "$F/cargo.env" 2>/dev/null)', not '$want'"
fi

reset_cargo
printf 'rustc 1.90.0 (fake)\nrelease: 1.90.0\n' > "$F/rustc.out"
steps fetch "$FORK"
expect_fail "a rustc that names no host fails fetch" "did not say which target"
if [[ ! -s "$F/cargo.argv" ]]; then
    pass "and cargo is never run with an empty --target"
else
    bad "cargo ran anyway: $(cat "$F/cargo.argv")"
fi
reset_cargo
printf '1' > "$F/status.rustc"
: > "$F/rustc.out"
steps fetch "$FORK"
expect_fail "a rustc that fails, printing nothing, fails fetch" "did not say which target"

reset_cargo
printf '101' > "$F/status.fetch"
steps fetch "$FORK"
expect_fail "a cargo fetch that fails fails fetch" "cargo fetch failed"

reset_cargo
( export CARGO_TARGET_DIR="$WORK/elsewhere" RUSTUP_TOOLCHAIN=nightly
  steps build "$FORK"
  printf '%s' "$RC" > "$WORK/rc"; printf '%s' "$ERR" > "$WORK/errsave" )
RC=$(<"$WORK/rc"); ERR=$(<"$WORK/errsave")
expect_ok "build runs"
# --no-default-features is the full model; the default features pull in
# default-model-ll. --release, not the workspace's release-lto, whose
# panic = "abort" would turn the plugin's caught sample-rate panic into a
# crash of the sound server.
want="build --frozen --release -p deep-filter-ladspa --no-default-features "
if [[ "$(cat "$F/cargo.argv" 2>/dev/null)" == "$want" ]]; then
    pass "build is \`cargo build --frozen --release -p deep-filter-ladspa --no-default-features\`"
else
    bad "build ran cargo as '$(cat "$F/cargo.argv" 2>/dev/null)', not '$want'"
fi
want="build RUSTUP_TOOLCHAIN=stable CARGO_TARGET_DIR=$TREE/target PWD=$TREE"
if [[ "$(cat "$F/cargo.env" 2>/dev/null)" == "$want" ]]; then
    pass "in the tree, with RUSTUP_TOOLCHAIN=stable and CARGO_TARGET_DIR=<tree>/target over the caller's"
else
    bad "build ran cargo with '$(cat "$F/cargo.env" 2>/dev/null)', not '$want'"
fi

reset_cargo
printf '101' > "$F/status.build"
steps build "$FORK"
expect_fail "a cargo build that fails fails build" "cargo build failed"
steps build
expect_fail "build with no tree is a usage error" "usage:"
steps fetch "$WORK/no-such-dir"
expect_fail "fetch of a directory that does not exist fails" "no plugin tree at"

echo
echo "check: what was built, proved"

# THE PLUGIN TREE: the two model tarballs where the fork keeps them, real
# gzip streams of different content, and a stand-in .so built out of them.
PLUG="$WORK/plugin"
SO="$PLUG/target/release/libdeep_filter_ladspa.so"
mkdir -p "$PLUG/models" "$PLUG/target/release" "$WORK/m/full" "$WORK/m/ll"
for n in $(seq 1 400); do printf 'full-model layer %04d weights\n' "$n"; done > "$WORK/m/full/enc.onnx"
for n in $(seq 1 400); do printf 'low-latency layer %04d weights\n' "$n"; done > "$WORK/m/ll/enc.onnx"
tar -C "$WORK/m/full" -czf "$WORK/full.tar.gz" enc.onnx
tar -C "$WORK/m/ll" -czf "$WORK/ll.tar.gz" enc.onnx
for t in full ll; do
    if [[ "$(head -c 3 "$WORK/$t.tar.gz" | od -An -tx1 | tr -d ' ')" != "1f8b08" ]]; then
        echo "$(basename "$0"): the $t stand-in is not a gzip stream; these tests cannot run" >&2
        exit 2
    fi
done

# Padding with no gzip anchor in it, and a decoy: an anchor followed by
# bytes that are no tarball, BEFORE the real one, so embeds() has to keep
# looking past the first place the three bytes occur.
pad() { for n in $(seq 1 200); do printf 'ELF stand-in, section %04d\n' "$n"; done; }
decoy() { printf '\x1f\x8b\x08 not a model, only its first three bytes\n'; }
make_so() { # make_so <out> <part>...: pad, decoy, then each part padded
    local out=$1 p
    shift
    { pad; decoy; pad
      for p in "$@"; do cat "$p"; pad; done
    } > "$out"
}
full_size=$(stat -c %s "$WORK/full.tar.gz")
# The full tarball less its last byte, then padding: every byte but one
# matches, which a comparison of anything less than the whole would pass.
head -c $((full_size - 1)) "$WORK/full.tar.gz" > "$WORK/full.cut"
make_so "$WORK/so.full" "$WORK/full.tar.gz"
make_so "$WORK/so.both" "$WORK/full.tar.gz" "$WORK/ll.tar.gz"
make_so "$WORK/so.ll" "$WORK/ll.tar.gz"
make_so "$WORK/so.cut" "$WORK/full.cut"

# The feature trees: `cargo tree --frozen -e features -p deep-filter-ladspa
# -i deep_filter`, RUN against the fork at the pin on 2026-10-03 -- the
# first with --no-default-features, as steps.sh asks, the second without,
# which is what a build that lost the flag resolves. Only the checkout's
# path is changed.
TREE_FULL='deep_filter v0.5.7-pre (/build/DeepFilterNetPlus/libDF)
├── deep_filter feature "default-model"
│   └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa)
├── deep_filter feature "logging"
│   └── deep_filter feature "tract"
│       └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa)
├── deep_filter feature "tract" (*)
├── deep_filter feature "transforms"
│   └── deep_filter feature "tract" (*)
└── deep_filter feature "use-jemalloc"
    └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa)'
TREE_DEFAULT='deep_filter v0.5.7-pre (/build/DeepFilterNetPlus/libDF)
├── deep_filter feature "default-model"
│   └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa)
│       ├── deep-filter-ladspa feature "default" (command-line)
│       └── deep-filter-ladspa feature "default-model-ll"
│           └── deep-filter-ladspa feature "default" (command-line)
├── deep_filter feature "default-model-ll"
│   └── deep-filter-ladspa feature "default-model-ll" (*)
├── deep_filter feature "logging"
│   └── deep_filter feature "tract"
│       └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa) (*)
├── deep_filter feature "tract" (*)
├── deep_filter feature "transforms"
│   └── deep_filter feature "tract" (*)
└── deep_filter feature "use-jemalloc"
    └── deep-filter-ladspa v0.5.7-pre (/build/DeepFilterNetPlus/ladspa) (*)'
# Synthetic, cut from those: neither model feature; the low-latency one
# alone, where "default-model" is a prefix of the only model line; and each
# model feature printed only as a repeated node, with cargo's trailing "(*)".
TREE_NONE=$(grep -v 'default-model' <<<"$TREE_FULL")
TREE_LL_ONLY=$(sed 's/feature "default-model"$/feature "default-model-ll"/' <<<"$TREE_FULL")
TREE_FULL_STAR=$(sed 's/feature "default-model"$/feature "default-model" (*)/' <<<"$TREE_FULL")
TREE_LL_STAR="$TREE_FULL
│   └── deep_filter feature \"default-model-ll\" (*)"

# Symbols as the real plugin's nm -D prints them: 117, two of them with
# "ladspa_descriptor" in the name. Only the second is the one EasyEffects
# dlsyms.
NM_OK='                 w __cxa_finalize@GLIBC_2.2.5
0000000000a8efb0 T get_ladspa_descriptor
0000000000a9b4e0 T ladspa_descriptor
                 U malloc@GLIBC_2.2.5'
NM_NONE='                 w __cxa_finalize@GLIBC_2.2.5
0000000000a8efb0 T get_ladspa_descriptor
                 U malloc@GLIBC_2.2.5'
NM_UNDEF='                 U ladspa_descriptor
                 U malloc@GLIBC_2.2.5'
# The descriptor first, then more than a megabyte of other symbols -- many
# times a pipe's 64 KiB, so a reader that stops at the first match leaves
# nm with most of its output still to write.
{ printf '0000000000a9b4e0 T ladspa_descriptor\n'
  for n in $(seq 1 40000); do printf '00000000%08x T _ZN4core3ptr%05dE\n' "$n" "$n"; done
} > "$WORK/nm.big"

readelf_out() { # readelf_out <NEEDED name>...: the shape of the real `readelf -d`
    local n
    printf '\nDynamic section at offset 0x19ca378 contains 29 entries:\n'
    printf '  Tag        Type                         Name/Value\n'
    for n in "$@"; do
        printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "$n"
    done
    printf ' 0x000000000000001e (FLAGS)              BIND_NOW\n'
    printf ' 0x000000006ffffffb (FLAGS_1)            Flags: NOW\n'
}
NEEDED_REAL=(libgcc_s.so.1 libm.so.6 libc.so.6 ld-linux-x86-64.so.2)

# Everything in the configuration that passes. Each failure case starts from
# here and changes one thing.
baseline() {
    rm -f "$F"/status.* "$F"/*.argv "$F/cargo.env"
    printf '%s\n' "$RUSTC_OK" > "$F/rustc.out"
    printf '%s\n' "$TREE_FULL" > "$F/tree.out"
    printf '%s\n' "$NM_OK" > "$F/nm.out"
    readelf_out "${NEEDED_REAL[@]}" > "$F/readelf.out"
    cp "$WORK/full.tar.gz" "$PLUG/models/DeepFilterNet3_onnx.tar.gz"
    cp "$WORK/ll.tar.gz" "$PLUG/models/DeepFilterNet3_ll_onnx.tar.gz"
    cp "$WORK/so.full" "$SO"
    cp "$ROOT/src/jayos-denoise" "$REPO/src/jayos-denoise"
    cp "$ROOT/src/easyeffects-lib.sh" "$REPO/src/easyeffects-lib.sh"
}
check_tree() { baseline; "$@"; steps check "$PLUG"; }
PLUG_REAL=$(realpath "$PLUG")

check_tree true
expect_ok "a full-model build with the descriptor, glibc and gcc-libs only, and passing tests, passes"
if [[ "$(sed -n 1p "$F/cargo.argv" 2>/dev/null)" == "tree --frozen -e features -p deep-filter-ladspa --no-default-features -i deep_filter " ]]; then
    pass "the feature tree is cargo's, inverted on deep_filter, with the build's flags"
else
    bad "cargo tree ran as '$(sed -n 1p "$F/cargo.argv" 2>/dev/null)'"
fi
if [[ "$(sed -n 2p "$F/cargo.argv" 2>/dev/null)" == "test --frozen --release -p deep-filter-ladspa --no-default-features " ]]; then
    pass "the fork's tests run with the build's flags, so they test what was built"
else
    bad "cargo test ran as '$(sed -n 2p "$F/cargo.argv" 2>/dev/null)'"
fi
if [[ "$(sed -n 1p "$F/cargo.env" 2>/dev/null)" == "tree RUSTUP_TOOLCHAIN=stable CARGO_TARGET_DIR=$PLUG_REAL/target PWD=$PLUG_REAL" ]]; then
    pass "in the tree, with the build's toolchain and target directory"
else
    bad "cargo tree ran with '$(sed -n 1p "$F/cargo.env" 2>/dev/null)'"
fi
if [[ "$(cat "$F/nm.argv" 2>/dev/null)" == "-D $PLUG_REAL/target/release/libdeep_filter_ladspa.so " ]]; then
    pass "nm reads the dynamic table (-D), which is what dlsym resolves against"
else
    bad "nm ran as '$(cat "$F/nm.argv" 2>/dev/null)'"
fi
if [[ "$(cat "$F/readelf.argv" 2>/dev/null)" == "-d $PLUG_REAL/target/release/libdeep_filter_ladspa.so " ]]; then
    pass "readelf reads the dynamic section of the built .so"
else
    bad "readelf ran as '$(cat "$F/readelf.argv" 2>/dev/null)'"
fi

baseline
rm -f "$SO"
steps check "$PLUG"
expect_fail "no built .so fails before anything is run" "build first"

echo "  -- the resolved feature tree"
check_tree eval 'printf "%s\n" "$TREE_DEFAULT" > "$F/tree.out"'
expect_fail "the default-features tree, with default-model-ll, fails" "low-latency model feature is in"
check_tree eval 'printf "%s\n" "$TREE_NONE" > "$F/tree.out"'
expect_fail "a tree with neither model feature fails" "full-model feature is not in"
check_tree eval 'printf "%s\n" "$TREE_LL_ONLY" > "$F/tree.out"'
expect_fail "default-model-ll alone is not read as default-model" "full-model feature is not in"
check_tree eval 'printf "%s\n" "$TREE_FULL_STAR" > "$F/tree.out"'
expect_ok "default-model printed only as a repeated node, with \"(*)\", is still found"
check_tree eval 'printf "%s\n" "$TREE_LL_STAR" > "$F/tree.out"'
expect_fail "default-model-ll printed only as a repeated node, with \"(*)\", is still found" "low-latency model feature is in"
check_tree eval 'printf "101" > "$F/status.tree"'
expect_fail "a cargo tree that fails fails check" "cargo tree failed"

echo "  -- the model inside the .so"
check_tree cp "$WORK/so.both" "$SO"
expect_fail "a .so that carries the low-latency tarball too fails" "carries the low-latency model"
check_tree cp "$WORK/so.ll" "$SO"
expect_fail "a .so that carries only the low-latency tarball fails" "does not carry the full model"
check_tree cp "$WORK/so.cut" "$SO"
expect_fail "a .so that carries all of the full tarball but its last byte fails" "does not carry the full model"
# Each tarball has to be something embeds() can find before either answer
# means anything. The absence half most of all: with the low-latency tarball
# gone from the tree -- renamed upstream at a bumped pin, say -- or not
# starting with the gzip anchor embeds() searches by, "the .so does not carry
# it" is true of every .so there is. And an empty full-model tarball is a
# zero-byte comparison, which every anchor in any .so matches.
UNFINDABLE="is missing, empty or not a gzip stream"
check_tree rm -f "$PLUG/models/DeepFilterNet3_onnx.tar.gz"
expect_fail "a tree with no full-model tarball fails, naming it" "DeepFilterNet3_onnx.tar.gz $UNFINDABLE"
check_tree eval ': > "$PLUG/models/DeepFilterNet3_onnx.tar.gz"'
expect_fail "an empty full-model tarball fails, rather than matching every anchor" "DeepFilterNet3_onnx.tar.gz $UNFINDABLE"
check_tree rm -f "$PLUG/models/DeepFilterNet3_ll_onnx.tar.gz"
expect_fail "a tree with no low-latency tarball to prove absent fails, rather than passing as an absence" "DeepFilterNet3_ll_onnx.tar.gz $UNFINDABLE"
check_tree eval 'printf "version https://git-lfs.github.com/spec/v1\n" > "$PLUG/models/DeepFilterNet3_ll_onnx.tar.gz"'
expect_fail "a low-latency tarball that is no gzip stream fails, rather than passing as an absence" "DeepFilterNet3_ll_onnx.tar.gz $UNFINDABLE"

echo "  -- the exported descriptor"
check_tree eval 'printf "%s\n" "$NM_NONE" > "$F/nm.out"'
expect_fail "no ladspa_descriptor fails; get_ladspa_descriptor is not it" "exports no ladspa_descriptor"
check_tree eval 'printf "%s\n" "$NM_UNDEF" > "$F/nm.out"'
expect_fail "an undefined (U) ladspa_descriptor is not an export" "exports no ladspa_descriptor"
check_tree eval 'printf "1" > "$F/status.nm"'
expect_fail "an nm that fails fails check" "nm could not read"
# The REGRESSION. `nm -D "$so" | grep -q ...` under pipefail failed a .so
# that exports the symbol: grep -q exits at the first match, nm takes a
# SIGPIPE writing the rest, and pipefail reports its 141. Hit running
# steps.sh check against the real build, whose nm list is 117 lines; this
# list is long enough that the race always goes the same way.
check_tree cp "$WORK/nm.big" "$F/nm.out"
expect_ok "the descriptor first in a megabyte of symbols still passes under pipefail"

echo "  -- what the .so links"
check_tree eval 'readelf_out libc.so.6 libgcc_s.so.1 > "$F/readelf.out"'
expect_ok "a NEEDED list that is a subset of glibc and gcc-libs passes"
check_tree eval 'readelf_out "${NEEDED_REAL[@]}" libstdc++.so.6 > "$F/readelf.out"'
expect_fail "libstdc++, which depends= does not install, fails and is named" "does not install: libstdc++.so.6"
check_tree eval 'readelf_out > "$F/readelf.out"'
expect_fail "an empty NEEDED list fails rather than passing as nothing outside" "read no NEEDED entry"

echo "  -- the fork's tests"
check_tree eval 'printf "101" > "$F/status.test"'
expect_fail "failing fork tests fail check" "the fork's tests failed"

echo "  -- the engine"
check_tree eval 'printf "\nif then\n" >> "$REPO/src/jayos-denoise"'
expect_fail "an engine that does not parse fails" "src/jayos-denoise does not parse"
check_tree eval 'printf "\nif then\n" >> "$REPO/src/easyeffects-lib.sh"'
expect_fail "a library that does not parse fails" "src/easyeffects-lib.sh does not parse"
check_tree eval 'printf "#!/usr/bin/env bash\nexit 0\n" > "$REPO/src/jayos-denoise"'
expect_fail "an engine that names no strengths fails" "names no strengths"
check_tree sed -i 's/"bypass": \$2,/"bypass": $2/' "$REPO/src/jayos-denoise"
expect_fail "a preset that is not JSON fails" "is not JSON with the filter on"
check_tree sed -i 's/"bypass": \$2,/"bypass": false,/' "$REPO/src/jayos-denoise"
expect_fail "a preset whose off does not bypass fails" "off, is not JSON with the filter bypassed"

echo
echo "package: the installed layout"

baseline
for f in LICENSE LICENSE-MIT LICENSE-APACHE; do
    printf 'stand-in: the fork'"'"'s %s\n' "$f" > "$PLUG/$f"
done
umask 022 # makepkg's
PKG="$WORK/pkg"
steps package "$PLUG" "$PKG"
expect_ok "package runs"

# THE EXACT LIST, type and mode, nothing more and nothing less: a file
# installed somewhere new is as much a change to the package as one dropped.
# The contract's files are whatever contract/ holds, because
# tools/contract.sh is what decides that.
want=$( {
    printf '%s\n' \
        "f 755 usr/lib/jayos-denoise/jayos-denoise" \
        "f 644 usr/lib/jayos-denoise/easyeffects-lib.sh" \
        "l 777 usr/bin/jayos-denoise" \
        "f 755 usr/lib/ladspa/libdeep_filter_ladspa.so" \
        "f 644 usr/share/licenses/jayos-denoise/LICENSE" \
        "f 644 usr/share/licenses/jayos-denoise/THIRD_PARTY.md" \
        "f 644 usr/share/licenses/jayos-denoise/DeepFilterNetPlus/LICENSE" \
        "f 644 usr/share/licenses/jayos-denoise/DeepFilterNetPlus/LICENSE-MIT" \
        "f 644 usr/share/licenses/jayos-denoise/DeepFilterNetPlus/LICENSE-APACHE" \
        "f 644 usr/share/doc/jayos-denoise/README.md" \
        "f 644 usr/share/doc/jayos-denoise/DEEPFILTERNET.md"
    for f in "$ROOT"/contract/*; do printf 'f 644 usr/share/jayos-denoise/contract/%s\n' "${f##*/}"; done
  } | sort )
got=$(cd "$PKG" 2>/dev/null && find . ! -type d -printf '%y %m %P\n' | sort)
if [[ "$got" == "$want" ]]; then
    pass "the package is exactly the documented layout: $(grep -c . <<<"$want") paths, types and modes"
else
    bad "the package differs from the documented layout:"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed -n 's/^[<>]/    &/p'
fi
empty=$(find "$PKG" -mindepth 1 -type d -empty 2>/dev/null)
if [[ -z "$empty" ]]; then
    pass "and no directory is left empty"
else
    bad "empty directories in the package: $(oneline "${empty//$PKG\//}")"
fi

target=$(readlink "$PKG/usr/bin/jayos-denoise")
if [[ "$target" == "../lib/jayos-denoise/jayos-denoise" ]]; then
    pass "/usr/bin/jayos-denoise is a relative link to ../lib/jayos-denoise/jayos-denoise"
else
    bad "/usr/bin/jayos-denoise points at '$target'"
fi

# THROUGH THE LINK, which is how JayOS and a person run it. The engine finds
# its library with realpath, so started as /usr/bin/jayos-denoise it still
# sources /usr/lib/jayos-denoise/easyeffects-lib.sh. The engine refuses with
# exit 1 when that source fails, and `strengths` needs nothing from the
# library -- so stderr has to be empty as well, and `status`, which is all
# library calls, has to print the contract's keys.
#
# With no EasyEffects on the PATH, so status takes the same branch on every
# machine. NOT by dropping each directory that holds easyeffects: on Arch
# that is /usr/bin, which holds bash and jq too, and the engine's #! line then
# found no bash (RUN, with a fake easyeffects overlaid onto /usr/bin in a
# private mount namespace: "env: 'bash': No such file or directory"). Each
# such directory is replaced by a directory of links to everything in it but
# easyeffects -- tools/contract.sh's path_without_easyeffects, for the same
# reason.
no_ee_path=""
n_farm=0
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    if [[ -x "$d/easyeffects" ]]; then
        n_farm=$((n_farm + 1))
        farm="$WORK/path-without-easyeffects/$n_farm"
        mkdir -p "$farm" && ln -s "$d"/* "$farm/" && rm -f "$farm/easyeffects"
        d=$farm
    fi
    no_ee_path+="$d:"
done
mkdir -p "$WORK/home"
via_link() { # via_link <verb>: the installed engine, by its /usr/bin name, as nobody in particular
    env -i PATH="${no_ee_path%:}" HOME="$WORK/home" "$PKG/usr/bin/jayos-denoise" "$@" 2>"$WORK/link.err"
}
strengths=$(via_link strengths)
rc=$?
if (( rc == 0 )) && [[ "$strengths" == "$(grep -v '^#' "$ROOT/contract/strengths.txt")" && ! -s "$WORK/link.err" ]]; then
    pass "run through the link, the installed engine prints the contract's strengths, and nothing on stderr"
else
    bad "through the link, strengths exited $rc, printed '$(oneline "$strengths")', stderr: $(oneline "$(cat "$WORK/link.err")")"
fi
keys=$(via_link status | jq -r 'keys_unsorted[]' 2>/dev/null)
if [[ -n "$keys" && "$keys" == "$(grep -v '^#' "$ROOT/contract/status-keys.txt")" && ! -s "$WORK/link.err" ]]; then
    pass "and status, which is all library calls, answers with the contract's keys"
else
    bad "through the link, status gave keys '$(oneline "$keys")', stderr: $(oneline "$(cat "$WORK/link.err")")"
fi

# Byte for byte: each installed file is the file it was installed from.
same() { # same <installed, under PKG> <source> <label>
    if cmp -s "$PKG/$1" "$2"; then pass "$3"; else bad "$3: /$1 is not $2"; fi
}
same usr/lib/ladspa/libdeep_filter_ladspa.so "$SO" "the plugin is the built .so"
same usr/lib/jayos-denoise/jayos-denoise "$REPO/src/jayos-denoise" "the engine is src/jayos-denoise"
same usr/lib/jayos-denoise/easyeffects-lib.sh "$REPO/src/easyeffects-lib.sh" "its library is src/easyeffects-lib.sh"
same usr/share/licenses/jayos-denoise/LICENSE "$REPO/LICENSE" "this repository's LICENSE"
same usr/share/licenses/jayos-denoise/THIRD_PARTY.md "$REPO/THIRD_PARTY.md" "THIRD_PARTY.md"
for f in LICENSE LICENSE-MIT LICENSE-APACHE; do
    same "usr/share/licenses/jayos-denoise/DeepFilterNetPlus/$f" "$PLUG/$f" "the fork's $f"
done
same usr/share/doc/jayos-denoise/README.md "$REPO/README.md" "README.md"
same usr/share/doc/jayos-denoise/DEEPFILTERNET.md "$REPO/docs/DEEPFILTERNET.md" "docs/DEEPFILTERNET.md"
differs=""
for f in "$REPO"/contract/*; do
    cmp -s "$f" "$PKG/usr/share/jayos-denoise/contract/${f##*/}" || differs+=" ${f##*/}"
done
if [[ -z "$differs" ]]; then
    pass "every contract file is installed byte for byte"
else
    bad "contract files missing or different:$differs"
fi

# What package refuses: each source it needs, missing in turn. A refusal is
# exit 1 with steps.sh's sentence; the partly filled pkgdir is makepkg's to
# throw away.
package_without() { # package_without <label> <fragment> <path to hide>
    mv "$3" "$3.hidden"
    rm -rf "$WORK/pkg2"
    steps package "$PLUG" "$WORK/pkg2"
    mv "$3.hidden" "$3"
    expect_fail "$1" "$2"
}
package_without "no docs/DEEPFILTERNET.md fails, saying so" "could not install the documentation" "$REPO/docs/DEEPFILTERNET.md"
package_without "no README.md fails, saying so" "could not install the documentation" "$REPO/README.md"
package_without "no THIRD_PARTY.md fails, saying so" "could not install the licence" "$REPO/THIRD_PARTY.md"
package_without "no LICENSE-APACHE in the fork fails, saying so" "could not install the plugin's licences" "$PLUG/LICENSE-APACHE"
package_without "no built .so fails, saying so" "build first" "$SO"
steps package "$PLUG"
expect_fail "no pkgdir is a usage error" "usage:"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
