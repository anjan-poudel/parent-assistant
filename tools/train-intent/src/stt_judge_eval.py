"""4B-judge eval over the REAL error stream, two modes.

Mode choice: the sentence + candidate readings (the pool the generator
produces) — measures the shipped multiple-choice judge on instances
whose true word IS reachable.

Mode propose: the sentence with the misheard word marked, no readings —
the model PROPOSES the intended word. This is the mode the measured
edit-distance distribution demands: most real corrections are 3-8 edits
from the noisy form (and some are script drift), so bounded-edit
generation can never supply the true candidate. The proposal's
acceptance rule is measured too: exact match with the clean token, and
the lexicon-hit rate (a proposal the corpus lexicon does not know is
refused).

CPU-only (llama_cpp wheel has no CUDA; the eval is 200 samples).
Run from tools/train-intent/:

    ./.venv/bin/python3 src/stt_judge_eval.py --pairs data/noised.jsonl \
        --ngram-bank build/calib/stt-ngram-prior-v2.json \
        --pair-bank build/calib/canonical-stt-reductions.json \
        --phonetic build/calib/phonetic-key.json \
        --model models/intent-ne-qwen4b-slotcanon-s43-q4_k_m.gguf \
        --mode propose --samples 200 --seed 42
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import stt_calibrate_bands as C  # noqa: E402
from pipeline_guards import EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402

MAX_READINGS = 3

CHOICE_GBNF = r"""
root   ::= "{" ws "\"picks\"" ws ":" ws "[" ws "{" ws "\"pick\"" ws ":" ws pick ws "," ws "\"confidence\"" ws ":" ws number ws "}" ws "]" ws "}"
pick   ::= "0" | "1" | "2"
number ::= ("0" | "1") ("." [0-9]+)?
ws     ::= [ \t\n]*
"""

PROPOSE_GBNF = r"""
root ::= "{" ws "\"word\"" ws ":" ws "\"" string "\"" ws "}"
string ::= ([^"\\] | "\\" .)*
ws ::= [ \t\n]*
"""


def choice_prompt(source: str, surface: str, readings: list) -> str:
    numbered = " ".join(f"{i}) {r}" for i, r in enumerate(readings))
    return (
        "तलको वाक्यमा एउटा शब्द गलत सुनिएको हुन सक्छ। प्रत्येक विकल्पमा, "
        "वाक्यको अर्थसँग सबैभन्दा मिल्ने पढाइ छान्नुहोस्।\n"
        f"वाक्य: {source}\n"
        f"विकल्प 1 — सुनिएको: {surface} पढाइहरू: {numbered}\n"
        "हरेक विकल्पको लागि pick मा पढाइको नम्बर र confidence मा "
        "० देखि १ सम्मको विश्वास देऊ।")


def propose_prompt(source: str, surface: str) -> str:
    return (
        "तलको वाक्यमा एउटा शब्द गलत सुनिएको छ। वाक्यको अर्थ हेरेर, "
        "त्यो ठाउँमा कुन शब्द हुनुपर्ने हो भन्ने सोचेर, त्यो शब्द मात्र "
        "देऊ। गलत सुनिएको शब्दलाई जस्ताको तस्तै नदोहोर्‍याऊ।\n"
        "उदाहरण 1: वाक्य «मलाई कसबी देऊ», सुनिएको «कसबी» → "
        '{"word": "remote"}\n'
        "उदाहरण 2: वाक्य «आज औधी खानुहोस्», सुनिएको «औधी» → "
        '{"word": "औषधि"}\n'
        f"वाक्य: {source}, सुनिएको: {surface} →\n"
        '{"word": "')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairs", type=Path, required=True)
    parser.add_argument("--ngram-bank", type=Path, required=True)
    parser.add_argument("--pair-bank", type=Path, required=True)
    parser.add_argument("--phonetic", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--mode", choices=["choice", "propose"],
                        default="propose")
    parser.add_argument("--samples", type=int, default=200)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    try:
        from llama_cpp import Llama, LlamaGrammar
    except ImportError:
        print("llama_cpp required — run under tools/train-intent/.venv",
              file=sys.stderr)
        return EXIT_USAGE

    bank = C.load_ngram_bank(args.ngram_bank)
    pair_lex = C.load_pair_bank(args.pair_bank)
    phonetic = C.load_phonetic(args.phonetic)
    indexes = C.build_indexes(pair_lex, bank, phonetic)
    instances = C.error_instances(args.pairs, limit=None)

    pool_cache: dict = {}
    eval_rows = []
    for token, clean_token, neighbours, sentence, row_id in instances:
        if token not in pool_cache:
            pool_cache[token] = C.candidates_indexed(token, indexes,
                                                     phonetic)
        pool = pool_cache[token]
        if args.mode == "choice" and clean_token not in pool:
            continue
        eval_rows.append((token, clean_token, pool, sentence, row_id))
    rng = random.Random(args.seed)
    rng.shuffle(eval_rows)
    sample = eval_rows[: args.samples]
    print(f"[judge-eval] mode {args.mode}: {len(eval_rows)} eligible, "
          f"sampling {len(sample)}", file=sys.stderr)

    llm = Llama(model_path=str(args.model), n_ctx=1024, n_threads=8,
                verbose=False)
    grammar = LlamaGrammar.from_string(
        CHOICE_GBNF if args.mode == "choice" else PROPOSE_GBNF,
        verbose=False)

    exact = 0
    lexicon_hit = 0
    total = 0
    pick_field = re.compile(r"\"pick\"\s*:\s*([0-9]+)")
    word_field = re.compile(r"\"word\"\s*:\s*\"([^\"]+)\"")
    for token, clean_token, pool, sentence, row_id in sample:
        source = sentence
        if args.mode == "choice":
            distractors = [c for c in pool if c != clean_token]
            readings = [clean_token] + distractors[: MAX_READINGS - 1]
            if len(readings) < 2:
                continue
            prompt = choice_prompt(source, token, readings)
        else:
            prompt = propose_prompt(source, token)
        output = llm(prompt, max_tokens=40, temperature=0.0,
                     grammar=grammar)
        text = output["choices"][0]["text"]
        total += 1
        if args.mode == "choice":
            match = pick_field.search(text)
            if match:
                pick = int(match.group(1))
                if 0 <= pick < len(readings) and readings[pick] == clean_token:
                    exact += 1
        else:
            match = word_field.search(text)
            if match:
                proposed = C.core(match.group(1))
                if proposed == clean_token:
                    exact += 1
                if proposed in bank["ordinal"]:
                    lexicon_hit += 1
        if total % 25 == 0:
            print(f"[judge-eval] {total}/{len(sample)} exact "
                  f"{exact / total:.3f}", file=sys.stderr)
    if args.mode == "propose":
        print(f"[judge-eval] propose exact {exact}/{total} = "
              f"{exact / total:.3f}; lexicon-hit "
              f"{lexicon_hit / total:.3f}")
    else:
        print(f"[judge-eval] choice exact {exact}/{total} = "
              f"{exact / total:.3f}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
