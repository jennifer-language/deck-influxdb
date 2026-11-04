# AGENTS.md - working on this deck with a coding agent

Instructions for an AI coding agent (and a useful checklist for a human). This
file is the same in every deck repository; anything specific to *this* deck -
its architecture, its design decisions, the traps it has already hit - goes in
`CLAUDE.md` (or your tool's equivalent) beside it, not here.

## What this repository is

A **deck**: a library for the Jennifer language, consumed by vendoring its
`src/` subtree into another project (`jvc add`). There is nothing to compile.
The manifest (`deck.toml`, `deck.yaml`, `deck.yml` or `deck.json` - whichever
exists) is the source of truth for the name, version, licence and interpreter
floor. Read it first.

| Path | What it is |
|---|---|
| `src/<slug>.j` | the entry module - the one consumers import |
| `src/*_test.j` | white-box test overlays, one beside every module |
| `src/topics/` | only in a *topics* deck: files `include`d by the entry module |
| `examples/` | runnable programs; CI runs or parses every one |
| `docs/` | the book; `SUMMARY.md` is the outline, `cheatsheet.md` the API surface |
| `tools/` | the CI helpers; most are shared byte-identical between decks |
| `.github/` | the workflows; shared byte-identical between decks |

## Before you write any `.j` code

1. **Check `JENNIFER.md` is current.** Run `jennifer version` and compare it to
   the `<!-- jennifer-md-synced-for: ... -->` marker on the file's last line.
   If they differ, follow the sync steps at the top of `JENNIFER.md`. A stale
   copy is the most common reason generated code is rejected.
2. **Read `JENNIFER.md`**, at least "The 10 rules that trip people up". Jennifer
   looks like other languages and is not: `$` sigils, no compound assignment,
   `#` comments, value semantics, no underscores in identifiers.
3. **Read `CLAUDE.md`** if there is one, for this deck's own conventions.
4. **Look at the code you are changing and the overlay that tests it.** Match
   their naming, comment density and docblock style.

## The working loop

1. **Understand** the request. If it is ambiguous in a way the code cannot
   answer, ask before writing.
2. **Change the code** in the smallest coherent step.
3. **Test it.** Every behaviour change gets a test in the co-located overlay.
   A bug fix starts with a test that fails without the fix.
4. **Document it.** A new or changed export is updated in `docs/cheatsheet.md`,
   in the docblock, and in any guide or example that shows it.
5. **Format**: `jennifer fmt -w <files>`.
6. **Run the gate** (below) and fix what it reports. Do not stop at "the tests
   pass": CI also fails on formatting, lint warnings, headers, overlays and
   undocumented exports.
7. **Report** what you changed, which checks you ran, and their result. If a
   check failed or you skipped one, say so plainly.

## The gate, as CI runs it

```sh
tools/check-all.sh
```

It runs every check `.github/workflows/test.yml` runs, in the same order, keeps
going after a failure, and ends with the list of what failed. A deck with
`[decks]` dependencies needs `tools/vendor-deps.sh` once first. Single checks,
when you are iterating on one thing:

```sh
jennifer test src/<module>_test.j      # one suite (there is no finer filter)
jennifer fmt -l <files>                # exits 1 if anything is unformatted
jennifer lint <files>                  # exits 1 on a warning
tools/check-headers.sh                 # SPDX pair + floor match the manifest
tools/check-overlays.sh                # every module has a _test.j, and back
tools/check-src.sh                     # src/ holds only .j files
tools/check-coverage.sh                # every export is called from a test
tools/check-docs.sh                    # docs, signatures and docblocks match the code
tools/check-identity.sh                # no template placeholder left
tools/check-examples.sh                # every example still works
```

## Rules the gate enforces

- **Every `.j` file opens with three header lines**, matching the manifest:

  ```
  # SPDX-License-Identifier: <package.license>
  # SPDX-FileCopyrightText: Copyright (C) <year> <holder>
  # pragma-jennifer-version: <engines.jennifer>
  ```

  The licence and floor are stated twice on purpose; change both or neither.
- **Every module in `src/` (or `src/topics/`) has a co-located
  `<module>_test.j`.** jvc will not publish without it. Only generated data
  files may opt out, with a `# ci-no-overlay` header line or an entry in
  `src/.no-overlay`.
- **Every export has a signature in the cheatsheet** (`docs/cheatsheet.md`)
  with its real parameter names, every constant its real value, every struct
  its fields; every docblock's `@param` / `@field` match the declaration,
  written `@param name {type} what it is` - the order Jennifer's `docblock`
  module reads. The format is described at the top of the template's
  cheatsheet.
- **Every exported function is called from an overlay.**
- **Calls in the docs are checked.** Snippets import the deck under its own
  name (`import "@scope/<slug>/" as <slug>;`), and every `<slug>.name(...)`
  they show must exist and take that many arguments.
- **Known gaps are a backlog, not a licence.** `docs/.cheatsheet-todo` and
  `tools/.coverage-todo` list what an older deck has not documented or tested
  yet. Remove a line when you fix it; never add one to make a check pass.
- **Every chapter in `docs/SUMMARY.md` has a file behind it**, or the docs
  build fails.
- **`src/` holds only Jennifer source.** It is exactly what consumers vendor.

## Jennifer habits that save time

- `X_test.j` is a **white-box overlay** of `X.j`: it sees the internals, calls
  them unqualified, and inherits the module's imports. Re-importing one of them
  is an alias collision.
- `lint` fails on a *warning*, not on *info*. A `# lint-disable: ID` directive
  only works as a trailing comment on the offending line.
- `jennifer fmt` re-joins hand-wrapped lines. Shorten a long line instead of
  wrapping it.
- `{` in a `"..."` string starts an interpolation; write `\{`, or use a raw
  `'...'` string.
- In CI `jennifer` runs in a container that mounts only the checkout. Test
  fixtures go *inside* the repository, and paths passed to programs are
  *relative*.

## Boundaries

- **Do not edit the shared files** - every `shared` entry in
  `tools/shared-files`, which is the workflows, `.github/actions/*`, this file,
  and everything in `tools/` except `check-examples.sh` and `check-extra.sh` -
  to fix something local to this deck. They are synced from the template
  repository and must stay identical across decks; `tools/check-shared.sh`
  fails CI when one differs from `tools/shared.lock`. A
  deck-specific check belongs in `tools/check-extra.sh` (or a workflow of its
  own); examples that need inputs or a network belong in
  `tools/check-examples.sh`, which is the deck's to change. If a shared file
  really is wrong, say so and propose the change for the template instead.
- **Do not edit `LICENSE`**, and edit `JENNIFER.md` only through its sync
  procedure.
- **Do not add a dependency** (`[decks]`) or a capability (`net`, `exec`,
  `sql`, ...) without asking. A capability needs a comment in the manifest
  saying why.
- **Do not change the interpreter floor** (`engines.jennifer`) without asking:
  it decides which interpreter CI tests on and which consumers can use the
  deck.
- **Never commit build output**: `site/`, `dist/`, `vendor/`, fixtures.
- **Ask before anything that leaves the machine or is hard to undo**: pushing,
  tagging, creating a release, publishing, rewriting history.

## Versions and releases

The version lives in the manifest. A release is cut by pushing a tag that
matches it, plain `0.2.0` with no `v` prefix; `release.yml` refuses a tag
that disagrees. So the order is: bump the manifest, commit, then tag - and the
tag is the maintainer's call, not the agent's.
