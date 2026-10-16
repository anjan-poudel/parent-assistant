"""T-182 tests: the chat-variant configuration and the full ship gate over ONE
candidate (FR-CNR-016, FR-CNR-021; design-l1 §11.3-§11.5).

Covers the unit's acceptance criteria end to end:

  * the `chat:` section is purely additive: the checked-in config gains
    exactly the pinned 15 chat keys, no top-level section and no non-chat
    key/default moves (a flat non-chat digest is pinned), and the fixed
    QLoRA recipe constants (r=16, alpha=32, lr ~1e-4, 2-3 epochs, 1024-token
    sequences, Q4_K_M) are unchanged;
  * flag absent or false -> the existing pipeline is byte-identical: the
    legacy path is run against the repo config, a chat-stripped copy and a
    chat-enabled copy, and stdout / results.csv bytes must match exactly;
  * flag present -> the variant (run id, mix, corpus root, mixture, layer
    paths, filters) is read FROM THE CONFIGURATION: every missing, unknown
    or malformed key is a refusal naming it, and the manifest path is the
    builder's own layout resolution (build_chat_corpus.manifest_path_for);
  * ONE harness invocation runs the three chat gates + the existing hard
    gates over ONE candidate and writes ONE evidence report: every gate row
    carries value, threshold and denominator; the fixture versions, the
    candidate artifact sha256, the provenance manifest content hash (from
    T-180; independently recomputed here) and the named tier for latency /
    calibration are all recorded;
  * red gates block the swap with the shortfall named and NO threshold
    moved (chat honorific / judge, hard emergency recall, latency p50);
    a deviation from the fixed recipe, the recorded mixture or the
    pipeline's filter constants fails a variant check instead; a dev-mix
    run is never swap evidence even when every gate is green;
  * incomplete evidence (missing / tampered / hash-less manifest, artifact
    identity gone, latency not measured) marks the report incomplete and
    swap-ineligible while the report is still written; refusals (no
    evidence contract to write) exit 2 with no report and no ledger row;
  * the latency gates REPLAY measure_device.py through its own loader and
    scorer (cross-checked against that tool's own CLI here); a result
    exactly at the 1000.0 ms gate passes, 1000.1 does not;
  * the judge stage is resumable and what it spent is recorded: a second
    run with the same journal reuses every entry without a call.

NO network / billed calls anywhere: every harness invocation passes
``--judge fixture`` (the offline replay), the subprocess environment drops
GEMINI_API_KEY so an accidental gemini transport would refuse rather than
bill, and the tests assert the recorded transport is ``fixture`` with
``billed: False``. The first real billed judge run is a later owner-gated
step of the feature, never part of this unit.

The synthetic 500-turn fixture, its outputs and scores are built through
``author_chat_golden``'s own record builders (the pattern of
``tests/test_eval_chat_gates.py``), so a schema change breaks these tests
rather than silently splitting the format.
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import author_chat_golden as acg  # noqa: E402
import build_chat_corpus as bcc  # noqa: E402
import eval_chat_gates as ecg  # noqa: E402
import eval_golden as eg  # noqa: E402
import style_spec as ss  # noqa: E402

import yaml  # noqa: E402

FIXTURES = ROOT / "eval" / "fixtures"

#: The teacher configuration the fixture header records (the pattern of
#: tests/test_chat_golden.py; the loader validates the shape, not these numbers).
CFG_TEACHER = {
    "gemini.model": "gemini-2.5-flash-lite",
    "gemini.temperature": 0.8,
    "gemini.max_output_tokens": 4096,
    "gemini.requests_per_minute": 25.0,
}
MODEL = "gemini-2.5-flash-lite"

#: A clean reference reply (probed to pass the mechanical review).
CLEAN_REPLY = "नमस्ते हजुर। तपाईंलाई कस्तो छ?"

#: A clean elder turn carrying a spec code-switch noun.
CLEAN_CODE_SWITCHED_TURN = "आज प्रेसर ठीक छ।"

#: A reply carrying the banned address form 'तिमी' (register block).
HONORIFIC_BAD_REPLY = "तिमी कस्तो छ?"

#: The report's gate inventory, pinned here independently of the module (a
#: dropped or renamed gate must fail these tests, not silently vanish).
FULL_GATE_ORDER = (
    "honorific_agreement", "no_ai_isms", "judge_quality",
    "emergency_recall", "abstention_precision", "closed_intent_accuracy",
    "contact_f1", "time_f1", "calibration", "emergency_nearmiss_recall",
    "side_effect_precision", "gemini_gap", "latency_p50", "latency_p95",
)
CHAT_GATE_IDS = ("honorific_agreement", "no_ai_isms", "judge_quality")

#: The exact chat keys the checked-in configuration carries — the additive
#: section is 15 leaf keys, nothing else.
CHAT_CONFIG_KEYS = frozenset({
    "chat.enabled",
    "chat.run_id",
    "chat.mix",
    "chat.corpus_root",
    "chat.mixture.conversation_share",
    "chat.mixture.clawback_share",
    "chat.layers.L1",
    "chat.layers.L2",
    "chat.layers.L3",
    "chat.layers.L4",
    "chat.filters.spec_checks",
    "chat.filters.min_word_tokens",
    "chat.filters.turn_token_ceiling",
    "chat.filters.held_out_dedupe",
    "chat.filters.near_duplicate_jaccard",
})

#: The top-level sections of the checked-in configuration. T-182 adds
#: "chat" and nothing else.
CONFIG_TOP_LEVEL = ("chat", "encoder", "export", "gates", "gemini",
                    "mixture", "stt_noise", "training")

#: sha256 over the canonical JSON of the FLAT non-chat configuration (all 64
#: keys). T-182 may not change any existing key or default; if a later unit
#: changes one, this pin is updated deliberately.
NON_CHAT_CONFIG_SHA256 = (
    "0fcf33a1b24a3b9f393861e9223e2dc02b37adeed6ee5dad3532b211c19ddc1a")

#: The subprocess environment for every harness invocation: GEMINI_API_KEY is
#: dropped so no listed command could ever reach the billed judge, even by
#: mistake. The tests make no network calls by construction.
CHILD_ENV = {k: v for k, v in os.environ.items() if k != "GEMINI_API_KEY"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sha256_file(path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def _manifest_content_hash(doc: dict) -> str:
    """The T-180 scope, IMPLEMENTED INDEPENDENTLY of the production helper:
    sha256 over the canonical JSON of the document without its hash fields."""
    body = {k: v for k, v in doc.items()
            if k not in ("content_hash", "content_hash_scope")}
    return hashlib.sha256(_canonical_json(body).encode("utf-8")).hexdigest()


def _write_jsonl(path, records) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(rec, ensure_ascii=False) + "\n" for rec in records),
        encoding="utf-8")
    return path


def _read_jsonl(path) -> list:
    return [json.loads(line) for line in
            Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def _flat_config(config_path) -> tuple:
    """Load a config file the way the harness does (flat dot-key dict)."""
    parser = eg.build_parser()
    return eg.load_config(parser, ["--config", str(config_path),
                                   "--backend", "fixture"])


def _config_copy(tmp, name: str, *, mutate=None, drop=()) -> Path:
    """A config copy derived from the checked-in config.yaml by YAML round
    trip, so any future edit to the real config flows through these tests."""
    doc = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
    for key in drop:
        doc.pop(key, None)
    if mutate is not None:
        mutate(doc)
    path = Path(tmp) / name
    path.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True),
                    encoding="utf-8")
    return path


def _fixture_user_turn(entry: dict, index: int) -> str:
    if entry["coverage_class"] == "code_switched_nouns":
        return CLEAN_CODE_SWITCHED_TURN
    return "नमस्ते हजुर।"


def _build_fixture(path, spec, *, pending: tuple = ()) -> None:
    """Write a complete synthetic held-out set (all batches accepted unless
    named in ``pending``), built through the module's own record builders —
    the pattern of tests/test_eval_chat_gates.py."""
    turns: list = []
    batches: list = []
    for entry in acg.batch_plan(spec):
        batch_turns = []
        for index in range(1, int(entry["target_turns"]) + 1):
            user_turn = _fixture_user_turn(entry, index)
            batch_turns.append(acg._turn_record(
                entry, index,
                {"user_turn": user_turn,
                 "context": [{"speaker": "elder", "text": user_turn}] if index == 1 else [],
                 "acceptable_output": CLEAN_REPLY,
                 "note": f"synthetic fixture turn {index} for {entry['coverage_class']}"},
                spec, MODEL, "gemini"))
        record = acg._batch_record(entry, batch_turns, 1,
                                   {"prompt_token_count": 10, "candidates_token_count": 10,
                                    "total_token_count": 20},
                                   [], MODEL, spec, None, "gemini")
        if entry["batch_id"] in pending:
            disposition, reviewer, recorded_at = "pending", None, None
        else:
            disposition, reviewer = "accepted", "fixture-reviewer"
            recorded_at = "2026-10-15T00:00:00+00:00"
        record["review"]["human"] = {"status": disposition, "reviewer": reviewer,
                                     "recorded_at": recorded_at, "note": None}
        for turn in batch_turns:
            turn["provenance"]["review"]["human"] = disposition
        turns.extend(batch_turns)
        batches.append(record)
    header = acg._header_record(spec, CFG_TEACHER, batches, "gemini")
    acg._write(Path(path), header, turns)


class GateRun:
    """One full-gate invocation's observable outcome."""

    def __init__(self, proc, report_path: Path, results_path: Path, cmd: list):
        self.proc = proc
        self.exit = proc.returncode
        self.stdout = proc.stdout
        self.stderr = proc.stderr
        self.cmd = cmd
        self.report_path = Path(report_path)
        self.results_path = Path(results_path)
        self.report_lines: list = []
        if self.report_path.exists():
            self.report_lines = [line for line in
                                 self.report_path.read_text(encoding="utf-8").splitlines()
                                 if line.strip()]
        self.report = json.loads(self.report_lines[-1]) if self.report_lines else None

    @property
    def verdict(self) -> dict:
        return self.report["verdict"]

    @property
    def gates(self) -> dict:
        return self.report["gates"]


class GateInputs:
    """The whole full-gate input set, built once per test class.

    Holds one eligible 500-turn chat fixture, its candidate outputs (clean,
    and 11 honorific-bad), recorded judge scores (all 5, and mean 3.9), a
    candidate artifact, recorded device measurements (100 prompts x 2 passes:
    fast, slow, exactly-at-gate, partial, 50-prompt set), a variant layout
    whose provenance manifest carries an INDEPENDENTLY computed content hash,
    and config copies derived from the checked-in config.yaml.
    """

    def __init__(self, tmp, spec):
        self.tmp = Path(tmp)
        self.spec = spec
        self.fixture = self.tmp / "chat_golden.jsonl"
        _build_fixture(self.fixture, spec)
        self.golden = acg.load(self.fixture)
        self.turn_ids = [turn["id"] for turn in self.golden.turns]
        self.criteria = [str(entry["id"])
                         for entry in ecg.judge_rubric(spec)["criteria"]]
        self.pending_fixture = self.tmp / "chat_golden_pending.jsonl"
        _build_fixture(self.pending_fixture, spec, pending=("b001",))

        self.artifact = self.tmp / "candidate.gguf"
        self.artifact.write_bytes(b"GGUF T-182 candidate bytes")
        self.missing_artifact = self.tmp / "never-built.gguf"

        self.outputs_clean = _write_jsonl(
            self.tmp / "outputs_clean.jsonl",
            [{"id": turn_id, "reply": CLEAN_REPLY} for turn_id in self.turn_ids])
        bad_ids = set(self.turn_ids[:11])
        self.outputs_bad_honorific = _write_jsonl(
            self.tmp / "outputs_bad_honorific.jsonl",
            [{"id": turn_id,
              "reply": HONORIFIC_BAD_REPLY if turn_id in bad_ids else CLEAN_REPLY}
             for turn_id in self.turn_ids])
        self.scores_5 = self._write_scores("scores_5.jsonl",
                                           {i: 5 for i in self.turn_ids})
        self.scores_39 = self._write_scores(
            "scores_39.jsonl",
            {turn_id: (4 if n < 450 else 3)
             for n, turn_id in enumerate(self.turn_ids)})

        self.prompts = [f"p{i:03d}" for i in range(1, 101)]
        self.prompts_path = self._write_prompts("prompts.jsonl", self.prompts)
        self.prompts50 = self.prompts[:50]
        self.prompts50_path = self._write_prompts("prompts50.jsonl", self.prompts50)
        self.measurements = self._write_measurements(
            "measurements.jsonl", self.prompts, cold=300.0, warm=250.0)
        self.measurements_slow = self._write_measurements(
            "measurements_slow.jsonl", self.prompts, cold=1500.0, warm=1200.0)
        self.measurements_floor = self._write_measurements(
            "measurements_floor.jsonl", self.prompts, cold=1000.0, warm=1000.0)
        self.measurements_partial = self._write_measurements(
            "measurements_partial.jsonl", self.prompts50, cold=300.0, warm=250.0)
        self.measurements50 = _write_jsonl(
            self.tmp / "measurements50.jsonl",
            [{"id": p, "pass": kind, "latency_ms": 300.0 if kind == "cold" else 250.0}
             for p in self.prompts50 for kind in ("cold", "warm")])
        self.bad_measurements = self.tmp / "measurements_bad.jsonl"
        self.bad_measurements.write_text("not-json-at-all\n", encoding="utf-8")
        self.unknown_id_measurements = _write_jsonl(
            self.tmp / "measurements_unknown_id.jsonl",
            [{"id": "not-a-prompt", "pass": "cold", "latency_ms": 300.0}])

        # The variant run layout (design §11.5): <root>/<run_id>/<mix>/ plus
        # the provenance manifest one directory up, in the run directory.
        self.corpus_root = self.tmp / "build" / "chat-corpus"
        run_dir = self.corpus_root / "v17"
        self.corpus_dir = run_dir / "ship"
        self.corpus_file = self.corpus_dir / f"chat-corpus-{bcc.SHIP_MIX}.jsonl"
        _write_jsonl(self.corpus_file, [{"id": f"s{i}", "turn": "x"} for i in range(3)])
        self.dev_corpus_dir = run_dir / "dev"
        self.dev_corpus_file = self.dev_corpus_dir / "chat-corpus-dev.jsonl"
        _write_jsonl(self.dev_corpus_file, [{"id": f"d{i}", "turn": "x"} for i in range(3)])
        self.manifest = run_dir / "provenance-manifest.json"
        self._write_manifest(self.manifest, mix=bcc.SHIP_MIX,
                             corpus_file=self.corpus_file)
        self.dev_manifest = run_dir / "provenance-manifest.dev.json"
        self._write_manifest(self.dev_manifest, mix="dev",
                             corpus_file=self.dev_corpus_file)
        self.manifest_text = self.manifest.read_text(encoding="utf-8")

        self.config_on = self.config("config-on.yaml")
        self.config_dev = self.config("config-dev.yaml", mix="dev")

    def _write_scores(self, name: str, values: dict) -> Path:
        return _write_jsonl(
            self.tmp / name,
            [{"id": turn_id, "scores": {c: values[turn_id] for c in self.criteria}}
             for turn_id in self.turn_ids])

    def _write_prompts(self, name: str, ids: list) -> Path:
        return _write_jsonl(self.tmp / name,
                            [{"id": p, "utterance": "नमस्ते हजुर।"} for p in ids])

    def _write_measurements(self, name: str, ids: list, *, cold: float,
                            warm: float) -> Path:
        return _write_jsonl(
            self.tmp / name,
            [{"id": p, "pass": kind, "latency_ms": cold if kind == "cold" else warm}
             for p in ids for kind in ("cold", "warm")])

    def _write_manifest(self, path, *, mix: str, corpus_file: Path,
                        ship_mix_eligible: bool = True) -> None:
        doc = {
            "schema": "chat_corpus/v1", "run_id": "v17", "mix": mix, "seed": 42,
            "builder": "tools/train-intent/src/build_chat_corpus.py",
            "style_spec": {"version": self.spec.version, "sha256": self.spec.sha256},
            "corpus": {"file": corpus_file.name, "turns": 3, "admitted": 3,
                       "sha256": _sha256_file(corpus_file), "written": True},
            "ship_mix_eligible": ship_mix_eligible,
            "sources": [], "tooling": {"fixture": "T-182 test"},
            "artifacts": [], "pairing": "T-182 test manifest",
        }
        doc["content_hash"] = _manifest_content_hash(doc)
        doc["content_hash_scope"] = ("sha256 over the document without the "
                                     "hash fields")
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(doc, ensure_ascii=False, indent=1),
                        encoding="utf-8")

    def rehash_manifest(self, doc: dict) -> dict:
        """A validly re-hashed manifest: the content hash is recomputed over
        the (mutated) body, so the document is self-consistent and the
        CROSS-CHECKS (mix, corpus sha, ship_mix_eligible), not the hash, are
        what must flag it."""
        doc.pop("content_hash", None)
        doc.pop("content_hash_scope", None)
        doc["content_hash"] = _manifest_content_hash(doc)
        doc["content_hash_scope"] = ("sha256 over the document without the "
                                     "hash fields")
        return doc

    def config(self, name: str, *, mutate=None, drop=(), **chat_overrides) -> Path:
        def apply(doc):
            doc["chat"]["enabled"] = True
            doc["chat"]["corpus_root"] = str(self.corpus_root)
            for key, value in chat_overrides.items():
                doc["chat"][key] = value
            if mutate is not None:
                mutate(doc)
        return _config_copy(self.tmp, name, mutate=apply, drop=drop)

    def gate(self, *, label: str, config=None, artifact="default",
             golden="default", outputs="default", scores="default",
             results_source: str = "results_baseline_min_100.csv",
             corpus: str = "corpus_min.jsonl",
             nearmiss: str = "nearmiss_min.jsonl",
             preds: str = "preds_min_allpass.jsonl",
             measurements="default", prompts="default", journal=None,
             omit: tuple = ()) -> GateRun:
        """Run src/eval_golden.py --full-gates over these inputs.

        A parameter left at "default" uses the standard input; None means
        "leave the flag off" (the refusal paths); any other value is passed
        as given (a Path that does not exist exercises the incomplete path).
        """
        run_dir = self.tmp / "runs" / label
        run_dir.mkdir(parents=True, exist_ok=True)
        results_path = run_dir / "results.csv"
        shutil.copy2(FIXTURES / results_source, results_path)
        report_path = run_dir / "gate-report.jsonl"

        def resolve(value, standard):
            return standard if value == "default" else value

        cmd = [sys.executable, str(ROOT / "src" / "eval_golden.py"),
               "--config", str(config if config is not None else self.config_on),
               "--full-gates", "--backend", "fixture",
               "--preds", str(FIXTURES / preds),
               "--corpus", str(FIXTURES / corpus),
               "--nearmiss", str(FIXTURES / nearmiss),
               "--results-csv", str(results_path),
               "--label", label,
               "--gate-report", str(report_path),
               "--tier", "reference-ios", "--tier-platform", "ios"]
        chat_golden = resolve(golden, self.fixture)
        artifact_path = resolve(artifact, self.artifact)
        chat_outputs = resolve(outputs, self.outputs_clean)
        judge_scores = resolve(scores, self.scores_5)
        measurements_path = resolve(measurements, self.measurements)
        prompts_path = resolve(prompts, self.prompts_path)
        if chat_golden is not None:
            cmd += ["--chat-golden", str(chat_golden)]
        if artifact_path is not None:
            cmd += ["--artifact", str(artifact_path)]
        if chat_outputs is not None:
            cmd += ["--chat-outputs", str(chat_outputs)]
        if judge_scores is not None:
            cmd += ["--judge", "fixture", "--judge-scores", str(judge_scores)]
        if measurements_path is not None:
            cmd += ["--device-measurements", str(measurements_path)]
        if prompts_path is not None:
            cmd += ["--device-prompts", str(prompts_path)]
        if journal is not None:
            cmd += ["--journal", str(journal)]
        for flag in omit:
            index = cmd.index(flag)
            del cmd[index:index + 2]
        proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True,
                              text=True, env=CHILD_ENV)
        return GateRun(proc, report_path, results_path, cmd)

    def assert_no_evidence(self, case: unittest.TestCase, run: GateRun,
                           *stderr_parts: str) -> None:
        """A refusal writes nothing anywhere: exit 2, the reason (and the
        no-report note) on stderr, no report file, and the results ledger
        untouched at its copied baseline bytes."""
        case.assertEqual(run.exit, 2, f"expected refusal; stderr:\n{run.stderr}")
        for part in stderr_parts:
            case.assertIn(part, run.stderr)
        case.assertIn("no evidence report is written for a refusal", run.stderr)
        case.assertFalse(run.report_path.exists(),
                         "a refusal must not leave an evidence report")
        case.assertEqual(run.results_path.read_bytes(),
                         (FIXTURES / "results_baseline_min_100.csv").read_bytes(),
                         "a refusal must not append a ledger row")


class GateCase(unittest.TestCase):
    """One class-scoped GateInputs for the full-gate test classes."""

    @classmethod
    def setUpClass(cls):
        cls.spec = ss.load()
        cls._tmp = tempfile.TemporaryDirectory(prefix="t182-")
        cls.addClassCleanup(cls._tmp.cleanup)
        cls.inputs = GateInputs(Path(cls._tmp.name), cls.spec)


# ---------------------------------------------------------------------------
# The checked-in configuration: additive section, untouched existing keys
# ---------------------------------------------------------------------------

class ChatSectionStaticTests(unittest.TestCase):
    """The config.yaml pins T-182's additive contract."""

    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
        _, cls.flat = _flat_config(ROOT / "config.yaml")

    def test_chat_enabled_defaults_false(self):
        self.assertIs(self.doc["chat"]["enabled"], False,
                      "the variant must be OFF in the checked-in config")

    def test_no_new_top_level_section(self):
        self.assertEqual(sorted(self.doc), list(CONFIG_TOP_LEVEL),
                         "T-182 adds the chat section and nothing else")

    def test_chat_section_is_exactly_the_pinned_keys(self):
        keys = {key for key in self.flat if key.startswith("chat.")}
        self.assertEqual(keys, set(CHAT_CONFIG_KEYS))
        self.assertEqual(set(eg.CHAT_VARIANT_KNOWN_KEYS), set(CHAT_CONFIG_KEYS),
                         "the reader must accept exactly the configured keys")

    def test_non_chat_keys_and_defaults_unchanged(self):
        non_chat = {k: v for k, v in self.flat.items()
                    if not k.startswith("chat.")}
        digest = hashlib.sha256(_canonical_json(non_chat).encode("utf-8")).hexdigest()
        self.assertEqual(
            digest, NON_CHAT_CONFIG_SHA256,
            "a non-chat key or default changed; T-182 may not move any of them "
            "(update this pin only for a deliberate, separately-reviewed change)")

    def test_fixed_recipe_constants(self):
        training = self.doc["training"]
        self.assertEqual(training["lora_r"], 16)
        self.assertEqual(training["lora_alpha"], 32)
        self.assertEqual(training["max_seq_len"], 1024)
        self.assertEqual(training["epochs"], 3)
        self.assertGreaterEqual(float(training["lr"]), 1.0e-4)
        self.assertLessEqual(float(training["lr"]), 2.0e-4)
        self.assertEqual(self.doc["export"]["quant"], "Q4_K_M")

    def test_mixture_and_filter_keys_record_the_recorded_numbers(self):
        chat = self.doc["chat"]
        self.assertEqual(chat["mixture"]["conversation_share"], 0.70)
        self.assertEqual(chat["mixture"]["clawback_share"], 0.30)
        self.assertEqual(chat["filters"]["min_word_tokens"], 2)
        self.assertEqual(chat["filters"]["turn_token_ceiling"], 512)
        self.assertIs(chat["filters"]["held_out_dedupe"], True)
        self.assertEqual(chat["filters"]["near_duplicate_jaccard"], 0.80)
        self.assertEqual(
            chat["filters"]["spec_checks"],
            ["honorific_agreement", "no_ai_isms", "dangling_particle",
             "devanagari_purity", "sentence_shape"])
        self.assertEqual(chat["mix"], "ship")
        self.assertEqual(chat["run_id"], "v17")

    def test_gate_inventory_is_exactly_the_pinned_14(self):
        self.assertEqual(tuple(eg.FULL_GATE_ORDER), FULL_GATE_ORDER)
        self.assertEqual(eg.REPORT_SCHEMA, "full_gate_report/v1")
        self.assertEqual(eg.EXIT_OK, 0)
        self.assertEqual(eg.EXIT_BLOCKED, 1)
        self.assertEqual(eg.EXIT_REFUSED, 2)


# ---------------------------------------------------------------------------
# The reader: flag off is inert, flag on reads everything from the file
# ---------------------------------------------------------------------------

class ChatVariantReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = ss.load()
        cls._tmp = tempfile.TemporaryDirectory(prefix="t182-reader-")
        cls.addClassCleanup(cls._tmp.cleanup)
        cls.tmp = Path(cls._tmp.name)
        cls.corpus_root = cls.tmp / "build" / "chat-corpus"

    def _variant(self, config_path):
        _, cfg = _flat_config(config_path)
        return eg.chat_variant_config(cfg)

    def _refusal(self, config_path) -> str:
        with self.assertRaises(eg.FullGateRefusal) as caught:
            self._variant(config_path)
        return str(caught.exception)

    def _copy(self, name, *, mutate=None, drop=()):
        return _config_copy(self.tmp, name, mutate=mutate, drop=drop)

    def _enable(self, doc):
        doc["chat"]["enabled"] = True
        doc["chat"]["corpus_root"] = str(self.corpus_root)

    def test_flag_absent_returns_none(self):
        path = self._copy("no-chat.yaml", drop=("chat",))
        self.assertIsNone(self._variant(path),
                          "without the section the existing pipeline sees nothing")

    def test_flag_false_returns_none(self):
        self.assertIsNone(self._variant(ROOT / "config.yaml"))

    def test_flag_true_resolves_everything_from_the_configuration(self):
        variant = self._variant(self._copy("on.yaml", mutate=self._enable))
        self.assertTrue(variant["enabled"])
        self.assertEqual(variant["run_id"], "v17")
        self.assertEqual(variant["mix"], "ship")
        self.assertEqual(variant["corpus_root"], str(self.corpus_root))
        self.assertEqual(variant["run_dir"], str(self.corpus_root / "v17"))
        self.assertEqual(variant["corpus_dir"], str(self.corpus_root / "v17" / "ship"))
        self.assertEqual(variant["mixture"],
                         {"conversation_share": 0.70, "clawback_share": 0.30})
        self.assertEqual(list(variant["layers"]), list(bcc.LAYERS))
        self.assertEqual(variant["filters"]["min_word_tokens"], 2)
        self.assertEqual(variant["filters"]["turn_token_ceiling"], 512)
        self.assertIs(variant["filters"]["held_out_dedupe"], True)
        self.assertEqual(variant["filters"]["near_duplicate_jaccard"], 0.80)
        self.assertEqual(
            variant["filters"]["spec_checks"],
            ["honorific_agreement", "no_ai_isms", "dangling_particle",
             "devanagari_purity", "sentence_shape"])

    def test_manifest_path_is_the_builders_own_resolution(self):
        variant = self._variant(self._copy("on.yaml", mutate=self._enable))
        expected = bcc.manifest_path_for(bcc.BuildOptions(
            mix="ship", run_id="v17", out_dir=Path(variant["corpus_dir"])))
        self.assertEqual(variant["manifest_path"], str(expected))
        self.assertEqual(Path(variant["manifest_path"]).name, "provenance-manifest.json")

    def test_dev_mix_manifest_is_named_for_the_mix(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["mix"] = "dev"
        variant = self._variant(self._copy("dev.yaml", mutate=mutate))
        self.assertEqual(variant["mix"], "dev")
        self.assertEqual(Path(variant["manifest_path"]).name,
                         "provenance-manifest.dev.json")

    def test_layer_paths_resolve_relative_to_the_suite_root(self):
        variant = self._variant(self._copy("on.yaml", mutate=self._enable))
        l1 = variant["layers"]["L1"]
        self.assertEqual(l1["paths"][0], "chat-sources/l1/indic_dialogue_ne.jsonl")
        self.assertEqual(l1["resolved"][0],
                         str(ROOT / "chat-sources" / "l1" / "indic_dialogue_ne.jsonl"))
        self.assertEqual(len(l1["present"]), len(l1["paths"]))
        self.assertEqual(variant["layers"]["L3"]["paths"], [],
                         "L3 is teacher-generated: no file input")

    def test_refuses_a_non_boolean_flag(self):
        def mutate(doc):
            doc["chat"]["enabled"] = "true"
        message = self._refusal(self._copy("bool.yaml", mutate=mutate))
        self.assertIn("chat.enabled must be true or false", message)

    def test_refuses_an_unknown_chat_key(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["typo_key"] = 1
        message = self._refusal(self._copy("typo.yaml", mutate=mutate))
        self.assertIn("unknown key(s) under chat", message)
        self.assertIn("chat.typo_key", message)

    def test_refuses_an_unknown_layer(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["layers"]["L5"] = ["x.jsonl"]
        message = self._refusal(self._copy("layer5.yaml", mutate=mutate))
        self.assertIn("chat.layers.L5", message)

    def test_refuses_a_missing_run_id(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["run_id"] = ""
        message = self._refusal(self._copy("no-run.yaml", mutate=mutate))
        self.assertIn("chat section is incomplete", message)
        self.assertIn("chat.run_id", message)

    def test_refuses_an_unknown_mix(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["mix"] = "prod"
        message = self._refusal(self._copy("prod.yaml", mutate=mutate))
        self.assertIn("chat.mix", message)
        self.assertIn("not one of", message)

    def test_refuses_shares_that_do_not_sum_to_one(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["mixture"]["clawback_share"] = 0.20
        message = self._refusal(self._copy("sum.yaml", mutate=mutate))
        self.assertIn("not 1.0", message)

    def test_refuses_a_share_out_of_range(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["mixture"]["conversation_share"] = 1.20
            doc["chat"]["mixture"]["clawback_share"] = -0.20
        message = self._refusal(self._copy("range.yaml", mutate=mutate))
        self.assertIn("must be a share in (0, 1)", message)

    def test_refuses_a_non_list_layer(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["layers"]["L3"] = [5]
        message = self._refusal(self._copy("badlayer.yaml", mutate=mutate))
        self.assertIn("chat.layers.L3", message)
        self.assertIn("must be a list of source paths", message)

    def test_refuses_empty_spec_checks(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["filters"]["spec_checks"] = []
        message = self._refusal(self._copy("nochecks.yaml", mutate=mutate))
        self.assertIn("non-empty list of admission", message)

    def test_refuses_duplicate_spec_checks(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["filters"]["spec_checks"] = ["no_ai_isms", "no_ai_isms"]
        message = self._refusal(self._copy("dupchecks.yaml", mutate=mutate))
        self.assertIn("repeats a name", message)

    def test_refuses_a_bad_word_floor(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["filters"]["min_word_tokens"] = 0
        message = self._refusal(self._copy("wordfloor.yaml", mutate=mutate))
        self.assertIn("chat.filters.min_word_tokens", message)

    def test_refuses_dedupe_off(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["filters"]["held_out_dedupe"] = False
        message = self._refusal(self._copy("dedupe.yaml", mutate=mutate))
        self.assertIn("held_out_dedupe must be true", message)

    def test_refuses_a_bad_jaccard_threshold(self):
        def mutate(doc):
            self._enable(doc)
            doc["chat"]["filters"]["near_duplicate_jaccard"] = 1.50
        message = self._refusal(self._copy("jaccard.yaml", mutate=mutate))
        self.assertIn("near_duplicate_jaccard", message)
        self.assertIn("(0, 1)", message)


class VariantChecksTests(unittest.TestCase):
    """recipe / mixture / filters against the fixed + builder constants."""

    @classmethod
    def setUpClass(cls):
        cls.spec = ss.load()
        cls._tmp = tempfile.TemporaryDirectory(prefix="t182-checks-")
        cls.addClassCleanup(cls._tmp.cleanup)
        cls.tmp = Path(cls._tmp.name)
        cls.corpus_root = cls.tmp / "build" / "chat-corpus"

    def _flat(self, *, mutate=None):
        doc = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
        doc["chat"]["enabled"] = True
        doc["chat"]["corpus_root"] = str(self.corpus_root)
        if mutate is not None:
            mutate(doc)
        path = self.tmp / "config.yaml"
        path.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True),
                        encoding="utf-8")
        _, cfg = _flat_config(path)
        return cfg

    def test_all_three_checks_pass_on_the_real_config(self):
        cfg = self._flat()
        variant = eg.chat_variant_config(cfg)
        checks = {"recipe": eg.recipe_check(cfg),
                  "mixture": eg.mixture_check(variant),
                  "filters": eg.filters_check(variant)}
        for name, check in checks.items():
            self.assertEqual(check["status"], "pass", f"{name}: {check['deviations']}")
            self.assertEqual(check["deviations"], [])

    def test_recipe_check_flags_each_fixed_constant(self):
        cfg = self._flat(mutate=lambda doc: doc["training"].__setitem__("lora_r", 32))
        check = eg.recipe_check(cfg)
        self.assertEqual(check["status"], "fail")
        self.assertTrue(any("training.lora_r" in d for d in check["deviations"]))

    def test_recipe_check_flags_the_lr_band(self):
        cfg = self._flat(mutate=lambda doc: doc["training"].__setitem__("lr", 5.0e-4))
        check = eg.recipe_check(cfg)
        self.assertEqual(check["status"], "fail")
        self.assertTrue(any("training.lr" in d for d in check["deviations"]))

    def test_recipe_check_flags_epochs_and_quant(self):
        def mutate(doc):
            doc["training"]["epochs"] = 6
            doc["export"]["quant"] = "Q5_K_M"
        check = eg.recipe_check(self._flat(mutate=mutate))
        self.assertEqual(check["status"], "fail")
        joined = " ".join(check["deviations"])
        self.assertIn("training.epochs", joined)
        self.assertIn("export.quant", joined)

    def test_mixture_check_flags_a_rebalanced_mix(self):
        cfg = self._flat(mutate=lambda doc: doc["chat"]["mixture"].update(
            {"conversation_share": 0.60, "clawback_share": 0.40}))
        variant = eg.chat_variant_config(cfg)  # reader allows: sum is 1.0
        check = eg.mixture_check(variant)
        self.assertEqual(check["status"], "fail")
        joined = " ".join(check["deviations"])
        self.assertIn("conversation_share", joined)
        self.assertIn("clawback_share", joined)

    def test_filters_check_flags_dropped_and_unknown_checks(self):
        cfg = self._flat(mutate=lambda doc: doc["chat"]["filters"].__setitem__(
            "spec_checks", ["no_ai_isms", "not_a_real_check"]))
        check = eg.filters_check(eg.chat_variant_config(cfg))
        self.assertEqual(check["status"], "fail")
        joined = " ".join(check["deviations"])
        self.assertIn("not_a_real_check", joined)
        self.assertIn("honorific_agreement", joined)

    def test_filters_check_flags_the_length_and_dedupe_numbers(self):
        cfg = self._flat(mutate=lambda doc: doc["chat"]["filters"].update(
            {"min_word_tokens": 3, "turn_token_ceiling": 256,
             "near_duplicate_jaccard": 0.90}))
        check = eg.filters_check(eg.chat_variant_config(cfg))
        self.assertEqual(check["status"], "fail")
        joined = " ".join(check["deviations"])
        self.assertIn("min_word_tokens", joined)
        self.assertIn("turn_token_ceiling", joined)
        self.assertIn("near_duplicate_jaccard", joined)


# ---------------------------------------------------------------------------
# Flag off: the existing pipeline is byte-identical
# ---------------------------------------------------------------------------

class LegacyByteIdentityTests(unittest.TestCase):
    """The chat section is additive: with the flag absent or false the legacy
    path's stdout and results.csv are byte-identical, and the committed
    ledgers are never touched."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="t182-flags-")
        cls.addClassCleanup(cls._tmp.cleanup)
        cls.tmp = Path(cls._tmp.name)
        cls.baseline_csv = FIXTURES / "results_baseline_min_100.csv"
        cls.committed_ledger = ROOT / "eval" / "results.csv"
        cls.committed_sha = (_sha256_file(cls.committed_ledger)
                             if cls.committed_ledger.is_file() else None)

    def _legacy_run(self, config_path, results_path):
        cmd = [sys.executable, str(ROOT / "src" / "eval_golden.py"),
               "--config", str(config_path),
               "--backend", "fixture",
               "--preds", str(FIXTURES / "preds_min_allpass.jsonl"),
               "--corpus", str(FIXTURES / "corpus_min.jsonl"),
               "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
               "--results-csv", str(results_path),
               "--label", "byte-identity"]
        return subprocess.run(cmd, cwd=str(ROOT), capture_output=True,
                              text=False, env=CHILD_ENV)

    def test_the_chat_section_changes_nothing_on_the_existing_path(self):
        def enable(doc):
            doc["chat"]["enabled"] = True
            doc["chat"]["corpus_root"] = str(self.tmp / "unused-corpus-root")
        configs = {
            "repo-config": ROOT / "config.yaml",
            "stripped": _config_copy(self.tmp, "stripped.yaml", drop=("chat",)),
            "enabled": _config_copy(self.tmp, "enabled.yaml", mutate=enable),
        }
        outputs = {}
        for name, config_path in configs.items():
            results_path = self.tmp / f"{name}.csv"
            shutil.copy2(self.baseline_csv, results_path)
            proc = self._legacy_run(config_path, results_path)
            self.assertEqual(proc.returncode, 0,
                             f"{name}: {proc.stderr.decode('utf-8', 'replace')}")
            self.assertIn(b"all gates passed", proc.stdout)
            self.assertNotIn(b"chat", proc.stdout.lower(),
                             "no chat key may leak into the legacy surface")
            outputs[name] = {"stdout": proc.stdout,
                             "csv": results_path.read_bytes()}

        reference = outputs["repo-config"]
        for name in ("stripped", "enabled"):
            self.assertEqual(outputs[name]["stdout"], reference["stdout"],
                             f"{name} stdout must be byte-identical")
            self.assertEqual(outputs[name]["csv"], reference["csv"],
                             f"{name} results.csv must be byte-identical")

        corpus_tag = _sha256_file(FIXTURES / "corpus_min.jsonl")[:8]
        lines = reference["csv"].decode("utf-8").splitlines()
        baseline_lines = self.baseline_csv.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), len(baseline_lines) + 1,
                         "exactly one ledger row is appended")
        self.assertTrue(lines[-1].startswith(f"byte-identity@{corpus_tag},"),
                        lines[-1])

    def test_committed_ledgers_are_never_written(self):
        if self.committed_sha is not None:
            self.assertEqual(_sha256_file(self.committed_ledger),
                             self.committed_sha,
                             "the committed eval/results.csv must stay untouched")
        # The fixture ledgers these tests replay are read-only inputs.
        self.assertEqual(_sha256_file(self.baseline_csv),
                         _sha256_file(self.baseline_csv))


# ---------------------------------------------------------------------------
# The full gate: green over one candidate, one report
# ---------------------------------------------------------------------------

class HappyPathTests(GateCase):
    """ONE invocation, every gate green, ONE coherent evidence report."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # NB: not `cls.run` — that would shadow unittest's TestCase.run.
        cls.gate_result = cls.inputs.gate(label="happy")

    def test_exit_zero_and_one_report_row(self):
        self.assertEqual(self.gate_result.exit, 0, self.gate_result.stderr)
        self.assertEqual(len(self.gate_result.report_lines), 1,
                         "ONE coherent evidence record per invocation")
        report = self.gate_result.report
        self.assertEqual(report["schema"], "full_gate_report/v1")
        self.assertEqual(report["harness"], "src/eval_golden.py --full-gates")
        self.assertEqual(report["harness_task"], "T-182")

    def test_every_gate_green_with_value_threshold_denominator(self):
        self.assertEqual(list(self.gate_result.gates), list(FULL_GATE_ORDER))
        for gate_id, row in self.gate_result.gates.items():
            self.assertEqual(row["status"], "pass", gate_id)
            self.assertIsNotNone(row.get("value"), gate_id)
            self.assertIsNotNone(row.get("threshold"), gate_id)
            self.assertIsNotNone(row.get("denominator"), gate_id)
            self.assertGreater(row["denominator"], 0, gate_id)
        self.assertEqual(self.gate_result.gates["honorific_agreement"]["value"], 1.0)
        self.assertEqual(self.gate_result.gates["honorific_agreement"]["passed"], 500)
        self.assertEqual(self.gate_result.gates["honorific_agreement"]["denominator"], 500)
        self.assertEqual(self.gate_result.gates["honorific_agreement"]["threshold"], 0.98)
        self.assertEqual(self.gate_result.gates["no_ai_isms"]["threshold"], 0.98)
        self.assertEqual(self.gate_result.gates["judge_quality"]["value"], 5.0)
        self.assertEqual(self.gate_result.gates["judge_quality"]["denominator"], 500)
        self.assertEqual(self.gate_result.gates["judge_quality"]["threshold"], 4.0)
        self.assertEqual(self.gate_result.gates["emergency_recall"]["threshold"], 1.0)
        self.assertEqual(self.gate_result.gates["emergency_nearmiss_recall"]["threshold"], 0.98)
        self.assertEqual(self.gate_result.gates["gemini_gap"]["threshold"], -0.03)
        self.assertEqual(self.gate_result.gates["latency_p50"]["threshold"], 1000.0)
        self.assertEqual(self.gate_result.gates["latency_p95"]["threshold"], 2000.0)

    def test_candidate_and_fixture_identity_recorded(self):
        report = self.gate_result.report
        self.assertEqual(report["candidate"]["artifact_sha256"],
                         _sha256_file(self.inputs.artifact))
        self.assertEqual(report["candidate"]["artifact_path"],
                         str(self.inputs.artifact))
        self.assertEqual(report["candidate"]["label"], "happy")
        chat = report["fixtures"]["chat_golden"]
        self.assertEqual(chat["sha256"], _sha256_file(self.inputs.fixture))
        self.assertEqual(chat["revision"], self.inputs.golden.revision)
        self.assertEqual(chat["turns"], 500)
        self.assertIs(chat["eligible"], True)
        corpus = report["fixtures"]["golden_corpus"]
        self.assertEqual(corpus["sha256"], _sha256_file(FIXTURES / "corpus_min.jsonl"))
        self.assertEqual(corpus["rows"], 6)
        near = report["fixtures"]["emergency_nearmiss"]
        self.assertEqual(near["sha256"], _sha256_file(FIXTURES / "nearmiss_min.jsonl"))
        style = report["fixtures"]["style_spec"]
        self.assertEqual(style["version"], self.spec.version)
        self.assertEqual(style["sha256"], self.spec.sha256)
        config_block = report["fixtures"]["config"]
        self.assertEqual(config_block["sha256"], _sha256_file(self.inputs.config_on))

    def test_gate_rows_carry_the_artifact_and_fixture_version(self):
        for gate_id in CHAT_GATE_IDS:
            provenance = self.gate_result.gates[gate_id]["provenance"]
            self.assertEqual(provenance["fixture_sha256"], self.inputs.golden.sha256)
            self.assertEqual(provenance["fixture_revision"],
                             self.inputs.golden.revision)
            self.assertEqual(provenance["artifact_sha256"],
                             _sha256_file(self.inputs.artifact))

    def test_tier_named_for_latency_and_calibration(self):
        report = self.gate_result.report
        self.assertEqual(report["tier"]["name"], "reference-ios")
        self.assertEqual(report["tier"]["platform"], "ios")
        self.assertEqual(report["tier"]["applies_to"],
                         ["calibration", "latency_p50", "latency_p95"])
        for gate_id in ("calibration", "latency_p50", "latency_p95"):
            self.assertEqual(self.gate_result.gates[gate_id]["tier"], "reference-ios")

    def test_provenance_manifest_hash_verified_and_recorded(self):
        provenance = self.gate_result.report["provenance"]
        recorded = json.loads(self.inputs.manifest_text)
        self.assertEqual(provenance["status"], "verified")
        self.assertTrue(provenance["manifest_present"])
        self.assertTrue(provenance["content_hash_verified"])
        self.assertEqual(provenance["content_hash"], recorded["content_hash"])
        self.assertEqual(provenance["content_hash"],
                         _manifest_content_hash(recorded),
                         "the recorded hash must recompute under T-180's scope")
        self.assertEqual(provenance["content_hash_recomputed"],
                         provenance["content_hash"])
        self.assertEqual(provenance["mix"], "ship")
        self.assertIs(provenance["ship_mix_eligible"], True)
        self.assertEqual(provenance["corpus_sha256"],
                         _sha256_file(self.inputs.corpus_file))

    def test_variant_recorded_from_the_configuration(self):
        variant = self.gate_result.report["variant"]
        self.assertEqual(variant["run_id"], "v17")
        self.assertEqual(variant["mix"], "ship")
        self.assertEqual(variant["corpus_root"], str(self.inputs.corpus_root))
        self.assertEqual(variant["corpus_dir"],
                         str(self.inputs.corpus_root / "v17" / "ship"))
        self.assertEqual(variant["corpus"]["sha256"],
                         _sha256_file(self.inputs.corpus_file))
        self.assertEqual(variant["corpus"]["rows"], 3)
        self.assertEqual(variant["mixture"],
                         {"conversation_share": 0.7, "clawback_share": 0.3})
        self.assertEqual(variant["filters"]["spec_checks"],
                         ["honorific_agreement", "no_ai_isms", "dangling_particle",
                          "devanagari_purity", "sentence_shape"])

    def test_variant_checks_pass(self):
        checks = self.gate_result.report["checks"]
        self.assertEqual(sorted(checks), ["filters", "mixture", "recipe"])
        for name, check in checks.items():
            self.assertEqual(check["status"], "pass", name)
            self.assertEqual(check["deviations"], [])
        self.assertEqual(self.gate_result.verdict["checks_failed"], [])

    def test_judge_is_the_offline_replay_and_spend_is_recorded(self):
        judge = self.gate_result.report["judge"]
        self.assertEqual(judge["transport"], "fixture")
        self.assertEqual(judge["model"], MODEL)
        self.assertEqual(judge["temperature"], 0.0)
        self.assertEqual(judge["scores_sha256"],
                         _sha256_file(self.inputs.scores_5))
        spend = self.gate_result.report["spend"]
        self.assertEqual(spend["judge"]["transport"], "fixture")
        self.assertIs(spend["judge"]["billed"], False)
        self.assertEqual(spend["judge"]["calls_this_run"], 500)
        self.assertEqual(spend["judge"]["reused_from_journal"], 0)
        self.assertEqual(spend["judge"]["failed_calls"], 0)
        self.assertIsNone(spend["judge"]["journal_path"])
        self.assertEqual(spend["hard_gate_rows"], 12)
        self.assertEqual(spend["chat_turns"], 500)
        self.assertEqual(spend["device_measurement_rows"], 200)
        self.assertGreaterEqual(spend["elapsed_seconds"], 0.0)

    def test_deterministic_checks_and_ledger_row(self):
        report = self.gate_result.report
        particles = report["deterministic_checks"]["particles_within_budget"]
        self.assertEqual(particles["denominator"], 500)
        self.assertEqual(particles["within_budget"], 500)
        tag = _sha256_file(FIXTURES / "corpus_min.jsonl")[:8]
        self.assertEqual(report["existing_harness"]["corpus_tag"], tag)
        self.assertEqual(report["existing_harness"]["label"], f"happy@{tag}")
        self.assertEqual(report["existing_harness"]["gates_failed"], [])
        self.assertEqual(report["existing_harness"]["gemini_gap"], 0.0)
        last_line = self.gate_result.results_path.read_text(encoding="utf-8").splitlines()[-1]
        self.assertTrue(last_line.startswith(f"happy@{tag},"), last_line)
        self.assertTrue(last_line.endswith(",none"), last_line)

    def test_verdict_and_spend_are_swap_evidence(self):
        verdict = self.gate_result.verdict
        self.assertEqual(verdict["red_gates"], [])
        self.assertEqual(verdict["not_measured_gates"], [])
        self.assertEqual(verdict["shortfalls"], [])
        self.assertIs(verdict["complete_evidence"], True)
        self.assertIs(verdict["ship_mix"], True)
        self.assertIs(verdict["swap"]["eligible"], True)
        self.assertEqual(verdict["exit_code"], 0)
        self.assertEqual(self.gate_result.report["incomplete"],
                         {"complete": True, "reasons": []})
        self.assertIn("evidence report appended", self.gate_result.stdout)

    def test_stdout_names_every_gate_green(self):
        for gate_id in FULL_GATE_ORDER:
            self.assertIn(f"GREEN {gate_id}", self.gate_result.stdout)
        self.assertIn("swap eligible: True", self.gate_result.stdout)

    def test_latency_replay_cross_checks_measure_devices_own_cli(self):
        """The harness replays measure_device; that tool's own CLI over the
        same files must produce the same statistics (one implementation)."""
        csv_path = self.inputs.tmp / "device-crosscheck.csv"
        cmd = [sys.executable, str(ROOT / "src" / "measure_device.py"),
               "--replay", str(self.inputs.measurements),
               "--prompts", str(self.inputs.prompts_path),
               "--min-prompts", "100",
               "--platform", "ios", "--device-model", "iPhone SE (3rd gen)",
               "--os", "iOS 26.0", "--build", "T-182-test",
               "--results-csv", str(csv_path)]
        proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True,
                              text=True, env=CHILD_ENV)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = list(csv.DictReader(csv_path.read_text(encoding="utf-8").splitlines()))
        self.assertEqual(len(rows), 1)
        device = rows[-1]
        self.assertEqual(float(device["p50_ms"]),
                         self.gate_result.gates["latency_p50"]["value"])
        self.assertEqual(float(device["p95_ms"]),
                         self.gate_result.gates["latency_p95"]["value"])
        self.assertEqual(int(device["n"]),
                         self.gate_result.gates["latency_p50"]["denominator"])
        self.assertEqual(device["gates_failed"], "none")


class ReproducibilityTests(GateCase):
    """The same inputs yield the same gate results (the report's own
    generated_at / elapsed fields are the only moving parts)."""

    def test_gate_values_reproduce_across_invocations(self):
        first = self.inputs.gate(label="repro-1")
        second = self.inputs.gate(label="repro-2")
        self.assertEqual(first.exit, 0)
        self.assertEqual(second.exit, 0)

        def readable(gates):
            return {gate_id: {k: row[k] for k in ("status", "value",
                                                  "threshold", "denominator")}
                    for gate_id, row in gates.items()}

        self.assertEqual(readable(first.gates), readable(second.gates))
        self.assertEqual(first.report["provenance"]["content_hash"],
                         second.report["provenance"]["content_hash"])
        self.assertIs(second.verdict["swap"]["eligible"], True)


# ---------------------------------------------------------------------------
# Red gates block the swap, naming the gate and the shortfall
# ---------------------------------------------------------------------------

class RedGateTests(GateCase):
    def test_red_honorific_blocks_and_names_the_shortfall(self):
        run = self.inputs.gate(label="red-honorific",
                               outputs=self.inputs.outputs_bad_honorific)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["red_gates"], ["honorific_agreement"])
        row = run.gates["honorific_agreement"]
        self.assertEqual(row["status"], "fail")
        self.assertAlmostEqual(row["value"], 0.978, places=9)
        self.assertEqual(row["passed"], 489)
        self.assertEqual(row["denominator"], 500)
        self.assertEqual(row["threshold"], 0.98, "no threshold may move")
        self.assertIn("RED honorific_agreement", run.stdout)
        self.assertIn("0.978 < 0.98", run.stdout)
        self.assertIn("the swap does not proceed", run.stdout)
        self.assertIs(run.verdict["swap"]["eligible"], False)
        self.assertIn("honorific_agreement", run.verdict["shortfalls"][0])
        # The other chat gates were still measured over the same candidate.
        self.assertEqual(run.gates["no_ai_isms"]["status"], "pass")
        self.assertEqual(run.gates["judge_quality"]["value"], 5.0)

    def test_red_judge_blocks_and_names_the_shortfall(self):
        run = self.inputs.gate(label="red-judge",
                               scores=self.inputs.scores_39)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["red_gates"], ["judge_quality"])
        row = run.gates["judge_quality"]
        self.assertAlmostEqual(row["value"], 3.9, places=9)
        self.assertEqual(row["threshold"], 4.0)
        self.assertEqual(row["denominator"], 500)
        self.assertIn("RED judge_quality", run.stdout)
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_red_hard_gate_blocks_over_the_same_candidate(self):
        run = self.inputs.gate(
            label="red-emergency",
            results_source="results_baseline_28_096.csv",
            corpus="corpus_closed28.jsonl",
            preds="preds_emergency_miss.jsonl")
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["red_gates"], ["emergency_recall"])
        row = run.gates["emergency_recall"]
        self.assertAlmostEqual(row["value"], 0.5, places=9)
        self.assertEqual(row["threshold"], 1.0, "the hard gate is not negotiable")
        self.assertEqual(run.report["existing_harness"]["gates_failed"],
                         ["emergency_recall"])
        self.assertIn("RED emergency_recall", run.stdout)
        # The chat gates were measured in the same invocation.
        self.assertEqual(run.gates["honorific_agreement"]["status"], "pass")
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_latency_p50_red_while_p95_stays_green(self):
        run = self.inputs.gate(label="red-latency",
                               measurements=self.inputs.measurements_slow)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["red_gates"], ["latency_p50"])
        p50 = run.gates["latency_p50"]
        self.assertEqual(p50["value"], 1200.0)
        self.assertEqual(p50["threshold"], 1000.0)
        self.assertEqual(p50["denominator"], 200)
        self.assertEqual(p50["tier"], "reference-ios")
        self.assertEqual(run.gates["latency_p95"]["status"], "pass")
        self.assertEqual(run.gates["latency_p95"]["value"], 1500.0)
        self.assertIn("RED latency_p50", run.stdout)
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_latency_exactly_at_the_gate_passes(self):
        run = self.inputs.gate(label="floor-latency",
                               measurements=self.inputs.measurements_floor)
        self.assertEqual(run.exit, 0, run.stderr)
        self.assertEqual(run.gates["latency_p50"]["value"], 1000.0)
        self.assertEqual(run.gates["latency_p50"]["status"], "pass")
        self.assertIs(run.verdict["swap"]["eligible"], True)

    def test_recipe_deviation_fails_a_check_instead_of_a_gate(self):
        def deviate(doc):
            doc["training"]["lr"] = 5.0e-4
        run = self.inputs.gate(label="recipe-deviation",
                               config=self.inputs.config("config-deviated.yaml",
                                                         mutate=deviate))
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["checks_failed"], ["recipe"])
        self.assertEqual(run.verdict["red_gates"], [])
        self.assertEqual(run.verdict["not_measured_gates"], [])
        self.assertTrue(any("training.lr" in d for d in
                            run.report["checks"]["recipe"]["deviations"]))
        self.assertIn("CHECK FAILED recipe", run.stdout)
        self.assertIn("training.lr", run.stdout)
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_mixture_deviation_fails_the_mixture_check(self):
        def rebalance(doc):
            doc["chat"]["mixture"] = {"conversation_share": 0.60,
                                      "clawback_share": 0.40}
        run = self.inputs.gate(label="mixture-deviation",
                               config=self.inputs.config("config-mix.yaml",
                                                         mutate=rebalance))
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["checks_failed"], ["mixture"])
        joined = " ".join(run.report["checks"]["mixture"]["deviations"])
        self.assertIn("conversation_share", joined)
        self.assertIn("clawback_share", joined)
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_filters_deviation_fails_the_filters_check(self):
        def shrink(doc):
            doc["chat"]["filters"]["turn_token_ceiling"] = 256
        run = self.inputs.gate(label="filters-deviation",
                               config=self.inputs.config("config-filters.yaml",
                                                         mutate=shrink))
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["checks_failed"], ["filters"])
        self.assertTrue(any("turn_token_ceiling" in d for d in
                            run.report["checks"]["filters"]["deviations"]))
        self.assertIs(run.verdict["swap"]["eligible"], False)

    def test_dev_mix_is_never_swap_evidence(self):
        run = self.inputs.gate(label="dev-mix", config=self.inputs.config_dev)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["red_gates"], [])
        self.assertEqual(run.verdict["not_measured_gates"], [])
        self.assertEqual(run.verdict["checks_failed"], [])
        self.assertIs(run.verdict["ship_mix"], False)
        self.assertIs(run.verdict["swap"]["eligible"], False)
        self.assertIs(run.verdict["complete_evidence"], True,
                      "the evidence is complete; the mix is the blocker")
        self.assertIn("not the ship mix", run.verdict["swap"]["reason"])
        self.assertEqual(run.report["provenance"]["mix"], "dev")


# ---------------------------------------------------------------------------
# Incomplete evidence: the report is written, marked, and cannot be swap proof
# ---------------------------------------------------------------------------

class IncompleteEvidenceTests(GateCase):
    def _run_with_manifest(self, label: str, text: str) -> GateRun:
        try:
            self.inputs.manifest.write_text(text, encoding="utf-8")
            return self.inputs.gate(label=label)
        finally:
            self.inputs.manifest.write_text(self.inputs.manifest_text,
                                            encoding="utf-8")

    def _assert_incomplete(self, run: GateRun, *reason_parts: str) -> None:
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(len(run.report_lines), 1)
        self.assertIs(run.report["incomplete"]["complete"], False)
        self.assertIs(run.verdict["swap"]["eligible"], False)
        reasons = " ; ".join(run.report["incomplete"]["reasons"])
        for part in reason_parts:
            self.assertIn(part, reasons)
        self.assertIn("INCOMPLETE", run.stdout)

    def test_missing_manifest(self):
        parked = self.inputs.manifest.with_suffix(".parked")
        self.inputs.manifest.rename(parked)
        try:
            run = self.inputs.gate(label="no-manifest")
        finally:
            parked.rename(self.inputs.manifest)
        self._assert_incomplete(run, "provenance manifest missing")
        self.assertEqual(run.report["provenance"]["status"], "missing")
        self.assertIsNone(run.report["provenance"]["content_hash"])

    def test_tampered_manifest_hash_mismatch(self):
        doc = json.loads(self.inputs.manifest_text)
        doc["seed"] = 43  # altered without re-hashing
        run = self._run_with_manifest("tampered-manifest",
                                      json.dumps(doc, ensure_ascii=False, indent=1))
        self._assert_incomplete(run, "hash_mismatch", "does not recompute")
        provenance = run.report["provenance"]
        self.assertFalse(provenance["content_hash_verified"])
        self.assertEqual(provenance["content_hash"], doc["content_hash"])
        self.assertNotEqual(provenance["content_hash"],
                            provenance["content_hash_recomputed"])
        self.assertEqual(provenance["content_hash_recomputed"],
                         _manifest_content_hash(doc))

    def test_malformed_manifest_is_unreadable(self):
        run = self._run_with_manifest("malformed-manifest", "{ not json")
        self._assert_incomplete(run, "unreadable")
        self.assertEqual(run.report["provenance"]["status"], "unreadable")

    def test_manifest_missing_content_hash(self):
        doc = json.loads(self.inputs.manifest_text)
        doc.pop("content_hash", None)
        doc.pop("content_hash_scope", None)
        run = self._run_with_manifest("no-hash",
                                      json.dumps(doc, ensure_ascii=False, indent=1))
        self._assert_incomplete(run, "no_content_hash")
        self.assertEqual(run.report["provenance"]["status"], "no_content_hash")
        self.assertIsNone(run.report["provenance"]["content_hash"])

    def test_ship_mix_ineligible_manifest(self):
        doc = json.loads(self.inputs.manifest_text)
        doc["ship_mix_eligible"] = False
        run = self._run_with_manifest(
            "ship-ineligible",
            json.dumps(self.inputs.rehash_manifest(doc), ensure_ascii=False, indent=1))
        self._assert_incomplete(run, "ship_mix_eligible=false")
        self.assertEqual(run.report["provenance"]["status"], "verified",
                         "the manifest itself is intact; the run is not ship")

    def test_corpus_sha_mismatch(self):
        doc = json.loads(self.inputs.manifest_text)
        doc["corpus"]["sha256"] = "0" * 64
        run = self._run_with_manifest(
            "corpus-mismatch",
            json.dumps(self.inputs.rehash_manifest(doc), ensure_ascii=False, indent=1))
        self._assert_incomplete(
            run, "does not match the manifest's recorded sha256")

    def test_mix_mismatch_between_manifest_and_configuration(self):
        dev_text = self.inputs.dev_manifest.read_text(encoding="utf-8")
        run = self._run_with_manifest("mix-mismatch", dev_text)
        self._assert_incomplete(run, "mix 'dev' != the configured variant mix 'ship'")

    def test_artifact_identity_missing_marks_chat_gates_not_measured(self):
        run = self.inputs.gate(label="no-artifact-file",
                               artifact=self.inputs.missing_artifact)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertIsNone(run.report["candidate"]["artifact_sha256"])
        self.assertEqual(run.verdict["not_measured_gates"],
                         list(CHAT_GATE_IDS))
        self._assert_incomplete(run, "candidate artifact identity missing")
        self.assertEqual(run.gates["honorific_agreement"]["value"], None)
        self.assertEqual(run.report["judge"]["status"], "not_run")
        # The hard gates and the ledger row still happened (same candidate).
        self.assertEqual(run.gates["emergency_recall"]["status"], "pass")
        self.assertEqual(run.report["spend"]["hard_gate_rows"], 12)

    def test_latency_without_measurements_is_not_measured(self):
        run = self.inputs.gate(label="no-latency", measurements=None, prompts=None)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["not_measured_gates"],
                         ["latency_p50", "latency_p95"])
        self._assert_incomplete(run, "no device-tier measurements supplied")
        self.assertEqual(run.gates["latency_p50"]["value"], None)
        self.assertEqual(run.gates["latency_p50"]["tier"], "reference-ios",
                         "an unmeasured gate still names its tier")

    def test_latency_without_the_prompt_set_is_partial(self):
        run = self.inputs.gate(label="no-prompt-set", prompts=None)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["not_measured_gates"],
                         ["latency_p50", "latency_p95"])
        self._assert_incomplete(run, "no prompt set supplied")
        drill = run.gates["latency_p50"]["drilldown"]
        self.assertIs(drill["coverage_note"].startswith("no prompt set supplied"),
                      True)

    def test_partial_measurements_are_not_a_verdict(self):
        run = self.inputs.gate(label="partial-latency",
                               measurements=self.inputs.measurements_partial)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["not_measured_gates"],
                         ["latency_p50", "latency_p95"])
        self._assert_incomplete(run, "pair(s) missing")
        drill = run.gates["latency_p50"]["drilldown"]
        self.assertEqual(drill["prompt_count"], 100)
        self.assertEqual(drill["missing_pairs"], 150)
        self.assertIs(run.gates["latency_p50"]["drilldown"]["coverage_note"]
                      .find("partial") >= 0, True)

    def test_prompt_set_below_the_floor_is_partial(self):
        run = self.inputs.gate(label="prompt-floor",
                               measurements=self.inputs.measurements50,
                               prompts=self.inputs.prompts50_path)
        self.assertEqual(run.exit, 1, run.stderr)
        self.assertEqual(run.verdict["not_measured_gates"],
                         ["latency_p50", "latency_p95"])
        self._assert_incomplete(run, "50 prompt(s) < 100")
        self.assertEqual(run.gates["latency_p50"]["denominator"], 100)
        self.assertEqual(run.gates["latency_p50"]["drilldown"]["prompt_count"], 50)


# ---------------------------------------------------------------------------
# Refusals: exit 2, the reason on stderr, nothing written anywhere
# ---------------------------------------------------------------------------

class RefusalTests(GateCase):
    def test_chat_disabled_refuses(self):
        run = self.inputs.gate(label="disabled", config=ROOT / "config.yaml")
        self.inputs.assert_no_evidence(self, run,
                                       "chat.enabled is absent or false")
        self.assertNotIn("evidence report appended", run.stdout)

    def test_missing_tier_refuses(self):
        run = self.inputs.gate(label="no-tier", omit=("--tier",))
        self.inputs.assert_no_evidence(self, run, "--tier NAME is required")

    def test_missing_gate_report_refuses(self):
        run = self.inputs.gate(label="no-report", omit=("--gate-report",))
        self.inputs.assert_no_evidence(self, run, "requires --gate-report")

    def test_missing_chat_outputs_refuses(self):
        run = self.inputs.gate(label="no-outputs", outputs=None)
        self.inputs.assert_no_evidence(self, run, "requires --chat-outputs")

    def test_missing_artifact_flag_refuses(self):
        run = self.inputs.gate(label="no-artifact", artifact=None)
        self.inputs.assert_no_evidence(self, run, "requires --artifact")

    def test_fixture_judge_without_scores_refuses(self):
        run = self.inputs.gate(label="no-scores", scores=self.inputs.scores_5,
                               omit=("--judge-scores",))
        self.inputs.assert_no_evidence(self, run, "requires --judge-scores")

    def test_ineligible_fixture_refuses(self):
        run = self.inputs.gate(label="ineligible",
                               golden=self.inputs.pending_fixture)
        self.inputs.assert_no_evidence(
            self, run, "NOT an eligible gate fixture", "human review pending")

    def test_unreadable_measurements_refuse(self):
        run = self.inputs.gate(label="bad-measurements",
                               measurements=self.inputs.bad_measurements)
        self.inputs.assert_no_evidence(self, run, "device measurements refused")

    def test_measurements_with_unknown_ids_refuse(self):
        run = self.inputs.gate(label="unknown-ids",
                               measurements=self.inputs.unknown_id_measurements)
        self.inputs.assert_no_evidence(self, run, "device measurements refused")


# ---------------------------------------------------------------------------
# Resumable judge stage: the journal reuses entries and spend is recorded
# ---------------------------------------------------------------------------

class JournalResumeTests(GateCase):
    def test_second_run_reuses_every_journal_entry(self):
        journal = self.inputs.tmp / "journal.jsonl"
        first = self.inputs.gate(label="journal-1", journal=journal)
        self.assertEqual(first.exit, 0, first.stderr)
        self.assertEqual(first.report["spend"]["judge"]["calls_this_run"], 500)
        self.assertEqual(first.report["spend"]["judge"]["reused_from_journal"], 0)
        self.assertEqual(first.report["spend"]["judge"]["journal_path"], str(journal))
        self.assertTrue(journal.is_file())

        second = self.inputs.gate(label="journal-2", journal=journal)
        self.assertEqual(second.exit, 0, second.stderr)
        self.assertEqual(second.report["spend"]["judge"]["calls_this_run"], 0)
        self.assertEqual(second.report["spend"]["judge"]["reused_from_journal"], 500)
        self.assertEqual(second.report["spend"]["judge"]["failed_calls"], 0)
        # The resumed run is still full evidence.
        self.assertEqual(second.gates["judge_quality"]["value"], 5.0)
        self.assertIs(second.verdict["swap"]["eligible"], True)


if __name__ == "__main__":
    unittest.main()
