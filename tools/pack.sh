#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Build the release archive, in the shape the deck spec describes.
#
#   <scope>-<deck>-<version>.tar.gz
#     <scope>-<deck>-<version>/
#       src/...          <- the only thing jvc vendors
#       <manifest>       <- carried, never vendored
#       LICENSE
#       README.md
#
# The spec tolerates a leading ./ and a single wrapping directory, and requires
# a src/ directory holding the entrypoint src/<deck>.j. jvc vendors the src/
# subtree to vendor/<scope>/<deck>/ and ignores everything beside it.
#
# Two forms of the digest are written: a `sha256sum -c` file for humans, and the
# `sha256:<hex>` the registry records as its integrity pin.
#
# Usage: tools/pack.sh [output-dir]   (default: dist/)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

out="${1:-dist}"
root="${DECK_SCOPE}-${DECK_SLUG}-${DECK_VERSION}"
stage="${out}/.stage/${root}"

rm -rf "${out}/.stage"
mkdir -p "$stage"

# src/ in full, topic subdirectories included. The *_test.j overlays ship: jvc
# filters them out when vendoring, and the publish gate runs them.
cp -R src "${stage}/src"

# The overlay-exemption sidecar is CI bookkeeping, not something a consumer
# vendors.
rm -f "${stage}/src/.no-overlay"

# src/ is the subtree jvc vendors into a consumer's tree, so nothing that is
# not Jennifer source has any business being in it. An editor swap file, or a
# `.jfmt-*.tmp` a crashed `jennifer fmt -w` left behind, is hidden, mode 0600
# and invisible to `fmt -l` and `lint` - and would otherwise be copied
# straight into the release archive. tools/check-src.sh catches it earlier.
stray="$(find "${stage}/src" -type f ! -name '*.j' | sed "s|^${stage}/||")"
if [[ -n "$stray" ]]; then
    echo "error: src/ holds files that are not Jennifer source:" >&2
    printf '  %s\n' $stray >&2
    echo "Remove them before packing; the archive is what consumers vendor." >&2
    rm -rf "${out}/.stage"
    exit 1
fi

cp "$DECK_MANIFEST" "$stage/"
for extra in LICENSE README.md; do
    [[ -f "$extra" ]] && cp "$extra" "$stage/"
done

tar -czf "${out}/${root}.tar.gz" -C "${out}/.stage" "$root"
rm -rf "${out}/.stage"

( cd "$out" && sha256sum "${root}.tar.gz" > "${root}.tar.gz.sha256" )
printf 'sha256:%s\n' \
    "$(sha256sum "${out}/${root}.tar.gz" | cut -d' ' -f1)" \
    > "${out}/${root}.tar.gz.checksum"

# jvc fails an install whose archive has no src/ or no entrypoint, so assert
# both here rather than discovering it from a consumer's bug report.
listing="$(tar -tzf "${out}/${root}.tar.gz")"
for required in "${root}/src/${DECK_SLUG}.j" "${root}/${DECK_MANIFEST}"; do
    grep -qxF -- "$required" <<<"$listing" || {
        echo "error: archive is missing ${required}" >&2
        echo "$listing" >&2
        exit 1
    }
done
grep -q "^${root}/src/" <<<"$listing" || {
    echo "error: archive has no src/ subtree" >&2; exit 1; }

echo "${out}/${root}.tar.gz"
echo "  $(wc -l <<<"$listing") entries, entrypoint src/${DECK_SLUG}.j present"
echo "  $(cat "${out}/${root}.tar.gz.checksum")"
