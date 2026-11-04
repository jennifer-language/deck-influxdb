#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard src/ against holding anything but Jennifer source.
#
# src/ is the subtree jvc vendors into every consumer's tree. An editor swap
# file, or the hidden 0600 `.jfmt-*.tmp` a crashed `jennifer fmt -w` leaves
# behind, is invisible to `fmt -l`, `lint` and often `git status` - and would
# otherwise be shipped. tools/pack.sh refuses one at release time; this catches
# it on the commit that introduced it.
#
# The one exception is src/.no-overlay, the sidecar deck-lib.sh reads to exempt
# generated files from needing an overlay. pack.sh leaves it out of the archive.
#
# Usage: tools/check-src.sh
set -euo pipefail
cd "$(dirname "$0")/.."

stray="$(find src -type f ! -name '*.j' ! -path src/.no-overlay | sort)"
if [[ -n "$stray" ]]; then
    echo "error: src/ holds files that are not Jennifer source:" >&2
    printf '  %s\n' $stray >&2
    echo "" >&2
    echo "src/ is the subtree jvc vendors into a consumer's tree. A" >&2
    echo "\`.jfmt-*.tmp\` is the leftover of a crashed \`jennifer fmt -w\`;" >&2
    echo "remove it and re-run the format." >&2
    exit 1
fi
echo "src/ holds only Jennifer source"
