"""Stage 6 — export a trained intent checkpoint to a Q4_K_M GGUF artifact.

Turns a LoRA adapter checkpoint into the single-file artifact the bake-off
gates and the app run against:

  1. merge the LoRA adapter into its base model (HF space, CPU only)  →
     checkpoints/<tag>-merged/                       (skip-if-exists)
  2. convert the merged HF dir to f16 GGUF via llama.cpp's
     convert_hf_to_gguf.py                           → *.f16.gguf
  3. quantize f16 → Q4_K_M via llama-quantize         → models/intent-ne-<tag>-q4_k_m.gguf
  4. sha256 sidecar (<file>.sha256) matching ModelStore's checksum policy

Design: docs/export-gguf-plan.md. Conventions mirror tools/train/src/
export_ggml.py: skip-if-output-exists, resumable, sha256 sidecar, no
partial artifacts (write .tmp then rename), delete the f16 intermediate
on success.

CPU-only by design: CUDA_VISIBLE_DEVICES is cleared unconditionally so no
stray .to("cuda") can ever grab the GPU out from under a training leg
(export may run while the other bake-off arm is still training).

Usage (from tools/train-intent/):
    .venv/bin/python src/export_gguf.py --model checkpoints/qwen-final --tag qwen
    # --model: the trainer's <tag>-final dir (adapter_config.json + adapter
    #          weights + tokenizer), or an already-merged HF model dir
    #          (config.json + model weights) — in which case merge is skipped.
    # --tag:   artifact tag, defaults to the model dir name minus "-final".
    # --base:  BASE_TAGS key of the base model to merge into (default: the
    #          tag itself). --base-id overrides with a raw HF id.

Idempotent: re-running after an interruption resumes from the last
completed step; a run whose final .gguf exists is a no-op.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# CPU-only guarantee — must happen before any torch import (torch is only
# imported lazily inside merge_adapter below).
os.environ["CUDA_VISIBLE_DEVICES"] = ""

ROOT = Path(__file__).resolve().parent.parent

# config has no heavy imports; train_qlora's module level is import-safe
# (heavy deps load only inside its main()). BASE_TAGS is the single source
# of truth for tag -> base model id.
from config import load_config  # noqa: E402
from train_qlora import BASE_TAGS  # noqa: E402

DEFAULT_LLAMA_CPP_DIR = "~/llama.cpp"

# Trainer/peft artifacts that must NOT be copied from the adapter dir into
# the merged dir (tokenizer + tokenizer_config etc. are carried over).
_EXCLUDED = {
    "adapter_config.json", "config.json", "optimizer.pt", "optimizer.bin",
    "scheduler.pt", "trainer_state.json", "rng_state.pth",
}
_EXCLUDED_PREFIXES = ("adapter_model", "pytorch_model", "model-",
                      "model.safetensors", "checkpoint-")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def llama_cpp_paths(cfg: dict) -> tuple[Path, Path, Path, str]:
    """Resolve the llama.cpp checkout, converter script and quantize bin.

    Order: LLAMA_CPP_DIR env > config export.llama_cpp_dir > ~/llama.cpp.
    Returns (dir, convert_script, quantize_bin, git_sha_or_unknown).
    """
    env_dir = os.environ.get("LLAMA_CPP_DIR")
    dir_ = Path(env_dir) if env_dir else (
        Path(str(cfg["export.llama_cpp_dir"]))
        if cfg.get("export.llama_cpp_dir") else Path(DEFAULT_LLAMA_CPP_DIR))
    dir_ = Path(os.path.expanduser(str(dir_)))
    if not (dir_ / "convert_hf_to_gguf.py").exists():
        print(f"llama.cpp not found at {dir_} — set LLAMA_CPP_DIR or "
              "export.llama_cpp_dir in config.yaml, then clone + CPU-build it:")
        print("  git clone --depth 1 https://github.com/ggml-org/llama.cpp ~/llama.cpp")
        print("  cmake -B ~/llama.cpp/build -DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release && "
              "cmake --build ~/llama.cpp/build -j8")
        raise SystemExit(1)
    convert = dir_ / "convert_hf_to_gguf.py"
    quantize = dir_ / "build" / "bin" / "llama-quantize"
    if not quantize.exists():
        quantize = dir_ / "bin" / "llama-quantize"
    if not quantize.exists():
        print(f"llama-quantize not built at {quantize.parent} — run the cmake "
              "build above (CPU-only: -DGGML_CUDA=OFF)")
        raise SystemExit(1)
    sha = "unknown"
    try:
        out = subprocess.run(["git", "-C", str(dir_), "rev-parse", "HEAD"],
                             capture_output=True, text=True, check=True)
        sha = out.stdout.strip()
    except Exception:
        pass
    return dir_, convert, quantize, sha


def merge_adapter(model_dir: Path, merged_dir: Path, base_id: str) -> Path:
    """Merge the adapter in model_dir into base_id → merged_dir (fp16 HF
    dir). Skips when merged_dir already holds weights (resumable)."""
    has_weights = (merged_dir / "config.json").exists() and (
        list(merged_dir.glob("*.safetensors")) or (merged_dir / "pytorch_model.bin").exists())
    if has_weights:
        print(f"[export] {merged_dir} exists — skipping merge")
        return merged_dir

    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    print(f"[export] merge: {base_id} + {model_dir}")
    model = AutoModelForCausalLM.from_pretrained(
        base_id, torch_dtype=torch.float32, low_cpu_mem_usage=True,
        attn_implementation="eager")
    model = PeftModel.from_pretrained(model, str(model_dir), is_trainable=False)
    merged = model.merge_and_unload()
    # fp16 is the dtype the f16 GGUF will carry; casting here halves the
    # merged dir and skips a redundant cast inside the converter.
    merged.to(torch.float16)

    tmp = Path(str(merged_dir) + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    merged.save_pretrained(str(tmp), safe_serialization=True)
    # Carry the training tokenizer (pad token etc.) into the merged dir —
    # the tokenizer files saved into <tag>-final by the trainer are the ones
    # training used; the base's would differ.
    for f in model_dir.iterdir():
        if (f.is_file() and f.name not in _EXCLUDED
                and not f.name.startswith(_EXCLUDED_PREFIXES)):
            shutil.copy2(f, tmp / f.name)
    tmp.rename(merged_dir)
    print(f"[export] merged → {merged_dir}")
    return merged_dir


def strip_oob_added_tokens(model_dir: Path) -> None:
    """Drop tokenizer added tokens whose id >= vocab_size from a merged HF
    dir before GGUF conversion (bake-off round 3, 2026-09-09).

    llama.cpp's convert_hf_to_gguf asserts max(tokenizer.vocab.values()) <
    vocab_size; transformers v5 loads tokenizer.json added_tokens into
    .vocab, so gemma-3's multimodal placeholder <image_soft_token> (id
    262144, one past a 262144 vocab) trips the assert. v5 re-injects the
    token on every load from tokenizer_config.json's multimodal keys
    (image_token / boi_token / eoi_token / model_specific_special_tokens),
    so those are dropped too. None of these tokens appear in text-only
    intent I/O or have embedding rows, so stripping is safe and makes the
    exported vocab 0..vocab_size-1. Idempotent: re-running on an
    already-stripped dir is a no-op.
    """
    tj_path = model_dir / "tokenizer.json"
    tcf_path = model_dir / "tokenizer_config.json"
    cfg_path = model_dir / "config.json"
    if not (tj_path.exists() and cfg_path.exists()):
        return
    import json
    with open(cfg_path, encoding="utf-8") as f:
        vocab_size = int(json.load(f).get("vocab_size") or 0)
    if not vocab_size:
        return
    with open(tj_path, encoding="utf-8") as f:
        tj = json.load(f)
    added = tj.get("added_tokens") or []
    kept = [t for t in added if int(t.get("id", 0)) < vocab_size]
    dropped = [t for t in added if int(t.get("id", 0)) >= vocab_size]
    if dropped:
        for t in dropped:
            print(f"[export] drop tokenizer added token {t.get('content')!r} "
                  f"(id {t.get('id')} >= vocab_size {vocab_size})")
        tj["added_tokens"] = kept
        tmp = Path(str(tj_path) + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(tj, f, ensure_ascii=False)
        tmp.replace(tj_path)
    if tcf_path.exists():
        with open(tcf_path, encoding="utf-8") as f:
            tcf = json.load(f)
        multimodal = {"image_token", "boi_token", "eoi_token",
                      "model_specific_special_tokens"}
        present = [k for k in multimodal if tcf.get(k) not in (None, {})]
        if present:
            for k in present:
                tcf.pop(k, None)
                print(f"[export] drop tokenizer_config multimodal key {k!r}")
            tmp = Path(str(tcf_path) + ".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(tcf, f, ensure_ascii=False)
            tmp.replace(tcf_path)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Merge LoRA adapter → base and export Q4_K_M GGUF (CPU only)")
    parser.add_argument("--model", type=str, required=True,
                        help="checkpoint dir: <tag>-final (adapter) or merged HF dir")
    parser.add_argument("--tag", type=str, default="",
                        help="artifact tag (default: model dir name minus -final)")
    parser.add_argument("--base", type=str, default="",
                        help="BASE_TAGS key of the base to merge into (default: tag)")
    parser.add_argument("--base-id", type=str, default="",
                        help="raw HF base id override (e.g. Qwen/Qwen3-1.7B)")
    args, cfg = load_config(parser)

    model_dir = Path(args.model).resolve()
    tag = args.tag or model_dir.name
    if tag.endswith("-final"):
        tag = tag[: -len("-final")]
    adapter_present = (model_dir / "adapter_config.json").exists()
    if adapter_present:
        base_id = args.base_id or BASE_TAGS.get(args.base or tag)
        if not base_id:
            print(f"no base model known for tag {args.base or tag!r} — known: "
                  f"{sorted(BASE_TAGS)}; pass --base or --base-id")
            raise SystemExit(1)
    else:
        base_id = ""
        if not (model_dir / "config.json").exists():
            print(f"{model_dir}: neither adapter_config.json nor config.json — "
                  "not a trainable checkpoint?")
            raise SystemExit(1)

    quant = str(cfg.get("export.quant", "Q4_K_M"))
    out_dir = ROOT / str(cfg.get("export.out_dir", "models"))
    out_dir.mkdir(parents=True, exist_ok=True)
    gguf_out = out_dir / f"intent-ne-{tag}-q4_k_m.gguf"
    f16_path = out_dir / f"intent-ne-{tag}.f16.gguf"

    if gguf_out.exists():
        if not Path(str(gguf_out) + ".sha256").exists():
            Path(str(gguf_out) + ".sha256").write_text(
                f"{sha256(gguf_out)}  {gguf_out.name}\n", encoding="utf-8")
        print(f"{gguf_out} exists — skipping")
        return

    dir_, convert, quantize, llama_sha = llama_cpp_paths(cfg)

    if adapter_present:
        merged_dir = ROOT / "checkpoints" / f"{tag}-merged"
        merge_src = merge_adapter(model_dir, merged_dir, base_id)
    else:
        merge_src = model_dir  # already-merged full model dir
        print(f"[export] no adapter in {model_dir} — using it as the merged model")
    strip_oob_added_tokens(merge_src)

    # --- convert HF -> f16 GGUF ---
    if f16_path.exists():
        print(f"[export] {f16_path} exists — reusing f16 intermediate")
    else:
        print(f"[export] convert {merge_src} → f16 GGUF")
        env = dict(os.environ)
        py_path = [str(Path(convert).parent), str(Path(convert).parent / "gguf-py")]
        # Converter deps that must not be pip-installed into the (possibly
        # live, GPU-owning) train-intent venv live in a neutral --target dir
        # instead (see config export.convert_deps_dir).
        deps = Path(os.path.expanduser(
            str(cfg.get("export.convert_deps_dir", "~/.llama-convert-deps"))))
        if deps.exists():
            py_path.insert(0, str(deps))
        if env.get("PYTHONPATH"):
            py_path.append(env["PYTHONPATH"])
        env["PYTHONPATH"] = os.pathsep.join(py_path)
        subprocess.run([sys.executable, str(convert),
                        "--outfile", str(f16_path), "--outtype", "f16",
                        str(merge_src)],
                       check=True, env=env)
        if not f16_path.exists():
            print("convert finished but produced no file — aborting")
            raise SystemExit(1)

    # --- quantize Q4_K_M (write .tmp then rename: no partial artifact) ---
    tmp_out = Path(str(gguf_out) + ".tmp")
    if tmp_out.exists():
        tmp_out.unlink()
    print(f"[export] quantize → {quant}")
    subprocess.run([str(quantize), str(f16_path), str(tmp_out), quant], check=True)
    tmp_out.rename(gguf_out)
    if f16_path.exists():
        f16_path.unlink()

    sidecar = Path(str(gguf_out) + ".sha256")
    sidecar.write_text(f"{sha256(gguf_out)}  {gguf_out.name}\n", encoding="utf-8")

    # --- record the run next to eval/results.csv (plan §8: reproducibility) ---
    hist = ROOT / "eval" / "export_history.tsv"
    new = not hist.exists()
    with open(hist, "a", encoding="utf-8") as f:
        if new:
            f.write("ts\ttag\tbase_id\tartifact\tsize_bytes\tsha256\tllama_cpp_sha\n")
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{tag}\t{base_id or '-'}\t"
                f"{gguf_out.name}\t{gguf_out.stat().st_size}\t"
                f"{sha256(gguf_out)}\t{llama_sha}\n")

    print(f"exported: {gguf_out} ({gguf_out.stat().st_size} bytes)")
    print(f"sha256:   {sha256(gguf_out)}")
    print(f"llama.cpp SHA: {llama_sha} ({dir_})")
    print("next: .venv/bin/python src/eval_golden.py --backend gguf "
          f"--model-path {gguf_out} --label {tag}")


if __name__ == "__main__":
    main()
