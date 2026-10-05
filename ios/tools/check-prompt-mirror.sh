#!/bin/bash
#
# check-prompt-mirror.sh — training/inference prompt-identity gate (T-094, C08).
#
# Entry point kept in shell so the gate stays one line in ios/build.sh. The
# checks live in check-prompt-mirror.py: Swift multiline-literal extraction
# and the four-interpolation anchor validation are not reasonably expressible
# in a shell one-liner, and a gate that cannot tell a missing anchor from a
# duplicated one is indistinguishable from one that has stopped firing.
#
# Two things run here, in this order:
#
#   1. the checker over the real tree — IntentPrompt.build's literal versus
#      tools/train-intent/seeds/prompt_template.txt, byte-for-byte after the
#      four interpolations are mapped to their placeholders;
#   2. the checker's own mutation suite (`--self-test`) — the negative path
#      on a temp copy: a flipped seed byte, a dropped placeholder, an altered
#      seed line, a dropped or duplicated Swift interpolation, and a broken
#      extraction must each be rejected by name.
#
# A gate whose negative path is never exercised is not trusted: the self-test
# run is not optional and cannot be switched off by configuration.
#
# Exit 0 = mirrored, 1 = drift (or a self-test that failed to fire).

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

/usr/bin/env python3 "${TOOLS_DIR}/check-prompt-mirror.py" || exit 1

/usr/bin/env python3 "${TOOLS_DIR}/check-prompt-mirror.py" --self-test || {
    echo "  ✗ the prompt-mirror gate's own mutation suite failed (see above)." >&2
    echo "    The gate is not trusted until its negative path fires; fix the" >&2
    echo "    checker, never delete the mutation." >&2
    exit 1
}
