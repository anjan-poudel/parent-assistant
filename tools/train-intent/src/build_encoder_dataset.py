"""T-036 stage E1 — encoder (intent + BIO span) dataset build.

Sibling of build_dataset.py (the LLM-row builder), same suite and same guards.
It consumes the T-034 annotation rules (annotation_rules.yaml) and the LLM-row
sources (teacher.jsonl / noised.jsonl / edge_cases.jsonl) and emits the T-034
row format:

    {id, utterance, action, register, source, confidence, spans, slots}

where `spans` are verbatim subtitle-styled spans `[{label, text, start, end}]`
over the row's own utterance and `slots` are the span surfaces (never resolved
values — requestedApp holds the surface the user spoke; T-035 maps it).

Guards preserved from build_dataset.py (spec §9/§10, T-034 §4.6/§7):
  - schema validation (action/utterance/confidence/id/source/register);
  - golden-corpus leakage refusal: normalized-utterance membership → refused and
    counted; the corpus can also never be passed as a source (GuardError);
  - 60/25/15 mixture with the noised bucket anchoring the total;
  - per-bucket label-conflict dropping (superset of build_dataset's: rows whose
    SAME utterance carries a different supervised target are all dropped);
  - dup_clean dropping (a noised row byte-equal to a surviving clean row);
  - refusal counters reported, never the utterance itself (NFR-016).

New in the encoder build (T-034):
  - spans derived from slot strings under the authoring invariant: a non-null
    slot that is not verbatim in the utterance makes the row non-alignable →
    refused (T-033's silent slot-loss masking is not allowed);
  - noised rows are re-annotated on the noised transcript, never inherited:
    recoverable surfaces are re-spanned, lost non-critical spans are omitted,
    a lost trigger drops the row (`relabel_or_drop`); emergency is never dropped;
  - edge bands re-checked against the pinned values (abstain < 0.4,
    gibberish < 0.2, corrections 0.8–0.95), teacher-born edge rows priority-kept;
  - frame floors (T-034 §5.3): stt_noised share ≥ 0.55, corpus ≥ 8000 rows,
    per-action ≥ 0.25 × target — violation is a non-zero hold (exit 4) unless
    explicitly waived with a recorded reason;
  - the leak counter (exact normalized-utterance matches against the golden
    corpus) can be waived with a recorded reason too — but only the counter is
    waivable (E2's row-level guard never is), and the record says "exact
    matches were excluded", not "contamination handled": noised rows whose
    `clean_utterance` parent is a golden utterance are invisible to both.

Exit codes: 0 ok, 3 guard refusal, 4 floors not met.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import re
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_dataset import (BUCKET_NAMES, BUCKET_OF_REGISTER, VALID_ACTIONS,
                           lossless_key, normalize)
from config import load_config
from encoder_align import canonical_text_violations, validate_spans, word_offsets
from encoder_rules import (NEVER_DROPPED, SLOT_FIELD_OF_SPAN, TRIGGER_SPANS,
                           EncoderRules, check_edge_band, load_rules)
from pipeline_guards import (EXIT_FLOOR, EXIT_GUARD, EXIT_OK, GOLDEN_CORPUS,
                             GuardError, assert_not_golden_input, golden_keys,
                             sha256_file, utc_now, write_json)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCES = ("data/teacher.jsonl", "data/noised.jsonl", "data/edge_cases.jsonl")
NOISED_SOURCE = "stt_noise"
DEV_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")

# Resolved `requestedApp` enum -> spoken surfaces. Mirrors the committed seed
# banks (seeds/intents.yaml entity_banks.apps = फेसटाइम/वाट्सएप/facetime/whatsapp)
# plus the method words the templates use (फोन, भिडियो कल). The encoder must
# learn the SURFACE the user spoke; resolution happens in MethodResolver later.
APP_ENUM_SURFACES = {
    "phone": ("फोन", "phone", "कल", "call"),
    "whatsapp": ("वाट्सएप", "whatsapp", "व्हाट्सएप", "व्हाट्सऐप"),
    "facetime": ("फेसटाइम", "facetime", "भिडियो कल", "video call", "भिडियो"),
}
CALLTYPE_SURFACES = {"video": ("भिडियो कल", "भिडियो", "video call", "video")}
# Resolved-value patterns that must never reach a target (T-034 §4.6).
URL_RE = re.compile(r"https?://|www\.", re.IGNORECASE)
UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}")
PHONE_RE = re.compile(r"(?<!\d)\d{7,}(?!\d)")
CLOCK_RE = re.compile(r"\b\d{1,2}:\d{2}\b")


class BuildError(RuntimeError):
    pass


# MARK: - span derivation


def slots_of(row: dict) -> dict[str, str | None]:
    """The six span-bearing slot fields, non-empty strings only."""
    out = {}
    for field in SLOT_FIELD_OF_SPAN.values():
        v = row.get(field)
        out[field] = v.strip() if isinstance(v, str) and v.strip() else None
    return out


def fold(text: str) -> str:
    """NFC + Devanagari digit fold — the conservative noised-surface match."""
    return unicodedata.normalize("NFC", text).translate(DEV_DIGITS)


def find_surface(utterance: str, surface: str) -> tuple[int, int] | None:
    """Locate a slot surface in the utterance: exact, NFC/digit-folded, else None.

    No fuzzy matching: a misspelled surface is omitted (counted), never
    approximated — a wrong span is worse than a missing one.
    """
    i = utterance.find(surface)
    if i >= 0:
        return (i, i + len(surface))
    hay, needle = fold(utterance), fold(surface)
    j = hay.find(needle)
    if j >= 0 and len(hay) == len(utterance) and len(needle) == len(surface):
        return (j, j + len(surface))
    return None


def snap_to_words(utterance: str, start: int, end: int) -> tuple[int, int]:
    """Widen a surface match to the whitespace words it intersects.

    T-034 §4.4: an affix merged into a token stays inside the span
    ("माइया लाई" -> "माइयालाई" widens the contact span); a particle emitted as
    its own word is not covered and therefore excluded.
    """
    words = word_offsets(utterance)
    a, b = start, end
    for wa, wb in words:
        if wa < end and wb > start:
            a, b = min(a, wa), max(b, wb)
    return a, b


def span_for(utterance: str, surface: str) -> dict | None:
    hit = find_surface(utterance, surface)
    if hit is None:
        return None
    a, b = snap_to_words(utterance, *hit)
    return {"label": None, "text": utterance[a:b], "start": a, "end": b}


def app_candidates(slots: dict) -> list[str]:
    """Spoken-surface candidates for requestedApp/callType (see APP_ENUM_SURFACES)."""
    cands: list[str] = []
    req = slots.get("requestedApp")
    if req:
        cands.extend(APP_ENUM_SURFACES.get(req.lower(), (req,)))
    call_type = slots.get("callType") or ""  # type: ignore[union-attr]
    if isinstance(call_type, str) and call_type.lower() in CALLTYPE_SURFACES:
        cands.extend(CALLTYPE_SURFACES[call_type.lower()])
    return cands


def derive_spans(utterance: str, slots: dict,
                 counters: dict) -> tuple[list[dict], set[str]]:
    """Spans for one row + the set of slot fields that were not recoverable.

    Clean rows: a non-null slot must be verbatim (modulo NFC/digit fold) in the
    utterance or the row is non-alignable (caller refuses). Noised rows: a lost
    surface omits that span and is counted; the caller decides drop-vs-keep from
    the action's trigger.
    """
    spans: list[dict] = []
    missing: set[str] = set()
    for field, label in SLOT_FIELD_OF_SPAN.items():
        if field == "requestedApp":
            cands = app_candidates(slots)
        else:
            cands = [slots[field]] if slots.get(field) else []
        if not cands:
            continue
        span = None
        for surface in cands:
            span = span_for(utterance, surface)
            if span:
                break
        if span is None:
            missing.add(label)
            if field == "requestedApp":
                counters["app_surface_not_found"] += 1
            continue
        span["label"] = label
        spans.append(span)
    spans.sort(key=lambda s: (s["start"], s["end"]))
    return spans, missing


def resolved_value_violation(spans: list[dict], utterance: str) -> bool:
    """True when a span surface smells like a resolved value (T-034 §4.6)."""
    for s in spans:
        text = s["text"]
        if URL_RE.search(text) or UUID_RE.search(text) or PHONE_RE.search(text):
            return True
        for m in CLOCK_RE.finditer(text):
            if m.group(0) not in utterance:
                return True
    return False


def slots_from_spans(spans: list[dict]) -> dict:
    out = {field: None for field in SLOT_FIELD_OF_SPAN.values()}
    for s in spans:
        out[SLOT_FIELD_OF_SPAN[s["label"]]] = s["text"]
    return out


# MARK: - row conversion


def convert_row(row: dict, rules: EncoderRules, counters: dict) -> dict | None:
    """One source row -> one T-034 encoder row, or None (refused, counted)."""
    action = row.get("action")
    if action is None and isinstance(row.get("intent"), str):
        action = row["intent"]
        counters["action_alias_intent"] += 1
    if action not in VALID_ACTIONS:
        counters["schema_action"] += 1
        return None
    utterance = row.get("utterance")
    if not isinstance(utterance, str):
        counters["schema_utterance"] += 1
        return None
    if canonical_text_violations(utterance):
        counters["whitespace_noncanonical"] += 1
        return None
    if not isinstance(row.get("id"), str) or not row["id"]:
        counters["schema_id"] += 1
        return None
    source = row.get("source") or ""
    if not source:
        counters["schema_source"] += 1
        return None
    register = row.get("register")
    noised = source.split(":")[0] == NOISED_SOURCE
    if not noised and register not in BUCKET_OF_REGISTER:
        counters["schema_register"] += 1
        return None
    try:
        conf = float(row.get("confidence"))
    except (TypeError, ValueError):
        counters["schema_confidence"] += 1
        return None
    if not 0.0 <= conf <= 1.0:
        counters["schema_confidence"] += 1
        return None
    if action == "ack_med" and any(m in utterance for m in rules.refusal_markers):
        counters["ack_refusal_marker"] += 1
        return None
    band = check_edge_band(rules, {**row, "action": action})
    if band:
        counters[f"edge_band_{band}"] += 1
        return None

    slots = slots_of(row)
    spans, missing = derive_spans(utterance, slots, counters)
    if missing and not noised:
        counters["non_alignable"] += 1
        return None
    if missing and noised:
        counters["span_omitted_under_noise"] += 1
        trigger = TRIGGER_SPANS.get(action, ())
        if trigger and not any(s["label"] in trigger for s in spans) \
                and action not in NEVER_DROPPED:
            counters["relabel_or_drop"] += 1
            return None

    problems = validate_spans(utterance, spans)
    if problems:
        counters["span_validation"] += 1
        return None
    if resolved_value_violation(spans, utterance):
        counters["resolved_value"] += 1
        return None

    return {"id": row["id"], "utterance": utterance, "action": action,
            "register": register, "source": source, "confidence": conf,
            "spans": spans, "slots": slots_from_spans(spans)}


def target_signature(row: dict) -> str:
    """What the encoder is taught for a row: action + spanned intervals."""
    spans = ",".join(f"{s['label']}:{s['start']}-{s['end']}" for s in row["spans"])
    return f"{row['action']}|{spans}"


# MARK: - mixture


def bucket_of(row: dict) -> str | None:
    source = (row.get("source") or "").split(":")[0]
    if source == NOISED_SOURCE:
        return "stt_noised"
    return BUCKET_OF_REGISTER.get(row.get("register"))


def select_mixture(rows: list[dict], frac: dict, rng: random.Random,
                   rules: EncoderRules, counters: dict
                   ) -> tuple[dict[str, list[dict]], list[str], dict[str, int]]:
    """Bucket -> kept rows after conflict-drop, dedupe and mixture sampling."""
    buckets: dict[str, list[dict]] = {b: [] for b in BUCKET_NAMES}
    for row in rows:
        b = bucket_of(row)
        if b:
            buckets[b].append(row)

    kept: dict[str, list[dict]] = {}
    conflicts: dict[str, int] = {}
    for bucket in BUCKET_NAMES:
        rows_b = list(buckets[bucket])
        by_target: dict[str, set] = {}
        for row in rows_b:
            by_target.setdefault(lossless_key(row["utterance"]), set()).add(
                target_signature(row))
        conflict_keys = {k for k, sigs in by_target.items() if len(sigs) > 1}
        conflicts[bucket] = len(conflict_keys)
        rows_b = [r for r in rows_b if lossless_key(r["utterance"]) not in conflict_keys]
        rng.shuffle(rows_b)
        by_key: dict[str, dict] = {}
        for row in rows_b:
            by_key.setdefault(lossless_key(row["utterance"]), row)
        kept[bucket] = list(by_key.values())
        counters[f"conflict_keys_{bucket}"] = len(conflict_keys)

    clean_keys = {lossless_key(r["utterance"]) for r in kept["clean_devanagari"]}
    clean_keys |= {lossless_key(r["utterance"]) for r in kept["romanized_codeswitched"]}
    before = len(kept["stt_noised"])
    kept["stt_noised"] = [r for r in kept["stt_noised"]
                          if lossless_key(r["utterance"]) not in clean_keys]
    counters["dup_clean"] = before - len(kept["stt_noised"])

    n_noised = len(kept["stt_noised"])
    total = math.ceil(n_noised / frac["stt_noised"]) if n_noised else 0
    selected: dict[str, list[dict]] = {"stt_noised": kept["stt_noised"]}
    supply_capped: list[str] = []
    for bucket in ("clean_devanagari", "romanized_codeswitched"):
        target = round(total * frac[bucket])
        rows_b = list(kept[bucket])
        priority = [r for r in rows_b if rules.is_edge_source(r["source"])]
        pool = [r for r in rows_b if r not in priority]
        counters[f"edge_priority_{bucket}"] = len(priority)
        rng.shuffle(pool)
        take = max(0, target - len(priority))
        if len(pool) < take:
            supply_capped.append(bucket)
            take = len(pool)
        selected[bucket] = priority + pool[:take]
    return selected, supply_capped, conflicts


def floor_violations(selected: dict[str, list[dict]], rules: EncoderRules,
                     counters: dict) -> list[str]:
    """T-034 §5.3 floors — returns human-readable violations (no utterance text)."""
    violations: list[str] = []
    total = sum(len(v) for v in selected.values())
    if total < rules.floors["corpus_min_rows"]:
        violations.append(
            f"corpus_floor: {total} rows < {rules.floors['corpus_min_rows']} "
            "(round-2 ran at 2,827 and was under-trained)")
    if total:
        share = len(selected["stt_noised"]) / total
        if share < rules.floors["stt_noised_min_share"]:
            violations.append(
                f"stt_noised_floor: {share:.3f} < "
                f"{rules.floors['stt_noised_min_share']} — regenerate noised data")
    per_action: dict[str, int] = {}
    for rows in selected.values():
        for r in rows:
            per_action[r["action"]] = per_action.get(r["action"], 0) + 1
    for action, target in rules.targets.items():
        if not target:
            continue
        want = rules.floors["per_action_min_frac"] * int(target)
        got = per_action.get(action, 0)
        if got < want:
            violations.append(f"per_action_floor: {action} {got} < {want:.0f} "
                              f"(0.25 x target {target})")
    return violations


# MARK: - report helpers


def source_stats(paths: list[Path]) -> list[dict]:
    return [{"path": str(p), "exists": p.exists(),
             "sha256": sha256_file(p) if p.exists() else None} for p in paths]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sources", nargs="+", default=None,
                        help="source jsonl files, comma-separated or space-separated "
                             f"(default: {', '.join(DEFAULT_SOURCES)})")
    parser.add_argument("--out-dir", default="data/encoder")
    parser.add_argument("--report", default="")
    parser.add_argument("--rules", default="")
    parser.add_argument("--smoke", action="store_true",
                        help="waive the supply floors explicitly (wiring proof only; "
                             "the run report records the waiver, and publication is "
                             "refused for smoke artifacts)")
    parser.add_argument("--waive-floor", default="",
                        help="comma-separated floor names to waive: "
                             "corpus_floor,stt_noised_floor,per_action_floor")
    parser.add_argument("--waive-reason", default="",
                        help="required with --waive-floor/--waive-leak; recorded "
                             "in the report")
    parser.add_argument("--waive-leak", action="store_true",
                        help="waive the E2 refusal on a nonzero leak counter (ONLY "
                             "the source-level counter — the row-level E2 guard is "
                             "never waivable). The counter counts EXACT normalized-"
                             "utterance matches against the golden corpus and "
                             "cannot see noised rows whose clean_utterance parent "
                             "is a golden utterance: 'waived' means 'exact matches "
                             "were excluded', never 'contamination handled'. "
                             "Requires --waive-reason")
    parser.add_argument("--max-source-rows", type=int, default=0,
                        help="debug: cap rows read per source")
    args, cfg = load_config(parser)

    try:
        rules = load_rules(args.rules) if args.rules else load_rules()
    except Exception as e:  # noqa: BLE001 — a bad contract must fail loudly
        print(f"[build-encoder] RULES ERROR: {e}", file=sys.stderr)
        return EXIT_GUARD
    try:
        keys = golden_keys(GOLDEN_CORPUS)
    except GuardError as e:
        print(f"[guard] REFUSED: {e}", file=sys.stderr)
        return EXIT_GUARD

    # Both spellings are accepted ("a.jsonl,b.jsonl" and "a.jsonl b.jsonl"):
    # run_encoder_pipeline.py forwards --sources as separate argv entries, and a
    # single-value option would silently keep only the first one.
    given = [p for chunk in (args.sources or []) for p in str(chunk).split(",") if p.strip()]
    sources = [Path(p.strip()).expanduser() for p in given] or \
        [ROOT / s for s in DEFAULT_SOURCES]
    for src in sources:
        try:
            assert_not_golden_input(src, "--sources")
        except GuardError as e:
            print(f"[guard] REFUSED: {e}", file=sys.stderr)
            return EXIT_GUARD
    # A source that does not exist is either a path mistake (the caller's cwd is
    # not this process's cwd) or a stage that was never run. Warning per file is
    # fine for an optional member of a set, but ALL of them missing means the
    # build would quietly produce an empty corpus — refuse instead, and print
    # the resolved path so the cwd mismatch is visible.
    missing = [s for s in sources if not s.exists()]
    if missing and len(missing) == len(sources):
        print("[guard] REFUSED: none of the --sources exist: "
              + ", ".join(str(s.resolve()) for s in missing)
              + " — run the upstream stage first, or fix the path (paths are "
                "resolved against the current directory)", file=sys.stderr)
        return EXIT_GUARD
    for s in missing:
        print(f"[build-encoder] warning: {s.resolve()} missing — skipped")

    # config.yaml is the runtime knob source (same convention as build_dataset);
    # the T-034 rules are the contract — a disagreement is a hard error, never a
    # silent pick.
    frac = {b: float(cfg[f"mixture.{b}"]) for b in BUCKET_NAMES}
    for b in BUCKET_NAMES:
        if abs(frac[b] - float(rules.mixture["targets"][b])) > 1e-9:
            print(f"[build-encoder] CONTRACT ERROR: config mixture.{b}={frac[b]} "
                  f"!= annotation_rules mixture.targets.{b}="
                  f"{rules.mixture['targets'][b]}", file=sys.stderr)
            return EXIT_GUARD
    valid_fraction = float(cfg["mixture.valid_fraction"])
    rng = random.Random(int(cfg["mixture.seed"]))

    counters = {name: 0 for name in (
        "schema_action", "schema_utterance", "schema_id", "schema_source",
        "schema_register", "schema_confidence", "whitespace_noncanonical",
        "action_alias_intent", "leak", "non_alignable", "resolved_value",
        "ack_refusal_marker", "edge_band_abstain_low_confidence",
        "edge_band_gibberish_to_none", "edge_band_corrections_overrides",
        "span_validation", "span_omitted_under_noise", "relabel_or_drop",
        "app_surface_not_found", "dup_clean", "noised_input_rows",
        "distinct_noised_utterances")}

    raw: list[dict] = []
    for src in sources:
        if not src.exists():   # already warned (with its resolved path) in main()
            continue
        rows = [json.loads(line) for line in src.read_text(encoding="utf-8").splitlines()
                if line.strip()]
        if args.max_source_rows:
            rows = rows[:args.max_source_rows]
        raw.extend(rows)

    raw_noised = [r for r in raw if str(r.get("source") or "").split(":")[0] == NOISED_SOURCE]
    counters["noised_input_rows"] = len(raw_noised)
    counters["distinct_noised_utterances"] = len(
        {lossless_key(r["utterance"]) for r in raw_noised if r.get("utterance")})

    converted: list[dict] = []
    for row in raw:
        if normalize(str(row.get("utterance") or "")) in keys:
            counters["leak"] += 1
            continue
        out = convert_row(row, rules, counters)
        if out is not None:
            converted.append(out)

    selected, supply_capped, conflicts = select_mixture(converted, frac, rng, rules, counters)

    train_pool = selected["stt_noised"] + selected["clean_devanagari"] \
        + selected["romanized_codeswitched"]
    rng.shuffle(train_pool)
    n_valid = max(1, int(len(train_pool) * valid_fraction)) if train_pool else 0
    valid, train = train_pool[:n_valid], train_pool[n_valid:]

    out_dir = Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, split in (("train", train), ("valid", valid)):
        with open(out_dir / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for row in split:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    violations = floor_violations(selected, rules, counters)
    waived = [w.strip() for w in args.waive_floor.split(",") if w.strip()]
    if args.smoke:
        waived = sorted(set(waived) | {"corpus_floor", "stt_noised_floor",
                                       "per_action_floor"})
    if waived and not args.waive_reason and not args.smoke:
        print("[build-encoder] --waive-floor requires --waive-reason", file=sys.stderr)
        return 2
    if args.waive_leak and not args.waive_reason and not args.smoke:
        print("[build-encoder] --waive-leak requires --waive-reason", file=sys.stderr)
        return 2
    unwaived = [v for v in violations
                if not any(v.startswith(w) for w in waived)]

    total = len(train_pool)
    achieved = {b: (len(v) / total if total else 0.0) for b, v in selected.items()}
    stt_noised_by_register: dict[str, int] = {}
    for r in selected["stt_noised"]:
        reg = r.get("register") or "unknown"
        stt_noised_by_register[reg] = stt_noised_by_register.get(reg, 0) + 1
    per_action: dict[str, int] = {}
    span_rows: dict[str, int] = {}
    span_rows_by_register: dict[str, dict[str, int]] = {}
    for rows in selected.values():
        for r in rows:
            per_action[r["action"]] = per_action.get(r["action"], 0) + 1
            for s in r["spans"]:
                span_rows[s["label"]] = span_rows.get(s["label"], 0) + 1
                by_reg = span_rows_by_register.setdefault(r["register"] or "unknown", {})
                by_reg[s["label"]] = by_reg.get(s["label"], 0) + 1
    edge_families: dict[str, int] = {}
    for r in train_pool:
        if rules.is_edge_source(r["source"]):
            # "teacher:<family>:<register>" / "edge_cases:<family>"
            fam = r["source"].split(":")[1]
            edge_families[fam] = edge_families.get(fam, 0) + 1

    report_path = Path(args.report) if args.report else out_dir / "build_report.json"
    report = {
        "schema": "encoder-build-report/v1",
        "created_utc": utc_now(),
        "smoke": bool(args.smoke),
        "rules": {"path": str(rules.path), "sha256": sha256_file(rules.path),
                  "labels": list(rules.labels)},
        "golden_corpus": {"path": str(GOLDEN_CORPUS), "sha256": sha256_file(GOLDEN_CORPUS),
                          "rows": len(keys)},
        "sources": source_stats(sources),
        "counters": counters,
        "kept": {"train": len(train), "valid": len(valid), "total": total},
        "buckets": {b: {"rows": len(selected[b]), "share": round(achieved[b], 4),
                        "target": frac[b],
                        "supply_capped": b in supply_capped,
                        "conflict_keys_dropped": conflicts[b]}
                    for b in BUCKET_NAMES},
        "stt_noised_by_parent_register": stt_noised_by_register,
        "per_action": per_action,
        "per_action_target": {k: v for k, v in rules.targets.items() if v},
        "span_bearing_rows": span_rows,
        "span_bearing_by_register": span_rows_by_register,
        "edge_families": edge_families,
        "floors": {"violations": violations, "waived": waived,
                   "unwaived": unwaived,
                   "waive_reason": args.waive_reason or ("smoke" if args.smoke else ""),
                   # train_encoder refuses a corpus whose build report says
                   # usable_for_training is false — a waived floor is wiring
                   # evidence, never a trainable corpus.
                   "usable_for_training": (not unwaived) and not args.smoke},
        # The leak counter is EXACTness: normalized-utterance equality against
        # the golden corpus. It cannot see noised rows whose `clean_utterance`
        # parent is a golden utterance (the row-level E2 guard does not see them
        # either), so a waiver recorded here must never be read as
        # "contamination handled" — only as "exact matches were excluded".
        "leak_waiver": {
            "requested": bool(args.waive_leak or args.smoke),
            "waived": bool(args.waive_leak or args.smoke),
            "counter": counters["leak"],
            "waive_reason": args.waive_reason or ("smoke" if args.smoke else ""),
            "scope": "EXACT normalized-utterance matches against the golden corpus "
                     "only; parent-derived noised rows are invisible to this counter "
                     "(and to the row-level guard)",
            "note": "measured 2026-09-13 on the real corpora: teacher 67 exact hits "
                    "/ 25 keys, noised 32 / 2 plus 118 rows whose clean_utterance "
                    "parent is a golden utterance (22 keys), edge_cases 6 / 5",
        },
        "outputs": {name: {"path": str(out_dir / f"{name}.jsonl"),
                           "sha256": sha256_file(out_dir / f"{name}.jsonl"),
                           "rows": len(split)}
                    for name, split in (("train", train), ("valid", valid))},
    }
    write_json(report_path, report)

    print(f"[build-encoder] kept {total} rows (train {len(train)}, valid {len(valid)})")
    print("[build-encoder] buckets: "
          + ", ".join(f"{b} {len(selected[b])} ({achieved[b]:.1%})" for b in BUCKET_NAMES))
    print("[build-encoder] refusals: " + ", ".join(
        f"{k}={v}" for k, v in sorted(counters.items()) if v))
    if supply_capped:
        print(f"[build-encoder] SUPPLY-CAPPED: {', '.join(supply_capped)}")
    if violations:
        print("[build-encoder] floor violations: " + "; ".join(violations))
    if counters["leak"]:
        if args.waive_leak or args.smoke:
            print(f"[build-encoder] leak counter WAIVED: {counters['leak']} exact "
                  f"golden-corpus match(es) excluded ({args.waive_reason or 'smoke'}) "
                  "— exact matches only; rows derived from a golden parent are NOT "
                  "covered by this counter")
        else:
            print(f"[build-encoder] leak counter: {counters['leak']} exact golden "
                  "match(es) excluded — E2 refuses this corpus unless the counter is "
                  "waived (--waive-leak on the pipeline)")
    print(f"[build-encoder] report -> {report_path}")
    if unwaived:
        print("[build-encoder] HOLD: floors not met and not waived — "
              "not a trainable corpus (T-034 §5.3)", file=sys.stderr)
        return EXIT_FLOOR
    if waived:
        print(f"[build-encoder] floors waived: {', '.join(waived)} "
              f"({args.waive_reason or 'smoke'}) — smoke/wiring use only")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
