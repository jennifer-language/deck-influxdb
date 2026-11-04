#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Guard against the documentation drifting from the code.
#
# Replaces check-cheatsheet.sh, which asked only whether every export was
# mentioned somewhere and answered by bare substring: it passed a cheatsheet
# naming `VERSION` only inside `TEXT_VERSION`, and could not see a wrong
# signature at all. What is checked here:
#
#   1  every `<namespace>.X` the docs name is actually exported
#   2  documented call arity matches the code
#   3  every export has a signature in the cheatsheet, carrying the real
#      parameter names in order
#   4  struct fields, enum variants and constant values match their declarations
#   5  docblock @param / @field match the declaration they sit on
#   6  relative links resolve and stay inside docs/, the book outline covers
#      every page, and docs/internal/directories.md (if any) lists the tree
#   7  Jennifer's own `docblock` module accepts every docblock in src/, on
#      private functions too: every @param names a parameter and every
#      parameter has one, and an enum describes its variants in prose
#   8  only with a tools/doc-claims.j: every value a guide claims is what the
#      code returns, every annotated number is one of those values, and every
#      listing the docs print is byte-for-byte what the code emits
#
# Namespaces follow the deck's shape. A modules deck has one per file in src/
# (`fastq.open(`); a topics deck has one, the slug (`geo.open(`), and its
# cheatsheet may write the names bare (`open(`).
#
# The cheatsheet is docs/cheatsheet.md, or docs/reference/cheatsheet.md. In it,
# a signature is the first cell of a table row, or a bullet:
#
#   | `open(path)` | ... |                    names only
#   | `fastq.open(path as string)` | ... |    or qualified, with types
#
# each struct and enum is a `### `Name`` heading over its fields
# (`` `name as type` ``) or variants, and each constant is a row of a table
# whose header has a `value` column.
#
# A struct may instead be a row of a table whose header has a `type` column;
# it then counts as described, but its fields go unchecked.
#
# Known gaps go in docs/.cheatsheet-todo, one name per line, written the way the
# cheatsheet would write it (`open`, or `fastq.open`). A gap is something
# *missing* - an export with no signature, a type not described, a docblock
# with no @param or @field at all. Those are reported as a backlog instead of
# failing, so a deck can adopt this guard without a red build while a *new*
# export still fails the moment it goes undocumented. Anything *wrong* - a
# signature, value or tag that disagrees with the code - always fails. Shrink
# the file; do not grow it.
#
# `--todo` prints every current gap instead of checking, to seed the file:
#
#   tools/check-docs.sh --todo > docs/.cheatsheet-todo
#
# Usage: tools/check-docs.sh [--todo]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/deck-lib.sh
source tools/deck-lib.sh
deck_load

JENNIFER="${JENNIFER:-jennifer}"

sheet="$(deck_cheatsheet)"
[[ -n "$sheet" ]] || deck_die "no docs/cheatsheet.md or docs/reference/cheatsheet.md - every deck documents its API surface"

mode="${1:-check}"
[[ "$mode" == check || "$mode" == --todo ]] || deck_die "usage: tools/check-docs.sh [--todo]"

# --- 1-6: the static half ---------------------------------------------------
python3 - "$sheet" "$mode" <<'PYSTATIC'
import re, glob, os, sys

SLUG, SHAPE = os.environ['DECK_SLUG'], os.environ['DECK_SHAPE']
SHEET, LIST_GAPS = sys.argv[1], sys.argv[2] == '--todo'
TODO = 'docs/.cheatsheet-todo'

problems, backlog, gaps = [], [], set()

def note(where, what):
    problems.append(f"{where}: {what}")

todo = set()
if os.path.exists(TODO):
    todo = {l.strip() for l in open(TODO, encoding='utf-8')
            if l.strip() and not l.lstrip().startswith('#')}

def missing(where, label, what):
    """Something undocumented: a backlog entry if listed in the todo file."""
    gaps.add(label)
    if label in todo:
        backlog.append(label)
    else:
        note(where, what)

# ---- the real API, from the source ----------------------------------------
# Everything is keyed by namespace: one per file in a modules deck, the slug
# for the whole of a topics deck.
sources = [f for f in sorted(glob.glob('src/**/*.j', recursive=True))
           if not f.endswith('_test.j')]
funcs, consts, structs, enums = {}, {}, {}, {}
generated = set()
for f in sources:
    ns = SLUG if SHAPE == 'topics' else os.path.splitext(os.path.basename(f))[0]
    src = open(f, encoding='utf-8').read()
    for m in re.finditer(r'^export func ([A-Za-z][A-Za-z0-9]*)\(([^)]*)\)', src, re.M):
        funcs[ns, m.group(1)] = [p.strip().split(' as ')[0].strip()
                                 for p in m.group(2).split(',') if p.strip()]
    for m in re.finditer(r'^export def const ([A-Z][A-Z0-9_]*) as [\w ]+? init ([^;]+);',
                         src, re.M):
        consts[ns, m.group(1)] = m.group(2).strip()
        # a generated file's values are stamped in by tools/inject-version.sh,
        # so the docs describe them rather than quoting them
        if 'generated by tools/inject-version.sh' in src:
            generated.add((ns, m.group(1)))
    for m in re.finditer(r'^export def struct ([A-Za-z]\w*) \{(.*?)\};', src, re.M | re.S):
        structs[ns, m.group(1)] = [x.strip().split(' as ')[0].strip()
                                   for x in m.group(2).split(',') if x.strip()]
    for m in re.finditer(r'^export def enum ([A-Za-z]\w*) \{(.*?)\n\};', src, re.M | re.S):
        # a variant may carry a payload, `Feature{value as Interval}`
        body = re.sub(r'\{[^{}]*\}', '', m.group(2))
        enums[ns, m.group(1)] = [x.strip() for x in body.split(',') if x.strip()]

namespaces = {ns for ns, _ in list(funcs) + list(consts) + list(structs) + list(enums)}
namespaces.add(SLUG if SHAPE == 'topics' else os.path.splitext(os.path.basename(
    os.environ['DECK_ENTRY']))[0])

def label(ns, name):
    """How the cheatsheet and the todo file write a name."""
    return name if SHAPE == 'topics' else f"{ns}.{name}"

def resolve(prefix, name, table):
    """The (ns, name) key a written name refers to, or None."""
    if prefix:
        return (prefix, name) if (prefix, name) in table else None
    hits = [k for k in table if k[1] == name]
    return hits[0] if len(hits) == 1 else None

known = {k for t in (funcs, consts, structs, enums) for k in t}
for (ns, e), vs in enums.items():
    known |= {(ns, f"{e}.{v}") for v in vs}
for (ns, s), fs in structs.items():
    known |= {(ns, f"{s}.{f}") for f in fs}

def arity(args):
    """Top-level arguments in a call, ignoring commas in strings and literals."""
    if not args:
        return 0
    depth, quote, count = 0, None, 1
    for c in args:
        if quote:
            quote = None if c == quote else quote
        elif c in '"\'':
            quote = c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            count += 1
    return count

docs = sorted(glob.glob('docs/**/*.md', recursive=True))
if os.path.exists('README.md'):
    docs.append('README.md')
else:
    # a checkout without one usually means it was never committed
    note('README.md', "missing - every deck needs one (is it committed?)")
ns_alt = '|'.join(sorted(map(re.escape, namespaces), key=len, reverse=True))

# ---- 1 + 2: phantom references and arity ---------------------------------
for d in docs:
    text = open(d, encoding='utf-8').read()
    for m in re.finditer(r'\b(' + ns_alt + r')\.([a-z][A-Za-z0-9]*)\(([^()]*)\)', text):
        ns, name, args = m.group(1), m.group(2), m.group(3).strip()
        if (ns, name) not in funcs:
            note(d, f"{ns}.{name}() is documented but not exported")
            continue
        if args == '...':          # prose, naming the call rather than making it
            continue
        got = arity(args)
        if got != len(funcs[ns, name]):
            note(d, f"{ns}.{name}({args}) passes {got} argument(s), "
                    f"the code takes {len(funcs[ns, name])}")
    for m in re.finditer(r'\b(' + ns_alt + r')\.([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z]\w*)?)\b(?!\()',
                         text):
        if (m.group(1), m.group(2)) not in known:
            note(d, f"{m.group(1)}.{m.group(2)} is documented but not exported")

# ---- 3: cheatsheet signatures --------------------------------------------
# A signature is the first cell of a table row, or a bullet. Only that cell is
# read, because a notes column may show a call as an example, which is not a
# declaration.
sheet = open(SHEET, encoding='utf-8').read()
declared = set()
for line in sheet.split('\n'):
    if line.startswith('- '):
        cell = line
    elif line.startswith('|'):
        parts = line.split('|')
        if len(parts) < 2:
            continue
        cell = parts[1]
    else:
        continue
    for m in re.finditer(r'`(?:([a-z][A-Za-z0-9]*)\.)?([a-z][A-Za-z0-9]*)\(([^`)]*)\)`', cell):
        prefix, name, args = m.groups()
        if prefix and prefix not in namespaces:
            continue               # another library's call, e.g. `strings.trim(`
        key = resolve(prefix, name, funcs)
        if key is None:
            note(SHEET, f"{(prefix + '.') if prefix else ''}{name}() has a signature "
                        f"but is not exported")
            continue
        declared.add(key)
        doc = [a.strip().split(' as ')[0].strip() for a in args.split(',') if a.strip()]
        if doc != funcs[key]:
            note(SHEET, f"{label(*key)}({', '.join(doc)}) does not match the code's "
                        f"({', '.join(funcs[key])})")
for key in sorted(set(funcs) - declared):
    missing(SHEET, label(*key), f"{label(*key)}() has no signature in the API surface")

# ---- 4: types and constants ----------------------------------------------
def type_section(ns, name):
    # each type is a `### `Name`` heading holding a field or variant table
    m = re.search(r'^### `(?:' + re.escape(ns) + r'\.)?' + re.escape(name) +
                  r'`\n(.*?)(?=^#{2,3} |\Z)', sheet, re.S | re.M)
    return m.group(1) if m else None

def type_row(ns, name):
    # the lighter form: a row in a table with a `type` column, fields unchecked
    return re.search(r'^\| `(?:' + re.escape(ns) + r'\.)?' + re.escape(name) + r'` \|',
                     sheet, re.M) is not None

for (ns, name), fields in sorted(structs.items()):
    blk = type_section(ns, name)
    if blk is None:
        if not type_row(ns, name):
            missing(SHEET, label(ns, name), f"struct {label(ns, name)} is not described")
        continue
    for field in fields:
        if f'`{field} as' not in blk:
            missing(SHEET, f"{label(ns, name)}.{field}",
                    f"struct {label(ns, name)} field `{field}` is undocumented")
    for stale in re.findall(r'`(\w+) as ', blk):
        if stale not in fields:
            note(SHEET, f"struct {label(ns, name)} has no field `{stale}`")

for (ns, name), variants in sorted(enums.items()):
    blk = type_section(ns, name)
    if blk is None:
        if not type_row(ns, name):
            missing(SHEET, label(ns, name), f"enum {label(ns, name)} is not described")
        continue
    for v in variants:
        if f'`{v}`' not in blk:
            missing(SHEET, f"{label(ns, name)}.{v}",
                    f"enum {label(ns, name)} variant `{v}` is undocumented")

def normalise(value):
    v = value.strip().strip('`').strip('"')
    if v.startswith('$'):
        return str(int(v[1:], 16))
    if v.startswith('0x'):
        return str(int(v, 16))
    try:                          # 1e15 and 1000000000000000.0 are one value
        return repr(float(v.replace('_', '')))
    except ValueError:
        return v

# Constant rows: any table whose header has a `value` column.
rows, header = {}, None
for line in sheet.split('\n'):
    if not line.startswith('|'):
        header = None
        continue
    cells = [c.strip() for c in line.strip().strip('|').split('|')]
    if header is None:
        header = [c.lower() for c in cells]
        continue
    if 'value' not in header or set(line) <= set('|-: '):
        continue
    m = re.fullmatch(r'`(?:([a-z][A-Za-z0-9]*)\.)?([A-Z][A-Z0-9_]*)`', cells[0])
    if m and len(cells) > header.index('value'):
        key = resolve(m.group(1), m.group(2), consts)
        rows[key or (m.group(1), m.group(2))] = cells[header.index('value')]

for key, value in sorted(consts.items()):
    if key not in rows:
        missing(SHEET, label(*key), f"constant {label(*key)} is not in a constants table")
    elif value.startswith(('[', '{')) or re.match(r'[A-Z]\w*\{', value):
        pass                      # a table cell cannot hold a list, a map or a struct
    elif key not in generated and normalise(value) != normalise(rows[key]):
        note(SHEET, f"constant {label(*key)} is {value} in the code, "
                    f"{rows[key].strip()} in the table")
for key in sorted(set(rows) - set(consts), key=str):
    note(SHEET, f"a constants table lists {key[1]}, which is not exported")

# ---- 5: docblock drift ---------------------------------------------------
# No tags at all is a gap; tags that disagree with the declaration are drift.
# Outside src/ a name is not an export, so its todo entry is `file:name`.
def tags_match(f, kind, name, tag, documented, real):
    if documented == real:
        return
    what = f"{kind} {name}: @{tag} {documented} does not match {real}"
    if documented:
        note(f, what)
    elif f in sources:
        ns = SLUG if SHAPE == 'topics' else os.path.splitext(os.path.basename(f))[0]
        missing(f, label(ns, name), what)
    else:
        missing(f, f"{f}:{name}", what)

for f in sources + sorted(glob.glob('tools/*.j')) + sorted(glob.glob('examples/*.j')):
    src = open(f, encoding='utf-8').read()
    for m in re.finditer(
            r'/\*\*((?:(?!\*/).)*?)\*/\s*\n((?:export )?(?:func|def struct)[^\n{;]*)',
            src, re.S):
        doc, decl = m.group(1), m.group(2)
        # Jennifer's docblock module reads `@param name {type}`; the reversed
        # order parses as a parameter called `{type}`, so it is drift, not style
        for bad in re.findall(r'@(?:param|field)\s+\{[^}]*\}\s+\w+', doc):
            note(f, f"`{bad}` puts the type first - write `@param name {{type}}`")
        fn = re.match(r'(?:export )?func (\w+)\(([^)]*)\)', decl)
        if fn:
            real = [p.strip().split(' as ')[0].strip()
                    for p in fn.group(2).split(',') if p.strip()]
            tags_match(f, 'func', fn.group(1), 'param',
                       re.findall(r'@param\s+(\w+)\s+\{', doc), real)
        st = re.match(r'(?:export )?def struct (\w+)', decl)
        if st:
            body = re.search(r'def struct ' + st.group(1) + r' \{(.*?)\};', src, re.S)
            real = [x.strip().split(' as ')[0].strip()
                    for x in body.group(1).split(',') if x.strip()]
            tags_match(f, 'struct', st.group(1), 'field',
                       re.findall(r'@field\s+(\w+)\s+\{', doc), real)

# ---- 6: links, outline, layout listing -----------------------------------
for d in docs:
    base = os.path.dirname(d)
    for m in re.finditer(r'\[([^\]]*)\]\(([^)#]+?)(?:#[^)]*)?\)',
                         open(d, encoding='utf-8').read()):
        target = m.group(2)
        if target.startswith(('http', 'mailto:')):
            continue
        resolved = os.path.normpath(os.path.join(base, target))
        if not os.path.exists(resolved):
            note(d, f"link [{m.group(1)}]({target}) does not resolve")
        elif d.startswith('docs/') and not resolved.startswith('docs' + os.sep):
            # the published book is only what is under docs/, so a link that
            # walks out of it resolves in a checkout and 404s on the site
            note(d, f"link [{m.group(1)}]({target}) leaves docs/, so it works "
                    f"in a checkout but 404s on the published site")

summary = open('docs/SUMMARY.md', encoding='utf-8').read()
listed = set(re.findall(r'\]\(([^)]+)\)', summary))
present = {os.path.relpath(p, 'docs')
           for p in glob.glob('docs/**/*.md', recursive=True)} - {'SUMMARY.md'}
for orphan in sorted(present - listed):
    note('docs/SUMMARY.md', f"docs/{orphan} is not in the book outline")

where = 'docs/internal/directories.md'
if os.path.exists(where):
    listing = open(where, encoding='utf-8').read()
    if '```' not in listing:
        note(where, "no source listing")
    else:
        shown = set(re.findall(r'^(\S+\.j)\s', listing, re.M))
        actual = set(sources) | {f'src/{SLUG}_test.j'}
        for gone in sorted(shown - actual):
            note(where, f"the source listing names {gone}, which does not exist")
        for missed in sorted(actual - shown):
            note(where, f"the source listing does not name {missed}")

if LIST_GAPS:
    print('\n'.join(sorted(gaps)))
    sys.exit(0)

if problems:
    print("", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print(f"\n{len(problems)} documentation problem(s).", file=sys.stderr)
    sys.exit(1)

print(f"docs name {len(funcs)} functions, {len(structs)} structs, "
      f"{len(enums)} enums and {len(consts)} constants, all matching the code")
if backlog:
    print(f"  except {len(backlog)} carried in {TODO} - shrink that file")
PYSTATIC

[[ "$mode" == check ]] || exit 0

# --- 7: what Jennifer's docblock parser says --------------------------------
# The parser that reads docblocks for Jennifer's own tooling, so a docblock
# it rejects is wrong whatever the checks above think. The driver is written
# inside the checkout, not /tmp: in CI the interpreter runs in a container
# that only has the workspace mounted. Gitignored as .docblocks-*.
mapfile -t documented < <(find src -name '*.j' ! -name '*_test.j' | sort)
if (( ${#documented[@]} )); then
    work="$(mktemp -d "${PWD}/.docblocks-XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    cat > "$work/check.j" <<'JDOCBLOCK'
use io;
use os;
use fs;

import "docblock.j" as docblock;

def count as int init 0;
for (def i in 1..len(os.ARGS)) {
    def doc as docblock.FileDoc init docblock.parse(fs.readString(os.ARGS[$i]));
    for (def d in $doc.diagnostics) {
        io.printf("  %s line %d: %s\n", os.ARGS[$i], $d.line, $d.message);
        $count = $count + 1;
    }
}
if ($count > 0) {
    io.printf("\n%d docblock(s) rejected by Jennifer's docblock module.\n", $count);
    exit 1;
}
io.printf("Jennifer's docblock module accepts all %d source file(s)\n", len(os.ARGS) - 1);
JDOCBLOCK
    "$JENNIFER" run "$(basename "$work")/check.j" "${documented[@]}"
fi

# --- 8: the values the guides claim ----------------------------------------
if [[ ! -f tools/doc-claims.j ]]; then
    echo "no tools/doc-claims.j in this deck - skipping the value claims"
    exit 0
fi

claims="$($JENNIFER run tools/doc-claims.j)"
printf '%s\n' "$claims" | sed -n '/matches the code$/p;/MISMATCH/p'

# Every integer a guide annotates a snippet with must be one of the values
# asserted by doc-claims.j. Without this a number edited in the markdown alone
# - code and assertions untouched - would go unnoticed. Declarations,
# assignments and imports carry no value of their own to claim.
python3 - "$claims" <<'PYCLAIMS'
import re, sys, glob, collections

asserted = collections.defaultdict(set)
for m in re.finditer(r'^claim (\S+) .*? => (.*)$', sys.argv[1], re.M):
    asserted[m.group(1)].add(m.group(2).strip())

bad = 0
checked = 0
for doc in sorted(glob.glob('docs/**/*.md', recursive=True)):
    for blk in re.findall(r'```jennifer\n(.*?)```',
                          open(doc, encoding='utf-8').read(), re.S):
        for line in blk.split('\n'):
            m = re.match(r'^\s*(\S.*?);\s*#\s*(.+)$', line)
            if not m or re.match(r'(def |import|use |\$\w+ = )', m.group(1)):
                continue
            lit = re.match(r'^(-?\d+)\b', m.group(2).strip())
            if not lit:
                continue          # a prose annotation, not a value
            checked += 1
            if lit.group(1) not in asserted.get(doc, set()):
                print(f"  {doc}: the snippet `{m.group(1)}` claims {lit.group(1)}, "
                      f"which tools/doc-claims.j never asserts", file=sys.stderr)
                bad += 1
if bad:
    print(f"\n{bad} of {checked} annotated value(s) are unverified.", file=sys.stderr)
    sys.exit(1)
print(f"all {checked} value(s) the guides annotate are asserted against the code")
PYCLAIMS

# Each listing doc-claims.j prints must appear verbatim in the guide it names.
python3 - "$claims" <<'PYLISTING'
import re, sys
blocks = re.findall(r'<<<listing (\S+)\n(.*?)>>>', sys.argv[1], re.S)
bad = 0
for where, listing in blocks:
    doc = open(where, encoding='utf-8').read()
    for line in [l for l in listing.split('\n') if l.strip()]:
        if line not in doc:
            print(f"  {where}: does not show the line {line!r} that "
                  f"tools/doc-claims.j now prints", file=sys.stderr)
            bad += 1
if bad:
    print(f"\n{bad} listing line(s) in the docs are stale.", file=sys.stderr)
    sys.exit(1)
print(f"the {len(blocks)} listing(s) the docs print are still exact")
PYLISTING
