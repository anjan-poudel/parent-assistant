"""T-033 shared encoder model: joint intent head + BIO slot head.

One shared encoder pass produces both heads, as the proposal's architecture
sketch requires (intent classification + token-level slot spans). Used by the
fine-tune script (`bakeoff_finetune.py`) and the eval harness encoder backend
(`eval_golden.py --backend encoder`), so training and inference cannot drift.

Slot supervision note: the current dataset's slot labels are only verbatim-
alignable to the utterance for ~65% of slot rows (contact 1374/2088, time
449/709). Rows whose non-null slot strings are not found in the utterance are
excluded from the slot loss (weight 0) instead of being taught an O tag that
would suppress real spans.

This is spike code, not the T-035 design — it exists to answer the GO/NO-GO.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import torch
import torch.nn as nn

# Intel-Mac CoreML export shim. torch 2.2.2 is the last release with macOS
# x86_64 wheels and has no Dynamo on Python 3.12, but transformers'
# modeling_modernbert.py applies @torch.compile(dynamic=True) at import time —
# so importing ModernBERT dies there. Compilation is irrelevant to a traced /
# exported graph (and would interfere with torch.jit.trace anyway), so on the
# export host the env var below replaces torch.compile with an identity
# decorator. Not used on the CUDA box, which has torch 2.6.
if os.environ.get("T033_PATCH_TORCH_COMPILE") == "1":  # pragma: no cover
    def _identity_compile(fn=None, **_kwargs):
        return fn if callable(fn) else (lambda f: f)

    torch.compile = _identity_compile

TAGS = ["O", "B-contact", "I-contact", "B-time", "I-time"]
TAG2ID = {t: i for i, t in enumerate(TAGS)}
SLOT_OF_TAG = {"contact": {"B-contact", "I-contact"}, "time": {"B-time", "I-time"}}


def word_offsets(text: str) -> list[tuple[int, int]]:
    """Char offsets of whitespace words (Devanagari-safe: Python str is code points)."""
    out, pos = [], 0
    for w in text.split():
        i = text.index(w, pos)
        out.append((i, i + len(w)))
        pos = i + len(w)
    return out


def bio_tags(utterance: str, slots: dict[str, str | None]) -> tuple[list[int], bool]:
    """Whitespace-word BIO tags + whether every non-null slot aligned verbatim."""
    words = utterance.split()
    tags = ["O"] * len(words)
    aligned_all = True
    offs = word_offsets(utterance)
    for name, span in slots.items():
        if not span:
            continue
        start = utterance.find(span)
        if start < 0:
            aligned_all = False
            continue
        end = start + len(span)
        first = True
        for wi, (a, b) in enumerate(offs):
            if a < end and b > start:  # word overlaps the span
                tags[wi] = f"B-{name}" if first else f"I-{name}"
                first = False
    return [TAG2ID[t] for t in tags], aligned_all


def spans_from_tags(words: list[str], tag_ids: list[int], label: str) -> str | None:
    """Concatenate B-/I- runs of `label` back into the surface string."""
    keep, cur = [], []
    for w, t in zip(words, tag_ids):
        tg = TAGS[t] if 0 <= t < len(TAGS) else "O"
        if tg in SLOT_OF_TAG[label]:
            cur.append(w)
        else:
            if cur:
                keep.append(" ".join(cur))
                cur = []
    if cur:
        keep.append(" ".join(cur))
    return " ".join(keep) if keep else None


class JointEncoder(nn.Module):
    def __init__(self, backbone_name_or_path: str, num_intents: int):
        super().__init__()
        from transformers import AutoModel
        self.backbone = AutoModel.from_pretrained(backbone_name_or_path)
        hidden = int(self.backbone.config.hidden_size)
        self.intent_head = nn.Linear(hidden, num_intents)
        self.slot_head = nn.Linear(hidden, len(TAGS))

    def forward(self, input_ids, attention_mask):
        out = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
        h = out.last_hidden_state
        pooled = h[:, 0]
        return self.intent_head(pooled), self.slot_head(h)


def save_model(model: JointEncoder, tokenizer, out_dir: str | Path, meta: dict) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    # Persist the resolved local backbone path so evaluation never refetches
    # from the Hub (transformers records it in config._name_or_path when a
    # checkpoint is loaded from the cache).
    meta.setdefault("backbone_local",
                    str(getattr(model.backbone.config, "_name_or_path", "") or ""))
    torch.save({"state_dict": model.state_dict(), "meta": meta}, out / "model.pt")
    tokenizer.save_pretrained(out)
    (out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False))


def load_model(model_dir: str | Path, map_location="cpu"):
    from transformers import AutoTokenizer
    d = Path(model_dir)
    ckpt = torch.load(d / "model.pt", map_location=map_location, weights_only=False)
    meta = ckpt["meta"]
    # Prefer the recorded local backbone path; fall back to the Hub id when
    # the checkpoint is loaded on a different machine (e.g. Mac for CoreML).
    # T033_BACKBONE_OVERRIDE points at a local backbone directory (used on the
    # export host, where the recorded server path does not exist and the
    # original .bin checkpoint is refused by transformers on torch < 2.6
    # (CVE-2025-32434 guard) — the override dir carries safetensors instead).
    local = os.environ.get("T033_BACKBONE_OVERRIDE") or meta.get("backbone_local") or ""
    backbone = local if local and Path(local).exists() else meta["backbone"]
    model = JointEncoder(backbone, num_intents=len(meta["intents"]))
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    tok = AutoTokenizer.from_pretrained(str(d))
    return model, tok, meta


@torch.no_grad()
def predict_encoder(utterance: str, model: JointEncoder, tok, meta: dict,
                    device: str = "cpu") -> dict:
    """Harness-compatible prediction dict (top-level contact/time like the LLM backends).

    Training and inference tokenise with `is_split_into_words=True` so word
    alignment for BIO decoding is exact and the two paths cannot drift.
    """
    words = utterance.split() or [utterance]
    max_len = int(meta.get("max_len", 64))
    enc = tok(words, is_split_into_words=True, truncation=True,
              max_length=max_len, return_tensors="pt")
    wids = enc.word_ids(0)                      # BatchEncoding before detach
    input_ids = enc["input_ids"].to(device)
    attention_mask = enc["attention_mask"].to(device)
    logits, slot_logits = model(input_ids, attention_mask)
    probs = torch.softmax(logits.float(), dim=-1)[0]
    conf, idx = float(probs.max()), int(probs.argmax())
    intent = meta["intents"][idx]

    token_tags = slot_logits.argmax(-1)[0].tolist()
    first_tag: dict[int, int] = {}
    for pos, wi in enumerate(wids):
        if wi is not None and wi not in first_tag:
            first_tag[wi] = token_tags[pos]
    word_tag = [first_tag.get(i, TAG2ID["O"]) for i in range(len(words))]

    return {
        "action": intent,
        "intent": intent,
        "confidence": round(conf, 4),
        "contact": spans_from_tags(words, word_tag, "contact"),
        "time": spans_from_tags(words, word_tag, "time"),
    }
