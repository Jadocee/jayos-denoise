#!/usr/bin/env bash
#
# The engine, src/jayos-audio, and jayos-denoise beside it, against stand-ins
# for systemd's user manager and PipeWire's tools.
#
#   tests/shell/test-engine.sh
#
# Exit 0: every case that ran passed. 1: a case failed. 2: could not run --
# no jq, which the engine needs to read pw-dump and write its status.
#
# WHAT THIS PROVES
#
# What the host's configuration holds for each strength and microphone; which
# microphone `on` records and how it makes the filtered source the default
# input; that `off` puts the microphone back and stops the host, and touches a
# default somebody else chose; that `input` moves a running filter through the
# capture stream's target.object, and `strength` sets a running filter's
# controls live and restarts it only where that fails; that the host runs
# PipeWire on the configuration it wrote; that a denoise preset 1.x left in
# EasyEffects is bypassed and never deleted; that `status` answers with the
# contract's keys and means what it says; and that jayos-denoise's verbs are
# the engine's.
#
# WHAT IT DOES NOT. Run PipeWire: tests/shell/test-host.sh does, where one is
# installed. Every stand-in here is its tool's interface as read.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-audio"
SHIM="$ROOT/src/jayos-denoise"
CONTRACT="$ROOT/contract"

command -v jq >/dev/null 2>&1 || { echo "test-engine not exercised: jq is not installed" >&2; exit 2; }
for f in "$ENGINE" "$SHIM" "$CONTRACT/status-keys.txt"; do
    [[ -r "$f" ]] || { echo "cannot read ${f#"$ROOT"/}" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-engine.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

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
says()     { if grep -qF -- "$2" <<< "$3"; then pass "$1"; else
                 bad "$1"; printf '         wanted: %s\n' "$2"
                 printf '%s\n' "$3" | sed 's/^/         got:    /'; fi; }
says_not() { if grep -qF -- "$2" <<< "$3"; then
                 bad "$1"; printf '         did not want: %s\n' "$2"
             else pass "$1"; fi; }

# ── the stand-ins ────────────────────────────────────────────────────────────
#
# $ST holds the machine: active and enabled for the unit, nodes for what
# pw-dump lists ("id node.name media.class" per line), meta.<key> for the
# default metadata, calls for every call made, no-source to keep the host from
# bringing its nodes up.
BIN="$WORK/bin"
ST="$WORK/st"
mkdir -p "$BIN" "$ST"
export ST

cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$ST/calls"
up()   { [[ -e "$ST/no-source" ]] && return 0
         grep -q ' jayos_denoise_source ' "$ST/nodes" 2>/dev/null && return 0
         printf '71 jayos_denoise_capture Stream/Input/Audio\n72 jayos_denoise_source Audio/Source\n' >> "$ST/nodes"; }
down() { [[ -f "$ST/nodes" ]] && sed -i '/ jayos_denoise_/d' "$ST/nodes"; }
case " $* " in
    *" is-active "*rtkit*)  [[ -e "$ST/rtkit" ]] ;;
    *" is-active "*)        [[ -e "$ST/active" ]] ;;
    *" is-enabled "*)       [[ -e "$ST/enabled" ]] ;;
    *" enable --now "*)     touch "$ST/enabled" "$ST/active"; up ;;
    *" enable "*)           touch "$ST/enabled" ;;
    *" restart "*)          touch "$ST/active"; down; up ;;
    *" disable --now "*)    rm -f "$ST/enabled" "$ST/active"; down ;;
    *)                      exit 1 ;;
esac
STUB
cat > "$BIN/pw-dump" <<'STUB'
#!/usr/bin/env bash
[[ -f "$ST/nodes" ]] || { echo '[]'; exit 0; }
jq -Rn '[inputs | split(" ") | {id: (.[0] | tonumber), type: "PipeWire:Interface:Node",
         info: {props: {"node.name": .[1], "media.class": .[2]}}}]' < "$ST/nodes"
STUB
cat > "$BIN/pw-metadata" <<'STUB'
#!/usr/bin/env bash
printf 'pw-metadata %s\n' "$*" >> "$ST/calls"
if [[ "$1" == -n ]]; then
    shift 3
    case $# in
        1) [[ -f "$ST/meta.$1" ]] && printf "update: id:0 key:'%s' value:'%s' type:'Spa:String:JSON'\n" "$1" "$(cat "$ST/meta.$1")" ;;
        2) [[ "$1" == -d ]] && rm -f "$ST/meta.$2" ;;
        *) printf '%s' "$2" > "$ST/meta.$1" ;;
    esac
    exit 0
fi
printf '%s %s %s\n' "$1" "$2" "$3" >> "$ST/moves"
STUB
cat > "$BIN/pw-cli" <<'STUB'
#!/usr/bin/env bash
printf 'pw-cli %s\n' "$*" >> "$ST/calls"
[[ -e "$ST/pwcli-fail" ]] && exit 1
exit 0
STUB
cat > "$BIN/pipewire" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ST/pipewire.args"
STUB
chmod +x "$BIN"/*

PLUGIN="$WORK/lib/ladspa/libdeep_filter_ladspa.so"
MODULES="$WORK/pw-modules"
mkdir -p "${PLUGIN%/*}" "$MODULES"
: > "$PLUGIN"
: > "$MODULES/libpipewire-module-filter-chain.so"

H="$WORK/home"
STATE="$H/.local/state/jayos-audio/denoise.state"
fresh() {
    rm -rf "$H" "$ST" "$WORK/run"
    mkdir -p "$H" "$ST" "$WORK/run"
}
engine() { # engine <args...>: OUT and RC, with the stand-ins first on PATH
    OUT=$(env HOME="$H" XDG_STATE_HOME="$H/.local/state" XDG_DATA_HOME="$H/.local/share" \
              XDG_CONFIG_HOME="$H/.config" XDG_RUNTIME_DIR="$WORK/run" \
              JAYOS_AUDIO_PLUGIN="${PLUGIN_OVERRIDE-$PLUGIN}" JAYOS_AUDIO_PW_MODULES="$MODULES" \
              JAYOS_AUDIO_WAIT=1 \
              PATH="$BIN:$PATH" bash "${CMD:-$ENGINE}" "$@" 2>&1)
    RC=$?
}
meta() { cat "$ST/meta.$1" 2>/dev/null; }
calls() { if [[ -f "$ST/calls" ]]; then grep -c -- "$1" "$ST/calls"; else echo 0; fi; }
hardware_default() { printf '{ "name": "%s" }' "$1" > "$ST/meta.default.configured.audio.source"; }

# ── strengths and the host's configuration ───────────────────────────────────
echo "strengths and the configuration"
fresh
engine denoise strengths
check "the strengths, in strength_params()'s order" "gentle balanced maximum" "$(tr '\n' ' ' <<<"$OUT" | sed 's/ $//')"

for s in gentle balanced maximum; do
    engine denoise config "$s"
    conf=$OUT
    # shellcheck disable=SC2046
    eval "$(sed -n "/^strength_params()/,/^}/p" "$ENGINE" | sed -n -E "s/^[[:space:]]+$s\)[[:space:]]+(.*);;$/\1/p")"
    got=$(sed -n -E 's/^[[:space:]]+"([^"]+)"[[:space:]]+= ([-0-9.]+)$/\1=\2/p' <<<"$conf" | tr '\n' ' ')
    check "$s: the six controls are strength_params()'s" \
        "Attenuation Limit (dB)=$ATTEN Min processing threshold (dB)=$MIN_T Max ERB processing threshold (dB)=$MAX_ERB Max DF processing threshold (dB)=$MAX_DF Min Processing Buffer (frames)=$BUFFER Post Filter Beta=$BETA " "$got"
done
engine denoise config balanced
says "the plugin's own mono label" "label  = deep_filter_mono" "$OUT"
says "one channel" "audio.position = [ MONO ]" "$OUT"
says "at the model's rate" "audio.rate     = 48000" "$OUT"
says "the plugin where it is" "plugin = \"$PLUGIN\"" "$OUT"
says "the capture side passive, under its name" "node.name    = \"jayos_denoise_capture\"" "$OUT"
says "the source applications record, as a source" "media.class  = Audio/Source" "$OUT"
says "real time from rtkit, not the portal" "args = { rtportal.enabled = false }" "$OUT"
says_not "no microphone named while none is chosen" "target.object" "$OUT"
mkdir -p "${STATE%/*}"; printf 'input=alsa_input.usb-Mic\n' > "$STATE"
engine denoise config balanced
says "a chosen microphone is recorded by name" 'target.object = "alsa_input.usb-Mic"' "$OUT"
engine denoise config loud
check "an unknown strength is refused" 1 "$RC"
PLUGIN_OVERRIDE="$WORK/none" engine denoise config gentle
says "with no plugin installed, where the package puts it" 'plugin = "/usr/lib/ladspa/libdeep_filter_ladspa.so"' "$OUT"

# ── status ───────────────────────────────────────────────────────────────────
echo
echo "status"
fresh
engine denoise status
check "status prints the contract's keys, in its order" \
    "$(grep -v '^#' "$CONTRACT/status-keys.txt" | tr '\n' ' ')" "$(jq -r 'keys_unsorted[]' <<<"$OUT" | tr '\n' ' ')"
check "with the plugin and the module, installed; nothing running, nothing loaded" "true false false" \
    "$(jq -r '[.installed, .running, .loaded] | map(tostring) | join(" ")' <<<"$OUT")"
check "and the legacy keys are their empty values" '0,"","",false,""' \
    "$(jq -c '[.layout, .presetsRoot, .presetFile, .presetExists, .inputPreset] | map(tojson) | join(",")' <<<"$OUT" | tr -d '\\' | sed 's/^"//; s/"$//')"
PLUGIN_OVERRIDE="$WORK/none" engine denoise status
check "no plugin: not installed, no plugin" "false false" "$(jq -r '[.installed, .plugin] | map(tostring) | join(" ")' <<<"$OUT")"
touch "$ST/active"; printf '72 jayos_denoise_source Audio/Source\n' > "$ST/nodes"
engine denoise status
check "running with the source there but another default: running, not loaded" "true false false" \
    "$(jq -r '[.running, .loaded, .isDefault] | map(tostring) | join(" ")' <<<"$OUT")"
printf '{ "name": "jayos_denoise_source" }' > "$ST/meta.default.audio.source"
engine denoise status
check "and the default: loaded" "true true" "$(jq -r '[.loaded, .isDefault] | map(tostring) | join(" ")' <<<"$OUT")"
rm -f "$ST/active"
engine denoise status
check "a source left with the host stopped is not loaded" "false" "$(jq -r '.loaded' <<<"$OUT")"

# ── on ───────────────────────────────────────────────────────────────────────
echo
echo "on"
fresh
hardware_default alsa_input.usb-Mic
engine denoise on gentle
check "on exits 0" 0 "$RC"
check "it records the microphone that was the default" "input=alsa_input.usb-Mic" "$(grep '^input=' "$STATE")"
check "and keeps the strength" "strength=gentle" "$(grep '^strength=' "$STATE")"
check "the unit is enabled and started in one call" 1 "$(calls 'systemctl --user enable --now jayos-audio-denoise.service')"
check "the filtered source is the default input" '{ "name": "jayos_denoise_source" }' "$(meta default.configured.audio.source)"
says "and it says so" "noise suppression on (gentle), recording alsa_input.usb-Mic" "$OUT"

# Again, with the filtered source the default: the microphone is the one
# recorded last, never the filter's own source, and a running host recording
# it takes the new strength live -- JayOS's popup cycles the strength through
# `on` -- with no restart, which is half a second of silence in a call.
engine denoise on maximum
check "on over a running host, the same microphone, sets the strength live" 1 \
    "$(calls 'pw-cli set-param')"
check "and does not restart it" 0 "$(calls 'systemctl --user restart jayos-audio-denoise.service')"
check "and still records the microphone, not its own source" "input=alsa_input.usb-Mic" "$(grep '^input=' "$STATE")"
check "and keeps the new strength" "strength=maximum" "$(grep '^strength=' "$STATE")"

# Another microphone made the default while it ran: a restart, since the
# running host keeps the microphone it was started with.
printf '{ "name": "alsa_input.pci-Builtin" }' > "$ST/meta.default.configured.audio.source"
printf '%s\n' "9 alsa_input.pci-Builtin Audio/Source" >> "$ST/nodes"
engine denoise on maximum
check "on over a running host, another microphone, restarts it" 1 \
    "$(calls 'systemctl --user restart jayos-audio-denoise.service')"
check "and records that one" "input=alsa_input.pci-Builtin" "$(grep '^input=' "$STATE")"

# A running host whose live set is refused is restarted instead.
fresh
hardware_default alsa_input.usb-Mic
engine denoise on gentle
touch "$ST/pwcli-fail"
engine denoise on balanced
check "on whose live set is refused restarts the host" 1 \
    "$(calls 'systemctl --user restart jayos-audio-denoise.service')"
rm -f "$ST/pwcli-fail"

fresh
printf '{ "name": "easyeffects_source" }' > "$ST/meta.default.configured.audio.source"
printf '{ "name": "alsa_input.pci-Internal" }' > "$ST/meta.default.audio.source"
engine denoise on
check "EasyEffects' source as the default: the hardware default WirePlumber chose is recorded" \
    "input=alsa_input.pci-Internal" "$(grep '^input=' "$STATE")"

fresh
PLUGIN_OVERRIDE="$WORK/none" engine denoise on
check "on without the plugin exits 1" 1 "$RC"
says "naming what is missing" "the DeepFilterNet plugin is not installed" "$OUT"
check "and starts nothing" 0 "$(calls 'systemctl')"

fresh
touch "$ST/no-source"
engine denoise on
check "a host whose source never appears: exit 1" 1 "$RC"
says "with the journal to read" "journalctl --user -u jayos-audio-denoise.service" "$OUT"
check "and the default is not moved onto a source that is not there" "" "$(meta default.configured.audio.source)"

fresh
engine denoise on loud
check "an unknown strength is refused" 1 "$RC"

# ── off ──────────────────────────────────────────────────────────────────────
echo
echo "off"
fresh
hardware_default alsa_input.usb-Mic
engine denoise on
engine denoise off
check "off exits 0" 0 "$RC"
check "the microphone is the default input again" '{ "name": "alsa_input.usb-Mic" }' "$(meta default.configured.audio.source)"
check "the unit is stopped and disabled" 1 "$(calls 'systemctl --user disable --now jayos-audio-denoise.service')"
says "and it says so" "noise suppression off, recording alsa_input.usb-Mic" "$OUT"

fresh
hardware_default alsa_input.usb-Mic
engine denoise on
hardware_default alsa_input.pci-Headset
engine denoise off
check "a default somebody chose since is left alone" '{ "name": "alsa_input.pci-Headset" }' "$(meta default.configured.audio.source)"

fresh
printf '{ "name": "jayos_denoise_source" }' > "$ST/meta.default.configured.audio.source"
engine denoise off
check "the filter's source the default, no microphone known: the key is cleared" "" "$(meta default.configured.audio.source)"

# ── input and strength ───────────────────────────────────────────────────────
echo
echo "input and strength"
fresh
hardware_default alsa_input.usb-Mic
engine denoise on
engine denoise input alsa_input.pci-Headset
check "input on a running host exits 0" 0 "$RC"
check "the capture stream is moved by its target.object" "71 target.object alsa_input.pci-Headset" "$(cat "$ST/moves" 2>/dev/null)"
check "and the next start records it too" "input=alsa_input.pci-Headset" "$(grep '^input=' "$STATE")"
engine denoise input
check "input alone prints it" "alsa_input.pci-Headset" "$OUT"
engine denoise input jayos_denoise_source
check "its own source is refused" 1 "$RC"
engine denoise input easyeffects_source
check "and EasyEffects' too" 1 "$RC"

fresh
engine denoise strength maximum
says "strength with no host: from the next start" "strength maximum, from the next start" "$OUT"
check "and no live set is attempted" 0 "$(calls 'pw-cli')"
hardware_default alsa_input.usb-Mic
engine denoise on gentle
engine denoise strength maximum
check "on a running host, set live" 1 "$(calls 'pw-cli set-param 71 Props')"
says "with all six of maximum's controls" '"df:Attenuation Limit (dB)" 100.0' "$(grep 'pw-cli set-param' "$ST/calls")"
says "the post-filter among them" '"df:Post Filter Beta" 0.05' "$(grep 'pw-cli set-param' "$ST/calls")"
check "and nothing restarted" 0 "$(calls 'systemctl --user restart')"
touch "$ST/pwcli-fail"
engine denoise strength gentle
check "a live set that fails restarts the host instead" 1 "$(calls 'systemctl --user restart')"
says "and says it did" "(the host was restarted)" "$OUT"

# ── the host ─────────────────────────────────────────────────────────────────
echo
echo "host"
fresh
mkdir -p "${STATE%/*}"; printf 'strength=maximum\ninput=alsa_input.usb-Mic\n' > "$STATE"
engine denoise host
check "host runs PipeWire on the configuration it wrote" "-c $WORK/run/jayos-audio/denoise.conf" "$(cat "$ST/pipewire.args" 2>/dev/null)"
says "for the strength kept" "for strength maximum" "$(cat "$WORK/run/jayos-audio/denoise.conf" 2>/dev/null)"
says "and the microphone kept" 'target.object = "alsa_input.usb-Mic"' "$(cat "$WORK/run/jayos-audio/denoise.conf" 2>/dev/null)"
fresh
PLUGIN_OVERRIDE="$WORK/none" engine denoise host
check "host without the plugin exits 1, running nothing" "1 absent" "$RC $([[ -e "$ST/pipewire.args" ]] && echo ran || echo absent)"

# ── the preset 1.x left in EasyEffects ───────────────────────────────────────
echo
echo "an EasyEffects preset 1.x left behind"
fresh
ee="$H/.local/share/easyeffects"
mkdir -p "$ee/input" "$ee/output" "$H/.config/easyeffects/db"
printf '{"input":{"plugins_order":["deepfilternet#0"],"deepfilternet#0":{"bypass":false}}}\n' > "$ee/input/denoise.json"
hardware_default alsa_input.usb-Mic
engine denoise on
check "on bypasses the DeepFilterNet in it" "true" "$(jq -r '.input["deepfilternet#0"].bypass' "$ee/input/denoise.json")"
says "and says what it did" "bypassed the DeepFilterNet in EasyEffects' denoise preset" "$OUT"
check "and the preset is kept" 1 "$(ls "$ee/input" | grep -c '^denoise.json$')"
engine denoise off
says_not "a preset already bypassed is not written again" "bypassed the DeepFilterNet" "$OUT"

# An instance running and holding the preset, which it restored from its own
# database un-bypassed whatever the file says: reloaded, the file bypassed
# already or not. The instance is a pgrep that finds it, a socket file, and
# a socat that answers the lib's questions as EasyEffects 8 does and writes
# down every line, all on PATH ahead of the machine's.
if command -v python3 >/dev/null 2>&1; then
    EEB="$WORK/ee-bin"
    mkdir -p "$EEB"
    cat > "$EEB/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" easyeffects "* ]]
STUB
    cat > "$EEB/socat" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -u ]] && exit 0
read -r line
printf 'heard %s\n' "$line" >> "$ST/ee.log"
[[ "$line" == get_last_loaded_preset:input ]] && echo denoise
exit 0
STUB
    chmod +x "$EEB/pgrep" "$EEB/socat"
    ee_up() { mkdir -p "$WORK/run"; python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$WORK/run/EasyEffectsServer"; }
    rm -f "$ST/ee.log"; ee_up
    PATH="$EEB:$PATH" engine denoise off
    check "an instance holding the preset, already bypassed on disk, is told to reload it" 1 \
        "$(grep -c '^heard load_preset:input:denoise$' "$ST/ee.log" 2>/dev/null || echo 0)"
    printf '{"input":{"plugins_order":["deepfilternet#0"],"deepfilternet#0":{"bypass":false}}}\n' > "$ee/input/denoise.json"
    rm -f "$ST/ee.log"
    PATH="$EEB:$PATH" engine denoise off
    check "and one whose file it has just bypassed, too" "1 true" \
        "$(grep -c '^heard load_preset:input:denoise$' "$ST/ee.log" 2>/dev/null || echo 0) $(jq -r '.input["deepfilternet#0"].bypass' "$ee/input/denoise.json")"
    rm -f "$WORK/run/EasyEffectsServer"
else
    skip "a running EasyEffects holding the 1.x preset not exercised: no python3 to make its socket"
fi

# ── jayos-denoise ────────────────────────────────────────────────────────────
echo
echo "jayos-denoise, the 1.x verbs"
fresh
CMD=$SHIM engine status; shim=$OUT
engine denoise status
check "status is the engine's" "$OUT" "$shim"
CMD=$SHIM engine strengths
check "strengths are the engine's" "gentle balanced maximum" "$(tr '\n' ' ' <<<"$OUT" | sed 's/ $//')"
CMD=$SHIM engine preset maximum off
says "preset prints the host's configuration, its off ignored" "for strength maximum" "$OUT"
hardware_default alsa_input.usb-Mic
CMD=$SHIM engine set on balanced
says "set on is on" "noise suppression on (balanced)" "$OUT"
CMD=$SHIM engine set off
says "set off is off" "noise suppression off" "$OUT"
CMD=$SHIM engine apply on gentle --force
says "apply on, --force and all, is the engine's apply" "noise suppression on (gentle)" "$OUT"
CMD=$SHIM engine apply off
says "apply off likewise" "noise suppression off" "$OUT"
CMD=$SHIM engine bogus
check "an unknown verb exits 1" 1 "$RC"

# ── real time ────────────────────────────────────────────────────────────────
echo
echo "realtime"
fresh
PROCDIR="$WORK/proc"
mkdir -p "$PROCDIR/501" "$PROCDIR/502"
printf 'Limit                     Soft Limit           Hard Limit           Units\nMax realtime timeout      200000               200000               us\n' > "$PROCDIR/501/limits"
printf 'Limit                     Soft Limit           Hard Limit           Units\nMax realtime timeout      0                    0                    us\n' > "$PROCDIR/502/limits"
printf 'pipewire\0' > "$PROCDIR/501/cmdline"
printf 'pipewire\0-c\0/run/user/1000/jayos-audio/denoise.conf\0' > "$PROCDIR/502/cmdline"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ "${*: -1}" == pipewire ]] && printf '501\n502\n'
exit 0
STUB
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" 501 "*) printf ' FF\n TS\n' ;; *) printf ' TS\n TS\n' ;; esac
STUB
chmod +x "$BIN/pgrep" "$BIN/ps"
touch "$ST/rtkit"
OUT=$(env HOME="$H" JAYOS_AUDIO_PROC="$PROCDIR" PATH="$BIN:$PATH" bash "$ENGINE" realtime 2>&1)
says "rtkit is reported" "rtkit: active" "$OUT"
says "a process with a real-time thread and its limit" "pipewire 501: 1 real-time thread(s), hard RLIMIT_RTTIME 200000" "$OUT"
says "and the host, by its configuration, with a limit of 0" "pipewire (noise suppression host) 502: 0 real-time thread(s), hard RLIMIT_RTTIME 0" "$OUT"
rm -f "$BIN/pgrep" "$BIN/ps"

# ── docs/DEEPFILTERNET.md's strength table ───────────────────────────────────
#
# The table is a transcription of strength_params(), and a transcription rots.
# The first six numbers of each row, in the order the function names them. A
# missing document is a defect in the tree, not something this machine lacks,
# so it fails: in 1.x it was once an uncounted note, and the comparison
# silently did not happen.
echo
echo "docs/DEEPFILTERNET.md's strength table"
DOC="$ROOT/docs/DEEPFILTERNET.md"
ARMS=$(sed -n '/^strength_params() {/,/^}/p' "$ENGINE")
arm_numbers() { # arm_numbers <name> -> "24 -15 30 20 2 0.02"
    grep -E "^\s*$1\)" <<<"$ARMS" | head -1 \
        | grep -oE '=-?[0-9]+(\.[0-9]+)?' | tr -d '=' \
        | sed -E 's/^(-?[0-9]+)\.0+$/\1/' | tr '\n' ' ' | sed 's/ $//'
}
if [[ ! -f "$DOC" ]]; then
    bad "docs/DEEPFILTERNET.md is not in the tree, so its strength table cannot be compared with the engine"
else
    while IFS= read -r s; do
        ROW=$(grep -iE "^\|[[:space:]]*\**$s\**[[:space:]]*\|" "$DOC" | head -1)
        if [[ -z "$ROW" ]]; then
            bad "docs/DEEPFILTERNET.md has no table row for $s"
            continue
        fi
        # The document may spell the minus sign as U+2212; the shell does not.
        DOC_NUMS=$(sed 's/\xe2\x88\x92/-/g' <<<"$ROW" | cut -d'|' -f3- \
                   | grep -oE -- '-?[0-9]+(\.[0-9]+)?' | head -6 | tr '\n' ' ' | sed 's/ $//')
        check "docs/DEEPFILTERNET.md's $s row states the engine's numbers" "$(arm_numbers "$s")" "$DOC_NUMS"
    done < <(bash "$ENGINE" denoise strengths)
fi

echo
SKIPPED=""
(( SKIP > 0 )) && SKIPPED=", $SKIP not exercised"
printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$SKIPPED"
(( FAIL == 0 ))
