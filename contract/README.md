# The contract with jayos

jayos draws this package's switch in its volume popup and its settings, starts
EasyEffects from several places, diagnoses noise suppression in its doctor,
and builds this package with a recipe of its own -- all from another
repository. These files are what the two sides agree on, in a form each side
can test against without the other's code. jayos vendors a copy of this
directory, records the commit it came from and each file's sha256, and its
suites hold its wrapper, its popup, its doctor and its recipe to the copy.

| File | What it is | Made by |
|---|---|---|
| `VERSION` | The schema of the files below. A reader refuses a newer one. | generated |
| `commands.txt` | The engine's command language, one form per line, as its own usage prints it. jayos's wrapper may run these and no others. | generated |
| `status-keys.txt` | The keys `jayos-denoise status` prints, in its order. A reader may rely on every key here and on none that is not. | generated |
| `strengths.txt` | The strength names, in order. jayos writes them into its settings, its popup's cycle and its panel's choices. | generated |
| `preset.<strength>.json`, `preset.<strength>.off.json` | The preset `set` writes for each strength, on and bypassed, keys sorted. | generated |
| `facts.txt` | Names a desktop writes into its own code: the preset's name, the plugin's file and its key inside the preset, and the directories EasyEffects searches when `LADSPA_PATH` is unset. | generated |
| `steps.txt` | The verbs of `packaging/steps.sh` and their arguments: everything jayos's recipe calls. | generated |

The generated files are made by `tools/contract.sh`, which runs the engine and
reads the library rather than describing them, and which fails when any of
them differs from what the code now produces (`tools/check.sh` runs it).
After an intended change:

    tools/contract.sh --write

then commit the result and re-vendor it into jayos
(`tools/fixtures/jayos-denoise-contract/` there, with its `PROVENANCE.md`).

The `.txt` files carry a header of `#` lines; a reader skips them.
