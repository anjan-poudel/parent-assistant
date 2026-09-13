"""Loader + validator for the T-034 annotation rules (schema annotation-rules/v1).

The encoder pipeline may not invent its label set, tag set, edge bands, mixture
targets or floors: they are the contract committed by T-034 at
`tools/train-intent/annotation_rules.yaml`. This module loads that file, cross
-checks it against the shipped taxonomy (`build_dataset.VALID_ACTIONS`) and
exposes it as a frozen dataclass so every stage reads the same numbers.

T-035 owns the distillation objective, the student size target and the artifact
version. Those are NOT invented here: the config carries `null` placeholders and
`require_t035()` turns any attempt to use them into an explicit error.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RULES = ROOT / "annotation_rules.yaml"

T035_PENDING = "TODO(T-035)"

# span label -> schema-v2 slot field (T-034 §4.1). `app` maps to requestedApp;
# callType is derived from the app span by T-035's field map — not a span.
SLOT_FIELD_OF_SPAN = {
    "contact": "contact",
    "time": "time",
    "medication": "medication",
    "message": "message",
    "topic": "topic",
    "app": "requestedApp",
}
SPAN_OF_SLOT_FIELD = {v: k for k, v in SLOT_FIELD_OF_SPAN.items()}

# Actions whose trigger material must survive STT noise or the row is dropped
# (T-034 §4.5 step 3). `ack_med`'s alternative trigger ("ack verb") is not a
# span label, so only the medication word is machine-checkable here; a row whose
# medication span is lost is dropped (safe direction — never teach ack on a
# transcript that no longer carries the medication mention).
TRIGGER_SPANS = {
    "call": ("contact", "app"),
    "set_reminder": ("time", "medication"),
    "send_message": ("message", "contact"),
    "ack_med": ("medication",),
    "guide": ("topic",),
}
# Recall-first (T-034 §4.5 step 5): an emergency row is never dropped for
# surface loss.
NEVER_DROPPED = ("emergency",)

# Teacher-born edge families (gen_teacher.py:85-90). Rows from these sources are
# priority-kept in their bucket — T-034 §5.3 ("edge rows are never sampled
# away"), extended from the existing `edge_cases:*`-only match.
EDGE_SOURCE_PREFIXES = (
    "edge_cases:",
    "teacher:abstain_low_confidence:",
    "teacher:gibberish_to_none:",
    "teacher:corrections_overrides:",
)


class RulesError(RuntimeError):
    """annotation_rules.yaml is missing, malformed or disagrees with the code."""


class T035PendingError(RuntimeError):
    """A T-035-owned value is still a TODO placeholder — fail loudly, never guess."""


@dataclass(frozen=True)
class EncoderRules:
    path: Path
    labels: tuple[str, ...]
    span_labels: tuple[str, ...]
    bio_tags: tuple[str, ...]
    tokenizer_repo: str
    tokenizer_revision_prefix: str
    tokenizer_vocab: int
    refusal_markers: tuple[str, ...]
    targets: dict = field(default_factory=dict)
    seed_gaps: tuple[str, ...] = ()
    edge_bands: dict = field(default_factory=dict)
    floors: dict = field(default_factory=dict)
    mixture: dict = field(default_factory=dict)

    @property
    def tag2id(self) -> dict[str, int]:
        return {t: i for i, t in enumerate(self.bio_tags)}

    def is_edge_source(self, source: str) -> bool:
        return any((source or "").startswith(p) for p in EDGE_SOURCE_PREFIXES)


def load_rules(path: str | Path = DEFAULT_RULES) -> EncoderRules:
    p = Path(path)
    if not p.exists():
        raise RulesError(
            f"annotation rules not found at {p!s}. They are the T-034 input "
            "contract (tools/train-intent/annotation_rules.yaml); copy/merge "
            "T-034's artifact before running any encoder stage.")
    with open(p, encoding="utf-8") as f:
        rules = yaml.safe_load(f) or {}

    if rules.get("schema") != "annotation-rules/v1":
        raise RulesError(f"{p.name}: unexpected schema {rules.get('schema')!r}, "
                         "expected 'annotation-rules/v1'")

    labels = tuple(rules["taxonomy"]["labels"])
    span_labels = tuple(rules["spans"]["labels"])
    bio_tags = tuple(rules["spans"]["bio"]["tags"])

    # Cross-check against the shipped taxonomy — the rules must equal the code,
    # never the other way round (T-034 verification, repeated at runtime).
    from build_dataset import VALID_ACTIONS

    if set(labels) != set(VALID_ACTIONS):
        raise RulesError(
            "rules taxonomy does not match build_dataset.VALID_ACTIONS: "
            f"only-in-rules={sorted(set(labels) - VALID_ACTIONS)}, "
            f"only-in-code={sorted(VALID_ACTIONS - set(labels))}")

    expected_tags = ["O"] + [f"{p}-{s}" for s in span_labels for p in ("B", "I")]
    if list(bio_tags) != expected_tags:
        raise RulesError("rules BIO tags do not match O + B/I x spans.labels: "
                         f"{list(bio_tags)} vs {expected_tags}")
    if int(rules["spans"]["bio"].get("tag_count", -1)) != len(bio_tags):
        raise RulesError("rules spans.bio.tag_count disagrees with spans.bio.tags")

    validation = rules["spans"]["validation"]
    refusal_line = next((v for v in validation if "refusal marker" in v), "")
    markers = tuple(m.strip() for m in refusal_line.split("(")[-1].split(")")[0].split(","))
    if len(markers) < 3:
        raise RulesError(f"{p.name}: could not parse refusal markers from "
                         f"spans.validation; got {markers!r}")

    floors = rules["mixture"]["supply_caps"]
    edge_bands = {
        "abstain_max_conf": 0.4,
        "gibberish_max_conf": 0.2,
        "corrections_min_conf": 0.8,
        "corrections_max_conf": 0.95,
    }
    _bands = rules.get("edge_classes", {})
    _abstain = str(_bands.get("abstain_low_confidence", {}).get("confidence", ""))
    _gibberish = str(_bands.get("gibberish_to_none", {}).get("confidence", ""))
    _corr = str(_bands.get("corrections_overrides", {}).get("confidence", ""))
    if "<" not in _abstain or "<" not in _gibberish or "–" not in _corr:
        raise RulesError(f"{p.name}: edge_classes confidence bands not parseable "
                         f"({_abstain!r}, {_gibberish!r}, {_corr!r})")
    edge_bands["abstain_max_conf"] = float(_abstain.split("<")[1].strip())
    edge_bands["gibberish_max_conf"] = float(_gibberish.split("<")[1].strip())
    lo, hi = _corr.split("–")
    edge_bands["corrections_min_conf"] = float(lo.strip())
    edge_bands["corrections_max_conf"] = float(hi.strip())

    tok = rules["spans"]["tokenizer"]
    return EncoderRules(
        path=p,
        labels=labels,
        span_labels=span_labels,
        bio_tags=bio_tags,
        tokenizer_repo=str(tok["source_repo"]),
        tokenizer_revision_prefix=str(tok["revision"])[:8],
        tokenizer_vocab=int(tok["vocab_size"]),
        refusal_markers=markers,
        targets={k: (v or {}).get("spec_9_1") or (v or {}).get("proposed")
                 for k, v in rules["taxonomy"].get("targets", {}).items()},
        seed_gaps=tuple(rules["taxonomy"].get("seed_gaps", [])),
        edge_bands=edge_bands,
        floors={"stt_noised_min_share": float(floors["hard_floor_stt_noised"]),
                "corpus_min_rows": int(floors["corpus_floor"]),
                "per_action_min_frac": 0.25},
        mixture={"targets": rules["mixture"]["targets"],
                 "register_to_bucket": rules["mixture"]["register_to_bucket"],
                 "anchor": rules["mixture"]["anchor"]},
    )


def require_t035(value, name: str):
    """Return `value` or raise when a T-035-owned parameter is still a placeholder."""
    if value is None or (isinstance(value, str) and value.strip() == T035_PENDING):
        raise T035PendingError(
            f"{name} is {T035_PENDING}: the value is fixed by T-035 (joint "
            "intent+slot encoder design) and must not be invented by this "
            "pipeline. Set it in config.yaml:encoder once T-035 lands.")
    return value


def check_edge_band(rules: EncoderRules, row: dict) -> str | None:
    """Return the violated edge-band name, or None when the row is in-band.

    Teacher rows carry the band in seeds/annotation rules; gen_teacher.edge_ok
    accepts abstain < 0.5 / gibberish < 0.3 (the discrepancy T-034 §6.1 flags),
    so the build re-checks the PINNED bands and refuses out-of-band rows rather
    than trusting the generator.
    """
    source = row.get("source") or ""
    conf = float(row.get("confidence", 1.0))
    if ":abstain_low_confidence:" in source or source.startswith("abstain_low_confidence"):
        return None if (row.get("action") == "none"
                        and conf < rules.edge_bands["abstain_max_conf"]) else "abstain_low_confidence"
    if ":gibberish_to_none:" in source or source.startswith("gibberish_to_none"):
        return None if (row.get("action") == "none"
                        and conf < rules.edge_bands["gibberish_max_conf"]) else "gibberish_to_none"
    if ":corrections_overrides:" in source or source.startswith("corrections_overrides"):
        ok = (row.get("action") == "call"
              and bool(row.get("requestedApp"))
              and rules.edge_bands["corrections_min_conf"] <= conf
              <= rules.edge_bands["corrections_max_conf"])
        return None if ok else "corrections_overrides"
    return None
