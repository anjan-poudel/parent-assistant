"""Shared prompt rendering — the single place the app/train template
identity is enforced (README §Training: training/inference prompt identity
is a hard requirement).

seeds/prompt_template.txt mirrors IntentPrompt.build (the Swift source of
truth) with that template's three interpolations rendered as placeholders:
{language_hint}, {medications}, {transcript}. Training (`train_qlora.to_text`)
and both eval backends (`eval_golden`) MUST render the template the same
way: a renderer that only fills {transcript} would train and gate the model
on a prompt that still contains the literal text "{language_hint}" —
exactly the drift class the identity rule exists to prevent.

Defaults mirror the app's on-device call site for the common case: the
language hint is "ne" (AppCoordinator passes activeLocale.languageCode
?? "ne"; InterpreterContext documents "ne" or "en") and an empty pending-
medication list renders as "(none)" (IntentPrompt.build's own rendering).
So the training prompt is byte-identical to what the app sends for a
Nepali-locale user with no scheduled doses.
"""
from __future__ import annotations

DEFAULT_LANGUAGE_HINT = "ne"
DEFAULT_MEDICATIONS = "(none)"  # IntentPrompt.build's empty-list rendering

PLACEHOLDERS = ("{language_hint}", "{medications}", "{transcript}")


def render_prompt(template: str, transcript: str,
                  language_hint: str = DEFAULT_LANGUAGE_HINT,
                  medications: str = DEFAULT_MEDICATIONS) -> str:
    """Fill the template's three placeholders for one utterance.

    Raises ValueError when the template is missing any placeholder: a
    stale (pre-slim) template must fail loudly instead of silently
    teaching the model literal placeholder text.
    """
    missing = [p for p in PLACEHOLDERS if p not in template]
    if missing:
        raise ValueError(
            f"prompt template is missing placeholder(s) {missing} — it is "
            "not the current IntentPrompt template; update "
            "seeds/prompt_template.txt in the SAME change as the Swift text")
    return (template
            .replace("{language_hint}", language_hint)
            .replace("{medications}", medications)
            .replace("{transcript}", transcript))
