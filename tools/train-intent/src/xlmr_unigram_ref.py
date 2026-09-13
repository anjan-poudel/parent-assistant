"""Faithful re-implementation of the XLM-R Unigram pipeline (tokenizers 0.21.0)
for the cartesinus/multilingual_minilm-amazon-massive-intent tokenizer.

Pipeline per whitespace word (is_split_into_words=True in HF):
  1. added-token extraction (raw literal match, ids from tokenizer.json)
  2. Precompiled normalizer (spm charsmap, grapheme-then-char lookup)
  3. Replace normalizer: runs of 2+ spaces -> one space
  4. Metaspace pre-tokenizer: ' '->'▁', prepend '▁' if absent, split on '▁'
     merged with the next chunk
  5. Unigram Viterbi per piece (lattice semantics incl. unk node injection)
  6. TemplateProcessing <s> A </s> + truncation to max_length
"""
import json
import re
import struct

import regex as regexmod

K_UNK_PENALTY = 10.0


class DartsTrie:
    """darts-clone double array as used by spm_precompiled."""

    def __init__(self, units):
        self.units = units

    @staticmethod
    def _has_leaf(u):
        return ((u >> 8) & 1) == 1

    @staticmethod
    def _value(u):
        return u & ((1 << 31) - 1)

    @staticmethod
    def _label(u):
        return u & ((1 << 31) | 0xFF)

    @staticmethod
    def _offset(u):
        return (u >> 10) << ((u & (1 << 9)) >> 6)

    def common_prefix_search(self, key):
        """Values of every prefix of `key` in the trie, shortest first."""
        node_pos = 0
        results = []
        unit = self.units[node_pos]
        node_pos ^= self._offset(unit)
        for c in key:
            if c == 0:
                break
            node_pos ^= c
            unit = self.units[node_pos]
            if self._label(unit) != c:
                return results
            node_pos ^= self._offset(unit)
            if self._has_leaf(unit):
                results.append(self._value(self.units[node_pos]))
        return results


class CharMap:
    def __init__(self, blob):
        (trie_size,) = struct.unpack("<I", blob[:4])
        n = trie_size // 4
        self.trie = DartsTrie(struct.unpack("<%dI" % n, blob[4:4 + trie_size]))
        self.normalized = blob[4 + trie_size:]          # BYTE offsets, not chars

    def transform(self, chunk):
        results = self.trie.common_prefix_search(chunk.encode("utf-8"))
        if not results:
            return None
        index = results[0]
        end = self.normalized.index(b"\x00", index)
        return self.normalized[index:end].decode("utf-8")

    def normalize(self, text):
        out = []
        for grapheme in regexmod.findall(r"\X", text):
            if len(grapheme.encode("utf-8")) < 6:
                norm = self.transform(grapheme)
                if norm is not None:
                    out.append(norm)
                    continue
            for ch in grapheme:
                norm = self.transform(ch)
                out.append(norm if norm is not None else ch)
        return "".join(out)


class XlmrRefTokenizer:
    def __init__(self, tokenizer_json_path):
        tj = json.load(open(tokenizer_json_path, encoding="utf-8"))
        self.model = tj["model"]
        assert self.model["type"] == "Unigram"
        self.vocab = self.model["vocab"]                     # list[[piece, score]]
        self.token_to_id = {p: i for i, (p, _) in enumerate(self.vocab)}
        self.token_to_id_bytes = {p.encode("utf-8"): i
                                  for i, (p, _) in enumerate(self.vocab)}
        self.scores = [s for _, s in self.vocab]
        self.unk_id = self.model["unk_id"]
        self.min_score = min(self.scores)
        self.max_piece_bytes = max(len(p.encode("utf-8")) for p, _ in self.vocab)
        self.charmap = CharMap(
            __import__("base64").b64decode(
                tj["normalizer"]["normalizers"][0]["precompiled_charsmap"]))
        self.replace_re = re.compile(
            tj["normalizer"]["normalizers"][1]["pattern"]["Regex"])
        self.replace_with = tj["normalizer"]["normalizers"][1]["content"]
        self.metaspace = tj["pre_tokenizer"]["replacement"]
        self.add_prefix_space = tj["pre_tokenizer"]["add_prefix_space"]
        self.added = [(t["content"], t["id"]) for t in tj["added_tokens"]]
        self.ids = {"<s>": 0, "</s>": 2}
        self.max_len = None

    # -- pipeline stages ---------------------------------------------------

    def split_added(self, word):
        """[(text, None)] and [(content, id)] segments covering `word`."""
        out = []
        i = 0
        n = len(word)
        while i < n:
            match = None
            for content, tid in self.added:
                if word.startswith(content, i):
                    if match is None or len(content) > len(match[0]):
                        match = (content, tid)
            if match is not None:
                out.append((match[0], match[1]))
                i += len(match[0])
            else:
                j = i + 1
                while j < n and not any(word.startswith(c, j) for c, _ in self.added):
                    j += 1
                out.append((word[i:j], None))
                i = j
        if not out:
            out.append(("", None))
        return out

    def normalize(self, text):
        text = self.charmap.normalize(text)
        return self.replace_re.sub(self.replace_with, text)

    def metaspace_pieces(self, text):
        # tokenizers' Metaspace returns EARLY on an empty input and emits no
        # parts at all, so a word the normalizer emptied contributes no ids
        # and no word index (HF: `words=[""]` -> `[<s>, </s>]`). The guard has
        # to be here, before the prefix insertion: checking after it is dead
        # code, because the insertion turns "" into "▁" and the spurious
        # piece then encodes as a real token.
        if not text:
            return []
        s = text.replace(" ", self.metaspace)
        if self.add_prefix_space and not s.startswith(self.metaspace):
            s = self.metaspace + s
        m = self.metaspace
        return [p for p in re.split("(?=%s)" % re.escape(m), s) if p != ""]

    def unigram(self, piece):
        """Viterbi per tokenizers' Lattice; returns vocab piece strings."""
        if not piece:
            return []
        data = piece.encode("utf-8")
        n = len(data)
        # byte positions that start a UTF-8 char (plus the end)
        positions = []
        p = 0
        for ch in piece:
            positions.append(p)
            p += len(ch.encode("utf-8"))
        positions.append(n)
        char_len = {}
        for i, pos in enumerate(positions[:-1]):
            char_len[pos] = positions[i + 1] - pos

        begin_nodes = {pos: [] for pos in positions}
        end_nodes = {pos: [] for pos in positions}
        # structural BOS at position 0 (Lattice::from inserts it first)
        end_nodes[0].append({"begin": 0, "end": 0, "id": -1, "score": 0.0,
                             "prev": None, "backtrace": 0.0})
        unk_score = self.min_score - K_UNK_PENALTY
        for pos in positions[:-1]:
            mblen = char_len[pos]
            has_single = False
            maxlen = min(self.max_piece_bytes, n - pos)
            for length in range(1, maxlen + 1):
                key = data[pos:pos + length]
                tid = self.token_to_id_bytes.get(key)
                if tid is None:
                    continue
                begin_nodes[pos].append(
                    {"begin": pos, "end": pos + length, "id": tid,
                     "score": self.scores[tid], "prev": None,
                     "backtrace": 0.0})
                if length == mblen:
                    has_single = True
            if not has_single:
                begin_nodes[pos].append(
                    {"begin": pos, "end": pos + mblen, "id": self.unk_id,
                     "score": unk_score, "prev": None, "backtrace": 0.0})
        for pos in positions[:-1]:
            for node in begin_nodes[pos]:
                end_nodes[node["end"]].append(node)

        # DP (same order/ties as tokenizers Lattice::viterbi)
        for pos in positions[:-1]:
            for rnode in begin_nodes[pos]:
                best_node = None
                best_score = 0.0
                for lnode in end_nodes[pos]:
                    score = lnode["backtrace"] + rnode["score"]
                    if best_node is None or score > best_score:
                        best_node = lnode
                        best_score = score
                if best_node is None:
                    return []          # unreachable, mirroring the Rust early-return
                rnode["prev"] = best_node
                rnode["backtrace"] = best_score

        # backtrack from the best node ending at n
        best_node = None
        best_score = 0.0
        for lnode in end_nodes[n]:
            if best_node is None or lnode["backtrace"] > best_score:
                best_node = lnode
                best_score = lnode["backtrace"]
        path = []
        node = best_node
        while node is not None and node["id"] != -1:   # stop before structural BOS
            path.append(node)
            node = node["prev"]
        path.reverse()

        # fuse_unk: merge consecutive unk nodes into one string
        results = []
        buffer = ""
        for node in path:
            text = data[node["begin"]:node["end"]].decode("utf-8")
            if node["id"] == self.unk_id:
                buffer += text
            else:
                if buffer:
                    results.append(buffer)
                    buffer = ""
                results.append(text)
        if buffer:
            results.append(buffer)
        return results

    def encode_words(self, words, max_length=64, add_special_tokens=True):
        ids = []
        word_ids = []
        for wi, word in enumerate(words):
            for text, tid in self.split_added(word):
                if tid is not None:
                    ids.append(tid)
                    word_ids.append(wi)
                    continue
                normalized = self.normalize(text)
                for piece in self.metaspace_pieces(normalized):
                    for sub in self.unigram(piece):
                        ids.append(self.token_to_id.get(sub, self.unk_id))
                        word_ids.append(wi)
        if add_special_tokens:
            n_added = 2
            if max_length is not None:
                keep = max(0, max_length - n_added)
                ids = ids[:keep]
                word_ids = word_ids[:keep]
            ids = [0] + ids + [2]
            word_ids = [None] + word_ids + [None]
        elif max_length is not None:
            ids = ids[:max_length]
            word_ids = word_ids[:max_length]
        return ids, word_ids
