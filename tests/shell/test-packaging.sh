#!/usr/bin/env bash
#
# The checkout recipe, packaging/arch/PKGBUILD, without makepkg.
#
#   tests/shell/test-packaging.sh
#
# Exit 0: every case passed. 1: a case failed. There is no exit 2: nothing
# here needs more than bash, sed, grep, awk and coreutils, so there is no
# machine that can start this suite and not run all of it.
#
# makepkg is an Arch tool and this suite has to run where it is not. So the
# recipe is sourced and read the way makepkg reads it, and each of its
# functions is called the way makepkg calls one -- under errexit and errtrace,
# with startdir, srcdir and pkgdir set -- in a scratch tree whose
# packaging/steps.sh is a stub that records what it was asked and fails when
# told to. The stub, not the real script, because what the recipe owns is
# where its sources come from and which steps it calls in what order; every
# build flag, proof and installed path is packaging/steps.sh's, and
# tests/shell/test-steps.sh holds those against fakes.
#
# depends= is held both ways to what the package runs: the plugin's half to
# the NEEDED check in steps.sh, the engine's to the commands a small shell
# lexer reads out of src/jayos-denoise and src/easyeffects-lib.sh.
#
# What this does NOT prove, and is read rather than run: that makepkg accepts
# the file (no makepkg or namcap here), that the source=() line clones, and
# that makepkg's run_function_safe gives a function the same errexit and
# errtrace that `bash -eE` gives it here; nor which package installs each
# command, which is this suite's table, read and not asked of pacman (there
# is none here to ask).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPE="$ROOT/packaging/arch/PKGBUILD"
STEPS_TXT="$ROOT/contract/steps.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/denoise-packaging-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Sourced in a subshell for each question, so nothing it sets leaks into the
# next case. startdir is the real one here; the function runs below point it
# at a scratch tree instead.
recipe() { ( set +u; startdir="$ROOT/packaging/arch"; source "$RECIPE"; eval "$1" ); }

# The recipe with its comments stripped, for the questions a sourced recipe
# cannot answer (how many lines assign the pin, which steps the text calls).
# Without the strip, the header's own `_commit` prose and a commented-out
# `_steps` line would satisfy the checks written to find the real ones. A `#`
# counts as a comment only at the start of a line or after a space, which is
# also what keeps source=()'s `.git#commit=` intact.
CODE=$(sed -E 's/(^|[[:space:]])#.*$//' "$RECIPE")

# has <array-name> <value>: is <value> one of the recipe's <array-name>?
has() { recipe "for v in \"\${$1[@]}\"; do [[ \$v == '$2' ]] && exit 0; done; exit 1"; }

echo "the recipe"

if bash -n "$RECIPE"; then
    pass "it parses"
else
    bad "it does not parse"
fi

# Every function the recipe defines is one this suite runs below, or one of
# the two helpers they share. A pkgver() or a split package_*() added later
# would otherwise be a function makepkg calls and nothing here has ever run.
fns=$(env -i PATH="$PATH" bash --norc --noprofile -c \
          'startdir=$1; source "$2"; declare -F | sed "s/^declare -f //"' _ "$ROOT/packaging/arch" "$RECIPE" \
      | sort | tr '\n' ' ')
if [[ "$fns" == "_steps _tree build check package prepare " ]]; then
    pass "its functions are prepare, build, check and package, and the two helpers they share"
else
    bad "its functions are '$fns'; this suite runs prepare, build, check and package and knows of no others"
fi

if [[ "$(recipe 'printf %s "$pkgname"')" == "jayos-denoise" ]]; then
    pass "pkgname is jayos-denoise"
else
    bad "pkgname is '$(recipe 'printf %s "$pkgname"')', not jayos-denoise"
fi

# THE VERSION IS VERSION's. Written out rather than computed -- the recipe
# says why a pkgver() would rewrite it on every build -- so it is held here.
version=$(tr -d '[:space:]' < "$ROOT/VERSION")
pkgver=$(recipe 'printf %s "$pkgver"')
if [[ -n "$version" && "$pkgver" == "$version" ]]; then
    pass "pkgver is VERSION ($version)"
else
    bad "pkgver '$pkgver' is not VERSION '$version'"
fi

# THE PIN, read three ways that have to agree: this suite's own reading of
# the text, bash's (the sourced value, which is what source=() expands), and
# packaging/steps.sh's (what JayOS's recipe checks out). The text is read
# here rather than trusted to `steps.sh pin`, so a fault in that reader
# cannot hide a fault in the line; tests/shell/test-steps.sh holds the reader.
pin_lines=$(grep -E '^[[:space:]]*_commit=' <<<"$CODE")
pin_count=$(grep -c . <<<"$pin_lines")
pin_text=$(sed -E "s/^[[:space:]]*_commit=//; s/[[:space:]]+\$//; s/['\"]//g" <<<"$pin_lines")
if [[ "$pin_count" -eq 1 ]]; then
    pass "_commit is assigned on exactly one line"
else
    bad "_commit is assigned on $pin_count lines; steps.sh refuses anything but one"
fi
if [[ "$pin_count" -eq 1 && "$pin_text" =~ ^[0-9a-f]{40}$ ]]; then
    pass "_commit is forty lowercase hex digits ($pin_text)"
else
    bad "_commit reads '$pin_text', not a full forty-digit commit id"
fi
pin_sourced=$(recipe 'printf %s "$_commit"')
pin_steps=$(bash "$ROOT/packaging/steps.sh" pin 2>"$WORK/pin.err")
if [[ -n "$pin_text" && "$pin_sourced" == "$pin_text" && "$pin_steps" == "$pin_text" ]]; then
    pass "the sourced \$_commit and \`steps.sh pin\` are that same commit"
else
    bad "the pin disagrees: text '$pin_text', sourced '$pin_sourced', steps.sh pin '$pin_steps' $(cat "$WORK/pin.err")"
fi

# THE SOURCE: the fork, under the folder name both recipes and steps.sh use,
# at the pin -- through $_commit, so the pin stays one literal and a bump
# cannot move one line and not the other.
want_source="DeepFilterNetPlus::git+https://github.com/ismailivanov/DeepFilterNetPlus.git#commit=$pin_text"
sources=$(recipe 'printf "%s\n" "${source[@]}"')
if [[ "$sources" == "$want_source" ]]; then
    pass "source=() is the one fork clone, folder DeepFilterNetPlus, at #commit=\$_commit"
else
    bad "source=() is '$sources', not '$want_source'"
fi
if grep -qF '#commit=$_commit"' <<<"$CODE"; then
    pass "and it names the commit through \$_commit, not as a second literal"
else
    bad "source=() does not take its #commit= from \$_commit"
fi
# SKIP for a git source is the convention, not a hole: makepkg cannot
# checksum a clone, and git verifies every object against the commit id.
if [[ "$(recipe 'printf "%s\n" "${sha256sums[@]}"')" == "SKIP" ]]; then
    pass "sha256sums=() is SKIP, one entry for the one source"
else
    bad "sha256sums=() is '$(recipe 'printf "%s " "${sha256sums[@]}"')', not the one SKIP"
fi

if [[ "$(recipe 'printf "%s\n" "${arch[@]}"')" == "x86_64" ]]; then
    pass "arch=() is x86_64"
else
    bad "arch=() is '$(recipe 'printf "%s " "${arch[@]}"')', not x86_64"
fi

# Every packaging of the plugin provides and conflicts on this name, the
# retired deepfilternet-ladspa recipe in JayOS among them: without both, the
# two packages would each own /usr/lib/ladspa/libdeep_filter_ladspa.so.
for a in provides conflicts; do
    if has "$a" libdeep_filter_ladspa; then
        pass "$a=() names libdeep_filter_ladspa"
    else
        bad "$a=() does not name libdeep_filter_ladspa"
    fi
done

# The recipe's own header says why each of these is there; what is held here
# is that they are.
for o in '!lto' '!debug'; do
    if has options "$o"; then
        pass "options=() has $o"
    else
        bad "options=() lacks $o"
    fi
done
for m in cargo git; do
    if has makedepends "$m"; then
        pass "makedepends=() has $m"
    else
        bad "makedepends=() lacks $m"
    fi
done
# packaging/steps.sh's links_only_depends passes a .so whose NEEDED entries
# all belong to these two, and says so by naming them: a depends= without
# them would make that proof a proof about packages nothing installs.
for d in glibc gcc-libs; do
    if has depends "$d"; then
        pass "depends=() has $d, which steps.sh's NEEDED check is written against"
    else
        bad "depends=() lacks $d, which steps.sh's NEEDED check assumes it names"
    fi
done

# THE ENGINE'S HALF OF depends=, held to the commands the engine and its
# library run. The commands are read out of the code, not listed here; what
# this suite adds is only which package installs each one, which nothing in
# the code can say. Nothing held this half before: drop socat from depends=
# and the package installed where `set on` died "socat is not installed";
# drop jq and status died, which jayos's wrapper turns into its no-engine
# answer.
#
# The commands come from a small shell lexer (the awk program below), not a
# grep: a grep for "socat" is satisfied by the comment that explains why
# socat, and a list of command words by line is fooled by a message such as
# "...; pacman -Qkk jayos-denoise lists ...", where `pacman` follows a `;`
# inside quotes. The lexer knows quotes, $( ) and ${ } nested inside them,
# comments, heredocs, case patterns, [[ ]], (( )), assignments, redirections,
# and the wrappers that run the word after them (timeout, setsid, env), and
# reports three things: a command run, a command only probed with
# `command -v`, and a command word it cannot name because it is an expansion
# -- which no row below could tie to a package, so any is a failure. What it
# is NOT: a shell parser. RUN on 2026-10-04 with a stand-in command (curl)
# in each place: in a comment, in a double-quoted message after its `;`, in
# a heredoc and in a for-list it is not read as run; after $(, inside
# "$( )", |, &&, if and then, a case arm, [[ -n "$( )" ]], ${x:-$( )}, the
# $( ) in a for (( )), a subshell, a group, timeout 2, setsid -f and
# env -i A=1, it is; `command -v curl` is a probe and "$cmd" a dynamic
# word. A construct the two files do not use (eval, a $( ) inside a
# heredoc) is one it may miss.
read -r -d '' COMMANDS_AWK <<'AWK'
# Prints "run NAME", "probe NAME" and "dynamic FILE:LINE" for the commands
# the bash files it is given run. keywords= and builtins= come from the
# bash that runs the suite (compgen -k, compgen -b), so neither list is
# written out here to go stale.
#
# A stack of frames, one per context that changes what a word means: "cmd"
# (the top level, a $( ), a ( ) subshell, an array literal), "dq" (inside
# double quotes), "brace" (a ${ }), "arith" (a (( )) or $(( ))). Only a
# cmd frame has command words; the others are skipped except for the cmd
# frames nested in them, which is how "$(realpath ...)" is read and
# "a message; with a semicolon" is not.
function ch(k) { return substr(S, k, 1) }
function lineat(k,   t) { t = substr(S, 1, k); return gsub(/\n/, "", t) + 1 }
# A cmd frame starts its own word and gives the enclosing one back when it
# closes: `x=$(cmd arg)` is one word outside and two inside. Shared, the
# assignment's "x=" glued itself to `cmd` and hid it.
function push(t, o) {
    D++; T[D] = t; OP[D] = o; X[D] = (t == "cmd" && o != "arr"); M[D] = ""
    CD[D] = 0; R[D] = 0; WS[D] = 0; P[D] = 0; BD[D] = 0
    if (t == "cmd") {
        SCUR[D] = CUR; SINW[D] = INW; SBARE[D] = BARE; SASSIGN[D] = ASSIGN
        CUR = ""; INW = 0; BARE = 1; ASSIGN = 0
    }
}
function pop() {
    if (D <= 1) return
    if (T[D] == "cmd") {
        CUR = SCUR[D]; INW = SINW[D]; BARE = SBARE[D]; ASSIGN = SASSIGN[D]
    }
    D--
}
# ; & && || | and a newline: the next word is a command again -- except
# inside [[ ]], a for header, a case header or a case pattern, where those
# characters are operators or alternatives, not separators.
function sep() {
    if (M[D] == "test" || M[D] == "for" || M[D] == "case" || M[D] == "pat") return
    if (OP[D] == "arr") return
    M[D] = ""; X[D] = 1; R[D] = 0
}
# What the word just finished means. M[D] is the frame's mode: what the
# words after a keyword or a wrapper are, until a separator ends it.
function endword(   w, b, a) {
    if (!INW) return
    w = CUR; b = BARE; a = ASSIGN
    CUR = ""; INW = 0; BARE = 1; ASSIGN = 0
    if (R[D] == 2) { HD[++NHD] = w; R[D] = 0; return }   # a heredoc's delimiter
    if (R[D] == 1) { R[D] = 0; return }                  # a redirection's target
    if (M[D] == "pat") {
        if (b && w == "esac") { CD[D]--; M[D] = ""; X[D] = 0 }
        return
    }
    if (M[D] == "for") { if (b && w == "do") { M[D] = ""; X[D] = 1 }; return }
    if (M[D] == "case") { if (b && w == "in") M[D] = "pat"; return }
    if (M[D] == "test") { if (b && w == "]]") { M[D] = ""; X[D] = 0 }; return }
    if (M[D] == "fname") { FN[w] = 1; M[D] = ""; return }
    # `command -v NAME` asks whether NAME exists; it runs nothing.
    if (M[D] == "probe") {
        if (w ~ /^-/) return
        print "probe " w; M[D] = ""; X[D] = 0; return
    }
    if (M[D] == "builtin-command") {
        if (w == "-v" || w == "-V") { M[D] = "probe"; return }
        if (w ~ /^-/) return
        M[D] = ""; X[D] = 1
    }
    # A wrapper runs the word after its options (and, for timeout, after
    # its duration; for env, after its assignments).
    if (M[D] == "wrap") {
        if (w ~ /^-/ || (b && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) return
        if (WS[D] > 0) { WS[D]--; return }
        M[D] = ""; X[D] = 1
    }
    if (!X[D]) return
    if (a) return                     # NAME=value before the command
    if (!b) { print "dynamic " FNAME ":" lineat(i); X[D] = 0; return }
    if (w in KW) {
        if (w == "fi" || w == "done" || w == "}") X[D] = 0
        else if (w == "esac") { CD[D]--; M[D] = ""; X[D] = 0 }
        else if (w == "for" || w == "select") { M[D] = "for"; X[D] = 0 }
        else if (w == "case") { M[D] = "case"; CD[D]++; X[D] = 0 }
        else if (w == "function") { M[D] = "fname"; X[D] = 0 }
        else if (w == "[[") { M[D] = "test"; X[D] = 0 }
        return
    }
    X[D] = 0
    if (w in BI) {
        if (w == "command") M[D] = "builtin-command"
        else if (w == "exec") { M[D] = "wrap"; WS[D] = 0 }
        return
    }
    RUN[w] = 1
    if (w == "timeout") { M[D] = "wrap"; WS[D] = 1 }
    else if (w == "setsid" || w == "nohup" || w == "env" || w == "nice" || w == "stdbuf") {
        M[D] = "wrap"; WS[D] = 0
    }
}
# A heredoc's body is data -- the engine's preset is one, and its JSON is
# not commands. i sits just past the newline that ends the line holding the
# <<: skip each pending body, in order, through its delimiter line.
function heredocs(   line, j, h, strip) {
    for (h = 1; h <= NHD; h++) {
        while (i <= N) {
            j = index(substr(S, i), "\n")
            line = (j ? substr(S, i, j - 1) : substr(S, i))
            i += (j ? j : length(S) - i + 1)
            strip = line; sub(/^\t+/, "", strip)
            if (line == HD[h] || strip == HD[h]) break
        }
    }
    NHD = 0
}
# Past a $'...' string: a backslash escapes the next character, a quote ends it.
function ansi() {
    while (i <= N && ch(i) != "'") { if (ch(i) == "\\") i++; i++ }
    i++
}
# The frames that may hold a command inside them, wherever they appear.
function nested(c, nc) {
    if (c == "$" && nc == "(" && ch(i + 2) == "(") { push("arith", ""); i += 3; return 1 }
    if (c == "$" && nc == "(") { push("cmd", "$("); i += 2; return 1 }
    if (c == "$" && nc == "{") { push("brace", ""); i += 2; return 1 }
    return 0
}
function scan(text,   c, nc, j) {
    S = text; N = length(S); i = 1; D = 0; push("cmd", "top")
    CUR = ""; INW = 0; BARE = 1; ASSIGN = 0; NHD = 0
    while (i <= N) {
        c = ch(i); nc = ch(i + 1)
        if (T[D] == "dq") {
            if (c == "\\") { i += 2; continue }
            if (c == "\"") { pop(); i++; continue }
            if (nested(c, nc)) continue
            i++; continue
        }
        if (T[D] == "brace") {
            if (c == "\\") { i += 2; continue }
            if (c == "$" && nc == "'") { i += 2; ansi(); continue }
            if (c == "'") { j = index(substr(S, i + 1), "'"); i += (j ? j + 1 : N); continue }
            if (c == "\"") { push("dq", ""); i++; continue }
            if (nested(c, nc)) continue
            if (c == "{") { BD[D]++; i++; continue }
            if (c == "}") { if (BD[D] > 0) BD[D]--; else pop(); i++; continue }
            i++; continue
        }
        if (T[D] == "arith") {
            if (c == "$" && nc == "(" && ch(i + 2) != "(") { push("cmd", "$("); i += 2; continue }
            if (c == "$" && nc == "{") { push("brace", ""); i += 2; continue }
            if (c == "(") { P[D]++; i++; continue }
            if (c == ")") { if (P[D] > 0) { P[D]--; i++ } else { pop(); i += 2 }; continue }
            i++; continue
        }
        # A cmd frame.
        if (c == "\\") {
            if (nc == "\n") { endword(); i += 2; continue }   # a continued line
            CUR = CUR nc; INW = 1; i += 2; continue
        }
        if (c == " " || c == "\t") { endword(); i++; continue }
        if (c == "\n") { endword(); sep(); i++; if (NHD) heredocs(); continue }
        if (c == "#" && !INW) { while (i <= N && ch(i) != "\n") i++; continue }
        if (c == "'") {
            j = index(substr(S, i + 1), "'")
            CUR = CUR substr(S, i + 1, j ? j - 1 : N); INW = 1; BARE = 0
            i += (j ? j + 1 : N); continue
        }
        if (c == "$" && nc == "'") { INW = 1; BARE = 0; i += 2; ansi(); continue }
        if (c == "\"") { INW = 1; BARE = 0; push("dq", ""); i++; continue }
        if (c == "$" && (nc == "(" || nc == "{")) { INW = 1; BARE = 0; nested(c, nc); continue }
        if (c == "$") { INW = 1; BARE = 0; CUR = CUR c; i++; continue }
        # Inside [[ ]], < > ( ) compare and group; they redirect nothing.
        if (M[D] == "test" && (c == "<" || c == ">" || c == "(" || c == ")")) {
            CUR = CUR c; INW = 1; i++; continue
        }
        if (c == "(") {
            if (!INW && nc == "(") { push("arith", ""); i += 2; continue }
            if (INW && nc == ")") {                      # name() -- a definition
                FN[CUR] = 1; CUR = ""; INW = 0; BARE = 1; ASSIGN = 0; i += 2; continue
            }
            if (INW && ASSIGN && CUR ~ /=$/) { push("cmd", "arr"); i++; continue }
            if (M[D] == "pat") { i++; continue }
            endword(); push("cmd", "("); i++; continue
        }
        if (c == ")") {
            endword()
            if (M[D] == "pat") { M[D] = ""; X[D] = 1; i++; continue }   # a case arm
            pop(); i++; continue
        }
        if (c == ";") {
            endword()
            if (nc == ";" || nc == "&") {                # ;; ;& ;;& end a case arm
                i += 2; if (ch(i) == "&") i++
                if (CD[D] > 0) { M[D] = "pat"; X[D] = 0 }
                continue
            }
            sep(); i++; continue
        }
        if (c == "&") {
            endword()
            if (nc == ">") { i += 2; if (ch(i) == ">") i++; R[D] = 1; continue }
            i += (nc == "&" ? 2 : 1); sep(); continue
        }
        if (c == "|") {
            endword()
            if (M[D] == "pat") { i++; continue }         # on|off)
            i += (nc == "|" ? 2 : 1); if (ch(i) == "&") i++; sep(); continue
        }
        if (c == "<" || c == ">") {
            # 2>/dev/null: the 2 is a descriptor, not a word.
            if (INW && BARE && CUR ~ /^[0-9]+$/) { CUR = ""; INW = 0 } else endword()
            if (nc == "(") { push("cmd", "<("); i += 2; continue }
            if (substr(S, i, 3) == "<<<") { i += 3; R[D] = 1; continue }
            if (substr(S, i, 2) == "<<") { i += 2; if (ch(i) == "-") i++; R[D] = 2; continue }
            i++; while (ch(i) == ">" || ch(i) == "&" || ch(i) == "|") i++
            R[D] = 1; continue
        }
        if (c == "=" && INW && BARE && CUR ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?$/) ASSIGN = 1
        CUR = CUR c; INW = 1; i++
    }
    endword()
}
BEGIN {
    n = split(keywords, a, " "); for (k = 1; k <= n; k++) KW[a[k]] = 1
    n = split(builtins, a, " "); for (k = 1; k <= n; k++) BI[a[k]] = 1
}
# One scan per file; the functions any of them define are no command.
FNR == 1 && NR > 1 { scan(TEXT); TEXT = "" }
FNR == 1 { FNAME = FILENAME }
{ TEXT = TEXT $0 "\n" }
END {
    scan(TEXT)
    for (w in RUN) if (!(w in FN)) print "run " w
}
AWK
# commands_of <file>...: "run NAME", "probe NAME", "dynamic FILE:LINE", sorted.
commands_of() {
    awk -v keywords="$(compgen -k | tr '\n' ' ')" -v builtins="$(compgen -b | tr '\n' ' ')" \
        "$COMMANDS_AWK" "$@" | sort -u
}
FOUND=$(cd "$ROOT" && commands_of src/jayos-denoise src/easyeffects-lib.sh)
RUNS=$(sed -n 's/^run //p' <<<"$FOUND")
PROBES=$(sed -n 's/^probe //p' <<<"$FOUND")
DYNAMIC=$(sed -n 's/^dynamic //p' <<<"$FOUND")

# command, the package that installs it, and how the recipe declares it:
# depends; optdepends (and probed with `command -v` before it is run, so the
# engine works without it); or probed (run only when `command -v` finds it,
# and needed by nothing). One row per command the code runs -- a command
# with no row fails, and so does a row whose command the code no longer
# runs, so the table cannot keep a package alive after its reason is gone.
read -r -d '' TOOLS <<'TABLE'
awk          gawk         depends
basename     coreutils    depends
cat          coreutils    depends
dirname      coreutils    depends
easyeffects  easyeffects  optdepends
grep         grep         depends
id           coreutils    depends
jq           jq           depends
mkdir        coreutils    depends
mktemp       coreutils    depends
mv           coreutils    depends
pgrep        procps-ng    depends
realpath     coreutils    depends
rm           coreutils    depends
sed          sed          depends
setsid       util-linux   depends
sleep        coreutils    depends
socat        socat        depends
systemctl    systemd      probed
timeout      coreutils    depends
TABLE

if [[ -n "$RUNS" ]] && grep -qx jq <<<"$RUNS"; then
    pass "the lexer reads $(grep -c . <<<"$RUNS") commands out of the engine and its library"
else
    bad "the lexer read no commands, or not jq, out of the engine and its library; nothing below examined anything"
fi
if [[ -z "$DYNAMIC" ]]; then
    pass "and no command word that is an expansion, which no package could be named for"
else
    bad "a command run through an expansion, which no row can tie to a package, at: $(paste -sd' ' <<<"$DYNAMIC")"
fi

declare -A ROW_PKG=() ROW_HOW=() NEED=()
while read -r tool pkg how; do
    [[ -n "$tool" ]] || continue
    ROW_PKG[$tool]=$pkg
    ROW_HOW[$tool]=$how
done <<<"$TOOLS"

for tool in $RUNS; do
    [[ -v ROW_PKG[$tool] ]] || bad "the engine runs $tool, which no row of this suite's table assigns to a package"
done
for tool in $(printf '%s\n' "${!ROW_PKG[@]}" | sort); do
    pkg=${ROW_PKG[$tool]}
    if ! grep -qx -- "$tool" <<<"$RUNS"; then
        bad "the table names $tool, which the engine and its library no longer run; drop its row, and $pkg from the recipe if nothing else needs it"
        continue
    fi
    case ${ROW_HOW[$tool]} in
        depends)
            NEED[$pkg]+=" $tool"
            ;;
        optdepends)
            if recipe "for v in \"\${optdepends[@]}\"; do [[ \$v == '$pkg:'* ]] && exit 0; done; exit 1" \
               && grep -qx -- "$tool" <<<"$PROBES"; then
                pass "optdepends=() has $pkg, and the engine probes for $tool before it runs it"
            else
                bad "$tool is run as an optional dependency, but optdepends=() lacks $pkg or the code never probes for it with command -v"
            fi
            ;;
        probed)
            if grep -qx -- "$tool" <<<"$PROBES"; then
                pass "$tool ($pkg) is run only where command -v finds it, so nothing declares it"
            else
                bad "$tool is in the table as probed, but the code never probes for it with command -v"
            fi
            ;;
        *) bad "the row for $tool says '${ROW_HOW[$tool]}', which is not depends, optdepends or probed" ;;
    esac
done

# The interpreter: the engine is started by its #! line, so that line's
# programs are run as surely as anything in its body.
shebang=$(head -n 1 "$ROOT/src/jayos-denoise")
if [[ "$shebang" == '#!/usr/bin/env bash' ]]; then
    NEED[bash]+=" bash(#!)"
    NEED[coreutils]+=" env(#!)"
else
    bad "src/jayos-denoise starts '$shebang', not '#!/usr/bin/env bash'; this suite knows which packages only that line needs"
fi

for pkg in $(printf '%s\n' "${!NEED[@]}" | sort); do
    if has depends "$pkg"; then
        pass "depends=() has $pkg, for what the engine runs:${NEED[$pkg]}"
    else
        bad "depends=() lacks $pkg, and the engine runs${NEED[$pkg]}"
    fi
done
# And nothing else: every entry is the plugin's NEEDED half or a package the
# engine runs, so a package whose last command was dropped goes with it.
for pkg in $(recipe 'printf "%s\n" "${depends[@]}"'); do
    case $pkg in
        glibc|gcc-libs) ;;
        *) [[ -v NEED[$pkg] ]] || bad "depends=() names $pkg, which nothing the package runs or links needs" ;;
    esac
done

echo
echo "every step the recipe calls is one steps.sh offers"

# contract/steps.txt is generated from steps.sh's dispatch by
# tools/contract.sh, which fails when the two differ; so a verb the recipe
# calls that is not listed there is a verb steps.sh answers with its usage.
declare -A SIG=()
while read -r verb rest; do
    [[ -z "$verb" || "$verb" == \#* ]] && continue
    SIG[$verb]=$rest
done < "$STEPS_TXT"
if (( ${#SIG[@]} > 0 )); then
    pass "contract/steps.txt lists ${#SIG[@]} verbs"
else
    bad "contract/steps.txt lists no verbs, so nothing below can be held to it"
fi
used=$(grep -oE '_steps[[:space:]]+[a-z]+' <<<"$CODE" | awk '{print $2}' | sort -u)
if [[ -n "$used" ]]; then
    pass "the recipe calls steps.sh's $(paste -sd' ' <<<"$used")"
else
    bad "the recipe calls no step at all"
fi
for verb in $used; do
    if [[ -v SIG[$verb] ]]; then
        pass "$verb is in contract/steps.txt"
    else
        bad "the recipe calls '$verb', which contract/steps.txt does not list"
    fi
done

echo
echo "each function, run as makepkg runs it, against a recording steps.sh"

# The scratch checkout the recipe will think it sits in. startdir is its
# packaging/arch, so _tree resolves two directories up to $TREE, and the
# steps.sh there is the stub. The stub is reached only through that
# resolution: had _tree resolved anywhere else, the real steps.sh would have
# refused a srcdir that does not exist and nothing would be recorded.
TREE="$WORK/tree"
STARTDIR="$TREE/packaging/arch"
SRCDIR="$WORK/build/src"
PKGDIR="$WORK/build/pkg"
mkdir -p "$STARTDIR" "$SRCDIR" "$PKGDIR"
cp "$RECIPE" "$STARTDIR/PKGBUILD"
# %q, so two arguments and one argument with a space in it cannot record the
# same line.
cat > "$TREE/packaging/steps.sh" <<STUB
#!/usr/bin/env bash
# A stand-in for packaging/steps.sh: records each call, fails the verb named
# in fail-verb.
{ printf '%q ' "\$@"; printf '\n'; } >> "$WORK/calls"
[[ "\$1" == "\$(cat "$WORK/fail-verb" 2>/dev/null)" ]] && exit 1
exit 0
STUB

# The line the stub records for <verb>, with steps.txt's placeholders filled
# the way the recipe is meant to fill them: <plugin-tree> is the fork's clone
# under srcdir, <pkgdir> is pkgdir. A placeholder this does not know fails,
# so a verb that grows an argument fails here until someone says what it is.
expect_call() { # expect_call <verb>
    local args=("$1") a
    [[ -v SIG[$1] ]] || return 1
    for a in ${SIG[$1]}; do
        case $a in
            "<plugin-tree>") args+=("$SRCDIR/DeepFilterNetPlus") ;;
            "<pkgdir>")      args+=("$PKGDIR") ;;
            *) return 1 ;;
        esac
    done
    printf '%q ' "${args[@]}"
    printf '\n'
}

# run_fn <function> [<verb to fail>]: the function, in a fresh bash under
# errexit and errtrace, from srcdir, as makepkg runs it. Its status is the
# status of that bash -- the function is a plain statement there, so errexit
# applies; called under `if` or `||` inside, errexit would be off.
run_fn() {
    : > "$WORK/calls"
    printf '%s' "${2:-}" > "$WORK/fail-verb"
    ( cd "$SRCDIR" && bash -eE -c \
        'startdir=$1 srcdir=$2 pkgdir=$3; source "$4"; '"$1" \
        _ "$STARTDIR" "$SRCDIR" "$PKGDIR" "$STARTDIR/PKGBUILD" ) >/dev/null 2>"$WORK/fn.err"
}

# Which steps each function calls, in order. prepare's order is the point of
# its case: fetch against a clone still at the default branch would fetch
# that branch's lockfile, not the pin's.
declare -A STEPS_OF=(
    [prepare]="checkout fetch"
    [build]="build"
    [check]="check"
    [package]="package"
)

for fn in prepare build check package; do
    want=""
    ok=1
    for verb in ${STEPS_OF[$fn]}; do
        line=$(expect_call "$verb") || { ok=0; break; }
        want+="$line"$'\n'
    done
    if (( ! ok )); then
        bad "$fn(): contract/steps.txt does not say how to call '$verb'"
        continue
    fi

    run_fn "$fn"
    rc=$?
    got=$(cat "$WORK/calls")
    if (( rc == 0 )) && [[ "$got"$'\n' == "$want" ]]; then
        said=""
        for verb in ${STEPS_OF[$fn]}; do said+="${said:+, then }$verb ${SIG[$verb]}"; done
        pass "$fn() calls $said"
    else
        bad "$fn() exited $rc and called: $(tr '\n' ';' <<<"$got") -- wanted: $(tr '\n' ';' <<<"$want") $(cat "$WORK/fn.err")"
    fi

    # Each step it calls, failing in turn: the function has to fail with it,
    # and nothing after the failed step may run. A recipe that wrote
    # `_steps checkout ... || true`, or ran fetch before checkout, would
    # build whatever the clone's default branch holds.
    upto=""
    for verb in ${STEPS_OF[$fn]}; do
        upto+=$(expect_call "$verb")$'\n'
        run_fn "$fn" "$verb"
        rc=$?
        got=$(cat "$WORK/calls")
        if (( rc != 0 )) && [[ "$got"$'\n' == "$upto" ]]; then
            pass "$fn() fails when steps.sh $verb fails, and calls nothing after it"
        else
            bad "$fn() exited $rc with steps.sh $verb failing, having called: $(tr '\n' ';' <<<"$got")"
        fi
    done
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
