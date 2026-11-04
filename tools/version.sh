#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Print the deck version, derived from git tags.
#
#   HEAD is a stable tag       0.2.0        (tag "0.2.0")
#   anywhere else              0.2.0-dev+14.9ebf3dd
#                              ^ last stable tag, commits since it, short sha
#   no stable tag yet          <manifest version>-dev+<commits>.<sha>
#   no git checkout            whatever the manifest declares
#
# Only src/topics/version.j is stamped with this. deck.toml's version is
# authored, because jvc resolves against the manifest on the default branch.
#
# The dev form is the one `jennifer version` itself prints, so a deck build and
# the interpreter that runs it read the same way. Build metadata after `+` is
# ignored by semver precedence, so 0.2.0-dev+14.9ebf3dd still orders before
# 0.2.0.
#
# Usage: tools/version.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Stable tags only: N.N.N, no leading v. A tag carrying a prefix, a
# prerelease or a build suffix is not a release and does not anchor one.
STABLE='^[0-9]+\.[0-9]+\.[0-9]+$'

# The nearest stable tag that is an ancestor of HEAD, and how far back it is.
# `git describe` is no use here: it would hand back the nearest tag of any
# shape, so a 0.3.0-rc1 in the way would hide the 0.2.0 behind it.
nearest_stable() {
    local tag best_tag="" best_n=-1 n
    while read -r tag; do
        [[ -n "$tag" ]] || continue
        git merge-base --is-ancestor "$tag" HEAD 2>/dev/null || continue
        n="$(git rev-list --count "${tag}..HEAD")"
        if (( best_n < 0 || n <= best_n )); then
            best_n="$n"
            best_tag="$tag"
        fi
    done < <(git tag --list | grep -E "$STABLE" | sort -V)
    [[ -n "$best_tag" ]] && printf '%s %s\n' "$best_tag" "$best_n"
}

# No checkout, or a repository with no commit yet: there is no history to
# derive anything from, so the manifest's placeholder stands. Without the
# second test a freshly `git init`ed tree stamps `0.0.0-dev+0.unknown`, which
# is worse than the placeholder it replaces.
if ! git rev-parse --git-dir >/dev/null 2>&1 || ! git rev-parse HEAD >/dev/null 2>&1; then
    # shellcheck source=tools/deck-lib.sh
    source tools/deck-lib.sh
    deck_load
    printf '%s\n' "${DECK_VERSION:-0.0.0}"
    exit 0
fi

# An exact stable tag on HEAD is a release, whatever else points at it.
exact="$(git tag --points-at HEAD 2>/dev/null | grep -E "$STABLE" \
    | sort -V | tail -1 || true)"
if [[ -n "$exact" ]]; then
    printf '%s\n' "$exact"
    exit 0
fi

sha="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
# `read` reports failure on empty input, which `set -e` would take as fatal -
# but "no stable tag yet" is an ordinary case with an answer of its own.
base=""
commits=0
read -r base commits < <(nearest_stable) || true

if [[ -n "${base:-}" ]]; then
    printf '%s-dev+%s.%s\n' "$base" "$commits" "$sha"
else
    # Nothing tagged yet: anchor on what the manifest says is being worked
    # toward, so a pre-release build reads 0.1.0-dev+3.abc1234 rather than
    # claiming a 0.0.0 nobody declared.
    # shellcheck source=tools/deck-lib.sh
    source tools/deck-lib.sh
    deck_load
    printf '%s-dev+%s.%s\n' "${DECK_VERSION:-0.0.0}" \
        "$(git rev-list --count HEAD 2>/dev/null || echo 0)" "$sha"
fi
