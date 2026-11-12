#!/usr/bin/env bash
#
# src/easyeffects.sh, as `jayos-audio easyeffects` runs it: the settings an
# install puts back, the game tag, the status a desktop draws, the device a
# doctor asks for, and the start hook -- with no EasyEffects running.
#
# MOVED WITH THE SCRIPT. The script came here from JayOS's
# config/common/scripts/hypr/easyeffects.sh, and JayOS's
# tools/test-easyeffects.sh still runs this package's copy of it -- vendored
# into its tools/fixtures/jayos-audio-contract/ -- through its wrapper, its
# popup, its doctor and its installer, against a stand-in EasyEffects that
# listens on its socket, stops, saves and starts again. That is the half of
# the behaviour a running instance has. This suite is the half that needs
# none, held here, so that a change to the script fails in this repository
# before it is vendored anywhere: every case runs with `pgrep` answering
# that nothing runs, an `easyeffects` that is only on PATH, and no socat.
#
# Exit 0 when every case passes, 1 when any fails, 2 when it could not run
# (no jq, which the script needs to write its status and its blocklist).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-audio"
EE="$ROOT/src/easyeffects.sh"
LIB="$ROOT/src/easyeffects-lib.sh"
CONTRACT="$ROOT/contract"

command -v jq >/dev/null 2>&1 || { echo "test-easyeffects not exercised: jq is not installed" >&2; exit 2; }
for f in "$ENGINE" "$EE" "$LIB" "$CONTRACT/easyeffects-commands.txt"; do
    [[ -r "$f" ]] || { echo "cannot read ${f#"$ROOT"/}" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-ee.XXXXXX")" || exit 2
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
says() { if grep -qF -- "$2" <<< "$3"; then pass "$1"; else
             bad "$1"; printf '         wanted: %s\n' "$2"
             printf '%s\n' "$3" | sed 's/^/         got:    /'; fi; }
code_sh() { grep -vE '^[[:space:]]*#' "$1"; }

# The stand-ins: an easyeffects that is installed and never run, a pgrep that
# says nothing runs, and a pactl whose answers are files. Every other command
# is the system's, minus socat, which would let the script look for a socket.
BIN="$WORK/bin"
NOEE="$WORK/noee"
mkdir -p "$BIN" "$NOEE"
printf '#!/bin/bash\necho "easyeffects ran: $*" >> "%s/ee.calls"\n' "$WORK" > "$BIN/easyeffects"
printf '#!/bin/bash\nexit 1\n' > "$BIN/pgrep"
cat > "$BIN/pactl" <<STUB
#!/bin/bash
case "\$*" in
    "-f json list sinks")   cat "$WORK/sinks.json" 2>/dev/null || echo '[]' ;;
    "-f json list sources") cat "$WORK/sources.json" 2>/dev/null || echo '[]' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$BIN/easyeffects" "$BIN/pgrep" "$BIN/pactl"
cp "$BIN/pgrep" "$BIN/pactl" "$NOEE/"
# The system's PATH, with every directory that holds socat or easyeffects
# replaced by links to the rest of it.
SYS="$WORK/sys"
mkdir -p "$SYS"
IFS=: read -ra DIRS <<<"$PATH"
for d in "${DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        n=${f##*/}
        [[ "$n" == socat || "$n" == easyeffects || -e "$SYS/$n" ]] && continue
        [[ -x "$f" && ! -d "$f" ]] && ln -s "$f" "$SYS/$n"
    done
done

HOME_DIR="$WORK/home"
RC="$HOME_DIR/.config/easyeffects/db/easyeffectsrc"
fresh() { rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/.config" "$HOME_DIR/.local/share/easyeffects/db"; }
rc() { mkdir -p "${RC%/*}"; printf '%s\n' "$1" > "$RC"; }
# run [VAR=value...] <args...>: the engine's easyeffects verb, in a clean
# environment with the stand-ins first.
run() {
    local envs=()
    while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
    env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_DATA_HOME="$HOME_DIR/.local/share" \
        XDG_RUNTIME_DIR="$WORK/run" PATH="${RUN_PATH:-$BIN:$SYS}" "${envs[@]}" \
        bash "$ENGINE" easyeffects "$@"
}
mkdir -p "$WORK/run"

# ── the tables, as the script holds them ─────────────────────────────────────
echo
echo "the settings the script holds"
table() { code_sh "$EE" | sed -n "/^$1=(/,/^)/p" | sed '1d;$d' | grep -oE '"[^"]+"|[^[:space:]"]+' | tr -d '"'; }
rows()  { code_sh "$EE" | sed -n "/^$1=(/,/^)/p" | sed -nE 's/^[[:space:]]*"([^"]*)"$/\1/p'; }
EXPECTED_ROWS=$(rows EXPECTED)
check "EXPECTED: nine settings at EasyEffects' defaults" 9 "$(grep -c . <<<"$EXPECTED_ROWS")"
check "among them the input chain's inactivity timer, on" 1 \
    "$(grep -cx 'EffectsPipelines inputInactivityTimerEnable true' <<<"$EXPECTED_ROWS")"
check "WANTED: recordings kept out, and a preset's blocklist never loaded over ours" \
    "EffectsPipelines processAllInputs false
Presets ignorePresetBlocklist true" "$(rows WANTED)"
TAG=$(code_sh "$EE" | sed -n 's/^GAME_TAG="\(.*\)"$/\1/p')
check "GAME_TAG is jayos-game" "jayos-game" "$TAG"
GAMES=$(table GAME_APPS | sed "s/^\\\$GAME_TAG\$/$TAG/")
check "GAME_APPS: Wine's loaders, Steam, and the tag" "wine steam jayos-game" "$(paste -sd' ' <<<"$GAMES")"
VOICE=$(table VOICE_APPS)
check "VOICE_APPS: serpantinum-audio's list, Element, Steam's voice chat and Signal, 30 names" 30 "$(grep -c . <<<"$VOICE")"
check "Steam's web helper and Signal's three names among them" "steamwebhelper signal-desktop Signal org.signal.Signal" \
    "$(grep -xE 'steamwebhelper|signal-desktop|Signal|org\.signal\.Signal' <<<"$VOICE" | paste -sd' ' -)"
SKIP_JOINED=$(printf '%s\n' "$VOICE" "$GAMES" | paste -sd, -)

# ── what an install puts back ───────────────────────────────────────────────
echo
echo "what an install puts back, with nothing running"
fresh
OUT=$(run defaults --check 2>&1); STATUS=$?
check "no rc: --check exits 1, naming the three set away from the defaults" \
    "1|[EffectsPipelines] processAllInputs is (unset); this configuration sets false
[Presets] ignorePresetBlocklist is (unset); this configuration sets true
[StreamOutputs] blocklist lacks 33 voice-chat application(s) and game(s): $(tr ',' ' ' <<<"$SKIP_JOINED")" \
    "$STATUS|$OUT"
OUT=$(run defaults 2>&1); STATUS=$?
check "defaults writes those three and nothing else" "0|[EffectsPipelines]
processAllInputs=false

[Presets]
ignorePresetBlocklist=true

[StreamOutputs]
blocklist=$SKIP_JOINED" "$STATUS|$(cat "$RC")"
OUT=$(run defaults --check 2>&1); STATUS=$?
check "after which --check is clean" "0|" "$STATUS|$OUT"
check "and EasyEffects was never started" "" "$(cat "$WORK/ee.calls" 2>/dev/null)"

# Each of the nine away from its default, in a spelling KConfig reads that
# way, beside the tail the three need: put back, and nothing else moved.
TAIL=$'\n[EffectsPipelines]\nprocessAllInputs=false\n\n[Presets]\nignorePresetBlocklist=true\n\n[StreamOutputs]\nblocklist='"$SKIP_JOINED"
while read -r group key default; do
    [[ -n "$group" ]] || continue
    if [[ "$default" == true ]]; then value=Off; else value=Yes; fi
    fresh
    BEFORE=$'[Other]\nkept=1\n\n['"$group"$']\nmine=2\n'"$key=$value"$'\n'"$TAIL"
    rc "$BEFORE"
    OUT=$(run defaults 2>&1); STATUS=$?
    check "[$group] $key=$value is put back to $default, the rest byte for byte" \
        "0|[$group] $key was $value; now $default, EasyEffects' default|$(grep -vxF -- "$key=$value" <<<"$BEFORE")" \
        "$STATUS|$OUT|$(cat "$RC")"
done <<<"$EXPECTED_ROWS"

# The person's own blocklist: theirs first and as written, an escaped comma
# kept, theirs and ours once each, ours that are missing after.
fresh
rc $'[EffectsPipelines]\nprocessAllInputs=false\n\n[Presets]\nignorePresetBlocklist=true\n\n[StreamOutputs]\nblocklist=spotify,my\\\\,app,Discord,wine'
OUT=$(run defaults 2>&1); STATUS=$?
BL=$(sed -n 's/^blocklist=//p' "$RC")
check "a blocklist of the person's is merged into: 31 added, theirs first" "0|spotify,my\\\\,app,Discord,wine," \
    "$STATUS|${BL:0:30}"
says "saying how many and which" "[StreamOutputs] blocklist: added 31 voice-chat application(s) and game(s), kept the rest: discord" "$OUT"
check "Discord and wine once each" "1 1" "$(tr ',' '\n' <<<"$BL" | grep -cx Discord) $(tr ',' '\n' <<<"$BL" | grep -cx wine)"

# A preset's blocklist turned back on by hand is turned off again.
fresh
rc "${TAIL/ignorePresetBlocklist=true/ignorePresetBlocklist=false}"
OUT=$(run defaults 2>&1); STATUS=$?
check "ignorePresetBlocklist=false is set true again" \
    "0|[Presets] ignorePresetBlocklist was false; now true, which this configuration sets" "$STATUS|$OUT"

fresh; mkdir -p "$RC"
OUT=$(run defaults --check 2>&1); STATUS=$?
check "an rc that cannot be read examined nothing: exit 2" 2 "$STATUS"

fresh
OUT=$(RUN_PATH="$NOEE:$SYS" run defaults 2>&1); STATUS=$?
check "without EasyEffects, defaults refuses and writes nothing" "1|absent" \
    "$STATUS|$([[ -e "$RC" ]] && echo present || echo absent)"

# ── the game tag ─────────────────────────────────────────────────────────────
echo
echo "the game tag a launcher is started with"
OUT=$(run game-env 2>&1); STATUS=$?
check "game-env: two variables naming the node the tag" \
    "0|PULSE_PROP=node.name=$TAG
PIPEWIRE_PROPS={ node.name = \"$TAG\" }" "$STATUS|$OUT"
OUT=$(run PULSE_PROP='media.role=game' game-env 2>&1)
check "a PULSE_PROP already set is joined" "PULSE_PROP=media.role=game node.name=$TAG" "$(head -1 <<<"$OUT")"
OUT=$(run 'PIPEWIRE_PROPS={ a = b }' game-env 2>&1)
check "a PIPEWIRE_PROPS already set is left alone" "PULSE_PROP=node.name=$TAG" "$OUT"
OUT=$(RUN_PATH="$NOEE:$SYS" run game-env 2>&1); STATUS=$?
check "and the same without EasyEffects" "0|2" "$STATUS|$(grep -c . <<<"$OUT")"

# ── the status a desktop draws ───────────────────────────────────────────────
echo
echo "the status a desktop draws"
fresh
OUT=$(RUN_PATH="$NOEE:$SYS" run status 2>&1); STATUS=$?
check "without EasyEffects: installed false, and the engine is this package" "0|false|true" \
    "$STATUS|$(jq -r '.installed' <<<"$OUT" 2>/dev/null)|$(jq -r '.engine' <<<"$OUT" 2>/dev/null)"
mkdir -p "$HOME_DIR/.local/share/easyeffects/output"
: > "$HOME_DIR/.local/share/easyeffects/output/Flat.json"
: > "$HOME_DIR/.local/share/easyeffects/output/live_eq.json"
OUT=$(run status 2>&1); STATUS=$?
check "installed and not running: its output presets, sorted, and running false" \
    '0|true|false|["Flat","live_eq"]' \
    "$STATUS|$(jq -r '.installed' <<<"$OUT" 2>/dev/null)|$(jq -r '.running' <<<"$OUT" 2>/dev/null)|$(jq -c '.outputPresets' <<<"$OUT" 2>/dev/null)"

# ── the device a doctor asks for ─────────────────────────────────────────────
echo
echo "the hardware device ranked first"
printf '%s' '[{"name":"easyeffects_sink","properties":{"media.class":"Audio/Sink"}},
  {"name":"alsa_output.low","properties":{"media.class":"Audio/Sink","device.api":"alsa","priority.session":"500"}},
  {"name":"alsa_output.high","properties":{"media.class":"Audio/Sink","device.api":"alsa","priority.session":"1000"}}]' \
    > "$WORK/sinks.json"
OUT=$(run best-device sink 2>&1); STATUS=$?
check "best-device sink: the hardware sink with the highest priority.session" "0|alsa_output.high" "$STATUS|$OUT"
printf '[]' > "$WORK/sources.json"
OUT=$(run best-device source 2>&1); STATUS=$?
check "and exits 1 where there is none" "1|" "$STATUS|$OUT"
OUT=$(run best-device elsewhere 2>&1); STATUS=$?
check "and 2 for a side it does not know" 2 "$STATUS"

# ── the equaliser ────────────────────────────────────────────────────────────
echo
echo "the equaliser's preset, from the desktop's slider state"
# A stand-in builder: prints a preset and exits with the status in a file.
cat > "$WORK/eqbuild" <<STUB
#!/bin/bash
[[ "\$1" == build && -n "\$2" ]] || exit 9
printf '{"output":{"blocklist":[],"plugins_order":["equalizer#0"]}}\n'
exit "\$(cat "$WORK/eq.status" 2>/dev/null || echo 0)"
STUB
chmod +x "$WORK/eqbuild"
EQ_FILE="$HOME_DIR/.local/share/easyeffects/output/live_eq.json"
eq() { # eq <builder status> [PATH]: the verb over a state file, without EasyEffects unless PATH says
    echo "$1" > "$WORK/eq.status"
    RUN_PATH="${2:-$NOEE:$SYS}" run JAYOS_EQUALIZER_PRESET="$WORK/eqbuild" equalizer "$WORK/eq_state.json" 2>&1
}
fresh; echo '{}' > "$WORK/eq_state.json"
OUT=$(eq 0); STATUS=$?
check "every slider read, no EasyEffects: the preset is written, and the verb says nothing loads it" \
    '0|{"output":{"blocklist":[],"plugins_order":["equalizer#0"]}}|1' \
    "$STATUS|$(cat "$EQ_FILE" 2>/dev/null)|$(grep -c 'easyeffects is not installed, so nothing loads' <<<"$OUT")"
printf 'the curve before\n' > "$EQ_FILE"
OUT=$(eq 2); STATUS=$?
check "nothing read (exit 2): the preset on disk is left as it was, and the verb fails saying why" \
    "1|the curve before|1" \
    "$STATUS|$(cat "$EQ_FILE")|$(grep -c 'no preset could be built from' <<<"$OUT")"
check "with nothing half written beside it" "" \
    "$(find "${EQ_FILE%/*}" -name '.live_eq.json.*' | head -1)"
OUT=$(eq 1); STATUS=$?
check "one slider unread (exit 1): the other nine are written" '0|{"output":{"blocklist":[],"plugins_order":["equalizer#0"]}}' \
    "$STATUS|$(cat "$EQ_FILE")"
OUT=$(eq 0 "$BIN:$SYS"); STATUS=$?
check "EasyEffects 8 installed and no socat: written, and the verb fails, naming socat" "1|1" \
    "$STATUS|$(grep -c "socat is not installed" <<<"$OUT")"
OUT=$(RUN_PATH="$NOEE:$SYS" run equalizer 2>&1); STATUS=$?
check "and with no state file named, its usage" "1|1" "$STATUS|$(grep -c '^usage: easyeffects.sh equalizer' <<<"$OUT")"

# ── the start hook ───────────────────────────────────────────────────────────
echo
echo "the caller's start hook"
cat > "$WORK/hook.sh" <<HOOK
printf '%s\n' "\$*" >> "$WORK/hook.calls"
HOOK
# Under set -u and pipefail, as easyeffects.sh sources the library: a hook
# left unset must not end the caller with "unbound variable". Each run says
# "after" once the call returns, and what the hook wrote follows it.
hook() { # hook [value]: ee_on_start with JAYOS_AUDIO_EE_ON_START at value, or unset
    local said
    rm -f "$WORK/hook.calls"
    if (( $# )); then
        said=$(env -i HOME="$HOME_DIR" PATH="$BIN:$SYS" JAYOS_AUDIO_EE_ON_START="$1" bash -c "set -uo pipefail; source '$LIB'; ee_on_start; echo after" 2>&1)
    else
        said=$(env -i HOME="$HOME_DIR" PATH="$BIN:$SYS" bash -c "set -uo pipefail; source '$LIB'; ee_on_start; echo after" 2>&1)
    fi
    for _ in $(seq 30); do [[ -s "$WORK/hook.calls" ]] && break; sleep 0.1; done
    printf '%s|%s' "$said" "$(cat "$WORK/hook.calls" 2>/dev/null)"
}
check "ee_on_start runs the command it is named, with its words, detached" "after|apply now" \
    "$(hook "$WORK/hook.sh apply now")"
check "and runs nothing where none is named, the caller going on under set -u" "after|" "$(hook)"
check "or where the name is empty" "after|" "$(hook '')"
check "the desktop's own script is named nowhere on a code line" 0 \
    "$(code_sh "$LIB" | grep -c 'hypr/denoise\.sh')"

# ── the engine hands the verb on ─────────────────────────────────────────────
echo
echo "jayos-audio easyeffects"
OUT=$(run nonsense 2>&1); STATUS=$?
check "a verb the script does not know: its usage, and its exit status" "1|1" \
    "$STATUS|$(grep -c '^usage: easyeffects.sh ' <<<"$OUT")"
VERBS=$(sed -n 's/^jayos-audio easyeffects \([a-z-]*\).*/\1/p' "$CONTRACT/easyeffects-commands.txt" | paste -sd'|' -)
DISPATCH=$(code_sh "$EE" | sed -nE 's/^    ([a-z][a-z-]*)\)$/\1/p' | paste -sd'|' -)
check "the verbs the contract lists are the script's dispatch, every one and no other" \
    "$(tr '|' '\n' <<<"$VERBS" | sort | paste -sd'|' -)" "$(tr '|' '\n' <<<"$DISPATCH" | sort | paste -sd'|' -)"
mkdir -p "$WORK/lone"
cp "$ENGINE" "$WORK/lone/jayos-audio"
OUT=$(env -i PATH="$BIN:$SYS" HOME="$HOME_DIR" bash "$WORK/lone/jayos-audio" easyeffects status 2>&1); STATUS=$?
check "an engine with no easyeffects.sh beside it says so and fails" "1|1" \
    "$STATUS|$(grep -c 'easyeffects.sh is not beside' <<<"$OUT")"

echo
if (( FAIL )); then
    printf '  \033[31m%d passed, %d failed%s\033[0m\n' "$PASS" "$FAIL" "$( (( SKIP )) && printf ', %d not exercised' "$SKIP")"
    exit 1
fi
if (( SKIP )); then
    printf '  \033[32m%d passed, %d not exercised\033[0m\n' "$PASS" "$SKIP"
else
    printf '  \033[32m%d passed\033[0m\n' "$PASS"
fi
exit 0
