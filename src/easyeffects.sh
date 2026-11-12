#!/usr/bin/env bash
#
# EasyEffects quick controls for the volume popup.
#
# Run as `jayos-audio easyeffects <verb>`, which hands every verb here.
#
# MOVED FROM JAYOS at jayos commit ac951df1: this was the desktop's
# config/common/scripts/hypr/easyeffects.sh, whose verbs its volume popup, its
# doctor, its installer and its AudioDefaultsService call. The desktop keeps
# a script of that name, which hands each verb to this one with the
# environment below and answers alone where this package is not installed.
# The comments are the desktop's and name its paths. Three edits, each said
# where it is: the library is beside this file, jayos-audio-state is
# this package's, and the start hook is the caller's command rather than the
# desktop's script (the library's ee_on_start).
#
#   easyeffects.sh status              JSON: installed, running, bypassed, presets, plugin,
#                                      engine, denoise (the noise filter's running, loaded,
#                                      input and isDefault), and which of the daemon's
#                                      values it answered itself
#   easyeffects.sh presets [output|input]
#   easyeffects.sh load <name> [output|input]
#                                      that pipeline's preset by that name; with no pipeline
#                                      named, input and output, whichever has one
#   easyeffects.sh bypass on|off|toggle
#   easyeffects.sh open                open the full application window
#   easyeffects.sh start               start it in the background
#   easyeffects.sh defaults [--check]  put back the settings this configuration relies on:
#                                      nine at EasyEffects' own defaults, recordings not
#                                      processed, a preset's blocklist not loaded over
#                                      ours, and the voice-chat applications and games on
#                                      the output blocklist; --check only names those
#                                      that differ, and exits 1 when any does
#   easyeffects.sh game-env            the environment, one NAME=value a line, that marks
#                                      every stream a game launcher's processes play as a
#                                      game's, for the blocklist's GAME_TAG
#   easyeffects.sh default-devices     where EasyEffects' own sink or source is the default,
#                                      make the device behind it the default again, or,
#                                      where none is named, the hardware one ranked first
#   easyeffects.sh equalizer <state-file>
#                                      the desktop's equaliser, from the ten sliders in
#                                      its state file, written as the output preset
#                                      live_eq and loaded -- into one started for it
#                                      when none runs
#   easyeffects.sh best-device sink|source
#                                      the hardware one ranked first, by name; exits 1
#                                      where none is connected
#
# An instance that load, open or start brings up is given the noise setting
# (`denoise.sh apply`, which reads it and hands it to the jayos-audio
# package's engine), as the one the unit starts at login is -- spawned
# before the wait for it, so that a click that stops this, or a popup closed
# meanwhile, cannot lose it (easyeffects-lib.sh, ee_on_start,
# which says what is left of that since the filter left EasyEffects).
#
# A load, the bypass and every question go to a running instance over its
# socket, through easyeffects-lib.sh, and not through the `easyeffects`
# command line: at 8.2.9 its `-l` and `-b` also close the application's
# window (the lib's header has the upstream lines). `open` still runs the
# command line with no arguments, which sends show_window and nothing else.
# Starting an instance just to load a preset would open the whole window over
# whatever you were doing, so anything that needs one starts it hidden
# (--hide-window --service-mode) first and waits for it.
#
# Where presets live, and how the current one is read, changed in EasyEffects
# 8.0.0. That is all in easyeffects-lib.sh, which this sources rather than
# repeating; see the note at the top of it.

set -uo pipefail

HERE="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# Beside this file, where the package installs both (/usr/lib/jayos-audio)
# and where a checkout keeps them (src/); the desktop's was one directory up.
# shellcheck source=easyeffects-lib.sh
source "$HERE/easyeffects-lib.sh"

# The hardware sink or source the session would choose with no default
# configured, by pactl's list: not one of EasyEffects' nodes, not a sink's
# monitor, a device's own node (device.api, which ALSA's and BlueZ's carry and
# a software sink does not) of the plain media class, its active port not
# unplugged, and then the highest priority.session, WirePlumber's own ranking
# -- the first listed among equals. Nothing where there is none. pactl's JSON
# and WirePlumber's choice are read, not run.
best_device() { # best_device sink|source
    command -v jq >/dev/null 2>&1 || return 0
    LC_ALL=C timeout 3 pactl -f json list "$1s" 2>/dev/null | jq -r --arg class "Audio/${1^}" '
        [.[]? | select(type == "object" and (.name | type) == "string")
         | select((.name | startswith("easyeffects_")) | not)
         | (.properties // {}) as $p
         | select(($p["device.class"] // "") != "monitor" and (.name | endswith(".monitor") | not))
         | select(($p["media.class"] // "") == $class and ($p["device.api"] // "") != "")
         | (.active_port // "") as $port
         | select(([.ports[]? | select(.name == $port) | .availability][0] // "") != "not available")
         | {name, rank: (($p["priority.session"] // "0") | tonumber? // 0)}]
        | sort_by(-.rank) | first | .name // empty' 2>/dev/null
}

require_installed() {
    ee_installed && return 0
    echo '{"installed":false}' >&2
    exit 1
}

# Presets are read from disk rather than from `easyeffects -p`, so the list is
# available whether or not the application is running -- which is the normal
# case when the popup is first opened.
#
# Into an array named by the caller, not onto stdout a line at a time: a file
# name may hold a newline, and a line-by-line list turned one such preset into
# two that do not exist.
preset_names() { # preset_names <output|input> <array name>
    local -n _names="$2"
    local dir file
    _names=()
    dir="$(ee_presets_root)/$1"
    [[ -d "$dir" ]] || return 0
    for file in "$dir"/*.json; do
        [[ -e "$file" ]] || continue
        file="${file##*/}"
        _names+=("${file%.json}")
    done
}

# A JSON array of strings, every byte escaped the way JSON requires.
#
# jq rather than an escaper of our own: the one that was here doubled `\`
# and `"` and nothing else, and JSON forbids every raw byte below 0x20 in a
# string. EasyEffects' validator refuses only `/` and `\`
# (contents/ui/Validators.qml) and an imported preset keeps its file name, so
# one tab in one name made the whole status unparseable -- and the popup's
# JSON.parse failing reads as "not installed", which hid both of its
# EasyEffects rows.
json_strings() { # json_strings <string>...
    jq -nc '$ARGS.positional' --args "$@"
}

# THE SETTINGS THIS CONFIGURATION RELIES ON, nine of them at EasyEffects' own
# default (src/contents/kcfg/easyeffects_db.kcfg, easyeffects_db_streaminputs.kcfg
# and easyeffects_db_streamoutputs.kcfg at v8.2.9, read; the ninth at v8.3.2),
# where no feature
# here sets any of them, and every one that needs one assumes the default:
#
#   bypass                  false  the Effects switch on. On, every plugin is out of
#                                  both chains, the microphone's filter and the
#                                  equaliser with them -- the doctor's "loaded, but
#                                  not filtering". EasyEffects turns it off itself
#                                  whenever the device changes
#                                  (resetBypassOnDeviceChange, true by default)
#   processAllOutputs       true   every playback stream through the output effects,
#                                  which is how the equaliser reaches what plays
#   excludeMonitorStreams   true   a recording of a sink's monitor -- desktop audio,
#                                  a screen recorder -- left alone. Off, it is moved
#                                  onto EasyEffects' source, which is the microphone
#   useDefaultInputDevice   true   the microphone recorded is the one the volume
#                                  popup makes the default, not one pinned earlier
#   useDefaultOutputDevice  true   and the device played into, the popup's default
#   listenToMic             false  the microphone not played back to the speakers: a
#                                  test switch, saved like any other setting, so a
#                                  test left on is heard after every restart
#   linkToVirtualSource     false  what plays not mixed into what applications record
#                                  as the microphone
#   autostartOnLogin        false  easyeffects.service starts it. EasyEffects' own
#                                  login entry is a second start, which uwsm runs at
#                                  login (startup.sh says so) and which races the
#                                  unit for the lock; when it wins, the instance
#                                  runs outside the unit, whose Restart= brings it
#                                  back and whose journal the doctor reads for the
#                                  filter's warnings
#   inputInactivityTimerEnable
#                           true   the input chain unlinked ten seconds after nothing
#                                  records EasyEffects' source. With processAllInputs
#                                  false nothing does, but EasyEffects links the
#                                  default input through its input preset as it starts
#                                  (StreamInputEffects' constructor ends in
#                                  connect_filters, src/stream_input_effects.cpp at
#                                  v8.3.2, read), and only this timer unlinks it: off,
#                                  the input preset's plugins ran on the noise filter's
#                                  source all session, in the one data thread the
#                                  equaliser runs in, with nobody hearing them
#
# Three more are set away from EasyEffects' defaults, in WANTED, VOICE_APPS
# and GAME_APPS below. Every other key is left as it is: the presets loaded and their
# plugins, the devices EasyEffects names, the input blocklist, the window.
# Those are EasyEffects' state or somebody's choice, and nothing here depends
# on their value.
EXPECTED=(
    "EffectsPipelines bypass false"
    "EffectsPipelines processAllOutputs true"
    "EffectsPipelines excludeMonitorStreams true"
    "StreamInputs useDefaultInputDevice true"
    "StreamOutputs useDefaultOutputDevice true"
    "StreamInputs listenToMic false"
    "StreamOutputs linkToVirtualSource false"
    "Window autostartOnLogin false"
    "EffectsPipelines inputInactivityTimerEnable true"
)

# THE SETTINGS SET AWAY FROM EASYEFFECTS' DEFAULTS, by the owner's call on
# 2026-11-11, written where the rc holds another value or none:
#
#   processAllInputs        false  no recording through EasyEffects. On, every
#                                  recording was moved onto easyeffects_source,
#                                  through the input preset, in EasyEffects' one
#                                  data thread beside every output effect, and the
#                                  microphone lagged and cut out in calls with the
#                                  Effects switch on (docs/AUDIO.md, The microphone
#                                  leaves EasyEffects). The noise filter is
#                                  jayos-audio's own PipeWire filter-chain now, and
#                                  needs nothing of EasyEffects
#   ignorePresetBlocklist   true   by the owner's call of 2026-11-11, "don't route
#                                  video games output through easy effects": a preset
#                                  loaded leaves the output blocklist as it is. Off,
#                                  EasyEffects puts each preset's own blocklist in its
#                                  place as it loads it, and an empty one where the
#                                  preset has none (Manager::load_blocklist,
#                                  src/presets_manager.cpp at v8.3.2, read) -- every
#                                  preset the equaliser writes carries "blocklist": [],
#                                  so the first equaliser preset picked put every voice
#                                  application and game below back on the effects
#
# Each is written as KConfig writes a bool, `processAllInputs=false` under
# [EffectsPipelines], `ignorePresetBlocklist=true` under [Presets]; a person who
# turns one back in EasyEffects has the next install turn it again, as it puts
# the nine above back.
WANTED=(
    "EffectsPipelines processAllInputs false"
    "Presets ignorePresetBlocklist true"
)

# The voice-chat applications kept off the output effects, by the owner's
# call on 2026-11-11: serpantinum-audio's list (its src/exclude.h, read on
# 2026-11-11), and Element, the owner's. A call's far end is already
# processed by the sender and the call's own echo canceller; an equaliser
# between it and the speakers changes what that canceller hears come back.
# EasyEffects keeps an output stream off its effects when its application.id,
# application.process.binary or node.name STARTS WITH an entry of [StreamOutputs]
# blocklist, case and all (NodeManager's app_is_blocklisted in
# src/pw_node_manager.cpp at v8.3.2, read), so each application is named as
# each of the three may spell it: its binary, its Flatpak id, the node name
# PipeWire gives a stream from its application.name (pw_stream_new in
# src/pipewire/stream.c, read), and the voice engine WebRTC names its own
# PulseAudio client after. EasyEffects has no rule by media.role, so
# serpantinum's skip of every call-role stream has no equivalent here. Merged
# into the person's list, never over it: an entry already there is left, and
# nothing is removed.
#
# And, by the owner's call on 2026-11-12, "Steam party voice chat, steam
# in-game voice chat, and signal, should not be routed through easyeffects
# for audio output":
#
#   steamwebhelper     Steam's chat, its party voice chat and the overlay's,
#                      which Steam's client runs in its web helper, a
#                      Chromium -- read, not run: its binary. GAME_APPS'
#                      `steam` begins it too; named here so that it is a
#                      voice application by its own entry
#   signal-desktop     Signal, as Arch's signal-desktop runs it: electron-
#   Signal             builder's own Electron at
#   org.signal.Signal  /usr/lib/signal-desktop/signal-desktop (its PKGBUILD's
#                      package(), and the signal-desktop.sh it installs in
#                      /usr/bin, read on 2026-11-12), so the binary is its
#                      name; Signal, the application.name Electron gives its
#                      PulseAudio client, from which its node is named; and
#                      the Flatpak's id. A call's engine, RingRTC, is
#                      built on WebRTC, which names its own PulseAudio client
#                      `WEBRTC VoiceEngine` (above) -- read, not run -- in
#                      the same process, whose binary is the first name
#
# A game's in-game voice chat -- Steam's voice API, which the game decodes
# and plays itself -- is the game's own stream, so GAME_APPS keeps it off:
# Proton's by `wine`, and a native game's by the tag a launcher gives it.
VOICE_APPS=(
    Discord discord com.discordapp
    vesktop Vesktop dev.vencord.Vesktop
    equibop Equibop io.github.equicord.equibop
    legcord Legcord app.legcord.Legcord
    armcord ArmCord
    webcord WebCord io.github.spacingbat3.webcord
    "WEBRTC VoiceEngine"
    zoom "ZOOM VoiceEngine" us.zoom.Zoom
    teams-for-linux com.github.IsmaelMartinez.teams_for_linux
    Element element-desktop im.riot.Riot
    steamwebhelper
    signal-desktop Signal org.signal.Signal
)

# The games kept off the output effects, by the owner's call on 2026-11-11:
# "don't route video games output through easy effects". A game mixes its own
# sound for its own speakers and headphones settings, and an equaliser tuned
# for music moves where its footsteps and its voices sit -- and its effects
# ride the data thread every other stream's do, where a late cycle is a gap.
#
# No property says "game" (PipeWire has none, and EasyEffects matches only the
# three above), so a game is named two ways:
#
#   wine        Wine and Proton, whichever launcher started them: libpulse
#               names its client's application.process.binary after
#               /proc/self/exe, which for a Windows program is Wine's loader
#               -- wine, wine64, wine-preloader, wine64-preloader -- never the
#               .exe, and every one starts with "wine"
#   steam       the Steam client and its steamwebhelper, which carries Steam's
#               own voice chat
#   GAME_TAG    everything a game launcher's processes play, native games
#               among them, whose binaries no list could name: game_env below
#               gives the launcher an environment that names every stream
#               they make GAME_TAG, and hypr/launch.sh, hypr/steam-open.sh and
#               hypr/steam-gamescope.sh start Steam and Prism Launcher with it
#
# Merged as VOICE_APPS is, never over the person's list.
GAME_TAG="jayos-game"
GAME_APPS=(
    wine
    steam
    "$GAME_TAG"
)

# The environment that tags a game launcher's streams, one NAME=value a line.
#
# node.name, because it is the one property EasyEffects matches that a client
# can be told from outside: PULSE_PROP is read by libpulse into every context
# the process opens (pa_init_proplist in src/pulse/context.c, read), and
# PIPEWIRE_PROPS by libpipewire into every stream and filter it connects, after
# the configuration's stream.rules (pw_stream_connect in src/pipewire/stream.c
# at 1.7.0, read). Run here, in a box of PipeWire 1.0.5: a paplay under the
# first and a pw-play under the second both made nodes named jayos-game, their
# application.name kept. Not application.id, which a game seldom sets and
# which would have tagged as well: WirePlumber keys each stream's saved volume
# by the first of application.id, application.name, media.name and node.name
# that it carries (formKey in src/scripts/node/state-stream.lua at 0.5.19,
# read), so an id shared by every game would give them all one volume, where
# node.name comes last and is never reached. Each joins a value already in the
# environment rather than replacing it; PIPEWIRE_PROPS's is an object, which
# two cannot be joined into, so a value already there is left alone.
game_env() {
    printf 'PULSE_PROP=%s\n' "${PULSE_PROP:+$PULSE_PROP }node.name=$GAME_TAG"
    [[ -n "${PIPEWIRE_PROPS:-}" ]] \
        || printf 'PIPEWIRE_PROPS=%s\n' "{ node.name = \"$GAME_TAG\" }"
}

# The login entry autostartOnLogin writes, at the name EasyEffects gives it
# (Autostart::fallback_enable_autostart in src/autostart.cpp): the
# application id, com.github.wwmm.easyeffects, under XDG_CONFIG_HOME/autostart.
EE_LOGIN_ENTRY="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/com.github.wwmm.easyeffects.desktop"

# easyeffectsrc read the way KConfig reads it, for the keys in EXPECTED.
#
#   list   one line per key whose value is not its default, in EXPECTED's
#          order: group, key, value as written, default, tab-separated
#   drop   the file again, less every line of the keys named in `drop`
#
# KConfig writes `key=value` and only for a value that is not the default
# (the lib's ee_rc_get), and reads more than it writes. Read in KConfig's
# master on 2026-10-17: each line is trimmed, the key is what comes before
# the first `=`, trimmed, with `[$i]`-style options after it, and a key with
# a locale, `key[de]`, is another entry (KConfigIniBackend::parseConfig in
# src/core/kconfigini.cpp); a bool is false spelled false, no, off or 0 in
# any case, and true spelled anything else (KConfigGroup::convertToQVariant
# in src/core/kconfiggroup.cpp); and of two lines for one key the later
# wins, so `list` reports that one and `drop` removes both. A group header
# that is not plain [Name] is never one of ours: a nested [A][B] reads here
# as a group named A][B, which none of ours is. Every other line is printed
# as it is, CR and all.
RC_AWK_FUNCS='
function boolean(v) {
    v = tolower(v)
    return (v == "false" || v == "no" || v == "off" || v == "0") ? "false" : "true"
}
function header(line,   g) {
    g = line
    sub(/^[ \t]+/, "", g); sub(/[ \t\r]+$/, "", g)
    if (substr(g, 1, 1) != "[") return 0
    group = (g ~ /^\[.*\]$/) ? substr(g, 2, length(g) - 2) : ""
    return 1
}
function entry(line,   s, k) {
    s = line
    sub(/^[ \t]+/, "", s)
    if (!match(s, /^[A-Za-z0-9_.-]+/)) return ""
    k = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
    while (match(s, /^\[\$[^]]*\]/)) s = substr(s, RLENGTH + 1)
    if (!match(s, /^[ \t]*=/)) return ""
    val = substr(s, RLENGTH + 1)
    sub(/^[ \t]+/, "", val); sub(/[ \t\r]+$/, "", val)
    return k
}
'
RC_AWK="$RC_AWK_FUNCS"'
BEGIN {
    rows = split(table, row, "\n")
    for (i = 1; i <= rows; i++) {
        if (split(row[i], f, " ") != 3) continue
        order[++n] = f[1] SUBSEP f[2]
        dflt[f[1] SUBSEP f[2]] = f[3]
    }
    rows = split(drop, row, "\n")
    for (i = 1; i <= rows; i++)
        if (split(row[i], f, " ") == 2) gone[f[1] SUBSEP f[2]] = 1
    group = ""
}
{
    if (header($0)) { if (mode == "drop") print; next }
    k = entry($0)
    if (k != "" && ((group SUBSEP k) in dflt)) {
        last[group SUBSEP k] = val
        if ((group SUBSEP k) in gone) next
    }
    if (mode == "drop") print
}
END {
    if (mode != "list") exit
    for (i = 1; i <= n; i++) {
        if (!(order[i] in last) || boolean(last[order[i]]) == dflt[order[i]]) continue
        split(order[i], f, SUBSEP)
        printf "%s\t%s\t%s\t%s\n", f[1], f[2], last[order[i]], dflt[order[i]]
    }
}'

rc_table() { printf '%s\n' "${EXPECTED[@]}"; }

# The last value easyeffectsrc gives a key, read with the same parsers as
# `list`; nothing, and 1, when it gives none.
RC_GET_AWK="$RC_AWK_FUNCS"'
BEGIN { group = ""; found = 0 }
{
    if (header($0)) next
    k = entry($0)
    if (k == want && group == wgroup) { last = val; found = 1 }
}
END { if (found) print last; exit !found }'

rc_get() { # rc_get <group> <key>
    [[ -f "$EE_RC" && -r "$EE_RC" ]] || return 1
    awk -v wgroup="$1" -v want="$2" "$RC_GET_AWK" "$EE_RC"
}

# easyeffectsrc with keys set, from "group<TAB>key<TAB>value" lines: every line
# of each key removed wherever it stood in its group, and one written at the
# group's end, ahead of the blank lines before the next -- or, for a group the
# file has not got, the group and its keys at the end of the file. KConfig
# reads the last line of a key, so one line is all that is left. The lines
# come in through ENVIRON, not -v: awk reads escapes in a -v value, and a
# blocklist entry of the person's with a `,` in it is written `\\,`, which -v
# made `\,` -- a different list (RUN with mawk 1.3.4; POSIX awk reads escapes
# in a -v assignment the same way).
RC_SET_AWK="$RC_AWK_FUNCS"'
function flush(g,   i) {
    if (!(g in need) || (g in done)) return
    for (i = 1; i <= n; i++) if (sg[i] == g) print sk[i] "=" sv[i]
    done[g] = 1
}
BEGIN {
    rows = split(ENVIRON["RC_SETS"], row, "\n")
    for (i = 1; i <= rows; i++) {
        if (split(row[i], f, "\t") != 3) continue
        n++; sg[n] = f[1]; sk[n] = f[2]; sv[n] = f[3]
        need[f[1]] = 1; setk[f[1] SUBSEP f[2]] = 1
    }
    group = ""
}
{
    before = group
    if ($0 ~ /^[ \t\r]*$/) { blank = blank $0 "\n"; next }
    if (header($0)) { flush(before); printf "%s", blank; blank = ""; print; next }
    k = entry($0)
    if (k != "" && ((group SUBSEP k) in setk)) next
    printf "%s", blank; blank = ""
    print
}
END {
    flush(group)
    printf "%s", blank
    for (i = 1; i <= n; i++) {
        if (sg[i] in done) continue
        if (NR > 0 || added) printf "\n"
        printf "[%s]\n", sg[i]
        flush(sg[i])
        added = 1
    }
}'

# Written beside itself and renamed over it, as rc_drop writes: through a
# symlink to the file it names, with its mode kept. A file that is not there
# yet is made, with the groups and keys alone.
rc_set() { # rc_set <"group<TAB>key<TAB>value" lines>
    local target="$EE_RC" tmp
    if [[ -L "$target" ]]; then
        target=$(realpath -m -- "$EE_RC" 2>/dev/null) || return 1
        [[ -n "$target" && ! -L "$target" ]] || return 1
    fi
    if [[ ! -e "$target" ]]; then
        mkdir -p -- "${target%/*}" 2>/dev/null && : > "$target" 2>/dev/null || return 1
    fi
    [[ -f "$target" && -r "$target" ]] || return 1
    tmp=$(mktemp "$target.XXXXXX" 2>/dev/null) || return 1
    if RC_SETS="$1" awk "$RC_SET_AWK" "$target" > "$tmp"; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$target" 2>/dev/null && return 0
    fi
    rm -f "$tmp"
    return 1
}

# The keys of WANTED the rc holds at another value, or not at all (which is
# EasyEffects' default, and so another value), as "group<TAB>key<TAB>value as
# read, or (unset)<TAB>wanted" lines. Booleans compared as KConfig reads them.
wanted_deviations() {
    local row group key want have have_b
    for row in "${WANTED[@]}"; do
        read -r group key want <<<"$row"
        if have=$(rc_get "$group" "$key"); then
            case "${have,,}" in false|no|off|0) have_b=false ;; *) have_b=true ;; esac
            [[ "$have_b" == "$want" ]] && continue
        else
            have="(unset)"
        fi
        printf '%s\t%s\t%s\t%s\n' "$group" "$key" "$have" "$want"
    done
}

# The output blocklist as KConfig keeps a string list: entries joined by `,`,
# a `,` inside one escaped as `\,`. The entries of VOICE_APPS and GAME_APPS it
# lacks, one per line, compared whole and as written -- each of ours holds no
# `,` or `\`, so an entry of the person's that spells one of ours exactly is
# ours.
blocklist_raw() { rc_get StreamOutputs blocklist || true; }
blocklist_missing() {
    local raw entry have=()
    raw=$(blocklist_raw)
    if [[ -n "$raw" ]]; then
        # Split on a `,` that no `\` escapes, by marking the escaped ones first.
        mapfile -t have < <(sed 's/\\,/\x1f/g' <<<"$raw" | tr ',' '\n' | sed 's/\x1f/\\,/g')
    fi
    # A here-string, not a pipe into grep -q: under pipefail, grep leaving at
    # its first match can fail the printf it reads, and a match read as none.
    local list
    list=$(printf '%s\n' "${have[@]}")
    for entry in "${VOICE_APPS[@]}" "${GAME_APPS[@]}"; do
        grep -qxF -- "$entry" <<<"$list" || printf '%s\n' "$entry"
    done
}
# The new value: the person's entries as they were, then the missing ones.
blocklist_with() { # blocklist_with <missing lines>
    local raw joined
    raw=$(blocklist_raw)
    joined=$(paste -sd, <<<"$1")
    if [[ -n "$raw" ]]; then printf '%s,%s' "$raw" "$joined"; else printf '%s' "$joined"; fi
}

# The keys of EXPECTED that easyeffectsrc holds at another value, as `list`
# prints them. Nothing when there is no rc: every key is then at its default.
# 1 when there is one and it is not a file that can be read -- awk warns over
# a directory and exits 0 -- which examined nothing.
rc_deviations() {
    [[ -e "$EE_RC" ]] || return 0
    [[ -f "$EE_RC" && -r "$EE_RC" ]] || return 1
    awk -v mode=list -v table="$(rc_table)" -v drop="" "$RC_AWK" "$EE_RC"
}

# easyeffectsrc without the keys named, one "group key" per line, written
# beside itself and renamed over it -- through a symlink to the file it
# names, with its mode kept, the way install.d/70-finish.sh's
# rewrite_settings writes settings.json, and for the same reasons: a
# dotfiles checkout keeps its link, and a reader never sees half a file.
# EasyEffects must not be running: it holds every setting in memory and
# writes them back when it quits (src/main.cpp, aboutToQuit -> saveAll).
rc_drop() { # rc_drop <"group key" lines>
    local target="$EE_RC" tmp
    if [[ -L "$target" ]]; then
        target=$(realpath -m -- "$EE_RC" 2>/dev/null) || return 1
        [[ -n "$target" && ! -L "$target" ]] || return 1
    fi
    [[ -f "$target" && -r "$target" ]] || return 1
    tmp=$(mktemp "$target.XXXXXX" 2>/dev/null) || return 1
    if awk -v mode=drop -v table="$(rc_table)" -v drop="$1" "$RC_AWK" "$target" > "$tmp"; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$target" 2>/dev/null && return 0
    fi
    rm -f "$tmp"
    return 1
}

# EasyEffects' own login entry, when there is one that would start it: the
# file autostartOnLogin writes, whose Exec runs easyeffects. A file at that
# name that runs something else is somebody's own, and left alone.
login_entry() {
    [[ -f "$EE_LOGIN_ENTRY" ]] || return 1
    grep -qE '^Exec=([^[:space:]]*/)?easyeffects([[:space:]]|$)' "$EE_LOGIN_ENTRY" 2>/dev/null
}

# Stopped the way a logout stops it: SIGTERM, which it answers by saving
# every setting and quitting (src/main.cpp at v8.2.9: SignalHandler, then
# aboutToQuit -> db::Manager::saveAll). This user's instance only, as
# ee_running counts it. Ten seconds to go, and never SIGKILL: killed, it
# saves nothing, and a hidden instance has saved nothing since it started --
# the presets the popup, the equaliser and the noise switch loaded into it
# over the socket would be gone at the next start (the lib's
# ee_current_preset). Signalled rather than stopped through the unit: one
# under easyeffects.service quits and exits 0, which Restart=on-failure
# leaves stopped, where `systemctl --user stop` on one that never quits
# waits out TimeoutStopSec, ninety seconds by default, and then kills it.
#
# Only once it answers. Its handler calls QCoreApplication::quit, which does
# nothing outside the event loop (`if (!...in_exec) return;` in Qt 6's
# qcoreapplication.cpp, read), and the socket listens before that loop runs
# (the lib's ee_current_preset) -- so a SIGTERM in between is lost, and the
# handler, which resets itself first, leaves the next one to kill it unsaved.
# A question is answered only from inside the loop. An instance that has not
# answered in ten seconds is signalled all the same: one before 8.0.7 never
# does, and without socat nothing can be asked.
ee_stop() {
    local i
    if ee_have_client; then
        for (( i = 0; i < 10; i++ )); do
            ee_ask get_last_loaded_preset:input && break
            sleep 0.5
        done
    fi
    pkill -TERM -u "$(id -u)" -x easyeffects >/dev/null 2>&1
    for (( i = 0; i < 20; i++ )); do
        ee_running || return 0
        sleep 0.5
    done
    ! ee_running
}

case "${1:-status}" in
    status)
        # Whether the package is installed is not a question about
        # EasyEffects, so it is answered in both branches: the doctor and the
        # popup read a machine with the package and no host the same way they
        # read one with both.
        # So is the noise filter, which is no EasyEffects preset since
        # jayos-audio 2.0.0: `plugin` and `denoise` below need nothing of
        # EasyEffects.
        engine=false
        engine_path=$(ee_denoise_engine) && engine=true
        plugin_path=$(ee_plugin_path) || plugin_path=""
        # `plugin` is whether the row can switch anything: the jayos-audio
        # package's engine AND the plugin where it looks, by its own word,
        # since the engine is what loads the plugin now. The file alone is
        # not that -- jayos-denoise 1.x and deepfilternet-ladspa, the recipe
        # this tree carried before it, left the same file with nothing here
        # to switch it -- and the popup's build button shows while `plugin`
        # is false, which is what installs the package over it. `engine` and
        # `pluginPath` keep the two halves apart, for the doctor: with no
        # engine, pluginPath is the file the lib finds, a leftover's.
        plugin=false
        # The filter's own word on itself, for the popup's Noise suppression
        # row: whether its host runs, whether its source is up and the
        # default input, and the microphone it records. Values that claim
        # nothing where there is no engine, or no answer.
        denoise='{"running":false,"loaded":false,"input":"","isDefault":false}'
        if [[ "$engine" == true ]] && command -v jq >/dev/null 2>&1; then
            if d=$("$engine_path" denoise status 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$d"; then
                [[ "$(jq -r '.plugin == true' <<<"$d")" == true ]] && plugin=true
                plugin_path=$(jq -r '.pluginPath // "" | tostring' <<<"$d")
                denoise=$(jq -c '{running: (.running == true), loaded: (.loaded == true),
                                  input: (.input // "" | tostring), isDefault: (.isDefault == true)}' <<<"$d")
            fi
        fi
        if ! ee_installed; then
            # Written without jq, which this branch never needed: the path
            # through jq where it is there, and "" where it is not.
            path_json='""'
            if command -v jq >/dev/null 2>&1; then
                path_json=$(jq -n --arg p "$plugin_path" '$p')
            fi
            printf '{"installed":false,"running":false,"bypassed":false,'
            printf '"outputPresets":[],"inputPresets":[],'
            printf '"outputPreset":"","inputPreset":"",'
            printf '"answered":{"bypassed":false,"outputPreset":false,"inputPreset":false},'
            printf '"plugin":%s,"pluginPath":%s,"engine":%s,"denoise":%s,"layout":0,"presetsRoot":""}\n' \
                "$plugin" "$path_json" "$engine" "$denoise"
            exit 0
        fi
        command -v jq >/dev/null 2>&1 \
            || { echo "easyeffects.sh: jq is not installed, so the status cannot be written" >&2; exit 1; }
        running=false
        ee_running && running=true
        preset_names output outs
        preset_names input ins
        # The daemon's three values, each with whether the daemon itself gave
        # it. A running daemon that does not answer within socat's half
        # second -- busy loading a preset, or only just listening -- is
        # reported from the rc, which is what it last SAVED (the lib's
        # ee_current_preset): right for one that has just started, stale for
        # one that is busy, and nothing here can tell the two apart. So
        # `answered` says which values are the daemon's own, and the popup
        # keeps what it last heard over an rc standing in (VolumePopup.qml,
        # applyEeStatus). With nothing running every one is the rc's.
        answered_bypassed=true answered_output=true answered_input=true
        bypassed=$(ee_value bypassed) || answered_bypassed=false
        output_preset=$(ee_value output) || answered_output=false
        input_preset=$(ee_value input) || answered_input=false
        # Every string through --arg, so jq escapes it: preset names are
        # anybody's (see json_strings), and so are the daemon's answers.
        # The plugin and the engine are for the popup's noise-suppression
        # row, and both halves apart for the doctor; the layout the lib
        # decided on, for the doctor too.
        jq -nc \
            --argjson running "$running" \
            --argjson bypassed "$bypassed" \
            --argjson outputPresets "$(json_strings "${outs[@]}")" \
            --argjson inputPresets "$(json_strings "${ins[@]}")" \
            --arg outputPreset "$output_preset" \
            --arg inputPreset "$input_preset" \
            --argjson answeredBypassed "$answered_bypassed" \
            --argjson answeredOutput "$answered_output" \
            --argjson answeredInput "$answered_input" \
            --argjson plugin "$plugin" \
            --arg pluginPath "$plugin_path" \
            --argjson engine "$engine" \
            --argjson denoise "$denoise" \
            --argjson layout "$(ee_layout)" \
            --arg presetsRoot "$(ee_presets_root)" \
            '{installed: true, running: $running, bypassed: $bypassed,
              outputPresets: $outputPresets, inputPresets: $inputPresets,
              outputPreset: $outputPreset, inputPreset: $inputPreset,
              answered: {bypassed: $answeredBypassed, outputPreset: $answeredOutput,
                         inputPreset: $answeredInput},
              plugin: $plugin, pluginPath: $pluginPath, engine: $engine,
              denoise: $denoise, layout: $layout, presetsRoot: $presetsRoot}'
        ;;

    presets)
        require_installed
        preset_names "${2:-output}" names
        (( ${#names[@]} == 0 )) || printf '%s\n' "${names[@]}"
        ;;

    load)
        require_installed
        name="${2:-}"
        only="${3:-}"
        [[ -n "$name" && ( -z "$only" || "$only" == output || "$only" == input ) ]] \
            || { echo "usage: $(basename "$0") load <name> [output|input]" >&2; exit 1; }
        # Every refusal comes before the start. This one was made only by
        # sending, after an instance had been started for it, and then
        # reported as "easyeffects did not take the load" -- EasyEffects
        # started for nothing and blamed for a rule of the socket's.
        if ! ee_preset_name_ok "$name"; then
            echo "cannot send '$name' to easyeffects: a preset name on its socket is one to a hundred bytes, with no newline" >&2
            exit 1
        fi
        # With no pipeline named: into the input pipeline if input/NAME.json
        # exists and into the output pipeline if output/NAME.json exists --
        # both, independently. That was `-l NAME`'s rule
        # (src/command_line_parser.cpp:184-199 at v8.2.9), decided on the
        # client's side, and the socket takes one pipeline per line, so the
        # rule is kept here for whoever calls this by hand.
        #
        # Named, that pipeline alone -- which is what the popup's Next
        # preset asks for. It cycles the OUTPUT presets, and under the rule
        # above any input preset sharing the name was loaded with it: the
        # microphone's `denoise` replaced, and the Noise suppression row
        # grey with "on, but input preset <name> is loaded" (RUN by the
        # audit). The socket can say which pipeline
        # (load_preset:<input|output>:NAME); the command line never could.
        #
        # Asked before anything starts: a name with no file is not worth an
        # instance.
        root=$(ee_presets_root)
        kinds=()
        for kind in input output; do
            [[ -z "$only" || "$kind" == "$only" ]] || continue
            [[ -f "$root/$kind/$name.json" ]] && kinds+=("$kind")
        done
        if (( ${#kinds[@]} == 0 )); then
            echo "no ${only:+$only }preset named '$name' under $root" >&2
            exit 1
        fi
        ee_have_client || { echo "socat is not installed, so nothing can reach easyeffects' socket" >&2; exit 1; }
        # An instance this starts gets the noise setting, spawned before the
        # wait so that nothing which stops this can lose it (the lib's
        # ee_on_start) -- unless this load fills the input
        # pipeline itself. apply -- jayos-denoise's, through denoise.sh --
        # decides by what that pipeline holds, so then it must look after
        # the load: spawned first, it could read the preset the instance
        # restored and load ours over the one asked for.
        # And once this load has landed there is a choice of somebody's in
        # the input pipeline, which apply leaves alone.
        apply=""
        if ! ee_ready; then
            if [[ "${kinds[0]}" == input ]]; then apply=after; else apply=before; fi
        fi
        if [[ "$apply" == before ]]; then ee_on_start; fi
        ee_ensure_running || { echo "easyeffects did not start" >&2; exit 1; }
        for kind in "${kinds[@]}"; do
            ee_load_preset "$kind" "$name" \
                || { echo "easyeffects did not take the load of '$name' ($kind)" >&2; exit 1; }
        done
        if [[ "$apply" == after ]]; then ee_on_start; fi
        ;;

    bypass)
        require_installed
        verb="${2:-toggle}"
        case "$verb" in
            on|off|toggle) ;;
            *) echo "usage: $(basename "$0") bypass on|off|toggle" >&2; exit 1 ;;
        esac

        # Only the live instance can be told. 7.x had a GSettings key that
        # persisted across restarts and this used to set it as well; 8.x keeps
        # the flag in its own database and writes it itself. Saying so beats
        # printing a state that nothing applied -- the popup sends `start`
        # instead when nothing is running.
        if ! ee_running; then
            echo "easyeffects is not running; nothing to bypass" >&2
            exit 1
        fi
        if [[ "$(ee_layout)" == 7 ]]; then
            # 7.x has no socket: its command line sets a GSettings key the
            # running instance watches, and hides no window. Its `-b 3`
            # reads that key on the spot rather than asking the instance, so
            # here a toggle can read and then set.
            case "$verb" in
                on)  want=true ;;
                off) want=false ;;
                toggle)
                    if [[ "$(timeout 2 easyeffects -b 3 2>/dev/null)" == 1 ]]; then
                        want=false
                    else
                        want=true
                    fi ;;
            esac
            # if/else, not `test && a || b`.
            #
            # In that form `b` runs when `a` FAILS, not only when the test
            # fails -- so an `-b 1` that returned non-zero for any reason
            # immediately ran `-b 2` and turned bypass off when you had
            # asked for it on. The toggle appeared to do nothing because it
            # did the thing and then undid it.
            if [[ "$want" == "true" ]]; then
                easyeffects -b 1 >/dev/null 2>&1 || true
            else
                easyeffects -b 2 >/dev/null 2>&1 || true
            fi
            printf '%s\n' "$want"
            exit 0
        fi
        ee_have_client || { echo "socat is not installed, so nothing can reach easyeffects' socket" >&2; exit 1; }
        # A process is not an instance that can hear: between its lock and
        # its socket it is still starting, and a request written then goes
        # nowhere. Waited for, as every other request here is -- ten
        # seconds, because this is a click in the popup, which re-polls when
        # it returns -- and refused out loud when it never listens.
        if ! ee_wait_running 10; then
            echo "easyeffects is running and not listening on its socket; nothing was sent" >&2
            exit 1
        fi
        # 0, not 2, for off: the command line's `-b 2` is its own spelling,
        # and the daemon's pattern is ^global_bypass:([01])\n$ -- a `2`
        # there is dropped without a word and bypass stays on.
        #
        # The toggle is ONE request, which the daemon applies to whatever
        # state is live (src/local_server.cpp, toggle_global_bypass). It was
        # a read and then a set, and the read fell back to the rc whenever a
        # busy daemon did not answer in time -- an rc a hidden instance does
        # not write until it quits (easyeffects-lib.sh, ee_current_preset) --
        # so the "opposite" sent was the state the daemon already had, and
        # the switch did nothing.
        case "$verb" in
            on)     ee_tell global_bypass:1 ;;
            off)    ee_tell global_bypass:0 ;;
            toggle) ee_tell toggle_global_bypass ;;
        esac || { echo "easyeffects did not take it; nothing changed" >&2; exit 1; }
        # The state it reports now, when it answers; nothing rather than a
        # guess when it does not. (The popup reads none of this: it polls.)
        if ee_ask get_global_bypass; then
            case "$EE_REPLY" in
                1) echo true ;;
                2) echo false ;;
            esac
        fi
        ;;

    open)
        require_installed

        if ee_running; then
            if [[ "$(ee_layout)" == 7 ]] && command -v gdbus >/dev/null 2>&1; then
                # The GTK-era instance is raised through GApplication's D-Bus
                # activation, not by running the binary again -- a second
                # process handed off and exited, which was the flicker of a
                # window appearing and vanishing.
                #
                # `@a{sv} {}`, not `{}`: gdbus parses its arguments as
                # GVariant text and a bare {} is ambiguous.
                gdbus call --session \
                    --dest com.github.wwmm.easyeffects \
                    --object-path /com/github/wwmm/easyeffects \
                    --method org.gtk.Application.Activate "@a{sv} {}" >/dev/null 2>&1 && exit 0
            elif [[ "$(ee_layout)" == 8 ]]; then
                # 8.x: a second `easyeffects` with no arguments finds the
                # lock held, tells the running instance over its local socket
                # to show its window, and exits. That IS the raise, so no
                # flicker this time. (easyeffects-lib.sh says how the socket
                # works; there is no D-Bus name to call.)
                #
                # Only once something listens. A process holding the lock
                # without the socket is still inside CoreServices
                # (src/main.cpp takes the lock, then CoreServices, then
                # startServer), and a second process started then cannot
                # connect: its show_window is dropped with a debug line and
                # it exits 0 (src/local_client.cpp). An instance started
                # hidden -- by the unit, or by the popup's own Start a
                # moment before -- then stayed hidden, and the button did
                # nothing. Twenty seconds, past ee_ensure_running's four
                # through the unit plus fifteen by hand, so no start it
                # would wait for is refused here.
                if ! ee_wait_running 20; then
                    echo "easyeffects is running and not listening on its socket; nothing raised its window" >&2
                    exit 1
                fi
                setsid -f easyeffects >/dev/null 2>&1
                exit 0
            else
                # 7.x without gdbus: the second process hands off through
                # GApplication, which has no socket to wait for.
                setsid -f easyeffects >/dev/null 2>&1
                exit 0
            fi
        fi

        # No instance: start one showing its window. Not hidden here, which
        # would look like the button did nothing. With the noise setting, as
        # every start here gets; nothing waits between the two, so there is
        # no moment in which this could be stopped between them.
        if ! ee_running; then
            setsid -f easyeffects >/dev/null 2>&1
            ee_on_start
            exit 0
        fi

        # Running but not reachable over D-Bus: ask the window manager, which
        # at least raises what is already there.
        if command -v hyprctl >/dev/null 2>&1; then
            hyprctl dispatch "hl.dsp.focus({ window = \"class:com.github.wwmm.easyeffects\" })" >/dev/null 2>&1 \
                || hyprctl dispatch "hl.dsp.focus({ window = \"class:easyeffects\" })" >/dev/null 2>&1
        fi
        ;;

    start)
        require_installed
        # The noise setting first, then the wait: this is the Effects switch,
        # and the popup's next click, or closing it, stops this long before
        # a slow start is done (the lib's ee_on_start).
        ee_ready || ee_on_start
        ee_ensure_running || { echo "failed to start" >&2; exit 1; }
        echo running
        ;;

    defaults)
        require_installed
        check=0
        case "${2:-}" in
            "")      ;;
            --check) check=1 ;;
            *) echo "usage: $(basename "$0") defaults [--check]" >&2; exit 1 ;;
        esac
        if ! found=$(rc_deviations); then
            echo "cannot read $EE_RC, so its settings were not examined" >&2
            exit 2
        fi
        # A running instance's bypass is asked of it, and the rc's is set
        # aside: the Effects switch flips it over the socket all session, and
        # a hidden instance saves only when it quits (the lib's
        # ee_current_preset), so its rc can say either. With no answer -- no
        # socat, a daemon too busy, one before 8.1.3 -- the rc's stands.
        live=""
        if ee_have_client && ee_ready && ee_ask get_global_bypass; then
            case "$EE_REPLY" in
                1) live=true ;;
                2) live=false ;;
            esac
        fi
        if [[ -n "$live" ]]; then
            found=$(awk -F'\t' '!($1 == "EffectsPipelines" && $2 == "bypass")' <<<"$found")
        fi

        wanted=$(wanted_deviations)
        missing=$(blocklist_missing)

        if (( check )); then
            differs=0
            while IFS=$'\t' read -r group key value default; do
                [[ -n "$group" ]] || continue
                printf "[%s] %s is %s; EasyEffects' default is %s\n" "$group" "$key" "$value" "$default"
                differs=1
            done <<<"$found"
            while IFS=$'\t' read -r group key value want; do
                [[ -n "$group" ]] || continue
                printf "[%s] %s is %s; this configuration sets %s\n" "$group" "$key" "$value" "$want"
                differs=1
            done <<<"$wanted"
            if [[ -n "$missing" ]]; then
                printf "[StreamOutputs] blocklist lacks %d voice-chat application(s) and game(s): %s\n" \
                    "$(grep -c . <<<"$missing")" "$(paste -sd' ' <<<"$missing")"
                differs=1
            fi
            if [[ "$live" == true ]]; then
                echo "[EffectsPipelines] bypass is true in the running instance; EasyEffects' default is false"
                differs=1
            fi
            if login_entry; then
                echo "EasyEffects' own login entry starts a second instance at login: $EE_LOGIN_ENTRY"
                differs=1
            fi
            exit "$differs"
        fi

        status=0
        restart=0
        # The file changes only while nothing holds it in memory. A running
        # instance is let finish starting first -- a SIGTERM that lands before
        # its event loop runs is lost, since QCoreApplication::quit does
        # nothing then -- and then stopped, and what it saves as it quits is
        # read again: that is the live state, its bypass included.
        if [[ -n "$found$wanted$missing" ]] && ee_running; then
            if ! ee_wait_running 20; then
                echo "easyeffects is running and not listening on its socket; its settings were left as they are" >&2
                exit 1
            fi
            if ! ee_stop; then
                echo "easyeffects did not stop within ten seconds; its settings were left as they are" >&2
                exit 1
            fi
            restart=1
            live=""
            wanted=$(wanted_deviations)
            missing=$(blocklist_missing)
            if ! found=$(rc_deviations); then
                echo "cannot read $EE_RC after easyeffects saved it; its settings were left as they are" >&2
                found="" wanted="" missing=""
                status=1
            elif [[ -z "$found$wanted$missing" ]]; then
                # What differed was a value the rc held and the instance no
                # longer did -- a bypass it could not be asked about, which
                # KConfig drops as it saves a default.
                echo "easyeffects saved its settings at their defaults as it quit"
            fi
        fi
        if [[ -n "$found" ]]; then
            if rc_drop "$(cut -f1,2 <<<"$found" | tr '\t' ' ')"; then
                while IFS=$'\t' read -r group key value default; do
                    printf "[%s] %s was %s; now %s, EasyEffects' default\n" "$group" "$key" "$value" "$default"
                done <<<"$found"
            else
                echo "could not rewrite $EE_RC; its settings were left as they are" >&2
                status=1
            fi
        fi
        # The three set away from EasyEffects' defaults, in one write.
        sets=""
        while IFS=$'\t' read -r group key value want; do
            [[ -n "$group" ]] && sets+="$group"$'\t'"$key"$'\t'"$want"$'\n'
        done <<<"$wanted"
        [[ -n "$missing" ]] && sets+="StreamOutputs"$'\t'"blocklist"$'\t'"$(blocklist_with "$missing")"$'\n'
        if [[ -n "$sets" ]]; then
            if rc_set "$sets"; then
                while IFS=$'\t' read -r group key value want; do
                    [[ -n "$group" ]] && printf "[%s] %s was %s; now %s, which this configuration sets\n" \
                        "$group" "$key" "$value" "$want"
                done <<<"$wanted"
                [[ -n "$missing" ]] && printf "[StreamOutputs] blocklist: added %d voice-chat application(s) and game(s), kept the rest: %s\n" \
                    "$(grep -c . <<<"$missing")" "$(paste -sd' ' <<<"$missing")"
            else
                echo "could not write $EE_RC; recordings may still go through EasyEffects" >&2
                status=1
            fi
        fi
        # The bypass alone needs no restart: the socket sets it, and the
        # instance saves it when it quits.
        if [[ "$live" == true ]]; then
            if ! ee_tell global_bypass:0; then
                echo "easyeffects did not take global_bypass:0; the bypass is still on" >&2
                status=1
            elif ee_ask get_global_bypass && [[ "$EE_REPLY" == 1 ]]; then
                echo "easyeffects took global_bypass:0 and still reports the bypass on" >&2
                status=1
            else
                echo "[EffectsPipelines] bypass was true in the running instance; now false, EasyEffects' default"
            fi
        fi
        # Removed, as EasyEffects removes it when autostartOnLogin goes off
        # (fallback_enable_autostart): the file is that setting's, and the
        # key alone does not take it away -- EasyEffects writes or removes it
        # only when the setting changes while it runs.
        if login_entry; then
            if rm -f -- "$EE_LOGIN_ENTRY"; then
                echo "removed EasyEffects' own login entry, $EE_LOGIN_ENTRY; easyeffects.service starts it"
            else
                echo "could not remove $EE_LOGIN_ENTRY" >&2
                status=1
            fi
        fi
        # Started again, with the noise setting spawned before the wait as
        # every start here is (the lib's ee_on_start), and through
        # the unit when it is installed -- so an instance that a login entry
        # had started comes back under the unit.
        if (( restart )); then
            ee_on_start
            if ee_ensure_running; then
                echo "restarted easyeffects, to read them"
            else
                echo "easyeffects did not start again; start it: systemctl --user start easyeffects.service" >&2
                status=1
            fi
        fi
        exit "$status"
        ;;

    default-devices)
        # EasyEffects processes the default output and input, and its own
        # sink and source must not be the default (its documentation and the
        # doctor's EasyEffects section): as the default, their volume and mute
        # reach nothing the shell's controls act on, and an application that
        # mutes "the default microphone" mutes no one. The doctor said so and
        # printed `pactl set-default-...` to type; reported on 2026-10-30 that
        # the install should do it. The device is what jayos-audio-state
        # names behind EasyEffects' node -- the one the shell's controls and
        # keys act on.
        #
        # WHERE IT NAMES NONE, the hardware device the session ranks first.
        # Reported on 2026-11-02 from the doctor: "the device behind it could
        # not be found", and the install changed nothing, so the input stayed
        # EasyEffects' own and every input control in the shell moved nothing.
        # Nothing names it while EasyEffects has unlinked its filters and its
        # record names no device, which is the case after it was itself made
        # the default. So the choice WirePlumber makes with nothing configured
        # is made here from pactl's list (best_device below), and this sets it.
        #
        # Never a fail of the install's: 0 where nothing needed doing or
        # everything that did was done, 1 where a default stays EasyEffects'.
        command -v pactl >/dev/null 2>&1 || { echo "pactl is not installed, so the defaults were not read" >&2; exit 1; }
        status=0
        # This package's, where it installs it, or the one beside this file
        # in a checkout's build or a suite's box; the desktop's was in its own
        # QS_BIN until the helper moved here with this script.
        helper="$HERE/jayos-audio-state"
        [[ -x "$helper" ]] || helper="${JAYOS_AUDIO_STATE:-/usr/bin/jayos-audio-state}"
        for side in sink source; do
            node="easyeffects_$side"
            what=output
            [[ "$side" == source ]] && what=input
            now=$(LC_ALL=C timeout 3 pactl "get-default-$side" 2>/dev/null)
            [[ "$now" == "$node" ]] || continue
            behind=""
            if [[ -x "$helper" ]] && command -v jq >/dev/null 2>&1; then
                behind=$(timeout 6 "$helper" master "$side" 2>/dev/null \
                         | jq -r 'select(type == "object" and (.name | type) == "string") | .name' 2>/dev/null)
            fi
            how="the device behind EasyEffects' own $side"
            if [[ -z "$behind" || "$behind" == "$node" ]]; then
                behind=$(best_device "$side")
                how="the hardware $what ranked first, since nothing named one behind EasyEffects' own $side"
            fi
            if [[ -z "$behind" ]]; then
                echo "the default $what is EasyEffects' own $side, and no device behind it, nor any hardware $what, could be named" >&2
                status=1
            elif LC_ALL=C timeout 3 pactl "set-default-$side" "$behind" 2>/dev/null; then
                echo "the default $what is $behind again, $how"
            else
                echo "the default $what is EasyEffects' own $side; pactl could not make $behind the default" >&2
                status=1
            fi
        done
        exit "$status"
        ;;

    equalizer)
        # MOVED FROM JAYOS with this script, at the same commit: the half of
        # its music/equalizer.sh that is EasyEffects' -- the build of the
        # preset from the slider state, where 8.x reads it, and its load --
        # since the builder, jayos-equalizer-preset, is this package's now.
        # The desktop keeps the sliders and their state file, and hands the
        # file here. The comments are that script's.
        state="${2:-}"
        [[ -n "$state" ]] || { echo "usage: $(basename "$0") equalizer <state-file>" >&2; exit 1; }
        eq_name=live_eq
        # Where EasyEffects reads presets from, which moved in 8.0.0. This was
        # `$HOME/.config/easyeffects/output`, the 7.x directory. 8.x reads
        # ~/.local/share/easyeffects/output and never looks in the old one,
        # so every apply wrote a preset nobody read and the `easyeffects -l`
        # reported "Specified preset does not exist" into /dev/null. The
        # sliders moved; the sound did not.
        eq_dir="$(ee_presets_root)/output"
        eq_file="$eq_dir/$eq_name.json"
        builder="$HERE/jayos-equalizer-preset"
        [[ -x "$builder" ]] || builder="${JAYOS_EQUALIZER_PRESET:-/usr/bin/jayos-equalizer-preset}"
        mkdir -p "$eq_dir"

        # The EasyEffects preset, built from the ten slider values, by a
        # binary rather than the jq program that was here: the band mapping
        # (slider n drives band 3n, the other 22 at unity) and the state
        # file's numbers-or-strings are its named tests now.
        #
        # A hard dependency, deliberately, with no `||` fallback: a fallback
        # that wrote a flat preset would silently undo every slider rather
        # than say anything.
        #
        # THE EXIT STATUS DECIDES WHETHER THIS REACHES EASYEFFECTS. The
        # binary always prints a complete, loadable preset, so a redirect
        # straight into the file followed by an unconditional load loaded
        # whatever came out -- and a state file that was not JSON at all came
        # out as 32 bands of 0.0, which reset the curve to flat with nothing
        # said. So the status is read:
        #
        #   0  every slider was read
        #   1  one slider would not parse; that band is flat and the other
        #      nine are the person's own -- load it
        #   2+ nothing was read, so every gain was invented. Also 127 when the
        #      binary is not installed, and 126 when it is not executable,
        #      both of which used to leave a zero-byte preset behind.
        #
        # The build goes to a temporary beside the file and is moved into
        # place only when it is worth loading: the file is the equaliser, and
        # overwriting it then declining to load is still a flat curve the
        # next time EasyEffects starts.
        tmp=$(mktemp "$eq_dir/.$eq_name.json.XXXXXX") || {
            echo "equalizer: cannot write in $eq_dir; the equaliser is left as it is" >&2
            exit 1
        }
        "$builder" build "$state" > "$tmp"
        status=$?
        if (( status >= 2 )); then
            rm -f "$tmp"
            echo "equalizer: no preset could be built from $state" \
                 "($builder exit $status), so the equaliser is left as it is" \
                 "rather than reset to flat." >&2
            echo "equalizer: run '$builder build $state' to see why," \
                 "or choose the Flat preset to start from a known state file." >&2
            exit 1
        fi
        mv -f "$tmp" "$eq_file"

        # Handed to the running EasyEffects -- or to one started for it. The
        # file alone does nothing: an instance restores its pipeline from its
        # own database and never reads a preset file at start, so a curve
        # left on disk "for the next start" is never heard. 8.x: over the
        # socket, now when an instance can hear, otherwise after starting one
        # the way everything here does, and in the background, since that can
        # take seconds and the desktop's caller is gone when this exits --
        # with the caller's start hook first, as every start here has it.
        # 7.x has no socket: its command line hands the load to a running
        # instance through GApplication, and to a running one only.
        if ! ee_installed; then
            echo "equalizer: easyeffects is not installed, so nothing loads $eq_file" >&2
            exit 0
        fi
        if [[ "$(ee_layout)" == 7 ]]; then
            if ee_running; then easyeffects -l "$eq_name" >/dev/null 2>&1 & fi
            exit 0
        fi
        if ! ee_have_client; then
            echo "equalizer: socat is not installed, so nothing can reach easyeffects' socket" >&2
            exit 1
        fi
        if ee_ready; then
            ee_load_preset output "$eq_name" \
                || echo "equalizer: easyeffects did not take the load of $eq_name" >&2
        else
            ee_on_start
            ( ee_ensure_running && ee_load_preset output "$eq_name" ) >/dev/null 2>&1 &
        fi
        exit 0
        ;;

    best-device)
        # The device default-devices falls back to, for the doctor: where
        # there is none -- a desktop with no microphone, or headphones in a
        # profile that carries none -- EasyEffects' own source is the only
        # input there is, and a default nothing can replace is no fault to
        # report (reported on 2026-11-03).
        [[ "${2:-}" == sink || "${2:-}" == source ]] || { echo "usage: $(basename "$0") best-device sink|source" >&2; exit 2; }
        command -v pactl >/dev/null 2>&1 || { echo "pactl is not installed" >&2; exit 2; }
        command -v jq >/dev/null 2>&1 || { echo "jq is not installed" >&2; exit 2; }
        best=$(best_device "$2")
        [[ -n "$best" ]] || exit 1
        printf '%s\n' "$best"
        exit 0
        ;;

    game-env)
        # Whether or not EasyEffects is installed: a launcher started before
        # it was still tags what it plays, and the tag changes nothing else.
        game_env
        exit 0
        ;;

    *)
        echo "usage: $(basename "$0") status|presets|load|bypass|open|start|defaults|default-devices|equalizer|best-device|game-env" >&2
        exit 1
        ;;
esac
