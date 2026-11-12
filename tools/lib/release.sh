#!/usr/bin/env bash
#
# What tools/release.sh and tools/publish-release.sh both need to know about a
# release: what a version and a tag look like, which of two versions is newer,
# the newest release among some tags, the keys .github/allowed_signers holds,
# and whether a tag is signed by one of them. Sourced; sets no shell options.
#
# A RELEASE IS A SIGNED TAG, vMAJOR.MINOR.PATCH, ON main, whose VERSION file
# says MAJOR.MINOR.PATCH. The version is the one VERSION has always held --
# 1.0.0 when the package was jayos-denoise, 2.0.0 since it became jayos-audio
# -- and the tag only says which commit is that version. JayOS's recipe,
# pkgbuilds/jayos-audio/PKGBUILD there, builds the release it pins by tag and
# by commit, and vendors the same release's contract/ (its
# tools/jayos-audio-release.sh); docs/RELEASES.md here has the whole account.
#
# The same shapes as JayOS's tools/lib/release.sh, where a release is a
# signed tag too, so the owner signs both with one key and one habit; the
# version is semantic here rather than a date, since JayOS's recipe and
# contract say which version of this package they were written against.

RELEASE_VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# release_version_ok <version>: MAJOR.MINOR.PATCH, no leading zeros, no v.
release_version_ok() {
    [[ "$1" =~ $RELEASE_VERSION_RE ]]
}

# release_tag_ok <tag>: v and a version.
release_tag_ok() {
    [[ "$1" == v* ]] && release_version_ok "${1#v}"
}

# release_cmp <a> <b>: -1, 0 or 1, by number, field by field: 2.10.0 is newer
# than 2.9.0, which text order would get wrong.
release_cmp() {
    local -a a b
    local i
    IFS=. read -ra a <<<"$1"
    IFS=. read -ra b <<<"$2"
    for i in 0 1 2; do
        if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then echo -1; return 0; fi
        if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then echo 1; return 0; fi
    done
    echo 0
}

# release_latest: the newest release tag among the tag names on stdin, or
# nothing. A tag that is not a release's shape is not counted.
release_latest() {
    local tag best=""
    while IFS= read -r tag; do
        release_tag_ok "$tag" || continue
        if [[ -z "$best" ]] || [[ "$(release_cmp "${tag#v}" "${best#v}")" == 1 ]]; then
            best=$tag
        fi
    done
    [[ -n "$best" ]] && printf '%s\n' "$best"
    return 0
}

# release_before <tag>: the newest release tag older than <tag> among the tag
# names on stdin, or nothing: where a release's notes start counting from.
release_before() {
    local limit="${1#v}" tag best=""
    while IFS= read -r tag; do
        release_tag_ok "$tag" || continue
        [[ "$(release_cmp "${tag#v}" "$limit")" == -1 ]] || continue
        if [[ -z "$best" ]] || [[ "$(release_cmp "${tag#v}" "${best#v}")" == 1 ]]; then
            best=$tag
        fi
    done
    [[ -n "$best" ]] && printf '%s\n' "$best"
    return 0
}

# release_signers_keys <file>: its key lines, comments and blank lines left
# out. Nothing means no key, and every release is refused.
release_signers_keys() {
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true
}

# release_verify_tag <tag> <signers file>: 0 when the tag is an annotated tag
# signed by a key the file lists, with git's namespace. git reads an SSH
# signature's block itself, so no gpg.format is needed to verify one; what it
# needs is the file, which it has nowhere else to take from.
release_verify_tag() {
    [[ "$(git cat-file -t "refs/tags/$1" 2>/dev/null)" == tag ]] || return 1
    git -c gpg.ssh.allowedSignersFile="$2" verify-tag "$1" >/dev/null 2>&1
}
