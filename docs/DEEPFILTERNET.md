# DeepFilterNet 3: the plugin this package builds

Why the plugin comes from the DeepFilterNet Plus fork at a pinned commit, why
this package patches it, why it is built with `--no-default-features`, what
each strength sets, what a build costs, and what to check on a machine once it
is installed. The code is the detail, and where the code and this document
disagree, the code is current: `packaging/steps.sh` holds every build flag,
every proof and the file list; the `_commit=` line of `packaging/arch/PKGBUILD`
is the pin, and `bash packaging/steps.sh pin` prints it;
`packaging/patches/` holds what this package changes in the fork, each patch
with its reason in its header; `strength_params()` in `src/jayos-denoise`
holds the numbers behind each strength, and `tests/shell/test-engine.sh`
fails unless the table under *Strength* states them.

This preface is current on 2026-10-04, and *Dropouts, and the headroom that
stops them*, after it, on 2026-10-17. Everything after those two MOVED HERE from
jayos when the engine and the plugin did, verbatim, from `docs/AUDIO.md` at
jayos commit `bf53d6a`: that file's lines 347-864, less what is marked
`[...]` -- lines 596-641, 663-742, 782, 800-804, and 836 through the first
sentence of 855. Those were about jayos's own ways in: its bootstrap stage,
its build script and popup button, its settings rows, its `hypr/denoise.sh`,
its doctor and its WirePlumber rule, which are jayos's to describe. The rest is history, kept as
written; a note in italic brackets, *[like this]*, marks a statement that no
longer describes this repository and says what does. **Paths in it are
jayos's at that commit.** Where the things it names are now:

| jayos at `bf53d6a` | Here |
|---|---|
| `pkgbuilds/deepfilternet-ladspa/PKGBUILD`, the recipe, with its `_commit` and its `pkgver` | `packaging/arch/PKGBUILD` names the sources and holds the pin, `_commit=`, on one line; its `pkgver` is `VERSION`'s, written out. jayos builds this package with a recipe of its own, `pkgbuilds/jayos-denoise/PKGBUILD` there, from this repository's `main` branch. Both call `packaging/steps.sh` for every step. |
| That recipe's `prepare()`, `build()`, `check()` and `package()` | `packaging/steps.sh checkout` and `fetch`; `build`; `check`; `package` |
| `config/common/scripts/hypr/denoise.sh`: `strength_params()`, `load_preset`, `set`, `apply` | `src/jayos-denoise`, installed as `/usr/bin/jayos-denoise`, with no settings: `set` and `apply` are told the state and the strength. Not otherwise the same code: it has a `strengths` verb and no `build`, its own remedies, a refusal of a library that will not load, and `apply`'s two failures on stdout. The *MOVED HERE* paragraph at the head of that file lists every difference. jayos kept a `hypr/denoise.sh` at the same path, which reads its settings and calls this. |
| `config/common/scripts/easyeffects-lib.sh` | `src/easyeffects-lib.sh`, a copy; its header names the two edits |
| `tools/test-easyeffects.sh`: the cases that drove `denoise.sh`, and the comparison of the *Strength* table at its lines 3316-3343 | `tests/shell/test-engine.sh` |
| `tools/test-installers.sh`'s block on the recipe | `tests/shell/test-packaging.sh` (the recipe), `tests/shell/test-steps.sh` (the steps, against fakes) and `tests/shell/test-source-guards.sh` (the cargo flags) |
| `tools/test-installers.sh:1232-1234`, `DFN_COMMIT`: the recipe's `_commit` and this document's commit line had to name one commit | `tests/shell/test-packaging.sh` holds `_commit=` to one line of forty hex digits, and holds `source=()` and `steps.sh pin` to it. Nothing holds this document to the pin: the commit named under *Which source, and why* is the pin at `bf53d6a`, history like the rest. |
| `/usr/lib/ladspa/libdeep_filter_ladspa.so`, the package's one file | The same path, one of this package's files; `README.md` lists the rest |

Nothing in this document has run on an Arch machine, and nothing in it has
been listened to: not makepkg, not pacman, not EasyEffects loading the
plugin, not a recording at any strength. What has run is the build. On
2026-10-03, in a sandbox with no sound server, against the pinned commit,
`packaging/steps.sh` checked the commit out, fetched, built -- 5 min 01 s --
and ran `check` in 118 s, nearly all of it compiling the fork's test harness:
the inverted feature tree, the full model found byte for byte inside the
`.so` and the low-latency one not, `ladspa_descriptor` exported, every NEEDED
library one that glibc or gcc-libs installs, and the fork's three tests in
`ladspa/tests/no_rt_blocking.rs`, which passed. That is run evidence about
the file and nothing more: it says which model is inside, not what the model
does to a voice. The same `.so`, read again for this preface: the string
`DeepFilterNet3_onnx` twice and `DeepFilterNet3_ll_onnx` never, as in jayos's
build below; NEEDED `libgcc_s.so.1`, `libm.so.6`, `libc.so.6` and
`ld-linux-x86-64.so.2`; `Cargo.lock` naming 595 packages; a 1.1 GB
`target/` after the build and the check. The times in the cost table below,
4 min 22 s and about 1 min 40 s, are jayos's build of the same commit, and
its other figures -- 452 crates fetched, about 145 compiled, 176 MB and
522 MB -- were not measured again.

## Dropouts, and the headroom that stops them

With noise suppression on, turning EasyEffects' effects on -- jayos's volume
popup has a switch for it -- made the microphone choppy, cutting in and out
with a delay that wandered, and bypassing them made it clean again. The
bypass is EasyEffects' global one, and it takes every plugin out of the input
chain: with it on, the microphone is linked straight to the spectrum, the
output level meter and EasyEffects' source, and DeepFilterNet is not in the
path at all
(`StreamInputEffects::connect_filters` in `src/stream_input_effects.cpp` at
v8.2.9, READ). So it was the plugin. It is, at the pin, as the fork ships it;
`packaging/patches/0001-ladspa-hold-headroom-above-the-host-quantum.patch`
is the fix, and the presets now ask for two frames of headroom.

### What the plugin did

EasyEffects calls the plugin's `run()` once per PipeWire cycle with the
cycle's quantum (`on_process` in `src/plugin_base.cpp` at v8.2.9, READ). The
fork's `run()` (`ladspa/src/lib.rs` at the pin, READ, and RUN below) never
waits for the thread the model runs in: it pushes the quantum into an input
queue and takes a quantum out of an output queue, and when the output queue
is short -- the thread has not finished the frames it needs -- it writes the
whole quantum as silence and grows its delay by that much. Ten seconds after
the delay last changed, if a frame of it went unused, it trims a frame back
off, which skips 10 ms of audio. Three things together made that a
microphone that cut out:

* **The delay was reached through silence, and only just.** It starts at one
  frame, 480 samples, grows only by underruns, and stops at the first value
  that serves the quantum that failed. What a quantum needs is the quantum
  plus the most the input queue can hold short of a frame while the quantum
  and the 480-sample hop go in and out of step, 480 less their greatest
  common divisor, so at PipeWire's default quantum the fork settled 32
  samples above the edge:

  | quantum | needs | the fork settles at | which leaves |
  |---:|---:|---:|---|
  | 128 | 576 | 960 | 384 samples, 8.0 ms |
  | 256 | 704 | 960 | 256 samples, 5.3 ms |
  | 480 | 480 | 480 | nothing |
  | 512 | 960 | 992 | 32 samples, 0.7 ms |
  | 1024 | 1472 | 1504 | 32 samples, 0.7 ms |
  | 2048 | 2496 | 2528 | 32 samples, 0.7 ms |

* **The thread is an ordinary one, and its frames vary.** A frame of the full
  model in the stereo instance EasyEffects opens took a median of 3.6 ms, 10.8
  at the 99.9th percentile and 25 at most (RUN, 6,000 frames at a quantum of
  480, below), and the thread competes with everything else on the machine.
  Every frame that ran later than the margin above was a quantum of silence,
  and every trim put the delay back where the next one landed.
* **`min-processing-buffer` was 0, and could not have done the job.** The
  presets set it to 0 for latency (*Strength* and *Latency*, below, as
  written). In the fork it is only a floor under the trim, counted in frames
  from nothing rather than from what the quantum needs, and it adds no sample
  before the first underrun: at a quantum of 1024, which needs more than
  three frames already, a floor of two changes nothing at all.

### What the patch does

`packaging/steps.sh checkout` applies it to the pinned commit, and `check`
proves the tree it built from is that commit with it and nothing else. It
changes `run()` in three ways, and adds two tests:

1. The delay is set up before the first output, not reached through
   underruns: what the quantum needs (`required_delay()`), plus
   `min-processing-buffer` frames of headroom for the thread to be late by.
   Again when a quantum needs more than is queued -- an underrun that is
   certain, not a late thread -- and when the headroom is raised.
2. The trim never takes the delay below that.
3. An overload episode -- underruns until one second has passed clean --
   raises that floor by a frame, up to eight, and each is given back after
   five minutes with no underrun. A stall the headroom did not cover is one
   the machine has; the fork trimmed the frame it cost straight back.

The tests hold `required_delay()` to a simulation of the two queues: for
fourteen quanta from 32 to 8192 and six starting remainders, the delay it
names serves every cycle and one sample less does not. Mutated twice -- the
remainder term dropped, then the greatest common divisor -- each failed.
The fork's three tests still pass over the patched source. With
`RUST_LOG=info`, the plugin says what it chose when it primes:
`Holding 50.7ms for a quantum of 1024, 20.0ms of it headroom`.

The presets set `min-processing-buffer` to 2 at every strength: 20 ms. The
three strengths cost the same per frame -- a median of 3.6 ms each over the
same 30 s (RUN) -- so there is no reason for them to differ.

### What it was measured with, and what that is worth

RUN on 2026-10-17, in a sandbox with no sound server: a four-vCPU virtual
machine, an Intel Xeon at 2.80 GHz. The fork was built at the pin twice, with
`packaging/steps.sh build`'s flags, without the patch and with it, and the
patched tree was then taken through `steps.sh checkout`, `build` and `check`
as makepkg would take it: the patch applied, and `check` passed in 1 min
54 s, its model proofs, the patch's proof and five tests among it. A host
written in C for the purpose `dlopen`ed each `.so`, instantiated
`deep_filter_stereo` at 48 kHz as EasyEffects does, set the six control
ports as the balanced preset sets them, and called `run()` once per quantum
from a `SCHED_FIFO` thread on an absolute clock, a quantum's worth of time
apart -- the shape of PipeWire's data thread, not PipeWire. Its input was the
fork's own `assets/noisy_snr0.wav`, speech at 0 dB SNR, looped, the same
samples in both channels, as EasyEffects feeds a mono microphone to the
stereo instance. A gap is a run of exact zeros in the output, at least 32
samples long, after the first second; an episode and a trim are the plugin's
own log lines. "Loaded" is two threads spinning at nice 0, half the vCPUs.
Two minutes per row:

| run | the fork as it ships, `min-processing-buffer` 0 | patched, 2 |
|---|---|---|
| idle, quantum 256 | 2 gaps, 20 ms of silence | 2 gaps, 20 ms |
| idle, quantum 480 | 1 gap, 10 ms; 1 trim | none |
| idle, quantum 1024 | 1 gap, 21 ms; 2 trims | none |
| loaded, quantum 256 | 4 gaps, 40 ms | 3 gaps, 30 ms |
| loaded, quantum 480 | 3 gaps, 30 ms; 1 trim | 1 gap, 40 ms |
| loaded, quantum 1024 | 4 gaps, 85 ms; 7 trims | none |
| **twelve minutes** | **15 gaps and 11 trims** | **6 gaps, no trim** |

And five minutes per row, one thread spinning:

| run | the fork as it ships, `min-processing-buffer` 0 | patched, 2 |
|---|---|---|
| quantum 1024 | 6 gaps, 128 ms of silence; 11 trims | 1 gap, 21 ms; 1 trim |
| quantum 256 | 14 gaps, 160 ms; 11 trims | 6 gaps, 60 ms; 2 trims |

At 256 the patched plugin's floor rose a frame with each of its four
episodes, from 34.7 ms to 74.7, as the third change above says it should.
The last episode was three underruns long and took the delay to 94.7 ms; the
two trims brought it back down to the floor and no further.

Every gap left in the patched column is a stall of more than the 20 ms of
headroom, and this machine has them: its four vCPUs lost 99.3 s between them
to the hypervisor in the 96 minutes after it booted, in bursts, and the
thread's slowest frame there was 25 ms of work that is 3.6 at the median.
One episode outran the headroom by four frames, 40 ms: no headroom a
microphone could afford covers a stall that long, and the next paragraph says
what this machine's stalls are worth as evidence about another's.
Raising the inference thread to nice -10 under the same load did not help
the fork either (3 gaps at 256; 2 gaps and 5 trims at 1024, RUN): this is a
margin problem, not a priority one.

What that is worth: the mechanism, both columns' differences, and the
arithmetic are run evidence. The rates are this virtual machine's. A desktop
with no hypervisor and a faster core -- the Ryzen 9 7950X jayos is built for --
runs a frame in less time and stalls less often, so the fork's gaps there are
rarer and the patched plugin's rarer still; how rare is not known. Not run:
EasyEffects, PipeWire, a microphone, and anybody listening.

### What it costs

The delay is the price, on top of the model's own and the quantum's
(*Latency*, below). Computed from `required_delay()` and the headroom, and
the 256 and 1024 rows RUN, as the plugin's own `Holding` lines:

| quantum | the fork, settled | patched |
|---:|---:|---:|
| 256 | 960 samples, 20.0 ms | 1664, 34.7 ms |
| 480 | 480, 10.0 ms | 1440, 30.0 ms |
| 1024 | 1504, 31.3 ms | 2432, 50.7 ms |
| 2048 | 2528, 52.7 ms | 3456, 72.0 ms |

The fork's figures are its best case: each underrun moved them up, by a
quantum at a time, until a trim brought them back.

## Noise suppression on the microphone

### What DeepFilterNet 3 is

A deep-learning speech enhancement model (Schröter et al.), run on the CPU
through the `tract` inference crate, packaged as a LADSPA plugin,
`libdeep_filter_ladspa.so`. EasyEffects lists it as **Deep Noise Remover**
and always opens the plugin's `deep_filter_stereo` instance. It works at
48 kHz on a 960-sample window (20 ms) with a 480-sample hop (10 ms), in two
stages: gains over 32 ERB bands for the whole spectrum, then a five-tap
"deep filter" over the lowest 96 frequency bins, where speech harmonics are.
The numbers are the model's own `config.ini` in the embedded tarball; the
`strength` knobs below decide, per frame, which stages run.

The plugin is in no Arch repository. It is built from
`pkgbuilds/deepfilternet-ladspa`, one of the two recipes in `pkgbuilds/` that
are this configuration's own (`jayos-sony-xm5` is the other) — not a vendored
CachyOS copy, not in `MANIFEST.sha256`, and this file is its provenance
(`pkgbuilds/PROVENANCE.md` says so).

### Which source, and why

**The DeepFilterNet Plus fork, `ismailivanov/DeepFilterNetPlus`, at its
v1.0.2 tag: commit `d97178d739dffc9f862315cad83f79d40580dc3d` (2026-08-15).**
The PKGBUILD pins the commit, not the tag — a tag can be moved and a commit
cannot — and `tools/test-installers.sh` holds a copy of the id,
`DFN_COMMIT`, and fails unless the recipe's `_commit` and this line both
name it and this document names no other. So a bump is three edits — the
PKGBUILD, this line and the suite's copy — or a failed suite.

*[Since the move, the pin is the `_commit=` line of `packaging/arch/PKGBUILD`,
and a bump is that one line: `packaging/steps.sh checkout` reads it for both
recipes, and `pkgver` comes from `VERSION`, not the fork's tag. No suite here
holds this paragraph, or any copy of the id, to the pin. On 2026-10-03 the
pin was still the commit above.]*

Not upstream: `Rikorose/DeepFilterNet` is dormant — v0.5.6 is from August
2023, the last commit from October 2024 — and its plugin's real-time callback
can block: the model runs in a worker thread, but the callback waits on a
bounded control channel, on queue mutexes, on allocation and on synchronous
logging, so a slow frame stalls the audio thread that called it (the fork's
`docs/LADSPA_OVERLOAD_REPORT.md`; upstream issue #661 is the crackling users
heard). The fork keeps upstream's models and feature
gating and fixes the real-time path: the callback never blocks, a sustained
overload degrades to passthrough rather than a stall (its
`docs/LADSPA_OVERLOAD_REPORT.md` records two desktop sessions lost to the old
behaviour), and stereo inference works, which matters because EasyEffects
opens the stereo instance.

*[What the callback does instead of blocking is write the quantum as
silence, and with the delay the fork settles at, that was every frame that
ran late: *Dropouts, and the headroom that stops them*, above, and
`packaging/patches/`, which this package applies to the pin.]*

Not the AUR: `deepfilternet-plus-bin`, `deepfilternet-plus-git` and
`deepfilternet-plugin-pipewire-bin` all `provides`/`conflicts` on
`libdeep_filter_ladspa`. The first and third ship a binary nobody here built;
the second tracks a moving branch; and all three embed the **low-latency**
model, since the fork's release workflow and its `-git` recipe both build the
ladspa crate with its default features. Our package provides and
conflicts on the same name, so it cannot be installed beside any of them —
which is right, since all four would put the same file in `/usr/lib/ladspa`.
`bootstrap.d/95-noise-suppression.sh` names the owning package when the file
is already there, because a plugin from one of those looks identical on disk
and is not.

### The full model, and what `--no-default-features` does

The repository ships two DeepFilterNet 3 models, and the difference is one
number in each `config.ini`:

| | `DeepFilterNet3_onnx.tar.gz` (full) | `DeepFilterNet3_ll_onnx.tar.gz` (low latency) |
|---|---|---|
| `conv_lookahead` | 2 | 0 |
| `df_lookahead` | 2 | 0 |

Two frames of lookahead is 20 ms the model may look into the future before
deciding what a frame is, and it is what the full model's quality rests on.
The ladspa crate's `Cargo.toml` says `default = ["default-model-ll"]`, and
`libDF` picks the model to embed by testing `default-model-ll` **first**; the
crate's own `deep_filter` dependency turns `default-model` on unconditionally.
So `cargo build -p deep-filter-ladspa --no-default-features` leaves exactly
one model feature standing, and it is the full one. The PKGBUILD's `check()`
proves that twice rather than from this sentence. First, the feature tree read
inverted on `deep_filter` (`cargo tree -e features --no-default-features -i
deep_filter`) must contain `deep_filter feature "default-model"` and must not
contain `deep_filter feature "default-model-ll"`. Inverted, because a forward
tree never prints an edge the root crate's own feature table adds, and that is
the edge through which the ladspa crate's `default` turns `default-model-ll`
on: the forward check this replaced passed a default-features build, the
low-latency one. Second, the finished `.so` must carry
`models/DeepFilterNet3_onnx.tar.gz` byte for byte — `libDF` embeds the model
with `include_bytes!` — and must not carry
`models/DeepFilterNet3_ll_onnx.tar.gz`, which catches a flag added to
`build()`'s line alone. In the sandbox build the finished `.so` held the
string `DeepFilterNet3_onnx` twice and `DeepFilterNet3_ll_onnx` never.

### Strength

`hypr/denoise.sh` writes one input preset, `denoise.json`, from a strength
name. The knobs are the plugin's own control ports in the units EasyEffects
passes through unchanged, and the numbers are `strength_params()` in that
script — `tools/test-easyeffects.sh` compares this table against it, so the
two cannot drift apart quietly.

| strength | attenuation-limit | min / max-ERB / max-DF thresholds | buffer | post-filter-beta | why |
|---|---|---|---|---|---|
| gentle | 24 | -15 / 30 / 20 | 2 | 0.02 | upstream's "medium reduction" ceiling: noise is softened, not deleted, and room tone survives |
| balanced | 70 | -15 / 30 / 20 | 2 | 0.02 | the default; the range EasyEffects' own manual calls balanced |
| maximum | 100 | -15 / 35 / 35 | 2 | 0.05 | no cap; every frame goes through both stages; the strongest post-filter |

*[The buffer column was 0 in every row until 2026-10-17, and the table is
held to `strength_params()`, so it says 2 now; the bullet below says what 0
was taken to mean, and *Dropouts* what it cost.]*

What each column is, from `libDF`'s `tract.rs` and the plugin's port
descriptors:

* **attenuation-limit** (dB, 0–100): how much of the noise estimate may be
  removed. 100 is *no* limit — the model's own default, "remove everything I
  call noise". Upstream suggests 6–12 for a little reduction and 18–24 for a
  medium one; EasyEffects' manual calls 70–80 the balanced range. This is the
  knob that tells the three rows apart, and it is what the labels in the
  settings panel name.
* **min-processing-threshold** (dB of local SNR): a frame the model estimates
  below this gets a zero mask instead of the model's gains — a strict `<`, in
  `libDF`'s `apply_stages` — and the attenuation limit then mixes the noisy
  frame back in, so a gated frame is 24 dB down on gentle and 70 dB down on
  balanced, and silent only on maximum, which has no limit. A gate that blunt
  clips soft onsets, so every row keeps it at -15, the floor EasyEffects
  allows (`easyeffects_db_deepfilternet.kcfg` at v8.2.9) — which is also the
  bottom of the model's own estimate, 50·sigmoid − 15 (`lsnr_fc` in the
  fork's `DeepFilterNet/df/deepfilternet3.py`, with `lsnr_min` and
  `lsnr_max` from the model's `config.ini`). So the gate is off in effect,
  and the gains do all the work; `libDF`'s own default, -10, is where it
  fires. Read from the pinned commit's source and the full model's
  `config.ini`; that the shipped models' graphs compute it that way (a
  sigmoid, times 50, minus 15) was the audit's walk.
* **max-ERB-processing-threshold**: above this local SNR the frame is passed
  as already clean, unprocessed. **max-DF-processing-threshold**: between it
  and the ERB threshold only the gain stage runs and the deep-filter stage is
  skipped. 30 and 20 are the defaults; 35 is the ceiling, where every frame
  goes through both stages. `libDF` warns unless min ≤ max-DF ≤ max-ERB, which
  every row satisfies.
* **buffer** (frames): extra frames queued before processing. Each is 10 ms
  of latency, so it is 0 everywhere.

  *[Neither, in the fork: it was a floor under the plugin's trim of its own
  delay, and changed nothing at a quantum of 1024. With this package's patch
  it is headroom -- frames of delay held above what the host's quantum
  needs, set up before the first sample -- and it is 2 everywhere, 20 ms.
  *Dropouts*.]*
* **post-filter-beta** (0–0.05): a post-filter that sharpens attenuation when
  it is above 0. 0.02 is EasyEffects' default, 0.05 the ceiling.

These are informed defaults, not measured ones: nothing in this repository
can listen. They are meant to be told apart in a recording, and the popup's
strength button cycles through them so that recording is one click per row.

### Latency

The full model's algorithmic delay is about **40 ms**: the 20 ms analysis
window plus the two 10 ms frames of lookahead. The low-latency model, with no
lookahead, is 20 ms. On top of that is the PipeWire quantum on the way into
EasyEffects and again on the way out, which is the same cost every EasyEffects
plugin pays. What EasyEffects reports for the plugin leaves the model's
lookahead out — its `get_latency_seconds()` for this plugin does not include
it — so the latency figure in its window is short by roughly that much. A
microphone can afford 40 ms; a path that monitors itself in headphones could
not, and nothing here routes one through it.

*[This left out the plugin's own queue, which holds the delay the quantum
needs and, with this package's patch, two frames of headroom above it:
50.7 ms at PipeWire's default quantum of 1024, where the fork held 31.3 ms at
best and moved up from there with every underrun. *Dropouts* has the table.
EasyEffects reports none of it.]*

### CPU

One worker thread per plugin instance, and the model runs in it, polled every
half a millisecond while the input queue fills. **Nothing here measured what
that costs**: the sandbox that built the plugin has no sound server. Expect a
noticeable slice of one core while the microphone is open and next to nothing
while the filter is bypassed, and read the real number off `pw-top` on the
machine. It is one of two reasons the setting is off by default; the other is
that the plugin is a source build that need not exist.

### Off means bypassed, not removed

Off is `"bypass": true` inside the same preset, still loaded — never a preset
without the plugin. EasyEffects' own `deepfilternet.cpp` keeps its
`clear_data()` disabled because the plugin "does not seem to destroy its
threads properly", citing a comment on wwmm/easyeffects#4652; flipping bypass
leaves the instance alive and idle.
So `denoise.sh set off` rewrites `denoise.json` with the plugin bypassed and
reloads it when a running instance holds `denoise`, and `set on` flips it
back.

### A load is verified, not assumed

The load is a line on the socket. It is refused when nothing listens, and
taken without a word for a preset the daemon lacks — so `load_preset` in
`denoise.sh` writes `load_preset:input:denoise` and then asks: it believes
the load only when `get_last_loaded_preset:input` answers `denoise`. Up to
three tries a second apart, because a daemon that has just opened its socket
may not be answering yet; the lib bounds each exchange. When none of the
three is answered with `denoise`, `set` dies saying so, and `apply` says so
on stderr and exits 0. Before any of that, readiness is `ee_ready` — this
user's process and a socket that accepts a connection — and
`ee_wait_running <seconds>` polls for both every half second. `set on`
refuses without socat before it writes or starts anything, as it already
does without the plugin; otherwise it starts an instance when none is ready,
through the unit when it is installed and by hand otherwise — never by hand
beside a process that is still starting — and waits for it to listen before
it loads.

*[Here `apply` says so on stdout, as it says everything it exits 0 after:
its status is 0 either way, so its lines are the whole report, and on
stderr its failures were the one part a caller that kept stdout alone never
heard. The head of the `apply` arm in `src/jayos-denoise` says more.]*

### A preset you chose wins at login

Two verbs, two rules. `denoise.sh apply` is the login path: it reads
`micDenoise` and `micDenoiseStrength` from `settings.json`, writes the file,
waits up to twenty seconds for the instance the unit starts — for a socket
something listens on, not its process — and loads `denoise` **only when the
input pipeline holds nothing or already holds `denoise`**. An input preset you
loaded by hand is left alone, `apply` says so and exits 0, and the popup's row
reads "on, but input preset X is loaded". `denoise.sh set on` is an explicit
act — the toggle in the popup or the panel — and always loads, saying what it
replaced. `set off` rewrites the file bypassed and reloads it only when a
running instance holds `denoise` — a process that is still starting is waited
for, up to twenty seconds, as `apply` waits — so it never replaces anything
but ours. With no instance the file says bypassed, and `apply` makes the next
instance agree: at login, and whenever the popup's Start, Next preset or Open,
or the equaliser, starts one (below). `apply --force` loads ours over whatever
the input pipeline holds, still without starting an instance, and it is what
the plugin's installer runs when the setting was already on.

*[Here, `jayos-denoise apply` reads no settings: it is told the state and the
strength, `apply on|off [strength] [--force]`, and with no strength it uses
balanced, as `set` does. jayos's `hypr/denoise.sh apply` is what reads
`micDenoise` and `micDenoiseStrength` now, and it passes them on. The popup
and the panel are jayos's.]*

`apply` with the setting off is not quite a no-op. The daemon restores its
pipeline at start from its own database, not from our file, so a `set off`
done while nothing was running left that database saying `denoise`,
un-bypassed, and the next login brought the filter back on. So when our file
exists, `apply` rewrites it bypassed and then, when the rc file's
`lastLoadedInputPreset` says `denoise` or a process already exists, waits up
to twenty seconds for the instance the way the on path does and reloads ours
if ours is what it holds; when the rc names nothing of ours and nothing is
running, it exits at once. An off chosen while EasyEffects was down is
therefore honoured at the next login — and at the next start the popup or
the equaliser makes. `easyeffects.sh start`, `load` and `open`, and
`equalizer.sh`, spawn `denoise.sh apply` (`ee_apply_noise_setting` in the
lib) when they start an instance, detached, and before any wait for it. So
the popup stopping them does not lose it: its next click stops the action in
flight with SIGTERM, and closing the popup kills it with SIGKILL. A load that
fills the input pipeline itself — `load <name> input`, or a name with an input
preset and no pipeline named; never the popup's Next preset, which names
`output` — spawns `apply` after its load instead, since `apply` decides by
what the input pipeline holds. A start from the
application launcher, `systemctl --user restart`, or the unit's own
`Restart=on-failure` still waits for the next login.

*[Nothing in this package starts EasyEffects, at login or otherwise, except
`set on`, and nothing in it runs `apply` when something else starts one. In
jayos, `ee_apply_noise_setting` in jayos's own `easyeffects-lib.sh` spawns
jayos's `hypr/denoise.sh apply`, which calls this package; this repository's
copy of the library has no `ee_apply_noise_setting`, and its header says why.
Without jayos, whatever starts EasyEffects has to run `jayos-denoise apply on`
or `apply off` after it -- or an off chosen while EasyEffects was down is
undone by its own database at the next start, as the paragraph above
describes.]*

To combine the filter with plugins of your own, do it in EasyEffects: open the
window, load `denoise` on the Input page, add what you want, and **save the
result under your own name**. That preset then wins at every login, and the
settings panel's toggle is no longer what controls the filter — a `set` from
the popup would replace your preset with plain `denoise` again. Your saved
copy carries the numbers from the moment you saved it, so a strength change
made afterwards reaches it only when you load `denoise` and save again.

Every write goes to a `mktemp` file beside the target, is parsed with
`jq -e .`, and is moved into place, because EasyEffects lists a preset that
does not parse and refuses it without a word, and its directory watcher would
otherwise see a half-written file. Nothing under `output/` is ever touched.

### Building the plugin: three ways to the same recipe

All three run `makepkg` on `pkgbuilds/deepfilternet-ladspa/PKGBUILD` and end
with one file, `/usr/lib/ladspa/libdeep_filter_ladspa.so`, which is on
EasyEffects' default search path, so no `LADSPA_PATH` is set anywhere.

[...] *Lines 596-641 at `bf53d6a`, omitted: jayos's three ways to run that
recipe -- its bootstrap stage `95-noise-suppression`,
`pkgbuilds/build.sh --install deepfilternet-ladspa`, and the volume popup's
build button through `app-install.sh` -- and `install.sh`'s warning when the
plugin is missing. They are jayos's to describe. This repository's own way
is `makepkg -si` in `packaging/arch` (`README.md`); jayos's is its
`pkgbuilds/jayos-denoise/PKGBUILD`, which builds this repository's `main`
through the same `packaging/steps.sh`. Either way the package ends with more
than the one file named above; `README.md` lists them.*

What the recipe does, and what it costs — the numbers are from one build of
the pinned commit in a sandbox, so treat them as the order of magnitude:

| step | what | measured |
|---|---|---|
| `prepare()` | `cargo fetch --locked` for the host target. `Cargo.lock` names 595 crates: 584 from crates.io, six from two git repositories the lockfile pins to a commit — xobs' `ladspa.rs`, which the plugin links, and five from aldanor's `hdf5-rust`, behind an optional `libDF` dependency that `build()` never compiles but `prepare()` clones all the same, submodule included — and five that are the workspace's own. The host-target fetch takes 452 of them, 446 crate archives and the six git crates; the other 138 are reached only through dependencies declared for other platforms. `--locked` refuses to resolve anything the lockfile does not name | 176 MB clone, 522 MB of crate sources under `~/.cargo` |
| `build()` | `cargo build --frozen --release -p deep-filter-ladspa --no-default-features`; about 145 crates compiled, jemalloc included. `--release`, not the workspace's `release-lto` profile: that one sets `panic = "abort"`, and the plugin turns the panic an unsupported host sample rate raises into a logged refusal — an aborting panic would take the sound server down instead | 4 min 22 s; a 1.1 GB `target/` under the recipe directory |
| `check()` | the inverted feature-tree greps and the tarball comparison above; `readelf -d` must name no NEEDED library but libc, libm, libgcc_s and `ld-linux-x86-64.so.2`, the ones `depends=('glibc' 'gcc-libs')` installs; `nm -D` must show `T ladspa_descriptor`, the symbol EasyEffects `dlsym`s; then the fork's three tests in `ladspa/tests/no_rt_blocking.rs` — the callback never blocks, mono and stereo, and a wrong sample rate is refused before a model is built | about 1 min 40 s, nearly all of it compiling the test harness |
| `package()` | the `.so` at 755 under `usr/lib/ladspa/`, the licence — MIT or Apache-2.0, at your option — with both texts, and the README | |

The network is needed from the clone through the fetch and for nothing after
— `--frozen` refuses to reach for it. Unlike `winboat`, whose npm tree and Go
module cache no checksum covers, two builds of this commit are the same build.
`options=('!lto' '!debug')`: makepkg's LTO flag reaches only the C in
jemalloc while the Rust side already has thin LTO, and the debug option would
add `-C debuginfo=2` to 145 crates for a `-debug` package nothing here would
open.

*[The table's steps are `packaging/steps.sh`'s now: `prepare()` calls its
`checkout` and `fetch`, the other three the verb of the same name. `check`
also checks the engine -- it parses, it names its strengths, and every preset
it would write is JSON -- and `package` installs, beside the `.so`, the
engine and its library, the contract, this repository's `LICENSE` and
`THIRD_PARTY.md` with the fork's three licence files, and this document with
`README.md`. `depends=` is no longer the two packages `check()`'s row names:
glibc and gcc-libs are the plugin's share, and the rest are the engine's,
each tied by `tests/shell/test-packaging.sh` to a command the engine or its
library runs. The preface has the times measured on 2026-10-03.]*

### Turning it on

[...] *Lines 663-742 at `bf53d6a`, omitted: jayos's settings rows and
volume popup, how they write and poll, and the `Config.qml` defect this
feature exposed there. The paragraph below is about EasyEffects, and is as
true without jayos as with it except for its last sentence: the unit that
starts EasyEffects at every login is jayos's own `easyeffects.service`,
which neither EasyEffects nor this package ships. Without jayos the routing
happens whenever whatever you use has EasyEffects running.*

What applications hear is EasyEffects' virtual source — `easyeffects_source`
is its node name, which `wpctl status -n` shows; plain `wpctl status` and an
application's device list show its description, "Easy Effects Source" — and
they hear it without choosing it. EasyEffects' "process all inputs", on by
default and set by nothing here, moves every recording stream onto that
source by writing `target.object` metadata, including one that chose by name
the very microphone EasyEffects records (`src/pw_node_manager.cpp:295-319`
and `:473-482` at v8.2.9, read). RUN with that metadata written by hand, on
WirePlumber 0.4.17: `pw-record --target` naming a stand-in microphone
recorded the microphone, and once the stream carried `target.object` naming a
stand-in `easyeffects_source`, it recorded that instead. What EasyEffects
leaves alone, read in the same file: a capture that chose a device other than
its input; a capture of a sink's monitor ("exclude monitor streams", also on
by default); pavucontrol and plasma-pa, which it never touches, and anything
on its input blocklist, which `denoise.json` leaves empty; and every capture
once "process all inputs" is off. An application that opens the hardware
through ALSA itself, rather than through PipeWire, never reaches it either.
That routing happens whenever EasyEffects runs, which the unit arranges at
every login, whether noise suppression is on or off; what the setting adds is
the filter, its latency and its core.

### Checking it on the machine

None of this could be run where it was written, so these are the checks, in
the order that finds the most common problem first.

```bash
# 1. Which model is inside the file you built. The line is at debug level in
#    libDF, so RUST_LOG has to reach the process that loads the plugin -- and
#    with the unit running, a second `easyeffects` hands off to it and exits.
systemctl --user stop easyeffects.service
RUST_LOG=debug easyeffects --debug 2>&1 | grep -F 'Loading model'
#    want:  Loading model DeepFilterNet3_onnx.tar.gz
#    not:   Loading model DeepFilterNet3_ll_onnx.tar.gz  (the AUR builds)
systemctl --user start easyeffects.service

# 2. The input pipeline holds our preset, and the toggle's view of it agrees.
easyeffects -a input                               # denoise
# [...] Line 782 at bf53d6a asked jayos's hypr/denoise.sh. Here:
jayos-denoise status | jq .                        # loaded: true

# 3. What it costs while the microphone is open. Find the easyeffects input
#    node and watch its load; it should sit well under the quantum.
pw-top

# 4. Listen. One recording per strength, a keyboard clattering throughout;
#    the popup's strength button cycles gentle -> balanced -> maximum.
#    By node NAME: --target takes a name or an object.serial, not the number
#    `wpctl status` prints, and a target that matches nothing -- that number,
#    or this name while EasyEffects is not running -- is no error: pw-record
#    records the default source instead, usually the raw microphone (RUN on
#    WirePlumber 0.4.17). node.dont-fallback turns that into "defined target
#    not found" on 0.5, which Arch ships (the audit's run, on 0.5.17); 0.4.17
#    ignores it (RUN).
pw-record -P '{ node.dont-fallback = true }' --target easyeffects_source gentle.wav
#    and the same for balanced.wav and maximum.wav

# [...] 5., lines 800-804 at bf53d6a, omitted: jayos's doctor.
```

`journalctl --user -u easyeffects.service -b` is where the plugin's own
warnings go, including the overload lines ("Output underrun, increasing
processing latency", one per episode) that mean the machine could not keep
up.

*[The fork as it ships wrote one of those at every start, because its delay
began at one frame, and one more for every frame that ran late, each a
quantum of silence. This package's plugin primes its delay instead, so on a
machine that keeps up there is none; one now means a stall longer than the
headroom, and each raises the floor by a frame for five minutes. Started
with `RUST_LOG=info`, as in step 1, it also says the delay it chose:
`Holding 50.7ms for a quantum of 1024, 20.0ms of it headroom`. That line is
also how to tell which plugin is installed, without starting anything:
`grep -c 'ms for a quantum of' /usr/lib/ladspa/libdeep_filter_ladspa.so`
counts 1 in this package's plugin and 0 in the fork's.]*

*[Without jayos, step 4's three recordings are made after
`jayos-denoise set on gentle`, `jayos-denoise set on balanced` and
`jayos-denoise set on maximum`. In step 2, `loaded` is true when the preset
file exists and `denoise` is what the input pipeline holds: the running
daemon's answer, or with nothing running the rc file's. And with no
`easyeffects.service` -- jayos's unit, which neither EasyEffects nor this
package ships -- step 1's two `systemctl` lines fail with "Unit
easyeffects.service not loaded": quit EasyEffects however it was started,
run `RUST_LOG=debug easyeffects --debug` as written, and start it again your
usual way afterwards. The plugin's warnings then go to that process's
stderr, not to `journalctl --user -u easyeffects.service`.]*

### Limits, honestly

* **The fork is weeks old with one maintainer.** The commit pin protects
  reproducibility, not the fork's survival. A bump is `_commit` and `pkgver`
  in the PKGBUILD, the commit named above, and `DFN_COMMIT` in
  `tools/test-installers.sh`, which fails unless the other two name the
  commit it names. The id to check a tag against is the peeled one,
  `git ls-remote <repository> 'v1.0.2^{}'`: the tag is annotated, and its
  bare name answers with the tag object's own id (the PKGBUILD says so where
  it pins).

  *[Here a bump is the `_commit=` line alone; see the note under "Which
  source, and why". `packaging/arch/PKGBUILD` says the same about the peeled
  tag where it pins.]*

* **Nothing here was A/B tested.** The strength table is what "RTX Voice
  quality" is approached with, not proof of it; the on-machine listening test
  is yours. CPU cost was not measured either.
* **The socket's replies are read, not seen.** The bytes the scripts rely on
  — a bare `1` or `2` for the bypass, the name and one newline for a preset —
  are read from upstream's `src/local_server.cpp`, and were run against a
  `QLocalServer` built with Qt 6.4 carrying that handler, not against
  EasyEffects; `tools/test-easyeffects.sh` plays the daemon's end with a
  Python listener modelled on the same file. For a load against an instance
  that has just started, `denoise.sh` writes `load_preset:input:denoise` up to
  three times, a second apart, and believes it only when
  `get_last_loaded_preset:input` answers `denoise`.
* **Bluetooth headsets are a poor fit.** A headset's microphone exists only on
  the headset profile, and [...] Selecting the
  headset's microphone is therefore a deliberate act in the audio panel, and
  what you get is a 16 kHz mSBC stream (8 kHz CVSD without mSBC): the plugin
  resamples it to 48 kHz, but there is nothing above 8 kHz to restore, and a
  model trained on wideband speech has less to work with than a wired
  microphone gives it.

  [...] *Lines 836 through the first sentence of 855 at `bf53d6a`, omitted:
  jayos's WirePlumber rule that keeps the headset profile from being
  switched to when something opens a capture stream, the setting's spelling,
  and how jayos's doctor reads it.*

* **The Flatpak is not covered.** Everything here — the unit, the plugin's
  search path, and the socket at `$XDG_RUNTIME_DIR/EasyEffectsServer`, which a
  Flatpak opens under its temporary directory instead (`src/local_server.cpp`,
  `TempLocation`) — assumes the native package at `/usr/bin/easyeffects`.
