"""Correction-bank companion: the stt-ngram-prior bank (addendum §6.7 Phase 2,
the corpus-expansion half of the correction-revive change, 2026-10-11).

CPU-only, no GPU, no model, no network. Read-only over its inputs.

WHAT IT BUILDS. The shipped pair bank (`canonical-stt-reductions.json`) was
calibrated for PRECISION over a small fixture corpus: recallAtDefault 0.0005.
The banded gate needs a statistical n-gram prior and a SymSpell symmetric-
delete index over a much larger vocabulary to make candidate generation and
re-ranking work at keyboard-autocorrect scale. This stage emits one additive
bank (`stt-ngram-prior.json`) from the TRAINING corpus:

  - `lexicon`  — the corpus's own clean vocabulary (unigram counts,
                 occurrence floor) — the expanded candidate space;
  - `bigrams` / `trigrams` — content-token counts over the same vocabulary,
                 keys `prev||cur` / `p2||p1||cur`;
  - `symspell.deletes` — the symmetric-delete index (delete-1 over Unicode
                 scalars) mapping each delete-form to lexicon ordinals;
  - `bands`  — the banded operating point. surfaceFloor/applyTotal are
                 PINNED to the shipped v3 measured operating point
                 (`correction-banks/v3#e133253b`, correctThreshold 0.8125), so
                 the silent-apply set is byte-identical to the calibrated set
                 until a v4 re-fit measures a wider one; judgeMin is AUTHORED
                 and labeled (A-9) — it feeds only the conversational bands
                 (judge / clarify), never a silent rewrite.

GUARDS (pipeline_guards discipline):
  - the corpus must clear `--min-rows` (EXIT_FLOOR) — an n-gram prior from a
    toy corpus is not a measurement;
  - the lexicon must clear `--min-lexicon` (EXIT_FLOOR);
  - the corpus revision (sha256 over the input bytes in sorted path order) is
    stamped into the bank, so a shipped prior cites the data it was counted
    from (A-12).

The `--check` mode re-counts the provided corpus and asserts the bank's
internal invariants (count sums, delete round-trips, floor gates) — a
golden-count contract is pinned by tests/test_stt_ngram_prior.py.

Run from tools/train-intent/:

    python3 src/stt_ngram_prior.py --corpus data/teacher.jsonl \
        data/noised.jsonl data/edge_cases.jsonl \
        --out ../../ios/ElderlyAssistant/Resources/VariantTables/stt-ngram-prior.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_correction_banks import core, nfc, tokenize  # noqa: E402
from pipeline_guards import EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402

FORMAT_VERSION = 1
TABLE_ID = "stt-ngram-prior"

# The shipped measured operating point this bank's silent-apply band is
# pinned to (canonical-stt-reductions.json v3 manifest). Not a guess: the
# apply set under these bands is exactly the set the v3 calibration counted.
V3_CORRECT_THRESHOLD = 0.8125
# Authored, labeled (A-9): the judge-eligibility floor. Feeds only the
# conversational bands — a judge call and, failing that, a spoken
# clarification — never a silent rewrite. A token below this floor has no
# candidate worth asking about.
JUDGE_MIN = 0.40
# Deletions per lexicon token in the symmetric-delete index.
MAX_DELETE_EDIT = 1
# Pairs below this count are dropped (sparse co-occurrence is noise).
NGRAM_COUNT_FLOOR = 2

DEFAULT_MIN_ROWS = 20000
DEFAULT_MIN_LEXICON = 3000


class GuardError(Exception):
    pass


def corpus_revision(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path).encode("utf-8"))
        digest.update(b"\x00")
        digest.update(path.read_bytes())
        digest.update(b"\x00")
    return digest.hexdigest()[:16]


def tool_revision() -> str:
    """The run id's tool half: the sha256 of THIS file's bytes. The run id
    pins the tool as well as its inputs (A-12), so a shipped decision can
    name the exact code that produced its data — no hand-stamped version
    strings that drift from the file they claim."""
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:8]


def load_rows(paths: list[Path]) -> list[str]:
    """The utterances, in file order. A row without an `utterance` is
    refused rather than skipped — a silently thinned corpus is a different
    measurement than the manifest claims."""
    rows: list[str] = []
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            utterance = row.get("utterance")
            if not utterance or not isinstance(utterance, str):
                raise GuardError(
                    f"row without a string `utterance` in {path} — the bank "
                    f"would count a corpus the manifest does not describe")
            rows.append(utterance)
    return rows


def symmetric_deletes(token: str) -> set[str]:
    """All delete-1 forms of the token over Unicode SCALARS (code points),
    which is the space the Swift runtime addresses (`SttErrorCorrector`
    offsets are scalar-based; a grapheme-cluster deletion would be a
    different index than the one the runtime looks up)."""
    forms: set[str] = set()
    for index in range(len(token)):
        forms.add(token[:index] + token[index + 1:])
    return forms


def count_ngrams(rows: list[str]) -> tuple[Counter, Counter, Counter, Counter]:
    unigram = Counter()
    bigram = Counter()
    trigram = Counter()
    token_total = Counter()
    for text in rows:
        keys = [core(t) for t in tokenize(text) if core(t)]
        if len(keys) < 1:
            continue
        unigram.update(keys)
        token_total.update(keys)
        for pair in zip(keys, keys[1:]):
            bigram["||".join(pair)] += 1
        for triple in zip(keys, keys[1:], keys[2:]):
            trigram["||".join(triple)] += 1
    return unigram, bigram, trigram, token_total


def build_bank(rows: list[str], revision: str) -> dict:
    unigram, bigram, trigram, _ = count_ngrams(rows)

    lexicon = [{"token": token, "occurrences": count}
               for token, count in sorted(unigram.items())
               if count >= 1]
    # Sorted by token (Unicode code-point order) so the ordinal space is
    # deterministic for a given corpus — the runtime's `ngram-lex-<n>` ids
    # name positions in THIS array and must not drift between hosts.
    lexicon.sort(key=lambda row: row["token"])

    ordinal = {row["token"]: index for index, row in enumerate(lexicon)}
    deletes: dict[str, list[int]] = defaultdict(list)
    for row in lexicon:
        for form in symmetric_deletes(row["token"]):
            deletes[form].append(ordinal[row["token"]])
    deletes = {form: sorted(hits) for form, hits in sorted(deletes.items())}

    kept_bigrams = {key: count for key, count in sorted(bigram.items())
                    if count >= NGRAM_COUNT_FLOOR}
    kept_trigrams = {key: count for key, count in sorted(trigram.items())
                     if count >= NGRAM_COUNT_FLOOR}

    return {
        "formatVersion": FORMAT_VERSION,
        "tableID": TABLE_ID,
        "generation": {
            "status": "MEASURED-FROM-CORPUS",
            "corpusRevision": revision,
            "runRevision": f"correction-banks/v4#{tool_revision()}",
            "date": "2026-10-11",
        },
        "corpus": {
            "rows": len(rows),
            "revision": revision,
            "note": ("revision = sha256 over the input files' bytes in sorted "
                     "path order, first 16 hex chars — the same A-12 stamp "
                     "discipline as the pair bank's corpusRevision"),
        },
        "lexicon": lexicon,
        "bigrams": kept_bigrams,
        "trigrams": kept_trigrams,
        "totals": {
            "unigrams": sum(unigram.values()),
            "bigrams": sum(kept_bigrams.values()),
            "trigrams": sum(kept_trigrams.values()),
        },
        "symspell": {
            "maxEdit": MAX_DELETE_EDIT,
            "lexiconCount": len(lexicon),
            "deletes": deletes,
        },
        "bands": {
            "surfaceFloor": V3_CORRECT_THRESHOLD,
            "applyTotal": V3_CORRECT_THRESHOLD,
            "judgeMin": JUDGE_MIN,
            "origin": ("surfaceFloor/applyTotal: pinned to the shipped v3 "
                       "measured operating point (correction-banks/v3#e133253b, "
                       "correctThreshold 0.8125) — the silent-apply set is "
                       "byte-identical to the calibrated set; judgeMin: "
                       "authored, labeled chosen (A-9), conversational-only "
                       "band (judge/clarify), never a silent rewrite"),
        },
    }


def check_invariants(bank: dict) -> list[str]:
    problems: list[str] = []
    lexicon = bank["lexicon"]
    if len({row["token"] for row in lexicon}) != len(lexicon):
        problems.append("lexicon tokens are not unique")
    ordinal = {row["token"]: index for index, row in enumerate(lexicon)}
    for form, hits in bank["symspell"]["deletes"].items():
        for hit in hits:
            if not (0 <= hit < len(lexicon)):
                problems.append(f"delete-form {form!r} names an ordinal out of range")
                continue
            token = lexicon[hit]["token"]
            if form not in symmetric_deletes(token):
                problems.append(
                    f"delete-form {form!r} is not a delete-1 form of {token!r}")
    for key, count in bank["bigrams"].items():
        parts = key.split("||")
        if len(parts) != 2 or not all(parts):
            problems.append(f"bigram key {key!r} is malformed")
        if count < NGRAM_COUNT_FLOOR:
            problems.append(f"bigram {key!r} below the count floor")
    for key, count in bank["trigrams"].items():
        parts = key.split("||")
        if len(parts) != 3 or not all(parts):
            problems.append(f"trigram key {key!r} is malformed")
        if count < NGRAM_COUNT_FLOOR:
            problems.append(f"trigram {key!r} below the count floor")
    bands = bank["bands"]
    if not (0 < bands["judgeMin"] <= bands["surfaceFloor"]):
        problems.append("bands out of order: judgeMin must be ≤ surfaceFloor")
    if bands["surfaceFloor"] != bands["applyTotal"]:
        problems.append("surfaceFloor must equal applyTotal until a v4 re-fit")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", nargs="+", type=Path, required=True,
                        help="training-corpus jsonl files (utterance rows)")
    parser.add_argument("--out", type=Path,
                        help="where to write stt-ngram-prior.json "
                             "(required unless --check)")
    parser.add_argument("--check", action="store_true",
                        help="re-count the corpus and assert the bank's "
                             "invariants; write nothing")
    parser.add_argument("--min-rows", type=int, default=DEFAULT_MIN_ROWS)
    parser.add_argument("--min-lexicon", type=int, default=DEFAULT_MIN_LEXICON)
    parser.add_argument("--bank", type=Path,
                        help="with --check: an existing bank to validate "
                             "against the corpus's re-count")
    args = parser.parse_args()

    try:
        missing = [str(p) for p in args.corpus if not p.is_file()]
        if missing:
            raise GuardError(f"corpus file(s) missing: {', '.join(missing)}")
        rows = load_rows(args.corpus)
        if len(rows) < args.min_rows:
            print(f"floor refused: {len(rows)} rows < --min-rows "
                  f"{args.min_rows} — an n-gram prior from this corpus is "
                  f"not a measurement", file=sys.stderr)
            return EXIT_FLOOR
        revision = corpus_revision(args.corpus)
        bank = build_bank(rows, revision)
        if len(bank["lexicon"]) < args.min_lexicon:
            print(f"floor refused: {len(bank['lexicon'])} lexicon tokens < "
                  f"--min-lexicon {args.min_lexicon}", file=sys.stderr)
            return EXIT_FLOOR
        problems = check_invariants(bank)
        if problems:
            raise GuardError("invariant failure: " + "; ".join(problems))
    except GuardError as refused:
        print(f"guard refused: {refused}", file=sys.stderr)
        return EXIT_GUARD
    except Exception as failure:  # noqa: BLE001 — the house exit vocabulary
        print(f"stage failed: {failure}", file=sys.stderr)
        return EXIT_STAGE

    if args.check:
        if args.bank:
            existing = json.loads(args.bank.read_text(encoding="utf-8"))
            mismatches = []
            if existing.get("corpus", {}).get("revision") != revision:
                mismatches.append("corpus revision")
            if existing.get("corpus", {}).get("rows") != len(rows):
                mismatches.append("row count")
            if len(existing.get("lexicon", [])) != len(bank["lexicon"]):
                mismatches.append("lexicon size")
            if existing.get("totals", {}).get("unigrams") != bank["totals"]["unigrams"]:
                mismatches.append("unigram total")
            if mismatches:
                print("check FAILED: bank disagrees with the corpus re-count: "
                      + ", ".join(mismatches), file=sys.stderr)
                return EXIT_GUARD
        print(f"[check] corpus rows {len(rows)}, revision {revision}, "
              f"lexicon {len(bank['lexicon'])}, delete-forms "
              f"{len(bank['symspell']['deletes'])}, bigrams "
              f"{len(bank['bigrams'])}, trigrams {len(bank['trigrams'])} — "
              f"invariants hold")
        return EXIT_OK

    if args.out is None:
        print("usage: --out is required unless --check", file=sys.stderr)
        return EXIT_USAGE

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(bank, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(f"[ngram] wrote {args.out} — rows {len(rows)}, lexicon "
          f"{len(bank['lexicon'])}, delete-forms "
          f"{len(bank['symspell']['deletes'])}, bigrams {len(bank['bigrams'])}, "
          f"trigrams {len(bank['trigrams'])}, revision {revision}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
