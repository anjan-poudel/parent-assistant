#!/bin/bash
#
# check-prompt-mirror.sh — training/inference prompt-identity gate
# (T-094, C08; extended by [CNR] T-170 with the chat discipline).
#
# Entry point kept in shell so the gate stays one line in ios/build.sh. The
# checks live in check-prompt-mirror.py: Swift multiline-literal extraction
# and the interpolation-anchor validation are not reasonably expressible in a
# shell one-liner, and a gate that cannot tell a missing anchor from a
# duplicated one is indistinguishable from one that has stopped firing.
#
# Two things run here, in this order:
#
#   1. the checker over the real tree:
#        a. IntentPrompt.build's literal versus
#           tools/train-intent/seeds/prompt_template.txt, byte-for-byte
#           after the four interpolations are mapped to their placeholders;
#        b. the PINNED intent prompt (FR-CNR-023): the seed + the training
#           renderer reproduce both sha256 digests IntentPromptTests records
#           (this gate never moves a pin — a legitimate change moves the
#           Swift pins and these together, explicitly, in one change);
#        c. IntentPrompt.buildChat's literal versus
#           tools/train-intent/seeds/chat_prompt_template.txt, byte-for-byte
#           after its three interpolations are mapped to their placeholders;
#        d. BOTH persona constants — LlamaCommandInterpreter
#           .chatPersonaSystemPrompt and GeminiCommandInterpreter
#           .replyPersona — ending with the style spec's persona_clause
#           byte-for-byte, exactly once, inside their own wrapper;
#        e. the guard's four embedded machine blocks (register, particles,
#           code_switch, guard_checks) versus the style spec's block bodies,
#           byte-for-byte;
#        f. the chat token budget (NFR-CNR-004): the worst-case prompt side
#           (local persona + the template at the 80-Character
#           personalization bound) inside its share of the 1,024-token
#           context (1,024 − the 512-token turn/reply allowance), with the
#           margin printed for T-186's sweep.
#   2. the checker's own mutation suite (`--self-test`) — the negative path
#      on a temp copy: a flipped seed byte, a dropped placeholder, an altered
#      seed line, a dropped or duplicated Swift interpolation, a broken
#      extraction, a broken intent-pin digest, every chat-seed/chat-builder
#      drift class, a drifted or duplicated persona clause, a wrapper-less
#      persona, a flipped guard block, a missing block marker, and a
#      consistent-but-over-budget template must each be rejected by name.
#
# A gate whose negative path is never exercised is not trusted: the self-test
# run is not optional and cannot be switched off by configuration.
#
# REGENERATION when a chat-prompt change is legitimate (one obvious path):
# edit IntentPrompt.buildChat FIRST (it is the source of truth), then
#
#     python3 ios/tools/check-prompt-mirror.py --regen-chat-seed
#
# and commit the builder + the seed in the SAME change. The intent prompt
# follows the same rule (edit IntentPrompt.build and seeds/prompt_template.txt
# together; if the change is ever legitimate it also moves the recorded pin,
# explicitly, in one change). Never hand-edit either seed.
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
