#!/usr/bin/env bash
#
# The floor under a call's recording cycle: the drop-in, `jayos-audio floor`,
# and a real pipewire-pulse reading it.
#
#   tests/shell/test-floor.sh
#
# WHAT IT HOLDS. share/pipewire/pipewire-pulse.conf.d/
# 60-jayos-capture-latency.conf sets pulse.min.frag to 1024/48000 and nothing
# else; packaging/steps.sh installs every file under share/ at its own path
# under /usr/share, which tests/shell/test-steps.sh holds. `jayos-audio floor`,
# against stand-ins for systemctl and pactl, says whether the running
# pipewire-pulse has the floor and restarts one that predates it only on
# `apply` and only where no stream is open -- never where pactl cannot answer
# or systemd cannot be asked. And where PipeWire, WirePlumber and
# pipewire-pulse are installed, it starts all three in a box of their own --
# their own runtime and configuration directories, a private session bus, and
# WirePlumber's device monitors off, so neither a sound card nor Bluetooth is
# touched -- links a 10 ms recording to a stand-in microphone that drives its
# graph, and reads the latency pipewire-pulse gave it and the graph's quantum,
# with the drop-in and without.
#
# Ported from JayOS's tools/test-pulse-latency.sh, where the drop-in and its
# helper lived until jayos-audio 2.0.0. RUN there on 2026-11-07, and here on
# 2026-11-11, in a container with PipeWire 1.0.5, WirePlumber 0.4.17 and
# pipewire-pulse: without the drop-in the recording was given 480/48000 and the
# graph ran at 256 frames; with it, 1024/48000 and 1024; a 10 ms playback was
# given 128/48000 either way. WirePlumber 0.5's half of the box's
# configuration is read from its src/config/wireplumber.conf, not run.
#
# Exit 0 when everything that ran passed, 1 on a failure, 2 when a file it
# reads is missing. The box is a counted skip where a tool it needs is not.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DROPIN="$ROOT/share/pipewire/pipewire-pulse.conf.d/60-jayos-capture-latency.conf"
ENGINE="$ROOT/src/jayos-audio"

for f in "$DROPIN" "$ENGINE"; do
    [[ -r "$f" ]] || { echo "cannot read ${f#"$ROOT"/}" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-floor.XXXXXX")" \
    || { echo "no temporary directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mfail\033[0m %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass "$1"; else
        bad "$1"
        printf '         expected: %s\n' "$2"
        printf '         actual:   %s\n' "$3"
    fi
}

# ── 1. the drop-in ───────────────────────────────────────────────────────────
echo "the drop-in sets one key"

# Comments and blank lines out, whitespace squeezed: what pipewire-pulse
# parses, not what the header says about it.
BODY=$(sed -E 's/#.*$//; s/[[:space:]]+/ /g; s/^ //; s/ $//' "$DROPIN" | grep -v '^$')
check "pulse.properties holds pulse.min.frag at 1024/48000, and nothing else" \
    "pulse.properties = { pulse.min.frag = 1024/48000 }" "$(tr '\n' ' ' <<<"$BODY" | sed 's/ $//')"
check "under share/, at the directory pipewire-pulse reads drop-ins from" \
    "share/pipewire/pipewire-pulse.conf.d" "$(dirname "${DROPIN#"$ROOT"/}")"
# The engine's default is where steps.sh puts it: /usr/share plus the path
# under share/. Read from the code, comments out.
ENGINE_CODE=$(grep -vE '^[[:space:]]*#' "$ENGINE")
check "and the engine looks for it where the package installs it" "1" \
    "$(grep -cF 'DROPIN="${JAYOS_AUDIO_FLOOR:-/usr/share/pipewire/pipewire-pulse.conf.d/60-jayos-capture-latency.conf}"' <<<"$ENGINE_CODE")"

# ── 2. the verb ──────────────────────────────────────────────────────────────
echo
echo "jayos-audio floor, against stand-ins"

BIN="$WORK/bin"
ST="$WORK/st"
mkdir -p "$BIN" "$ST"
export ST
cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ST/calls"
[[ -e "$ST/no-systemd" ]] && exit 1
[[ -e "$ST/says-nothing" && " $* " == *" show "* ]] && exit 0
case " $* " in
    *" show "*)
        printf 'ActiveState=%s\nActiveEnterTimestamp=@%s\n' "$(cat "$ST/state")" "$(cat "$ST/since")" ;;
    *" restart "*)
        [[ -e "$ST/refuse" ]] && exit 1
        date +%s > "$ST/since"; echo active > "$ST/state" ;;
esac
STUB
cat > "$BIN/pactl" <<'STUB'
#!/usr/bin/env bash
[[ -e "$ST/pactl-fail" ]] && exit 1
[[ "$1 $2" == "list short" ]] || exit 1
cat "$ST/$3" 2>/dev/null
exit 0
STUB
chmod +x "$BIN/systemctl" "$BIN/pactl"

STATE="$WORK/state"
INSTALLED="$WORK/usr/share/pipewire/pipewire-pulse.conf.d/60-jayos-capture-latency.conf"
STAMP="$STATE/jayos-audio/floor.stamp"

# A fresh case: the given state and start time, no stamp, the shipped file.
reset() { # reset <active|inactive> <start offset from now, seconds>
    rm -rf "$WORK/usr" "$STATE" "$ST"/*
    mkdir -p "${INSTALLED%/*}"
    cp "$DROPIN" "$INSTALLED"
    echo "$1" > "$ST/state"
    echo $(( $(date +%s) + $2 )) > "$ST/since"
}
floor() { # floor <verb> [PATH]
    env XDG_STATE_HOME="$STATE" JAYOS_AUDIO_FLOOR="$INSTALLED" PATH="${2:-$BIN:$PATH}" \
        bash "$ENGINE" floor "$1" 2>&1
}
calls()    { if [[ -f "$ST/calls" ]]; then grep -c . "$ST/calls"; else echo 0; fi; }
restarts() { if [[ -f "$ST/calls" ]]; then grep -c 'restart' "$ST/calls"; else echo 0; fi; }
first_word() { printf '%s' "${1%%:*}"; }

reset active -1000
rm -f "$INSTALLED"
OUT=$(floor apply)
check "no drop-in: 'not installed'" "not installed" "$(first_word "$OUT")"
check "and systemd is not even asked" "0" "$(calls)"

reset active 100
OUT=$(floor apply)
check "pipewire-pulse started after the floor: 'in effect'" "in effect" "$(first_word "$OUT")"
check "and is not restarted" "0" "$(restarts)"

reset active -1000
OUT=$(floor apply)
check "started before it, nothing streaming: 'restarted'" "restarted" "$(first_word "$OUT")"
check "with exactly one restart of pipewire-pulse.service" "1" \
    "$(grep -cxF -- '--user restart pipewire-pulse.service' "$ST/calls")"
check "and the stamp holds the file's hash" "$(sha256sum < "$DROPIN" | cut -d' ' -f1)" \
    "$(cut -d' ' -f1 "$STAMP" 2>/dev/null)"
OUT=$(floor apply)
check "a second run: 'in effect'" "in effect" "$(first_word "$OUT")"
check "with no second restart" "1" "$(restarts)"

reset active -1000
floor apply >/dev/null
printf '# a newer floor\n' >> "$INSTALLED"
echo $(( $(date +%s) - 1 )) > "$ST/since"
# The stamp's time is this second or the last; a start one second before the
# new contents are first seen has to read as older than them.
sed -i -E "s/ [0-9]+$/ $(( $(date +%s) - 5 ))/" "$STAMP"
OUT=$(floor apply)
check "contents changed after pipewire-pulse started: 'restarted'" "restarted" "$(first_word "$OUT")"
check "and the stamp moves to the new hash" "$(sha256sum < "$INSTALLED" | cut -d' ' -f1)" \
    "$(cut -d' ' -f1 "$STAMP" 2>/dev/null)"

reset active -1000
printf '41\tprotocol-native.c\tpipewire-pulse\ts16le 2ch 48000Hz\n' > "$ST/sink-inputs"
OUT=$(floor apply)
check "a stream open: 'waiting'" "waiting" "$(first_word "$OUT")"
check "and it says how many, and what to run" "1" \
    "$(grep -c '1 stream(s) open.*systemctl --user restart pipewire-pulse.service' <<<"$OUT")"
check "and nothing is restarted" "0" "$(restarts)"

reset active -1000
printf '52\tprotocol-native.c\tpipewire-pulse\ts16le 2ch 48000Hz\n' > "$ST/source-outputs"
OUT=$(floor apply)
check "a recording open, nothing playing: 'waiting', no restart" "waiting 0" "$(first_word "$OUT") $(restarts)"

reset active -1000
touch "$ST/pactl-fail"
OUT=$(floor apply)
check "pactl failing is not 'nothing streaming': 'waiting', no restart" "waiting 0" "$(first_word "$OUT") $(restarts)"

# No pactl at all: a PATH of links to everything but pactl, beside the
# stand-in systemctl, so bash, sha256sum and the rest are still found.
reset active -1000
NOPACTL="$WORK/nopactl"
mkdir -p "$NOPACTL"
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for t in "$d"/*; do
        n=${t##*/}
        [[ "$n" == pactl || -e "$NOPACTL/$n" || ! -x "$t" ]] && continue
        ln -s "$t" "$NOPACTL/$n"
    done
done
mkdir -p "$BIN-nopactl"; cp "$BIN/systemctl" "$BIN-nopactl/"
OUT=$(floor apply "$BIN-nopactl:$NOPACTL")
check "no pactl at all: 'waiting', no restart" "waiting 0" "$(first_word "$OUT") $(restarts)"

reset inactive -1000
OUT=$(floor apply)
check "pipewire-pulse not running: 'in effect' at its next start, no restart" "in effect 0" \
    "$(first_word "$OUT") $(restarts)"

reset active -1000
touch "$ST/no-systemd"
OUT=$(floor apply)
check "systemd not answering is not 'not running': 'waiting', no restart" "waiting 0" \
    "$(first_word "$OUT") $(restarts)"

reset active -1000
touch "$ST/says-nothing"
OUT=$(floor apply)
check "systemd answering with nothing: 'waiting', no restart" "waiting 0" \
    "$(first_word "$OUT") $(restarts)"

reset active -1000
touch "$ST/refuse"
OUT=$(floor apply)
check "a refused restart: 'waiting', saying so" "waiting 1" \
    "$(first_word "$OUT") $(grep -c 'would not restart' <<<"$OUT")"

reset active -1000
OUT=$(floor status)
check "status over a stale pipewire-pulse: 'waiting', and never a restart" "waiting 0" \
    "$(first_word "$OUT") $(restarts)"

for verb in status apply; do
    reset active -1000
    floor "$verb" >/dev/null; rc=$?
    check "$verb exits 0" "0" "$rc"
done
floor bogus >/dev/null; rc=$?
check "an unknown verb exits 2" "2" "$rc"

# ── 3. a real pipewire-pulse ─────────────────────────────────────────────────
echo
echo "a real pipewire-pulse, in a box"

NEED=""
for t in pipewire wireplumber pipewire-pulse pacat pw-cli pw-dump pw-top pactl dbus-run-session jq timeout; do
    command -v "$t" >/dev/null 2>&1 || NEED+="$t "
done
# The box's sockets live under its runtime directory, and a Unix socket's path
# is at most 107 bytes: a long TMPDIR is a skip, not a failure.
BOXDIR="$WORK/b"
if (( ${#BOXDIR} > 60 )); then
    for base in /tmp /dev/shm; do
        [[ -d "$base" && -w "$base" ]] || continue
        link=$(mktemp -u "$base/jafl.XXXX")
        ln -s "$WORK" "$link" 2>/dev/null && { BOXDIR="$link/b"; trap 'rm -f "$link"; rm -rf "$WORK"' EXIT; break; }
    done
fi
if [[ -n "$NEED" ]]; then
    skip "the drop-in under a real pipewire-pulse not exercised: no ${NEED% }"
elif (( ${#BOXDIR} > 60 )); then
    skip "the drop-in under a real pipewire-pulse not exercised: no directory short enough for a socket"
else
    cat > "$WORK/box.sh" <<'BOX'
#!/usr/bin/env bash
# box.sh <dir> <drop-in or none>: prints "<recording latency> <playback latency> <graph quantum>"
set -u
B=$1
export XDG_RUNTIME_DIR="$B/run" XDG_CONFIG_HOME="$B/config" XDG_STATE_HOME="$B/state" HOME="$B/home"
unset PIPEWIRE_REMOTE PIPEWIRE_RUNTIME_DIR PULSE_SERVER PULSE_RUNTIME_PATH PULSE_COOKIE
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/pipewire/pipewire-pulse.conf.d" "$XDG_STATE_HOME" "$HOME" \
    "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d" \
    "$XDG_CONFIG_HOME/wireplumber/main.lua.d" "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d"
chmod 700 "$XDG_RUNTIME_DIR"
# The package puts the drop-in under /usr/share, which a box cannot write;
# pipewire-pulse reads the same file from ~/.config the same way.
[[ "$2" != none ]] && cp "$2" "$XDG_CONFIG_HOME/pipewire/pipewire-pulse.conf.d/"
# No device monitor, so a box on a real machine opens no sound card, camera or
# Bluetooth adapter: 0.5's hardware features off as its own video-only profile
# turns them off, and 0.4's monitors by their Lua switches. Each version reads
# only its own form.
cat > "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/10-box.conf" <<'CONF'
wireplumber.profiles = {
  main = {
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
  }
}
CONF
echo 'alsa_monitor.enabled = false; v4l2_monitor.enabled = false; libcamera_monitor.enabled = false' \
    > "$XDG_CONFIG_HOME/wireplumber/main.lua.d/90-box.lua"
echo 'bluez_monitor.enabled = false' > "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d/90-box.lua"

trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT
pipewire >"$B/pipewire.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] || { echo "no pipewire"; exit 1; }
wireplumber >"$B/wireplumber.log" 2>&1 &
pipewire-pulse >"$B/pipewire-pulse.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/pulse/native" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/pulse/native" ]] || { echo "no pipewire-pulse"; exit 1; }
sleep 1
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=box-mic node.description=box-mic
    media.class=Audio/Source/Virtual audio.position=[FL FR] object.linger=true }' >/dev/null
for _ in $(seq 30); do pactl set-default-source box-mic 2>/dev/null && break; sleep 0.1; done
pacat --record --latency-msec=10 --rate=48000 --channels=2 --client-name=box-call /dev/null &
pacat --playback --latency-msec=10 --rate=48000 --channels=2 --client-name=box-play /dev/zero &
lat() {
    pw-dump 2>/dev/null | jq -r --arg c "$1" '.[] | select(.type == "PipeWire:Interface:Node")
        | .info.props | select(."media.class" == $c) | ."node.latency" // empty' | head -n 1
}
for _ in $(seq 50); do
    r=$(lat Stream/Input/Audio); p=$(lat Stream/Output/Audio)
    [[ -n "$r" && -n "$p" ]] && break; sleep 0.1
done
sleep 1.5
q=$(pw-top -b -n 3 2>/dev/null | awk '$NF == "box-mic" { q = $3 } END { print q }')
echo "${r:-none} ${p:-none} ${q:-none}"
BOX
    mkdir -p "$BOXDIR/without" "$BOXDIR/with"
    WITHOUT=$(timeout 60 dbus-run-session -- bash "$WORK/box.sh" "$BOXDIR/without" none 2>/dev/null | tail -n 1)
    WITH=$(timeout 60 dbus-run-session -- bash "$WORK/box.sh" "$BOXDIR/with" "$DROPIN" 2>/dev/null | tail -n 1)
    read -r W_REC W_PLAY W_Q <<<"$WITHOUT"
    read -r F_REC F_PLAY F_Q <<<"$WITH"
    if [[ "$WITHOUT" != *" "*" "* || "$WITH" != *" "*" "* ]]; then
        bad "the box did not come up: '${WITHOUT}' / '${WITH}'"
    else
        printf '         without the drop-in: recording %s, playback %s, graph quantum %s\n' "$W_REC" "$W_PLAY" "$W_Q"
        printf '         with it:             recording %s, playback %s, graph quantum %s\n' "$F_REC" "$F_PLAY" "$F_Q"
        # At least 1024: a drop-in of the machine's own, named after this one,
        # may raise it further, and that is somebody's choice, not a failure.
        num=${F_REC%/*}
        check "with it, a 10 ms recording is given at least 1024/48000" "yes" \
            "$([[ "$F_REC" == */48000 && "$num" =~ ^[0-9]+$ ]] && (( num >= 1024 )) && echo yes || echo "no ($F_REC)")"
        check "and the microphone's graph runs at that quantum" "${num}" "$F_Q"
        check "a 10 ms playback is given what it was given without it" "$W_PLAY" "$F_PLAY"
        if [[ "$W_REC" == 480/48000 && "$W_Q" == 256 ]]; then
            pass "without it, the recording asked 480 frames and the graph ran at 256: the cycle the floor exists for"
        else
            # The machine's own pipewire configuration already raises it.
            skip "the 256-frame cycle without the drop-in not exercised: this machine gives ${W_REC} and ${W_Q} already"
        fi
    fi
fi

echo
skipped=""
(( SKIP > 0 )) && skipped=", $SKIP not exercised"
printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$skipped"
(( FAIL == 0 ))
