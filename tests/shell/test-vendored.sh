#!/usr/bin/env bash
#
# rust/crates/jayos-core is JayOS's, byte for byte: every file its
# PROVENANCE.md lists has the sum the table gives it.
#
#   tests/shell/test-vendored.sh
#
# Exit 0: every listed file is there with its sum, and the crate holds no
# source the table does not list. 1: one differs, is gone, or is unlisted.
# 2: could not run -- no sha256sum, or no table to read -- which is not the
# same answer as "the copy is whole".
#
# WHY. The crate is a copy of five of JayOS's modules, kept so that this
# package builds jayos-audio-state and jayos-equalizer-preset with no JayOS
# checkout (the PROVENANCE.md says why a copy, and how to refresh it). A copy
# is only worth calling one while it is what its table says: a fix made here
# by hand is a fork of JayOS's library that nobody will carry back, and a
# module added without a row is code whose origin nothing records. So the
# table is a check of the copy, not only a record of it, the way JayOS holds
# the contract it vendors from this repository
# (tools/fixtures/jayos-audio-contract/PROVENANCE.md there).
#
# What is not a row: src/lib.rs, which is this package's (its header says
# so), and PROVENANCE.md itself.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE="$ROOT/rust/crates/jayos-core"
TABLE="$CRATE/PROVENANCE.md"

command -v sha256sum >/dev/null 2>&1 || { echo "$(basename "$0"): sha256sum is not installed; nothing was compared" >&2; exit 2; }
[[ -f "$TABLE" ]] || { echo "$(basename "$0"): no $TABLE to read; nothing was compared" >&2; exit 2; }

PASS=0
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The table's rows: | `path` | `sum` |, a path relative to the crate and a
# sum of sixty-four hex digits. Any other row of the file is prose.
ROWS=$(sed -n -E 's/^\| `([^`]+)` \| `([0-9a-f]{64})` \|$/\1 \2/p' "$TABLE")

echo "rust/crates/jayos-core against its PROVENANCE.md"

if [[ -z "$ROWS" ]]; then
    bad "PROVENANCE.md lists no file with a sum; the copy is checked against nothing"
else
    pass "PROVENANCE.md lists $(grep -c . <<<"$ROWS") files with their sums"
fi

while read -r path sum; do
    [[ -n "$path" ]] || continue
    if [[ ! -f "$CRATE/$path" ]]; then
        bad "$path is listed and not there"
    elif [[ "$(sha256sum < "$CRATE/$path" | cut -d' ' -f1)" == "$sum" ]]; then
        pass "$path is the commit's, byte for byte"
    else
        bad "$path differs from the commit PROVENANCE.md names; refresh it from JayOS, or carry the change there"
    fi
done <<<"$ROWS"

# And nothing the table does not account for: every file in the crate but
# src/lib.rs and the table itself is a row. Untracked or not, since a module
# dropped in and not yet committed is the case this exists for.
unlisted=""
while IFS= read -r f; do
    rel=${f#"$CRATE/"}
    case $rel in
        src/lib.rs|PROVENANCE.md) continue ;;
    esac
    grep -q "^$rel " <<<"$ROWS" || unlisted+=" $rel"
done < <(find "$CRATE" -type f ! -path "$CRATE/target/*" | LC_ALL=C sort)
if [[ -z "$unlisted" ]]; then
    pass "and the crate holds nothing else but src/lib.rs, this package's"
else
    bad "files in the crate the table does not list:$unlisted"
fi

# src/lib.rs declares only modules the table holds: a `pub mod x;` with no
# src/x.rs row is a module from nowhere.
undeclared=""
for m in $(sed -n -E 's/^pub mod ([a-z_]+);$/\1/p' "$CRATE/src/lib.rs" 2>/dev/null); do
    grep -q "^src/$m.rs " <<<"$ROWS" || undeclared+=" $m"
done
if [[ -z "$undeclared" ]] && grep -qE '^pub mod ' "$CRATE/src/lib.rs" 2>/dev/null; then
    pass "src/lib.rs declares only modules the table holds"
else
    bad "src/lib.rs declares modules the table does not hold:${undeclared:- (or none at all)}"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
