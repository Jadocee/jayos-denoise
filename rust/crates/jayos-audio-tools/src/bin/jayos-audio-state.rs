//! The volume popup's devices, microphones and playback streams, paused ones included.
//!
//!     jayos-audio-state                  sinks, sources and sink-inputs, as JSON
//!     jayos-audio-state master sink      the output the volume controls act on
//!     jayos-audio-state master source    the input a microphone control acts on
//!
//! Bare, it is the volume popup's poll: VolumePopup.qml runs it from a
//! `Process` and re-runs it once a second for as long as the popup is open.
//! `master` is every OTHER volume control's question, answered the way the
//! popup's hero answers it -- see MASTER below.
//!
//! THE SHAPE, AND WHO READS EACH PART OF IT
//!
//! `{"outputs": [...], "inputs": [...], "apps": [...], "cookie": "..."}`, and
//! every list holds the same node object. `processAudioJson` reads the three
//! lists and feeds each to `syncModel`, so all three must be present even when
//! empty -- `data.outputs || []` covers an absent key, but a RENAMED one is a
//! tab that silently stays empty.
//!
//!   cookie       the sound server's cookie from `pactl -f json info`, read
//!                BEFORE the lists, or "" when it did not answer. The popup
//!                passes it back with every id it writes to, and
//!                audio_control.sh refuses an id whose cookie is not the live
//!                one: an id is an object serial, and a restarted server
//!                numbers its nodes afresh, so an id held across a restart
//!                names another node. Read first because a restart between the
//!                lists and the cookie would pair old ids with the new cookie.
//!
//! Within a node, every key but `icon` has a reader in VolumePopup.qml, and
//! `syncModel` copies every key into the row -- tools/test-volume-popup.sh
//! holds the node's fields, `syncModel`'s keys and the delegate's reads in
//! step:
//!
//!   id           the pactl index, as a string. `syncModel` matches rows by it
//!                across polls, so a row keeps its place instead of being
//!                destroyed and rebuilt every second, and audio_control.sh
//!                passes it to `pactl set-sink-volume` / `set-source-volume` /
//!                `set-sink-input-volume` -- the hero's slider and orb included,
//!                which act on the id of the row the hero shows.
//!   name         the node name, passed to `pactl set-default-sink|source`
//!                when a row is clicked -- so this is the node name pactl
//!                accepts, NOT a pretty label. For a stream, its track.
//!   description  the pretty label, drawn as the row's title and as the hero
//!                text for whichever node is default.
//!   volume       an integer percent. The slider binds to it.
//!   mute         drives the mute glyph and the hero orb's red state.
//!   is_default   picks the hero node and draws the "Active Default" badge. A
//!                sink's monitor is an input row only while it is the default
//!                source: then it is what a recorder hears, and the hero has
//!                to show the node its controls act on.
//!   icon         an icon-theme name: application.icon_name, then
//!                device.icon_name, else "audio-card". `syncModel` copies it
//!                into each row and NOTHING DRAWS IT -- the row delegate picks
//!                a Nerd Font glyph from the tab and the description instead.
//!                Kept rather than dropped because it costs nothing, and a
//!                delegate that wanted theme icons would need only itself
//!                changed.
//!   inert        this device's own volume and mute reach nothing anyone
//!                hears: one of EasyEffects' virtual devices with its "monitor
//!                channel volumes" off, which is EasyEffects' default (see
//!                jayos_core::pw_route). The row draws no slider or mute for it.
//!   via          for an inert row that is the DEFAULT, the id of the listed
//!                row its sound actually reaches -- the speakers after
//!                EasyEffects' output chain, the microphone before its input
//!                chain -- and "" for every other row or when nothing
//!                resolves. The hero's slider and orb act on that row, since
//!                acting on the default itself would change nothing.
//!   detail       what the row and the hero say under the title, or "" for
//!                nothing: a device's bus as a person names it -- "USB",
//!                "Bluetooth", "HDMI 3" -- where its properties or its node
//!                name say it, and a stream's track, unless that is a name
//!                its program gives every stream; never a repeat of the title.
//!                The node names that stood there --
//!                `alsa_output.usb-Schiit_Audio_...`,
//!                `bluez_output.AC_80_0A_1F_33_5E.1` -- were pactl's, not the
//!                person's. See [`detail_of`].
//!
//! Array order is on-screen order: `syncModel` moves existing rows to match the
//! order of the array it is given.
//!
//! `apps` is every playback stream -- every sink-input -- and a paused one is
//! listed exactly like a playing one: a player that pauses corks its stream
//! rather than closing it, and the row stays so its volume can be set before it
//! resumes. Recording streams (source-outputs) are never listed at all.
//!
//! WHY WPCTL DECIDES WHAT IS DEFAULT, AND PACTL ONLY BACKS IT UP
//!
//! Under PipeWire, `pactl info` reports the default through the pulse
//! compatibility layer, which does not always agree with WirePlumber about
//! which node is actually the default -- and when it disagrees, no row in the
//! list matches, so the popup shows no "Active Default" and the hero falls back
//! to whatever happens to be first. `wpctl inspect @DEFAULT_AUDIO_SINK@` asks
//! the thing that decides. `pactl info` is the fallback for when wpctl is
//! missing or WirePlumber is not running.
//!
//! One answer of wpctl's is translated rather than taken. When a sink's
//! monitor is the default source, WirePlumber records the SINK's node name,
//! so `wpctl inspect @DEFAULT_AUDIO_SOURCE@` prints `media.class =
//! "Audio/Sink"` and the sink's name (RUN: WirePlumber 0.4.17; `pactl info`
//! named `alsa_input.fake_mic_sink.monitor` at the same moment). The source a
//! recorder hears is that sink's monitor, which is what pactl lists and what
//! audio_control.sh's writes reach, so an `Audio/Sink` answer for the source
//! reads as `<name>.monitor` -- see [`default_from_inspect`].
//!
//! Asking wpctl does not remove the other way to get the same symptom: the
//! lists and the defaults are two snapshots taken a few milliseconds apart.
//! The lists come first, so a headset plugged in and made default between the
//! two is named by wpctl and missing from the list, and that poll marks no row
//! (RUN against PipeWire 1.0.5: a sink created and made default while the
//! helper ran left 49 and 51 of 60 polls with no default marked, in two runs;
//! with the re-list below, 0 of 60). Asking wpctl first would only move the
//! race to unplugs. So a kind whose non-empty default names no listed node is
//! listed ONCE more, after the defaults are known -- never in a loop, and
//! without asking for the default again, which would reopen the window from
//! the other side. See `listed_too_early`.
//!
//! MASTER: THE NODE THAT IS HEARD, FOR EVERY OTHER SURFACE
//!
//! `jayos-audio-state master sink` prints one line of JSON naming the node a
//! volume control should act on, and what it reads:
//!
//!   {"name":"alsa_output.usb-headset","object_id":"31","description":"USB Headset",
//!    "volume":55,"mute":false,"default":"easyeffects_sink"}
//!
//!   name         the node name, which is what pactl takes
//!   object_id    the PipeWire object id, which is what wpctl takes -- NOT
//!                pactl's index, which is the object serial: `wpctl
//!                set-volume 46`, 46 being the speakers' pactl index, moved
//!                the headphones, whose object id is 46 (RUN, WirePlumber
//!                0.4.17). "" when pactl printed none, and for a sink's
//!                monitor, whose object.id is its sink's.
//!   description, volume, mute
//!                that node's: its first channel as a whole percent, which
//!                is what a popup row shows and what `wpctl get-volume`
//!                prints for it
//!   default      the default it was resolved from
//!
//! `name` is `default` unless the default is one of EasyEffects' inert
//! virtual devices (`inert` above). Then it is the device behind it, found by
//! the same `behind` and the same rule as the popup's `via` -- listed, and not
//! inert itself -- so the hero and every other control name one device. When
//! nothing is found the answer is a failure (`{"ok":false,"error":...}`,
//! exit 1), never the virtual device: a control that moves a node nobody hears
//! is the defect this mode exists to end. No default at all is a failure too;
//! a verb or side this does not know exits 2.
//!
//! A LIVE DEFAULT IS WPCTL'S ALONE TO ANSWER. `wpctl inspect` of the default
//! is asked first, and when it prints a node whose own level works -- one of
//! the side's own media class, and not inert by [`pw_route::inert`] -- that
//! node is the answer: its object id from the `id N` line, its level and mute
//! from `wpctl get-volume N`. Two wpctl calls, and no pactl at all. This asked
//! pactl's list first, so a hardware default needed pipewire-pulse to answer,
//! where every surface asking had needed wpctl alone: with pipewire-pulse
//! killed the volume keys changed nothing and the bar read "--" over a default
//! wpctl could act on, and with it SIGSTOPped each asked for the whole five
//! seconds of [`BUDGET`] before refusing (RUN by the review of that version,
//! PipeWire 1.0.5 + WirePlumber 0.4.17). pactl, pw-dump and EasyEffects' rc are
//! asked only for what wpctl cannot answer: an inert default, whose device
//! behind is found in the graph and checked against pactl's list exactly as
//! the popup's `via` is; a sink's monitor as the default source, for which
//! wpctl names the SINK and get-volume reads the sink's level, while only
//! pactl lists the monitor's own (RUN, both); and no readable answer from
//! wpctl at all.
//!
//! wpctl's answer is read strictly ([`inspected`]): the `id N, type
//! PipeWire:Interface:Node` line, then one `key = "value"` line per property,
//! each key once. wpctl prints every value raw, unescaped, and pins
//! LC_NUMERIC to C itself (wpctl.c at 0.4.17 and 0.5.10, READ; RUN under
//! de_DE.UTF-8, where pactl printed "0,00 dB" and wpctl "0.55"), so the one
//! thing that can mislead a line reader is a value with a newline in it,
//! printing a line that reads as another property -- a node.description
//! forging a second node.name. Anything not exactly that shape is not trusted
//! for an answer that names a node for writes; pactl's JSON, which cannot be
//! forged that way, answers instead.
//!
//! WHO ASKS. With EasyEffects' sink as the default, the top bar read ITS
//! level, and the volume keys and the battery popup's slider and mute moved
//! it, while the speakers played on at -9.0 dBFS (RUN against an
//! EasyEffects-shaped graph on PipeWire 1.0.5 + WirePlumber 0.4.17: `osd.sh
//! volume-down 20` took easyeffects_sink from 60% to 40%, the mute key muted
//! it, the bar said 60, and the doctor said "wpctl reports 60%"). The popup's
//! hero already acted on the device behind; watchers/audio_fetch.sh,
//! config/common/scripts/osd.sh's volume keys, the battery popup's volume row
//! and the doctor's Audio section now ask this. So does
//! config/common/scripts/hypr/audio-switch.sh, only while EasyEffects' sink
//! is the default, to count the next output from the one heard.
//!
//! WHAT IT COSTS, AND WHY NOTHING CACHES IT. A live default costs two wpctl
//! calls and nothing else. An inert one costs wpctl's inspect, pactl's list
//! and the single whole-graph pw-dump the popup's poll already pays for it --
//! so it still needs pipewire-pulse: with pipewire-pulse SIGSTOPped, a volume
//! key under EasyEffects' default waited the whole [`BUDGET`] and refused,
//! touching nothing (RUN: 5012 ms), where a hardware default answered in
//! 25 ms. The bar asks on every reading instead of caching the answer by the
//! default's identity, because the answer can change while the default does
//! not: EasyEffects relinking its chain to another device changes no default
//! and raises no sink event. And a cache would save little. The bar's whole
//! reading -- watchers/audio_fetch.sh, jq included -- took a median 38 ms
//! through this with a hardware default, where 9d6e4f6's reading, four wpctl
//! calls, took 60 ms; with EasyEffects' sink as the default, 66 ms against
//! 61 ms for that old reading of the wrong node (RUN, 30 readings each, a
//! 14-node graph on PipeWire 1.0.5). The version of this mode that asked
//! pactl first measured 82 ms on a 27-node graph, an EasyEffects chain
//! lengthened to eighteen filters, 40 ms of it pw-dump writing its 370 KB
//! into a pipe, where it takes 22 ms into /dev/null. And
//! watchers/audio_watch.sh reads once per burst of events, never once per
//! event.
//!
//! WHY THIS EXISTS AT ALL
//!
//! The right answer here is neither a script nor a binary: Quickshell ships
//! `Pipewire`, which spawns no process, stays
//! live instead of being polled once a second, and cannot go missing. This
//! binary exists because `config/` still shells out for the list, and a helper
//! that is present and correct is what makes swapping to the native one a
//! decision rather than an emergency. When that swap lands, this can go.

use jayos_core::cli::Args;
use jayos_core::emit;
use jayos_core::proc::Budget;
use jayos_core::pw_route::{self, Side};
use serde::Serialize;
use serde_json::{Map, Value};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// How long one poll may spend asking, ALL of its calls together.
///
/// The Python had no limit at all. Both tools talk to the sound server over a
/// socket and wait on it, so a daemon that has accepted the connection and
/// then stopped answering -- a driver wedged in the kernel, most often --
/// stalls the call: pactl for libpulse's own 30 seconds before it fails, wpctl
/// for as long as the stall lasts, because it has no timeout at all (RUN by the
/// audit against a socket that accepts and never replies, and a SIGSTOPped
/// PipeWire). VolumePopup.qml spawns us and shows the cached state until our
/// stdout closes; nothing in that widget gives up on its own, and re-arming its
/// poll timer does not restart a `Process` that is still running. So a stall
/// here is a popup frozen on stale numbers -- and closing the popup ends the
/// freeze but not the stalled call, which is why [`run`] ties each child's
/// life to ours.
///
/// A BUDGET FOR THE POLL, NOT A DEADLINE PER CALL. This was five seconds per
/// call once, and a poll made six calls in a row -- three lists, two wpctl
/// lookups and `pactl info` -- against the same daemon, so a wedged one cost
/// every poll 30 seconds and then printed three empty lists (RUN: a SIGSTOPped
/// PipeWire, `real 0m30.012s`). It can make more now: a pw-dump for each name
/// pactl could not encode, a second list for a default that arrived late, and
/// one whole-graph pw-dump when an EasyEffects virtual device is the default.
/// Shared through `jayos_core::proc::Budget`, the first call that stalls spends it
/// and every later one returns at once without starting anything, which is the
/// right answer: once the daemon has stopped replying there is nothing left to
/// ask it. The same wedged run now takes five seconds and starts one client,
/// not six (RUN: 5.016 s, one pactl exec'd, counted under strace).
///
/// What that costs: a daemon that is slow rather than stopped, spending most of
/// the budget on the lists, leaves the default lookups nothing, and that poll
/// marks no row "Active Default". The one partial wedge measured does not reach
/// it -- with WirePlumber alone SIGSTOPped, `pactl info` and `pactl list` hang
/// as well as wpctl (RUN), so there was no answer to lose.
///
/// Generous against the real cost: a whole healthy poll takes tens of
/// milliseconds.
const BUDGET: Duration = Duration::from_secs(5);

/// One row of any of the three tabs.
///
/// Field order is the key order in the JSON. It is the order of the dict
/// literal the retired Python built -- id, name, description, volume, mute,
/// is_default, icon -- with `inert`, `via` and `detail` added at the end, and
/// nothing depends on it: the popup reads every field by name. The order stays
/// because changing it buys nothing and costs a little: the popup keeps the
/// whole answer as one string and rewrites its last_state.json cache only
/// when that string changes (`cache.lastAudioJson` in VolumePopup.qml), so a
/// reorder is one needless write. The document is compared byte for byte by
/// tools/test-audio-state.sh, so a reorder has to be made on purpose.
///
/// The Python's `binary` is gone. It fed an "open the app" button on the
/// Streams tab that never appeared, because `syncModel` never copied the key
/// into the row, and wiring it up would have run a program the stream named
/// for itself: `application.process.binary` is whatever a client says it is
/// -- a client can call itself "poweroff" -- and the key fell back to the
/// display name, lowercased. The one case the button was written for does
/// not occur: EasyEffects creates no sink-input, so it is never a Streams row
/// (READ in its source; RUN by the audit on PipeWire 1.0.5 with EasyEffects
/// 7.1.6 and with a pw_filter carrying 8.2.9's properties), and the Effects
/// row's own Open button already reaches it.
#[derive(Debug, Clone, PartialEq, Serialize)]
struct Node {
    id: String,
    name: String,
    description: String,
    volume: i64,
    mute: bool,
    is_default: bool,
    icon: String,
    inert: bool,
    via: String,
    detail: String,
}

/// The whole answer. Key order is the Python dict's -- outputs, inputs, apps
/// -- and then the cookie.
#[derive(Debug, Clone, PartialEq, Serialize)]
struct State {
    outputs: Vec<Node>,
    inputs: Vec<Node>,
    apps: Vec<Node>,
    cookie: String,
}

/// What `master` prints: the node a control acts on. The header's MASTER
/// section says what each field is for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct Master {
    name: String,
    object_id: String,
    description: String,
    volume: i64,
    mute: bool,
    default: String,
}

// ── reading the properties ───────────────────────────────────────────────────

/// A node's `properties` object, or nothing when it is absent or not an object.
fn props(node: &Value) -> Option<&Map<String, Value>> {
    node.get("properties").and_then(Value::as_object)
}

/// One property, as a string.
///
/// pactl writes every property value as a JSON string: an unset one as "", and
/// one it will not encode as the literal [`PACTL_UNENCODABLE`], never as JSON
/// `null`. Anything that is not a string is still treated as absent, as
/// defence against a pactl that changes that, and because it is where
/// `get_valid_string` sent null anyway.
fn prop<'a>(p: Option<&'a Map<String, Value>>, key: &str) -> &'a str {
    p.and_then(|m| m.get(key)).and_then(Value::as_str).unwrap_or("")
}

/// What pactl's JSON writer prints in place of a value it will not encode.
///
/// PulseAudio's `pa_json_escape` (pulsecore/json.c) refuses every byte outside
/// 0x20-0x7E and returns NULL, and its caller prints that NULL through
/// `"\"%s\""` -- which glibc renders as these six characters. So one accent,
/// typographic apostrophe, en dash or emoji anywhere in a value turns the WHOLE
/// value into this: "Jay’s AirPods", "Café del Mar – YouTube" and "Élan" all
/// came out of `pactl -f json` as "(null)" (RUN: pactl 16.1 against PipeWire
/// 1.0.5, with pactl's "Invalid non-ASCII character" on stderr each time). The
/// same code is in PulseAudio 17.0 (READ); the audit that found this read the
/// fix as upstream commit 2821ec1f, in no release yet. `pactl list` in text
/// and `pw-dump` carry the real UTF-8, which is what [`restore_from_pw_dump`]
/// uses.
const PACTL_UNENCODABLE: &str = "(null)";

/// The first candidate that is a real value.
///
/// The Python's `get_valid_string`. The rejected set is the point: PipeWire
/// hands out the literal strings "null" and "None" for properties an
/// application did not set, pactl prints [`PACTL_UNENCODABLE`] for one it
/// could not encode, and putting any of them in front of someone as a device
/// or stream name looks like a bug in the shell rather than in the tools. The
/// third is compared whole, so a real name that merely contains "null" stands.
fn valid_string(candidates: &[&str]) -> String {
    for candidate in candidates {
        let folded = candidate.trim().to_lowercase();
        if !folded.is_empty() && folded != "null" && folded != "none" && folded != PACTL_UNENCODABLE
        {
            return (*candidate).to_string();
        }
    }
    String::new()
}

/// The node's index as the id string.
///
/// `str(n.get("index"))` in the Python, which renders a missing index as the
/// string "None" rather than skipping the node -- kept, because pactl always
/// emits an index and a change here would only paper over output that is
/// already malformed. Note that two such nodes would collide in `syncModel`,
/// which matches rows by id.
fn index_string(node: &Value) -> String {
    match node.get("index") {
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => "None".to_string(),
        Some(other) => other.to_string(),
    }
}

/// The node's volume as a whole percent: its FIRST channel, in the node's own
/// channel order.
///
/// That is what `wpctl get-volume` reports, and that is what the top bar's pill
/// (config/quickshell/watchers/audio_fetch.sh) and the battery popup
/// (config/quickshell/battery/BatteryPopup.qml) read. Reading any other
/// channel makes the popup and the bar show two numbers for one device --
/// which this did: it read `front-left`, then `mono`, and otherwise 0, so a
/// Pro Audio profile (`aux0..auxN`) and a front-center-only node read 0 while
/// playing, and a node whose map starts with some other channel read that
/// other one (RUN against PipeWire 1.0.5 /
/// WirePlumber 0.4.17: aux0-3 at 70% read 0 here and 0.70 from wpctl;
/// rear-left 30% / front-left 80% read 80 here and 0.30 from wpctl).
///
/// Not the loudest channel, although that is what never reads a playing node
/// as silent: on an unbalanced node it disagrees with the bar the other way
/// (front 40% / rear 90% would read 90 here against 40 there). pactl moves
/// every channel together, so a balanced node reads the same whichever is
/// taken, and the popup has one slider.
///
/// The order comes from pactl's own `channel_map` string, because the parsed
/// `volume` object cannot give it: serde_json's Map is sorted by key unless
/// the workspace turns on `preserve_order`, which would change it for every
/// crate that uses serde_json. With no usable map -- pactl prints one for
/// sinks, sources and sink-inputs alike, so this is defence -- front-left, then
/// mono, then the loudest of whatever is there. Zero only when there is no
/// channel at all.
fn volume_percent(node: &Value) -> i64 {
    let Some(channels) = node.get("volume").and_then(Value::as_object) else {
        return 0;
    };

    let first_in_map = node
        .get("channel_map")
        .and_then(Value::as_str)
        .and_then(|map| map.split(',').next())
        .and_then(|name| channels.get(name.trim()));

    match first_in_map.or_else(|| channels.get("front-left")).or_else(|| channels.get("mono")) {
        Some(channel) => channel_percent(channel),
        None => channels.values().map(channel_percent).max().unwrap_or(0),
    }
}

/// One channel's `value_percent` as a whole number.
fn channel_percent(channel: &Value) -> i64 {
    let raw = channel.get("value_percent").and_then(Value::as_str).unwrap_or("0%");

    // `int(x.strip("%"))` in the Python, which raised on anything else and took
    // the whole poll with it -- an exception here means no stdout at all, so
    // `JSON.parse` throws in the QML and the popup keeps the previous state
    // forever. Unparseable reads as 0 instead: one wrong slider rather than a
    // dead popup.
    raw.trim_matches('%').trim().parse::<i64>().unwrap_or(0)
}

/// Python's `bool()` of the `mute` field.
///
/// pactl emits a real JSON bool; the rest is what `bool()` would have said, so
/// a future pactl that emits "yes"/"no" strings does not silently read as
/// unmuted.
fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Number(n)) => n.as_f64().map(|f| f != 0.0).unwrap_or(true),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
    }
}

/// Whether this node is the one WirePlumber calls default.
///
/// A node with no `name` is never the default. The Python compared
/// `n.get("name")` -- `None` when the key is absent -- against a string, which
/// is never equal; comparing an empty string against an empty default would be,
/// so the absent case is spelled out here rather than left to coincidence.
fn is_named(node: &Value, target: &str) -> bool {
    match node.get("name").and_then(Value::as_str) {
        Some(name) => name == target,
        None => false,
    }
}

// ── what a row says under its title ──────────────────────────────────────────

/// The names programs give every stream they play, which say nothing about
/// what is playing: Firefox's, "AudioStream" for media and
/// "AudioCallbackDriver" for a graph with no name of its own (Gecko's
/// dom/media/AudioStream.cpp and GraphDriver.cpp); Chromium's "Playback"
/// (media/audio/pulse/pulse_util.cc); and WebRTC's "playStream", which every
/// call through its PulseAudio device carries -- Discord's among them
/// (modules/audio_device/linux/audio_device_pulse_linux.cc). Each READ in its
/// project's source on 2026-10-27, and each is the stream name pactl lists as
/// `media.name`. Compared whole and as written: they are constants in code.
const STREAM_PLACEHOLDERS: [&str; 4] =
    ["AudioStream", "AudioCallbackDriver", "Playback", "playStream"];

/// Whether `title` already says `detail`, as whole words and in any case: a
/// subtitle that repeats its title says nothing. "spotify" over "Spotify",
/// "USB" under "USB Headset", "HDMI 3" under "... Digital Stereo (HDMI 3)".
/// Whole words, so "USB" is not found in "Busby Speakers".
fn repeats(title: &str, detail: &str) -> bool {
    let title = title.to_lowercase();
    let detail = detail.to_lowercase();
    if detail.trim().is_empty() {
        return true;
    }
    let word = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
    title.match_indices(&detail).any(|(at, found)| {
        !word(title[..at].chars().next_back()) && !word(title[at + found.len()..].chars().next())
    })
}

/// An HDMI output's port, named as PipeWire's profile descriptions name it:
/// `hdmi-stereo` is "HDMI", `hdmi-stereo-extra1` "HDMI 2", `-extra2` "HDMI 3"
/// ("Digital Stereo (HDMI 3)"). The profile is `device.profile.name`, or the
/// last part of the node name, which WirePlumber ends with it.
fn hdmi_port(p: Option<&Map<String, Value>>, node_name: &str) -> Option<String> {
    let profile = match valid_string(&[prop(p, "device.profile.name")]) {
        named if !named.is_empty() => named,
        _ => node_name.rsplit('.').next().unwrap_or("").to_string(),
    };
    if !profile.starts_with("hdmi-") {
        return None;
    }
    let extra = profile
        .rsplit_once("-extra")
        .and_then(|(_, n)| n.parse::<u32>().ok())
        .map(|n| format!("HDMI {}", n + 1));
    Some(extra.unwrap_or_else(|| "HDMI".to_string()))
}

/// The bus a device is on, as a person would name it, or "".
///
/// Each from what pactl lists for the node, and the node name WirePlumber
/// builds from the same device -- `bluez_output.<address>.<n>`,
/// `alsa_output.usb-<vendor>_<model>-<n>.<profile>` -- for a node whose
/// properties say less. A device whose bus is none of these -- the
/// motherboard's own codec, a virtual device -- says nothing: its title is
/// what it is.
fn bus_of(p: Option<&Map<String, Value>>, node_name: &str) -> String {
    let bluetooth = !prop(p, "api.bluez5.address").trim().is_empty()
        || prop(p, "device.api") == "bluez5"
        || node_name.starts_with("bluez_");
    if bluetooth {
        return "Bluetooth".to_string();
    }
    if let Some(port) = hdmi_port(p, node_name) {
        return port;
    }
    let usb = prop(p, "device.bus") == "usb"
        || prop(p, "alsa.driver_name") == "snd_usb_audio"
        || prop(p, "api.alsa.card.longname").contains(" at usb-")
        || node_name.starts_with("alsa_output.usb-")
        || node_name.starts_with("alsa_input.usb-");
    if usb {
        return "USB".to_string();
    }
    String::new()
}

/// What a row says under its title: a device's bus, a stream's track -- or
/// nothing, where that is all there is or the title already says it.
///
/// A stream's track is `media.name`, then `window.title`, as the `name` field
/// takes them, but never a name its program gives every stream
/// ([`STREAM_PLACEHOLDERS`]) and never the role or the "Audio Stream" that
/// `name` falls back to: "music" under "Spotify" says nothing either.
fn detail_of(node: &Value, is_app: bool, title: &str) -> String {
    let p = props(node);
    let detail = if is_app {
        let track = |key: &str| {
            let value = prop(p, key);
            if STREAM_PLACEHOLDERS.contains(&value.trim()) {
                ""
            } else {
                value
            }
        };
        valid_string(&[track("media.name"), track("window.title")])
    } else {
        bus_of(p, node.get("name").and_then(Value::as_str).unwrap_or(""))
    };
    if repeats(title, &detail) {
        String::new()
    } else {
        detail
    }
}

// ── building a row ───────────────────────────────────────────────────────────

/// Turn one pactl node into a row.
///
/// `is_app` swaps which properties are the title and which the subtitle. A
/// device is identified by its hardware description over its node name; a
/// stream by the application that owns it over whatever it called the track.
fn format_node(node: &Value, is_default: bool, is_app: bool) -> Node {
    let p = props(node);
    let node_name = node.get("name").and_then(Value::as_str).unwrap_or("");

    let (display_name, sub_desc) = if is_app {
        (
            valid_string(&[
                prop(p, "application.name"),
                prop(p, "application.process.binary"),
                "Unknown App",
            ]),
            valid_string(&[
                prop(p, "media.name"),
                prop(p, "window.title"),
                prop(p, "media.role"),
                "Audio Stream",
            ]),
        )
    } else {
        // A monitor's `device.description` property is its SINK's -- pactl
        // printed "Fake-Mic" there for `alsa_input.fake_mic_sink.monitor`, and
        // "Monitor of Fake-Mic" as the node's own top-level description (RUN,
        // pactl 16.1 on PipeWire 1.0.5). A default monitor is an input row, and
        // titling it with the output's name is the very confusion between a
        // sink and its monitor that row exists to end.
        let own = if is_monitor(node) {
            node.get("description").and_then(Value::as_str).unwrap_or("")
        } else {
            ""
        };
        (
            valid_string(&[own, prop(p, "device.description"), node_name, "Unknown Device"]),
            valid_string(&[node_name, "Unknown"]),
        )
    };

    let icon = valid_string(&[
        prop(p, "application.icon_name"),
        prop(p, "device.icon_name"),
        "audio-card",
    ]);

    Node {
        id: index_string(node),
        name: sub_desc,
        detail: detail_of(node, is_app, &display_name),
        description: display_name,
        volume: volume_percent(node),
        mute: truthy(node.get("mute")),
        is_default,
        icon,
        // A stream's volume is always its own; only a device can be one of
        // EasyEffects' virtual ones.
        inert: !is_app && pw_route::inert(p, node_name),
        // Filled in by `route_through` for the one row that needs it.
        via: String::new(),
    }
}

/// Whether a source is a monitor of an output rather than a real input.
///
/// Every sink gets a monitor source, so without this the Inputs tab lists every
/// speaker alongside the microphones. Both tests are kept: `device.class` is the
/// property PipeWire sets, and the name suffix catches the nodes that carry no
/// class at all.
fn is_monitor(node: &Value) -> bool {
    prop(props(node), "device.class") == "monitor"
        || node.get("name").and_then(Value::as_str).unwrap_or("").ends_with(".monitor")
}

/// Assemble the three lists from what pactl and wpctl said.
///
/// Separated from the subprocess calls so the filtering and the default
/// matching can be tested without a sound server.
fn build_state(
    sinks: &[Value],
    sources: &[Value],
    sink_inputs: &[Value],
    default_sink: &str,
    default_source: &str,
) -> State {
    // Every playback stream, unfiltered. A mixer's own peak meters are
    // RECORDING streams -- pavucontrol connects them with
    // pa_stream_connect_record and PA_STREAM_PEAK_DETECT against each sink's
    // monitor, which makes them source-outputs (READ; the audit RAN pavucontrol
    // 5.0 and pavucontrol-qt 1.4 and found no sink-input carrying their id) --
    // and this list is built from sink-inputs alone, so they never reach it
    // (RUN: a parecord carrying pavucontrol's application.id showed up as one
    // source-output and no sink-input). tools/test-audio-state.sh asserts
    // source-outputs are never even asked for. A filter on pavucontrol's id
    // stood here, hiding a stream no server produces.
    let apps = sink_inputs.iter().map(|s| format_node(s, false, true)).collect();

    // Monitors are left out -- every sink has one, and listing them put each
    // speaker on the Inputs tab -- EXCEPT the one that is the default source.
    // That one is what a recorder of the default hears and what the hero's
    // controls act on, and dropping it left no input marked default: the hero
    // fell back to the first microphone, or kept the Outputs tab's device,
    // while the slider moved something else (the audit RAN it: with a monitor
    // default the hero showed a real mic at 35% while the slider moved the
    // monitor's sink to 20%).
    let inputs = sources
        .iter()
        .filter(|s| !is_monitor(s) || is_named(s, default_source))
        .map(|s| format_node(s, is_named(s, default_source), false))
        .collect();

    let outputs = sinks.iter().map(|s| format_node(s, is_named(s, default_sink), false)).collect();

    State { outputs, inputs, apps, cookie: String::new() }
}

/// The default row, when it is one whose own controls reach nothing.
fn inert_default(rows: &[Node]) -> Option<&Node> {
    rows.iter().find(|row| row.is_default && row.inert)
}

/// The listed row named `behind` that a control may act on in an inert
/// default's place: one of the same list, and not inert itself.
///
/// `behind` is a node name, from the link graph or EasyEffects' rc. The popup
/// acts on `via` by id, so an unlisted device has nothing to act on, and
/// pointing one virtual device at the other would be the same dead control
/// twice. `master` asks this too, so the hero and every other control cannot
/// disagree about which device that is.
fn listed_device<'a>(rows: &'a [Node], behind: &str) -> Option<&'a Node> {
    rows.iter().find(|row| !row.inert && row.name == behind)
}

/// Point an inert default row at the listed row named `behind`, when there is
/// one ([`listed_device`]).
fn route_through(rows: &mut [Node], behind: &str) {
    let Some(target) = listed_device(rows, behind).map(|row| row.id.clone()) else {
        return;
    };
    if let Some(row) = rows.iter_mut().find(|row| row.is_default && row.inert) {
        row.via = target;
    }
}

/// The default row and the row its controls act on, for `master`.
///
/// The default row is its own target unless it is inert; then `behind_of` is
/// asked for the device behind it -- only then, because answering costs a
/// whole-graph pw-dump -- and the target is the [`listed_device`] of that
/// name. An `Err` is the sentence the failure envelope carries.
fn master_rows(
    rows: &[Node],
    side: Side,
    behind_of: impl FnOnce(&str) -> Option<String>,
) -> Result<(&Node, &Node), String> {
    let noun = match side {
        Side::Sink => "output",
        Side::Source => "input",
    };
    let Some(default) = rows.iter().find(|row| row.is_default) else {
        return Err(format!("the default {noun} is not in pactl's list"));
    };
    if !default.inert {
        return Ok((default, default));
    }
    match behind_of(&default.name).and_then(|name| listed_device(rows, &name)) {
        Some(target) => Ok((default, target)),
        None => Err(format!(
            "the default {noun}, {}, is one of EasyEffects' virtual devices, whose own level \
             and mute reach nothing, and the device behind it could not be found",
            default.name
        )),
    }
}

/// The device behind an inert default: the link graph first, then EasyEffects'
/// own record, which is all there is while its inactivity timer has unlinked
/// the filters. `dump` and `rc` are what pw-dump printed and what the rc file
/// holds, each asked for at most once per poll however many sides need them.
fn behind(name: &str, side: Side, dump: &Value, rc: Option<&str>) -> Option<String> {
    pw_route::device_behind(dump, name, side)
        .or_else(|| rc.and_then(|text| pw_route::easyeffects_device(text, side)))
}

// ── asking the sound server ──────────────────────────────────────────────────

/// Run a command and return its stdout, or `None` if it could not be started,
/// exited non-zero, or did not finish in time.
///
/// Every failure folds into `None`, which is where the Python's bare `except:
/// return "[]"` sent them: a missing pactl, a non-zero exit and a stalled
/// daemon are all "there is no answer".
///
/// Not `jayos_core::proc::output_within`, which is this with a deadline and no
/// more: a child it starts outlives a caller that is SIGKILLed mid-call, and
/// this caller is SIGKILLed on every popup close -- see the pre_exec below.
fn run(program: &str, args: &[&str], limit: Duration) -> Option<String> {
    // A spent budget starts nothing. Spawning a pactl only to kill it
    // microseconds later would hand one more client to a daemon that has
    // already stopped answering, once per remaining call, every poll. Nothing
    // a unit test can see tells the two apart -- a child killed that soon
    // never runs a line -- so tools/test-audio-state.sh counts the execs under
    // strace instead.
    if limit.is_zero() {
        return None;
    }

    let parent = std::process::id() as libc::pid_t;
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        // The Python sent stderr to DEVNULL. Discarded rather than inherited,
        // because inheriting puts pactl's complaints into the shell's own
        // stderr on every poll -- once a second, forever.
        .stderr(Stdio::null())
        .stdout(Stdio::piped());

    // THE CHILD DIES WITH US. Closing the popup destroys its `Process`, and
    // Quickshell's destructor SIGKILLs the one process it started -- this one
    // (READ: quickshell's process.cpp, ~Process). Nothing of ours runs after a
    // SIGKILL, so the deadline below goes with us, and whichever pactl or wpctl
    // was in flight was orphaned: RUN, this helper killed a second into a poll
    // against a stopped PipeWire left its `pactl -f json list sinks` running
    // under PID 1; the audit, opening and closing the real popup under
    // Quickshell against a wedged pulse socket, counted fifteen live pactl
    // orphans by the fourteenth close, and against a stopped PipeWire, wpctl
    // orphans that lived as long as the stall did. PR_SET_PDEATHSIG has the
    // kernel SIGKILL the child the moment we die, however we die.
    //
    // Three things about it that are easy to break:
    //
    //  - It fires when the THREAD that forked exits, not the process. run() is
    //    only ever called on the main thread -- the drain thread below reads,
    //    it never spawns -- and it has to stay that way: a spawn from a worker
    //    thread would kill its child as soon as that thread ended.
    //  - It does not survive a fork, only an exec. pactl and wpctl do not
    //    fork; a wrapper script that did would leave its own child uncovered.
    //  - We can die between fork and the prctl, before the child has asked to
    //    be told. So the child checks it still has the parent that forked it,
    //    compared against our pid rather than against 1: under a subreaper --
    //    `systemd --user` is one -- an orphan's new parent is not PID 1.
    //
    // A prctl that fails is ignored rather than refused: the child then runs
    // exactly as it did before this existed, which is better than an empty
    // popup. pre_exec also makes std fork and exec instead of posix_spawn,
    // which at a few spawns a second costs nothing measurable.
    //
    // SAFETY: prctl and getppid are plain syscalls and _exit ends the process
    // without running anything of ours. All three are async-signal-safe, which
    // is what may run between fork and exec; nothing here allocates or locks.
    unsafe {
        command.pre_exec(move || {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL as libc::c_ulong);
            if libc::getppid() != parent {
                libc::_exit(1);
            }
            Ok(())
        });
    }

    let mut child = command.spawn().ok()?;

    let Some(mut pipe) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };

    // Read on another thread so that the deadline still holds while the read
    // blocks. read_to_end returns only at EOF, and a pactl or wpctl stalled on
    // a wedged daemon (see BUDGET) keeps its stdout open, so a read on this
    // thread would last as long as the stall -- which is the whole failure the
    // deadline exists for. `run_gives_up_on_a_command_that_hangs` is the test
    // that fails without the thread (RUN: a read moved onto this thread made
    // it take the full 30 seconds of its `sleep 30`, against a 150 ms limit).
    //
    // The ORDER is a separate matter: the pipe has to be read while the child
    // runs, not after it exits. Waiting first deadlocks once the output passes
    // the 64 KiB pipe buffer, because the child blocks on a write nobody is
    // reading and never exits; `run_survives_more_output_than_a_pipe_buffer_
    // holds` guards that. Reading to EOF and THEN waiting, on one thread, does
    // not deadlock -- it is what `Command::output` does -- it only outlasts the
    // deadline.
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = pipe.read_to_end(&mut buf);
        let _ = tx.send(buf);
    });

    let deadline = Instant::now() + limit;

    let stdout = match rx.recv_timeout(limit) {
        // Lossy: a device description is whatever the vendor put in the USB
        // descriptor, and a byte sequence that is not UTF-8 should cost that
        // one name a replacement character rather than cost the popup its list.
        Ok(buf) => String::from_utf8_lossy(&buf).into_owned(),
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    };

    // EOF on stdout almost always means the child has exited, so this settles
    // on the first pass. The deadline is still enforced, because a program that
    // closes stdout and keeps running is exactly what a timeout is for.
    loop {
        match child.try_wait() {
            // Non-zero is nothing, as `subprocess.check_output` raising made it.
            Ok(Some(status)) => return (status.code() == Some(0)).then_some(stdout),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                thread::sleep(Duration::from_millis(2));
            }
            Err(_) => return None,
        }
    }
}

/// Parse what pactl printed, or an empty array.
///
/// The Python's `parse_pactl`: any JSON error is an empty list, and so is the
/// literal `"[]"` that `run_cmd` returned when the command itself failed.
fn parse(text: Option<String>) -> Value {
    text.and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .unwrap_or_else(|| Value::Array(Vec::new()))
}

/// Parse what pw-dump printed, or an empty array. Not [`parse`]: pw-dump can
/// print a second array after the graph, which one JSON document refuses --
/// and a refused graph handed the answer to EasyEffects' rc, another device.
/// [`pw_route::parse_dump`] has the run and the numbers.
fn parse_dump(text: Option<String>) -> Value {
    text.and_then(|t| pw_route::parse_dump(&t)).unwrap_or_else(|| Value::Array(Vec::new()))
}

/// The pactl properties this helper reads that can come back as
/// [`PACTL_UNENCODABLE`], each with the keys PipeWire keeps the same value
/// under. pipewire-pulse renames some on the way out: `node.description`
/// becomes `device.description`, and `application.icon-name` becomes
/// `application.icon_name` (RUN: one null sink and one pacat stream compared
/// between `pactl -f json` and `pw-dump` on PipeWire 1.0.5). The device icon
/// is taken to follow the icon rule; both spellings are tried for each icon,
/// so a guess that is wrong costs nothing.
const RECOVERABLE: [(&str, &[&str]); 8] = [
    ("device.description", &["node.description", "device.description"]),
    ("device.icon_name", &["device.icon-name", "device.icon_name"]),
    ("application.name", &["application.name"]),
    ("application.process.binary", &["application.process.binary"]),
    ("application.icon_name", &["application.icon-name", "application.icon_name"]),
    ("media.name", &["media.name"]),
    ("window.title", &["window.title"]),
    ("media.role", &["media.role"]),
];

/// Whether pactl lost the node's name or anything in [`RECOVERABLE`] to its
/// ASCII-only encoder.
fn lost_to_pactl(node: &Value) -> bool {
    node.get("name").and_then(Value::as_str) == Some(PACTL_UNENCODABLE)
        || RECOVERABLE.iter().any(|(key, _)| prop(props(node), key) == PACTL_UNENCODABLE)
}

/// A PipeWire object's `object.serial`, which pw-dump prints as a number.
fn serial_of(pw_props: &Map<String, Value>) -> Option<u64> {
    match pw_props.get("object.serial")? {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// Put back what pactl could not encode, from PipeWire's own copy of the node.
///
/// `dump` is what `pw-dump <index>` printed. Under pipewire-pulse a pactl
/// index IS the node's `object.serial` (RUN: sink 74 and stream 94 both), but
/// `pw-dump N` matches N against an object's id OR its serial, so the array
/// can also hold an unrelated object whose id happens to be N -- the join is on
/// the serial alone. Only values that came back as [`PACTL_UNENCODABLE`] are
/// replaced; everything pactl did encode is left exactly as it printed it.
fn restore_from_pw_dump(node: &mut Value, dump: &Value) {
    let Some(index) = node.get("index").and_then(Value::as_u64) else {
        return;
    };
    let Some(pw) = dump.as_array().into_iter().flatten().find_map(|object| {
        let pw_props = object.get("info")?.get("props")?.as_object()?;
        (serial_of(pw_props) == Some(index)).then_some(pw_props)
    }) else {
        return;
    };
    let pw_string = |keys: &[&str]| {
        keys.iter().find_map(|key| pw.get(*key).and_then(Value::as_str)).map(str::to_string)
    };

    // The node name as well: it is what a click hands `pactl
    // set-default-sink`, which takes UTF-8 arguments without complaint, and
    // what the default is matched on -- wpctl names the default in UTF-8.
    if node.get("name").and_then(Value::as_str) == Some(PACTL_UNENCODABLE) {
        if let Some(name) = pw_string(&["node.name"]) {
            node["name"] = Value::String(name);
        }
    }
    if let Some(Value::Object(properties)) = node.get_mut("properties") {
        for (key, pw_keys) in RECOVERABLE {
            if properties.get(key).and_then(Value::as_str) == Some(PACTL_UNENCODABLE) {
                if let Some(value) = pw_string(pw_keys) {
                    properties.insert(key.to_string(), Value::String(value));
                }
            }
        }
    }
}

/// `pactl -f json list <kind>`, with anything pactl could not encode put back
/// from `pw-dump`.
///
/// pw-dump is asked only for a node that lost something, and only for that
/// node: it dumps every object with every parameter otherwise -- 688 KB and
/// 40-50 ms for a graph of 34 sinks, against 12 ms for one node (RUN) -- and a
/// machine whose names are all ASCII never runs it at all. It ships in the
/// `pipewire` package, which wpctl's `wireplumber` depends on; where it is
/// missing, the value stays [`PACTL_UNENCODABLE`], [`valid_string`] rejects
/// it, and the row falls back to its node name or binary as before.
///
/// Monitor sources are skipped: a monitor's pactl index is its SINK's serial
/// (RUN: `utf_sink.monitor` is index 74, the sink's serial), so pw-dump would
/// hand back the sink's description for it. The Inputs tab shows a monitor
/// only while it is the default source, and one whose description pactl could
/// not encode then shows its node name instead.
fn nodes(kind: &str, budget: &Budget) -> Vec<Value> {
    let mut items = list(kind, budget);
    for node in items.iter_mut().filter(|node| !is_monitor(node) && lost_to_pactl(node)) {
        let Some(index) = node.get("index").and_then(Value::as_u64) else {
            continue;
        };
        let dump = parse_dump(run("pw-dump", &[&index.to_string()], budget.left()));
        restore_from_pw_dump(node, &dump);
    }
    items
}

/// `pactl -f json list <kind>`, as a list of nodes.
fn list(kind: &str, budget: &Budget) -> Vec<Value> {
    match parse(run("pactl", &["-f", "json", "list", kind], budget.left())) {
        Value::Array(items) => items,
        // pactl printing an object where a list belongs would have made the
        // Python iterate its keys and die on the first `s.get`; nothing to show
        // is the honest answer.
        _ => Vec::new(),
    }
}

/// wpctl's name for the default on one side.
fn default_token(side: Side) -> &'static str {
    match side {
        Side::Sink => "@DEFAULT_AUDIO_SINK@",
        Side::Source => "@DEFAULT_AUDIO_SOURCE@",
    }
}

/// The node name WirePlumber calls default, from `wpctl inspect`.
///
/// wpctl prints one `key = value` per property; the one whose KEY is
/// `node.name` is the answer (see [`node_name_in`] for why the key and not the
/// line). Anything else -- wpctl missing, WirePlumber not running, no such
/// property -- is an empty string, and the caller then falls back to `pactl
/// info`.
fn wpctl_default(side: Side, budget: &Budget) -> String {
    let Some(out) = run("wpctl", &["inspect", default_token(side)], budget.left()) else {
        return String::new();
    };
    default_from_inspect(&out, side)
}

/// What `wpctl inspect` printed for one node, read strictly: the PipeWire
/// object id from its first line, and every property as a string.
#[derive(Debug, PartialEq)]
struct Inspected {
    id: String,
    props: Map<String, Value>,
}

/// `wpctl inspect` output read as exactly the shape wpctl prints -- `id N,
/// type PipeWire:Interface:Node`, then one `  [*] key = "value"` per property
/// -- or nothing.
///
/// Stricter than [`property_in`], which the popup's poll uses to take a name
/// and nothing more, because what this reads decides which node every other
/// control writes to. wpctl prints each value raw between quotes (wpctl.c's
/// inspect_print_object, READ at 0.4.17 and 0.5.10), so a value holding a
/// newline prints a second line that reads as a property of its own: a device
/// description of `x"<newline>  * node.name = "decoy` prints two well-formed
/// lines, the forged node.name before the real one because the description
/// sorts first. So a key seen twice is refused, as is any
/// line that is not one whole quoted property -- the tail of a split value --
/// and any first line that is not a node's. A refusal costs nothing but the
/// wpctl-only answer: [`master`] asks pactl, whose JSON a newline cannot
/// forge, as it always did.
fn inspected(text: &str) -> Option<Inspected> {
    let mut lines = text.lines();
    let id = lines.next()?.strip_prefix("id ")?.strip_suffix(", type PipeWire:Interface:Node")?;
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut props = Map::new();
    for line in lines {
        let property = line.trim_start();
        let property = property.strip_prefix('*').unwrap_or(property);
        // Keys never hold `=`, so the first one splits key from value.
        let (key, value) = property.split_once('=')?;
        let value = value.trim().strip_prefix('"')?.strip_suffix('"')?;
        if props.insert(key.trim().to_string(), Value::String(value.to_string())).is_some() {
            return None;
        }
    }
    Some(Inspected { id: id.to_string(), props })
}

/// The default wpctl inspected, when wpctl alone can answer for it: its node
/// name and its description. See "A LIVE DEFAULT IS WPCTL'S ALONE TO ANSWER"
/// in the header.
///
/// `None` for one of EasyEffects' inert devices, whose device behind is in the
/// graph and pactl's list, and for any node not of the side's own class. On
/// the source side that is a sink's monitor: WirePlumber records the SINK as
/// the default source (see the header), so `wpctl get-volume` would read the
/// speakers' level for the monitor's -- RUN, the monitor at 30% read as its
/// sink's 0.70 -- and only pactl lists the monitor's own. A duplex node, or a
/// class this does not know, goes to pactl the same way: it answered for them
/// before, and nothing here has been run against one.
fn live_default(read: &Inspected, side: Side) -> Option<(String, String)> {
    let p = Some(&read.props);
    let name = prop(p, "node.name");
    let class = prop(p, "media.class");
    let own_class = match side {
        Side::Sink => class == "Audio/Sink",
        Side::Source => class == "Audio/Source" || class == "Audio/Source/Virtual",
    };
    if name.is_empty() || !own_class || pw_route::inert(p, name) {
        return None;
    }
    let description = valid_string(&[prop(p, "node.description"), name, "Unknown Device"]);
    Some((name.to_string(), description))
}

/// `wpctl get-volume` output -- `Volume: 0.55`, `Volume: 0.55 [MUTED]` -- as a
/// whole percent and the mute, or nothing.
///
/// Rounded, not truncated, as every reader of wpctl's two decimals here rounds
/// them (watchers/audio_fetch.sh has why: 0.29 * 100 is 28.999999999999996).
/// Only that exact line: `wpctl get-volume` of a node that does not exist
/// prints "Node ... not found" and exits 0 (RUN, WirePlumber 0.4.17), and one
/// with no volume says so on stderr alone (wpctl.c's do_print_volume, READ).
fn wpctl_level(text: &str) -> Option<(i64, bool)> {
    let line = text.lines().find(|l| l.starts_with("Volume: "))?;
    let mut words = line.split(' ').skip(1);
    let level = words.next()?;
    if level.is_empty() || !level.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    let level: f64 = level.parse().ok()?;
    let mute = match words.next() {
        None => false,
        Some("[MUTED]") => true,
        Some(_) => return None,
    };
    if words.next().is_some() {
        return None;
    }
    Some(((level * 100.0 + 0.5).floor() as i64, mute))
}

/// The answer for a live default, from what wpctl inspected and what `level_of`
/// -- `wpctl get-volume <id>` -- prints for its object id; `None` when either
/// cannot answer, which sends [`master`] to pactl.
fn live_master(
    read: &Inspected,
    side: Side,
    level_of: impl FnOnce(&str) -> Option<String>,
) -> Option<Master> {
    let (name, description) = live_default(read, side)?;
    let (volume, mute) = wpctl_level(&level_of(&read.id)?)?;
    Some(Master {
        default: name.clone(),
        name,
        object_id: read.id.clone(),
        description,
        volume,
        mute,
    })
}

/// The default's pactl name, from what `wpctl inspect` printed for it.
///
/// For the source, an `Audio/Sink` answer means a sink's monitor is the
/// default (see the header), and the source pactl lists for it -- the one a
/// recorder hears, and the one pipewire-pulse resolves @DEFAULT_SOURCE@ to --
/// is `<sink>.monitor`.
fn default_from_inspect(text: &str, side: Side) -> String {
    let name = node_name_in(text);
    if side == Side::Source && !name.is_empty() && property_in(text, "media.class") == "Audio/Sink"
    {
        return format!("{name}.monitor");
    }
    name
}

/// The value of the `node.name` property in `wpctl inspect` output.
fn node_name_in(text: &str) -> String {
    property_in(text, "node.name")
}

/// The value of one property in `wpctl inspect` output.
///
/// Matched on the KEY, never on the line. wpctl prints the properties sorted
/// by key, so `node.description` comes out before `node.name` -- and a
/// description is whatever the device or its owner chose to call it. A
/// Bluetooth speaker advertising itself as "Studio node.name = decoy" was
/// taken for the name when this looked for the first line merely containing
/// `node.name` (RUN: a null sink with that description, made default, came
/// back with no row marked default). Keys that only END in `node.name` are not
/// it either, for the same reason.
///
/// Properties set on the object itself are marked with a leading `*`; the
/// marker is not part of the key. Keys never contain `=`, so the first `=`
/// splits key from value however many the value holds.
///
/// A key printed TWICE is no answer at all. wpctl prints every value raw
/// between quotes (wpctl.c's inspect_print_object, READ at 0.4.17 and
/// 0.5.10), so a description or nick with a newline in it prints a whole
/// second `node.name = "..."` line -- before the real one from
/// `node.description`, which sorts first, and after it from `node.nick`,
/// which sorts after. Taking the first line or the last would each be fooled
/// by one of the two, and wpctl prints each property once, so a repeat means
/// the text cannot be read: "" sends the caller to `pactl info`, whose JSON a
/// newline cannot forge. [`inspected`] refuses the same way for `master`.
fn property_in(text: &str, wanted: &str) -> String {
    let mut found: Option<String> = None;
    for line in text.lines() {
        let property = line.trim_start();
        let property = property.strip_prefix('*').unwrap_or(property);
        // A line with no `=` is not a property; keep looking rather than
        // giving up, as the Python's `if len(parts) == 2` did.
        let Some((key, value)) = property.split_once('=') else {
            continue;
        };
        if key.trim() == wanted {
            if found.is_some() {
                return String::new();
            }
            found = Some(value.trim().trim_matches('"').to_string());
        }
    }
    found.unwrap_or_default()
}

/// Fill in whichever defaults wpctl did not supply, from `pactl info`.
///
/// Only the missing one is replaced: wpctl is the more trustworthy source when
/// it answered, so a working sink answer is not discarded because the source
/// answer was empty. Both halves agree about a monitor: pactl names it
/// `<sink>.monitor`, and [`default_from_inspect`] translates wpctl's answer to
/// the same.
fn fill_defaults_from_pactl(info: &Value, default_sink: &mut String, default_source: &mut String) {
    let Some(obj) = info.as_object() else {
        return;
    };
    if default_sink.is_empty() {
        *default_sink =
            obj.get("default_sink_name").and_then(Value::as_str).unwrap_or("").to_string();
    }
    if default_source.is_empty() {
        *default_source =
            obj.get("default_source_name").and_then(Value::as_str).unwrap_or("").to_string();
    }
}

/// Whether `default` names a node that `nodes`, listed a moment earlier, does
/// not hold -- the sign of a device that arrived between the list and the
/// default, and the one case where listing again can help.
///
/// Two names count as listed although they do not match exactly:
///
///  - `<default>.monitor`. When a monitor is the default source, wpctl names
///    the SINK node it monitors (RUN: `wpctl inspect @DEFAULT_AUDIO_SOURCE@`
///    printed `alsa_input.fake_mic_sink`, media.class Audio/Sink, while pactl
///    lists `alsa_input.fake_mic_sink.monitor`). [`default_from_inspect`]
///    translates that answer before it gets here, so this arm is defence for
///    a wpctl whose answer carries no media.class: without it, every poll on
///    such a machine would list the sources twice, and the second list could
///    never match either.
///  - a node whose name pactl could not encode ([`PACTL_UNENCODABLE`], where
///    pw-dump was not there to restore it). It may well be the default, and
///    listing it again would print it no better.
fn listed_too_early(nodes: &[Value], default: &str) -> bool {
    if default.is_empty() {
        return false;
    }
    let monitor = format!("{default}.monitor");
    !nodes.iter().any(|node| {
        is_named(node, default) || is_named(node, &monitor) || is_named(node, PACTL_UNENCODABLE)
    })
}

// ── entry ────────────────────────────────────────────────────────────────────

/// What the arguments ask for.
#[derive(Debug, PartialEq)]
enum Mode {
    /// No verb: the popup's poll. Flags are ignored rather than refused, as
    /// they always were -- the popup passes none.
    Popup,
    Master(Side),
    /// `master` with a side it does not know, or with more than one.
    Usage,
    Unknown(String),
}

fn mode(args: &Args) -> Mode {
    match args.command.as_deref() {
        None => Mode::Popup,
        Some("master") => match (args.positional(0), args.positional(1)) {
            (Some("sink"), None) => Mode::Master(Side::Sink),
            (Some("source"), None) => Mode::Master(Side::Source),
            _ => Mode::Usage,
        },
        Some(other) => Mode::Unknown(other.to_string()),
    }
}

/// `master sink|source`: the node a control on that side acts on. See MASTER
/// in the header.
///
/// wpctl first, and for a live default nothing else ("A LIVE DEFAULT IS
/// WPCTL'S ALONE TO ANSWER" in the header). Past that, the popup's own
/// questions under the same budget, for the one kind: the list; the default,
/// as the poll reads it from what wpctl printed, or from `pactl info` when
/// wpctl said nothing -- there is no id here to pair with a cookie, so `info`
/// is not asked otherwise; and the list once more when the default is not in
/// it. The poll lists before it asks for the default; here the default is
/// known first, so the second list can only help a node pipewire-pulse had not
/// listed yet, and it stays for the same reason as the poll's: once, never in
/// a loop.
fn master(side: Side) -> ExitCode {
    let budget = Budget::new(BUDGET);

    let inspect = run("wpctl", &["inspect", default_token(side)], budget.left());
    let live = inspect.as_deref().and_then(inspected).and_then(|read| {
        live_master(&read, side, |id| run("wpctl", &["get-volume", id], budget.left()))
    });
    if let Some(answer) = live {
        return emit::json(&answer);
    }

    let kind = match side {
        Side::Sink => "sinks",
        Side::Source => "sources",
    };
    let mut listed = nodes(kind, &budget);
    // The poll's reading of wpctl's answer, not `inspected`'s: this path has
    // to name the node the popup's hero names for the same world, and it is
    // pactl's list, not wpctl's text, that decides what that node is.
    let mut default =
        inspect.as_deref().map(|text| default_from_inspect(text, side)).unwrap_or_default();
    if default.is_empty() {
        let info = parse(run("pactl", &["-f", "json", "info"], budget.left()));
        let (mut sink, mut source) = (String::new(), String::new());
        fill_defaults_from_pactl(&info, &mut sink, &mut source);
        default = match side {
            Side::Sink => sink,
            Side::Source => source,
        };
    }
    if default.is_empty() {
        return emit::failure(match side {
            Side::Sink => "there is no default output, or the sound server did not answer",
            Side::Source => "there is no default input, or the sound server did not answer",
        });
    }
    if listed_too_early(&listed, &default) {
        let again = nodes(kind, &budget);
        if !again.is_empty() {
            listed = again;
        }
    }
    // Nothing listed at all is pipewire-pulse not answering -- a server has
    // at least the default in its list -- and saying "not in pactl's list"
    // then sent the reader looking for a missing device. The doctor prints
    // this sentence as its FAIL.
    if listed.is_empty() {
        return emit::failure(format!(
            "pactl listed no {} -- is pipewire-pulse running? -- and wpctl alone cannot answer for the default, {default}",
            match side {
                Side::Sink => "outputs",
                Side::Source => "inputs",
            }
        ));
    }

    let state = match side {
        Side::Sink => build_state(&listed, &[], &[], &default, ""),
        Side::Source => build_state(&[], &listed, &[], "", &default),
    };
    let rows = match side {
        Side::Sink => &state.outputs,
        Side::Source => &state.inputs,
    };
    let answer = master_rows(rows, side, |name| {
        let dump = parse_dump(run("pw-dump", &[], budget.left()));
        let rc = std::fs::read_to_string(pw_route::easyeffects_rc()).ok();
        behind(name, side, &dump, rc.as_deref())
    });
    match answer {
        Ok((default_row, target)) => emit::json(&Master {
            name: target.name.clone(),
            object_id: object_id_of(&listed, &target.name),
            description: target.description.clone(),
            volume: target.volume,
            mute: target.mute,
            default: default_row.name.clone(),
        }),
        Err(why) => emit::failure(why),
    }
}

/// The PipeWire object id of the listed node called `name`, for wpctl, or "".
///
/// pipewire-pulse prints it as the `object.id` property, beside the
/// `object.serial` that is pactl's index (RUN, pactl 16.1 on PipeWire 1.0.5:
/// object.id "45", object.serial "46" for one sink). A monitor carries its
/// SINK's properties, so its object.id names the sink: handed to wpctl it
/// would move or mute the speakers instead of the monitor -- the trap the
/// header's source default describes -- so a monitor gets "". Anything that is
/// not a plain number is "" as well: wpctl would take a word for a name it
/// cannot resolve.
fn object_id_of(listed: &[Value], name: &str) -> String {
    listed
        .iter()
        .find(|node| is_named(node, name) && !is_monitor(node))
        .map(|node| prop(props(node), "object.id"))
        .filter(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()))
        .unwrap_or("")
        .to_string()
}

/// Bare, the popup's poll: the three lists, the defaults and the cookie.
fn main() -> ExitCode {
    let args = Args::from_env();
    match mode(&args) {
        Mode::Popup => {}
        Mode::Master(side) => return master(side),
        Mode::Usage => {
            // A side it does not know is a question it cannot answer, and
            // answering the other side would name the wrong device: 2, as
            // emit::unknown_command answers a verb it does not know.
            eprintln!("{}: usage: {} master sink|source", args.program, args.program);
            let _ = emit::json(&serde_json::json!({
                "ok": false,
                "error": "usage: master sink|source",
            }));
            return ExitCode::from(emit::REFUSED);
        }
        Mode::Unknown(verb) => return emit::unknown_command(&args.program, &verb, &["master"]),
    }

    let budget = Budget::new(BUDGET);

    // The cookie first, before any id is read: see `cookie` in the header. The
    // same answer backs up whichever default wpctl does not give below.
    let info = parse(run("pactl", &["-f", "json", "info"], budget.left()));

    let mut sinks = nodes("sinks", &budget);
    let mut sources = nodes("sources", &budget);
    let sink_inputs = nodes("sink-inputs", &budget);

    // Use wpctl for accurate default nodes under PipeWire
    let mut default_sink = wpctl_default(Side::Sink, &budget);
    let mut default_source = wpctl_default(Side::Source, &budget);

    // Fallback to pactl info if wpctl fails
    fill_defaults_from_pactl(&info, &mut default_sink, &mut default_source);

    // A device that arrived after its list was taken: list that kind once
    // more (see the header). Only a list that came back replaces the first
    // one -- a re-list that failed, or ran out of budget, is empty, and an
    // empty list would cost the popup every row to gain one badge.
    if listed_too_early(&sinks, &default_sink) {
        let again = nodes("sinks", &budget);
        if !again.is_empty() {
            sinks = again;
        }
    }
    if listed_too_early(&sources, &default_source) {
        let again = nodes("sources", &budget);
        if !again.is_empty() {
            sources = again;
        }
    }

    let mut state = build_state(&sinks, &sources, &sink_inputs, &default_sink, &default_source);
    state.cookie = cookie_of(&info);

    // An EasyEffects virtual device as the default: find the device behind it
    // (see `via` in the header). Only then, because the graph comes from one
    // whole pw-dump -- tens of milliseconds and hundreds of kilobytes on a
    // busy machine -- and a poll that runs once a second should not pay that
    // for a state most machines are never in.
    let sink_name = inert_default(&state.outputs).map(|row| row.name.clone());
    let source_name = inert_default(&state.inputs).map(|row| row.name.clone());
    if sink_name.is_some() || source_name.is_some() {
        let dump = parse_dump(run("pw-dump", &[], budget.left()));
        let rc = std::fs::read_to_string(pw_route::easyeffects_rc()).ok();
        if let Some(name) = sink_name {
            if let Some(device) = behind(&name, Side::Sink, &dump, rc.as_deref()) {
                route_through(&mut state.outputs, &device);
            }
        }
        if let Some(name) = source_name {
            if let Some(device) = behind(&name, Side::Source, &dump, rc.as_deref()) {
                route_through(&mut state.inputs, &device);
            }
        }
    }

    // Exit 0 even when nothing answered. A machine whose sound server is not
    // running has an empty answer, not a failed helper, and three empty lists
    // are what clear the rows of devices that are gone. The popup reads the
    // status: VolumePopup.qml's audioPoller draws a run only when it exited 0,
    // and otherwise keeps the rows it had under a failure line -- "jayos-audio-state
    // failed, exit N" for a non-zero exit, whatever was printed, and
    // "jayos-audio-state's answer could not be read" for an exit of 0 whose output
    // is not this document. So exiting non-zero here would leave the gone
    // devices on screen under an error that blames the helper.
    // tools/test-audio-state.sh holds both halves: exit 0, and
    // `{"outputs":[],"inputs":[],"apps":[],"cookie":""}` byte for byte, when
    // every tool fails.
    emit::json(&state)
}

/// The server cookie from `pactl -f json info`, or "" when it did not answer.
fn cookie_of(info: &Value) -> String {
    info.get("cookie").and_then(Value::as_str).unwrap_or("").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sink(index: u64, name: &str, description: &str, percent: &str) -> Value {
        json!({
            "index": index,
            "name": name,
            "mute": false,
            "volume": {
                "front-left":  { "value_percent": percent },
                "front-right": { "value_percent": percent }
            },
            "properties": {
                "device.description": description,
                "device.icon_name": "audio-card-analog"
            }
        })
    }

    // ── get_valid_string ────────────────────────────────────────────────────

    #[test]
    fn valid_string_takes_the_first_real_value() {
        assert_eq!(valid_string(&["Speakers", "fallback"]), "Speakers");
    }

    #[test]
    fn valid_string_rejects_the_placeholders_pipewire_hands_out() {
        // Empty, whitespace, and the literal words -- in any case -- are all
        // "this application did not set it".
        assert_eq!(valid_string(&["", "  ", "null", "NULL", "None", "ok"]), "ok");
        assert_eq!(valid_string(&["nUlL", "real"]), "real");
    }

    #[test]
    fn valid_string_rejects_what_pactl_prints_for_a_value_it_could_not_encode() {
        assert_eq!(valid_string(&["(null)", "real"]), "real");
        assert_eq!(valid_string(&[" (null) ", "real"]), "real");
        // Compared whole: a real name that contains the word is a real name.
        assert_eq!(valid_string(&["Null Modem (null) Out"]), "Null Modem (null) Out");
    }

    #[test]
    fn valid_string_is_empty_when_nothing_qualifies() {
        assert_eq!(valid_string(&["", "none"]), "");
        assert_eq!(valid_string(&[]), "");
    }

    #[test]
    fn valid_string_keeps_the_untrimmed_original() {
        // The reject test trims; the value returned does not. Matches the
        // Python, which returned `str(arg)` rather than the stripped copy.
        assert_eq!(valid_string(&[" Living Room "]), " Living Room ");
    }

    // ── volume ──────────────────────────────────────────────────────────────

    #[test]
    fn volume_reads_front_left_then_mono() {
        let stereo = json!({"volume": {"front-left": {"value_percent": "65%"}}});
        assert_eq!(volume_percent(&stereo), 65);

        let mono = json!({"volume": {"mono": {"value_percent": "12%"}}});
        assert_eq!(volume_percent(&mono), 12);

        // front-left wins when both are somehow present.
        let both = json!({"volume": {
            "front-left": {"value_percent": "80%"},
            "mono": {"value_percent": "10%"}
        }});
        assert_eq!(volume_percent(&both), 80);
    }

    #[test]
    fn volume_is_the_first_channel_in_the_nodes_own_map() {
        // What `wpctl get-volume` reports for the same node, which is what the
        // top bar shows beside it. Each shape is one pactl printed against
        // PipeWire 1.0.5.
        fn node(map: &str, levels: &[(&str, &str)]) -> Value {
            let volume: Map<String, Value> = levels
                .iter()
                .map(|(ch, pct)| (ch.to_string(), json!({ "value_percent": pct })))
                .collect();
            json!({ "channel_map": map, "volume": volume })
        }

        // The Pro Audio profile: no front-left, no mono, and it was reading 0.
        let aux = node(
            "aux0,aux1,aux2,aux3",
            &[("aux0", "70%"), ("aux1", "70%"), ("aux2", "70%"), ("aux3", "70%")],
        );
        assert_eq!(volume_percent(&aux), 70);

        // A front-center-only node, which was reading 0 too.
        let center = node("front-center", &[("front-center", "55%")]);
        assert_eq!(volume_percent(&center), 55);

        // The first channel, not the loudest -- 40 is what wpctl says here.
        let surround = node(
            "front-left,front-right,rear-left,rear-right",
            &[
                ("front-left", "40%"),
                ("front-right", "40%"),
                ("rear-left", "90%"),
                ("rear-right", "90%"),
            ],
        );
        assert_eq!(volume_percent(&surround), 40);

        // The first channel, not front-left: wpctl reads 0.30 for this node.
        let rear_first =
            node("rear-left,front-left", &[("rear-left", "30%"), ("front-left", "80%")]);
        assert_eq!(volume_percent(&rear_first), 30);

        // A hard-right balance (left silent) reads 0 in both places -- here
        // and in wpctl, whose first channel is front-left too -- which is the
        // agreement being kept rather than a node read as silent by mistake.
        let hard_right =
            node("front-left,front-right", &[("front-left", "0%"), ("front-right", "100%")]);
        assert_eq!(volume_percent(&hard_right), 0);
    }

    #[test]
    fn with_no_usable_map_the_loudest_channel_stands_in() {
        // Past front-left and mono, the loudest -- not the first key in
        // sorted order, which is aux0 and reads 20.
        let unmapped = json!({"volume": {
            "aux0": {"value_percent": "20%"},
            "aux1": {"value_percent": "60%"}
        }});
        assert_eq!(volume_percent(&unmapped), 60);

        // A map naming a channel the volume object does not hold is no map.
        let stale = json!({"channel_map": "front-center",
                           "volume": {"front-left": {"value_percent": "35%"}}});
        assert_eq!(volume_percent(&stale), 35);
    }

    #[test]
    fn volume_is_zero_only_when_there_is_no_channel_to_read() {
        assert_eq!(volume_percent(&json!({})), 0);
        assert_eq!(volume_percent(&json!({"volume": "unavailable"})), 0);
        assert_eq!(volume_percent(&json!({"volume": {}})), 0);
        assert_eq!(volume_percent(&json!({"volume": {"front-left": {}}})), 0);
    }

    #[test]
    fn volume_above_a_hundred_is_kept() {
        // PipeWire allows boosting past 100%, and the popup draws it.
        let loud = json!({"volume": {"front-left": {"value_percent": "153%"}}});
        assert_eq!(volume_percent(&loud), 153);
    }

    #[test]
    fn volume_that_cannot_be_parsed_reads_as_zero_rather_than_killing_the_poll() {
        let odd = json!({"volume": {"front-left": {"value_percent": "n/a"}}});
        assert_eq!(volume_percent(&odd), 0);
    }

    // ── mute ────────────────────────────────────────────────────────────────

    #[test]
    fn mute_defaults_to_false_and_follows_python_truthiness() {
        assert!(!truthy(None));
        assert!(!truthy(Some(&json!(null))));
        assert!(!truthy(Some(&json!(false))));
        assert!(truthy(Some(&json!(true))));
        assert!(!truthy(Some(&json!(0))));
        assert!(truthy(Some(&json!("no"))));
        assert!(!truthy(Some(&json!(""))));
    }

    // ── id ──────────────────────────────────────────────────────────────────

    #[test]
    fn id_is_the_index_as_a_string() {
        assert_eq!(index_string(&json!({"index": 55})), "55");
        assert_eq!(index_string(&json!({"index": "55"})), "55");
    }

    #[test]
    fn a_node_with_no_index_keeps_pythons_none_string() {
        // Ported as-is. See `index_string`.
        assert_eq!(index_string(&json!({})), "None");
        assert_eq!(index_string(&json!({"index": null})), "None");
    }

    // ── default matching ────────────────────────────────────────────────────

    #[test]
    fn default_matching_is_by_node_name() {
        let s = json!({"name": "alsa_output.pci-0000_00_1f.3.analog-stereo"});
        assert!(is_named(&s, "alsa_output.pci-0000_00_1f.3.analog-stereo"));
        assert!(!is_named(&s, "alsa_output.usb-Some_DAC"));
    }

    #[test]
    fn a_nameless_node_is_never_the_default_even_when_nothing_is() {
        // Both defaults empty is the "no sound server answered" case; nothing
        // should light up as Active Default because of it.
        assert!(!is_named(&json!({}), ""));
        assert!(!is_named(&json!({"name": null}), ""));
    }

    // ── wpctl parsing ───────────────────────────────────────────────────────

    #[test]
    fn node_name_comes_from_the_first_matching_property_line() {
        let out = "\
id 51, type PipeWire:Interface:Node
  properties:
    * alsa.card = \"0\"
    * media.class = \"Audio/Sink\"
    * node.name = \"alsa_output.pci-0000_00_1f.3.analog-stereo\"
    * node.nick = \"ALC257 Analog\"
    * priority.driver = 1009
";
        assert_eq!(node_name_in(out), "alsa_output.pci-0000_00_1f.3.analog-stereo");
    }

    #[test]
    fn a_description_mentioning_node_name_is_not_the_name() {
        // Real wpctl order, cut from `wpctl inspect @DEFAULT_AUDIO_SINK@`
        // (WirePlumber 0.4.17): sorted by key, so the description comes first.
        let out = "\
id 214, type PipeWire:Interface:Node
    audio.channels = \"2\"
  * media.class = \"Audio/Sink\"
  * node.description = \"Studio node.name = decoy\"
    node.driver = \"true\"
  * node.name = \"spoofy\"
  * object.serial = \"420\"
";
        assert_eq!(node_name_in(out), "spoofy");
    }

    #[test]
    fn a_key_that_only_ends_in_node_name_is_not_the_name() {
        let out = "    * api.bluez5.node.name = \"not_it\"\n    * node.name = \"real_node\"\n";
        assert_eq!(node_name_in(out), "real_node");
    }

    #[test]
    fn a_node_name_line_with_no_equals_does_not_stop_the_search() {
        let out = "  node.name is missing here\n    * node.name = \"real_node\"\n";
        assert_eq!(node_name_in(out), "real_node");
    }

    #[test]
    fn a_node_name_printed_twice_is_no_name_whichever_comes_first() {
        // A value with a newline in it forges a whole property line. From the
        // description, which sorts before node.name, the forgery comes first;
        // from the nick, which sorts after, it comes last. First-wins is
        // fooled by the one and last-wins by the other.
        let real = "id 31, type PipeWire:Interface:Node
  * media.class = \"Audio/Sink\"
  * node.description = \"USB Headset\"
  * node.name = \"alsa_output.usb-headset\"
  * node.nick = \"Headset\"
";
        assert_eq!(node_name_in(real), "alsa_output.usb-headset");
        let before = real.replace("\"USB Headset\"", "\"x\"\n  * node.name = \"decoy\"");
        let after = real.replace("\"Headset\"", "\"x\"\n  * node.name = \"decoy\"");
        for forged in [&before, &after] {
            assert_eq!(forged.matches("node.name").count(), 2, "the forgery was built");
            assert_eq!(node_name_in(forged), "", "{forged}");
            assert_eq!(default_from_inspect(forged, Side::Sink), "");
            assert_eq!(inspected(forged), None);
        }
    }

    #[test]
    fn no_node_name_is_an_empty_string() {
        // What wpctl prints when the target does not resolve, and what the
        // Python's "[]" placeholder degraded to.
        assert_eq!(node_name_in("Object 'x' not found\n"), "");
        assert_eq!(node_name_in("[]"), "");
    }

    #[test]
    fn a_sink_named_as_the_default_source_is_read_as_its_monitor() {
        // What `wpctl inspect @DEFAULT_AUDIO_SOURCE@` printed with a monitor
        // chosen as the default source (WirePlumber 0.4.17), cut down.
        let monitor = "\
id 52, type PipeWire:Interface:Node
  * media.class = \"Audio/Sink\"
  * node.description = \"Fake-Mic\"
  * node.name = \"alsa_input.fake_mic_sink\"
";
        assert_eq!(default_from_inspect(monitor, Side::Source), "alsa_input.fake_mic_sink.monitor");
        // The same answer for the SINK is the sink itself.
        assert_eq!(default_from_inspect(monitor, Side::Sink), "alsa_input.fake_mic_sink");

        // A real source, and EasyEffects' virtual one, are taken as named.
        let mic = "  * media.class = \"Audio/Source\"\n  * node.name = \"alsa_input.usb\"\n";
        assert_eq!(default_from_inspect(mic, Side::Source), "alsa_input.usb");
        let virt =
            "  * media.class = \"Audio/Source/Virtual\"\n  * node.name = \"easyeffects_source\"\n";
        assert_eq!(default_from_inspect(virt, Side::Source), "easyeffects_source");
        // Nothing named is nothing, not ".monitor".
        assert_eq!(default_from_inspect("  * media.class = \"Audio/Sink\"\n", Side::Source), "");
    }

    // ── a device that arrived between the list and the default ──────────────

    #[test]
    fn a_default_the_list_lacks_is_listed_again() {
        let sinks = vec![sink(40, "alsa_output.speakers", "Speakers", "30%")];
        assert!(listed_too_early(&sinks, "bluez_output.headset"));
        // Listed already: nothing to gain.
        assert!(!listed_too_early(&sinks, "alsa_output.speakers"));
        // No default at all is the no-server case, not a late device.
        assert!(!listed_too_early(&sinks, ""));
        assert!(!listed_too_early(&[], ""));
        // An empty list with a default is still late -- the device may be the
        // only one, plugged in during the gap.
        assert!(listed_too_early(&[], "bluez_output.headset"));
    }

    #[test]
    fn a_monitor_default_source_is_listed_under_its_monitor_name() {
        // wpctl names the sink; pactl lists `<sink>.monitor`. Re-listing would
        // happen on every poll and never match.
        let sources = vec![json!({"index": 56, "name": "alsa_input.fake_mic_sink.monitor",
                                  "properties": {"device.class": "monitor"}})];
        assert!(!listed_too_early(&sources, "alsa_input.fake_mic_sink"));
    }

    #[test]
    fn a_node_pactl_could_not_name_might_be_the_default() {
        let sinks = vec![json!({"index": 74, "name": "(null)"})];
        assert!(!listed_too_early(&sinks, "Élan-sink"));
    }

    // ── pactl info fallback ─────────────────────────────────────────────────

    #[test]
    fn pactl_info_only_fills_the_default_wpctl_missed() {
        let info = json!({
            "default_sink_name": "pactl_sink",
            "default_source_name": "pactl_source"
        });
        let mut sink = "wpctl_sink".to_string();
        let mut source = String::new();
        fill_defaults_from_pactl(&info, &mut sink, &mut source);
        assert_eq!(sink, "wpctl_sink");
        assert_eq!(source, "pactl_source");
    }

    #[test]
    fn a_pactl_info_that_is_not_an_object_changes_nothing() {
        // `parse` returns an empty ARRAY when pactl failed, and the Python's
        // `info.get` raised on it into a bare `except: pass`.
        let mut sink = String::new();
        let mut source = String::new();
        fill_defaults_from_pactl(&json!([]), &mut sink, &mut source);
        assert_eq!(sink, "");
        assert_eq!(source, "");
    }

    // ── row shape ───────────────────────────────────────────────────────────

    #[test]
    fn a_device_row_puts_the_description_in_front_and_the_node_name_behind() {
        let s = sink(55, "alsa_output.hdmi", "Big Screen HDMI", "40%");
        let node = format_node(&s, true, false);
        assert_eq!(
            node,
            Node {
                id: "55".into(),
                name: "alsa_output.hdmi".into(),
                description: "Big Screen HDMI".into(),
                volume: 40,
                mute: false,
                is_default: true,
                icon: "audio-card-analog".into(),
                inert: false,
                via: String::new(),
                // Nothing in its name or properties says what it is plugged
                // into, so nothing is said.
                detail: String::new(),
            }
        );
    }

    // ── detail: what a row says under its title ─────────────────────────────

    /// A device as pactl lists one, with the properties given.
    fn device(name: &str, description: &str, properties: Value) -> Value {
        let mut p = properties;
        p["device.description"] = Value::String(description.to_string());
        json!({ "index": 52, "name": name, "properties": p })
    }

    #[test]
    fn a_usb_device_says_usb_under_its_title() {
        // The owner's DAC as pactl lists it under PipeWire: the node name was
        // its subtitle, "alsa_output.usb-Schiit_Audio_Schiit_Modi_3-00...".
        let schiit = device(
            "alsa_output.usb-Schiit_Audio_Schiit_Modi_3-00.analog-stereo",
            "Schiit Modi 3+ Analog Stereo",
            json!({
                "alsa.driver_name": "snd_usb_audio",
                "api.alsa.card.longname": "Schiit Audio Schiit Modi 3+ at usb-0000:0c:00.3-1, high speed",
                "device.profile.name": "analog-stereo"
            }),
        );
        assert_eq!(format_node(&schiit, true, false).detail, "USB");
        // Each of the three things that say USB is enough on its own.
        for props in [
            json!({"alsa.driver_name": "snd_usb_audio"}),
            json!({"api.alsa.card.longname": "Elgato Wave:3 at usb-0000:0c:00.3-2, full speed"}),
            json!({"device.bus": "usb"}),
        ] {
            let d = device("alsa_input.renamed-by-a-rule", "Elgato Wave:3 Mono", props.clone());
            assert_eq!(format_node(&d, false, false).detail, "USB", "{props}");
        }
        // And so is the node name WirePlumber gave it, with no properties.
        let named = device(
            "alsa_input.usb-Elgato_Systems_Elgato_Wave_3-00.mono-fallback",
            "Elgato Wave:3 Mono",
            json!({}),
        );
        assert_eq!(format_node(&named, false, false).detail, "USB");
    }

    #[test]
    fn a_bluetooth_device_says_bluetooth() {
        let headset = device(
            "bluez_output.AC_80_0A_1F_33_5E.1",
            "WH-1000XM5",
            json!({"api.bluez5.address": "AC:80:0A:1F:33:5E", "api.bluez5.codec": "ldac"}),
        );
        assert_eq!(format_node(&headset, false, false).detail, "Bluetooth");
        let bare = device("bluez_input.AC_80_0A_1F_33_5E.0", "WH-1000XM5", json!({}));
        assert_eq!(format_node(&bare, false, false).detail, "Bluetooth");
        let api = device("headset", "WH-1000XM5", json!({"device.api": "bluez5"}));
        assert_eq!(format_node(&api, false, false).detail, "Bluetooth");
    }

    #[test]
    fn an_hdmi_output_says_its_port_unless_the_title_already_does() {
        // WirePlumber's own description ends in the profile's, "(HDMI 3)", and
        // a subtitle saying it again says nothing.
        let gpu = device(
            "alsa_output.pci-0000_01_00.1.hdmi-stereo-extra2",
            "AD103 High Definition Audio Controller Digital Stereo (HDMI 3)",
            json!({}),
        );
        assert_eq!(format_node(&gpu, false, false).detail, "");
        // A description of somebody's own does not, and the port is said.
        let renamed =
            device("alsa_output.pci-0000_01_00.1.hdmi-stereo-extra2", "Odyssey G9", json!({}));
        assert_eq!(format_node(&renamed, false, false).detail, "HDMI 3");
        let first = device("alsa_output.pci-0000_01_00.1.hdmi-stereo", "Odyssey G9", json!({}));
        assert_eq!(format_node(&first, false, false).detail, "HDMI");
        let surround =
            device("alsa_output.pci-0000_01_00.1.hdmi-surround71-extra1", "Living room", json!({}));
        assert_eq!(format_node(&surround, false, false).detail, "HDMI 2");
        // The profile property, where it is there, over the name's last part.
        let prop = device(
            "alsa_output.gpu",
            "Odyssey G9",
            json!({"device.profile.name": "hdmi-stereo-extra3"}),
        );
        assert_eq!(format_node(&prop, false, false).detail, "HDMI 4");
    }

    #[test]
    fn a_device_on_no_bus_worth_naming_says_nothing() {
        // The motherboard's own codec, EasyEffects' virtual sink and a null
        // sink: their titles are what they are.
        for (name, description) in [
            (
                "alsa_output.pci-0000_13_00.6.analog-stereo",
                "Family 17h/19h HD Audio Controller Analog Stereo",
            ),
            ("easyeffects_sink", "Easy Effects Sink"),
            ("vp123_a", "A"),
        ] {
            assert_eq!(
                format_node(&device(name, description, json!({})), false, false).detail,
                "",
                "{name}"
            );
        }
    }

    #[test]
    fn the_monitor_of_a_usb_output_says_usb() {
        // A monitor is an input row while it is the default source; its title
        // is "Monitor of <sink>", and its bus is its sink's.
        let monitor = json!({
            "index": 52,
            "name": "alsa_output.usb-Schiit_Audio_Schiit_Modi_3-00.analog-stereo.monitor",
            "description": "Monitor of Schiit Modi 3+ Analog Stereo",
            "properties": {"device.description": "Schiit Modi 3+ Analog Stereo", "device.class": "monitor"}
        });
        let node = format_node(&monitor, true, false);
        assert_eq!(node.description, "Monitor of Schiit Modi 3+ Analog Stereo");
        assert_eq!(node.detail, "USB");
    }

    #[test]
    fn a_subtitle_that_repeats_its_title_is_dropped_as_whole_words() {
        assert!(repeats("USB Headset", "USB"));
        assert!(repeats("spotify", "Spotify"));
        assert!(repeats("Digital Stereo (HDMI 3)", "HDMI 3"));
        assert!(repeats("Anything", ""), "nothing to say repeats nothing worth saying");
        // Inside a word is not a repeat: "usb" is in "Busby".
        assert!(!repeats("Busby Speakers", "USB"));
        assert!(
            repeats("Digital Stereo (HDMI 3)", "HDMI"),
            "the title says HDMI, as a word of its own"
        );
        assert!(!repeats("Digital Stereo (HDMI 3)", "HDMI 2"));
        assert!(!repeats("Firefox", "Some Video - YouTube"));
        let busby = device("alsa_output.usb-Busby-00.analog-stereo", "Busby Speakers", json!({}));
        assert_eq!(format_node(&busby, false, false).detail, "USB");
    }

    #[test]
    fn a_stream_says_its_track_but_not_its_programs_name_for_every_stream() {
        let stream = |app: &str, props: Value| {
            let mut p = props;
            p["application.name"] = Value::String(app.to_string());
            format_node(&json!({ "index": 120, "properties": p }), false, true)
        };
        // The track, when it is one.
        assert_eq!(stream("mpv", json!({"media.name": "Some Song"})).detail, "Some Song");
        // Spotify names its stream "Spotify": the reviewer's "spotify" over
        // "Spotify".
        assert_eq!(stream("spotify", json!({"media.name": "Spotify"})).detail, "");
        // Firefox, Chromium and WebRTC name every stream the same.
        for placeholder in STREAM_PLACEHOLDERS {
            let s = stream("Firefox", json!({"media.name": placeholder}));
            assert_eq!(s.detail, "", "{placeholder}");
            // The name field still carries it, for the tests that hold it.
            assert_eq!(s.name, placeholder);
        }
        // Past a placeholder to a window title that says something.
        let titled = stream(
            "Firefox",
            json!({"media.name": "AudioStream", "window.title": "Some Video - YouTube"}),
        );
        assert_eq!(titled.detail, "Some Video - YouTube");
        // A role, or nothing at all, is not a track.
        assert_eq!(stream("Firefox", json!({"media.role": "music"})).detail, "");
        assert_eq!(stream("Firefox", json!({})).detail, "");
        // Compared whole and as written: a track that only contains one is a
        // track.
        assert_eq!(stream("vlc", json!({"media.name": "Playback test"})).detail, "Playback test");
    }

    #[test]
    fn a_device_with_no_description_falls_back_to_its_node_name() {
        let s = json!({"index": 3, "name": "alsa_output.usb", "properties": {}});
        let node = format_node(&s, false, false);
        assert_eq!(node.description, "alsa_output.usb");
        assert_eq!(node.name, "alsa_output.usb");
        assert_eq!(node.icon, "audio-card");
    }

    #[test]
    fn a_device_with_nothing_at_all_still_renders_something() {
        let node = format_node(&json!({"index": 9}), false, false);
        assert_eq!(node.description, "Unknown Device");
        assert_eq!(node.name, "Unknown");
        assert_eq!(node.icon, "audio-card");
    }

    #[test]
    fn a_stream_row_is_the_application_over_the_track() {
        let s = json!({
            "index": 120,
            "mute": true,
            "volume": {"front-left": {"value_percent": "100%"}},
            "properties": {
                "application.name": "Spotify",
                "application.process.binary": "spotify",
                "media.name": "Some Song",
                "application.icon_name": "spotify-client"
            }
        });
        let node = format_node(&s, false, true);
        assert_eq!(node.description, "Spotify");
        assert_eq!(node.name, "Some Song");
        assert_eq!(node.icon, "spotify-client");
        assert!(node.mute);
    }

    #[test]
    fn a_stream_with_no_owner_is_an_unknown_app() {
        let s = json!({"index": 7, "properties": {"media.name": "beep"}});
        assert_eq!(format_node(&s, false, true).description, "Unknown App");
    }

    #[test]
    fn a_stream_titled_by_its_binary_keeps_the_binarys_case() {
        // application.process.binary is only ever a fallback TITLE now, and a
        // title is shown as the client gave it. The lowercasing the retired
        // `binary` key did was never applied to it, and must not start.
        let s = json!({
            "index": 7,
            "properties": { "application.process.binary": "Telegram" }
        });
        assert_eq!(format_node(&s, false, true).description, "Telegram");
    }

    #[test]
    fn a_stream_falls_through_media_name_to_window_title_to_role() {
        let s = json!({
            "index": 7,
            "properties": {
                "application.name": "Firefox",
                "media.name": "null",
                "window.title": "Some Video - YouTube"
            }
        });
        assert_eq!(format_node(&s, false, true).name, "Some Video - YouTube");

        let roled = json!({
            "index": 8,
            "properties": { "application.name": "Firefox", "media.role": "music" }
        });
        assert_eq!(format_node(&roled, false, true).name, "music");

        let bare = json!({"index": 9, "properties": {"application.name": "Firefox"}});
        assert_eq!(format_node(&bare, false, true).name, "Audio Stream");
    }

    #[test]
    fn a_value_pactl_could_not_encode_falls_through_to_the_next_candidate() {
        // What `pactl -f json` printed for a sink described "Jay’s AirPods",
        // and for a pacat stream named "Élan" playing "Café del Mar – YouTube".
        let device = json!({
            "index": 74,
            "name": "bluez_output.AA_BB_CC_DD_EE_FF.1",
            "properties": { "device.description": "(null)", "device.icon_name": "(null)" }
        });
        let node = format_node(&device, false, false);
        assert_eq!(node.description, "bluez_output.AA_BB_CC_DD_EE_FF.1");
        assert_eq!(node.icon, "audio-card");

        let stream = json!({
            "index": 94,
            "properties": {
                "application.name": "(null)",
                "media.name": "(null)",
                "application.icon_name": "(null)",
                "application.process.binary": "pacat"
            }
        });
        let node = format_node(&stream, false, true);
        assert_eq!(node.description, "pacat");
        assert_eq!(node.name, "Audio Stream");
        assert_eq!(node.icon, "audio-card");

        // With the binary lost too, the title is the last resort, never a
        // program called "(null)".
        let orphan = json!({
            "index": 95,
            "properties": {
                "application.name": "(null)",
                "application.process.binary": "(null)"
            }
        });
        assert_eq!(format_node(&orphan, false, true).description, "Unknown App");
    }

    #[test]
    fn a_property_that_is_not_a_string_is_treated_as_absent() {
        // Defence, not a description of pactl: it prints "" or "(null)", never
        // JSON null. A pactl that started to would still get a usable row.
        let s = json!({
            "index": 4,
            "name": "alsa_input.usb",
            "properties": { "device.description": null, "device.icon_name": 7 }
        });
        let node = format_node(&s, false, false);
        assert_eq!(node.description, "alsa_input.usb");
        assert_eq!(node.icon, "audio-card");
    }

    /// A pw-dump array holding one node with these props, in pw-dump's shape.
    fn pw_dump_of(id: u64, props: Value) -> Value {
        json!([{ "id": id, "type": "PipeWire:Interface:Node", "info": { "props": props } }])
    }

    #[test]
    fn pw_dump_restores_what_pactl_could_not_encode() {
        // Both halves cut from one real session (PipeWire 1.0.5): pactl's
        // sink and stream, and pw-dump's copy of each, with its renamed keys.
        let mut sink = json!({
            "index": 74,
            "name": "utf_sink",
            "properties": { "device.description": "(null)", "object.serial": "74" }
        });
        let dump = pw_dump_of(
            58,
            json!({
                "node.name": "utf_sink",
                "node.description": "Jay’s AirPods",
                "object.serial": 74
            }),
        );
        assert!(lost_to_pactl(&sink));
        restore_from_pw_dump(&mut sink, &dump);
        assert_eq!(format_node(&sink, false, false).description, "Jay’s AirPods");
        assert!(!lost_to_pactl(&sink));

        let mut stream = json!({
            "index": 94,
            "name": "(null)",
            "properties": {
                "application.name": "(null)",
                "media.name": "(null)",
                "media.role": "(null)",
                "application.icon_name": "(null)",
                "application.process.binary": "pacat"
            }
        });
        let dump = pw_dump_of(
            63,
            json!({
                "application.name": "Élan",
                "media.name": "Café del Mar – YouTube",
                "media.role": "Música",
                "application.icon-name": "élan-icon",
                "application.process.binary": "pacat",
                "node.name": "Élan",
                "object.serial": 94
            }),
        );
        restore_from_pw_dump(&mut stream, &dump);
        let node = format_node(&stream, false, true);
        assert_eq!(node.description, "Élan");
        assert_eq!(node.name, "Café del Mar – YouTube");
        assert_eq!(node.icon, "élan-icon");
        assert_eq!(stream["name"], json!("Élan"));
        // Not drawn while media.name stands, but the subtitle falls back to it.
        assert_eq!(stream["properties"]["media.role"], json!("Música"));
    }

    #[test]
    fn pw_dump_is_joined_on_the_serial_never_the_id() {
        // `pw-dump 74` answers with every object whose id OR serial is 74.
        let mut sink = json!({
            "index": 74,
            "name": "utf_sink",
            "properties": { "device.description": "(null)" }
        });
        let dump = json!([
            { "id": 74, "info": { "props": { "node.description": "Wrong Node", "object.serial": 120 } } },
            { "id": 58, "info": { "props": { "node.description": "Right Node", "object.serial": 74 } } }
        ]);
        restore_from_pw_dump(&mut sink, &dump);
        assert_eq!(sink["properties"]["device.description"], json!("Right Node"));
    }

    #[test]
    fn only_what_pactl_lost_is_replaced() {
        let mut sink = json!({
            "index": 74,
            "name": "utf_sink",
            "properties": { "device.description": "Speakers", "device.icon_name": "(null)" }
        });
        let dump = pw_dump_of(
            58,
            json!({
                "node.name": "something_else",
                "node.description": "PipeWire's Own Description",
                "device.icon-name": "audio-speakers",
                "object.serial": 74
            }),
        );
        restore_from_pw_dump(&mut sink, &dump);
        assert_eq!(sink["name"], json!("utf_sink"));
        assert_eq!(sink["properties"]["device.description"], json!("Speakers"));
        assert_eq!(sink["properties"]["device.icon_name"], json!("audio-speakers"));

        // A node pactl encoded whole never sends anyone to pw-dump.
        assert!(!lost_to_pactl(&json!({"name": "a", "properties": {"media.name": "b"}})));
        // And no matching serial, no pw-dump, or a pw-dump that printed
        // nothing usable all leave the placeholder for valid_string to reject.
        let mut lost = json!({"index": 5, "properties": {"media.name": "(null)"}});
        restore_from_pw_dump(&mut lost, &json!([]));
        restore_from_pw_dump(&mut lost, &pw_dump_of(5, json!({"object.serial": 6})));
        assert_eq!(lost["properties"]["media.name"], json!("(null)"));
    }

    // ── filtering ───────────────────────────────────────────────────────────

    #[test]
    fn monitor_sources_are_recognised_by_class_or_by_suffix() {
        assert!(is_monitor(&json!({
            "name": "alsa_output.hdmi.monitor",
            "properties": {"device.class": "monitor"}
        })));
        // No class at all, but the name says what it is.
        assert!(is_monitor(&json!({"name": "alsa_output.hdmi.monitor"})));
        assert!(!is_monitor(&json!({
            "name": "alsa_input.usb-Blue_Yeti",
            "properties": {"device.class": "sound"}
        })));
        assert!(!is_monitor(&json!({})));
    }

    #[test]
    fn a_monitor_that_is_the_default_source_is_listed_and_marked() {
        // The hero shows the default input and acts on its id; a monitor
        // dropped from the list left no input marked and the hero on the
        // first microphone, while the controls reached the monitor.
        let sources = vec![
            // pactl's shape: the property is the sink's description, the
            // top-level one is the monitor's own.
            json!({"index": 1, "name": "alsa_output.hdmi.monitor", "description": "Monitor of HDMI",
                   "properties": {"device.class": "monitor",
                                  "device.description": "HDMI"}}),
            json!({"index": 3, "name": "alsa_output.pci.monitor",
                   "properties": {"device.class": "monitor"}}),
            json!({"index": 2, "name": "alsa_input.usb-Blue_Yeti",
                   "properties": {"device.description": "Yeti"}}),
        ];
        let state = build_state(&[], &sources, &[], "", "alsa_output.hdmi.monitor");
        assert_eq!(
            state.inputs.iter().map(|i| (i.id.as_str(), i.is_default)).collect::<Vec<_>>(),
            vec![("1", true), ("2", false)]
        );
        assert_eq!(state.inputs[0].description, "Monitor of HDMI");
    }

    #[test]
    fn the_inputs_tab_holds_only_real_microphones() {
        let sources = vec![
            json!({"index": 1, "name": "alsa_output.hdmi.monitor",
                   "properties": {"device.class": "monitor"}}),
            json!({"index": 2, "name": "alsa_input.usb-Blue_Yeti",
                   "properties": {"device.description": "Yeti"}}),
        ];
        let state = build_state(&[], &sources, &[], "", "alsa_input.usb-Blue_Yeti");
        assert_eq!(state.inputs.len(), 1);
        assert_eq!(state.inputs[0].description, "Yeti");
        assert!(state.inputs[0].is_default);
    }

    #[test]
    fn every_playback_stream_is_listed_and_none_is_the_default() {
        // pavucontrol's application.id included: its meters are source-outputs
        // and never arrive here, so a sink-input carrying that id is something
        // pavucontrol really plays, and it belongs on the Streams tab.
        let streams = vec![
            json!({"index": 1, "properties": {"application.id": "org.PulseAudio.pavucontrol",
                                              "application.name": "PulseAudio Volume Control"}}),
            json!({"index": 2, "properties": {"application.name": "mpv"}}),
        ];
        let state = build_state(&[], &[], &streams, "", "");
        assert_eq!(
            state.apps.iter().map(|a| a.description.as_str()).collect::<Vec<_>>(),
            vec!["PulseAudio Volume Control", "mpv"]
        );
        // A stream is never the default of anything.
        assert!(state.apps.iter().all(|a| !a.is_default));
    }

    #[test]
    fn a_corked_stream_is_listed_like_a_playing_one() {
        // `corked` is what pactl reports for a paused stream (RUN: a libpulse
        // client with one corked and one running stream, pactl 16.1). The
        // header promises paused streams are listed; this holds it.
        let streams = vec![
            json!({"index": 7, "corked": false, "properties": {"application.name": "mpv"}}),
            json!({"index": 8, "corked": true, "properties": {"application.name": "Spotify"}}),
        ];
        let state = build_state(&[], &[], &streams, "", "");
        assert_eq!(state.apps.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), vec!["7", "8"]);
    }

    #[test]
    fn exactly_one_output_is_marked_default() {
        let sinks = vec![
            sink(1, "alsa_output.pci", "Speakers", "30%"),
            sink(2, "alsa_output.hdmi", "HDMI", "100%"),
        ];
        let state = build_state(&sinks, &[], &[], "alsa_output.hdmi", "");
        assert_eq!(
            state.outputs.iter().map(|o| o.is_default).collect::<Vec<_>>(),
            vec![false, true]
        );
    }

    #[test]
    fn a_default_that_matches_nothing_leaves_every_row_unmarked() {
        // The failure the wpctl lookup exists to avoid: pactl and WirePlumber
        // disagreeing means no row matches and the hero falls back to the
        // first. Still valid output, which is why it is not an error.
        let sinks = vec![sink(1, "alsa_output.pci", "Speakers", "30%")];
        let state = build_state(&sinks, &[], &[], "some_other_sink", "");
        assert!(!state.outputs[0].is_default);
    }

    // ── EasyEffects' virtual devices ────────────────────────────────────────

    /// A pactl node shaped like EasyEffects 8's virtual sink or source.
    fn easyeffects_node(index: u64, name: &str, channel_volumes: &str) -> Value {
        json!({
            "index": index,
            "name": name,
            "mute": false,
            "volume": {"front-left": {"value_percent": "100%"}},
            "properties": {
                "application.id": "com.github.wwmm.easyeffects",
                "device.description": "Easy Effects Sink",
                "monitor.channel-volumes": channel_volumes,
                "node.virtual": "true"
            }
        })
    }

    #[test]
    fn easyeffects_virtual_devices_are_marked_inert_and_hardware_is_not() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
        ];
        let state = build_state(&sinks, &[], &[], "alsa_output.speakers", "");
        assert_eq!(state.outputs.iter().map(|o| o.inert).collect::<Vec<_>>(), vec![false, true]);
        // With EasyEffects' "monitor channel volumes" on, its controls work.
        let on = vec![easyeffects_node(66, "easyeffects_sink", "true")];
        assert!(!build_state(&on, &[], &[], "", "").outputs[0].inert);
        // A stream is never inert, EasyEffects' own included.
        let streams = vec![json!({"index": 9, "properties": {
            "application.id": "com.github.wwmm.easyeffects", "application.name": "EasyEffects"}})];
        assert!(!build_state(&[], &[], &streams, "", "").apps[0].inert);
    }

    #[test]
    fn the_monitor_of_easyeffects_sink_as_default_source_is_a_live_row() {
        // pactl lists the monitor with the sink's properties plus
        // device.class "monitor" (RUN, pactl 16.1), and its own controls
        // work. Read as inert, the row drew no slider or mute and the hero
        // moved the microphone EasyEffects records instead.
        let mut monitor = easyeffects_node(124, "easyeffects_sink.monitor", "false");
        monitor["description"] = json!("Monitor of Easy Effects Sink");
        monitor["properties"]["device.class"] = json!("monitor");
        monitor["properties"]["node.name"] = json!("easyeffects_sink");
        let sources = vec![
            monitor,
            json!({"index": 133, "name": "alsa_input.usb-mic", "properties": {"device.class": "sound"}}),
        ];
        let mut state = build_state(&[], &sources, &[], "", "easyeffects_sink.monitor");
        assert!(state.inputs[0].is_default);
        assert!(!state.inputs[0].inert);
        assert!(inert_default(&state.inputs).is_none());
        // Nothing to route, even when EasyEffects' rc names a microphone.
        route_through(&mut state.inputs, "alsa_input.usb-mic");
        assert!(state.inputs.iter().all(|i| i.via.is_empty()));
    }

    #[test]
    fn an_inert_default_is_routed_through_the_listed_device_behind_it() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            sink(49, "alsa_output.headphones", "Headphones", "70%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
        ];
        let mut state = build_state(&sinks, &[], &[], "easyeffects_sink", "");
        assert_eq!(inert_default(&state.outputs).map(|r| r.id.as_str()), Some("66"));
        route_through(&mut state.outputs, "alsa_output.headphones");
        assert_eq!(
            state.outputs.iter().map(|o| o.via.as_str()).collect::<Vec<_>>(),
            vec!["", "", "49"]
        );
    }

    #[test]
    fn nothing_is_routed_to_an_unlisted_or_inert_device_or_from_a_live_default() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
            easyeffects_node(67, "easyeffects_other", "false"),
        ];
        let mut state = build_state(&sinks, &[], &[], "easyeffects_sink", "");
        route_through(&mut state.outputs, "alsa_output.gone");
        route_through(&mut state.outputs, "easyeffects_other");
        assert!(state.outputs.iter().all(|o| o.via.is_empty()));

        // A hardware default has nothing to route: its own controls work.
        let mut state = build_state(&sinks, &[], &[], "alsa_output.speakers", "");
        assert!(inert_default(&state.outputs).is_none());
        route_through(&mut state.outputs, "alsa_output.speakers");
        assert!(state.outputs.iter().all(|o| o.via.is_empty()));
    }

    // ── master: the node every other control acts on ────────────────────────

    #[test]
    fn a_live_default_is_its_own_master_and_the_graph_is_not_asked() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
        ];
        let state = build_state(&sinks, &[], &[], "alsa_output.speakers", "");
        let (default, target) =
            master_rows(&state.outputs, Side::Sink, |_| panic!("pw-dump asked for a live default"))
                .unwrap();
        assert_eq!(
            (default.name.as_str(), target.name.as_str()),
            ("alsa_output.speakers", "alsa_output.speakers")
        );
        // EasyEffects' sink with "monitor channel volumes" on is live too: its
        // own level works, so it is what the controls move.
        let on = vec![easyeffects_node(66, "easyeffects_sink", "true")];
        let state = build_state(&on, &[], &[], "easyeffects_sink", "");
        let (_, target) =
            master_rows(&state.outputs, Side::Sink, |_| panic!("pw-dump asked")).unwrap();
        assert_eq!(target.name, "easyeffects_sink");
    }

    #[test]
    fn an_inert_default_masters_the_device_behind_it_as_the_popups_via_does() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            sink(49, "alsa_output.headphones", "Headphones", "70%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
        ];
        let mut state = build_state(&sinks, &[], &[], "easyeffects_sink", "");
        let (default, target) = master_rows(&state.outputs, Side::Sink, |name| {
            assert_eq!(name, "easyeffects_sink");
            Some("alsa_output.headphones".to_string())
        })
        .unwrap();
        assert_eq!(
            (default.name.as_str(), target.name.as_str(), target.volume),
            ("easyeffects_sink", "alsa_output.headphones", 70)
        );
        // The popup's hero, given the same answer, points at the same row.
        let target_id = target.id.clone();
        route_through(&mut state.outputs, "alsa_output.headphones");
        assert_eq!(inert_default(&state.outputs).map(|r| r.via.clone()), Some(target_id));
    }

    #[test]
    fn an_inert_default_with_nothing_usable_behind_it_is_refused_not_mastered() {
        let sinks = vec![
            sink(40, "alsa_output.speakers", "Speakers", "30%"),
            easyeffects_node(66, "easyeffects_sink", "false"),
            easyeffects_node(67, "easyeffects_other", "false"),
        ];
        let state = build_state(&sinks, &[], &[], "easyeffects_sink", "");
        // Nothing found, an unlisted device, and a device that is itself
        // inert: each would be a control that moves nothing anyone hears.
        for behind in [None, Some("alsa_output.gone"), Some("easyeffects_other")] {
            let why = master_rows(&state.outputs, Side::Sink, |_| behind.map(str::to_string))
                .unwrap_err();
            assert!(
                why.contains("easyeffects_sink") && why.contains("could not be found"),
                "{why}"
            );
        }
        // No default row at all is refused too, and says which side.
        let state = build_state(&sinks, &[], &[], "alsa_output.gone", "");
        let why = master_rows(&state.outputs, Side::Sink, |_| None).unwrap_err();
        assert_eq!(why, "the default output is not in pactl's list");
    }

    #[test]
    fn the_source_side_masters_the_microphone_behind_easyeffects_source() {
        let sources = vec![
            json!({"index": 60, "name": "alsa_input.usb-mic", "mute": true,
                   "volume": {"front-left": {"value_percent": "80%"}},
                   "properties": {"device.class": "sound", "object.id": "34"}}),
            easyeffects_node(72, "easyeffects_source", "false"),
        ];
        let state = build_state(&[], &sources, &[], "", "easyeffects_source");
        let (default, target) =
            master_rows(&state.inputs, Side::Source, |_| Some("alsa_input.usb-mic".to_string()))
                .unwrap();
        assert_eq!(
            (default.name.as_str(), target.name.as_str(), target.mute),
            ("easyeffects_source", "alsa_input.usb-mic", true)
        );
        let why = master_rows(&state.inputs, Side::Source, |_| None).unwrap_err();
        assert!(why.starts_with("the default input, easyeffects_source,"), "{why}");
    }

    #[test]
    fn the_object_id_is_wpctls_never_pactls_index_and_never_a_monitors() {
        let listed = vec![
            json!({"index": 46, "name": "alsa_output.speakers",
                   "properties": {"object.id": "45", "object.serial": "46"}}),
            // A monitor carries its sink's properties, object.id included:
            // handed to wpctl it would name the sink.
            json!({"index": 46, "name": "alsa_output.speakers.monitor",
                   "properties": {"object.id": "45", "device.class": "monitor"}}),
            json!({"index": 50, "name": "no_id_printed", "properties": {}}),
            json!({"index": 51, "name": "odd_id", "properties": {"object.id": "@DEFAULT_AUDIO_SINK@"}}),
        ];
        assert_eq!(object_id_of(&listed, "alsa_output.speakers"), "45");
        assert_eq!(object_id_of(&listed, "alsa_output.speakers.monitor"), "");
        assert_eq!(object_id_of(&listed, "no_id_printed"), "");
        assert_eq!(object_id_of(&listed, "odd_id"), "");
        assert_eq!(object_id_of(&listed, "not_listed"), "");
    }

    /// `wpctl inspect @DEFAULT_AUDIO_SINK@` as WirePlumber 0.4.17 printed it
    /// for a null sink on PipeWire 1.0.5 (RUN), cut to the lines that matter
    /// and the shape around them.
    const INSPECT_SPEAKERS: &str = "id 45, type PipeWire:Interface:Node
    audio.adapt.follower = \"\"
    audio.channels = \"2\"
  * client.id = \"44\"
  * media.class = \"Audio/Sink\"
    monitor.channel-volumes = \"true\"
  * node.description = \"Fake-Speakers\"
  * node.name = \"alsa_output.fake_speakers\"
  * object.serial = \"46\"
";

    /// The same for EasyEffects' sink, as the simulated one printed it: its
    /// application id, and its level switched off (`on` switches it on).
    fn inspect_easyeffects(side: Side, on: bool) -> String {
        let (id, class, name) = match side {
            Side::Sink => (57, "Audio/Sink", "easyeffects_sink"),
            Side::Source => (58, "Audio/Source/Virtual", "easyeffects_source"),
        };
        format!(
            "id {id}, type PipeWire:Interface:Node
    application.id = \"com.github.wwmm.easyeffects\"
  * media.class = \"{class}\"
    monitor.channel-volumes = \"{on}\"
  * node.description = \"Easy Effects\"
  * node.name = \"{name}\"
"
        )
    }

    #[test]
    fn wpctl_inspect_is_read_as_wpctl_prints_it() {
        let read = inspected(INSPECT_SPEAKERS).unwrap();
        assert_eq!(read.id, "45");
        let p = Some(&read.props);
        assert_eq!(prop(p, "node.name"), "alsa_output.fake_speakers");
        assert_eq!(prop(p, "media.class"), "Audio/Sink");
        assert_eq!(prop(p, "monitor.channel-volumes"), "true");
        // An empty value is a value, and a `*` is a marker, not the key.
        assert_eq!(prop(p, "audio.adapt.follower"), "");
        assert_eq!(prop(p, "client.id"), "44");
    }

    #[test]
    fn an_inspect_answer_that_is_not_exactly_one_node_is_not_trusted() {
        // A description of `x"\n  * node.name = "easyeffects_sink` prints two
        // lines that are each a well-formed property, the forged node.name
        // BEFORE the real one because properties are sorted by key. Only the
        // key seen twice gives it away.
        let forged = INSPECT_SPEAKERS
            .replace("\"Fake-Speakers\"", "\"x\"\n  * node.name = \"easyeffects_sink\"");
        assert_eq!(forged.matches("node.name").count(), 2, "the forgery was built");
        assert_eq!(inspected(&forged), None);
        // A clumsier one leaves the first line's quote open: the tail of a
        // value split over two lines is no property either.
        let split = INSPECT_SPEAKERS.replace("\"Fake-Speakers\"", "\"Fake\nSpeakers\"");
        assert_eq!(inspected(&split), None);
        let open = INSPECT_SPEAKERS
            .replace("\"Fake-Speakers\"", "\"x\n  * node.name = \"easyeffects_sink\"");
        assert_eq!(inspected(&open), None);
        // A value that is not one quoted string.
        let bare = INSPECT_SPEAKERS.replace("\"Fake-Speakers\"", "Fake-Speakers");
        assert_eq!(inspected(&bare), None);
        // Not a node, not an id, no header, nothing.
        let link = INSPECT_SPEAKERS.replace("PipeWire:Interface:Node", "PipeWire:Interface:Link");
        assert_eq!(inspected(&link), None);
        let word = INSPECT_SPEAKERS.replace("id 45,", "id @DEFAULT_AUDIO_SINK@,");
        assert_eq!(inspected(&word), None);
        assert_eq!(inspected(INSPECT_SPEAKERS.split_once('\n').unwrap().1), None);
        assert_eq!(inspected(""), None);
    }

    #[test]
    fn a_live_default_is_wpctls_to_answer_and_an_inert_or_monitor_one_is_not() {
        let live = |text: &str, side| inspected(text).and_then(|read| live_default(&read, side));
        assert_eq!(
            live(INSPECT_SPEAKERS, Side::Sink),
            Some(("alsa_output.fake_speakers".to_string(), "Fake-Speakers".to_string()))
        );
        // EasyEffects' own devices: their level reaches nothing, so the device
        // behind is pactl's and the graph's to find -- unless the person
        // switched "monitor channel volumes" on.
        assert_eq!(live(&inspect_easyeffects(Side::Sink, false), Side::Sink), None);
        assert_eq!(live(&inspect_easyeffects(Side::Source, false), Side::Source), None);
        assert_eq!(
            live(&inspect_easyeffects(Side::Sink, true), Side::Sink).map(|(n, _)| n).as_deref(),
            Some("easyeffects_sink")
        );
        // A monitor as the default source: WirePlumber names its SINK, and
        // get-volume would read the speakers' level.
        assert_eq!(live(INSPECT_SPEAKERS, Side::Source), None);
        let mic = INSPECT_SPEAKERS
            .replace("Audio/Sink", "Audio/Source")
            .replace("alsa_output.fake_speakers", "alsa_input.usb-mic");
        assert_eq!(live(&mic, Side::Source).map(|(n, _)| n).as_deref(), Some("alsa_input.usb-mic"));
        assert_eq!(live(&mic, Side::Sink), None);
        // A class this does not know goes to pactl, as does a node with no name.
        let duplex = INSPECT_SPEAKERS.replace("Audio/Sink", "Audio/Duplex");
        assert_eq!(live(&duplex, Side::Sink), None);
        let nameless = INSPECT_SPEAKERS.replace("\"alsa_output.fake_speakers\"", "\"\"");
        assert_eq!(live(&nameless, Side::Sink), None);
        // A node with no description is titled by its name.
        let plain = INSPECT_SPEAKERS.replace("  * node.description = \"Fake-Speakers\"\n", "");
        assert_eq!(
            live(&plain, Side::Sink).map(|(_, d)| d).as_deref(),
            Some("alsa_output.fake_speakers")
        );
    }

    #[test]
    fn wpctl_level_reads_the_volume_line_rounded_and_nothing_else() {
        // Rounded: 0.29 * 100 is 28.999999999999996.
        assert_eq!(wpctl_level("Volume: 0.29\n"), Some((29, false)));
        assert_eq!(wpctl_level("Volume: 0.57 [MUTED]\n"), Some((57, true)));
        assert_eq!(wpctl_level("Volume: 1.50\n"), Some((150, false)));
        assert_eq!(wpctl_level("Volume: 0.00\n"), Some((0, false)));
        // What wpctl prints, with exit 0, for a node that is gone.
        assert_eq!(wpctl_level("Node '9999' not found\n"), None);
        assert_eq!(wpctl_level(""), None);
        for odd in [
            "Volume: 0,55",
            "Volume: 0.55 [MUTED] 1",
            "Volume: -0.5",
            "Volume: nan",
            "Volume:  0.55",
            "Volume: ",
        ] {
            assert_eq!(wpctl_level(odd), None, "{odd:?}");
        }
    }

    #[test]
    fn a_live_master_is_the_node_wpctl_named_at_the_level_wpctl_read_by_its_id() {
        let read = inspected(INSPECT_SPEAKERS).unwrap();
        let answer = live_master(&read, Side::Sink, |id| {
            assert_eq!(id, "45", "get-volume is asked by the object id inspect printed");
            Some("Volume: 0.55 [MUTED]\n".to_string())
        });
        assert_eq!(
            answer,
            Some(Master {
                name: "alsa_output.fake_speakers".into(),
                object_id: "45".into(),
                description: "Fake-Speakers".into(),
                volume: 55,
                mute: true,
                default: "alsa_output.fake_speakers".into(),
            })
        );
        // No level read back is no answer from wpctl: pactl is asked instead.
        assert_eq!(live_master(&read, Side::Sink, |_| None), None);
        assert_eq!(live_master(&read, Side::Sink, |_| Some("Node '45' not found\n".into())), None);
        // An inert default never asks for a level: its own reaches nothing.
        let ee = inspected(&inspect_easyeffects(Side::Sink, false)).unwrap();
        assert_eq!(
            live_master(&ee, Side::Sink, |_| panic!("get-volume asked of an inert default")),
            None
        );
    }

    #[test]
    fn the_verb_and_side_decide_the_mode_and_a_wrong_one_is_no_mode_at_all() {
        let mode_of = |argv: &[&str]| {
            mode(&Args::parse(
                "jayos-audio-state".to_string(),
                argv.iter().map(std::ffi::OsString::from),
            ))
        };
        // Bare is the popup's poll, flags or not: the popup passes none, and
        // refusing one now would take the popup down over nothing.
        assert_eq!(mode_of(&[]), Mode::Popup);
        assert_eq!(mode_of(&["--verbose"]), Mode::Popup);
        assert_eq!(mode_of(&["master", "sink"]), Mode::Master(Side::Sink));
        assert_eq!(mode_of(&["master", "source"]), Mode::Master(Side::Source));
        // Anything else that is not exactly `master sink|source` is refused,
        // and the popup's document is never the answer to it: a reader of
        // `master` that got the lists would read no level at all.
        for bad in [&["master"][..], &["master", "speakers"], &["master", "sink", "extra"]] {
            assert_eq!(mode_of(bad), Mode::Usage, "{bad:?}");
        }
        assert_eq!(mode_of(&["frob"]), Mode::Unknown("frob".to_string()));
    }

    #[test]
    fn a_master_answer_serialises_with_the_keys_its_readers_take() {
        let text = serde_json::to_string(&Master {
            name: "alsa_output.speakers".into(),
            object_id: "45".into(),
            description: "Speakers".into(),
            volume: 30,
            mute: false,
            default: "easyeffects_sink".into(),
        })
        .unwrap();
        assert_eq!(
            text,
            r#"{"name":"alsa_output.speakers","object_id":"45","description":"Speakers","volume":30,"mute":false,"default":"easyeffects_sink"}"#
        );
    }

    #[test]
    fn the_link_graph_wins_and_the_rc_stands_in_when_it_is_unlinked() {
        let dump = json!([
            {"id": 1, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "easyeffects_sink", "media.class": "Audio/Sink"}}},
            {"id": 2, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "ee_soe_filter"}}},
            {"id": 3, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "alsa_output.speakers", "media.class": "Audio/Sink"}}},
            {"id": 10, "type": "PipeWire:Interface:Link",
             "info": {"output-node-id": 1, "input-node-id": 2}},
            {"id": 11, "type": "PipeWire:Interface:Link",
             "info": {"output-node-id": 2, "input-node-id": 3}}
        ]);
        let rc = "[StreamOutputs]\noutputDevice=alsa_output.headphones\n";
        assert_eq!(
            behind("easyeffects_sink", Side::Sink, &dump, Some(rc)).as_deref(),
            Some("alsa_output.speakers")
        );
        assert_eq!(
            behind("easyeffects_sink", Side::Sink, &json!([]), Some(rc)).as_deref(),
            Some("alsa_output.headphones")
        );
        assert_eq!(behind("easyeffects_sink", Side::Sink, &json!([]), None), None);
    }

    #[test]
    fn a_dump_with_a_second_array_is_still_the_graph_not_the_rc() {
        // pw-dump on PipeWire 1.0.5 with a client leaving part-way: the graph,
        // then `[{"id":110,"info":null}]`. Read as one document it was no graph
        // at all, and the rc's headphones answered for the speakers.
        let graph = json!([
            {"id": 1, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "easyeffects_sink", "media.class": "Audio/Sink"}}},
            {"id": 2, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "ee_soe_filter"}}},
            {"id": 3, "type": "PipeWire:Interface:Node",
             "info": {"props": {"node.name": "alsa_output.speakers", "media.class": "Audio/Sink"}}},
            {"id": 10, "type": "PipeWire:Interface:Link",
             "info": {"output-node-id": 1, "input-node-id": 2}},
            {"id": 11, "type": "PipeWire:Interface:Link",
             "info": {"output-node-id": 2, "input-node-id": 3}}
        ]);
        let text = format!("{graph}\n[{{\"id\": 110, \"info\": null}}]\n");
        let rc = "[StreamOutputs]\noutputDevice=alsa_output.headphones\n";
        assert_eq!(parse(Some(text.clone())), json!([]), "one document refuses it");
        assert_eq!(
            behind("easyeffects_sink", Side::Sink, &parse_dump(Some(text)), Some(rc)).as_deref(),
            Some("alsa_output.speakers")
        );
        assert_eq!(parse_dump(None), json!([]));
    }

    // ── the whole document ──────────────────────────────────────────────────

    #[test]
    fn the_four_keys_are_always_present_and_in_order() {
        let text = serde_json::to_string(&build_state(&[], &[], &[], "", "")).unwrap();
        assert_eq!(text, r#"{"outputs":[],"inputs":[],"apps":[],"cookie":""}"#);
    }

    #[test]
    fn the_cookie_is_pactl_infos_or_empty() {
        assert_eq!(cookie_of(&json!({"cookie": "987c:d52e"})), "987c:d52e");
        assert_eq!(cookie_of(&json!({})), "");
        // `parse` hands back an empty array when pactl failed.
        assert_eq!(cookie_of(&json!([])), "");
    }

    #[test]
    fn a_row_serialises_with_the_keys_the_qml_reads() {
        let sinks = vec![sink(55, "alsa_output.hdmi", "Big Screen", "40%")];
        let state = build_state(&sinks, &[], &[], "alsa_output.hdmi", "");
        let text = serde_json::to_string(&state).unwrap();
        assert!(text.starts_with(
            r#"{"outputs":[{"id":"55","name":"alsa_output.hdmi","description":"Big Screen","volume":40,"mute":false,"is_default":true,"icon":"audio-card-analog","inert":false,"via":"","detail":""}]"#
        ));
    }

    #[test]
    fn output_order_follows_pactl_order_because_syncmodel_does() {
        let sinks = vec![
            sink(3, "c", "Third", "10%"),
            sink(1, "a", "First", "10%"),
            sink(2, "b", "Second", "10%"),
        ];
        let state = build_state(&sinks, &[], &[], "", "");
        assert_eq!(
            state.outputs.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(),
            vec!["3", "1", "2"]
        );
    }

    // ── parsing what the tools printed ──────────────────────────────────────

    #[test]
    fn unparseable_output_is_an_empty_list() {
        assert_eq!(parse(None), json!([]));
        assert_eq!(parse(Some("not json".into())), json!([]));
        assert_eq!(parse(Some("[]".into())), json!([]));
        assert_eq!(parse(Some(r#"{"a":1}"#.into())), json!({"a": 1}));
    }

    // ── the subprocess wrapper ──────────────────────────────────────────────

    #[test]
    fn run_returns_stdout_only_when_the_command_succeeded() {
        assert_eq!(run("sh", &["-c", "printf hello"], BUDGET).as_deref(), Some("hello"));
        assert_eq!(run("sh", &["-c", "printf hello; exit 1"], BUDGET), None);
        assert_eq!(run("definitely-not-a-real-program-qs", &[], BUDGET), None);
    }

    // Guards the reader THREAD: with the read on the calling thread this takes
    // the whole 30 seconds, because read_to_end waits for an EOF that a
    // sleeping child never sends.
    #[test]
    fn run_gives_up_on_a_command_that_hangs() {
        assert_eq!(run("sleep", &["30"], Duration::from_millis(150)), None);
    }

    // Guards the ORDER: waiting for the child before draining its pipe
    // deadlocks here, because 200 KB does not fit in a 64 KiB pipe buffer.
    #[test]
    fn run_survives_more_output_than_a_pipe_buffer_holds() {
        let got = run("sh", &["-c", "yes abcdefgh | head -c 200000"], BUDGET);
        assert_eq!(got.map(|s| s.len()), Some(200000));
    }
}
