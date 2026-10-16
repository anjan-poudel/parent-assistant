"""Correction-model training — the PROPOSE task (masked-span fill).

Measured (2026-10-12): rank-the-pool correction covers ~0.1% of real
errors; the 4B brain cannot generate corrections (0.5% few-shot). The
correction task is generative, so the model is trained to FILL the
masked word: input = the sentence with the misheard word replaced by
<mask>, target = the true word's BPE pieces + <eow> at the mask
position (teacher forcing, cross-entropy per position).

ARCHITECTURE: BERT-small class encoder (6 layers, 384 hidden) over the
BPE vocabulary (trained on the template + wiki corpora with
<mask>/<eow> user symbols), vocab head. Inference: greedy argmax per
position until <eow> (max 4 pieces).

GPU (the 3090; --smoke = 200-row CPU wiring check). Run from
tools/train-intent/ (the train venv has torch+cu121):

    /mnt/.../tools/train/.venv/bin/python3 src/stt_train_correction_judge.py \
        --data build/correction-judge/ --tokenizer build/correction-sp.model \
        --out build/correction-judge-model/ --epochs 6 --batch 64

Acceptance bar: valid exact-match must clear the 4B judge's 79.5%
choice number to earn the seam (and it must beat it on the FULL error
distribution, which the choice path cannot reach at all).
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402


class GuardError(Exception):
    pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--max-length", type=int, default=64)
    parser.add_argument("--max-answer", type=int, default=4)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"],
                        default="auto")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    try:
        import sentencepiece as spm
        import torch
        import torch.nn as nn
        from torch.utils.data import DataLoader, Dataset
    except ImportError as failure:
        print(f"dependency missing: {failure}", file=sys.stderr)
        return EXIT_USAGE

    train_path = args.data / "train.jsonl"
    valid_path = args.data / "valid.jsonl"
    if not train_path.is_file():
        print(f"guard refused: {train_path} missing", file=sys.stderr)
        return EXIT_GUARD
    if not args.tokenizer.is_file():
        print(f"guard refused: {args.tokenizer} missing", file=sys.stderr)
        return EXIT_GUARD

    sp = spm.SentencePieceProcessor(model_file=str(args.tokenizer))
    vocab = sp.get_piece_size()
    # `in sp` iterates by INTEGER index on this sentencepiece binding —
    # never use containment on the processor; piece_to_id is the check.
    mask_id = sp.piece_to_id("<mask>")
    eow_id = sp.piece_to_id("<eow>")
    if mask_id == sp.unk_id() or eow_id == sp.unk_id():
        print("guard refused: the tokenizer must carry <mask>/<eow> user "
              "symbols (train the BPE with them)", file=sys.stderr)
        return EXIT_GUARD

    def load_rows(path: Path) -> list:
        rows = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
        return rows

    train_rows = load_rows(train_path)
    valid_rows = load_rows(valid_path)
    if len(train_rows) < 1000 and not args.smoke:
        print(f"floor refused: {len(train_rows)} training rows < 1000",
              file=sys.stderr)
        return EXIT_FLOOR
    if args.smoke:
        train_rows = train_rows[:200]
        valid_rows = valid_rows[:50]

    class ProposeDataset(Dataset):
        def __init__(self, rows: list):
            self.items = []
            for row in rows:
                tokens = row["sentence"].split()
                position = min(row["position"], len(tokens) - 1)
                marked = tokens[:position] + ["<mask>"] + tokens[position + 1:]
                ids = sp.encode(" ".join(marked), out_type=int,
                                add_bos=True, add_eos=True)
                if len(ids) > args.max_length:
                    ids = ids[: args.max_length]
                answer = sp.encode(row["answer"], out_type=int)
                if not answer:
                    continue
                self.items.append((ids, answer[: args.max_answer],
                                   row["answer"]))

        def __len__(self) -> int:
            return len(self.items)

        def __getitem__(self, index: int):
            return self.items[index]

    def collate(batch):
        max_len = max(len(ids) for ids, _, _ in batch)
        max_ans = max(len(answer) for _, answer, _ in batch)
        input_ids = torch.zeros(len(batch), max_len, dtype=torch.long)
        target_ids = torch.full((len(batch), max_ans), -100,
                                dtype=torch.long)
        answers = []
        for b, (ids, answer, answer_text) in enumerate(batch):
            input_ids[b, : len(ids)] = torch.tensor(ids, dtype=torch.long)
            target_ids[b, : len(answer)] = torch.tensor(answer,
                                                        dtype=torch.long)
            target_ids[b, len(answer): len(answer) + 1] = eow_id
            answers.append(answer_text)
        return input_ids, target_ids, answers

    class ProposeModel(nn.Module):
        def __init__(self):
            super().__init__()
            hidden = 384
            self.embedding = nn.Embedding(vocab, hidden, padding_idx=0)
            layer = nn.TransformerEncoderLayer(
                d_model=hidden, nhead=8, dim_feedforward=1536,
                batch_first=True, dropout=0.1, activation="gelu")
            self.encoder = nn.TransformerEncoder(layer, num_layers=6)
            self.head = nn.Linear(hidden, vocab)

        def forward(self, input_ids):
            mask = input_ids == 0
            embedded = self.embedding(input_ids)
            encoded = self.encoder(embedded, src_key_padding_mask=mask)
            logits = self.head(encoded)
            return logits

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    # The 3090 has flaked "busy or unavailable" at CUDA init repeatedly
    # since the reboot — `--device cpu` is the reliable path until the
    # card's state is sorted (nvidia-smi answers, CUDA contexts fail).
    if args.smoke:
        device = torch.device("cpu")
    elif args.device == "cpu":
        device = torch.device("cpu")
    elif args.device == "cuda":
        device = torch.device("cuda")
    else:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[judge-train] device {device}, rows train {len(train_rows)} "
          f"valid {len(valid_rows)}, vocab {vocab}", file=sys.stderr)

    model = ProposeModel().to(device)
    loader = DataLoader(ProposeDataset(train_rows), batch_size=args.batch,
                        shuffle=True, collate_fn=collate)
    valid_loader = DataLoader(ProposeDataset(valid_rows),
                              batch_size=args.batch, collate_fn=collate)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    steps_per_epoch = max(1, len(loader))
    scheduler = torch.optim.lr_scheduler.OneCycleLR(
        optimizer, max_lr=args.lr,
        total_steps=steps_per_epoch * args.epochs, pct_start=0.1)

    def decode_word(input_ids_row, logits_row):
        """Greedy: read the prediction AT the mask position, then extend
        while the previous step's argmax feeds forward (autoregressive
        span fill) until <eow> or max-answer pieces."""
        pieces = []
        # The mask position in the input row.
        positions = (input_ids_row == mask_id).nonzero(as_tuple=True)[0]
        if len(positions) == 0:
            return ""
        pos = positions[0].item()
        for _ in range(args.max_answer):
            if pos >= logits_row.shape[0]:
                break
            token = logits_row[pos].argmax().item()
            if token == eow_id or token in (0, 1, 2):
                break
            pieces.append(token)
            pos += 1
        if not pieces:
            return ""
        return sp.decode(pieces)

    # Answer matching needs the row answers — carry them through the
    # loader instead: rebuild a per-batch answer list.
    def accuracy_with_rows(loader, max_batches=None):
        model.eval()
        correct = total = 0
        with torch.no_grad():
            for input_ids, _, answers in loader:
                input_ids = input_ids.to(device)
                logits = model(input_ids)
                for b in range(input_ids.shape[0]):
                    word = decode_word(input_ids[b], logits[b])
                    total += 1
                    if word and word == answers[b]:
                        correct += 1
        model.train()
        return correct / max(1, total)

    best = 0.0
    for epoch in range(args.epochs):
        running = 0.0
        for input_ids, target_ids, _ in loader:
            input_ids = input_ids.to(device)
            target_ids = target_ids.to(device)
            optimizer.zero_grad()
            logits = model(input_ids)
            # The targets align with the positions AFTER the mask.
            # Align: find the mask position per row and slide the target.
            batch, seq = input_ids.shape
            loss = 0.0
            count = 0
            mask_positions = (input_ids == mask_id).nonzero()
            for b, pos in mask_positions.tolist():
                for offset in range(target_ids.shape[1]):
                    target = target_ids[b, offset].item()
                    if target == -100:
                        continue
                    position = pos + 1 + offset
                    if position >= seq:
                        break
                    loss = loss + nn.functional.cross_entropy(
                        logits[b, position: position + 1],
                        torch.tensor([target], device=device))
                    count += 1
            if count:
                loss = loss / count
                loss.backward()
                optimizer.step()
                scheduler.step()
                running += loss.item()
        valid_acc = accuracy_with_rows(valid_loader)
        best = max(best, valid_acc)
        print(f"[judge-train] epoch {epoch + 1}/{args.epochs} loss "
              f"{running / max(1, len(loader)):.3f} valid exact "
              f"{valid_acc:.3f}", file=sys.stderr)
        if args.smoke:
            break

    args.out.mkdir(parents=True, exist_ok=True)
    torch.save({"model": model.state_dict(), "vocab": vocab,
                "config": {"hidden": 384, "layers": 6, "heads": 8,
                           "max_length": args.max_length,
                           "max_answer": args.max_answer}},
               args.out / "model.pt")
    meta = {
        "valid_exact": round(best, 4),
        "bar_4b_choice": 0.795,
        "rows": {"train": len(train_rows), "valid": len(valid_rows)},
        "smoke": args.smoke,
    }
    (args.out / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")
    print(f"[judge-train] valid exact {best:.3f}", file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
