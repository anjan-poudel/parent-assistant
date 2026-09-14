#!/usr/bin/env python3
"""Generate the golden tokenizer fixtures the Swift tokenizer is gated on
([ENCODER-RUNTIME-READY]).

Source of truth: the HuggingFace `AutoTokenizer` for the encoder checkpoint's
XLM-R vocabulary (`cartesinus/multilingual_minilm-amazon-massive-intent`,
revision prefix `08dc4816`, MIT — the vocabulary files are the XLM-R 250k
SentencePiece tables; see `encoder_tokenizer_export.py` for the full
attribution), called EXACTLY the way the T-036 training code calls it:

    tok(words, is_split_into_words=True, add_special_tokens=True,
        truncation=True, max_length=64)

Every emitted row is `{id, source, transcript, words, ids, wordIndices}` and
is re-checked in-process against the committed Python reference
(`xlmr_unigram_ref.py`) — the fixtures are self-validating, and the Swift
side must reproduce `ids` and `wordIndices` exactly (see
`ElderlyAssistantTests/Services/Intents/XlmrUnigramTokenizerTests.swift`).

Word splitting is the RUNTIME's rule, i.e. exactly what
`IntentEncoderDecoder.wordScalarOffsets` does (unicode scalars, with
`CharacterSet.whitespacesAndNewlines` as the separator set): the tokenizer's
`words` must equal the decoder's `textWords` or the interpreter abstains on
every utterance, and the golden `wordIndices` are only meaningful against the
word list the runtime derives.  Python's `str.split()` uses a slightly
different separator set (it also treats U+001C..U+001F as whitespace, and it
does NOT treat U+200B as whitespace); the generator reports every row where
the two disagree so the difference is visible rather than assumed away.

## Usage

    python3 tools/train-intent/src/encoder_tokenizer_fixtures.py \
        --snapshot /path/to/snapshot \
        --corpus-dir /path/to/corpus \
        --out ios/ElderlyAssistantTests/Services/Intents/Fixtures/encoder_tokenizer_golden.jsonl

Requires the training venv (`transformers`, `tokenizers`, `regex`); the
corpus files are not committed (see tools/train-intent/README.md).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from xlmr_unigram_ref import XlmrRefTokenizer  # noqa: E402

MAX_LENGTH = 64
FIXTURE_SOURCES = ("teacher.jsonl", "noised.jsonl", "edge_cases.jsonl")
PER_REGISTER = 25
DIGIT_ROWS = 10


# --------------------------------------------------------------------------
# the runtime's word-splitting rule (mirrors IntentEncoderDecoder)
# --------------------------------------------------------------------------

# Enumerated from Foundation itself (every scalar contained in `CharacterSet
# .whitespacesAndNewlines`, walked in a scratch harness): U+0009..U+000D,
# U+0085, U+2028, U+2029, U+200B, and the 18 Unicode general category Zs
# scalars.  U+200B ZERO WIDTH SPACE is the surprise — Foundation counts it as
# whitespace even though Unicode does not — and it is exactly the kind of
# drift the fixture gate exists to catch.  The runtime rule is Foundation's
# set (the span decoder slices with the same set), so this list must match it.
_FOUNDATION_WHITESPACE = {
    "\u0009", "\u000a", "\u000b", "\u000c", "\u000d", "\u0020", "\u0085",
    "\u00a0", "\u1680", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004",
    "\u2005", "\u2006", "\u2007", "\u2008", "\u2009", "\u200a", "\u200b",
    "\u2028", "\u2029", "\u202f", "\u205f", "\u3000",
}


def _swift_is_whitespace(scalar: str) -> bool:
    """`CharacterSet.whitespacesAndNewlines` as Foundation defines it (see
    `_FOUNDATION_WHITESPACE`)."""
    if scalar in _FOUNDATION_WHITESPACE:
        return True
    return unicodedata.category(scalar) == "Zs"


def runtime_split(text: str):
    """Whitespace words, exactly as `wordScalarOffsets` slices them."""
    words = []
    current = []
    for scalar in text:
        if _swift_is_whitespace(scalar):
            if current:
                words.append("".join(current))
                current = []
        else:
            current.append(scalar)
    if current:
        words.append("".join(current))
    return words


# --------------------------------------------------------------------------
# adversarial cases (the task's explicit list plus the neighbours of each)
# --------------------------------------------------------------------------

def adversarial_rows():
    long_word = "\u0905" * 300
    many_words = " ".join("\u0936\u092c\u094d\u0926%02d" % i for i in range(80))
    almost_full = " ".join("w%02d" % i for i in range(62))
    one_over = " ".join("w%02d" % i for i in range(65))
    rows = [
        ("empty", ""),
        ("spaces-only", "   "),
        ("single-char", "\u0915"),
        ("single-word", "\u0928\u092e\u0938\u094d\u0924\u0947"),
        ("two-words", "\u092b\u094b\u0928 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d"),
        ("leading-space", "  \u0928\u092e\u0938\u094d\u0924\u0947"),
        ("trailing-space", "\u0928\u092e\u0938\u094d\u0924\u0947  "),
        ("multiple-spaces", "\u0914\u0937\u0927\u093f   \u0916\u093e\u090f\u0901"),
        ("tab-separated", "\u0914\u0937\u0927\u093f\t\u0916\u093e\u090f\u0901"),
        ("newline-separated", "\u0914\u0937\u0927\u093f\n\u0916\u093e\u090f\u0901"),
        ("nbsp-separated", "\u0914\u0937\u0927\u093f\u00a0\u0916\u093e\u090f\u0901"),
        ("line-separator", "\u0914\u0937\u0927\u093f\u2028\u0916\u093e\u090f\u0901"),
        ("64-words-exact", " ".join("w%02d" % i for i in range(64))),
        ("62-words", almost_full),
        ("63-words", " ".join("w%02d" % i for i in range(63))),
        ("65-words", one_over),
        ("80-words", many_words),
        ("punctuation", "\u0928\u092e\u0938\u094d\u0924\u0947, \u0915\u0938\u094d\u0924\u094b \u091b? \u0920\u0940\u0915 \u091b!"),
        ("punctuation-runs", "\u0939\u094b... \u0939\u094b?? \u0939\u094b!!!"),
        ("literal-bos", "<s>"),
        ("literal-eos", "</s>"),
        ("literal-mask", "<mask>"),
        ("literal-pad", "<pad>"),
        ("literal-unk", "<unk>"),
        ("embedded-special", "a<s>b"),
        ("special-in-word", "\u092b\u094b\u0928</s>\u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d"),
        ("angle-brackets", "<not-a-special>"),
        ("zwj-family", "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466"),
        ("zwj-rainbow-flag", "\U0001f3f3\ufe0f\u200d\U0001f308"),
        ("flag-sequence", "\U0001f1f3\U0001f1f5"),
        ("emoji-simple", "\U0001f64f"),
        ("emoji-keycap", "1\ufe0f\u20e3"),
        ("devanagari-conjunct", "\u0915\u094d\u200d\u0937"),
        ("devanagari-zwnj", "\u0915\u094d\u200c\u0937"),
        ("combining-nukta-decomposed", "\u0915\u093c"),
        ("combining-nukta-precomposed", "\u0915\u093c"),
        ("combining-only", "\u093c"),
        ("combining-latin", "a\u0301"),
        ("control-start", "\u0001abc"),
        ("control-middle", "a\u001cb"),
        ("control-nul", "a\u0000b"),
        ("control-bell", "\u0914\u0937\u0927\u093f\u0007"),
        ("bom", "\ufeff\u0928\u092e\u0938\u094d\u0924\u0947"),
        ("halfwidth-latin", "\uff21\uff22\uff23 \uff11\uff12\uff13"),
        ("fullwidth-space", "\u0914\u0937\u0927\u093f\u3000\u0916\u093e\u090f\u0901"),
        ("ligature-fi", "\ufb01le"),
        ("vulgar-half", "\u00bd"),
        ("roman-numeral", "\u2168"),
        ("superscript", "x\u00b2 + y\u00b3"),
        ("very-long-word", long_word),
        ("long-latin-word", "a" * 400),
        ("long-numeric", "0" * 200),
        ("repeated-word", " ".join(["\u0939\u094b"] * 100)),
        ("digits-devanagari", "\u0967\u0968\u0969 \u096a\u096b\u096c"),
        ("digits-latin", "123 456"),
        ("mixed-scripts", "\u0915 call \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d 2 message \u092a\u0920\u093e\u0909\u0928\u0941\u0939\u094b\u0938\u094d"),
        ("romanized", "malai pani sunchha ki?"),
        ("trailing-punctuation-word", "\u0928\u092e\u0938\u094d\u0924\u0947\u0964"),
        ("apostrophe", "don't"),
        ("underscore", "a_b_c"),
        ("metaspace-literal", "\u2581abc"),
        ("metaspace-only", "\u2581"),
        ("double-metaspace", "\u2581\u2581\u2581"),
        ("zero-width-space", "\u0914\u0937\u0927\u093f\u200b\u0916\u093e\u090f\u0901"),
        ("word-joiner", "\u0914\u0937\u0927\u093f\u2060\u0916\u093e\u090f\u0901"),
        ("soft-hyphen", "\u0914\u0937\u00ad\u0927\u093f"),
        ("replacement-char", "\u0914\u0937\u0927\u093f\ufffd"),
        ("hindi-danda", "\u0914\u0937\u0927\u093f \u0916\u093e\u090f\u0901\u0964"),
        # The empty-normalisation class (review round F1): a word the
        # Precompiled charmap deletes ENTIRELY normalises to "" and HF's
        # Metaspace then emits NO pieces at all — no ids and no word index.
        # U+007F / U+008F / U+009F are the scalars of this class that survive
        # `InputSanitiser.sanitise(_, level: .quarantine)` (it turns <0x20
        # into a space and leaves these three alone), so the embedded rows
        # are the reachable form; U+001C is the reviewer's original repro.
        ("empty-normalised-lone-usc", "\u001c"),
        ("empty-normalised-lone-del", "\u007f"),
        ("empty-normalised-lone-c1-8f", "\u008f"),
        ("empty-normalised-lone-c1-9f", "\u009f"),
        ("empty-normalised-embedded-del",
         "\u0914\u0937\u0927\u093f \u007f \u0916\u093e\u090f\u0901"),
        ("empty-normalised-embedded-c1-8f",
         "\u0914\u0937\u0927\u093f \u008f \u0916\u093e\u090f\u0901"),
        ("empty-normalised-embedded-c1-9f",
         "\u0914\u0937\u0927\u093f \u009f \u0916\u093e\u090f\u0901"),
    ]
    return [{"id": "adv-%03d" % (i + 1), "source": "adversarial:%s" % name,
             "transcript": text}
            for i, (name, text) in enumerate(rows)]


# --------------------------------------------------------------------------
# corpus sampling
# --------------------------------------------------------------------------

def _read_jsonl(path):
    with open(path, encoding="utf-8") as handle:
        for index, line in enumerate(handle):
            line = line.strip()
            if line:
                yield index, json.loads(line)


def stratified_corpus_rows(corpus_dir, per_register=PER_REGISTER):
    rows = []
    digit_rows = []
    for name in FIXTURE_SOURCES:
        path = os.path.join(corpus_dir, name)
        if not os.path.isfile(path):
            raise SystemExit("missing corpus file %s" % path)
        by_register = {}
        for index, row in _read_jsonl(path):
            text = row.get("utterance")
            if not text:
                continue
            by_register.setdefault(row.get("register", "unknown"), []).append((index, text))
            if re.search(r"[0-9\u0966-\u096f]", text):
                digit_rows.append((name, row.get("register", "unknown"), index, text))
        for register in sorted(by_register):
            entries = by_register[register]
            stride = max(1, len(entries) // per_register)
            picked = entries[::stride][:per_register]
            if name == "edge_cases.jsonl":
                # The edge-case set is small and entirely on-point — take all.
                picked = entries
            for index, text in picked:
                rows.append({"id": "corpus-%s-%s-%d" % (name.split(".")[0], register, index),
                             "source": "%s:%s" % (name, register),
                             "transcript": text})
    existing = {row["transcript"] for row in rows}
    for index, (name, register, row_index, text) in enumerate(digit_rows):
        if index >= DIGIT_ROWS:
            break
        if text in existing:
            continue
        existing.add(text)
        rows.append({"id": "corpus-digit-%d" % index,
                     "source": "%s:%s:digits" % (name, register),
                     "transcript": text})
    return rows


# --------------------------------------------------------------------------

def encode_row(tokenizer, ref, transcript):
    words = runtime_split(transcript)
    python_words = transcript.split()
    encoding = tokenizer(words, is_split_into_words=True,
                         add_special_tokens=True, truncation=True,
                         max_length=MAX_LENGTH)
    ids = list(encoding["input_ids"])
    word_indices = encoding.word_ids()
    ref_ids, ref_word_indices = ref.encode_words(words, max_length=MAX_LENGTH)
    if ref_ids != ids or ref_word_indices != word_indices:
        raise SystemExit(
            "reference implementation disagrees with HF on %r:\n  hf=%r\n  ref=%r"
            % (transcript[:120], ids, ref_ids))
    return {
        "words": words,
        "ids": ids,
        "wordIndices": word_indices,
        "pythonSplitDiffers": words != python_words,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True, help="HF snapshot dir")
    parser.add_argument("--corpus-dir", required=True, help="dir with teacher.jsonl etc.")
    parser.add_argument("--out", required=True, help="fixture jsonl to write")
    parser.add_argument("--per-register", type=int, default=PER_REGISTER)
    args = parser.parse_args(argv)

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(args.snapshot)
    ref = XlmrRefTokenizer(os.path.join(args.snapshot, "tokenizer.json"))

    rows = stratified_corpus_rows(args.corpus_dir, args.per_register)
    rows += adversarial_rows()
    out_rows = []
    split_diffs = []
    for row in rows:
        encoded = encode_row(tokenizer, ref, row["transcript"])
        if encoded.pop("pythonSplitDiffers"):
            split_diffs.append(row["id"])
        out_rows.append({"id": row["id"], "source": row["source"],
                         "transcript": row["transcript"], **encoded})

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        for row in out_rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    tokens = sum(len(row["ids"]) for row in out_rows)
    truncated = sum(1 for row in out_rows
                    if any(index is not None for index in row["wordIndices"])
                    and max(index for index in row["wordIndices"]
                            if index is not None) + 1 < len(row["words"]))
    print("wrote %s: %d rows, %d tokens" % (args.out, len(out_rows), tokens))
    print("rows where Python str.split() != the runtime rule: %d %s"
          % (len(split_diffs), split_diffs))
    print("rows whose trailing words are truncated away: %d" % truncated)
    print("max words in a row: %d" % max(len(row["words"]) for row in out_rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
