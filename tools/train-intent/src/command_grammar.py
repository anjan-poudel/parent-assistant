"""[EVAL-FIDELITY] The app's decode grammar, mirrored into the GGUF eval.

The on-device interpreter decodes under
`LlamaGrammar.commandJSONSchema` (ios/ElderlyAssistant/Services/Voice/
LlamaCommandInterpreter.swift): `LLMCore.generateWithConstraints(from:
jsonSchema:)` converts that JSON Schema to a llama.cpp GBNF grammar and
chains the sampler through it, so malformed JSON is STRUCTURALLY
IMPOSSIBLE at decode time. The GGUF eval backend sampled UNCONSTRAINED,
which is what let qwen4b-s42 emit `"confidence": .9` (JSON-invalid — the
app cannot produce it) and scored 5/20 golden rows as no-JSON (README
"Gate-fidelity caveat": single-seed deltas dominated by no-JSON rows are
eval artifacts, not model quality).

This module carries the SAME schema into the eval backend, so the gate
measures what the app would actually decode:

    seeds/command_schema.json   checked-in extraction of the Swift
                                literal, produced byte-for-byte by
                                extract_schema() below (same discipline
                                as seeds/prompt_template.txt)
    extract_schema(text)        pull the literal out of the Swift source
    load_schema()               the checked-in schema; when the Swift
                                source is reachable the two are compared
                                and a DRIFTED app grammar raises instead
                                of silently grading a stale schema
    build_grammar(schema)       schema -> llama_cpp.LlamaGrammar, i.e.
                                llama.cpp's own json-schema-to-GBNF
                                converter (the same one the app links)
    gbnf_text(schema)           the GBNF string itself (logs/tests)

Source of truth: commandJSONSchema in
ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift
(commit 2b72a2fb "wire the on-device interpretation contract through
the interpreter", 2026-09-12). Set INTENT_SWIFT_PATH to point the drift
check at a different checkout.

NOTE the key-ORDER difference this mirror exposes (recorded here, not
"fixed"): training labels are written in train_qlora.LABEL_FIELDS order
(intent, entryId, contact, time, medication, message, callType,
requestedApp, topic, steps, confidence, response) while the grammar
forces the SCHEMA's order (intent, response, confidence, actionType,
actionUrl, entryId, ...). Every production decode — and now every gated
eval — has the model emit `response` second and invent the four keys
training never taught. See the Phase-1 report.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
SCHEMA_PATH = ROOT / "seeds" / "command_schema.json"

# Repo checkout root (tools/train-intent/ -> tools/ -> repo root), where
# the Swift source of truth lives. Overridable for other checkouts.
SWIFT_SOURCE = "ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift"
SWIFT_PATH = Path(os.environ.get("INTENT_SWIFT_PATH")
                  or ROOT.parent.parent / SWIFT_SOURCE)

# Swift multiline-string literal: `static let commandJSONSchema: String = """`
# ... `"""`. Group 2 is the closing delimiter's indentation, which is the
# margin Swift strips from every line before the literal reaches the
# runtime (captured rather than assumed, so re-indenting the Swift file
# cannot silently change the schema).
_LITERAL_RE = re.compile(
    r'static\s+let\s+commandJSONSchema\s*:\s*String\s*=\s*"""\n(.*?)\n([ \t]*)"""',
    re.S)


_WARNED_NO_LITERAL = False


def extract_schema(swift_text: str) -> dict:
    """The schema dict from LlamaGrammar.commandJSONSchema's Swift literal."""
    m = _LITERAL_RE.search(swift_text)
    if not m:
        raise ValueError(
            "commandJSONSchema literal not found in the Swift source — the "
            "app grammar moved or was renamed; update this extractor in the "
            "SAME change as seeds/command_schema.json")
    body, margin = m.group(1), m.group(2)
    lines = [line[len(margin):] if line.startswith(margin) else line.lstrip()
             for line in body.split("\n")]
    return json.loads("\n".join(lines))


def load_schema(check_drift: bool = True) -> dict:
    """The checked-in app schema, drift-checked against the Swift source.

    A reachable checkout that DOES carry the literal is authoritative: if
    it differs from seeds/command_schema.json this raises — grading
    against a drifted grammar would quietly re-open the gate-fidelity
    hole this module exists to close.

    A checkout that does NOT carry the literal (the training box's iOS
    tree is a 2026-09-02 snapshot, older than the 2026-09-07 grammar
    wiring) is a checkout-age fact, not app drift, so it warns loudly
    instead of failing every eval; INTENT_SCHEMA_STRICT=1 makes it fatal
    for a CI box that is supposed to have the current checkout.
    """
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    if not (check_drift and SWIFT_PATH.exists()):
        return schema
    swift_text = SWIFT_PATH.read_text(encoding="utf-8")
    try:
        swift = extract_schema(swift_text)
    except ValueError as exc:
        if os.environ.get("INTENT_SCHEMA_STRICT"):
            raise
        global _WARNED_NO_LITERAL
        if not _WARNED_NO_LITERAL:  # once per process — see docstring
            _WARNED_NO_LITERAL = True
            print(f"[command_grammar] WARNING: {SWIFT_PATH} carries no "
                  "commandJSONSchema literal (pre-2026-09-07 checkout?) — "
                  f"grading the checked-in schema {fingerprint(schema)} "
                  "unverified against Swift. Set INTENT_SCHEMA_STRICT=1 to "
                  f"make this fatal. ({exc})", file=sys.stderr)
        return schema
    if swift != schema:
        raise ValueError(
            f"seeds/command_schema.json has DRIFTED from {SWIFT_PATH}: "
            "re-extract it (extract_schema) in the same change as the "
            "Swift grammar, or the eval grades a grammar the app no "
            "longer uses")
    return schema


def schema_json(schema: dict | None = None) -> str:
    """Canonical compact text handed to the GBNF converter."""
    return json.dumps(schema or load_schema(), ensure_ascii=False,
                      separators=(",", ":"))


def fingerprint(schema: dict | None = None) -> str:
    """Stable id for the schema actually in force (logged per eval run)."""
    import hashlib
    return hashlib.sha256(schema_json(schema).encode("utf-8")).hexdigest()[:16]


def gbnf_text(schema: dict | None = None) -> str:
    """The GBNF grammar llama.cpp derives from the schema — llama_cpp's
    converter is the same llama.cpp code the app's runtime links
    (`json_schema_to_grammar`), so this text is the app's decode grammar."""
    from llama_cpp.llama_grammar import json_schema_to_gbnf
    return json_schema_to_gbnf(schema_json(schema))


def build_grammar(schema: dict | None = None):
    """A LlamaGrammar for `grammar=` on llama_cpp's generate call."""
    from llama_cpp import LlamaGrammar
    return LlamaGrammar.from_json_schema(schema_json(schema))
