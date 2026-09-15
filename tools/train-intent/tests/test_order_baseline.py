#!/usr/bin/env python3
"""Tests for `src/order_baseline.py` (T-061 order-robustness baseline).

Local, stdlib-only.  The corpus fixtures are built through
`eval/author_golden_corpus.py`'s `row()` so every span offset is located in the
utterance by the authoring path itself — the same path the harness uses — which
is what makes these fixtures honest about the annotation contract.

`python3 -m unittest tests.test_order_baseline -v` (run from tools/train-intent/).
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import author_golden_corpus as author  # noqa: E402
import eval_golden  # noqa: E402
import order_baseline as ob  # noqa: E402


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

def mini_corpus() -> list:
    """A miniature corpus covering the operator cases, the frozen material, the
    refusal reasons and the collision guard.  Every row is authored through the
    project's own path so spans are located, not guessed."""
    return [
        # tail = [के, हो]; core = [आज, दिन] — the rich five-operator case
        author.row("mini-query-0001", "devanagari", "query", "आज के दिन हो", {}, []),
        # a second query row whose text is exactly the O3 permutation of the
        # first: the leak guard must refuse the collision
        author.row("mini-query-0002", "devanagari", "query", "के आज दिन हो", {}, []),
        # tail = [नि]; the medication span is atomic
        author.row("mini-ack-0001", "devanagari", "ack_med", "बिहानको औषधि खाएँ नि",
                   {"medication": "औषधि"}, [("medication", "औषधि")]),
        # frozen refusal marker after the ack verb: O5 must refuse
        author.row("mini-ack-0002", "devanagari", "ack_med", "औषधि खाएँ छैन",
                   {"medication": "औषधि"}, [("medication", "औषधि")]),
        # romanized, tail = [lai]
        author.row("mini-call-0001", "latin", "call", "maiya lai phone gara",
                   {"contact": "maiya"}, [("contact", "maiya")]),
        # tail = [na]
        author.row("mini-music-0001", "latin", "music", "bhajan bajau na", {}, []),
        # emergency rows are O0-only
        author.row("mini-emergency-0001", "devanagari", "emergency",
                   "मलाई मदत गर्नुहोस्", {}, []),
        # tail = [के, हुन्न]; a health_query with a trailing copula
        author.row("mini-health-0001", "devanagari", "health_query",
                   "मिर्गौला दुख्दा के खानु हुन्न", {}, []),
        # tail = [कस्तो, छ]
        author.row("mini-none-0001", "devanagari", "none", "तपाईंलाई कस्तो छ", {}, []),
        # tail = [कसरी]
        author.row("mini-guide-0001", "devanagari", "guide",
                   "माइक्रोवेभमा चिया कसरी तताउने", {}, []),
        # an interrogative inside a span: O4 must refuse, never split the span
        author.row("mini-guide-0002", "devanagari", "guide", "के खाने भनेर सोध्नुहोस्",
                   {}, [("topic", "के खाने")]),
        # irregular whitespace INSIDE a span (94 pinned rows look like this)
        author.row("mini-reminder-0001", "devanagari", "set_reminder",
                   "भोलि  दिउँसो ३ बजे औषधि खान सम्झाउनु",
                   {"time": "भोलि  दिउँसो ३ बजे", "medication": "औषधि"},
                   [("time", "भोलि  दिउँसो ३ बजे"), ("medication", "औषधि")]),
    ]


def mini_nearmiss() -> list:
    """eval_golden refuses a near-miss set without both kinds (fail-closed)."""
    return [
        author.row("mini-nm-0001", "devanagari", "emergency",
                   "मलाई सास फेर्न गाह्रो भयो", {}, [],
                   kind="emergency_paraphrase"),
        author.row("mini-nm-0002", "devanagari", "health_query",
                   "मेरो खुट्टा अलि दुख्छ", {}, [], kind="calm_pain_health"),
    ]


def write_jsonl(path: Path, rows: list) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def by_tier_verdict(record: dict, tier: str) -> str:
    return record["delta_table"]["by_tier"][tier]["verdict"]


class Harness(unittest.TestCase):
    """Tmp-dir scaffolding; nothing here touches the pinned corpus."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="order-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.corpus = self.tmp / "corpus.jsonl"
        self.rows = mini_corpus()
        write_jsonl(self.corpus, self.rows)
        self.by_id = {r["id"]: r for r in self.rows}
        self.nearmiss = self.tmp / "nearmiss.jsonl"
        write_jsonl(self.nearmiss, mini_nearmiss())

    def generate(self, target: int = 40, scan_limit: int = 20,
                 corpus: Path | None = None, fixture: str = "fixture.jsonl",
                 extra: list | None = None) -> tuple:
        out = self.tmp / fixture
        argv = ["--stage", "generate", "--corpus", str(corpus or self.corpus),
                "--fixture-out", str(out), "--target-pairs", str(target),
                "--scan-limit", str(scan_limit), "--allow-short-fixture"]
        argv += list(extra or [])
        code = ob.main(argv)
        rows = eval_golden.load_rows(out) if out.is_file() else []
        return code, out, rows

    def preds_for(self, fixture_rows: list, overrides: dict | None = None) -> Path:
        """Perfect predictions for the fixture, its parents and the near-miss set
        (a `--backend fixture` replay), with optional per-id overrides."""
        overrides = overrides or {}
        fields = ["contact", "time", "medication", "message", "topic", "requestedApp"]

        def record(row: dict, action: str) -> dict:
            rec = {"id": row["id"], "action": action, "confidence": 0.9}
            for f in fields:
                rec[f] = (row.get("slots") or {}).get(f)
            return rec

        out, seen = [], set()
        for row in fixture_rows:
            parent = self.by_id[row["perm_of"]]
            for src in (row, parent):
                if src["id"] not in seen:
                    seen.add(src["id"])
                    out.append(record(src, overrides.get(src["id"], src["intent"])))
        for row in mini_nearmiss():
            if row["id"] not in seen:
                seen.add(row["id"])
                out.append(record(row, overrides.get(row["id"], row["intent"])))
        for rid, action in overrides.items():
            if rid not in seen:
                out.append({"id": rid, "action": action, "confidence": 0.5,
                            "contact": None, "time": None, "medication": None,
                            "message": None, "topic": None, "requestedApp": None})
        path = self.tmp / "preds.jsonl"
        write_jsonl(path, out)
        return path

    def measure(self, fixture: Path, preds: Path, evidence: Path | None = None,
                target: int = 40, extra: list | None = None,
                backend: str = "fixture") -> int:
        argv = ["--stage", "measure", "--corpus", str(self.corpus),
                "--fixture", str(fixture), "--nearmiss", str(self.nearmiss),
                "--backend", backend, "--preds", str(preds),
                "--target-pairs", str(target), "--allow-short-fixture"]
        argv += ["--evidence-out", str(evidence)] if evidence else ["--no-evidence"]
        argv += list(extra or [])
        return ob.main(argv)


# ---------------------------------------------------------------------------
# tokenisation and the partition
# ---------------------------------------------------------------------------

class TestPartition(Harness):

    def test_offsets_are_code_points(self):
        toks = ob.tokenize_with_offsets("आज के दिन हो")
        self.assertEqual([t for t, _, _ in toks], ["आज", "के", "दिन", "हो"])
        utt = "आज के दिन हो"
        for text, start, end in toks:
            self.assertEqual(utt[start:end], text)

    def test_tail_lexicon_is_the_grammatical_class_only(self):
        for tok in ("के", "हो", "छ", "लाई", "lai", "नि", "न", "को", "कसरी"):
            self.assertIn(tok, ob.TAIL_LEXICON, tok)
        # content words, verbs, pronouns and arguments stay in the core
        for tok in ("गर", "फोन", "मलाई", "भनेर", "औषधि", "सन्देश", "खान", "ma"):
            self.assertNotIn(tok, ob.TAIL_LEXICON, tok)

    def test_frozen_is_whole_token_or_suffix(self):
        for tok in ("छैन", "न", "मा", "पछि", "नाइँ"):
            self.assertTrue(ob.is_frozen(tok), tok)
        self.assertTrue(ob.is_frozen("भएनछैन"))          # suffix form
        # a verb that merely CONTAINS a scalar marker is not frozen
        self.assertFalse(ob.is_frozen("खाने"))
        self.assertFalse(ob.is_frozen("गरेन"))
        self.assertFalse(ob.is_frozen("माइयालाई"))

    def test_plan_splits_core_and_tail(self):
        plan = ob.build_plan(self.by_id["mini-query-0001"])
        self.assertEqual([u.text for u in ob.core_units(plan)], ["आज", "दिन"])
        self.assertEqual([u.text for u in ob.movable_units(plan)], ["के", "हो"])
        self.assertEqual([u.text for u in plan.spine], ["आज", "दिन"])

    def test_plan_keeps_a_span_atomic_with_interior_whitespace(self):
        plan = ob.build_plan(self.by_id["mini-reminder-0001"])
        spans = [u for u in plan.units if u.kind == "span"]
        self.assertEqual([u.text for u in spans],
                         ["भोलि  दिउँसो ३ बजे", "औषधि"])
        self.assertIn(spans[0], ob.core_units(plan))

    def test_frozen_material_leaves_the_movable_tail(self):
        plan = ob.build_plan(self.by_id["mini-ack-0002"])
        self.assertEqual(ob.movable_units(plan), [])
        self.assertEqual([u.text for u in plan.spine][-1], "छैन")
        self.assertTrue(plan.spine[-1].frozen)

    def test_assemble_roundtrips_the_units(self):
        for row in self.rows:
            plan = ob.build_plan(row)
            self.assertEqual(ob._assemble(plan.spine, plan.gaps), plan.units, row["id"])

    def test_refusals_at_plan_time(self):
        cases = {
            "word_limit": author.row("h-word", "devanagari", "none",
                                     " ".join(["शब्द"] * 21), {}, []),
            "template_artefact": author.row("h-tmpl", "devanagari", "call",
                                            "{name} लाई फोन गर", {}, []),
            "empty": {"id": "h-empty", "utterance": "   ", "intent": "none",
                      "script": "devanagari", "slots": {}, "spans": []},
            "span_not_token_aligned": author.row("h-span", "devanagari", "ack_med",
                                                 "औषधि खाएँ", {},
                                                 [("medication", "औषध")]),
            "whitespace": {"id": "h-ws", "utterance": "फोन  गर", "intent": "call",
                           "script": "devanagari", "slots": {}, "spans": []},
        }
        for reason, row in cases.items():
            with self.subTest(reason=reason):
                with self.assertRaises(ob.Refusal) as ctx:
                    ob.build_plan(row)
                self.assertEqual(str(ctx.exception), reason)


# ---------------------------------------------------------------------------
# the operator family
# ---------------------------------------------------------------------------

class TestOperators(Harness):

    def utterance(self, row_id: str, op: str) -> str:
        plan = ob.build_plan(self.by_id[row_id])
        units = ob.apply_op(plan, op)["units"]
        return " ".join(u.text for u in units)

    def test_o0_is_identity(self):
        self.assertEqual(self.utterance("mini-query-0001", "O0"), "आज के दिन हो")

    def test_o1_content_then_tail(self):
        self.assertEqual(self.utterance("mini-query-0001", "O1"), "आज दिन के हो")

    def test_o2_tail_then_content(self):
        self.assertEqual(self.utterance("mini-query-0001", "O2"), "के हो आज दिन")

    def test_o3_tail_halves_bracket_the_core(self):
        self.assertEqual(self.utterance("mini-query-0001", "O3"), "के आज दिन हो")

    def test_o4_interrogative_to_the_front(self):
        # ONLY the interrogative moves: हो keeps its trailing gap, so this is a
        # fronting of के, not a whole-tail prepose (that is O2's job)
        self.assertEqual(self.utterance("mini-query-0001", "O4"), "के आज दिन हो")
        self.assertEqual(self.utterance("mini-health-0001", "O4"),
                         "के मिर्गौला दुख्दा खानु हुन्न")

    def test_o4_alone_is_not_an_o2_prepose(self):
        plan = ob.build_plan(self.by_id["mini-health-0001"])
        o4 = [u.text for u in ob.apply_op(plan, "O4")["units"]]
        o2 = [u.text for u in ob.apply_op(plan, "O2")["units"]]
        self.assertNotEqual(o4, o2)
        self.assertEqual(o4, ["के", "मिर्गौला", "दुख्दा", "खानु", "हुन्न"])

    def test_o5_last_core_unit_trails(self):
        self.assertEqual(self.utterance("mini-query-0001", "O5"), "आज के हो दिन")

    def test_o6_swaps_the_tail_halves_in_place(self):
        # the two tail tokens trade gaps: के → the trailing gap, हो → के's old
        # one; the content core is untouched, so the text is NOT the same as O2
        self.assertEqual(self.utterance("mini-query-0001", "O6"), "आज हो दिन के")
        self.assertEqual(self.utterance("mini-query-0001", "O6").split()[-2:],
                         ["दिन", "के"])
        self.assertNotEqual(self.utterance("mini-query-0001", "O6"),
                            self.utterance("mini-query-0001", "O2"))

    def test_single_tail_token_makes_most_operators_identity(self):
        # mini-call-0001 has tail [lai] and core [maiya, phone, gara]
        self.assertEqual(self.utterance("mini-call-0001", "O1"),
                         "maiya phone gara lai")
        self.assertEqual(self.utterance("mini-call-0001", "O6"), "maiya lai phone gara")
        plan = ob.build_plan(self.by_id["mini-call-0001"])
        self.assertEqual(ob.apply_op(plan, "O6")["status"], "identity_by_absence")
        self.assertEqual(ob.apply_op(plan, "O6")["reason"], "tail_too_short")

    def test_emergency_rows_are_o0_only(self):
        plan = ob.build_plan(self.by_id["mini-emergency-0001"])
        for op in ob.OPS[1:]:
            with self.subTest(op=op):
                with self.assertRaises(ob.Refusal) as ctx:
                    ob.apply_op(plan, op)
                self.assertEqual(str(ctx.exception), "emergency_frozen")
        self.assertEqual(ob.apply_op(plan, "O0")["status"], "ok")

    def test_o4_refuses_an_interrogative_inside_a_span(self):
        plan = ob.build_plan(self.by_id["mini-guide-0002"])
        with self.assertRaises(ob.Refusal) as ctx:
            ob.apply_op(plan, "O4")
        self.assertEqual(str(ctx.exception), "interrogative_immovable")

    def test_o5_refuses_to_move_past_frozen_material(self):
        # the guard fires even though the movable tail is empty: a frozen
        # barricade is a guard trip (invariant 4), not an absence
        plan = ob.build_plan(self.by_id["mini-ack-0002"])
        self.assertEqual(ob.movable_units(plan), [])
        with self.assertRaises(ob.Refusal) as ctx:
            ob.apply_op(plan, "O5")
        self.assertEqual(str(ctx.exception), "frozen_moved")

    def test_spans_move_whole_and_never_split(self):
        plan = ob.build_plan(self.by_id["mini-reminder-0001"])
        for op in ob.OPS:
            with self.subTest(op=op):
                units = ob.apply_op(plan, op)["units"]
                span_texts = [u.text for u in units if u.kind == "span"]
                self.assertEqual(sorted(span_texts),
                                 sorted(["भोलि  दिउँसो ३ बजे", "औषधि"]))
                # and no span text is ever broken across two units
                utterance = " ".join(u.text for u in units)
                for text in span_texts:
                    self.assertIn(text, utterance)

    def test_violations_detects_a_tampered_sequence(self):
        plan = ob.build_plan(self.by_id["mini-query-0001"])
        good = ob.apply_op(plan, "O1")["units"]
        self.assertEqual(ob.violations(plan, good), [])
        swapped = list(reversed(good))
        # reversing trips both order invariants; the check is containment, the
        # order of the findings is not a contract
        self.assertIn("spine_order", ob.violations(plan, swapped))
        self.assertIn("content_order", ob.violations(plan, swapped))
        self.assertEqual(ob.violations(plan, good[:-1]), ["unit_set"])

    def test_every_operator_keeps_the_core_order_on_the_real_corpus(self):
        rows = eval_golden.load_rows(ROOT / "eval" / "golden_corpus.jsonl")[:150]
        checked = 0
        for row in rows:
            try:
                plan = ob.build_plan(row)
            except ob.Refusal:
                continue
            for op in ob.OPS:
                if plan.intent == "emergency" and op != "O0":
                    continue
                try:
                    units = ob.apply_op(plan, op)["units"]
                except ob.Refusal:
                    continue
                self.assertEqual(ob.violations(plan, units), [], (row["id"], op))
                checked += 1
        self.assertGreater(checked, 400)


# ---------------------------------------------------------------------------
# generation
# ---------------------------------------------------------------------------

class TestGenerate(Harness):

    def test_fixture_is_wellformed_and_paired(self):
        code, _, rows = self.generate()
        self.assertEqual(code, ob.EXIT_OK)
        self.assertEqual(eval_golden.validate_rows(rows, "fixture"), [])
        ids = [r["id"] for r in rows]
        self.assertEqual(len(ids), len(set(ids)))
        for row in rows:
            self.assertIn(row["order_op"], ob.OPS)
            self.assertEqual(row["tier"], ob.OP_TIER[row["order_op"]])
            self.assertEqual(row["perm_of"], row["parent_id"])
            self.assertIn(row["perm_of"], self.by_id)
            self.assertEqual(row["id"], f"{row['perm_of']}:ord{row['order_op'][1:]}")
            self.assertLessEqual(len(ob.tokenize_words(row["utterance"])), ob.MAX_WORDS)

    def test_every_operator_is_represented(self):
        _, _, rows = self.generate(target=80)
        seen = {r["order_op"] for r in rows}
        self.assertEqual(seen, set(ob.OPS))

    def test_emergency_rows_are_o0_only(self):
        _, _, rows = self.generate(target=80)
        emergency = [r for r in rows if r["intent"] == "emergency"]
        self.assertTrue(emergency)
        self.assertEqual({r["order_op"] for r in emergency}, {"O0"})
        # and the refusals for the other six operators are counted
        code, _, _ = self.generate(target=80)
        self.assertEqual(code, ob.EXIT_OK)

    def test_emergency_refusals_are_counted_not_dropped(self):
        gen = ob.generate(self.rows, 80, scan_limit=1)
        self.assertEqual(gen["refusals"].get("emergency_frozen"), 6)

    def test_spans_are_relocated_not_carried_over(self):
        _, _, rows = self.generate(target=80)
        for row in rows:
            plan = ob.build_plan(self.by_id[row["perm_of"]])
            spans = [u for u in plan.units if u.kind == "span"]
            self.assertEqual(len(row["spans"]), len(spans), row["id"])
            for span in row["spans"]:
                self.assertEqual(row["utterance"][span["start"]:span["end"]],
                                 span["text"])
                self.assertIn(span["text"], [u.text for u in spans])

    def test_generation_is_deterministic(self):
        _, path_a, _ = self.generate(fixture="a.jsonl")
        _, path_b, _ = self.generate(fixture="b.jsonl")
        self.assertEqual(path_a.read_bytes(), path_b.read_bytes())

    def test_heldout_collision_is_refused_with_scan_limit_one(self):
        # mini-query-0002 IS mini-query-0001's O3 (and now O4) permutation: a
        # perturbed row may never collide with a held-out corpus utterance
        gen = ob.generate(self.rows, 80, scan_limit=1)
        self.assertGreaterEqual(gen["refusals"].get("heldout_collision", 0), 1)
        for row in gen["fixture"]:
            if row["perm_of"] == "mini-query-0001":
                self.assertNotEqual(row["utterance"], "के आज दिन हो", row["id"])
        # ...while mini-query-0002's own rows may of course say that

    def test_identity_by_absence_is_counted_and_keeps_the_control(self):
        gen = ob.generate(self.rows, 80, scan_limit=1)
        counter = gen["counters"]
        self.assertGreater(counter["identity_by_absence"], 0)
        self.assertEqual(counter["identity:O0"], 0)   # O0 is the control, not absence
        o0 = [r for r in gen["fixture"] if r["order_op"] == "O0"]
        self.assertEqual(counter["control"], len(o0))
        # every row is either perturbed, the O0 control, or an absence
        self.assertLessEqual(counter["control"] + counter["identity_by_absence"],
                             len(gen["fixture"]))
        self.assertGreater(counter["pairs"] - counter["control"]
                           - counter["identity_by_absence"], 0)
        self.assertEqual(counter["pairs"], len(gen["fixture"]))
        # the O0 rows carry the parents' text and are counted as such
        control = [r for r in gen["fixture"] if r["order_op"] == "O0"]
        self.assertTrue(control)
        for row in control:
            self.assertEqual(row["utterance"], self.by_id[row["perm_of"]]["utterance"])
            self.assertTrue(row.get("heldout_identity"))

    def test_a_row_the_scheme_cannot_represent_counts_one_refusal(self):
        hostile = self.tmp / "hostile.jsonl"
        write_jsonl(hostile, [
            author.row("h-word", "devanagari", "none", " ".join(["शब्द"] * 21), {}, []),
            author.row("h-ok", "devanagari", "query", "आज के दिन हो", {}, []),
        ])
        gen = ob.generate(eval_golden.load_rows(hostile), 80, scan_limit=1)
        self.assertEqual(gen["refusals"].get("row:word_limit"), 1)

    def test_fixture_rows_below_the_floor_exit_four(self):
        fixture = self.tmp / "floor_fixture.jsonl"
        argv = ["--stage", "generate", "--corpus", str(self.corpus),
                "--fixture-out", str(fixture), "--target-pairs", "800"]
        self.assertEqual(ob.main(argv), ob.EXIT_FLOOR)
        self.assertTrue(fixture.is_file())
        self.assertTrue(eval_golden.load_rows(fixture))
        # the same run with the shortfall allowed through is EXIT_OK
        self.assertEqual(ob.main(argv + ["--allow-short-fixture"]), ob.EXIT_OK)

    def test_irregular_whitespace_inside_a_span_survives_permutation(self):
        _, _, rows = self.generate(target=80)
        time_rows = [r for r in rows if r["perm_of"] == "mini-reminder-0001"]
        self.assertTrue(time_rows)
        for row in time_rows:
            self.assertIn("भोलि  दिउँसो ३ बजे", row["utterance"])


# ---------------------------------------------------------------------------
# the measurement
# ---------------------------------------------------------------------------

class TestMeasurement(Harness):

    def test_paired_stats_delta_discordant_and_se(self):
        def pair(correct, parent_correct):
            return {"correct": correct, "parent_correct": parent_correct}
        stats = ob.paired_stats([pair(True, True), pair(True, True),
                                 pair(False, True), pair(True, False)])
        self.assertEqual(stats["n"], 4)
        self.assertEqual(stats["discordant"], 2)
        self.assertAlmostEqual(stats["delta"], 0.0)          # one each way
        self.assertAlmostEqual(stats["se"], (0.5 / 4) ** 0.5)
        self.assertAlmostEqual(stats["half_width_95"],
                               ob.Z_95 * (0.5 / 4) ** 0.5)
        stats = ob.paired_stats([pair(False, True), pair(False, True),
                                 pair(True, True), pair(True, True)])
        self.assertAlmostEqual(stats["delta"], 0.5)
        self.assertEqual(stats["discordant"], 2)

    def test_paired_stats_on_no_pairs_is_not_decidable(self):
        stats = ob.paired_stats([])
        self.assertEqual(stats["n"], 0)
        self.assertEqual(stats["verdict"], "not_decidable")
        self.assertFalse(stats["decidable"])

    def test_block_verdicts(self):
        def pair(correct, parent_correct, op="O1", tier="A"):
            return {"row": {"intent": "query", "slots": {}},
                    "parent": {"intent": "query", "slots": {}},
                    "pred": {"action": "query" if correct else "none"},
                    "parent_pred": {"action": "query" if parent_correct else "none"},
                    "correct": correct, "parent_correct": parent_correct,
                    "op": op, "tier": tier, "perturbed": True, "families": []}
        # 40 identical pairs: decidable, delta 0
        within = ob.block([pair(True, True)] * 40)
        self.assertEqual(within["verdict"], "within_band")
        self.assertTrue(within["decidable"])
        # 60% wrong: delta 0.6, and the interval is far wider than the band
        beyond = ob.block([pair(False, True)] * 24 + [pair(True, True)] * 16)
        self.assertEqual(beyond["verdict"], "not_decidable")
        self.assertGreater(beyond["delta"], ob.GATE_BAND)
        # 3% of a large fixture: decidable and beyond the band
        big = ob.block([pair(False, True)] * 30 + [pair(True, True)] * 970)
        self.assertAlmostEqual(big["delta"], 0.03)
        self.assertTrue(big["decidable"])
        self.assertEqual(big["verdict"], "within_band")
        big2 = ob.block([pair(False, True)] * 60 + [pair(True, True)] * 940)
        self.assertEqual(big2["verdict"], "beyond_band")

    def test_families_of(self):
        self.assertEqual(ob.families_of("ack_med", "औषधि खाएँ"),
                         ["ack_med_vs_refusal"])
        # a refusal row IS intent none, so it lands in both of its families
        self.assertEqual(ob.families_of("none", "औषधि खाएँ छैन"),
                         ["ack_med_vs_refusal", "query_vs_none"])
        self.assertEqual(ob.families_of("none", "आज के दिन हो"), ["query_vs_none"])
        self.assertEqual(ob.families_of("music", "भजन बजाउ"),
                         ["music_vs_suggest_video"])
        self.assertEqual(ob.families_of("emergency", "मलाई मदत गर्नुहोस्"),
                         ["emergency_vs_health_query"])

    def test_verdict_of_exit_codes(self):
        base = {"identity": {"void": False, "mismatch": 0},
                "gates": {"closed_intent_delta": {"verdict": "within_band"},
                          "emergency_recall": {"verdict": "pass"},
                          "abstention_delta": {"verdict": "pass"},
                          "span_f1_delta": {"verdict": "pass"},
                          "tier_b": {"verdict": "within_band"}}}
        self.assertEqual(ob.verdict_of(base)[0], ob.EXIT_OK)

        void = {**base, "identity": {"void": True, "mismatch": 2}}
        code, verdict, reasons = ob.verdict_of(void)
        self.assertEqual(code, ob.EXIT_GUARD)
        self.assertEqual(verdict, "void")
        self.assertIn("void", reasons[0])

        failed = {**base, "gates": {**base["gates"],
                                    "closed_intent_delta": {"verdict": "beyond_band"}}}
        self.assertEqual(ob.verdict_of(failed)[0], ob.EXIT_STAGE)

        undecided = {**base, "gates": {**base["gates"],
                                       "tier_b": {"verdict": "not_decidable"}}}
        code, verdict, reasons = ob.verdict_of(undecided)
        self.assertEqual(code, ob.EXIT_STAGE)
        self.assertIn("not decidable", reasons[0])

    def test_span_and_abstention_helpers(self):
        rows = [{"slots": {"contact": "माइया"}, "intent": "call"}]
        preds = [{"action": "call", "contact": "माइया"}]
        golds, got = ob.slot_pairs(rows, preds)
        self.assertEqual(eval_golden.slot_f1(golds, got), 1.0)
        self.assertEqual(ob.accuracy(rows, preds), 1.0)
        self.assertEqual(ob.abstention_rate(preds), 0.0)
        self.assertEqual(ob.abstention_rate([{"action": "none"}]), 1.0)


# ---------------------------------------------------------------------------
# the command line, end to end
# ---------------------------------------------------------------------------

class TestCli(Harness):

    def test_missing_corpus_is_refused(self):
        code, _, _ = self.generate(corpus=self.tmp / "nope.jsonl")
        self.assertEqual(code, ob.EXIT_GUARD)

    def test_fixture_validation_failure_is_usage(self):
        bad = self.tmp / "bad_fixture.jsonl"
        write_jsonl(bad, [{"id": "x", "utterance": "फोन गर", "intent": "not_an_action",
                           "script": "devanagari", "slots": {}, "spans": [],
                           "perm_of": "mini-call-0001"}])
        code = self.measure(bad, self.tmp / "unused.jsonl")
        self.assertEqual(code, ob.EXIT_USAGE)

    def test_fixture_without_a_parent_is_usage(self):
        fixture = self.tmp / "orphan_fixture.jsonl"
        write_jsonl(fixture, [author.row("orphan", "devanagari", "query",
                                         "आज के दिन हो", {}, [])])
        code = self.measure(fixture, self.tmp / "unused.jsonl")
        self.assertEqual(code, ob.EXIT_USAGE)

    def test_malformed_preds_is_usage(self):
        _, fixture, rows = self.generate(target=40)
        bad = self.tmp / "bad_preds.jsonl"
        bad.write_text("[\"not\", \"an\", \"object\"]\n", encoding="utf-8")
        self.assertEqual(self.measure(fixture, bad), ob.EXIT_USAGE)

    def test_unknown_parent_is_refused(self):
        fixture = self.tmp / "alien_fixture.jsonl"
        row = author.row("alien:ord1", "devanagari", "query", "के आज दिन हो", {}, [])
        row["perm_of"] = "gc-query-999"          # not in the mini corpus
        write_jsonl(fixture, [row])
        preds = self.preds_for([], overrides={"alien:ord1": "query"})
        self.assertEqual(self.measure(fixture, preds), ob.EXIT_GUARD)

    def test_a_real_backend_must_name_the_artifact(self):
        _, fixture, rows = self.generate(target=40)
        preds = self.preds_for(rows)
        code = self.measure(fixture, preds, backend="encoder")
        self.assertEqual(code, ob.EXIT_GUARD)

    def test_a_missing_export_is_a_stage_error_not_a_traceback(self):
        # the box-side command names the pinned artifact correctly and the only
        # thing wrong is the export path: that must read as a stage failure
        _, fixture, rows = self.generate(target=40)
        preds = self.preds_for(rows)
        naming = ["--artifact-sha256-prefix", "d8f549ec",
                  "--catalog-entry", ob.CATALOG_ENTRY,
                  "--run-id", "t036-full-0.1.0-internal-noised6b-topup-20260914-071945"]
        code = self.measure(fixture, preds, backend="encoder",
                            extra=naming + ["--model-path",
                                            str(self.tmp / "no-such-export")])
        self.assertEqual(code, ob.EXIT_STAGE)

    def test_the_pinned_run_id_is_not_a_version_word(self):
        # the artifact is named by digest prefix + run id + catalog entry; the
        # naming guard must not trip on the real run id or catalog entry
        args = type("A", (), {"artifact_sha256_prefix": "d8f549ec",
                              "model_path": None, "catalog_entry": ob.CATALOG_ENTRY,
                              "run_id": "t036-full-0.1.0-internal-noised6b-topup-1"})()
        naming, named = ob.artifact_naming(args)
        self.assertTrue(named)
        self.assertFalse(ob.VERSION_WORD.search(naming["run_id"]))
        self.assertFalse(ob.VERSION_WORD.search(naming["catalog_entry"]))
        self.assertTrue(ob.VERSION_WORD.search("intentEncoder-v2"))

    def test_a_version_word_in_the_artifact_name_is_refused(self):
        _, fixture, rows = self.generate(target=40)
        preds = self.preds_for(rows)
        code = self.measure(fixture, preds, backend="encoder",
                            extra=["--catalog-entry", "intentEncoder-v2",
                                   "--run-id", "20260915-000000"])
        self.assertEqual(code, ob.EXIT_GUARD)

    def test_perfect_predictions_are_go(self):
        _, fixture, rows = self.generate(target=40)
        code = self.measure(fixture, self.preds_for(rows))
        self.assertEqual(code, ob.EXIT_OK)

    def test_degraded_tier_a_is_no_go(self):
        _, fixture, rows = self.generate(target=40)
        overrides = {}
        for row in rows:
            if row["order_op"] in ("O1", "O3", "O5"):
                overrides[row["id"]] = "none"
        code = self.measure(fixture, self.preds_for(rows, overrides))
        self.assertEqual(code, ob.EXIT_STAGE)

    def test_a_broken_control_voids_the_measurement(self):
        _, fixture, rows = self.generate(target=40)
        overrides = {r["id"]: "none" for r in rows if r["order_op"] == "O0"}
        self.assertTrue(overrides)
        code = self.measure(fixture, self.preds_for(rows, overrides))
        self.assertEqual(code, ob.EXIT_GUARD)

    def test_emergency_recall_failure_is_no_go(self):
        # the emergency rows are O0-only, so a missed emergency degrades the
        # control and the permuted run alike: the recall gate trips on its own,
        # the identity check stays intact
        _, fixture, rows = self.generate(target=40)
        emergency = [r for r in rows if r["intent"] == "emergency"]
        self.assertTrue(emergency)
        overrides = {}
        for row in emergency:
            self.assertEqual(row["order_op"], "O0")
            overrides[row["id"]] = "none"
            overrides[row["perm_of"]] = "none"       # the parent, too
        self.assertEqual(self.measure(fixture, self.preds_for(rows, overrides)),
                         ob.EXIT_STAGE)

    def test_evidence_pack_is_written(self):
        out = self.tmp / "evidence"
        _, fixture, rows = self.generate(target=40)
        code = self.measure(fixture, self.preds_for(rows), evidence=out)
        self.assertEqual(code, ob.EXIT_OK)
        record = json.loads((out / "order-baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(record["schema"], "order-baseline/v1")
        self.assertTrue(record["fixture"]["provisional"])
        self.assertIn("NOT the gate's measurement", record["not_a_gate_measurement"])
        self.assertEqual(record["verdict"], "go")
        self.assertEqual(record["exit_code"], ob.EXIT_OK)
        self.assertEqual(record["fixture"]["pairs"], len(rows))
        self.assertTrue(record["artifact"]["rule"])
        self.assertIn("NOT EVALUATED", record["gemini_gap"])
        self.assertEqual(sorted(record["delta_table"]["by_op"]), sorted(ob.OPS))
        self.assertEqual(record["gate_runs"]["permuted"]["exit"] in (0, 1), True)
        rows_written = eval_golden.load_rows(out / "evidence-rows.jsonl")
        self.assertEqual(len(rows_written), len(rows))
        for row in rows_written:
            self.assertIn("parent_correct", row)
            self.assertIn("order_op", row)
        table = json.loads((out / "delta-table.json").read_text(encoding="utf-8"))
        self.assertEqual(table["gate_band"], ob.GATE_BAND)
        self.assertIn("by_family", table)
        manifest = record["manifest"]
        self.assertEqual(manifest["fixture_id"], ob.FIXTURE_ID)
        self.assertEqual(manifest["corpus_revision"],
                         ob.sha256_file(self.corpus)[:8])
        self.assertEqual(manifest["tail_lexicon"], sorted(ob.TAIL_LEXICON))
        self.assertEqual(manifest["frozen"]["tokens"], list(ob.FROZEN_TOKENS))
        self.assertEqual(manifest["tokenizer"]["max_len"], 64)

    def test_stage_all_generates_then_measures_and_trips(self):
        # the echo backend predicts "none" for everything: the fixture is
        # generated in the same invocation and the measurement must trip
        out = self.tmp / "evidence_all"
        fixture = self.tmp / "all_fixture.jsonl"
        code = ob.main(["--stage", "all", "--corpus", str(self.corpus),
                        "--fixture-out", str(fixture), "--nearmiss",
                        str(self.nearmiss), "--target-pairs", "40",
                        "--allow-short-fixture", "--backend", "echo",
                        "--evidence-out", str(out)])
        self.assertEqual(code, ob.EXIT_STAGE)
        rows = eval_golden.load_rows(fixture)
        self.assertEqual(eval_golden.validate_rows(rows, fixture.name), [])
        record = json.loads((out / "order-baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(record["verdict"], "no_go")
        self.assertEqual(record["fixture"]["pairs"], len(rows))
        self.assertEqual(record["gates"]["emergency_recall"]["verdict"], "fail")
        self.assertEqual(record["gates"]["closed_intent_delta"]["verdict"],
                         by_tier_verdict(record, "A"))

    def test_stage_all_replay_needs_predictions_for_the_fresh_fixture(self):
        fixture = self.tmp / "all2_fixture.jsonl"
        code = ob.main(["--stage", "all", "--corpus", str(self.corpus),
                        "--fixture-out", str(fixture), "--nearmiss",
                        str(self.nearmiss), "--target-pairs", "40",
                        "--allow-short-fixture", "--backend", "fixture",
                        "--preds", str(self.preds_for([])), "--no-evidence"])
        self.assertEqual(code, ob.EXIT_USAGE)
        rows = eval_golden.load_rows(fixture)
        self.assertTrue(rows)
        self.assertTrue(all(r["notes"].startswith(ob.FIXTURE_ID) for r in rows))
        self.assertTrue(all("provisional" in r["notes"] for r in rows))


if __name__ == "__main__":
    unittest.main()
