#!/usr/bin/env bash
#
# Source guards: properties of the shipped scripts that no behavioural test
# can hold, because each is about what the code never says.
#
#   tests/shell/test-source-guards.sh
#
# Exit 0: every guard holds. 1: one does not -- or the lines a guard is about
# could not be found, which is reported as a failure, never as a pass: a grep
# for something forbidden passes over a file that is missing, emptied or
# rewritten past recognition, and that pass would be evidence of nothing.
# There is no exit 2. Everything here needs only bash, sed, grep and awk, and
# a file this tree ships being absent is a defect in the tree, not a tool the
# machine lacks.
#
# The seven guards, each with its reason where it runs:
#
#   1. src/jayos-denoise reads no settings.
#   2. Never the global bypass, never the command line's -b or -l, never
#      hide_window.
#   3. The library's copy has no path back into jayos.
#   4. The engine sources its library from its own resolved directory, and
#      nothing else.
#   5. packaging/steps.sh: the cargo flags that pick the full model and pin
#      the dependencies, no release-lto, no `| grep -q` (nor in the engine or
#      the library, which run under the same pipefail).
#   6. packaging/arch/PKGBUILD runs no cargo of its own.
#   7. packaging/patches/ changes the plugin's code and tests and nothing
#      else, and each patch gives its reason and is named in the document.
#
# Guard 2 overlaps tests/shell/test-engine.sh's "what the code never does",
# which strips whole-line comments only; this one strips trailing ones too and
# refuses to pass over code it could not find. Guard 1 has a behavioural
# counterpart there -- a settings.json where jayos keeps one changes nothing
# -- and is the half that holds for the code paths no case drives.
#
# COMMENTS ARE STRIPPED BEFORE EVERY GREP, whole-line and trailing. The
# engine's header names settings.json, micDenoise, `easyeffects -b` and
# global_bypass in prose, at length, because it explains why the code never
# does those things; the library's header names hypr/denoise.sh and
# toggle_global_bypass; steps.sh's comments name release-lto and `grep -q`. A
# grep over the raw files would fail on the explanations, and a grep for a
# positive line (the HERE assignment, say) would be satisfied by a comment
# quoting it over a tree where the code was deleted.
#
# The stripping is textual, not a shell parser: a `#` after whitespace ends
# the line. That is right for every line of the four files today (each `#`
# after code on a line is a real comment -- checked by reading every such
# line when this was written), and would be wrong for a quoted string holding
# " #" -- which would lose its tail, never gain one: the cut falls where
# the original had whitespace, and every pattern here treats a line's end
# as it treats whitespace, so it can make a positive guard fail and cannot
# make a negative guard trip. Lines inside a
# heredoc that open with `#` would be dropped the same way; the one heredoc
# here, the engine's preset, has none.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-denoise"
LIB="$ROOT/src/easyeffects-lib.sh"
STEPS="$ROOT/packaging/steps.sh"
RECIPE="$ROOT/packaging/arch/PKGBUILD"

PASS=0
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The offending lines under a failure, so it says where without a second run.
show() { sed -n '1,5s/^/         | /p' <<<"$1"; }

# code <file>: the file with its comments gone and its continued lines joined.
#
# Whole-line comments first, then trailing ones (a `#` after a space or tab),
# THEN the joining: bash does not continue a comment that ends in a
# backslash, so joining first would glue the next code line onto a comment
# and delete both. Joined because steps.sh splits `cargo tree` over two
# lines, and a flag on the second line is still a flag of the command.
code() { # code <file>
    sed -E '/^[[:space:]]*#/d; s/[[:space:]]+#.*$//' "$1" \
        | sed -E -e ':join' -e '/\\$/ { N; s/\\\n[[:space:]]*/ /; b join' -e '}'
}

# Read once. A missing file reads as no code, and every guard over it then
# says it examined nothing.
read_code() { # read_code <file> <label>
    if [[ -f "$1" ]]; then
        code "$1"
    else
        echo "  $2 is missing" >&2
    fi
}
ENGINE_CODE=$(read_code "$ENGINE" src/jayos-denoise)
LIB_CODE=$(read_code "$LIB" src/easyeffects-lib.sh)
STEPS_CODE=$(read_code "$STEPS" packaging/steps.sh)
RECIPE_CODE=$(read_code "$RECIPE" packaging/arch/PKGBUILD)

# found <label> <code> <ERE> <what>: 0 when the anchor is there. Every
# negative guard below asks this first, about the lines its question is
# about; a guard whose target is gone fails here rather than passing.
found() {
    if grep -qE "$3" <<<"$2"; then
        return 0
    fi
    bad "$1: $4 could not be found; this check examined nothing"
    return 1
}

# lacks <label> <code> <ERE> <sentence>: pass when no code line matches.
lacks() {
    local hits
    hits=$(grep -E "$3" <<<"$2")
    if [[ -z "$hits" ]]; then
        pass "$1: $4"
    else
        bad "$1: not true that $4"
        show "$hits"
    fi
}

# The engine's dispatch and the library's first request function: what every
# guard over those two files needs to see before it may say anything.
ENGINE_ANCHOR='^case "\$\{1:-status\}" in$'
LIB_ANCHOR='^ee_installed\(\)'

# ── 1. the engine reads no settings ──────────────────────────────────────────
#
# WHY. Whether noise suppression SHOULD be on is a person's setting, and it
# belongs to whatever draws the switch -- jayos's
# config/common/scripts/hypr/denoise.sh owns micDenoise and
# micDenoiseStrength and hands this engine `apply on|off <strength>`. The
# engine at jayos bf53d6a sourced "$HERE/../settings.sh" and asked
# `setting micDenoise false` and `setting_strength`, and used QS_TERMINAL; a
# package that still did any of that would break the day jayos moved its
# settings file, and would read a file no other desktop has. The library is
# held to the same, since it runs inside the engine.
#
# The patterns are those reads as they were written: the file names, the
# helper (`setting ` and `setting_`, after a non-word character so that
# ee_apply_noise_setting is not one), the two keys, and any QS_ variable.
echo "the engine reads no settings"
SETTINGS_RE='settings\.(json|sh)|(^|[^[:alnum:]_])setting([[:space:]_]|$)|micDenoise|(^|[^[:alnum:]_])QS_[[:alnum:]_]'
if found "src/jayos-denoise" "$ENGINE_CODE" "$ENGINE_ANCHOR" "its verb dispatch"; then
    lacks "src/jayos-denoise" "$ENGINE_CODE" "$SETTINGS_RE" \
        "no code line names settings.json, settings.sh, setting, micDenoise or a QS_ variable"
fi
if found "src/easyeffects-lib.sh" "$LIB_CODE" "$LIB_ANCHOR" "ee_installed()"; then
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$SETTINGS_RE" \
        "no code line names settings.json, settings.sh, setting, micDenoise or a QS_ variable"
fi

# ── 2. never the global bypass, never the command line ──────────────────────
#
# WHY. The engine's rule 2: the global bypass is both pipelines at once, and
# muting the microphone's filter with it would silence the speakers'
# equaliser too. Off is "bypass": true inside our own preset. So no
# `global_bypass:<0|1>` and no `toggle_global_bypass` is ever written to the
# socket -- while `get_global_bypass`, the library's QUESTION, is allowed,
# which is why the pattern wants a non-word character before global_bypass.
#
# And never `easyeffects -b` or `-l` (or --bypass, --load-preset): at v8.2.9
# both also send hide_window (the library's header, citing upstream's
# src/command_line_parser.cpp:201 and :229), so every toggle closed an
# EasyEffects window somebody had open. Everything goes through the socket,
# where nothing sends hide_window either. The flag may come after other
# arguments, so the pattern allows any between `easyeffects` and it, up to
# the end of the command.
echo
echo "never the global bypass, never the command line"
BYPASS_RE='toggle_global_bypass|(^|[^[:alnum:]_])global_bypass([^[:alnum:]_]|$)|hide_window'
CLI_RE='(^|[^[:alnum:]_./-])easyeffects([[:space:]]+[^;&|)[:space:]]+)*[[:space:]]+(-[[:alnum:]]*[bl][[:alnum:]]*|--bypass|--load-preset)([[:space:]=]|$)'
if found "src/jayos-denoise" "$ENGINE_CODE" "$ENGINE_ANCHOR" "its verb dispatch" \
   && found "src/jayos-denoise" "$ENGINE_CODE" 'ee_load_preset input' "the load it sends through the library"; then
    lacks "src/jayos-denoise" "$ENGINE_CODE" "$BYPASS_RE" \
        "no code line writes global_bypass, toggle_global_bypass or hide_window"
    lacks "src/jayos-denoise" "$ENGINE_CODE" "$CLI_RE" \
        "no code line runs easyeffects -b, -l, --bypass or --load-preset"
fi
if found "src/easyeffects-lib.sh" "$LIB_CODE" '^ee_socket\(\)' "ee_socket(), where every request is written,"; then
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$BYPASS_RE" \
        "no code line writes global_bypass, toggle_global_bypass or hide_window"
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$CLI_RE" \
        "no code line runs easyeffects -b, -l, --bypass or --load-preset"
fi

# ── 3. the library's copy has no path back into jayos ───────────────────────
#
# WHY. src/easyeffects-lib.sh is jayos's config/common/scripts/
# easyeffects-lib.sh at bf53d6a with two edits, and one of them is that
# ee_apply_noise_setting is gone: it ran
#   setsid -f bash "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/hypr/denoise.sh" apply
# -- a path relative to the library, which here is /usr/lib/jayos-denoise/
# hypr/denoise.sh, a file no package installs; and if one did, it would be
# jayos's wrapper, which calls this engine, which would be a loop. A carried
# fix that brought the function back would fail silently: setsid -f reports
# nothing. The engine is held to the same, since its own comment names the
# function (and must not trip this).
echo
echo "no path back into jayos"
JAYOS_RE='ee_apply_noise_setting|denoise\.sh'
if found "src/easyeffects-lib.sh" "$LIB_CODE" '^ee_ensure_running\(\)' "ee_ensure_running(), the function the removed one followed,"; then
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$JAYOS_RE" \
        "no code line names ee_apply_noise_setting or denoise.sh"
fi
if found "src/jayos-denoise" "$ENGINE_CODE" "$ENGINE_ANCHOR" "its verb dispatch"; then
    lacks "src/jayos-denoise" "$ENGINE_CODE" "$JAYOS_RE" \
        "no code line names ee_apply_noise_setting or denoise.sh"
fi

# ── 4. the library comes from the engine's own resolved directory ───────────
#
# WHY. The package installs the engine at /usr/lib/jayos-denoise/jayos-denoise
# with its library beside it, and /usr/bin/jayos-denoise is a symlink to it
# (packaging/steps.sh, step_package). Run through the link, BASH_SOURCE is
# /usr/bin/jayos-denoise: a directory taken from it without realpath is
# /usr/bin, where there is no library, and a checkout's src/ would work and
# hide that. So HERE must be the realpath's directory, assigned once, before
# the one source line, which must source the library from HERE and nothing
# else -- not jayos's settings.sh (guard 1's reason), not a fixed
# /usr/lib path that a checkout does not have. And the library itself
# sources nothing: whatever it pulled in would run inside the engine too.
echo
echo "the library comes from the engine's own resolved directory"
# A source or `.` at the start of a command: line start, or after ; & | ( {.
SOURCE_RE='(^|[;&|({])[[:space:]]*(source|\.)[[:space:]]+[^[:space:]]'
HERE_SET_RE='(^|[;&|[:space:]])(local[[:space:]]+|readonly[[:space:]]+|export[[:space:]]+|declare([[:space:]]+-[[:alpha:]]+)*[[:space:]]+)?HERE='
HERE_REALPATH_RE='^HERE="?\$\(dirname "\$\(realpath "\$\{BASH_SOURCE(\[0\])?\}"\)"\)"?$'
LIB_SOURCE_RE='^(source|\.)[[:space:]]+"?\$\{?HERE\}?/easyeffects-lib\.sh"?([[:space:]]|$)'
sources=$(grep -nE "$SOURCE_RE" <<<"$ENGINE_CODE")
sets=$(grep -nE "$HERE_SET_RE" <<<"$ENGINE_CODE")
if [[ -z "$sources" ]]; then
    bad "src/jayos-denoise: a source line could not be found; this check examined nothing"
else
    n=$(grep -c . <<<"$sources")
    if (( n == 1 )); then
        pass "src/jayos-denoise: exactly one code line sources anything"
    else
        bad "src/jayos-denoise: $n code lines source something, where one should"
        show "$sources"
    fi
    if grep -qE "^[0-9]+:[[:space:]]*${LIB_SOURCE_RE#^}" <<<"$sources" && (( n == 1 )); then
        pass "and it is \$HERE/easyeffects-lib.sh"
    else
        bad "src/jayos-denoise sources something other than \$HERE/easyeffects-lib.sh"
        show "$sources"
    fi
    if [[ -z "$sets" ]]; then
        bad "src/jayos-denoise: the HERE assignment could not be found; this check examined nothing"
    else
        m=$(grep -c . <<<"$sets")
        here_line=${sets%%:*}
        here_text=$(sed -E 's/^[0-9]+:[[:space:]]*//' <<<"$sets")
        if (( m != 1 )); then
            bad "HERE is assigned on $m code lines, where one should"
            show "$sets"
        elif grep -qE "$HERE_REALPATH_RE" <<<"$here_text"; then
            pass "HERE is assigned once, as the directory of realpath \"\${BASH_SOURCE[0]}\""
        else
            bad "HERE is not the directory of realpath \"\${BASH_SOURCE[0]}\""
            show "$here_text"
        fi
        if (( m == 1 && here_line < ${sources%%:*} )); then
            pass "and before the library is sourced"
        else
            bad "HERE is not assigned once before the library is sourced"
        fi
    fi
fi
if found "src/easyeffects-lib.sh" "$LIB_CODE" "$LIB_ANCHOR" "ee_installed()"; then
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$SOURCE_RE" "sources nothing"
fi

# ── 5. packaging/steps.sh: the flags that pick the model ────────────────────
#
# WHY. Both recipes call steps.sh, so a flag here reaches both, and the drift
# it guards is silent: without --no-default-features the fork builds the
# low-latency model, and the package installs and loads exactly as before.
# `check` proves the built .so (the inverted feature tree and the embedded
# tarballs), but only of what was built with check's own flags -- so each of
# build, tree and test has to carry the same three: -p deep-filter-ladspa,
# --no-default-features and --frozen (the lockfile is the pin for
# everything the commit id does not cover, and the network is fetch's
# alone). fetch has --locked. Nothing names release-lto: that profile has
# panic = "abort", and the plugin catches the panic an unsupported sample
# rate raises -- an abort would take the sound server with it (steps.sh,
# step_build).
#
# And no pipe into `grep -q`: grep -q exits at the first match, the producer
# takes a SIGPIPE writing the rest, and under steps.sh's pipefail that 141
# failed `nm -D ... | grep -q ladspa_descriptor` over a .so that exports it
# -- RUN against the built plugin, whose nm -D list is 117 lines, two of
# them exported and the other 115 imports (steps.sh, check_plugin). The
# engine and the library run under the same pipefail and are held to it as
# well. Read whole, then searched: `<<<"$var"`.
#
# A cargo command is found where a command starts -- line start, or after
# ; & | ( { or $( -- so `die "cargo build failed"` is a message and not one;
# its flags are read up to the end of that command, so a flag spelled in a
# message on the same line cannot stand in for one on the command.
echo
echo "packaging/steps.sh: the flags that pick the model"
CARGO_RE='(^|[;&|({])[[:space:]]*cargo[[:space:]][^;&|)]*'
has_flag() { grep -qE "(^|[[:space:]])$2([[:space:]]|\$)" <<<"$1"; }
if found "packaging/steps.sh" "$STEPS_CODE" "$CARGO_RE" "a cargo command"; then
    declare -A SEEN=()
    while IFS= read -r cmd; do
        cmd=$(sed -E 's/^[;&|({[:space:]]*//; s/[[:space:]]+$//' <<<"$cmd")
        # The subcommand: the first word after cargo that is not an option.
        sub=$(awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^[-+]/) { print $i; exit } }' <<<"$cmd")
        SEEN[$sub]=1
        case "$sub" in
            build|tree|test)
                missing=()
                grep -qE '(^|[[:space:]])(-p|--package)([[:space:]]+|=)deep-filter-ladspa([[:space:]]|$)' <<<"$cmd" \
                    || missing+=("-p deep-filter-ladspa")
                has_flag "$cmd" --no-default-features || missing+=(--no-default-features)
                has_flag "$cmd" --frozen || missing+=(--frozen)
                if (( ${#missing[@]} == 0 )); then
                    pass "cargo $sub has -p deep-filter-ladspa, --no-default-features and --frozen"
                else
                    bad "cargo $sub lacks ${missing[*]}"
                    show "$cmd"
                fi
                ;;
            fetch)
                if has_flag "$cmd" --locked; then
                    pass "cargo fetch has --locked"
                else
                    bad "cargo fetch lacks --locked"
                    show "$cmd"
                fi
                ;;
            *)
                # A subcommand nothing above examines is a cargo call no
                # flag of this guard was checked on.
                bad "cargo ${sub:-<none>} is a cargo command this guard does not examine"
                show "$cmd"
                ;;
        esac
    done < <(grep -oE "$CARGO_RE" <<<"$STEPS_CODE")
    for sub in fetch build tree test; do
        [[ -n "${SEEN[$sub]:-}" ]] \
            || bad "packaging/steps.sh: cargo $sub could not be found; this check examined nothing"
    done
    lacks "packaging/steps.sh" "$STEPS_CODE" 'release-lto' "no code line names release-lto"
fi
# `|` but not `||`, then grep with -q, --quiet or --silent among its options.
GREPQ_RE='(^|[^|])\|[[:space:]]*(LC_ALL=[^[:space:]]*[[:space:]]+)?grep([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(-[[:alnum:]]*q[[:alnum:]]*|--quiet|--silent)([[:space:]]|$)'
if found "packaging/steps.sh" "$STEPS_CODE" '(^|[^[:alnum:]_])nm -D ' "the nm -D read of the dynamic symbols"; then
    lacks "packaging/steps.sh" "$STEPS_CODE" "$GREPQ_RE" "nothing is piped into grep -q"
fi
if found "src/jayos-denoise" "$ENGINE_CODE" "$ENGINE_ANCHOR" "its verb dispatch"; then
    lacks "src/jayos-denoise" "$ENGINE_CODE" "$GREPQ_RE" "nothing is piped into grep -q"
fi
if found "src/easyeffects-lib.sh" "$LIB_CODE" "$LIB_ANCHOR" "ee_installed()"; then
    lacks "src/easyeffects-lib.sh" "$LIB_CODE" "$GREPQ_RE" "nothing is piped into grep -q"
fi

# ── 6. the checkout recipe runs no cargo of its own ─────────────────────────
#
# WHY. Two recipes build this package -- packaging/arch/PKGBUILD and jayos's
# pkgbuilds/jayos-denoise/PKGBUILD -- and the whole point of steps.sh is that
# neither spells out a flag. A `cargo build` written into this recipe's
# build() would be a second copy of guard 5's flags that guard 5 does not
# read, and the two recipes would build different plugins with nothing
# failing. So: no word `cargo` in any function body, no cargo command
# anywhere in the file (makedepends=('cargo') is a package name, not a
# command), and each of makepkg's four functions goes through _steps, which
# runs packaging/steps.sh.
echo
echo "packaging/arch/PKGBUILD runs no cargo of its own"
# Every function, one-line or not, each line prefixed with its name.
BODIES=$(awk '
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
        fn = $0; sub(/\(\).*/, "", fn); gsub(/[[:space:]]/, "", fn)
        print fn ": " $0
        open = ($0 !~ /\}[[:space:]]*$/)
        next
    }
    open { print fn ": " $0; if ($0 ~ /^\}/) open = 0 }
' <<<"$RECIPE_CODE")
fns_found=()
for fn in prepare build check package; do
    grep -q "^$fn: " <<<"$BODIES" && fns_found+=("$fn")
done
if (( ${#fns_found[@]} == 0 )); then
    bad "packaging/arch/PKGBUILD: prepare, build, check and package could not be found; this check examined nothing"
else
    if (( ${#fns_found[@]} == 4 )); then
        pass "prepare, build, check and package are all there to read"
    else
        bad "of prepare, build, check and package, only ${fns_found[*]} could be found"
    fi
    lacks "packaging/arch/PKGBUILD" "$BODIES" '(^|[^[:alnum:]_-])cargo([^[:alnum:]_-]|$)' \
        "no function body names cargo"
    lacks "packaging/arch/PKGBUILD" "$RECIPE_CODE" "$CARGO_RE" "no cargo command anywhere in the file"
    for fn in "${fns_found[@]}"; do
        if grep -E "^$fn: " <<<"$BODIES" | grep -qE '(^|[[:space:]])_steps[[:space:]]+[a-z]+'; then
            pass "$fn() goes through _steps"
        else
            bad "$fn() does not call _steps"
        fi
    done
    if grep -E '^_steps: ' <<<"$BODIES" | grep -qE 'packaging/steps\.sh'; then
        pass "and _steps runs packaging/steps.sh"
    else
        bad "_steps could not be found running packaging/steps.sh; the functions' calls examined nothing"
    fi
fi

# ── 7. the patches change the plugin's code and tests, and nothing else ─────
#
# WHY. steps.sh proves which model is inside the .so from the resolved
# feature tree and from the .so's own bytes, and pins every dependency with
# --locked and --frozen; a patch is applied before all of it. One that
# touched a Cargo.toml could turn the low-latency model back on or add a
# crate, one that touched Cargo.lock would move what --locked pins with no
# proof noticing, and one that touched models/ would change the tarball the
# .so is compared against. So a patch may change files under ladspa/src/ and
# ladspa/tests/ -- the plugin and its tests -- and no other. And each says
# why in its own header, a Subject: line as git format-patch writes one, and
# docs/DEEPFILTERNET.md names it: the document says what the plugin is, and a
# patch it did not name would be a plugin it does not describe. A tree with
# no patch fails here, because then this guard examined nothing; whoever
# removes the last patch removes this guard with it.
echo
echo "packaging/patches/: the plugin's code and tests, and nothing else"
DOC="$ROOT/docs/DEEPFILTERNET.md"
PATCH_FILES=()
for p in "$ROOT"/packaging/patches/*.patch; do
    [[ -f "$p" ]] && PATCH_FILES+=("$p")
done
# One name per line, for the lines that list what a patch touched.
joined() { awk 'NR > 1 { printf "," } { printf "%s", $0 } END { print "" }'; }
if (( ${#PATCH_FILES[@]} == 0 )); then
    bad "packaging/patches/ holds no patch; this guard examined nothing"
else
    for p in "${PATCH_FILES[@]}"; do
        name=${p##*/}
        touched=$(sed -n -E 's|^diff --git a/([^ ]+) b/.*$|\1|p; s|^\+\+\+ b/(.*)$|\1|p' "$p" | awk '!seen[$0]++')
        if [[ -z "$touched" ]]; then
            bad "$name names no file; it is no patch git apply would read"
            continue
        fi
        outside=$(grep -vE '^ladspa/(src|tests)/' <<<"$touched") || true
        if [[ -z "$outside" ]]; then
            pass "$name changes only $(joined <<<"$touched")"
        else
            bad "$name changes what no patch may: $(joined <<<"$outside")"
        fi
        if grep -qE '^Subject: .+' "$p"; then
            pass "$name says what it does in a Subject: line"
        else
            bad "$name has no Subject: line; git format-patch writes one, with the reason under it"
        fi
        if [[ -f "$DOC" ]] && grep -qF "$name" "$DOC"; then
            pass "docs/DEEPFILTERNET.md names $name"
        else
            bad "docs/DEEPFILTERNET.md does not name $name"
        fi
    done
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
