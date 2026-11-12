# The contract with jayos

jayos draws this package's switch in its volume popup and its settings,
fills that popup's device and stream lists from this package's
`jayos-audio-state`, diagnoses noise suppression and the recording floor in
its doctor, runs `floor apply` and `easyeffects defaults` from its install,
reads EasyEffects' state for its popup through `jayos-audio easyeffects`, and
builds this package with a recipe of its own -- all from another repository. These files are what the two sides agree
on, in a form each side can test against without the other's code. jayos
vendors a copy of this directory, records the commit it came from and each
file's sha256, and its suites hold its wrappers, its popup, its doctor and its
recipe to the copy.

| File | What it is | Made by |
|---|---|---|
| `VERSION` | The schema of the files below: 2 since jayos-audio 2.0.0, where 1 had EasyEffects presets. A reader refuses a newer one. | generated |
| `engine-commands.txt` | `jayos-audio`'s command language, one form per line, as its own usage prints it. jayos's wrappers may run these and no others. | generated |
| `easyeffects-commands.txt` | The verbs `jayos-audio easyeffects` takes, from `src/easyeffects.sh`'s usage block: EasyEffects as jayos's volume popup, installer, doctor and default-device service drive it, since that script moved here from jayos. jayos's `hypr/easyeffects.sh` hands every word on, so its callers may use these and no others. | generated |
| `commands.txt` | `jayos-denoise`'s forms, 1.x's verbs, which the engine takes on its behalf. | generated |
| `status-keys.txt` | The keys `jayos-audio denoise status` prints, in its order: 1.x's, then this engine's. A reader may rely on every key here and on none that is not. | generated |
| `strengths.txt` | The strength names, in order. jayos writes them into its settings, its popup's cycle and its panel's choices. | generated |
| `config.<strength>.conf` | The host's PipeWire configuration for each strength, byte for byte, as `jayos-audio denoise config` writes it with no plugin installed and no microphone chosen. | generated |
| `facts.txt` | Names a desktop writes into its own code: the plugin's file, the directories searched for it, `headroom-mark` -- a string the plugin this package builds carries and the fork's does not, a piece of what `packaging/patches/0001-*` logs, so a desktop can tell which is installed by reading the file -- the host's source and capture node names, its unit, where the recording floor is installed, and the EasyEffects input preset 1.x wrote, which `on` bypasses. | generated |
| `steps.txt` | The verbs of `packaging/steps.sh` and their arguments: everything jayos's recipe calls. | generated |
| `audio-state-fields.txt` | The keys `jayos-audio-state` prints, `<object> <key>` a line, in its order: `state` the bare answer, `node` each object of its three lists, `master` the answer to `master sink\|source`. Read off the program's three structs; `tests/shell/test-audio-state.sh` holds it to what the built program prints, and jayos's popup suite holds the QML's model to the copy it vendors. | generated |

The generated files are made by `tools/contract.sh`, which runs the engine and
reads its source and `jayos-audio-state`'s rather than describing them, and
which fails when any of them differs from what the code now produces
(`tools/check.sh` runs it).
After an intended change:

    tools/contract.sh --write

then commit the result and re-vendor it into jayos
(`tools/fixtures/jayos-audio-contract/` there, with its `PROVENANCE.md`).

The `.txt` files carry a header of `#` lines, and each `.conf` two; a reader
skips them.
