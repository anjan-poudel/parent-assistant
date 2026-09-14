#!/usr/bin/env python3
"""Export the intent encoder's XLM-R vocabulary to the compact binary resource
the iOS runtime tokenizer loads ([ENCODER-RUNTIME-READY]).

## What it reads

The tokenizer snapshot of the encoder checkpoint's model repo
(`cartesinus/multilingual_minilm-amazon-massive-intent`, revision prefix
`08dc4816`; MIT licence — see the attribution block below).  The snapshot is
NOT committed (tokenizer.json alone is 17,098,081 bytes); this script and the
resource it produces are the artifact of record.

## What it writes

A single little-endian binary resource (default
`ios/ElderlyAssistant/Resources/Intents/encoder_xlmr_unigram.dat`) holding
everything the Swift tokenizer needs:

  * the full Unigram vocabulary (250,002 pieces) as UTF-8 bytes + u32 offsets,
    sorted by piece bytes, carrying each piece's u32 id and f32 score —
    sorted so the runtime can answer "does this byte string exist in the
    vocab?" with a binary search and no load-time sort;
  * the Precompiled normalizer's character map as a key -> replacement table.
    Only keys of at most 5 UTF-8 bytes are kept: the spm precompiled
    algorithm only ever queries a whole grapheme cluster shorter than 6 bytes
    or a single character (at most 4 bytes), and it uses the SHORTEST
    matching prefix (`spm_precompiled::transform` reads `results[0]`).  Every
    possible match is therefore at most 5 bytes long — 7,563 of the trie's
    224,711 keys — and dropping the rest loses nothing while shrinking the
    table from ~4 MB to ~64 KB;
  * the five added tokens (`<s>`, `<pad>`, `</s>`, `<unk>`, `<mask>`) with
    their ids — the literal-extraction stage needs contents + ids.

## Licensing / attribution

  * Vocabulary: `cartesinus/multilingual_minilm-amazon-massive-intent`
    (revision prefix `08dc4816`), MIT licence.  That checkpoint's tokenizer
    files are the base model's — its `tokenizer_config.json` records
    `name_or_path: microsoft/Multilingual-MiniLM-L12-H384` — i.e. the
    standard XLM-R 250k SentencePiece vocabulary, MIT licence, Copyright
    (c) Microsoft Corporation.
  * This script and the generated resource are derivative works of that
    vocabulary and carry the same MIT terms.

## Usage

    # regenerate the committed resource (needs the snapshot dir)
    python3 tools/train-intent/src/encoder_tokenizer_export.py \
        --snapshot /path/to/snapshot \
        --out ios/ElderlyAssistant/Resources/Intents/encoder_xlmr_unigram.dat

    # verify the committed resource is exactly what the snapshot yields
    python3 tools/train-intent/src/encoder_tokenizer_export.py \
        --snapshot /path/to/snapshot \
        --out ios/ElderlyAssistant/Resources/Intents/encoder_xlmr_unigram.dat \
        --verify

Stdlib only: base64, json, struct, argparse.  The snapshot's `tokenizer.json`
is the only input file read.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys

MAGIC = b"XLMU0001"
HEADER_BYTES = 88
U32 = struct.Struct("<I")
F32 = struct.Struct("<f")

# The resource only needs charmap keys up to this length; see the module
# docstring.  `_MAX_KEY_BYTES - 1` is the longest grapheme cluster the
# precompiled normalizer will hand to the trie as a whole (graphemes of
# >= 6 bytes are normalised character by character).
MAX_KEY_BYTES = 5

DEFAULT_SECTION_NAMES = (
    "piece_ids",
    "piece_scores",
    "piece_offsets",
    "pieces_blob",
    "charmap_key_offsets",
    "charmap_value_offsets",
    "charmap_keys_blob",
    "charmap_values_blob",
    "added_ids",
    "added_offsets",
    "added_blob",
)

ADDED_TOKEN_IDS = {
    "bos": "<s>",
    "eos": "</s>",
    "unk": "<unk>",
    "pad": "<pad>",
    "mask": "<mask>",
}


# --------------------------------------------------------------------------
# darts-clone double-array trie (the encoding spm_precompiled / HF's
# `Precompiled` normalizer uses)
# --------------------------------------------------------------------------

def _unit_has_leaf(unit: int) -> bool:
    return ((unit >> 8) & 1) == 1


def _unit_value(unit: int) -> int:
    return unit & ((1 << 31) - 1)


def _unit_label(unit: int) -> int:
    return unit & ((1 << 31) | 0xFF)


def _unit_offset(unit: int) -> int:
    return (unit >> 10) << ((unit & (1 << 9)) >> 6)


def parse_charsmap(precompiled_charsmap_b64: str):
    """(units, normalized_blob) of the base64 precompiled charsmap."""
    raw = base64.b64decode(precompiled_charsmap_b64)
    (trie_size,) = U32.unpack(raw[:4])
    count = trie_size // 4
    units = struct.unpack("<%dI" % count, raw[4:4 + trie_size])
    normalized = raw[4 + trie_size:]
    return units, normalized


def enumerate_charmap(units, normalized, max_key_bytes: int):
    """Every trie key of at most `max_key_bytes` bytes -> replacement bytes.

    A value sits at `child ^ offset(child_unit)` when the child unit has the
    leaf bit; keys are the byte paths from the root.
    """
    table = {}
    stack = [(_unit_offset(units[0]), b"")]
    while stack:
        base, key = stack.pop()
        if len(key) >= max_key_bytes:
            continue
        for byte in range(1, 256):
            child = base ^ byte
            if child >= len(units):
                continue
            unit = units[child]
            if _unit_label(unit) != byte:
                continue
            new_key = key + bytes([byte])
            value_pos = child ^ _unit_offset(unit)
            if _unit_has_leaf(unit):
                end = normalized.index(b"\x00", _unit_value(units[value_pos]))
                table[new_key] = normalized[_unit_value(units[value_pos]):end]
            stack.append((value_pos, new_key))
    return table


def trie_lookup(units, normalized, key: bytes):
    """Shortest-prefix-match lookup, exactly as spm_precompiled does it."""
    node_pos = 0
    node_pos ^= _unit_offset(units[node_pos])
    for byte in key:
        node_pos ^= byte
        unit = units[node_pos]
        if _unit_label(unit) != byte:
            return None
        node_pos ^= _unit_offset(unit)
        if _unit_has_leaf(unit):
            value = _unit_value(units[node_pos])
            end = normalized.index(b"\x00", value)
            return normalized[value:end]
    return None


def key_table_lookup(table, key: bytes):
    """The runtime rule: shortest prefix of `key` present in the flat table."""
    for length in range(1, min(len(key), MAX_KEY_BYTES) + 1):
        candidate = key[:length]
        if candidate in table:
            return table[candidate]
    return None


# --------------------------------------------------------------------------
# resource assembly
# --------------------------------------------------------------------------

def _pad4(buffer: bytearray) -> None:
    while len(buffer) % 4:
        buffer.append(0)


def build_resource(tokenizer_json_path: str, verify_only: bool = False):
    with open(tokenizer_json_path, encoding="utf-8") as handle:
        tokenizer = json.load(handle)

    model = tokenizer["model"]
    if model["type"] != "Unigram":
        raise SystemExit("unexpected model type %r (want Unigram)" % model["type"])
    vocab = model["vocab"]                       # [[piece, score], ...]
    unk_id = int(model["unk_id"])

    # --- scores must be exactly representable as f32 -----------------------
    # A SentencePiece model stores f32 scores; the HF JSON prints them as
    # decimals.  If every value round-trips through f32 we can store the
    # compact form with no loss, and the runtime accumulates in Double to
    # match the training-side (f64) arithmetic bit for bit.
    worst = 0.0
    for _, score in vocab:
        worst = max(worst, abs(score - F32.unpack(F32.pack(score))[0]))
    if worst != 0.0:
        raise SystemExit(
            "vocab scores are not exactly f32 (max delta %r) — storing them "
            "as f32 would change Viterbi outcomes; extend the format" % worst)

    # --- sorted vocab ------------------------------------------------------
    order = sorted(range(len(vocab)), key=lambda i: vocab[i][0].encode("utf-8"))
    pieces_blob = bytearray()
    offsets = [0]
    scores = []
    ids = []
    max_piece_bytes = 0
    for index in order:
        piece, score = vocab[index]
        data = piece.encode("utf-8")
        pieces_blob.extend(data)
        offsets.append(len(pieces_blob))
        ids.append(index)
        scores.append(F32.unpack(F32.pack(score))[0])
        max_piece_bytes = max(max_piece_bytes, len(data))
    piece_offsets = offsets

    # --- charmap -----------------------------------------------------------
    normalizers = tokenizer["normalizer"]["normalizers"]
    precompiled = next(n for n in normalizers if n["type"] == "Precompiled")
    units, normalized = parse_charsmap(precompiled["precompiled_charsmap"])
    table = enumerate_charmap(units, normalized, MAX_KEY_BYTES)

    # Self-check.  The spm precompiled algorithm returns the SHORTEST prefix
    # of the query that is a trie key, so the flat table is equivalent to the
    # trie exactly when, for every trie key K, the shortest <= 5-byte prefix
    # of K present in the table is also the shortest prefix of K present in
    # the trie.  Enumerate the whole trie and check that, plus the reachable
    # set: the runtime only ever queries <= 5 bytes, so a trie key whose
    # shortest match is longer than 5 bytes is unreachable (counted, never
    # silently accepted).
    all_keys = enumerate_charmap(units, normalized, 64)
    unreachable = 0
    for key in all_keys:
        flat = key_table_lookup(table, key)
        trie = trie_lookup(units, normalized, key)
        if flat == trie:
            continue
        if flat is None and trie is not None and len(key) > MAX_KEY_BYTES:
            unreachable += 1
            continue
        raise SystemExit("charmap table disagrees with the trie for %r" % key)

    keys_blob = bytearray()
    key_offsets = [0]
    values_blob = bytearray()
    value_offsets = [0]
    for key in sorted(table):
        keys_blob.extend(key)
        key_offsets.append(len(keys_blob))
        values_blob.extend(table[key])
        value_offsets.append(len(values_blob))

    # --- added tokens ------------------------------------------------------
    added = [(t["content"].encode("utf-8"), int(t["id"]))
             for t in tokenizer["added_tokens"]]
    added.sort(key=lambda item: item[0])
    added_blob = bytearray()
    added_offsets = [0]
    added_ids = []
    for content, token_id in added:
        added_blob.extend(content)
        added_offsets.append(len(added_blob))
        added_ids.append(token_id)

    specials = {}
    by_content = {content.decode("utf-8"): token_id for content, token_id in added}
    for key, content in ADDED_TOKEN_IDS.items():
        if content not in by_content:
            raise SystemExit("snapshot has no added token %r" % content)
        specials[key] = by_content[content]
    if specials["unk"] != unk_id:
        raise SystemExit("unk id mismatch: %r vs %r" % (specials["unk"], unk_id))

    # --- serialize ---------------------------------------------------------
    header = bytearray(HEADER_BYTES)
    header[0:8] = MAGIC
    sections = []

    def add(name, payload: bytes):
        sections.append((name, payload))

    add("piece_ids", b"".join(U32.pack(i) for i in ids))
    add("piece_scores", b"".join(F32.pack(s) for s in scores))
    add("piece_offsets", b"".join(U32.pack(o) for o in piece_offsets))
    add("pieces_blob", bytes(pieces_blob))
    add("charmap_key_offsets", b"".join(U32.pack(o) for o in key_offsets))
    add("charmap_value_offsets", b"".join(U32.pack(o) for o in value_offsets))
    add("charmap_keys_blob", bytes(keys_blob))
    add("charmap_values_blob", bytes(values_blob))
    add("added_ids", b"".join(U32.pack(i) for i in added_ids))
    add("added_offsets", b"".join(U32.pack(o) for o in added_offsets))
    add("added_blob", bytes(added_blob))

    body = bytearray()
    layout = {}
    for name, payload in sections:
        _pad4(body)
        layout[name] = (HEADER_BYTES + len(body), len(payload))
        body.extend(payload)
    _pad4(body)

    fields = [len(vocab), len(table), len(added),
              specials["bos"], specials["eos"], specials["unk"],
              specials["pad"], specials["mask"]]
    for index, value in enumerate(fields):
        U32.pack_into(header, 8 + 4 * index, value)
    for index, name in enumerate(DEFAULT_SECTION_NAMES):
        offset, length = layout[name]
        U32.pack_into(header, 40 + 4 * index, length)
    # offsets of the section start are implied by the fixed order; keep the
    # header free of absolute offsets so the file is position independent.
    assert len(header) == HEADER_BYTES

    resource = bytes(header) + bytes(body)
    return {
        "resource": resource,
        "counts": {
            "pieces": len(vocab),
            "charmap_keys": len(table),
            "charmap_keys_total": len(all_keys),
            "charmap_keys_unreachable": unreachable,
            "added_tokens": len(added),
            "max_piece_bytes": max_piece_bytes,
        },
        "layout": layout,
        "specials": specials,
        "table": table,
        "units_normalized": (units, normalized),
    }


# --------------------------------------------------------------------------
# resource reader (mirrors the Swift loader; used by --verify)
# --------------------------------------------------------------------------

def load_resource(path: str):
    with open(path, "rb") as handle:
        blob = handle.read()
    if len(blob) < HEADER_BYTES or blob[0:8] != MAGIC:
        raise SystemExit("%s: not an XLMU0001 resource" % path)
    header = blob[0:HEADER_BYTES]
    values = [U32.unpack_from(header, 8 + 4 * i)[0] for i in range(8)]
    lengths = [U32.unpack_from(header, 40 + 4 * i)[0] for i in range(11)]
    piece_count, charmap_count, added_count = values[0], values[1], values[2]
    cursor = HEADER_BYTES
    out = {"specials": {"bos": values[3], "eos": values[4], "unk": values[5],
                        "pad": values[6], "mask": values[7]}}

    def take(length):
        nonlocal cursor
        payload = blob[cursor:cursor + length]
        if len(payload) != length:
            raise SystemExit("%s: truncated section" % path)
        cursor += length + (-length % 4)
        return payload

    piece_ids = [U32.unpack_from(payload, i * 4)[0]
                 for payload in [take(lengths[0])]
                 for i in range(len(payload) // 4)]
    piece_scores = [F32.unpack_from(payload, i * 4)[0]
                    for payload in [take(lengths[1])]
                    for i in range(len(payload) // 4)]
    piece_offsets = [U32.unpack_from(payload, i * 4)[0]
                     for payload in [take(lengths[2])]
                     for i in range(len(payload) // 4)]
    pieces_blob = take(lengths[3])
    key_offsets = [U32.unpack_from(payload, i * 4)[0]
                   for payload in [take(lengths[4])]
                   for i in range(len(payload) // 4)]
    value_offsets = [U32.unpack_from(payload, i * 4)[0]
                     for payload in [take(lengths[5])]
                     for i in range(len(payload) // 4)]
    keys_blob = take(lengths[6])
    values_blob = take(lengths[7])
    added_ids = [U32.unpack_from(payload, i * 4)[0]
                 for payload in [take(lengths[8])]
                 for i in range(len(payload) // 4)]
    added_offsets = [U32.unpack_from(payload, i * 4)[0]
                     for payload in [take(lengths[9])]
                     for i in range(len(payload) // 4)]
    added_blob = take(lengths[10])

    if piece_count != len(piece_ids) or piece_count + 1 != len(piece_offsets):
        raise SystemExit("%s: piece table is inconsistent" % path)
    if charmap_count + 1 != len(key_offsets) or charmap_count + 1 != len(value_offsets):
        raise SystemExit("%s: charmap table is inconsistent" % path)
    if added_count + 1 != len(added_offsets) or added_count != len(added_ids):
        raise SystemExit("%s: added-token table is inconsistent" % path)
    if cursor != len(blob):
        raise SystemExit("%s: %d trailing bytes" % (path, len(blob) - cursor))

    out.update({
        "piece_ids": piece_ids,
        "piece_scores": piece_scores,
        "piece_offsets": piece_offsets,
        "pieces_blob": pieces_blob,
        "charmap_keys": keys_blob,
        "charmap_key_offsets": key_offsets,
        "charmap_values": values_blob,
        "charmap_value_offsets": value_offsets,
        "added_blob": added_blob,
        "added_offsets": added_offsets,
        "added_ids": added_ids,
    })

    def piece(index):
        return pieces_blob[piece_offsets[index]:piece_offsets[index + 1]]

    def charmap_lookup(key: bytes):
        """Shortest prefix of `key` present in the table (runtime rule)."""
        for length in range(1, min(len(key), MAX_KEY_BYTES) + 1):
            candidate = key[:length]
            lo, hi = 0, charmap_count
            while lo < hi:
                mid = (lo + hi) // 2
                if keys_blob[key_offsets[mid]:key_offsets[mid + 1]] < candidate:
                    lo = mid + 1
                else:
                    hi = mid
            if lo < charmap_count:
                start, end = key_offsets[lo], key_offsets[lo + 1]
                if keys_blob[start:end] == candidate:
                    return values_blob[value_offsets[lo]:value_offsets[lo + 1]]
        return None

    out["piece"] = piece
    out["charmap_lookup"] = charmap_lookup
    return out


def verify(resource_path: str, tokenizer_json_path: str) -> int:
    """Re-derive from the snapshot and compare byte for byte."""
    fresh = build_resource(tokenizer_json_path)["resource"]
    with open(resource_path, "rb") as handle:
        committed = handle.read()
    if fresh != committed:
        raise SystemExit("%s does NOT match the snapshot (%d vs %d bytes)"
                         % (resource_path, len(committed), len(fresh)))
    loaded = load_resource(resource_path)
    summary = {
        "bytes": len(committed),
        "pieces": len(loaded["piece_ids"]),
        "charmap_keys": len(loaded["charmap_key_offsets"]) - 1,
        "added_tokens": len(loaded["added_ids"]),
        "charmap_values_bytes": len(loaded["charmap_values"]),
        "specials": loaded["specials"],
    }
    print("verified: %s" % json.dumps(summary, sort_keys=True))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True,
                        help="directory (or tokenizer.json path) of the HF snapshot")
    parser.add_argument("--out", required=True, help="resource path to write")
    parser.add_argument("--verify", action="store_true",
                        help="compare against the existing resource, write nothing")
    args = parser.parse_args(argv)

    tokenizer_json = args.snapshot
    if os.path.isdir(tokenizer_json):
        tokenizer_json = os.path.join(tokenizer_json, "tokenizer.json")
    if not os.path.isfile(tokenizer_json):
        raise SystemExit("no tokenizer.json at %s" % tokenizer_json)

    if args.verify:
        return verify(args.out, tokenizer_json)

    built = build_resource(tokenizer_json)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as handle:
        handle.write(built["resource"])
    print("wrote %s (%d bytes)" % (args.out, len(built["resource"])))
    print("counts: %s" % json.dumps(built["counts"], sort_keys=True))
    print("specials: %s" % json.dumps(built["specials"], sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
