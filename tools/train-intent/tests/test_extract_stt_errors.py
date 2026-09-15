"""T-070 extended: STT error-distribution extraction tests.

Run from tools/train-intent/:

    python3 -m unittest discover -s tests -v

Two layers, mirroring tests/test_eval_golden_gates.py:
  - unit tests over the pure functions (alignment, classification, the fold
    table) with no subprocess;
  - integration tests that execute src/extract_stt_errors.py end-to-end
    against the committed fixture in tests/data/stt_pairs/ and assert the exit
    code, the report counters and the evidence-pack artifacts.

The fixture is hand-built so every class, every counter and both hazard
reasons have at least one instance; the pinned numbers below are the
fixture's contract and move only when the fixture moves.
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
FIXTURE = ROOT / "tests" / "data" / "stt_pairs" / "pairs_fixture.jsonl"
GOLDEN = ROOT / "eval" / "golden_corpus.jsonl"
sys.path.insert(0, str(SRC))

import extract_stt_errors as X  # noqa: E402  (path set above)

# The fixture's measured contract (pairs_fixture.jsonl).
FIXTURE_PAIRS = 32
FIXTURE_ERROR_EVENTS = 30
FIXTURE_MATCHED = 62
FIXTURE_UNALIGNED_ROWS = 1
FIXTURE_IDENTICAL = 1
FIXTURE_CLASSES = {
    "truncation": 6, "prefix_extension": 4, "phonetic_confusion": 10,
    "substitution_other": 1, "insertion": 1, "deletion": 2, "merger": 1,
    "split": 1, "script_drift": 2, "numeral_fold": 2,
}
FIXTURE_GROUPS = {
    "sibilant": 1, "vowel_length": 3, "halanta": 0, "voicing": 1,
    "retroflex_dental": 1, "aspiration": 1, "nasal": 1, "semivowel": 2,
}


def run_extract(pairs: Path, out_dir: Path, *extra: str):
    return subprocess.run(
        [sys.executable, str(SRC / "extract_stt_errors.py"),
         "--pairs", str(pairs), "--out-dir", str(out_dir),
         "--golden", str(GOLDEN), "--min-events", "0", "--min-truncations", "0",
         *extra],
        cwd=ROOT, capture_output=True, text=True)


class TestAlignment(unittest.TestCase):
    """§4.2 — the bounded token Levenshtein and its tie-break."""

    def test_identical_token_lists_are_all_matches(self):
        out = X.align_tokens(["a", "b", "c"], ["a", "b", "c"], 3)
        self.assertEqual(out["distance"], 0)
        self.assertIsNone(out["unaligned"])
        self.assertEqual([op[0] for op in out["ops"]], ["match"] * 3)

    def test_substitution_is_preferred_over_delete_plus_insert(self):
        # [a,b] -> [b,c]: two substitutions (cost 2) tie with delete+sub
        # (cost 2); the tie-break must report the substitutions, because one
        # substitution reported as two events inflates every class table.
        out = X.align_tokens(["a", "b"], ["b", "c"], 3)
        self.assertEqual(out["distance"], 2)
        self.assertEqual([op[0] for op in out["ops"]], ["sub", "sub"])

    def test_common_prefix_and_suffix_are_trimmed_not_edited(self):
        out = X.align_tokens(["x", "a", "y"], ["x", "b", "y"], 3)
        self.assertEqual(out["distance"], 1)
        self.assertEqual([op[0] for op in out["ops"]], ["match", "sub", "match"])

    def test_pure_insertion_and_deletion(self):
        ins = X.align_tokens(["a", "b"], ["a", "x", "b"], 3)
        self.assertEqual([op[0] for op in ins["ops"]], ["match", "ins", "match"])
        dele = X.align_tokens(["a", "x", "b"], ["a", "b"], 3)
        self.assertEqual([op[0] for op in dele["ops"]], ["match", "del", "match"])

    def test_beyond_the_bound_is_unaligned_and_counted(self):
        out = X.align_tokens(["a", "b", "c"], ["x", "y", "z"], 2)
        self.assertIsNotNone(out["unaligned"])
        self.assertEqual(out["unaligned"]["clean_tokens"], 3)
        self.assertEqual(out["unaligned"]["noisy_tokens"], 3)
        self.assertEqual(out["unaligned"]["distance"], 3)
        self.assertEqual(out["unaligned"]["bound"], 2)
        # the untouched prefix/suffix are still matched — only the changed
        # middle is withheld from the classification
        self.assertEqual([op[0] for op in out["ops"]], [])

    def test_bound_is_inclusive(self):
        self.assertIsNone(X.align_tokens(["a"], ["b"], 1)["unaligned"])
        self.assertIsNotNone(X.align_tokens(["a", "b"], ["c", "d"], 1)["unaligned"])

    def test_alignment_is_deterministic(self):
        args = (["a", "b", "c", "d"], ["a", "x", "d"], 3)
        self.assertEqual(X.align_tokens(*args), X.align_tokens(*args))


class TestClassification(unittest.TestCase):
    """§4.3 — the closed class set, one case per class."""

    def test_every_class_is_reachable(self):
        cases = {
            # truncation: the noisy token is a strict prefix of the clean one
            ("मौसम", "मौस"): ("truncation", None),
            ("खाएँ", "खाए"): ("truncation", None),
            # prefix extension: the clean token is a strict prefix
            ("gara", "garaa"): ("prefix_extension", None),
            # phonetic confusion, one case per measured group
            ("साथी", "शाथी"): ("phonetic_confusion", "sibilant"),
            ("औषधि", "औषधी"): ("phonetic_confusion", "vowel_length"),
            ("बजे", "पजे"): ("phonetic_confusion", "voicing"),
            ("टाउको", "ताउको"): ("phonetic_confusion", "retroflex_dental"),
            ("कति", "खति"): ("phonetic_confusion", "aspiration"),
            ("किन", "किं"): ("phonetic_confusion", "nasal"),
            ("दवाई", "दबाई"): ("phonetic_confusion", "semivowel"),
            # equal length, no measured group
            ("चलाउ", "चलाई"): ("substitution_other", None),
            # script drift beats the prefix relation it may also satisfy
            ("गर", "gara"): ("script_drift", None),
            ("फोन", "phone"): ("script_drift", None),
            # numeral fold beats script drift (८ is devanagari, 8 is latin)
            ("८", "8"): ("numeral_fold", None),
            ("७", "7"): ("numeral_fold", None),
        }
        for (clean, noisy), (cls, group) in cases.items():
            with self.subTest(clean=clean, noisy=noisy):
                out = X.classify_pair(clean, noisy)
                self.assertEqual(out["class"], cls)
                self.assertEqual(out.get("group"), group)

    def test_punctuation_only_change_is_a_match_not_an_error(self):
        # `aaunus` vs `aaunus,` is the fake prefix pair §4.2 step 1 names: the
        # decoder was right, the round trip added a comma. It belongs to the
        # false-positive population, never to `prefix_extension`.
        out = X.classify_pair("aaunus", "aaunus,")
        self.assertEqual(out["class"], "match")
        self.assertEqual(out["sub_kind"], "punctuation_only")

    def test_length_changing_pair_without_a_prefix_relation_is_ins_or_del(self):
        self.assertEqual(X.classify_pair("औषधि", "औषधिर")["class"], "prefix_extension")
        self.assertEqual(X.classify_pair("औषधिर", "औषधि")["class"], "truncation")
        # a mid-word change is neither a prefix nor an extension
        self.assertEqual(X.classify_pair("सम्झाउनु", "समझाउनु")["class"], "deletion")
        self.assertEqual(X.classify_pair("समझाउनु", "सम्झाउनु")["class"], "insertion")

    def test_fold_scalar_elision_is_recorded_as_fold_evidence(self):
        out = X.classify_pair("सम्झाउनु", "समझाउनु")
        self.assertEqual(out["class"], "deletion")
        self.assertEqual(out["group"], "halanta")
        self.assertTrue(out["sub_kind"].startswith("fold_scalar_delete"))

    def test_merger_and_split_are_grouped_runs_not_pairs(self):
        merge = X.classify_pair_events(["औषधि"], ["औषधी", "खायो"],
                                       X.align_tokens(["औषधि"], ["औषधी", "खायो"], 3))
        self.assertEqual([e["class"] for e in merge], ["merger"])
        split = X.classify_pair_events(["फोन", "गर"], ["फोनगर"],
                                       X.align_tokens(["फोन", "गर"], ["फोनगर"], 3))
        self.assertEqual([e["class"] for e in split], ["split"])

    def test_aligned_matches_are_reported_once_per_unchanged_token(self):
        events = X.classify_pair_events(["औषधि", "खाएँ"], ["औषधि", "खाए"],
                                        X.align_tokens(["औषधि", "खाएँ"], ["औषधि", "खाए"], 3))
        self.assertEqual([e["class"] for e in events], ["truncation", "match"])
        self.assertEqual(sum(1 for e in events if e["class"] == "match"), 1)


class TestFoldTable(unittest.TestCase):
    """§4.6 + A-3 — a fold is admitted only with measured support."""

    def _table(self, observations):
        table = X.FoldTable()
        for kind, group, clean, noisy in observations:
            if kind == "sub":
                table.observe_substitution(group, clean, noisy)
            else:
                table.observe_elision(group, clean, noisy)
        return table

    def test_unsupported_group_is_not_in_the_key(self):
        # vocalic length has a linguistically obvious argument and zero
        # measured events — so इ and ई do not fold (A-3).
        table = self._table([("sub", "sibilant", "स", "श")])
        self.assertNotEqual(table.key("किन"), table.key("कीं"))
        self.assertEqual([g["group"] for g in table.to_json()["groups"]
                          if g["status"] == "proposed, unsupported"],
                         [g for g in X.CONFUSION_GROUPS if g != "sibilant"])
        self.assertEqual(table.key("स"), table.key("श"))

    def test_supported_group_folds_and_carries_its_count(self):
        # the fold is per *scalar*: measuring the vowel sign ि/ी does not admit
        # the independent vowel इ/ई, which is what keeps the key a description
        # of this decoder rather than of Nepali phonology (A-3).
        table = self._table([("sub", "vowel_length", "ि", "ी"),
                             ("sub", "vowel_length", "ि", "ी")])
        self.assertEqual(table.key("किन"), table.key("कीन"))
        self.assertNotEqual(table.key("इन"), table.key("ईन"))
        folds = [f for g in table.to_json()["groups"] for f in g["folds"]]
        self.assertEqual(folds, [{"kind": "unify", "scalars": ["ि", "ी"],
                                  "representative": "ि", "count": 2,
                                  "from_substitution": 2, "from_length_change": 0}])

    def test_elision_is_admitted_only_when_measured(self):
        unmeasured = self._table([("sub", "sibilant", "स", "श")])
        self.assertNotEqual(unmeasured.key("खान्"), unmeasured.key("खान"))
        measured = self._table([("elide", "halanta", "्", "delete")])
        self.assertEqual(measured.key("खान्"), measured.key("खान"))
        halanta = [g for g in measured.to_json()["groups"] if g["group"] == "halanta"][0]
        self.assertEqual(halanta["status"], "admitted")
        self.assertEqual(halanta["folds"], [{"kind": "elide", "scalar": "्", "count": 1,
                                             "from_substitution": 0,
                                             "from_length_change": 1}])

    def test_key_is_a_function_of_scalars_not_of_words(self):
        table = self._table([("sub", "sibilant", "स", "श")])
        self.assertEqual(table.key("साथी"), table.key("शाथी"))
        self.assertNotEqual(table.key("साथी"), table.key("साथीको"))

    def test_collision_rate_counts_entries_not_keys(self):
        table = self._table([("sub", "sibilant", "स", "श")])
        tokens = X.Counter({"साथी": 1, "शाथी": 1, "फोन": 1})
        collision = X.collision_report(table, tokens)
        self.assertEqual(collision["entries"], 3)
        self.assertEqual(collision["distinct_keys"], 2)
        self.assertEqual(collision["colliding_keys"], 1)
        self.assertAlmostEqual(collision["collision_rate"], 1 / 3, places=5)


class TestEndToEnd(unittest.TestCase):
    """The committed fixture, run through the real entry point."""

    def _run(self, *extra):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = Path(tmp.name) / "pack"
        proc = run_extract(FIXTURE, out, *extra)
        return proc, out

    def test_fixture_run_writes_the_evidence_pack(self):
        proc, out = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for name in ("stt-error-distribution.json", "phonetic-key.json",
                     "calibration-set.jsonl", "run-manifest.json"):
            self.assertTrue((out / name).is_file(), f"{name} missing")
        report = json.loads((out / "stt-error-distribution.json").read_text(encoding="utf-8"))
        self.assertEqual(report["schema"], "stt-error-distribution/v1")
        self.assertEqual(report["counts"]["pairs"], FIXTURE_PAIRS)
        self.assertEqual(report["counts"]["error_events"], FIXTURE_ERROR_EVENTS)
        self.assertEqual(report["counts"]["matched_events"], FIXTURE_MATCHED)
        self.assertEqual(report["unaligned"]["rows"], FIXTURE_UNALIGNED_ROWS)
        self.assertEqual(report["unchanged"]["rows_discarded_as_identical_round_trips"],
                         FIXTURE_IDENTICAL)
        measured = {cls: entry["events"] for cls, entry in report["classes"].items()}
        self.assertEqual(measured, FIXTURE_CLASSES)
        groups = report["classes"]["phonetic_confusion"]["confusion_groups"]
        self.assertEqual(groups, FIXTURE_GROUPS)
        # the two denominators differ and both are printed
        self.assertNotEqual(
            report["classes"]["script_drift"]["share_of_events"],
            report["classes"]["script_drift"]["share_of_corrupted_rows"])

    def test_top_k_tables_are_count_tables(self):
        proc, out = self._run("--top-k", "3")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report = json.loads((out / "stt-error-distribution.json").read_text(encoding="utf-8"))
        trunc = report["classes"]["truncation"]
        self.assertEqual(len(trunc["top_pairs"]), 3)
        self.assertEqual(trunc["top_pairs"][0], {"clean": "मौसम", "noisy": "मौस", "count": 2})
        self.assertLessEqual(len(trunc["top_clean_tokens"]), 3)

    def test_false_positive_population_is_reported_with_both_hazards(self):
        proc, out = self._run()
        report = json.loads((out / "stt-error-distribution.json").read_text(encoding="utf-8"))
        fp = report["false_positive_population"]
        self.assertEqual(fp["positions"], FIXTURE_MATCHED)
        self.assertGreater(fp["distinct_tokens"], 0)
        self.assertEqual(fp["hazardous"]["ambiguous_prefix"], 1)
        self.assertEqual(fp["hazardous"]["fold_key_collision"], 2)
        reasons = {t["token"]: t["reasons"] for t in fp["hazardous"]["tokens"]}
        self.assertIn("ambiguous_prefix", reasons.get("खान", []))

    def test_provenance_split_traces_golden_parents(self):
        proc, out = self._run()
        report = json.loads((out / "stt-error-distribution.json").read_text(encoding="utf-8"))
        prov = report["classes"]["truncation"]["provenance"]
        self.assertGreater(prov.get("traced_to_golden", 0), 0)
        self.assertGreater(prov.get("generated", 0), 0)

    def test_variant_and_cell_breakdown_survives_t066(self):
        proc, out = self._run()
        report = json.loads((out / "stt-error-distribution.json").read_text(encoding="utf-8"))
        self.assertIn("1", report["by_variant"])
        self.assertIn("2", report["by_variant"])
        self.assertIn("noise_snr_15", report["by_cell"])

    def test_fold_table_is_measured_and_halanta_arrives_via_length_change(self):
        proc, out = self._run()
        key = json.loads((out / "phonetic-key.json").read_text(encoding="utf-8"))
        by_group = {g["group"]: g for g in key["groups"]}
        self.assertEqual(by_group["halanta"]["events_from_length_change"], 1)
        self.assertEqual(by_group["halanta"]["events"], 1)
        self.assertEqual(key["unsupported_groups"], [])
        # a group whose only evidence is a word-final virama drop, plus the
        # canonicalizer's punctuation rule, must not appear as a fold
        self.assertTrue(all(g["folds"] for g in key["groups"] if g["events"]))

    def test_unsupported_groups_are_excluded_from_the_key_end_to_end(self):
        # one class only: the sibilant fold is measured, the other seven are
        # printed as zero and excluded (A-3).
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        pairs = Path(tmp.name) / "sib.jsonl"
        pairs.write_text(json.dumps({
            "id": "gen-sib-001:noise1", "clean_utterance": "साथी लाई फोन गर",
            "utterance": "शाथी लाई फोन गर", "source": "stt_noise:devanagari"},
            ensure_ascii=False) + "\n", encoding="utf-8")
        out = Path(tmp.name) / "pack"
        proc = run_extract(pairs, out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        key = json.loads((out / "phonetic-key.json").read_text(encoding="utf-8"))
        self.assertEqual([g["group"] for g in key["groups"] if g["events"]], ["sibilant"])
        self.assertEqual(sorted(key["unsupported_groups"]),
                         sorted(g for g in X.CONFUSION_GROUPS if g != "sibilant"))
        self.assertEqual(key["admitted_folds"], 1)
        self.assertEqual([f["scalars"] for g in key["groups"] for f in g["folds"]],
                         [["श", "स"]])

    def test_evidence_pack_is_byte_deterministic(self):
        proc_a, out_a = self._run()
        proc_b, out_b = self._run()
        self.assertEqual(proc_a.returncode, 0, proc_a.stderr)
        for name in ("stt-error-distribution.json", "phonetic-key.json",
                     "calibration-set.jsonl"):
            self.assertEqual((out_a / name).read_bytes(), (out_b / name).read_bytes(),
                             f"{name} is not byte-deterministic")

    def test_calibration_set_carries_both_populations(self):
        proc, out = self._run()
        rows = [json.loads(line) for line in
                (out / "calibration-set.jsonl").read_text(encoding="utf-8").splitlines()]
        positives = [r for r in rows if r["population"] == "positive"]
        negatives = [r for r in rows if r["population"] == "negative"]
        self.assertTrue(positives and negatives)
        self.assertTrue(all("class" in r and "clean" in r and "noisy" in r
                            for r in positives))
        self.assertTrue(all("token" in r and "hazardous" in r for r in negatives))

    def test_manifest_carries_the_command_the_digest_and_the_revision(self):
        proc, out = self._run()
        manifest = json.loads((out / "run-manifest.json").read_text(encoding="utf-8"))
        self.assertIn("extract_stt_errors.py", manifest["command"])
        self.assertEqual(len(manifest["input_sha256"]), 64)
        self.assertEqual(manifest["input_sha256"], X.sha256_file(FIXTURE))
        self.assertEqual(manifest["input_rows_read"], FIXTURE_PAIRS + FIXTURE_IDENTICAL)
        self.assertEqual(manifest["golden_corpus_revision"], "7f71b8ae")
        self.assertEqual(manifest["segmenter_revision"], "whitespace-nfc-v1")
        self.assertEqual(manifest["tool_revision"], "extract-stt-errors/v1")
        self.assertTrue(manifest["floors"]["overridden"])

    def test_printout_carries_the_counters_never_omitted(self):
        proc, _ = self._run()
        for needle in ("unaligned rows", "unchanged round trips discarded",
                       "false-positive population", "phonetic key", "floors"):
            self.assertIn(needle, proc.stdout)


class TestFloorsAndGuards(unittest.TestCase):
    """§4.5 floors and the refusal paths."""

    def _out(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Path(tmp.name) / "pack"

    def test_default_floors_refuse_a_small_run(self):
        proc = subprocess.run(
            [sys.executable, str(SRC / "extract_stt_errors.py"),
             "--pairs", str(FIXTURE), "--out-dir", str(self._out()),
             "--golden", str(GOLDEN)],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 4)          # EXIT_FLOOR
        self.assertIn("EXIT_FLOOR", proc.stderr)
        self.assertIn("500", proc.stderr)

    def test_truncation_floor_trips_alone(self):
        proc = run_extract(FIXTURE, self._out(), "--min-truncations", "25")
        self.assertEqual(proc.returncode, 4)
        self.assertIn("25", proc.stderr)

    def test_a_met_floor_does_not_trip(self):
        proc = run_extract(FIXTURE, self._out(), "--min-events", "1",
                           "--min-truncations", "1")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_missing_pairs_file_is_refused(self):
        proc = subprocess.run(
            [sys.executable, str(SRC / "extract_stt_errors.py"),
             "--pairs", str(ROOT / "tests" / "data" / "nope.jsonl"),
             "--out-dir", str(self._out())],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 3)          # EXIT_GUARD
        self.assertIn("REFUSED", proc.stderr)

    def test_a_row_without_both_sides_is_refused(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        pairs = Path(tmp.name) / "bad.jsonl"
        pairs.write_text('{"id": "a:noise1", "clean_utterance": "x", "utterance": "y"}\n'
                         '{"id": "b:noise1", "utterance": "z"}\n', encoding="utf-8")
        proc = run_extract(pairs, Path(tmp.name) / "pack")
        self.assertEqual(proc.returncode, 3)
        self.assertIn("missing clean_utterance/utterance", proc.stderr)

    def test_duplicate_ids_are_refused_but_can_be_accepted(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        pairs = Path(tmp.name) / "dup.jsonl"
        pairs.write_text(
            '{"id": "a:noise1", "clean_utterance": "x y", "utterance": "x z"}\n'
            '{"id": "a:noise1", "clean_utterance": "p q", "utterance": "p r"}\n',
            encoding="utf-8")
        refused = run_extract(pairs, Path(tmp.name) / "pack1")
        self.assertEqual(refused.returncode, 3)
        accepted = run_extract(pairs, Path(tmp.name) / "pack2", "--allow-duplicate-ids")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_bad_arguments_are_a_usage_error(self):
        proc = run_extract(FIXTURE, self._out(), "--max-distance", "0")
        self.assertEqual(proc.returncode, 2)          # EXIT_USAGE

    def test_alignment_bound_is_wired_through(self):
        # with a bound of 1 every multi-edit row lands in `unaligned`
        proc = run_extract(FIXTURE, self._out(), "--max-distance", "1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        manifest = json.loads((Path(proc.args[proc.args.index("--out-dir") + 1])
                               / "run-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["max_distance"], 1)


if __name__ == "__main__":
    unittest.main()
