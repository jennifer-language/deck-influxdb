#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard the test-coverage half of jvc's publish gate.
#
# jvc requires a co-located MODULE_test.j beside every module, and will not
# publish a deck without one. Checking it here means a module that grows a
# test-free surface fails at push time rather than at publish time.
#
# Both directions are checked: a module with no overlay, and an overlay with no
# module. A generated data file - tables, not behaviour - opts out with a
# `# ci-no-overlay` line in its header.
#
# Usage: tools/check-overlays.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

dir=src
[[ "$DECK_SHAPE" == topics ]] && dir=src/topics

missing=0
checked=0
while read -r module; do
    checked=$((checked + 1))
    overlay="${module%.j}_test.j"
    [[ -f "$overlay" ]] || { echo "${module} has no ${overlay}" >&2; missing=$((missing + 1)); }
done < <(deck_testable_modules)

while read -r overlay; do
    module="${overlay%_test.j}.j"
    [[ -f "$module" ]] || { echo "${overlay} overlays no module ${module}" >&2; missing=$((missing + 1)); }
done < <(find "$dir" -maxdepth 1 -name '*_test.j' | sort)

if (( missing > 0 )); then
    echo "" >&2
    echo "$missing module(s) or overlay(s) unpaired in ${dir}/." >&2
    echo "jvc will not publish a deck whose modules have no co-located overlay." >&2
    exit 1
fi
echo "all $checked modules in ${dir}/ have a co-located test overlay"
