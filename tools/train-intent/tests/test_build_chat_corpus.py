"""T-179 tests: the four-layer chat corpus pipeline (build_chat_corpus.py).

The unit's contract (tasks/TG-37-v17-chat-aware-training-suite/T-179):

  * four layers built and counted per layer (L1 native, L2 translated +
    post-edited, L3 teacher-generated, L4 claw-back) at the 70/30 mixture;
  * the filters execute the STYLE SPEC's machine blocks through
    ``author_chat_golden.mechanical_review`` (one rule, one source) plus the
    pipeline length rule; every rejection is counted by rule; an unavailable
    filter stops the run;
  * every assistant turn passes the teacher GEC stage before admission; its
    call count, cache hits and usage are reported; the stage is resumable;
  * every candidate is deduped at admission against the held-out chat set's
    exact keys, the suite's normalize-skeleton keys (golden corpus +
    near-miss) and a token-Jaccard near-duplicate pool; exclusions are
    reported by rule;
  * the eval fixtures the design named as claw-back sources are refused (the
    recorded deviation): counted as refused sources and excluded at
    admission, never trained on;
  * the dev/ship split is a first-class parameter: NC/research-gated sources
    never enter the ship mix, unclassified sources enter neither;
  * shortfalls are reported per layer with a reason and the mixture's target
    ratio is never silently re-balanced;
  * outputs are deterministic (byte-identical dual runs) and the CLI runs
    offline via ``--plan`` and a recorded teacher fixture.

No network access anywhere: the teacher, translator and STT-noise seams are
injected; the CLI end-to-end replays a RECORDED teacher fixture (the
eval_golden.py ``--backend fixture`` precedent). The synthetic held-out
fixture is built through ``author_chat_golden``'s own record builders, so a
schema change breaks these tests rather than silently splitting the format.
"""
from __future__ import annotations

import contextlib
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:                       # the config cross-check only; the fixtures need no PyYAML
    import yaml
except ImportError:        # pragma: no cover - environment without PyYAML
    yaml = None

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import style_spec as ss  # noqa: E402
import author_chat_golden as acg  # noqa: E402
import pipeline_guards as guards  # noqa: E402
import build_chat_corpus as bc  # noqa: E402

#: Distinguishes "use the default" from an explicit None (e.g. translate=None
#: means "the translation tier is unavailable", not "use the fake").
_DEFAULT = object()

#: The teacher configuration the synthetic chat-golden fixture's header records.
CFG = {
    "gemini.model": "gemini-2.5-flash-lite",
    "gemini.temperature": 0.8,
    "gemini.max_output_tokens": 4096,
    "gemini.requests_per_minute": 25.0,
}
MODEL = "gemini-2.5-flash-lite"

# ---------------------------------------------------------------------------
# Fixture texts (every one verified collision-free against the REAL held-out
# set as well — the CLI end-to-end build runs with the default guard)
# ---------------------------------------------------------------------------

#: A clean assistant reply: honorific register, no particle, no AI-ism, no
#: Latin, two sentences — passes ``mechanical_review`` and the length rule.
REPLY = "हजुर, म ठीक छु। तपाईंलाई धन्यवाद।"

ECOM_USER = "मलाई नयाँ किताब चाहियो हजुर।"
TASK_ELDER_EN = "Book me a taxi to the health post."
TASK_ELDER_NE = "ट्याक्सी बोलाइदिनुहोस् हजुर।"
TASK_REPLY_EN = "Sure, I will book it for tomorrow morning."
DAILYD_ELDER_EN = "I could not sleep at all last night."
DAILYD_ELDER_NE = "हिजो राति निद्रा लागेन हजुर।"
DAILYD_REPLY_EN = "I am sorry to hear that."

TT1_UTTERANCE = "औषधि खानुभयो हजुर?"
TT1_NOISY = "औषधि खानभयो हजुर?"
TT2_UTTERANCE = "मेरो उमेर कति भयो?"
TT3_UTTERANCE = "भोलि मौसम कस्तो छ"
TT3_CLEAN = "भोलि मौसम कस्तो हुन्छ"
E1_UTTERANCE = "अब भन्नुहोस् हजुर।"
E1_NOISY = "अब भनुहोस हजुर।"

#: The synthetic held-out chat set's two turns (5+ tokens each so the
#: near-duplicate pool carries them).
GUARD_USER_1 = "बिहानको खाजा र चिया खानुभयो हजुर?"
GUARD_USER_2 = "आज गाउँमा मौसम राम्रो छ।"
GUARD_REPLY_1 = "खानुभयो हजुर। धन्यवाद।"
GUARD_REPLY_2 = "राम्रो छ हजुर। बाहिर हिँड्नुहोस्।"
GOLDEN_UTTERANCE = "यो सुनौलो वाक्य पहिलो हो।"
GOLDEN_UTTERANCE_2 = "यो सुनौलो वाक्य दोस्रो हो।"
NEARMISS_UTTERANCE = "यो आपतकालीन नजिकको वाक्य हो।"


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

def _write_jsonl(path, records) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records),
                    encoding="utf-8")


def _read_jsonl(path) -> list:
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()
            if line.strip()]


def _guard_fixture(tmp: Path, spec) -> dict:
    """A tiny but schema-valid held-out set built through acg's own builders.

    One authoring batch (the first of the plan) with two turns; the human
    review stays ``pending`` — the guard must load on the PATH to eligibility
    being false (admission must NOT gate on ``require_gate_fixture()``).
    """
    tmp.mkdir(parents=True, exist_ok=True)
    batch = dict(acg.batch_plan(spec)[0])
    turns = [
        acg._turn_record(batch, 1, {
            "user_turn": GUARD_USER_1, "context": [],
            "acceptable_output": GUARD_REPLY_1,
            "note": "synthetic guard fixture turn 1"}, spec, MODEL),
        acg._turn_record(batch, 2, {
            "user_turn": GUARD_USER_2, "context": [],
            "acceptable_output": GUARD_REPLY_2,
            "note": "synthetic guard fixture turn 2"}, spec, MODEL),
    ]
    record = acg._batch_record(batch, turns, 1, {"total_token_count": 20}, [], MODEL,
                               spec, None, "gemini")
    header = acg._header_record(spec, CFG, [record], "gemini")
    chat = tmp / "chat_golden.jsonl"
    acg._write(chat, header, turns)
    golden = tmp / "golden_corpus.jsonl"
    _write_jsonl(golden, [
        {"id": "g-1", "utterance": GOLDEN_UTTERANCE, "intent": "smalltalk"},
        {"id": "g-2", "utterance": GOLDEN_UTTERANCE_2, "intent": "smalltalk"},
    ])
    nearmiss = tmp / "emergency_nearmiss.jsonl"
    _write_jsonl(nearmiss, [{"id": "nm-1", "utterance": NEARMISS_UTTERANCE,
                             "kind": "emergency"}])
    return {"chat": chat, "golden": golden, "nearmiss": nearmiss}


def _write_sources(root, *, indic=None, ecommerce=None, taskmaster=None,
                   dailydialog=None, teacher=None, edge=None) -> None:
    """Write the source files the registry names (None = don't write the file)."""
    paths = {
        "indic": "chat-sources/l1/indic_dialogue_ne.jsonl",
        "ecommerce": "chat-sources/l1/devanagari_ecommerce.jsonl",
        "dailydialog": "chat-sources/l2/dailydialog.jsonl",
        "taskmaster": "chat-sources/l2/taskmaster.jsonl",
        "teacher": "data/teacher.jsonl",
        "edge": "data/edge_cases.jsonl",
    }
    rows = {"indic": indic, "ecommerce": ecommerce, "dailydialog": dailydialog,
            "taskmaster": taskmaster, "teacher": teacher, "edge": edge}
    for name, rel in paths.items():
        if rows[name] is not None:
            _write_jsonl(Path(root) / rel, rows[name])


INDIC = [{"dialogue_id": "d-1", "turns": [
    {"speaker": "elder", "text": "नमस्ते हजुर।"},
    {"speaker": "assistant", "text": REPLY},
    {"speaker": "elder", "text": "आज दिन कस्तो छ?"},
    {"speaker": "assistant", "text": REPLY}]}]
ECOM = [{"id": "p-1", "user_turn": ECOM_USER, "reply": REPLY}]
TASKMASTER = [{"dialogue_id": "t-1", "language": "en", "turns": [
    {"speaker": "elder", "text": TASK_ELDER_EN},
    {"speaker": "assistant", "text": TASK_REPLY_EN}]}]
DAILYD = [{"dialogue_id": "dd-1", "language": "en", "turns": [
    {"speaker": "elder", "text": DAILYD_ELDER_EN},
    {"speaker": "assistant", "text": DAILYD_REPLY_EN}]}]
TEACHER = [
    {"id": "tt-1", "utterance": TT1_UTTERANCE, "reply": REPLY,
     "action": "query_medication", "confidence": 0.9},
    {"id": "tt-2", "utterance": TT2_UTTERANCE, "action": "query_age"},
    {"id": "tt-3", "utterance": TT3_UTTERANCE, "reply": REPLY,
     "action": "query_weather", "confidence": 0.8, "clean_utterance": TT3_CLEAN},
]
EDGE = [{"id": "e-1", "utterance": E1_UTTERANCE, "reply": REPLY, "confidence": 0.2,
         "action": "abstain"}]

#: The standard build's source set: L1 dev (rejected in the ship mix) + L1 ship
#: + L2 ship + L4 teacher/edge. dailydialog is deliberately absent.
_DEFAULT_SOURCES = {"indic": INDIC, "ecommerce": ECOM, "taskmaster": TASKMASTER,
                    "teacher": TEACHER, "edge": EDGE}


def _mapped_translate(texts):
    """The default fake translation tier (a recorded seam, deterministic)."""
    mapping = {TASK_ELDER_EN: TASK_ELDER_NE, DAILYD_ELDER_EN: DAILYD_ELDER_NE}
    return [mapping.get(text, TASK_ELDER_NE) for text in texts]


class FakeTeacher:
    """The injectable teacher: GEC, L3 generation and L2 post-edit, recorded.

    Detection is by the prompts the builder itself builds (no prompt text is
    duplicated here): the GEC batch starts with ``GEC_PROMPT_HEADER``, the
    post-edit call starts with its fixed first line, and the L3 call carries
    the ``= THIS BATCH =`` block whose batch id / class / count are parsed
    back out of the prompt.
    """

    def __init__(self, *, reply=REPLY, gec_correct=None, gec_drop=(),
                 gec_raise=False, l3_empty_classes=(), l3_raise_classes=(),
                 l3_incomplete=False, postedit_reply=None, postedit_drop=(),
                 postedit_raise=False):
        self.reply = reply
        self.gec_correct = dict(gec_correct or {})
        self.gec_drop = set(gec_drop)          # texts to OMIT from the response
        self.gec_raise = gec_raise
        self.l3_empty_classes = set(l3_empty_classes)
        self.l3_raise_classes = set(l3_raise_classes)
        self.l3_incomplete = l3_incomplete
        self.postedit_reply = postedit_reply or reply
        self.postedit_drop = set(postedit_drop)
        self.postedit_raise = postedit_raise
        self.prompts = []
        self.gec_batches = []                  # list of text lists
        self.gec_texts = []                    # flat occurrence order
        self.l3_keys = []
        self.postedit_prompts = []
        self._l3_n = 0

    def __call__(self, prompt, cfg):
        self.prompts.append(prompt)
        if prompt.startswith(bc.GEC_PROMPT_HEADER):
            if self.gec_raise:
                raise RuntimeError("gec backend down")
            texts = [m.group(2) for m in re.finditer(r"^\[(\d+)\] (.*)$", prompt,
                                                     flags=re.M)]
            self.gec_batches.append(texts)
            self.gec_texts.extend(texts)
            turns = [{"i": index, "corrected": self.gec_correct.get(text, text)}
                     for index, text in enumerate(texts) if text not in self.gec_drop]
            return {"turns": turns, "usage": {"prompt_tokens": 10, "output_tokens": 5}}
        if prompt.startswith("You are post-editing"):
            self.postedit_prompts.append(prompt)
            if self.postedit_raise:
                raise RuntimeError("post-edit backend down")
            indexes = [int(m.group(1)) for m in
                       re.finditer(r"^\[(\d+)\] elder:", prompt, flags=re.M)]
            return {"turns": [{"i": i, "reply": self.postedit_reply}
                              for i in indexes if i not in self.postedit_drop],
                    "usage": {"prompt_tokens": 50, "output_tokens": 30}}
        if "= THIS BATCH =" in prompt:
            key = re.search(r"^batch id: (\S+)$", prompt, flags=re.M).group(1)
            klass = re.search(r"^conversation class: (\S+)", prompt, flags=re.M).group(1)
            count = int(re.search(r"Produce exactly (\d+) chat turns", prompt).group(1))
            self.l3_keys.append(key)
            if klass in self.l3_raise_classes:
                raise RuntimeError("l3 backend down")
            if klass in self.l3_empty_classes:
                return {"turns": [], "usage": {"prompt_tokens": 100, "output_tokens": 0}}
            turns = []
            for n in range(count):
                self._l3_n += 1
                turn = {"user_turn": f"नक्कली प्रश्न {self._l3_n}", "context": [],
                        "acceptable_output": self.reply, "note": f"fake {klass}"}
                if self.l3_incomplete and n in (0, count - 1):
                    turn.pop("user_turn" if n == 0 else "acceptable_output")
                turns.append(turn)
            return {"turns": turns, "usage": {"prompt_tokens": 500, "output_tokens": 200}}
        raise AssertionError(f"FakeTeacher got an unknown prompt: {prompt[:200]!r}")


class RecordingTeacher:
    """Wraps a teacher and records ``{prompt_sha256, response}`` for replay.

    The recorded file is exactly what ``default_teacher(..., "teacher-fixture",
    path)`` replays: the offline transport the CLI end-to-end test uses.
    """

    def __init__(self, inner):
        self.inner = inner
        self.records = []

    def __call__(self, prompt, cfg):
        response = self.inner(prompt, cfg)
        self.records.append({"prompt_sha256": bc._sha256_text(prompt),
                             "response": response})
        return response

    def write_fixture(self, path) -> None:
        _write_jsonl(Path(path), self.records)


class CorpusTestCase(unittest.TestCase):
    """Shared fixture: a synthetic held-out set + the tiny licensed source set."""

    maxDiff = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="t179-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.spec = ss.load()
        self.paths = _guard_fixture(self.tmp / "heldout", self.spec)
        self.guard = bc.HeldOutGuard.load(chat_path=self.paths["chat"],
                                          golden_path=self.paths["golden"],
                                          nearmiss_path=self.paths["nearmiss"])

    # -- the one build entry point every test goes through ------------------

    def build(self, *, mix="ship", sources=_DEFAULT, source_root=None, out="out",
              guard=_DEFAULT, teacher=None, translate=_DEFAULT, noise_fn=_DEFAULT,
              noise_pairs=None, noise_backend="none", noise_rate=0.6,
              l3_target_turns=11, gec_budget=bc.GEC_MAX_CALLS_DEFAULT, seed=42,
              limit_per_source=0, execute=True, run_id="t179-test",
              translation_command="", teacher_transport="gemini",
              teacher_fixture=None):
        """Run one build; returns (report, out_dir, teacher).

        ``guard=_DEFAULT`` uses the synthetic held-out set; ``guard=None``
        lets the builder load its DEFAULTS (the real fixtures) — the CLI
        end-to-end needs that. ``translate=None`` means "tier unavailable".
        """
        src_root = Path(source_root) if source_root else (self.tmp / "sources")
        rows = dict(_DEFAULT_SOURCES) if sources is _DEFAULT else dict(sources)
        if rows:
            _write_sources(src_root, **rows)
        resolved_teacher = teacher if teacher is not None else FakeTeacher()
        out_dir = self.tmp / out
        opts = bc.BuildOptions(
            mix=mix, source_root=src_root, out_dir=out_dir, run_id=run_id,
            seed=seed, limit_per_source=limit_per_source,
            l3_target_turns=l3_target_turns, gec_budget=gec_budget,
            noise_rate=noise_rate, noise_backend=noise_backend,
            noise_pairs=noise_pairs, translation_command=translation_command,
            teacher_transport=teacher_transport, teacher_fixture=teacher_fixture,
            execute=execute)
        report = bc.build_chat_corpus(
            opts, spec=self.spec, teacher=resolved_teacher,
            translate=(_mapped_translate if translate is _DEFAULT else translate),
            noise_fn=(None if noise_fn is _DEFAULT else noise_fn),
            held_out=(self.guard if guard is _DEFAULT else guard),
            log=lambda line: None)
        return report, out_dir, resolved_teacher

    # -- small readers -------------------------------------------------------

    def corpus(self, out_dir, mix="ship") -> list:
        return _read_jsonl(Path(out_dir) / f"chat-corpus-{mix}.jsonl")

    def layer_rows(self, out_dir, layer) -> list:
        return _read_jsonl(Path(out_dir) / "layers" / f"{layer}.jsonl")

    def counters(self, out_dir) -> dict:
        return json.loads((Path(out_dir) / "chat-corpus-counters.json")
                          .read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Constants and small helpers
# ---------------------------------------------------------------------------

class ConstantsTests(unittest.TestCase):
    def test_layers_and_mixture_shares(self):
        self.assertEqual(bc.LAYERS, ("L1", "L2", "L3", "L4"))
        self.assertEqual(bc.CONVERSATION_LAYERS, ("L1", "L2", "L3"))
        self.assertEqual(bc.CLAWBACK_LAYER, "L4")
        self.assertAlmostEqual(bc.CONVERSATION_SHARE + bc.CLAWBACK_SHARE, 1.0)
        self.assertAlmostEqual(bc.CONVERSATION_SHARE, 0.70)
        self.assertAlmostEqual(bc.CLAWBACK_SHARE, 0.30)

    def test_layer_targets_follow_the_design_band(self):
        self.assertEqual(bc.TOTAL_TURNS_TARGET, 40_000)
        self.assertEqual(bc.L3_TARGET_TURNS, 10_000)
        self.assertEqual(bc.L4_TARGET_TURNS, 12_000)   # 30% of the total target
        self.assertIsNone(bc.LAYER_TARGETS["L1"])
        self.assertIsNone(bc.LAYER_TARGETS["L2"])
        self.assertEqual(bc.LAYER_TARGETS["L3"], 10_000)
        self.assertEqual(bc.LAYER_TARGETS["L4"], 12_000)
        for layer in bc.LAYERS:
            self.assertTrue(bc.LAYER_TARGET_RATIONALE[layer].strip())

    def test_teacher_and_noise_constants(self):
        self.assertEqual(bc.GEC_TEMPERATURE, 0.0)     # correction override of 0.8
        self.assertEqual(bc.GEC_BATCH_TURNS, 20)
        self.assertEqual(bc.GEC_MAX_CALLS_DEFAULT, 2000)
        self.assertEqual(bc.STT_NOISE_RATE_DEFAULT, 0.60)
        self.assertEqual(bc.POST_EDIT_STATUSES, ("pending", "spot_checked", "rejected"))
        self.assertEqual(bc.NEAR_DUP_JACCARD, 0.80)
        self.assertEqual(bc.NEAR_DUP_MIN_TOKENS, 4)
        self.assertEqual(bc.MAX_CONTEXT_ENTRIES, 4)
        self.assertEqual(bc.MIN_ASSISTANT_WORD_TOKENS, 2)
        self.assertEqual(bc.TURN_TOKEN_CEILING, 512)

    def test_word_tokens_split_on_punctuation(self):
        self.assertEqual(bc.word_tokens("नमस्ते हजुर। कस्तो छ?"),
                         ["नमस्ते", "हजुर", "कस्तो", "छ"])
        self.assertEqual(bc.word_tokens(""), [])
        self.assertEqual(bc.word_tokens("एउटा, दुई; तीन"),
                         ["एउटा", "दुई", "तीन"])

    def test_rough_token_estimate(self):
        self.assertEqual(bc.rough_token_estimate(""), 0)
        self.assertEqual(bc.rough_token_estimate("कख"), 1)
        self.assertEqual(bc.rough_token_estimate("कखग"), 2)

    def test_jaccard(self):
        self.assertAlmostEqual(bc._jaccard(["a", "b"], ["a", "b", "c"]), 2 / 3)
        self.assertEqual(bc._jaccard([], ["a"]), 0.0)
        self.assertEqual(bc._jaccard(["a"], []), 0.0)


# ---------------------------------------------------------------------------
# The source registry: licences, mix classes, the eval-fixture refusals
# ---------------------------------------------------------------------------

class RegistryTests(unittest.TestCase):
    def test_every_source_carries_licence_layer_and_class(self):
        for source in bc.SOURCE_REGISTRY:
            self.assertTrue(source.id)
            self.assertIn(source.layer, bc.LAYERS)
            self.assertTrue(source.license.strip())
            self.assertIn(source.admissibility,
                          ("ship", "dev", "unclassified", "eval-fixture"))
            self.assertIn(source.kind, ("dialogue", "intent", "generated", "fixture"))
            self.assertIn(source.provenance,
                          ("third-party", "own", "synthetic", "tooling"))

    def test_ship_sources_carry_no_nc_or_research_restrictions(self):
        for source in bc.SOURCE_REGISTRY:
            if source.admissibility != "ship":
                continue
            lowered = source.license.lower()
            for banned in ("nc", "non-commercial", "research"):
                if banned == "nc":     # substring test done case-sensitively on "NC"
                    self.assertNotIn("NC", source.license,
                                     f"{source.id}: NC licence in the ship mix")
                    continue
                self.assertNotIn(banned, lowered,
                                 f"{source.id}: research restriction in the ship mix")

    def test_dev_sources_are_research_gated(self):
        by_id = {s.id: s for s in bc.SOURCE_REGISTRY}
        self.assertEqual(by_id["indic_dialogue_ne"].admissibility, "dev")
        self.assertEqual(by_id["call_center_transcripts"].admissibility, "dev")
        self.assertEqual(by_id["dailydialog"].admissibility, "dev")
        self.assertEqual(by_id["personachat_convai2"].admissibility, "dev")
        self.assertEqual(by_id["empathetic_dialogues"].admissibility, "dev")
        self.assertIn("research", by_id["call_center_transcripts"].license.lower())

    def test_unclassified_sources_are_refused_from_both_mixes(self):
        by_id = {s.id: s for s in bc.SOURCE_REGISTRY}
        for source_id in ("nepali_sft_himalaya", "nepali_sft_saugatkafley"):
            source = by_id[source_id]
            self.assertEqual(source.admissibility, "unclassified")
            self.assertIn("unclassified", source.license.lower())

    def test_eval_fixture_sources_carry_the_recorded_refusal_reason(self):
        by_id = {s.id: s for s in bc.SOURCE_REGISTRY}
        for source_id in ("golden_corpus_fixture", "emergency_nearmiss_fixture"):
            source = by_id[source_id]
            self.assertEqual(source.admissibility, "eval-fixture")
            self.assertTrue(source.refusal_reason.strip(),
                            f"{source_id}: a refusal is never silent")
            self.assertIn("eval/", source.default_path.replace("\\", "/"))

    def test_guards_own_refusal_matches_the_registry(self):
        # The registry's refusal is the suite's own guard talking, not a
        # local policy: pointing the guard at the golden corpus refuses.
        with self.assertRaises(guards.GuardError):
            guards.assert_not_golden_input(guards.GOLDEN_CORPUS, "test")

    def test_chat_golden_tooling_entry_is_an_eval_fixture(self):
        by_id = {s.id: s for s in bc.TOOLING_SOURCES}
        self.assertIn("chat_golden_fixture", by_id)
        self.assertEqual(by_id["chat_golden_fixture"].admissibility, "eval-fixture")
        self.assertTrue(by_id["chat_golden_fixture"].refusal_reason)

    def test_tooling_inputs_are_classified(self):
        ids = {s.id for s in bc.TOOLING_SOURCES}
        self.assertLessEqual(
            {"teacher_gemini_flash_lite", "translation_tier_qwen",
             "style_spec_artifact", "stt_noise_roundtrip"}, ids)

    def test_sources_for_layer_partitions_the_registry(self):
        seen = []
        for layer in bc.LAYERS:
            seen.extend(s.id for s in bc.sources_for_layer(layer))
        self.assertEqual(sorted(seen), sorted(s.id for s in bc.SOURCE_REGISTRY))

    def test_layer_4_carries_intent_and_abstain_components(self):
        ids = {s.id for s in bc.sources_for_layer("L4")}
        self.assertIn("intent_training_teacher", ids)
        self.assertIn("intent_training_noised", ids)
        self.assertIn("abstain_honesty_edge_cases", ids)
        by_id = {s.id: s for s in bc.sources_for_layer("L4")}
        self.assertEqual(by_id["intent_training_teacher"].component, "intent_training")
        self.assertEqual(by_id["intent_training_noised"].component, "intent_training")
        self.assertEqual(by_id["abstain_honesty_edge_cases"].component, "abstain_honesty")

    def test_parser_exposes_the_first_class_build_parameters(self):
        parser = bc.build_parser()
        actions = {action.dest: action for action in parser._actions}
        self.assertEqual(set(actions["mix"].choices), {"ship", "dev"})
        self.assertEqual(set(actions["teacher_transport"].choices),
                         {"gemini", "openrouter", "teacher-fixture"})
        self.assertEqual(set(actions["noise_backend"].choices),
                         {"auto", "recorded", "hf", "cli", "none"})
        for dest in ("source_root", "out_dir", "run_id", "seed", "l3_target_turns",
                     "gec_budget", "noise_rate", "noise_pairs", "translation_command",
                     "teacher_fixture", "plan", "record_spot_check", "reviewer",
                     "disposition", "limit_per_source"):
            self.assertIn(dest, actions)


# ---------------------------------------------------------------------------
# The filters: the spec's machine checks, executed and named
# ---------------------------------------------------------------------------

class FilterTests(CorpusTestCase):
    def filters(self, reply, user_turn=ECOM_USER):
        return bc.apply_filters(user_turn, reply, [], self.spec)

    def checks(self, violations):
        return sorted({v["check"] for v in violations})

    def test_a_clean_reply_passes(self):
        self.assertEqual(self.filters(REPLY), [])

    def test_length_floor_rejects_a_fragment(self):
        violations = self.filters("हजुर।")
        self.assertEqual(self.checks(violations), ["length"])
        self.assertIn("below the floor", violations[0]["detail"])

    def test_length_ceiling_rejects_an_over_budget_turn(self):
        reply = "क" * (2 * (bc.TURN_TOKEN_CEILING + 10))
        violations = self.filters(reply)
        self.assertIn("length", self.checks(violations))
        self.assertTrue(any("ceiling" in v["detail"] for v in violations
                            if v["check"] == "length"))

    def test_honorific_disagreement_is_rejected_by_the_spec_lexicon(self):
        forbidden = self.spec.register()["forbidden_address_forms"][0]
        violations = self.filters(f"{forbidden} कस्तो छ?")
        self.assertEqual(self.checks(violations), ["honorific_agreement"])
        self.assertIn(forbidden, violations[0]["detail"])

    def test_banned_ai_ism_is_rejected_by_the_spec_blacklist(self):
        entry = next(e for e in self.spec.forbidden_ai_isms()
                     if e["kind"] == "substring" and e["id"] == "canned_service_phrase")
        violations = self.filters(f"{entry['patterns'][0]} हजुर।")
        self.assertEqual(self.checks(violations), ["no_ai_isms"])
        self.assertIn(entry["id"], violations[0]["detail"])

    def test_reply_initial_clitic_is_a_dangling_particle(self):
        violations = self.filters("अनि, के भयो हजुर?")
        self.assertEqual(self.checks(violations), ["dangling_particle"])
        detail = next(v["detail"] for v in violations
                      if v["check"] == "dangling_particle")
        self.assertGreaterEqual(detail["count"], 1)
        self.assertTrue(detail["dangling"])

    def test_particle_budget_counts_occurrences(self):
        violations = self.filters("राम्रो छ नि हजुर। ठीक छ नि।")
        detail = next(v["detail"] for v in violations
                      if v["check"] == "dangling_particle")
        self.assertEqual(detail["count"], 2)
        self.assertEqual(detail["budget"], self.spec.particle_budget())

    def test_latin_runs_trip_devanagari_purity(self):
        violations = self.filters("hello हजुर।")
        self.assertIn("devanagari_purity", self.checks(violations))

    def test_sentence_shape_rejects_three_sentences(self):
        violations = self.filters("ठीक छ। ठीक छ। ठीक छ।")
        self.assertEqual(self.checks(violations), ["sentence_shape"])
        self.assertEqual(violations[0]["detail"],
                         self.spec.sentence_shape()["max_sentences"] + 1)

    def test_filters_execute_author_chat_goldens_review_function(self):
        # One rule, one source: the pipeline's spec checks ARE the review the
        # held-out fixture is authored under — same class names, same detail.
        for text in (REPLY, "अनि, के भयो हजुर?", "तँ कस्तो छ?",
                     "कृपया नम्र निवेदन हजुर।", "hello हजुर।"):
            review = acg.mechanical_review(text, self.spec)
            pipeline = [v["check"] for v in self.filters(text)
                        if v["check"] != "length"]
            self.assertEqual(pipeline, [v["check"] for v in review["violations"]],
                             text)

    def test_explicit_spec_argument_matches_the_default(self):
        self.assertEqual(self.filters(REPLY), bc.apply_filters(ECOM_USER, REPLY, []))


# ---------------------------------------------------------------------------
# One rule, one source: prompts render the spec, nothing re-authors lexicons
# ---------------------------------------------------------------------------

class SpecSingleSourceTests(CorpusTestCase):
    def test_render_rules_carries_every_spec_lexicon_and_rule(self):
        text = bc.render_rules(self.spec)
        self.assertIn(f"= NEPALI CHAT STYLE SPEC v{self.spec.version} =", text)
        register = self.spec.register()
        self.assertIn(str(register["address_pronoun"]), text)
        self.assertIn(str(register["attention_marker"]), text)
        for form in register["forbidden_address_forms"]:
            self.assertIn(form, text)
        for form in register["non_honorific_verb_forms"]:
            self.assertIn(form, text)
        self.assertIn(f"at most {self.spec.particle_budget()} particle per reply", text)
        for unit in self.spec.particle_lexicon():
            self.assertIn(unit, text)
        shape = self.spec.sentence_shape()
        self.assertIn(f"at most {shape['max_sentences']} sentences", text)
        for topic in self.spec.small_talk_topics():
            self.assertIn(topic["id"], text)
        for noun in self.spec.code_switch_nouns():
            self.assertIn(noun["spoken"], text)
        for entry in self.spec.forbidden_ai_isms():
            self.assertIn(entry["id"], text)
            self.assertIn(entry["description"], text)
        self.assertIn(self.spec.persona_clause(), text)

    def test_module_source_does_not_re_author_the_spec_lexicons(self):
        # The drift pin: no spec lexicon entry (>= 2 Devanagari chars) appears
        # literally in the builder's source — the lexicons live in the spec.
        source = (ROOT / "src" / "build_chat_corpus.py").read_text(encoding="utf-8")
        devanagari = re.compile(r"[ऀ-ॿ]")
        entries = list(self.spec.particle_lexicon())
        entries += list(self.spec.register()["forbidden_address_forms"])
        entries += list(self.spec.register()["non_honorific_verb_forms"])
        entries += [noun["spoken"] for noun in self.spec.code_switch_nouns()]
        for entry in entries:
            if len(devanagari.findall(entry)) >= 2:
                self.assertNotIn(entry, source,
                                 f"the builder re-authors spec lexicon entry {entry!r}")

    def test_gec_prompt_is_header_plus_rendered_rules(self):
        prompt = bc.build_gec_prompt([REPLY, "अनि, के भयो हजुर?"], self.spec)
        self.assertTrue(prompt.startswith(bc.GEC_PROMPT_HEADER))
        self.assertIn(bc.render_rules(self.spec), prompt)
        self.assertIn("[0] " + REPLY, prompt)
        self.assertIn("[1] अनि, के भयो हजुर?", prompt)

    def test_l3_prompt_renders_the_spec_and_names_the_batch(self):
        entry = self.spec.coverage_classes()[0]
        prompt = bc.build_l3_prompt(self.spec, entry, 10, batch_id="l3:greeting:0000")
        self.assertIn(bc.render_rules(self.spec), prompt)
        self.assertIn(f"conversation class: {entry['id']} — {entry['gloss']}", prompt)
        self.assertIn(entry["example"], prompt)
        self.assertIn("batch id: l3:greeting:0000", prompt)
        self.assertIn("Produce exactly 10 chat turns", prompt)
        # distinct calls for the same class must be distinct prompts
        other = bc.build_l3_prompt(self.spec, entry, 10, batch_id="l3:greeting:0001")
        self.assertNotEqual(prompt, other)

    def test_l3_prompt_exclusion_section(self):
        entry = self.spec.coverage_classes()[0]
        prompt = bc.build_l3_prompt(self.spec, entry, 5, exclude=["पुरानो वाक्य"],
                                    batch_id="l3:greeting:0000")
        self.assertIn("Do NOT reuse these elder turns already produced:", prompt)
        self.assertIn("- पुरानो वाक्य", prompt)

    def test_postedit_prompt_carries_exemplars_when_available(self):
        prompt = bc.build_postedit_prompt(self.spec, [(TASK_ELDER_EN, TASK_REPLY_EN)],
                                          exemplars=[(ECOM_USER, REPLY)])
        self.assertIn(bc.render_rules(self.spec), prompt)
        self.assertIn("= REAL-EXEMPLARS (Layer-1 style anchors) =", prompt)
        self.assertIn(f"elder: {ECOM_USER}", prompt)
        self.assertIn(f"assistant: {REPLY}", prompt)
        self.assertIn(f"[0] elder: {TASK_ELDER_EN}", prompt)
        self.assertIn(f"translation: {TASK_REPLY_EN}", prompt)

    def test_postedit_prompt_records_the_no_exemplar_case(self):
        prompt = bc.build_postedit_prompt(self.spec, [(TASK_ELDER_EN, TASK_REPLY_EN)],
                                          exemplars=[])
        self.assertIn("(none available in this build", prompt)
        self.assertNotIn("(Layer-1 style anchors)", prompt)

    def test_default_spec_loader_matches_an_explicit_spec(self):
        self.assertEqual(bc.render_rules(), bc.render_rules(self.spec))


# ---------------------------------------------------------------------------
# The held-out guard: exact keys, skeletons, near-duplicates, failure modes
# ---------------------------------------------------------------------------

class HeldOutGuardTests(CorpusTestCase):
    def test_exact_user_key_collision_is_excluded_by_lossless_key(self):
        exclusion = self.guard.check_user_turn(GUARD_USER_1)
        self.assertIsNotNone(exclusion)
        self.assertEqual(exclusion["rule"], "held_out_user_turn")
        self.assertIn("lossless_key", exclusion["detail"])

    def test_skeleton_variant_is_excluded_by_the_normalize_key(self):
        # The en dash survives lossless_key but normalizes to a space: the
        # candidate is a NEW lossless string and the SAME skeleton.
        variant = GUARD_USER_1.replace(" ", "–", 1)
        self.assertNotEqual(variant, GUARD_USER_1)
        exclusion = self.guard.check_user_turn(variant)
        self.assertIsNotNone(exclusion)
        self.assertEqual(exclusion["rule"], "held_out_user_turn")
        self.assertIn("normalized-skeleton", exclusion["detail"])

    def test_golden_corpus_utterance_is_excluded(self):
        exclusion = self.guard.check_user_turn(GOLDEN_UTTERANCE)
        self.assertEqual(exclusion["rule"], "held_out_eval_fixture")
        self.assertIn("golden corpus", exclusion["detail"])

    def test_golden_corpus_skeleton_variant_is_excluded(self):
        variant = GOLDEN_UTTERANCE.replace(" ", "–", 1)
        exclusion = self.guard.check_user_turn(variant)
        self.assertEqual(exclusion["rule"], "held_out_eval_fixture")

    def test_emergency_nearmiss_utterance_is_excluded(self):
        exclusion = self.guard.check_user_turn(NEARMISS_UTTERANCE)
        self.assertEqual(exclusion["rule"], "held_out_eval_fixture")

    def test_near_duplicate_user_turn_is_excluded(self):
        exclusion = self.guard.check_user_turn(GUARD_USER_1 + " अहिले")
        self.assertEqual(exclusion["rule"], "held_out_user_turn")
        self.assertIn("near-duplicate", exclusion["detail"])

    def test_tiny_acknowledgements_are_not_near_duplicates(self):
        # Below NEAR_DUP_MIN_TOKENS the token overlap never excludes — the
        # floor keeps tiny courtesies from colliding trivially.
        self.assertIsNone(self.guard.check_user_turn("बिहानको खाजा चिया"))

    def test_exact_reply_collision_is_excluded(self):
        exclusion = self.guard.check_reply(GUARD_REPLY_1)
        self.assertEqual(exclusion["rule"], "held_out_reply")
        self.assertIn("exact duplicate of a held-out chat reference reply",
                      exclusion["detail"])

    def test_reply_skeleton_variant_is_excluded(self):
        exclusion = self.guard.check_reply(GUARD_REPLY_2.replace(" ", "–", 1))
        self.assertEqual(exclusion["rule"], "held_out_reply")
        self.assertIn("normalized-skeleton", exclusion["detail"])

    def test_near_duplicate_reply_is_excluded(self):
        exclusion = self.guard.check_reply(GUARD_REPLY_2 + " अहिले")
        self.assertEqual(exclusion["rule"], "held_out_reply")
        self.assertIn("near-duplicate", exclusion["detail"])

    def test_empty_text_is_never_excluded(self):
        self.assertIsNone(self.guard.check_user_turn(""))
        self.assertIsNone(self.guard.check_reply(""))

    def test_evidence_records_the_fixture_version_and_the_dedupe_policy(self):
        evidence = self.guard.evidence()
        chat = evidence["chat_golden"]
        self.assertEqual(chat["sha256"], acg.content_sha256(self.paths["chat"]))
        self.assertEqual(chat["revision"], chat["sha256"][:8])
        self.assertEqual(chat["turns"], 2)
        self.assertIs(chat["eligible_gate_fixture"], False)
        self.assertIn("require_gate_fixture", chat["note"])
        self.assertEqual(evidence["exact_user_keys"], 2)
        self.assertEqual(evidence["golden_corpus"]["keys"], 3)   # 2 + near-miss row
        self.assertIs(evidence["nearmiss_guarded"], True)
        self.assertEqual(evidence["near_dup_policy"],
                         {"jaccard": bc.NEAR_DUP_JACCARD,
                          "min_tokens": bc.NEAR_DUP_MIN_TOKENS})

    def test_exact_user_keys_are_held_out_keys_verbatim(self):
        self.assertEqual(self.guard.exact_user_keys,
                         acg.held_out_keys(self.paths["chat"]))

    def test_guard_loads_even_though_the_fixture_is_ineligible(self):
        # The recorded deviation from require_gate_fixture(): the human review
        # is pending, so the set is not an eligible GATE fixture — but its
        # keys protect admission either way, and eligibility is reported.
        with self.assertRaises(acg.ChatGoldenError):
            acg.require_gate_fixture(self.paths["chat"])
        self.guard  # loads in setUp without a stop

    def test_missing_chat_fixture_stops_the_run(self):
        with self.assertRaises(bc.BuildStopped):
            bc.HeldOutGuard.load(chat_path=self.tmp / "nope.jsonl",
                                 golden_path=self.paths["golden"],
                                 nearmiss_path=self.paths["nearmiss"])

    def test_missing_golden_corpus_stops_the_run(self):
        with self.assertRaises(bc.BuildStopped):
            bc.HeldOutGuard.load(chat_path=self.paths["chat"],
                                 golden_path=self.tmp / "nope.jsonl",
                                 nearmiss_path=self.paths["nearmiss"])

    def test_missing_nearmiss_is_recorded_and_does_not_stop(self):
        guard = bc.HeldOutGuard.load(chat_path=self.paths["chat"],
                                     golden_path=self.paths["golden"],
                                     nearmiss_path=self.tmp / "nope.jsonl")
        self.assertIs(guard.evidence()["nearmiss_guarded"], False)
        self.assertEqual(guard.evidence()["golden_corpus"]["keys"], 2)


# ---------------------------------------------------------------------------
# The teacher GEC stage: batching, resumability, budget, recorded refusals
# ---------------------------------------------------------------------------

class GecStageTests(CorpusTestCase):
    def make_stage(self, teacher, *, out="gec-cache.jsonl", budget=10, batch_turns=20):
        return bc.GecStage(self.tmp / out, budget=budget, model=MODEL,
                           temperature=bc.GEC_TEMPERATURE, teacher=teacher,
                           cfg=bc._teacher_cfg(), batch_turns=batch_turns)

    def test_corrects_every_text_and_records_the_cache(self):
        teacher = FakeTeacher()
        stage = self.make_stage(teacher, out="g1.jsonl")
        results = stage.correct([REPLY, "अनि, के भयो हजुर?"], self.spec.sha256)
        self.assertEqual([r[0] for r in results], [REPLY, "अनि, के भयो हजुर?"])
        self.assertEqual(stage.calls, 1)
        self.assertEqual(stage.cache_hits, 0)
        records = _read_jsonl(self.tmp / "g1.jsonl")
        self.assertEqual(len(records), 2)
        for record in records:
            self.assertEqual(record["model"], MODEL)
            self.assertEqual(record["temperature"], 0.0)
            self.assertIs(record["changed"], False)

    def test_a_resume_replays_from_cache_without_paying_again(self):
        teacher = FakeTeacher()
        first = self.make_stage(teacher, out="g2.jsonl")
        first.correct([REPLY], self.spec.sha256)
        second = self.make_stage(FakeTeacher(gec_raise=True), out="g2.jsonl")
        results = second.correct([REPLY, REPLY], self.spec.sha256)
        self.assertEqual([r[0] for r in results], [REPLY, REPLY])
        self.assertEqual([r[1] for r in results], [True, True])
        self.assertEqual(second.calls, 0)
        self.assertEqual(second.cache_hits, 2)

    def test_cache_key_covers_model_and_spec_hash(self):
        stage = self.make_stage(FakeTeacher(), out="g3.jsonl")
        self.assertNotEqual(stage.key_for(REPLY, "aaa"), stage.key_for(REPLY, "bbb"))
        other = bc.GecStage(self.tmp / "g3b.jsonl", budget=10, model="other-model",
                            temperature=0.0, teacher=FakeTeacher(),
                            cfg=bc._teacher_cfg())
        self.assertNotEqual(stage.key_for(REPLY, "aaa"), other.key_for(REPLY, "aaa"))

    def test_budget_exhaustion_holds_the_remaining_turns(self):
        teacher = FakeTeacher()
        stage = self.make_stage(teacher, out="g4.jsonl", budget=0)
        results = stage.correct([REPLY], self.spec.sha256)
        self.assertEqual(results, [None])
        self.assertTrue(stage.budget_exhausted)
        self.assertTrue(any(r["reason"] == "gec budget exhausted"
                            for r in stage.refusals))
        self.assertEqual(stage.calls, 0)

    def test_missing_response_entry_is_a_recorded_refusal(self):
        teacher = FakeTeacher(gec_drop=[REPLY])
        stage = self.make_stage(teacher, out="g5.jsonl")
        results = stage.correct([REPLY, "अनि, के भयो हजुर?"], self.spec.sha256)
        self.assertIsNone(results[0])
        self.assertEqual(results[1][0], "अनि, के भयो हजुर?")
        self.assertTrue(any(r["reason"] == "no correction in the teacher response"
                            for r in stage.refusals))

    def test_a_failing_call_is_recorded_and_does_not_abort_the_stage(self):
        teacher = FakeTeacher(gec_raise=True)
        stage = self.make_stage(teacher, out="g6.jsonl")
        results = stage.correct([REPLY], self.spec.sha256, log=lambda line: None)
        self.assertEqual(results, [None])
        self.assertTrue(any(r["reason"] == "teacher call failed"
                            for r in stage.refusals))
        report = stage.report()
        self.assertIn("runtimeerror", report["refusals"][0]["detail"].lower())

    def test_batching_chunks_the_texts(self):
        teacher = FakeTeacher()
        stage = self.make_stage(teacher, out="g7.jsonl", batch_turns=20)
        texts = [f"वाक्य {n}" for n in range(45)]
        results = stage.correct(texts, self.spec.sha256)
        self.assertEqual([r[0] for r in results], texts)
        self.assertEqual(stage.calls, 3)
        self.assertEqual([len(b) for b in teacher.gec_batches], [20, 20, 5])

    def test_usage_accumulates_across_calls(self):
        teacher = FakeTeacher()
        stage = self.make_stage(teacher, out="g8.jsonl", batch_turns=1)
        stage.correct([REPLY, "अनि, के भयो हजुर?"], self.spec.sha256)
        self.assertEqual(stage.report()["usage"],
                         {"prompt_tokens": 20, "output_tokens": 10})

    def test_a_correction_marks_changed_and_is_written(self):
        teacher = FakeTeacher(gec_correct={TT1_UTTERANCE: REPLY})
        stage = self.make_stage(teacher, out="g9.jsonl")
        results = stage.correct([TT1_UTTERANCE], self.spec.sha256)
        self.assertEqual(results[0][0], REPLY)
        record = _read_jsonl(self.tmp / "g9.jsonl")[0]
        self.assertIs(record["changed"], True)
        self.assertEqual(record["text"], TT1_UTTERANCE)
        self.assertEqual(record["corrected"], REPLY)

    def test_flush_is_ordered_by_key(self):
        teacher = FakeTeacher()
        stage = self.make_stage(teacher, out="g10.jsonl")
        stage.correct(["वाक्य ब", "वाक्य अ"], self.spec.sha256)
        records = _read_jsonl(self.tmp / "g10.jsonl")
        self.assertEqual([r["key"] for r in records],
                         sorted(r["key"] for r in records))


# ---------------------------------------------------------------------------
# Layer 2: translation tier + teacher post-edit + the human spot-check gate
# ---------------------------------------------------------------------------

#: The dev-mix source set: the three dev dialogue sets + ship L1 + L4.
_DEV_SOURCES = {"indic": INDIC, "ecommerce": ECOM, "taskmaster": TASKMASTER,
                "dailydialog": DAILYD, "teacher": TEACHER, "edge": EDGE}


def _read_review(out_dir) -> dict:
    return json.loads((Path(out_dir) / "l2-review.json").read_text(encoding="utf-8"))


def _without_cache_flag(rows) -> list:
    out = json.loads(json.dumps(rows, ensure_ascii=False))
    for row in out:
        gec = (row.get("assistant") or {}).get("gec")
        if isinstance(gec, dict):
            gec.pop("from_cache", None)
    return out


def _cand(turn_id: str, layer: str, component: str = "") -> "bc.Candidate":
    return bc.Candidate(turn_id=turn_id, layer=layer, source_id=f"{layer}-src",
                        component=component, admissibility="ship", context=[],
                        user_turn=f"u-{turn_id}", reply="r")


class L2PipelineTests(CorpusTestCase):
    def test_ship_mix_skips_dev_l2_sources_before_translation_spend(self):
        calls = []

        def translate(texts):
            calls.append(list(texts))
            return _mapped_translate(texts)

        report, out_dir, teacher = self.build(
            mix="ship", l3_target_turns=0,
            sources=dict(ecommerce=ECOM, dailydialog=DAILYD),
            translate=translate)
        self.assertEqual(calls, [])                       # no spend on dev-only rows
        self.assertEqual(teacher.postedit_prompts, [])
        self.assertEqual(report["rejections"].get("dev_only_source"), 1)
        self.assertNotIn("l2_post_edit", report["stages"])
        entry = next(s for s in report["sources"] if s["id"] == "dailydialog")
        self.assertEqual((entry["candidates"], entry["admitted"]), (1, 0))
        self.assertEqual(report["layers"]["L2"]["candidates"], 1)
        self.assertEqual(report["layers"]["L2"]["admitted"], 0)
        self.assertFalse((Path(out_dir) / "l2-review.json").exists())

    def test_dev_mix_translates_and_post_edits_with_pending_review(self):
        calls = []

        def translate(texts):
            calls.append(list(texts))
            return _mapped_translate(texts)

        report, out_dir, teacher = self.build(mix="dev", l3_target_turns=0,
                                              sources=_DEV_SOURCES,
                                              translate=translate)
        self.assertEqual(calls, [[DAILYD_ELDER_EN], [TASK_ELDER_EN]])
        self.assertEqual(report["layers"]["L1"]["admitted"], 3)
        self.assertEqual(report["layers"]["L2"]["admitted"], 2)
        self.assertEqual(report["stages"]["l2_post_edit"],
                         {"dailydialog": {"batches": 1, "turns_post_edited": 1},
                          "taskmaster": {"batches": 1, "turns_post_edited": 1}})
        # the pending batches are held out of the mixture, flagged for review
        self.assertEqual(report["held"], {"pending_spot_check": 2})
        self.assertEqual(report["stages"]["l2_spot_check"]["pending_batches"],
                         ["dailydialog#0000", "taskmaster#0000"])
        self.assertEqual(report["stages"]["l2_spot_check"]["rejected_batches"], [])
        state = _read_review(out_dir)
        self.assertEqual(state["schema"], "chat_corpus_l2_review/v1")
        for batch in ("dailydialog#0000", "taskmaster#0000"):
            self.assertEqual(state["batches"][batch]["status"], "pending")
            self.assertIsNone(state["batches"][batch]["reviewer"])
        corpus = self.corpus(out_dir, mix="dev")
        self.assertEqual(len(corpus), 4)                   # L1 3 + claw 1; L2 held
        self.assertEqual([r for r in corpus if r["layer"] == "L2"], [])
        self.assertTrue(any(r["mix_class"] == "dev-only" for r in corpus))
        # the post-edit prompts carry the spec + the Layer-1 exemplar
        self.assertEqual(len(teacher.postedit_prompts), 2)
        prompt = teacher.postedit_prompts[0]
        self.assertIn("= REAL-EXEMPLARS (Layer-1 style anchors) =", prompt)
        self.assertIn(ECOM_USER, prompt)
        self.assertIn(REPLY, prompt)
        self.assertTrue(any("post-edit prompts carry 1 Layer-1 style exemplar(s)"
                            in note for note in report["notes"]))
        # the mixture anchor note records the L2 removal
        self.assertIn("all 3 taken; claw-back capped at 1 of 3",
                      " ".join(report["mixture"]["notes"]))

    def test_spot_check_acceptance_promotes_the_batch(self):
        report, out_dir, _ = self.build(mix="dev", l3_target_turns=0,
                                        sources=_DEV_SOURCES)
        record = bc.record_spot_check(out_dir, "dailydialog#0000", "tester")
        self.assertEqual(record["status"], "spot_checked")
        self.assertEqual(record["reviewer"], "tester")
        self.assertTrue(record["recorded_at"])
        self.assertIsNone(record["note"])
        report, out_dir, _ = self.build(mix="dev", l3_target_turns=0,
                                        sources=_DEV_SOURCES, out=out_dir.name)
        self.assertEqual(report["stages"]["l2_spot_check"]["pending_batches"],
                         ["taskmaster#0000"])
        self.assertEqual(report["held"], {"pending_spot_check": 1})
        self.assertEqual(report["mixture"]["selected_per_layer"],
                         {"L1": 3, "L2": 1, "L3": 0, "L4": 2})
        corpus = self.corpus(out_dir, mix="dev")
        self.assertEqual(len(corpus), 6)
        self.assertEqual(len([r for r in corpus if r["layer"] == "L2"]), 1)

    def test_spot_check_rejection_counts_the_batch_out(self):
        report, out_dir, _ = self.build(mix="dev", l3_target_turns=0,
                                        sources=_DEV_SOURCES)
        bc.record_spot_check(out_dir, "dailydialog#0000", "tester",
                             disposition="rejected", note="machine-ish register")
        report, out_dir, _ = self.build(mix="dev", l3_target_turns=0,
                                        sources=_DEV_SOURCES, out=out_dir.name)
        stage = report["stages"]["l2_spot_check"]
        self.assertEqual(stage["rejected_batches"], ["dailydialog#0000"])
        self.assertEqual(stage["pending_batches"], ["taskmaster#0000"])
        self.assertEqual(report["mixture"]["selected_per_layer"]["L2"], 0)
        corpus = self.corpus(out_dir, mix="dev")
        self.assertEqual([r for r in corpus if r["source"] == "dailydialog"], [])
        self.assertFalse(any("dailydialog" in row["turn_id"] for row in corpus))

    def test_record_spot_check_validation(self):
        _, out_dir, _ = self.build(mix="dev", l3_target_turns=0, sources=_DEV_SOURCES)
        with self.assertRaises(ValueError):
            bc.record_spot_check(out_dir, "dailydialog#0000", "tester",
                                 disposition="approved")
        with self.assertRaises(ValueError):
            bc.record_spot_check(out_dir, "dailydialog#0000", "   ")
        with self.assertRaises(ValueError) as ctx:
            bc.record_spot_check(out_dir, "nope#9999", "tester")
        self.assertIn("unknown post-edit batch", str(ctx.exception))
        record = bc.record_spot_check(out_dir, "taskmaster#0000", "tester",
                                      note="listened to five turns")
        self.assertEqual(record["note"], "listened to five turns")
        state = _read_review(out_dir)
        self.assertEqual(state["batches"]["taskmaster#0000"]["status"], "spot_checked")

    def test_record_spot_check_cli(self):
        _, out_dir, _ = self.build(mix="dev", l3_target_turns=0, sources=_DEV_SOURCES)
        base = [sys.executable, str(ROOT / "src" / "build_chat_corpus.py"),
                "--out-dir", str(out_dir)]
        done = subprocess.run(base + ["--record-spot-check", "dailydialog#0000",
                                      "--reviewer", "cli-tester"],
                              cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(done.returncode, guards.EXIT_OK)
        self.assertIn("[spot-check] dailydialog#0000: spot_checked by cli-tester",
                      done.stdout)
        rejected = subprocess.run(base + ["--record-spot-check", "taskmaster#0000",
                                          "--reviewer", "cli-tester",
                                          "--disposition", "rejected"],
                                 cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(rejected.returncode, guards.EXIT_OK)
        self.assertIn("rejected by cli-tester", rejected.stdout)
        missing = subprocess.run(base + ["--record-spot-check", "dailydialog#0000"],
                                 cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(missing.returncode, guards.EXIT_USAGE)
        self.assertIn("--record-spot-check needs --reviewer NAME", missing.stderr)
        unknown = subprocess.run(base + ["--record-spot-check", "nope#9999",
                                         "--reviewer", "cli-tester"],
                                 cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(unknown.returncode, guards.EXIT_USAGE)
        self.assertIn("unknown post-edit batch", unknown.stderr)
        state = _read_review(out_dir)
        self.assertEqual(state["batches"]["taskmaster#0000"]["status"], "rejected")

    def test_translation_unavailable_holds_the_source(self):
        report, out_dir, teacher = self.build(mix="ship", l3_target_turns=0,
                                              sources=dict(ecommerce=ECOM,
                                                           taskmaster=TASKMASTER),
                                              translate=None)
        self.assertEqual(report["held"], {"translation_unavailable": 1})
        self.assertEqual(report["layers"]["L2"]["admitted"], 0)
        self.assertEqual(teacher.postedit_prompts, [])
        self.assertNotIn("l2_post_edit", report["stages"])
        self.assertTrue(any("translation tier unavailable (no --translation-command "
                            "and no injected translator) — 1 row(s) HELD, no "
                            "fabricated translation (T-183 training-box item)" in note
                            for note in report["notes"]))
        self.assertFalse((Path(out_dir) / "l2-review.json").exists())

    def test_translation_failure_and_short_response_hold_the_rows(self):
        def broken(texts):
            raise RuntimeError("tier down")

        report, _, _ = self.build(mix="ship", l3_target_turns=0,
                                  sources=dict(ecommerce=ECOM, taskmaster=TASKMASTER),
                                  translate=broken)
        self.assertEqual(report["held"], {"translation_unavailable": 1})
        self.assertTrue(any("translation tier failed (RuntimeError: tier down) — "
                            "rows HELD" in note for note in report["notes"]))
        report, _, _ = self.build(mix="ship", l3_target_turns=0, out="out-short",
                                  sources=dict(ecommerce=ECOM, taskmaster=TASKMASTER),
                                  translate=lambda texts: [])
        self.assertEqual(report["held"], {"translation_unavailable": 1})
        self.assertTrue(any("translation tier returned 0 of 1 rows — rows HELD "
                            "(a short response is not a translation)" in note
                            for note in report["notes"]))

    def test_post_edit_failure_holds_the_batch(self):
        report, out_dir, _ = self.build(
            mix="ship", l3_target_turns=0,
            sources=dict(ecommerce=ECOM, taskmaster=TASKMASTER),
            teacher=FakeTeacher(postedit_raise=True))
        self.assertEqual(report["held"], {"postedit_unavailable": 1})
        self.assertEqual(report["stages"]["l2_post_edit"],
                         {"taskmaster": {"batches": 1, "turns_post_edited": 0}})
        self.assertTrue(any("post-edit call for taskmaster#0000 failed "
                            "(RuntimeError: post-edit backend down) — batch held"
                            in note for note in report["notes"]))
        self.assertEqual(_read_review(out_dir)["batches"], {})
        self.assertEqual(report["stages"]["l2_spot_check"]["pending_batches"], [])
        self.assertEqual(report["layers"]["L2"]["admitted"], 0)

    def test_post_edit_batches_chunk_at_twenty(self):
        rows = [{"user_turn": f"Please book appointment number {n} soon.",
                 "reply": f"Sure, I will book appointment {n} now."}
                for n in range(21)]
        report, _, teacher = self.build(mix="ship", l3_target_turns=0,
                                        sources=dict(taskmaster=rows))
        self.assertEqual(report["stages"]["l2_post_edit"]["taskmaster"]["batches"], 2)
        self.assertEqual(report["stages"]["l2_post_edit"]["taskmaster"]["turns_post_edited"],
                         21)
        self.assertEqual(len(teacher.postedit_prompts), 2)
        self.assertEqual(sorted(_read_review(self.tmp / "out")["batches"]),
                         ["taskmaster#0000", "taskmaster#0001"])


# ---------------------------------------------------------------------------
# Layer 3: teacher generation plan, batch ids, resume, recorded failures
# ---------------------------------------------------------------------------

class L3GenerationTests(CorpusTestCase):
    def test_plan_math_matches_the_spec_class_inventory(self):
        classes = self.spec.coverage_classes()
        report, out_dir, teacher = self.build(sources={}, l3_target_turns=11)
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["target_turns"], 11)
        self.assertEqual(stage["calls_planned"], 11)
        self.assertEqual(stage["calls_executed"], 11)
        self.assertEqual(stage["calls_cached"], 0)
        self.assertEqual(stage["turns_generated"], 110)
        self.assertEqual(stage["usage"], {"prompt_tokens": 5500, "output_tokens": 2200})
        self.assertIs(stage["executed"], True)
        self.assertEqual(len(teacher.l3_keys), 11)
        self.assertEqual({key.split(":")[1] for key in teacher.l3_keys},
                         {entry["id"] for entry in classes})
        self.assertEqual(report["layers"]["L3"]["admitted"], 110)
        # no other layer: the mixture degenerates to the conversation side
        self.assertEqual(report["mixture"]["achieved"],
                         {"conversation": 110, "clawback": 0, "total": 110,
                          "conversation_share": 1.0, "clawback_share": 0.0})
        self.assertIn("degenerate mixture: no claw-back turns",
                      " ".join(report["mixture"]["notes"]))

    def test_two_calls_per_class_when_the_target_exceeds_one_batch(self):
        report, _, teacher = self.build(sources={}, l3_target_turns=220)
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["calls_planned"], 22)
        self.assertEqual(stage["calls_executed"], 22)
        self.assertEqual(stage["turns_generated"], 220)
        self.assertEqual(len(teacher.l3_keys), 22)
        self.assertEqual(len(set(teacher.l3_keys)), 22)   # batch ids never collide
        first_class = self.spec.coverage_classes()[0]["id"]
        self.assertEqual(teacher.l3_keys.count(f"l3:{first_class}:0000"), 1)
        self.assertEqual(teacher.l3_keys.count(f"l3:{first_class}:0001"), 1)

    def test_resume_replays_completed_calls(self):
        report, _, teacher = self.build(sources={}, l3_target_turns=11)
        self.assertEqual(report["stages"]["l3_generation"]["calls_executed"], 11)
        second = FakeTeacher()
        report, out_dir, _ = self.build(sources={}, l3_target_turns=11, out="out",
                                        teacher=second)
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["calls_executed"], 0)
        self.assertEqual(stage["calls_cached"], 11)
        self.assertEqual(stage["turns_generated"], 110)
        self.assertIs(stage["executed"], True)
        self.assertEqual(second.l3_keys, [])
        self.assertEqual(len(self.layer_rows(out_dir, "L3")), 110)

    def test_empty_class_response_is_counted_not_fabricated(self):
        first_class = self.spec.coverage_classes()[0]["id"]
        report, _, _ = self.build(sources={}, l3_target_turns=11,
                                  teacher=FakeTeacher(l3_empty_classes={first_class}))
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["calls_executed"], 11)     # the call happened
        self.assertEqual(stage["turns_generated"], 100)   # 10 turns were not produced
        self.assertEqual(stage["usage"], {"prompt_tokens": 5100, "output_tokens": 2000})

    def test_failed_class_call_is_recorded_and_others_continue(self):
        first_class = self.spec.coverage_classes()[0]["id"]
        report, _, _ = self.build(sources={}, l3_target_turns=11,
                                  teacher=FakeTeacher(l3_raise_classes={first_class}))
        self.assertTrue(any(
            f"L3 call l3:{first_class}:0000 failed (RuntimeError: l3 backend down)"
            in note for note in report["notes"]))
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["calls_executed"], 11)
        self.assertEqual(stage["turns_generated"], 100)
        self.assertEqual(stage["usage"], {"prompt_tokens": 5000, "output_tokens": 2000})

    def test_incomplete_turns_are_skipped(self):
        report, _, _ = self.build(sources={}, l3_target_turns=11,
                                  teacher=FakeTeacher(l3_incomplete=True))
        self.assertEqual(report["stages"]["l3_generation"]["turns_generated"], 88)

    def test_no_target_no_calls_and_no_generated_file(self):
        report, out_dir, teacher = self.build(sources={}, l3_target_turns=0)
        stage = report["stages"]["l3_generation"]
        self.assertEqual(stage["calls_planned"], 0)
        self.assertEqual(stage["calls_executed"], 0)
        self.assertEqual(stage["turns_generated"], 0)
        self.assertIs(stage["executed"], False)
        self.assertEqual(teacher.prompts, [])
        self.assertFalse((Path(out_dir) / "l3-generated.jsonl").exists())

    def test_generated_file_follows_the_plan_order(self):
        # A fresh run writes the batches in plan order (the spec's class
        # inventory), which is the deterministic order every resume re-plans.
        self.build(sources={}, l3_target_turns=11)
        records = _read_jsonl(self.tmp / "out" / "l3-generated.jsonl")
        keys = [r["key"] for r in records]
        self.assertEqual(keys, [f"l3:{entry['id']}:0000"
                                for entry in self.spec.coverage_classes()])


# ---------------------------------------------------------------------------
# Layer 4: claw-back accounting, fixture refusals, the STT-noise stage
# ---------------------------------------------------------------------------

class L4ClawbackTests(CorpusTestCase):
    def test_intent_rows_are_counted_and_missing_reports_are_recorded(self):
        report, _, _ = self.build()
        self.assertEqual(report["rejections"]["missing_reply"], 1)
        entry = next(s for s in report["sources"] if s["id"] == "intent_training_teacher")
        self.assertEqual((entry["candidates"], entry["admitted"]), (3, 2))
        edge = next(s for s in report["sources"] if s["id"] == "abstain_honesty_edge_cases")
        self.assertEqual((edge["candidates"], edge["admitted"]), (1, 1))
        self.assertEqual(report["layers"]["L4"]["candidates"], 4)
        self.assertEqual(report["layers"]["L4"]["admitted"], 3)

    def test_intent_fields_travel_into_the_row(self):
        _, out_dir, _ = self.build()
        corpus = self.corpus(out_dir)
        row = next(r for r in corpus if r["turn_id"] == "intent_training_teacher:tt-3")
        self.assertEqual(row["assistant"]["intent"],
                         {"action": "query_weather", "confidence": 0.8, "slots": None})
        self.assertEqual(row["provenance"]["user_turn_source"],
                         {"noised": True, "clean_utterance": TT3_CLEAN})
        self.assertEqual(row["language"], "ne")
        edge = next(r for r in corpus
                    if r["turn_id"] == "abstain_honesty_edge_cases:e-1")
        self.assertEqual(edge["component"], "abstain_honesty")
        self.assertEqual(edge["assistant"]["intent"],
                         {"action": "abstain", "confidence": 0.2, "slots": None})

    def test_eval_fixture_sources_are_refused_and_counted(self):
        report, _, _ = self.build()
        self.assertEqual(report["rejections"]["held_out_eval_fixture_source"], 2)
        for source_id in ("golden_corpus_fixture", "emergency_nearmiss_fixture"):
            entry = next(s for s in report["sources"] if s["id"] == source_id)
            self.assertTrue(entry["refused"], source_id)
            self.assertEqual((entry["candidates"], entry["admitted"]), (0, 0))
            self.assertIs(entry["present"], False)
        deviation = report["deviations"][0]
        self.assertEqual(deviation["id"], "eval-fixtures-refused-as-claw-back")
        self.assertIn("golden_corpus", deviation["design_reference"])
        self.assertIn("pipeline_guards.assert_not_golden_input", deviation["executed"])
        self.assertEqual(deviation["fixture_sources_refused"], 2)

    def test_fixture_rows_are_excluded_at_admission(self):
        rows = [{"id": "g", "user_turn": GOLDEN_UTTERANCE, "reply": REPLY},
                {"id": "ok", "user_turn": ECOM_USER, "reply": REPLY}]
        report, out_dir, _ = self.build(l3_target_turns=0,
                                        sources=dict(ecommerce=rows, teacher=TEACHER,
                                                     edge=EDGE))
        self.assertEqual(report["rejections"]["held_out_eval_fixture"], 1)
        self.assertEqual(report["exclusions"], {"held_out_eval_fixture": 1})
        self.assertEqual(report["deviations"][0]["fixture_rows_excluded"], 1)
        corpus = self.corpus(out_dir)
        self.assertFalse(any(r["user_turn"] == GOLDEN_UTTERANCE for r in corpus))
        entry = next(s for s in report["sources"] if s["id"] == "devanagari_ecommerce")
        self.assertEqual(entry["admitted"], 1)

    def test_absent_clawback_sources_are_recorded_not_substituted(self):
        report, _, _ = self.build(sources=dict(ecommerce=ECOM))
        for source_id, rel in (("intent_training_teacher", "data/teacher.jsonl"),
                               ("intent_training_noised", "data/noised.jsonl"),
                               ("abstain_honesty_edge_cases", "data/edge_cases.jsonl")):
            self.assertTrue(any(f"source {source_id} absent at" in note
                                and "recorded, not substituted (T-183 training-box "
                                "item)" in note for note in report["notes"]), source_id)
        self.assertEqual(report["layers"]["L4"]["admitted"], 0)
        shortfall = next(s for s in report["shortfalls"] if s["layer"] == "L4")
        self.assertEqual((shortfall["target"], shortfall["achieved"]), (12000, 0))
        self.assertIn("claw-back supply below target", shortfall["reason"])
        self.assertIn("the eval fixtures are refused", shortfall["reason"])

    def _pairs_fixture(self):
        pairs = self.tmp / "stt-pairs.jsonl"
        _write_jsonl(pairs, [
            {"clean_utterance": TT1_UTTERANCE, "utterance": TT1_NOISY},
            {"clean_utterance": E1_UTTERANCE, "utterance": E1_NOISY}])
        return pairs

    def test_stt_noise_recorded_pairs_add_variants(self):
        report, out_dir, _ = self.build(
            l3_target_turns=0, sources=dict(ecommerce=ECOM, teacher=TEACHER,
                                            edge=EDGE),
            noise_backend="recorded", noise_pairs=self._pairs_fixture())
        stage = report["stages"]["stt_noise"]
        self.assertEqual(stage["rate_target"], 0.6)
        self.assertEqual(stage["backend"], "recorded")
        self.assertEqual(stage["eligible"], 2)            # tt-3 (clean_utterance) excluded
        self.assertEqual(stage["variants"], 1)
        self.assertEqual(stage["rate_achieved"], 0.5)
        self.assertEqual(stage["noop"], 0)
        self.assertEqual(stage["failures"], 0)
        self.assertIs(stage["executed"], True)
        self.assertTrue(any("STT-noised variants: 1 (rate 0.5 vs target 0.6)" in note
                            for note in report["notes"]))
        layer = self.layer_rows(out_dir, "L4")
        self.assertEqual(len(layer), 4)                   # 3 clean + 1 variant
        noise_rows = [row for row in layer if row["turn_id"].endswith(":noise")]
        self.assertEqual(len(noise_rows), 1)
        row = noise_rows[0]
        pairs_map = {TT1_UTTERANCE: TT1_NOISY, E1_UTTERANCE: E1_NOISY}
        clean = row["provenance"]["user_turn_source"]["clean_utterance"]
        self.assertIn(clean, pairs_map)
        self.assertEqual(row["user_turn"], pairs_map[clean])
        self.assertIs(row["provenance"]["user_turn_source"]["noised"], True)
        self.assertEqual(row["assistant"]["reply"], REPLY)
        self.assertIsNotNone(row["assistant"]["gec"])
        entry = next(s for s in report["sources"]
                     if s["id"] == row["source"])
        expected_admitted = {"intent_training_teacher": 3,     # 2 clean + 1 variant
                             "abstain_honesty_edge_cases": 2}  # 1 clean + 1 variant
        self.assertEqual(entry["admitted"], expected_admitted[row["source"]])

    def test_stt_noise_rate_one_takes_every_eligible_turn(self):
        report, out_dir, _ = self.build(
            l3_target_turns=0, sources=dict(ecommerce=ECOM, teacher=TEACHER,
                                            edge=EDGE),
            noise_backend="recorded", noise_pairs=self._pairs_fixture(),
            noise_rate=1.0)
        stage = report["stages"]["stt_noise"]
        self.assertEqual(stage["variants"], 2)
        self.assertEqual(stage["rate_achieved"], 1.0)
        self.assertEqual(len(self.layer_rows(out_dir, "L4")), 5)

    def test_stt_noise_noop_and_failure_are_recorded(self):
        report, out_dir, _ = self.build(
            l3_target_turns=0, sources=dict(ecommerce=ECOM, teacher=TEACHER,
                                            edge=EDGE),
            noise_backend="recorded", noise_pairs=self._pairs_fixture(),
            noise_fn=lambda text: text)
        stage = report["stages"]["stt_noise"]
        self.assertEqual(stage["variants"], 0)
        self.assertEqual(stage["noop"], 1)                # identical round trip
        self.assertFalse(any(note.startswith("STT-noised variants:") for note in
                             report["notes"]))
        self.assertEqual(len(self.layer_rows(out_dir, "L4")), 3)

        def broken(text):
            raise RuntimeError("noise backend down")

        report, _, _ = self.build(
            l3_target_turns=0, out="out-fail",
            sources=dict(ecommerce=ECOM, teacher=TEACHER, edge=EDGE),
            noise_backend="recorded", noise_pairs=self._pairs_fixture(),
            noise_fn=broken)
        stage = report["stages"]["stt_noise"]
        self.assertEqual(stage["variants"], 0)
        self.assertEqual(stage["failures"], 1)

    def test_recorded_backend_without_pairs_file_is_recorded(self):
        report, _, _ = self.build(
            l3_target_turns=0, sources=dict(ecommerce=ECOM, teacher=TEACHER,
                                            edge=EDGE),
            noise_backend="recorded", noise_pairs=self.tmp / "missing-pairs.jsonl")
        stage = report["stages"]["stt_noise"]
        self.assertIs(stage["executed"], False)
        self.assertEqual(stage["variants"], 0)
        self.assertTrue(any(
            "STT-noised turns NOT executed (noise backend 'recorded' unavailable on "
            "this host) — 2 L4 turn(s) stay clean; recorded, never fabricated "
            "(T-183 training-box item)" in note for note in report["notes"]))

    def test_none_backend_reports_the_disabled_stage(self):
        report, _, _ = self.build()
        self.assertTrue(any(
            "STT-noised turns NOT executed (noise backend 'none' — the STT-noise "
            "stage is disabled for this run); 2 L4 turn(s) stay clean" in note
            for note in report["notes"]))

    def test_limit_per_source_caps_rows(self):
        report, _, _ = self.build(limit_per_source=1)
        teacher = next(s for s in report["sources"]
                       if s["id"] == "intent_training_teacher")
        self.assertEqual((teacher["candidates"], teacher["admitted"]), (1, 1))
        self.assertNotIn("missing_reply", report["rejections"])
        self.assertEqual(report["layers"]["L4"]["candidates"], 2)
        self.assertEqual(report["layers"]["L4"]["admitted"], 2)


# ---------------------------------------------------------------------------
# The mixture: 70/30 preserved, surplus sampled, shortfalls reported
# ---------------------------------------------------------------------------

class MixtureTests(CorpusTestCase):
    def test_surplus_clawback_is_capped_to_the_ratio(self):
        conv = [_cand(f"c{i}", "L1") for i in range(7)]
        claw = [_cand(f"b{i}", "L4", component="intent_training") for i in range(10)]
        mixture = bc.assemble_mixture(conv, claw, seed=42, log=lambda line: None)
        self.assertEqual(mixture["achieved"],
                         {"conversation": 7, "clawback": 3, "total": 10,
                          "conversation_share": 0.7, "clawback_share": 0.3})
        self.assertEqual(mixture["target"]["conversation_share"], 0.70)
        self.assertEqual(mixture["target"]["clawback_share"], 0.30)
        self.assertEqual(mixture["admitted_pools"], {"conversation": 7, "clawback": 10})
        self.assertEqual(sum(1 for c in conv + claw if c.selected), 10)

    def test_surplus_conversation_is_capped_to_the_ratio(self):
        conv = [_cand(f"c{i}", "L3") for i in range(100)]
        claw = [_cand(f"b{i}", "L4") for i in range(3)]
        mixture = bc.assemble_mixture(conv, claw, seed=42, log=lambda line: None)
        achieved = mixture["achieved"]
        self.assertEqual((achieved["conversation"], achieved["clawback"]), (7, 3))
        self.assertEqual(achieved["total"], 10)
        self.assertIn("claw-back anchors the mixture (scarce side): all 3 taken; "
                      "conversation capped at 7 of 100", mixture["notes"][0])

    def test_degenerate_mixture_takes_the_available_side_whole(self):
        claw = [_cand(f"b{i}", "L4") for i in range(3)]
        mixture = bc.assemble_mixture([], claw, seed=42, log=lambda line: None)
        self.assertEqual(mixture["achieved"]["clawback"], 3)
        self.assertEqual(mixture["achieved"]["conversation_share"], 0.0)
        self.assertIn("degenerate mixture: no conversation turns", mixture["notes"][0])
        self.assertEqual(mixture["target"]["conversation_share"], 0.70)  # unchanged

    def test_sampling_is_seeded_and_deterministic(self):
        def run():
            conv = [_cand(f"c{i}", "L1") for i in range(100)]
            claw = [_cand(f"b{i}", "L4") for i in range(50)]
            mixture = bc.assemble_mixture(conv, claw, seed=42, log=lambda line: None)
            return sorted(c.turn_id for c in conv + claw if c.selected)
        self.assertEqual(run(), run())

    def test_standard_build_mixture_exact_numbers(self):
        report, _, _ = self.build()
        mixture = report["mixture"]
        self.assertEqual(mixture["achieved"],
                         {"conversation": 7, "clawback": 3, "total": 10,
                          "conversation_share": 0.7, "clawback_share": 0.3})
        self.assertEqual(mixture["admitted_pools"], {"conversation": 111, "clawback": 3})
        self.assertEqual(mixture["notes"],
                         ["claw-back anchors the mixture (scarce side): all 3 taken; "
                          "conversation capped at 7 of 111"])
        self.assertEqual(mixture["selected_per_layer"],
                         {"L1": 0, "L2": 0, "L3": 7, "L4": 3})
        self.assertEqual(mixture["clawback_components"],
                         {"abstain_honesty": 1, "intent_training": 2})

    def test_short_mix_is_never_rebalanced(self):
        report, _, _ = self.build(mix="dev", l3_target_turns=0, sources=_DEV_SOURCES)
        mixture = report["mixture"]
        # achieved is 75/25 (claw-back is scarce and capped) but the TARGET
        # ratio stays 70/30 — recorded beside the achievement, never changed
        self.assertEqual(mixture["achieved"]["conversation_share"], 0.75)
        self.assertEqual(mixture["achieved"]["clawback_share"], 0.25)
        self.assertEqual(mixture["target"]["conversation_share"], 0.70)
        self.assertEqual(mixture["target"]["clawback_share"], 0.30)
        self.assertEqual(mixture["achieved"]["clawback"], 1)   # capped at supply

    def test_selected_rows_are_sorted_by_layer_and_turn_id(self):
        _, out_dir, _ = self.build()
        pairs = [(row["layer"], row["turn_id"]) for row in self.corpus(out_dir)]
        self.assertEqual(pairs, sorted(pairs))
        self.assertTrue(all(row["selected"] for row in self.corpus(out_dir)))


# ---------------------------------------------------------------------------
# Outputs: files, schemas, determinism, resume, the dry-run switch
# ---------------------------------------------------------------------------

class OutputContractTests(CorpusTestCase):
    def test_output_file_set(self):
        _, out_dir, _ = self.build()
        files = {p.relative_to(out_dir).as_posix()
                 for p in Path(out_dir).rglob("*") if p.is_file()}
        self.assertEqual(files, {
            "chat-corpus-ship.jsonl", "chat-corpus-counters.json", "gec-cache.jsonl",
            "l3-generated.jsonl", "l2-review.json",
            "layers/L1.jsonl", "layers/L2.jsonl", "layers/L3.jsonl", "layers/L4.jsonl"})

    def test_corpus_row_schema_and_provenance(self):
        _, out_dir, _ = self.build()
        corpus = self.corpus(out_dir)
        self.assertEqual(len(corpus), 10)
        for row in corpus:
            self.assertEqual(set(row), set(bc.CORPUS_FIELDS) | {"selected"})
            self.assertEqual(row["record"], "turn")
            self.assertEqual(row["mix_class"], "ship-eligible")
            self.assertEqual(row["language"], "ne")
            self.assertIs(row["selected"], True)
            self.assertEqual(row["assistant"]["gec"]["model"], MODEL)
            self.assertIs(row["assistant"]["gec"]["from_cache"], False)
        # layer files carry admitted-but-unselected rows too
        l1 = self.layer_rows(out_dir, "L1")
        self.assertEqual(len(l1), 1)
        self.assertEqual(l1[0]["source"], "devanagari_ecommerce")
        self.assertIs(l1[0]["selected"], False)
        l2 = self.layer_rows(out_dir, "L2")
        self.assertEqual(len(l2), 1)
        self.assertEqual(l2[0]["provenance"]["post_edit_batch"], "taskmaster#0000")
        self.assertEqual(l2[0]["user_turn"], TASK_ELDER_NE)   # the translation
        self.assertIs(l2[0]["selected"], False)
        l4 = {row["turn_id"]: row for row in self.layer_rows(out_dir, "L4")}
        self.assertEqual(len(l4), 3)

    def test_counters_top_level_shape(self):
        _, out_dir, _ = self.build()
        report = self.counters(out_dir)
        for key in ("schema", "run_id", "mix", "seed", "style_spec", "held_out_guard",
                    "layers", "mixture", "sources", "tooling", "rejections", "held",
                    "exclusions", "stages", "shortfalls", "deviations", "notes",
                    "outputs"):
            self.assertIn(key, report)
        self.assertEqual(report["schema"], bc.SCHEMA_ID)
        self.assertEqual(report["mix"], "ship")
        self.assertEqual(report["seed"], 42)
        # every FILE-BACKED source is accounted; the generated L3 layer has no
        # file and is accounted in layers.L3 + stages.l3_generation instead
        read_sources = {s.id for s in bc.SOURCE_REGISTRY if s.kind != "generated"}
        self.assertEqual({s["id"] for s in report["sources"]}, read_sources)
        self.assertEqual(len(read_sources), len(bc.SOURCE_REGISTRY) - 1)
        self.assertEqual(len(report["tooling"]), len(bc.TOOLING_SOURCES))
        self.assertEqual(report["layers"]["L3"]["selected"], 7)
        self.assertEqual(report["layers"]["L1"]["target"], None)
        self.assertEqual(report["outputs"]["corpus"], "chat-corpus-ship.jsonl")
        self.assertEqual(report["style_spec"]["sha256"], self.spec.sha256)
        self.assertEqual(report["stages"]["teacher_gec"]["model"], MODEL)

    def test_dual_run_is_byte_identical(self):
        _, out_a, _ = self.build(out="out-a")
        _, out_b, _ = self.build(out="out-b")
        for name in ("chat-corpus-ship.jsonl", "chat-corpus-counters.json",
                     "gec-cache.jsonl", "l3-generated.jsonl", "l2-review.json"):
            self.assertEqual((Path(out_a) / name).read_bytes(),
                             (Path(out_b) / name).read_bytes(), name)

    def test_resume_replays_from_cache_and_rewrites_the_same_corpus(self):
        _, out_dir, _ = self.build()
        original = self.corpus(out_dir)
        report, out_dir, teacher = self.build(out="out", teacher=FakeTeacher())
        gec = report["stages"]["teacher_gec"]
        self.assertEqual(gec["calls"], 0)
        self.assertEqual(gec["cache_hits"], 115)
        self.assertIs(gec["executed"], True)
        l3 = report["stages"]["l3_generation"]
        self.assertEqual((l3["calls_executed"], l3["calls_cached"]), (0, 11))
        self.assertEqual(teacher.gec_texts, [])           # no GEC text was re-sent
        self.assertEqual(teacher.l3_keys, [])             # no L3 batch regenerated
        self.assertEqual(len(teacher.postedit_prompts), 1)   # post-edit re-runs
        resumed = self.corpus(out_dir)
        self.assertTrue(all(row["assistant"]["gec"]["from_cache"] for row in resumed))
        self.assertEqual(_without_cache_flag(resumed), _without_cache_flag(original))
        self.assertNotEqual(resumed, original)            # the flag is the only delta

    def test_gec_budget_exhaustion_holds_every_turn(self):
        report, out_dir, teacher = self.build(gec_budget=0)
        self.assertEqual(report["held"], {"gec_missing": 115})
        self.assertEqual(report["layers"]["L1"]["admitted"], 0)
        self.assertEqual(report["layers"]["L4"]["admitted"], 0)
        self.assertEqual(report["stages"]["teacher_gec"]["calls"], 0)
        self.assertIs(report["stages"]["teacher_gec"]["budget_exhausted"], True)
        self.assertEqual(report["stages"]["teacher_gec"]["refusals"][0]["reason"],
                         "gec budget exhausted")
        self.assertEqual(teacher.gec_texts, [])           # nothing spent
        self.assertEqual(self.corpus(out_dir), [])
        self.assertEqual(report["stages"]["stt_noise"]["eligible"], 0)
        layers = {s["layer"] for s in report["shortfalls"]}
        self.assertEqual(layers, {"L1", "L2", "L3", "L4", "total"})

    def test_execute_false_is_a_dry_counters_run(self):
        # The dry-run switch skips the L1/L2 source reads and the L2/L3 teacher
        # generation; the L4 claw-back supply is still read and counted (that is
        # the quantity the dry run is for) and the GEC stage still runs on it.
        report, out_dir, teacher = self.build(execute=False)
        self.assertEqual(report["layers"]["L1"]["candidates"], 0)
        self.assertEqual(report["layers"]["L2"]["candidates"], 0)
        self.assertEqual(report["layers"]["L3"]["candidates"], 0)
        self.assertEqual(report["stages"]["l3_generation"]["calls_planned"], 11)
        self.assertEqual(report["stages"]["l3_generation"]["calls_executed"], 0)
        self.assertIs(report["stages"]["l3_generation"]["executed"], False)
        self.assertFalse((Path(out_dir) / "l3-generated.jsonl").exists())
        self.assertFalse((Path(out_dir) / "l2-review.json").exists())
        self.assertEqual([s["id"] for s in report["sources"]],
                         ["intent_training_teacher", "intent_training_noised",
                          "abstain_honesty_edge_cases", "golden_corpus_fixture",
                          "emergency_nearmiss_fixture"])
        self.assertEqual(report["layers"]["L4"]["candidates"], 4)
        self.assertEqual(report["layers"]["L4"]["admitted"], 3)
        self.assertEqual(len(teacher.prompts), 1)         # GEC only
        self.assertIn("degenerate mixture: no conversation turns",
                      " ".join(report["mixture"]["notes"]))
        self.assertEqual(len(self.corpus(out_dir)), 3)
        self.assertNotIn("unclassified_source", report["rejections"])
        self.assertEqual(report["rejections"]["held_out_eval_fixture_source"], 2)


# ---------------------------------------------------------------------------
# The CLI: offline plan, offline replay, exit codes, usage errors
# ---------------------------------------------------------------------------

class CliTests(CorpusTestCase):
    def _cli(self, *args):
        return subprocess.run(
            [sys.executable, str(ROOT / "src" / "build_chat_corpus.py"), *args],
            cwd=ROOT, capture_output=True, text=True)

    def test_plan_prints_registry_refusals_and_mixture(self):
        done = self._cli("--plan")
        self.assertEqual(done.returncode, guards.EXIT_OK)
        self.assertTrue(done.stdout.startswith(
            "chat_corpus/v1 — layers, sources, mixture (seed default 42)"))
        self.assertIn("L1 — native Nepali conversation (target supply-driven)",
                      done.stdout)
        self.assertIn("L4 — retention claw-back (target 12000)", done.stdout)
        self.assertIn("REFUSED: it IS the held-out intent eval set", done.stdout)
        self.assertIn("tooling inputs (classified for the provenance manifest):",
                      done.stdout)
        self.assertIn("mixture: conversation 70% / claw-back 30%", done.stdout)
        self.assertNotIn("[guard] STOPPED", done.stderr)

    def test_plan_in_process(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = bc.main(["--plan"])
        self.assertEqual(rc, guards.EXIT_OK)
        self.assertIn("chat_corpus/v1", out.getvalue())

    def test_record_spot_check_usage_errors_in_process(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = bc.main(["--record-spot-check", "b#0000",
                          "--out-dir", str(self.tmp / "nowhere")])
        self.assertEqual(rc, guards.EXIT_USAGE)
        self.assertIn("--record-spot-check needs --reviewer NAME", err.getvalue())
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = bc.main(["--record-spot-check", "b#0000", "--reviewer", "x",
                          "--out-dir", str(self.tmp / "nowhere")])
        self.assertEqual(rc, guards.EXIT_USAGE)
        self.assertIn("unknown post-edit batch", err.getvalue())

    def test_unknown_mix_is_an_argparse_usage_error(self):
        with self.assertRaises(SystemExit) as ctx:
            bc.main(["--mix", "staging"])
        self.assertEqual(ctx.exception.code, guards.EXIT_USAGE)

    def test_e2e_record_and_replay_offline_byte_identical(self):
        # The translation tier runs the SAME recorded command in both runs, so
        # every prompt the recording run recorded is byte-reproducible offline.
        script = self.tmp / "translate_fixture.py"
        mapping = json.dumps({TASK_ELDER_EN: TASK_ELDER_NE,
                              DAILYD_ELDER_EN: DAILYD_ELDER_NE}, ensure_ascii=False)
        script.write_text(
            "import json, sys\n"
            f"MAPPING = json.loads({mapping!r})\n"
            "for line in sys.stdin:\n"
            "    if not line.strip():\n"
            "        continue\n"
            "    text = json.loads(line)['text']\n"
            "    print(json.dumps({'text': MAPPING.get(text, "
            + repr(TASK_ELDER_NE) + ")}, ensure_ascii=False))\n",
            encoding="utf-8")
        command = f"{sys.executable} {script}"
        recorder = RecordingTeacher(FakeTeacher())
        report, out_a, _ = self.build(teacher=recorder, guard=None, translate=None,
                                      translation_command=command,
                                      teacher_transport="teacher-fixture",
                                      out="out-e2e-a")
        self.assertEqual(len(recorder.records), 18)       # 6 GEC + 11 L3 + 1 post-edit
        fixture = self.tmp / "teacher-fixture.jsonl"
        recorder.write_fixture(fixture)
        src_root = self.tmp / "sources"
        out_b = self.tmp / "out-e2e-b"
        done = self._cli("--mix", "ship", "--source-root", str(src_root),
                         "--out-dir", str(out_b), "--run-id", "t179-test",
                         "--l3-target-turns", "11", "--noise-backend", "none",
                         "--translation-command", command,
                         "--teacher-transport", "teacher-fixture",
                         "--teacher-fixture", str(fixture))
        self.assertEqual(done.returncode, guards.EXIT_FLOOR)
        self.assertEqual(done.stderr, "")
        self.assertIn("[floors] 3 shortfall(s) recorded", done.stdout)
        for name in ("chat-corpus-ship.jsonl", "chat-corpus-counters.json"):
            self.assertEqual((Path(out_a) / name).read_bytes(),
                             (out_b / name).read_bytes(), name)
        replay = json.loads((out_b / "chat-corpus-counters.json").read_text("utf-8"))
        self.assertEqual(replay["stages"]["teacher_gec"]["transport"],
                         "teacher-fixture")
        self.assertEqual(len(self.corpus(out_b)), 10)

    def test_missing_teacher_fixture_stops_the_run(self):
        out = self.tmp / "out-stopped"
        done = self._cli("--out-dir", str(out), "--run-id", "t179-test",
                         "--teacher-transport", "teacher-fixture",
                         "--teacher-fixture", str(self.tmp / "missing.jsonl"))
        self.assertEqual(done.returncode, guards.EXIT_GUARD)
        self.assertIn("[guard] STOPPED: teacher fixture not found", done.stderr)
        self.assertIn("the recorded responses file the transport replays", done.stderr)
        counters = json.loads((out / "chat-corpus-counters.json").read_text("utf-8"))
        self.assertIs(counters["stopped"], True)
        self.assertIn("teacher fixture not found", counters["stop_reason"])
        self.assertEqual(counters["schema"], bc.SCHEMA_ID)


# ---------------------------------------------------------------------------
# The real held-out fixtures (the T-178 output, pinned by revision + sha256)
# ---------------------------------------------------------------------------

REAL_CHAT_GOLDEN_SHA256 = ("8328366331996b3e3fc809e360208c2fb6365c0aeb1a71e90752f1"
                           "569fcb1519")
REAL_CHAT_GOLDEN_REVISION = "83283663"


class RealFixtureTests(CorpusTestCase):
    def test_real_chat_golden_is_pinned(self):
        path = Path(acg.CHAT_GOLDEN_PATH)
        self.assertTrue(path.is_file())
        self.assertEqual(acg.content_sha256(path), REAL_CHAT_GOLDEN_SHA256)
        golden = acg.load(path)
        self.assertEqual(golden.revision, REAL_CHAT_GOLDEN_REVISION)
        self.assertEqual(len(golden.turns), 500)
        self.assertEqual(len(acg.held_out_keys(path)), 500)
        with self.assertRaises(acg.ChatGoldenError):
            acg.require_gate_fixture(path)     # human review still pending (T-178)

    def test_real_guard_loads_the_defaults_without_gating_on_eligibility(self):
        guard = bc.HeldOutGuard.load()
        evidence = guard.evidence()
        chat = evidence["chat_golden"]
        self.assertEqual(chat["sha256"], REAL_CHAT_GOLDEN_SHA256)
        self.assertEqual(chat["revision"], REAL_CHAT_GOLDEN_REVISION)
        self.assertEqual(chat["turns"], 500)
        self.assertIs(chat["eligible_gate_fixture"], False)
        self.assertEqual(evidence["exact_user_keys"], 500)
        self.assertIs(evidence["nearmiss_guarded"], True)
        golden_keys = guards.golden_keys(guards.GOLDEN_CORPUS)
        self.assertGreaterEqual(evidence["golden_corpus"]["keys"], len(golden_keys))

    def test_real_guard_excludes_real_held_out_texts(self):
        guard = bc.HeldOutGuard.load()
        turns = acg.load().turns
        first = turns[0]
        exclusion = guard.check_user_turn(first["user_turn"])
        self.assertEqual(exclusion["rule"], "held_out_user_turn")
        exclusion = guard.check_reply(first["acceptable_output"])
        self.assertEqual(exclusion["rule"], "held_out_reply")
        first_golden_line = (ROOT / "eval" / "golden_corpus.jsonl") \
            .read_text(encoding="utf-8").splitlines()[0]
        utterance = json.loads(first_golden_line)["utterance"]
        exclusion = guard.check_user_turn(utterance)
        self.assertEqual(exclusion["rule"], "held_out_eval_fixture")

    def test_real_build_rejects_and_excludes_fixture_material(self):
        turns = acg.load().turns
        clean_replies = [
            t["acceptable_output"] for t in turns
            if len(bc.word_tokens(t["acceptable_output"])) >= 2
            and not acg.mechanical_review(t["acceptable_output"], self.spec)["violations"]]
        self.assertTrue(clean_replies, "no reference reply passes the mechanical review")
        reference_reply = clean_replies[0]
        golden_utterance = json.loads(
            (ROOT / "eval" / "golden_corpus.jsonl").read_text(encoding="utf-8")
            .splitlines()[0])["utterance"]
        rows = [{"id": "x-user", "user_turn": turns[0]["user_turn"], "reply": REPLY},
                {"id": "x-reply", "user_turn": ECOM_USER, "reply": reference_reply},
                {"id": "x-golden", "user_turn": golden_utterance, "reply": REPLY}]
        report, out_dir, _ = self.build(
            sources=dict(ecommerce=rows, teacher=TEACHER, edge=EDGE), guard=None)
        self.assertEqual(report["rejections"]["held_out_user_turn"], 1)
        self.assertEqual(report["rejections"]["held_out_reply"], 1)
        self.assertEqual(report["rejections"]["held_out_eval_fixture"], 1)
        self.assertEqual(report["exclusions"], {"held_out_eval_fixture": 1,
                                                "held_out_reply": 1,
                                                "held_out_user_turn": 1})
        self.assertEqual(report["deviations"][0]["fixture_rows_excluded"], 1)
        entry = next(s for s in report["sources"] if s["id"] == "devanagari_ecommerce")
        self.assertEqual((entry["candidates"], entry["admitted"]), (3, 0))
        corpus = self.corpus(out_dir)
        self.assertEqual(len(corpus), 10)                 # L3 7 + claw 3
        forbidden = {turns[0]["user_turn"], reference_reply, golden_utterance}
        for row in corpus:
            self.assertNotIn(row["user_turn"], forbidden)
            self.assertNotIn(row["assistant"]["reply"], forbidden)
        self.assertEqual(report["mixture"]["selected_per_layer"],
                         {"L1": 0, "L2": 0, "L3": 7, "L4": 3})


# ---------------------------------------------------------------------------
# The unit spec's scenarios, end to end
# ---------------------------------------------------------------------------

class AcceptanceTests(CorpusTestCase):
    """One test per T-179 acceptance criterion / failure path."""

    def test_ac1_four_layers_counted_with_clawback_share_and_noise_rate(self):
        report, _, _ = self.build()
        layers = report["layers"]
        self.assertEqual(layers["L1"]["admitted"], 1)
        self.assertEqual(layers["L2"]["admitted"], 1)
        self.assertEqual(layers["L3"]["admitted"], 110)
        self.assertEqual(layers["L4"]["admitted"], 3)
        for layer in bc.LAYERS:
            self.assertIn("admitted", layers[layer])
            self.assertIn("candidates", layers[layer])
        achieved = report["mixture"]["achieved"]
        self.assertEqual(achieved["clawback_share"], 0.3)   # ~30% of the mixture
        self.assertEqual(report["stages"]["stt_noise"]["rate_target"],
                         bc.STT_NOISE_RATE_DEFAULT)
        cfg_path = ROOT / "config.yaml"
        if yaml is not None and cfg_path.is_file():
            cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
            self.assertEqual(float(cfg["mixture"]["stt_noised"]), 0.6)

    def test_ac2_filters_reject_and_count_each_rule(self):
        forbidden = self.spec.register()["forbidden_address_forms"][0]
        ai_entry = next(e for e in self.spec.forbidden_ai_isms()
                        if e["id"] == "canned_service_phrase")
        rows = [{"id": "ok", "user_turn": ECOM_USER, "reply": REPLY},
                {"id": "hon", "user_turn": "तपाईंको दिन कस्तो छ?",
                 "reply": f"{forbidden} कस्तो छ?"},
                {"id": "ai", "user_turn": "मलाई सहयोग चाहियो हजुर।",
                 "reply": f"{ai_entry['patterns'][0]} हजुर।"},
                {"id": "short", "user_turn": "ठीक छ हजुर?", "reply": "हजुर।"}]
        report, out_dir, _ = self.build(
            l3_target_turns=0,
            sources=dict(ecommerce=rows, teacher=TEACHER, edge=EDGE))
        self.assertEqual(report["rejections"]["honorific_agreement"], 1)
        self.assertEqual(report["rejections"]["no_ai_isms"], 1)
        self.assertEqual(report["rejections"]["length"], 1)
        entry = next(s for s in report["sources"] if s["id"] == "devanagari_ecommerce")
        self.assertEqual(entry["admitted"], 1)
        admitted_texts = {row["user_turn"] for row in self.corpus(out_dir)}
        for bad_user in ("तपाईंको दिन कस्तो छ?", "मलाई सहयोग चाहियो हजुर।", "ठीक छ हजुर?"):
            self.assertNotIn(bad_user, admitted_texts)

    def test_ac3_every_assistant_turn_is_gec_corrected(self):
        defect = "हजुर , म ठीक छु. तपाईंलाई धन्यवाद हजुर।"
        rows = [{"id": "p", "user_turn": "आज कस्तो दिन भयो हजुर?", "reply": defect}]
        report, out_dir, teacher = self.build(
            l3_target_turns=0,
            sources=dict(ecommerce=rows, teacher=TEACHER, edge=EDGE),
            teacher=FakeTeacher(gec_correct={defect: REPLY}))
        corpus = self.corpus(out_dir)
        row = next(r for r in corpus if r["source"] == "devanagari_ecommerce")
        self.assertEqual(row["assistant"]["reply"], REPLY)      # the corrected text
        self.assertNotIn(defect, [r["assistant"]["reply"] for r in corpus])
        for candidate_row in corpus:
            self.assertIsNotNone(candidate_row["assistant"]["gec"])
        gec = report["stages"]["teacher_gec"]
        self.assertEqual(gec["model"], MODEL)
        self.assertEqual(gec["temperature"], 0.0)
        self.assertEqual(gec["transport"], "gemini")
        self.assertEqual(gec["calls"], 1)         # ecommerce 1 + L4 3 in one batch
        self.assertEqual(gec["budget_calls"], 2000)
        self.assertEqual(gec["usage"], {"prompt_tokens": 10, "output_tokens": 5})
        cache = _read_jsonl(Path(out_dir) / "gec-cache.jsonl")
        record = next(r for r in cache if r["text"] == defect)
        self.assertEqual(record["corrected"], REPLY)
        self.assertIs(record["changed"], True)
        self.assertTrue(any(defect == text for text in teacher.gec_texts))

    def test_ac4_held_out_dedupe_at_admission_reported_by_rule(self):
        rows = [{"id": "u", "user_turn": GUARD_USER_1, "reply": REPLY},
                {"id": "g", "user_turn": GOLDEN_UTTERANCE, "reply": REPLY},
                {"id": "ok", "user_turn": ECOM_USER, "reply": REPLY}]
        report, out_dir, _ = self.build(
            l3_target_turns=0,
            sources=dict(ecommerce=rows, teacher=TEACHER, edge=EDGE))
        self.assertEqual(report["rejections"]["held_out_user_turn"], 1)
        self.assertEqual(report["rejections"]["held_out_eval_fixture"], 1)
        self.assertEqual(report["exclusions"], {"held_out_eval_fixture": 1,
                                                "held_out_user_turn": 1})
        users = {row["user_turn"] for row in self.corpus(out_dir)}
        self.assertNotIn(GUARD_USER_1, users)
        self.assertNotIn(GOLDEN_UTTERANCE, users)

    def test_ac5_layer_shortfalls_are_reported_and_not_rebalanced(self):
        report, _, _ = self.build()
        shortfalls = {s["layer"]: s for s in report["shortfalls"]}
        self.assertEqual((shortfalls["L3"]["target"], shortfalls["L3"]["achieved"]),
                         (10000, 110))
        self.assertEqual((shortfalls["L4"]["target"], shortfalls["L4"]["achieved"]),
                         (12000, 3))
        self.assertEqual((shortfalls["total"]["target"], shortfalls["total"]["achieved"]),
                         (40000, 10))
        for shortfall in report["shortfalls"]:
            self.assertTrue(shortfall["reason"].strip())
        self.assertEqual(report["mixture"]["target"]["conversation_share"], 0.70)
        self.assertEqual(report["mixture"]["target"]["clawback_share"], 0.30)

    def test_ac6_unavailable_filter_stops_the_run(self):
        out = self.tmp / "out-stop"
        opts = bc.BuildOptions(mix="ship", source_root=self.tmp / "no-sources",
                               out_dir=out)
        with mock.patch.object(bc, "_SPEC_CACHE", {}), \
                mock.patch.object(ss, "load", side_effect=ss.StyleSpecError("boom")):
            with self.assertRaises(bc.BuildStopped) as ctx:
                bc.build_chat_corpus(opts, spec=None, teacher=FakeTeacher(),
                                     translate=_mapped_translate, held_out=self.guard,
                                     log=lambda line: None)
        self.assertIn("style spec unavailable — filters cannot run", str(ctx.exception))
        with self.assertRaises(bc.BuildStopped) as ctx:
            bc.build_chat_corpus(
                bc.BuildOptions(mix="prod", out_dir=self.tmp / "out-x"),
                spec=self.spec, teacher=FakeTeacher(), held_out=self.guard)
        self.assertIn("unknown mix", str(ctx.exception))
        with mock.patch.object(acg, "CHAT_GOLDEN_PATH", self.tmp / "gone.jsonl"):
            with self.assertRaises(bc.BuildStopped) as ctx:
                bc.build_chat_corpus(
                    bc.BuildOptions(mix="ship", source_root=self.tmp / "no-sources",
                                    out_dir=self.tmp / "out-y"),
                    spec=self.spec, teacher=FakeTeacher(),
                    translate=_mapped_translate, log=lambda line: None)
        self.assertIn("held-out chat set unavailable", str(ctx.exception))

    def test_ac7_unreviewed_post_edit_is_flagged_not_counted(self):
        report, out_dir, _ = self.build(mix="dev", l3_target_turns=0,
                                        sources=_DEV_SOURCES)
        self.assertEqual(report["held"]["pending_spot_check"], 2)
        self.assertEqual(report["stages"]["l2_spot_check"]["pending_batches"],
                         ["dailydialog#0000", "taskmaster#0000"])
        self.assertTrue(any("pending human spot-check" in note
                            for note in report["notes"]))
        self.assertEqual(report["mixture"]["admitted_pools"]["conversation"], 3)
        self.assertFalse(any(row["layer"] == "L2" for row in self.corpus(out_dir,
                                                                        mix="dev")))

    def test_ac8_dev_ship_separation_is_a_build_parameter(self):
        ship, out_ship, _ = self.build(
            sources=dict(indic=INDIC, ecommerce=ECOM, taskmaster=TASKMASTER,
                         dailydialog=DAILYD, teacher=TEACHER, edge=EDGE))
        self.assertEqual(ship["rejections"]["dev_only_source"], 3)   # indic 2 + dd 1
        self.assertEqual(ship["rejections"]["unclassified_source"], 2)
        self.assertFalse(any(row["mix_class"] != "ship-eligible"
                             for row in self.corpus(out_ship)))
        dev, out_dev, _ = self.build(mix="dev", l3_target_turns=0,
                                     sources=_DEV_SOURCES)
        self.assertNotIn("dev_only_source", dev["rejections"])
        self.assertEqual(dev["rejections"]["unclassified_source"], 2)
        self.assertTrue(any(row["mix_class"] == "dev-only"
                            for row in self.corpus(out_dev, mix="dev")))
        self.assertEqual(dev["layers"]["L1"]["admitted"], 3)

    def test_ac9_outputs_are_deterministic(self):
        _, out_a, _ = self.build(out="out-a")
        _, out_b, _ = self.build(out="out-b")
        self.assertEqual((Path(out_a) / "chat-corpus-ship.jsonl").read_bytes(),
                         (Path(out_b) / "chat-corpus-ship.jsonl").read_bytes())
        self.assertEqual((Path(out_a) / "chat-corpus-counters.json").read_bytes(),
                         (Path(out_b) / "chat-corpus-counters.json").read_bytes())

    def test_ac10_stt_noised_turn_is_added_at_the_recorded_rate(self):
        report, out_dir, _ = self.build(
            l3_target_turns=0,
            sources=dict(ecommerce=ECOM, teacher=TEACHER, edge=EDGE),
            noise_backend="recorded", noise_pairs=self._pairs_fixture())
        self.assertEqual(report["stages"]["stt_noise"]["variants"], 1)
        self.assertIs(report["stages"]["stt_noise"]["executed"], True)
        layer = self.layer_rows(out_dir, "L4")
        self.assertTrue(any(row["turn_id"].endswith(":noise") for row in layer))

    def _pairs_fixture(self):
        pairs = self.tmp / "acceptance-pairs.jsonl"
        _write_jsonl(pairs, [
            {"clean_utterance": TT1_UTTERANCE, "utterance": TT1_NOISY},
            {"clean_utterance": E1_UTTERANCE, "utterance": E1_NOISY}])
        return pairs


if __name__ == "__main__":
    unittest.main()
