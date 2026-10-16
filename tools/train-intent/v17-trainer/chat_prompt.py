"""The CHAT prompt renderer — the single place the chat-shape
app/train template identity is enforced.

Stage 3 of the brain conversational-augmentation plan (2026-09-23).

`seeds/prompt_template_chat.txt` mirrors `IntentPrompt.buildChat`
(ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift) — the Swift source
of truth — with that template's TWO interpolations rendered as
placeholders: `{language_hint}` and `{transcript}`.

This is deliberately a SEPARATE module from `intent_prompt.py`, for the
same reason `IntentPrompt.buildChat` is a separate builder from
`IntentPrompt.build`:

  * the chat template has NO `{medications}` placeholder (buildChat
    composes no dose list), so `intent_prompt.render_prompt` — which
    REQUIRES all three placeholders and raises otherwise — cannot render
    it. Reusing it would have meant adding a third placeholder to the chat
    template that the app never sends.
  * the two templates teach different decodes (12-intent slot contract vs
    a three-key free-text reply), so keeping the renderers apart keeps a
    future edit to one from silently moving the other's bytes.

BYTE-IDENTITY CONTRACT (verified by `src/chat_prompt_check.py`):

    rendered = quick_render(seed, transcript)     # {language_hint} -> "ne"
    training_text = rendered + JSON label + <|im_end|>

    rendered == IntentPrompt.buildChat(transcript:context:)   # exactly

Note the construction difference from the command path. The seed here IS
the Swift value byte-for-byte, including the trailing blank line the
multi-line literal produces, so `to_text` must NOT insert a separator
newline between the template and the label. (The command path's seed is
the Swift value minus one trailing newline and `train_qlora.to_text` adds
that newline back; both arrive at the same place by different routes. This
module uses the direct route, which is the one that can be checked against
the Swift text without an arithmetic step.)
"""
from __future__ import annotations

DEFAULT_LANGUAGE_HINT = "ne"  # AppCoordinator: activeLocale.languageCode ?? "ne"
# v17 (T-183): the CNR seed `seeds/chat_prompt_template.txt` mirrors the
# CURRENT IntentPrompt.buildChat, which carries THREE interpolations — the
# added `address_as_clause` renders the app's fresh-install default:
# `addressAsClause(nil)` returns "" (IntentPrompt.swift:142-145), so an
# un-personalized turn sends NO clause (byte-identical to the pre-feature
# text). Recorded in specs/CNR-v17-run-notes.md.
DEFAULT_ADDRESS_AS_CLAUSE = ""  # un-personalized turn (fresh install)

CHAT_PLACEHOLDERS = ("{language_hint}", "{address_as_clause}", "{transcript}")


def render_chat_prompt(template: str, transcript: str,
                       language_hint: str = DEFAULT_LANGUAGE_HINT,
                       address_as_clause: str = DEFAULT_ADDRESS_AS_CLAUSE) -> str:
    """Fill the chat template's two placeholders for one utterance.

    Raises ValueError when the template is missing either placeholder or
    still carries a third (`{medications}`): a stale or command-shaped
    template must fail loudly instead of silently teaching the model
    literal placeholder text — the same failure mode
    `intent_prompt.render_prompt` guards on the command side.
    """
    missing = [p for p in CHAT_PLACEHOLDERS if p not in template]
    if missing:
        raise ValueError(
            f"chat prompt template is missing placeholder(s) {missing} — it "
            "is not the current IntentPrompt.buildChat template; update "
            "seeds/prompt_template_chat.txt in the SAME change as the Swift "
            "text")
    if "{medications}" in template:
        raise ValueError(
            "chat prompt template carries {medications} — buildChat composes "
            "no dose list, so this is a command-shaped template")
    return (template
            .replace("{language_hint}", language_hint)
            .replace("{address_as_clause}", address_as_clause)
            .replace("{transcript}", transcript))
