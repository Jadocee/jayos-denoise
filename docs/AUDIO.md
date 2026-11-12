# Audio: the microphone's path, and what PipeWire needs under it

What jayos-audio 2.0.0 changed about the microphone, and why: noise
suppression in a PipeWire filter-chain of its own rather than an EasyEffects
input preset, real time from rtkit, and the floor under a call's recording
cycle. The code is the detail: `src/jayos-audio` for the engine and its host,
`systemd/jayos-audio-denoise.service` for the unit, and `share/` for every
drop-in the package installs, each with its reason in its header.
`docs/DEEPFILTERNET.md` is the plugin's account and 1.x's, and is history
where it describes an EasyEffects preset.

Nothing here has run on an Arch machine, in a call, or with a person
listening. What has run is said where it is claimed, and the last section
draws the line.

## Why the microphone left EasyEffects

The owner's reports: on 2026-11-05, that the microphone stuttered in voice
chat -- Element, "etc." -- with EasyEffects' Effects switch on, *with noise
suppression off*, and was clean with the switch off; and on 2026-11-11, after
the floor below had shipped, that it was laggy and cut out with the switch on.

With the switch on, EasyEffects ran the microphone. JayOS sets its
`processAllInputs`, so every recording stream was moved onto
`easyeffects_source`, through every plugin of the input preset, whatever the
plugin's own bypass; and EasyEffects runs every plugin of both chains -- the
microphone's and the speakers' -- as filters in one PipeWire context, whose
one data thread serves both graphs on their two devices' clocks
(`src/plugin_base.cpp`, `src/pw_manager.cpp` and `src/stream_input_effects.cpp`
at EasyEffects v8.3.2, and `context.num-data-loops` in pipewire.conf(5), READ).
Nothing guaranteed that thread real time either: rtkit is no dependency of
Arch's pipewire, and PipeWire's module-rt asks xdg-desktop-portal first
(below). A call makes the cycle short -- a 10 ms WebRTC recording put the
microphone's graph on 256 frames, RUN, *The microphone stuttering in calls* --
and every cycle that thread finished late was a gap in what the call recorded.
The floor removed the short cycle. It did not take the microphone out of a
thread that also runs the music's equaliser, and the second report is what is
left: the inference, which nothing here has run, is that a late cycle on
either clock still costs the microphone a cycle.

What the two references do, read on 2026-11-11 (clones of each at that day's
default branch):

- **serpantinum-audio** (`ilyamiro/serpantinum-audio`), the engine behind
  the Serpantinum shell, replaced EasyEffects with an output engine of its own
  on PipeWire, and does no microphone effects at all ("microphone effects,
  which Serpantinum does not do", the shell's
  `docs/components/serpantinum-audio.md`). Voice-chat applications skip its
  output effects -- Discord and its PTB and Canary, Vesktop, Equibop, Legcord,
  ArmCord, WebCord, Zoom, Teams for Linux, by application name or binary, and
  any stream whose `media.role` is `Communication` or `phone`
  (`src/exclude.h`) -- each stream decided once, when it appears, so a stream
  never moves while it plays (its README).
- **omarchy** installs rtkit, because without it PipeWire's threads run at
  `SCHED_OTHER` and xrun under load (its issue #9390), and turns module-rt's
  portal path off for every client, because a portal started before rtkit was
  installed hands out a budget of zero, which module-rt applies as a hard
  `RLIMIT_RTTIME` of 0, and the kernel kills the process once its thread goes
  real time (its migrations `1789747667` and `1790114905`, and
  `etc/pipewire/client.conf.d/50-omarchy-rtkit.conf`). Its speaker tuning is a
  filter-chain hosted by a PipeWire process of its own, as a user unit.

The decisions, the owner's on 2026-11-11: the filter moves into a
filter-chain host of its own, as omarchy hosts its tuning; the Effects switch
no longer touches the microphone, and EasyEffects is output only; voice-chat
applications skip EasyEffects' output effects, serpantinum's list and
Element; and the package is renamed jayos-audio, with a `jayos-denoise`
command that takes 1.x's verbs. The last two are JayOS's half: its
`hypr/easyeffects.sh` writes `processAllInputs` false and the output
blocklist.

## The noise-suppression host

`jayos-audio denoise on [strength]` records the strength and the microphone
in `$XDG_STATE_HOME/jayos-audio/denoise.state`, then enables and starts
`jayos-audio-denoise.service`. The unit runs `jayos-audio denoise host`,
which writes the host's configuration under
`$XDG_RUNTIME_DIR/jayos-audio/` and execs `pipewire -c` on it: a PipeWire
client, not a second daemon, that loads module-rt, the native protocol and
`libpipewire-module-filter-chain` with one node, the plugin's
`deep_filter_mono` label. `jayos-audio denoise config <strength>` prints that
configuration; `contract/config.<strength>.conf` holds each, byte for byte.

- **Mono.** A microphone is one channel, and the stereo label would run the
  model twice on the same signal. The filter-chain converts whatever the
  microphone gives to 48 kHz mono, the plugin's only rate.
- **The microphone by name.** The capture side, `jayos_denoise_capture`,
  carries `target.object` naming the microphone `on` chose: the configured
  default source, else the one the state names, else the default WirePlumber
  reports. By name, because WirePlumber's fallback for a capture whose
  default is its own link group's source is the hardware source with the
  highest `priority.session`, which need not be the one chosen (`canLink` in
  `modules/lua-scripts/lib/linking-utils.lua` and `find-best-target` at
  WirePlumber 0.5.19, read). RUN on 0.4.17: with two stand-in microphones of
  priority 900 and 2000, the capture linked to the 900 one it was told.
- **The source applications record.** The playback side,
  `jayos_denoise_source`, `Audio/Source`, described "Microphone (noise
  suppressed)", is made the default input through
  `default.configured.audio.source` in the `default` metadata -- the key
  `wpctl set-default` writes, by name, which WirePlumber keeps across its
  restarts. So an application that records the default records the filtered
  source, with nothing moved by metadata behind its back, and one that chose
  a device by name keeps it.
- **Off.** `off` puts the microphone it recorded back as the default -- or
  removes the key where nothing else was configured -- then stops and
  disables the unit. With the unit enabled, the host returns at every login
  and WirePlumber restores its default; disabled, WirePlumber falls back to
  hardware.
- **Live.** `strength` sets the running node's six controls with one
  `pw-cli set-param ... Props`, by the names the filter-chain gives them
  (`df:Attenuation Limit (dB)` and the rest), and restarts the host only where
  that is refused; so does `on` over a running host that records the same
  microphone, since JayOS's popup cycles the strength through `on`, and a
  restart is the model's load in silence, about 290 ms, in the middle of a
  call. `input <node.name>` moves the running capture with
  `pw-metadata <id> target.object`. RUN on 0.4.17: the attenuation read back
  100 after `strength maximum`, and the capture relinked to the other
  microphone.
- **1.x's preset.** `on` bypasses DeepFilterNet in EasyEffects' `denoise`
  input preset, where 1.x left one, and reloads it where EasyEffects holds it
  (`retire_easyeffects_preset`), so the microphone is never filtered twice.
  It never deletes the file: it is the person's to keep.

The status keys are 1.x's, kept for what reads them; the engine's header says
what each means now, and which five are constant.

## Real time

`depends=` names rtkit, which Arch's pipewire does not, and the package puts
`module.rt.args = { rtportal.enabled = false }` in
`/usr/share/pipewire/client.conf.d/` and `jack.conf.d/`, omarchy's setting:
every native client, EasyEffects and the host among them, asks rtkit itself.
The host's own configuration sets the same in its module-rt arguments,
because `pipewire -c` reads its file and not `client.conf.d`. PipeWire's
`pipewire.conf` and `pipewire-pulse.conf` are not changed: the daemon starts
before any portal.

`jayos-audio realtime` says what each of PipeWire's processes got: whether
rtkit is active, and for `pipewire`, `wireplumber`, `pipewire-pulse`,
`easyeffects` and the host, how many threads run `SCHED_FIFO` or `SCHED_RR`
and the hard `RLIMIT_RTTIME` from `/proc/<pid>/limits`. A process with no
real-time thread runs its audio at the scheduler's pleasure; one with a hard
limit of 0 is the portal's budget, and is killed when a thread goes real
time.

None of this has run under rtkit: the containers it was written in have none.
`tests/shell/test-engine.sh` runs `realtime` against a stand-in `/proc`.

## The microphone stuttering in calls

`share/pipewire/pipewire-pulse.conf.d/60-jayos-capture-latency.conf` sets
`pulse.min.frag = 1024/48000`, and the package installs it under
`/usr/share/pipewire/pipewire-pulse.conf.d/`, where a drop-in of the person's
own named after it, in any of the three directories, sets the key over it
(pipewire.conf(5), *DROP-IN CONFIGURATION FILES*). pipewire-pulse makes a
recording's latency its fragment (`fix_record_buffer_attr`,
`src/modules/module-protocol-pulse/pulse-server.c` at PipeWire `8fe27cc`,
READ), and Chromium and Electron record in 10 ms fragments with WebRTC's
processing on, which PipeWire rounds to a 256-frame cycle. The floor raises
recordings and nothing else. 1024 frames is PipeWire's default quantum, and
the one at which this package's plugin held 50.7 ms and never underran
(`README.md`, 2026-11-04). The cost is 21.3 ms of recording latency in place
of 10. The file's header has the rest, its name's place among drop-ins
included.

pipewire-pulse reads it only as it starts. `jayos-audio floor apply`
restarts one that started before the file's current contents were first seen
and holds no stream -- a restart drops every PulseAudio client's sound, a
call's both ways -- and otherwise says why it did not and what to run; `floor
status` says the same and restarts nothing. Its stamp is
`$XDG_STATE_HOME/jayos-audio/floor.stamp`.

RUN by `tests/shell/test-floor.sh` on 2026-11-11, PipeWire 1.0.5, WirePlumber
0.4.17 and pipewire-pulse in a box: a 10 ms recording linked to a stand-in
microphone was given 480/48000 and the graph ran at 256 frames without the
file; with it, 1024/48000 and 1024; a 10 ms playback was given 128/48000
either way. JayOS shipped the file in `~/.config` and the helper as
`hypr/pulse-latency.sh` from 2026-11-07 until this package took them.

## The two programs JayOS's controls read

`jayos-audio-state` and `jayos-equalizer-preset` came here from JayOS, whose
`rust/crates/jayos-desktop` built them until jayos commit `45256e08`
(2026-11-11), with the rest of its audio code. They are byte for byte what
was there (`rust/crates/jayos-audio-tools/README.md` has the sums), built
from `rust/`, this repository's own Cargo workspace, by `packaging/steps.sh`'s
`build` and installed in `/usr/bin` by its `package`.

- **`jayos-audio-state`** answers which devices, microphones and playback
  streams there are, which of each is the default, and -- as
  `jayos-audio-state master sink|source` -- which node a control acts on
  when the default is one of EasyEffects' virtual devices, whose own volume
  reaches nothing. JayOS's volume popup polls it once a second while it is
  open; its on-screen display, its top bar, its battery popup and its doctor
  ask `master`. Its `//!` block is its manual, and `contract/audio-state-fields.txt`
  names every key it prints, for JayOS's popup suite to hold its model to.
- **`jayos-equalizer-preset`** turns the ten sliders of JayOS's equaliser
  into the EasyEffects output preset its `music/equalizer.sh` writes and
  loads: slider n drives band 3n of EasyEffects' 32, and the other 22 sit at
  unity gain.

The library they share, `rust/crates/jayos-core`, is a vendored copy of the
five modules of JayOS's they use, held to JayOS's commit by a table of sums
(its `PROVENANCE.md`, and `tests/shell/test-vendored.sh`): JayOS keeps its
own for its microphone and camera indicator, which uses all of `pw_route`.
`packaging/steps.sh check` runs the programs' unit tests and
`tests/shell/test-audio-state.sh` over the release build, and holds each
program's linked libraries to `depends=` as it does the plugin's.

## What has run, and what has only been read

RUN, in containers with PipeWire 1.0.5 and WirePlumber 0.4.17 and no sound
card, on 2026-11-11:

- `tests/shell/test-host.sh`, with the plugin built from the pin and both
  patches: the host came up with its capture linked to the microphone `on`
  chose, its source the default input, `input` moved it, `strength` set the
  controls live, white noise came out 41.8 dB quieter, and `off` made the
  microphone the default again and stopped the host.
- The same host by hand over the fork's `assets/clean_freesound_33711.wav`
  mixed at 0 dB SNR with its `assets/noise_freesound_2530.wav`, played into a
  stand-in microphone and recorded from `jayos_denoise_source` at balanced:
  22.7 dB less noise in the speech's pauses, SI-SDR from 0.3 dB to 6.1, no
  silent run inside the speech, and the plugin's own line, "Holding 50.7ms for
  a quantum of 1024".
- `tests/shell/test-floor.sh`'s box, above.
- The recipe, `packaging/arch/PKGBUILD`, under makepkg -- pacman 6.0.2's,
  Ubuntu's build, with Arch's flags written into its `makepkg.conf` -- at
  `1e8e740`, with `check()`: 528 seconds, the fork's three tests and the two
  patches' passing. pacman installed the package into a scratch root: 31
  files, which `pacman -Qkk` found whole, `jayos-audio version` answering
  2.0.0 through its `/usr/bin` link, the plugin carrying the headroom mark
  and not the low-latency model; and `tests/shell/test-host.sh` passed over
  that installed plugin.

And on 2026-11-12, for the code that moved here from JayOS (the second
half of this document): every `packaging/steps.sh` verb over a fresh copy of
the pinned plugin repository, `check` running the plugin's six tests, the two
programs' 185 and `tests/shell/test-audio-state.sh`'s 100 over the release
build, and `package` making 34 files; `tests/shell/test-easyeffects.sh`'s 47
with no EasyEffects running; JayOS's own `tools/test-easyeffects.sh`, 909,
over this package's vendored copy against its stand-in EasyEffects, which
listens, stops, saves and starts again; and the game tag in a PipeWire 1.0.5
box, where a `paplay` and a `pw-play` under `game-env`'s two variables each
made a node named `jayos-game`. Twelve changes over the helper, its library,
the engine's dispatch, the packaging step and the lexer were each caught by
these suites -- one only once the start hook's cases ran under `set -u`, as
the helper does -- and twenty over the programs, by the fork that moved them,
all but one that changes nothing a suite holds.

Read, not run: Arch's makepkg 7 and pacman; WirePlumber 0.5, which Arch
ships, and so how it links the capture and keeps the default there; rtkit,
the portal and module-rt's choice between them; EasyEffects with `processAllInputs` off,
and EasyEffects 8.3.2 itself -- its blocklist match, its preset loads with
`ignorePresetBlocklist` on and its input chain's timer are read in its
source; Steam, Proton and a game under `game-env`'s variables; a call in
Element or anything else; a real microphone; and listening.

## Checking it on the machine

```bash
# 1. The host is running, records the microphone, and is the default input.
jayos-audio denoise status | jq '{running, loaded, input, isDefault}'
wpctl status -n | grep -A6 'Sources:'      # jayos_denoise_source marked *

# 2. Real time: rtkit active, and a real-time thread in each process.
jayos-audio realtime

# 3. The floor is in effect, and a call's recording runs at 1024 frames.
jayos-audio floor status
pw-top                                     # QUANT 1024 on the microphone during a call

# 4. Listen: one recording per strength, a keyboard clattering throughout.
jayos-audio denoise on gentle   && pw-record --target jayos_denoise_source gentle.wav
jayos-audio denoise on maximum  && pw-record --target jayos_denoise_source maximum.wav
```

`journalctl --user -u jayos-audio-denoise.service -b` is where the plugin's
lines go, the delay it holds and any "Output underrun" among them.

# EasyEffects, as the desktop drives it

The sections below moved here from JayOS's `docs/AUDIO.md` on 2026-11-11,
with the code they describe: `src/easyeffects.sh` (JayOS's
`hypr/easyeffects.sh` until then), `src/easyeffects-lib.sh`, and the two
programs under `rust/crates/jayos-audio-tools`. They are JayOS's words, and
name JayOS's paths as they stood: where they say `hypr/easyeffects.sh` they
mean `src/easyeffects.sh` here, run as `jayos-audio easyeffects`; where they
say `easyeffects-lib.sh`, the library beside it; and where they name a
JayOS suite -- `tools/test-easyeffects.sh` -- that suite still runs this
package's copy, vendored, against its stand-in EasyEffects, beside this
repository's own `tests/shell/test-easyeffects.sh`. *The microphone leaves
EasyEffects*, which several of them cite, is JayOS's record of the change
this document's *Why the microphone left EasyEffects* gives the reasons for.

## EasyEffects 8 moved, and three scripts had not noticed

8.0.0 (Arch has shipped 8.x since November 2025) changed where everything
lives:

| | 7.x | 8.x |
|---|---|---|
| presets | `~/.config/easyeffects/{input,output}` | `~/.local/share/easyeffects/{input,output}` — `XDG_DATA_HOME`, beside `irs/` and `autoload/` |
| settings | GSettings, schema `com.github.wwmm.easyeffects` | KConfig, `~/.config/easyeffects/db/easyeffectsrc` |
| the loaded preset | a GSettings key | `[Presets]` → `lastLoadedInputPreset`, `lastLoadedOutputPreset` |
| global bypass | a GSettings key | `[EffectsPipelines]` → `bypass` |
| headless start | `--gapplication-service` | `--hide-window --service-mode`; the old flag still works and is deprecated |
| how a second `easyeffects` reaches the first | as a GApplication, over D-Bus | a lock file, `$XDG_RUNTIME_DIR/easyeffects.lock`, and a local socket, `$XDG_RUNTIME_DIR/EasyEffectsServer` — no bus name at all |
| a unit or autostart entry in the package | none — 7.2.5-2 held a D-Bus activation file, `com.github.wwmm.easyeffects.service`, which is not a systemd unit | none — 8.2.9 holds only the launcher `.desktop`; `easyeffects.service` here is this configuration's own |

Three scripts here had the 7.x layout written into them separately, and each
looked as if it worked: the volume popup listed presets from a directory 8.x
never reads, the equaliser wrote a preset 8.x never loaded, and "current
preset" came from a schema that is no longer installed, so it was always
empty. One file knows the layout now —
`config/common/scripts/easyeffects-lib.sh`, sourced by `hypr/easyeffects.sh`,
`hypr/denoise.sh`, `music/equalizer.sh` and `hypr/app-install.sh`, whose
`jayos-denoise` arm asks it where EasyEffects looks for the plugin. The
`jayos-denoise` package carries a copy, taken at this tree's `bf53d6a` for the
engine that left with it; the copy's header names its two edits, and a fix to
one is a fix to one. The doctor does not source it: `doctor.d/50-hardware.sh`
runs `easyeffects.sh status` and `denoise.sh status` and reads the JSON they
print — `layout`, `presetsRoot`, `running`, `bypassed`, `plugin`,
`pluginPath`, `engine` and the two preset lists from the first; `enabled`,
`strength`, `presetExists`, `presetFile`, `inputPreset` and `loaded` from the
second. The first also prints `answered`, which of its three daemon values —
`bypassed`, `outputPreset`, `inputPreset` — the running daemon gave itself
rather than the rc standing in (all three false when nothing runs); the volume
popup reads it, the doctor does not. Those keys are part of the two scripts'
contract, and `tools/test-easyeffects.sh` checks both key sets by name.

**The layout is read from the files, not from `easyeffects --version`.**
`ee_layout` answers 8 when `~/.local/share/easyeffects` or
`~/.config/easyeffects/db` exists, 7 when only the old `input/` or `output/`
directories do, and 8 when nothing does — a fresh 8.x that has never run has
no directory at all. Asking the binary would be simpler, and wrong:
`easyeffects --version` is a Qt application that builds its QApplication — so
it needs a display — and reaches for the single-instance lock before it
prints anything, and the poll behind the volume popup runs every time the
popup opens. A poller should not spawn a Qt process to learn a directory
layout that the filesystem states for free.

**KConfig writes a key only when the value differs from the compiled-in
default**, so an absent `lastLoadedInputPreset` means "nothing loaded" and an
absent `bypass` means false. `ee_rc_get` prints nothing for an absent key
rather than guessing.

**There is no D-Bus service and no bus name in 8.x.** The first instance
takes a lock file, `$XDG_RUNTIME_DIR/easyeffects.lock`, and — only after its
PipeWire connection and every plugin are up — listens on a local socket,
`$XDG_RUNTIME_DIR/EasyEffectsServer`, which takes one request per line
(`src/local_server.cpp` at v8.2.9). `easyeffects-lib.sh` writes those lines
itself, through `socat` — `ee_socket` is the exchange, `ee_tell` a request
that wants no reply, `ee_ask` a question, `ee_load_preset` a load — and not
through the `easyeffects` command line, for two reasons:

* **The command line closes the window.** A second `easyeffects` finds the
  lock held and writes the same lines to the socket, and at v8.2.9 its `-l`
  and every `-b` write `hide_window` after them
  (`src/command_line_parser.cpp:201` and `:229`). So every popup open, whose
  poll asked `-b 3`, every preset load, every noise-suppression toggle and
  every equaliser apply closed an EasyEffects window somebody had open.
  Upstream took the hide out of `-b` after 8.2.9 (3b88265, in no release yet)
  and kept it in `-l` (`:209` on master). Read from upstream's source: there
  is no EasyEffects here to run.
* **It exits 0 whatever happened.** A line written to a socket nobody listens
  on is dropped without a word, so neither "the process exists" nor "the
  command exited 0" means anything was heard. `socat` exits 1 when nothing
  accepts the connection.

No display is needed for any of it, and every exchange is bounded:
`connect-timeout=1` turns a daemon whose queue is full into an immediate
refusal, `-t 0.5` is the half second upstream's own client waits for a
reply, and `timeout 2` bounds the rest.

**Readiness is this user's process and a socket that accepts a connection.**
`ee_running` is `pgrep -u`: another user's EasyEffects, on a second seat,
keeps its lock and socket in its own `XDG_RUNTIME_DIR`, and nothing here can
speak to it. `ee_listening` asks socat whether a connection would be
accepted, because a socket FILE is not a listener: a crash leaves the file
behind, upstream removes it only at the end of the next start, and the unit
restarts the process three seconds after a crash — so for the seconds a
restart takes there is a process and a file and nothing listening. `ee_ready`
is both, and `ee_wait_running <seconds>` polls for both every half second.
Without socat nothing can be asked, and readiness falls back to the socket
file.

**A load is believed only by the script that asks.** The daemon takes a load
of a preset it does not have without a word, so a load that reached a
listening daemon is not a load that happened. The noise switch asks afterwards
— `jayos-denoise`, the engine `hypr/denoise.sh` hands every switch to (that
package's `docs/DEEPFILTERNET.md`, *A load is verified, not assumed*).
`easyeffects.sh load` does not: it exits 0 once its line reached a daemon that
was listening, and the volume popup polls `status` when the action ends —
which asks the daemon — so the Effects row shows what the daemon holds, not
what was asked for. `equalizer.sh` does not ask either.

What the socket takes, and what the scripts send it:

* **`load_preset:<input|output>:NAME`, one pipeline per line.** The command
  line's `easyeffects -l NAME` loads NAME into the input pipeline if
  `input/NAME.json` exists **and** into the output pipeline if
  `output/NAME.json` exists — both, independently, with no way to say which
  (the second process decides that, `src/command_line_parser.cpp:184-199`).
  `easyeffects.sh load <name> [output|input]` names the pipeline; given none,
  it keeps `-l`'s rule and sends a line for each pipeline that has a
  `NAME.json`. The volume popup's Next preset passes `output`, so a name the
  input side also has a preset for no longer replaces the microphone's
  `denoise`. Before anything starts, `load` refuses a name the socket cannot
  carry — more than 100 bytes, or a newline in it (`ee_preset_name_ok`; the
  daemon's pattern is `^load_preset:(input|output):([^\n]{1,100})\n$`, and it
  drops anything else without a word) — a pipeline word that is neither
  `output` nor `input`, a name with no preset in the pipeline it was asked
  for (or, with none named, in either), and anything at all when socat is
  missing. The two presets this configuration writes have names that cannot
  collide: `live_eq` on the output side, `denoise` on the input side.
* **`global_bypass:0|1` and `toggle_global_bypass` are the GLOBAL bypass**,
  both pipelines at once. Nothing here uses it for the microphone: it would
  silence the equaliser on the speakers to mute a filter on the microphone,
  and the noise switch never sends it — not `denoise.sh`, and not the
  `jayos-denoise` engine it calls. The popup's Effects switch is the only
  caller, and it means both: it runs `easyeffects.sh bypass toggle` (and
  `start` when nothing is running). The verb takes `on` and `off` as well, for
  a hand at a terminal, and the doctor prints `bypass off` as the remedy when
  the bypass keeps the microphone's filter out of the chain. The toggle
  is one request, which the daemon applies to whatever state is live; it was a
  read and then a set, and the read fell back to the rc whenever a busy daemon
  did not answer, so the "opposite" sent was the state it already had. Off is
  `0`, not the command line's `2`: the daemon's pattern is
  `^global_bypass:([01])\n$`. 7.x has no socket, keeps `-b 1|2`, and reads its
  key with `-b 3` before a toggle.
* **`get_last_loaded_preset:<input|output>` is answered with the name and ONE
  newline.** A lone newline means nothing is loaded; no bytes at all means no
  answer — nothing listening, or a daemon too busy to reply within the half
  second. `ee_ask` keeps the reply in `EE_REPLY` rather than on stdout,
  because `$(...)` would eat the newline that is the whole of an answer naming
  nothing. **`get_global_bypass` is answered with a bare `1`** (bypassed) **or
  `2`**, and no newline.
* **When a running daemon does not answer, the rc stands in.** `ee_value`
  returns 0 when the daemon answered and 1 when the rc's value stands in, and
  `ee_current_preset` and `ee_bypassed` print its value either way. The rc is
  what the daemon last SAVED, and it saves when its window hides or closes
  (its `contents/ui/Main.qml`) and when it quits (`src/main.cpp:454`) —
  `easyeffects.service` starts it hidden. So the rc is right for a daemon
  that has just started, whose socket listens before its event loop runs
  (`src/main.cpp:448` against `:469`) and whose pipeline was restored from that
  very file, and stale for one too busy to answer. `status` reports which of
  its values stood in (`answered`, above), and the popup keeps what the
  running daemon last said over an rc standing in for a moment it was busy.
* **Not every 8.x speaks all of it.** Read at the tags
  (`src/tags_local_server.hpp` and the patterns in `src/local_server.cpp`):
  `load_preset` and the window lines from 8.0.0, `global_bypass` from 8.0.1,
  `get_last_loaded_preset` from 8.0.7 — which is also when `load_preset` took
  `input|output` for the pipeline; 8.0.0 to 8.0.6 wanted a number there, so a
  load from here reaches such a daemon and changes nothing, which
  `jayos-denoise` catches by asking and `easyeffects.sh load` cannot — and
  `get_global_bypass` and `toggle_global_bypass` from 8.1.3. A line a daemon
  does not know is dropped without a word, so before 8.1.3 a question about
  the bypass reads as no answer, the rc answers, and the Effects switch does
  nothing.

## The settings an install puts back

The equaliser and the volume popup each rest on an EasyEffects setting at
its default, and no feature here sets any of them. So a switch flipped once
in EasyEffects' own window went on undoing a feature, with nothing in the
shell saying why. Three more are set away from their defaults since
2026-11-11, below the table.
Since 2026-10-17, by the owner's call, every `./install.sh --apply`, and so
every `update.sh`, runs `hypr/easyeffects.sh defaults` with no question, and
it puts back any of these that `~/.config/easyeffects/db/easyeffectsrc` holds
at another value:

| group | key | default | what rests on it |
|---|---|---|---|
| `EffectsPipelines` | `bypass` | false | the Effects switch on; with the bypass on, every plugin is out of both chains. EasyEffects turns it off itself whenever the device changes (`resetBypassOnDeviceChange`, true by default) |
| `EffectsPipelines` | `processAllOutputs` | true | every playback stream through the output effects, the equaliser among them |
| `EffectsPipelines` | `excludeMonitorStreams` | true | a recording of a sink's monitor — desktop audio, a screen recorder — left alone, not moved onto the source that carries the microphone |
| `StreamInputs` | `useDefaultInputDevice` | true | the microphone recorded is the one the volume popup makes the default |
| `StreamOutputs` | `useDefaultOutputDevice` | true | and so is the device played into |
| `StreamInputs` | `listenToMic` | false | the microphone not played back through the speakers |
| `StreamOutputs` | `linkToVirtualSource` | false | what plays not mixed into what applications record as the microphone |
| `Window` | `autostartOnLogin` | false | `easyeffects.service` starts it; EasyEffects' own login entry, which uwsm runs as well, races the unit for the lock, and when it wins the instance runs outside the unit whose journal the doctor reads |
| `EffectsPipelines` | `inputInactivityTimerEnable` | true | the input chain unlinked ten seconds after nothing records EasyEffects' source. EasyEffects links the default input through its input preset as it starts (`StreamInputEffects`' constructor ends in `connect_filters`, `src/stream_input_effects.cpp` at v8.3.2, read), and only this timer unlinks it; off, the input preset's plugins ran on the noise filter's source all session, in the thread the equaliser runs in, heard by nobody |

The defaults are EasyEffects 8.2.9's, from `easyeffects_db.kcfg`,
`easyeffects_db_streaminputs.kcfg` and `easyeffects_db_streamoutputs.kcfg`,
read; `inputInactivityTimerEnable`'s is 8.3.2's. `EXPECTED` in
`hypr/easyeffects.sh` is the table, and `tools/test-easyeffects.sh` holds a
copy of it, so a row taken out of one is a failure. `processAllInputs` was
among its rows, at true, until 2026-11-11.

**And three set away from EasyEffects' defaults**, by the owner's calls on
2026-11-11, written wherever the file holds another value or none:

| group | key | written | why |
|---|---|---|---|
| `EffectsPipelines` | `processAllInputs` | false | no recording through EasyEffects: with it on, every recording ran through the input preset in EasyEffects' one data thread, beside every output effect, and the microphone lagged and cut out in calls with the Effects switch on (*The microphone leaves EasyEffects*, below). The noise filter is jayos-audio's own filter-chain now |
| `Presets` | `ignorePresetBlocklist` | true | a preset loaded leaves the blocklist below as it is. Off, EasyEffects puts each preset's own blocklist in its place as it loads it, and an empty one where the preset has none (`Manager::load_blocklist`, `src/presets_manager.cpp` at v8.3.2, read). Every preset the equaliser writes carries `"blocklist": []`, so the first one picked put every application below back on the effects |
| `StreamOutputs` | `blocklist` | the voice-chat applications and the games, merged in | a call's far end and a game's own mix kept off the output effects: serpantinum-audio's list and Element, each as EasyEffects may match it, and Wine, Steam and the game tag (below) |

`WANTED`, `VOICE_APPS` and `GAME_APPS` in `hypr/easyeffects.sh` are the
three, and the suite holds a copy of each. EasyEffects keeps an output stream off its effects when
its `application.id`, `application.process.binary` or `node.name` starts with
an entry of the list, case and all (`app_is_blocklisted` in
`src/pw_node_manager.cpp` at v8.3.2, read), so each application is named as
each of the three may spell it: Discord, its PTB and Canary, Vesktop,
Equibop, Legcord, ArmCord, WebCord, Zoom, Teams for Linux and Element, by
binary, Flatpak id and the node name PipeWire gives a stream from its
`application.name`, and WebRTC's own `WEBRTC VoiceEngine` and Zoom's `ZOOM
VoiceEngine`. EasyEffects has no rule by `media.role`, so serpantinum's skip
of every call-role stream has no equivalent here. The list is merged into the
person's, never over it: their entries stay first and as written, an entry of
ours already there is not added again, and nothing is removed.

**Games**, by the owner's call on 2026-11-11, "don't route video games output
through easy effects": a game mixes its own sound for the speakers or
headphones its settings name, an equaliser tuned for music moves where its
footsteps and voices sit, and its effects would ride the thread every other
stream's do. No property says "game" -- PipeWire has none, and EasyEffects
matches only the three above -- so `GAME_APPS` names a game two ways:

- **`wine`**, Wine and Proton whichever launcher started them. libpulse names
  a client's `application.process.binary` after `/proc/self/exe`, which for a
  Windows program is Wine's loader -- `wine`, `wine64`, `wine-preloader`,
  `wine64-preloader` -- never the `.exe`, and each starts with `wine`.
  **`steam`** is the Steam client and its `steamwebhelper`, which carries
  Steam's own voice chat.
- **`jayos-game`**, the node name every stream gets that a process started by
  a game launcher plays -- native games among them, whose binaries no list
  could name. `hypr/easyeffects.sh game-env` prints two variables, and
  `hypr/launch.sh` exports them as it starts Steam, Prism Launcher, Lutris or
  Heroic, `hypr/steam-open.sh` as it starts Steam with a URL, and
  `hypr/steam-gamescope.sh` puts them before the Steam inside gamescope --
  not on gamescope, whose own stream is the picture it offers for capture.
  Every process the launcher starts inherits them:
  - `PULSE_PROP=node.name=jayos-game`, which libpulse reads into every
    context the process opens (`pa_init_proplist`, read), joined to a
    `PULSE_PROP` already set;
  - `PIPEWIRE_PROPS={ node.name = "jayos-game" }`, which libpipewire reads
    into every stream and filter it connects, after the configuration's
    `stream.rules` (`pw_stream_connect` in `src/pipewire/stream.c`, read),
    and only where no `PIPEWIRE_PROPS` is set already, since two objects
    cannot be joined.

  Run here, in a box of PipeWire 1.0.5: a `paplay` under the first and a
  `pw-play` under the second each made a node named `jayos-game`, its
  `application.name` kept -- which is what the volume popup and EasyEffects
  show. `node.name` and not `application.id`, which EasyEffects matches too:
  WirePlumber keys a stream's saved volume by the first of `application.id`,
  `application.name`, `media.name` and `node.name` that it carries (`formKey`
  in `src/scripts/node/state-stream.lua` at 0.5.19, read), so one id on every
  game would give them all one volume, where `node.name` comes last and is
  never reached.

Not covered, and read rather than run: a Steam started some other way --
from a terminal, or by Steam's own login entry -- tags nothing, so only its
Proton games are kept off, by `wine`; a Flatpak Steam is handed the
variables, and whether Flatpak passes them into its sandbox has not been
tried; and no game, Steam or EasyEffects has run here.

Everything else in the file is left as it is: the presets loaded and the
plugins in them, the devices EasyEffects names, the input blocklist, the
window. Those are EasyEffects' state or somebody's choice, and nothing here
depends on them.

**The file is read the way KConfig reads it** — read in KConfig's source, on
its master branch: a bool is false spelled `false`, `no`, `off` or `0` in any
case and true spelled anything else, spaces round the `=` and a `[$i]` option
on a key are allowed, a CR from a file edited elsewhere is trimmed, and of
two lines for one key the later one counts. A key at its default in another
spelling, `listenToMic=Off`, is left alone. A key with a locale,
`key[de]=`, and a nested group, `[A][B]`, are other entries, and left alone
too. A key put back loses every line it has, and nothing else in the file
moves: the file is rewritten beside itself and renamed over, through a
symlink to the file it names, with its mode kept.

**EasyEffects holds its settings in memory and writes them back as it
quits**, so its file changes only while nothing is running it. With nothing
running, the file is edited and the next start reads it. With an instance
running and the file to change, `defaults` waits for it to listen, asks it a
question — it answers only from inside its event loop, and a SIGTERM that
lands before that loop runs is lost, because `QCoreApplication::quit` does
nothing there (Qt 6's source, read) — then sends this user's `easyeffects`
SIGTERM, which it answers by saving everything and quitting
(`src/main.cpp`, read), and gives it ten seconds. What it saved is read
again, which is how a bypass it held live gets into the file to be taken
out; then the file is edited, `denoise.sh apply` is spawned, and the
instance is started again through the unit, or by hand, hidden, where there
is none. It is never killed: killed, it saves nothing, and a hidden instance
has saved nothing since it started. One that does not stop, or that is not
listening yet, is left as it was, and the install prints a note with the
command that tries again. The bypass alone, on in a running instance whose
file is otherwise right, needs no restart: `global_bypass:0` goes over the
socket, and the instance saves it when it quits.

**EasyEffects' own login entry**, the
`~/.config/autostart/com.github.wwmm.easyeffects.desktop` that
`autostartOnLogin` writes, is removed whenever it runs `easyeffects`, whether
or not the key is still on: EasyEffects writes or removes the file only when
the setting changes while it runs, so the key alone does not take it away. A
file at that name that runs something else is somebody's own, and stays.

```bash
  # Which of the ten differ, and from what; exit 1 when any does.
jayos-easyeffects defaults --check
  # Put them back, as the install does.
jayos-easyeffects defaults
```

A setting you want away from its default goes back at the next install:
that is the trade the owner chose, and a row out of `EXPECTED` is how one
stops being put back. Run: `tools/test-easyeffects.sh`, against a fake
EasyEffects that saves its bypass as it quits and a `pkill` that quits it.
Not run: EasyEffects, KConfig or uwsm, on any machine; nor any of the
voice-chat applications, so which of the three names each one's streams
carry is read evidence.

## The equaliser writes where 8.x reads

`config/quickshell/music/equalizer.sh` builds `live_eq.json` from the ten
sliders with `jayos-equalizer-preset` and loads it over the daemon's socket,
`load_preset:output:live_eq`. It wrote the file to
`~/.config/easyeffects/output`, the 7.x directory, so on 8.x every apply wrote
a preset nobody read and the load reported "Specified preset does not exist"
into `/dev/null`. The sliders moved; the sound did not. `PRESET_DIR` is
`$(ee_presets_root)/output` now, and nothing writes a preset under
`~/.config/easyeffects/`; the one file there that anything here edits is the
settings file, which every install puts back to the nine defaults above.

The file alone does nothing either: an instance restores its pipeline from
its own database and never reads a preset file at start (upstream's
`presets_manager.cpp`, read). So with no instance ready the load is not left
for later. `equalizer.sh` first spawns `denoise.sh apply` (*A preset you
chose wins at login* says why), then starts an instance hidden — through the
unit when it is installed, by hand otherwise — and loads once it listens, in
the background, because a start takes seconds and the popup's process is gone
when the script exits. It used to end in a bare `easyeffects -l live_eq &`,
which with nothing running became the instance itself: hidden, outside the
unit, and deaf to its own `-l`, which only a second process passes on. On 7.x,
which has no socket, it uses the command line, and only while an instance is
running.

## EasyEffects' own devices, and what the volume controls act on

EasyEffects 8 makes two virtual devices, `easyeffects_sink` ("Easy Effects
Sink") and `easyeffects_source` ("Easy Effects Source"), and runs its effects
between them and the hardware: applications play into the sink, and its
output filters read the sink's monitor and write to the speakers; the
microphone feeds its input filters, and they write into the source
applications record from. Both are null sinks whose `monitor.channel-volumes`
is EasyEffects' "monitor channel volumes" setting,
`activateMonitorChannelVolumes`, which is off by default (`load_virtual_devices`
in `src/pw_node_manager.cpp`, and `easyeffects_db.kcfg`, read at v8.2.9). Off,
**neither device's own volume nor its mute reaches anything anyone hears.**
RUN on PipeWire 1.0.5 and WirePlumber 0.4.17 against stand-ins carrying those
properties: a tone read through the sink's monitor, the way its filters read
it, stayed at -15.1 dBFS with the sink muted and with it at 20 %, and a
recording of the source stayed at -15.1 dBFS with the source muted or at
20 %. With the property true, the same mute gave silence and 20 % gave
-57.0 dBFS, on both.

**The hardware stays the default.** EasyEffects moves streams onto its
devices itself: "process all outputs" and "process all inputs", both on by
default, write `target.object` metadata that sends playback to its sink and
recording to its source (*Turning it on*, below, says which captures it
leaves alone). Its README says its devices must never be the defaults — "Do
NOT set Easy Effects virtual devices as your default audio input/output"
(`README.md:163-166` at v8.2.9). One click on their rows in the volume popup
made one the default all the same, and WirePlumber then brings it back every
time EasyEffects starts, because the configured default names it: RUN, a
stand-in `easyeffects_sink` made the default, destroyed and made again was the
default again, and after `pactl set-default-sink` named the speakers it was
not. `qs_manager.sh doctor` fails when `easyeffects_sink` or
`easyeffects_source` is the default in force or the one WirePlumber has
configured, and prints the `pactl set-default-sink|source` that puts the
hardware back: with the device behind EasyEffects' when `jayos-audio-state`
finds one, and with the default in force when only the configured default
names EasyEffects' device and the one in force is not a monitor. Otherwise it
prints `hypr/easyeffects.sh default-devices`, which sets the hardware device
the session ranks first. That is what `install.sh --apply` runs, and since
2026-11-02 it also does so where nothing names a device behind EasyEffects'
node (by `pactl`'s list: not EasyEffects' own, not a monitor, a device's node
with its port not unplugged, then the highest `priority.session`; read, not
run against a real server). When the helper cannot say, the FAIL names which of
four states it is in: not installed; did not answer, with its status; `jq`
not installed; or built before `master` (`./install.sh --apply` rebuilds it).

Since 2026-11-03, when the troubleshooting page found the input left as
EasyEffects' own source after the install had put it back, three more things
hold it:
- **Nothing makes it so.** The popup's row for one of EasyEffects' devices is
  not a button, and `volume/audio_control.sh set-default` refuses either node,
  with status 1, for any caller.
- **The shell puts it back.** `services/AudioDefaultsService.qml` runs
  `default-devices` whenever the default output or input becomes EasyEffects'
  own, 3 s after the last change. It runs once for each state of the defaults
  and the devices, so a machine with nothing to put in its place is not asked
  in a loop, and a device connected afterwards is asked about.
- **No device is not a fault.** Where no device is named behind EasyEffects'
  node and `hypr/easyeffects.sh best-device` finds no hardware one either (no
  microphone, or headphones in a profile that carries none), EasyEffects'
  node is the only one there is. The doctor says so as a note, with no
  command, where it called it a problem and printed a command that could
  change nothing.
The doctor's volume line fails on any failure of the helper, rather than
reading the default in its place.

**Every volume control acts on the node that is heard.** The volume popup's
hero acts on the default row, by that row's id, and every other surface —
the top bar's volume pill, the volume keys, the battery popup's volume row
and the doctor — asks `jayos-audio-state master sink` (MASTER in
`rust/crates/jayos-desktop/src/bin/jayos-audio-state.rs`), which answers the way the
hero does. The music popup asks it too, for the device it names under the
track, by that device's description, where it named the bus ("USB Audio",
"System") or EasyEffects' sink. A hardware default is its own answer, from `wpctl inspect` and
`wpctl get-volume` alone, so it needs no pipewire-pulse (RUN: 33 ms with
pipewire-pulse stopped). There is no "real sink" any more: `audio_control.sh`'s
`real_sink()`, which redirected the popup's master under a DSP default, is
gone, so with a filter-chain or virtual-sink default the master is gain in
front of the chain, as on every other surface here.

EasyEffects' two devices, while their "monitor channel volumes" is off, are
the one case resolved. With one of them as the default, the controls act on
the device behind it — the speakers its output filters play into, or the
microphone its input filters record — found in `pw-dump`'s link graph
(`jayos_core::pw_route`, walking through nodes that have no media class, which
is what a filter is), or, when EasyEffects has unlinked its filters for
inactivity, in its rc (`[StreamOutputs] outputDevice`, `[StreamInputs]
inputDevice`). The hero keeps the virtual device's name and says under it
what its slider and mute move ("Level and mute: <device>"), and the popup
draws no slider or mute on the virtual device's own row. The answer has to be
a device pactl lists, as a popup row is, so finding it needs pipewire-pulse:
with pipewire-pulse stopped the helper refused after its five-second budget
(RUN: 5014 ms). When nothing is found the answer is a refusal, and the
controls change nothing rather than move a device nobody hears; the hero then
says "EasyEffects ignores this device's level and mute". RUN against a
stand-in `pw_filter` with no media class linked between each virtual device
and a device: the graph answered with no rc at all, and won over an rc naming
other devices; with the filters gone, the rc answered; with neither, both
`master` and `jayos-privacy` refused.

**The popup's writes go through pactl.** Every slider and mute button in the
volume popup runs `config/quickshell/volume/audio_control.sh`, which writes
with pactl, by the row's index, and only while the sound server's cookie is
the one the index was read under (RUN: another lifetime's cookie was refused
with exit 1). A default choice writes the row's node name, which survives a
restart and needs no cookie. None of it goes through wpctl, whose object ids
are not pactl's indices: RUN, a stand-in source that wpctl numbered 59 was
index 1187 to pactl, which is its object serial.

**One level is written at a time.** A drag writes every 50 ms, and each write
asks pactl twice: for the cookie, then for the level. Until 2026-11-02 each
tick started a write of its own, so a second of dragging was twenty writes in
flight. They landed in whatever order they finished, and after a release the
slider moved between levels for a while as each poll drew whichever had
landed last (reported that day). One write runs at a time now (`volumeWriter`
in `VolumePopup.qml`). A node waiting keeps only the newest level asked for,
so the last level asked for is the last written. The slider follows the
device again only 600 ms after that last write lands, and a write that has
not ended after five seconds is stopped. `tools/test-volume-popup.sh` runs the
queue against a stand-in Process; a real sound server has not been through it.

**The microphone has two traps, and both are handled.**

* **EasyEffects' source as the default input.** The popup's Inputs hero and
  the privacy page's *Mute the microphone* act on the microphone EasyEffects
  records, found as above — RUN: `jayos-privacy mic off` muted the microphone
  the rc named and left `easyeffects_source` as it was. When that microphone
  cannot be found, the privacy switch is withdrawn (`canMuteMic` false)
  rather than offered over a mute that would silence no one, and
  `jayos-privacy mic off` refuses with exit 1. The top bar's microphone pill
  cannot read that microphone's mute: it is yellow and pulsing while
  something records, and hidden otherwise, and the fullscreen clock's mark
  is a plain microphone while something records (`tools/test-topbar.sh` and
  `tools/test-fullscreen-clock.sh` hold those states). The mute keys — `XF86AudioMicMute`, and a key of your own set on
  *Shell services → Microphone → Mute key* — and a click on the pill, run
  `osd.sh mic-mute`, which goes through `jayos-privacy`, and the OSD says the
  mute it read back.
* **A sink's MONITOR as the default input.** WirePlumber records the sink as
  the default — RUN: `wpctl inspect @DEFAULT_AUDIO_SOURCE@` printed the sink's
  name and `media.class = "Audio/Sink"` while pactl named the monitor — and
  the Inputs master used to move and mute the speakers. The Inputs tab now
  lists the monitor, "Monitor of <sink>", as the default row, and its
  controls move the monitor, never the sink (RUN: `audio_control.sh`'s
  `set-volume` and `set-mute` on that row took the monitor to 30 % and muted
  it, and left the sink at 100 % and unmuted). The top bar's pill cannot read
  a monitor's mute either, and is yellow while something records. The
  monitor of EasyEffects' own sink is such a monitor and not one of its
  inert devices: pactl lists it as "Monitor of Easy Effects Sink" with the
  sink's EasyEffects properties and `device.class` "monitor", and its own
  mute and volume work. As the default input it is what the Inputs hero and
  the privacy page act on, and muting it also silences what EasyEffects
  plays, because EasyEffects' output filters read the same monitor ports —
  RUN: muted, a stand-in reader of the sink's monitor ports read silence as
  well as a recorder of the monitor did; at 20 % both read -57.0 dBFS; and
  `jayos-privacy mic off` muted it.
