#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard against source headers drifting from the manifest.
#
# Every .j file opens with an SPDX pair and an interpreter range. `jennifer
# lint` (L303) rejects a malformed pragma but says nothing about a missing one,
# so a new file can land bare and still lint clean. This checks that each file
# has all three lines, and that the two the manifest also states still agree
# with it - the licence and the engine range (`>=X.Y.Z`, or `>=X.Y.Z <A.B.C`
# with an upper bound) are declared twice by design, and CI is what keeps the
# copies honest. The pragma must equal engines.jennifer exactly.
#
# Usage: tools/check-headers.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

# The header block sits at the top of the file, after an optional shebang.
HEADER_LINES=5

[[ -n "$DECK_LICENSE" ]] || deck_die "$DECK_MANIFEST declares no package.license"
[[ -n "$DECK_RANGE"   ]] || deck_die "$DECK_MANIFEST declares no engines.jennifer"

want_license="# SPDX-License-Identifier: ${DECK_LICENSE}"
want_pragma="# pragma-jennifer-version: ${DECK_RANGE}"

bad=0
checked=0
while read -r file; do
    checked=$((checked + 1))
    head="$(head -n "$HEADER_LINES" "$file")"

    grep -qxF -- "$want_license" <<<"$head" || {
        echo "${file}: missing '${want_license}'" >&2; bad=$((bad + 1)); }
    grep -qE '^# SPDX-FileCopyrightText: .' <<<"$head" || {
        echo "${file}: missing '# SPDX-FileCopyrightText: ...'" >&2; bad=$((bad + 1)); }
    if ! grep -qxF -- "$want_pragma" <<<"$head"; then
        have="$(grep -m1 '^# pragma-jennifer-version:' <<<"$head" || true)"
        if [[ -n "$have" ]]; then
            echo "${file}: '${have}' should be '${want_pragma}'" >&2
        else
            echo "${file}: missing '${want_pragma}'" >&2
        fi
        bad=$((bad + 1))
    fi
done < <(deck_all_sources)

if (( bad > 0 )); then
    echo "" >&2
    echo "$bad header problem(s) across $checked files." >&2
    echo "Each .j file opens with the SPDX pair and the range $DECK_MANIFEST states." >&2
    exit 1
fi
echo "all $checked source files carry the SPDX pair and ${DECK_RANGE}"
