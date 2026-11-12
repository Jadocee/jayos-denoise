# jayos-audio-tools

The two Rust programs jayos-audio installs in `/usr/bin` beside its shell
engine. Both came from JayOS's `rust/crates/jayos-desktop/src/bin/` at jayos
commit `45256e088ee133c177cc805248e43188edd87cfd` (2026-11-11), with the rest
of the audio code that moved into this package, and both are byte for byte
what was there: not one line was changed to build them here, because the
library they use, `jayos-core`, is vendored beside them under the name they
already call it by (`../jayos-core/PROVENANCE.md`).

| Program | sha256 at that commit, and here |
|---|---|
| `src/bin/jayos-audio-state.rs` | `b5757fb3e03ca3409417e9c8d3bd9f1bb7dc9387f1dbb42854e382e27552e544` |
| `src/bin/jayos-equalizer-preset.rs` | `b8baf5dc8a1595561bc0c4a9c69d425cd94a03fb39d5d91e665358113dc4bf62` |

Those sums record where the programs came from; unlike jayos-core's, they are
no check of anything. The programs are this package's code now, and a change
to one here is the change -- `tests/shell/test-vendored.sh` reads only
jayos-core's table.

- **`jayos-audio-state`** is the volume popup's producer: the devices and
  streams there are, which is the default, and which node a control acts on
  (`master sink|source`). JayOS's volume popup, on-screen display, top bar,
  battery popup and doctor call it. Its `//!` block is its manual.
  `tests/shell/test-audio-state.sh` runs the built program against fake
  `pactl`, `wpctl` and `pw-dump`; `contract/audio-state-fields.txt` names the
  keys it prints, which JayOS's popup suite holds its model to.
- **`jayos-equalizer-preset`** builds the EasyEffects output preset JayOS's
  equaliser (`music/equalizer.sh`) writes and loads, from its ten sliders.

The comments in both still name JayOS's paths -- `config/quickshell/...`,
`install.d/...`, `docs/AUDIO.md` -- as JayOS's at that commit: the callers
they describe are JayOS's, and stay there.
