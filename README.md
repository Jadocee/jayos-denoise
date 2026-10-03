# jayos-denoise

Noise suppression for a microphone on Linux: DeepFilterNet 3, built with its
full model as the LADSPA plugin EasyEffects loads, and `jayos-denoise`, the
command that writes EasyEffects' input preset for it and switches it on and
off. Built for [JayOS](https://github.com/Jadocee/jayos); usable without it.

Nothing here has run on an Arch machine, and nothing has been listened to.
The engine is tested against a fake EasyEffects 8.2.9 that plays the daemon's
end of its socket (`tests/shell/test-engine.sh`). The plugin was built at the
pinned commit in a sandbox with no sound server on 2026-10-03, and
`packaging/steps.sh check` passed over it: the full model inside the `.so`
and the low-latency one not, and the fork's three tests passing. makepkg,
pacman and a real EasyEffects have not run. `docs/DEEPFILTERNET.md` says
which of its numbers were measured and which were read.

## What is here

| | |
|---|---|
| `src/jayos-denoise` | The engine. Writes one input preset, `denoise`, from a strength name, and asks the running EasyEffects to load it and believes the load only when EasyEffects answers that it holds it. Off is the same preset with the filter bypassed. Knows nothing about whether noise suppression should be on: whatever draws the switch says. |
| `src/easyeffects-lib.sh` | Where EasyEffects 8.x keeps its presets and settings, and how to speak to its socket. A copy of JayOS's; its header names the commit to diff against and the two edits. |
| `packaging/steps.sh` | The steps both recipes call: check the pinned commit out, fetch locked, build with the full model, prove what was built, run the fork's tests, install. Every build flag and the file list are here, once. |
| `packaging/arch/PKGBUILD` | Builds and installs this checkout. Its `_commit=` line is the plugin's pin, for both recipes. |
| `contract/` | What JayOS tests its side against: the engine's commands, its status keys, the strengths, every preset it writes, the names a desktop writes into its own code, and `steps.sh`'s verbs. Generated; see `contract/README.md`. |
| `docs/DEEPFILTERNET.md` | Why this fork, why `--no-default-features`, what each strength sets, what a build costs, and what to check on a machine. Mostly moved, verbatim, from JayOS. |
| `tests/shell/` | The engine against a fake EasyEffects (`test-engine.sh`); the recipe and the steps against fakes (`test-packaging.sh`, `test-steps.sh`); `tools/contract.sh` and `tools/check.sh` against scratch copies of this tree (`test-contract.sh`); and properties of the code that no behavioural test can hold (`test-source-guards.sh`). |
| `tools/check.sh` | Everything above that needs no Rust toolchain, in one run. |
| `tools/contract.sh` | Compares `contract/` with what the code produces; `--write` rewrites it. |
| `VERSION` | The package's version, which the checkout recipe's `pkgver` repeats. |

## Installing

On Arch, from a checkout:

    cd packaging/arch && makepkg -si

That clones the DeepFilterNet Plus fork at the pinned commit, fetches its
crates, builds the plugin, checks it and installs:

    /usr/bin/jayos-denoise                       a link to the engine
    /usr/lib/jayos-denoise/jayos-denoise         the engine
    /usr/lib/jayos-denoise/easyeffects-lib.sh    its library
    /usr/lib/ladspa/libdeep_filter_ladspa.so     the plugin, with the full model
    /usr/share/jayos-denoise/contract/           contract/
    /usr/share/licenses/jayos-denoise/           LICENSE, THIRD_PARTY.md, and
                                                 DeepFilterNetPlus/ with the fork's three
    /usr/share/doc/jayos-denoise/                README.md and DEEPFILTERNET.md

The build needs `cargo` (from `rust` or `rustup`) and `git`, and the network
for the clone and the fetch and nothing after them. Measured once, in that
sandbox: five minutes to build, two more to check, and a 1.1 GB build tree.

JayOS carries a recipe of its own, `pkgbuilds/jayos-denoise/PKGBUILD` there,
that fetches this repository's `main` branch and calls the same
`packaging/steps.sh`, and its volume popup offers to build it when it is not
installed.

The package provides and conflicts on `libdeep_filter_ladspa`, the name the
AUR's three packagings of the plugin provide -- `deepfilternet-plus-bin`,
`deepfilternet-plus-git` and `deepfilternet-plugin-pipewire-bin` -- and so did
`deepfilternet-ladspa`, the recipe JayOS carried before this package. So it
cannot be installed beside any of them, and pacman asks before it removes the
one that is. They would all put the same file in `/usr/lib/ladspa`.

Without JayOS:

    jayos-denoise set on balanced    # write the preset, start EasyEffects if needed, load it
    jayos-denoise set off            # the same preset, the filter bypassed
    jayos-denoise status | jq .      # what is installed, running and loaded
    jayos-denoise strengths          # gentle, balanced, maximum

A strength left out is balanced. `set on` replaces whatever input preset is
loaded, and says what it replaced. And after whatever starts EasyEffects at
login, run `jayos-denoise apply on balanced`, or `apply off`: `apply` never
starts EasyEffects, waits up to twenty seconds for the instance something
else starts, and leaves an input preset loaded by hand alone unless given
`--force`. It is not optional for off. EasyEffects restores its pipeline from
its own database at start, so an off chosen while it was not running is
undone at the next start unless `apply off` follows it.

## Checking

    tools/check.sh

Parses every script, compares `contract/` with what the code produces, and
runs every suite in `tests/shell/`. Exit 0 is clean, 1 is a failure, 2 is
"could not run" (no jq, python3, socat, git or gzip, or no Unix socket to
bind) -- which is not the same answer as clean and is not reported as one.
It builds nothing: the plugin's proofs are `packaging/steps.sh check`, which
makepkg runs as the recipe's `check()`.

## Licence

MIT; see `LICENSE`. The plugin is built from `ismailivanov/DeepFilterNetPlus`,
which is MIT OR Apache-2.0 at your option, and its three licence files are
installed beside this one. `THIRD_PARTY.md` lists what comes from elsewhere,
what is only cited, and what the package does not yet install.
