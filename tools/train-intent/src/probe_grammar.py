"""[EVAL-FIDELITY] What the app's grammar does to a checkpoint's output.

Read-only diagnostic for the phase-1 corrected-table work: runs N golden
rows through the SAME grammar-constrained gguf path the gate uses and
prints BOTH the raw decoded text (so the invented app-only keys are
visible) and the parsed object (so the slot damage is visible). No
results.csv row, no gates — this is the microscope behind the table.

Usage:
  .venv/bin/python src/probe_grammar.py models/<x>.gguf gc-call-001 gc-reminder-001
  .venv/bin/python src/probe_grammar.py models/<x>.gguf --all
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from command_grammar import build_grammar, fingerprint, load_schema  # noqa: E402
from eval_golden import GGUF_MAX_TOKENS, _first_complete_json, _repeat_penalty, _stop_strings  # noqa: E402
from intent_prompt import render_prompt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
APP_ONLY = ("actionType", "actionUrl", "pluginAction", "pluginEntities")


def main() -> None:
    model_path, ids = sys.argv[1], sys.argv[2:]
    corpus = {}
    for line in open(ROOT / "eval" / "golden_corpus.jsonl", encoding="utf-8"):
        if line.strip():
            row = json.loads(line)
            corpus[row["id"]] = row
    if not ids or ids == ["--all"]:
        ids = list(corpus)

    from llama_cpp import Llama
    llm = Llama(model_path=model_path, n_ctx=4096, verbose=False)
    template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
    grammar = build_grammar(load_schema())
    print(f"[probe] {model_path}\n[probe] grammar=commandJSONSchema "
          f"{fingerprint()} | {len(ids)} rows\n")

    for row_id in ids:
        row = corpus[row_id]
        prompt = render_prompt(template, row["utterance"])
        out = llm(prompt, max_tokens=GGUF_MAX_TOKENS, temperature=0.0,
                  repeat_penalty=_repeat_penalty(model_path),
                  stop=_stop_strings(model_path), grammar=grammar)
        text = out["choices"][0]["text"].strip()
        obj = _first_complete_json(text) or {}
        invented = {k: obj.get(k) for k in APP_ONLY}
        print(f"{row_id:20s} gold={row['intent']:14s} pred={obj.get('intent')!r} "
              f"gold_slots={json.dumps(row.get('slots'), ensure_ascii=False)}")
        print(f"  raw : {text[:260]}")
        print(f"  slots-> contact={obj.get('contact')!r} time={obj.get('time')!r} "
              f"| app-only keys: {json.dumps(invented, ensure_ascii=False)}")
        print()


if __name__ == "__main__":
    main()
