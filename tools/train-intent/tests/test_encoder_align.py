"""T-034 §4.3/§4.4 alignment tests — pure functions, no torch, no tokenizer.

The tokenizer is faked with a word-level one (one token per whitespace word,
offsets in code points, <s>/</s> as (0,0) specials): exactly the contract the
real XLM-R sentencepiece exposes to `encode_row`, and proof that the projection
table is right without a 250k-vocab download.

Offsets are always COMPUTED (`sp()` below), never typed by hand — Devanagari
code-point counts are exactly the thing a hand-written literal gets wrong, and
a wrong literal here would test the test rather than the code.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

from encoder_align import (  # noqa: E402
    AlignError, canonical_text_violations, check_token_recoverable, decode_spans,
    encode_row, intersect_word, project_token_tags, spans_of_label, tag_id_for,
    validate_spans, word_offsets, word_tags_from_spans,
)

SPAN_LABELS = ("contact", "time", "medication", "message", "topic", "app")
TAGS = ("O", "B-contact", "I-contact", "B-time", "I-time", "B-medication",
        "I-medication", "B-message", "I-message", "B-topic", "I-topic", "B-app", "I-app")
TAG2ID = {t: i for i, t in enumerate(TAGS)}


def sp(utterance: str, label: str, text: str, start: int = -1) -> dict:
    """A validated span for `text` in `utterance` with computed code points."""
    i = utterance.index(text) if start < 0 else start
    assert utterance[i:i + len(text)] == text
    return {"label": label, "text": text, "start": i, "end": i + len(text)}


class FakeTokenizer:
    """Word-level tokenizer: matches what XLM-R produces for Nepali words."""

    def __init__(self):
        self.vocab: dict[str, int] = {}

    def __call__(self, text_or_words, add_special_tokens=True,
                 return_offsets_mapping=False, **_kw):
        words = text_or_words.split() if isinstance(text_or_words, str) \
            else list(text_or_words)
        text = " ".join(words)
        offs, ids, pos = [], [0], 0
        for w in words:
            i = text.index(w, pos)
            offs.append((i, i + len(w)))
            ids.append(self.vocab.setdefault(w, len(self.vocab) + 1))
            pos = i + len(w)
        offs, ids = [(0, 0)] + offs + [(0, 0)], ids + [2]
        return {"input_ids": ids, "offset_mapping": offs}


class TestOffsets(unittest.TestCase):
    def test_word_offsets_devanagari(self):
        u = "बिहान ८ बजे औषधि खान सम्झाउनु"
        offs = word_offsets(u)
        self.assertEqual(len(offs), len(u.split()))
        for (a, b), w in zip(offs, u.split()):
            self.assertEqual(u[a:b], w)

    def test_word_offsets_are_code_points(self):
        u = "हरिलाई फोन गर"
        first = word_offsets(u)[0]
        self.assertEqual(first, (0, len("हरिलाई")))
        self.assertNotEqual(first[1], 2 * len("हरिलाई"))  # not UTF-16 bytes

    def test_canonical_text_violations(self):
        self.assertEqual(canonical_text_violations("हरिलाई फोन गर"), [])
        self.assertIn("non_canonical_whitespace", canonical_text_violations("हरि  लाई"))
        self.assertIn("control_whitespace", canonical_text_violations("हरि\nलाई"))
        self.assertIn("empty", canonical_text_violations("   "))


class TestValidateSpans(unittest.TestCase):
    def test_ok(self):
        u = "भोलि बिहान नौ बजे डाक्टरलाई फोन गर्न सम्झाइदिनु"
        spans = [sp(u, "time", "भोलि बिहान नौ बजे"), sp(u, "contact", "डाक्टरलाई")]
        self.assertEqual(validate_spans(u, spans), [])
        self.assertEqual(len(spans_of_label(spans, "time")), 1)

    def test_text_mismatch_and_range(self):
        u = "हरिलाई फोन गर"
        bad = [{"label": "contact", "text": "गीता", "start": 0, "end": 4},
               {"label": "time", "text": "गर", "start": 99, "end": 101}]
        v = validate_spans(u, bad)
        self.assertIn("offset_text_mismatch", v)
        self.assertIn("offset_out_of_range", v)

    def test_duplicate_and_overlap_are_refused(self):
        u = "हरिलाई फोन गर"
        s = sp(u, "contact", "हरिलाई")
        self.assertIn("duplicate_span", validate_spans(u, [s, dict(s)]))
        overlapping = [s, {"label": "time", "text": "रिलाई", "start": 1, "end": 6}]
        self.assertIn("overlapping_spans", validate_spans(u, overlapping))

    def test_adjacent_same_label_must_be_merged(self):
        u = "हरिलाई फोन गर"          # split inside the first word: end == start
        spans = [{"label": "contact", "text": "हरि", "start": 0, "end": 3},
                 {"label": "contact", "text": "लाई", "start": 3, "end": 6}]
        self.assertIn("adjacent_same_label_not_merged", validate_spans(u, spans))


class TestWordTags(unittest.TestCase):
    def test_multiword_span_gets_b_then_i(self):
        u = "भोलि बिहान नौ बजे फोन गर"
        spans = [sp(u, "time", "भोलि बिहान नौ बजे")]
        self.assertEqual(word_tags_from_spans(u, spans, SPAN_LABELS),
                         ["B-time", "I-time", "I-time", "I-time", "O", "O"])

    def test_partial_word_span_widens_to_the_word(self):
        u = "कृष्णलाई फोन गर"          # span covers part of the first word only
        spans = [{"label": "contact", "text": "कृष्ण", "start": 0,
                  "end": len("कृष्ण")}]
        self.assertEqual(word_tags_from_spans(u, spans, SPAN_LABELS)[0], "B-contact")

    def test_no_spans_is_all_o(self):
        self.assertEqual(word_tags_from_spans("हरिलाई फोन गर", [], SPAN_LABELS),
                         ["O", "O", "O"])

    def test_non_verbatim_span_raises(self):
        with self.assertRaises(AlignError):
            word_tags_from_spans("हरिलाई फोन गर",
                                 [{"label": "contact", "text": "गीता", "start": 0, "end": 4}],
                                 SPAN_LABELS)

    def test_unknown_label_raises(self):
        u = "हरिलाई फोन गर"
        with self.assertRaises(AlignError):
            word_tags_from_spans(u, [sp(u, "engine", "हरिलाई")], SPAN_LABELS)


class TestTokenProjection(unittest.TestCase):
    def test_specials_get_none(self):
        offs = [(0, 0), (0, 6), (7, 10), (0, 0)]
        words = [(0, 6), (7, 10)]
        out = project_token_tags(offs, words, ["B-contact", "O"], TAG2ID)
        self.assertEqual(out, [None, TAG2ID["B-contact"], TAG2ID["O"], None])

    def test_intersect_word_ignores_zero_width(self):
        self.assertIsNone(intersect_word((0, 0), [(0, 6)]))
        self.assertEqual(intersect_word((0, 3), [(0, 6)]), 0)

    def test_decode_uses_offsets_not_token_strings(self):
        u = "हरिलाई फोन गर"
        c = len("हरिलाई")
        offs = [(0, 0), (0, c), (c + 1, c + 4), (c + 5, c + 8), (0, 0)]
        ids = [None, TAG2ID["B-contact"], TAG2ID["O"], TAG2ID["O"], None]
        spans = decode_spans(u, offs, ids, TAGS)
        self.assertEqual(spans, [{"label": "contact", "text": "हरिलाई",
                                  "start": 0, "end": c}])
        self.assertNotIn("▁", spans[0]["text"])

    def test_decode_multi_token_span_and_merge(self):
        u = "भोलि बिहान फोन गर"
        t = len("भोलि")
        offs = [(0, 0), (0, t), (t + 1, t + 1 + len("बिहान")),
                (t + 2 + len("बिहान"), t + 2 + len("बिहान") + len("फोन")),
                (len(u) - len("गर"), len(u)), (0, 0)]
        ids = [None, TAG2ID["B-time"], TAG2ID["I-time"], TAG2ID["B-contact"],
               TAG2ID["O"], None]
        spans = decode_spans(u, offs, ids, TAGS)
        self.assertEqual([(s["label"], s["text"]) for s in spans],
                         [("time", "भोलि बिहान"), ("contact", "फोन")])

    def test_decode_strips_whitespace_between_tokens(self):
        """A byte-level BPE marks a word start with '▁'; the offset path must
        never surface that marker (the T-033 decode bug this guards)."""
        u = "हरिलाई फोन गर"
        c = len("हरिलाई")
        offs = [(0, 0), (0, c), (c + 1, c + 4), (0, 0)]
        ids = [None, TAG2ID["B-contact"], TAG2ID["B-contact"], None]
        spans = decode_spans(u, offs, ids, TAGS)
        self.assertEqual(spans[0]["text"], "हरिलाई फोन")   # offsets slice, no marker


class TestEncodeRow(unittest.TestCase):
    def setUp(self):
        self.tok = FakeTokenizer()

    def test_encode_row_projects_tags(self):
        u = "हरिलाई फोन गर"
        spans = [sp(u, "contact", "हरिलाई")]
        ids, tags = encode_row(self.tok, u, spans, SPAN_LABELS, TAG2ID)
        self.assertEqual(tags[0], None)                      # <s>
        self.assertEqual(tags[1], TAG2ID["B-contact"])
        self.assertEqual(tags[2:4], [TAG2ID["O"], TAG2ID["O"]])
        self.assertEqual(tags[-1], None)                     # </s>
        self.assertEqual(ids[0], 0)

    def test_span_without_tokens_is_refused(self):
        offs = [(0, 0), (0, 1), (2, 5), (0, 0)]
        v = check_token_recoverable("हरिलाई फोन",
                                    offs, [{"label": "contact", "text": "हरिलाई",
                                            "start": 0, "end": 6}])
        self.assertIn("span_not_covered_by_tokens", v)

    def test_tag_id_for(self):
        self.assertEqual(tag_id_for(TAGS, "time", "I"), TAG2ID["I-time"])
        with self.assertRaises(ValueError):
            tag_id_for(TAGS, "engine", "B")


if __name__ == "__main__":
    unittest.main()
