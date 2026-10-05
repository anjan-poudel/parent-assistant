"""T-094 (C08) tests: the shared renderer's contract against the seed.

The app/train prompt identity is enforced by `ios/tools/check-prompt-mirror.py`
(Swift template vs seed, byte-for-byte). These tests cover the RENDERER half:
the default clause slot renders to nothing (so the no-term training corpus is
byte-identical to the pre-feature training prompt), a term renders the exact
clause shape the Swift `IntentPrompt.addressAsClause` produces, and a stale
template fails loudly instead of training on literal placeholder text.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from intent_prompt import (  # noqa: E402
    DEFAULT_ADDRESS_AS_CLAUSE,
    PLACEHOLDERS,
    render_prompt,
)

SEED = ROOT / "seeds" / "prompt_template.txt"


def _seed_text() -> str:
    return SEED.read_text(encoding="utf-8")


class SeedShapeTests(unittest.TestCase):
    def test_seed_carries_all_four_placeholders_exactly_once(self):
        seed = _seed_text()
        for placeholder in PLACEHOLDERS:
            self.assertEqual(
                seed.count(placeholder), 1,
                f"{placeholder} must appear exactly once in the seed")

    def test_the_clause_placeholder_follows_the_pinned_sentence(self):
        seed = _seed_text()
        self.assertIn("one short idea per sentence.{address_as_clause}\n",
                      seed,
                      "the clause slot must sit directly after the pinned "
                      "sentence — the same anchor as the Swift interpolation")


class DefaultRenderTests(unittest.TestCase):
    def test_default_render_erases_the_clause_slot_byte_exactly(self):
        rendered = render_prompt(_seed_text(), "भोलिको मौसम कस्तो छ?")
        self.assertNotIn("{address_as_clause}", rendered)
        self.assertNotIn("Address them as", rendered,
                         "the un-personalized render carries no clause")
        # The pre-feature adjacency, byte-exact: the erased slot leaves the
        # pinned sentence and the following line untouched.
        self.assertIn("one short idea per sentence.\n"
                      "Fill ONLY slots you heard", rendered)

    def test_default_clause_is_the_empty_string(self):
        self.assertEqual(DEFAULT_ADDRESS_AS_CLAUSE, "")
        rendered = render_prompt(_seed_text(), "x")
        explicit = render_prompt(_seed_text(), "x", address_as_clause="")
        self.assertEqual(rendered, explicit,
                         "the default IS the un-personalized render")

    def test_render_is_placeholder_free_and_deterministic(self):
        first = render_prompt(_seed_text(), "छोरालाई फोन गर")
        second = render_prompt(_seed_text(), "छोरालाई फोन गर")
        self.assertEqual(first, second)
        for placeholder in PLACEHOLDERS:
            self.assertNotIn(placeholder, first)


class PersonalizedRenderTests(unittest.TestCase):
    def test_a_term_renders_the_swift_clause_shape(self):
        # The exact string IntentPrompt.addressAsClause composes — the
        # renderer is passed the composed clause, never the bare term.
        clause = ' Address them as "Mum" where it fits, never every sentence.'
        rendered = render_prompt(_seed_text(), "x", address_as_clause=clause)
        self.assertIn('one short idea per sentence. Address them as "Mum" '
                      'where it fits, never every sentence.\n'
                      'Fill ONLY slots you heard', rendered)
        self.assertNotIn("{address_as_clause}", rendered)


class StaleTemplateTests(unittest.TestCase):
    def test_a_template_missing_the_clause_slot_raises(self):
        stale = _seed_text().replace("{address_as_clause}", "")
        with self.assertRaises(ValueError):
            render_prompt(stale, "x")

    def test_a_pre_feature_three_placeholder_template_raises(self):
        # The drift class the identity rule exists to prevent: a template
        # from before the clause must fail loudly, not train on it.
        stale = _seed_text().replace("{address_as_clause}", "")
        with self.assertRaises(ValueError) as raised:
            render_prompt(stale, "x")
        self.assertIn("{address_as_clause}", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
