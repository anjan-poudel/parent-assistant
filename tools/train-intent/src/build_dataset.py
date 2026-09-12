"""Stage 3 — dataset build: mixture + validation + dedupe + split.

Fully deterministic and fast — safe to re-run anytime; rebuilds
data/train.jsonl and data/valid.jsonl from scratch.

Guards (spec §9 / §10):
 - schema: every row must carry all intent/v2 fields with the right types
 - leakage: any row whose NORMALIZED utterance appears in the golden
   corpus is REFUSED (the corpus is the eval set — training on it means
   flying blind; normalization here mirrors the app's
   NepaliTextNormalizer: NFC, Devanagari digits folded, punctuation
   including danda stripped, whitespace collapsed, lowercased)
 - mixture: targets 60% stt-noised / 25% clean devanagari / 15% romanized
   + code-switched (spec §9.2), best-effort given available supply
"""

# Mixture mechanics (rewritten for bake-off round 2, 2026-09-07):
#
# Round 1 deduped EVERY source against one shared normalized key (the
# lossy app-mirror skeleton key — \W strips Devanagari matras, so it only
# sees the consonant skeleton). STT noise mostly disturbs matras, so
# nearly every noised row skeleton-collided with its clean teacher twin
# and was dropped as a "dup": the round-1 corpus ended up ~86% clean /
# ~14% noised instead of the spec's 60/25/15.
#
# Round 2 splits the corpus into three REGISTER buckets before any
# filtering, dedupes INSIDE each bucket with a lossless-ish key (matras
# preserved — two rows that differ by a matra are different training
# examples), and only then samples the buckets toward the §9.2 ratio:
#
#   stt_noised             noised.jsonl rows (any register) — the scarce
#                          supply; ALL kept rows anchor the total so the
#                          60% target is met exactly when clean supply
#                          allows (it does)
#   clean_devanagari       teacher + edge rows, register devanagari or
#                          elder_fragmented (both Devanagari script)
#   romanized_codeswitched teacher + edge rows, register romanized or
#                          code_switched
#
# Measured supply (2026-09-07): noised.jsonl holds 29,304 rows but only
# 2,458 DISTINCT utterances — whisper outputs converge hard, so the file
# is ~12 copies per text; 703 of the distinct texts carry CONTRADICTORY
# labels across their copies (different parents collapsed onto one
# transcript) and are dropped wholesale rather than taught arbitrary
# labels. teacher.jsonl: ~14.3k distinct rows across the 4 registers,
# BUT 0 ack_med rows (seed taxonomy never defined the intent — round-1
# ack gates failed because ack was never taught; data/edge_cases.jsonl
# supplies them, always kept, exempt from clean-bucket sampling).
#
# Round 3 findings (bake-off iteration-3, 2026-09-09) → ANCHORED DRAW
# (bake-off iteration-4, 2026-09-09): the rng(seed) whole-pool shuffle +
# slice draw made every selection step a function of pool LENGTH — the
# RNG stream position at each draw depends on all earlier draws' sizes,
# so any pool growth (a new gen/noise run appends rows) silently re-drew
# ~1000 of 2827 rows between builds, old rows swapped for other old rows
# by lottery. Iteration deltas were therefore not interpretable.
#
# All draws now use CONTENT-ADDRESSED keys (draw_key): a pure function of
# (mixture.seed, namespace, row bytes). Identical inputs rebuild a
# byte-identical dataset, and append-only pool growth can only move a
# selection boundary by the share of genuinely new rows — an existing row
# never changes key, so it is never re-drawn out in favor of another old
# row. No RNG stream is consumed anywhere, so no draw can shift another.
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import string
import unicodedata
from pathlib import Path

from config import load_config

# Canonical app wire shape (2026-09-12 reconciliation): `intent`/`response`
# (IntentPrompt.swift's structured-response contract), not the legacy
# action/reply names the pre-reconciliation rows carried.
SCHEMA_FIELDS = {
    "intent": str, "entryId": (str, type(None)), "contact": (str, type(None)),
    "time": (str, type(None)), "medication": (str, type(None)),
    "message": (str, type(None)), "callType": (str, type(None)),
    "requestedApp": (str, type(None)), "topic": (str, type(None)),
    "steps": (list, type(None)), "confidence": (int, float), "response": str,
}
VALID_INTENTS = {"ack_med", "call", "emergency", "set_reminder", "health_query",
                 "music", "send_message", "guide", "create_calendar_event",
                 "suggest_video", "query", "none"}

DEV_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")

# register → mixture bucket. elder_fragmented is Devanagari-script speech,
# so it belongs to the clean-devanagari side of the §9.2 axis.
BUCKET_OF_REGISTER = {
    "devanagari": "clean_devanagari",
    "elder_fragmented": "clean_devanagari",
    "romanized": "romanized_codeswitched",
    "code_switched": "romanized_codeswitched",
}
NOISED_SOURCES = ("stt_noise",)
EDGE_SOURCES = ("edge_cases",)
BUCKET_NAMES = ("stt_noised", "clean_devanagari", "romanized_codeswitched")


def normalize(text: str) -> str:
    """Mirror of the app's NepaliTextNormalizer (leakage checks must use
    the SAME normalization the cache/resolver keys use)."""
    nfc = unicodedata.normalize("NFC", text).translate(DEV_DIGITS).lower()
    stripped = re.sub(r"[।॥\W_]+", " ", nfc, flags=re.UNICODE)
    return " ".join(stripped.split())


def lossless_key(text: str) -> str:
    """Dedupe key (NOT the leakage key): near-lossless — NFC, Devanagari
    digits folded, casefolded, ASCII punctuation + danda stripped,
    whitespace collapsed. Keeps vowel signs: two utterances that differ
    by a matra are distinct training examples (round-1's matra-stripping
    skeleton key erased the whole STT-noised axis). Only true textual
    duplicates (punct/space/case-level differences) collapse."""
    nfc = unicodedata.normalize("NFC", text).translate(DEV_DIGITS).casefold()
    stripped = re.sub(r"[" + re.escape(string.punctuation) + r"॥।\s]+", " ", nfc)
    return " ".join(stripped.split())


# Schema-key reconciliation (2026-09-12): the label keys were renamed
# action→intent / reply→response with row CONTENT unchanged. draw_key
# hashes the full row JSON, so without canonicalization the rename flips
# every row's key and the anchored draw re-selects the mixture wholesale
# (measured on the first post-rename rebuild: 2061 of 2686 rows swapped —
# exactly the old-for-old churn the anchored draw exists to prevent, and
# it would have made the iteration's bake-off delta uninterpretable).
# Hashing the LEGACY-keyed form of the row keeps every pre/post-rename row
# on the same key; a genuine label/slot edit still changes it.
LEGACY_LABEL_KEYS = {"intent": "action", "response": "reply"}


def draw_key(row: dict, seed, namespace: str) -> bytes:
    """Content-addressed selection key (iteration-4 anchored draw).

    Pure function of (mixture.seed, namespace, row bytes) — NOT of file
    order, pool length or RNG stream position. Consequences:
      * identical inputs → identical keys → byte-identical rebuilds;
      * append-only pool growth never reshuffles existing rows: a row
        keeps its key forever and can only leave a take by being pushed
        past the boundary by genuinely new rows whose keys sort in;
      * no shared RNG stream, so no draw's size can shift another draw.
    Keys are 64-bit blake2b digests of the full row JSON in its
    legacy-canonical key form (see LEGACY_LABEL_KEYS), so two rows that
    differ in ANY content field (label value, slots, source, register)
    draw independently while a pure schema-key rename does not re-draw."""
    canonical = {LEGACY_LABEL_KEYS.get(k, k): v for k, v in row.items()}
    content = json.dumps(canonical, sort_keys=True, ensure_ascii=False)
    return hashlib.blake2b(f"{seed}|{namespace}|{content}".encode("utf-8"),
                           digest_size=8).digest()


def valid_row(row: dict) -> bool:
    if row.get("intent") not in VALID_INTENTS:
        return False
    if not row.get("utterance"):
        return False
    for field, types in SCHEMA_FIELDS.items():
        if field not in row or not isinstance(row[field], types):
            return False
    conf = row["confidence"]
    return 0.0 <= float(conf) <= 1.0


def load_golden_keys(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {normalize(json.loads(line)["utterance"])
            for line in open(path, encoding="utf-8") if line.strip()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true",
                        help="validate data/sample.jsonl only")
    args, cfg = load_config(parser)
    root = Path(__file__).parent.parent

    if args.smoke:
        sources = [root / "data" / "sample.jsonl"]
    else:
        sources = [root / "data" / "teacher.jsonl",
                   root / "data" / "noised.jsonl",
                   root / "data" / "edge_cases.jsonl"]
    raw: list[dict] = []
    for src in sources:
        if not src.exists():
            print(f"[build] warning: {src.name} missing — skipped")
            continue
        with open(src, encoding="utf-8") as f:
            raw.extend(json.loads(line) for line in f if line.strip())

    golden = load_golden_keys(root / "eval" / "golden_corpus.jsonl")
    frac = {b: float(cfg[f"mixture.{b}"]) for b in
            ("stt_noised", "clean_devanagari", "romanized_codeswitched")}

    # Bucket + validate + leak-check first, dedupe inside each bucket after.
    buckets: dict[str, list[dict]] = {b: [] for b in BUCKET_NAMES}
    dropped = {"schema": 0, "leak": 0}
    for row in raw:
        if not valid_row(row):
            dropped["schema"] += 1
            continue
        if normalize(row["utterance"]) in golden:
            dropped["leak"] += 1
            continue
        source = (row.get("source") or "").split(":")[0]
        register = row.get("register")
        if source in NOISED_SOURCES:
            bucket = "stt_noised"
        elif register and register in BUCKET_OF_REGISTER:
            bucket = BUCKET_OF_REGISTER[register]
        else:
            dropped["schema"] += 1  # no usable register → not classifiable
            continue
        buckets[bucket].append(row)

    # Draw anchor: mixture.seed from config.yaml. draw_key() is a pure
    # function of this seed — no RNG object is used anywhere below.
    seed = cfg["mixture.seed"]

    # Per-bucket label-conflict guard + dedupe (lossless key, anchored
    # winner). CONFLICT GUARD FIRST: when several copies of the SAME
    # utterance disagree on the intent, every copy is dropped — teaching
    # one arbitrary label for a text that occurs with two is noise
    # (measured: 703 noised keys carry contradictory labels; the two
    # whisper variants of different parents collapse onto one
    # transcript). Only then dedupe within the surviving rows: which copy
    # of a duplicate survives is the one with the smallest draw_key —
    # content-addressed, so pool growth can never flip an old duplicate
    # pair (round-3 shuffle made the winner a function of pool length).
    kept: dict[str, list[dict]] = {}
    for bucket in BUCKET_NAMES:
        rows = list(buckets[bucket])
        by_intent: dict[str, set] = {}
        for row in rows:
            by_intent.setdefault(lossless_key(row["utterance"]), set()).add(row["intent"])
        conflict_keys = {k for k, acts in by_intent.items() if len(acts) > 1}
        rows = [r for r in rows if lossless_key(r["utterance"]) not in conflict_keys]
        keyed = sorted((draw_key(r, seed, f"dedupe-{bucket}"), r) for r in rows)
        best: dict[str, dict] = {}
        for _, r in keyed:  # ascending key → smallest key wins per lossless key
            best.setdefault(lossless_key(r["utterance"]), r)
        kept[bucket] = [best[k] for k in sorted(best)]
        if conflict_keys:
            print(f"[build] {bucket}: dropped {len(conflict_keys)} "
                  "conflicting-label keys")

    # A noised text that is byte-equal to a surviving clean text is not an
    # STT-noised example — it is the clean example under a noise label that
    # may contradict it. Drop from the noised side (counted as dup_clean).
    clean_keys = {lossless_key(r["utterance"]) for r in kept["clean_devanagari"]}
    clean_keys |= {lossless_key(r["utterance"])
                   for r in kept["romanized_codeswitched"]}
    before = len(kept["stt_noised"])
    kept["stt_noised"] = [r for r in kept["stt_noised"]
                          if lossless_key(r["utterance"]) not in clean_keys]
    dup_clean = before - len(kept["stt_noised"])

    # Mixture: the noised bucket anchors the total (it is the scarce
    # supply — round-1's failure was starving it, not over-using it), then
    # the clean buckets are sampled toward their §9.2 share, capped by
    # supply. edge_cases rows are always kept (priority) — they carry the
    # round-2 intent fixes (ack_med/refusal/bare-emergency) and must not
    # be sampled away. The take is the `take` rows with the smallest
    # draw_key (anchored — see module docstring): pool growth admits only
    # the boundary share of genuinely new rows, never old-for-old churn.
    n_noised = len(kept["stt_noised"])
    total = math.ceil(n_noised / frac["stt_noised"])
    targets = {"clean_devanagari": round(total * frac["clean_devanagari"]),
               "romanized_codeswitched": round(total * frac["romanized_codeswitched"])}
    selected: dict[str, list[dict]] = {"stt_noised": kept["stt_noised"]}
    supply_capped: list[str] = []
    for bucket, target in targets.items():
        rows = list(kept[bucket])
        priority = [r for r in rows if (r.get("source") or "").startswith(EDGE_SOURCES)]
        pool = sorted((r for r in rows if r not in priority),
                      key=lambda r: draw_key(r, seed, f"mix-{bucket}"))
        take = max(0, target - len(priority))
        if len(pool) < take:
            supply_capped.append(bucket)
            take = len(pool)
        selected[bucket] = priority + pool[:take]

    # Train/valid split: first n_valid rows of the keyed total order
    # (5% over the whole mixture, as before) — anchored like every other
    # draw, so a rebuild only moves the split boundary where membership
    # itself changed.
    train_pool = sorted(selected["stt_noised"] + selected["clean_devanagari"]
                        + selected["romanized_codeswitched"],
                        key=lambda r: draw_key(r, seed, "split"))
    n_valid = max(1, int(len(train_pool) * float(cfg["mixture.valid_fraction"])))
    valid, train = train_pool[:n_valid], train_pool[n_valid:]

    for name, split in (("train", train), ("valid", valid)):
        out = root / "data" / f"{name}.jsonl"
        with open(out, "w", encoding="utf-8") as f:
            for row in split:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    # Report: achieved mix vs targets (with supply caps called out).
    total_kept = sum(len(v) for v in selected.values())
    achieved = {b: len(v) / total_kept for b, v in selected.items()}
    print(f"[build] kept {total_kept} rows (train {len(train)}, valid {len(valid)})")
    print(f"[build] dropped: {dropped}")
    print(f"[build] mixture by bucket: "
          + ", ".join(f"{b} {len(v)} ({achieved[b]:.1%})"
                      for b, v in selected.items()))
    print(f"[build] mixture targets: "
          + ", ".join(f"{b} {frac[b]:.0%}" for b in BUCKET_NAMES))
    if dup_clean:
        print(f"[build] noised: {dup_clean} rows byte-equal to a clean row "
              "dropped as dup_clean")
    for b in BUCKET_NAMES:
        diff = achieved[b] - frac[b]
        if abs(diff) > 0.005:
            flag = " (SUPPLY-CAPPED)" if b in supply_capped else ""
            print(f"[build] NOTE: {b} {achieved[b]:.1%} vs target "
                  f"{frac[b]:.0%} (Δ {diff:+.1%}){flag}")
    if dropped["leak"]:
        print("[build] NOTE: leakage rows were REFUSED — investigate gen_teacher overlap with the golden corpus")


if __name__ == "__main__":
    main()
