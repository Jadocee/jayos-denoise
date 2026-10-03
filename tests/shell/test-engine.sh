#!/usr/bin/env bash
#
# The engine, src/jayos-denoise, against a fake EasyEffects 8.2.9.
#
#   tests/shell/test-engine.sh
#
# Exit 0: every case that ran passed. 1: a case failed. 2: could not run --
# no jq, no python3 (it plays the daemon's end of the socket), no socat (the
# engine reaches the daemon through it), or no AF_UNIX socket could be bound
# either in the scratch directory or in a short one under /tmp -- which is
# not the same answer as "nothing is wrong" and must not be reported as one. One case depends on the machine
# rather than on a tool: the remedy printed when LADSPA_PATH is unset is
# asked only where none of EasyEffects' own LADSPA directories holds the
# plugin, and elsewhere it is a counted skip, named in the tally, that leaves
# the status alone -- a machine that has the plugin installed is not a
# machine with findings, and a run that asked everything else has not
# examined nothing.
#
# WHAT THIS PROVES
#
# Where the engine writes its preset and what is in it; which lines it sends
# the daemon, in what order, and whether anybody was listening when it sent
# them; that it never touches the global bypass or the window; that `apply`
# never starts an instance and never loads over a preset somebody chose
# unless forced; that a load is believed only once the daemon says it holds
# ours; that `status` is JSON with exactly the keys contract/status-keys.txt
# names, whatever bytes the daemon's answers hold; that `strengths` is the
# case arms of strength_params() and contract/strengths.txt; that a
# settings.json where jayos keeps one changes nothing; that it finds its
# library when it is run through the /usr/bin symlink the package installs,
# and refuses to run without one. Every one of those is
# asserted from what the fakes recorded, not from an exit status: the
# failures this suite exists for are scripts that run, exit 0 and do nothing.
#
# WHAT IT DOES NOT PROVE, because it needs a machine: that EasyEffects loads
# the preset, that the daemon's bytes are the shape the fake writes (READ
# from upstream's src/local_server.cpp at v8.2.9, and run once against a
# QLocalServer carrying upstream's handler -- evidence from jayos, not
# repeated here), or that the plugin filters anything. Nor the package:
# packaging/steps.sh's `check` proves a built plugin, inside a package build.
# Nor jayos's side -- the wrapper that owns micDenoise and micDenoiseStrength
# and hands this engine explicit arguments is jayos's
# tools/test-easyeffects.sh's, against a vendored copy of this engine.
#
# WHERE THIS CAME FROM
#
# Moved from jayos's tools/test-easyeffects.sh at jayos commit bf53d6a: the
# cases that drove hypr/denoise.sh alone (the A class of that suite --
# its lines 836-847, 1307-1318, the denoise.sh passes of 1324-1360, and
# 1456-1720, 1740-1747, 1801-2001, 2139-2165, 2178-2188), the strength-table
# comparison at 3316-3343, and the infrastructure under them (1-753). The
# fakes are that suite's, copied verbatim so a fix to one can be carried to
# the other by diff, with two exceptions said where they are: gdbus, hyprctl
# and uwsm also write to a log no case clears, and term-recorder and the
# equaliser's preset builder are gone, since nothing here opens a terminal
# or builds an equaliser. Some of their switches no case here sets --
# kill_caller (the popup stopping its own action), v7 (EasyEffects 7.x's
# command line) and the global bypass the daemon keeps -- and they stay,
# because removing them would make the two copies differ for nothing.
#
# What changed in the moved cases is what the move changed in the engine.
# Where a case wrote settings.json (micDenoise, micDenoiseStrength) and ran
# `denoise.sh apply`, it now runs `jayos-denoise apply on|off <strength>`;
# `set` with no strength now means balanced, not the saved strength; status
# has ten keys, without enabled and strength; messages begin
# "jayos-denoise:"; and with no plugin the engine names its own package's
# remedy instead of jayos's build arm. Each adapted case says so.
#
# NEW HERE, marked "New here" where they are: the verbs and their usage
# (an unknown verb, no verb, `strengths`, `preset` and `set` with nothing
# to act on), `apply`'s arguments (--force before or after the strength, an
# unknown strength replaced by balanced for on and for off, a missing
# state), that a settings.json beside the engine is not read, the status
# key list against the contract, the engine run through a symlink in another
# directory and the engine with no library beside it, the source guards
# applied to the library's copy as well, another user's instance, a daemon
# that hears and does not answer, a daemon that cannot take a connection, a
# 7.x tree, the remedy without LADSPA_PATH, and a whole-run check that
# nothing was detached and no session tool was called.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-denoise"
LIB="$ROOT/src/easyeffects-lib.sh"
CONTRACT="$ROOT/contract"
DOC="$ROOT/docs/DEEPFILTERNET.md"

# Exit 2 only for what this suite needs in order to ask anything. The doc is
# not one of those: it is a thing the tree ships, and its absence is a
# failure below (the table case), not "not exercised".
for f in "$ENGINE" "$LIB"; do
    [[ -r "$f" ]] || { echo "  engine not exercised: cannot read $f" >&2; exit 2; }
done

# 2, not 1: "not exercised" is a different answer from "found problems".
command -v jq >/dev/null 2>&1 || {
    echo "  engine not exercised: jq is not installed"
    exit 2
}
PYTHON=$(command -v python3) || {
    echo "  engine not exercised: python3 is not installed (it plays the daemon's end of the socket)"
    exit 2
}
SOCAT=$(command -v socat) || {
    echo "  engine not exercised: socat is not installed (the engine reaches the daemon through it)"
    exit 2
}
# Before any fake is on PATH: the fake sleep returns at once, and the few
# waits that must really wait -- for a fake daemon to die -- need this one.
REAL_SLEEP=$(command -v sleep)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-denoise-test-engine.XXXXXX")"
SHORT=""
# The fake daemon is a background process: stopped before the directory it
# writes into is removed, and it exits by itself if this shell dies first.
trap '"$WORK/fakes/daemon-stop" 2>/dev/null; rm -rf "$WORK" ${SHORT:+"$SHORT"}' EXIT

# A listener must be possible where the sandbox puts the socket, or every
# readiness case below would be testing python3.
#
# AF_UNIX paths are short -- 108 bytes on Linux, the terminating NUL
# included -- and a TMPDIR deep enough leaves no room for
# .../run/EasyEffectsServer: jayos's suite, run with its TMPDIR in an agent's
# scratch directory, answered "not exercised" for exactly that. So the run
# directory alone moves to a short one of its own under /tmp when it must,
# and only when that cannot bind either is this a machine that cannot run
# the suite.
can_bind() { # can_bind <path>
    "$PYTHON" -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1" 2>/dev/null \
        && rm -f "$1"
}
RUN_DIR="$WORK/run"
SOCKET="$RUN_DIR/EasyEffectsServer"
mkdir -p "$RUN_DIR"
if ! can_bind "$SOCKET"; then
    SHORT=$(mktemp -d /tmp/jdn.XXXXXX) || SHORT=""
    if [[ -n "$SHORT" ]]; then
        RUN_DIR="$SHORT/run"
        SOCKET="$RUN_DIR/EasyEffectsServer"
        mkdir -p "$RUN_DIR"
    fi
    can_bind "$SOCKET" || {
        echo "  engine not exercised: could not bind a socket at $SOCKET"
        exit 2
    }
fi

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mfail\033[0m %s\n' "$1"; }
# A case that could not run is neither: counted, and said in the tally, so a
# run that dropped one does not end on the line a full run prints.
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

# What the fakes were asked, in order; what was asked with nobody listening;
# how many times something looked for the process.
calls()     { cat "$WORK/calls.log" 2>/dev/null; }
unheard()   { cat "$WORK/unheard.log" 2>/dev/null; }
ticks()     { cat "$WORK/ticks" 2>/dev/null || echo 0; }
log_has()   { says "$1" "$2" "$(calls)"; }
log_lacks() { says_not "$1" "$2" "$(calls)"; }
line_of()   { calls | grep -nF -- "$1" | head -1 | cut -d: -f1; }
before() { # before <what> <earlier line> <later line>
    local a b
    a=$(line_of "$2"); b=$(line_of "$3")
    if [[ -n "$a" && -n "$b" ]] && (( a < b )); then
        pass "$1"
    else
        bad "$1 ('$2' at line ${a:-none}, '$3' at line ${b:-none})"
    fi
}
# A hide_window the daemon heard is the window somebody had open, closed.
no_hide() { # no_hide <what>
    log_lacks "$1" "heard hide_window"
}
# Every start of an instance, by the unit or by hand.
started() { calls | grep -E '^(setsid -f easyeffects|systemctl --user start)' || true; }

# ── path_without ─────────────────────────────────────────────────────────────
#
# jayos's tools/lib/absent.sh at bf53d6a, the function alone; its header there
# says why absence is a PATH with everything but the named tool, and not a
# short hand-written PATH: on the machine this package is FOR, /usr/bin is
# where the tool lives, so omitting it from a list hides nothing. Copied, not
# sourced, because this repository must run without jayos beside it.
path_without() { # path_without <dir> <tool>...
    local dir="${1:-}"; shift 2>/dev/null || true
    # A call naming no tool would hide nothing and still succeed.
    if (( $# == 0 )); then
        echo "path_without: no tool named, so this would hide nothing" >&2
        return 1
    fi
    # The next line is rm -rf.
    if [[ "$dir" != /* ]]; then
        echo "path_without: <dir> must be absolute, got '$dir'" >&2
        return 1
    fi
    rm -rf "$dir"
    mkdir -p "$dir" || return 1
    local d f base
    local IFS=:
    for d in $PATH; do
        [[ -n "$d" && -d "$d" ]] || continue
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
    # An empty farm would be testing the absence of everything.
    [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]
}

# ── the sandbox ──────────────────────────────────────────────────────────────
FAKE_HOME="$WORK/home"
CONF="$FAKE_HOME/.config/easyeffects"
DATA="$FAKE_HOME/.local/share/easyeffects"
# Where jayos keeps settings.json, so that a case can put one there and show
# the engine does not read it.
SHELL_DIR="$WORK/shell"
FILE="$DATA/input/denoise.json"

# ── the fakes ────────────────────────────────────────────────────────────────
#
# Copied from jayos's tools/test-easyeffects.sh at bf53d6a (its lines
# 284-627); the header of that suite describes each one at length, and the
# comments that travelled with them say what matters here.
FAKES="$WORK/fakes"
mkdir -p "$FAKES" "$RUN_DIR" "$WORK/detached"

# $WORK and the sandbox paths are expanded into each fake at creation, because
# the fakes run inside the scripts under test with an environment this suite
# does not control.

# The daemon's end of the socket. Forks once it is listening, so whoever
# started it goes on only when a connection would be accepted; the child
# detaches from every stream of its caller, since a $(...) round a script
# that started it would otherwise wait for it to exit.
cat > "$FAKES/ee-daemon.py" <<'FAKE'
import os, re, socket, sys, time

work, sock_path, data, suite_pid = sys.argv[1:5]

def at(name):
    return os.path.join(work, name)

def has(name):
    return os.path.exists(at(name))

def read(name):
    try:
        with open(at(name), 'rb') as fh:
            return fh.read()
    except OSError:
        return b''

def touch(name):
    open(at(name), 'wb').close()

def drop(name):
    try:
        os.unlink(at(name))
    except OSError:
        pass

def log(text):
    with open(at('calls.log'), 'ab') as fh:
        fh.write(text + b'\n')

# src/local_server.cpp at v8.2.9: the same tags, the same patterns, the same
# replies -- a bare "1"/"2" for the bypass, the name and one newline for a
# preset -- and nothing at all for a line it does not match.
def respond(conn, line):
    log(b'heard ' + line)
    quiet = has('no_answer') and line.startswith(read('no_answer'))
    if line == b'get_global_bypass':
        if not quiet:
            conn.sendall(b'1' if has('bypassed') else b'2')
        return
    m = re.fullmatch(rb'get_last_loaded_preset:(input|output)', line)
    if m:
        if not quiet:
            conn.sendall(read('fake_current' if m[1] == b'input' else 'fake_current_output') + b'\n')
        return
    m = re.fullmatch(rb'load_preset:(input|output):([^\n]{1,100})', line)
    if m:
        preset = os.path.join(data.encode(), m[1], m[2] + b'.json')
        if not has('ignore_loads') and os.path.isfile(preset):
            with open(at('fake_current' if m[1] == b'input' else 'fake_current_output'), 'wb') as fh:
                fh.write(m[2])
        return
    m = re.fullmatch(rb'global_bypass:([01])', line)
    if m:
        touch('bypassed') if m[1] == b'1' else drop('bypassed')
        return
    if line.startswith(b'toggle_global_bypass'):
        drop('bypassed') if has('bypassed') else touch('bypassed')
        return
    if line == b'show_window':
        touch('window')
    elif line == b'hide_window':
        drop('window')

def alive():
    try:
        os.kill(int(suite_pid), 0)
    except OSError:
        return False
    return os.path.isdir(work)

try:
    os.unlink(sock_path)
except OSError:
    pass
server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen(50)
child = os.fork()
if child:
    with open(at('daemon.pid'), 'w') as fh:
        fh.write(str(child))
    os._exit(0)
os.setsid()
null = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
server.settimeout(0.5)

# One connection at a time, lines answered as they arrive, closed when the
# client half-closes -- the daemon's one event loop, and what the real
# QLocalSocket does at the end of the stream.
while alive():
    try:
        conn, _ = server.accept()
    except socket.timeout:
        continue
    conn.settimeout(5)
    pending = b''
    try:
        while True:
            chunk = conn.recv(1024)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                respond(conn, line)
    except OSError:
        pass
    conn.close()
FAKE

cat > "$FAKES/instance-up" <<FAKE
#!/usr/bin/env bash
: > "$WORK/running"
"$FAKES/daemon-stop"
exec "$PYTHON" "$FAKES/ee-daemon.py" "$WORK" "$SOCKET" "$DATA" "$$"
FAKE

# Stopping the daemon leaves its socket file behind, as a crash does; the
# helpers below that mean "no socket" remove it themselves. Dead means gone
# or a zombie: the daemon's parent is whatever reaps orphans here, and it may
# take seconds to, while the listener closed the moment the process died.
cat > "$FAKES/daemon-stop" <<FAKE
#!/usr/bin/env bash
[[ -f "$WORK/daemon.pid" ]] || exit 0
pid=\$(cat "$WORK/daemon.pid"); rm -f "$WORK/daemon.pid"
kill "\$pid" 2>/dev/null || exit 0
alive() { local st; read -r _ _ st _ < "/proc/\$pid/stat" 2>/dev/null && [[ "\$st" != Z ]]; }
for _ in \$(seq 100); do
    alive || exit 0
    "$REAL_SLEEP" 0.02
done
kill -9 "\$pid" 2>/dev/null
exit 0
FAKE

# 8.2.9's second process (src/main.cpp runSecondaryInstance, the options in
# src/command_line_parser.cpp): one connection, the lines in the order the
# parser emits them, hide_window after every -l, -b and --bypass-toggle,
# show_window when there was nothing else to say, and an answer printed with
# a newline of its own. The engine never runs it on purpose; a regression to
# the command line shows here as the hide_window it sends.
cat > "$FAKES/ee-cli.py" <<'FAKE'
import os, socket, sys

sock_path, data, work = sys.argv[1:4]
args = sys.argv[4:]
lines, hide, i = [], False, 0
while i < len(args):
    a, v = args[i], (args[i + 1] if i + 1 < len(args) else '')
    if a in ('-a', '--last-loaded-preset'):
        lines.append(('get_last_loaded_preset:' + v, True)); i += 1
    elif a in ('-l', '--load-preset'):
        for kind in ('input', 'output'):
            if os.path.isfile(os.path.join(data, kind, v + '.json')):
                lines.append(('load_preset:%s:%s' % (kind, v), False))
        hide = True; i += 1
    elif a in ('-b', '--bypass'):
        lines.append({'1': ('global_bypass:1', False), '2': ('global_bypass:0', False),
                      '3': ('get_global_bypass', True)}.get(v, ('', False)))
        hide = True; i += 1
    elif a == '--bypass-toggle':
        lines.append(('toggle_global_bypass', False)); hide = True
    i += 1
lines = [l for l in lines if l[0]]
if hide:
    lines.append(('hide_window', False))
if not args:
    lines.append(('show_window', False))

client = socket.socket(socket.AF_UNIX)
try:
    client.connect(sock_path)
except OSError:
    with open(os.path.join(work, 'unheard.log'), 'a') as fh:
        for line, _ in lines:
            fh.write('easyeffects ' + line + '\n')
    for _, question in lines:
        if question:
            print()
    sys.exit(0)
client.settimeout(0.5)
for line, question in lines:
    client.sendall((line + '\n').encode())
    if question:
        try:
            reply = client.recv(1024)
        except OSError:
            reply = b''
        sys.stdout.write(reply.decode('utf-8', 'replace') + '\n')
client.close()
FAKE

cat > "$FAKES/easyeffects" <<FAKE
#!/usr/bin/env bash
printf 'easyeffects %s\n' "\$*" >> "$WORK/calls.log"
if [[ -e "$WORK/v7" ]]; then
    # 7.x: no socket; -b reads and writes a GSettings key, 1/0 when asked.
    case "\${1:-} \${2:-}" in
        "-b 1") : > "$WORK/bypassed" ;;
        "-b 2") rm -f "$WORK/bypassed" ;;
        "-b 3") if [[ -e "$WORK/bypassed" ]]; then echo 1; else echo 0; fi ;;
    esac
    exit 0
fi
if [[ ! -e "$WORK/running" ]]; then
    printf 'easyeffects %s\n' "\$*" >> "$WORK/unheard.log"
    exit 0
fi
exec "$PYTHON" "$FAKES/ee-cli.py" "$SOCKET" "$DATA" "$WORK" "\$@"
FAKE

# The real socat, and a record of every request it could not deliver. The
# probe (-u, reading nothing) goes straight through: its stdin is its
# caller's and must not be read here.
cat > "$FAKES/socat" <<FAKE
#!/usr/bin/env bash
[[ "\${1:-}" == -u ]] && exec "$SOCAT" "\$@"
request=\$(cat; printf x); request=\${request%x}
printf '%s' "\$request" | "$SOCAT" "\$@"
status=\$?
(( status == 0 )) || printf 'socat %s' "\$request" >> "$WORK/unheard.log"
exit \$status
FAKE

cat > "$FAKES/pgrep" <<FAKE
#!/usr/bin/env bash
n=\$(( \$(cat "$WORK/ticks" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "$WORK/ticks"
if [[ -f "$WORK/comes_up_after" ]] && (( n == \$(cat "$WORK/comes_up_after") )); then
    "$FAKES/instance-up"
    printf 'instance up (pgrep call %s)\n' "\$n" >> "$WORK/calls.log"
fi
[[ -e "$WORK/running" ]] && exit 0
# Another user's instance: seen by a pgrep that does not name this user.
[[ -e "$WORK/foreign" && " \$* " != *" -u "* ]]
FAKE

cat > "$FAKES/setsid" <<FAKE
#!/usr/bin/env bash
printf 'setsid %s\n' "\$*" >> "$WORK/calls.log"
[[ "\${1:-}" == -f ]] && shift
if [[ "\${1:-}" == easyeffects ]]; then
    shift
    # The lock is held: a second process, handing its options on.
    [[ -e "$WORK/running" ]] && exec "$FAKES/easyeffects" "\$@"
    # Nothing holds it: this one is the instance.
    "$FAKES/instance-up"
    [[ " \$* " == *" --hide-window "* ]] || : > "$WORK/window"
    exit 0
fi
job=\$(mktemp "$WORK/detached/\$(date +%s%N).XXXXXX") || exit 1
{ declare -px; printf 'exec'; printf ' %q' "\$@"; printf '\n'; } > "\$job"
exit 0
FAKE

cat > "$FAKES/systemctl" <<FAKE
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$WORK/calls.log"
case "\$*" in
    "--user cat easyeffects.service")   [[ -e "$WORK/unit" ]] && exit 0; exit 1 ;;
    "--user start easyeffects.service")
        [[ -e "$WORK/unit" && -e "$WORK/unit_condition_ok" ]] && "$FAKES/instance-up"
        [[ -s "$WORK/kill_caller" ]] && kill -"\$(cat "$WORK/kill_caller")" "\$PPID"
        exit 0 ;;
esac
exit 0
FAKE

cat > "$FAKES/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

# A daemon whose event loop is stuck: listening, never accepting, and its
# queue already full -- one connection waiting that nobody takes. A connect
# to it does not fail; it waits for room that never comes.
cat > "$FAKES/ee-wedged.py" <<'FAKE'
import os, socket, sys, time

work, sock_path, suite_pid = sys.argv[1:4]
try:
    os.unlink(sock_path)
except OSError:
    pass
server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen(0)
waiting = socket.socket(socket.AF_UNIX)
waiting.setblocking(False)
try:
    waiting.connect(sock_path)
except BlockingIOError:
    pass
child = os.fork()
if child:
    with open(os.path.join(work, 'daemon.pid'), 'w') as fh:
        fh.write(str(child))
    os._exit(0)
os.setsid()
null = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
while os.path.isdir(work):
    try:
        os.kill(int(suite_pid), 0)
    except OSError:
        break
    time.sleep(0.5)
FAKE

# 7.x's raise is a GApplication Activate over D-Bus, and its fallback asks
# the compositor to focus the window; uwsm says the session is not its own.
# None of them reaches a real session bus, Hyprland or user manager. The
# engine has no reason to call any of them -- it speaks to a socket and
# needs no display -- so each also writes to session.log, which no case
# clears, and the end of this suite holds that log empty. (That second
# write is the one change from jayos's copy of these three.)
cat > "$FAKES/uwsm" <<FAKE
#!/usr/bin/env bash
printf 'uwsm %s\n' "\$*" >> "$WORK/calls.log"
printf 'uwsm %s\n' "\$*" >> "$WORK/session.log"
exit 1
FAKE
for tool in gdbus hyprctl; do
    cat > "$FAKES/$tool" <<FAKE
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >> "$WORK/calls.log"
printf '$tool %s\n' "\$*" >> "$WORK/session.log"
exit 0
FAKE
done

chmod +x "$FAKES"/*

# The plugin, present in one LADSPA directory and absent from another.
mkdir -p "$WORK/ladspa" "$WORK/ladspa-empty"
: > "$WORK/ladspa/libdeep_filter_ladspa.so"

# PATHs with the fakes but without one tool: the machine's own PATH minus
# that one name, plus every fake but its stand-in. run() takes one through
# WITHOUT=<tool>.
for tool in easyeffects socat; do
    path_without "$WORK/no-$tool" "$tool" \
        || { echo "could not build a PATH without $tool" >&2; exit 2; }
    mkdir -p "$WORK/fakes-no-$tool"
    for f in "$FAKES"/*; do
        [[ "${f##*/}" == "$tool" ]] || ln -s "$f" "$WORK/fakes-no-$tool/${f##*/}"
    done
done

# Back to nothing: no home, no settings, no instance, no switches, no calls,
# nothing detached waiting to run.
#
# New here: what the last case detached is written down first. The engine
# starts nothing in the background but `setsid -f easyeffects`, which the
# fake setsid turns into an instance; anything else would be a job queued in
# $WORK/detached, and jayos's suite ran those because its subjects mean to
# detach. Nothing here does, so a job is kept for the check at the end
# instead of being run or silently wiped.
fresh() {
    "$FAKES/daemon-stop"
    local job
    for job in "$WORK"/detached/*; do
        [[ -f "$job" ]] && tail -n 1 "$job" >> "$WORK/stray.log"
    done
    rm -rf "$FAKE_HOME" "$SHELL_DIR" "$RUN_DIR" "$WORK/calls.log" "$WORK/unheard.log" \
           "$WORK/running" "$WORK/ticks" "$WORK/comes_up_after" "$WORK/window" \
           "$WORK/fake_current" "$WORK/fake_current_output" "$WORK/no_answer" \
           "$WORK/ignore_loads" "$WORK/bypassed" "$WORK/unit" "$WORK/unit_condition_ok" \
           "$WORK/v7" "$WORK/foreign" "$WORK/kill_caller" "$WORK/detached"
    mkdir -p "$FAKE_HOME" "$SHELL_DIR" "$RUN_DIR" "$WORK/detached"
}
rc()        { mkdir -p "$CONF/db"; printf '%s\n' "$1" > "$CONF/db/easyeffectsrc"; }
# What the daemon answers for the input pipeline: the bare name, no newline;
# the fake adds the daemon's.
current()   { printf '%s' "$1" > "$WORK/fake_current"; }
clear_log() { : > "$WORK/calls.log"; : > "$WORK/unheard.log"; rm -f "$WORK/ticks"; }
up()        { "$FAKES/instance-up"; }
starting()  { : > "$WORK/running"; "$FAKES/daemon-stop"; rm -f "$SOCKET"; }
wedged()    { : > "$WORK/running"; "$FAKES/daemon-stop"; "$PYTHON" "$FAKES/ee-wedged.py" "$WORK" "$SOCKET" "$$"; }
down()      { rm -f "$WORK/running"; "$FAKES/daemon-stop"; rm -f "$SOCKET"; }
# What a crash and the unit's restart look like for the seconds until the new
# process reaches startServer: a process again, and the socket file the dead
# one left, which nothing listens on.
crashed()   { up; "$FAKES/daemon-stop"; : > "$WORK/running"; }
comes_up_after() { printf '%s' "$1" > "$WORK/comes_up_after"; rm -f "$WORK/ticks"; }
unit()      { : > "$WORK/unit"; : > "$WORK/unit_condition_ok"; }
# Our preset on disk without an instance to load it: what a `set on` on an
# earlier day leaves behind.
our_file()  { mkdir -p "$DATA/input"; run "$ENGINE" preset "${1:-balanced}" > "$FILE"; }
# The two numbers most cases turn on, read from the file `set` wrote.
bypass_of() { jq -r '.input["deepfilternet#0"].bypass' "$FILE" 2>/dev/null; }
atten_of()  { jq -r '.input["deepfilternet#0"]["attenuation-limit"] + 0' "$FILE" 2>/dev/null; }

# Which LADSPA directory, which tool is missing, and how long the next run
# may take before it is killed -- for a case whose failure is a hang.
# PLUGIN is 1 (LADSPA_PATH names a directory holding the plugin), 0 (one
# that does not) or none (LADSPA_PATH removed, so EasyEffects' own list is
# searched -- which is this machine's, see the case that uses it).
PLUGIN=1
WITHOUT=""
RUN_LIMIT=""

# run <bash arguments...>: bash, under the sandbox.
#
# QS_SHELL_DIR is jayos's, and set here only so that a settings.json the
# engine must NOT read is where jayos's scripts would have read it. WAYLAND_DISPLAY
# and DISPLAY are removed, not merely left unset, so the developer's own
# session cannot lend a display to a script that must not need one.
run() {
    local path="$FAKES:$PATH" limit=() unset_ladspa=() ladspa=()
    case "$PLUGIN" in
        1)    ladspa=(LADSPA_PATH="$WORK/ladspa") ;;
        0)    ladspa=(LADSPA_PATH="$WORK/ladspa-empty") ;;
        none) unset_ladspa=(-u LADSPA_PATH) ;;
    esac
    [[ -n "$WITHOUT" ]] && path="$WORK/fakes-no-$WITHOUT:$WORK/no-$WITHOUT"
    [[ -n "$RUN_LIMIT" ]] && limit=(timeout "$RUN_LIMIT")
    "${limit[@]}" env -u WAYLAND_DISPLAY -u DISPLAY "${unset_ladspa[@]}" HOME="$FAKE_HOME" \
        XDG_CONFIG_HOME="$FAKE_HOME/.config" XDG_DATA_HOME="$FAKE_HOME/.local/share" \
        XDG_RUNTIME_DIR="$RUN_DIR" QS_SHELL_DIR="$SHELL_DIR" \
        "${ladspa[@]}" PATH="$path" \
        bash "$@"
}

# Code lines only, for every static check below: each of these files explains
# the mistake it avoids in prose, using the words the check looks for.
code_sh() { grep -vE '^[[:space:]]*#' "$1"; }
# The names a contract file lists, its `#` header skipped, comma-joined.
listed() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | paste -sd, -; }

# strength_params()'s body, code lines only, read here rather than asked of
# the engine: `strengths` is under test, so it cannot be the oracle.
ARMS=$(awk '
    /^strength_params\(\)/ { f = 1; next }
    f && /esac/ { exit }
    f' "$ENGINE" | grep -vE '^[[:space:]]*#')
ARM_NAMES=$(grep -oE '^\s*[a-z]+\)' <<<"$ARMS" | tr -d ' )' | paste -sd, -)
STATUS_KEYS=$(listed "$CONTRACT/status-keys.txt")

# ── the verbs ────────────────────────────────────────────────────────────────
#
# New here. The engine is a command other code calls by name -- jayos's
# wrapper, its doctor, a person -- and a verb it does not know has to be a
# refusal with exit 1, never an exit 0 that read as success to a caller that
# misspelled it.
echo
echo "the verbs"

fresh; clear_log
OUT=$(run "$ENGINE" bogus 2>&1); STATUS=$?
check "an unknown verb exits 1" 1 "$STATUS"
says "with the usage, under the command's own name" "usage: jayos-denoise status|preset|set|apply|strengths" "$OUT"
check "and calls nothing" "" "$(calls)"

OUT=$(run "$ENGINE" 2>/dev/null); STATUS=$?
check "no verb is status: exits 0" 0 "$STATUS"
check "with status's keys" "$STATUS_KEYS" "$(jq -r 'keys_unsorted | join(",")' <<<"$OUT" 2>/dev/null)"

if [[ -n "$ARM_NAMES" ]]; then
    pass "strength_params() has the arms: $ARM_NAMES"
else
    bad "could not read the case arms out of strength_params() in src/jayos-denoise"
fi
OUT=$(run "$ENGINE" strengths 2>&1); STATUS=$?
check "strengths exits 0" 0 "$STATUS"
check "and prints strength_params()'s arms, one per line, in their order" "$ARM_NAMES" "$(paste -sd, - <<<"$OUT")"
check "which are contract/strengths.txt's, in its order" "$(listed "$CONTRACT/strengths.txt")" "$(paste -sd, - <<<"$OUT")"

OUT=$(run "$ENGINE" preset 2>&1); STATUS=$?
check "preset with no strength exits 1" 1 "$STATUS"
says "with its usage" "jayos-denoise: usage: jayos-denoise preset <gentle|balanced|maximum> [off]" "$OUT"
for bad_state in "" maybe gentle; do
    OUT=$(run "$ENGINE" set $bad_state 2>&1); STATUS=$?
    check "set ${bad_state:-with no state} exits 1" 1 "$STATUS"
    says "with its usage" "usage: jayos-denoise set on|off" "$OUT"
done
check "and none of them called anything" "" "$(calls)"

# ── status ───────────────────────────────────────────────────────────────────
echo
echo "status"

# Names are not ours. EasyEffects' own validator refuses only `/` and `\`
# (contents/ui/Validators.qml), an imported preset keeps its file name, and
# JSON forbids raw control bytes inside a string -- one tab made the whole
# status unparseable, and the popup's catch then hid both EasyEffects rows.
# (jayos's 836-847.)
fresh; mkdir -p "$DATA/output" "$DATA/input"
up; current $'Tab\tName'; clear_log
OUT=$(run "$ENGINE" status 2>/dev/null)
if jq -e . <<<"$OUT" >/dev/null 2>&1; then
    pass "status is JSON with a tab in the input preset's name"
else
    bad "status is not JSON with a tab in the input preset: $(head -c 200 <<<"$OUT" | cat -A)"
    OUT='{}'
fi
check "and names it byte for byte" $'Tab\tName' "$(jq -r .inputPreset <<<"$OUT" 2>/dev/null)"
current 'quote"back\slash'
OUT=$(run "$ENGINE" status 2>/dev/null)
check "and a quote and a backslash (new here)" 'quote"back\slash' "$(jq -r .inputPreset <<<"$OUT" 2>/dev/null)"

# New here: the keys, against the contract jayos vendors. A key jayos's
# wrapper reads that the engine stopped printing is a popup row that goes
# blank without an error; and enabled and strength are the setting's, which
# the wrapper adds -- an engine that printed them would be one reading the
# settings again, or making them up.
if [[ -n "$STATUS_KEYS" ]]; then
    pass "contract/status-keys.txt lists $(tr ',' '\n' <<<"$STATUS_KEYS" | wc -l) keys"
else
    bad "contract/status-keys.txt is missing or lists no keys"
fi
check "status prints exactly those keys, in that order" "$STATUS_KEYS" "$(jq -r 'keys_unsorted | join(",")' <<<"$OUT" 2>/dev/null)"
check "and neither enabled nor strength: the setting is jayos's" false \
    "$(jq -r 'has("enabled") or has("strength")' <<<"$OUT" 2>/dev/null)"

# New here: another user's instance -- a second seat -- is nobody this user
# can speak to; the lib counts processes with -u for that reason.
fresh; mkdir -p "$DATA"; : > "$WORK/foreign"; clear_log
OUT=$(run "$ENGINE" status 2>/dev/null)
check "another user's instance is not called running" false "$(jq -r .running <<<"$OUT" 2>/dev/null)"
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "and set on beside it exits 0" 0 "$STATUS"
log_has "having started this user's own" "setsid -f easyeffects --hide-window --service-mode"
check "which holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"

# New here: a 7.x tree. The engine cannot load into a 7.x instance (there is
# no socket), but status must still say where the preset would be.
fresh; mkdir -p "$CONF/output"; clear_log
OUT=$(run "$ENGINE" status 2>/dev/null)
check "on a 7.x tree status reports layout 7" 7 "$(jq -r .layout <<<"$OUT" 2>/dev/null)"
check "and the preset file under ~/.config/easyeffects/input" "$CONF/input/denoise.json" \
    "$(jq -r .presetFile <<<"$OUT" 2>/dev/null)"

# ── the 7.x calls, and the global bypass, are gone from the code ─────────────
#
# jayos's 1324-1360, the denoise.sh passes -- and, new here, the same guards
# over the library, which is this repository's copy now and is what the
# engine runs.
echo
echo "what the code never does"

for f in "$ENGINE" "$LIB"; do
    name="src/${f##*/}"
    CODE=$(code_sh "$f")
    if grep -qi 'gsettings' <<<"$CODE"; then
        bad "$name calls gsettings on a code line; the schema is gone in 8.x"
    else
        pass "$name has no gsettings call on a code line"
    fi
    if grep -q -- '--gapplication-service' <<<"$CODE"; then
        bad "$name uses --gapplication-service on a code line; 8.x spells it --hide-window --service-mode"
    else
        pass "$name does not use --gapplication-service"
    fi
    # The command line's -l, -b and -a are how the window got closed.
    if grep -qE 'easyeffects +-(l|b|a)( |$)|easyeffects +--(load-preset|bypass|last-loaded-preset)' <<<"$CODE"; then
        bad "$name runs easyeffects -l, -b or -a on a code line, which also hides the window"
    else
        pass "$name never runs easyeffects -l, -b or -a on a code line"
    fi
done
if grep -qE 'easyeffects +--version' <<<"$(code_sh "$LIB")"; then
    bad "the lib asks easyeffects --version to decide the layout, which spawns a Qt process"
else
    pass "the lib never asks easyeffects --version"
fi
if grep -qE 'easyeffects +-b|global_bypass|ee_(set|toggle)_bypass' <<<"$(code_sh "$ENGINE")"; then
    bad "the engine touches the GLOBAL bypass (easyeffects -b, or global_bypass on the socket) on a code line"
else
    pass "the engine never touches the global bypass on a code line"
fi

# ── the preset ───────────────────────────────────────────────────────────────
#
# The nine keys src/deepfilternet_preset.cpp reads under the plugin, no more
# and no fewer; the plugin alone in plugins_order; and the numbers behind each
# strength name, which are the whole difference between the three.
# (jayos's 1456-1507.)
echo
echo "the preset the engine generates"

PLUGIN_KEYS="attenuation-limit,bypass,input-gain,max-df-processing-threshold,max-erb-processing-threshold,min-processing-buffer,min-processing-threshold,output-gain,post-filter-beta"
# attenuation, min threshold, max-ERB, max-DF, buffer, beta -- as jq prints
# them once normalised (24.0 in the file is 24 here).
numbers() {
    jq -r '.input["deepfilternet#0"]
           | [.["attenuation-limit"], .["min-processing-threshold"],
              .["max-erb-processing-threshold"], .["max-df-processing-threshold"],
              .["min-processing-buffer"], .["post-filter-beta"]]
           | map(. + 0 | tostring) | join(" ")' <<<"$1"
}
declare -A EXPECT=(
    [gentle]="24 -15 30 20 0 0.02"
    [balanced]="70 -15 30 20 0 0.02"
    [maximum]="100 -15 35 35 0 0.05"
)
for s in gentle balanced maximum; do
    OUT=$(run "$ENGINE" preset "$s" 2>&1); STATUS=$?
    check "preset $s exits 0" 0 "$STATUS"
    if jq -e . <<<"$OUT" >/dev/null 2>&1; then
        pass "and is JSON"
    else
        bad "preset $s is not JSON: $OUT"
        OUT='{}'
    fi
    check "$s: the input pipeline only, nothing about output" "input" "$(jq -r 'keys | join(",")' <<<"$OUT")"
    check "$s: block list, plugin, order -- and no other key" "blocklist,deepfilternet#0,plugins_order" \
        "$(jq -r '.input | keys | join(",")' <<<"$OUT")"
    check "$s: plugins_order is exactly [deepfilternet#0]" 'deepfilternet#0' \
        "$(jq -r '.input.plugins_order | join(",")' <<<"$OUT")"
    check "$s: the nine keys the plugin reads, no more" "$PLUGIN_KEYS" \
        "$(jq -r '.input["deepfilternet#0"] | keys | join(",")' <<<"$OUT")"
    check "$s: not bypassed" false "$(jq -r '.input["deepfilternet#0"].bypass' <<<"$OUT")"
    check "$s: gains stay at 0 (level is the mixer's)" "0 0" \
        "$(jq -r '.input["deepfilternet#0"] | [.["input-gain"], .["output-gain"]] | map(. + 0 | tostring) | join(" ")' <<<"$OUT")"
    check "$s: attenuation, min, max-ERB, max-DF, buffer, beta" "${EXPECT[$s]}" "$(numbers "$OUT")"
done
OUT=$(run "$ENGINE" preset balanced off 2>&1)
check "preset balanced off: the same preset with bypass true" true \
    "$(jq -r '.input["deepfilternet#0"].bypass' <<<"$OUT" 2>/dev/null)"
check "and the plugin still in plugins_order" 'deepfilternet#0' \
    "$(jq -r '.input.plugins_order | join(",")' <<<"$OUT" 2>/dev/null)"
OUT=$(run "$ENGINE" preset loud 2>&1); STATUS=$?
check "an unknown strength exits 1" 1 "$STATUS"
says "and names the three, under the engine's prefix" \
    "jayos-denoise: unknown strength 'loud' (gentle, balanced or maximum)" "$OUT"

# ── set on and off ───────────────────────────────────────────────────────────
#
# jayos's 1509-1640. Adapted: the cases that took the strength from
# settings.json now hand it over, or leave it out and get balanced.
echo
echo "set on and off, against a ready instance"

fresh; mkdir -p "$DATA"; up; current ""; clear_log
OUT=$(run "$ENGINE" set on balanced 2>&1); STATUS=$?
check "set on balanced exits 0" 0 "$STATUS"
if [[ -f "$FILE" ]]; then
    pass "writes input/denoise.json under the 8.x root"
    check "not bypassed" false "$(bypass_of)"
    check "at balanced's attenuation" 70 "$(atten_of)"
else
    bad "input/denoise.json was not written under $DATA"
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi
log_has "asks the instance to load it: load_preset:input:denoise, on the socket" "heard load_preset:input:denoise"
# The fake takes a load only for a file that exists when the load arrives,
# as the daemon does: a load sent before the write is a load of nothing.
check "and the daemon holds it, so the file was written before the load was sent" denoise \
    "$(cat "$WORK/fake_current" 2>/dev/null)"
log_has "and the load was believed only after asking what is held" "heard get_last_loaded_preset:input"
log_lacks "and never the global bypass" "heard global_bypass"
log_lacks "nor its toggle" "heard toggle_global_bypass"
no_hide "and the window is left alone"
log_lacks "nor a start, since one is ready" "setsid"
says "and says so" "noise suppression on (balanced)" "$OUT"
check "only denoise.json is left in input/ (the temporary was moved, not copied)" "denoise.json" "$(ls -A "$DATA/input")"
if [[ ! -e "$DATA/output" ]]; then
    pass "and output/ was not created: the speakers are not this engine's"
else
    bad "set on created $DATA/output"
fi

# Adapted: jayos's case read maximum out of settings.json; here it is handed
# over, as the wrapper hands it. It also leaves maximum's 100 in the file, so
# the case after it can tell balanced from "whatever was there".
clear_log
OUT=$(run "$ENGINE" set on maximum 2>&1); STATUS=$?
check "set on maximum writes maximum's attenuation" 100 "$(atten_of)"
says "and says which" "noise suppression on (maximum)" "$OUT"

# Adapted: jayos's denoise.sh took a missing strength from micDenoiseStrength.
# The engine knows no settings file -- the wrapper hands it the strength --
# so a missing one is balanced, and a settings.json saying maximum where
# jayos keeps it, and where XDG puts jayos's config, changes nothing.
printf '%s\n' '{"micDenoise":false,"micDenoiseStrength":"maximum"}' > "$SHELL_DIR/settings.json"
mkdir -p "$FAKE_HOME/.config/quickshell"
cp "$SHELL_DIR/settings.json" "$FAKE_HOME/.config/quickshell/settings.json"
clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with no strength exits 0" 0 "$STATUS"
check "and writes balanced's attenuation, not the 100 a settings.json beside it names" 70 "$(atten_of)"
says "and says balanced" "noise suppression on (balanced)" "$OUT"
check "and is on, though that settings.json says micDenoise false" false "$(bypass_of)"
OUT=$(run "$ENGINE" set on loud 2>&1); STATUS=$?
check "but an unknown strength given outright exits 1" 1 "$STATUS"
says "naming it" "jayos-denoise: unknown strength 'loud'" "$OUT"
check "and leaves the preset as it was" 70 "$(atten_of)"

# Off takes whatever strength it is handed: there it only fills in the numbers
# of a bypassed preset. It died over a hand-edited "strong" as on does, so the
# popup's switch said off over a filter left loaded and not bypassed.
# Adapted: balanced stands in now, where denoise.sh used the saved strength --
# the wrapper is what knows that, and hands it over (the next case).
our_file gentle; current denoise; clear_log
OUT=$(run "$ENGINE" set off strong 2>&1); STATUS=$?
check "set off with a strength it does not know still exits 0" 0 "$STATUS"
check "and bypasses our preset" true "$(bypass_of)"
check "with balanced standing in: balanced's attenuation, over the file's gentle" 70 "$(atten_of)"
log_has "and reloads it, since ours is what the daemon holds" "heard load_preset:input:denoise"
says "and says off" "noise suppression off" "$OUT"
# Adapted from "the SAVED strength stands in": the strength off is handed is
# the one written, over a preset at another strength's numbers.
our_file balanced; current denoise; clear_log
OUT=$(run "$ENGINE" set off gentle 2>&1); STATUS=$?
check "set off gentle over a preset at balanced exits 0" 0 "$STATUS"
check "and gentle's attenuation is written, over balanced's 70" 24 "$(atten_of)"
check "still bypassed" true "$(bypass_of)"

# An explicit set replaces a preset chosen by hand, and says which.
current mine; clear_log
OUT=$(run "$ENGINE" set on gentle 2>&1)
says "set on over a foreign input preset says what it replaces" "replacing input preset 'mine' with denoise" "$OUT"
log_has "and loads ours anyway: an explicit act wins" "heard load_preset:input:denoise"
check "and the daemon then holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"

# status, with everything in place. Adapted: enabled and strength are gone.
current denoise
OUT=$(run "$ENGINE" status 2>/dev/null); STATUS=$?
check "status exits 0" 0 "$STATUS"
if jq -e . <<<"$OUT" >/dev/null 2>&1; then pass "and is JSON"; else bad "status is not JSON: $OUT"; OUT='{}'; fi
check "with contract/status-keys.txt's keys" "$STATUS_KEYS" "$(jq -r 'keys_unsorted | join(",")' <<<"$OUT")"
check "loaded: ours is the input preset and the file exists" true "$(jq -r .loaded <<<"$OUT")"
check "running" true "$(jq -r .running <<<"$OUT")"
check "presetFile is the file set wrote" "$FILE" "$(jq -r .presetFile <<<"$OUT")"
check "presetExists" true "$(jq -r .presetExists <<<"$OUT")"
check "and the plugin path" "$WORK/ladspa/libdeep_filter_ladspa.so" "$(jq -r .pluginPath <<<"$OUT")"

# Off while ours is loaded: the same file, bypassed, reloaded. Adapted: the
# strength is handed over (it was read from settings.json).
clear_log
OUT=$(run "$ENGINE" set off gentle 2>&1); STATUS=$?
check "set off exits 0" 0 "$STATUS"
check "off keeps deepfilternet#0 in plugins_order (#4652: idled, never removed)" 'deepfilternet#0' \
    "$(jq -r '.input.plugins_order | join(",")' "$FILE" 2>/dev/null)"
check "with bypass true" true "$(bypass_of)"
check "and the strength it was handed" 24 "$(atten_of)"
log_has "and reloads it, since ours was what was loaded" "heard load_preset:input:denoise"
log_lacks "still never the global bypass" "heard global_bypass"
no_hide "and still the window is left alone"
says "and says so" "noise suppression off" "$OUT"
check "still only denoise.json in input/" "denoise.json" "$(ls -A "$DATA/input")"
OUT=$(run "$ENGINE" status 2>/dev/null)
check "status still calls it loaded: bypassed is loaded" true "$(jq -r .loaded <<<"$OUT")"
# New here: off with no strength is balanced too.
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off with no strength exits 0, at balanced's attenuation" "0 70" "$STATUS $(atten_of)"

# Off while a foreign preset is loaded: written, not loaded over it.
current mine; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off over a foreign preset exits 0" 0 "$STATUS"
check "and writes bypass true" true "$(bypass_of)"
log_lacks "but never loads over a preset somebody chose" "heard load_preset"
if [[ ! -e "$DATA/output" ]]; then
    pass "output/ still does not exist after every set"
else
    bad "a set created $DATA/output"
fi

# Off with nothing of ours: nothing to do, nothing written.
fresh; mkdir -p "$DATA"; up; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off with no preset of ours exits 0" 0 "$STATUS"
says "and says nothing was loaded" "nothing was loaded" "$OUT"
if [[ ! -e "$DATA/input" ]]; then
    pass "and writes nothing"
else
    bad "set off with nothing of ours wrote under $DATA/input"
fi
log_lacks "and loads nothing" "heard load_preset"

# ── a load is believed only when the daemon says it holds ours ──────────────
#
# A write to the socket reaches the daemon whatever it then does -- with a
# preset it does not have, with a file it has not noticed yet. A daemon that
# ignores the load must not produce "noise suppression on". (jayos's
# 1642-1663.)
echo
echo "a load the daemon ignored"

fresh; mkdir -p "$DATA"; up; current ""; : > "$WORK/ignore_loads"; clear_log
OUT=$(run "$ENGINE" set on balanced 2>&1); STATUS=$?
check "set on exits 1 when the daemon does not take the load" 1 "$STATUS"
says "and says it did not load" "jayos-denoise: easyeffects did not load the preset" "$OUT"
says_not "and never claims the filter is on" "noise suppression on" "$OUT"
check "after three tries, a second apart" 3 "$(calls | grep -c 'heard load_preset:input:denoise')"
# The asks from the first load on: the one before it says what is replaced.
check "each followed by asking what is held" 3 \
    "$(calls | sed -n "$(line_of 'heard load_preset:input:denoise'),\$p" | grep -c 'heard get_last_loaded_preset:input')"
if [[ -f "$FILE" ]]; then
    pass "the file is written all the same, for the next try"
else
    bad "set on did not write $FILE"
fi

# New here: a daemon that took the load and never answered the question. The
# answer is the only evidence, so no answer is no load.
fresh; mkdir -p "$DATA"; up; current ""; printf 'get_last_loaded_preset' > "$WORK/no_answer"; clear_log
OUT=$(run "$ENGINE" set on balanced 2>&1); STATUS=$?
check "set on against a daemon that hears and never answers exits 1" 1 "$STATUS"
log_has "though the load was heard" "heard load_preset:input:denoise"
says_not "and does not claim the filter is on" "noise suppression on" "$OUT"

# ── set starts an instance; apply never does ─────────────────────────────────
#
# jayos's 1665-1720. Adapted only by dropping the settings.json each case
# wrote, which the engine does not read.
echo
echo "who starts the instance, and what it waits for"

fresh; mkdir -p "$DATA"; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with nothing running and no unit exits 0" 0 "$STATUS"
log_has "starts one by hand: setsid -f easyeffects --hide-window --service-mode" \
    "setsid -f easyeffects --hide-window --service-mode"
log_has "and then loads" "heard load_preset:input:denoise"
before "in that order" "setsid" "heard load_preset:input:denoise"
check "and the load was heard: the daemon holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"

fresh; mkdir -p "$DATA"; unit; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with the unit installed exits 0" 0 "$STATUS"
log_has "starts it through easyeffects.service, so systemd owns the process" \
    "systemctl --user start easyeffects.service"
log_lacks "and not by hand as well" "setsid"
log_has "then loads" "heard load_preset:input:denoise"

# The unit's ConditionEnvironment: `start` on a unit whose condition is not
# met returns 0 and starts nothing. Nothing appears, so the start by hand
# must follow.
fresh; mkdir -p "$DATA"; : > "$WORK/unit"; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with a unit whose start produces no instance exits 0" 0 "$STATUS"
log_has "the unit was tried" "systemctl --user start easyeffects.service"
log_has "and, with no socket after that, it fell through to a start by hand" \
    "setsid -f easyeffects --hide-window --service-mode"
before "in that order" "systemctl --user start" "setsid"
log_has "and then loaded" "heard load_preset:input:denoise"
says "and says it is on" "noise suppression on" "$OUT"

# A process that exists but has no socket yet: a second start would lose the
# lock and exit, so it is waited for, and the load goes after the socket.
fresh; mkdir -p "$DATA"; starting; comes_up_after 3; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with a process that is still starting exits 0" 0 "$STATUS"
log_lacks "and starts nothing beside it (a second start would lose the lock)" "setsid"
log_has "the socket came while it waited" "instance up"
before "and the load went after it" "instance up" "heard load_preset:input:denoise"
check "no load was sent while nobody was listening" "" "$(unheard | grep -- 'load_preset' || true)"
says "and says it is on" "noise suppression on" "$OUT"

# One that never comes up: no load sent into the void, and an exit that says so.
fresh; mkdir -p "$DATA"; starting; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on with a process that never opens its socket exits 1" 1 "$STATUS"
says "and says it did not start" "jayos-denoise: easyeffects did not start" "$OUT"
log_lacks "and sent no load to a socket that never came" "heard load_preset"
if (( $(ticks) >= 30 )); then
    pass "after waiting for it (pgrep was polled $(ticks) times)"
else
    bad "set on gave up after only $(ticks) polls; the lib waits fifteen seconds for a starting process"
fi

# ── a socket a crash left behind ────────────────────────────────────────────
#
# For the seconds a restart takes there is a process AND a socket file --
# and nothing listening on it (the lib's ee_listening says why). A file is
# not a daemon. (jayos's 1740-1747.)
echo
echo "a socket a crash left behind"

fresh; mkdir -p "$DATA"; crashed; comes_up_after 3; clear_log
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on against a restart that has not reached its socket yet exits 0" 0 "$STATUS"
log_has "it waited, and the new daemon came" "instance up"
before "and the load went to the new daemon" "instance up" "heard load_preset:input:denoise"
check "not into the socket the dead one left" "" "$(unheard | grep -- 'load_preset' || true)"
log_lacks "and it started nothing beside the restart (a second start would lose the lock)" "setsid"
says "and says it is on" "noise suppression on" "$OUT"

# New here: a daemon that cannot take a connection at all -- its loop stuck,
# its queue full. jayos's wrapper asks this engine's status on every open of
# the volume popup, and its doctor asks too, so status must answer from the
# rc at once rather than wait on a connect; and set on must give up within
# its own bound. Each run is capped, so a hang fails here instead of hanging
# the suite.
fresh; mkdir -p "$DATA"
rc $'[Presets]\nlastLoadedInputPreset=mine'
wedged; clear_log
T0=$(date +%s%N)
RUN_LIMIT=20
OUT=$(run "$ENGINE" status 2>/dev/null)
RUN_LIMIT=""
ELAPSED_MS=$(( ($(date +%s%N) - T0) / 1000000 ))
check "a daemon that cannot take a connection: status answers from the rc" "mine false" \
    "$(jq -r '[.inputPreset, (.loaded | tostring)] | join(" ")' <<<"$OUT" 2>/dev/null)"
if (( ELAPSED_MS < 3000 )); then
    pass "and at once, not after a wait per question ($ELAPSED_MS ms)"
else
    bad "status against a daemon with a full queue took $ELAPSED_MS ms"
fi
clear_log
RUN_LIMIT=60
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
RUN_LIMIT=""
check "set on against it exits 1, inside its bound" 1 "$STATUS"
says "saying it did not start" "jayos-denoise: easyeffects did not start" "$OUT"
check "and starts nothing beside the process that holds the lock" "" "$(started)"

# ── apply: the login path ────────────────────────────────────────────────────
#
# jayos's 1801-1945. Adapted: each case wrote micDenoise and
# micDenoiseStrength and ran `apply`; it now runs `apply on|off <strength>`.
echo
echo "apply, the login path"

fresh; mkdir -p "$DATA"
rc $'[Presets]\nlastLoadedInputPreset=mine'
up; current mine; clear_log
OUT=$(run "$ENGINE" apply on balanced 2>&1); STATUS=$?
check "apply on with a foreign input preset loaded exits 0" 0 "$STATUS"
log_lacks "and does not load ours over it" "heard load_preset"
says "and names the preset it left alone" "jayos-denoise: input preset 'mine' is loaded" "$OUT"
if [[ -f "$FILE" ]]; then
    pass "the preset file is written all the same"
    check "not bypassed, ready for the next set or --force" false "$(bypass_of)"
else
    bad "apply did not write $FILE"
fi
OUT=$(run "$ENGINE" status 2>/dev/null)
check "status.loaded is false" false "$(jq -r .loaded <<<"$OUT")"
check "and status.inputPreset names the foreign one" mine "$(jq -r .inputPreset <<<"$OUT")"

clear_log
OUT=$(run "$ENGINE" apply on --force 2>&1); STATUS=$?
check "apply on --force exits 0" 0 "$STATUS"
log_has "and replaces it" "heard load_preset:input:denoise"
says "saying so, at balanced when no strength was given" "jayos-denoise: loaded denoise (balanced)" "$OUT"

current ""; clear_log
OUT=$(run "$ENGINE" apply on balanced 2>&1)
log_has "with nothing loaded, apply loads ours" "heard load_preset:input:denoise"
current denoise; clear_log
OUT=$(run "$ENGINE" apply on balanced 2>&1)
log_has "with ours loaded, apply loads it again (the file may have changed)" "heard load_preset:input:denoise"
log_lacks "and in none of these did apply start anything: no setsid" "setsid"
log_lacks "and no systemctl start" "systemctl --user start"

# The instance is the unit's, and at login it is usually between its lock and
# its socket when this runs. The wait is for the SOCKET: a load sent to a
# process that is not listening yet is dropped without a word and exits 0.
fresh; mkdir -p "$DATA"
starting; comes_up_after 3; clear_log
OUT=$(run "$ENGINE" apply on balanced 2>&1); STATUS=$?
check "apply on with a process that has no socket yet exits 0" 0 "$STATUS"
log_has "waits, and the socket comes" "instance up"
before "and only then sends the load" "instance up" "heard load_preset:input:denoise"
check "nothing was sent while nobody was listening (it would have been dropped without a word)" "" \
    "$(unheard | grep -- 'load_preset' || true)"
check "and the daemon holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"
says "and it says loaded, which is now true" "loaded denoise (balanced)" "$OUT"
log_lacks "and it started nothing: the process was the unit's" "setsid"

# No instance at all: written, not loaded, nothing started. The unit is
# installed here, so a start through it would have been the easy mistake.
fresh; mkdir -p "$DATA"; unit; clear_log
OUT=$(run "$ENGINE" apply on 2>&1); STATUS=$?
check "apply on with no instance exits 0 (login goes on)" 0 "$STATUS"
says "and says the preset is written and not loaded" "not running; the preset is written and not loaded" "$OUT"
log_lacks "never starts one by hand (the unit does; two starts race for the lock)" "setsid"
log_lacks "and not through the unit either" "systemctl --user start"
log_lacks "and asks no load of an instance that is not there" "heard load_preset"
if (( $(ticks) >= 40 )); then
    pass "after waiting the full twenty seconds for it (pgrep was polled $(ticks) times)"
else
    bad "apply waited only $(ticks) polls for the unit's instance; it should wait twenty seconds"
fi
if [[ -f "$FILE" ]]; then
    pass "the file is there for the instance to load when it comes"
else
    bad "apply with no instance did not write $FILE"
fi

# The setting off at login: ours bypassed, reloaded only if ours is loaded.
fresh; mkdir -p "$DATA"; up; current denoise
run "$ENGINE" set on balanced >/dev/null 2>&1
clear_log
OUT=$(run "$ENGINE" apply off balanced 2>&1); STATUS=$?
check "apply off exits 0" 0 "$STATUS"
check "and rewrites ours bypassed" true "$(bypass_of)"
log_has "reloading it, since ours is what is loaded" "heard load_preset:input:denoise"
current mine; clear_log
OUT=$(run "$ENGINE" apply off balanced 2>&1)
log_lacks "but not over a foreign preset" "heard load_preset"
if [[ ! -e "$DATA/output" ]]; then
    pass "output/ still does not exist after every apply"
else
    bad "an apply created $DATA/output"
fi

# The daemon restores its pipeline from its own database, not from our file.
# A `set off` that found nothing running left that database saying "ours,
# not bypassed", and the instance the unit starts at the next login brings
# the filter back on -- unless apply waits for it, the way the on path does,
# whenever the rc says ours is what it will restore.
fresh; mkdir -p "$DATA"
our_file balanced
rc $'[Presets]\nlastLoadedInputPreset=denoise'
down; current denoise; comes_up_after 3; clear_log
OUT=$(run "$ENGINE" apply off balanced 2>&1); STATUS=$?
check "apply off, rc says ours, nothing running yet: exits 0" 0 "$STATUS"
check "rewrites ours bypassed" true "$(bypass_of)"
log_has "waits for the instance the rc says will restore ours" "instance up"
before "and reloads the bypassed file once it is there" "instance up" "heard load_preset:input:denoise"
check "which the daemon took" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"
check "nothing was sent while nobody was listening" "" "$(unheard | grep -- 'load_preset' || true)"

# ...and when the rc names nothing of ours, there is nothing to wait for:
# jayos's autostart.lua promises the off path exits at once.
fresh; mkdir -p "$DATA"
our_file balanced
rc $'[Presets]\nlastLoadedInputPreset=mine'
down; clear_log
OUT=$(run "$ENGINE" apply off 2>&1); STATUS=$?
check "apply off, rc names a foreign preset, nothing running: exits 0" 0 "$STATUS"
check "still rewrites ours bypassed" true "$(bypass_of)"
check "calls nothing" "" "$(calls)"
if (( $(ticks) <= 1 )); then
    pass "and does not wait: pgrep was asked once, not forty times"
else
    bad "apply with nothing of ours to restore polled pgrep $(ticks) times; it should exit at once"
fi

# The rc says ours and the instance never comes: the wait, then a quiet exit.
fresh; mkdir -p "$DATA"
our_file balanced
rc $'[Presets]\nlastLoadedInputPreset=denoise'
down; clear_log
OUT=$(run "$ENGINE" apply off 2>&1); STATUS=$?
check "apply off, rc says ours, and no instance ever comes: exits 0" 0 "$STATUS"
log_lacks "sends no load" "heard load_preset"
if (( $(ticks) >= 40 )); then
    pass "after the full wait (pgrep was polled $(ticks) times)"
else
    bad "apply polled pgrep only $(ticks) times before giving up"
fi

fresh; clear_log
OUT=$(run "$ENGINE" apply off 2>&1); STATUS=$?
check "apply off with no file of ours exits 0" 0 "$STATUS"
check "and says nothing" "" "$OUT"
if [[ ! -e "$DATA" ]]; then
    pass "and writes nothing"
else
    bad "apply with nothing to do wrote under $DATA"
fi

# New here: apply's arguments. jayos's wrapper hands over the strength it
# read and --force where a person asked for one; the order is not the
# caller's problem, a strength the engine does not know is replaced rather
# than refused (nobody reads a refusal at login), and a missing state is a
# usage error, never a guess.
echo
echo "apply's arguments"

fresh; mkdir -p "$DATA"; up; current mine; clear_log
OUT=$(run "$ENGINE" apply on gentle --force 2>&1); STATUS=$?
check "apply on gentle --force exits 0" 0 "$STATUS"
log_has "and loads ours over the foreign one" "heard load_preset:input:denoise"
says "at gentle" "jayos-denoise: loaded denoise (gentle)" "$OUT"
check "with gentle's attenuation in the file" 24 "$(atten_of)"
current mine; clear_log
OUT=$(run "$ENGINE" apply on --force maximum 2>&1); STATUS=$?
check "apply on --force maximum (the flag first) exits 0" 0 "$STATUS"
log_has "and loads ours too" "heard load_preset:input:denoise"
says "at maximum" "jayos-denoise: loaded denoise (maximum)" "$OUT"
check "with maximum's attenuation in the file" 100 "$(atten_of)"
current mine; clear_log
OUT=$(run "$ENGINE" apply on gentle 2>&1)
log_lacks "without --force the same strength leaves the foreign preset alone" "heard load_preset"
current ""; clear_log
OUT=$(run "$ENGINE" apply on loud 2>&1); STATUS=$?
check "apply on with an unknown strength exits 0" 0 "$STATUS"
check "and writes balanced, on" "70 false" "$(atten_of) $(bypass_of)"
says "saying balanced" "jayos-denoise: loaded denoise (balanced)" "$OUT"
our_file gentle; current denoise; clear_log
OUT=$(run "$ENGINE" apply off loud 2>&1); STATUS=$?
check "apply off with an unknown strength exits 0" 0 "$STATUS"
check "and writes balanced, bypassed" "70 true" "$(atten_of) $(bypass_of)"
log_has "and reloads ours, which the daemon holds" "heard load_preset:input:denoise"
our_file gentle; clear_log
for args in "" "gentle" "--force" "maybe balanced"; do
    # shellcheck disable=SC2086 # the words are the arguments
    OUT=$(run "$ENGINE" apply $args 2>&1); STATUS=$?
    check "apply ${args:-with nothing} exits 1: there is no state to apply" 1 "$STATUS"
    says "with apply's usage" "jayos-denoise: usage: jayos-denoise apply on|off" "$OUT"
done
check "and none of them wrote the preset or called anything" "24 " "$(atten_of) $(calls)"
WITHOUT=easyeffects
OUT=$(run "$ENGINE" apply 2>&1); STATUS=$?
WITHOUT=""
check "the state is checked before the quiet exit a machine without EasyEffects gets" 1 "$STATUS"

# ── set off with no instance ────────────────────────────────────────────────
#
# The file is what carries "off" to the next login; the instance, when there
# is one, is told only when ours is what it holds. (jayos's 1947-2001.)
echo
echo "set off without an instance"

fresh; mkdir -p "$DATA"; our_file balanced
rc $'[Presets]\nlastLoadedInputPreset=denoise'
down; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off with our file and no instance exits 0" 0 "$STATUS"
check "writes bypass true" true "$(bypass_of)"
log_lacks "and sends no load: there is no filter to idle" "heard load_preset"
log_lacks "and starts nothing" "setsid"
if (( $(ticks) <= 1 )); then
    pass "and does not wait for an instance that is not there"
else
    bad "set off with nothing running polled pgrep $(ticks) times"
fi
says "and says so" "noise suppression off" "$OUT"

# A process that is still starting is waited for, and then told.
fresh; mkdir -p "$DATA"; our_file balanced
starting; current denoise; comes_up_after 3; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off with a process that is still starting exits 0" 0 "$STATUS"
log_has "waits for its socket" "instance up"
before "and reloads the bypassed file once it can be heard" "instance up" "heard load_preset:input:denoise"
check "nothing was sent while nobody was listening" "" "$(unheard | grep -- 'load_preset' || true)"
check "and the daemon holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"

# One that takes fifteen seconds -- inside what the lib allows a start
# (four through the unit, fifteen by hand) and what apply waits (twenty). A
# ten-second wait here gave up first, printed "off", and left the daemon to
# come up holding ours not bypassed: the filter running under a row that
# said off.
fresh; mkdir -p "$DATA"; our_file balanced
starting; current denoise; comes_up_after 30; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off against a start that takes fifteen seconds exits 0" 0 "$STATUS"
before "and waits it out, then reloads ours bypassed" "instance up" "heard load_preset:input:denoise"

# One whose socket never comes: the wait is bounded, and the file carries it.
fresh; mkdir -p "$DATA"; our_file balanced
starting; current denoise; clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off with a process whose socket never comes exits 0" 0 "$STATUS"
check "the file says bypassed" true "$(bypass_of)"
log_lacks "no load went into the void" "heard load_preset"
if (( $(ticks) >= 40 && $(ticks) < 80 )); then
    pass "after waiting twenty seconds, as apply does (pgrep was polled $(ticks) times)"
else
    bad "set off polled pgrep $(ticks) times; the wait for a starting process is twenty seconds"
fi

# ── without the plugin ───────────────────────────────────────────────────────
#
# jayos's 2139-2165. Adapted: denoise.sh named jayos's build arm by its
# absolute path; the engine is the package that ships the plugin, so its
# remedy is its own -- where it looked, and pacman -Qkk for a file the
# package should have put there -- and never a jayos path.
echo
echo "without the plugin"

PLUGIN=0
fresh; mkdir -p "$DATA"; up; clear_log
OUT=$(run "$ENGINE" status 2>/dev/null)
check "status: plugin false" false "$(jq -r .plugin <<<"$OUT")"
check "and pluginPath empty (new here)" "" "$(jq -r .pluginPath <<<"$OUT")"
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on exits 1" 1 "$STATUS"
says "saying the plugin is not where EasyEffects looks" \
    "jayos-denoise: the DeepFilterNet plugin is not where EasyEffects looks, so there is nothing to turn on" "$OUT"
says "naming LADSPA_PATH, which is what was searched" \
    "libdeep_filter_ladspa.so is in no directory of LADSPA_PATH=$WORK/ladspa-empty" "$OUT"
says "and the package's own remedy" "pacman -Qkk jayos-denoise" "$OUT"
says_not "and no jayos path: the build arm is not this package's" "app-install.sh" "$OUT"
says_not "nor the retired recipe" "deepfilternet-ladspa" "$OUT"
if [[ ! -e "$DATA/input" ]]; then
    pass "and writes nothing"
else
    bad "set on without the plugin wrote under $DATA/input"
fi
log_lacks "and loads nothing" "heard load_preset"
clear_log
OUT=$(run "$ENGINE" apply on 2>/dev/null); STATUS=$?
check "apply on exits 0 all the same" 0 "$STATUS"
says "and gives the same remedy, on stdout, which a login hook keeps" "pacman -Qkk jayos-denoise" "$OUT"
log_lacks "and loads nothing" "heard load_preset"
if [[ ! -e "$DATA/input" ]]; then
    pass "and writes nothing"
else
    bad "apply without the plugin wrote under $DATA/input"
fi
clear_log
OUT=$(run "$ENGINE" set off 2>&1); STATUS=$?
check "set off without the plugin exits 0: there is no filter to idle" 0 "$STATUS"

# New here: with LADSPA_PATH unset EasyEffects searches its own list, and so
# does the engine -- this machine's real directories, which the sandbox
# cannot empty. Asked only where none of them holds the plugin.
HAVE_PLUGIN=""
for d in /usr/local/lib/ladspa /usr/lib/ladspa /usr/lib64/ladspa; do
    [[ -f "$d/libdeep_filter_ladspa.so" ]] && { HAVE_PLUGIN=$d; break; }
done
if [[ -n "$HAVE_PLUGIN" ]]; then
    skip "the no-LADSPA_PATH remedy not exercised: this machine has the plugin in $HAVE_PLUGIN"
else
    PLUGIN=none
    fresh; mkdir -p "$DATA"; up; clear_log
    OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
    check "with LADSPA_PATH unset and no plugin installed, set on exits 1" 1 "$STATUS"
    says "naming the directories EasyEffects searches" \
        "libdeep_filter_ladspa.so is in none of /usr/local/lib/ladspa, /usr/lib/ladspa" "$OUT"
    says "all three" "and /usr/lib64/ladspa, where EasyEffects looks" "$OUT"
    says "and the package's remedy" "pacman -Qkk jayos-denoise" "$OUT"
fi
PLUGIN=1

# ── without easyeffects, or without socat ───────────────────────────────────
#
# jayos's 2178-2188, adapted: "enabled still read from settings.json" is the
# wrapper's now; here the key list is the same in the branch that answers
# without EasyEffects. And jayos's 1307-1318.
echo
echo "without easyeffects, or without socat"

WITHOUT=easyeffects
fresh
OUT=$(run "$ENGINE" status 2>&1); STATUS=$?
check "status exits 0" 0 "$STATUS"
check "with installed false" false "$(jq -r .installed <<<"$OUT" 2>/dev/null)"
check "and the same keys (new here)" "$STATUS_KEYS" "$(jq -r 'keys_unsorted | join(",")' <<<"$OUT" 2>/dev/null)"
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
check "set on exits 1" 1 "$STATUS"
says "and says why" "jayos-denoise: easyeffects is not installed" "$OUT"
OUT=$(run "$ENGINE" apply on 2>&1); STATUS=$?
check "apply on exits 0" 0 "$STATUS"
check "and says nothing: this runs at every login" "" "$OUT"
WITHOUT=""

fresh; mkdir -p "$DATA"; clear_log
WITHOUT=socat
OUT=$(run "$ENGINE" set on 2>&1); STATUS=$?
WITHOUT=""
check "set on without socat, nothing running: exits 1" 1 "$STATUS"
says "naming socat" "jayos-denoise: socat is not installed" "$OUT"
check "and starts nothing" "" "$(started)"
if [[ ! -e "$FILE" ]]; then
    pass "and writes nothing, as when the plugin is missing"
else
    bad "set on without socat wrote $FILE"
fi

# ── run through a symlink ────────────────────────────────────────────────────
#
# New here. The package installs the engine and its library side by side in
# /usr/lib/jayos-denoise and puts a relative symlink in /usr/bin
# (packaging/steps.sh package). The engine finds the library, and reads its
# own strength table, through realpath of itself; the directory a symlink
# sits in holds neither. Laid out here as the package lays it out, and run
# the way PATH runs it -- executed, not handed to bash -- plus a symlink to
# the checkout's own file from somewhere else.
echo
echo "run through a symlink"

PKG="$WORK/pkg"
mkdir -p "$PKG/usr/lib/jayos-denoise" "$PKG/usr/bin" "$WORK/elsewhere"
install -m 0755 "$ENGINE" "$PKG/usr/lib/jayos-denoise/jayos-denoise"
install -m 0644 "$LIB" "$PKG/usr/lib/jayos-denoise/easyeffects-lib.sh"
ln -s ../lib/jayos-denoise/jayos-denoise "$PKG/usr/bin/jayos-denoise"
ln -s "$ENGINE" "$WORK/elsewhere/jayos-denoise"

for link in "$PKG/usr/bin/jayos-denoise" "$WORK/elsewhere/jayos-denoise"; do
    where=${link#"$WORK"/}
    fresh; mkdir -p "$DATA"; up; current ""; clear_log
    OUT=$(run -c 'exec "$@"' _ "$link" strengths 2>&1); STATUS=$?
    check "$where strengths exits 0" 0 "$STATUS"
    check "and reads the strength table of the file it points at" "$ARM_NAMES" "$(paste -sd, - <<<"$OUT")"
    OUT=$(run -c 'exec "$@"' _ "$link" status 2>&1); STATUS=$?
    check "$where status exits 0, its library found" 0 "$STATUS"
    check "and answers from it" "true true" "$(jq -r '[.installed, .running] | map(tostring) | join(" ")' <<<"$OUT" 2>/dev/null)"
    OUT=$(run -c 'exec "$@"' _ "$link" set on gentle 2>&1); STATUS=$?
    check "$where set on gentle exits 0" 0 "$STATUS"
    check "and the daemon holds ours" denoise "$(cat "$WORK/fake_current" 2>/dev/null)"
done
OUT=$(run -c 'exec "$@"' _ "$PKG/usr/bin/jayos-denoise" bogus 2>&1)
says "its usage names the command it was run as" "usage: jayos-denoise status" "$OUT"

# New here: the engine with no library beside it -- a package whose
# easyeffects-lib.sh is gone, which `pacman -Qkk` would show. It carried on
# without one, every ee_ function "command not found", and status exited 0
# with installed:false: "EasyEffects is not installed", said with confidence
# about a machine that has it, and jayos's wrapper passes a successful
# status through as the engine's answer. Found by breaking the symlink case
# above; a refusal is the honest answer, and the wrapper answers for itself
# when the engine fails.
mkdir -p "$WORK/alone"
install -m 0755 "$ENGINE" "$WORK/alone/jayos-denoise"
fresh; mkdir -p "$DATA"; up; clear_log
OUT=$(run "$WORK/alone/jayos-denoise" status 2>/dev/null); STATUS=$?
check "without its library, status exits 1" 1 "$STATUS"
check "and prints no JSON a reader could take for an answer" "" "$OUT"
OUT=$(run "$WORK/alone/jayos-denoise" status 2>&1 >/dev/null)
says "saying which file it could not load" "jayos-denoise: could not load $WORK/alone/easyeffects-lib.sh" "$OUT"
OUT=$(run "$WORK/alone/jayos-denoise" set on 2>&1); STATUS=$?
check "and set on exits 1 too" 1 "$STATUS"
log_lacks "having started nothing" "setsid"

# ── docs/DEEPFILTERNET.md's strength table ───────────────────────────────────
#
# The table is a transcription of strength_params(), and a transcription rots.
# The first six numbers of each row, in the order the function names them.
# (jayos's 3316-3343, which held docs/AUDIO.md's copy of this table; the
# table moved here with the engine.) A missing doc is a defect in the tree,
# not something this machine lacks, so it fails: it was once an uncounted
# note, and the comparison silently did not happen.
arm_numbers() { # arm_numbers <name> -> "24 -15 30 20 0 0.02"
    grep -E "^\s*$1\)" <<<"$ARMS" | head -1 \
        | grep -oE '=-?[0-9]+(\.[0-9]+)?' | tr -d '=' \
        | sed -E 's/^(-?[0-9]+)\.0+$/\1/' | tr '\n' ' ' | sed 's/ $//'
}
echo
echo "docs/DEEPFILTERNET.md's strength table"
if [[ ! -f "$DOC" ]]; then
    bad "docs/DEEPFILTERNET.md is not in the tree, so its strength table cannot be compared with the engine"
else
    while IFS= read -r s; do
        ROW=$(grep -iE "^\|[[:space:]]*\**$s\**[[:space:]]*\|" "$DOC" | head -1)
        if [[ -z "$ROW" ]]; then
            bad "docs/DEEPFILTERNET.md has no table row for $s"
            continue
        fi
        # The docs may spell the minus sign as U+2212; the shell does not.
        DOC_NUMS=$(sed 's/\xe2\x88\x92/-/g' <<<"$ROW" | cut -d'|' -f3- \
                   | grep -oE -- '-?[0-9]+(\.[0-9]+)?' | head -6 | tr '\n' ' ' | sed 's/ $//')
        check "docs/DEEPFILTERNET.md's $s row states the engine's numbers" "$(arm_numbers "$s")" "$DOC_NUMS"
    done < <(tr ',' '\n' <<<"$ARM_NAMES")
fi

# ── the whole run ────────────────────────────────────────────────────────────
#
# New here: across every case above, the engine detached nothing but
# EasyEffects itself and never reached for a session bus, the compositor or
# the session manager. Each case's own log is cleared by the next; these two
# are not.
echo
echo "across the whole run"

fresh
check "nothing was detached but easyeffects" "" "$(cat "$WORK/stray.log" 2>/dev/null)"
check "and gdbus, hyprctl and uwsm were never called" "" "$(cat "$WORK/session.log" 2>/dev/null)"

echo
SKIPPED=""
(( SKIP > 0 )) && SKIPPED=", $SKIP not exercised"
printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$SKIPPED"
(( FAIL == 0 ))
