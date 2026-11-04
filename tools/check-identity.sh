#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard against the template's identity surviving into a real deck.
#
# deck-template is written against a placeholder name, `@myscope/mydeck`, and
# its own repository name, `deck-template`. tools/init-deck.sh rewrites them,
# but a file added after init, a URL edited by hand, or a TEMPLATE.md nobody
# deleted can still carry them - and a deck published with a `deck-template`
# manual link or a `mydeck.greet(` in its cheatsheet is broken for every
# consumer.
#
# The placeholder is chosen so that it never occurs in prose, so the check is a
# plain search with no exceptions to maintain.
#
# The template itself is still called @myscope/mydeck and is exempt. A release
# never is: `--release` refuses the placeholder name outright, so neither the
# template nor an uninitialised copy of it can be tagged.
#
# Usage: tools/check-identity.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

PLACEHOLDER_NAME="@myscope/mydeck"

if [[ "$DECK_NAME" == "$PLACEHOLDER_NAME" ]]; then
    if [[ "${1-}" == "--release" ]]; then
        echo "::error::${DECK_MANIFEST} still names the template placeholder ${DECK_NAME}" >&2
        echo "Run tools/init-deck.sh before releasing." >&2
        exit 1
    fi
    echo "this is the template (${DECK_NAME}) - skipping the leftover check"
    exit 0
fi

# Everything in the checkout but build output, vendored dependencies and this
# script, which has to name the placeholder to look for it.
leftovers="$(grep -rIn -E 'mydeck|myscope|deck-template' . \
    --exclude-dir=.git --exclude-dir=site --exclude-dir=dist \
    --exclude-dir=vendor --exclude-dir=.jennifer-src \
    --exclude=check-identity.sh || true)"

if [[ -n "$leftovers" ]]; then
    printf '%s\n' "$leftovers" >&2
    echo "" >&2
    echo "$(wc -l <<<"$leftovers") line(s) still carry the template's identity." >&2
    echo "Replace mydeck with ${DECK_SLUG}, myscope with ${DECK_SCOPE} and deck-template" >&2
    echo "with deck-${DECK_SLUG};" >&2
    echo "delete TEMPLATE.md and tools/init-deck.sh if they are still here." >&2
    exit 1
fi
echo "no template identity left in ${DECK_NAME}"
