# jayos-core, vendored

Every file in this crate but `src/lib.rs` and this one is a copy, byte for
byte, of JayOS's `rust/crates/jayos-core`: the shared library its helper
programs are built on. `jayos-audio-state` and `jayos-equalizer-preset` came
here from JayOS (`../jayos-audio-tools/README.md`), and these are the five of
its twelve modules they use -- `cli`, `emit`, `paths`, `proc` and `pw_route`,
of which only `cli` uses another (`emit`) and `pw_route` another (`paths`).

`src/lib.rs` is not JayOS's: it declares those five and nothing else, and
leaves out `now_unix`, which neither program calls. Its header says so.

| | |
|---|---|
| Repository | `https://github.com/Jadocee/jayos` |
| Commit | `45256e088ee133c177cc805248e43188edd87cfd` (2026-11-11) |
| Branch it was taken from | `ccr-3147b012-y550t7` |
| Path there | `rust/crates/jayos-core/` |

| File | sha256 |
|---|---|
| `Cargo.toml` | `670d93e5d5130428d7c0f76ffd18acaeceda1d3119c99b8d3e6dc3a97e2f4f26` |
| `src/cli.rs` | `84b12553ff30105bb301d1862bc8cb9901d121dfa7df2c4e278783621b8373d4` |
| `src/emit.rs` | `e8b751ce39bb5f7af9119f8c9cef849764a3fb45f5c2a6c6268bdadf8ddcde76` |
| `src/paths.rs` | `505ce599d886933a96dbd03f971cd4a26d157dd99443e16d257c6307e3ab17d6` |
| `src/proc.rs` | `7b2c10a951111cfdd05683c072f00c05ce0a0b7c31a3b77e7bbc7233bd4601cc` |
| `src/pw_route.rs` | `b78287c5f809c5bd69d4b51b90f49c45aa6263bad78e8ce810d2445dc89ad294` |

`Cargo.toml` takes its version, edition, rust-version and licence from the
workspace, so the same bytes say 2.0.0 here, the package's version, and 1.0.0
in JayOS.

## Why a copy, and not a dependency on JayOS

The package is built by makepkg from this repository alone, and its
`build` step runs `cargo build --frozen`: nothing past crates.io, fetched in
`fetch`, and no JayOS checkout. A `git` dependency on JayOS would fetch the
whole desktop to build two programs, tie each package build to whatever JayOS's
branch held that day, and make this package need the desktop it was moved out
of -- the coupling the move exists to remove.

And JayOS keeps its own: `jayos-privacy`, the microphone and camera indicator,
stays there and uses every function of `pw_route` -- `parse_dump`, `inert`,
`device_behind`, `easyeffects_rc` and `easyeffects_device` -- so the module
cannot move whole, and splitting it would leave two halves to keep in step
instead of one copy.

So there are two copies, and a fix to one is a fix to one.
`tests/shell/test-vendored.sh` compares every file here with its sum in the
table above, and fails on a file that differs, a listed file that is gone, and
a source file the table does not list -- so the table is a check of the copy,
not only a record of it.

## Refreshing it

Copy the files above from a later commit of JayOS's `rust/crates/jayos-core/`,
add any module the programs come to use (and declare it in `src/lib.rs`), then
replace both tables -- the sums with `sha256sum` over the new files -- and run
`tests/shell/test-vendored.sh` and `cd rust && cargo test --workspace`.
