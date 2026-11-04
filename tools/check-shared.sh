#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard the shared CI layer against local edits.
#
# The workflows and most of tools/ are written by the template's
# tools/sync-deck.sh and must stay identical across every deck - that is what
# lets one fix reach all of them, and what keeps them from drifting apart again.
# The sync records a sha256 per shared file in tools/shared.lock; this fails
# when a file no longer matches it.
#
# An `optional` file (tools/shared-files) may be missing - the deck opted out
# of it - but not edited. Every `import` entry is checked too: a deck's own
# CLAUDE.md must keep its `@AGENTS.md` line while the deck carries AGENTS.md.
#
# A deck that needs one more gate puts it in tools/check-extra.sh, or in a
# workflow of its own, never in a shared file. A shared file that is wrong is
# fixed in the template and synced to every deck.
#
# The template itself has no lock - it is where the shared files come from.
#
# Usage: tools/check-shared.sh
set -euo pipefail
cd "$(dirname "$0")/.."

lock=tools/shared.lock

if [[ ! -f "$lock" ]]; then
    if [[ -f tools/sync-deck.sh ]]; then
        echo "this is the template - it is the source of the shared files"
        exit 0
    fi
    echo "error: no ${lock} - this deck has never been synced with the template." >&2
    echo "From the template, run: tools/sync-deck.sh <path to this deck>" >&2
    exit 1
fi

source_line="$(grep -m1 '^# source: ' "$lock" | sed 's/^# source: //' || true)"
report="$(grep -v '^#' "$lock" | sha256sum --check --quiet - 2>&1 || true)"

# An optional file the deck deleted is an opt-out, not drift.
while read -r kind path _; do
    [[ "$kind" == optional && ! -e "$path" ]] || continue
    report="$(grep -vF -- "${path}: FAILED open or read" <<<"$report" || true)"
done < <(grep -vE '^[[:space:]]*(#|$)' tools/shared-files)
report="$(grep -v '^sha256sum: ' <<<"$report" || true)"

if [[ -n "$report" ]]; then
    echo "error: shared files differ from the template they were synced from:" >&2
    sed -E 's/^/  /; s/: FAILED open or read$/: missing/; s/: FAILED$/: changed/' <<<"$report" \
        | grep -vE 'WARNING|^  sha256sum: ' >&2
    echo "" >&2
    echo "These files are shared by every deck. Undo the local change, and either" >&2
    echo "move deck-specific logic to tools/check-extra.sh or fix the file in the" >&2
    echo "template and sync it (synced from: ${source_line:-unknown})." >&2
    exit 1
fi
# import entries: the deck's own file keeps the line the template relies on
missing_imports=()
while read -r kind path line; do
    [[ "$kind" == import && -f "$path" ]] || continue
    [[ "$line" != @* || -f "${line#@}" ]] || continue
    grep -qxF -- "$line" "$path" || missing_imports+=("${path}: ${line}")
done < <(grep -vE '^[[:space:]]*(#|$)' tools/shared-files)
if (( ${#missing_imports[@]} )); then
    echo "error: a deck file lost a line the shared layer depends on:" >&2
    printf '  %s\n' "${missing_imports[@]}" >&2
    echo "Put the line back (for CLAUDE.md, \`@AGENTS.md\` on its own line near the top)." >&2
    exit 1
fi

echo "all $(grep -vc '^#' "$lock") shared files match the template (${source_line:-unknown})"
