#!/usr/bin/env bash
#
# The noise-suppression host under a real PipeWire and WirePlumber.
#
#   tests/shell/test-host.sh                 the plugin from LADSPA's directories
#   JAYOS_AUDIO_TEST_PLUGIN=<.so> tests/shell/test-host.sh
#
# Starts PipeWire and WirePlumber in a box of their own -- their own runtime,
# configuration and state directories and a private session bus, WirePlumber's
# device monitors off, so neither a sound card nor Bluetooth is touched -- with
# two stand-in microphones (loopbacks, a sink fed from a file and the source it
# plays out of). systemd's user manager is the one stand-in: its `enable
# --now` starts `jayos-audio denoise host` in the box and its `disable --now`
# stops it, so `on` and `off` run whole, against WirePlumber's own default
# metadata.
#
# WHAT IT PROVES. The host comes up with the capture side linked to the
# microphone `on` chose, and its source is made the default input; `input`
# moves the running filter onto the other microphone by target.object;
# `strength` sets the running filter's controls live, by the names the
# filter-chain gives them; white noise played into the microphone comes out of
# the filtered source at least 15 dB quieter; and `off` makes the microphone
# the default again and stops the host.
#
# Exit 0: everything that ran passed, or the box is a counted skip because a
# tool, a socket short enough to bind, or the plugin is missing; 1: a case
# failed; 2: a file it reads is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-audio"
[[ -r "$ENGINE" ]] || { echo "cannot read src/jayos-audio" >&2; exit 2; }

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mfail\033[0m %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() { # check <what> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass "$1"; else
        bad "$1"
        printf '         expected: %s\n' "$2"
        printf '         actual:   %s\n' "$3"
    fi
}
finish() {
    echo
    local skipped=""
    (( SKIP > 0 )) && skipped=", $SKIP not exercised"
    printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$skipped"
    (( FAIL == 0 ))
    exit $?
}

echo "the host, under a real PipeWire"

need=""
for t in pipewire wireplumber pw-dump pw-metadata pw-cli pw-link pw-loopback pw-cat jq dbus-run-session python3 timeout; do
    command -v "$t" >/dev/null 2>&1 || need+="$t "
done
PLUGIN=${JAYOS_AUDIO_TEST_PLUGIN:-}
if [[ -z "$PLUGIN" ]]; then
    for d in /usr/local/lib/ladspa /usr/lib/ladspa /usr/lib64/ladspa; do
        [[ -f "$d/libdeep_filter_ladspa.so" ]] && { PLUGIN="$d/libdeep_filter_ladspa.so"; break; }
    done
fi
if [[ -n "$need" ]]; then
    skip "the host under a real PipeWire not exercised: no ${need% }"
    finish
fi
if [[ -z "$PLUGIN" || ! -f "$PLUGIN" ]]; then
    skip "the host under a real PipeWire not exercised: no libdeep_filter_ladspa.so (JAYOS_AUDIO_TEST_PLUGIN names a build's)"
    finish
fi

# A socket's path is at most 107 bytes, and a scratch directory under a deep
# TMPDIR is longer than that with PipeWire's names on it. So the box lives in
# the scratch directory and its runtime directory is reached by a short link.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-host.XXXXXX")" || exit 2
RUNLINK=""
for base in "${TMPDIR:-/tmp}" /tmp /dev/shm; do
    l="$base/jah.$$"
    if ln -s "$WORK/run" "$l" 2>/dev/null; then RUNLINK=$l; break; fi
done
trap 'rm -rf "$WORK"; [[ -n "$RUNLINK" ]] && rm -f "$RUNLINK"' EXIT
if [[ -z "$RUNLINK" || ${#RUNLINK} -gt 60 ]]; then
    skip "the host under a real PipeWire not exercised: no directory with a path short enough for PipeWire's socket"
    finish
fi

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/st"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# systemd's user manager for one unit: the host, run in the box.
pidf="$BOX_STATE/host.pid"
alive() { [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; }
start() { alive && return 0
          setsid bash "$BOX_ENGINE" denoise host > "$BOX_STATE/host.log" 2>&1 &
          echo $! > "$pidf"; }
stop()  { alive && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; sleep 0.3; }
case " $* " in
    *" is-active "*)     alive ;;
    *" is-enabled "*)    [[ -e "$BOX_STATE/enabled" ]] ;;
    *" enable --now "*)  touch "$BOX_STATE/enabled"; start ;;
    *" enable "*)        touch "$BOX_STATE/enabled" ;;
    *" restart "*)       stop; start ;;
    *" disable --now "*) rm -f "$BOX_STATE/enabled"; stop ;;
    *)                   exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/systemctl"

# White noise, 6 s at 48 kHz, 16-bit mono: what the filter exists to remove.
python3 -I - "$WORK/noise.wav" <<'EOF'
import random, struct, sys, wave
random.seed(7)
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<h", int(random.gauss(0, 0.1) * 32767)) for _ in range(48000 * 6)))
w.close()
EOF

cat > "$WORK/box.sh" <<'BOX'
#!/usr/bin/env bash
# Runs inside dbus-run-session; prints "key value" lines for the suite.
set -u
export XDG_CONFIG_HOME="$BOX/config" XDG_STATE_HOME="$BOX/state" HOME="$BOX/home"
unset PIPEWIRE_REMOTE PIPEWIRE_RUNTIME_DIR PULSE_SERVER
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" "$XDG_STATE_HOME" \
    "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d" \
    "$XDG_CONFIG_HOME/wireplumber/main.lua.d" "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d"
chmod 700 "$XDG_RUNTIME_DIR"
# 0.5's hardware features off, as its own video-only profile turns them off;
# 0.4's monitors by their Lua switches. Each version reads only its own form.
printf 'wireplumber.profiles = {\n  main = {\n    hardware.audio = disabled\n    hardware.bluetooth = disabled\n    hardware.video-capture = disabled\n  }\n}\n' \
    > "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/10-box.conf"
echo 'alsa_monitor.enabled = false; v4l2_monitor.enabled = false; libcamera_monitor.enabled = false' \
    > "$XDG_CONFIG_HOME/wireplumber/main.lua.d/90-box.lua"
echo 'bluez_monitor.enabled = false' > "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d/90-box.lua"
trap 'bash "$BOX_BIN/systemctl" --user disable --now x >/dev/null 2>&1; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT

pipewire > "$BOX/pipewire.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] || { echo "error no pipewire"; exit 1; }
wireplumber > "$BOX/wireplumber.log" 2>&1 &
sleep 1
for m in mic-a mic-b; do
    pw-loopback --capture-props="media.class=Audio/Sink node.name=feed-$m audio.position=[MONO]" \
                --playback-props="media.class=Audio/Source node.name=$m node.description=$m audio.position=[MONO] priority.session=$([[ $m == mic-a ]] && echo 900 || echo 2000)" \
                > "$BOX/loop-$m.log" 2>&1 &
done
for _ in $(seq 50); do [[ $(pw-dump 2>/dev/null | grep -c '"mic-[ab]"') -ge 2 ]] && break; sleep 0.1; done
pw-metadata -n default 0 default.configured.audio.source '{ "name": "mic-a" }' Spa:String:JSON > /dev/null

ja() { PATH="$BOX_BIN:$PATH" JAYOS_AUDIO_PLUGIN="$BOX_PLUGIN" JAYOS_AUDIO_WAIT=8 bash "$BOX_ENGINE" "$@" 2>&1; }
# The node the capture side's first input port is linked from.
linked_from() { pw-link -l 2>/dev/null | awk '/^jayos_denoise_capture:/ {f=1; next} f && /\|<-/ {sub(/.*\|<- /, ""); sub(/:.*/, ""); print; exit} /^[^ ]/ {f=0}'; }
default_source() { pw-metadata -n default 0 default.configured.audio.source 2>/dev/null | sed -n -E "s/.*value:'(.*)' type.*/\1/p" | jq -r '.name // empty'; }

echo "on $(ja denoise on balanced | tail -n 1)"
sleep 1.5
echo "default-after-on $(default_source)"
echo "capture-from $(linked_from)"
echo "source-present $(pw-dump 2>/dev/null | grep -c '"jayos_denoise_source"')"

ja denoise input mic-b > /dev/null
sleep 1.5
echo "capture-from-after-input $(linked_from)"

echo "strength $(ja denoise strength maximum)"
sleep 0.5
cap=$(pw-dump 2>/dev/null | jq -r 'first(.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == "jayos_denoise_capture") | .id)')
echo "atten-after-strength $(pw-dump "$cap" 2>/dev/null | jq -r '[.. | objects | select(has("params")) | .params | arrays | . as $p | range(0; length; 2) | select($p[.] == "df:Attenuation Limit (dB)") | $p[. + 1]] | first // empty')"

# Noise in, filtered out: mic-b is recorded now, so feed it.
pw-cat --record --target jayos_denoise_source --rate 48000 --channels 1 --format s16 "$BOX/out.wav" > /dev/null 2>&1 &
rec=$!
sleep 0.5
pw-cat --playback --target feed-mic-b "$BOX_NOISE" > /dev/null 2>&1
sleep 0.3; kill "$rec" 2>/dev/null; wait "$rec" 2>/dev/null
echo "recorded $([[ -s "$BOX/out.wav" ]] && echo yes || echo no)"

echo "off $(ja denoise off | tail -n 1)"
sleep 1
echo "default-after-off $(default_source)"
echo "source-after-off $(pw-dump 2>/dev/null | grep -c '"jayos_denoise_source"')"
BOX
OUT=$(cd "$WORK" && BOX="$WORK/box" XDG_RUNTIME_DIR="$RUNLINK" BOX_BIN="$WORK/bin" BOX_STATE="$WORK/st" \
      BOX_ENGINE="$ENGINE" BOX_PLUGIN="$PLUGIN" BOX_NOISE="$WORK/noise.wav" \
      timeout 120 dbus-run-session -- bash "$WORK/box.sh" 2>/dev/null)
val() { sed -n -E "s/^$1 (.*)$/\\1/p" <<<"$OUT" | head -n 1; }

if grep -q '^error ' <<<"$OUT" || [[ -z "$OUT" ]]; then
    bad "the box did not come up: $(head -n 3 <<<"$OUT")"
    finish
fi
check "on exits with its line" "noise suppression on (balanced), recording mic-a" "$(val on)"
check "the filtered source is the default input" "jayos_denoise_source" "$(val default-after-on)"
check "the capture side records the microphone that was the default, not the one WirePlumber ranks first" \
    "mic-a" "$(val capture-from)"
check "input moves the running filter onto the other microphone" "mic-b" "$(val capture-from-after-input)"
check "strength on a running host is set live" "strength maximum" "$(val strength)"
check "and the filter's attenuation limit is maximum's" "100" "$(val atten-after-strength | sed -E 's/\.0+$//')"
check "a recording came out of the filtered source" "yes" "$(val recorded)"
if [[ -s "$WORK/box/out.wav" ]]; then
    drop=$(python3 -I - "$WORK/noise.wav" "$WORK/box/out.wav" <<'EOF'
import math, struct, sys, wave
def rms(p, skip_s):
    w = wave.open(p); n = w.getnframes(); w.setpos(min(n, int(skip_s * 48000)))
    d = w.readframes(n); v = struct.unpack("<%dh" % (len(d) // 2), d)
    return math.sqrt(sum(x * x for x in v) / max(1, len(v))) or 1e-9
print("%.1f" % (20 * math.log10(rms(sys.argv[1], 1) / rms(sys.argv[2], 1.5))))
EOF
)
    if awk -v d="$drop" 'BEGIN { exit !(d >= 15) }'; then
        pass "white noise through the filter came out ${drop} dB quieter"
    else
        bad "white noise through the filter came out only ${drop} dB quieter (wanted at least 15)"
    fi
fi
check "off makes the microphone recorded last the default again" "mic-b" "$(val default-after-off)"
check "and stops the host: its source is gone" "0" "$(val source-after-off)"
finish
