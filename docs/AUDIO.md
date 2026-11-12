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

Read, not run: Arch's makepkg 7 and pacman; WirePlumber 0.5, which Arch
ships, and so how it links the capture and keeps the default there; rtkit,
the portal and module-rt's choice between them; EasyEffects with `processAllInputs` off; a call in
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
