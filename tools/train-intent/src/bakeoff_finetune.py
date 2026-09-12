"""T-033 encoder fine-tune — joint intent head + BIO slot head, one shared pass.

Spike-grade training: 3 epochs, seed 42, on the snapshot of
`tools/train-intent`'s own `data/train.jsonl` (the LLM-format dataset, because
T-032/T-034 owns the register-designed dataset). No PII: synthetic teacher
rows only (NFR-016).

Every run writes `manifest.json` next to the checkpoint with the exact command
line, dataset SHA-256, config SHA-256 and checkpoint digest (K7 —
reproducibility).

Usage (server):
    python src/bakeoff_finetune.py \
        --repo jhu-clsp/mmBERT-small \
        --train data/train_snapshot.jsonl --valid data/valid_snapshot.jsonl \
        --out-dir models/C2-mmBERT-small --device cuda
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import torch
import torch.nn as nn

from bakeoff_encoder import JointEncoder, bio_tags, save_model, TAGS


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_jsonl(path: str, intents: list[str] | None = None) -> list[dict]:
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if intents is not None and r.get("intent") not in intents:
            continue
        tags, aligned = bio_tags(r["utterance"], {"contact": r.get("contact"),
                                                  "time": r.get("time")})
        rows.append({"utterance": r["utterance"], "intent": r["intent"],
                     "words": r["utterance"].split(), "tags": tags,
                     "slot_weight": 1.0 if aligned else 0.0})
    return rows


def encode(tok, row: dict, max_len: int) -> dict:
    enc = tok(row["words"], is_split_into_words=True, truncation=True,
              max_length=max_len)
    labels = [-100] * len(enc["input_ids"])
    for pos, wi in enumerate(enc.word_ids()):
        if wi is not None and pos < len(labels):
            labels[pos] = row["tags"][wi]
    return {"input_ids": enc["input_ids"], "attention_mask": enc["attention_mask"],
            "intent": row["intent"], "tags": labels, "slot_weight": row["slot_weight"],
            "n_words": len(row["words"])}


def collate(batch, tok, intent2id):
    maxlen = max(len(b["input_ids"]) for b in batch)
    input_ids = torch.full((len(batch), maxlen), tok.pad_token_id or 0, dtype=torch.long)
    attn = torch.zeros((len(batch), maxlen), dtype=torch.long)
    labels = torch.full((len(batch), maxlen), -100, dtype=torch.long)
    for i, b in enumerate(batch):
        n = len(b["input_ids"])
        input_ids[i, :n] = torch.tensor(b["input_ids"])
        attn[i, :n] = torch.tensor(b["attention_mask"])
        labels[i, :n] = torch.tensor(b["tags"])
    return {
        "input_ids": input_ids, "attention_mask": attn, "tags": labels,
        "intents": torch.tensor([intent2id[b["intent"]] for b in batch]),
        "slot_weights": torch.tensor([b["slot_weight"] for b in batch]),
    }


@torch.no_grad()
def evaluate(model, tok, rows, intent2id, device, max_len, batch_size=64):
    model.eval()
    correct = total = 0
    for i in range(0, len(rows), batch_size):
        batch = collate([encode(tok, r, max_len) for r in rows[i:i + batch_size]],
                        tok, intent2id)
        batch = {k: v.to(device) for k, v in batch.items()}
        logits, _ = model(batch["input_ids"], batch["attention_mask"])
        pred = logits.argmax(-1)
        correct += int((pred == batch["intents"]).sum())
        total += len(batch["intents"])
    model.train()
    return correct / max(total, 1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="HF id or local snapshot path")
    ap.add_argument("--train", required=True)
    ap.add_argument("--valid", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--batch-size", type=int, default=32)
    ap.add_argument("--max-len", type=int, default=64)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    ap.add_argument("--max-train", type=int, default=0)
    ap.add_argument("--backbone-path", default="", help="local path override")
    args = ap.parse_args()

    t0 = time.time()
    random.seed(args.seed)
    torch.manual_seed(args.seed)

    from transformers import AutoTokenizer
    backbone = args.backbone_path or args.repo
    tok = AutoTokenizer.from_pretrained(backbone)

    train_rows = read_jsonl(args.train)
    valid_rows = read_jsonl(args.valid)
    intents = sorted({r["intent"] for r in train_rows})
    intent2id = {it: i for i, it in enumerate(intents)}
    train_rows = [r for r in train_rows if r["intent"] in intent2id]
    valid_rows = [r for r in valid_rows if r["intent"] in intent2id]
    if args.max_train:
        train_rows = train_rows[:args.max_train]
    aligned = sum(r["slot_weight"] for r in train_rows) / max(len(train_rows), 1)
    print(f"[data] train={len(train_rows)} valid={len(valid_rows)} intents={intents}")
    print(f"[data] slot-supervisable rows: {aligned:.1%} "
          f"(rest excluded from slot loss — alignment limit, see K6 note)")

    model = JointEncoder(backbone, num_intents=len(intents)).to(args.device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"[model] {backbone}: {n_params/1e6:.1f}M params on {args.device}")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    encoded = [encode(tok, r, args.max_len) for r in train_rows]
    steps_per_epoch = (len(encoded) + args.batch_size - 1) // args.batch_size
    total_steps = steps_per_epoch * args.epochs
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=args.lr, total_steps=total_steps, pct_start=0.1)
    ce = nn.CrossEntropyLoss()
    ce_slot = nn.CrossEntropyLoss(reduction="none", ignore_index=-100)

    model.train()
    step = 0
    best_val = -1.0
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for epoch in range(args.epochs):
        order = list(range(len(encoded)))
        random.shuffle(order)
        for i in range(0, len(order), args.batch_size):
            idx = order[i:i + args.batch_size]
            batch = collate([encoded[j] for j in idx], tok, intent2id)
            w = batch.pop("slot_weights")
            batch = {k: v.to(args.device) for k, v in batch.items()}
            logits, slot_logits = model(batch["input_ids"], batch["attention_mask"])
            loss_intent = ce(logits, batch["intents"])
            slot_loss = ce_slot(slot_logits.reshape(-1, len(TAGS)),
                                batch["tags"].reshape(-1)).view(batch["tags"].shape)
            tok_mask = (batch["tags"] != -100).float()
            row_loss = (slot_loss * tok_mask).sum(1) / tok_mask.sum(1).clamp(min=1)
            loss_slot = (row_loss * w).sum() / w.sum().clamp(min=1e-6)
            loss = loss_intent + loss_slot
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            step += 1
            if step % 50 == 0 or step == total_steps:
                print(f"[train] epoch {epoch+1} step {step}/{total_steps} "
                      f"loss={loss.item():.4f} (intent {loss_intent.item():.4f} "
                      f"slot {loss_slot.item():.4f}) lr={sched.get_last_lr()[0]:.2e} "
                      f"elapsed={time.time()-t0:.0f}s", flush=True)
        val_acc = evaluate(model, tok, valid_rows, intent2id, args.device, args.max_len)
        print(f"[epoch {epoch+1}] valid intent accuracy: {val_acc:.3f}", flush=True)
        if val_acc >= best_val:
            best_val = val_acc
            meta = {
                "backbone": backbone, "repo_arg": args.repo, "intents": intents,
                "tags": TAGS, "max_len": args.max_len, "seed": args.seed,
                "epochs": args.epochs, "lr": args.lr, "batch_size": args.batch_size,
                "valid_intent_accuracy": val_acc, "params": n_params,
                "train_file": args.train, "valid_file": args.valid,
                "train_sha256": sha256(args.train), "valid_sha256": sha256(args.valid),
            }
            save_model(model, tok, out_dir, meta)
            print(f"[save] best checkpoint -> {out_dir} (valid acc {val_acc:.3f})", flush=True)

    ckpt = out_dir / "model.pt"
    manifest = {
        "command": " ".join(sys.argv),
        "repo": args.repo, "backbone": backbone, "device": args.device,
        "dataset_sha256": sha256(args.train), "valid_sha256": sha256(args.valid),
        "config_sha256": sha256(str(Path(__file__).parent.parent / "config.yaml")),
        "checkpoint_sha256": sha256(str(ckpt)) if ckpt.exists() else None,
        "best_valid_intent_accuracy": best_val, "train_rows": len(train_rows),
        "elapsed_seconds": round(time.time() - t0, 1),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"[done] {out_dir} best_val={best_val:.3f} elapsed={time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
