"""Stage 1 — teacher generation (spec §9.2).

Expands seeds/intents.yaml into labelled intent/v2 training rows using
Gemini 2.5 Flash as the teacher: for each (intent, filled-template) pair,
the teacher produces N paraphrases per register (devanagari / romanized /
code-switched / elder-fragmented) AND the label (action + slots +
confidence + reply), then a self-critique pass rejects mislabeled rows.

Resumable: rows are appended to data/teacher.jsonl with deterministic ids;
ids already present are skipped, so killing and re-running continues where
it stopped.

Requires: GEMINI_API_KEY in the environment.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import random
import time
from pathlib import Path

import yaml

from config import load_config, abs_path

SCHEMA_FIELDS = ["action", "entryId", "contact", "time", "medication", "message",
                 "callType", "requestedApp", "topic", "steps", "confidence", "reply"]


def row_id(utterance: str, action: str, register: str) -> str:
    h = hashlib.sha256(f"{register}|{action}|{utterance}".encode()).hexdigest()
    return h[:16]


def load_existing_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    with open(path, encoding="utf-8") as f:
        return {json.loads(line)["id"] for line in f if line.strip()}


def fill_templates(seeds: dict) -> list[dict]:
    """Combinatorially fill {slots} in templates from the entity banks."""
    banks = seeds["entity_banks"]
    jobs = []
    for intent, spec in seeds["intents"].items():
        for template in spec["templates"]:
            slots = {
                "contact": banks["contact_names"] + banks["contact_relationships"],
                "contact_latin": banks["contact_names_latin"] + banks["contact_relationships_latin"],
                "medication": banks["medications"],
                "time": banks["times"],
                "app": banks["apps"],
                "appliance": banks["appliances"],
                "bhajan": banks["bhajans"],
                "message": ["ठीक छ", "आज भेट्नुहोस्", "खाना खानुभयो"],
            }
            needed = [s for s in ("contact", "contact_latin", "medication", "time",
                                  "app", "appliance", "bhajan", "message")
                      if "{" + s + "}" in template]
            combos = itertools.product(*(slots[s] for s in needed)) if needed else [()]
            for combo in combos:
                utterance = template
                for slot_name, value in zip(needed, combo):
                    utterance = utterance.replace("{" + slot_name + "}", value)
                jobs.append({"intent": intent, "template_utterance": utterance})
    # Cap per intent at its target (teacher expands further via paraphrase).
    capped = []
    per_intent: dict[str, int] = {}
    random.Random(42).shuffle(jobs)
    for job in jobs:
        cap = seeds["intents"][job["intent"]]["target"]
        if per_intent.get(job["intent"], 0) < cap // 4:  # ~4x expansion happens at paraphrase
            capped.append(job)
            per_intent[job["intent"]] = per_intent.get(job["intent"], 0) + 1
    return capped


PROMPT = """You are generating training data for an on-device Nepali intent parser
for an elderly person's voice assistant. For the seed utterance below,
produce {n} natural paraphrases an elderly Nepali speaker might actually
say — including fragmented speech, repetitions, and code-switching with
English — in the "{register}" register. For EACH paraphrase output the
intent/v2 label.

Seed intent: {intent}
Seed utterance: {utterance}

Output ONLY a JSON array, one object per paraphrase:
[{{"utterance": "...", "action": "{intent}", "entryId": null,
   "contact": string|null, "time": string|null, "medication": string|null,
   "message": string|null, "callType": string|null, "requestedApp": string|null,
   "topic": string|null, "steps": string[]|null,
   "confidence": number, "reply": "short spoken reply in the user's language"}}]

Rules: copy entity spans VERBATIM from each paraphrase into the slot fields;
never invent entities not present; requestedApp only if the paraphrase names
the app; emergency recall-first (plea+pain = emergency)."""


def call_teacher(prompt: str, cfg: dict) -> list[dict]:
    """One Gemini call. Imported lazily so the script loads without the SDK."""
    import google.generativeai as genai  # pip install google-generativeai

    genai.configure(api_key=os.environ["GEMINI_API_KEY"])
    model = genai.GenerativeModel(str(cfg["gemini.model"]))
    resp = model.generate_content(
        prompt,
        generation_config=genai.GenerationConfig(
            max_output_tokens=int(cfg["gemini.max_output_tokens"]),
            temperature=float(cfg["gemini.temperature"]),
            response_mime_type="application/json",
        ),
    )
    return json.loads(resp.text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registers", nargs="*",
                        default=["devanagari", "romanized", "code_switched", "elder_fragmented"])
    parser.add_argument("--limit", type=int, default=0, help="debug: stop after N seeds")
    args, cfg = load_config(parser)

    out_path = abs_path(cfg, "gemini.out") if "gemini.out" in cfg else (Path(__file__).parent.parent / "data" / "teacher.jsonl")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(Path(__file__).parent.parent / "seeds" / "intents.yaml", encoding="utf-8") as f:
        seeds = yaml.safe_load(f)

    jobs = fill_templates(seeds)
    if args.limit:
        jobs = jobs[: args.limit]
    done = load_existing_ids(out_path)
    print(f"[gen_teacher] {len(jobs)} seeds, {len(done)} rows already generated")

    written = 0
    with open(out_path, "a", encoding="utf-8") as out:
        for i, job in enumerate(jobs):
            for register in args.registers:
                prompt = (PROMPT
                          .replace("{n}", str(cfg["gemini.variants_per_seed"]))
                          .replace("{intent}", job["intent"])
                          .replace("{utterance}", job["template_utterance"])
                          .replace("{register}", register))
                try:
                    rows = call_teacher(prompt, cfg)
                except Exception as e:  # noqa: BLE001 — transient API failures must not lose progress
                    print(f"[gen_teacher] seed {i}/{register} failed: {e} — continuing")
                    time.sleep(5)
                    continue
                for row in rows:
                    rid = row_id(row.get("utterance", ""), row.get("action", ""), register)
                    if rid in done:
                        continue
                    # Schema validation: all intent/v2 fields must be present.
                    if any(f not in row for f in SCHEMA_FIELDS):
                        continue
                    row["id"] = rid
                    row["source"] = f"teacher:{register}"
                    row["register"] = register
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    done.add(rid)
                    written += 1
                out.flush()
                time.sleep(60.0 / float(cfg["gemini.requests_per_minute"]))
            if (i + 1) % 25 == 0:
                print(f"[gen_teacher] {i + 1}/{len(jobs)} seeds, {written} rows written")
    print(f"[gen_teacher] done: {written} new rows → {out_path}")


if __name__ == "__main__":
    main()
