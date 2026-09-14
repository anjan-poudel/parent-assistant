#!/usr/bin/env python3
"""Differential harness: the committed reference pipeline vs HF AutoTokenizer.

([ENCODER-RUNTIME-READY]) This is the evidence run behind the claim that the
pipeline the Swift tokenizer mirrors — `xlmr_unigram_ref.py` — reproduces the
HuggingFace tokenizer the T-036 training code uses, over the FULL local
corpora (teacher + noised + edge cases), not just the fixture sample:

    tok(words, is_split_into_words=True, add_special_tokens=True,
        truncation=True, max_length=64)

Reported per corpus file and in total: rows, id mismatches, word-id
mismatches, plus up to 12/24 example rows printed in full so a non-zero
result is diagnosable from the log alone. Exit code 0 iff there are ZERO
divergences (ids AND word_ids) — a non-zero result is a blocking finding,
never a number to round away.

Recorded run: see the `[ENCODER-RUNTIME-READY]` section of
`specs/T-037-a-notes.md` — the harness prints its own per-file counts and
TOTALS line, and the notes quote them verbatim (including the corpus
snapshot they were measured on).

Usage:
    python3 tools/train-intent/src/encoder_tokenizer_diff_harness.py \
        --snapshot DIR --corpus-dir DIR [--limit N]

Requires the training venv (transformers/tokenizers/regex). `--limit N`
encodes at most N rows per corpus file (a smoke run); the corpora themselves
are not committed (see tools/train-intent/README.md).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from xlmr_unigram_ref import XlmrRefTokenizer  # noqa: E402

MAX_LEN = 64
CORPUS_FILES = ("teacher.jsonl", "noised.jsonl", "edge_cases.jsonl")

# [review round F1] The empty-normalisation class, supplied as word lists:
# a word whose normalised text is the empty string contributes NO ids and NO
# word index (HF's Metaspace returns early on empty input). The corpora,
# split with `str.split()`, never produced such a word — which is how the
# reference's spurious `▁` piece slipped through this harness before. The control
# scalars are the reachable ones (U+007F/U+008F/U+009F survive
# `InputSanitiser` quarantine; U+001C does not, and is kept as the original
# repro), plus the empty word itself.
ADVERSARIAL_CASES = [
    ["\u001c"],
    ["\u007f"],
    ["\u008f"],
    ["\u009f"],
    [""],
    ["\u0914\u0937\u0927\u093f", "\u007f", "\u0916\u093e\u090f\u0901"],
    ["\u0914\u0937\u0927\u093f", "\u008f", "\u0916\u093e\u090f\u0901"],
    ["\u0914\u0937\u0927\u093f", "\u009f", "\u0916\u093e\u090f\u0901"],
    ["\u008f", "\u008f"],
    ["a", "", "b"],
]


def rows(path, limit=None):
    with open(path, encoding="utf-8") as handle:
        for index, line in enumerate(handle):
            if limit is not None and index >= limit:
                return
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            yield index, row.get("utterance") or row.get("text") or ""


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True, help="HF snapshot dir (tokenizer.json)")
    parser.add_argument("--corpus-dir", required=True, help="dir with teacher.jsonl etc.")
    parser.add_argument("--limit", type=int, default=None, help="rows per file (smoke run)")
    args = parser.parse_args(argv)

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(args.snapshot)
    ref = XlmrRefTokenizer(os.path.join(args.snapshot, "tokenizer.json"))
    print(f"vocab={len(ref.vocab)} unk={ref.unk_id} min_score={ref.min_score:.4f} "
          f"max_piece_bytes={ref.max_piece_bytes}")

    totals = {"rows": 0, "ids_mismatch": 0, "wid_mismatch": 0}
    examples = []
    started = time.time()
    for name in CORPUS_FILES:
        path = os.path.join(args.corpus_dir, name)
        if not os.path.isfile(path):
            raise SystemExit("missing corpus file %s" % path)
        per_file = {"rows": 0, "ids": 0, "wids": 0}
        for index, text in rows(path, args.limit):
            words = text.split()
            if not words:
                continue
            got_ids, got_wids = ref.encode_words(words, max_length=MAX_LEN)
            encoding = tokenizer(words, is_split_into_words=True,
                                 add_special_tokens=True, truncation=True,
                                 max_length=MAX_LEN)
            exp_ids, exp_wids = encoding["input_ids"], encoding.word_ids()
            totals["rows"] += 1
            per_file["rows"] += 1
            # The metric name is spelled out: `key + "_mismatch"` mapped a
            # word-id divergence onto "wids_mismatch", which is not a total
            # (KeyError) — zero divergences meant it had never been hit.
            for kind, got, exp, metric in (("ids", got_ids, exp_ids, "ids_mismatch"),
                                           ("wids", got_wids, exp_wids, "wid_mismatch")):
                if got == exp:
                    continue
                totals[metric] += 1
                per_file[kind] += 1
                if len(examples) < 24:
                    examples.append((kind, name, index, text, exp_ids, got_ids,
                                     exp_wids, got_wids))
        print(f"{name}: {per_file}  ({time.time() - started:.1f}s)")
    # [review round F1] Empty-normalisation cases, supplied directly: the
    # corpora above never yield a word whose normalised text is empty, which
    # is exactly how the spurious piece slipped through before. Same
    # comparison and the same bookkeeping as the corpus rows.
    adversarial = {"rows": 0, "ids": 0, "wids": 0}
    for index, words in enumerate(ADVERSARIAL_CASES):
        got_ids, got_wids = ref.encode_words(words, max_length=MAX_LEN)
        encoding = tokenizer(words, is_split_into_words=True,
                             add_special_tokens=True, truncation=True,
                             max_length=MAX_LEN)
        exp_ids, exp_wids = encoding["input_ids"], encoding.word_ids()
        totals["rows"] += 1
        adversarial["rows"] += 1
        for kind, got, exp, metric in (("ids", got_ids, exp_ids, "ids_mismatch"),
                                       ("wids", got_wids, exp_wids, "wid_mismatch")):
            if got == exp:
                continue
            totals[metric] += 1
            adversarial[kind] += 1
            if len(examples) < 24:
                examples.append((kind, "adversarial-empty-word", index,
                                 " ".join(words), exp_ids, got_ids,
                                 exp_wids, got_wids))
    print("adversarial empty-normalisation cases:", adversarial)
    print("TOTALS:", totals)
    for kind, name, index, text, exp_ids, got_ids, exp_wids, got_wids in examples:
        print("----", kind, name, index)
        print("  text    :", repr(text[:200]))
        print("  exp ids :", exp_ids[:40], "..." if len(exp_ids) > 40 else "")
        print("  got ids :", got_ids[:40], "..." if len(got_ids) > 40 else "")
        print("  exp wids:", exp_wids[:40])
        print("  got wids:", got_wids[:40])
    diverged = totals["ids_mismatch"] + totals["wid_mismatch"]
    print("VERDICT:", "IDENTICAL" if diverged == 0 else "DIVERGENT (%d)" % diverged)
    return 0 if diverged == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
