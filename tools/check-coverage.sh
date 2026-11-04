#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard against an export no test ever calls.
#
# check-overlays.sh proves every module has a co-located overlay, which is what
# jvc demands - but an overlay can exist and still not touch a new export. This
# checks that every exported function is called from at least one overlay. It
# is a floor, not a coverage measure: one call counts, whatever it asserts.
#
# Known gaps go in tools/.coverage-todo, one name per line, written the way the
# cheatsheet would (`open` in a topics deck, `fastq.open` in a modules deck).
# They are reported as a backlog instead of failing; shrink the file, do not
# grow it. `--todo` prints every current gap, to seed it:
#
#   tools/check-coverage.sh --todo > tools/.coverage-todo
#
# Usage: tools/check-coverage.sh [--todo]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

mode="${1:-check}"
[[ "$mode" == check || "$mode" == --todo ]] || deck_die "usage: tools/check-coverage.sh [--todo]"

python3 - "$mode" <<'PYCOVER'
import re, glob, os, sys

SLUG, SHAPE = os.environ['DECK_SLUG'], os.environ['DECK_SHAPE']
LIST_GAPS = sys.argv[1] == '--todo'
TODO = 'tools/.coverage-todo'

todo = set()
if os.path.exists(TODO):
    todo = {l.strip() for l in open(TODO, encoding='utf-8')
            if l.strip() and not l.lstrip().startswith('#')}

exports = {}
for f in sorted(glob.glob('src/**/*.j', recursive=True)):
    if f.endswith('_test.j'):
        continue
    ns = SLUG if SHAPE == 'topics' else os.path.splitext(os.path.basename(f))[0]
    for m in re.finditer(r'^export func ([A-Za-z][A-Za-z0-9]*)\(',
                         open(f, encoding='utf-8').read(), re.M):
        name = m.group(1)
        exports[name if SHAPE == 'topics' else f"{ns}.{name}"] = (f, name)

overlays = "".join(open(f, encoding='utf-8').read()
                   for f in sorted(glob.glob('src/**/*_test.j', recursive=True)))

gaps = sorted(label for label, (_, name) in exports.items()
              if not re.search(r'\b' + name + r'\s*\(', overlays))

if LIST_GAPS:
    print('\n'.join(gaps))
    sys.exit(0)

failing = [g for g in gaps if g not in todo]
if failing:
    print("", file=sys.stderr)
    for g in failing:
        print(f"  {exports[g][0]}: {g}() is exported but never called from an overlay",
              file=sys.stderr)
    print(f"\n{len(failing)} of {len(exports)} exported function(s) are untested.",
          file=sys.stderr)
    sys.exit(1)

print(f"all {len(exports)} exported functions are called from an overlay")
backlog = len(gaps) - len(failing)
if backlog:
    print(f"  except {backlog} carried in {TODO} - shrink that file")
PYCOVER
