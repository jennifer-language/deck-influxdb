#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# How this deck's examples are checked. This file belongs to the deck, not to
# the shared CI layer: the workflows call it, and it is the place to say what
# the examples need.
#
# By default every example is simply run, by tools/check-examples-shared.sh.
# When that cannot work, replace this body and say why here:
#
#   examples call a live service or need credentials
#       exec env EXAMPLES_SKIP_RUN=1 tools/check-examples-shared.sh
#   examples read input files
#       build fixtures *inside the checkout* (CI's interpreter is a container
#       that mounts only the workspace), run each example against them with
#       relative paths, and clean up
#
# Usage: tools/check-examples.sh
set -euo pipefail
cd "$(dirname "$0")/.."
exec tools/check-examples-shared.sh "$@"
