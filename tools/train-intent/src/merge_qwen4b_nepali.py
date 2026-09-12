"""Merge sidskarki/qwen3-4b-nepali: base + resize + SFT adapter + CPT embeddings."""
from __future__ import annotations
import os, torch
from huggingface_hub import snapshot_download
from peft import PeftModel
from safetensors.torch import load_file
from transformers import AutoModelForCausalLM, AutoTokenizer

SRC = "/home/anjan/qwen3-4b-nepali-src"
OUT = "/mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent/checkpoints/qwen3-4b-nepali-merged"

snapshot_download("sidskarki/qwen3-4b-nepali", local_dir=SRC)

tokenizer = AutoTokenizer.from_pretrained(os.path.join(SRC, "sft-adapter"), trust_remote_code=True)
tokenizer.pad_token = tokenizer.eos_token

model = AutoModelForCausalLM.from_pretrained(
    "Qwen/Qwen3-4B", torch_dtype=torch.bfloat16, trust_remote_code=True)

base_vocab = model.get_input_embeddings().weight.shape[0]  # 151936
model.resize_token_embeddings(len(tokenizer))              # 166925
model = PeftModel.from_pretrained(model, os.path.join(SRC, "sft-adapter"))
model = model.merge_and_unload()

# Restore CPT-trained embeddings for the extended tokens
cpt = load_file(os.path.join(SRC, "cpt-checkpoint", "adapter_model.safetensors"))
emb_key = "base_model.model.model.embed_tokens.modules_to_save.default.weight"
if emb_key not in cpt:
    # try alternate key forms
    cands = [k for k in cpt if "embed_tokens" in k]
    print("candidate embed keys:", cands)
    emb_key = cands[0]
new_emb = cpt[emb_key]
model.get_input_embeddings().weight.data[base_vocab:] = new_emb[base_vocab:].to(
    model.get_input_embeddings().weight.dtype)
if not model.config.tie_word_embeddings:
    model.get_output_embeddings().weight.data[base_vocab:] = new_emb[base_vocab:].to(
        model.get_output_embeddings().weight.dtype)

os.makedirs(OUT, exist_ok=True)
model.save_pretrained(OUT, max_shard_size="5GB")
tokenizer.save_pretrained(OUT)
print("merged saved to", OUT)
