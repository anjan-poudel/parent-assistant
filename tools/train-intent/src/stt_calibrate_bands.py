"""Correction-band calibration over the REAL STT error stream.

The correction-revive follow-up (2026-10-11): the shipped banded gate kept
the v3 measured operating point (recall 0.0005 — near-inert) because no
measurement existed for a wider silent-apply set. The measurement now
exists: `data/noised.jsonl` carries `clean_utterance` beside every noised
utterance — 29,304 real (noised → clean) utterance pairs produced by the
shipped STT noise injector. This stage replays the SHIPPED scorer
(`build_correction_banks`'s surface terms + the n-gram bank's prior, the
same weights `SttErrorCorrector` uses) over those pairs and sweeps the
banded operating point, so a wider silent-apply gate is a MEASURED
decision (A-12/C-11 discipline), not an authored guess.

CPU-only. Read-only over its inputs.

Outputs (--out-dir):
  - calibration-report.json — the sweep grid, the precision/recall table,
    the chosen operating point and the number of pairs each band claims;
  - bands.json — the `bands` block to splice into stt-ngram-prior.json
    (plus the measured precision/recall/manifest fields).

Run on the training box from tools/train-intent/:

    python3 src/stt_calibrate_bands.py \
        --pairs data/noised.jsonl \
        --ngram-bank <repo>/ios/ElderlyAssistant/Resources/VariantTables/stt-ngram-prior.json \
        --pair-bank <repo>/ios/ElderlyAssistant/Resources/VariantTables/canonical-stt-reductions.json \
        --phonetic <repo>/ios/ElderlyAssistant/Resources/VariantTables/phonetic-key.json \
        --out-dir /tmp/band-calibration

The scorer mirrors `SttErrorCorrector` exactly: same weights, same
prefix/similarity/phonetic terms, the n-gram prior normalised by the
bank's totals, margin over the runner-up, the candidate pool capped the
same way. Any Swift/Python drift here is a wrong measurement, so the
pieces are REUSED from `build_correction_banks` wherever they exist.
"""
from __future__ import annotations

import argparse
import difflib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_correction_banks import core, nfc, similarity, prefix_completion, within, levenshtein  # noqa: E402
from pipeline_guards import EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402

# The SHIPPED weights (SttErrorCorrector.Weights.authored, pinned by the
# bank and by tests). The calibration must replay THESE, not a copy that
# can drift.
WEIGHTS = {"similarity": 0.35, "prefixCompletion": 0.40, "phoneticKey": 0.15,
           "ngramPrior": 0.10}
MARGIN_THRESHOLD = 0.15
MAX_CANDIDATES = 8
MAX_PREFIX_SLACK = 4
PREFIX_PENALTY_STEP = 0.25
LENGTH_WINDOW = 2
LEVENSHTEIN_BOUND = 2
POOL_CAP = 3 * MAX_CANDIDATES


class GuardError(Exception):
    pass


def tokenize(text: str) -> list:
    return [t for t in nfc(text).split() if t]


def load_phonetic(path: Path) -> tuple[dict, set]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    resolved = raw["resolvedKey"]
    return (dict(resolved["unify"]), set(resolved["elide"]))


def phonetic_key(token: str, unify: dict, elide: set) -> tuple:
    out = []
    for scalar in token:
        if scalar in elide:
            continue
        out.append(unify.get(scalar, scalar))
    return tuple(out)


def load_ngram_bank(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8"))
    lexicon = [row["token"] for row in raw["lexicon"]]
    ordinal = {token: index for index, token in enumerate(lexicon)}
    bigrams = {key: float(count) for key, count in raw["bigrams"].items()}
    bigram_total = float(raw["totals"]["bigrams"])
    trigram_total = float(raw["totals"]["trigrams"])
    deletes = raw["symspell"]["deletes"]
    return {
        "lexicon": lexicon,
        "ordinal": ordinal,
        "bigrams": bigrams,
        "bigram_total": bigram_total,
        "trigram_total": trigram_total,
        "deletes": deletes,
    }


def load_pair_bank(path: Path) -> list:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [row["token"] for row in raw["correctionBank"]["lexicon"]]


def ngram_prior(candidate: str, neighbours: list, bank: dict) -> float:
    best = 0.0
    for neighbour in neighbours:
        forward = bank["bigrams"].get(f"{neighbour}\u0001{candidate}", 0)
        backward = bank["bigrams"].get(f"{candidate}\u0001{neighbour}", 0)
        best = max(best, forward, backward)
    total = max(bank["bigram_total"], bank["trigram_total"])
    if total <= 0:
        return 0.0
    return min(1.0, best / total)


def build_indexes(pair_lexicon: list, bank: dict,
                  phonetic: tuple[dict, set]) -> dict:
    """The generation indexes, built ONCE — the Python twin of
    `CorrectionLexicon`'s wiring-time indexes, so the big-vocabulary bank
    does not turn the fit into a per-instance linear scan."""
    unify, elide = phonetic
    prefix_index: dict = defaultdict(list)
    length_buckets: dict = defaultdict(list)
    key_index: dict = defaultdict(list)
    for source in (pair_lexicon, bank["lexicon"]):
        for candidate in source:
            length_buckets[len(candidate)].append(candidate)
            for stop in range(1, len(candidate) + 1):
                prefix_index[candidate[:stop]].append(candidate)
            key_index[phonetic_key(candidate, unify, elide)].append(candidate)
    return {"prefix": prefix_index, "lengths": length_buckets,
            "keys": key_index, "deletes": bank["deletes"],
            "lexicon": bank["lexicon"]}


def candidates_indexed(token: str, indexes: dict,
                       phonetic: tuple[dict, set]) -> list:
    """The shipped generator over INDEXES — the same tiers and the same
    [POOL-BALANCE] per-tier caps as `SttErrorCorrector.candidates(for:)`
    (prefix 6, edit 8, key 6, symspell 8; the measured fix for the
    prefix-flood that starved the true word out of the pool)."""
    unify, elide = phonetic
    length = len(token)
    pool: list = []
    seen: set = set()

    prefix_tier: list[tuple] = []
    for candidate in indexes["prefix"].get(token, []):
        if candidate == token:
            continue
        added = len(candidate) - length
        if 1 <= added <= MAX_PREFIX_SLACK:
            prefix_tier.append((added, candidate))
    prefix_tier.sort()
    for _, candidate in prefix_tier[:6]:
        if candidate not in seen:
            seen.add(candidate)
            pool.append(candidate)

    if length > 0:
        bound = min(LEVENSHTEIN_BOUND, length // 3)
        if bound > 0:
            edit_tier: list[tuple] = []
            for size in range(max(1, length - LENGTH_WINDOW),
                              length + LENGTH_WINDOW + 1):
                for candidate in indexes["lengths"].get(size, []):
                    if candidate == token or candidate in seen:
                        continue
                    if within(token, candidate, bound):
                        edit_tier.append((levenshtein(token, candidate),
                                          candidate))
            edit_tier.sort()
            for _, candidate in edit_tier[:8]:
                if candidate not in seen:
                    seen.add(candidate)
                    pool.append(candidate)

    key = phonetic_key(token, unify, elide)
    key_tier: list = []
    for candidate in indexes["keys"].get(key, []):
        if candidate == token or candidate in seen:
            continue
        if abs(len(candidate) - length) <= LENGTH_WINDOW:
            key_tier.append(candidate)
    key_tier.sort()
    for candidate in key_tier[:6]:
        if candidate not in seen:
            seen.add(candidate)
            pool.append(candidate)

    for form in set(token[:i] + token[i + 1:] for i in range(len(token))):
        for ordinal in indexes["deletes"].get(form, []):
            candidate = indexes["lexicon"][ordinal]
            if candidate != token and candidate not in seen:
                if abs(len(candidate) - length) <= LENGTH_WINDOW:
                    if length > 0 and within(token, candidate,
                                            min(LEVENSHTEIN_BOUND,
                                                length // 3)):
                        seen.add(candidate)
                        pool.append(candidate)
    return pool[:POOL_CAP]


def score_instances(instances: list, indexes: dict,
                    phonetic: tuple[dict, set], bank: dict) -> list:
    """One scored row per error instance: the top candidate with its
    surface/total/margin, plus the clean token's own score when it made
    the pool (for recall accounting). Computed ONCE — the sweep below
    reads these rows, never re-generates.

    The candidate POOL is cached per unique noisy token: the error
    corpus repeats a small set of noisy forms across its 29k pairs, and
    generation is the dominant cost (measured 45 s / 500 instances on
    the 57k-word bank before this cache). Scoring stays per instance —
    the n-gram term reads the pair's own neighbours."""
    rows = []
    pool_cache: dict = {}
    for index, (token, clean_token, neighbours, sentence, row_id) in enumerate(instances):
        if token not in pool_cache:
            pool_cache[token] = candidates_indexed(token, indexes, phonetic)
        pool = pool_cache[token]
        if index and index % 5000 == 0:
            print(f"[score] {index}/{len(instances)} "
                  f"(unique tokens {len(pool_cache)})", file=sys.stderr)
        if not pool:
            rows.append({"token": token, "clean": clean_token,
                         "sentence": sentence,
                         "best": None, "surface": 0.0, "total": 0.0,
                         "margin": 0.0, "clean_in_pool": False,
                         "clean_rank": None, "id": row_id})
            continue
        ranked = []
        for candidate in pool:
            scored = score_candidate(token, candidate, neighbours,
                                     phonetic, bank)
            ranked.append((scored["total"], candidate, scored))
        ranked.sort(key=lambda item: (item[0], item[1]), reverse=True)
        best_total, best_candidate, best_scored = ranked[0]
        runner_up = ranked[1][0] if len(ranked) > 1 else 0.0
        clean_in_pool = any(candidate == clean_token
                            for _, candidate, _ in ranked)
        clean_rank = None
        for position, (_, candidate, _) in enumerate(ranked):
            if candidate == clean_token:
                clean_rank = position
                break
        rows.append({"token": token, "clean": clean_token,
                     "sentence": sentence,
                     "best": best_candidate, "surface": best_scored["surface"],
                     "total": best_total, "margin": best_total - runner_up,
                     "clean_in_pool": clean_in_pool, "clean_rank": clean_rank,
                     "id": row_id})
    return rows


def sweep(rows: list, precision_floor: float) -> tuple[list, dict]:
    # [SWEEP-SPACE] The real error stream scores LOW on surface (the
    # diagnostic instance: clean ranked #1, surface 0.44, margin 0.06) —
    # so the floor sweeps DOWN to 0.20 and the margin is swept too. A
    # point with no predictions is NOT eligible: "precision 1.0 on zero
    # applications" is not a measurement, and neither is a point whose
    # evidence is a handful of pairs (min_tp).
    floors = [n / 100 for n in range(20, 96, 5)]
    margins = [0.02, 0.05, 0.08, 0.10, 0.12, 0.15]
    min_tp = 50
    grid = []
    chosen = None
    for floor in floors:
        for apply_total in [t for t in floors if t >= floor]:
            for margin_threshold in margins:
                tp = fp = fn = judge_eligible = no_candidate = 0
                for row in rows:
                    if row["best"] is None:
                        no_candidate += 1
                        continue
                    if (row["surface"] >= floor
                            and row["total"] >= apply_total
                            and row["margin"] >= margin_threshold):
                        if row["best"] == row["clean"]:
                            tp += 1
                        else:
                            fp += 1
                    else:
                        fn += 1
                        if row["surface"] >= 0.40:
                            judge_eligible += 1
                precision = tp / (tp + fp) if (tp + fp) else None
                recall = tp / (tp + fn) if (tp + fn) else 0.0
                entry = {"surfaceFloor": floor, "applyTotal": apply_total,
                         "marginThreshold": margin_threshold,
                         "tp": tp, "fp": fp, "fn": fn,
                         "precision": (round(precision, 4)
                                       if precision is not None else None),
                         "recall": round(recall, 4),
                         "judge_eligible": judge_eligible,
                         "no_candidate": no_candidate}
                grid.append(entry)
                if (precision is not None and tp >= min_tp
                        and precision >= precision_floor):
                    if (chosen is None or recall > chosen["recall"]
                            or (recall == chosen["recall"]
                                and floor > chosen["surfaceFloor"])):
                        chosen = dict(entry)
    return grid, chosen


def score_candidate(token: str, candidate: str, neighbours: list,
                    phonetic: tuple[dict, set], bank: dict) -> dict:
    """The shipped scoring, replayed: surface terms + the n-gram prior,
    total = surface + w·prior (the context priors l1/l2/l3 are zero here —
    the calibration corpus's frame priors were fitted on the golden
    fixture, not this error stream, and the design bounds them at 0.10)."""
    unify, elide = phonetic
    sim = similarity(token, candidate)
    prefix = prefix_completion(token, candidate)
    key_hit = phonetic_key(token, unify, elide) == phonetic_key(candidate,
                                                               unify, elide)
    surface = (WEIGHTS["similarity"] * sim
               + WEIGHTS["prefixCompletion"] * prefix
               + WEIGHTS["phoneticKey"] * (1.0 if key_hit else 0.0))
    prior = ngram_prior(candidate, neighbours, bank)
    total = surface + WEIGHTS["ngramPrior"] * prior
    return {"surface": surface, "total": total, "prior": prior,
            "prefix": prefix, "similarity": sim, "key_hit": key_hit}


def error_instances(pairs_path: Path, limit: int | None) -> list:
    """(noisy token, clean token, neighbours, sentence_id) per mismatched
    token.

    [ALIGN-FIX] Pairing is CHARACTER-LEVEL, not token-level: the noise
    injector merges and splits words, so a token-list difflib zip pairs
    unrelated spans (measured: pairs like ज्योटिभिको→यो). Character
    difflib over the JOINED strings finds the true mismatched spans;
    only spans that sit at word boundaries and map ONE noisy token to
    ONE clean token of comparable length are kept — merger/split rows
    are skipped, not mis-paired."""
    instances: list = []
    rows = []
    for line in pairs_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    if limit:
        rows = rows[:limit]
    for row in rows:
        noisy_tokens = [core(t) for t in tokenize(row["utterance"])]
        clean_tokens = [core(t) for t in tokenize(row["clean_utterance"])]
        noisy_text = row["utterance"]
        clean_text = row["clean_utterance"]
        matcher = difflib.SequenceMatcher(a=noisy_text, b=clean_text,
                                          autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            # The mismatched spans must be interior word spans: the
            # span's boundaries fall on word boundaries in BOTH texts,
            # and each span covers exactly one token on its side.
            def spans_word(text: str, start: int, end: int) -> bool:
                if start > 0 and text[start - 1] != " ":
                    return False
                if end < len(text) and text[end] != " ":
                    return False
                if " " in text[start:end]:
                    return False
                return bool(text[start:end].strip())
            if not spans_word(noisy_text, i1, i2):
                continue
            if not spans_word(clean_text, j1, j2):
                continue
            noisy_token = core(noisy_text[i1:i2])
            clean_token = core(clean_text[j1:j2])
            if not noisy_token or not clean_token:
                continue
            # A real single-word error, not a mis-aligned merger.
            if noisy_token not in noisy_tokens or clean_token not in clean_tokens:
                continue
            neighbours = []
            position = clean_tokens.index(clean_token)
            if position > 0:
                neighbours.append(clean_tokens[position - 1])
            if position + 1 < len(clean_tokens):
                neighbours.append(clean_tokens[position + 1])
            instances.append((noisy_token, clean_token, neighbours,
                              noisy_text, row.get("id", "")))
    return instances


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairs", type=Path, required=True,
                        help="noised.jsonl (utterance + clean_utterance rows)")
    parser.add_argument("--ngram-bank", type=Path, required=True)
    parser.add_argument("--pair-bank", type=Path, required=True)
    parser.add_argument("--phonetic", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--min-pairs", type=int, default=5000)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    args = parser.parse_args()

    try:
        for path in (args.pairs, args.ngram_bank, args.pair_bank,
                     args.phonetic):
            if not path.is_file():
                raise GuardError(f"missing input: {path}")
        bank = load_ngram_bank(args.ngram_bank)
        pair_lexicon = load_pair_bank(args.pair_bank)
        phonetic = load_phonetic(args.phonetic)
        instances = error_instances(args.pairs, limit=None)
        if len(instances) < args.min_pairs:
            print(f"floor refused: {len(instances)} error pairs < "
                  f"--min-pairs {args.min_pairs}", file=sys.stderr)
            return EXIT_FLOOR
    except GuardError as refused:
        print(f"guard refused: {refused}", file=sys.stderr)
        return EXIT_GUARD
    except Exception as failure:  # noqa: BLE001 — the house exit vocabulary
        print(f"stage failed: {failure}", file=sys.stderr)
        return EXIT_STAGE

    indexes = build_indexes(pair_lexicon, bank, phonetic)
    rows = score_instances(instances, indexes, phonetic, bank)
    grid, chosen = sweep(rows, args.precision_floor)

    if chosen is None:
        print("no operating point clears the precision floor — the grid "
              "report still names the best measured row", file=sys.stderr)
        # The None-precision rows (no predictions) are not measurements —
        # the fallback ranks only rows that predicted something.
        eligible = [row for row in grid if row["precision"] is not None]
        chosen = max(eligible, key=lambda row: (row["precision"],
                                                row["recall"])) if eligible else {
            "surfaceFloor": 0.95, "applyTotal": 0.95, "marginThreshold": 0.15,
            "tp": 0, "fp": 0, "fn": len(rows),
            "precision": None, "recall": 0.0, "judge_eligible": 0,
            "no_candidate": 0, "note": "no point predicted anything",
        }

    report = {
        "generation": {
            "status": "MEASURED-FROM-CORPUS",
            "tool": "stt_calibrate_bands.py",
            "date": "2026-10-11",
        },
        "corpus": {
            "pairs": len(instances),
            "note": ("error pairs = noised.jsonl rows (utterance vs "
                     "clean_utterance), aligned token-wise"),
        },
        "weights": WEIGHTS,
        "marginThreshold": MARGIN_THRESHOLD,
        "precision_floor": args.precision_floor,
        "chosen": chosen,
        "grid": grid,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "calibration-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")
    bands = {
        "surfaceFloor": chosen["surfaceFloor"],
        "applyTotal": chosen["applyTotal"],
        "judgeMin": 0.40,
        "measured": {
            "precision": chosen["precision"],
            "recall": chosen["recall"],
            "tp": chosen["tp"], "fp": chosen["fp"], "fn": chosen["fn"],
            "pairs": len(instances),
            "runRevision": "correction-banks/v4#band-fit",
        },
        "origin": ("silent-apply band fitted over the shipped noise corpus's "
                   f"{len(instances)} error pairs at precision >= "
                   f"{args.precision_floor}; judgeMin remains the authored "
                   "conversational floor"),
    }
    (args.out_dir / "bands.json").write_text(
        json.dumps(bands, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")

    print(f"[calibrate] pairs {len(instances)}; chosen floor "
          f"{chosen['surfaceFloor']} applyTotal {chosen['applyTotal']} "
          f"precision {chosen['precision']} recall {chosen['recall']} "
          f"(tp {chosen['tp']} fp {chosen['fp']} fn {chosen['fn']}, "
          f"judge-eligible {chosen['judge_eligible']})")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
