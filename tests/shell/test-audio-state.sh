#!/usr/bin/env bash
#
# jayos-audio-state, the volume popup's producer, run as a whole against fakes.
#
#   tests/shell/test-audio-state.sh
#
# MOVED FROM JAYOS, with the program, at jayos commit 45256e08: this is its
# tools/test-audio-state.sh with four changes -- the paths, which are this
# repository's (the program is rust/crates/jayos-audio-tools/src/bin/ here);
# path_without, which JayOS keeps in tools/lib/absent.sh and this file now
# carries itself, its code as that commit has it; JAYOS_AUDIO_STATE_BIN,
# through which packaging/steps.sh's `check` hands it the release build; and
# no section reading JayOS's VolumePopup.qml for the one key nothing draws,
# which is JayOS's to keep, since the popup is there and not here. The
# paragraphs below are JayOS's, and "install.sh" in them is JayOS's
# installer, which ran this suite until the move.
#
# WHY THIS EXISTS
#
# rust/crates/jayos-audio-tools/src/bin/jayos-audio-state.rs has unit tests for every
# pure function in it -- the row builder, the filters, the wpctl parser, the
# subprocess wrapper -- and none for main(), which is where the decisions are
# that the popup actually shows: which three lists are fetched, which wpctl
# target is asked for which default, which default is matched against which
# list, and when `pactl info` is asked instead. Three mis-wirings of main() were
# tried against those unit tests and all three passed every one of them:
# swapping the two defaults (no row anywhere marked the default),
# listing `source-outputs` where `sink-inputs` belongs (the Streams tab filled
# with recording streams), and a misspelt list verb (the Streams tab empty).
# And the unit tests would not have caught them under install.sh in any case:
# install.d/build.sh builds the workspace and never runs `cargo test`.
#
# So this runs the BUILT binary, which is what VolumePopup.qml runs, and
# asserts on what it prints and on what it asked. Beyond main()'s wiring it
# holds what the helper's own fixes need a whole run to show: a default read
# from wpctl's node.name key and not from a description that mentions it; a
# node's first channel as its volume; "(null)" -- pactl's rendering of any
# non-ASCII value -- restored from pw-dump or never shown; a device that
# arrived between the list and the default; one five-second budget for a
# poll against a wedged server; and a child that dies with a SIGKILLed
# helper. The wedged case is most of the run time: about five seconds. And
# what decides which node the popup's controls act on: the server cookie,
# read before any id; a monitor that is the default source, listed as an
# input and marked; and an EasyEffects virtual device as the default, marked
# inert and routed to the device behind it -- but never the MONITOR of
# EasyEffects' sink, whose own controls work. And `master sink|source`, the
# same resolution asked by every other volume control -- the top bar, the
# keys, the battery popup, the doctor: which device it names, that it names
# the row the popup's `via` names for the same world, that it refuses rather
# than name an inert device, that a live default is wpctl's alone to answer --
# no pactl, so pipewire-pulse down or wedged costs it nothing -- and that a
# node.name forged by a newline in another property is never taken for it.
#
# HOW
#
# Fake `pactl`, `wpctl` and `pw-dump` go first on PATH. Each records its argv in
# $WORK/<case>/calls.log and answers from fixture files in the case directory,
# and each answers ONLY the exact argv the helper is supposed to use -- any
# other verb exits 1 with nothing on stdout, so a mutated verb reads as "the
# sound server said nothing" rather than as whatever the machine's real tool
# would have said. The rest of PATH is path_without's farm (below) with the
# real pactl, wpctl and pw-dump removed: on the machine this configuration is
# for, /usr/bin has all three and a live PipeWire behind them, and a case that
# leaked through to them would assert against the tester's own devices.
#
# The fixtures are cut down from `pactl -f json list ...`, `wpctl inspect` and
# `pw-dump` as printed by pactl 16.1, WirePlumber 0.4.17 and PipeWire 1.0.5
# (RUN in a headless session) -- only the keys the helper reads, in the shape
# the real tools print them. The two defaults are DIFFERENT nodes from what
# `pactl info` names, so a default that came from the wrong source is visible
# in the output rather than coincidentally right.
#
# WHAT IS NOT TESTED: a real sound server. Whether pactl and wpctl on a given
# machine print what these fixtures say they print is read evidence here; the
# fixtures record the versions they were cut from.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_SRC="$SRC/rust/crates/jayos-audio-tools/src/bin/jayos-audio-state.rs"

# EXIT 2 AT THE TOP, before any assertion. A suite whose subject is not there
# has examined nothing, and `0 passed` with exit 0 is the answer that makes a
# deleted file look like a clean tree.
[[ -f "$HELPER_SRC" ]] || { echo "missing $HELPER_SRC" >&2; exit 2; }

# path_without <absolute dir> <tool>...: a directory of links to every
# executable on PATH, first on PATH winning, with the tools named left out.
# JayOS's tools/lib/absent.sh at 45256e08, its code whole and its reasons
# cut short, since this repository has no copy of that file to source: a
# PATH written as a short list would leave pactl wherever the list includes
# /usr/bin, which on the machine this is for is where pactl is.
path_without() {
    local dir="${1:-}"; shift 2>/dev/null || true
    # REFUSE A CALL THAT WOULD HIDE NOTHING.
    #
    # With no tool names the loop below hides nothing, the farm comes back
    # non-empty, and the function returns SUCCESS -- so a case built on it runs
    # against a PATH identical to the real one and passes having exercised the
    # absence of nothing.
    if (( $# == 0 )); then
        echo "path_without: no tool named, so this would hide nothing" >&2
        return 1
    fi
    # REFUSE A RELATIVE DESTINATION, because the next line is `rm -rf`.
    #
    # `path_without jq jq` reads as "a PATH without jq" and means "delete ./jq,
    # then build the farm there". An absolute path cannot be a directory the
    # caller happens to be standing in.
    if [[ "$dir" != /* ]]; then
        echo "path_without: <dir> must be absolute, got '$dir'" >&2
        return 1
    fi
    rm -rf "$dir"
    mkdir -p "$dir" || return 1
    local d f base
    # Split on ':' locally, so the caller's IFS is untouched.
    local IFS=:
    for d in $PATH; do
        # An empty element means "the current directory" to the shell. Not
        # something a test should inherit.
        [[ -n "$d" && -d "$d" ]] || continue
        # Not a glob over "$d"/* with nullglob unset: a directory with no
        # matches would yield the literal pattern.
        for f in "$d"/*; do
            [[ -f "$f" && -x "$f" ]] || continue
            base="${f##*/}"
            # First on PATH wins, exactly as execution would resolve it.
            [[ -e "$dir/$base" ]] || ln -s "$f" "$dir/$base" 2>/dev/null
        done
    done
    local hide
    unset IFS
    for hide in "$@"; do
        rm -f "$dir/$hide"
    done
    # A farm with nothing in it means PATH was empty or unreadable, and every
    # case built on it would then be testing the absence of everything.
    [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qs-test-audio-state.XXXXXX")"
# Every fake that was told to hang wrote its pid first. Killed by that pid and
# nothing else -- never by name -- so a run of this suite cannot touch a real
# pactl or wpctl belonging to the machine it runs on. A case that passed has
# left nothing to kill; one that failed has, and a suite that leaves a sleeping
# process behind would hold install.sh's output pipe open.
cleanup() {
    local p
    for p in $(cat "$WORK"/*/pids 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
# A case that could not run: two spaces, no colour, counted. That is the shape
# install.sh's skips_within() greps for, and counting it is why a machine with
# no cargo build cannot print the same thing as one that ran everything.
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() {
    local what="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then pass "$what"
    else bad "$what"; printf '         want: %s\n         got:  %s\n' "$want" "$got"; fi
}
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# The binary packaging/steps.sh's check hands this, or the workspace's own
# build: release first, which is what the package installs, then debug, which
# is what a `cargo test` by hand leaves.
if [[ -n "${JAYOS_AUDIO_STATE_BIN:-}" ]]; then
    BIN="$JAYOS_AUDIO_STATE_BIN"
else
    BIN="$SRC/rust/target/release/jayos-audio-state"
    [[ -x "$BIN" ]] || BIN="$SRC/rust/target/debug/jayos-audio-state"
fi
if [[ ! -x "$BIN" ]]; then
    # Nothing below can run without it, and nothing ran: that is exit 2, not a
    # pass. A fresh clone has no build, so this is the path it takes.
    skip "jayos-audio-state not exercised: it is not built (cd rust && cargo build --release -p jayos-audio-tools)"
    printf '\n  0 passed, %d not exercised\n' "$SKIP"
    exit 2
fi

# ── the fakes ────────────────────────────────────────────────────────────────

FAKES="$WORK/fakes"
mkdir -p "$FAKES"

# pactl: the three list verbs and `info`, each from <case>/<kind>.json. A
# numbered <kind>.<n>.json, when present, answers the n-th call of that kind
# instead, so a case can hand out a list that changes between two calls, and
# a <kind>.<n>.fail makes the n-th call fail. No file means exit 1 and no
# output -- which is what pactl does with no server.
#
# A <case>/hang-pactl file turns every call into one that never answers, the
# way pactl behaves against a daemon that accepted the connection and stopped:
# the pid is recorded, then `exec sleep` -- exec, so the pid the helper started
# IS the sleeping process and nothing else holds its stdout.
cat > "$FAKES/pactl" <<'SH'
#!/bin/sh
printf 'pactl %s\n' "$*" >> "$AS_CASE/calls.log"
if [ -f "$AS_CASE/hang-pactl" ]; then echo $$ >> "$AS_CASE/pids"; exec sleep 600; fi
case "$*" in
    "-f json list sinks"|"-f json list sources"|"-f json list sink-inputs"|"-f json list source-outputs")
        kind="$4"
        n=$(grep -cx "pactl -f json list $kind" "$AS_CASE/calls.log")
        [ -f "$AS_CASE/$kind.$n.fail" ] && exit 1
        [ -f "$AS_CASE/$kind.$n.json" ] && exec cat "$AS_CASE/$kind.$n.json"
        [ -f "$AS_CASE/$kind.json" ] && exec cat "$AS_CASE/$kind.json"
        exit 1 ;;
    "-f json info")
        [ -f "$AS_CASE/info.json" ] && exec cat "$AS_CASE/info.json"
        exit 1 ;;
esac
exit 1
SH

# wpctl: `inspect @DEFAULT_AUDIO_SINK@` and `inspect @DEFAULT_AUDIO_SOURCE@`,
# from <case>/wpctl-sink.txt and <case>/wpctl-source.txt, and `get-volume
# <object id>` from <case>/wpctl-volume-<id>.txt -- by a number only, the way
# `master` asks it. Anything else -- including an inspect of a node named any
# other way -- is exit 1. A <case>/hang-wpctl file makes it hang as pactl's
# does.
cat > "$FAKES/wpctl" <<'SH'
#!/bin/sh
printf 'wpctl %s\n' "$*" >> "$AS_CASE/calls.log"
if [ -f "$AS_CASE/hang-wpctl" ]; then echo $$ >> "$AS_CASE/pids"; exec sleep 600; fi
case "$*" in
    "inspect @DEFAULT_AUDIO_SINK@")
        [ -f "$AS_CASE/wpctl-sink.txt" ] && exec cat "$AS_CASE/wpctl-sink.txt"
        exit 1 ;;
    "inspect @DEFAULT_AUDIO_SOURCE@")
        [ -f "$AS_CASE/wpctl-source.txt" ] && exec cat "$AS_CASE/wpctl-source.txt"
        exit 1 ;;
    "get-volume "*[!0-9]*) exit 1 ;;
    "get-volume "?*)
        [ -f "$AS_CASE/wpctl-volume-$2.txt" ] && exec cat "$AS_CASE/wpctl-volume-$2.txt"
        exit 1 ;;
esac
exit 1
SH

# pw-dump: `pw-dump <n>` from <case>/pw-dump.<n>.json, which the helper asks
# for only when pactl printed "(null)" for something it could not encode; and
# a bare `pw-dump` -- the whole graph -- from <case>/pw-dump.all.json, which
# it asks for only when an EasyEffects virtual device is the default.
cat > "$FAKES/pw-dump" <<'SH'
#!/bin/sh
printf 'pw-dump %s\n' "$*" >> "$AS_CASE/calls.log"
[ $# -eq 0 ] && [ -f "$AS_CASE/pw-dump.all.json" ] && exec cat "$AS_CASE/pw-dump.all.json"
[ $# -eq 1 ] && [ -f "$AS_CASE/pw-dump.$1.json" ] && exec cat "$AS_CASE/pw-dump.$1.json"
exit 1
SH
chmod +x "$FAKES"/*

# The same fakes without wpctl, for the fallback: a machine with pactl and no
# WirePlumber CLI at all.
FAKES_NOWP="$WORK/fakes-nowp"
mkdir -p "$FAKES_NOWP"
cp -p "$FAKES/pactl" "$FAKES/pw-dump" "$FAKES_NOWP/"

# And without pw-dump, for a machine where pactl's "(null)" cannot be undone.
FAKES_NOPWDUMP="$WORK/fakes-nopwdump"
mkdir -p "$FAKES_NOPWDUMP"
cp -p "$FAKES/pactl" "$FAKES/wpctl" "$FAKES_NOPWDUMP/"

# Everything the machine has, minus the real sound tools. path_without refuses
# to build a farm that hides nothing, so a failure here is a broken harness,
# not a skipped case.
BARE="$WORK/bare"
if ! path_without "$BARE" pactl wpctl pw-dump; then
    echo "could not build a PATH without pactl, wpctl and pw-dump" >&2
    exit 2
fi

# run_case <case dir> <fakes dir> -- runs the helper, leaving stdout in
# <case>/out, the exit status in <case>/rc, and the calls in <case>/calls.log.
#
# XDG_CONFIG_HOME is the case's own: the helper reads EasyEffects' rc file
# from under it when an EasyEffects device is the default, and a case must
# never read the tester's.
run_case() {
    local case="$1" fakes="$2"
    : > "$case/calls.log"
    AS_CASE="$case" XDG_CONFIG_HOME="$case/config" PATH="$fakes:$BARE" \
        "$BIN" > "$case/out" 2> "$case/err" </dev/null
    echo $? > "$case/rc"
}

# default_of <case dir> <id> -- the is_default the helper printed for one row,
# or "absent". Every row is one flat object with no nested braces, so the text
# from the id to the next `}` is that row.
default_of() {
    local row
    row=$(grep -o "\"id\":\"$2\"[^}]*" "$1/out" | head -1)
    [[ -n "$row" ]] || { echo absent; return; }
    grep -o '"is_default":[a-z]*' <<<"$row" | cut -d: -f2
}

# ── the world every case starts from ─────────────────────────────────────────
#
# Two outputs, one monitor and two real microphones, two playback streams (one
# of them paused, which pactl reports as corked) and one recording stream that
# must never reach the popup. wpctl names the USB headset and the USB mic as
# default; `pactl info` names the OTHER two.
base_world() {
    local d="$1"
    mkdir -p "$d"
    cat > "$d/sinks.json" <<'JSON'
[{"index":40,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value":19661,"value_percent":"30%","db":"-31.37 dB"},
            "front-right":{"value":19661,"value_percent":"30%","db":"-31.37 dB"}},
  "properties":{"device.description":"Built-in Audio Analog Stereo",
                "device.icon_name":"audio-card-analog","object.serial":"40"}},
 {"index":43,"name":"alsa_output.usb-headset","mute":true,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value":36044,"value_percent":"55%","db":"-15.58 dB"},
            "front-right":{"value":36044,"value_percent":"55%","db":"-15.58 dB"}},
  "properties":{"device.description":"USB Headset",
                "device.icon_name":"audio-headset","object.serial":"43"}}]
JSON
    cat > "$d/sources.json" <<'JSON'
[{"index":40,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo.monitor","mute":false,
  "description":"Monitor of Built-in Audio Analog Stereo",
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"Built-in Audio Analog Stereo",
                "device.class":"monitor","object.serial":"40"}},
 {"index":60,"name":"alsa_input.usb-mic","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"80%"},"front-right":{"value_percent":"80%"}},
  "properties":{"device.description":"USB Microphone","device.class":"sound","object.serial":"60"}},
 {"index":61,"name":"alsa_input.pci-mic","mute":false,
  "channel_map":"mono",
  "volume":{"mono":{"value_percent":"20%"}},
  "properties":{"device.description":"Built-in Mic","device.class":"sound","object.serial":"61"}}]
JSON
    cat > "$d/sink-inputs.json" <<'JSON'
[{"index":90,"sink":40,"corked":false,"mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"application.name":"Firefox","application.process.binary":"firefox",
                "media.name":"AudioStream","object.serial":"90"}},
 {"index":91,"sink":40,"corked":true,"mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"64%"},"front-right":{"value_percent":"64%"}},
  "properties":{"application.name":"mpv","application.process.binary":"mpv",
                "media.name":"Some Song","application.icon_name":"mpv","object.serial":"91"}}]
JSON
    # A recorder. Listing it would put a capture stream on the Streams tab,
    # whose sliders set PLAYBACK volume; the helper must never ask for it.
    cat > "$d/source-outputs.json" <<'JSON'
[{"index":95,"source":60,"corked":false,"mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"application.name":"OBS Studio","application.process.binary":"obs",
                "media.name":"Mic capture","object.serial":"95"}}]
JSON
    cat > "$d/info.json" <<'JSON'
{"server_name":"PulseAudio (on PipeWire 1.0.5)",
 "default_sink_name":"alsa_output.pci-0000_00_1f.3.analog-stereo",
 "default_source_name":"alsa_input.pci-mic","cookie":"54a1:77c0"}
JSON
    # Real wpctl prints every property sorted by key, `*` marking the ones set
    # on the object itself. The first line's id is the node's PipeWire object
    # id -- the one pactl prints as its object.id property (RUN: `id 45` for
    # the sink pactl listed with index 46 and object.id "45") -- and `master`
    # reads it, so each id here is the object.id with_object_ids gives the
    # same device below.
    cat > "$d/wpctl-sink.txt" <<'TXT'
id 31, type PipeWire:Interface:Node
    audio.channels = "2"
    audio.position = "[ FL, FR ]"
  * client.id = "36"
  * factory.id = "18"
  * media.class = "Audio/Sink"
  * node.description = "USB Headset"
  * node.name = "alsa_output.usb-headset"
  * object.serial = "43"
TXT
    cat > "$d/wpctl-source.txt" <<'TXT'
id 34, type PipeWire:Interface:Node
    audio.channels = "2"
  * client.id = "36"
  * media.class = "Audio/Source"
  * node.description = "USB Microphone"
  * node.name = "alsa_input.usb-mic"
  * object.serial = "60"
TXT
    # `wpctl get-volume <id>` for each, at the level and mute pactl lists.
    printf 'Volume: 0.55 [MUTED]\n' > "$d/wpctl-volume-31.txt"
    printf 'Volume: 0.80\n' > "$d/wpctl-volume-34.txt"
}

# ── main()'s wiring ──────────────────────────────────────────────────────────
step "main() fetches the three lists and matches each default to its own list"

C="$WORK/wiring"; base_world "$C"
run_case "$C" "$FAKES"

check "it exits 0" "0" "$(cat "$C/rc")"

# The whole document, byte for byte. Every mis-wiring tried against the unit
# tests changes at least one byte of it: the swapped defaults clear both
# is_default=true, source-outputs puts OBS on the Streams tab, and a misspelt
# verb empties it. Each row's `detail` is what the popup says under its
# title: nothing for the two USB devices, whose titles say USB already, or
# for Firefox, whose "AudioStream" is its name for every stream; mpv's track.
WANT_WIRING='{"outputs":[{"id":"40","name":"alsa_output.pci-0000_00_1f.3.analog-stereo","description":"Built-in Audio Analog Stereo","volume":30,"mute":false,"is_default":false,"icon":"audio-card-analog","inert":false,"via":"","detail":""},{"id":"43","name":"alsa_output.usb-headset","description":"USB Headset","volume":55,"mute":true,"is_default":true,"icon":"audio-headset","inert":false,"via":"","detail":""}],"inputs":[{"id":"60","name":"alsa_input.usb-mic","description":"USB Microphone","volume":80,"mute":false,"is_default":true,"icon":"audio-card","inert":false,"via":"","detail":""},{"id":"61","name":"alsa_input.pci-mic","description":"Built-in Mic","volume":20,"mute":false,"is_default":false,"icon":"audio-card","inert":false,"via":"","detail":""}],"apps":[{"id":"90","name":"AudioStream","description":"Firefox","volume":100,"mute":false,"is_default":false,"icon":"audio-card","inert":false,"via":"","detail":""},{"id":"91","name":"Some Song","description":"mpv","volume":64,"mute":false,"is_default":false,"icon":"mpv","inert":false,"via":"","detail":"Some Song"}],"cookie":"54a1:77c0"}'
check "it prints the document the popup reads, byte for byte" "$WANT_WIRING" "$(cat "$C/out")"

# And what it asked, in order. `pactl info` comes FIRST, for the cookie: the
# popup passes it back with every id, and audio_control.sh refuses an id read
# under another server lifetime -- so it has to be read before the ids, or a
# restart between the two would pair old ids with the new cookie. `list
# source-outputs` is absent because recording streams are not the Streams
# tab's, and pw-dump because no EasyEffects device is the default.
WANT_CALLS='pactl -f json info
pactl -f json list sinks
pactl -f json list sources
pactl -f json list sink-inputs
wpctl inspect @DEFAULT_AUDIO_SINK@
wpctl inspect @DEFAULT_AUDIO_SOURCE@'
check "it asks pactl info, the three lists and the two wpctl defaults, in that order" \
    "$WANT_CALLS" "$(cat "$C/calls.log")"

check "the default output is the one wpctl named, not the one pactl info named" \
    "true false" "$(default_of "$C" 43) $(default_of "$C" 40)"
check "the default input is the one wpctl named, not the one pactl info named" \
    "true false" "$(default_of "$C" 60) $(default_of "$C" 61)"
if grep -q '"id":"40","name":"alsa_output.pci-0000_00_1f.3.analog-stereo.monitor"' "$C/out"; then
    bad "a monitor source is kept off the Inputs tab"
else
    pass "a monitor source is kept off the Inputs tab"
fi
# mpv's stream is corked -- paused -- in the fixture, and the header's first
# line promises paused streams are listed.
if grep -qF '"id":"91","name":"Some Song","description":"mpv"' "$C/out"; then
    pass "a paused (corked) stream is listed like a playing one"
else
    bad "a paused (corked) stream is listed like a playing one"
fi
if grep -q 'OBS Studio' "$C/out"; then
    bad "a recording stream never reaches the Streams tab"
else
    pass "a recording stream never reaches the Streams tab"
fi

# ── what a row says under its title ──────────────────────────────────────────
step "Each row says its bus or its track under its title, never a node name or a repeat"

# The owner's machine as pactl lists it: a USB DAC, Bluetooth headphones, a
# GPU's third HDMI port and the motherboard's codec, and the streams the
# review saw. The popup drew each device's node name under its title --
# alsa_output.usb-Schiit_Audio_Schiit..., bluez_output.AC_80_0A_1F_33_5E.1 --
# and "Spotify" under "spotify", "AudioStream" under "Firefox". The node name
# is still `name`, which a click hands pactl.
C="$WORK/detail"; base_world "$C"
cat > "$C/sinks.json" <<'JSON'
[{"index":52,"name":"alsa_output.usb-Schiit_Audio_Schiit_Modi_3-00.analog-stereo","mute":false,
  "channel_map":"front-left,front-right","volume":{"front-left":{"value_percent":"62%"}},
  "properties":{"device.description":"Schiit Modi 3+ Analog Stereo","alsa.driver_name":"snd_usb_audio",
                "api.alsa.card.longname":"Schiit Audio Schiit Modi 3+ at usb-0000:0c:00.3-1, high speed",
                "device.profile.name":"analog-stereo","object.serial":"52"}},
 {"index":88,"name":"bluez_output.AC_80_0A_1F_33_5E.1","mute":false,
  "channel_map":"front-left,front-right","volume":{"front-left":{"value_percent":"45%"}},
  "properties":{"device.description":"WH-1000XM5","api.bluez5.address":"AC:80:0A:1F:33:5E",
                "api.bluez5.profile":"a2dp-sink","object.serial":"88"}},
 {"index":54,"name":"alsa_output.pci-0000_01_00.1.hdmi-stereo-extra2","mute":false,
  "channel_map":"front-left,front-right","volume":{"front-left":{"value_percent":"100%"}},
  "properties":{"device.description":"Odyssey G9","device.profile.name":"hdmi-stereo-extra2",
                "object.serial":"54"}},
 {"index":55,"name":"alsa_output.pci-0000_01_00.1.hdmi-stereo","mute":false,
  "channel_map":"front-left,front-right","volume":{"front-left":{"value_percent":"100%"}},
  "properties":{"device.description":"AD103 High Definition Audio Controller Digital Stereo (HDMI)",
                "device.profile.name":"hdmi-stereo","object.serial":"55"}},
 {"index":56,"name":"alsa_output.pci-0000_13_00.6.analog-stereo","mute":true,
  "channel_map":"front-left,front-right","volume":{"front-left":{"value_percent":"40%"}},
  "properties":{"device.description":"Family 17h/19h HD Audio Controller Analog Stereo",
                "device.profile.name":"analog-stereo","object.serial":"56"}}]
JSON
cat > "$C/sink-inputs.json" <<'JSON'
[{"index":120,"sink":52,"corked":false,"mute":false,"channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"}},
  "properties":{"application.name":"spotify","media.name":"Spotify","object.serial":"120"}},
 {"index":131,"sink":52,"corked":false,"mute":false,"channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"74%"}},
  "properties":{"application.name":"Firefox","media.name":"AudioStream","object.serial":"131"}},
 {"index":142,"sink":52,"corked":false,"mute":false,"channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"55%"}},
  "properties":{"application.name":"WEBRTC VoiceEngine","media.name":"playStream","object.serial":"142"}},
 {"index":143,"sink":52,"corked":false,"mute":false,"channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"80%"}},
  "properties":{"application.name":"Chromium","media.name":"Playback","object.serial":"143"}},
 {"index":144,"sink":52,"corked":true,"mute":false,"channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"64%"}},
  "properties":{"application.name":"mpv","media.name":"Some Song","object.serial":"144"}}]
JSON
run_case "$C" "$FAKES"
# detail_of <case dir> <id> -- the detail one row printed.
detail_of() { grep -o "\"id\":\"$2\"[^}]*" "$1/out" | head -1 | grep -o '"detail":"[^"]*"' | cut -d'"' -f4; }
check "the DAC says USB, the headphones Bluetooth, the third HDMI port HDMI 3, the motherboard nothing" \
    "USB|Bluetooth|HDMI 3|" "$(detail_of "$C" 52)|$(detail_of "$C" 88)|$(detail_of "$C" 54)|$(detail_of "$C" 56)"
check "an HDMI port whose title already names it says nothing more" "" "$(detail_of "$C" 55)"
check "and the click still has each node name to hand pactl" \
    "alsa_output.usb-Schiit_Audio_Schiit_Modi_3-00.analog-stereo" \
    "$(grep -o '"id":"52","name":"[^"]*"' "$C/out" | cut -d'"' -f8)"
check "Spotify's \"Spotify\", Firefox's, WebRTC's and Chromium's names for every stream say nothing; mpv's track is said" \
    "||||Some Song" \
    "$(detail_of "$C" 120)|$(detail_of "$C" 131)|$(detail_of "$C" 142)|$(detail_of "$C" 143)|$(detail_of "$C" 144)"

# ── reading wpctl's answer ───────────────────────────────────────────────────
step "The default is read from wpctl's node.name key, not from any line naming it"

# wpctl sorts properties by key, so node.description is printed first, and a
# description is whatever the device calls itself. When the parser took the
# first line merely CONTAINING "node.name", this description became the
# default's "name", matched no row, and the popup marked no row the default.
C="$WORK/decoy"; base_world "$C"
sed -i 's/^  \* node.description = "USB Headset"$/  * node.description = "Studio node.name = decoy"/' "$C/wpctl-sink.txt"
if grep -q 'Studio node.name = decoy' "$C/wpctl-sink.txt"; then
    run_case "$C" "$FAKES"
    check "a description containing 'node.name = ...' still leaves the real default marked" \
        "true" "$(default_of "$C" 43)"
else
    # The fixture edit is the case; without it this would pass having tested
    # an ordinary answer.
    bad "the decoy fixture was built (its sed matched nothing)"
fi

# A description with a NEWLINE in it is another matter: wpctl prints values
# raw, so `x"<newline>  * node.name = "..."` is a whole second node.name line,
# key and all, printed before the real one. A key printed twice is no answer,
# and `pactl info` names the default instead -- here the headset, with the
# forged name the built-in sink's. The `master` cases below hold the same for
# a forgery printed after the real line.
C="$WORK/decoy-line"; base_world "$C"
sed -i 's/"default_sink_name":"alsa_output.pci-0000_00_1f.3.analog-stereo"/"default_sink_name":"alsa_output.usb-headset"/' \
    "$C/info.json"
sed -i 's/^  \* node.description = "USB Headset"$/  * node.description = "x"\n  * node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"/' \
    "$C/wpctl-sink.txt"
if [[ "$(grep -c 'node.name' "$C/wpctl-sink.txt")" == 2 ]] && grep -q usb-headset "$C/info.json"; then
    run_case "$C" "$FAKES"
    check "a node.name forged on a line of its own: pactl info's default is marked, not the forged one" \
        "true false" "$(default_of "$C" 43) $(default_of "$C" 40)"
else
    bad "the forged-line fixture was built (a sed above matched nothing)"
fi

# ── a device that arrives between the list and the default ───────────────────
step "A default the list does not hold yet is listed once more, and only once"

# list_calls <case dir> <kind> -- how many times that list was asked for.
list_calls() { grep -cx "pactl -f json list $2" "$1/calls.log"; }

# The lists are read before the defaults. A headset plugged in and made
# default in between is named by wpctl and absent from the first list: here
# the first `list sinks` lacks it and the second holds it, as a real server
# would a moment later.
C="$WORK/late-default"; base_world "$C"
cat > "$C/sinks.1.json" <<'JSON'
[{"index":40,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"30%"},"front-right":{"value_percent":"30%"}},
  "properties":{"device.description":"Built-in Audio Analog Stereo","object.serial":"40"}}]
JSON
run_case "$C" "$FAKES"
check "the late headset is listed and marked default" "true" "$(default_of "$C" 43)"
check "by exactly one more list of the sinks" "2" "$(list_calls "$C" sinks)"
# The second list comes after both defaults are known -- the call before it
# is the last wpctl lookup -- because a re-list before them could miss the
# same device again.
check "asked after the defaults were known" "wpctl inspect @DEFAULT_AUDIO_SOURCE@" \
    "$(grep -B1 -x 'pactl -f json list sinks' "$C/calls.log" | tail -2 | head -1)"
check "and the sources, whose default was listed, are not listed again" "1" "$(list_calls "$C" sources)"

# The same race on the other side: a USB microphone plugged in and made
# default mid-poll. main() re-lists each kind in its own block, so the sinks
# case above says nothing about this one -- with the sources block disabled
# every other case in this suite still passed. The first `list sources` holds
# the monitor and the built-in mic and not the USB mic wpctl names; the second
# falls through to sources.json, which holds it.
C="$WORK/late-mic"; base_world "$C"
cat > "$C/sources.1.json" <<'JSON'
[{"index":40,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo.monitor","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"Monitor of Built-in Audio Analog Stereo",
                "device.class":"monitor","object.serial":"40"}},
 {"index":61,"name":"alsa_input.pci-mic","mute":false,
  "channel_map":"mono",
  "volume":{"mono":{"value_percent":"20%"}},
  "properties":{"device.description":"Built-in Mic","device.class":"sound","object.serial":"61"}}]
JSON
run_case "$C" "$FAKES"
check "the late microphone is listed and marked default" "true" "$(default_of "$C" 60)"
check "by exactly one more list of the sources" "2" "$(list_calls "$C" sources)"
check "and the sinks, whose default was listed, are not listed again" "1" "$(list_calls "$C" sinks)"

# A default that NO list will ever hold -- pactl and wpctl simply disagree --
# costs one more list and no more: no loop, and no row marked on a guess.
C="$WORK/never-listed"; base_world "$C"
sed -i 's/"alsa_output.usb-headset"$/"alsa_output.never-there"/' "$C/wpctl-sink.txt"
if grep -q 'never-there' "$C/wpctl-sink.txt"; then
    run_case "$C" "$FAKES"
    check "a default no list holds is listed again once, never in a loop" "2" "$(list_calls "$C" sinks)"
    check "and no output is marked default on a guess" "false false" \
        "$(default_of "$C" 40) $(default_of "$C" 43)"
else
    bad "the never-listed fixture was built (its sed matched nothing)"
fi

# The second list failing -- the server went away, or the budget ran out --
# must not cost the popup the rows the first list found.
C="$WORK/relist-fails"; base_world "$C"
cp "$WORK/late-default/sinks.1.json" "$C/sinks.1.json"; touch "$C/sinks.2.fail"
run_case "$C" "$FAKES"
check "a re-list that fails keeps the rows the first list found" \
    "false absent" "$(default_of "$C" 40) $(default_of "$C" 43)"

# A monitor as the default source: wpctl names the SINK it monitors, and pactl
# lists the source as "<sink>.monitor". That counts as listed -- re-listing on
# every poll could never find anything else.
#
# And the monitor is the default INPUT, so it is listed and marked: it is what
# a recorder hears and what the hero's slider and orb act on. The helper once
# dropped every monitor, this one too, and the hero then showed the first
# microphone while the controls reached the monitor. wpctl's answer is what
# WirePlumber 0.4.17 printed for it -- the SINK's node name, media.class
# Audio/Sink -- and it is read as the monitor. Its title is pactl's own
# "Monitor of ..." description; its device.description property is the
# sink's, and an input row titled with an output's name is the confusion this
# row is here to end.
C="$WORK/monitor-default"; base_world "$C"
sed -i 's/"alsa_input.usb-mic"$/"alsa_output.pci-0000_00_1f.3.analog-stereo"/; s/"Audio\/Source"$/"Audio\/Sink"/' \
    "$C/wpctl-source.txt"
# input_row <case dir> <id> -- one row of the INPUTS list. A monitor shares
# its pactl index with its sink, so an id alone would find the output first.
input_row() {
    sed -n 's/.*"inputs":\[\(.*\)\],"apps".*/\1/p' "$1/out" | grep -o "\"id\":\"$2\"[^}]*" | head -1
}
if grep -q 'analog-stereo' "$C/wpctl-source.txt" && grep -q 'Audio/Sink' "$C/wpctl-source.txt"; then
    run_case "$C" "$FAKES"
    check "a monitor default source does not make every poll list the sources twice" \
        "1" "$(list_calls "$C" sources)"
    check "the default monitor is an input row, marked default" \
        '"id":"40","name":"alsa_output.pci-0000_00_1f.3.analog-stereo.monitor","description":"Monitor of Built-in Audio Analog Stereo","volume":100,"mute":false,"is_default":true' \
        "$(input_row "$C" 40 | cut -d, -f1-6)"
    check "and no microphone is marked default in its place" "false false" \
        "$(input_row "$C" 60 | grep -o '"is_default":[a-z]*' | cut -d: -f2) $(input_row "$C" 61 | grep -o '"is_default":[a-z]*' | cut -d: -f2)"
else
    bad "the monitor-default fixture was built (its sed matched nothing)"
fi

# Only the default monitor: with a real microphone as the default, the same
# monitor stays off the tab, as every monitor did before.
C="$WORK/wiring"
check "a monitor that is not the default is still no input row" "" "$(input_row "$C" 40)"

# ── EasyEffects' virtual devices ─────────────────────────────────────────────
step "An EasyEffects virtual device as the default is routed to the device behind it"

# easyeffects_sink and easyeffects_source are null sinks whose monitor carries
# no channel volume by EasyEffects' default, so their own volume and mute reach
# nothing (jayos_core::pw_route has the measurement). As rows they are marked
# `inert`; as the default, `via` names the listed row behind them, from the
# link graph pw-dump prints -- EasyEffects' filters are nodes with no
# media.class -- or, with the filters unlinked, from EasyEffects' rc file.
easyeffects_world() {
    local d="$1"
    base_world "$d"
    cat > "$d/sinks.json" <<'JSON'
[{"index":40,"name":"alsa_output.pci-0000_00_1f.3.analog-stereo","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"30%"},"front-right":{"value_percent":"30%"}},
  "properties":{"device.description":"Built-in Audio Analog Stereo","object.serial":"40"}},
 {"index":43,"name":"alsa_output.usb-headset","mute":true,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"55%"},"front-right":{"value_percent":"55%"}},
  "properties":{"device.description":"USB Headset","object.serial":"43"}},
 {"index":66,"name":"easyeffects_sink","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"Easy Effects Sink","application.id":"com.github.wwmm.easyeffects",
                "monitor.channel-volumes":"false","node.virtual":"true","object.serial":"66"}}]
JSON
    cat > "$d/sources.json" <<'JSON'
[{"index":60,"name":"alsa_input.usb-mic","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"80%"},"front-right":{"value_percent":"80%"}},
  "properties":{"device.description":"USB Microphone","device.class":"sound","object.serial":"60"}},
 {"index":72,"name":"easyeffects_source","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"Easy Effects Source","application.id":"com.github.wwmm.easyeffects",
                "monitor.channel-volumes":"false","node.virtual":"true","object.serial":"72"}}]
JSON
    # wpctl's answer names the virtual devices by their own ids, with the two
    # properties that make them inert, as it printed them for the simulated
    # EasyEffects sink on WirePlumber 0.4.17 (RUN). `master` decides from
    # these whether wpctl alone can answer, so they have to be here.
    cat > "$d/wpctl-sink.txt" <<'TXT'
id 32, type PipeWire:Interface:Node
    application.id = "com.github.wwmm.easyeffects"
  * media.class = "Audio/Sink"
    monitor.channel-volumes = "false"
  * node.description = "Easy Effects Sink"
  * node.name = "easyeffects_sink"
  * object.serial = "66"
TXT
    cat > "$d/wpctl-source.txt" <<'TXT'
id 36, type PipeWire:Interface:Node
    application.id = "com.github.wwmm.easyeffects"
  * media.class = "Audio/Source/Virtual"
    monitor.channel-volumes = "false"
  * node.description = "Easy Effects Source"
  * node.name = "easyeffects_source"
  * object.serial = "72"
TXT
    printf 'Volume: 1.00\n' > "$d/wpctl-volume-32.txt"
    printf 'Volume: 1.00\n' > "$d/wpctl-volume-36.txt"
    # The graph as pw-dump printed an EasyEffects-shaped one on PipeWire 1.0.5,
    # cut down: each virtual device joined to a device through a filter with
    # no media.class. The headset, not the built-in speakers, is behind the
    # sink, so a guess at "the other sink" would be visible. The links are
    # kept apart so a case can drop them, as EasyEffects' inactivity timer
    # does.
    cat > "$d/pw-nodes.json" <<'JSON'
{"id":30,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_output.pci-0000_00_1f.3.analog-stereo","media.class":"Audio/Sink","object.serial":40}}},
{"id":31,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_output.usb-headset","media.class":"Audio/Sink","object.serial":43}}},
{"id":32,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"easyeffects_sink","media.class":"Audio/Sink","object.serial":66}}},
{"id":33,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"ee_soe_output_level","media.category":"Filter","object.serial":80}}},
{"id":34,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_input.usb-mic","media.class":"Audio/Source","object.serial":60}}},
{"id":35,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"ee_sie_output_level","media.category":"Filter","object.serial":81}}},
{"id":36,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"easyeffects_source","media.class":"Audio/Source/Virtual","object.serial":72}}}
JSON
    cat > "$d/pw-links.json" <<'JSON'
{"id":50,"type":"PipeWire:Interface:Link","info":{"output-node-id":32,"input-node-id":33,"state":"active"}},
{"id":51,"type":"PipeWire:Interface:Link","info":{"output-node-id":33,"input-node-id":31,"state":"active"}},
{"id":52,"type":"PipeWire:Interface:Link","info":{"output-node-id":34,"input-node-id":35,"state":"active"}},
{"id":53,"type":"PipeWire:Interface:Link","info":{"output-node-id":35,"input-node-id":36,"state":"active"}}
JSON
    { echo '['; cat "$d/pw-nodes.json"; echo ','; cat "$d/pw-links.json"; echo ']'; } > "$d/pw-dump.all.json"
}

# via_of <case dir> <id> -- the via one row printed, from outputs then inputs.
via_of() { grep -o "\"id\":\"$2\"[^}]*" "$1/out" | head -1 | grep -o '"via":"[^"]*"' | cut -d'"' -f4; }
inert_of() { grep -o "\"id\":\"$2\"[^}]*" "$1/out" | head -1 | grep -o '"inert":[a-z]*' | cut -d: -f2; }

C="$WORK/easyeffects"; easyeffects_world "$C"
if grep -q easyeffects_sink "$C/wpctl-sink.txt" && grep -q 'Source/Virtual' "$C/wpctl-source.txt"; then
    run_case "$C" "$FAKES"
    check "EasyEffects' sink and source are marked inert, the devices are not" \
        "true true false false false" \
        "$(inert_of "$C" 66) $(inert_of "$C" 72) $(inert_of "$C" 40) $(inert_of "$C" 43) $(inert_of "$C" 60)"
    check "the default sink is routed to the headset its chain plays into" "43" "$(via_of "$C" 66)"
    check "the default source is routed to the microphone its chain records" "60" "$(via_of "$C" 72)"
    check "and no other row carries a via" "||" "$(via_of "$C" 40)|$(via_of "$C" 43)|$(via_of "$C" 60)"
    check "the whole graph is asked for once" "1" "$(grep -cx 'pw-dump ' "$C/calls.log")"

    # pw-dump on PipeWire 1.0.5 prints a second array when a client comes or
    # goes while it is still dumping (RUN: 4 of 60 dumps while the popup
    # polled). Read as one document that was no graph, and the rc answered --
    # here naming the built-in speakers while the chain plays into the headset.
    C="$WORK/easyeffects-two-arrays"; easyeffects_world "$C"
    printf '[{"id":110,"info":null}]\n' >> "$C/pw-dump.all.json"
    mkdir -p "$C/config/easyeffects/db"
    printf '[StreamInputs]\ninputDevice=alsa_input.usb-mic\n\n[StreamOutputs]\noutputDevice=alsa_output.pci-0000_00_1f.3.analog-stereo\n' \
        > "$C/config/easyeffects/db/easyeffectsrc"
    run_case "$C" "$FAKES"
    check "a dump with a second array is still the graph: the sink is routed to the headset, not the rc's speakers" \
        "43|60" "$(via_of "$C" 66)|$(via_of "$C" 72)"

    # EasyEffects unlinks its filters once nothing has played for a while.
    # With no links, its rc file names the devices -- and it is read from the
    # case's own XDG_CONFIG_HOME, never the tester's.
    C="$WORK/easyeffects-unlinked"; easyeffects_world "$C"
    { echo '['; cat "$C/pw-nodes.json"; echo ']'; } > "$C/pw-dump.all.json"
    run_case "$C" "$FAKES"
    check "unlinked and no rc file: nothing to route to" "|" "$(via_of "$C" 66)|$(via_of "$C" 72)"
    mkdir -p "$C/config/easyeffects/db"
    printf '[StreamInputs]\ninputDevice=alsa_input.usb-mic\n\n[StreamOutputs]\noutputDevice=alsa_output.pci-0000_00_1f.3.analog-stereo\n' \
        > "$C/config/easyeffects/db/easyeffectsrc"
    run_case "$C" "$FAKES"
    check "unlinked: EasyEffects' rc names the device behind each side" "40|60" "$(via_of "$C" 66)|$(via_of "$C" 72)"

    # A hardware default never pays for the whole graph.
    C="$WORK/easyeffects-listed-only"; easyeffects_world "$C"
    cp "$WORK/wiring/wpctl-sink.txt" "$WORK/wiring/wpctl-source.txt" "$C/"
    run_case "$C" "$FAKES"
    check "with hardware defaults and EasyEffects merely running, pw-dump is not asked" \
        "0" "$(grep -cx 'pw-dump ' "$C/calls.log")"
    check "and nothing is routed" "|" "$(via_of "$C" 66)|$(via_of "$C" 72)"

    # The MONITOR of EasyEffects' sink as the default source. pactl lists it
    # with the sink's properties (EasyEffects' application.id,
    # monitor.channel-volumes "false", the sink's node.name) plus
    # device.class "monitor". That was RUN with pactl 16.1 on PipeWire 1.0.5,
    # and its own mute and volume worked. wpctl names the sink, as it does for
    # any monitor. Read as inert, the row lost its slider and mute, and the
    # hero moved the microphone in the rc below instead.
    C="$WORK/easyeffects-monitor"; easyeffects_world "$C"
    sed -i 's/"easyeffects_source"$/"easyeffects_sink"/; s/"Audio\/Source\/Virtual"$/"Audio\/Sink"/' \
        "$C/wpctl-source.txt"
    sed -i '$ s/\]$/,/' "$C/sources.json"
    cat >> "$C/sources.json" <<'JSON'
 {"index":66,"name":"easyeffects_sink.monitor","mute":false,"description":"Monitor of Easy Effects Sink",
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"Easy Effects Sink","application.id":"com.github.wwmm.easyeffects",
                "monitor.channel-volumes":"false","node.virtual":"true","node.name":"easyeffects_sink",
                "device.class":"monitor","object.serial":"66"}}]
JSON
    mkdir -p "$C/config/easyeffects/db"
    printf '[StreamInputs]\ninputDevice=alsa_input.usb-mic\n' > "$C/config/easyeffects/db/easyeffectsrc"
    if grep -q '"Audio/Sink"$' "$C/wpctl-source.txt" && grep -q 'easyeffects_sink.monitor' "$C/sources.json"; then
        run_case "$C" "$FAKES"
        # input_row: the monitor shares index 66 with the sink it monitors.
        row=$(input_row "$C" 66)
        check "EasyEffects' sink's monitor as the default source: a live input row, marked default, routed nowhere" \
            'true|false|' \
            "$(grep -o '"is_default":[a-z]*' <<<"$row" | cut -d: -f2)|$(grep -o '"inert":[a-z]*' <<<"$row" | cut -d: -f2)|$(grep -o '"via":"[^"]*"' <<<"$row" | cut -d'"' -f4)"
        check "and the microphone the rc names stays an ordinary row, neither default nor routed" "false|" \
            "$(input_row "$C" 60 | grep -o '"is_default":[a-z]*' | cut -d: -f2)|$(input_row "$C" 60 | grep -o '"via":"[^"]*"' | cut -d'"' -f4)"
    else
        bad "the EasyEffects-monitor fixture was built (a sed above matched nothing)"
    fi
else
    bad "the EasyEffects fixtures were built (a sed above matched nothing)"
fi

# ── master: the node every other control acts on ─────────────────────────────
step "master names the node a control acts on: the default, or the device behind EasyEffects'"

# The top bar, the volume keys, the battery popup and the doctor ask `master`
# instead of acting on the default, because with EasyEffects' sink as the
# default they read and moved a node whose level reaches nothing (the helper's
# MASTER section has the run). The worlds are the ones above, so each answer
# can be held against what the popup's `via` says for the same world.
#
# run_master <case dir> <fakes dir> <arg>... -- as run_case, with arguments.
run_master() {
    local case="$1" fakes="$2"; shift 2
    : > "$case/calls.log"
    AS_CASE="$case" XDG_CONFIG_HOME="$case/config" PATH="$fakes:$BARE" \
        "$BIN" "$@" > "$case/out" 2> "$case/err" </dev/null
    echo $? > "$case/rc"
}
# field <case dir> <key> -- one key of the one-line answer, or "absent".
field() {
    local v
    v=$(grep -o "\"$2\":\(\"[^\"]*\"\|[a-z0-9]*\)" "$1/out" | head -1 | cut -d: -f2- | tr -d '"')
    [[ -n "$v" ]] && echo "$v" || echo absent
}
# object.id beside each device's object.serial, as pipewire-pulse prints both:
# the id is what wpctl takes, the serial is pactl's index. They differ here
# as they do on a real server, so an answer that printed the index as the id
# is visible.
with_object_ids() {
    sed -i 's/"object.serial":"43"}/"object.serial":"43","object.id":"31"}/;
            s/"object.serial":"40"}/"object.serial":"40","object.id":"30"}/;
            s/"object.serial":"60"}/"object.serial":"60","object.id":"34"}/' \
        "$1/sinks.json" "$1/sources.json"
}

C="$WORK/master-hardware"; base_world "$C"; with_object_ids "$C"
run_master "$C" "$FAKES" master sink
check "a hardware default is its own master: exit 0" "0" "$(cat "$C/rc")"
check "and the answer is the whole line its readers take" \
    '{"name":"alsa_output.usb-headset","object_id":"31","description":"USB Headset","volume":55,"mute":true,"default":"alsa_output.usb-headset"}' \
    "$(cat "$C/out")"
# A LIVE DEFAULT IS WPCTL'S ALONE TO ANSWER (the helper's MASTER section): the
# node wpctl names, its level asked by the object id on inspect's first line,
# and nothing of pactl's at all. This listed with pactl first, so every
# control lost a hardware default wpctl could act on whenever pipewire-pulse
# was down -- the two cases below.
check "it asks wpctl for the default and for that node's level, and nothing of pactl's" \
    "wpctl inspect @DEFAULT_AUDIO_SINK@|wpctl get-volume 31" \
    "$(paste -sd'|' "$C/calls.log")"
run_master "$C" "$FAKES" master source
check "the source side: the USB microphone wpctl names, at its own 80%" \
    "0 alsa_input.usb-mic 34 80 false" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" object_id) $(field "$C" volume) $(field "$C" mute)"

# pipewire-pulse down: pactl answers nothing, not even `info`. The default is
# a live device wpctl can act on, and the keys and the bar had acted on it
# through wpctl alone before `master` existed.
C="$WORK/master-nopulse"; base_world "$C"; rm "$C/sinks.json" "$C/sources.json" "$C/info.json"
run_master "$C" "$FAKES" master sink
check "pipewire-pulse down: a hardware default is still named, from wpctl alone" \
    "0 alsa_output.usb-headset 31 55 true" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" object_id) $(field "$C" volume) $(field "$C" mute)"
# And wedged: a pactl that never answers. Asked first, it held every key press
# and every reading for the whole five-second budget and then refused (RUN on
# a SIGSTOPped pipewire-pulse); now it is never started, which the fake's pid
# file would show.
C="$WORK/master-wedgedpulse"; base_world "$C"; : > "$C/hang-pactl"
T0=$(date +%s%N)
run_master "$C" "$FAKES" master sink
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
check "pipewire-pulse wedged: named at once, with no pactl started to wait on" \
    "0 alsa_output.usb-headset 0 fast" \
    "$(cat "$C/rc") $(field "$C" name) $(grep -c '^pactl' "$C/calls.log") $( (( MS < 2000 )) && echo fast || echo "took ${MS} ms")"

C="$WORK/master-easyeffects"; easyeffects_world "$C"; with_object_ids "$C"
run_master "$C" "$FAKES" master sink
check "EasyEffects' sink as the default: the headset its chain plays into" \
    "0 alsa_output.usb-headset 31 easyeffects_sink" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" object_id) $(field "$C" default)"
check "at the headset's own level and mute, not the virtual sink's 100%" "55 true" \
    "$(field "$C" volume) $(field "$C" mute)"
check "the whole graph asked once" "1" "$(grep -cx 'pw-dump ' "$C/calls.log")"
# An inert default is pactl's and the graph's to answer: the device behind it
# has to be one of pactl's rows, as the popup's `via` is, and the virtual
# sink's own level is never asked -- it is the number that reaches nothing.
check "wpctl names the default, then pactl's list and the graph answer; no level is asked of wpctl" \
    "wpctl inspect @DEFAULT_AUDIO_SINK@|pactl -f json list sinks|pw-dump " \
    "$(paste -sd'|' "$C/calls.log")"
# The popup's poll for the same world routes the same default to a row: the
# one master names. Two answers to one question are the defect this closes.
run_case "$C" "$FAKES"
check "and it is the row the popup's via names for the same world" \
    "43 alsa_output.usb-headset" \
    "$(via_of "$C" 66) $(grep -o '"id":"43","name":"[^"]*"' "$C/out" | cut -d'"' -f8)"
run_master "$C" "$FAKES" master source
check "EasyEffects' source as the default: the microphone its chain records" \
    "0 alsa_input.usb-mic easyeffects_source" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" default)"

# The same second array under `master`, which the keys, the bar, the battery
# popup and the doctor ask: the graph's headset, not the rc's speakers.
C="$WORK/master-two-arrays"; easyeffects_world "$C"; with_object_ids "$C"
printf '[{"id":110,"info":null}]\n' >> "$C/pw-dump.all.json"
mkdir -p "$C/config/easyeffects/db"
printf '[StreamOutputs]\noutputDevice=alsa_output.pci-0000_00_1f.3.analog-stereo\n' \
    > "$C/config/easyeffects/db/easyeffectsrc"
run_master "$C" "$FAKES" master sink
check "master over a dump with a second array: still the headset the chain plays into" \
    "0 alsa_output.usb-headset" "$(cat "$C/rc") $(field "$C" name)"

# Unlinked -- EasyEffects' inactivity timer -- and no rc to name the device:
# nothing to act on, and it says so. NOT the virtual device: a key or a bar
# acting on that is the defect itself.
C="$WORK/master-unlinked"; easyeffects_world "$C"
{ echo '['; cat "$C/pw-nodes.json"; echo ']'; } > "$C/pw-dump.all.json"
run_master "$C" "$FAKES" master sink
check "unlinked and no rc: exit 1, never the virtual device" "1 absent" \
    "$(cat "$C/rc") $(field "$C" name)"
check "with the failure envelope on stdout" "false" "$(field "$C" ok)"
check "and the reason on stderr names the default" "yes" \
    "$(grep -q 'easyeffects_sink.*could not be found' "$C/err" && echo yes || echo no)"
mkdir -p "$C/config/easyeffects/db"
printf '[StreamOutputs]\noutputDevice=alsa_output.pci-0000_00_1f.3.analog-stereo\n' \
    > "$C/config/easyeffects/db/easyeffectsrc"
run_master "$C" "$FAKES" master sink
check "unlinked with the rc: the device EasyEffects last played into" \
    "0 alsa_output.pci-0000_00_1f.3.analog-stereo 30" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" volume)"
# An rc that names the virtual device itself names nothing that can be
# acted on: the listed device behind an inert default must not be inert.
printf '[StreamOutputs]\noutputDevice=easyeffects_sink\n' > "$C/config/easyeffects/db/easyeffectsrc"
run_master "$C" "$FAKES" master sink
check "an rc naming EasyEffects' own sink is no answer: exit 1, nothing named" "1 absent" \
    "$(cat "$C/rc") $(field "$C" name)"

# With pipewire-pulse down, an inert default has nothing to answer for it --
# no list to find the device behind it in -- and it is refused. Never the
# virtual sink itself because wpctl could answer for THAT: its level is the
# one that reaches nothing.
C="$WORK/master-ee-nopulse"; easyeffects_world "$C"; rm "$C/sinks.json" "$C/info.json"
run_master "$C" "$FAKES" master sink
check "EasyEffects' sink as the default with pipewire-pulse down: exit 1, never the virtual sink" \
    "1 absent 0" \
    "$(cat "$C/rc") $(field "$C" name) $(grep -c 'get-volume' "$C/calls.log")"
# And it says what went wrong: pactl listed nothing, not "the default is not
# in pactl's list", which sent the reader -- the doctor prints this as its
# FAIL -- looking for a missing device.
check "and the reason is pactl's silence, naming pipewire-pulse and the default" "yes" \
    "$(grep -q 'pactl listed no outputs -- is pipewire-pulse running.*easyeffects_sink' "$C/err" && echo yes || echo no)"

# "Monitor channel volumes" switched on: EasyEffects' sink's own level works,
# so it is its own master -- wpctl's to answer, like any live default -- and
# neither the graph nor pactl is asked.
C="$WORK/master-mcv-on"; easyeffects_world "$C"
sed -i 's/"monitor.channel-volumes":"false"/"monitor.channel-volumes":"true"/' "$C/sinks.json"
sed -i 's/monitor.channel-volumes = "false"/monitor.channel-volumes = "true"/' "$C/wpctl-sink.txt"
# 0.29, which is 28.999999999999996 times 100: rounded as every reader of
# wpctl's two decimals rounds it (watchers/audio_fetch.sh has why), not cut.
printf 'Volume: 0.29\n' > "$C/wpctl-volume-32.txt"
run_master "$C" "$FAKES" master sink
check "EasyEffects' sink with its level switched on is its own master, from wpctl alone" \
    "0 easyeffects_sink 32 0 0" \
    "$(cat "$C/rc") $(field "$C" name) $(field "$C" object_id) $(grep -cx 'pw-dump ' "$C/calls.log") $(grep -c '^pactl' "$C/calls.log")"
check "at wpctl's 0.29 read as 29, not 28" "29" "$(field "$C" volume)"

# A monitor as the default source is its own master, and has no object id to
# hand wpctl: its object.id is the sink's, and wpctl would mute the speakers.
C="$WORK/master-monitor"; base_world "$C"
sed -i 's/"object.serial":"40"}/"object.serial":"40","object.id":"30"}/' "$C/sources.json"
sed -i 's/"alsa_input.usb-mic"$/"alsa_output.pci-0000_00_1f.3.analog-stereo"/; s/"Audio\/Source"$/"Audio\/Sink"/' \
    "$C/wpctl-source.txt"
run_master "$C" "$FAKES" master source
check "a monitor default source is its own master, with no object id for wpctl" \
    "0 alsa_output.pci-0000_00_1f.3.analog-stereo.monitor " \
    "$(cat "$C/rc") $(field "$C" name) $(grep -o '"object_id":"[^"]*"' "$C/out" | cut -d'"' -f4)"
# And pactl's to answer: wpctl named the SINK, whose level is its 30%, and
# `wpctl get-volume` of it reads that and not the monitor's (RUN: the
# monitor at 30% read as its sink's 0.70). The monitor's own is pactl's 100%.
check "at the monitor's own 100% from pactl's list, not its sink's 30%, and no level asked of wpctl" \
    "100 0" "$(field "$C" volume) $(grep -c 'get-volume' "$C/calls.log")"

# A device description or nick with a newline in it prints a line of its own,
# and one built as `x"<newline>  * node.name = "..."` forges a whole second
# node.name: before the real one from the description, which sorts first,
# after it from the nick, which sorts after. Neither copy is trusted -- first
# wins is fooled by one, last wins by the other -- and pactl answers: the
# default pipewire-pulse names in `info`, which a newline cannot forge. Here
# that is the headset, and the forged name is the built-in sink.
for where in description nick; do
    C="$WORK/master-forged-$where"; base_world "$C"; with_object_ids "$C"
    sed -i 's/"default_sink_name":"alsa_output.pci-0000_00_1f.3.analog-stereo"/"default_sink_name":"alsa_output.usb-headset"/' \
        "$C/info.json"
    if [[ "$where" == description ]]; then
        sed -i 's/^  \* node.description = "USB Headset"$/  * node.description = "x"\n  * node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"/' \
            "$C/wpctl-sink.txt"
    else
        sed -i 's/^\(  \* node.name = "alsa_output.usb-headset"\)$/\1\n  * node.nick = "x"\n  * node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"/' \
            "$C/wpctl-sink.txt"
    fi
    if [[ "$(grep -c 'node.name' "$C/wpctl-sink.txt")" == 2 ]] && grep -q usb-headset "$C/info.json"; then
        run_master "$C" "$FAKES" master sink
        check "a node.name forged from the $where: the default pactl info names, by its own id" \
            "0 alsa_output.usb-headset 31" \
            "$(cat "$C/rc") $(field "$C" name) $(field "$C" object_id)"
    else
        bad "the $where forgery was built (a sed above matched nothing)"
    fi
done

# No wpctl: the default comes from pactl info, as the popup's does.
C="$WORK/master-nowp"; base_world "$C"
run_master "$C" "$FAKES_NOWP" master sink
check "with no wpctl, pactl info names the default" "0 alsa_output.pci-0000_00_1f.3.analog-stereo" \
    "$(cat "$C/rc") $(field "$C" name)"
# And no server at all: no default, so nothing to act on.
C="$WORK/master-noserver"; mkdir -p "$C"
run_master "$C" "$FAKES" master sink
check "no sound server: exit 1, nothing named" "1 absent" "$(cat "$C/rc") $(field "$C" name)"

# A question it does not know is refused with 2 before any tool is asked --
# and never answered with the popup's lists, which carry no level to read.
C="$WORK/master-usage"; base_world "$C"
for argv in "master" "master speakers" "master sink extra" "frob"; do
    # shellcheck disable=SC2086
    run_master "$C" "$FAKES" $argv
    check "\`$argv\` is refused with 2, asking nothing and printing no lists" "2 0 0" \
        "$(cat "$C/rc") $(grep -c . "$C/calls.log") $(grep -c '"outputs"' "$C/out")"
done

# ── the volume a row shows ───────────────────────────────────────────────────
step "A row's volume is its first channel, which is what wpctl and the top bar read"

# volume_of <case dir> <id> -- the volume the helper printed for one row.
volume_of() {
    grep -o "\"id\":\"$2\"[^}]*" "$1/out" | head -1 | grep -o '"volume":[0-9]*' | cut -d: -f2
}

# Three maps the old reading got wrong, each at a level `wpctl get-volume`
# reported for the same node on PipeWire 1.0.5: the Pro Audio profile (read 0),
# a front-center-only sink (read 0), and a map whose first channel is not
# front-left (read front-left's 80 against wpctl's 30).
C="$WORK/volumes"; base_world "$C"
cat > "$C/sinks.json" <<'JSON'
[{"index":70,"name":"alsa_output.usb-interface.pro-output-0","mute":false,
  "channel_map":"aux0,aux1,aux2,aux3",
  "volume":{"aux0":{"value_percent":"70%"},"aux1":{"value_percent":"70%"},
            "aux2":{"value_percent":"70%"},"aux3":{"value_percent":"70%"}},
  "properties":{"device.description":"USB Interface Pro","object.serial":"70"}},
 {"index":71,"name":"centersink","mute":false,"channel_map":"front-center",
  "volume":{"front-center":{"value_percent":"55%"}},
  "properties":{"device.description":"Center","object.serial":"71"}},
 {"index":72,"name":"rearfirst","mute":false,"channel_map":"rear-left,front-left",
  "volume":{"rear-left":{"value_percent":"30%"},"front-left":{"value_percent":"80%"}},
  "properties":{"device.description":"Rear First","object.serial":"72"}}]
JSON
run_case "$C" "$FAKES"
check "a Pro Audio (aux0..aux3) sink reads its level, not 0" "70" "$(volume_of "$C" 70)"
check "a front-center-only sink reads its level, not 0" "55" "$(volume_of "$C" 71)"
check "a sink whose map starts at rear-left reads rear-left, as wpctl does" "30" "$(volume_of "$C" 72)"

# ── what pactl could not encode ──────────────────────────────────────────────
step "A name pactl printed as \"(null)\" is restored from pw-dump, or falls back"

# pactl's JSON writer turns any value holding a byte outside printable ASCII
# into the literal "(null)" -- a typographic apostrophe in a Bluetooth name, an
# en dash in a track title. These are the three the finding RAN, served the
# way pactl 16.1 and pw-dump 1.0.5 printed them. The monitor of the renamed
# sink shares its pactl index with the sink, and must not be sent to pw-dump:
# the answer would be the SINK's description.
unencodable_world() {
    local d="$1"
    base_world "$d"
    sed -i 's/"device.description":"USB Headset"/"device.description":"(null)"/' "$d/sinks.json"
    sed -i 's/"application.name":"mpv"/"application.name":"(null)"/; s/"media.name":"Some Song"/"media.name":"(null)"/' \
        "$d/sink-inputs.json"
    cat > "$d/sources.json" <<'JSON'
[{"index":43,"name":"alsa_output.usb-headset.monitor","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"100%"},"front-right":{"value_percent":"100%"}},
  "properties":{"device.description":"(null)","device.class":"monitor","object.serial":"43"}},
 {"index":60,"name":"alsa_input.usb-mic","mute":false,
  "channel_map":"front-left,front-right",
  "volume":{"front-left":{"value_percent":"80%"},"front-right":{"value_percent":"80%"}},
  "properties":{"device.description":"USB Microphone","device.class":"sound","object.serial":"60"}}]
JSON
    # pw-dump N answers every object whose id OR serial is N; the first
    # object here has id 43 and is not the sink, so a join on the id reads
    # the wrong name.
    cat > "$d/pw-dump.43.json" <<'JSON'
[{"id":43,"type":"PipeWire:Interface:Node",
  "info":{"props":{"node.name":"some.other.node","node.description":"Wrong Node","object.serial":77}}},
 {"id":51,"type":"PipeWire:Interface:Node",
  "info":{"props":{"node.name":"alsa_output.usb-headset","node.description":"Jay’s AirPods",
                   "media.class":"Audio/Sink","object.serial":43}}}]
JSON
    cat > "$d/pw-dump.91.json" <<'JSON'
[{"id":63,"type":"PipeWire:Interface:Node",
  "info":{"props":{"application.name":"Élan","media.name":"Café del Mar – YouTube",
                   "application.process.binary":"mpv","media.class":"Stream/Output/Audio",
                   "object.serial":91}}}]
JSON
}

C="$WORK/unencodable"; unencodable_world "$C"
if grep -q '"(null)"' "$C/sinks.json" && grep -q '"(null)"' "$C/sink-inputs.json"; then
    run_case "$C" "$FAKES"
    if grep -q '(null)' "$C/out"; then
        bad "no \"(null)\" reaches the popup"
        printf '         %s\n' "$(cat "$C/out")"
    else
        pass "no \"(null)\" reaches the popup"
    fi
    if grep -qF '"id":"43","name":"alsa_output.usb-headset","description":"Jay’s AirPods"' "$C/out"; then
        pass "a device's description is restored from pw-dump, joined on the serial"
    else
        bad "a device's description is restored from pw-dump, joined on the serial"
    fi
    if grep -qF '"id":"91","name":"Café del Mar – YouTube","description":"Élan"' "$C/out"; then
        pass "a stream's application and track are restored from pw-dump"
    else
        bad "a stream's application and track are restored from pw-dump"
    fi
    check "pw-dump is asked for the two nodes that lost something, and not for the monitor" \
        "pw-dump 43
pw-dump 91" "$(grep '^pw-dump' "$C/calls.log")"

    # No pw-dump on the machine: the rows fall back to what pactl did encode.
    C="$WORK/unencodable-no-pwdump"; unencodable_world "$C"
    run_case "$C" "$FAKES_NOPWDUMP"
    if grep -q '(null)' "$C/out"; then
        bad "without pw-dump, still no \"(null)\" reaches the popup"
    else
        pass "without pw-dump, still no \"(null)\" reaches the popup"
    fi
    if grep -qF '"id":"43","name":"alsa_output.usb-headset","description":"alsa_output.usb-headset"' "$C/out"; then
        pass "and the device falls back to its node name"
    else
        bad "and the device falls back to its node name"
    fi
    if grep -qF '"id":"91","name":"Audio Stream","description":"mpv"' "$C/out"; then
        pass "and the stream falls back to its binary"
    else
        bad "and the stream falls back to its binary"
    fi
else
    bad "the \"(null)\" fixtures were built (a sed above matched nothing)"
fi

# ── the fallback to pactl info ───────────────────────────────────────────────
step "pactl info stands in for whichever default wpctl did not answer"

# No wpctl on PATH at all: both defaults come from `pactl info`.
C="$WORK/no-wpctl"; base_world "$C"
run_case "$C" "$FAKES_NOWP"
check "with no wpctl, it exits 0" "0" "$(cat "$C/rc")"
check "the default output comes from pactl info" \
    "true false" "$(default_of "$C" 40) $(default_of "$C" 43)"
check "the default input comes from pactl info" \
    "true false" "$(default_of "$C" 61) $(default_of "$C" 60)"
check "and pactl info, asked once, is what it had for them" \
    "1" "$(grep -cx 'pactl -f json info' "$C/calls.log")"

# wpctl answers the sink and not the source: only the source is filled in from
# `pactl info`, whose sink answer is a different node and must not win.
C="$WORK/wpctl-sink-only"; base_world "$C"; rm "$C/wpctl-source.txt"
run_case "$C" "$FAKES"
check "wpctl's sink answer is kept when only the source is missing" \
    "true false" "$(default_of "$C" 43) $(default_of "$C" 40)"
check "and the missing source comes from pactl info" \
    "true false" "$(default_of "$C" 61) $(default_of "$C" 60)"

# ── no sound server ──────────────────────────────────────────────────────────
step "No sound server is an empty answer, not a failure"

# Every fake exits 1 with nothing on stdout. The popup renders whatever three
# lists it parses, so three empty ones are what clear rows for devices that
# are no longer there; and all three keys have to be present, because
# processAudioJson feeds each to syncModel by name. The cookie is empty, and
# audio_control.sh refuses an id that comes with an empty cookie.
C="$WORK/no-server"; mkdir -p "$C"
run_case "$C" "$FAKES"
check "it exits 0" "0" "$(cat "$C/rc")"
check "it prints the three lists, empty, and no cookie" '{"outputs":[],"inputs":[],"apps":[],"cookie":""}' "$(cat "$C/out")"

# ── a wedged sound server ────────────────────────────────────────────────────
step "A sound server that stopped answering costs one poll five seconds, not thirty"

# Every call hangs, as against a daemon that accepted the connection and then
# stopped. The helper's limit is one budget for the whole poll: the first call
# spends it, and every later call must return without starting anything. Per
# call, as it was, this poll took six five-second timeouts in a row.
#
# Run under `timeout 25` so a regression costs this suite 25 seconds and a
# failure, not a hang; the helper's own bound is 5s plus a moment to kill.
#
# The calls AFTER the first are asserted from strace's execve log rather than
# from the fakes' own call log, because a call that is started and killed at
# once never gets as far as writing a line: without the helper's check for a
# spent budget, it still forked and exec'd five doomed clients per poll --
# five more connections to a daemon that had stopped answering -- and the call
# log looked exactly the same. std's spawn returns only after the exec, so an
# exec that happened is in strace's log however soon it was killed.
C="$WORK/wedged"; mkdir -p "$C"; : > "$C/calls.log"; touch "$C/hang-pactl" "$C/hang-wpctl"
TRACE=()
if command -v strace >/dev/null 2>&1 \
   && strace -f -qq -e trace=execve -o /dev/null true >/dev/null 2>&1; then
    TRACE=(strace -f -qq -e trace=execve -o "$C/exec.log")
fi
T0=$(date +%s%N)
AS_CASE="$C" PATH="$FAKES:$BARE" timeout 25 "${TRACE[@]}" "$BIN" > "$C/out" 2>/dev/null </dev/null
RC=$?
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
check "it exits 0" "0" "$RC"
check "it prints the three lists, empty, and no cookie" '{"outputs":[],"inputs":[],"apps":[],"cookie":""}' "$(cat "$C/out")"
if (( MS < 8000 )); then
    pass "the whole poll ends within the five-second budget (${MS} ms)"
else
    bad "the whole poll ends within the five-second budget (${MS} ms)"
fi
check "the first call is the one that hung" "pactl -f json info" "$(cat "$C/calls.log")"
if (( ${#TRACE[@]} )); then
    STARTED=$(grep -F "execve(\"$FAKES/" "$C/exec.log" | grep -c '= 0$')
    check "and once the budget is spent, nothing more is even started" "1" "$STARTED"
else
    skip "the doomed-call count not exercised: no strace here, or ptrace is not permitted"
fi

# ── the keys it prints are the contract's ───────────────────────────────────
step "The keys it prints are contract/audio-state-fields.txt's, in its order"

# tools/contract.sh writes that file from the three structs' source, and
# JayOS's popup suite holds the QML's model to the copy it vendors; this holds
# the file to what the built program prints, so a key renamed in the struct
# and in the file alike still has to reach a run. The wiring case's answer and
# the hardware master's, both read above: every list there has a row.
FIELDS="$SRC/contract/audio-state-fields.txt"
contract_keys() { sed -n "s/^$1 //p" "$FIELDS" | paste -sd' ' -; }
if [[ ! -f "$FIELDS" ]]; then
    bad "contract/audio-state-fields.txt is missing"
elif ! command -v jq >/dev/null 2>&1; then
    skip "the printed keys not exercised: no jq to read the answers with"
else
    check "the bare answer's keys" "$(contract_keys state)" \
        "$(jq -r 'keys_unsorted | join(" ")' "$WORK/wiring/out" 2>/dev/null)"
    check "every row's keys, in all three lists" "$(contract_keys node)" \
        "$(jq -r '[.outputs[], .inputs[], .apps[] | keys_unsorted | join(" ")] | unique | join("|")' "$WORK/wiring/out" 2>/dev/null)"
    check "and master's" "$(contract_keys master)" \
        "$(jq -r 'keys_unsorted | join(" ")' "$WORK/master-hardware/out" 2>/dev/null)"
fi

# ── a poll cut short ─────────────────────────────────────────────────────────
step "Closing the popup mid-poll takes the in-flight call with it"

# alive <pid> -- the process exists and is not a zombie. A SIGKILLed orphan is
# a zombie until its new parent reaps it, and a zombie has already done all
# the harm it can; `kill -0` would call it alive.
alive() {
    local state
    state=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null) || return 1
    [[ -n "$state" && "$state" != Z ]]
}

# VolumePopup.qml's Process is destroyed when the popup closes, and Quickshell
# SIGKILLs the helper -- nothing of the helper's runs after that, so its own
# deadline cannot kill the child it was waiting on. Here pactl answers nothing
# at once and wpctl hangs, which is where a stalled PipeWire leaves the helper;
# the helper is SIGKILLed while waiting, and the wpctl it started must go too.
if [[ ! -r /proc/self/stat ]]; then
    skip "the orphaned child not exercised: no /proc to tell a live process from a reaped one"
else
    C="$WORK/orphan"; mkdir -p "$C"; : > "$C/calls.log"; touch "$C/hang-wpctl"
    AS_CASE="$C" PATH="$FAKES:$BARE" "$BIN" > /dev/null 2>&1 </dev/null &
    HELPER=$!
    CHILD=""
    for _ in $(seq 100); do
        CHILD=$(head -1 "$C/pids" 2>/dev/null)
        [[ -n "$CHILD" ]] && break
        sleep 0.05
    done
    if [[ -z "$CHILD" ]]; then
        bad "the helper reached wpctl (no fake wpctl started within 5s)"
        kill -9 "$HELPER" 2>/dev/null
    else
        # The pid in the file is the helper's own child, so what is asserted
        # below is about the process this helper started and nothing else.
        PARENT=$(cut -d' ' -f4 "/proc/$CHILD/stat" 2>/dev/null)
        check "the hanging wpctl is the helper's own child" "$HELPER" "$PARENT"
        kill -9 "$HELPER" 2>/dev/null
        wait "$HELPER" 2>/dev/null
        for _ in $(seq 20); do alive "$CHILD" || break; sleep 0.05; done
        if alive "$CHILD"; then
            bad "a SIGKILLed helper's wpctl dies with it"
            printf '         pid %s is still running, now under pid %s\n' \
                "$CHILD" "$(cut -d' ' -f4 "/proc/$CHILD/stat" 2>/dev/null)"
        else
            pass "a SIGKILLed helper's wpctl dies with it"
        fi
    fi
fi

echo
# The skip count belongs in the tally whichever way the run went: a pass count
# alone cannot tell a machine that ran everything from one with no cargo build.
# The exit status deliberately does not move -- a machine without a built
# binary is not a machine with findings.
SKIPPED=""
(( SKIP > 0 )) && SKIPPED=", $SKIP not exercised"
if (( FAIL )); then
    printf '  \033[31m%d passed, %d failed%s\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
    exit 1
fi
printf '  \033[32m%d passed%s\033[0m\n' "$PASS" "$SKIPPED"
exit 0
