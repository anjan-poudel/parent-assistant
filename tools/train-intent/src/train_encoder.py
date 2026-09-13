"""T-036 stage E2 — encoder fine-tune: joint intent + BIO slot model, resumable.

Model: the T-033 `JointEncoder` (shared backbone, [CLS]-pooled intent head,
token slot head) instantiated with the T-034 13-tag BIO set. Tokenisation uses
the pinned XLM-R sentencepiece and span alignment follows T-034 §4.3
(`encoder_align.py`). Data is stage E1's output (`build_encoder_dataset.py`).

Guards run BEFORE torch/transformers are imported, so a refused input fails
identically on a host without torch:
  - the golden corpus is refused as a train/valid input (by construction);
  - any row whose normalized utterance is in the golden corpus is a hard error
    (the builder already drops those — seeing one means the corpus was not
    produced by stage E1);
  - the E1 build report must exist and say `usable_for_training: true`
    (`--smoke` relaxes this for wiring runs only);
  - the base model revision / tokenizer vocab must match the T-034 pin;
  - the GPU must be free before a CUDA run starts (never overlap another job).

Resumability: `state.pt` holds model/optimizer/scheduler/step/epoch/rng plus
the config and data hashes it started with. `--fresh` discards it; a mismatch
is a refusal, never a silent continue.

No PII (NFR-016): logs, manifest and report carry paths, hashes, counters and
label histograms — never an utterance.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import (  # noqa: E402  (guards before torch, on purpose)
    EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE, GuardError, assert_not_golden_input,
    canonical_json, check_gpu_free, leak_refusals, read_json, read_jsonl,
    sha256_file, utc_now, write_json,
)
from encoder_rules import T035PendingError, load_rules  # noqa: E402
from encoder_contract import (  # noqa: E402
    ContractError, distill_loss, distill_skip_reason, load_contract, soft_targets,
)
from encoder_align import (  # noqa: E402
    AlignError, canonical_text_violations, encode_row, validate_spans,
)
from config import abs_path, load_config  # noqa: E402

IGNORE_INDEX = -100
EVENTS_FILE = "manifest_events.jsonl"


# --------------------------------------------------------------------------
# data loading (torch-free)
# --------------------------------------------------------------------------
def load_encoder_rows(path: Path, rules, counters: dict, max_rows: int = 0) -> list[dict]:
    """Read a stage-E1 JSONL and re-validate it. Never masks a bad row."""
    rows = read_jsonl(path)
    if max_rows:
        rows = rows[:max_rows]
    keep = []
    for r in rows:
        rid = r.get("id") or ""
        utt = r.get("utterance")
        if not rid or not isinstance(utt, str) or not utt.strip():
            counters["schema_row"] += 1
            continue
        action = r.get("action")
        if action not in rules.labels:
            counters["unknown_label"] += 1
            continue
        bad = canonical_text_violations(utt)
        if bad:
            counters["non_canonical_utterance"] += 1
            continue
        spans = r.get("spans") or []
        viol = validate_spans(utt, spans)
        if viol:
            counters["span_validation"] += 1
            continue
        for s in spans:
            if s.get("label") not in rules.span_labels:
                counters["unknown_span_label"] += 1
                break
        else:
            conf = r.get("confidence")
            keep.append({"id": rid, "utterance": utt, "action": action,
                         "spans": spans, "register": r.get("register"),
                         "source": r.get("source"),
                         "confidence": float(conf) if isinstance(conf, (int, float)) else None})
    return keep


def label_histogram(rows: list[dict], key: str) -> dict:
    out: dict[str, int] = {}
    for r in rows:
        v = r.get(key) or "unknown"
        out[str(v)] = out.get(str(v), 0) + 1
    return dict(sorted(out.items()))


def span_histogram(rows: list[dict], rules) -> dict:
    out = {lab: 0 for lab in rules.span_labels}
    for r in rows:
        seen = {s["label"] for s in r["spans"]}
        for lab in seen:
            out[lab] = out.get(lab, 0) + 1
    return out


# --------------------------------------------------------------------------
# tokenisation / alignment (needs the tokenizer, still torch-free)
# --------------------------------------------------------------------------
def build_features(tok, rows: list[dict], rules, max_len: int,
                   counters: dict) -> list[dict]:
    """T-034 §4.3 projection + the train/infer tokenisation identity check.

    The harness tokenises with `is_split_into_words=True` while training maps
    raw-utterance offsets. For a whitespace-canonical utterance the two must
    produce identical ids; a single mismatch would silently train and evaluate
    different functions, so it is a hard refusal.
    """
    feats = []
    for r in rows:
        try:
            ids, tags = encode_row(tok, r["utterance"], r["spans"],
                                   rules.span_labels, rules.tag2id)
        except AlignError as e:
            raise GuardError(
                f"row {r['id']}: spans are not alignable ({e}) — stage E1 must "
                "drop such rows; refusing to mask them into O tags.") from e
        words = r["utterance"].split()
        ids_words = tok(words, is_split_into_words=True, add_special_tokens=True,
                        truncation=False)["input_ids"]
        if list(ids_words) != list(ids[:len(ids_words)]):
            counters["tokenization_identity_mismatch"] += 1
            raise GuardError(
                f"row {r['id']}: raw-text and is_split_into_words tokenisation "
                "disagree — training and eval_golden.py would score different "
                "functions. Refusing to train.")
        if len(ids) > max_len:
            cut = [t for t in tags[max_len:] if t is not None and t != rules.tag2id["O"]]
            if cut:
                counters["over_max_len_with_spans"] += 1
                raise GuardError(
                    f"row {r['id']}: a span falls past max_len={max_len}; "
                    "raise encoder.max_len or drop the row in stage E1.")
            ids, tags = ids[:max_len], tags[:max_len]
            counters["truncated"] += 1
        feats.append({"id": r["id"], "intent": r["action"],
                      "confidence": r.get("confidence"),
                      "input_ids": ids, "tags": tags})
    return feats


def collate(batch: list[dict], pad_id: int, label_of: dict | None = None):
    import torch

    n = max(len(b["input_ids"]) for b in batch)
    ids = torch.full((len(batch), n), pad_id, dtype=torch.long)
    mask = torch.zeros((len(batch), n), dtype=torch.long)
    tags = torch.full((len(batch), n), IGNORE_INDEX, dtype=torch.long)
    for i, b in enumerate(batch):
        L = len(b["input_ids"])
        ids[i, :L] = torch.tensor(b["input_ids"], dtype=torch.long)
        mask[i, :L] = 1
        # `tags` is None for intent-only callers (calibration collects intent
        # logits, it has no gold tags); the slot tensor stays all-ignore_index.
        if b.get("tags") is not None:
            tags[i, :L] = torch.tensor(
                [IGNORE_INDEX if t is None else t for t in b["tags"]], dtype=torch.long)
    out = {"input_ids": ids, "attention_mask": mask, "tags": tags}
    if label_of is not None:
        out["intent_labels"] = torch.tensor([label_of[b["intent"]] for b in batch],
                                            dtype=torch.long)
        out["confidence"] = [b.get("confidence") for b in batch]
    return out


# --------------------------------------------------------------------------
# evaluation (word-level spans, matching the harness's decode)
# --------------------------------------------------------------------------
def word_tag_ids(tok, utterance: str, ids: list[int], token_tag_ids: list[int],
                 rules) -> list[int]:
    """Project token tags to words via the word_ids of an is_split_into_words pass
    (same rule as bakeoff_encoder.predict_encoder: first token of a word wins)."""
    words = utterance.split()
    enc = tok(words, is_split_into_words=True, add_special_tokens=True, truncation=True,
              max_length=len(ids))
    wids = enc.word_ids(0) if hasattr(enc, "word_ids") else None
    first: dict[int, int] = {}
    for pos, wi in enumerate(wids or []):
        if wi is not None and wi not in first:
            first[wi] = token_tag_ids[pos]
    return [first.get(i, rules.tag2id["O"]) for i in range(len(words))]


def spans_from_word_tags(utterance: str, word_tags: list[int], rules) -> set:
    """Decode word-level tag ids into (label, start, end) — offset-free, so a
    prediction is comparable to a gold span even when the gold text differs."""
    words = utterance.split()
    offs, pos = [], 0
    for w in words:
        i = utterance.index(w, pos)
        offs.append((i, i + len(w)))
        pos = i + len(w)
    out, cur_label, start, end = set(), None, None, None
    for (a, b), t in zip(offs, word_tags):
        lab = None
        if 0 <= t < len(rules.bio_tags):
            tag = rules.bio_tags[t]
            if tag != "O":
                lab = tag.split("-", 1)[1]
        if lab != cur_label:
            if cur_label is not None:
                out.add((cur_label, start, end))
            cur_label, start = lab, (a if lab else None)
        if lab:
            end = b
    if cur_label is not None:
        out.add((cur_label, start, end))
    return out


def gold_spans(row: dict) -> set:
    return {(s["label"], s["start"], s["end"]) for s in row["spans"]}


def evaluate(model, tok, rows: list[dict], feats: list[dict], rules, device: str,
             batch_size: int) -> dict:
    import torch

    model.eval()
    # Canonical logit order (== contract.heads.intent.labels, asserted at load).
    intents = list(rules.labels)
    idx_of = {a: i for i, a in enumerate(intents)}
    correct = total = 0
    tp = fp = fn = 0
    with torch.no_grad():
        for i in range(0, len(feats), batch_size):
            chunk = feats[i:i + batch_size]
            batch = collate(chunk, tok.pad_token_id)
            logits, slot_logits = model(batch["input_ids"].to(device),
                                        batch["attention_mask"].to(device))
            pred = logits.argmax(-1).tolist()
            tags = slot_logits.argmax(-1).tolist()
            for j, f in enumerate(chunk):
                row = rows[i + j]
                total += 1
                correct += int(pred[j] == idx_of[row["action"]])
                wtags = word_tag_ids(tok, row["utterance"],
                                     f["input_ids"],
                                     tags[j][:len(f["input_ids"])], rules)
                p, g = spans_from_word_tags(row["utterance"], wtags, rules), gold_spans(row)
                tp += len(p & g)
                fp += len(p - g)
                fn += len(g - p)
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    return {"rows": total,
            "intent_accuracy": round(correct / total, 4) if total else 0.0,
            "slot_precision": round(prec, 4), "slot_recall": round(rec, 4),
            "slot_f1": round(f1, 4), "slot_tp": tp, "slot_fp": fp, "slot_fn": fn}


# --------------------------------------------------------------------------
# distillation (parameters and formula from the T-035 contract)
# --------------------------------------------------------------------------
def distillation_spec(cfg: dict, contract, n_params: int | None = None) -> dict:
    """The distillation decision, always reported — enabled or skipped.

    The contract makes stage 2 conditional: it runs only when a real teacher
    distribution exists. `gemini_teacher_rows` is available but its per-class
    target is a STATED construction from a scalar row confidence — so the
    default is to skip and RECORD that (never to silently train a second
    objective the contract did not measure).
    """
    if not bool(cfg.get("encoder.distillation.enabled", False)):
        return {"enabled": False, "reason": distill_skip_reason(contract),
                "contract_defaults": {"temperature": contract.distill_temperature,
                                      "lambda_kd": contract.distill_lambda_kd,
                                      "formula": contract.distill_formula}}
    teacher = (cfg.get("encoder.distillation.teacher")
               or (contract.available_teacher() or {}).get("id"))
    if not teacher:
        raise T035PendingError(
            "encoder.distillation.enabled=true but the contract lists no available "
            "teacher (loss.distillation.teacher_preference_order) — nothing to "
            "distill from; keep stage 2 off or land a teacher distribution.")
    tau = float(cfg.get("encoder.distillation.temperature") or contract.distill_temperature)
    lam = float(cfg.get("encoder.distillation.lambda_kd") or contract.distill_lambda_kd)
    spec = {"enabled": True, "teacher": teacher, "temperature": tau,
            "lambda_kd": lam, "formula": contract.distill_formula,
            "objective": "kd_tau2_kl", "slot_distillation": contract.slot_distillation,
            "teacher_at_runtime": "forbidden (FR-007: inference stays on-device)"}
    if contract.distill_temperature != tau:
        spec["temperature_overridden_from_contract"] = contract.distill_temperature
    if contract.distill_lambda_kd != lam:
        spec["lambda_kd_overridden_from_contract"] = contract.distill_lambda_kd
    return spec


def intent_loss_weights(contract, intents: list[str], cfg: dict):
    """Class weights from the contract (emergency > others), optional override.

    The override lives inside the contract's stated tuning range; outside it the
    run is refused rather than quietly trading away the emergency hard gate.
    """
    import torch

    w = torch.ones(len(intents))
    override = cfg.get("encoder.loss.emergency_weight")
    em = float(override or contract.intent_weights["emergency"])
    lo_hi = contract.emergency_weight_range
    if override and em != contract.intent_weights["emergency"]:
        if lo_hi is None:
            raise ContractError(
                f"encoder.loss.emergency_weight={em} was set but the consumed contract "
                f"revision states no machine-readable tuning range ({contract.path.name}"
                f" sha={contract.sha256[:12]}) — keep the contract default "
                f"{contract.intent_weights['emergency']} or get the range into the "
                "contract before sweeping it.")
        if not (lo_hi[0] <= em <= lo_hi[1]):
            raise ContractError(
                f"encoder.loss.emergency_weight={em} is outside the contract's stated "
                f"tuning range [{lo_hi[0]}, {lo_hi[1]}]")
    w[intents.index("emergency")] = em
    return w


# --------------------------------------------------------------------------
# checkpointing / resumability
# --------------------------------------------------------------------------
def make_meta(rules, cfg, base_repo: str, max_len: int, steps: int,
              data_hashes: dict, smoke: bool, calib: dict | None = None,
              contract=None) -> dict:
    """Artifact meta. `intents`/`tags` ARE the logit order (T-035 contract).

    The contract's `runtime.meta_json.required_keys` are all present here:
    intents, tags, max_len, calibration_temperature, artifact_digest. The digest
    is stamped by `stamp_artifact_meta` after the weights are written (a file
    cannot contain the hash of the bytes that contain the hash).

    `calibration_temperature` is ALWAYS a number: before stage E3 fits one it is
    the honest identity 1.0 with `calibration.status='uncalibrated'`, never null —
    the interpreter divides by it, and "unset" must not be indistinguishable from
    "calibrated to 1.0". Stage E3 rewrites both keys with the fitted value.
    """
    cal = calib or {"status": "uncalibrated", "temperature": 1.0,
                    "mechanism": "identity (temperature scaling not yet fitted)",
                    "applied_in": "interpreter_code",
                    "graph_contains_temperature": False,
                    "note": "no fit has been performed; this is T=1.0, not a "
                            "calibrated value"}
    meta = {
        "intents": list(rules.labels),      # == contract.heads.intent.labels (asserted)
        "tags": list(rules.bio_tags),       # == contract.heads.slot.tags (asserted)
        "span_labels": list(rules.span_labels),
        "max_len": max_len,
        "backbone": base_repo,
        "trained_steps": steps,
        "data": data_hashes,
        "rules_sha256": sha256_file(rules.path),
        "smoke": smoke,
        "calibration": cal,
        "calibration_temperature": float(cal.get("temperature") or 1.0),
        "artifact_digest": None,
        "provenance": {"task": "T-036", "schema": "encoder-artifact/v1"},
    }
    if contract is not None:
        meta["provenance"].update({
            "contract_path": str(contract.path),
            "contract_schema": contract.schema,
            "contract_sha256": contract.sha256,
            "contract_source_task": contract.source_task,
        })
        # Export-dtype reconciliation (int64 contract vs int32 CoreML wire) and
        # the interpreter-side runtime.config: recorded here, not re-decided.
        meta["conformance"] = {
            "input_dtype": contract.dtype_conformance(),
            "runtime_config": dict(contract.runtime_config),
            "note": "runtime.config is applied by the iOS interpreter (T-037); the "
                    "trainer neither drives nor overrides it, it is recorded so a "
                    "T-035 revision is detectable",
        }
    return meta


def stamp_artifact_meta(artifact_dir: Path) -> str:
    """Write `artifact_digest` (= sha256 of model.pt) + calibration into meta.json.

    Called after the weights are written; meta.json is the runtime contract file,
    so it carries the digest of the weights it describes. The digest is NOT fed
    back into model.pt (that would be circular).
    """
    meta_path = artifact_dir / "meta.json"
    if not meta_path.exists():
        return ""
    meta = read_json(meta_path)
    digest = sha256_file(artifact_dir / "model.pt")
    meta["artifact_digest"] = digest
    write_json(meta_path, meta)
    return digest


def load_state(path: Path, map_location="cpu"):
    import torch
    return torch.load(path, map_location=map_location, weights_only=False)


def resume_mismatch(state: dict, cfg_hash: str, data_hash: str) -> str | None:
    """Reason a resume would be a different run, or None when it is the same.

    Torch-free on purpose: the refusal is a property of the hashes, and it must
    be testable (and readable) without loading a checkpoint.
    """
    if state.get("cfg_hash") != cfg_hash:
        return ("state.pt was started with a different config (lr/batch/max_len/"
                "labels/rules changed)")
    if state.get("data_hash") != data_hash:
        return "state.pt was trained on a different dataset (train/valid hash changed)"
    return None


def tokenizer_pin_problem(tok_len: int, emb_rows: int, pinned: int) -> str | None:
    """Reason the tokenizer/model disagrees with the T-034 pin, or None.

    The pin (`spans.tokenizer.vocab_size`) is the EMBEDDING row count — for the
    C3 XLM-R checkpoint, config.json:vocab_size = 250037 — while the
    sentencepiece tokenizer itself reports 250002 (the same checkpoint: the
    extra 35 rows are reserved and unused). Comparing those two numbers to each
    other refuses a CORRECT model, which the server smoke run did, so the check
    is two-sided and explicit:
      - the embedding rows must equal the pin (catches the wrong checkpoint);
      - the tokenizer must not exceed the embeddings (catches out-of-range ids).
    Torch-free: both numbers are passed in, so the refusal is testable.
    """
    if emb_rows != pinned:
        return (f"model embedding rows {emb_rows} != pinned tokenizer vocab "
                f"{pinned} (annotation_rules.yaml spans.tokenizer.vocab_size) — "
                "wrong backbone revision pins the alignment contract")
    if tok_len > emb_rows:
        return (f"tokenizer has {tok_len} ids but the embeddings have only "
                f"{emb_rows} rows — token ids would be out of range")
    return None


def save_state(path: Path, model, opt, sched, step: int, epoch: int,
               cfg_hash: str, data_hash: str, seed: int) -> None:
    import torch
    tmp = path.with_suffix(".pt.tmp")
    torch.save({"model": model.state_dict(), "opt": opt.state_dict(),
                "sched": sched.state_dict() if sched else None,
                "step": step, "epoch": epoch, "cfg_hash": cfg_hash,
                "data_hash": data_hash, "seed": seed,
                "torch_rng": torch.get_rng_state(),
                "python_rng": random.getstate(), "saved_utc": utc_now()}, tmp)
    tmp.replace(path)


def append_event(out_dir: Path, event: dict) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    with open(out_dir / EVENTS_FILE, "a", encoding="utf-8") as f:
        f.write(canonical_json(event) + "\n")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def parse_args(argv=None):
    p = argparse.ArgumentParser(description="T-036 stage E2: encoder fine-tune")
    p.add_argument("--train", default=None, help="stage-E1 train.jsonl")
    p.add_argument("--valid", default=None, help="stage-E1 valid.jsonl")
    p.add_argument("--build-report", default=None, help="stage-E1 build_report.json")
    p.add_argument("--out-dir", default=None)
    p.add_argument("--device", default=None, help="cuda | cuda:0 | cpu | auto")
    p.add_argument("--max-steps", type=int, default=0, help="cap optimizer steps (smoke)")
    p.add_argument("--max-train", type=int, default=0, help="cap training rows (smoke)")
    p.add_argument("--batch-size", type=int, default=None)
    p.add_argument("--max-len", type=int, default=None)
    p.add_argument("--epochs", type=int, default=None)
    p.add_argument("--lr", type=float, default=None)
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--fresh", action="store_true", help="ignore any state.pt")
    p.add_argument("--smoke", action="store_true",
                   help="wiring run: allows a floor-failing corpus, never publishes")
    p.add_argument("--allow-gpu-overlap", action="store_true")
    return p


def main(argv=None) -> int:
    args, cfg = load_config(parse_args(), argv)

    # ---- guard phase: no torch, no transformers, no GPU touched ----------
    try:
        rules = load_rules()
        # The T-035 contract fixes the logit order the checkpoint carries; it is
        # asserted element-wise against the T-034 rules here, before any work.
        contract = load_contract(cfg.get("encoder.contract_path"), rules=rules)
    except (RuntimeError, KeyError) as e:  # RulesError/ContractError are RuntimeErrors
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    print(f"[contract] {contract.path.name} sha={contract.sha256[:12]} "
          f"schema={contract.schema} task={contract.source_task}")
    if contract.ignore_index != IGNORE_INDEX:
        print(f"[guard] REFUSED: contract ignore_index={contract.ignore_index} != "
              f"collate's {IGNORE_INDEX} — the slot loss would train different "
              "positions than the contract names")
        return EXIT_GUARD

    base_repo = cfg.get("encoder.base_model")
    backbone_path = cfg.get("encoder.backbone_path")
    if backbone_path:  # local snapshot wins; never refetch mid-stage
        base_repo = str(backbone_path)

    train_path = Path(args.train) if args.train else abs_path(cfg, "encoder.train_path") \
        if cfg.get("encoder.train_path") else None
    valid_path = Path(args.valid) if args.valid else None
    report_path = Path(args.build_report) if args.build_report \
        else (train_path.parent / "build_report.json" if train_path else None)
    out_dir = Path(args.out_dir) if args.out_dir else abs_path(cfg, "encoder.out_dir") \
        if cfg.get("encoder.out_dir") else None

    if not train_path or not valid_path or not out_dir:
        print("[usage] --train --valid --out-dir are required (or set encoder.* paths)")
        return EXIT_USAGE
    if not train_path.exists() or not valid_path.exists():
        print(f"[guard] REFUSED: train/valid jsonl missing ({train_path!s} / {valid_path!s})")
        return EXIT_GUARD

    try:
        assert_not_golden_input(train_path, "train input")
        assert_not_golden_input(valid_path, "valid input")

        # The E1 report is the corpus's provenance: floors + leak counter.
        build = None
        if report_path and Path(report_path).exists():
            build = read_json(report_path)
        if build is None:
            raise GuardError(
                f"build report not found ({report_path!s}) — the corpus has no "
                "provenance; re-run build_encoder_dataset.py and pass --build-report.")
        if build.get("counters", {}).get("leak", 0):
            raise GuardError("build report records leaked rows — refusing this corpus")
        if not build.get("floors", {}).get("usable_for_training", False) and not args.smoke:
            floors = build.get("floors", {})
            why = ("the build report is from a --smoke build (floors waived on purpose; "
                   "not a training corpus)" if build.get("smoke")
                   else f"{len(floors.get('unwaived', []))} unwaived floor violation(s): "
                        + "; ".join(floors.get("unwaived", [])[:3]))
            raise GuardError(
                f"build report is not trainable — {why}. Regenerate data (T-034 "
                "mixture/floors); --smoke is for wiring runs only and never publishes.")

        counters: dict[str, int] = defaultdict(int)
        train_rows = load_encoder_rows(train_path, rules, counters, args.max_train)
        valid_rows = load_encoder_rows(valid_path, rules, counters, args.max_train)
        if not train_rows or not valid_rows:
            raise GuardError("train/valid split is empty after validation")

        # Row-level leak guard (belt and braces: E1 already drops these).
        keys = _golden_keys_safe()
        leaked = leak_refusals([r["utterance"] for r in train_rows + valid_rows], keys)
        if leaked:
            raise GuardError(
                f"{leaked} row(s) whose normalized utterance is in the golden "
                "corpus — refusing to train (this corpus was not built by stage E1)")
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD

    device = args.device or cfg.get("encoder.device") or "auto"
    if device == "auto":
        import importlib.util
        has_torch = importlib.util.find_spec("torch") is not None
        if has_torch:
            import torch
            device = "cuda" if torch.cuda.is_available() else "cpu"
        else:
            device = "cpu"

    try:
        gpu = check_gpu_free(device,
                             int(cfg.get("encoder.gpu.max_resident_mib", 500) or 500),
                             bool(args.allow_gpu_overlap)
                             or bool(cfg.get("encoder.gpu.allow_overlap", False)))
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    if gpu.get("checked"):
        print(f"[gpu] {gpu['busy_processes']} busy process(es), "
              f"{gpu.get('resident_mib', 0)} MiB resident; device={device}")

    try:
        spec = distillation_spec(cfg, contract)
    except (T035PendingError, ContractError) as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    if spec["enabled"]:
        print(f"[distill] stage 2 ACTIVE: teacher={spec['teacher']} "
              f"tau={spec['temperature']} lambda_kd={spec['lambda_kd']}")
    else:
        print(f"[distill] stage 2 skipped: {spec['reason']}")

    max_len = int(args.max_len or cfg.get("encoder.max_len", 64))
    try:
        # runtime.config.maxSequenceLength is the contract's value and equals
        # meta.json:max_len (T-035); an off-contract truncation is refused here,
        # before torch is imported, like every other guard.
        contract.check_max_len(max_len)
    except ContractError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD

    # ---- heavy imports (all guards above ran without them, on purpose) ----
    try:
        import torch
        from torch.utils.data import DataLoader
        from transformers import AutoTokenizer, get_linear_schedule_with_warmup

        from bakeoff_encoder import JointEncoder
    except ModuleNotFoundError as e:
        print(f"[guard] REFUSED: {e.name!r} is not installed in this interpreter — the "
              "training stage needs the tools/train-intent venv (see README "
              "'T-036 encoder pipeline'). The guards above deliberately run first so "
              "refused inputs fail the same way on a machine without torch.")
        return EXIT_STAGE

    batch_size = int(args.batch_size or cfg.get("encoder.batch_size", 16))
    epochs = int(args.epochs or cfg.get("encoder.epochs", 6))
    lr = float(args.lr or cfg.get("encoder.lr", 5e-5))
    seed = int(args.seed or cfg.get("encoder.seed", 42))
    save_steps = int(cfg.get("encoder.save_steps", 200))
    grad_clip = float(cfg.get("encoder.grad_clip", 1.0))
    intent_w = float(cfg.get("encoder.intent_loss_weight", 1.0))
    # lambda_slot / ignore_index come from the T-035 contract, not from here.
    slot_w = float(cfg.get("encoder.slot_loss_weight") or contract.lambda_slot)
    ignore_index = contract.ignore_index
    kd_tau = float(spec["temperature"]) if spec["enabled"] else 0.0
    kd_lambda = float(spec["lambda_kd"]) if spec["enabled"] else 0.0
    max_steps = int(args.max_steps)

    tok = AutoTokenizer.from_pretrained(base_repo)
    from transformers import AutoConfig
    emb_rows = int(getattr(AutoConfig.from_pretrained(base_repo), "vocab_size", 0))
    problem = tokenizer_pin_problem(len(tok), emb_rows, rules.tokenizer_vocab)
    if problem:
        print(f"[guard] REFUSED: {problem}")
        return EXIT_GUARD
    print(f"[tok] tokenizer_vocab={len(tok)} embedding_rows={emb_rows} "
          f"pin={rules.tokenizer_vocab} repo={base_repo}")

    feats = build_features(tok, train_rows, rules, max_len, counters)
    vfeats = build_features(tok, valid_rows, rules, max_len, counters)
    data_hash = canonical_json({
        "train": sha256_file(train_path), "valid": sha256_file(valid_path),
        "rows": len(feats), "vrows": len(vfeats), "max_len": max_len})

    model = JointEncoder(base_repo, num_intents=len(rules.labels),
                         tags=list(rules.bio_tags)).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    try:
        contract.check_student_size(n_params)     # T-035 model.student_size_target_params
    except ContractError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    resolved_rev = getattr(model.backbone.config, "_commit_hash", None) or ""
    pin = rules.tokenizer_revision_prefix
    if resolved_rev and not str(resolved_rev).startswith(pin):
        print(f"[guard] REFUSED: backbone revision {str(resolved_rev)[:8]} != "
              f"pinned {pin} (annotation_rules.yaml) — tokenizer/weights drift")
        return EXIT_GUARD
    print(f"[model] params={n_params} revision={str(resolved_rev)[:8] or 'deferred'}"
          f" pinned={pin}")

    cfg_hash = canonical_json({
        "base": base_repo, "lr": lr, "batch_size": batch_size, "epochs": epochs,
        "max_len": max_len, "seed": seed, "intent_w": intent_w, "slot_w": slot_w,
        "tags": list(rules.bio_tags), "labels": list(rules.labels),
        "rules": sha256_file(rules.path),
        "contract": contract.sha256, "slot_w": slot_w, "ignore_index": ignore_index,
        "kd": [kd_tau, kd_lambda] if spec["enabled"] else None})

    opt = torch.optim.AdamW(model.parameters(), lr=lr,
                            weight_decay=float(cfg.get("encoder.weight_decay", 0.01)))
    steps_per_epoch = max(1, math.ceil(len(feats) / batch_size))
    # The FULL length of the configured run — the yardstick for "is this run
    # partial?", independent of the --max-steps cap applied to total_steps.
    full_steps = steps_per_epoch * epochs
    total_steps = (max_steps or full_steps)
    sched = get_linear_schedule_with_warmup(opt, int(0.1 * total_steps), total_steps)

    out_dir.mkdir(parents=True, exist_ok=True)
    state_path = out_dir / "state.pt"
    start_step, start_epoch = 0, 0
    if state_path.exists() and not args.fresh:
        st = load_state(state_path, map_location="cpu")
        drift = resume_mismatch(st, cfg_hash, data_hash)
        if drift:
            print(f"[guard] REFUSED: {drift} — resume would silently continue another "
                  "run; use --fresh to start over")
            return EXIT_GUARD
        model.load_state_dict(st["model"])
        opt.load_state_dict(st["opt"])
        if st.get("sched"):
            sched.load_state_dict(st["sched"])
        start_step, start_epoch = int(st["step"]), int(st["epoch"])
        torch.set_rng_state(st["torch_rng"])
        random.setstate(st["python_rng"])
        print(f"[resume] step={start_step} epoch={start_epoch}")
        append_event(out_dir, {"utc": utc_now(), "event": "resume", "step": start_step})
    else:
        random.seed(seed)
        torch.manual_seed(seed)
        append_event(out_dir, {"utc": utc_now(), "event": "start",
                               "config_hash": cfg_hash[:12],
                               "data_hash_prefix": data_hash[:12], "smoke": args.smoke})
    write_json(out_dir / "run_config.json",
               {"config_hash": cfg_hash, "data_hash": data_hash, "device": device,
                "params": n_params, "revision": str(resolved_rev)[:8] or None,
                "pinned_prefix": pin, "smoke": args.smoke,
                "distillation": spec, "rules_sha256": sha256_file(rules.path),
                "contract": {"path": str(contract.path), "sha256": contract.sha256,
                             "schema": contract.schema,
                             "source_task": contract.source_task}})

    pad_id = tok.pad_token_id if tok.pad_token_id is not None else 1
    intents = list(contract.intent_labels)          # canonical logit order
    label_of = contract.intent_index()
    # Deterministic sampler per epoch: the same seed+epoch gives the same order,
    # so a resume reproduces the step it continues from.
    sampler = torch.utils.data.RandomSampler(
        feats, generator=torch.Generator().manual_seed(seed + start_epoch))
    loader = DataLoader(feats, batch_size=batch_size, sampler=sampler,
                        collate_fn=lambda b: collate(b, pad_id, label_of))
    # A resume that already reached the --max-steps cap must not run a further
    # step just because the loop starts: collapse the epoch range instead.
    if max_steps and start_step >= max_steps:
        print(f"[resume] step {start_step} is already at --max-steps {max_steps}: "
              "no training needed — re-checkpointing the resumed state")
        epochs = start_epoch
    # Losses exactly as the contract states: class-weighted intent CE +
    # lambda_slot * masked slot CE (+ optional tau^2 * KL for stage 2).
    ce_intent = torch.nn.CrossEntropyLoss(
        weight=intent_loss_weights(contract, intents, cfg).to(device))
    ce_slot = torch.nn.CrossEntropyLoss(ignore_index=ignore_index)
    model.train()
    step, t0 = start_step, time.time()
    done = False
    # `resume_epoch` is the epoch a continuation must restart from (the epoch
    # the loop is currently inside). The final checkpoint must save THIS, not
    # `epochs` — saving the terminal epoch made a resume start past the end of
    # the run and silently do nothing (observed on the server smoke run).
    resume_epoch = start_epoch
    for epoch in range(start_epoch, epochs):
        resume_epoch = epoch
        if epoch != start_epoch:
            sampler.generator = torch.Generator().manual_seed(seed + epoch)
        skip = max(0, step - epoch * steps_per_epoch)
        for bi, batch in enumerate(loader):
            if bi < skip:      # mid-epoch resume: replay-free skip (same order)
                continue
            out = model(batch["input_ids"].to(device), batch["attention_mask"].to(device))
            intent_logits, slot_logits = out
            gold = batch["intent_labels"].to(device)
            loss = intent_w * ce_intent(intent_logits, gold)
            loss = loss + slot_w * ce_slot(slot_logits.permute(0, 2, 1),
                                           batch["tags"].to(device))
            if spec["enabled"]:
                # Contract target construction: p[gold] = row confidence, rest uniform.
                teacher_probs = [soft_targets(c if c is not None else 1.0, int(y),
                                              len(intents))
                                 for c, y in zip(batch.get("confidence", []),
                                                 gold.tolist())] or None
                if teacher_probs:
                    loss = loss + kd_lambda * distill_loss(intent_logits, teacher_probs,
                                                           kd_tau)
            if not torch.isfinite(loss):
                print(f"[stage] FAILED: non-finite loss at step {step}")
                return EXIT_STAGE
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), grad_clip)
            opt.step()
            sched.step()
            opt.zero_grad(set_to_none=True)
            step += 1
            if step % 10 == 0:
                print(f"[step] {step}/{total_steps} epoch={epoch} loss={loss.item():.4f} "
                      f"({time.time() - t0:.0f}s)")
            if step % save_steps == 0:
                _checkpoint(model, tok, opt, sched, out_dir, state_path, step, epoch,
                            cfg_hash, data_hash, seed, rules, cfg, base_repo, max_len,
                            data_hashes={"train": sha256_file(train_path),
                                         "valid": sha256_file(valid_path)},
                            smoke=args.smoke, contract=contract)
                append_event(out_dir, {"utc": utc_now(), "event": "checkpoint", "step": step})
            if max_steps and step >= max_steps:
                done = True
                break
        if done:
            break
    # Resumability: a run stopped early by --max-steps is a PARTIAL run and must
    # leave state.pt behind (the server smoke run proved the opposite was true —
    # a capped run left no state, so nothing could continue). A run that finished
    # all epochs has nothing to resume and deliberately leaves no state file: a
    # stale state.pt would only invite an accidental continuation.
    partial = bool(done) and step < full_steps
    if partial:
        save_state(state_path, model, opt, sched, step, epoch, cfg_hash, data_hash, seed)
        print(f"[state] partial run (max-steps {max_steps}) — resume with the same "
              f"command; state -> {state_path}")

    valid_metrics = evaluate(model, tok, valid_rows, vfeats, rules, device, batch_size)
    print(f"[valid] {json.dumps(valid_metrics, sort_keys=True)}")
    data_hashes = {"train": sha256_file(train_path), "valid": sha256_file(valid_path),
                   "build_report": sha256_file(report_path) if Path(report_path).exists() else None}
    calib = None
    calib_path = out_dir / "calibration.json"
    if calib_path.exists():
        calib = read_json(calib_path)
    # `final=True` skips the state write, so only a COMPLETE run passes it; a
    # --max-steps-capped run keeps its state.pt (written just above) resumable.
    _checkpoint(model, tok, opt, sched, out_dir, state_path, step, resume_epoch,
                cfg_hash, data_hash, seed, rules, cfg, base_repo, max_len, data_hashes,
                smoke=args.smoke, contract=contract, calib=calib, final=not partial)

    manifest = {
        "schema": "encoder-run-manifest/v1",
        "created_utc": utc_now(),
        "smoke": bool(args.smoke),
        "task": "T-036",
        "status": "smoke-run" if args.smoke else "trained",
        "publishable": False,
        "publishable_reason": "smoke run (wiring only)" if args.smoke else
                              "calibration and ship gates are applied by "
                              "run_encoder_pipeline.py (T-038 harness owns the gates)",
        "device": device,
        "steps": step,
        "model": {"base": base_repo, "params": n_params,
                  "revision_resolved_prefix": str(resolved_rev)[:8] or None,
                  "revision_pinned_prefix": pin,
                  "revision_verified": bool(resolved_rev) and str(resolved_rev).startswith(pin),
                  "intents": sorted(rules.labels), "tags": list(rules.bio_tags)},
        "data": {"train": str(train_path), "valid": str(valid_path),
                 **{k: v for k, v in data_hashes.items()},
                 "train_rows": len(train_rows), "valid_rows": len(valid_rows),
                 "rows_by_action": label_histogram(train_rows, "action"),
                 "rows_by_register": label_histogram(train_rows, "register"),
                 "rows_by_source_family": {k: v for k, v in
                                           label_histogram(train_rows, "source").items()},
                 "span_bearing_rows": span_histogram(train_rows, rules),
                 "leak_rows": 0,
                 "refused_rows": dict(sorted((k, v) for k, v in counters.items() if v))},
        "config": {"sha256": sha256_file(Path(args.config)),
                   "config_hash_prefix": cfg_hash[:12],
                   "rules_sha256": sha256_file(rules.path),
                   "rules_schema": "annotation-rules/v1"},
        "contract": {"path": str(contract.path), "sha256": contract.sha256,
                     "schema": contract.schema, "task": contract.source_task,
                     "branch": contract.source_branch,
                     "intent_order_is_logit_order": True,
                     "meta_required_keys": list(contract.meta_required_keys),
                     "student_size_target_params": list(contract.student_size_target_params),
                     "lambda_slot": contract.lambda_slot,
                     "emergency_class_weight": contract.intent_weights["emergency"]},
        "distillation": {"enabled": bool(spec["enabled"]), "spec": spec,
                         "status": "active" if spec["enabled"] else "skipped",
                         "reason": None if spec["enabled"] else spec["reason"]},
        "artifact": {"version": cfg.get("encoder.artifact.version"),
                     "version_status": "unset (release step must set it; the "
                                       "contract names no artifact version)"
                     if cfg.get("encoder.artifact.version") is None else "set",
                     "meta_required_keys_present": True},
        "checkpoint": {"dir": str(out_dir / "artifact"),
                       "model_pt_sha256_prefix": _sha_prefix(out_dir / "artifact" / "model.pt")},
        "valid_metrics": valid_metrics,
        "calibration": calib or {"status": "uncalibrated"},
        "consent": {"real_user_rows": 0,
                    "note": "T-036 trains on teacher + consented-export ground truth; "
                            "consent-export ingestion is T-035/ops-gated and not "
                            "implemented here (no real user rows in this manifest)"},
        "pii": {"utterance_content_logged": False, "manifest_schema": "counts+hashes only"},
        "gpu": {k: v for k, v in gpu.items() if k != "processes"},
    }
    write_json(out_dir / "manifest.json", manifest)
    append_event(out_dir, {"utc": utc_now(), "event": "finish", "step": step,
                           "manifest": "manifest.json"})
    print(f"[done] steps={step} valid_intent_acc={valid_metrics['intent_accuracy']} "
          f"slot_f1={valid_metrics['slot_f1']}")
    print(f"[done] manifest -> {out_dir / 'manifest.json'}")
    print(f"[done] artifact -> {out_dir / 'artifact'} (sha prefix "
          f"{_sha_prefix(out_dir / 'artifact' / 'model.pt')})")
    return EXIT_OK


def _golden_keys_safe() -> set:
    from pipeline_guards import golden_keys
    return golden_keys()


def _sha_prefix(path: Path, n: int = 12) -> str | None:
    return sha256_file(path)[:n] if Path(path).exists() else None


def _checkpoint(model, tok, opt, sched, out_dir, state_path, step, epoch, cfg_hash,
                data_hash, seed, rules, cfg, base_repo, max_len, data_hashes, smoke,
                contract, calib=None, final=False):
    from bakeoff_encoder import save_model  # heavy import, checkpoint time only

    meta = make_meta(rules, cfg, base_repo, max_len, step, data_hashes, smoke, calib,
                     contract=contract)
    save_model(model, tok, out_dir / "artifact", meta)
    stamp_artifact_meta(out_dir / "artifact")
    if not final:
        save_state(state_path, model, opt, sched, step, epoch, cfg_hash, data_hash, seed)
    print(f"[ckpt] step={step} -> {out_dir / 'artifact'}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        sys.exit(EXIT_GUARD)
