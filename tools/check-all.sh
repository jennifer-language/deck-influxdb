#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Run the whole gate locally, in the order .github/workflows/test.yml runs it.
#
# Every check runs even after one fails, so a single pass reports everything;
# the exit status is 1 if any did. Two CI steps are left out because they
# change the working tree: tools/vendor-deps.sh (run it once, and again when
# the dependencies change) and tools/inject-version.sh (it would stamp a dev
# version into a tracked file).
#
# Usage: tools/check-all.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

JENNIFER="${JENNIFER:-jennifer}"
failed=()

step() {
    local name="$1"
    shift
    echo "=== ${name}"
    "$@" || failed+=("$name")
}

suites() {
    local suite rc=0
    while read -r suite; do
        $JENNIFER test "$suite" || rc=1
    done < <(deck_test_suites)
    return "$rc"
}

mapfile -t sources < <(deck_all_sources)
mapfile -t units < <(deck_lint_units)

echo "$DECK_NAME $DECK_VERSION - $DECK_MANIFEST, $DECK_SHAPE shape, tiny=$DECK_TINY"
step "shared"    tools/check-shared.sh
step "format"    $JENNIFER fmt -l "${sources[@]}"
step "lint"      $JENNIFER lint "${units[@]}"
step "headers"   tools/check-headers.sh
step "overlays"  tools/check-overlays.sh
step "src"       tools/check-src.sh
step "coverage"  tools/check-coverage.sh
step "docs"      tools/check-docs.sh
step "identity"  tools/check-identity.sh
step "suites"    suites
step "examples"  tools/check-examples.sh
if [[ -x tools/check-extra.sh ]]; then
    step "extra" tools/check-extra.sh
fi

echo ""
if (( ${#failed[@]} > 0 )); then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
echo "the gate is green"
