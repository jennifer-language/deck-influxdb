#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# The examples are documentation that has to keep working: the docs quote them,
# so a broken example means stale docs. Running them is cheap and catches what
# the unit suites cannot - the end-to-end path through the public surface.
#
# This is the shared runner. The workflows call tools/check-examples.sh, which
# is the deck's own file and by default only hands over to this one. A deck
# whose examples need inputs or a network host replaces that wrapper instead -
# building fixtures, or setting `EXAMPLES_SKIP_RUN=1` to reduce this to a parse
# check - and leaves this file identical to every other deck's.
#
# `JENNIFER` names the interpreter, so the jennifer-tiny job can reuse this.
#
# Usage: tools/check-examples-shared.sh
set -euo pipefail
cd "$(dirname "$0")/.."

JENNIFER="${JENNIFER:-jennifer}"

shopt -s nullglob
examples=(examples/*.j)
shopt -u nullglob

if (( ${#examples[@]} == 0 )); then
    echo "no examples/ programs in this deck - nothing to run"
    exit 0
fi

failed=0
for example in "${examples[@]}"; do
    echo "--- ${example}"
    if [[ -n "${EXAMPLES_SKIP_RUN:-}" ]]; then
        $JENNIFER ast "$example" > /dev/null || failed=1
    else
        $JENNIFER run "$example" > /dev/null || failed=1
    fi
done

if (( failed )); then
    echo "" >&2
    echo "at least one example failed." >&2
    exit 1
fi
echo "all ${#examples[@]} examples ran"
