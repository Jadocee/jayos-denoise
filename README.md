# jayos-audio

The audio engine JayOS's shell drives: noise suppression on the microphone --
DeepFilterNet 3 with its full model, as a LADSPA plugin in a PipeWire
filter-chain that a process of its own hosts -- real time for PipeWire's
clients from rtkit, the floor under a call's recording cycle, and the two
programs JayOS's audio controls read: `jayos-audio-state`, which lists the
devices and streams and names the node a control acts on, and
`jayos-equalizer-preset`, which builds its equaliser's EasyEffects preset.
Built for [JayOS](https://github.com/Jadocee/jayos); usable without it.

Until 2.0.0 this was jayos-denoise, which filtered the microphone as an
EasyEffects input preset. With EasyEffects' Effects switch on, the microphone
ran in the one thread that also runs every output effect, and lagged and cut
out in calls; `docs/AUDIO.md`, *Why the microphone left EasyEffects*, has the
diagnosis and the two projects it drew on. The package replaces and provides
jayos-denoise, and a `jayos-denoise` command takes 1.x's verbs.

The plugin is the DeepFilterNet Plus fork at a pinned commit with two
patches of this package's. One stops it cutting the microphone out: as the
fork ships it, a frame of inference that runs late is a quantum of silence,
and it ran with 0.7 ms to be late by. The other ends each instance's worker
thread with the instance, which the fork leaves polling, with its model in
memory, for the rest of the host's life.

Nothing here has run on an Arch machine, in a call, or with a person
listening. 2.0.0's host ran on 2026-11-11 under PipeWire 1.0.5 and
WirePlumber 0.4.17 in a container with no sound card
(`tests/shell/test-host.sh`): linked to the microphone it was told, made the
default input, moved and restrengthened live, white noise 41.8 dB quieter
through it, and the microphone the default again when it stopped; over a
speech recording at 0 dB SNR, 22.7 dB less noise in the pauses and SI-SDR
from 0.3 dB to 6.1. The recipe ran under makepkg the same day -- pacman
6.0.2's, Ubuntu's build, with Arch's flags in its `makepkg.conf` -- at
`1e8e740`, `check()` and its proofs included, in 528 seconds, and pacman
installed the package into a scratch root: 31 files, which `pacman -Qkk`
found whole, the plugin carrying the headroom mark and not the low-latency
model, and the host suite passing over the installed plugin. WirePlumber 0.5,
which Arch ships, rtkit, and Arch's own makepkg and pacman have not run;
`docs/AUDIO.md` draws the line. What ran before 2.0.0, with EasyEffects or a
host paced like PipeWire as the plugin's host:

The plugin was built at the pinned commit in a sandbox with no sound server
on 2026-10-03, and `packaging/steps.sh check` passed over it: the full model inside the `.so`
and the low-latency one not, and the fork's three tests passing. On
2026-10-17 it was built again, with and without the patch, and both were
driven by a LADSPA host paced the way PipeWire paces a filter
(`docs/DEEPFILTERNET.md`, *Dropouts*). On 2026-11-04 both recipes ran under
makepkg -- pacman 6.0.2's, Ubuntu's build, with Arch's flags in its
`makepkg.conf`, so not Arch's makepkg 7 -- and pacman 6.0.2 installed each
package into a scratch root: 24 files, which `pacman -Qkk` found whole, and
the two plugins byte for byte the same, the full model inside, the
low-latency one not, and the patch's log line in it. The installed plugin
then ran in such a host for a minute at each of two quanta, at the balanced
preset, over the fork's `assets/clean_freesound_33711.wav` mixed at 0 dB SNR
with its `assets/noise_freesound_2530.wav`: about 26 dB less noise in the
speech's pauses, the speech 1.2 dB quieter, and SI-SDR from 0.0 dB to 9.0.
At a quantum of 1024 it primed 50.7 ms and never underran, where 1.0.0's
plugin, built from `main` that day without the patch, lost a quantum to
silence 23 seconds in and moved its delay from 31 ms to 53. At 256 it had
one overload episode, 1.4 seconds after it started, and none after it.
On 2026-11-07 the second patch went on top of the first, and `steps.sh
checkout` applied both to a fresh clone of the pin and `steps.sh check`
passed over the tree built from them, the fork's three tests, the first
patch's two and the second's one among it. The second's test fails without
it. A host that made and destroyed five instances without running them was
left with five threads polling and 130 MB resident by the plugin as 1.0.1
built it, and with none and 27 MB by this one (`docs/DEEPFILTERNET.md`, *The
worker thread, ended with its instance*). Arch's makepkg and pacman, and a
real EasyEffects, have not run. `docs/DEEPFILTERNET.md` says which of its
numbers were measured and which were read.

## What is here

| | |
|---|---|
| `src/jayos-audio` | The engine. `denoise on`, `off`, `strength`, `input` and `status` drive the noise-suppression host; `denoise host` is the host, which writes its filter-chain configuration and execs `pipewire -c` on it; `floor` puts the recording floor into effect; `realtime` says how PipeWire's processes are scheduled. Knows nothing about whether noise suppression should be on: whatever draws the switch says. Its header says why each part is the way it is. |
| `src/jayos-denoise` | 1.x's verbs -- `status`, `strengths`, `preset`, `set on\|off`, `apply` -- handed to the engine, for what still calls them. |
| `src/easyeffects-lib.sh` | Where EasyEffects 8.x keeps its presets and settings, and how to speak to its socket: used only to bypass the input preset 1.x left. A copy of JayOS's; its header names the commit to diff against and the two edits. |
| `rust/` | The two programs' Cargo workspace. `crates/jayos-audio-tools` is `jayos-audio-state` and `jayos-equalizer-preset`, moved from JayOS unchanged at jayos commit 45256e08 (its README); `crates/jayos-core` is a vendored copy of the five modules of JayOS's shared library they use, whose `PROVENANCE.md` has each file's sum and why a copy. |
| `systemd/jayos-audio-denoise.service` | The host's user unit. `denoise on` enables and starts it, `off` stops and disables it. |
| `share/` | The drop-ins the package installs under `/usr/share`: module-rt's portal path off for every native and JACK client, the floor under a PulseAudio client's recording cycle, and the soft mixer for ALSA cards. Each says why in its header. |
| `packaging/steps.sh` | The steps both recipes call: check the pinned commit out and patch it, fetch locked, build with the full model and build `rust/`'s two programs, prove what was built, run the fork's tests and the programs', install. Every build flag and the file list are here, once. |
| `packaging/patches/` | This package's changes to the plugin, applied in name order onto the pin: two today. 0001 holds a headroom of delay above what the host's quantum needs, set up before the first sample, so a late frame of inference is absorbed instead of heard; 0002 stops and joins an instance's worker thread when the host destroys the instance. Each patch's header says why; `steps.sh check` proves the tree it built from carries them. |
| `packaging/arch/PKGBUILD` | Builds and installs this checkout. Its `_commit=` line is the plugin's pin, for both recipes. |
| `contract/` | What JayOS tests its side against: both commands' forms, the status keys, the strengths, the host configuration for each, the names a desktop writes into its own code, `steps.sh`'s verbs, and the keys `jayos-audio-state` prints. Generated; see `contract/README.md`. |
| `docs/AUDIO.md` | The microphone's path in 2.0.0: why it left EasyEffects, the host, real time, the floor, and what has run. |
| `docs/DEEPFILTERNET.md` | Why this fork, why it is patched, why `--no-default-features`, what each strength sets, what a build costs. Mostly moved, verbatim, from JayOS; history where it describes 1.x's EasyEffects preset. |
| `tests/shell/` | The engine against stand-ins for systemd's user manager and PipeWire's tools (`test-engine.sh`); the host under a real PipeWire and WirePlumber (`test-host.sh`); the floor against stand-ins and under a real pipewire-pulse (`test-floor.sh`); the recipe and the steps against fakes (`test-packaging.sh`, `test-steps.sh`); `tools/contract.sh` and `tools/check.sh` against scratch copies of this tree (`test-contract.sh`); the built `jayos-audio-state` against fake `pactl`, `wpctl` and `pw-dump` (`test-audio-state.sh`, moved from JayOS with it); the vendored `jayos-core` against its table of sums (`test-vendored.sh`); and properties of the code that no behavioural test can hold (`test-source-guards.sh`). |
| `tools/check.sh` | Everything above in one run: `rust/` built and tested where cargo is installed, and the rest with no Rust toolchain. |
| `tools/contract.sh` | Compares `contract/` with what the code produces; `--write` rewrites it. |
| `VERSION` | The package's version, which the checkout recipe's `pkgver` repeats. |

## Installing

On Arch, from a checkout:

    cd packaging/arch && makepkg -si

That clones the DeepFilterNet Plus fork at the pinned commit, fetches its
crates, builds the plugin, checks it and installs:

    /usr/bin/jayos-audio, /usr/bin/jayos-denoise       links to the two commands
    /usr/bin/jayos-audio-state                         the devices, streams and master node, as JSON
    /usr/bin/jayos-equalizer-preset                    the equaliser's EasyEffects preset
    /usr/lib/jayos-audio/                              jayos-audio, jayos-denoise,
                                                       easyeffects-lib.sh, VERSION
    /usr/lib/ladspa/libdeep_filter_ladspa.so           the plugin, with the full model
    /usr/lib/systemd/user/jayos-audio-denoise.service  the host's unit
    /usr/share/pipewire/client.conf.d/60-jayos-audio-rt.conf
    /usr/share/pipewire/jack.conf.d/60-jayos-audio-rt.conf
    /usr/share/pipewire/pipewire-pulse.conf.d/60-jayos-capture-latency.conf
    /usr/share/wireplumber/wireplumber.conf.d/50-alsa-soft-mixer.conf
    /usr/share/jayos-audio/contract/                   contract/
    /usr/share/licenses/jayos-audio/                   LICENSE, THIRD_PARTY.md, and
                                                       DeepFilterNetPlus/ with the fork's three
    /usr/share/doc/jayos-audio/                        README.md, AUDIO.md and DEEPFILTERNET.md

The build needs `cargo` (from `rust` or `rustup`) and `git`, and the network
for the clone and the fetch and nothing after them. Measured once, in that
sandbox: five minutes to build, two more to check, and a 1.1 GB build tree.
At run time it needs PipeWire, WirePlumber, rtkit, systemd's user manager and
jq; EasyEffects and pipewire-pulse are optional, and `pactl` is what `floor`
asks whether anything is streaming and where `jayos-audio-state` reads its
lists -- without it, they come back empty.

JayOS carries a recipe of its own, `pkgbuilds/jayos-audio/PKGBUILD` there,
that fetches this repository's `main` branch and calls the same
`packaging/steps.sh`.

The package replaces jayos-denoise, so pacman offers it in 1.x's place at
the next upgrade, and provides and conflicts on `libdeep_filter_ladspa`, the
name the AUR's three packagings of the plugin provide --
`deepfilternet-plus-bin`, `deepfilternet-plus-git` and
`deepfilternet-plugin-pipewire-bin` -- and so did `deepfilternet-ladspa`, the
recipe JayOS carried before jayos-denoise. So it cannot be installed beside
any of them, and pacman asks before it removes the one that is. They would
all put the same file in `/usr/lib/ladspa`.

Without JayOS:

    jayos-audio denoise on balanced     # filter the default microphone; its output is the default input
    jayos-audio denoise input alsa_input.usb-...  # record another microphone
    jayos-audio denoise strength maximum          # live, while it runs
    jayos-audio denoise off             # the microphone is the default input again
    jayos-audio denoise status | jq .
    jayos-audio floor apply             # put the recording floor into effect
    jayos-audio realtime                # which audio threads run real time

A strength left out is the one last set, or balanced. The unit stays enabled
while it is on, so the host comes back at every login.

## Checking

    tools/check.sh

Parses every script, compares `contract/` with what the code produces, and
runs every suite in `tests/shell/`. Exit 0 is: everything that ran passed.
A case a suite could not run on this machine -- the boxes under a real
PipeWire where PipeWire, WirePlumber or pipewire-pulse is not installed, or
the host's where no plugin is built (`JAYOS_AUDIO_TEST_PLUGIN` names a
build's) -- leaves it at 0, but is named in the summary under its suite, and
the last line counts it rather than ending on the bare `ok, nothing to fix`
a run that asked everything prints. 1 is a failure. 2 is "could not run" (no
jq, git, gzip, tar, od or cmp) -- which is not the same answer as clean and
is not reported as one. It does not build the plugin: the plugin's proofs
are `packaging/steps.sh check`, which makepkg runs as the recipe's
`check()`. It does build `rust/`, where cargo is installed -- the two
programs, their unit tests and rustfmt's check, then `test-audio-state.sh`
over that build -- and says "not exercised" for that step where it is not.

## Licence

MIT; see `LICENSE`. The plugin is built from `ismailivanov/DeepFilterNetPlus`,
which is MIT OR Apache-2.0 at your option, and its three licence files are
installed beside this one. `THIRD_PARTY.md` lists what comes from elsewhere,
what is only cited, and what the package does not yet install.
