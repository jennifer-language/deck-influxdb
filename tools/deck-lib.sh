# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Shared shell library for the deck CI helpers. Source it, do not run it.
#
# One copy of this file lives in every deck repository so the workflows can be
# byte-identical between them. Everything a deck differs in - which manifest
# format it uses, whether it is one module or a module plus included topics,
# whether it claims jennifer-tiny - is discovered here rather than hard-coded
# into a workflow.

# shellcheck shell=bash

deck_die() { echo "error: $*" >&2; exit 1; }

# --- the manifest ----------------------------------------------------------
#
# jvc accepts deck.toml, deck.yaml, deck.yml and deck.json, first present wins.
# Decks do use different ones, so everything here reads whichever is there.

deck_manifest() {
    local candidate
    for candidate in deck.toml deck.yaml deck.yml deck.json; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    deck_die "no deck.toml, deck.yaml, deck.yml or deck.json in $PWD"
}

# deck_field <dotted.path> [default]
#
# Reads a scalar out of the manifest. The path is the JSON shape - the TOML and
# YAML readers map onto it - so `package.version` and `engines.jennifer` work
# whichever format the deck ships.
deck_field() {
    local path="$1" fallback="${2-}" manifest value
    manifest="$(deck_manifest)"

    case "$manifest" in
        *.json)
            value="$(jq -r --arg p "$path" '
                getpath($p | split(".")) // empty
                | if type == "array" then .[0] else . end
            ' "$manifest" 2>/dev/null || true)"
            ;;
        *.toml)
            value="$(deck_scalar_toml "$manifest" "$path")"
            ;;
        *.yaml | *.yml)
            value="$(deck_scalar_yaml "$manifest" "$path")"
            ;;
    esac

    value="${value%\"}"; value="${value#\"}"
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s\n' "$fallback"
    else
        printf '%s\n' "$value"
    fi
}

# TOML: `[section]` headers with `key = "value"` beneath. `package.urls.deck`
# means the `deck` key under `[package.urls]`.
deck_scalar_toml() {
    local file="$1" path="$2" section="${2%.*}" key="${2##*.}"
    [[ "$path" == "$key" ]] && section=""
    awk -v want="$section" -v key="$key" '
        /^[[:space:]]*\[/ {
            s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\].*$/, "", s)
            cur = s; next
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line !~ "^" key "[[:space:]]*=") next
            if (cur != want) next
            sub(/^[^=]*=[[:space:]]*/, "", line)
            if (line ~ /^\[/) {                        # first element of an array
                sub(/^\[[[:space:]]*/, "", line)
                sub(/\][[:space:]]*$/, "", line)
                sub(/,.*$/, "", line)
            }
            gsub(/^"|"$/, "", line)
            print line; exit
        }
    ' "$file"
}

# YAML: two-space nesting, `key: value`. Same dotted path.
deck_scalar_yaml() {
    local file="$1" path="$2"
    python3 - "$file" "$path" <<'PY'
import re, sys

path = sys.argv[2].split(".")
want_depth = len(path) - 1
depth_of = lambda s: (len(s) - len(s.lstrip(" "))) // 2

cur, value = [], None
for raw in open(sys.argv[1]):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    m = re.match(r"^(\s*)([A-Za-z0-9_.\-\"@/]+):\s*(.*)$", line)
    if not m:
        continue
    indent, key, rest = depth_of(m.group(1) + "x"), m.group(2).strip('"'), m.group(3)
    cur = cur[:indent] + [key]
    if cur == path and rest:
        value = rest
        break

if value is not None:
    value = value.split("#")[0].strip()
    if value.startswith("["):                      # first element of a flow list
        value = value[1:].split(",")[0].strip()
    print(value.strip().strip('"').strip("'"))
PY
}

# --- identity --------------------------------------------------------------

deck_load() {
    DECK_MANIFEST="$(deck_manifest)"
    DECK_NAME="$(deck_field package.name)"
    [[ -n "$DECK_NAME" ]] || deck_die "$DECK_MANIFEST declares no package.name"
    DECK_SCOPE="${DECK_NAME#@}"; DECK_SCOPE="${DECK_SCOPE%%/*}"
    DECK_SLUG="${DECK_NAME##*/}"
    DECK_VERSION="$(deck_field package.version)"
    DECK_LICENSE="$(deck_field package.license)"
    DECK_FLOOR="$(deck_field engines.jennifer)"

    # A deck claims the constrained binary by listing it in [engines].
    if [[ -n "$(deck_field engines.jennifer-tiny)" ]]; then
        DECK_TINY=yes
    else
        DECK_TINY=no
    fi

    # Two shapes. A `topics` deck is one compilable module that `include`s its
    # topic files; a topic cannot be linted or tested alone, because in
    # isolation its calls into the module read as undefined.
    if [[ -d src/topics ]]; then
        DECK_SHAPE=topics
    else
        DECK_SHAPE=modules
    fi

    DECK_ENTRY="src/${DECK_SLUG}.j"
    [[ -f "$DECK_ENTRY" ]] || deck_die "no entry module $DECK_ENTRY for $DECK_NAME"

    export DECK_MANIFEST DECK_NAME DECK_SCOPE DECK_SLUG DECK_VERSION \
           DECK_LICENSE DECK_FLOOR DECK_TINY DECK_SHAPE DECK_ENTRY
}

# --- the interpreter image -------------------------------------------------
#
# Which container CI runs is a property of the deck's floor, not of the
# workflow. The interpreter enforces `# pragma-jennifer-version` when it reads
# a file, so a deck whose floor is a *released* version must be tested on that
# release: a dev build bypasses the floor, which would let a construct from a
# newer language version slip in and break every consumer on the old one.
#
# A deck whose floor is not released yet has no such image, and a dev build is
# the only thing that will load it at all.
#
# Bump this when a new interpreter is released.
JENNIFER_NEWEST_RELEASE="0.25"

deck_image() {
    # An explicit override always wins - useful for bisecting.
    if [[ -n "${JENNIFER_IMAGE:-}" ]]; then
        printf '%s\n' "$JENNIFER_IMAGE"
        return 0
    fi

    local floor series
    floor="${DECK_FLOOR:-}"
    # ">=0.24.0" -> "0.24"
    series="$(sed -E 's/^[^0-9]*([0-9]+\.[0-9]+).*/\1/' <<<"$floor")"

    if [[ -z "$series" ]]; then
        printf 'ghcr.io/jennifer-language/jennifer:dev\n'
        return 0
    fi

    # Released series, or newer than anything released?
    if [[ "$(printf '%s\n%s\n' "$series" "$JENNIFER_NEWEST_RELEASE" | sort -V | tail -1)" == "$JENNIFER_NEWEST_RELEASE" ]]; then
        printf 'ghcr.io/jennifer-language/jennifer:%s\n' "$series"
    else
        printf 'ghcr.io/jennifer-language/jennifer:dev\n'
    fi
}

# The interpreter source ref matching deck_image, for a job that builds the
# interpreter rather than pulling it - jennifer-tiny has no published image.
# Same rule: `dev` builds main, a released series builds its newest patch tag,
# and an image pinned to an exact version builds that version.
JENNIFER_REPO="https://github.com/jennifer-language/jennifer"

deck_source_ref() {
    local tag series
    tag="$(deck_image)"; tag="${tag##*:}"

    if [[ "$tag" == dev ]]; then
        printf 'main\n'
        return 0
    fi
    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$tag"
        return 0
    fi

    series="${tag//./\\.}"
    tag="$(git ls-remote --tags --refs "$JENNIFER_REPO" \
        | sed -E 's#.*refs/tags/##' \
        | grep -E "^${series}\.[0-9]+$" \
        | sort -V | tail -1 || true)"
    [[ -n "$tag" ]] || deck_die "no ${series//\\/}.x release tag at $JENNIFER_REPO"
    printf '%s\n' "$tag"
}

# --- file sets -------------------------------------------------------------

# The cheatsheet: docs/cheatsheet.md, or docs/reference/cheatsheet.md in a book
# that has a reference part. Prints nothing when the deck has neither.
deck_cheatsheet() {
    local candidate
    for candidate in docs/cheatsheet.md docs/reference/cheatsheet.md; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
}

# Every .j file that must carry a header and be formatted.
deck_all_sources() {
    find src examples tools -name '*.j' 2>/dev/null | sort
}

# The compilable units to lint. For a topics deck that is the module, its
# overlay, and the standalone programs; the topics are reached through the
# include splice.
deck_lint_units() {
    if [[ "$DECK_SHAPE" == topics ]]; then
        printf '%s\n' "$DECK_ENTRY" "src/${DECK_SLUG}_test.j"
    else
        find src -maxdepth 1 -name '*.j' | sort
    fi
    find examples tools -name '*.j' 2>/dev/null | sort
}

# The test overlays to run.
deck_test_suites() {
    if [[ "$DECK_SHAPE" == topics ]]; then
        printf '%s\n' "src/${DECK_SLUG}_test.j"
    else
        find src -maxdepth 1 -name '*_test.j' | sort
    fi
}

# Modules that must have a co-located overlay.
#
# A file opts out either with a `# ci-no-overlay` line in its header, or by
# being listed in src/.no-overlay - one path per line, `#` for comments. The
# sidecar exists for generated files, whose header a generator would overwrite
# on its next run. Both are for data, not behaviour: a module with logic in it
# needs a test.
deck_testable_modules() {
    local dir=src exempt=src/.no-overlay
    [[ "$DECK_SHAPE" == topics ]] && dir=src/topics
    find "$dir" -maxdepth 1 -name '*.j' ! -name '*_test.j' | sort | while read -r f; do
        grep -q '^# ci-no-overlay' "$f" && continue
        if [[ -f "$exempt" ]] && grep -qxF -- "$f" "$exempt"; then
            continue
        fi
        printf '%s\n' "$f"
    done
}
