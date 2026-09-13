"""T-034 §4.3 alignment: word-first annotation projected onto subword tokens.

The rules (annotation_rules.yaml `spans.alignment`) in code:

  words       maximal non-whitespace runs of the exact utterance (code points)
  word tags   first word intersecting a span -> B-<label>, later words -> I-<label>
  tokens      tokenize the EXACT utterance with the T-033 tokenizer
              (add_special_tokens=true, return_offsets_mapping=true); each token
              is assigned to the word it intersects; special / zero-width tokens
              get -100 and are excluded from the slot loss
  decode      a B-/I- run of one label becomes utterance[start:end] taken from
              the token offsets — never a concatenation of token strings (the
              sentencepiece '▁' marker must not leak)

Everything here is torch-free and tokenizer-free: the tokenizer is passed in
(anything exposing `__call__(text, return_offsets_mapping=True)`), so the pure
functions are unit-testable on a laptop and the training path can be proven
without a model download.
"""
from __future__ import annotations


class AlignError(RuntimeError):
    """A row's spans cannot be aligned — T-034: refuse the row, never mask it."""


def canonical_text_violations(utterance: str) -> list[str]:
    """Reasons the utterance cannot carry code-point offsets safely."""
    out = []
    if not isinstance(utterance, str) or not utterance.strip():
        out.append("empty")
    elif utterance != " ".join(utterance.split()):
        out.append("non_canonical_whitespace")
    if any(c in utterance for c in "\n\r\t"):
        out.append("control_whitespace")
    return out


def word_offsets(text: str) -> list[tuple[int, int]]:
    """Char offsets of whitespace words, code-point based (Devanagari-safe)."""
    out, pos = [], 0
    for w in text.split():
        i = text.index(w, pos)
        out.append((i, i + len(w)))
        pos = i + len(w)
    return out


def validate_spans(utterance: str, spans: list[dict]) -> list[str]:
    """T-034 §4.6 row validation for spans; returns the list of violations."""
    v: list[str] = []
    seen = set()
    for s in spans:
        label, text = s.get("label"), s.get("text")
        start, end = s.get("start"), s.get("end")
        if not isinstance(start, int) or not isinstance(end, int):
            v.append("non_integer_offset")
            continue
        if not (0 <= start < end <= len(utterance)):
            v.append("offset_out_of_range")
            continue
        if utterance[start:end] != text:
            v.append("offset_text_mismatch")
        if (label, start, end) in seen:
            v.append("duplicate_span")
        seen.add((label, start, end))
    ordered = sorted(spans, key=lambda s: (s.get("start", -1), s.get("end", -1)))
    for a, b in zip(ordered, ordered[1:]):
        if not isinstance(a.get("start"), int) or not isinstance(b.get("start"), int):
            continue
        if b["start"] < a["end"]:
            v.append("overlapping_spans")
        elif b["start"] == a["end"] and a.get("label") == b.get("label"):
            v.append("adjacent_same_label_not_merged")
    return v


def spans_of_label(spans: list[dict], label: str) -> list[dict]:
    return [s for s in spans if s.get("label") == label]


def word_tags_from_spans(utterance: str, spans: list[dict],
                         span_labels: tuple[str, ...]) -> list[str]:
    """Word-level BIO tags (T-034 §4.3 steps 1-2). Raises on unalignable spans."""
    for s in spans:
        if s.get("label") not in span_labels:
            raise AlignError(f"span label {s.get('label')!r} not in {span_labels}")
        if not isinstance(s.get("start"), int) or not isinstance(s.get("end"), int):
            raise AlignError(f"span {s!r} has non-integer offsets")
        if utterance[s["start"]:s["end"]] != s.get("text"):
            raise AlignError(f"span {s!r} is not a verbatim substring of the utterance")
    words = utterance.split()
    offs = word_offsets(utterance)
    tags = ["O"] * len(words)
    for s in sorted(spans, key=lambda s: (s["start"], s["end"])):
        first = True
        touched = False
        for wi, (a, b) in enumerate(offs):
            if a < s["end"] and b > s["start"]:  # word intersects the span
                tags[wi] = f"{'B' if first else 'I'}-{s['label']}"
                first = False
                touched = True
        if not touched:
            raise AlignError(f"span {s!r} intersects no word — unalignable row")
    return tags


def intersect_word(token_off: tuple[int, int],
                   word_offs: list[tuple[int, int]]) -> int | None:
    p, q = token_off
    if q <= p:
        return None  # special or zero-width token
    for wi, (a, b) in enumerate(word_offs):
        if a < q and b > p:
            return wi
    return None


def project_token_tags(token_offsets: list[tuple[int, int]],
                       word_offs: list[tuple[int, int]],
                       word_tags: list[str], tag2id: dict[str, int]) -> list[int | None]:
    """T-034 §4.3 steps 3-5: subword tag projection (None == -100 excluded)."""
    out: list[int | None] = []
    for off in token_offsets:
        wi = intersect_word(off, word_offs)
        out.append(None if wi is None else tag2id[word_tags[wi]])
    return out


def decode_spans(utterance: str, token_offsets: list[tuple[int, int]],
                 tag_ids: list[int | None], bio_tags: tuple[str, ...]) -> list[dict]:
    """T-034 §4.3 step 6: B-/I- runs -> utterance[start:end] spans."""
    spans: list[dict] = []
    cur_label, cur_start, cur_end = None, None, None
    for off, tid in zip(token_offsets, tag_ids):
        label = None
        if tid is not None and 0 <= tid < len(bio_tags):
            tag = bio_tags[tid]
            if tag != "O":
                label = tag.split("-", 1)[1]
        if label != cur_label:
            if cur_label is not None:
                spans.append({"label": cur_label, "text": utterance[cur_start:cur_end],
                              "start": cur_start, "end": cur_end})
            cur_label = label
            cur_start = off[0] if label else None
        if label:
            cur_end = off[1]
    if cur_label is not None:
        spans.append({"label": cur_label, "text": utterance[cur_start:cur_end],
                      "start": cur_start, "end": cur_end})
    return spans


def check_token_recoverable(utterance: str, token_offsets: list[tuple[int, int]],
                            spans: list[dict]) -> list[str]:
    """T-034 §4.4: every span must be a contiguous run of tokens covering it."""
    v: list[str] = []
    for s in spans:
        idx = [i for i, (p, q) in enumerate(token_offsets)
               if q > p and p < s["end"] and q > s["start"]]
        if not idx:
            v.append("span_intersects_no_token")
            continue
        if idx[-1] - idx[0] + 1 != len(idx):
            v.append("span_not_token_contiguous")
            continue
        first, last = token_offsets[idx[0]], token_offsets[idx[-1]]
        if first[0] > s["start"] or last[1] < s["end"]:
            v.append("span_not_covered_by_tokens")
    return v


def tokenize_offsets(tok, utterance: str) -> list[tuple[int, int]]:
    """T-034 §4.3 step 3 via a transformers fast tokenizer (imported by caller)."""
    enc = tok(utterance, add_special_tokens=True, return_offsets_mapping=True)
    return [tuple(o) for o in enc["offset_mapping"]]


def encode_row(tok, utterance: str, spans: list[dict],
               span_labels: tuple[str, ...], tag2id: dict[str, int]
               ) -> tuple[list[int], list[int | None]]:
    """input_ids + projected tags for one row; raises AlignError when refused."""
    word_tags = word_tags_from_spans(utterance, spans, span_labels)
    offs = word_offsets(utterance)
    enc = tok(utterance, add_special_tokens=True, return_offsets_mapping=True)
    token_offs = [tuple(o) for o in enc["offset_mapping"]]
    violations = check_token_recoverable(utterance, token_offs, spans)
    if violations:
        raise AlignError("; ".join(sorted(set(violations))))
    return list(enc["input_ids"]), project_token_tags(token_offs, offs, word_tags, tag2id)


def tag_id_for(bio_tags: tuple[str, ...], label: str, prefix: str) -> int:
    return bio_tags.index(f"{prefix}-{label}")
