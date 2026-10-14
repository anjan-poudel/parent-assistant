"""T-179 — the four-layer chat corpus builder (v17 chat variant).

Builds the Nepali conversation corpus the v17 chat variant trains on
(FR-CNR-016, FR-CNR-017; design-l1 §11.1–11.2), in four layers:

  L1  native Nepali conversation (style anchors, grammar ground truth):
      IndicDialogue Nepali, the research-gated call-center transcriptions,
      Devanagari-Ecommerce; the optional nepali-sft sets are classified
      unclassified and are refused until their licence is recorded.
  L2  translated + post-edited English dialogue: research-only sets
      (DailyDialog, PersonaChat/ConvAI2, EmpatheticDialogues) and
      commercial-safe sets (Taskmaster, SODA, ProsocialDialog, OASST1),
      machine-translated en->ne by the project's translation tier, then
      teacher post-edited with the style spec + Layer-1 exemplars, then
      the automatic filters, then a HUMAN SPOT-CHECK. An unreviewed
      post-edit batch is held out of the mixture until reviewed.
  L3  teacher-generated synthetic elderly-care dialogue, persona-grounded
      in the style spec's repertoire, ~10–20k turns (design §11.1).
  L4  retention claw-back (~30% of the mixture — the intent-regression
      mitigation, design §11.1): the suite's existing intent training
      material (data/teacher.jsonl, data/noised.jsonl,
      data/edge_cases.jsonl — where the abstention/honesty edge classes
      and the light instruction rows live), plus STT-noised user turns at
      the suite's existing 60% rate (config.yaml mixture.stt_noised,
      `src/stt_noise.py`).

CRITICAL RECORDED DEVIATION — the claw-back's eval fixtures
-----------------------------------------------------------
The design and the proposal name `eval/golden_corpus.jsonl` and
`eval/emergency_nearmiss.jsonl` as claw-back sources. Those files are the
suite's HELD-OUT EVAL SET (eval_golden.py: "The corpus is HELD OUT —
build_dataset.py refuses to train on it"), and the suite's own guard module
says it plainly: `pipeline_guards.assert_not_golden_input` — "no stage may be
pointed at the eval set, whatever the reason". Training the v17 candidate on
the very fixtures the non-negotiable gates (emergency recall 1.00, abstention
>=0.90, closed-intent >=0.95) read would turn those gates into memorization
checks — a safety event, not a corpus choice.

So this builder refuses them, twice, and counts the refusal:

  * source-level — a source entry whose path IS one of the eval fixtures is
    refused by `pipeline_guards.assert_not_golden_input` / the fixture check
    below; it contributes 0 candidates and the refusal is recorded per source;
  * row-level — EVERY candidate from EVERY layer is checked against the
    normalize-skeleton keys of all three fixtures (golden corpus, emergency
    near-miss, chat golden) and against the chat golden set's exact dedupe
    keys (`author_chat_golden.held_out_keys()`, the admission-dedupe input);
    a collision is an exclusion under `held_out_eval_fixture` /
    `held_out_user_turn` / `held_out_reply`, never an admission.

The retention function of L4 is carried by the suite's existing *training*
material (the `intent_training` and `abstain_honesty` sources), which is what
the current model's intent behaviour was actually learned from. The deviation
is written into every run's counters (`deviations`), never left to a note.

Mixture, determinism, and honesty rules
---------------------------------------
* Mixture: 70% conversation (L1+L2+L3) / 30% claw-back (L4) — the
  intent-regression mitigation, not a preference. The builder records TARGET
  and ACHIEVED counts, per layer, and never silently re-balances: the target
  ratio is preserved by sampling the surplus side down (the build_dataset.py
  discipline); a side that cannot fill its share is recorded as a shortfall
  with a reason, and the achieved mixture is reported beside the target.
* Filters: the spec-driven checks execute `author_chat_golden.mechanical_review`
  — one rule, one source (`style_spec.py` reads the seeds artifact; this module
  never re-authors a lexicon). Per-rule rejection counts are recorded. An
  unavailable filter (spec fails to load, held-out guard cannot load) STOPS the
  run — nothing is admitted unfiltered.
* Teacher GEC: every assistant turn passes the teacher grammar-correction
  stage (`gemini-2.5-flash-lite` discipline from config.yaml) BEFORE admission;
  the stage is resumable through a content-hash cache (a re-run does not repay
  for completed batches) and its call count, cache hits, token usage and budget
  are reported. A turn the stage did not correct is HELD, never admitted.
* Dev/ship split is a first-class build parameter (`--mix ship|dev`): the
  source registry carries each source's admissibility; CC BY-NC sets and the
  research-gated call-center transcripts enter the DEV mix only and are refused
  from the ship mix (exclusion `dev_only_source`, counted); an unclassified
  source is refused from BOTH mixes (`unclassified_source`). T-180's manifest
  re-asserts the same separation; this builder keeps the layers separable and
  emits the per-source accounting the manifest consumes.
* Determinism: same inputs -> byte-identical corpus files and counters. No
  wall-clock values are written into the corpus or its counters; sampling uses
  the configured seed (config.yaml mixture.seed).

Source interchange formats (what the training box prepares)
-----------------------------------------------------------
Every source file is JSONL. The builder reads two shapes:

  dialogue row    {"dialogue_id": "d001",
                   "turns": [{"speaker": "elder"|"assistant", "text": "..."}, ...]}
                  (optional "language": "ne"|"en"; L2 rows are English)
  pair row        {"user_turn": "...", "reply": "...", "context": [...]?,
                   "id": "..."?}
  intent row (L4) {"id": ..., "utterance": "...", "reply": "...",
                   "action"|"intent": "...", "confidence": 0.0-1.0?,
                   "slots": {...}?, "source"?: "...", "clean_utterance"?: "..."}

A dialogue yields one candidate per assistant turn that follows an elder turn
(the preceding turns up to MAX_CONTEXT_ENTRIES become the turn's context).
An intent row yields one candidate; a row without a `reply` is rejected
(`missing_reply`). The preparation of the named public datasets into these
files is a training-box step (T-183); this builder never downloads anything.

CLI (run from tools/train-intent/)::

    python3 src/build_chat_corpus.py --mix ship            # build the ship mix
    python3 src/build_chat_corpus.py --mix dev             # build the dev mix
    python3 src/build_chat_corpus.py --plan                # print registry+plan
    python3 src/build_chat_corpus.py --record-spot-check BATCH --reviewer NAME
    python3 src/build_chat_corpus.py --teacher-fixture FILE  # offline replay

Exit codes (pipeline_guards vocabulary): 0 ok; 1 a stage failed; 2 usage;
3 the run STOPPED (an unavailable filter / held-out guard — a deviation was
recorded and nothing was admitted unfiltered); 4 the data floors are not met
(the run completed, the shortfalls are recorded — the caller decides).

No user content anywhere: sources are licensed public corpora, synthetic
teacher output, or the suite's own synthetic fixtures (FR-CNR-018).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
SRC = ROOT / "src"
EVAL = ROOT / "eval"
for _path in (str(SRC), str(EVAL)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import style_spec  # noqa: E402  (the ONLY source of the lexicons)
import author_chat_golden as chat_golden  # noqa: E402  (the held-out seam + review)
import pipeline_guards as guards  # noqa: E402  (the suite's leak-guard vocabulary)
from build_dataset import lossless_key, normalize  # noqa: E402  (the suite's keys)

__all__ = [
    "SCHEMA_ID",
    "LAYERS",
    "CONVERSATION_LAYERS",
    "CLAWBACK_LAYER",
    "CONVERSATION_SHARE",
    "CLAWBACK_SHARE",
    "TOTAL_TURNS_TARGET",
    "L3_TARGET_TURNS",
    "SourceSpec",
    "SOURCE_REGISTRY",
    "TOOLING_SOURCES",
    "sources_for_layer",
    "BuildStopped",
    "BuildOptions",
    "HeldOutGuard",
    "apply_filters",
    "word_tokens",
    "rough_token_estimate",
    "assemble_mixture",
    "render_rules",
    "build_chat_corpus",
    "record_spot_check",
    "main",
]

SCHEMA_ID = "chat_corpus/v1"

#: The design's layer ids (§11.1). L4 is the claw-back.
LAYERS: Tuple[str, ...] = ("L1", "L2", "L3", "L4")
LAYER_TITLE: Dict[str, str] = {
    "L1": "native Nepali conversation",
    "L2": "translated + post-edited English dialogue",
    "L3": "teacher-generated synthetic elderly-care dialogue",
    "L4": "retention claw-back",
}
CONVERSATION_LAYERS: Tuple[str, ...] = ("L1", "L2", "L3")
CLAWBACK_LAYER = "L4"

#: The mixture (design §11.1; FR-CNR-016): 70% conversation / 30% claw-back.
#: This IS the intent-regression mitigation — recorded constants, never
#: re-derived at run time.
CONVERSATION_SHARE = 0.70
CLAWBACK_SHARE = 0.30

#: Corpus size targets. The design's band is ~30–60k clean turns; the
#: midpoint is the plan, and the per-layer targets below come from the
#: design's own numbers where it names them:
#:   L3 ~10–20k turns  (band floor is the target)
#:   L4 ~30% of the mix
#: L1/L2 have no named turn targets — they are supply-driven and report
#: achieved counts only.
TOTAL_TURNS_TARGET = 40_000
L3_TARGET_TURNS = 10_000
L4_TARGET_TURNS = int(round(TOTAL_TURNS_TARGET * CLAWBACK_SHARE))

LAYER_TARGETS: Dict[str, Optional[int]] = {
    "L1": None, "L2": None, "L3": L3_TARGET_TURNS, "L4": L4_TARGET_TURNS,
}
LAYER_TARGET_RATIONALE: Dict[str, str] = {
    "L1": "supply-driven: the design names sources, not a turn target",
    "L2": "supply-driven: the design names sources, not a turn target",
    "L3": f"design band ~10–20k turns; target = the band floor ({L3_TARGET_TURNS})",
    "L4": f"30% of the {TOTAL_TURNS_TARGET}-turn total target ({L4_TARGET_TURNS})",
}

MIXES: Tuple[str, ...] = ("ship", "dev")
SHIP_MIX = "ship"
DEV_MIX = "dev"

#: A candidate's context window (chat_golden carries 1–2 entries; four keeps
#: a short exchange while staying inside the token ceiling below).
MAX_CONTEXT_ENTRIES = 4

#: Length filter (design §11.2 — a pipeline rule beside the spec checks):
#: a one-word assistant turn is a fragment, not an answer (the pinned golden
#: replies are all longer); the ceiling is the 1,024-token chat budget's other
#: half — the turn's context+user+reply may use at most half of the assembled
#: prompt's budget, the rest belongs to the system text, the buildChat
#: template and generation headroom (NFR-CNR-004; design §11 preamble).
MIN_ASSISTANT_WORD_TOKENS = 2
TURN_TOKEN_CEILING = 512
#: Conservative rough tokenisation for the ceiling (stdlib-only): Devanagari
#: runs roughly one token per two characters on the Nepali-extended base. The
#: estimate is deliberately rough and its purpose is a guard, not a meter —
#: the exact budget check is T-170's mirror check, on the real tokenizer.
CHARS_PER_TOKEN = 2

#: Near-duplicate policy at admission (T-179 owns it; `held_out_keys()` is the
#: exact-match input). Two turns are near-duplicates when their word-token
#: Jaccard overlap is at or above the threshold AND both carry at least the
#: minimum token count — the floor keeps tiny common acknowledgements
#: ("नमस्ते हजुर") from colliding trivially.
NEAR_DUP_JACCARD = 0.80
NEAR_DUP_MIN_TOKENS = 4

#: Teacher GEC stage. Batching keeps the request count modest; temperature is
#: a correction-task override of the paraphrase default (config.yaml carries
#: 0.8 for paraphrase diversity — correction wants determinism), recorded in
#: the run counters. Every entry is a named, reviewable constant.
GEC_BATCH_TURNS = 20
GEC_TEMPERATURE = 0.0
GEC_MAX_CALLS_DEFAULT = 2000

#: L3 generation: turns requested per teacher call and the calls the plan
#: spends per coverage class.
L3_TURNS_PER_CALL = 10
#: L2 post-edit batches: turns per post-edit call.
L2_POSTEDIT_BATCH_TURNS = 20
POST_EDIT_STATUSES = ("pending", "spot_checked", "rejected")

#: STT-noise rate fallback (config.yaml mixture.stt_noised is the recorded
#: source; this constant only covers a config without the key).
STT_NOISE_RATE_DEFAULT = 0.60

_WORD_SPLIT_RE = re.compile(r"[\s।॥,\.!\?;:…\"'“”‘’\(\)\[\]{}<>–—•*・]+")


class BuildStopped(Exception):
    """The run stopped: an unavailable filter / guard. Nothing was admitted."""


# ---------------------------------------------------------------------------
# The source registry — every named source with its licence and mix class
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SourceSpec:
    """One named source: licence, layer, mix class and default path.

    ``admissibility`` is the dev/ship classification the whole build turns on
    (FR-CNR-018): ``ship`` (CC-BY/Apache/MIT/synthetic/own data), ``dev``
    (research-only: CC BY-NC sets, research-gated transcripts), ``unclassified``
    (licence not recorded — refused from BOTH mixes) or ``eval-fixture``
    (held-out eval set — refused from both mixes, with the recorded reason).
    """
    id: str
    layer: str
    license: str
    admissibility: str          # ship | dev | unclassified | eval-fixture
    kind: str                   # dialogue | intent | generated | tooling
    default_path: str           # relative to ROOT; "" for generated sources
    provenance: str             # synthetic | own | third-party | tooling
    component: str = ""         # L4 component id
    refusal_reason: str = ""
    notes: str = ""


SOURCE_REGISTRY: Tuple[SourceSpec, ...] = (
    # -- Layer 1 ------------------------------------------------------------
    SourceSpec(
        id="indic_dialogue_ne", layer="L1",
        license="CC BY-NC 3.0 (research-only)",
        admissibility="dev", kind="dialogue",
        default_path="chat-sources/l1/indic_dialogue_ne.jsonl",
        provenance="third-party",
        notes="9,688 Nepali dialogues; natural dialogue structure, weak register fit"),
    SourceSpec(
        id="call_center_transcripts", layer="L1",
        license="research-gated (CC-BY-tagged; enterprise licence required to ship)",
        admissibility="dev", kind="dialogue",
        default_path="chat-sources/l1/call_center_transcripts.jsonl",
        provenance="third-party",
        notes=("InfoBayAI Nepali call-center corpus ~100–300h transcribed through the "
               "suite's Whisper pipeline on the training box — the only public source "
               "of SPOKEN Nepali register; dev-mix only until licensed (FR-CNR-018)")),
    SourceSpec(
        id="devanagari_ecommerce", layer="L1",
        license="Apache-2.0",
        admissibility="ship", kind="dialogue",
        default_path="chat-sources/l1/devanagari_ecommerce.jsonl",
        provenance="third-party",
        notes="kshitizgajurel/Devanagari-Ecommerce 4,930 rows; task-oriented politeness"),
    SourceSpec(
        id="nepali_sft_himalaya", layer="L1",
        license="unclassified (not recorded)",
        admissibility="unclassified", kind="dialogue",
        default_path="chat-sources/l1/nepali_sft_himalaya.jsonl",
        provenance="third-party",
        notes="optional teacher-cleaned set; refused until its licence is recorded"),
    SourceSpec(
        id="nepali_sft_saugatkafley", layer="L1",
        license="unclassified (not recorded)",
        admissibility="unclassified", kind="dialogue",
        default_path="chat-sources/l1/nepali_sft_saugatkafley.jsonl",
        provenance="third-party",
        notes=("52k Google-translated pairs, mediocre MT quality — teacher-cleaned, "
               "light-weight, licence to be verified")),
    # -- Layer 2 ------------------------------------------------------------
    SourceSpec(
        id="dailydialog", layer="L2", license="CC BY-NC 4.0 (research-only)",
        admissibility="dev", kind="dialogue",
        default_path="chat-sources/l2/dailydialog.jsonl", provenance="third-party",
        notes="research-only English dialogue (dev mix only)"),
    SourceSpec(
        id="personachat_convai2", layer="L2", license="CC BY-NC 4.0 (research-only)",
        admissibility="dev", kind="dialogue",
        default_path="chat-sources/l2/personachat_convai2.jsonl", provenance="third-party",
        notes="research-only persona dialogue (dev mix only)"),
    SourceSpec(
        id="empathetic_dialogues", layer="L2", license="CC BY-NC 4.0 (research-only)",
        admissibility="dev", kind="dialogue",
        default_path="chat-sources/l2/empathetic_dialogues.jsonl", provenance="third-party",
        notes="research-only empathy dialogue (dev mix only)"),
    SourceSpec(
        id="taskmaster", layer="L2", license="CC-BY 4.0",
        admissibility="ship", kind="dialogue",
        default_path="chat-sources/l2/taskmaster.jsonl", provenance="third-party",
        notes="Taskmaster-1/2/3, commercial-safe"),
    SourceSpec(
        id="soda", layer="L2", license="CC-BY 4.0",
        admissibility="ship", kind="dialogue",
        default_path="chat-sources/l2/soda.jsonl", provenance="third-party",
        notes="commercial-safe dialogue"),
    SourceSpec(
        id="prosocial_dialog", layer="L2", license="CC-BY 4.0",
        admissibility="ship", kind="dialogue",
        default_path="chat-sources/l2/prosocial_dialog.jsonl", provenance="third-party",
        notes="commercial-safe dialogue"),
    SourceSpec(
        id="oasst1", layer="L2", license="Apache-2.0",
        admissibility="ship", kind="dialogue",
        default_path="chat-sources/l2/oasst1.jsonl", provenance="third-party",
        notes="commercial-safe assistant dialogue"),
    # -- Layer 3 ------------------------------------------------------------
    SourceSpec(
        id="synthetic_eldercare", layer="L3", license="synthetic (project-generated)",
        admissibility="ship", kind="generated", default_path="",
        provenance="synthetic",
        notes="teacher-generated persona-grounded elderly-care dialogue (design §11.1)"),
    # -- Layer 4 (claw-back components) ------------------------------------
    SourceSpec(
        id="intent_training_teacher", layer="L4", license="own data",
        admissibility="ship", kind="intent", default_path="data/teacher.jsonl",
        provenance="own", component="intent_training",
        notes="the suite's existing intent training rows (the retention material)"),
    SourceSpec(
        id="intent_training_noised", layer="L4", license="own data",
        admissibility="ship", kind="intent", default_path="data/noised.jsonl",
        provenance="own", component="intent_training",
        notes=("the suite's already STT-noised intent rows (stt_noise.py round trip); "
               "rows carrying clean_utterance are not re-noised by the 60% stage")),
    SourceSpec(
        id="abstain_honesty_edge_cases", layer="L4", license="own data",
        admissibility="ship", kind="intent", default_path="data/edge_cases.jsonl",
        provenance="own", component="abstain_honesty",
        notes=("abstention/honesty examples: the abstain_low_confidence and "
               "gibberish_to_none edges plus the round-2 ack/refusal/bare-emergency "
               "fixes — the behaviours the >=0.90 abstention gate measures")),
    SourceSpec(
        id="golden_corpus_fixture", layer="L4",
        license="own data (held-out eval fixture)",
        admissibility="eval-fixture", kind="fixture",
        default_path="eval/golden_corpus.jsonl", provenance="own",
        refusal_reason=(
            "it IS the held-out intent eval set (eval_golden.py corpus contract; "
            "pipeline_guards.assert_not_golden_input refuses it as a training "
            "input 'whatever the reason') — see the module docstring's recorded "
            "deviation"),
    ),
    SourceSpec(
        id="emergency_nearmiss_fixture", layer="L4",
        license="own data (held-out eval fixture)",
        admissibility="eval-fixture", kind="fixture",
        default_path="eval/emergency_nearmiss.jsonl", provenance="own",
        refusal_reason=(
            "the near-miss gate (>=0.98) scores this file; training on it voids "
            "the gate — refused like the golden corpus"),
    ),
)

#: Tooling inputs are classified too (FR-CNR-018; T-180 emits them in the
#: manifest): they feed the build but are not training sources.
TOOLING_SOURCES: Tuple[SourceSpec, ...] = (
    SourceSpec(
        id="teacher_gemini_flash_lite", layer="tooling",
        license="proprietary API (Google Gemini)", admissibility="tooling",
        kind="tooling", default_path="config.yaml", provenance="tooling",
        notes="the recorded teacher (config.yaml gemini block): L2 post-edit, L3, GEC"),
    SourceSpec(
        id="translation_tier_qwen", layer="tooling",
        license="model weights Apache-2.0 (Qwen)", admissibility="tooling",
        kind="tooling", default_path="", provenance="tooling",
        notes="the project's en->ne translation tier, off-device on the training box"),
    SourceSpec(
        id="style_spec_artifact", layer="tooling", license="own data",
        admissibility="tooling", kind="tooling",
        default_path="seeds/nepali-chat-style-spec", provenance="own",
        notes="the single rule source every prompt and filter renders from"),
    SourceSpec(
        id="stt_noise_roundtrip", layer="tooling", license="own data",
        admissibility="tooling", kind="tooling", default_path="config.yaml",
        provenance="tooling",
        notes="piper TTS + the app's bundled Whisper medium-ne (stt_noise.py)"),
    SourceSpec(
        id="chat_golden_fixture", layer="tooling", license="own data (held-out eval fixture)",
        admissibility="eval-fixture", kind="fixture",
        default_path="eval/chat_golden.jsonl", provenance="own",
        refusal_reason=("the held-out chat set: the admission dedupe runs AGAINST it, "
                        "never admits FROM it (FR-CNR-019)"),
    ),
)

SOURCES_BY_ID: Dict[str, SourceSpec] = {s.id: s for s in SOURCE_REGISTRY}
TOOLING_BY_ID: Dict[str, SourceSpec] = {s.id: s for s in TOOLING_SOURCES}


def sources_for_layer(layer: str) -> Tuple[SourceSpec, ...]:
    return tuple(s for s in SOURCE_REGISTRY if s.layer == layer)


# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

@dataclass
class BuildOptions:
    """One build invocation. Every knob is explicit; defaults are recorded."""
    mix: str = SHIP_MIX
    source_root: Path = field(default_factory=lambda: ROOT)
    out_dir: Path = field(default_factory=lambda: ROOT / "build" / "chat-corpus" / "v17")
    run_id: str = "v17"
    seed: int = 42
    limit_per_source: int = 0          # debug/demo: stop after N rows per source
    l3_target_turns: int = L3_TARGET_TURNS
    gec_budget: int = GEC_MAX_CALLS_DEFAULT
    noise_rate: float = STT_NOISE_RATE_DEFAULT
    noise_backend: str = "auto"        # auto | recorded | hf | cli | none
    noise_pairs: Optional[Path] = None
    translation_command: str = ""
    teacher_transport: str = "gemini"  # gemini | openrouter | teacher-fixture
    teacher_fixture: Optional[Path] = None
    execute: bool = True               # False: plan/counters only, no stages

    def resolved_out_dir(self) -> Path:
        return Path(self.out_dir)


# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------

def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def word_tokens(text: str) -> List[str]:
    """Word tokens (whitespace/danda/punctuation separate) — the length unit."""
    return [tok for tok in _WORD_SPLIT_RE.split(text or "") if tok]


def rough_token_estimate(text: str) -> int:
    """A conservative rough token estimate (stdlib only; see CHARS_PER_TOKEN)."""
    return int(math.ceil(len(text or "") / CHARS_PER_TOKEN))


def _jaccard(a: Iterable[str], b: Iterable[str]) -> float:
    left, right = set(a), set(b)
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


# ---------------------------------------------------------------------------
# The style spec and the shared rule-text rendering (one source, no copies)
# ---------------------------------------------------------------------------

_SPEC_CACHE: Dict[str, style_spec.StyleSpec] = {}


def _spec(spec: Optional[style_spec.StyleSpec] = None) -> style_spec.StyleSpec:
    if spec is not None:
        return spec
    if "spec" not in _SPEC_CACHE:
        _SPEC_CACHE["spec"] = style_spec.load()
    return _SPEC_CACHE["spec"]


def render_rules(spec: Optional[style_spec.StyleSpec] = None) -> str:
    """The rule-text block every generation/post-edit/GEC prompt embeds.

    Rendered from the style spec at call time — no prompt text beside the
    spec (design §22: "src/style_spec.py loads the spec at generation time
    and renders rules into every layer-builder and teacher-post-edit prompt").
    """
    resolved = _spec(spec)
    register = resolved.register()
    particles = resolved.particle_budget()
    lexicon = resolved.particle_lexicon()
    shape = resolved.sentence_shape()
    lines: List[str] = [
        f"= NEPALI CHAT STYLE SPEC v{resolved.version} =",
        "",
        "REGISTER",
        resolved.section_text("register"),
        "address pronoun: " + str(register["address_pronoun"]),
        "polite attention marker: " + str(register["attention_marker"]),
        "forbidden address forms: " + ", ".join(register["forbidden_address_forms"]),
        "banned familiar verb forms (use their honorific partner): "
        + ", ".join(register["non_honorific_verb_forms"]),
        "",
        "PARTICLES",
        resolved.section_text("particles"),
        f"budget: at most {particles} particle per reply",
        "particle lexicon: " + ", ".join(lexicon),
        "",
        "SENTENCE SHAPE",
        resolved.section_text("sentence_shape"),
        f"at most {shape.get('max_sentences', 2)} sentences",
        "",
        "SMALL-TALK REPERTOIRE",
        resolved.section_text("small_talk"),
    ]
    for topic in resolved.small_talk_topics():
        lines.append(f"- {topic['nepali']} ({topic['id']}): {topic['gloss']}")
    lines += ["", "CODE-SWITCHED NOUNS (Devanagari renderings, never the Latin spelling)",
              resolved.section_text("code_switch")]
    for noun in resolved.code_switch_nouns():
        lines.append(f"- {noun['spoken']} ({noun['english']}): {noun['gloss']}")
    lines += ["", "FORBIDDEN AI-ISMS — a reply that trips any of these is a defect",
              resolved.section_text("ai_isms")]
    for entry in resolved.forbidden_ai_isms():
        lines.append(f"- {entry['id']}: {entry['description']}")
    lines += ["", "PERSONA (the assistant's voice)", resolved.persona_clause()]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# The held-out guard — the suite's leak discipline, executed at admission
# ---------------------------------------------------------------------------

class HeldOutGuard:
    """The held-out protection: exact keys, skeleton keys, near-duplicate pool.

    Built from the three eval fixtures. ``exact_user_keys`` is
    ``author_chat_golden.held_out_keys()`` VERBATIM (the declared interface —
    the lossless `build_dataset.lossless_key` set the gates' fixture exposes);
    ``skeleton_*`` sets use `build_dataset.normalize`, the suite's leak key
    (`pipeline_guards.golden_keys` reads the same function — never
    re-implemented). The near-duplicate pool holds token sets of the chat
    golden user turns and reference replies for the Jaccard rule.
    """

    def __init__(self, *, exact_user_keys: set, chat_user_skeleton: set,
                 chat_reply_skeleton: set, chat_reply_exact: set,
                 intent_fixture_skeleton: set, near_user: list, near_reply: list,
                 chat_golden_path: Path, chat_golden_sha256: str,
                 chat_golden_revision: str, chat_golden_turns: int,
                 chat_golden_eligible: bool, near_fixture_present: bool,
                 golden_fixture_path: Path) -> None:
        self.exact_user_keys = exact_user_keys
        self.chat_user_skeleton = chat_user_skeleton
        self.chat_reply_skeleton = chat_reply_skeleton
        self.chat_reply_exact = chat_reply_exact
        self.intent_fixture_skeleton = intent_fixture_skeleton
        self.near_user = near_user
        self.near_reply = near_reply
        self.chat_golden_path = chat_golden_path
        self.chat_golden_sha256 = chat_golden_sha256
        self.chat_golden_revision = chat_golden_revision
        self.chat_golden_turns = chat_golden_turns
        self.chat_golden_eligible = chat_golden_eligible
        self.near_fixture_present = near_fixture_present
        self.golden_fixture_path = golden_fixture_path

    # -- construction -------------------------------------------------------

    @classmethod
    def load(cls, *, chat_path: Optional[Path] = None,
             golden_path: Optional[Path] = None,
             nearmiss_path: Optional[Path] = None) -> "HeldOutGuard":
        """Load the guard from the fixtures; fail loudly (BuildStopped).

        The chat golden set is REQUIRED — it is the admission-dedupe input, so
        an unavailable guard STOPS the run rather than admitting unguarded
        turns. The golden corpus is required by the suite's own guard
        (`pipeline_guards.golden_keys` raises when it is missing); the
        near-miss file is guarded when present and its absence is recorded.
        """
        chat_path = Path(chat_path) if chat_path else chat_golden.CHAT_GOLDEN_PATH
        golden_path = Path(golden_path) if golden_path else guards.GOLDEN_CORPUS
        nearmiss_path = (Path(nearmiss_path) if nearmiss_path
                         else ROOT / "eval" / "emergency_nearmiss.jsonl")
        try:
            golden_keys = guards.golden_keys(golden_path)
        except guards.GuardError as exc:
            raise BuildStopped(f"held-out guard unavailable: {exc}") from exc
        # NOTE: the chat golden fixture's human review is still pending
        # (T-178): admission dedupe must NOT gate on require_gate_fixture().
        # The set loads, its keys protect, and eligibility is reported.
        try:
            golden = chat_golden.load(chat_path)
        except chat_golden.ChatGoldenError as exc:
            raise BuildStopped(
                f"held-out chat set unavailable ({chat_path}): {exc}") from exc

        exact_user_keys = chat_golden.held_out_keys(chat_path)
        chat_user_skeleton = {normalize(turn["user_turn"]) for turn in golden.turns}
        chat_reply_skeleton = {normalize(turn["acceptable_output"]) for turn in golden.turns}
        chat_reply_exact = {lossless_key(turn["acceptable_output"]) for turn in golden.turns}

        intent_skeleton = set(golden_keys)
        near_present = nearmiss_path.is_file()
        if near_present:
            for line in nearmiss_path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    intent_skeleton.add(normalize(json.loads(line)["utterance"]))

        near_user, near_reply = [], []
        for turn in golden.turns:
            user_tokens = frozenset(word_tokens(turn["user_turn"]))
            if len(user_tokens) >= NEAR_DUP_MIN_TOKENS:
                near_user.append(user_tokens)
            reply_tokens = frozenset(word_tokens(turn["acceptable_output"]))
            if len(reply_tokens) >= NEAR_DUP_MIN_TOKENS:
                near_reply.append(reply_tokens)

        return cls(
            exact_user_keys=exact_user_keys,
            chat_user_skeleton=chat_user_skeleton,
            chat_reply_skeleton=chat_reply_skeleton,
            chat_reply_exact=chat_reply_exact,
            intent_fixture_skeleton=intent_skeleton,
            near_user=near_user, near_reply=near_reply,
            chat_golden_path=Path(chat_path),
            chat_golden_sha256=chat_golden.content_sha256(chat_path),
            chat_golden_revision=golden.revision,
            chat_golden_turns=len(golden.turns),
            chat_golden_eligible=golden.eligibility()["eligible"],
            near_fixture_present=near_present,
            golden_fixture_path=Path(golden_path),
        )

    # -- the admission checks ----------------------------------------------

    def check_user_turn(self, text: str) -> Optional[Dict[str, str]]:
        """The exclusion for one candidate user turn, or None when allowed."""
        if not text:
            return None
        if lossless_key(text) in self.exact_user_keys:
            return {"rule": "held_out_user_turn",
                    "detail": "exact duplicate of a held-out chat elder turn "
                              "(lossless_key collision)"}
        skeleton = normalize(text)
        if skeleton in self.intent_fixture_skeleton:
            return {"rule": "held_out_eval_fixture",
                    "detail": "normalized-skeleton collision with a held-out eval "
                              "fixture (golden corpus / emergency near-miss)"}
        if skeleton in self.chat_user_skeleton:
            return {"rule": "held_out_user_turn",
                    "detail": "normalized-skeleton duplicate of a held-out chat elder turn"}
        tokens = frozenset(word_tokens(text))
        if len(tokens) >= NEAR_DUP_MIN_TOKENS:
            for golden_tokens in self.near_user:
                overlap = _jaccard(tokens, golden_tokens)
                if overlap >= NEAR_DUP_JACCARD:
                    return {"rule": "held_out_user_turn",
                            "detail": f"near-duplicate of a held-out chat elder turn "
                                      f"(token jaccard {overlap:.2f})"}
        return None

    def check_reply(self, text: str) -> Optional[Dict[str, str]]:
        """The exclusion for one candidate assistant reply, or None."""
        if not text:
            return None
        if lossless_key(text) in self.chat_reply_exact:
            return {"rule": "held_out_reply",
                    "detail": "exact duplicate of a held-out chat reference reply"}
        skeleton = normalize(text)
        if skeleton in self.intent_fixture_skeleton:
            return {"rule": "held_out_eval_fixture",
                    "detail": "normalized-skeleton collision with a held-out eval fixture"}
        if skeleton in self.chat_reply_skeleton:
            return {"rule": "held_out_reply",
                    "detail": "normalized-skeleton duplicate of a held-out chat reply"}
        tokens = frozenset(word_tokens(text))
        if len(tokens) >= NEAR_DUP_MIN_TOKENS:
            for golden_tokens in self.near_reply:
                overlap = _jaccard(tokens, golden_tokens)
                if overlap >= NEAR_DUP_JACCARD:
                    return {"rule": "held_out_reply",
                            "detail": f"near-duplicate of a held-out chat reply "
                                      f"(token jaccard {overlap:.2f})"}
        return None

    def evidence(self) -> Dict[str, Any]:
        return {
            "chat_golden": {
                "path": str(self.chat_golden_path),
                "sha256": self.chat_golden_sha256,
                "revision": self.chat_golden_revision,
                "turns": self.chat_golden_turns,
                "eligible_gate_fixture": self.chat_golden_eligible,
                "note": ("admission does NOT gate on require_gate_fixture(): the "
                         "fixture's human review is pending (T-178) — its keys "
                         "protect either way, and eligibility is reported"),
            },
            "golden_corpus": {"path": str(self.golden_fixture_path),
                              "keys": len(self.intent_fixture_skeleton)},
            "nearmiss_guarded": self.near_fixture_present,
            "exact_user_keys": len(self.exact_user_keys),
            "near_dup_policy": {"jaccard": NEAR_DUP_JACCARD,
                                "min_tokens": NEAR_DUP_MIN_TOKENS},
        }


# ---------------------------------------------------------------------------
# The filters (spec-driven via author_chat_golden.mechanical_review + length)
# ---------------------------------------------------------------------------

def apply_filters(user_turn: str, reply: str, context: List[dict],
                  spec: Optional[style_spec.StyleSpec] = None) -> List[Dict[str, Any]]:
    """Every filter violation of one candidate turn ([] = passes).

    The spec-driven checks are executed by ``author_chat_golden.mechanical_review``
    — the SAME function the held-out fixture's own review runs, reading the
    spec's machine blocks. One rule, two (more) execution sites. The pipeline's
    own length rule (design §11.2) is added here: floor + the turn's share of
    the 1,024-token budget.
    """
    resolved = _spec(spec)
    violations: List[Dict[str, Any]] = [
        dict(v) for v in chat_golden.mechanical_review(reply, resolved)["violations"]]
    n_words = len(word_tokens(reply))
    if n_words < MIN_ASSISTANT_WORD_TOKENS:
        violations.append({
            "check": "length",
            "detail": (f"assistant reply carries {n_words} word token(s), below the "
                       f"floor {MIN_ASSISTANT_WORD_TOKENS} — a fragment is not an answer"),
        })
    parts = [entry.get("text", "") for entry in context] + [user_turn, reply]
    estimate = rough_token_estimate("".join(parts))
    if estimate > TURN_TOKEN_CEILING:
        violations.append({
            "check": "length",
            "detail": (f"turn content ~{estimate} tokens > ceiling {TURN_TOKEN_CEILING} "
                       f"(half of the 1,024-token assembled-prompt budget)"),
        })
    return violations


# ---------------------------------------------------------------------------
# Candidates and admission
# ---------------------------------------------------------------------------

@dataclass
class Candidate:
    turn_id: str
    layer: str
    source_id: str
    component: str
    admissibility: str
    context: List[dict]
    user_turn: str
    reply: str
    intent: Optional[dict] = None
    language: str = "ne"
    origin: dict = field(default_factory=dict)
    post_edit_batch: Optional[str] = None
    already_noised: bool = False
    reply_gec: Optional[dict] = None
    selected: bool = False


@dataclass
class Counters:
    """Every number a run reports; the counters file serialises this."""
    candidates: Dict[str, int] = field(default_factory=lambda: {
        "per_layer": {layer: 0 for layer in LAYERS}, "per_source": {},
        "per_component": {}})
    admitted: Dict[str, int] = field(default_factory=lambda: {
        "per_layer": {layer: 0 for layer in LAYERS}, "per_source": {},
        "per_component": {}})
    rejections: Dict[str, int] = field(default_factory=dict)
    held: Dict[str, int] = field(default_factory=dict)
    exclusions: Dict[str, int] = field(default_factory=dict)
    sources: List[dict] = field(default_factory=list)
    stages: Dict[str, Any] = field(default_factory=dict)
    shortfalls: List[dict] = field(default_factory=list)
    deviations: List[dict] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)

    def bump(self, bucket: Dict[str, int], key: str) -> None:
        bucket[key] = bucket.get(key, 0) + 1

    def reject(self, rule: str) -> None:
        self.bump(self.rejections, rule)

    def hold(self, reason: str) -> None:
        self.bump(self.held, reason)


# ---------------------------------------------------------------------------
# Source loading — the interchange formats
# ---------------------------------------------------------------------------

def _read_jsonl(path: Path, limit: int = 0) -> List[Tuple[int, dict]]:
    rows: List[Tuple[int, dict]] = []
    with open(path, encoding="utf-8") as handle:
        for index, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            rows.append((index, json.loads(line)))
            if limit and len(rows) >= limit:
                break
    return rows


def _dialogue_candidates(rows: List[Tuple[int, dict]], source: SourceSpec,
                         path: Path) -> Tuple[List[Candidate], List[dict]]:
    """Convert dialogue/pair rows into candidates (deterministic order)."""
    candidates: List[Candidate] = []
    problems: List[dict] = []
    for line_no, row in rows:
        dialogue_id = str(row.get("dialogue_id") or f"{path.stem}:{line_no}")
        turns = row.get("turns")
        if turns is None:
            if isinstance(row.get("user_turn"), str) and isinstance(row.get("reply"), str):
                turns = [{"speaker": "elder", "text": row["user_turn"]},
                         {"speaker": "assistant", "text": row["reply"]}]
                if row.get("context"):
                    turns = list(row["context"]) + turns
            else:
                problems.append({"line": line_no,
                                 "problem": "row is neither a dialogue nor a pair"})
                continue
        if not isinstance(turns, list) or not turns:
            problems.append({"line": line_no, "problem": "dialogue carries no turns"})
            continue
        for index, turn in enumerate(turns):
            if not isinstance(turn, dict) or turn.get("speaker") != "assistant":
                continue
            if index == 0 or not isinstance(turns[index - 1], dict) \
                    or turns[index - 1].get("speaker") != "elder":
                continue                     # an assistant turn with no elder turn before it
            user_text = str(turns[index - 1].get("text", "")).strip()
            reply = str(turn.get("text", "")).strip()
            if not user_text or not reply:
                problems.append({"line": line_no, "problem": "empty turn text"})
                continue
            context = []
            for prior in turns[max(0, index - 1 - MAX_CONTEXT_ENTRIES):index - 1]:
                if isinstance(prior, dict) and prior.get("speaker") in ("elder", "assistant") \
                        and str(prior.get("text", "")).strip():
                    context.append({"speaker": prior["speaker"],
                                    "text": str(prior["text"]).strip()})
            candidates.append(Candidate(
                turn_id=f"{source.id}:{dialogue_id}:{index}",
                layer=source.layer, source_id=source.id, component=source.component,
                admissibility=source.admissibility, context=context,
                user_turn=user_text, reply=reply,
                language=str(row.get("language") or
                             ("en" if source.layer == "L2" else "ne")),
                origin={"path": str(path), "line": line_no, "dialogue_id": dialogue_id},
            ))
    return candidates, problems


def _intent_candidates(rows: List[Tuple[int, dict]], source: SourceSpec,
                       path: Path) -> Tuple[List[Candidate], List[dict], int]:
    """Convert intent rows into catch candidates (reply required; missing_reply)."""
    candidates: List[Candidate] = []
    problems: List[dict] = []
    missing_reply = 0
    for line_no, row in rows:
        utterance = str(row.get("utterance") or "").strip()
        reply = str(row.get("reply") or "").strip()
        intent = {
            "action": row.get("action") or row.get("intent"),
            "confidence": row.get("confidence"),
            "slots": row.get("slots"),
        } if (row.get("action") or row.get("intent")) else None
        if not utterance:
            problems.append({"line": line_no, "problem": "empty utterance"})
            continue
        if not reply:
            missing_reply += 1
            continue                    # no assistant text -> nothing to GEC/admit
        candidates.append(Candidate(
            turn_id=f"{source.id}:{row.get('id') or f'{path.stem}:{line_no}'}",
            layer=source.layer, source_id=source.id, component=source.component,
            admissibility=source.admissibility, context=[],
            user_turn=utterance, reply=reply, intent=intent,
            language="ne",
            origin={"path": str(path), "line": line_no,
                    "id": row.get("id"), "register": row.get("register"),
                    # a suite-noised row carries its clean utterance so the
                    # admitted turn's provenance is self-contained (the same
                    # field the 60% stage writes on its own variants)
                    "clean_utterance": (str(row["clean_utterance"]).strip()
                                        if row.get("clean_utterance") else None)},
            already_noised=bool(row.get("clean_utterance")),
        ))
    return candidates, problems, missing_reply


# ---------------------------------------------------------------------------
# Teacher stages (GEC, L3 generation, L2 post-edit) — injectable, resumable
# ---------------------------------------------------------------------------

def default_teacher(cfg: dict, transport: str, fixture_path: Optional[Path],
                    pacing: bool = True):
    """The teacher seam: gemini | openrouter | teacher-fixture.

    The transport discipline is ``author_chat_golden``'s (same recorded model
    id, same request pacing via cfg gemini.requests_per_minute); the
    ``teacher-fixture`` transport replays RECORDED responses offline (the
    eval_golden.py ``--backend fixture`` precedent) keyed by the prompt hash,
    and is recorded as a transport substitution in the counters — a missing
    fixture entry is a failed call, never a silent skip.
    """
    fixture: Dict[str, dict] = {}
    if transport == "teacher-fixture":
        if fixture_path is None or not Path(fixture_path).is_file():
            raise BuildStopped(
                f"teacher fixture not found: {fixture_path!r} (the recorded "
                "responses file the transport replays)")
        for line in Path(fixture_path).read_text(encoding="utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                fixture[record["prompt_sha256"]] = record["response"]

    def teacher(prompt: str, cfg_: dict) -> dict:
        if transport == "teacher-fixture":
            key = _sha256_text(prompt)
            if key not in fixture:
                raise chat_golden.ChatGoldenError(
                    f"teacher fixture carries no recorded response for prompt {key[:12]}")
            return fixture[key]
        payload = chat_golden.teacher_call(prompt, cfg_, transport=transport)
        if pacing:
            import time
            time.sleep(60.0 / float(cfg_["gemini.requests_per_minute"]))
        return payload

    return teacher


GEC_PROMPT_HEADER = (
    "You are the grammar-correction stage of a Nepali chat corpus build. For each "
    "assistant reply below, return the SAME reply with any grammar, honorific, "
    "particle-placement, spelling or register defect corrected — minimal edits; "
    "never add, remove or re-order information; never translate; if the reply is "
    "already clean, return it unchanged.")


def build_gec_prompt(texts: Sequence[str], spec: Optional[style_spec.StyleSpec] = None) -> str:
    """The GEC batch prompt — rules rendered from the spec, never re-authored."""
    lines = [GEC_PROMPT_HEADER, "", render_rules(spec), "",
             "= TASK =",
             "Output ONLY a JSON object whose \"turns\" key holds one object per "
             "input reply, in order:", '{"turns": [{"i": <0-based index>, '
             '"corrected": "<corrected reply>"}]}']
    for index, text in enumerate(texts):
        lines.append(f"[{index}] {text}")
    return "\n".join(lines)


class GecStage:
    """Teacher GEC over every assistant turn before admission.

    Resumable: a content-hash cache keyed by (model, spec sha256, text) means a
    re-run does not repay for completed batches — cached batches are served
    from disk and counted as cache hits. A budget caps the calls of one run;
    turns beyond the budget are HELD (never admitted uncorrected).
    """

    def __init__(self, cache_path: Path, *, budget: int, model: str,
                 temperature: float, teacher: Callable[[str, dict], dict],
                 cfg: dict, batch_turns: int = GEC_BATCH_TURNS,
                 transport: str = "gemini") -> None:
        self.cache_path = Path(cache_path)
        self.budget = int(budget)
        self.model = model
        self.temperature = float(temperature)
        self.teacher = teacher
        self.cfg = cfg
        self.batch_turns = int(batch_turns)
        self.transport = transport
        self.cache: Dict[str, dict] = {}
        if self.cache_path.is_file():
            for line in self.cache_path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    record = json.loads(line)
                    self.cache[record["key"]] = record
        self.calls = 0
        self.cache_hits = 0
        self.usage: Dict[str, int] = {}
        self.refusals: List[dict] = []
        self.budget_exhausted = False

    def key_for(self, text: str, spec_sha256: str) -> str:
        return _sha256_text(f"{self.model}\x00{spec_sha256}\x00{text}")

    def correct(self, texts: Sequence[str], spec_sha256: str,
                log=print) -> List[Optional[Tuple[str, bool]]]:
        """Correct replies; ``(corrected, from_cache)`` per text, None = no result."""
        results: List[Optional[Tuple[str, bool]]] = [None] * len(texts)
        pending: List[int] = []
        keys: List[str] = []
        for index, text in enumerate(texts):
            key = self.key_for(text, spec_sha256)
            keys.append(key)
            record = self.cache.get(key)
            if record is not None:
                self.cache_hits += 1
                results[index] = (record["corrected"], True)
            else:
                pending.append(index)
        for start in range(0, len(pending), self.batch_turns):
            chunk = pending[start:start + self.batch_turns]
            if self.calls >= self.budget:
                self.budget_exhausted = True
                self.refusals.append({
                    "reason": "gec budget exhausted",
                    "detail": f"{len(pending) - start} turn(s) left uncorrected"})
                break
            prompt = build_gec_prompt([texts[i] for i in chunk])
            self.calls += 1
            try:
                payload = self.teacher(prompt, self.cfg)
            except Exception as exc:  # noqa: BLE001 — recorded, never hidden
                self.refusals.append({"reason": "teacher call failed",
                                      "detail": f"{type(exc).__name__}: {exc}"})
                log(f"[gec]   call failed: {type(exc).__name__}: {str(exc)[:160]}")
                continue
            for name, value in (payload.get("usage") or {}).items():
                self.usage[name] = self.usage.get(name, 0) + int(value)
            corrected_by_index: Dict[int, str] = {}
            for entry in payload.get("turns") or []:
                if not isinstance(entry, dict):
                    continue
                index = entry.get("i")
                corrected = entry.get("corrected")
                if not isinstance(index, int) or not isinstance(corrected, str):
                    continue
                if index < 0 or index >= len(chunk):
                    continue
                if not corrected.strip():
                    continue
                corrected_by_index[index] = corrected.strip()
            for offset, original_index in enumerate(chunk):
                corrected = corrected_by_index.get(offset)
                if corrected is None:
                    self.refusals.append({
                        "reason": "no correction in the teacher response",
                        "detail": texts[original_index][:120]})
                    continue
                record = {
                    "key": keys[original_index],
                    "model": self.model,
                    "temperature": self.temperature,
                    "text": texts[original_index],
                    "corrected": corrected,
                    "changed": corrected != texts[original_index],
                }
                self.cache[keys[original_index]] = record
                results[original_index] = (corrected, False)
        self._flush()
        return results

    def _flush(self) -> None:
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        ordered = sorted(self.cache.values(), key=lambda rec: rec["key"])
        payload = "".join(json.dumps(rec, ensure_ascii=False) + "\n" for rec in ordered)
        self.cache_path.write_text(payload, encoding="utf-8")

    def report(self) -> Dict[str, Any]:
        return {
            "model": self.model,
            "temperature": self.temperature,
            "transport": self.transport,
            "batch_turns": self.batch_turns,
            "budget_calls": self.budget,
            "calls": self.calls,
            "cache_hits": self.cache_hits,
            "cache_entries": len(self.cache),
            "usage": dict(self.usage),
            "refusals": list(self.refusals),
            "budget_exhausted": self.budget_exhausted,
            "executed": self.calls > 0 or self.cache_hits > 0,
        }


def build_l3_prompt(spec: style_spec.StyleSpec, class_entry: dict, count: int,
                    exclude: Optional[Sequence[str]] = None,
                    batch_id: str = "") -> str:
    """The L3 synthetic-dialogue prompt — rules and class from the spec.

    ``batch_id`` names the generation batch so two calls for the same class are
    distinct prompts (a resume keyed on the batch id never mistakes one for the
    other, and a recorded-fixture transport can replay them separately).
    """
    lines = [
        "You are authoring synthetic training conversations for Sahayak, a warm "
        "Nepali voice assistant for elderly Nepali speakers. The style spec below "
        "is the single source of truth — follow it exactly.",
        "", "= STYLE SPEC =", render_rules(spec), "",
        "= THIS BATCH =",
        f"batch id: {batch_id}",
        f"conversation class: {class_entry['id']} — {class_entry['gloss']}",
        f"a spec example of this class: {class_entry['example']}",
        "",
        "Ground each conversation in ordinary elderly-care life: medicines taken, "
        "health talk, family news, food, weather, memories, or quiet loneliness. "
        "Use only synthetic household details (छोरा, छोरी, नाति and common first "
        "names): no real people, no phone numbers, no addresses. Write every "
        "number, time, money and percent as WORDS.", "",
        "= TASK =",
        f"Produce exactly {count} chat turns for this class, each an independent "
        "short exchange.",
    ]
    if exclude:
        lines += ["", "Do NOT reuse these elder turns already produced:"] + \
            [f"- {text}" for text in exclude]
    lines += [
        "",
        "Output ONLY a JSON object whose \"turns\" key holds the array, one object "
        "per turn:",
        '{"turns": [{"user_turn": "...", "context": [], "acceptable_output": "...",',
        '            "note": "..."}]}',
    ]
    return "\n".join(lines)


def build_postedit_prompt(spec: style_spec.StyleSpec,
                          pairs: Sequence[Tuple[str, str]],
                          exemplars: Sequence[Tuple[str, str]]) -> str:
    """The L2 teacher post-edit prompt (spec + L1 exemplars, never a local rule)."""
    lines = [
        "You are post-editing a machine translation of English dialogue into Nepali "
        "for Sahayak's elderly-care chat corpus. Rewrite each assistant reply so it "
        "obeys the style spec exactly (register, particles, length, no AI-isms) and "
        "reads as natural spoken Nepali; never change the facts of the reply. Leave "
        "the elder's turn as it is.", "",
        "= STYLE SPEC =", render_rules(spec)]
    if exemplars:
        lines += ["", "= REAL-EXEMPLARS (Layer-1 style anchors) ="]
        for user_text, reply_text in exemplars:
            lines += [f"elder: {user_text}", f"assistant: {reply_text}"]
    else:
        lines += ["", "= REAL-EXEMPLARS = (none available in this build; recorded "
                      "in the run counters)"]
    lines += ["", "= TASK =",
              "Output ONLY a JSON object whose \"turns\" key holds one object per "
              "pair, in order:",
              '{"turns": [{"i": <0-based index>, "reply": "<post-edited Nepali reply>"}]}',
              ""]
    for index, (user_text, reply_text) in enumerate(pairs):
        lines += [f"[{index}] elder: {user_text}", f"    translation: {reply_text}"]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# The mixture
# ---------------------------------------------------------------------------

def _sample_indices(count: int, take: int, rng: random.Random) -> List[int]:
    if take >= count:
        return list(range(count))
    return sorted(rng.sample(range(count), take))


def assemble_mixture(conversation: List[Candidate], clawback: List[Candidate],
                     *, seed: int, log=print) -> Dict[str, Any]:
    """Select the 70/30 mixture, preserving the target ratio; report achieved.

    The target ratio is the mitigation (design §11.1) and is never changed at
    run time: the SURPLUS side is sampled down so the ratio holds, exactly the
    `build_dataset.py` discipline ("the scarce supply anchors the total, the
    other side is capped by supply and the delta is flagged"). Both pools are
    ordered deterministically before sampling; selection is seeded.
    """
    conversation = sorted(conversation, key=lambda c: c.turn_id)
    clawback = sorted(clawback, key=lambda c: c.turn_id)
    conv_n, claw_n = len(conversation), len(clawback)
    rng = random.Random(seed)
    notes: List[str] = []
    if conv_n == 0 or claw_n == 0:
        conv_take, claw_take = conv_n, claw_n
        notes.append("degenerate mixture: " +
                     ("no conversation turns" if conv_n == 0 else "no claw-back turns")
                     + " — the available side is taken whole and the ratio shortfall "
                       "is reported; the target ratio is unchanged")
    elif conv_n * CLAWBACK_SHARE <= claw_n * CONVERSATION_SHARE:
        conv_take = conv_n
        claw_take = min(claw_n, int(round(conv_n * CLAWBACK_SHARE / CONVERSATION_SHARE)))
        notes.append(f"conversation anchors the mixture (scarce side): all {conv_n} "
                     f"taken; claw-back capped at {claw_take} of {claw_n}")
    else:
        claw_take = claw_n
        conv_take = min(conv_n, int(round(claw_n * CONVERSATION_SHARE / CLAWBACK_SHARE)))
        notes.append(f"claw-back anchors the mixture (scarce side): all {claw_n} taken; "
                     f"conversation capped at {conv_take} of {conv_n}")
    conv_selected = [conversation[i] for i in _sample_indices(conv_n, conv_take, rng)]
    claw_selected = [clawback[i] for i in _sample_indices(claw_n, claw_take, rng)]
    for candidate in conv_selected + claw_selected:
        candidate.selected = True
    total = len(conv_selected) + len(claw_selected)
    achieved = {
        "conversation": len(conv_selected),
        "clawback": len(claw_selected),
        "total": total,
        "conversation_share": (len(conv_selected) / total) if total else 0.0,
        "clawback_share": (len(claw_selected) / total) if total else 0.0,
    }
    return {
        "target": {"conversation_share": CONVERSATION_SHARE,
                   "clawback_share": CLAWBACK_SHARE,
                   "total_turns_target": TOTAL_TURNS_TARGET},
        "ratio_policy": ("the target ratio is preserved by sampling the surplus side "
                         "down; an under-delivering side is reported, never absorbed by "
                         "changing the target"),
        "achieved": achieved,
        "admitted_pools": {"conversation": conv_n, "clawback": claw_n},
        "notes": notes,
    }


# ---------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------

def _source_entry(counters: Counters, source: SourceSpec, path: Path) -> dict:
    entry = {
        "id": source.id, "layer": source.layer, "license": source.license,
        "admissibility": source.admissibility, "kind": source.kind,
        "provenance": source.provenance, "component": source.component,
        "path": str(path), "present": path.is_file(),
        "candidates": 0, "admitted": 0, "refused": None,
    }
    counters.sources.append(entry)
    return entry


def _check_source_refusal(source: SourceSpec, path: Path) -> Optional[str]:
    """The source-level refusal: eval fixtures and unclassified admissibility."""
    if source.admissibility == "eval-fixture":
        return (f"refused: {source.refusal_reason or 'held-out eval fixture'}")
    try:
        guards.assert_not_golden_input(path, f"source {source.id}")
    except guards.GuardError as exc:
        return f"refused: {exc}"
    return None


def _pre_gates(candidate: Candidate, mix: str, counters: Counters) -> bool:
    """Structural / mix gates before any teacher spend. True = keep."""
    if candidate.admissibility == "eval-fixture":
        counters.reject("held_out_eval_fixture")
        return False
    if candidate.admissibility == "unclassified":
        counters.reject("unclassified_source")
        return False
    if mix == SHIP_MIX and candidate.admissibility == "dev":
        counters.reject("dev_only_source")
        return False
    return True


def _stage_l1_l2(opts: BuildOptions, spec: style_spec.StyleSpec, counters: Counters,
                 *, translate: Optional[Callable], teacher, log) -> Tuple[List[Candidate], List[Candidate]]:
    """Read L1/L2 sources; L2 rows pass translation + teacher post-edit.

    Returns (candidates_by_layer[L1], [L2]). L2 post-edit batches are recorded
    in the run's review state; the admission stage holds pending batches out of
    the mixture (design: unreviewed post-edit is flagged, never counted).
    """
    l1: List[Candidate] = []
    l2: List[Candidate] = []
    l2_sources = sources_for_layer("L2") if opts.execute else ()
    l1_sources = sources_for_layer("L1") if opts.execute else ()
    for source in (*l1_sources, *l2_sources):
        path = Path(opts.source_root) / source.default_path
        entry = _source_entry(counters, source, path)
        if source.admissibility == "unclassified":
            entry["refused"] = ("refused from both mixes: licence not recorded "
                                "(T-180's manifest check fails an unclassified source)")
            counters.reject("unclassified_source")
            continue
        if not path.is_file():
            entry["refused"] = None
            counters.notes.append(f"source {source.id} absent at {path} — recorded, "
                                  "not substituted (T-183 training-box item)")
            continue
        refusal = _check_source_refusal(source, path)
        if refusal:
            entry["refused"] = refusal
            if source.admissibility == "eval-fixture":
                counters.reject("held_out_eval_fixture_source")
            continue
        rows = _read_jsonl(path, opts.limit_per_source)
        candidates, problems = _dialogue_candidates(rows, source, path)
        for problem in problems:
            counters.notes.append(f"{source.id} line {problem['line']}: {problem['problem']}")
        if source.layer == "L2" and candidates:
            entry["candidates"] = len(candidates)
            counters.candidates["per_layer"]["L2"] += len(candidates)
            counters.candidates["per_source"][source.id] = len(candidates)
            if opts.mix == SHIP_MIX and source.admissibility == "dev":
                # dev-only dialogue never enters the ship mix — and no teacher
                # spend is made on it on the way to the refusal (the rows are
                # counted, then dropped).
                for _ in candidates:
                    counters.reject("dev_only_source")
                continue
            candidates = _l2_translate_and_post_edit(
                candidates, source, opts, spec, counters, translate=translate,
                teacher=teacher, log=log,
                exemplars=[(c.user_turn, c.reply) for c in l1
                           if c.admissibility == "ship"][:3])
            if opts.execute:
                l2.extend(candidates)
            continue
        entry["candidates"] = len(candidates)
        counters.candidates["per_layer"][source.layer] += len(candidates)
        counters.candidates["per_source"][source.id] = len(candidates)
        if source.layer == "L1" and opts.execute:
            l1.extend(candidates)
    return l1, l2


def _l2_translate_and_post_edit(candidates: List[Candidate], source: SourceSpec,
                                opts: BuildOptions, spec: style_spec.StyleSpec,
                                counters: Counters, *, translate, teacher, log,
                                exemplars: Sequence[Tuple[str, str]] = (),
                                ) -> List[Candidate]:
    """The L2 pipeline: en->ne translation tier, then teacher post-edit.

    Both stages are recorded seams. An unavailable translation tier holds the
    whole source (counted, never replaced by a fabricated translation); the
    post-edit batches land in the run's review state as ``pending`` and the
    admission stage excludes them until a human records the spot-check. The
    post-edit prompt carries the spec's rule text AND Layer-1 style exemplars
    (design §11.2: "with the style spec + Layer-1 exemplars").
    """
    if translate is None and not opts.translation_command:
        counters.notes.append(
            f"L2/{source.id}: translation tier unavailable (no --translation-command "
            f"and no injected translator) — {len(candidates)} row(s) HELD, no "
            "fabricated translation (T-183 training-box item)")
        for _ in candidates:
            counters.hold("translation_unavailable")
        return []
    texts = [c.user_turn for c in candidates]
    translate_fn = translate
    if translate_fn is None:
        translate_fn = lambda batch: _command_translator(  # noqa: E731
            opts.translation_command, batch)
    try:
        translated = translate_fn(texts)
    except Exception as exc:  # noqa: BLE001 — recorded, never hidden
        counters.notes.append(f"L2/{source.id}: translation tier failed "
                              f"({type(exc).__name__}: {exc}) — rows HELD")
        for _ in candidates:
            counters.hold("translation_unavailable")
        return []
    if len(translated) != len(texts):
        counters.notes.append(
            f"L2/{source.id}: translation tier returned {len(translated)} of "
            f"{len(texts)} rows — rows HELD (a short response is not a translation)")
        for _ in candidates:
            counters.hold("translation_unavailable")
        return []
    for candidate, text in zip(candidates, translated):
        candidate.user_turn = str(text).strip()
        candidate.language = "ne"      # the admitted turn is the Nepali translation;
        # the origin records the English source line for provenance

    batches: Dict[str, List[Candidate]] = {}
    for index, candidate in enumerate(candidates):
        key = f"{source.id}#{index // L2_POSTEDIT_BATCH_TURNS:04d}"
        candidate.post_edit_batch = key
        batches.setdefault(key, []).append(candidate)

    review_path = Path(opts.out_dir) / "l2-review.json"
    review_state = _load_review_state(review_path)
    post_ok: List[Candidate] = []
    counters.notes.append(
        f"L2/{source.id}: post-edit prompts carry {len(exemplars)} Layer-1 style "
        "exemplar(s)" if exemplars else
        f"L2/{source.id}: post-edit prompts carry no Layer-1 exemplars in this build "
        "(recorded)")
    for key, batch in sorted(batches.items()):
        if not opts.execute:
            continue
        reply_texts = [c.reply for c in batch]
        prompt = build_postedit_prompt(spec, list(zip(
            [c.user_turn for c in batch], reply_texts)), exemplars=exemplars)
        try:
            payload = teacher(prompt, _teacher_cfg())
        except Exception as exc:  # noqa: BLE001
            counters.notes.append(f"L2/{source.id}: post-edit call for {key} failed "
                                  f"({type(exc).__name__}: {exc}) — batch held")
            counters.hold("postedit_unavailable")
            continue
        edited: Dict[int, str] = {}
        for entry in payload.get("turns") or []:
            if isinstance(entry, dict) and isinstance(entry.get("i"), int) \
                    and isinstance(entry.get("reply"), str) and entry["reply"].strip():
                edited[entry["i"]] = entry["reply"].strip()
        for offset, candidate in enumerate(batch):
            if offset in edited:
                candidate.reply = edited[offset]
            else:
                counters.hold("postedit_unavailable")
                continue
            review_state["batches"].setdefault(key, {
                "status": "pending", "reviewer": None, "recorded_at": None, "note": None})
            post_ok.append(candidate)
    if opts.execute:
        _save_review_state(review_path, review_state)
        counters.stages.setdefault("l2_post_edit", {})[source.id] = {
            "batches": len(batches),
            "turns_post_edited": len(post_ok),
        }
    return post_ok


def _teacher_cfg() -> dict:
    """The recorded teacher configuration (config.yaml gemini block)."""
    from config import load_config
    parser = argparse.ArgumentParser(add_help=False)
    _, cfg = load_config(parser, argv=[])
    return {
        "gemini.model": cfg.get("gemini.model", "gemini-2.5-flash-lite"),
        "gemini.temperature": cfg.get("gemini.temperature", 0.8),
        "gemini.max_output_tokens": cfg.get("gemini.max_output_tokens", 4096),
        "gemini.requests_per_minute": cfg.get("gemini.requests_per_minute", 25.0),
    }


def _command_translator(command: str, texts: Sequence[str]) -> List[str]:
    """Run the translation tier as a subprocess: JSONL on stdin, JSONL out."""
    payload = "".join(json.dumps({"text": text}, ensure_ascii=False) + "\n"
                      for text in texts)
    completed = subprocess.run(command, shell=True, input=payload, text=True,
                               capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"translation command exited {completed.returncode}: "
                           f"{completed.stderr[:200]}")
    out: List[str] = []
    for line in completed.stdout.splitlines():
        if line.strip():
            out.append(str(json.loads(line).get("text", "")))
    return out


def _load_review_state(path: Path) -> dict:
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"schema": "chat_corpus_l2_review/v1", "batches": {}}


def _save_review_state(path: Path, state: dict) -> None:
    guards.write_json(path, state)


def record_spot_check(out_dir: Path, batch: str, reviewer: str,
                      disposition: str = "spot_checked", note: "str | None" = None) -> dict:
    """Record a human spot-check disposition for one L2 post-edit batch."""
    if disposition not in POST_EDIT_STATUSES:
        raise ValueError(f"disposition {disposition!r} not in {POST_EDIT_STATUSES}")
    if not reviewer.strip():
        raise ValueError("a spot-check record needs a reviewer name")
    path = Path(out_dir) / "l2-review.json"
    state = _load_review_state(path)
    if batch not in state["batches"]:
        raise ValueError(
            f"unknown post-edit batch {batch!r} — post-edit must have run before "
            "its spot-check is recorded")
    state["batches"][batch] = {
        "status": disposition, "reviewer": reviewer.strip(),
        "recorded_at": guards.utc_now(), "note": note,
    }
    _save_review_state(path, state)
    return state["batches"][batch]


def _stage_l3(opts: BuildOptions, spec: style_spec.StyleSpec, counters: Counters,
              teacher, log) -> List[Candidate]:
    """L3 teacher generation: plan from the spec's coverage inventory."""
    classes = [dict(entry) for entry in spec.coverage_classes()]
    if not classes:
        raise BuildStopped("style spec carries no coverage classes — nothing to ground L3")
    plan: List[dict] = []
    if opts.l3_target_turns:
        per_class = int(math.ceil(opts.l3_target_turns / len(classes)))
        calls = max(0, int(math.ceil(per_class / L3_TURNS_PER_CALL)))
        for entry in classes:
            for index in range(calls):
                plan.append({"class": entry, "call": index,
                             "key": f"l3:{entry['id']}:{index:04d}"})
    counters.stages["l3_generation"] = {
        "target_turns": opts.l3_target_turns,
        "calls_planned": len(plan),
        "calls_executed": 0,
        "calls_cached": 0,
        "turns_generated": 0,
        "usage": {},
        "executed": False,
    }
    if not opts.execute or not plan:
        return []
    generated_path = Path(opts.out_dir) / "l3-generated.jsonl"
    done: Dict[str, dict] = {}
    if generated_path.is_file():
        for line in generated_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                done[record["key"]] = record
    candidates: List[Candidate] = []
    written: List[dict] = sorted(done.values(), key=lambda rec: rec["key"])
    for entry in plan:
        record = done.get(entry["key"])
        if record is None:
            prompt = build_l3_prompt(spec, entry["class"], L3_TURNS_PER_CALL,
                                     batch_id=entry["key"])
            counters.stages["l3_generation"]["calls_executed"] += 1
            try:
                payload = teacher(prompt, _teacher_cfg())
            except Exception as exc:  # noqa: BLE001
                counters.notes.append(f"L3 call {entry['key']} failed "
                                      f"({type(exc).__name__}: {exc})")
                continue
            for name, value in (payload.get("usage") or {}).items():
                usage = counters.stages["l3_generation"]["usage"]
                usage[name] = usage.get(name, 0) + int(value)
            record = {"key": entry["key"], "class": entry["class"]["id"],
                      "turns": [t for t in (payload.get("turns") or [])
                                if isinstance(t, dict)]}
            written.append(record)
        else:
            counters.stages["l3_generation"]["calls_cached"] += 1
        for index, raw in enumerate(record["turns"]):
            user_text = str(raw.get("user_turn") or "").strip()
            reply = str(raw.get("acceptable_output") or "").strip()
            if not user_text or not reply:
                continue
            context = [c for c in (raw.get("context") or [])
                       if isinstance(c, dict) and c.get("speaker") in ("elder", "assistant")
                       and str(c.get("text", "")).strip()]
            candidates.append(Candidate(
                turn_id=f"synthetic_eldercare:{entry['class']['id']}:{entry['call']:04d}:{index}",
                layer="L3", source_id="synthetic_eldercare", component="",
                admissibility="ship", context=context, user_turn=user_text,
                reply=reply, language="ne",
                origin={"generated_by": "l3", "call": entry["key"],
                        "coverage_class": entry["class"]["id"]},
            ))
    generated_path.parent.mkdir(parents=True, exist_ok=True)
    generated_path.write_text(
        "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in written),
        encoding="utf-8")
    counters.stages["l3_generation"]["turns_generated"] = len(candidates)
    counters.stages["l3_generation"]["executed"] = True
    return candidates


def _stage_l4(opts: BuildOptions, counters: Counters, teacher, log) -> List[Candidate]:
    """L4 claw-back sources: the suite's own intent material + the fixtures.

    The eval fixtures are read only to COUNT the refusal honestly (they are
    refused by the source-level guard); the retention candidates come from the
    suite's existing training material. Rows already carrying a
    ``clean_utterance`` are the suite's own noised variants and are not
    re-noised by the 60% stage.
    """
    candidates: List[Candidate] = []
    for source in sources_for_layer("L4"):
        path = Path(opts.source_root) / source.default_path
        entry = _source_entry(counters, source, path)
        refusal = _check_source_refusal(source, path)
        if refusal:
            entry["refused"] = refusal
            counters.reject("held_out_eval_fixture_source")
            continue
        if not path.is_file():
            counters.notes.append(f"source {source.id} absent at {path} — recorded, "
                                  "not substituted (T-183 training-box item)")
            continue
        rows = _read_jsonl(path, opts.limit_per_source)
        candidates_batch, problems, missing_reply = _intent_candidates(rows, source, path)
        for _ in range(missing_reply):
            counters.reject("missing_reply")
        for problem in problems:
            counters.notes.append(f"{source.id} line {problem['line']}: {problem['problem']}")
        entry["candidates"] = len(candidates_batch) + missing_reply
        counters.candidates["per_layer"]["L4"] += entry["candidates"]
        counters.candidates["per_source"][source.id] = entry["candidates"]
        counters.candidates["per_component"][source.component] = \
            counters.candidates["per_component"].get(source.component, 0) \
            + entry["candidates"]
        candidates.extend(candidates_batch)
    return candidates


def _apply_stt_noise(candidates: List[Candidate], opts: BuildOptions,
                     counters: Counters, noise_fn, log) -> List[Candidate]:
    """Add STT-noised user-turn variants at the suite's existing rate.

    The noised variant keeps the (already GEC'd) assistant reply and records the
    clean utterance; the variant is a NEW turn. An identical round-trip result
    teaches nothing (`stt_noise.py`'s own rule) and is not added.
    """
    eligible = [c for c in candidates if not c.already_noised]
    report = {
        "rate_target": opts.noise_rate,
        "backend": opts.noise_backend,
        "pairs": str(opts.noise_pairs) if opts.noise_pairs else None,
        "eligible": len(eligible),
        "variants": 0,
        "rate_achieved": 0.0,
        "noop": 0,
        "failures": 0,
        "executed": False,
    }
    counters.stages["stt_noise"] = report
    if not opts.execute or not eligible:
        return []
    if noise_fn is None:
        noise_fn = resolve_noise_fn(opts)
    if noise_fn is None:
        if opts.noise_backend == "none":
            counters.notes.append(
                f"STT-noised turns NOT executed (noise backend 'none' — the "
                f"STT-noise stage is disabled for this run); {len(eligible)} L4 "
                "turn(s) stay clean")
        else:
            counters.notes.append(
                f"STT-noised turns NOT executed (noise backend {opts.noise_backend!r} "
                f"unavailable on this host) — {len(eligible)} L4 turn(s) stay clean; "
                "recorded, never fabricated (T-183 training-box item)")
        return []
    report["executed"] = True
    rng = random.Random(opts.seed)
    take = int(round(len(eligible) * float(opts.noise_rate)))
    chosen = [eligible[i] for i in _sample_indices(len(eligible), take, rng)]
    variants: List[Candidate] = []
    for candidate in chosen:
        try:
            noisy = str(noise_fn(candidate.user_turn) or "").strip()
        except Exception as exc:  # noqa: BLE001 — recorded, never hidden
            report["failures"] += 1
            log(f"[noise] {candidate.turn_id}: {type(exc).__name__}: {str(exc)[:120]}")
            continue
        if not noisy or noisy == candidate.user_turn:
            report["noop"] += 1
            continue
        variant = Candidate(
            turn_id=f"{candidate.turn_id}:noise", layer=candidate.layer,
            source_id=candidate.source_id, component=candidate.component,
            admissibility=candidate.admissibility, context=list(candidate.context),
            user_turn=noisy, reply=candidate.reply, intent=candidate.intent,
            language=candidate.language,
            origin=dict(candidate.origin, clean_utterance=candidate.user_turn),
            already_noised=True, reply_gec=candidate.reply_gec,
        )
        variants.append(variant)
    report["variants"] = len(variants)
    report["rate_achieved"] = round(len(variants) / len(eligible), 4)
    return variants


def _noise_roundtrip_available(cfg: dict, backend: str) -> Optional[str]:
    """Which round-trip path is actually available on this host, or None.

    A path is available only when its inputs exist: piper + the voice for the
    synthesis side, and (``cli``) the whisper-cli binary + GGML model, or
    (``hf``) the HF checkpoint directory. ``auto`` prefers cli and falls back
    to hf. A missing toolchain is reported as ``not executed`` — never
    approximated with a fabricated corruption.
    """
    def _path(value) -> Optional[Path]:
        if not value:
            return None
        resolved = Path(str(value)).expanduser()
        return resolved if resolved.is_absolute() else ROOT / resolved

    voice = _path(cfg.get("stt_noise.tts_voice"))
    piper = _path(cfg.get("stt_noise.piper_bin"))
    if not (voice and voice.is_file() and piper and piper.is_file()):
        return None
    cli_ready = bool(
        (_path(cfg.get("stt_noise.whisper_cpp")) or Path("/nonexistent")).is_file()
        and (_path(cfg.get("stt_noise.whisper_model")) or Path("/nonexistent")).is_file())
    hf_value = cfg.get("stt_noise.hf_model")
    hf_ready = bool(hf_value and Path(str(hf_value)).expanduser().is_dir())
    if backend == "cli":
        return "cli" if cli_ready else None
    if backend == "hf":
        return "hf" if hf_ready else None
    return "cli" if cli_ready else ("hf" if hf_ready else None)


def resolve_noise_fn(opts: BuildOptions):
    """The STT-noise backend: recorded pairs / hf / cli / none.

    ``recorded`` applies ONLY recorded (clean -> noisy) pairs (the suite's
    tests/data/stt_pairs shape) when the clean utterance matches exactly — a
    real recorded round-trip result, never a generated corruption. ``hf``/``cli``
    drive the piper->whisper round trip through ``stt_noise.py`` (training-box
    only; unavailable locally => None, recorded).
    """
    backend = opts.noise_backend
    if backend == "none":
        return None
    if backend in ("recorded", "auto") and opts.noise_pairs and Path(opts.noise_pairs).is_file():
        pairs: Dict[str, str] = {}
        for line in Path(opts.noise_pairs).read_text(encoding="utf-8").splitlines():
            if line.strip():
                row = json.loads(line)
                clean = str(row.get("clean_utterance") or "").strip()
                noisy = str(row.get("utterance") or "").strip()
                if clean and noisy and clean != noisy:
                    pairs.setdefault(clean, noisy)
        if not pairs:
            return None
        return lambda text: pairs.get(text, text)
    if backend in ("hf", "cli", "auto"):
        try:
            from config import load_config  # noqa: E402
            import stt_noise  # noqa: E402 — stdlib-only module level; torch stays lazy
            parser = argparse.ArgumentParser(add_help=False)
            _, full_cfg = load_config(parser, argv=[])
        except Exception:  # noqa: BLE001 — the round trip is training-box tooling
            return None
        chosen = _noise_roundtrip_available(full_cfg, backend)
        if chosen is None:
            return None

        def roundtrip(text: str) -> str:
            import tempfile
            with tempfile.TemporaryDirectory() as tmp:
                wav = Path(tmp) / "u.wav"
                stt_noise.synthesize(text, wav, full_cfg)
                if chosen == "cli":
                    return stt_noise.transcribe_cli(wav, full_cfg)
                return stt_noise.make_hf_transcriber(full_cfg)(wav)

        return roundtrip
    return None


# ---------------------------------------------------------------------------
# The whole build
# ---------------------------------------------------------------------------

def build_chat_corpus(opts: BuildOptions, *, spec: Optional[style_spec.StyleSpec] = None,
                      teacher: Optional[Callable] = None,
                      translate: Optional[Callable] = None,
                      noise_fn: Optional[Callable] = None,
                      held_out: Optional[HeldOutGuard] = None,
                      log=print) -> dict:
    """Run the four-layer build and return the counters dict.

    Raises :class:`BuildStopped` when an unavailable filter / guard would force
    admitting unguarded turns — the CLI records the deviation and exits 3.
    """
    if opts.mix not in MIXES:
        raise BuildStopped(f"unknown mix {opts.mix!r} (expected one of {MIXES})")
    counters = Counters()
    try:
        resolved_spec = _spec(spec)
    except style_spec.StyleSpecError as exc:
        raise BuildStopped(f"style spec unavailable — filters cannot run: {exc}") from exc
    if held_out is None:
        held_out = HeldOutGuard.load()
    if teacher is None:
        teacher = default_teacher(_teacher_cfg(), opts.teacher_transport,
                                  opts.teacher_fixture)

    out_dir = Path(opts.resolved_out_dir())
    out_dir.mkdir(parents=True, exist_ok=True)

    log(f"[step] build {opts.run_id} ({opts.mix} mix): style spec "
        f"v{resolved_spec.version} sha256 {resolved_spec.sha256[:12]}…")
    log(f"[step] held-out guard: chat golden {held_out.chat_golden_revision} "
        f"({held_out.chat_golden_turns} turns), exact keys "
        f"{len(held_out.exact_user_keys)}, near-dup jaccard "
        f"{NEAR_DUP_JACCARD} @ >= {NEAR_DUP_MIN_TOKENS} tokens")

    candidates: Dict[str, List[Candidate]] = {layer: [] for layer in LAYERS}
    l1, l2 = _stage_l1_l2(opts, resolved_spec, counters, translate=translate,
                          teacher=teacher, log=log)
    candidates["L1"], candidates["L2"] = l1, l2
    candidates["L3"] = _stage_l3(opts, resolved_spec, counters, teacher, log)
    counters.candidates["per_layer"]["L3"] = len(candidates["L3"])
    log(f"[step] candidates: L1 {len(l1)}, L2 {len(l2)}, L3 {len(candidates['L3'])}")
    candidates["L4"] = _stage_l4(opts, counters, teacher, log)

    # -- pre-gates + collect the turns that need GEC -------------------------
    kept: List[Candidate] = []
    for layer in LAYERS:
        for candidate in candidates[layer]:
            if _pre_gates(candidate, opts.mix, counters):
                kept.append(candidate)
    log(f"[step] pre-gates kept {len(kept)} candidate(s) "
        f"(rejections so far: {dict(sorted(counters.rejections.items()))})")

    # -- teacher GEC: every assistant turn, before admission -----------------
    gec = GecStage(out_dir / "gec-cache.jsonl", budget=opts.gec_budget,
                   model=_teacher_cfg()["gemini.model"], temperature=GEC_TEMPERATURE,
                   teacher=teacher, cfg=_teacher_cfg(),
                   transport=opts.teacher_transport)
    corrected = gec.correct([c.reply for c in kept], resolved_spec.sha256, log=log) \
        if kept else []
    for candidate, result in zip(kept, corrected):
        if result is None:
            counters.hold("gec_missing")
            continue
        text, from_cache = result
        candidate.reply = text
        candidate.reply_gec = {"model": gec.model, "temperature": gec.temperature,
                               "from_cache": from_cache}
    counters.stages["teacher_gec"] = gec.report()
    gec_ok = [c for c in kept if c.reply_gec is not None]
    log(f"[step] teacher GEC: {gec.calls} call(s), {gec.cache_hits} cache hit(s), "
        f"{len(gec_ok)}/{len(kept)} assistant turn(s) corrected")

    # -- filters, held-out dedupe, within-corpus dedupe ----------------------
    admitted: List[Candidate] = []
    seen_keys: set = set()
    for candidate in gec_ok:
        violations = apply_filters(candidate.user_turn, candidate.reply,
                                   candidate.context, resolved_spec)
        if violations:
            for violation in violations:
                counters.reject(violation["check"])
            continue
        exclusion = held_out.check_user_turn(candidate.user_turn) \
            or held_out.check_reply(candidate.reply)
        if exclusion:
            counters.reject(exclusion["rule"])
            counters.bump(counters.exclusions, exclusion["rule"])
            continue
        key = lossless_key(candidate.user_turn)
        if key in seen_keys:
            counters.reject("duplicate_within_corpus")
            continue
        seen_keys.add(key)
        admitted.append(candidate)
    for candidate in admitted:
        counters.admitted["per_layer"][candidate.layer] = \
            counters.admitted["per_layer"].get(candidate.layer, 0) + 1
        counters.admitted["per_source"][candidate.source_id] = \
            counters.admitted["per_source"].get(candidate.source_id, 0) + 1
        if candidate.component:
            counters.admitted["per_component"][candidate.component] = \
                counters.admitted["per_component"].get(candidate.component, 0) + 1
    for entry in counters.sources:
        layer_admitted = [c for c in admitted if c.source_id == entry["id"]]
        entry["admitted"] = len(layer_admitted)
    log(f"[step] admitted {len(admitted)} turn(s): "
        + ", ".join(f"{layer} {counters.admitted['per_layer'].get(layer, 0)}"
                    for layer in LAYERS))

    # -- L2 spot-check gate (pending batches are not counted) ---------------
    l2_review = _load_review_state(out_dir / "l2-review.json")
    for candidate in admitted:
        if candidate.layer != "L2" or not candidate.post_edit_batch:
            continue
        status = (l2_review["batches"].get(candidate.post_edit_batch) or {}).get("status")
        if status != "spot_checked":
            candidate.selected = False
            counters.hold("pending_spot_check")
    pending_batches = sorted(
        key for key, value in l2_review["batches"].items()
        if (value or {}).get("status") == "pending")
    rejected_batches = sorted(
        key for key, value in l2_review["batches"].items()
        if (value or {}).get("status") == "rejected")
    l2_stage = counters.stages.setdefault("l2_spot_check", {})
    l2_stage["pending_batches"] = pending_batches
    l2_stage["rejected_batches"] = rejected_batches
    l2_stage["rule"] = (
        "an unreviewed post-edit batch is flagged pending and is NOT counted toward "
        "the mixture until reviewed (design §11.2); a rejected batch is counted out "
        "for good")
    if pending_batches or rejected_batches:
        counters.notes.append(
            f"{len(pending_batches)} L2 post-edit batch(es) pending human spot-check, "
            f"{len(rejected_batches)} rejected — held out of the mixture, recorded")

    visible = [c for c in admitted if c.layer != "L2"
               or (l2_review["batches"].get(c.post_edit_batch) or {}).get("status")
               == "spot_checked"]

    # -- STT-noise variants (L4 only) ---------------------------------------
    l4_visible = [c for c in visible if c.layer == CLAWBACK_LAYER]
    noised = _apply_stt_noise(l4_visible, opts, counters, noise_fn, log)
    for variant in noised:
        counters.admitted["per_layer"][CLAWBACK_LAYER] = \
            counters.admitted["per_layer"].get(CLAWBACK_LAYER, 0) + 1
        counters.admitted["per_source"][variant.source_id] = \
            counters.admitted["per_source"].get(variant.source_id, 0) + 1
    visible.extend(noised)
    #: the variants ARE admitted turns: keep the layer files and the per-source
    #: accounting consistent with the counters' per_layer/per_source bumps above
    admitted.extend(noised)
    for entry in counters.sources:
        entry["admitted"] = sum(1 for c in admitted if c.source_id == entry["id"])
    if counters.stages.get("stt_noise", {}).get("variants"):
        counters.notes.append(
            f"STT-noised variants: {counters.stages['stt_noise']['variants']} "
            f"(rate {counters.stages['stt_noise']['rate_achieved']} vs target "
            f"{opts.noise_rate})")

    # -- the mixture ---------------------------------------------------------
    conversation = [c for c in visible if c.layer in CONVERSATION_LAYERS]
    clawback = [c for c in visible if c.layer == CLAWBACK_LAYER]
    mixture = assemble_mixture(conversation, clawback, seed=opts.seed, log=log)
    selected = sorted([c for c in conversation + clawback if c.selected],
                      key=lambda c: (c.layer, c.turn_id))
    mixture["selected_per_layer"] = {
        layer: sum(1 for c in selected if c.layer == layer) for layer in LAYERS}
    mixture["clawback_components"] = {
        component: sum(1 for c in selected if c.component == component)
        for component in sorted({c.component for c in clawback if c.component})}
    counters.stages["mixture"] = mixture

    # -- shortfalls (reported, never silently re-balanced) -------------------
    for layer in LAYERS:
        target = LAYER_TARGETS[layer]
        achieved = counters.admitted["per_layer"].get(layer, 0)
        if target is not None and achieved < target:
            counters.shortfalls.append({
                "layer": layer, "target": target, "achieved": achieved,
                "reason": _shortfall_reason(layer, counters),
            })
        elif target is None and achieved == 0:
            counters.shortfalls.append({
                "layer": layer, "target": None, "achieved": 0,
                "reason": _shortfall_reason(layer, counters),
            })
    if mixture["achieved"]["total"] < TOTAL_TURNS_TARGET:
        counters.shortfalls.append({
            "layer": "total", "target": TOTAL_TURNS_TARGET,
            "achieved": mixture["achieved"]["total"],
            "reason": "the assembled mixture is below the ~30–60k target; the "
                      "target ratio is unchanged and the shortfall is reported",
        })

    # -- deviations (recorded, never silent) ---------------------------------
    counters.deviations.append({
        "id": "eval-fixtures-refused-as-claw-back",
        "design_reference": "design-l1 §11.1 / FR-CNR-017 name eval/golden_corpus.jsonl "
                            "and eval/emergency_nearmiss.jsonl as L4 claw-back sources",
        "executed": ("the suite's guard refuses the eval set as training input "
                     "(pipeline_guards.assert_not_golden_input; eval_golden.py corpus "
                     "contract) — the fixtures are counted as refused sources and their "
                     "rows are excluded at admission (held_out_eval_fixture); the "
                     "retention function is carried by the intent_training + "
                     "abstain_honesty sources"),
        "fixture_sources_refused": counters.rejections.get("held_out_eval_fixture_source", 0),
        "fixture_rows_excluded": counters.rejections.get("held_out_eval_fixture", 0),
    })
    if opts.mix == SHIP_MIX and counters.rejections.get("dev_only_source"):
        counters.notes.append(
            f"{counters.rejections['dev_only_source']} turn(s) from dev-only sources "
            "excluded from the SHIP mix (CC BY-NC / research-gated)")

    # -- outputs -------------------------------------------------------------
    _write_outputs(opts, counters, selected, admitted, resolved_spec, held_out)
    report = _counters_dict(opts, counters, resolved_spec, held_out, mixture,
                            selected, admitted)
    guards.write_json(Path(opts.resolved_out_dir()) / "chat-corpus-counters.json",
                      report)
    _print_summary(counters, mixture, log=log)
    return report


def _shortfall_reason(layer: str, counters: Counters) -> str:
    notes = " | ".join(note for note in counters.notes
                       if note.startswith(f"source")
                       or note.startswith(f"L2/")
                       or note.startswith("STT-noised")
                       or note.startswith(f"L3"))
    base = {
        "L1": "no L1 source file was present in this build (sources are prepared on "
              "the training box); recorded per source",
        "L2": "translated+post-edited supply below plan (translation tier / post-edit "
              "availability is recorded in the notes)",
        "L3": "teacher generation did not reach the target in this run (call budget "
              "or execution availability — recorded)",
        "L4": "claw-back supply below target: the eval fixtures are refused by the "
              "suite's guard and the suite's intent-training corpus is a training-box "
              "source (recorded per source)",
    }.get(layer, "see the run notes")
    return f"{base}" + (f" [{notes}]" if notes else "")


# ---------------------------------------------------------------------------
# Output writing
# ---------------------------------------------------------------------------

CORPUS_FIELDS = ("record", "turn_id", "layer", "source", "component", "mix_class",
                 "language", "context", "user_turn", "assistant", "provenance")


def _turn_record(candidate: Candidate, opts: BuildOptions) -> dict:
    assistant = {
        "reply": candidate.reply,
        "gec": candidate.reply_gec,
    }
    if candidate.intent is not None:
        assistant["intent"] = candidate.intent
    user_turn_source = {"noised": candidate.already_noised,
                        "clean_utterance": candidate.origin.get("clean_utterance")}
    provenance = {
        "origin": candidate.origin.get("path") or candidate.source_id,
        "line": candidate.origin.get("line"),
        "source": candidate.source_id,
        "admissibility": candidate.admissibility,
        "post_edit_batch": candidate.post_edit_batch,
        "user_turn_source": user_turn_source,
    }
    return {
        "record": "turn",
        "turn_id": candidate.turn_id,
        "layer": candidate.layer,
        "source": candidate.source_id,
        "component": candidate.component or None,
        "selected": bool(candidate.selected),
        "mix_class": ("ship-eligible" if candidate.admissibility == "ship"
                      else "dev-only" if candidate.admissibility == "dev"
                      else candidate.admissibility),
        "language": candidate.language,
        "context": candidate.context,
        "user_turn": candidate.user_turn,
        "assistant": assistant,
        "provenance": provenance,
    }


def _write_jsonl(path: Path, records: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in records)
    path.write_text(payload, encoding="utf-8")


def _write_outputs(opts: BuildOptions, counters: Counters, selected: List[Candidate],
                   admitted: List[Candidate], spec: style_spec.StyleSpec,
                   held_out: HeldOutGuard) -> None:
    out_dir = Path(opts.resolved_out_dir())
    _write_jsonl(out_dir / f"chat-corpus-{opts.mix}.jsonl",
                 (_turn_record(c, opts) for c in selected))
    for layer in LAYERS:
        layer_turns = sorted([c for c in admitted if c.layer == layer],
                             key=lambda c: c.turn_id)
        _write_jsonl(out_dir / "layers" / f"{layer}.jsonl",
                     (_turn_record(c, opts) for c in layer_turns))
    if opts.mix == SHIP_MIX:
        for entry in counters.sources:
            if entry["admissibility"] == "dev" and entry["admitted"]:
                raise AssertionError(  # pragma: no cover - guard, not a path
                    f"SHIP MIX VIOLATION: {entry['id']} admitted {entry['admitted']} "
                    "turn(s) — dev-only sources can never enter the ship mix")


def _counters_dict(opts: BuildOptions, counters: Counters,
                   spec: style_spec.StyleSpec, held_out: HeldOutGuard,
                   mixture: dict, selected: List[Candidate],
                   admitted: List[Candidate]) -> dict:
    return {
        "schema": SCHEMA_ID,
        "run_id": opts.run_id,
        "mix": opts.mix,
        "seed": opts.seed,
        "style_spec": spec.evidence(),
        "held_out_guard": held_out.evidence(),
        "layers": {
            layer: {
                "title": LAYER_TITLE[layer],
                "candidates": counters.candidates["per_layer"].get(layer, 0),
                "admitted": counters.admitted["per_layer"].get(layer, 0),
                "selected": mixture["selected_per_layer"][layer],
                "target": LAYER_TARGETS[layer],
                "target_rationale": LAYER_TARGET_RATIONALE[layer],
            } for layer in LAYERS},
        "mixture": mixture,
        "sources": counters.sources,
        "tooling": [
            {"id": source.id, "license": source.license, "kind": source.kind,
             "notes": source.notes} for source in TOOLING_SOURCES],
        "rejections": dict(sorted(counters.rejections.items())),
        "held": dict(sorted(counters.held.items())),
        "exclusions": dict(sorted(counters.exclusions.items())),
        "stages": counters.stages,
        "shortfalls": counters.shortfalls,
        "deviations": counters.deviations,
        "notes": counters.notes,
        "outputs": {
            "corpus": f"chat-corpus-{opts.mix}.jsonl",
            "layers": [f"layers/{layer}.jsonl" for layer in LAYERS],
            "counters": "chat-corpus-counters.json",
        },
    }


def _print_summary(counters: Counters, mixture: dict, log=print) -> None:
    log("[step] per-layer admitted (selected): "
        + ", ".join(f"{layer} {counters.admitted['per_layer'].get(layer, 0)}"
                    f" ({mixture['selected_per_layer'][layer]})" for layer in LAYERS))
    achieved = mixture["achieved"]
    log(f"[step] mixture achieved: conversation {achieved['conversation']} "
        f"({achieved['conversation_share']:.1%}) / claw-back {achieved['clawback']} "
        f"({achieved['clawback_share']:.1%}) vs target "
        f"{mixture['target']['conversation_share']:.0%}/"
        f"{mixture['target']['clawback_share']:.0%}")
    for note in mixture["notes"]:
        log(f"[step] mixture note: {note}")
    for layer, count in sorted(counters.rejections.items()):
        log(f"[step] rejected by {layer}: {count}")
    for reason, count in sorted(counters.held.items()):
        log(f"[step] held ({reason}): {count}")
    for shortfall in counters.shortfalls:
        log(f"[step] SHORTFALL {shortfall['layer']}: {shortfall['achieved']} of "
            f"{shortfall['target']} — {shortfall['reason'][:160]}")
    for note in counters.notes:
        log(f"[note] {note}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="build_chat_corpus.py",
        description="Build the four-layer v17 chat corpus (T-179).")
    parser.add_argument("--mix", choices=MIXES, default=SHIP_MIX,
                        help="ship mix (CC-BY/Apache/MIT/synthetic/own only) or "
                             "dev mix (research-only sources admitted)")
    parser.add_argument("--source-root", type=Path, default=ROOT,
                        help="root the registry's relative source paths resolve "
                             "against (default: tools/train-intent/)")
    parser.add_argument("--out-dir", type=Path, default=None,
                        help="output directory (default: "
                             "build/chat-corpus/<run-id>/<mix>)")
    parser.add_argument("--run-id", default="v17")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--limit-per-source", type=int, default=0,
                        help="debug/demo: read at most N rows per source")
    parser.add_argument("--l3-target-turns", type=int, default=L3_TARGET_TURNS)
    parser.add_argument("--gec-budget", type=int, default=GEC_MAX_CALLS_DEFAULT)
    parser.add_argument("--noise-rate", type=float, default=STT_NOISE_RATE_DEFAULT)
    parser.add_argument("--noise-backend", choices=("auto", "recorded", "hf", "cli", "none"),
                        default="auto")
    parser.add_argument("--noise-pairs", type=Path, default=None,
                        help="recorded (clean_utterance, utterance) STT pairs for the "
                             "'recorded' backend")
    parser.add_argument("--translation-command", default="",
                        help="the en->ne translation tier as a command: JSONL "
                             "{'text': ...} on stdin, JSONL {'text': ...} on stdout")
    parser.add_argument("--teacher-transport", choices=("gemini", "openrouter",
                                                        "teacher-fixture"),
                        default="gemini")
    parser.add_argument("--teacher-fixture", type=Path, default=None,
                        help="recorded teacher responses (prompt_sha256 -> response) "
                             "for offline replay; recorded as a transport substitution")
    parser.add_argument("--plan", action="store_true",
                        help="print the source registry and layer plan, then exit")
    parser.add_argument("--record-spot-check", metavar="BATCH", default=None)
    parser.add_argument("--reviewer", default=None)
    parser.add_argument("--disposition", choices=POST_EDIT_STATUSES,
                        default="spot_checked")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.plan:
        return _print_plan()
    default_out = ROOT / "build" / "chat-corpus" / args.run_id / args.mix
    out_dir = Path(args.out_dir) if args.out_dir else default_out
    if args.record_spot_check:
        if not args.reviewer:
            print("[usage] --record-spot-check needs --reviewer NAME", file=sys.stderr)
            return guards.EXIT_USAGE
        try:
            record = record_spot_check(out_dir, args.record_spot_check, args.reviewer,
                                       args.disposition)
        except ValueError as exc:
            print(f"[usage] {exc}", file=sys.stderr)
            return guards.EXIT_USAGE
        print(f"[spot-check] {args.record_spot_check}: {record['status']} "
              f"by {record['reviewer']}")
        return guards.EXIT_OK
    opts = BuildOptions(
        mix=args.mix, source_root=Path(args.source_root), out_dir=out_dir,
        run_id=args.run_id, seed=args.seed, limit_per_source=args.limit_per_source,
        l3_target_turns=args.l3_target_turns, gec_budget=args.gec_budget,
        noise_rate=args.noise_rate, noise_backend=args.noise_backend,
        noise_pairs=args.noise_pairs, translation_command=args.translation_command,
        teacher_transport=args.teacher_transport, teacher_fixture=args.teacher_fixture,
    )
    try:
        report = build_chat_corpus(opts, log=lambda line: print(line))
    except BuildStopped as exc:
        print(f"[guard] STOPPED: {exc}", file=sys.stderr)
        _record_stop(opts, str(exc))
        return guards.EXIT_GUARD
    counters_path = Path(out_dir) / "chat-corpus-counters.json"
    guards.write_json(counters_path, report)
    if report["shortfalls"]:
        print(f"[floors] {len(report['shortfalls'])} shortfall(s) recorded — the run "
              "completed; the caller decides (list in "
              f"{counters_path.relative_to(ROOT) if counters_path.is_relative_to(ROOT) else counters_path})")
        return guards.EXIT_FLOOR
    return guards.EXIT_OK


def _record_stop(opts: BuildOptions, reason: str) -> None:
    """A stopped run still records why (the deviation for the run notes)."""
    out_dir = Path(opts.resolved_out_dir())
    out_dir.mkdir(parents=True, exist_ok=True)
    guards.write_json(out_dir / "chat-corpus-counters.json", {
        "schema": SCHEMA_ID, "run_id": opts.run_id, "mix": opts.mix,
        "stopped": True,
        "stop_reason": reason,
        "deviation": ("a run that cannot execute its filters / held-out guard STOPS "
                      "rather than admitting unfiltered turns (T-179 failure path)"),
    })


def _print_plan() -> int:
    print(f"{SCHEMA_ID} — layers, sources, mixture (seed default 42)")
    for layer in LAYERS:
        print(f"\n{layer} — {LAYER_TITLE[layer]} "
              f"(target {LAYER_TARGETS[layer] or 'supply-driven'})")
        for source in sources_for_layer(layer):
            print(f"  {source.id:32s} {source.admissibility:13s} {source.license}")
            if source.default_path:
                present = (ROOT / source.default_path).is_file()
                print(f"      path: {source.default_path} ({'present' if present else 'absent'})")
            if source.refusal_reason:
                print(f"      REFUSED: {source.refusal_reason}")
    print("\ntooling inputs (classified for the provenance manifest):")
    for source in TOOLING_SOURCES:
        print(f"  {source.id:32s} {source.license}")
    print(f"\nmixture: conversation {CONVERSATION_SHARE:.0%} / claw-back "
          f"{CLAWBACK_SHARE:.0%} (total target {TOTAL_TURNS_TARGET} turns; "
          f"eval-fixture dedupe vs chat golden; filters from the style spec)")
    return guards.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
