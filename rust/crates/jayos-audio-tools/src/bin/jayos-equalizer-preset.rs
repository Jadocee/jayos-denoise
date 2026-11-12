//! The EasyEffects preset, built from the ten equaliser sliders.
//!
//!     jayos-equalizer-preset [build [STATE]]  read the state file, print the preset
//!     jayos-equalizer-preset parse            the same preset, from state JSON on stdin
//!
//! `build` is accepted as an explicit name for the default, so a call site can
//! be read without knowing which verb is the default one. STATE defaults to
//! `$QS_RUN_MUSIC/eq_state.json`, which is where equalizer.sh keeps it; the
//! script passes the path anyway so there is one place that decides it.
//! Anything else is `emit::unknown_command`.
//!
//! WHY `parse` EXISTS
//!
//! It is not a convenience. This runs on a machine with an EasyEffects daemon
//! and ten sliders in a popup, and the port had to be checked against the jq it
//! replaces. `parse` takes the raw state JSON on stdin and touches no file, so
//! the identical bytes go to both.
//!
//! THE BAND MAPPING IS NOT OBVIOUS AND IS NOT OURS TO IMPROVE
//!
//! EasyEffects wants 32 bands at fixed frequencies. The popup exposes ten
//! sliders. So slider n drives band 3n -- 0, 3, 6, ... 27 -- and the other 22
//! sit at unity gain. That is what the Python did, what the jq that replaced it
//! did, and what every preset already saved on disk assumes; a different
//! mapping silently changes what every stored preset sounds like.
//!
//! Indices 30 and 31 are both 24000 in the original table. The duplicate is
//! kept, because EasyEffects wants exactly 32 entries and the last two are
//! above anything audible anyway.
//!
//! THE ONE THING THIS PORT CHANGES, DELIBERATELY
//!
//! The jq wrote a whole-number gain as `0` where the Python wrote `0.0`, and
//! recorded that it had no way to force the trailing `.0`. This writes `0.0`
//! again: every gain is an `f64` and serde_json formats a finite `f64` with a
//! decimal point, so no hand-written JSON is needed for it. See
//! [`Band::gain`] for why that is worth doing rather than merely tidy.
//!
//! Frequencies stay integers. Only the gain differed between the Python and the
//! jq, so the Python wrote them as integers too, and so does every preset this
//! script has already left on disk.
//!
//! A FAILURE STILL PRINTS A WHOLE PRESET
//!
//! equalizer.sh builds this into a temporary file and moves it over
//! `live_eq.json`. The jq's failure mode was to print nothing, which left a
//! truncated preset for EasyEffects to reject -- so a bad slider value took
//! the equaliser out entirely. Every path here prints a complete, loadable
//! preset, with the bands it could not read left flat and the reason in a
//! top-level `error` beside `output`. EasyEffects ignores a key it does not
//! know; a person reading the file, or the exit status, gets told.
//!
//! TWO KINDS OF FAILURE, AND THE EXIT STATUS IS WHAT SEPARATES THEM
//!
//! A complete preset is only worth loading when it was built from the values
//! the user actually set. Those are two different questions, and both answers
//! used to leave here as exit 1, which the script could not act on -- so it
//! loaded whatever came out. A state file that was not JSON at all therefore
//! wrote 32 bands of 0.0 over `live_eq.json` and EasyEffects was told to load
//! it: the user's curve silently reset to flat by a corrupt file, where the jq
//! this replaced printed nothing and left the playing curve alone.
//!
//!   0  every slider was read. The preset is the user's curve.
//!   1  the state file was read and at least one slider in it was not a
//!      number. That band is flat and the other nine are the user's own, which
//!      is a better answer than refusing -- the caller SHOULD load this.
//!   2  nothing was read: the file is missing, is not JSON, is not an object,
//!      or carries no slider value this program could use. Every gain below is
//!      invented, so the caller must NOT load it and must leave whatever curve
//!      is playing where it is.
//!
//! 2 is already this workspace's status for "there is no answer at all" --
//! jayos-aur exits 2 when the AUR is unreachable and nothing was vetted,
//! jayos-focus-stats when the command line was unusable -- and 1 stays an ordinary
//! failure, so a caller that only tests for non-zero is no worse off than it
//! was.

use jayos_core::{cli::Args, emit, paths};
use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};
use serde_json::Value;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

/// The 32 fixed band frequencies, in EasyEffects' order.
///
/// Indices 30 and 31 are both 24000. That is not a typo to fix: the table came
/// over from the Python unchanged and the presets on disk were built from it.
const FREQS: [u32; BANDS] = [
    32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
    2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000, 22000, 24000, 24000,
];

/// How many bands EasyEffects wants.
const BANDS: usize = 32;

/// How many sliders the popup has.
const SLIDERS: usize = 10;

/// One band drives every third one.
const STRIDE: usize = 3;

// ── the shape EasyEffects reads ──────────────────────────────────────────────
//
// Structs rather than `serde_json::json!`, because serde writes the fields in
// declaration order while a `serde_json::Map` without the `preserve_order`
// feature -- which this workspace does not enable -- sorts them. EasyEffects
// indexes by name and would not care, but a preset whose keys came out in a
// different order from the jq's is a diff nobody can read, and the field set
// is then the thing that has to stay right rather than the spelling.

/// One of the 32 bands.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
struct Band {
    frequency: u32,
    /// An `f64` even when the slider is a whole number, and that is the point
    /// of the port.
    ///
    /// serde_json formats a finite `f64` with a decimal point, so 0 comes out
    /// as `0.0` -- what the Python wrote, and what EasyEffects itself writes
    /// when it saves a preset from its own interface. The jq could not do it:
    /// JSON has one number type and jq prints an integral value without the
    /// fraction, which is why the script carried a comment saying so. Nothing
    /// reads the difference, but a preset this writes and a preset EasyEffects
    /// rewrites should not differ on every line of a diff.
    gain: f64,
    mode: &'static str,
    mute: bool,
    q: f64,
    solo: bool,
    width: f64,
    slope: &'static str,
}

/// All 32 bands, keyed `band0` .. `band31`.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Bands([Band; BANDS]);

impl Serialize for Bands {
    /// Written by hand so the keys come out in BAND order.
    ///
    /// A `BTreeMap` or a `serde_json::Map` sorts its keys as strings, which
    /// gives band0, band1, band10, band11 ... band19, band2 -- correct JSON
    /// that EasyEffects loads perfectly well, and unreadable next to the jq's
    /// output when the two are compared. jq's `from_entries` keeps insertion
    /// order, so this does too.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (i, band) in self.0.iter().enumerate() {
            map.serialize_entry(&format!("band{i}"), band)?;
        }
        map.end()
    }
}

/// The equaliser plugin's own settings.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
struct Equalizer {
    bypass: bool,
    #[serde(rename = "input-gain")]
    input_gain: f64,
    #[serde(rename = "output-gain")]
    output_gain: f64,
    /// The same bands in both channels. `split-channels` is false, so
    /// EasyEffects reads `left` and ignores `right` -- but it wants both keys
    /// present, and a preset saved with one channel missing is refused.
    left: Bands,
    right: Bands,
    mode: &'static str,
    #[serde(rename = "num-bands")]
    num_bands: u32,
    #[serde(rename = "split-channels")]
    split_channels: bool,
}

/// The `output` chain: which plugins run, and their settings.
#[derive(Debug, Clone, PartialEq, Serialize)]
struct Output {
    blocklist: Vec<&'static str>,
    plugins_order: Vec<&'static str>,
    equalizer: Equalizer,
}

/// Which of the two failures produced a preset. The only distinction a caller
/// can act on, and for a while there was no way for it to see one.
///
/// Deliberately not a key in the JSON: it leaves by the exit status, so
/// equalizer.sh tests `$?` rather than matching on a message that is free to be
/// reworded, and the file EasyEffects loads keeps the exact shape the jq wrote.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fault {
    /// The document was read and one of the values in it was not usable. The
    /// bands that did parse hold the user's own gains, so this preset is worth
    /// loading with the one bad band flat.
    Slider,
    /// Nothing usable came out of the document. Every gain in the preset was
    /// invented here, so loading it replaces the curve that is playing with a
    /// flat one.
    Document,
}

/// What went wrong, in both the forms it has to exist in: a sentence for the
/// `error` key and for stderr, and a kind for the exit status.
#[derive(Debug, Clone, PartialEq)]
struct Problem {
    kind: Fault,
    message: String,
}

impl Problem {
    /// Nothing in the state file was read.
    fn document(message: impl Into<String>) -> Self {
        Self { kind: Fault::Document, message: message.into() }
    }

    /// The state file was read and a slider in it was not.
    fn slider(message: impl Into<String>) -> Self {
        Self { kind: Fault::Slider, message: message.into() }
    }
}

impl Serialize for Problem {
    /// The message alone, so `error` stays the plain string it has been since
    /// the jq -- anything reading the preset file already expects that, and the
    /// kind has a channel of its own.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.message)
    }
}

/// The whole preset file.
#[derive(Debug, Clone, PartialEq, Serialize)]
struct Preset {
    output: Output,
    /// Absent when everything was read, so a good preset is byte-identical to
    /// the jq's apart from the gains' decimal points.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<Problem>,
}

// ── reading the state file ───────────────────────────────────────────────────

/// One slider value, read the way jq's `tonumber` read it.
///
/// The state file holds BOTH shapes and always has. `save_preset` builds it
/// with `jq --arg`, which makes every value a string, and `set_band` writes one
/// key the same way -- while the default file the script writes when there is
/// none holds bare numbers. So `{"b1": 0}` and `{"b1": "0"}` are both normal,
/// and a state file part-way through a session is a mixture of the two.
fn slider_value(value: Option<&Value>) -> Result<f64, &'static str> {
    match value {
        // jq's `tonumber` errors on null, and an absent key is null -- which
        // took the whole preset out. Named here instead, and the band is left
        // flat.
        None | Some(Value::Null) => Err("missing"),

        Some(Value::Number(n)) => n.as_f64().ok_or("not a number"),

        Some(Value::String(s)) => {
            // Trimmed, because jq's `tonumber` trims: `" 5 " | tonumber` is 5
            // while `" 5 ".parse::<f64>()` is an error. set_band interpolates
            // its argument into the jq program, so a value that arrives with a
            // space around it reaches the file with the space still on it.
            let text = s.trim();
            if text.is_empty() {
                return Err("empty");
            }
            let n: f64 = text.parse().map_err(|_| "not a number")?;
            // `f64::from_str` accepts "inf", "infinity" and "NaN", and so does
            // an overflowing literal like "1e400". serde_json cannot represent
            // a non-finite float and writes it as `null`, and EasyEffects
            // reading a null gain rejects the preset -- so the one value that
            // would produce an unloadable file is refused here.
            if !n.is_finite() {
                return Err("not a finite number");
            }
            Ok(n)
        }

        Some(_) => Err("not a number"),
    }
}

/// The ten slider gains, and what could not be read.
///
/// A value that will not parse leaves ITS band flat and the other nine alone.
/// The jq failed the whole program on the first bad value and printed nothing,
/// so one empty slider silenced the equaliser; there is no reason for the nine
/// good sliders to be lost with it.
fn slider_gains(state: &Value) -> ([f64; SLIDERS], Vec<String>) {
    let mut gains = [0.0; SLIDERS];
    let mut bad = Vec::new();

    for (i, gain) in gains.iter_mut().enumerate() {
        let key = format!("b{}", i + 1);
        match slider_value(state.get(&key)) {
            Ok(value) => *gain = value,
            Err(why) => bad.push(format!("{key} {why}")),
        }
    }

    (gains, bad)
}

/// The frequency for a band index.
///
/// The out-of-range answer is 20000, carried over from the jq's
/// `$freqs[$i] // 20000` and the Python's `.get(i, 20000)` before it. The table
/// has exactly 32 entries and the loop runs 0..32, so it cannot fire today --
/// it is kept because the fallback is the only record of what the shape of the
/// table is allowed to be, and a 33rd band added without a frequency should get
/// an audible-range default rather than silently taking band 0's.
fn frequency_of(index: usize) -> u32 {
    FREQS.get(index).copied().unwrap_or(20000)
}

/// The gain for a band index.
///
/// Slider n drives band 3n. `index / STRIDE < SLIDERS` is what keeps band 30
/// flat: it is a multiple of three, so without the bound it would read an
/// eleventh slider that does not exist. In the jq that bound was `($i / 3) < 10`
/// over jq's floating-point division, which is the same test.
fn gain_of(index: usize, gains: &[f64; SLIDERS]) -> f64 {
    if index % STRIDE == 0 && index / STRIDE < SLIDERS {
        gains[index / STRIDE]
    } else {
        // A band no slider maps to stays flat.
        0.0
    }
}

/// The 32 bands for one set of slider values.
fn bands(gains: &[f64; SLIDERS]) -> Bands {
    let mut out = [Band {
        frequency: 0,
        gain: 0.0,
        mode: "Bell",
        mute: false,
        q: 1.0,
        solo: false,
        width: 1.0,
        slope: "x1",
    }; BANDS];

    for (i, band) in out.iter_mut().enumerate() {
        band.frequency = frequency_of(i);
        band.gain = gain_of(i, gains);
    }

    Bands(out)
}

/// The JSON document inside whatever the file actually holds.
///
/// Two kinds of stray byte the jq never had to cope with, because it was fed
/// `vals=$(cat "$STATE_FILE")` and command substitution had already removed
/// them. This binary reads the file, so it meets them, and each one cost all
/// ten sliders rather than one:
///
/// A LEADING BYTE ORDER MARK. jq's parser skips one -- it has a "Malformed
/// BOM" error of its own, so handling the well-formed case is deliberate on
/// its part -- and a state file that picked one up from an editor built the
/// preset correctly under the jq. serde_json refuses it: `expected value at
/// line 1 column 1`, which took the whole document out and left all 32 bands
/// flat with a message that says nothing about a BOM.
///
/// TRAILING NUL BYTES. `$(...)` drops NULs, so the jq was immune to them by
/// accident. A state file whose tail was left as zeros by an unclean shutdown
/// -- which is what a delayed allocation that never got its data written
/// leaves behind -- is a complete document followed by padding, and serde_json
/// rejects it as `trailing characters`. Only the TAIL is stripped: bash would
/// have deleted a NUL from the middle of the document too, but a document that
/// only parses once a byte has been removed from the middle of it is
/// corruption worth reporting rather than quietly patching over.
fn json_text(raw: &str) -> &str {
    raw.strip_prefix('\u{feff}').unwrap_or(raw).trim_end_matches('\0')
}

/// The whole preset, from the raw text of the state file.
///
/// The pure function everything else is a wrapper around: the two verbs differ
/// only in where the string comes from, and every test drives this.
fn build(raw: &str) -> Preset {
    let (state, mut problem) = match serde_json::from_str::<Value>(json_text(raw)) {
        Ok(v) if v.is_object() => (v, None),
        // Not an object -- an array, a bare string, a number. `state.get(key)`
        // would answer None for every slider and the message would then be ten
        // copies of "missing", which says nothing about the real problem.
        Ok(_) => (Value::Null, Some(Problem::document("the state file is not a JSON object"))),
        Err(e) => {
            (Value::Null, Some(Problem::document(format!("the state file is not JSON: {e}"))))
        }
    };

    let (gains, bad) = slider_gains(&state);
    if problem.is_none() && !bad.is_empty() {
        problem = Some(if bad.len() == SLIDERS {
            // All ten unusable is not ten small faults, it is a document that
            // told this program nothing -- and the flat preset below is flat
            // because it was invented, not because anybody asked for flat.
            // `{}` and `{"preset": "Flat", "pending": false}` are both valid
            // JSON objects that land here, and loading what either produces
            // resets the equaliser.
            Problem::document(format!("no slider value could be read: {}", bad.join(", ")))
        } else {
            Problem::slider(format!("slider values left flat: {}", bad.join(", ")))
        });
    }

    let bands = bands(&gains);

    Preset {
        output: Output {
            blocklist: Vec::new(),
            plugins_order: vec!["equalizer"],
            equalizer: Equalizer {
                bypass: false,
                input_gain: 0.0,
                output_gain: 0.0,
                left: bands,
                right: bands,
                mode: "IIR",
                num_bands: BANDS as u32,
                split_channels: false,
            },
        },
        error: problem,
    }
}

// ── entry ────────────────────────────────────────────────────────────────────

/// Where equalizer.sh keeps the slider values.
fn state_path() -> PathBuf {
    paths::run_dir("music").join("eq_state.json")
}

/// The state file's bytes as text, replacing anything that is not UTF-8.
///
/// Shared by both verbs on purpose, and not merely tidy. `build` used to read
/// the file with `std::fs::read_to_string`, which refuses a non-UTF-8 file
/// outright -- so a state file carrying one stray high byte (in `preset`, a
/// key this program does not even look at) failed with "stream did not contain
/// valid UTF-8" and left all ten sliders flat, while the jq before it read the
/// same file and built the preset, and `parse` -- the verb that exists to
/// check `build` against that jq -- read it through `from_utf8_lossy` and
/// agreed with the jq. The verb being verified has to be the same function of
/// the same bytes as the verb doing the verifying, or the check proves
/// nothing.
fn lossy_text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn read_stdin() -> Option<String> {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf).ok()?;
    Some(lossy_text(&buf))
}

/// Print the preset, pretty, with a trailing newline.
///
/// Pretty rather than `emit::json`'s compact line, which is the one place this
/// departs from the house rule, and for a reason the rule does not cover: this
/// stdout is not read by QML. It is redirected into `live_eq.json`, which
/// EasyEffects reads and rewrites -- pretty-printed, two spaces -- whenever a
/// person touches the preset in its own interface. The jq printed pretty too,
/// so keeping it means a diff between this and the program it replaces is the
/// gains and nothing else.
fn print_preset(preset: &Preset) -> bool {
    let mut text = match serde_json::to_string_pretty(preset) {
        Ok(t) => t,
        Err(e) => {
            // Serialising our own fixed-shape struct failed, which is a bug
            // rather than a condition. Nothing usable was printed.
            eprintln!("jayos-equalizer-preset: could not serialise the preset: {e}");
            return false;
        }
    };
    text.push('\n');

    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    match out.write_all(text.as_bytes()).and_then(|()| out.flush()) {
        Ok(()) => true,
        // The caller stopped reading, so there is nothing on the far end to
        // load and nothing to report.
        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => true,
        Err(e) => {
            eprintln!("jayos-equalizer-preset: could not write the preset: {e}");
            false
        }
    }
}

/// At least one slider was unusable and its band is flat; the sliders that did
/// parse carry the user's own gains, so this preset is still the best answer
/// available and the caller should load it.
const EXIT_BAND_FLAT: u8 = 1;

/// Nothing was read, so every gain printed was invented here. The caller must
/// not load it.
const EXIT_NOTHING_READ: u8 = 2;

/// Print, and say in the exit status how much of the preset came from the state
/// file.
///
/// Exit zero means the answer is trustworthy, not that the program ran, and the
/// two non-zero statuses are not interchangeable: `b3 = "abc"` is nine good
/// sliders and one flat band, which is worth loading, while a state file that
/// is not JSON is 32 invented zeros, which is the user's curve wiped. Both used
/// to be `ExitCode::FAILURE` and equalizer.sh, unable to tell them apart, ran
/// `easyeffects -l` for both.
fn finish(preset: &Preset) -> ExitCode {
    if let Some(problem) = &preset.error {
        eprintln!("jayos-equalizer-preset: {}", problem.message);
    }

    if !print_preset(preset) {
        // Whatever reached the far end is a truncated preset, so it is in the
        // same class as an invented one: not loadable. Saying `1` here would
        // tell the script to move half a JSON document over live_eq.json.
        return ExitCode::from(EXIT_NOTHING_READ);
    }

    ExitCode::from(status_of(preset))
}

/// The exit status for a preset that was printed in full.
///
/// Split out from `finish` so the mapping is a pure function with tests, rather
/// than something only reachable by running the binary and reading `$?`. This
/// is the contract equalizer.sh is written against.
fn status_of(preset: &Preset) -> u8 {
    match preset.error.as_ref().map(|p| p.kind) {
        None => 0,
        Some(Fault::Slider) => EXIT_BAND_FLAT,
        Some(Fault::Document) => EXIT_NOTHING_READ,
    }
}

fn main() -> ExitCode {
    let args = Args::from_env();

    match args.command_or("build") {
        "build" => {
            let path = args.positional(0).map(PathBuf::from).unwrap_or_else(state_path);
            // An unreadable state file is reported as its own error rather
            // than as ten missing sliders. A complete flat preset is still
            // printed, because a caller that redirects stdout to a file should
            // never be handed half a document -- but it exits 2, so the caller
            // knows the file it has is invented and leaves the running curve
            // alone.
            let raw = match std::fs::read(&path).map(|bytes| lossy_text(&bytes)) {
                Ok(text) => text,
                Err(e) => {
                    let mut preset = build("");
                    preset.error =
                        Some(Problem::document(format!("cannot read {}: {e}", path.display())));
                    return finish(&preset);
                }
            };
            finish(&build(&raw))
        }

        "parse" => match read_stdin() {
            Some(text) => finish(&build(&text)),
            None => {
                let mut preset = build("");
                preset.error = Some(Problem::document("could not read stdin"));
                finish(&preset)
            }
        },

        other => emit::unknown_command(&args.program, other, &["build", "parse"]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── fixtures ─────────────────────────────────────────────────────────────

    /// The default state file, byte for byte as equalizer.sh writes it when
    /// there is none. Bare NUMBERS.
    const DEFAULT_STATE: &str = r#"{"b1": 0, "b2": 0, "b3": 0, "b4": 0, "b5": 0, "b6": 0, "b7": 0, "b8": 0, "b9": 0, "b10": 0, "preset": "Flat", "pending": false}"#;

    /// What `save_preset 5 7 5 2 1 0 0 0 1 2 "Bass"` leaves behind: every value
    /// a STRING, because it is built with `jq --arg`.
    const BASS_STATE: &str = r#"{"b1":"5","b2":"7","b3":"5","b4":"2","b5":"1","b6":"0","b7":"0","b8":"0","b9":"1","b10":"2","preset":"Bass","pending":false}"#;

    /// A default file after one `set_band 3 -4`: nine numbers and one string,
    /// which is the normal state of the file part-way through a session.
    const MIXED_STATE: &str = r#"{"b1":0,"b2":0,"b3":"-4","b4":0,"b5":0,"b6":0,"b7":0,"b8":0,"b9":0,"b10":0,"preset":"Custom","pending":true}"#;

    /// A state file with the ten sliders set to a given list, as strings.
    fn state_of(values: &[&str]) -> String {
        let body: Vec<String> =
            values.iter().enumerate().map(|(i, v)| format!("\"b{}\":{v}", i + 1)).collect();
        format!("{{{}}}", body.join(","))
    }

    fn left(preset: &Preset) -> [Band; BANDS] {
        preset.output.equalizer.left.0
    }

    fn text(raw: &str) -> String {
        serde_json::to_string_pretty(&build(raw)).unwrap()
    }

    /// The sentence in the `error` key, for a preset that has one.
    fn why(preset: &Preset) -> String {
        preset.error.as_ref().expect("a problem was expected").message.clone()
    }

    /// Which of the two failures a preset carries -- what the exit status is
    /// made of, and the thing equalizer.sh acts on.
    fn kind(preset: &Preset) -> Option<Fault> {
        preset.error.as_ref().map(|p| p.kind)
    }

    // ── the band mapping ─────────────────────────────────────────────────────

    #[test]
    fn slider_n_drives_band_three_n() {
        // The mapping the whole program exists to preserve. Ten distinct
        // values, so a band reading the wrong slider cannot pass by accident.
        let preset = build(&state_of(&["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]));
        let bands = left(&preset);
        for slider in 0..SLIDERS {
            assert_eq!(
                bands[slider * STRIDE].gain,
                (slider + 1) as f64,
                "slider {} belongs to band {}",
                slider + 1,
                slider * STRIDE
            );
        }
    }

    #[test]
    fn the_twenty_two_bands_no_slider_maps_to_sit_at_unity_gain() {
        let preset = build(&state_of(&["9"; SLIDERS]));
        let bands = left(&preset);
        let flat: Vec<usize> = (0..BANDS).filter(|i| bands[*i].gain == 0.0).collect();
        assert_eq!(flat.len(), 22, "22 bands are not driven by any slider: {flat:?}");
        for i in flat {
            assert!(i % STRIDE != 0 || i / STRIDE >= SLIDERS, "band {i} should have a slider");
        }
    }

    #[test]
    fn band_thirty_is_flat_even_though_it_is_a_multiple_of_three() {
        // The `< 10` bound in the jq. Without it, band 30 reads an eleventh
        // slider that does not exist -- in the jq that was `null`, which made
        // the whole preset fail to build.
        let preset = build(&state_of(&["6"; SLIDERS]));
        assert_eq!(left(&preset)[30].gain, 0.0);
        assert_eq!(left(&preset)[27].gain, 6.0, "band 27 is the last one with a slider");
    }

    #[test]
    fn there_are_exactly_thirty_two_bands() {
        let preset = build(DEFAULT_STATE);
        assert_eq!(left(&preset).len(), BANDS);
        assert_eq!(preset.output.equalizer.num_bands, 32);
    }

    // ── the frequency table ──────────────────────────────────────────────────

    #[test]
    fn the_frequency_table_is_the_one_the_saved_presets_were_built_from() {
        let preset = build(DEFAULT_STATE);
        let got: Vec<u32> = left(&preset).iter().map(|b| b.frequency).collect();
        assert_eq!(
            got,
            vec![
                32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
                1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000, 22000,
                24000, 24000
            ]
        );
    }

    #[test]
    fn indices_thirty_and_thirty_one_are_both_twenty_four_thousand() {
        // The duplicate in the original table, kept deliberately: EasyEffects
        // wants exactly 32 entries and both of these are above anything
        // audible. Removing it would shift every band above 20000.
        assert_eq!(frequency_of(30), 24000);
        assert_eq!(frequency_of(31), 24000);
    }

    #[test]
    fn a_band_past_the_end_of_the_table_falls_back_to_twenty_thousand() {
        // Unreachable with 32 bands, and the jq's `// 20000` and the Python's
        // `.get(i, 20000)` both carried it. It records what a band with no
        // frequency is allowed to be, rather than letting one take band 0's.
        assert_eq!(frequency_of(BANDS), 20000);
        assert_eq!(frequency_of(999), 20000);
    }

    // ── both shapes of the state file ────────────────────────────────────────

    #[test]
    fn slider_values_may_be_bare_numbers() {
        // The default file the script writes has numbers.
        let preset = build(DEFAULT_STATE);
        assert!(left(&preset).iter().all(|b| b.gain == 0.0));
        assert_eq!(preset.error, None);
    }

    #[test]
    fn slider_values_may_be_strings() {
        // save_preset builds the file with `jq --arg`, so every value in it is
        // a string. A reader that took only numbers would drop every preset
        // click.
        let preset = build(BASS_STATE);
        let bands = left(&preset);
        assert_eq!(bands[0].gain, 5.0);
        assert_eq!(bands[3].gain, 7.0);
        assert_eq!(bands[27].gain, 2.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn one_state_file_may_mix_strings_and_numbers() {
        // set_band rewrites ONE key as a string and leaves the rest as they
        // were, so a file half-way through a session is a mixture.
        let preset = build(MIXED_STATE);
        assert_eq!(left(&preset)[6].gain, -4.0, "b3 drives band 6");
        assert_eq!(left(&preset)[0].gain, 0.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn whitespace_around_a_string_value_is_trimmed() {
        // jq's tonumber trims and f64::from_str does not, so `" 5 "` parses
        // there and would have failed here.
        let preset = build(&state_of(&["\" 5 \"", "0", "0", "0", "0", "0", "0", "0", "0", "0"]));
        assert_eq!(left(&preset)[0].gain, 5.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn a_leading_plus_or_leading_zero_parses_as_jq_parsed_it() {
        let preset =
            build(&state_of(&["\"+5\"", "\"05\"", "0", "0", "0", "0", "0", "0", "0", "0"]));
        assert_eq!(left(&preset)[0].gain, 5.0);
        assert_eq!(left(&preset)[3].gain, 5.0);
    }

    #[test]
    fn a_negative_slider_survives() {
        // The Treble preset opens with -2, so this is the ordinary case rather
        // than an edge one.
        let preset =
            build(&state_of(&["\"-2\"", "\"-1\"", "0", "1", "2", "3", "4", "5", "6", "6"]));
        assert_eq!(left(&preset)[0].gain, -2.0);
        assert_eq!(left(&preset)[3].gain, -1.0);
    }

    #[test]
    fn a_fractional_gain_survives() {
        // The popup rounds, but the state file is editable by hand and jq's
        // tonumber kept the fraction.
        let preset = build(&state_of(&["\"2.5\"", "0", "0", "0", "0", "0", "0", "0", "0", "0"]));
        assert_eq!(left(&preset)[0].gain, 2.5);
    }

    #[test]
    fn keys_other_than_the_sliders_are_ignored() {
        // `preset` and `pending` live in the same file and are the popup's,
        // not the preset builder's.
        assert_eq!(build(DEFAULT_STATE), build(&state_of(&["0"; SLIDERS])));
    }

    // ── the number formatting this port fixes ────────────────────────────────

    #[test]
    fn a_whole_number_gain_is_written_with_a_decimal_point() {
        // THE POINT OF THE PORT. The jq wrote `"gain": 0` and recorded that it
        // could not do otherwise; the Python wrote `0.0`, and so does
        // EasyEffects when it saves a preset from its own interface.
        let out = text(BASS_STATE);
        assert!(out.contains("\"gain\": 5.0"), "a driven band: {out}");
        assert!(out.contains("\"gain\": 0.0"), "an undriven band: {out}");
        assert!(!out.contains("\"gain\": 5,"), "no bare integer gain");
        assert!(!out.contains("\"gain\": 0,"), "no bare integer gain");
    }

    #[test]
    fn a_fractional_gain_is_not_padded() {
        let out = text(&state_of(&["\"2.5\"", "0", "0", "0", "0", "0", "0", "0", "0", "0"]));
        assert!(out.contains("\"gain\": 2.5"), "{out}");
    }

    #[test]
    fn the_fixed_floats_keep_their_decimal_point() {
        // jq 1.7 preserved these literals, so they already read `1.0` and
        // `0.0` in the file EasyEffects has today.
        let out = text(DEFAULT_STATE);
        assert!(out.contains("\"input-gain\": 0.0"), "{out}");
        assert!(out.contains("\"output-gain\": 0.0"), "{out}");
        assert!(out.contains("\"q\": 1.0"), "{out}");
        assert!(out.contains("\"width\": 1.0"), "{out}");
    }

    #[test]
    fn the_frequency_stays_an_integer() {
        // Only the gain differed between the Python and the jq, so both wrote
        // the frequency as an integer -- as does every preset this script has
        // already left on disk.
        let out = text(DEFAULT_STATE);
        assert!(out.contains("\"frequency\": 32,"), "{out}");
        assert!(out.contains("\"frequency\": 24000,"), "{out}");
        assert!(!out.contains("\"frequency\": 32.0"), "{out}");
    }

    // ── the shape of the file ────────────────────────────────────────────────

    #[test]
    fn band_keys_come_out_in_band_order_not_lexicographic_order() {
        // A BTreeMap would give band0, band1, band10 ... band19, band2, which
        // EasyEffects loads perfectly well and nobody can diff.
        let out = text(DEFAULT_STATE);
        let at = |k: &str| out.find(k).unwrap_or_else(|| panic!("{k} missing from {out}"));
        assert!(at("\"band9\"") < at("\"band10\""), "band9 before band10");
        assert!(at("\"band2\"") < at("\"band10\""), "band2 before band10");
        assert!(at("\"band30\"") < at("\"band31\""), "band30 before band31");
    }

    #[test]
    fn the_field_order_matches_the_program_this_replaces() {
        let out = text(DEFAULT_STATE);
        let order = [
            "\"output\"",
            "\"blocklist\"",
            "\"plugins_order\"",
            "\"equalizer\"",
            "\"bypass\"",
            "\"input-gain\"",
            "\"output-gain\"",
            "\"left\"",
        ];
        let mut last = 0;
        for key in order {
            let at = out.find(key).unwrap_or_else(|| panic!("{key} missing from {out}"));
            assert!(at >= last, "{key} is out of order");
            last = at;
        }
        // right, mode, num-bands and split-channels come after the two band
        // maps, so they are checked from the tail rather than by first find --
        // "mode" also appears inside every band.
        let tail = &out[out.rfind("\"right\"").unwrap()..];
        assert!(tail.find("\"mode\": \"IIR\"") < tail.find("\"num-bands\""));
        assert!(tail.find("\"num-bands\"") < tail.find("\"split-channels\""));
    }

    #[test]
    fn both_channels_carry_the_same_bands() {
        // split-channels is false, so EasyEffects reads left -- but it wants
        // both keys and refuses a preset with one missing.
        let preset = build(BASS_STATE);
        assert_eq!(preset.output.equalizer.left, preset.output.equalizer.right);
        assert!(!preset.output.equalizer.split_channels);
    }

    #[test]
    fn every_band_carries_the_fixed_fields() {
        let preset = build(BASS_STATE);
        for (i, band) in left(&preset).iter().enumerate() {
            assert_eq!(band.mode, "Bell", "band {i}");
            assert!(!band.mute, "band {i}");
            assert!(!band.solo, "band {i}");
            assert_eq!(band.q, 1.0, "band {i}");
            assert_eq!(band.width, 1.0, "band {i}");
            assert_eq!(band.slope, "x1", "band {i}");
        }
    }

    #[test]
    fn the_chain_names_only_the_equaliser() {
        let preset = build(DEFAULT_STATE);
        assert_eq!(preset.output.plugins_order, vec!["equalizer"]);
        assert!(preset.output.blocklist.is_empty());
        assert!(!preset.output.equalizer.bypass);
        assert!(text(DEFAULT_STATE).contains("\"blocklist\": []"));
    }

    // ── failures still print a whole preset ──────────────────────────────────

    #[test]
    fn a_good_preset_has_no_error_key_at_all() {
        // So that a working build stays byte-comparable with the jq's output.
        assert_eq!(build(DEFAULT_STATE).error, None);
        assert!(!text(DEFAULT_STATE).contains("error"));
    }

    #[test]
    fn a_non_numeric_slider_leaves_that_band_flat_and_names_it() {
        let preset = build(&state_of(&["\"abc\"", "3", "0", "0", "0", "0", "0", "0", "0", "0"]));
        assert_eq!(left(&preset)[0].gain, 0.0);
        assert!(why(&preset).contains("b1"), "{:?}", preset.error);
        assert_eq!(kind(&preset), Some(Fault::Slider), "nine sliders were still read");
    }

    #[test]
    fn one_bad_slider_does_not_lose_the_other_nine() {
        // The jq failed the whole program on the first bad value and printed
        // nothing, so one empty slider left a truncated file and silenced the
        // equaliser.
        let preset = build(&state_of(&["\"\"", "1", "2", "3", "4", "5", "6", "7", "8", "9"]));
        assert_eq!(left(&preset)[0].gain, 0.0, "the bad one is flat");
        assert_eq!(left(&preset)[3].gain, 1.0, "the good ones are kept");
        assert_eq!(left(&preset)[27].gain, 9.0);
        assert!(preset.error.is_some());
    }

    #[test]
    fn an_empty_slider_value_is_not_a_number() {
        // `"" | tonumber` is a jq error, not zero.
        assert_eq!(slider_value(Some(&Value::String(String::new()))), Err("empty"));
        assert_eq!(slider_value(Some(&Value::String("   ".into()))), Err("empty"));
    }

    #[test]
    fn a_missing_slider_is_named_rather_than_taken_as_zero() {
        // jq's `null | tonumber` errored and took the whole preset with it.
        let preset = build(r#"{"b1": 4}"#);
        assert_eq!(left(&preset)[0].gain, 4.0);
        assert_eq!(left(&preset)[3].gain, 0.0);
        let error = why(&preset);
        assert!(error.contains("b2 missing"), "{error}");
        assert!(error.contains("b10 missing"), "{error}");
        // b1 was read, so the preset is one real gain and nine flat bands --
        // still the user's own b1, and still worth loading.
        assert_eq!(kind(&preset), Some(Fault::Slider));
    }

    #[test]
    fn a_null_or_boolean_slider_is_not_a_number() {
        assert_eq!(slider_value(Some(&Value::Null)), Err("missing"));
        assert_eq!(slider_value(Some(&Value::Bool(true))), Err("not a number"));
        assert_eq!(slider_value(Some(&serde_json::json!([1]))), Err("not a number"));
    }

    #[test]
    fn a_non_finite_slider_is_refused() {
        // f64::from_str accepts "inf", "infinity" and "NaN", and an
        // overflowing literal saturates to infinity. serde_json writes a
        // non-finite float as `null`, and a null gain is the one value that
        // makes EasyEffects reject the whole preset -- so it is refused here
        // and the band stays flat.
        for value in ["\"inf\"", "\"infinity\"", "\"NaN\"", "\"-inf\"", "\"1e400\""] {
            let preset = build(&state_of(&[value, "0", "0", "0", "0", "0", "0", "0", "0", "0"]));
            assert_eq!(left(&preset)[0].gain, 0.0, "{value}");
            assert!(preset.error.is_some(), "{value}");
            assert!(!text(&state_of(&[value, "0", "0", "0", "0", "0", "0", "0", "0", "0"]))
                .contains("\"gain\": null"));
        }
    }

    #[test]
    fn text_that_is_not_json_still_gives_a_loadable_preset() {
        // The state file has been found truncated after a logout, and the jq
        // answered that with an empty preset file that EasyEffects refused.
        let preset = build("{\"b1\": 0, \"b2\"");
        assert_eq!(left(&preset).len(), BANDS);
        assert!(left(&preset).iter().all(|b| b.gain == 0.0), "flat is the safe answer");
        assert!(why(&preset).contains("not JSON"));
        assert_eq!(kind(&preset), Some(Fault::Document), "nothing here was read");
    }

    #[test]
    fn a_leading_byte_order_mark_is_not_a_broken_state_file() {
        // Found by running this against the jq it replaces. jq skips a BOM and
        // built the preset; serde_json answers `expected value at line 1
        // column 1`, so a state file that picked one up from an editor lost
        // all ten sliders at once rather than none.
        let preset = build(&format!("\u{feff}{BASS_STATE}"));
        assert_eq!(left(&preset)[0].gain, 5.0);
        assert_eq!(left(&preset)[3].gain, 7.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn nul_padding_on_the_tail_does_not_lose_the_sliders() {
        // The jq was fed `$(cat "$STATE_FILE")` and command substitution drops
        // NULs, so it never saw these; this reads the file, so it does. A tail
        // of zeros is what an unclean shutdown leaves on a file whose data
        // never reached the disk, and serde_json calls it `trailing
        // characters` -- which flattened all ten sliders over padding that
        // carries no information.
        let preset = build(&format!("{BASS_STATE}\0\0\0\0"));
        assert_eq!(left(&preset)[0].gain, 5.0);
        assert_eq!(left(&preset)[27].gain, 2.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn a_nul_in_the_middle_of_the_document_is_still_reported() {
        // bash would have deleted this one too, so the jq would have built a
        // preset from it. Not copied: a document that only parses once a byte
        // has been removed from the middle of it is corruption, and silently
        // repairing it hides the fact that the file is damaged.
        let preset = build(&BASS_STATE.replace("\"b5\"", "\"b\u{0}5\""));
        assert!(why(&preset).contains("not JSON"));
    }

    #[test]
    fn a_state_file_that_is_not_valid_utf8_still_reads_its_sliders() {
        // A stray high byte in `preset` -- a key this program does not read at
        // all. The jq built the preset from it, and so did `parse`; `build`
        // was the only one of the three that answered "stream did not contain
        // valid UTF-8" and flattened all ten sliders, because it alone used
        // read_to_string.
        let mut bytes = br#"{"b1":7,"b2":0,"b3":0,"b4":0,"b5":0,"b6":0,"b7":0,"b8":0,"b9":0,"b10":0,"preset":"caf"#
            .to_vec();
        bytes.push(0xe9); // latin-1 'é', which is not valid UTF-8 on its own
        bytes.extend_from_slice(br#""}"#);

        let preset = build(&lossy_text(&bytes));
        assert_eq!(left(&preset)[0].gain, 7.0);
        assert_eq!(preset.error, None);
    }

    #[test]
    fn an_empty_state_file_still_gives_a_loadable_preset() {
        let preset = build("");
        assert_eq!(left(&preset).len(), BANDS);
        assert!(preset.error.is_some());
    }

    #[test]
    fn a_number_literal_only_jq_would_accept_costs_the_whole_document() {
        // A KNOWN BOUNDARY, pinned so nobody has to rediscover it by reading
        // serde_json. jq's parser takes `.5`, `5.`, `05`, `+5`, `nan` and an
        // out-of-range `1e400` as bare literals; RFC 8259 does not, and
        // serde_json fails the whole document rather than the one value -- so
        // here, and only here, ONE bad slider does cost the other nine, which
        // is what every other failure path in this file exists to avoid.
        //
        // Left alone on purpose. Nothing in the running system can write one:
        // the default file the script echoes holds bare `0`, and save_preset
        // and set_band both build the file with jq, which emits strict JSON --
        // so a literal like this needs a hand edit, and the next slider move
        // rewrites the file strictly again. Recovering the nine would mean
        // splitting the document up before parsing it, which is a second,
        // hand-written JSON parser to maintain for a case the script cannot
        // reach. The preset printed is still complete, flat and loadable, the
        // reason is named, and the exit is non-zero.
        for literal in [".5", "5.", "05", "+5", "nan", "1e400"] {
            let preset = build(&format!("{{\"b1\":{literal},\"b2\":3}}"));
            assert_eq!(left(&preset)[0].gain, 0.0, "{literal}");
            assert_eq!(left(&preset)[3].gain, 0.0, "b2 is lost with it: {literal}");
            assert_eq!(left(&preset).len(), BANDS, "{literal}");
            assert!(why(&preset).contains("not JSON"), "{literal}");
        }
        // The same values as STRINGS are what the script actually writes, and
        // those are read one at a time: b2 survives.
        let preset = build(r#"{"b1":".5","b2":"3"}"#);
        assert_eq!(left(&preset)[0].gain, 0.5);
        assert_eq!(left(&preset)[3].gain, 3.0);
    }

    #[test]
    fn json_that_is_not_an_object_is_reported_as_such() {
        // Otherwise the message is ten copies of "missing", which says nothing
        // about what actually went wrong.
        let preset = build("[1,2,3]");
        let error = why(&preset);
        assert!(error.contains("not a JSON object"), "{error}");
        assert!(!error.contains("b1"), "{error}");
    }

    #[test]
    fn the_error_sits_beside_output_rather_than_inside_it() {
        // EasyEffects reads `output` and ignores keys it does not know, so a
        // preset carrying an error is still loadable; putting the error inside
        // the plugin chain would not be.
        let out = text("nonsense");
        let value: Value = serde_json::from_str(&out).unwrap();
        assert!(value["output"]["equalizer"]["left"]["band0"].is_object());
        assert!(value["error"].is_string());
        assert!(value["output"]["error"].is_null());
    }

    // ── the two failures the caller has to tell apart ────────────────────────

    #[test]
    fn one_bad_slider_and_an_unreadable_file_do_not_share_an_exit_status() {
        // THE POINT OF THE STATUSES, in one test. Both of these print a
        // complete 32-band preset and both used to exit 1, so equalizer.sh --
        // which could only see "non-zero" -- loaded both. The second one is 32
        // invented zeros, and loading it reset whatever the user was listening
        // to.
        let one_bad = build(&state_of(&["\"abc\"", "1", "2", "3", "4", "5", "6", "7", "8", "9"]));
        let unreadable = build("not json at all");

        assert_eq!(status_of(&one_bad), EXIT_BAND_FLAT, "nine sliders are the user's own");
        assert_eq!(status_of(&unreadable), EXIT_NOTHING_READ, "every gain here is invented");
        assert_ne!(status_of(&one_bad), status_of(&unreadable));

        // And the loadable one really does still carry the user's gains, which
        // is why it is worth loading rather than refusing.
        assert_eq!(left(&one_bad)[3].gain, 1.0);
        assert_eq!(left(&one_bad)[27].gain, 9.0);
    }

    #[test]
    fn a_preset_built_from_every_slider_exits_zero() {
        assert_eq!(status_of(&build(DEFAULT_STATE)), 0);
        assert_eq!(status_of(&build(BASS_STATE)), 0);
        assert_eq!(status_of(&build(MIXED_STATE)), 0);
    }

    #[test]
    fn every_way_of_reading_nothing_exits_two() {
        // Each of these produces a preset that is flat because this program
        // invented it, not because anybody asked for flat -- so each one must
        // stop the caller before it loads the preset (equalizer.sh returns on
        // a status of 2 or more, ahead of both loads: `easyeffects -l` on
        // 7.x and the socket's load_preset on 8.x).
        for raw in [
            "",                   // an empty state file
            "not json at all",    // a truncated or overwritten one
            "{\"b1\": 0, \"b2\"", // a half-written one
            "[1,2,3]",            // JSON, but not the shape this reads
            "\"Flat\"",           // ditto
        ] {
            assert_eq!(status_of(&build(raw)), EXIT_NOTHING_READ, "{raw:?}");
            assert_eq!(kind(&build(raw)), Some(Fault::Document), "{raw:?}");
        }
    }

    #[test]
    fn an_object_with_no_readable_slider_is_a_document_fault_not_ten_slider_faults() {
        // `{}` is valid JSON and a valid object, so the parse succeeded and
        // every band still came out flat by invention. Counting it as ten
        // separate slider faults would exit 1 and the curve would be reset by a
        // file that says nothing at all about the sliders.
        for raw in [r#"{}"#, r#"{"preset": "Flat", "pending": false}"#, r#"{"b1": "abc"}"#] {
            let preset = build(raw);
            assert_eq!(kind(&preset), Some(Fault::Document), "{raw}");
            assert_eq!(status_of(&preset), EXIT_NOTHING_READ, "{raw}");
            assert!(why(&preset).contains("no slider value could be read"), "{raw}");
        }

        // One slider surviving is the whole difference: that gain is the
        // user's, so the preset is worth loading with the rest flat.
        let preset = build(r#"{"b1": 6}"#);
        assert_eq!(kind(&preset), Some(Fault::Slider));
        assert_eq!(status_of(&preset), EXIT_BAND_FLAT);
        assert_eq!(left(&preset)[0].gain, 6.0);
    }

    #[test]
    fn a_state_file_that_cannot_be_opened_is_a_document_fault() {
        // What `main` builds when `fs::read` fails -- a missing state file, a
        // directory in its place, a permission error. Nothing was read, so the
        // preset is invented.
        let mut preset = build("");
        preset.error = Some(Problem::document("cannot read /nope/eq_state.json: no such file"));
        assert_eq!(status_of(&preset), EXIT_NOTHING_READ);
    }

    #[test]
    fn the_error_key_is_still_the_plain_string_it_has_always_been() {
        // The kind travels as the exit status, NOT as a new key: EasyEffects
        // rewrites this file from its own interface and a preset it wrote back
        // should still diff cleanly against one this wrote.
        let out = text("nonsense");
        let value: Value = serde_json::from_str(&out).unwrap();
        assert!(value["error"].is_string(), "{out}");
        assert!(value["kind"].is_null(), "no second key appeared: {out}");
        assert!(!out.contains("Document"), "the fault kind is not in the file: {out}");
    }
}
