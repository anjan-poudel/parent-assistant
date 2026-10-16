#!/usr/bin/env python
"""T-183 (CNR v17) Phase B — candidate replies over the held-out chat set.

Produces the {"id","reply"} JSONL that the full ship gate consumes as
--chat-outputs: one decode per held-out chat turn over the EXPORTED
candidate GGUF, app-faithful by construction.

App fidelity (why these exact knobs):
  * prompt = seeds/chat_prompt_template.txt rendered with the turn's
    user_turn as {transcript}. IntentPrompt.buildChat sends exactly the
    single utterance ("User said: ..."); InterpreterContext supplies only
    the language hint and address clause — the app has no conversation-
    history slot, so fixture `context` turns are deliberately NOT fed
    (the app cannot send them; the model was trained the same way).
  * language_hint="ne", address_as_clause="" (fresh-install default,
    chat_prompt.DEFAULT_ADDRESS_AS_CLAUSE).
  * decode under the chatJSONSchema GBNF (src/chat_grammar.py, sha
    recorded), max_tokens=256, temperature=0.0, stop tokens
    <|im_end|>/<|endoftext|> — the same decode chat_probe executes.
  * reply = the parsed JSON's "reply" recorded AS-IS: the harness
    measures the candidate's replies, not the app's low-confidence
    substitution path (no floor logic here, by design).

Output schema is strictly {"id","reply"} (eval_chat_gates.load_outputs
refuses unknown fields, empty replies and id-set mismatches). A turn
whose decode yields no parseable reply falls back to the stripped raw
text; an EMPTY reply aborts the run (never fabricate a reply). A sidecar
eval/chat-outputs-<tag>.meta.json records the recipe, identity shas and
counts.

Usage from tools/train-intent (box):
  .venv/bin/python v17-trainer/gen_chat_golden_outputs.py \
      --model-path models/intent-ne-qwen-s43-chat-v17-q4_k_m.gguf \
      --out eval/chat-outputs-qwen-s43-chat-v17.jsonl \
      [--fixture eval/chat_golden.jsonl] [--limit N]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
sys.path.append(str(ROOT / "src"))
sys.path.append(str(Path(__file__).resolve().parent))  # v17-trainer/

from chat_prompt import (DEFAULT_ADDRESS_AS_CLAUSE, DEFAULT_LANGUAGE_HINT,
                         render_chat_prompt)               # noqa: E402

#: The chat extraction contract: the first complete JSON object in the
#: decode carrying the canonical string "intent" AND a non-empty string
#: "reply". This mirrors the stage-3 eval_golden contract (the version the
#: chat probe graded with: strict on the canonical "intent" key, legacy
#: shapes count as no-JSON). The v17 command-side `_first_complete_json`
#: cannot be imported here: it requires a command-shaped "action" field and
#: would read every chat decode as no-JSON.
_JSON_OBJECT = json.JSONDecoder()


def first_chat_json(text: str) -> dict | None:
    for m in re.finditer(r"\{", text):
        try:
            obj, _ = _JSON_OBJECT.raw_decode(text, m.start())
        except json.JSONDecodeError:
            continue
        if (isinstance(obj, dict) and isinstance(obj.get("intent"), str)
                and isinstance(obj.get("reply"), str)):
            return obj
    return None


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--fixture", default="eval/chat_golden.jsonl")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    import chat_grammar
    from llama_cpp import Llama

    fixture = Path(args.fixture)
    model_path = Path(args.model_path)
    out_path = Path(args.out)
    tag = args.tag or out_path.stem.replace("chat-outputs-", "")

    raw = fixture.read_text(encoding="utf-8").split("\n")
    records = [json.loads(line) for line in raw if line.strip()]
    turns = records[1:]
    if args.limit:
        turns = turns[:args.limit]

    template_path = ROOT / "seeds" / "chat_prompt_template.txt"
    template = template_path.read_text(encoding="utf-8")

    schema = chat_grammar.load_schema()
    grammar = chat_grammar.build_grammar(schema)
    fp = chat_grammar.fingerprint(schema)
    print(f"[geno] grammar=chatJSONSchema fingerprint={fp}")

    llm = Llama(model_path=str(model_path), n_ctx=2048, seed=20_260_907,
                logits_all=False, verbose=False)

    started = time.time()
    outputs = []
    no_json = 0
    fallback_raw = 0
    for i, turn in enumerate(turns, 1):
        prompt = render_chat_prompt(
            template, turn["user_turn"],
            language_hint=DEFAULT_LANGUAGE_HINT,
            address_as_clause=DEFAULT_ADDRESS_AS_CLAUSE)
        out = llm(prompt, max_tokens=256, temperature=0.0, grammar=grammar,
                  stop=["<|im_end|>", "<|endoftext|>"])
        text = out["choices"][0]["text"]
        parsed = first_chat_json(text)
        reply = ""
        if isinstance(parsed, dict) and isinstance(parsed.get("reply"), str):
            reply = parsed["reply"].strip()
        if not reply:
            no_json += 1
            if text.strip():
                reply = text.strip()
                fallback_raw += 1
        if not reply:
            raise SystemExit(
                f"[geno] turn {turn['id']} produced an EMPTY reply — "
                "aborting (a missing reply would read as a pass; never "
                "fabricate one)")
        outputs.append({"id": turn["id"], "reply": reply})
        if i % 25 == 0 or i == len(turns):
            print(f"[geno] {i}/{len(turns)}  no_json={no_json} "
                  f"raw_fallback={fallback_raw}  ({time.time()-started:.0f}s)")

    ids = [o["id"] for o in outputs]
    assert len(ids) == len(set(ids)), "duplicate ids"
    out_path.write_text(
        "".join(json.dumps(o, ensure_ascii=False) + "\n" for o in outputs),
        encoding="utf-8")

    meta = {
        "schema": "cnr_chat_outputs_meta/v1",
        "tag": tag,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "fixture": {"path": str(fixture), "sha256": sha256_file(fixture),
                    "turns_used": len(outputs)},
        "model": {"path": str(model_path), "sha256": sha256_file(model_path)},
        "prompt": {"template": str(template_path),
                   "sha256": sha256_file(template_path),
                   "language_hint": DEFAULT_LANGUAGE_HINT,
                   "address_as_clause": DEFAULT_ADDRESS_AS_CLAUSE,
                   "context_turns_fed": False,
                   "context_note": (
                       "fixture `context` turns are NOT fed to the decode: "
                       "IntentPrompt.buildChat has no history slot (it sends "
                       "the single utterance); the app cannot send context "
                       "and the model was not trained with it")},
        "extraction": "first complete JSON object carrying canonical string "
                      "\"intent\" + non-empty string \"reply\" (stage-3 "
                      "eval_golden contract)",
        "decode": {"grammar": "chatJSONSchema", "fingerprint": fp,
                   "max_tokens": 256, "temperature": 0.0,
                   "stop": ["<|im_end|>", "<|endoftext|>"],
                   "n_ctx": 2048, "seed": 20_260_907},
        "counts": {"turns": len(outputs), "no_json": no_json,
                   "raw_fallback": fallback_raw},
        "wall_s": round(time.time() - started, 1),
        "chat_grammar_sha256": sha256_file(ROOT / "src" / "chat_grammar.py"),
    }
    meta_path = out_path.with_name(out_path.stem + ".meta.json")
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8")
    print(f"[geno] wrote {out_path} ({len(outputs)} turns)")
    print(f"[geno] wrote {meta_path}")


if __name__ == "__main__":
    main()
