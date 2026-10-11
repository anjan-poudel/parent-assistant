"""stt-ngram-prior builder tests (correction-revive, 2026-10-11).

Run from tools/train-intent/:

    python3 -m unittest discover -s tests -v

Two layers, mirroring tests/test_extract_stt_errors.py:
  - unit tests over the pure functions (symmetric_deletes, count_ngrams,
    the band pinning) with no subprocess;
  - an integration test that executes src/stt_ngram_prior.py end-to-end
    against the committed fixture and asserts the pinned counts and the
    --check pass — the fixture's contract moves only when the fixture
    moves.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
SRC = ROOT / "src"
FIXTURE = ROOT / "tests" / "data" / "ngram_prior" / "corpus.jsonl"
sys.path.insert(0, str(SRC))

import stt_ngram_prior as N  # noqa: E402  (path set above)

# The fixture's measured contract (corpus.jsonl — see the file's header).
# Bigram/trigram counts are the COUNT-FLOOR-KEPT set (pairs ≥ 2).
FIXTURE_ROWS = 5
FIXTURE_UNIGRAMS = 10
FIXTURE_BIGRAMS = 4
FIXTURE_TRIGRAMS = 1
FIXTURE_DELETE_FORMS = 57


def run_prior(corpus: Path, *extra: str):
    return subprocess.run(
        [sys.executable, str(SRC / "stt_ngram_prior.py"),
         "--corpus", str(corpus), "--min-rows", "0", "--min-lexicon", "0",
         *extra],
        cwd=ROOT, capture_output=True, text=True)


class SymSpellTests(unittest.TestCase):
    def test_delete_one_forms_are_scalar_deletions(self):
        token = "गर्नु"
        forms = N.symmetric_deletes(token)
        self.assertEqual(len(forms), len(token),
                         "delete-1 over scalars yields len(token) forms")
        self.assertIn("र्नु", forms)
        self.assertIn("गर्न", forms)
        self.assertNotIn("", forms, "a single-scalar deletion never emits "
                         "the empty string")

    def test_devanagari_combining_marks_delete_individually(self):
        # `गर्नुहोस्` ends with virama+स; scalar deletion treats the
        # combining mark as its own scalar, exactly like the Swift runtime's
        # scalar-based offsets.
        token = "गर्नुहोस्"
        forms = N.symmetric_deletes(token)
        self.assertIn("गर्नुहोस", forms, "the halanta deletes on its own")
        self.assertIn("गर्नुहो्", forms)  # ... or the स before it goes


class CountTests(unittest.TestCase):
    def test_bigram_keys_are_joined_with_double_pipe(self):
        unigram, bigram, trigram, _ = N.count_ngrams(["एक दुई तीन"])
        self.assertIn("एक||दुई", bigram)
        self.assertIn("दुई||तीन", bigram)
        self.assertIn("एक||दुई||तीन", trigram)

    def test_core_normalisation_strips_punctuation_from_keys(self):
        unigram, bigram, _, _ = N.count_ngrams(["खाना! खानुहोस्।"])
        self.assertIn("खाना", unigram)
        self.assertIn("खाना||खानुहोस्", bigram)


class BandTests(unittest.TestCase):
    def test_bands_are_pinned_to_the_v3_measured_operating_point(self):
        bank = N.build_bank(["कुनै उदाहरण वाक्य हो"], "fixture")
        bands = bank["bands"]
        self.assertEqual(bands["surfaceFloor"], 0.8125)
        self.assertEqual(bands["applyTotal"], 0.8125,
                         "applyTotal must equal surfaceFloor until a v4 "
                         "re-fit measures a wider silent-apply set")
        self.assertLess(bands["judgeMin"], bands["surfaceFloor"])
        self.assertIn("authored", bands["origin"])

    def test_invariants_reject_out_of_order_bands(self):
        bank = N.build_bank(["कुनै उदाहरण वाक्य हो"], "fixture")
        bank["bands"]["judgeMin"] = 0.9
        problems = N.check_invariants(bank)
        self.assertTrue(any("bands out of order" in p for p in problems))


class IntegrationTests(unittest.TestCase):
    def test_end_to_end_counts_match_the_fixture_contract(self):
        self.assertTrue(FIXTURE.is_file(), "the fixture corpus must be committed")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "stt-ngram-prior.json"
            result = run_prior(FIXTURE, "--out", str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            bank = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(bank["corpus"]["rows"], FIXTURE_ROWS)
            self.assertEqual(len(bank["lexicon"]), FIXTURE_UNIGRAMS)
            self.assertEqual(len(bank["bigrams"]), FIXTURE_BIGRAMS)
            self.assertEqual(len(bank["trigrams"]), FIXTURE_TRIGRAMS)
            self.assertEqual(len(bank["symspell"]["deletes"]), FIXTURE_DELETE_FORMS)
            self.assertEqual(bank["formatVersion"], 1)
            self.assertEqual(bank["tableID"], "stt-ngram-prior")

    def test_check_mode_agrees_with_the_written_bank(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "stt-ngram-prior.json"
            written = run_prior(FIXTURE, "--out", str(out))
            self.assertEqual(written.returncode, 0, written.stderr)
            checked = run_prior(FIXTURE, "--check", "--bank", str(out))
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("invariants hold", checked.stdout)

    def test_floor_refuses_a_toy_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "stt-ngram-prior.json"
            result = run_prior(FIXTURE, "--out", str(out), "--min-rows", "100000")
            self.assertEqual(result.returncode, N.EXIT_FLOOR, result.stdout)
            self.assertIn("floor refused", result.stderr)


if __name__ == "__main__":
    unittest.main()
