"""Stage 1 — teacher generation (spec §9.2).

Expands seeds/intents.yaml into labelled intent/v2 training rows using
Gemini 2.5 Flash as the teacher. Two job families:

  - core intents: paraphrase each filled seed template, label it
  - EDGE CLASSES (spec §9.1/§9.3 — abstention is a feature):
      abstain_low_confidence : ambiguous/fragmentary → conf < 0.5
      gibberish_to_none      : STT-noise strings → action none, conf < 0.3
      corrections_overrides  : no-with-amendment → call + requestedApp

Resumable at CALL level: completed (job, register) pairs are recorded in
data/.gen_teacher_state.json after every successful call, so killing and
re-running does NOT re-call (or duplicate — paraphrases differ at
temperature 0.8, which makes row-level dedupe alone insufficient).
Row ids are additionally deduped on write as belt-and-braces.

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

STATE_PATH = Path(__file__).parent.parent / "data" / ".gen_teacher_state.json"


def row_id(utterance: str, action: str, register: str) -> str:
    h = hashlib.sha256(f"{register}|{action}|{utterance}".encode()).hexdigest()
    return h[:16]


def load_existing_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    with open(path, encoding="utf-8") as f:
        return {json.loads(line)["id"] for line in f if line.strip()}


def load_call_state() -> set[str]:
    if not STATE_PATH.exists():
        return set()
    try:
        return set(json.loads(STATE_PATH.read_text(encoding="utf-8"))["done_calls"])
    except Exception:  # noqa: BLE001 — a corrupt state file must not lose data; just re-call
        return set()


def save_call_state(done_calls: set[str]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps({"done_calls": sorted(done_calls)}), encoding="utf-8")
    tmp.replace(STATE_PATH)


# MARK: - Job construction

def rows_per_job(cfg: dict, registers: list[str]) -> int:
    return int(cfg["gemini.variants_per_seed"]) * len(registers)


def count_existing(out_path: Path) -> tuple[dict[str, int], dict[str, int]]:
    """Rows already written, per action (core) and per edge class
    (matched on the source prefix written by this script)."""
    per_action: dict[str, int] = {}
    per_edge: dict[str, int] = {}
    if out_path.exists():
        for line in open(out_path, encoding="utf-8"):
            if not line.strip():
                continue
            row = json.loads(line)
            per_action[row["action"]] = per_action.get(row["action"], 0) + 1
            source = row.get("source") or ""
            for prefix in ("abstain_low_confidence", "gibberish_to_none",
                           "corrections_overrides"):
                if f":{prefix}:" in source:
                    per_edge[prefix] = per_edge.get(prefix, 0) + 1
    return per_action, per_edge


def fill_templates(seeds: dict, cfg: dict, registers: list[str],
                   already: dict[str, int], only: set[str] | None = None) -> list[dict]:
    """Target-driven: ceil((target - already_have) / rows_per_job) jobs per
    intent. Static (slot-less) templates CYCLE — paraphrase diversity comes
    from temperature, so the same template is a fresh job each time."""
    banks = seeds["entity_banks"]
    per_job = rows_per_job(cfg, registers)
    jobs = []
    rnd = random.Random(42)
    for intent, spec in seeds["intents"].items():
        if only and intent not in only:
            continue
        filled = []
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
            needed_slots = [s for s in slots if "{" + s + "}" in template]
            combos = itertools.product(*(slots[s] for s in needed_slots)) if needed_slots else [()]
            for combo in combos:
                utterance = template
                for slot_name, value in zip(needed_slots, combo):
                    utterance = utterance.replace("{" + slot_name + "}", value)
                filled.append(utterance)
        rnd.shuffle(filled)
        shortfall = max(0, int(spec["target"]) - already.get(intent, 0))
        needed = -(-shortfall // per_job) if filled else 0  # ceil
        for i in range(needed):
            jobs.append({"intent": intent,
                         "template_utterance": filled[i % len(filled)],
                         "edge_class": None})
    rnd.shuffle(jobs)
    return jobs


def fill_edge_templates(seeds: dict, cfg: dict, registers: list[str],
                        already_edge: dict[str, int]) -> list[dict]:
    """Edge-class jobs (spec §9.3), same target-driven logic. Gibberish
    has no templates — the teacher creates the noise from scratch."""
    edges = seeds.get("edge_classes", {})
    per_job = rows_per_job(cfg, registers)
    jobs = []
    rnd = random.Random(43)
    for name, spec in edges.items():
        templates = spec.get("templates") or ["(create from scratch)"]
        shortfall = max(0, int(spec["target"]) - already_edge.get(name, 0))
        needed = -(-shortfall // per_job)  # ceil
        for i in range(needed):
            jobs.append({"intent": "none",
                         "template_utterance": templates[i % len(templates)],
                         "edge_class": name})
    rnd.shuffle(jobs)
    return jobs


# MARK: - Prompts

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

EDGE_PROMPTS = {
    "abstain_low_confidence": """You are generating ABSTENTION training data for an
on-device Nepali intent parser for an elderly person's voice assistant.
The model must learn to say "not sure" — an overconfident small model is
worse than no model. For the ambiguous utterance below, produce {n}
variants an elderly Nepali speaker might actually say — fragmented,
self-interrupting, trailing off, or genuinely ambiguous between two
intents — in the "{register}" register.

Seed utterance: {utterance}

Output ONLY a JSON array, one object per variant:
[{{"utterance": "...", "action": "none", "entryId": null,
   "contact": null, "time": null, "medication": null, "message": null,
   "callType": null, "requestedApp": null, "topic": null, "steps": null,
   "confidence": number between 0.1 and 0.4,
   "reply": "a short gentle re-prompt in the user's language, e.g. asking
them to say it again"}}]

Rules: action is ALWAYS "none"; confidence is ALWAYS below 0.4 (these
utterances must not cross the 0.7 dispatch threshold); reply asks for
clarification, never guesses.""",

    "gibberish_to_none": """You are generating GIBBERISH training data for an
on-device Nepali intent parser. Speech-to-text on a noisy room sometimes
decodes TV audio, background chatter, coughs, fans, or silence as broken
text. Produce {n} strings that look like such broken Nepali/English STT
output — repetition loops ("राम राम राम राम"), random fragments, cut-off
words, mixed-script noise, single particles — in the "{register}"
register's script.

Output ONLY a JSON array:
[{{"utterance": "...", "action": "none", "entryId": null,
   "contact": null, "time": null, "medication": null, "message": null,
   "callType": null, "requestedApp": null, "topic": null, "steps": null,
   "confidence": number between 0.0 and 0.2,
   "reply": "short polite 'I didn't understand' in the user's language"}}]

Rules: action is ALWAYS "none"; confidence ALWAYS below 0.2; the strings
must NOT contain a recognizable command.""",

    "corrections_overrides": """You are generating CORRECTION training data for an
on-device Nepali intent parser. When the assistant asks "माइयालाई
फेसटाइममा फोन गर्ने?" (call maiya on FaceTime?), the user may answer
with a METHOD AMENDMENT, not a plain no: "होइन, फोन नै गर" (no, plain
phone). For the seed correction below, produce {n} variants in the
"{register}" register — including negation-first and bare-amendment
forms ("फेसटाइममा गर" alone).

Seed correction: {utterance}

Output ONLY a JSON array:
[{{"utterance": "...", "action": "call", "entryId": null,
   "contact": null, "time": null, "medication": null, "message": null,
   "callType": "video"|null, "requestedApp": "whatsapp"|"facetime"|"phone"|null,
   "topic": null, "steps": null,
   "confidence": number between 0.8 and 0.95,
   "reply": "short acknowledgment of the corrected method in the user's
language"}}]

Rules: action is ALWAYS "call"; requestedApp mirrors the method the
variant names ("वाट्सएप"→"whatsapp", "फेसटाइम"→"facetime",
"फोन/कल"→"phone", "भिडियो"→"facetime" with callType "video"); the
amended method must appear verbatim in the utterance.""",
}


def edge_ok(row: dict, job: dict) -> bool:
    """Class-rule enforcement — the teacher's label discipline is
    imperfect; rows violating their edge class's rule are rejected
    rather than clamped (a clamped-but-wrong label teaches false
    calibration, spec §9.3)."""
    ec = job.get("edge_class")
    if not ec:
        return True
    conf = float(row.get("confidence", 1))
    if ec == "abstain_low_confidence":
        return row.get("action") == "none" and conf < 0.5
    if ec == "gibberish_to_none":
        return row.get("action") == "none" and conf < 0.3
    if ec == "corrections_overrides":
        return row.get("action") == "call" and bool(row.get("requestedApp"))
    return True


def call_teacher(prompt: str, cfg: dict) -> list[dict]:
    """One Gemini call via the current google-genai SDK (pip install
    google-genai — the legacy google-generativeai package is EOL).
    Imported lazily so the script loads without the SDK."""
    from google import genai
    from google.genai import types

    if not hasattr(call_teacher, "_client"):
        call_teacher._client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    resp = call_teacher._client.models.generate_content(
        model=str(cfg["gemini.model"]),
        contents=prompt,
        config=types.GenerateContentConfig(
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
    parser.add_argument("--limit", type=int, default=0, help="debug: stop after N jobs")
    parser.add_argument("--edge-only", action="store_true",
                        help="generate only edge-class jobs (core already done)")
    parser.add_argument("--only-intents", type=str, default="",
                        help="comma-separated core intents to top up (default: all)")
    args, cfg = load_config(parser)

    out_path = Path(__file__).parent.parent / "data" / "teacher.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(Path(__file__).parent.parent / "seeds" / "intents.yaml", encoding="utf-8") as f:
        seeds = yaml.safe_load(f)

    per_action, per_edge = count_existing(out_path)
    only = {s.strip() for s in args.only_intents.split(",") if s.strip()} or None
    core_jobs = [] if args.edge_only else fill_templates(
        seeds, cfg, args.registers, per_action, only)
    edge_jobs = fill_edge_templates(seeds, cfg, args.registers, per_edge)
    jobs = core_jobs + edge_jobs
    if args.limit:
        jobs = jobs[: args.limit]
    done = load_existing_ids(out_path)
    done_calls = load_call_state()
    print(f"[gen_teacher] {len(jobs)} jobs, {len(done)} rows written, "
          f"{len(done_calls)} calls already done")

    written = rejected = 0
    state_dirty = 0
    with open(out_path, "a", encoding="utf-8") as out:
        for i, job in enumerate(jobs):
            for register in args.registers:
                call_key = f"{i}:{register}:{job['template_utterance'][:40]}"
                if call_key in done_calls:
                    continue
                edge = job.get("edge_class")
                prompt_template = EDGE_PROMPTS[edge] if edge else PROMPT
                prompt = (prompt_template
                          .replace("{n}", str(cfg["gemini.variants_per_seed"]))
                          .replace("{intent}", job["intent"])
                          .replace("{utterance}", job["template_utterance"])
                          .replace("{register}", register))
                try:
                    rows = call_teacher(prompt, cfg)
                except Exception as e:  # noqa: BLE001 — transient API failures must not lose progress
                    print(f"[gen_teacher] job {i}/{register} failed: {e} — continuing")
                    time.sleep(5)
                    continue
                done_calls.add(call_key)
                state_dirty += 1
                if state_dirty >= 20:
                    save_call_state(done_calls)
                    state_dirty = 0
                for row in rows:
                    if any(f not in row for f in SCHEMA_FIELDS):
                        rejected += 1
                        continue
                    if not edge_ok(row, job):
                        rejected += 1
                        continue
                    rid = row_id(row.get("utterance", ""), row.get("action", ""), register)
                    if rid in done:
                        continue
                    row["id"] = rid
                    row["source"] = f"teacher:{register}" if not edge else f"teacher:{edge}:{register}"
                    row["register"] = register
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    done.add(rid)
                    written += 1
                out.flush()
                time.sleep(60.0 / float(cfg["gemini.requests_per_minute"]))
            if (i + 1) % 25 == 0:
                save_call_state(done_calls)
                print(f"[gen_teacher] {i + 1}/{len(jobs)} jobs, "
                      f"{written} rows written, {rejected} rejected")
    save_call_state(done_calls)
    print(f"[gen_teacher] done: {written} new rows, {rejected} rejected → {out_path}")


if __name__ == "__main__":
    main()
