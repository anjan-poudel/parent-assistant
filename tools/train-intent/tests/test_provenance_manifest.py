"""T-180 tests: the provenance manifest and the ship-mix enforcement.

The unit's contract (tasks/TG-37-v17-chat-aware-training-suite/T-180;
FR-CNR-018, NFR-CNR-011; design-l1 §11.5):

  * the manifest is emitted by the SAME builder that assembled the corpus, into
    the run directory (``provenance-manifest.json`` beside the corpus
    directory — the design's ``build/<run-id>/``), and lists EVERY source — the
    training registry AND the tooling inputs — with its licence, layer,
    ship/dev classification, counts used and the derived artifacts it fed; the
    held-out chat set and the eval fixtures are recorded EXCLUDED;
  * the ship mix may contain only CC-BY/Apache/MIT/synthetic/own data, and the
    assertion is CODE inside the build: a CC BY-NC layer (IndicDialogue,
    DailyDialog, PersonaChat, EmpatheticDialogues) or a research-gated
    transcript in the ship mix FAILS the build naming the source and its
    licence, and NO corpus is written (the artifact is rejected — it does not
    enter the catalog and the run cannot claim ship-mix eligibility);
  * a source with no recorded classification FAILS the build — it is never
    defaulted into either mix and the missing classification is reported;
  * a real-transcript source without its consent record is REFUSED from both
    mixes with the reason recorded (no silent harvest, even into the dev mix;
    the P2 consent leg is T-191);
  * the manifest carries a content hash that is stable across re-emissions of
    the same corpus — the hash that pairs it with the gate results — and the
    artifact contains no user content (counts, licences and identifiers only).

No network anywhere: the teacher and translator seams are injected. The
synthetic held-out set is built through ``author_chat_golden``'s own builders,
so a fixture-schema change breaks these tests rather than silently changing
what the guard protects. The fixture TEXTS are the T-179 suite's (verified
collision-free against the REAL held-out set): the CLI end-to-end runs with the
default guard over the real fixtures.

The registry checks are data-not-code: the family table, the never-admissible
pin and the tooling sources are all read from the module under test, and the
tests mutate a COPY of the registry — a registry change must move the check,
and these tests move it.
"""
from __future__ import annotations

import contextlib
import dataclasses
import hashlib
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

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import style_spec as ss  # noqa: E402
import author_chat_golden as acg  # noqa: E402
import pipeline_guards as guards  # noqa: E402
import build_chat_corpus as bc  # noqa: E402

#: Distinguishes "use the default" from an explicit None.
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
# Fixture texts (the T-179 suite's set — collision-free against the real
# held-out set, which the CLI end-to-end build loads through the default guard)
# ---------------------------------------------------------------------------

REPLY = "हजुर, म ठीक छु। तपाईंलाई धन्यवाद।"
ECOM_USER = "मलाई नयाँ किताब चाहियो हजुर।"
TASK_ELDER_EN = "Book me a taxi to the health post."
TASK_ELDER_NE = "ट्याक्सी बोलाइदिनुहोस् हजुर।"
TASK_REPLY_EN = "Sure, I will book it for tomorrow morning."
DAILYD_ELDER_EN = "I could not sleep at all last night."
DAILYD_ELDER_NE = "हिजो राति निद्रा लागेन हजुर।"
DAILYD_REPLY_EN = "I am sorry to hear that."
TT1_UTTERANCE = "औषधि खानुभयो हजुर?"
TT2_UTTERANCE = "मेरो उमेर कति भयो?"
E1_UTTERANCE = "अब भन्नुहोस् हजुर।"
CALL_UTTERANCE = "मलाई सहयोग चाहियो हजुर।"

#: The synthetic held-out chat set's turns (5+ tokens each so the
#: near-duplicate pool carries them).
GUARD_USER_1 = "बिहानको खाजा र चिया खानुभयो हजुर?"
GUARD_USER_2 = "आज गाउँमा मौसम राम्रो छ।"
GUARD_REPLY_1 = "खानुभयो हजुर। धन्यवाद।"
GUARD_REPLY_2 = "राम्रो छ हजुर। बाहिर हिँड्नुहोस्।"
GOLDEN_UTTERANCE = "यो सुनौलो वाक्य पहिलो हो।"
GOLDEN_UTTERANCE_2 = "यो सुनौलो वाक्य दोस्रो हो।"
NEARMISS_UTTERANCE = "यो आपतकालीन नजिकको वाक्य हो।"

#: Every fixture text that must NEVER appear in the manifest (no user content).
_USER_CONTENT_TEXTS = (REPLY, ECOM_USER, TASK_ELDER_EN, TASK_ELDER_NE,
                       TASK_REPLY_EN, DAILYD_ELDER_EN, DAILYD_ELDER_NE,
                       DAILYD_REPLY_EN, TT1_UTTERANCE, TT2_UTTERANCE,
                       E1_UTTERANCE, CALL_UTTERANCE, GUARD_USER_1, GUARD_USER_2,
                       GUARD_REPLY_1, GUARD_REPLY_2, GOLDEN_UTTERANCE,
                       GOLDEN_UTTERANCE_2, NEARMISS_UTTERANCE)

#: The corpus is Devanagari; no manifest string may carry a Devanagari
#: codepoint (U+0900–U+097F).
_DEVANAGARI = re.compile("[ऀ-ॿ]")

#: Closed key sets — a future field that carries content fails the test.
MANIFEST_KEYS = {
    "schema", "run_id", "mix", "seed", "builder", "style_spec", "corpus",
    "held_out", "license_registry", "classification_check", "consent_check",
    "non_admissible_ship_sources", "ship_mix_assertion", "ship_mix_eligible",
    "sources", "tooling", "artifacts", "pairing", "content_hash",
    "content_hash_scope"}
SOURCE_ENTRY_KEYS = {
    "id", "layer", "kind", "component", "license", "license_family",
    "classification", "mix", "admissible_to_ship", "provenance", "source_path",
    "present", "status", "reason", "counts", "derived_artifacts",
    "requires_consent", "consent_record"}
TOOLING_ENTRY_KEYS = {
    "id", "layer", "kind", "classification", "mix", "license", "license_family",
    "provenance", "source_path", "status", "reason", "counts",
    "derived_artifacts", "inputs_classified"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_jsonl(path, records) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records),
                    encoding="utf-8")


def _read_jsonl(path) -> list:
    return [json.loads(line) for line in
            Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def _guard_fixture(tmp: Path, spec) -> dict:
    """A tiny schema-valid held-out set built through acg's own builders."""
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
        {"id": "g-2", "utterance": GOLDEN_UTTERANCE_2, "intent": "smalltalk"}])
    nearmiss = tmp / "emergency_nearmiss.jsonl"
    _write_jsonl(nearmiss, [{"id": "nm-1", "utterance": NEARMISS_UTTERANCE,
                             "kind": "emergency"}])
    return {"chat": chat, "golden": golden, "nearmiss": nearmiss}


#: The registry paths the fixture sources are written to.
SOURCE_PATHS = {
    "indic": "chat-sources/l1/indic_dialogue_ne.jsonl",
    "ecommerce": "chat-sources/l1/devanagari_ecommerce.jsonl",
    "call_center": "chat-sources/l1/call_center_transcripts.jsonl",
    "own_transcripts": "chat-sources/l1/own_transcripts.jsonl",
    "dailydialog": "chat-sources/l2/dailydialog.jsonl",
    "taskmaster": "chat-sources/l2/taskmaster.jsonl",
    "teacher": "data/teacher.jsonl",
    "edge": "data/edge_cases.jsonl",
}

INDIC = [{"dialogue_id": "d-1", "turns": [
    {"speaker": "elder", "text": "नमस्ते हजुर।"},
    {"speaker": "assistant", "text": REPLY},
    {"speaker": "elder", "text": "आज दिन कस्तो छ?"},
    {"speaker": "assistant", "text": REPLY}]}]
ECOM = [{"id": "p-1", "user_turn": ECOM_USER, "reply": REPLY}]
CALL_CENTER = [{"dialogue_id": "cc-1", "turns": [
    {"speaker": "elder", "text": CALL_UTTERANCE},
    {"speaker": "assistant", "text": REPLY}]}]
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
]
EDGE = [{"id": "e-1", "utterance": E1_UTTERANCE, "reply": REPLY, "confidence": 0.2,
         "action": "abstain"}]

#: Commercial-safe sources only: the ship-mix subset.
_SHIP_SOURCES = {"ecommerce": ECOM, "teacher": TEACHER, "edge": EDGE}
#: Plus the CC BY-NC L1/L2 layers (dev-mix material).
_DEV_SOURCES = dict(_SHIP_SOURCES, indic=INDIC, dailydialog=DAILYD,
                    taskmaster=TASKMASTER)


def _mapped_translate(texts):
    """The fake translation tier (a recorded seam, deterministic)."""
    mapping = {TASK_ELDER_EN: TASK_ELDER_NE, DAILYD_ELDER_EN: DAILYD_ELDER_NE}
    return [mapping.get(text, TASK_ELDER_NE) for text in texts]


def _write_sources(root: Path, rows: dict) -> None:
    for name, records in rows.items():
        if records is None:
            continue
        _write_jsonl(Path(root) / SOURCE_PATHS[name], records)


class FakeTeacher:
    """The injectable teacher: GEC, L3 generation and L2 post-edit.

    Detection is by the prompts the builder itself builds: the GEC batch
    starts with ``bc.GEC_PROMPT_HEADER``, the post-edit call with its fixed
    first line, and the L3 call carries the ``= THIS BATCH =`` block whose
    class and count are parsed back out of the prompt.
    """

    def __init__(self, *, reply=REPLY, gec_drop=()):
        self.reply = reply
        self.gec_drop = set(gec_drop)
        self.gec_prompts = []
        self.gec_batches = []                  # list of text lists
        self.l3_keys = []
        self.postedit_prompts = []
        self._l3_n = 0

    def __call__(self, prompt, cfg):
        if prompt.startswith(bc.GEC_PROMPT_HEADER):
            texts = [m.group(2) for m in re.finditer(r"^\[(\d+)\] (.*)$", prompt,
                                                     flags=re.M)]
            self.gec_prompts.append(prompt)
            self.gec_batches.append(texts)
            return {"turns": [{"i": index, "corrected": text}
                              for index, text in enumerate(texts)
                              if text not in self.gec_drop],
                    "usage": {"prompt_tokens": 10, "output_tokens": 5}}
        if prompt.startswith("You are post-editing"):
            self.postedit_prompts.append(prompt)
            indexes = [int(m.group(1)) for m in
                       re.finditer(r"^\[(\d+)\] elder:", prompt, flags=re.M)]
            return {"turns": [{"i": index, "reply": self.reply} for index in indexes],
                    "usage": {"prompt_tokens": 50, "output_tokens": 30}}
        if "= THIS BATCH =" in prompt:
            key = re.search(r"^batch id: (\S+)$", prompt, flags=re.M).group(1)
            klass = re.search(r"^conversation class: (\S+)", prompt, flags=re.M).group(1)
            count = int(re.search(r"Produce exactly (\d+) chat turns",
                                  prompt).group(1))
            self.l3_keys.append(key)
            turns = []
            for _ in range(count):
                self._l3_n += 1
                turns.append({"user_turn": f"नक्कली प्रश्न {self._l3_n}",
                              "context": [], "acceptable_output": self.reply,
                              "note": f"fake {klass}"})
            return {"turns": turns,
                    "usage": {"prompt_tokens": 500, "output_tokens": 200}}
        raise AssertionError(f"FakeTeacher got an unknown prompt: {prompt[:200]!r}")


class RecordingTeacher:
    """Records ``{prompt_sha256, response}`` — the offline replay fixture
    ``default_teacher(..., "teacher-fixture", path)`` consumes."""

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


# ---------------------------------------------------------------------------
# Registry mutation helpers (data-not-code: a registry change MOVES the check)
# ---------------------------------------------------------------------------

def _registry_with(*, mutate=None, add=()) -> tuple:
    mutated = []
    for source in bc.SOURCE_REGISTRY:
        changes = (mutate or {}).get(source.id)
        mutated.append(dataclasses.replace(source, **changes) if changes else source)
    return tuple(mutated) + tuple(add)


def _transcript_source(*, consent="", admissibility="ship",
                       source_id="own_transcripts") -> "bc.SourceSpec":
    """A real-transcript source (the T-191 P2 shape): own data + consent."""
    return bc.SourceSpec(
        id=source_id, layer="L1", license="own data (consented transcripts)",
        admissibility=admissibility, kind="dialogue",
        default_path=SOURCE_PATHS["own_transcripts"], provenance="own",
        requires_consent=True, consent=consent,
        notes="real transcripts collected with informed consent (T-191)")


@contextlib.contextmanager
def _patched(registry, *, tooling=None):
    """Patch the module registry (the checks read it at call time)."""
    tooling_sources = tuple(tooling) if tooling is not None else bc.TOOLING_SOURCES
    with mock.patch.object(bc, "SOURCE_REGISTRY", tuple(registry)), \
            mock.patch.object(bc, "SOURCES_BY_ID",
                              {s.id: s for s in registry}), \
            mock.patch.object(bc, "TOOLING_SOURCES", tooling_sources):
        yield


def _counts_from(report: dict) -> dict:
    """The per-source admitted turns the counters recorded (file-backed)."""
    return {entry["id"]: int(entry.get("admitted") or 0)
            for entry in report["sources"]}


# ---------------------------------------------------------------------------
# The fixture build harness
# ---------------------------------------------------------------------------

class ProvenanceTestCase(unittest.TestCase):
    """A synthetic held-out set + a small registry-backed source fixture."""

    maxDiff = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="t180-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.spec = ss.load()
        self.paths = _guard_fixture(self.tmp / "heldout", self.spec)
        self.guard = bc.HeldOutGuard.load(chat_path=self.paths["chat"],
                                          golden_path=self.paths["golden"],
                                          nearmiss_path=self.paths["nearmiss"])
        self.src_root = self.tmp / "sources"

    # -- the one build entry point every test goes through ------------------

    def build(self, *, mix="ship", rows=_SHIP_SOURCES, out="run/ship",
              teacher=None, translate=_DEFAULT, l3_target_turns=0, seed=42,
              noise_backend="none", execute=True, run_id="t180-test",
              manifest_path=None, registry=None):
        rows = dict(rows)
        if rows:
            _write_sources(self.src_root, rows)
        out_dir = self.tmp / out
        opts = bc.BuildOptions(
            mix=mix, source_root=self.src_root, out_dir=out_dir, run_id=run_id,
            seed=seed, l3_target_turns=l3_target_turns, noise_backend=noise_backend,
            execute=execute, manifest_path=manifest_path)
        teacher = teacher if teacher is not None else FakeTeacher()
        context = _patched(registry) if registry is not None \
            else contextlib.nullcontext()
        with context:
            report = bc.build_chat_corpus(
                opts, spec=self.spec, teacher=teacher,
                translate=(_mapped_translate if translate is _DEFAULT else translate),
                held_out=self.guard, log=lambda line: None)
        return report, out_dir, teacher

    # -- small readers ------------------------------------------------------

    def manifest_path(self, out_dir) -> Path:
        return Path(out_dir).parent / bc.MANIFEST_NAME

    def manifest(self, out_dir) -> dict:
        return json.loads(self.manifest_path(out_dir).read_text(encoding="utf-8"))

    def counters(self, out_dir) -> dict:
        return json.loads((Path(out_dir) / "chat-corpus-counters.json")
                          .read_text(encoding="utf-8"))

    def corpus(self, out_dir, mix="ship") -> list:
        return _read_jsonl(Path(out_dir) / f"chat-corpus-{mix}.jsonl")


# ---------------------------------------------------------------------------
# The registry the check cites (constants + data-not-code pins)
# ---------------------------------------------------------------------------

class RegistryTests(unittest.TestCase):
    def test_schema_and_exit_code(self):
        self.assertEqual(bc.PROVENANCE_SCHEMA, "chat_corpus_provenance/v1")
        self.assertEqual(bc.MANIFEST_NAME, "provenance-manifest.json")
        self.assertTrue(bc.LICENSE_REGISTRY_ID)
        self.assertEqual(bc.EXIT_PROVENANCE, 5)      # the suite's vocabulary is 0-4
        for code in (guards.EXIT_OK, guards.EXIT_STAGE, guards.EXIT_USAGE,
                     guards.EXIT_GUARD, guards.EXIT_FLOOR):
            self.assertNotEqual(bc.EXIT_PROVENANCE, code)

    def test_ship_admissible_families_are_the_requirements_set(self):
        self.assertEqual(tuple(bc.SHIP_ADMISSIBLE_LICENSE_FAMILIES),
                         ("CC-BY", "Apache-2.0", "MIT", "synthetic", "own data"))
        self.assertEqual(set(bc.SHIP_ADMISSIBLE_LICENSE_FAMILIES),
                         {family for family in bc.LICENSE_FAMILIES
                          if bc.ship_admissible_family(family)})

    def test_every_registry_licence_resolves_to_a_recorded_family(self):
        for source in (*bc.SOURCE_REGISTRY, *bc.TOOLING_SOURCES):
            family = bc.license_family(source.license)
            self.assertIn(family, bc.LICENSE_FAMILIES, source.id)
            self.assertNotEqual(family, "unknown", source.id)

    def test_the_nc_layers_and_the_transcript_corpus_are_dev_only(self):
        by_id = bc.sources_by_id()
        for source_id in ("indic_dialogue_ne", "dailydialog", "personachat_convai2",
                          "empathetic_dialogues"):
            source = by_id[source_id]
            self.assertEqual(bc.license_family(source.license), "CC BY-NC", source_id)
            self.assertEqual(source.admissibility, "dev", source_id)
            self.assertFalse(
                bc.ship_admissible_family(bc.license_family(source.license)), source_id)
        transcripts = by_id["call_center_transcripts"]
        self.assertEqual(bc.license_family(transcripts.license), "research-gated")
        self.assertEqual(transcripts.admissibility, "dev")

    def test_every_ship_source_resolves_to_an_admissible_family(self):
        for source in bc.SOURCE_REGISTRY:
            if source.admissibility != "ship":
                continue
            self.assertTrue(
                bc.ship_admissible_family(bc.license_family(source.license)),
                source.id)

    def test_the_pin_matches_the_current_registry(self):
        record = bc.non_admissible_ship_sources()
        self.assertEqual(record["violations"], [])
        self.assertEqual([entry["id"] for entry in record["sources"]],
                         list(bc.NON_ADMISSIBLE_SHIP_SOURCE_IDS))
        families = {entry["id"]: entry["license_family"] for entry in record["sources"]}
        for entry in record["sources"]:
            self.assertTrue(entry["license"])
            self.assertFalse(entry["admissible_to_ship"], entry["id"])
            self.assertIn(entry["classification"], ("dev", "unclassified"))
        self.assertEqual(families["indic_dialogue_ne"], "CC BY-NC")
        self.assertEqual(families["dailydialog"], "CC BY-NC")
        self.assertEqual(families["personachat_convai2"], "CC BY-NC")
        self.assertEqual(families["empathetic_dialogues"], "CC BY-NC")
        self.assertEqual(families["call_center_transcripts"], "research-gated")

    def test_a_promoted_named_source_is_a_violation(self):
        registry = _registry_with(mutate={"indic_dialogue_ne":
                                          {"admissibility": "ship"}})
        record = bc.non_admissible_ship_sources(registry)
        self.assertEqual([v["kind"] for v in record["violations"]],
                         ["non_admissible_source_promoted"])
        violation = record["violations"][0]
        self.assertEqual(violation["source"], "indic_dialogue_ne")
        self.assertIn("CC BY-NC", violation["license"])
        self.assertIn("CC BY-NC", violation["message"])

    def test_a_missing_named_source_is_a_pin_failure(self):
        registry = tuple(s for s in bc.SOURCE_REGISTRY if s.id != "dailydialog")
        record = bc.non_admissible_ship_sources(registry)
        self.assertEqual([v["kind"] for v in record["violations"]],
                         ["non_admissible_source_missing"])
        self.assertIn("dailydialog", record["violations"][0]["message"])

    def test_the_registry_record_is_the_data_the_check_cites(self):
        record = bc.license_registry_record()
        self.assertEqual(record["id"], bc.LICENSE_REGISTRY_ID)
        self.assertEqual(len(record["sources"]),
                         len(bc.SOURCE_REGISTRY) + len(bc.TOOLING_SOURCES))
        self.assertEqual(sorted(record["sources"][0]),
                         sorted(["id", "layer", "license", "license_family",
                                 "classification", "admissible_to_ship"]))
        self.assertEqual(len(record["sha256"]), 64)
        # the hash MOVES with the registry: a licence change is a new registry
        mutated = bc.license_registry_record(_registry_with(
            mutate={"oasst1": {"license": "CC BY-NC 4.0 (research-only)"}}))
        self.assertNotEqual(record["sha256"], mutated["sha256"])

    def test_the_static_checks_are_clean_on_the_shipped_registry(self):
        self.assertEqual(bc.non_admissible_ship_sources()["violations"], [])
        self.assertEqual(bc.classification_violations(), [])
        self.assertEqual(bc.consent_refusals(), [])
        self.assertTrue(bc.sources_by_id())


# ---------------------------------------------------------------------------
# Missing classification — never defaulted into either mix
# ---------------------------------------------------------------------------

class ClassificationTests(unittest.TestCase):
    def test_a_source_without_a_classification_is_reported(self):
        source = dataclasses.replace(bc.SOURCES_BY_ID["devanagari_ecommerce"],
                                     admissibility="")
        violations = bc.classification_violations([source])
        self.assertEqual(len(violations), 1)
        violation = violations[0]
        self.assertEqual(violation["kind"], "missing_classification")
        self.assertEqual(violation["source"], source.id)
        self.assertEqual(violation["field"], "admissibility")
        self.assertIn("NEITHER mix", violation["message"])

    def test_an_unknown_classification_value_is_not_defaulted(self):
        source = dataclasses.replace(bc.SOURCES_BY_ID["taskmaster"],
                                     admissibility="maybe")
        violations = bc.classification_violations([source])
        self.assertEqual([v["kind"] for v in violations], ["missing_classification"])
        self.assertEqual(violations[0]["value"], "maybe")

    def test_a_source_without_a_licence_is_reported(self):
        source = dataclasses.replace(bc.SOURCES_BY_ID["oasst1"], license="")
        violations = bc.classification_violations([source])
        self.assertEqual([v["kind"] for v in violations], ["missing_classification"])
        self.assertEqual(violations[0]["field"], "license")
        self.assertIn("no licence record", violations[0]["message"])

    def test_a_ship_source_with_a_non_ship_licence_is_a_contradiction(self):
        source = dataclasses.replace(bc.SOURCES_BY_ID["taskmaster"],
                                     license="CC BY-NC 4.0 (research-only)")
        violations = bc.classification_violations([source])
        self.assertEqual([v["kind"] for v in violations], ["registry_contradiction"])
        self.assertEqual(violations[0]["license_family"], "CC BY-NC")
        self.assertIn("not a ship-admissible family", violations[0]["message"])

    def test_the_build_fails_on_an_unclassified_source_and_reports_it(self):
        registry = _registry_with(mutate={"oasst1": {"admissibility": ""}})
        opts = bc.BuildOptions(mix="ship", out_dir=Path("/nonexistent-out"))
        with self.assertRaises(bc.ProvenanceError) as ctx:
            bc.assert_provenance(opts, bc.Counters(), sources=registry)
        error = ctx.exception
        self.assertIsInstance(error, bc.BuildStopped)
        self.assertEqual([v["kind"] for v in error.violations],
                         ["missing_classification"])
        self.assertEqual(error.violations[0]["source"], "oasst1")
        self.assertIn("oasst1", str(error))
        self.assertIn("no recorded classification", str(error))
        # nothing was defaulted: the record names the missing classification
        self.assertEqual(error.record["classification_check"]["verdict"], "fail")
        self.assertIs(error.record["ship_mix_eligible"], False)


# ---------------------------------------------------------------------------
# The ship-mix assertion (pure function)
# ---------------------------------------------------------------------------

class ShipMixCheckTests(unittest.TestCase):
    def test_an_admissible_ship_mix_passes_and_records_the_registry(self):
        counts = {"devanagari_ecommerce": 3, "taskmaster": 2, "soda": 1,
                  "prosocial_dialog": 1, "oasst1": 4, "synthetic_eldercare": 7,
                  "intent_training_teacher": 2}
        record = bc.ship_mix_check(counts, mix="ship")
        self.assertEqual(record["verdict"], "pass")
        self.assertIs(record["ship_mix_eligible"], True)
        self.assertEqual(record["violations"], [])
        self.assertEqual(record["applies_to"], "ship")
        self.assertIn("CC-BY", record["rule"])
        # the assertion records the licence registry it used
        self.assertEqual(record["license_registry"]["id"], bc.LICENSE_REGISTRY_ID)
        self.assertEqual(len(record["license_registry"]["sha256"]), 64)
        evaluated = {entry["id"]: entry for entry in record["evaluated"]}
        self.assertEqual(evaluated["devanagari_ecommerce"]["license_family"],
                         "Apache-2.0")
        self.assertIs(evaluated["oasst1"]["eligible_to_ship"], True)
        self.assertIs(evaluated["indic_dialogue_ne"]["eligible_to_ship"], False)
        self.assertEqual(evaluated["indic_dialogue_ne"]["admitted"], 0)

    def test_a_cc_by_nc_source_in_the_ship_mix_fails_naming_source_and_licence(self):
        record = bc.ship_mix_check({"indic_dialogue_ne": 4}, mix="ship")
        self.assertEqual(record["verdict"], "fail")
        self.assertIs(record["ship_mix_eligible"], False)
        violation = record["violations"][0]
        self.assertEqual(violation["kind"], "non_admissible_source_in_ship_mix")
        self.assertEqual(violation["source"], "indic_dialogue_ne")
        self.assertIn("CC BY-NC", violation["license"])
        self.assertEqual(violation["admitted"], 4)
        self.assertIn("indic_dialogue_ne", violation["message"])
        self.assertIn("CC BY-NC 3.0", violation["message"])

    def test_a_research_gated_transcript_in_the_ship_mix_fails(self):
        record = bc.ship_mix_check({"call_center_transcripts": 12}, mix="ship")
        self.assertEqual(record["verdict"], "fail")
        violation = record["violations"][0]
        self.assertEqual(violation["source"], "call_center_transcripts")
        self.assertEqual(violation["license_family"], "research-gated")
        self.assertIn("research-gated", violation["license"])

    def test_every_named_non_admissible_source_fails_in_the_ship_mix(self):
        for source_id in bc.NON_ADMISSIBLE_SHIP_SOURCE_IDS:
            record = bc.ship_mix_check({source_id: 1}, mix="ship")
            self.assertEqual(record["verdict"], "fail", source_id)
            self.assertEqual([v["source"] for v in record["violations"]], [source_id])

    def test_an_unclassified_source_in_the_ship_mix_fails(self):
        record = bc.ship_mix_check({"nepali_sft_himalaya": 2}, mix="ship")
        self.assertEqual(record["verdict"], "fail")
        self.assertEqual(record["violations"][0]["license_family"], "unclassified")

    def test_a_source_with_zero_turns_never_violates(self):
        record = bc.ship_mix_check({"indic_dialogue_ne": 0}, mix="ship")
        self.assertEqual(record["verdict"], "pass")
        self.assertEqual(record["violations"], [])

    def test_the_dev_mix_records_not_applicable_and_still_records_families(self):
        record = bc.ship_mix_check({"indic_dialogue_ne": 4, "dailydialog": 2}, mix="dev")
        self.assertEqual(record["verdict"], "not_applicable")
        self.assertIs(record["ship_mix_eligible"], False)
        self.assertEqual(record["violations"], [])
        evaluated = {entry["id"]: entry for entry in record["evaluated"]}
        self.assertEqual(evaluated["indic_dialogue_ne"]["license_family"], "CC BY-NC")
        self.assertIs(evaluated["indic_dialogue_ne"]["eligible_to_ship"], False)

    def test_tooling_inputs_are_never_evaluated_as_mix_turns(self):
        registry = (*bc.SOURCE_REGISTRY, *bc.TOOLING_SOURCES)
        record = bc.ship_mix_check({"teacher_gemini_flash_lite": 5}, mix="ship",
                                   sources=registry)
        self.assertEqual([entry["id"] for entry in record["evaluated"]
                          if entry["id"].startswith("teacher_")], [])


# ---------------------------------------------------------------------------
# The ship-mix rule over REAL build counts
# ---------------------------------------------------------------------------

class RealCountsTests(ProvenanceTestCase):
    def test_a_real_dev_mix_corpus_fails_the_check_when_claimed_as_ship(self):
        """The ship-mix rule over the counts of an executed dev build.

        The dev mix legitimately admits CC BY-NC sources (that is their home);
        the very same counts evaluated as a ship mix are a compliance failure
        naming the sources and their licences — which is exactly what the
        assertion is for. The L1 layer is the witness; the L2 CC BY-NC batch
        is LAYER-admitted but MIXTURE-excluded while its human spot-check is
        pending (`selected = False` + `hold("pending_spot_check")`, design
        §11.2): it feeds layers/L2.jsonl, never the corpus.
        """
        report, out_dir, _ = self.build(mix="dev", rows=_DEV_SOURCES,
                                        out="run/dev")
        counts = _counts_from(report)
        self.assertGreaterEqual(counts["indic_dialogue_ne"], 1)  # the L1 witness
        # the pending L2 batch: layer-admitted (the layer file carries it),
        # mixture-excluded (no corpus row, selected 0)
        self.assertGreaterEqual(counts["dailydialog"], 1)
        self.assertGreaterEqual(report["held"].get("pending_spot_check", 0), 1)
        self.assertNotIn("dailydialog",
                         {row["source"] for row in self.corpus(out_dir, mix="dev")})
        manifest = json.loads((Path(out_dir).parent / "provenance-manifest.dev.json")
                              .read_text(encoding="utf-8"))
        held_entry = {entry["id"]: entry
                      for entry in manifest["sources"]}["dailydialog"]
        self.assertGreaterEqual(held_entry["counts"]["admitted"], 1)
        self.assertEqual(held_entry["counts"]["selected"], 0)
        self.assertIn("layers/L2.jsonl", held_entry["derived_artifacts"])
        self.assertNotIn("chat-corpus-dev.jsonl", held_entry["derived_artifacts"])
        dirty = bc.ship_mix_check(counts, mix="ship")
        self.assertEqual(dirty["verdict"], "fail")
        named = {v["source"]: v for v in dirty["violations"]}
        self.assertIn("indic_dialogue_ne", named)
        self.assertIn("CC BY-NC", named["indic_dialogue_ne"]["license"])
        self.assertEqual(named["indic_dialogue_ne"]["admitted"],
                         counts["indic_dialogue_ne"])
        self.assertIn("dailydialog", named)          # the held batch still counts
        self.assertEqual(named["dailydialog"]["admitted"], counts["dailydialog"])
        # ... while the same counts are honest for the dev mix they came from
        clean = bc.ship_mix_check(counts, mix="dev")
        self.assertEqual(clean["verdict"], "not_applicable")
        self.assertEqual(clean["violations"], [])


# ---------------------------------------------------------------------------
# Consent — a transcript source without its record is refused
# ---------------------------------------------------------------------------

class ConsentTests(ProvenanceTestCase):
    def test_the_refusal_names_both_mixes_and_the_p2_leg(self):
        source = _transcript_source()
        self.assertTrue(bc.source_consent_missing(source))
        refusals = bc.consent_refusals([source])
        self.assertEqual(len(refusals), 1)
        refusal = refusals[0]
        self.assertEqual(refusal["id"], "own_transcripts")
        self.assertEqual(refusal["mix"], "none")
        self.assertEqual(refusal["status"], "refused")
        self.assertIn("no silent harvest", refusal["reason"])
        self.assertIn("T-191", refusal["reason"])
        self.assertIsNone(refusal["consent_record"])

    def test_a_consent_record_clears_the_refusal(self):
        source = _transcript_source(consent="consent-2026-10-14-household-a")
        self.assertFalse(bc.source_consent_missing(source))
        self.assertEqual(bc.consent_refusals([source]), [])

    def test_an_unconsented_transcript_is_refused_from_the_ship_build(self):
        registry = _registry_with(add=[_transcript_source()])
        report, out_dir, _ = self.build(
            rows=dict(_SHIP_SOURCES, own_transcripts=CALL_CENTER), registry=registry)
        self.assertEqual(report["rejections"]["unconsented_transcript"], 1)
        self.assertEqual(report["layers"]["L1"]["admitted"], 1)   # ecommerce only
        self.assertNotIn("own_transcripts",
                         {row["source"] for row in self.corpus(out_dir)})
        entry = next(e for e in self.manifest(out_dir)["sources"]
                     if e["id"] == "own_transcripts")
        self.assertEqual(entry["status"], "refused")
        self.assertEqual(entry["mix"], "none")
        self.assertIn("no silent harvest", entry["reason"])
        self.assertEqual(entry["counts"],
                         {"candidates": 0, "admitted": 0, "selected": 0})
        self.assertIs(entry["requires_consent"], True)

    def test_an_unconsented_transcript_is_refused_from_the_dev_build_too(self):
        registry = _registry_with(add=[_transcript_source()])
        report, out_dir, _ = self.build(
            mix="dev", rows=dict(_SHIP_SOURCES, own_transcripts=CALL_CENTER),
            registry=registry)
        self.assertEqual(report["rejections"]["unconsented_transcript"], 1)
        self.assertNotIn("own_transcripts",
                         {row["source"] for row in self.corpus(out_dir, mix="dev")})

    def test_a_consented_transcript_source_is_admitted_as_own_data(self):
        registry = _registry_with(add=[_transcript_source(consent="consent-1")])
        report, out_dir, _ = self.build(
            rows=dict(_SHIP_SOURCES, own_transcripts=CALL_CENTER), registry=registry)
        self.assertNotIn("unconsented_transcript", report["rejections"])
        self.assertIn("own_transcripts",
                      {row["source"] for row in self.corpus(out_dir)})
        entry = next(e for e in self.manifest(out_dir)["sources"]
                     if e["id"] == "own_transcripts")
        self.assertEqual(entry["status"], "used")
        self.assertEqual(entry["license_family"], "own data")
        self.assertIs(entry["admissible_to_ship"], True)
        self.assertEqual(entry["consent_record"], "consent-1")
        self.assertGreaterEqual(entry["counts"]["admitted"], 1)
        self.assertIn("layers/L1.jsonl", entry["derived_artifacts"])

    def test_a_consent_refused_source_that_still_contributed_turns_fails(self):
        # the bypass backstop: if the refusal were ever skipped, admitted turns
        # from a consent-less transcript source FAIL the build
        registry = _registry_with(add=[_transcript_source()])
        counters = bc.Counters()
        counters.admitted["per_source"]["own_transcripts"] = 2
        opts = bc.BuildOptions(mix="ship", out_dir=self.tmp / "unused")
        with self.assertRaises(bc.ProvenanceError) as ctx:
            bc.assert_provenance(opts, counters, sources=registry)
        violation = ctx.exception.violations[0]
        self.assertEqual(violation["kind"], "unconsented_transcript_in_mix")
        self.assertEqual(violation["source"], "own_transcripts")
        self.assertIn("refused from BOTH mixes", violation["message"])
        self.assertEqual(ctx.exception.record["consent_check"]["verdict"], "fail")
        self.assertIs(ctx.exception.record["ship_mix_eligible"], False)


# ---------------------------------------------------------------------------
# The manifest emission (the builder that assembled the corpus wrote it)
# ---------------------------------------------------------------------------

class ManifestTests(ProvenanceTestCase):
    def test_the_manifest_is_written_in_the_run_directory(self):
        _, out_dir, _ = self.build()
        path = self.manifest_path(out_dir)
        self.assertTrue(path.is_file())
        self.assertEqual(path.parent, Path(out_dir).parent)
        self.assertFalse((Path(out_dir) / bc.MANIFEST_NAME).exists())
        manifest = self.manifest(out_dir)
        self.assertEqual(manifest["schema"], bc.PROVENANCE_SCHEMA)
        self.assertEqual(manifest["run_id"], "t180-test")
        self.assertEqual(manifest["mix"], "ship")
        self.assertEqual(manifest["builder"],
                         "tools/train-intent/src/build_chat_corpus.py")
        self.assertEqual(manifest["style_spec"]["sha256"], self.spec.sha256)

    def test_the_manifest_is_the_design_path_in_the_cli_layout(self):
        path = bc.manifest_path_for(bc.BuildOptions(
            mix="ship", out_dir=Path("build/chat-corpus/v17/ship")))
        self.assertEqual(path.as_posix(),
                         "build/chat-corpus/v17/provenance-manifest.json")
        dev = bc.manifest_path_for(bc.BuildOptions(
            mix="dev", out_dir=Path("build/chat-corpus/v17/dev"), run_id="v17"))
        self.assertEqual(dev.as_posix(),
                         "build/chat-corpus/v17/provenance-manifest.dev.json")
        explicit = bc.manifest_path_for(bc.BuildOptions(
            mix="ship", out_dir=Path("x/ship"), manifest_path=Path("elsewhere/m.json")))
        self.assertEqual(explicit, Path("elsewhere/m.json"))

    def test_every_source_appears_with_licence_layer_classification_counts_and_artifacts(self):
        report, out_dir, _ = self.build()
        manifest = self.manifest(out_dir)
        entries = {entry["id"]: entry for entry in manifest["sources"]}
        self.assertEqual(set(entries), {s.id for s in bc.SOURCE_REGISTRY})
        for source in bc.SOURCE_REGISTRY:
            entry = entries[source.id]
            self.assertEqual(set(entry), SOURCE_ENTRY_KEYS, source.id)
            self.assertEqual(entry["license"], source.license)
            self.assertEqual(entry["layer"], source.layer)
            self.assertEqual(entry["classification"], source.admissibility)
            self.assertEqual(entry["license_family"],
                             bc.license_family(source.license))
            self.assertEqual(set(entry["counts"]),
                             {"candidates", "admitted", "selected"})
        # the counts used are the run's own accounting (manifest entries nest
        # them; the counters file carries the flat per-source shape)
        admitted = _counts_from(report)
        for source_id, count in admitted.items():
            self.assertEqual(entries[source_id]["counts"]["admitted"], count,
                             source_id)
        # the derived artifacts are the files the source's turns landed in
        ecom = entries["devanagari_ecommerce"]
        self.assertEqual(ecom["status"], "used")
        self.assertGreaterEqual(ecom["counts"]["admitted"], 1)
        self.assertIn("layers/L1.jsonl", ecom["derived_artifacts"])
        self.assertIn("chat-corpus-ship.jsonl", ecom["derived_artifacts"])
        # a source that contributed nothing fed nothing
        self.assertEqual(entries["soda"]["derived_artifacts"], [])

    def test_the_derived_artifacts_are_artifacts_this_build_wrote(self):
        _, out_dir, teacher = self.build(l3_target_turns=11)
        manifest = self.manifest(out_dir)
        names = {record["name"] for record in manifest["artifacts"]}
        self.assertIn("chat-corpus-ship.jsonl", names)
        self.assertIn("l3-generated.jsonl", names)
        for entry in manifest["sources"] + manifest["tooling"]:
            for name in entry["derived_artifacts"]:
                self.assertIn(name, names, entry["id"])
        # the invariant: layer files follow admission, the corpus follows
        # selection (the mixture may legitimately sample an admitted turn out)
        corpus_name = "chat-corpus-ship.jsonl"
        for entry in manifest["sources"]:
            if entry["status"] in ("refused", "excluded"):
                continue
            layer_file = f"layers/{entry['layer']}.jsonl"
            self.assertEqual(layer_file in entry["derived_artifacts"],
                             entry["counts"]["admitted"] > 0, entry["id"])
            self.assertEqual(corpus_name in entry["derived_artifacts"],
                             entry["counts"]["selected"] > 0, entry["id"])
        self.assertGreaterEqual(len(teacher.l3_keys), 1)
        l3 = next(e for e in manifest["sources"] if e["id"] == "synthetic_eldercare")
        self.assertEqual(l3["status"], "used")
        self.assertEqual(l3["license_family"], "synthetic")
        self.assertIn("l3-generated.jsonl", l3["derived_artifacts"])
        self.assertIn("layers/L3.jsonl", l3["derived_artifacts"])

    def test_each_artifact_carries_its_own_hash_and_row_count(self):
        _, out_dir, _ = self.build()
        manifest = self.manifest(out_dir)
        corpus = Path(out_dir) / f"chat-corpus-{manifest['mix']}.jsonl"
        record = next(r for r in manifest["artifacts"]
                      if r["name"] == "chat-corpus-ship.jsonl")
        self.assertEqual(record["sha256"],
                         hashlib.sha256(corpus.read_bytes()).hexdigest())
        self.assertEqual(record["rows"], len(self.corpus(out_dir)))
        self.assertEqual(manifest["corpus"]["sha256"], record["sha256"])
        self.assertEqual(manifest["corpus"]["turns"], len(self.corpus(out_dir)))
        self.assertEqual(manifest["corpus"]["file"], "chat-corpus-ship.jsonl")
        self.assertIs(manifest["corpus"]["written"], True)

    def test_tooling_inputs_are_classified_and_never_omitted(self):
        report, out_dir, teacher = self.build()
        manifest = self.manifest(out_dir)
        entries = {entry["id"]: entry for entry in manifest["tooling"]}
        self.assertEqual(set(entries), {s.id for s in bc.TOOLING_SOURCES})
        for source in bc.TOOLING_SOURCES:
            entry = entries[source.id]
            self.assertEqual(set(entry), TOOLING_ENTRY_KEYS, source.id)
            self.assertEqual(entry["license"], source.license)
            self.assertEqual(entry["classification"], source.admissibility)
            self.assertEqual(entry["license_family"],
                             bc.license_family(source.license))
            self.assertEqual(entry["mix"], "none")   # tooling is not a mix input
        # the teacher's participation is the run's own stage evidence
        self.assertGreaterEqual(len(teacher.gec_batches), 1)
        teacher_entry = entries["teacher_gemini_flash_lite"]
        self.assertEqual(teacher_entry["status"], "used")
        self.assertEqual(teacher_entry["counts"]["gec_calls"],
                         report["stages"]["teacher_gec"]["calls"])
        self.assertEqual(teacher_entry["counts"]["gec_cache_entries"],
                         report["stages"]["teacher_gec"]["cache_entries"])
        self.assertIn("gec-cache.jsonl", teacher_entry["derived_artifacts"])
        self.assertEqual(teacher_entry["counts"]["l3_turns_generated"], 0)
        # the tier that did not run says so, rather than being omitted
        self.assertEqual(entries["translation_tier_qwen"]["status"], "not_exercised")
        self.assertIn("translation tier", entries["translation_tier_qwen"]["reason"])
        self.assertEqual(entries["stt_noise_roundtrip"]["counts"]["variants"], 0)
        self.assertEqual(entries["style_spec_artifact"]["status"], "used")
        # the chat golden set is tooling, classified, and EXCLUDED
        self.assertEqual(entries["chat_golden_fixture"]["status"], "excluded")
        self.assertTrue(entries["chat_golden_fixture"]["reason"])

    def test_the_held_out_chat_set_is_recorded_as_excluded(self):
        _, out_dir, _ = self.build()
        manifest = self.manifest(out_dir)
        chat = manifest["held_out"]["chat_golden"]
        self.assertEqual(chat["status"], "excluded")
        self.assertEqual(chat["source_id"], "chat_golden_fixture")
        self.assertEqual(chat["turns"], self.guard.chat_golden_turns)
        self.assertEqual(chat["revision"], self.guard.chat_golden_revision)
        self.assertEqual(chat["sha256"], self.guard.chat_golden_sha256)
        self.assertEqual(chat["exact_dedupe_keys"], len(self.guard.exact_user_keys))
        self.assertIn("EXCLUDED", chat["reason"])
        self.assertIn("never trained on", chat["reason"])
        fixtures = {entry["source_id"]: entry
                    for entry in manifest["held_out"]["eval_fixtures"]}
        self.assertEqual(set(fixtures), {"golden_corpus_fixture",
                                         "emergency_nearmiss_fixture"})
        for entry in fixtures.values():
            self.assertEqual(entry["status"], "excluded")
            self.assertTrue(entry["reason"])
        # ... and the same sources are excluded in the per-source accounting
        for entry in manifest["sources"]:
            if entry["id"] in fixtures:
                self.assertEqual(entry["status"], "excluded")
                self.assertEqual(entry["mix"], "none")
                self.assertEqual(entry["derived_artifacts"], [])

    def test_the_assertion_is_recorded_in_the_manifest_and_the_counters(self):
        report, out_dir, _ = self.build()
        manifest = self.manifest(out_dir)
        assertion = manifest["ship_mix_assertion"]
        self.assertEqual(assertion["verdict"], "pass")
        self.assertIs(assertion["ship_mix_eligible"], True)
        self.assertIs(manifest["ship_mix_eligible"], True)
        self.assertEqual(assertion["license_registry"]["id"], bc.LICENSE_REGISTRY_ID)
        self.assertEqual(
            [entry["id"] for entry in manifest["non_admissible_ship_sources"]],
            list(bc.NON_ADMISSIBLE_SHIP_SOURCE_IDS))
        self.assertEqual(report["provenance"]["ship_mix_eligible"], True)
        self.assertEqual(report["provenance"]["ship_mix_assertion"], assertion)

    def test_the_content_hash_is_recorded_with_the_run_and_pairs_with_the_artifact(self):
        report, out_dir, _ = self.build()
        manifest = self.manifest(out_dir)
        block = report["provenance"]
        self.assertEqual(block["manifest"], bc.MANIFEST_NAME)
        self.assertIn("run directory", block["manifest_location"])
        self.assertEqual(block["content_hash"], manifest["content_hash"])
        self.assertEqual(block["license_registry"]["id"], bc.LICENSE_REGISTRY_ID)
        # recomputed from the document itself: the hash covers the whole record
        body = {key: value for key, value in manifest.items()
                if key not in ("content_hash", "content_hash_scope")}
        expected = hashlib.sha256(
            guards.canonical_json(body).encode("utf-8")).hexdigest()
        self.assertEqual(manifest["content_hash"], expected)
        self.assertIn("content_hash", manifest["content_hash_scope"])
        self.assertIn(manifest["content_hash"][:16], json.dumps(block))

    def test_the_content_hash_is_stable_across_re_emissions(self):
        _, out_a, _ = self.build(out="run/ship")
        _, out_b, _ = self.build(out="run2/ship")
        manifest_a = self.manifest(out_a)
        manifest_b = self.manifest(out_b)
        self.assertEqual(manifest_a["content_hash"], manifest_b["content_hash"])
        # the bytes are the same too: no wall-clock, no absolute path, stable
        # orderings — the hash that pairs the manifest with the gate results
        self.assertEqual(self.manifest_path(out_a).read_bytes(),
                         self.manifest_path(out_b).read_bytes())
        self.assertEqual(manifest_a["corpus"]["sha256"], manifest_b["corpus"]["sha256"])
        self.assertEqual((Path(out_a) / "chat-corpus-ship.jsonl").read_bytes(),
                         (Path(out_b) / "chat-corpus-ship.jsonl").read_bytes())
        self.assertEqual((Path(out_a) / "chat-corpus-counters.json").read_bytes(),
                         (Path(out_b) / "chat-corpus-counters.json").read_bytes())

    def test_the_manifest_carries_no_user_content(self):
        _, out_dir, _ = self.build(l3_target_turns=11)
        text = self.manifest_path(out_dir).read_text(encoding="utf-8")
        manifest = json.loads(text)
        self.assertEqual(set(manifest), MANIFEST_KEYS)
        for entry in manifest["sources"]:
            self.assertEqual(set(entry), SOURCE_ENTRY_KEYS, entry["id"])
        for entry in manifest["tooling"]:
            self.assertEqual(set(entry), TOOLING_ENTRY_KEYS, entry["id"])
        # no fixture text and no Devanagari codepoint anywhere in the document
        # (the corpus is Devanagari: any turn text leaking in would trip this)
        for value in _USER_CONTENT_TEXTS:
            self.assertNotIn(value, text)
        match = _DEVANAGARI.search(text)
        self.assertIsNone(match, f"Devanagari in the manifest at {match!r}")
        # ... and nothing from the corpus this manifest describes (rows nest
        # the assistant turn: _turn_record emits assistant: {reply, gec, ...})
        for row in self.corpus(out_dir):
            self.assertNotIn(row["user_turn"], text)
            self.assertNotIn(row["assistant"]["reply"], text)
        self.assertNotIn("user_turn", text)
        self.assertNotIn("acceptable_output", text)

    def test_the_manifest_travels_with_the_run_beside_the_gate_results(self):
        _, out_dir, _ = self.build()
        run_dir = Path(out_dir).parent
        manifest_path = self.manifest_path(out_dir)
        # the gate harness appends its evidence to the same run directory
        gate_evidence = run_dir / "chat-gate-evidence.jsonl"
        gate_evidence.write_text(
            json.dumps({"gate": "honorific_agreement", "status": "pass",
                        "provenance_manifest_sha256":
                            self.manifest(out_dir)["content_hash"]}) + "\n",
            encoding="utf-8")
        recorded = json.loads(gate_evidence.read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(recorded["provenance_manifest_sha256"],
                         self.counters(out_dir)["provenance"]["content_hash"])
        self.assertEqual(manifest_path.parent, gate_evidence.parent)
        self.assertIn("binds", self.manifest(out_dir)["pairing"])

    def test_the_dev_mix_manifest_is_emitted_and_records_the_dev_sources(self):
        # first build: the post-edit batches land pending (held out of the mix)
        _, out_dir, _ = self.build(mix="dev", rows=_DEV_SOURCES, out="devrun/dev")
        pending = json.loads((out_dir / "l2-review.json").read_text(encoding="utf-8"))
        self.assertEqual(pending["batches"]["dailydialog#0000"]["status"], "pending")
        # the human spot-check is recorded, then the run is re-emitted
        record = bc.record_spot_check(out_dir, "dailydialog#0000", "tester")
        self.assertEqual(record["status"], "spot_checked")
        report, _, _ = self.build(mix="dev", rows=_DEV_SOURCES, out="devrun/dev")
        path = Path(out_dir).parent / "provenance-manifest.dev.json"
        self.assertTrue(path.is_file())
        manifest = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["mix"], "dev")
        self.assertIs(manifest["ship_mix_eligible"], False)
        self.assertEqual(manifest["ship_mix_assertion"]["verdict"], "not_applicable")
        dev = {entry["id"]: entry for entry in manifest["sources"]}
        self.assertEqual(dev["dailydialog"]["classification"], "dev")
        self.assertEqual(dev["dailydialog"]["license_family"], "CC BY-NC")
        self.assertEqual(dev["dailydialog"]["status"], "used")
        self.assertIs(dev["dailydialog"]["admissible_to_ship"], False)
        self.assertGreaterEqual(dev["dailydialog"]["counts"]["admitted"], 1)
        self.assertIn("layers/L2.jsonl", dev["dailydialog"]["derived_artifacts"])
        self.assertEqual(report["provenance"]["manifest"],
                         "provenance-manifest.dev.json")

    def test_an_absent_source_is_recorded_not_substituted(self):
        _, out_dir, _ = self.build()
        entries = {entry["id"]: entry
                   for entry in self.manifest(out_dir)["sources"]}
        self.assertEqual(entries["soda"]["status"], "absent")
        self.assertIn("soda.jsonl", entries["soda"]["reason"])
        self.assertIn("not substituted", entries["soda"]["reason"])
        self.assertEqual(entries["soda"]["counts"]["admitted"], 0)
        self.assertEqual(entries["soda"]["derived_artifacts"], [])

    def test_the_generated_l3_source_is_recorded_without_a_file(self):
        _, out_dir, _ = self.build()
        entry = next(e for e in self.manifest(out_dir)["sources"]
                     if e["id"] == "synthetic_eldercare")
        self.assertEqual(entry["status"], "not_generated")
        self.assertIn("stages.l3_generation", entry["reason"])
        self.assertIsNone(entry["source_path"])


# ---------------------------------------------------------------------------
# A contaminated ship mix FAILS the build — no artifact is written
# ---------------------------------------------------------------------------

class ShipMixFailureTests(ProvenanceTestCase):
    def test_a_promoted_nc_source_fails_the_build_and_writes_nothing(self):
        registry = _registry_with(mutate={"indic_dialogue_ne":
                                          {"admissibility": "ship"}})
        with self.assertRaises(bc.ProvenanceError) as ctx:
            self.build(rows=dict(_SHIP_SOURCES, indic=INDIC), registry=registry)
        error = ctx.exception
        kinds = [violation["kind"] for violation in error.violations]
        self.assertIn("non_admissible_source_promoted", kinds)
        promoted = next(v for v in error.violations
                        if v["kind"] == "non_admissible_source_promoted")
        self.assertEqual(promoted["source"], "indic_dialogue_ne")
        self.assertIn("CC BY-NC", promoted["license"])
        self.assertIn("indic_dialogue_ne", str(error))
        self.assertIn("CC BY-NC", str(error))
        # no artifact: neither the corpus nor the manifest exists
        run_dir = self.tmp / "run"
        self.assertFalse((run_dir / "ship" / "chat-corpus-ship.jsonl").exists())
        self.assertFalse((run_dir / bc.MANIFEST_NAME).exists())

    def test_an_unclassified_present_source_fails_the_build(self):
        registry = _registry_with(mutate={"oasst1": {"admissibility": ""}})
        with self.assertRaises(bc.ProvenanceError) as ctx:
            self.build(registry=registry)
        self.assertEqual([v["kind"] for v in ctx.exception.violations],
                         ["missing_classification"])
        self.assertIs(ctx.exception.record["ship_mix_eligible"], False)

    def test_the_cli_exits_5_and_records_the_rejected_artifact(self):
        out = self.tmp / "dirty" / "ship"
        registry = _registry_with(mutate={"call_center_transcripts":
                                          {"admissibility": "ship"}})
        err = io.StringIO()
        with _patched(registry), contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            rc = bc.main(["--mix", "ship", "--out-dir", str(out),
                          "--run-id", "t180-dirty", "--l3-target-turns", "0",
                          "--noise-backend", "none"])
        self.assertEqual(rc, bc.EXIT_PROVENANCE)
        message = err.getvalue()
        self.assertIn("[provenance] FAILED", message)
        self.assertIn("call_center_transcripts", message)
        self.assertIn("research-gated", message)
        self.assertIn("ship-mix eligibility", message)
        counters = self.counters(out)
        self.assertIs(counters["stopped"], True)
        self.assertIs(counters["provenance"]["ship_mix_eligible"], False)
        self.assertEqual(counters["provenance"]["phase"], "preflight")
        violation = counters["provenance"]["violations"][0]
        self.assertEqual(violation["source"], "call_center_transcripts")
        self.assertIn("research-gated", violation["license"])
        self.assertFalse((out / "chat-corpus-ship.jsonl").exists())
        self.assertFalse((out.parent / bc.MANIFEST_NAME).exists())

    def test_the_cli_documents_the_provenance_exit_code(self):
        parser = bc.build_parser()
        actions = {action.dest: action for action in parser._actions}
        self.assertIn("manifest_out", actions)
        self.assertIn(str(bc.EXIT_PROVENANCE), bc.__doc__)


# ---------------------------------------------------------------------------
# The CLI end-to-end: the manifest is written where the run's evidence lives
# ---------------------------------------------------------------------------

class CliEndToEndTests(ProvenanceTestCase):
    def test_recorded_replay_writes_the_manifest_into_the_run_directory(self):
        # 1. record every prompt the offline transport must replay
        _write_sources(self.src_root, _SHIP_SOURCES)
        recorder = RecordingTeacher(FakeTeacher())
        _, recorded_out, _ = self.build(teacher=recorder, out="record/run/ship")
        fixture = self.tmp / "teacher-fixture.jsonl"
        recorder.write_fixture(fixture)
        self.assertGreaterEqual(len(recorder.records), 1)

        # 2. replay through the CLI into a fresh run directory
        out = self.tmp / "cli-run" / "ship"
        with contextlib.redirect_stdout(io.StringIO()):
            rc = bc.main(["--mix", "ship", "--source-root", str(self.src_root),
                          "--out-dir", str(out), "--run-id", "t180-cli",
                          "--l3-target-turns", "0", "--noise-backend", "none",
                          "--teacher-transport", "teacher-fixture",
                          "--teacher-fixture", str(fixture)])
        self.assertEqual(rc, guards.EXIT_FLOOR)      # floors recorded; run completed
        manifest_path = out.parent / bc.MANIFEST_NAME
        self.assertTrue(manifest_path.is_file())
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["run_id"], "t180-cli")
        self.assertEqual(manifest["mix"], "ship")
        # the manifest describes the corpus the CLI actually wrote
        corpus = out / "chat-corpus-ship.jsonl"
        self.assertEqual(manifest["corpus"]["sha256"],
                         hashlib.sha256(corpus.read_bytes()).hexdigest())
        counters = self.counters(out)
        self.assertEqual(counters["provenance"]["content_hash"],
                         manifest["content_hash"])
        self.assertIs(counters["provenance"]["ship_mix_eligible"], True)
        # the replay is offline and deterministic: same corpus as the recording
        self.assertEqual(_read_jsonl(corpus),
                         _read_jsonl(Path(recorded_out) / "chat-corpus-ship.jsonl"))
        # ... and the same corpus is the same artifact hash in both manifests
        self.assertEqual(self.manifest(recorded_out)["corpus"]["sha256"],
                         manifest["corpus"]["sha256"])

    def test_the_cli_refuses_a_contaminated_registry_before_any_spend(self):
        """The failure path with NO source files at all.

        The preflight fires from the registry alone: nothing is read, no teacher
        call is made, and the run still records the compliance event.
        """
        out = self.tmp / "pin-only" / "ship"
        registry = _registry_with(mutate={"call_center_transcripts":
                                          {"admissibility": "ship"}})
        err = io.StringIO()
        with _patched(registry), contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            rc = bc.main(["--mix", "ship", "--source-root", str(self.tmp / "empty"),
                          "--out-dir", str(out), "--run-id", "t180-pin",
                          "--l3-target-turns", "0", "--noise-backend", "none"])
        self.assertEqual(rc, bc.EXIT_PROVENANCE)
        self.assertIn("call_center_transcripts", err.getvalue())
        self.assertIn("research-gated", err.getvalue())
        self.assertFalse((out / "chat-corpus-ship.jsonl").exists())
        self.assertFalse((out.parent / bc.MANIFEST_NAME).exists())


# ---------------------------------------------------------------------------
# The CLI in a subprocess (one genuine process-boundary check)
# ---------------------------------------------------------------------------

class CliSubprocessTests(unittest.TestCase):
    def test_plan_reports_the_ship_mix_rule_and_the_manifest(self):
        done = subprocess.run(
            [sys.executable, str(ROOT / "src" / "build_chat_corpus.py"), "--plan"],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(done.returncode, guards.EXIT_OK)
        self.assertEqual(done.stderr, "")
        self.assertIn("admissible licence families (FR-CNR-018)", done.stdout)
        self.assertIn("CC-BY, Apache-2.0, MIT, synthetic, own data", done.stdout)
        self.assertIn("never admissible to ship", done.stdout)
        self.assertIn("indic_dialogue_ne", done.stdout)
        self.assertIn("CC BY-NC 3.0 (research-only)", done.stdout)
        self.assertIn("research-gated", done.stdout)
        self.assertIn("OK", done.stdout)
        self.assertIn(bc.MANIFEST_NAME, done.stdout)
        self.assertIn(f"exit {bc.EXIT_PROVENANCE}", done.stdout)


if __name__ == "__main__":
    unittest.main()
