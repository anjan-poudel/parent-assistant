"""[PROBE] Ask a checkpoint for the intent of each boundary golden row's
nearest corpus twins.

The golden set gives each boundary only 1-2 rows, so a 0/2 tells us little.
Every one of the arm's failing rows has near-verbatim corpus twins (0.79-0.92
similarity) that are labelled with the golden intent. If the model answers the
twin correctly, the failure is a knife-edge phrasing sensitivity; if it fails
the twin too, the boundary is genuinely unlearned.

CPU-only; read-only.
"""
import difflib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from command_grammar import build_grammar  # noqa: E402
from eval_golden import GGUF_MAX_TOKENS, GGUF_TEMPERATURE, _repeat_penalty, _stop_strings  # noqa: E402
from intent_prompt import render_prompt  # noqa: E402
from llama_cpp import Llama  # noqa: E402

ROOT = Path(__file__).resolve().parent
model_path, tag = sys.argv[1], sys.argv[2]
golden = {r["id"]: r for r in
          (json.loads(l) for l in open(ROOT / "eval" / "golden_corpus.jsonl", encoding="utf-8") if l.strip())}
corpus = [json.loads(l) for l in open(ROOT / "data" / "backup-pre-distill" / "train.jsonl", encoding="utf-8") if l.strip()]
TARGETS = ["gc-health-001", "gc-health-002", "gc-reminder-001", "gc-reminder-002",
           "gc-ack-002", "gc-none-001", "gc-query-001"]
template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
llm = Llama(model_path=model_path, n_ctx=4096, n_threads=8, n_threads_batch=8, verbose=False)
grammar = build_grammar()

hits = 0
total = 0
for rid in TARGETS:
    utt = golden[rid]["utterance"]
    gold = golden[rid]["intent"]
    twins = [r for r in corpus if abs(difflib.SequenceMatcher(None, r["utterance"], utt).ratio() - 1) < 99]
    twins = sorted(twins, key=lambda r: -difflib.SequenceMatcher(None, r["utterance"], utt).ratio())[:3]
    print("\n%s  gold=%s  %r" % (rid, gold, utt))
    for t in twins:
        ratio = difflib.SequenceMatcher(None, t["utterance"], utt).ratio()
        out = llm(render_prompt(template, t["utterance"]), max_tokens=GGUF_MAX_TOKENS,
                  temperature=GGUF_TEMPERATURE, repeat_penalty=_repeat_penalty(model_path),
                  stop=_stop_strings(model_path), grammar=grammar)
        try:
            pred = json.loads(out["choices"][0]["text"]).get("intent")
        except Exception:  # noqa: BLE001
            pred = "NO-JSON"
        ok = pred == t["intent"]
        hits += int(ok)
        total += 1
        print("   %.2f corpus=%-13s pred=%-14s %s  %r"
              % (ratio, t["intent"], pred, "ok" if ok else "MISS", t["utterance"][:46]))
print("\n[%s] %d/%d corpus twins answered with their own (golden-consistent) intent" % (tag, hits, total))
