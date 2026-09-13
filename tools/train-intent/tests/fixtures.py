"""Synthetic source rows for the T-036 encoder pipeline tests + smoke run.

These are seed-derived, hand-written rows (no real user data, NFR-016). They are
LLM-format source rows (the encoder builder derives spans from the slot strings),
covering every guard the builder implements:

  clean teacher rows (all four registers) / noised rows / edge families /
  ack refusal marker / non-alignable slot / resolved value / out-of-band edge
  confidence / conflicting labels / duplicate noised row / non-canonical
  whitespace / missing id / `intent` schema alias.

The utterances are deliberately chosen to be OUTSIDE the golden corpus's
normalized (matra-stripped) skeleton — the leak guard is conservative by design
and a fixture that collided would silently lose its rows. A test pins
`leak == 0` for this fixture and exercises the leak refusal with a row built
from the corpus itself.

`write_fixture()` is deterministic; a test re-generates the committed JSONL and
asserts byte equality, so the fixture can never silently drift from this file.
"""
from __future__ import annotations

import json
from pathlib import Path

FIXTURE_PATH = Path(__file__).resolve().parent / "data" / "encoder_rows_sample.jsonl"

BASE = {
    "entryId": None, "contact": None, "time": None, "medication": None,
    "message": None, "callType": None, "requestedApp": None, "topic": None,
    "steps": None, "confidence": 0.9, "reply": "ठीक छ",
}


def row(rid: str, utterance: str, action: str, register: str, source: str,
        **slots) -> dict:
    r = dict(BASE)
    r.update({"id": rid, "utterance": utterance, "action": action,
              "register": register, "source": source})
    r.update(slots)
    return r


ROWS: list[dict] = [
    # --- clean teacher rows: devanagari -----------------------------------
    row("fx-call-dev", "हरिलाई फोन गर", "call", "devanagari",
        "teacher:devanagari", contact="हरि", requestedApp="फोन", confidence=0.92),
    row("fx-call-dev-app", "गीतालाई वाट्सएपमा कल गर", "call", "devanagari",
        "teacher:devanagari", contact="गीता", requestedApp="whatsapp",
        confidence=0.9),
    row("fx-reminder-dev", "भोलि बिहान नौ बजे डाक्टरलाई फोन गर्न सम्झाइदिनु",
        "set_reminder", "devanagari", "teacher:devanagari",
        time="भोलि बिहान नौ बजे", contact="डाक्टरलाई", confidence=0.9),
    row("fx-reminder-med", "बेलुका ७ बजे औषधि खान सम्झाउनु", "set_reminder",
        "devanagari", "teacher:devanagari", time="बेलुका ७ बजे",
        medication="औषधि", confidence=0.9),
    row("fx-emergency-dev", "मद्दत गर्नुहोस्, छाती धेरै दुख्यो", "emergency",
        "devanagari", "teacher:devanagari", confidence=0.95),
    row("fx-message-dev", "कृष्णलाई आज भेट्नुहोस् भनेर मेसेज पठाउ", "send_message",
        "devanagari", "teacher:devanagari", contact="कृष्णलाई",
        message="आज भेट्नुहोस्", confidence=0.9),
    row("fx-guide-dev", "माइक्रोवेभमा खाना कसरी तताउने", "guide", "devanagari",
        "teacher:devanagari", topic="माइक्रोवेभमा", confidence=0.9),
    row("fx-ack-dev", "बिहानको औषधि खाएँ", "ack_med", "devanagari",
        "teacher:devanagari", medication="औषधि", confidence=0.9),
    row("fx-ack-refusal-none", "दवाई खाइनँ", "none", "devanagari",
        "teacher:devanagari", confidence=0.6),
    row("fx-query-dev", "पोखराको मौसम कस्तो हुन्छ", "query", "devanagari",
        "teacher:devanagari", confidence=0.8),
    row("fx-none-dev", "अनि", "none", "devanagari", "teacher:devanagari",
        confidence=0.2),
    # --- clean teacher rows: romanized / code-switched / elder ------------
    row("fx-call-rom", "saraswati lai phone gara", "call", "romanized",
        "teacher:romanized", contact="saraswati", requestedApp="phone",
        confidence=0.92),
    row("fx-call-cs", "krishna lai WhatsApp ma call gara", "call", "code_switched",
        "teacher:code_switched", contact="krishna", requestedApp="whatsapp",
        confidence=0.88),
    row("fx-reminder-rom", "bholi bihana nau baje doctor lai phone garna samjhaidinu",
        "set_reminder", "romanized", "teacher:romanized", time="bholi bihana nau baje",
        contact="doctor", confidence=0.9),
    row("fx-elder-frag", "मलाई... छोरा... फोन...", "none", "elder_fragmented",
        "teacher:elder_fragmented", confidence=0.35),
    # --- correction (teacher edge family, app span from resolved app) -----
    row("fx-correction", "होइन, फोन नै गर", "call", "devanagari",
        "teacher:corrections_overrides:devanagari", requestedApp="phone",
        confidence=0.9),
    # --- edge families ----------------------------------------------------
    row("fx-abstain-edge", "फोन... अहँ... के भन्ने भनेको थिएँ", "none",
        "devanagari", "teacher:abstain_low_confidence:devanagari", confidence=0.35),
    row("fx-abstain-ec", "ऊ... त्यो... के भनें...", "none", "devanagari",
        "edge_cases:abstain_low_confidence", confidence=0.3),
    row("fx-gibberish-edge", "राम राम राम राम राम", "none", "devanagari",
        "teacher:gibberish_to_none:devanagari", confidence=0.15),
    # --- refused rows (each must increment exactly one named counter) -----
    row("fx-non-alignable", "हरिलाई फोन गर", "call", "devanagari",
        "teacher:devanagari", contact="गीता", requestedApp="फोन", confidence=0.9),
    row("fx-resolved-phone", "9841234567 लाई फोन गर", "call", "devanagari",
        "teacher:devanagari", contact="9841234567", requestedApp="फोन",
        confidence=0.9),
    row("fx-ack-refusal-marker", "दवाई खाइनँ", "ack_med", "devanagari",
        "teacher:devanagari", medication="दवाई", confidence=0.9),
    row("fx-abstain-out-of-band", "के भनेको थियो", "none", "devanagari",
        "teacher:abstain_low_confidence:devanagari", confidence=0.45),
    row("fx-gibberish-out-of-band", "हो हो हो", "none", "devanagari",
        "teacher:gibberish_to_none:devanagari", confidence=0.25),
    row("fx-whitespace", "हरि  लाई फोन गर", "call", "devanagari",
        "teacher:devanagari", contact="हरि", requestedApp="फोन", confidence=0.9),
    # --- noised rows: re-annotated on the noisy transcript ---------------
    row("fx-call-dev:noise0", "हरिलाई फोन गर", "call", "devanagari",
        "stt_noise:devanagari", contact="हरि", requestedApp="फोन", confidence=0.92),
    row("fx-call-rom:noise0", "saraswati lai fon gara", "call", "romanized",
        "stt_noise:romanized", contact="saraswati", requestedApp="phone",
        confidence=0.92),
    row("fx-reminder-dev:noise0", "बिहान 8 बजे डाक्टरलई औषधि खान सम्झाउनु",
        "set_reminder", "devanagari", "stt_noise:devanagari",
        time="बिहान ८ बजे", contact="डाक्टरलाई", medication="औषधि",
        confidence=0.9),
    row("fx-emergency-dev:noise0", "मदत गर्नुस छाती दुख्यो", "emergency",
        "devanagari", "stt_noise:devanagari", contact="हरि", confidence=0.95),
    row("fx-message-dev:noise0", "कृष्णलाई आज भेट्नुहोस भनेर मेसेज पठाउ",
        "send_message", "devanagari", "stt_noise:devanagari",
        contact="कृष्णलाई", message="आज भेट्नुहोस्", confidence=0.9),
    row("fx-reminder-drop-trigger:noise0", "के भनेको थियो", "set_reminder",
        "devanagari", "stt_noise:devanagari", time="बिहान ८ बजे",
        medication="औषधि", confidence=0.9),
    row("fx-dup-clean:noise0", "हरिलाई फोन गर", "call", "devanagari",
        "stt_noise:devanagari", contact="हरि", requestedApp="फोन", confidence=0.92),
    # --- conflicting labels on the same text (both dropped) ---------------
    row("fx-conflict-a", "लौ", "none", "devanagari", "teacher:devanagari",
        confidence=0.2),
    row("fx-conflict-b", "लौ", "query", "devanagari", "teacher:devanagari",
        confidence=0.8),
    # --- clean rows that keep the mixture fed -----------------------------
    row("fx-music-dev", "गायत्री मन्त्र बजाउ", "music", "devanagari",
        "teacher:devanagari", confidence=0.85),
    row("fx-health-dev", "दबाब कति हुँदा ठीक हुन्छ", "health_query", "devanagari",
        "teacher:devanagari", confidence=0.8),
    row("fx-call-ef", "छोरा... फोन... गर न त", "call", "elder_fragmented",
        "teacher:elder_fragmented", contact="छोरा", requestedApp="फोन", confidence=0.7),
    row("fx-guide-cs", "microwave ma chiya kasari tataune", "guide", "code_switched",
        "teacher:code_switched", topic="microwave", confidence=0.85),
]

# Row with the `intent` key instead of `action` (schema alias accepted by the
# builder with a counter) — appended separately because `row()` adds `action`.
ALIAS_ROW = {
    "id": "fx-alias-intent", "utterance": "गीतालाई फोन गर", "intent": "call",
    "register": "devanagari", "source": "teacher:devanagari",
    "contact": "गीता", "requestedApp": "फोन", "confidence": 0.9,
}

# Row with no id in a separate source — the builder refuses it (schema_id).
NO_ID_ROW = {
    "utterance": "सरस्वतीलाई फोन गर", "action": "call", "register": "devanagari",
    "source": "teacher:devanagari", "contact": "सरस्वती", "requestedApp": "फोन",
    "confidence": 0.9,
}


def all_rows() -> list[dict]:
    return list(ROWS) + [ALIAS_ROW, NO_ID_ROW]


def write_fixture(path: Path = FIXTURE_PATH) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in all_rows():
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return path


if __name__ == "__main__":
    print(write_fixture())
