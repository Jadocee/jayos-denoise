#!/usr/bin/env bash
#
# EasyEffects, as this configuration finds it on disk and on its socket.
#
# Sourced by jayos-denoise, from its own directory, and sets no shell
# options: the caller's `set -u` and pipefail stay the caller's.
#
# A COPY. This is JayOS's config/common/scripts/easyeffects-lib.sh at jayos
# commit bf53d6a, where hypr/easyeffects.sh, music/equalizer.sh and the
# noise-suppression script that became jayos-denoise all sourced it. JayOS
# keeps its own for the first two, so there are two copies, and a fix to one
# is a fix to one: diff against that commit to carry a change across.
#
# Not a dependency on JayOS, which would make this package need the desktop it
# was moved out of -- the coupling the move exists to remove. Whole, not
# trimmed, so the reasons travel with the code; the comments below are JayOS's,
# and the paths in them are JayOS's at that commit (hypr/denoise.sh is what
# became jayos-denoise). Two edits:
#
#   - this paragraph and the one above it replace the original's sentence
#     naming its three sourcers;
#   - ee_apply_noise_setting is gone from the end. It spawned JayOS's
#     hypr/denoise.sh by a path relative to the library, which does not exist
#     here; the shell that starts EasyEffects is what has to call `apply`.
#
# WHY THIS EXISTS
#
# EasyEffects 8.0.0 moved. Presets, impulse responses and autoload profiles
# went from ~/.config/easyeffects to ~/.local/share/easyeffects, and the
# settings went from GSettings (com.github.wwmm.easyeffects) to KConfig files
# under ~/.config/easyeffects/db/. Three scripts here had the 7.x layout
# written into them separately, and each looked like it worked: the popup
# listed presets from a directory 8.x no longer reads, the equaliser wrote a
# preset 8.x never loaded, and the current preset came from a GSettings schema
# that is no longer installed -- so it was always "".
#
# One place that knows where things are, for all of them.
#
# HOW THE 8.x DAEMON IS SPOKEN TO, WHICH EVERYTHING BELOW RESTS ON
#
# There is no D-Bus service and no bus name. The first instance takes a lock
# file, $XDG_RUNTIME_DIR/easyeffects.lock, and -- only after its PipeWire
# connection and every plugin are up (src/main.cpp: CoreServices, then
# startServer) -- listens on a local socket, $XDG_RUNTIME_DIR/EasyEffectsServer,
# which takes one request per line (src/local_server.cpp at v8.2.9):
#
#   load_preset:<input|output>:NAME   global_bypass:<0|1>   toggle_global_bypass
#   get_last_loaded_preset:<input|output>   answered with NAME and a newline
#   get_global_bypass                       answered "1" (bypassed) or "2", bare
#   show_window   hide_window
#
# THESE LINES ARE WRITTEN HERE, THROUGH socat, NOT THROUGH `easyeffects`.
#
# The command line is a second `easyeffects` that finds the lock held and
# writes those same lines -- and then one more. At v8.2.9 `-l` and every
# `-b` also send hide_window (src/command_line_parser.cpp:201 and :229), so
# the poll behind the volume popup, which asked `-b 3` on every open, closed
# an EasyEffects window somebody had open; so did every preset load, every
# noise-suppression toggle and the equaliser, and the popup's own Open
# button raised a window its re-poll hid a moment later. Upstream took the
# hide out of `-b` after 8.2.9 (3b88265, unreleased) and kept it in `-l`
# (master's command_line_parser.cpp:209). READ from upstream's source: there
# is no EasyEffects here to run. A client of our own sends exactly the line
# that was meant and nothing else, and needs no display, where the command
# line is a whole Qt application that did.
#
# socat, because it is already a core dependency
# (pkgbuilds/quickshell-shell-core) and upstream documents this socket for
# exactly this use, with socat (src/contents/docs/user_interface/
# local_server.md at v8.2.9). Two things about it make it a good client:
#
#   - It exits 1 when nothing accepts the connection, so "delivered to a
#     daemon that is listening" is knowable. The command line exits 0
#     WHATEVER HAPPENED: a line for a socket nobody listens on is dropped
#     without a word.
#   - Having written its line it half-closes, and the daemon, which replies
#     from inside the same read (src/local_server.cpp: socket->write, then
#     flush), takes the end of the stream as the end of the conversation and
#     closes -- so an answer comes back in milliseconds, and -t 0.5 bounds a
#     daemon too busy to reply at the half second upstream's own client waits
#     (src/local_client.cpp: waitForReadyRead(500)). RUN against a
#     QLocalServer built with Qt 6.4 and upstream's handler: answers in 7 ms,
#     a load written while the event loop was not yet running was acted on
#     when it did, and a daemon blocked for 700 ms left the ask empty at 0.5 s.
#
# Not every 8.x speaks all of it. Read at each tag, src/tags_local_server.hpp
# and the patterns in src/local_server.cpp: show_window, hide_window and
# load_preset are there from 8.0.0, global_bypass from 8.0.1,
# get_last_loaded_preset from 8.0.7 -- which is also when load_preset took
# input|output for the pipeline; 8.0.0 to 8.0.6 wanted a number there -- and
# get_global_bypass and toggle_global_bypass from 8.1.3. A line an instance
# does not know, or whose pattern it does not match, is dropped without a
# word. So before 8.1.3 a question about the bypass reads here as no answer
# and the rc answers instead, and the popup's bypass switch does nothing;
# before 8.0.7 a load reaches the daemon and changes nothing, which denoise.sh
# catches by asking what is held and easyeffects.sh's `load` cannot.
#
# Readiness here is a socket something listens on. A load is believed only by
# a caller that asks afterwards what is held, which is denoise.sh:
# easyeffects.sh's `load` leaves that to the popup's next status poll, and
# music/equalizer.sh asks nobody (docs/AUDIO.md).

EE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/easyeffects"
EE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/easyeffects"
EE_RC="$EE_CONF/db/easyeffectsrc"
EE_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/EasyEffectsServer"
EE_PLUGIN_SO="libdeep_filter_ladspa.so"

ee_installed()    { command -v easyeffects >/dev/null 2>&1; }
# THIS user's instance. The lock and the socket both live in this user's
# XDG_RUNTIME_DIR (upstream's util::get_lock_file and LocalServer use
# RuntimeLocation), so another user's EasyEffects on the same machine -- a
# second seat, a session switched away from -- is nothing this user can speak
# to. Counted, it made status say running, stopped ee_ensure_running starting
# this user's own, and sent `bypass` at a socket that was never there.
# The Sony daemon is counted with the same -u, for the same reason: by
# jayos-sony-xm5's process script, which hypr/sony-daemon.sh asks, and by
# hypr/sony-daemon.sh itself when it stops the qs-sonyd an older install.sh
# built.
ee_running()      { pgrep -u "$(id -u)" -x easyeffects >/dev/null 2>&1; }
# The client every request below goes through (see the top of this file).
ee_have_client()  { command -v socat >/dev/null 2>&1; }

# Ready to be spoken to: a process AND a socket something listens on.
#
# Both, because either alone lies. The socket is opened last, so a process
# without it is still starting. And a socket FILE is not a listener: a crash
# leaves the file behind, upstream removes it only in startServer at the very
# end of the next start (src/local_server.cpp removeServer; src/main.cpp,
# startServer after CoreServices), and the unit brings the process back
# three seconds after a crash (easyeffects.service RestartSec=3). So for the
# seconds a restart takes there is a process and a socket file and nothing
# listening, and `-S` called that ready: every wait below returned at once,
# denoise.sh spent its three tries on a dead socket and failed `set on`, and
# the popup's preset button sent its load into it.
#
# The test is the one that matters -- would a connection be accepted -- made
# with the client every request uses. The lock is no help (the audit's first
# fix compared the socket's age with it): the new process takes it only at
# src/main.cpp:407, so until then the dead instance's files still agree.
# Without socat nothing can be said anyway, and the file is all there is.
ee_listening() {
    [[ -S "$EE_SOCKET" ]] || return 1
    ee_have_client || return 0
    timeout 2 socat -u OPEN:/dev/null "UNIX-CONNECT:$EE_SOCKET,connect-timeout=1" >/dev/null 2>&1
}
ee_ready() { ee_running && ee_listening; }

# 8 or 7, from the files rather than from `easyeffects --version`.
#
# The poller behind the volume popup runs on every open, and a Qt application
# asked for its version string still builds a QApplication -- so it needs a
# display -- and tries the single-instance lock before it prints anything.
# The directories say the same thing for free: 8.x keeps its KConfig under
# db/ and its presets under XDG_DATA_HOME, and 7.x had neither. A fresh 8.x
# that has never run has neither directory, and Arch has shipped 8.x since
# 2025-11 -- so nothing on disk means 8.
ee_layout() {
    if [[ -d "$EE_DATA" || -d "$EE_CONF/db" ]]; then
        echo 8
    elif [[ -d "$EE_CONF/output" || -d "$EE_CONF/input" ]]; then
        echo 7
    else
        echo 8
    fi
}

# The directory holding input/ and output/.
ee_presets_root() {
    if [[ "$(ee_layout)" == 8 ]]; then
        printf '%s' "$EE_DATA"
    else
        printf '%s' "$EE_CONF"
    fi
}

# One key out of one [Group] of easyeffectsrc.
#
# KConfig writes a key only when its value differs from the compiled-in
# default, so an absent key means the default -- "" for the preset names,
# false for bypass -- and this prints nothing rather than guessing.
ee_rc_get() { # ee_rc_get <group> <key>
    [[ -f "$EE_RC" ]] || return 0
    awk -v g="[$1]" -v k="$2" '
        $0 == g { in_g = 1; next }
        /^\[/   { in_g = 0 }
        in_g && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
    ' "$EE_RC"
}

# One request to the daemon: the line out, whatever came back on stdout.
#
# 1 when nothing accepted the connection -- no socket file, a file nobody
# listens on, or a daemon whose queue is full: connect-timeout turns the
# kernel's wait for room into an immediate refusal, and a daemon that cannot
# take a connection cannot be spoken to either. `timeout` bounds the rest.
# A line with a newline in it would be two requests, so it is refused; the
# preset name in a load is the one part of any line that is not ours. The
# path goes into socat's address syntax, where `,` and `:` separate options;
# XDG_RUNTIME_DIR is /run/user/<uid>, which holds neither.
ee_socket() { # ee_socket <line>
    [[ "$1" != *$'\n'* ]] || return 1
    printf '%s\n' "$1" \
        | timeout 2 socat -t 0.5 - "UNIX-CONNECT:$EE_SOCKET,connect-timeout=1" 2>/dev/null
}

# A request that expects no reply: 0 when a listening daemon took it.
ee_tell() { # ee_tell <line>
    ee_socket "$1" >/dev/null
}

# A question. The reply's bytes land in EE_REPLY -- a variable rather than
# stdout, because $(...) would eat the newline that is the whole of an
# answer naming nothing -- and the status says whether any came back.
EE_REPLY=""
ee_ask() { # ee_ask <line>
    local raw
    raw=$(ee_socket "$1"; printf x)
    EE_REPLY=${raw%x}
    [[ -n "$EE_REPLY" ]]
}

# Whether a load can carry this name at all. It must match the daemon's own
# pattern, ^load_preset:(input|output):([^\n]{1,100})\n$
# (src/local_server.cpp), or the line is dropped there without a word: one to
# a hundred BYTES, which LC_ALL=C makes ${#} count, and no newline, which
# would make the line two requests. A question of its own so that a caller
# can refuse a name before it starts an instance to send it to --
# easyeffects.sh's `load` asked only by sending, after the start, and so
# started EasyEffects in order to refuse and then blamed it.
ee_preset_name_ok() { # ee_preset_name_ok <name>
    local LC_ALL=C
    [[ -n "$1" && ${#1} -le 100 && "$1" != *$'\n'* ]]
}

# Load one preset into one pipeline: 0 when the line reached a daemon that
# was listening, which is all a write can know -- denoise.sh asks afterwards
# what is held. The name is refused here as well as by any caller that asked
# first: this is the last place it can be.
ee_load_preset() { # ee_load_preset <input|output> <name>
    [[ "$1" == input || "$1" == output ]] || return 1
    ee_preset_name_ok "$2" || return 1
    ee_tell "load_preset:$1:$2"
}

# Ask the daemon what one pipeline holds. Prints the name -- possibly nothing
# -- and returns 0 when the daemon ANSWERED; returns 1 when nothing could be
# asked or nothing answered, which the caller must not read as "nothing loaded".
#
# The reply is the name and ONE newline, so an answer naming nothing is a
# lone newline and still an answer; no bytes at all is a question nobody
# answered -- nothing listening, or a daemon too busy to reply in time.
# (The command line printed "None" for nothing, but only when it was the
# primary with no daemon at all; the daemon itself never says it, so a
# preset called None is a preset called None.)
ee_ask_preset() { # ee_ask_preset <input|output>
    ee_running && [[ -S "$EE_SOCKET" ]] || return 1
    ee_ask "get_last_loaded_preset:$1" || return 1
    printf '%s' "${EE_REPLY%$'\n'}"
}

# The preset loaded in one pipeline: the daemon's answer when there is one,
# the rc file otherwise.
#
# An answer is trusted even when it names nothing, because the rc is not the
# daemon's state: it is what was last SAVED. Its autosave timer runs only
# while its window is open (databaseAutosaveInterval in easyeffects_db.kcfg,
# "active only when our window is opened"; contents/ui/Main.qml turns it on
# when the window shows), and it saves everything when the window hides or
# closes (Main.qml's onVisibleChanged and onCloseWindow) and when it quits
# (src/main.cpp:454). easyeffects.service starts it hidden, so after a load
# or a bypass over the socket the rc holds what was true at the last quit,
# for the rest of the session -- not "an autosave interval" behind, as this
# said.
#
# No answer still falls back to the rc, because the common reason for none
# is a daemon that has just started: its socket listens before its event
# loop runs (src/main.cpp:448 against :469), and what it restored its
# pipeline from is that very file. Mid-session, a daemon too busy to answer
# in half a second makes this the last saved state until the next poll --
# which is why nothing here ACTS on the fallback where acting on a stale
# answer would be wrong: `easyeffects.sh bypass toggle` sends the toggle
# itself instead of the opposite of what it read.
ee_current_preset() { # ee_current_preset <input|output>
    ee_value "$1"
    return 0
}

# The GLOBAL bypass, which is both pipelines at once. Nothing about the
# microphone alone lives here; that is a flag inside the input preset.
#
# get_global_bypass is answered "1" for bypassed and "2" for not, with no
# newline (src/local_server.cpp). No answer -- or a 7.x instance, which has
# no socket -- falls to the rc.
ee_bypassed() {
    ee_value bypassed
    return 0
}

# What each of the two above prints, with where it came from kept: 0 when
# the daemon itself answered, 1 when the rc's value stands in. status
# reports which, value by value (easyeffects.sh), because the rc can be as
# stale as ee_current_preset says: the volume popup keeps what it last heard
# the daemon say over an rc standing in for a moment it was too busy to
# answer (VolumePopup.qml, applyEeStatus).
ee_value() { # ee_value <input|output|bypassed>
    local out
    case "$1" in
        bypassed)
            if ee_running && [[ -S "$EE_SOCKET" ]] && ee_ask get_global_bypass; then
                case "$EE_REPLY" in
                    1) echo true;  return 0 ;;
                    2) echo false; return 0 ;;
                esac
            fi
            case "$(ee_rc_get EffectsPipelines bypass)" in
                true) echo true ;;
                *)    echo false ;;
            esac
            ;;
        input|output)
            if [[ "$(ee_layout)" == 8 ]] && out=$(ee_ask_preset "$1"); then
                printf '%s' "$out"
                return 0
            fi
            case "$1" in
                input)  ee_rc_get Presets lastLoadedInputPreset ;;
                output) ee_rc_get Presets lastLoadedOutputPreset ;;
            esac
            ;;
    esac
    return 1
}

# Where the DeepFilterNet plugin is, if anywhere.
#
# The same search EasyEffects does (src/ladspa_wrapper.cpp): $LADSPA_PATH when
# it is set, its built-in list otherwise. Printed, so the doctor can name the
# file; 1 when there is none.
ee_plugin_path() {
    local dirs="${LADSPA_PATH:-}" d
    [[ -n "$dirs" ]] || dirs="/usr/local/lib/ladspa:/usr/lib/ladspa:/usr/lib64/ladspa"
    local -a list
    IFS=: read -ra list <<<"$dirs"
    for d in "${list[@]}"; do
        [[ -n "$d" && -f "$d/$EE_PLUGIN_SO" ]] || continue
        printf '%s' "$d/$EE_PLUGIN_SO"
        return 0
    done
    return 1
}

# Wait for an instance somebody else is starting to become READY -- a socket
# something listens on, not the process and not a socket file (see ee_ready).
# Never starts one: at login easyeffects.service does, and a second start
# would race it for the lock.
ee_wait_running() { # ee_wait_running <seconds>
    local ticks=$(( ${1:-10} * 2 )) i
    for (( i = 0; i < ticks; i++ )); do
        ee_ready && return 0
        sleep 0.5
    done
    ee_ready
}

# Start an instance without a window and wait until it can be spoken to.
#
# Through our unit when it is installed, so systemd owns the process the way
# it does after a login; by hand otherwise. --hide-window --service-mode is
# the 8.x spelling; --gapplication-service still works and is deprecated.
# The unit has a ConditionEnvironment on WAYLAND_DISPLAY, and `start` on a
# unit whose condition fails returns 0 and starts nothing -- so a start that
# produced no listener within a few seconds falls through to the by-hand path.
ee_ensure_running() {
    ee_ready && return 0
    ee_installed || return 1
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user cat easyeffects.service >/dev/null 2>&1; then
        systemctl --user start easyeffects.service >/dev/null 2>&1 || true
        ee_wait_running 4 && return 0
    fi
    # Not when a process already exists and is merely still starting: a second
    # start would lose the lock and exit, and the wait below covers it.
    ee_running || setsid -f easyeffects --hide-window --service-mode >/dev/null 2>&1
    ee_wait_running 15
}
