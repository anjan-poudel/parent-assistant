"""Author the held-out eval fixtures (T-038).

Writes:
  eval/golden_corpus.jsonl        — the §9.1 held-out corpus (15-25 rows per
                                    schema-v2 action), span-annotated
  eval/emergency_nearmiss.jsonl   — adversarial emergency near-miss set:
                                    emergency paraphrases that MUST classify
                                    as emergency + calm pain/health questions
                                    that MUST NOT

The committed JSONL files are the artifacts; this script is the reproducible
authoring path. Span offsets are computed here (never hand-counted) and every
row is validated before writing, so the annotations cannot silently drift from
the utterances.

Run from tools/train-intent/:
    python3 eval/author_golden_corpus.py           # (re)write both files
    python3 eval/author_golden_corpus.py --check   # verify committed files match

Annotation conventions (T-034 annotation-rules/v1 — annotation_rules.yaml):
  - span labels: contact, time, medication, message, topic, app
  - offsets are Unicode code points, start inclusive / end exclusive, and
    utterance[start:end] == text
  - spans cover whole whitespace words: an affix merged into a word stays in
    the span ("माइयालाई" carries माइया + लाई); a case particle that is its own
    word is excluded
  - `app` is spanned when the utterance names a method/app that maps onto
    requestedApp/callType (फोन, भिडियो कल, वाट्सएपमा, फेसटाइममा); a bare generic
    "कल" carries no distinction and is not spanned
  - `slots` keep the resolver-ready surfaces the LLM harness already scores
    (they may be a sub-string of the span when the affix is merged, e.g.
    slots.contact "माइया" vs span "माइयालाई"); span->slot normalization for
    span-level scoring is T-035's follow-up (T-034 eval_note)
  - every row carries a script marker: devanagari | latin | code_switched

All utterances are synthetic (entity banks from seeds/intents.yaml); no PII.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VALID_ACTIONS = {"ack_med", "call", "emergency", "set_reminder", "health_query",
                 "music", "send_message", "guide", "create_calendar_event",
                 "suggest_video", "query", "none"}
SPAN_LABELS = {"contact", "time", "medication", "message", "topic", "app"}
SCRIPT_MARKERS = {"devanagari", "latin", "code_switched"}
NEARMISS_KINDS = {"emergency_paraphrase", "calm_pain_health"}
# Slot keys whose value is a spoken surface and therefore must appear verbatim
# in the utterance. requestedApp/callType are resolved values (whatsapp, video)
# and are not required to appear.
SURFACE_SLOT_KEYS = ("contact", "time", "medication", "message", "topic")


def _locate(utterance: str, text: str, occurrence: int = 0) -> tuple[int, int]:
    pos, seen = -1, -1
    while True:
        pos = utterance.find(text, pos + 1)
        if pos < 0:
            raise SystemExit(
                f"span text {text!r} not found in {utterance!r} (occurrence {occurrence})")
        seen += 1
        if seen == occurrence:
            return pos, pos + len(text)


def row(row_id: str, script: str, intent: str, utterance: str, slots: dict,
        spans: list[tuple], notes: str = "", kind: str | None = None) -> dict:
    """One fixture row; spans are (label, text[, occurrence]) tuples."""
    if intent not in VALID_ACTIONS:
        raise SystemExit(f"{row_id}: intent {intent!r} is not a schema-v2 action")
    if script not in SCRIPT_MARKERS:
        raise SystemExit(f"{row_id}: script {script!r} is not a script marker")
    if kind is not None and kind not in NEARMISS_KINDS:
        raise SystemExit(f"{row_id}: kind {kind!r} is not a near-miss kind")
    out = []
    for spec in spans:
        label, text = spec[0], spec[1]
        occurrence = spec[2] if len(spec) > 2 else 0
        if label not in SPAN_LABELS:
            raise SystemExit(f"{row_id}: span label {label!r} is not a T-034 label")
        start, end = _locate(utterance, text, occurrence)
        out.append({"label": label, "text": text, "start": start, "end": end})
    out.sort(key=lambda s: (s["start"], s["end"]))
    for (a, b) in zip(out, out[1:]):
        if b["start"] < a["end"]:
            raise SystemExit(f"{row_id}: overlapping spans {a} and {b}")
    for key in SURFACE_SLOT_KEYS:
        value = slots.get(key)
        if value and value not in utterance:
            raise SystemExit(
                f"{row_id}: slots.{key} {value!r} is not a substring of the utterance "
                "(resolver-ready values must be spoken surfaces)")
    rec = {"id": row_id, "utterance": utterance, "script": script,
           "intent": intent, "slots": slots, "spans": out}
    if kind:
        rec["kind"] = kind
    rec["notes"] = notes
    return rec


# ---------------------------------------------------------------------------
# eval/golden_corpus.jsonl — spec §9.1 coverage, 15-25 rows per action
# ---------------------------------------------------------------------------

CORPUS: list[dict] = []


def add(*args, **kwargs) -> None:
    CORPUS.append(row(*args, **kwargs))


# --- call (16): names + relationships, apps, video, corrections -------------
add("gc-call-001", "devanagari", "call", "माइयालाई फोन गर",
    {"contact": "माइया", "callType": None, "requestedApp": None},
    [("contact", "माइयालाई"), ("app", "फोन")],
    "canonical bare call — resolver chain picks the default method")
add("gc-call-002", "latin", "call", "maiya lai phone gara",
    {"contact": "maiya", "callType": None, "requestedApp": None},
    [("contact", "maiya"), ("app", "phone")], "romanized twin of gc-call-001")
add("gc-call-003", "devanagari", "call", "छोरालाई वाट्सएपमा कल गर",
    {"contact": "छोरा", "callType": None, "requestedApp": "whatsapp"},
    [("contact", "छोरालाई"), ("app", "वाट्सएपमा")], "relationship + explicit app")
add("gc-call-004", "devanagari", "call", "सुनितालाई भिडियो कल गर्नुहोस्",
    {"contact": "सुनिता", "callType": "video", "requestedApp": None},
    [("contact", "सुनितालाई"), ("app", "भिडियो कल")], "explicit video")
add("gc-call-005", "code_switched", "call", "didi lai facetime ma call gara na",
    {"contact": "didi", "callType": None, "requestedApp": "facetime"},
    [("contact", "didi"), ("app", "facetime")], "code-switched with particle")
add("gc-call-006", "devanagari", "call", "रामलाई फोन लगाउनुहोस्",
    {"contact": "राम", "callType": None, "requestedApp": None},
    [("contact", "रामलाई"), ("app", "फोन")], "alternate verb लगाउनु")
add("gc-call-007", "devanagari", "call", "गीतालाई कल गर",
    {"contact": "गीता", "callType": None, "requestedApp": None},
    [("contact", "गीतालाई")], "bare कल — generic method, not spanned")
add("gc-call-008", "latin", "call", "ram lai call gara",
    {"contact": "ram", "callType": None, "requestedApp": None},
    [("contact", "ram")], "romanized bare call")
add("gc-call-009", "devanagari", "call", "हरिलाई भिडियो कल गर",
    {"contact": "हरि", "callType": "video", "requestedApp": None},
    [("contact", "हरिलाई"), ("app", "भिडियो कल")], "video call, no app named")
add("gc-call-010", "devanagari", "call", "आमालाई व्हाट्सएपमा फोन गर",
    {"contact": "आमा", "callType": None, "requestedApp": "whatsapp"},
    [("contact", "आमालाई"), ("app", "व्हाट्सएपमा")], "spelling variant of वाट्सएप")
add("gc-call-011", "devanagari", "call", "बुबालाई फेसटाइममा कल गर्नुहोस्",
    {"contact": "बुबा", "callType": None, "requestedApp": "facetime"},
    [("contact", "बुबालाई"), ("app", "फेसटाइममा")], "relationship + facetime")
add("gc-call-012", "latin", "call", "saraswati lai video call gara",
    {"contact": "saraswati", "callType": "video", "requestedApp": None},
    [("contact", "saraswati"), ("app", "video call")], "romanized video call")
add("gc-call-013", "devanagari", "call", "होइन, वाट्सएपमा नै गर",
    {"contact": None, "callType": None, "requestedApp": "whatsapp"},
    [("app", "वाट्सएपमा")],
    "correction: schema-v2 meaning is the amended method, not a rejection")
add("gc-call-014", "devanagari", "call", "कृष्णलाई फोन गर न",
    {"contact": "कृष्ण", "callType": None, "requestedApp": None},
    [("contact", "कृष्णलाई"), ("app", "फोन")], "trailing particle")
add("gc-call-015", "latin", "call", "didi lai phone gara",
    {"contact": "didi", "callType": None, "requestedApp": None},
    [("contact", "didi"), ("app", "phone")], "relationship, romanized")
add("gc-call-016", "devanagari", "call", "मलाई छोरी सँग कुरा गर्नु छ",
    {"contact": "छोरी", "callType": None, "requestedApp": None},
    [("contact", "छोरी")], "talk-to phrasing, particle as its own word")

# --- emergency (16): pleas, pain+help, falls, breathlessness, fear ----------
add("gc-emergency-001", "devanagari", "emergency", "मद्दत गर्नुहोस्", {}, [],
    "canonical plea")
add("gc-emergency-002", "devanagari", "emergency",
    "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ", {}, [],
    "THE boundary case — plea+pain is emergency, NOT health_query (live Gemini failure, 2026-09-04)")
add("gc-emergency-003", "devanagari", "emergency", "म लडेँ, उठ्न सकिन", {}, [],
    "fall + inability")
add("gc-emergency-004", "devanagari", "emergency", "मलाई बचाउनुहोस्", {}, [],
    "bare rescue plea")
add("gc-emergency-005", "devanagari", "emergency",
    "छाती धेरै दुख्यो, मद्दत गर्नुहोस्", {}, [], "chest pain + plea")
add("gc-emergency-006", "devanagari", "emergency", "सास फेर्न सकिन", {}, [],
    "breathlessness, first person, no explicit plea")
add("gc-emergency-007", "devanagari", "emergency", "म लडेँ, मद्दत चाहियो", {}, [],
    "fall + help needed")
add("gc-emergency-008", "devanagari", "emergency", "मलाई डर लागिरहेको छ", {}, [],
    "fear for safety")
add("gc-emergency-009", "devanagari", "emergency",
    "टाउको धेरै दुख्यो, बचाउनुहोस्", {}, [], "severe pain + rescue plea")
add("gc-emergency-010", "latin", "emergency",
    "madat garnus, malai saas ferna sakina", {}, [], "romanized breathlessness + plea")
add("gc-emergency-011", "devanagari", "emergency",
    "आमा बेहोस भइन्, मद्दत गर्नुहोस्", {}, [], "collapse of another person")
add("gc-emergency-012", "devanagari", "emergency",
    "रगत बगिरहेको छ, हतार गर्नुहोस्", {}, [], "bleeding + urgency")
add("gc-emergency-013", "devanagari", "emergency",
    "उठ्न सक्दिन, मद्दत गर्नुहोस्", {}, [], "cannot get up + plea")
add("gc-emergency-014", "devanagari", "emergency",
    "मलाई सन्चो छैन, मद्दत गर्नुहोस्", {}, [], "unwell + plea")
add("gc-emergency-015", "devanagari", "emergency",
    "मिर्गौला दुख्यो, मद्दत गर्नुहोस्", {}, [],
    "boundary twin of gc-health-002 — pain PLUS plea")
add("gc-emergency-016", "devanagari", "emergency",
    "पेट दुख्यो र उठ्न सकिन, मद्दत चाहियो", {}, [], "pain + inability + plea")

# --- health_query (16): calm questions only, no plea ------------------------
add("gc-health-001", "devanagari", "health_query", "मेरो रक्तचाप कस्तो हुनुपर्छ", {}, [],
    "calm health question — the other half of the boundary pair")
add("gc-health-002", "devanagari", "health_query", "मिर्गौला दुख्दा के खानु हुन्न", {}, [],
    "pain mentioned but NO plea — must not fire emergency")
add("gc-health-003", "devanagari", "health_query", "सुगर कति हुँदा ठीक हुन्छ", {}, [],
    "calm threshold question")
add("gc-health-004", "devanagari", "health_query", "रक्तचाप बढी भए के गर्नुपर्छ", {}, [],
    "calm what-to-do question")
add("gc-health-005", "devanagari", "health_query", "औषधि खान बिर्सें भने के गर्ने", {}, [],
    "missed-dose question")
add("gc-health-006", "devanagari", "health_query", "टाउको दुख्दा कुन औषधि खाने", {}, [],
    "calm pain question — medicine choice")
add("gc-health-007", "devanagari", "health_query", "घुँडा दुख्दा के गर्नु राम्रो हुन्छ", {}, [],
    "joint pain, calm")
add("gc-health-008", "devanagari", "health_query", "दिनमा कति पानी पिउनुपर्छ", {}, [],
    "hydration question")
add("gc-health-009", "devanagari", "health_query", "नुन कति खानु हुन्छ", {}, [],
    "diet question")
add("gc-health-010", "devanagari", "health_query", "दुखाइको औषधि खाली पेट खान हुन्छ", {}, [],
    "medicine timing question")
add("gc-health-011", "devanagari", "health_query", "ब्लड सुगरको जाँच कति दिनमा गर्नुपर्छ", {}, [],
    "check frequency")
add("gc-health-012", "devanagari", "health_query", "निद्रा लाग्दैन, के गर्नुपर्छ", {}, [],
    "sleep question, no urgency")
add("gc-health-013", "devanagari", "health_query", "रगतको चाप सामान्य कति हुनुपर्छ", {}, [],
    "normal-range question")
add("gc-health-014", "devanagari", "health_query", "खोकी लागिरहेको छ, घरेलु उपाय के छ", {}, [],
    "cough, home remedy, calm")
add("gc-health-015", "devanagari", "health_query", "मेरो तौल घट्दै छ, किन होला", {}, [],
    "weight-loss question")
add("gc-health-016", "devanagari", "health_query", "आँखा धमिलो देखिन्छ, के कारण होला", {}, [],
    "vision question, calm")

# --- ack_med (15 ack_med + 1 none): completed-dose acknowledgements --------
# gc-ack-002 is the refusal twin and carries intent=none (it lives in this
# section so the खाएँ-vs-खाएको छैन contrast stays visible while authoring).
add("gc-ack-001", "devanagari", "ack_med", "औषधि खाएँ", {},
    [("medication", "औषधि")], "canonical ack")
add("gc-ack-002", "devanagari", "none", "औषधि खाएको छैन", {},
    [("medication", "औषधि")],
    "REFUSAL — खाए sits inside खाएको छैन; must never parse as ack_med")
add("gc-ack-003", "devanagari", "ack_med", "औषधि खाइसकें", {},
    [("medication", "औषधि")], "completive ack")
add("gc-ack-004", "devanagari", "ack_med", "दवाई खाएँ", {},
    [("medication", "दवाई")], "synonym for medicine")
add("gc-ack-005", "devanagari", "ack_med", "औषधि लिएँ", {},
    [("medication", "औषधि")], "take-verb ack")
add("gc-ack-006", "devanagari", "ack_med", "प्रेसरको औषधि खाएँ", {},
    [("medication", "प्रेसरको औषधि")], "dose name, multi-word span")
add("gc-ack-007", "devanagari", "ack_med", "सुगरको औषधि खाइसकें", {},
    [("medication", "सुगरको औषधि")], "dose name + completive")
add("gc-ack-008", "devanagari", "ack_med", "भिटामिन खाएँ", {},
    [("medication", "भिटामिन")], "supplement ack")
add("gc-ack-009", "latin", "ack_med", "aushadhi khaen", {"medication": "aushadhi"},
    [("medication", "aushadhi")], "romanized ack")
add("gc-ack-010", "latin", "ack_med", "dabai khaisake", {"medication": "dabai"},
    [("medication", "dabai")], "romanized completive ack")
add("gc-ack-011", "code_switched", "ack_med", "medicine khaisake",
    {"medication": "medicine"}, [("medication", "medicine")], "code-switched ack")
add("gc-ack-012", "devanagari", "ack_med", "आजको औषधि खाएँ", {},
    [("medication", "औषधि")], "day-scoped ack")
add("gc-ack-013", "devanagari", "ack_med", "बिहानको औषधि खाइसकें", {},
    [("medication", "औषधि")], "period-scoped ack")
add("gc-ack-014", "devanagari", "ack_med", "मैले औषधि खाएँ", {},
    [("medication", "औषधि")], "explicit subject")
add("gc-ack-015", "devanagari", "ack_med", "औषधि खाएँ, ठीक छ", {},
    [("medication", "औषधि")], "ack + reassurance")
add("gc-ack-016", "devanagari", "ack_med", "औषधि खाएको छु", {},
    [("medication", "औषधि")], "perfect-tense ack (distinct from past खाएँ)")

# --- set_reminder (16): time-expression zoo --------------------------------
add("gc-reminder-001", "devanagari", "set_reminder", "बिहान ८ बजे औषधि खान सम्झाउनु",
    {"time": "बिहान ८ बजे", "medication": "औषधि"},
    [("time", "बिहान ८ बजे"), ("medication", "औषधि")],
    "Devanagari digit in time expression")
add("gc-reminder-002", "devanagari", "set_reminder", "साढे ७ बजे हिँड्न सम्झाउनुहोस्",
    {"time": "साढे ७ बजे", "medication": None},
    [("time", "साढे ७ बजे")], "साढे half-past")
add("gc-reminder-003", "devanagari", "set_reminder", "दिउँसो २ बजे औषधि खान सम्झाउनु",
    {"time": "दिउँसो २ बजे", "medication": "औषधि"},
    [("time", "दिउँसो २ बजे"), ("medication", "औषधि")], "afternoon period")
add("gc-reminder-004", "devanagari", "set_reminder", "बेलुका ७ बजे दवाई खान सम्झाउनु",
    {"time": "बेलुका ७ बजे", "medication": "दवाई"},
    [("time", "बेलुका ७ बजे"), ("medication", "दवाई")], "evening period")
add("gc-reminder-005", "devanagari", "set_reminder", "राति ९ बजे सुगरको औषधि खान सम्झाउनु",
    {"time": "राति ९ बजे", "medication": "सुगरको औषधि"},
    [("time", "राति ९ बजे"), ("medication", "सुगरको औषधि")], "night + multi-word med")
add("gc-reminder-006", "devanagari", "set_reminder", "साढे ८ बजे पानी खान सम्झाउनु",
    {"time": "साढे ८ बजे", "medication": None},
    [("time", "साढे ८ बजे")], "water reminder, साढे")
add("gc-reminder-007", "devanagari", "set_reminder", "भोलि बिहान ७ बजे हिँड्न सम्झाउनु",
    {"time": "भोलि बिहान ७ बजे", "medication": None},
    [("time", "भोलि बिहान ७ बजे")], "relative day + period + digit")
add("gc-reminder-008", "devanagari", "set_reminder", "हरेक दिन बिहान ६ बजे उठ्न सम्झाउनु",
    {"time": "बिहान ६ बजे", "medication": None},
    [("time", "बिहान ६ बजे")], "recurring — हरेक दिन is not part of the time slot")
add("gc-reminder-009", "devanagari", "set_reminder",
    "साँझ ५ बजे प्रेसरको औषधि खान सम्झाउनु",
    {"time": "साँझ ५ बजे", "medication": "प्रेसरको औषधि"},
    [("time", "साँझ ५ बजे"), ("medication", "प्रेसरको औषधि")], "साँझ period")
add("gc-reminder-010", "latin", "set_reminder", "bihana 7 baje aushadhi khana samjhaunu",
    {"time": "bihana 7 baje", "medication": "aushadhi"},
    [("time", "bihana 7 baje"), ("medication", "aushadhi")], "romanized reminder")
add("gc-reminder-011", "latin", "set_reminder", "saadhe 6 baje hidna samjhaunu",
    {"time": "saadhe 6 baje", "medication": None},
    [("time", "saadhe 6 baje")], "romanized half-past")
add("gc-reminder-012", "devanagari", "set_reminder", "मलाई बिहान ८ बजे सम्झना गराउनुहोस्",
    {"time": "बिहान ८ बजे", "medication": None},
    [("time", "बिहान ८ बजे")], "no medication — generic reminder")
add("gc-reminder-013", "devanagari", "set_reminder", "हरेक दिन बेलुका ८ बजे औषधि खान सम्झाउनु",
    {"time": "बेलुका ८ बजे", "medication": "औषधि"},
    [("time", "बेलुका ८ बजे"), ("medication", "औषधि")], "recurring daily med")
add("gc-reminder-014", "devanagari", "set_reminder", "बिहान १० बजे भिटामिन खान सम्झाउनु",
    {"time": "बिहान १० बजे", "medication": "भिटामिन"},
    [("time", "बिहान १० बजे"), ("medication", "भिटामिन")], "two-digit Devanagari hour")
add("gc-reminder-015", "devanagari", "set_reminder", "दिउँसो १ बजे खाना खान सम्झाउनु",
    {"time": "दिउँसो १ बजे", "medication": None},
    [("time", "दिउँसो १ बजे")], "meal reminder")
add("gc-reminder-016", "devanagari", "set_reminder", "राति साढे ९ बजे औषधि खान सम्झाउनु",
    {"time": "राति साढे ९ बजे", "medication": "औषधि"},
    [("time", "राति साढे ९ बजे"), ("medication", "औषधि")], "period + साढे")

# --- send_message (16): dictated bodies -------------------------------------
add("gc-message-001", "devanagari", "send_message",
    "सुनितालाई आज भेट्नुहोस् भनेर मेसेज पठाउ",
    {"contact": "सुनिता", "message": "आज भेट्नुहोस्"},
    [("contact", "सुनितालाई"), ("message", "आज भेट्नुहोस्")], "dictated body")
add("gc-message-002", "devanagari", "send_message", "माइयालाई मेसेज गर",
    {"contact": "माइया", "message": None}, [("contact", "माइयालाई")],
    "no body dictated")
add("gc-message-003", "devanagari", "send_message",
    "छोरालाई भोलि आउनु भनेर मेसेज पठाउ",
    {"contact": "छोरा", "message": "भोलि आउनु"},
    [("contact", "छोरालाई"), ("message", "भोलि आउनु")], "body with time word")
add("gc-message-004", "devanagari", "send_message",
    "रामलाई फोन गर्न भन्ने मेसेज पठाउ",
    {"contact": "राम", "message": "फोन गर्न"},
    [("contact", "रामलाई"), ("message", "फोन गर्न")], "body contains a call verb")
add("gc-message-005", "devanagari", "send_message",
    "रामलाई भोलि भेटौँला भनेर मेसेज पठाउ",
    {"contact": "राम", "message": "भोलि भेटौँला"},
    [("contact", "रामलाई"), ("message", "भोलि भेटौँला")], "body-only distinction")
add("gc-message-006", "latin", "send_message", "maiya lai message patha",
    {"contact": "maiya", "message": None}, [("contact", "maiya")], "romanized, no body")
add("gc-message-007", "latin", "send_message",
    "sunita lai ma thik chhu bhanera message patha",
    {"contact": "sunita", "message": "ma thik chhu"},
    [("contact", "sunita"), ("message", "ma thik chhu")], "romanized dictated body")
add("gc-message-008", "devanagari", "send_message",
    "दिदीलाई आज आउनुहोस् भनेर मेसेज गर",
    {"contact": "दिदी", "message": "आज आउनुहोस्"},
    [("contact", "दिदीलाई"), ("message", "आज आउनुहोस्")], "message verb variant")
add("gc-message-009", "devanagari", "send_message",
    "आमालाई मलाई फोन गर्नु भनेर मेसेज पठाउ",
    {"contact": "आमा", "message": "मलाई फोन गर्नु"},
    [("contact", "आमालाई"), ("message", "मलाई फोन गर्नु")], "body contains मलाई")
add("gc-message-010", "devanagari", "send_message",
    "भाइलाई घर आउँदै छु भनेर मेसेज पठाउ",
    {"contact": "भाइ", "message": "घर आउँदै छु"},
    [("contact", "भाइलाई"), ("message", "घर आउँदै छु")], "first-person body")
add("gc-message-011", "devanagari", "send_message",
    "हरिलाई शुभकामना भनेर मेसेज पठाउ",
    {"contact": "हरि", "message": "शुभकामना"},
    [("contact", "हरिलाई"), ("message", "शुभकामना")], "single-word body")
add("gc-message-012", "devanagari", "send_message",
    "गीतालाई भोलि बिहान आउनु भनेर मेसेज पठाउ",
    {"contact": "गीता", "message": "भोलि बिहान आउनु"},
    [("contact", "गीतालाई"), ("message", "भोलि बिहान आउनु")], "time inside body")
add("gc-message-013", "latin", "send_message",
    "krishna lai aaja aaunu bhanera message patha",
    {"contact": "krishna", "message": "aaja aaunu"},
    [("contact", "krishna"), ("message", "aaja aaunu")], "romanized dictated body")
add("gc-message-014", "devanagari", "send_message",
    "सरस्वतीलाई औषधि खान बिर्सनु हुन्न भनेर मेसेज पठाउ",
    {"contact": "सरस्वती", "message": "औषधि खान बिर्सनु हुन्न"},
    [("contact", "सरस्वतीलाई"), ("message", "औषधि खान बिर्सनु हुन्न")],
    "long body — medication words inside the message")
add("gc-message-015", "devanagari", "send_message",
    "नातिलाई परीक्षा राम्रो होस् भनेर मेसेज पठाउ",
    {"contact": "नाति", "message": "परीक्षा राम्रो होस्"},
    [("contact", "नातिलाई"), ("message", "परीक्षा राम्रो होस्")], "wish body")
add("gc-message-016", "code_switched", "send_message",
    "didi lai 'ma pugẽ' bhanera message patha",
    {"contact": "didi", "message": "ma pugẽ"},
    [("contact", "didi"), ("message", "ma pugẽ")], "code-switched dictated body")

# --- music (16) -------------------------------------------------------------
add("gc-music-001", "devanagari", "music", "भजन बजाउनुस्", {}, [], "")
add("gc-music-002", "code_switched", "music", "bhajan bajau na", {}, [], "")
add("gc-music-003", "devanagari", "music", "गीत चलाउ", {}, [], "song play")
add("gc-music-004", "devanagari", "music", "पुरानो नेपाली गीत बजाउ", {}, [],
    "era-qualified song")
add("gc-music-005", "devanagari", "music", "ओम मणि पद्मे हूँ बजाउ", {}, [],
    "mantra title")
add("gc-music-006", "devanagari", "music", "गायत्री मन्त्र लगाउ", {}, [], "mantra play")
add("gc-music-007", "devanagari", "music", "रेडियोमा भजन लगाउ", {}, [],
    "radio + bhajan")
add("gc-music-008", "devanagari", "music", "फेरि बजाउ", {}, [],
    "repeat request (spec §9.1 music family)")
add("gc-music-009", "devanagari", "music", "अर्को गीत बजाउ", {}, [], "next track")
add("gc-music-010", "latin", "music", "purano geet bajau", {}, [], "romanized song")
add("gc-music-011", "latin", "music", "bhajan chalaunus", {}, [], "romanized bhajan")
add("gc-music-012", "devanagari", "music", "लोक गीत बजाउनुस्", {}, [], "folk song")
add("gc-music-013", "devanagari", "music", "मन्त्र बजाउनुस्", {}, [], "mantra play")
add("gc-music-014", "devanagari", "music", "गीत बजाउ न", {}, [], "particle")
add("gc-music-015", "devanagari", "music", "पुरानो भजन लगाउनुहोस्", {}, [],
    "era-qualified bhajan")
add("gc-music-016", "devanagari", "music", "चलचित्रको गीत बजाउ", {}, [],
    "film song")

# --- guide (16): how-to, never executed -------------------------------------
add("gc-guide-001", "devanagari", "guide", "माइक्रोवेभमा चिया कसरी तताउने",
    {"topic": "माइक्रोवेभ"}, [("topic", "माइक्रोवेभमा")],
    "guide class — steps are spoken, never executed")
add("gc-guide-002", "devanagari", "guide", "वासिङ मेसिन कसरी चलाउने",
    {"topic": "वासिङ मेसिन"}, [("topic", "वासिङ मेसिन")], "appliance how-to")
add("gc-guide-003", "devanagari", "guide", "टिभी रिमोटमा के बटन थिच्ने",
    {"topic": "टिभी रिमोट"}, [("topic", "टिभी रिमोट")], "remote buttons")
add("gc-guide-004", "devanagari", "guide", "माइक्रोवेभ कसरी सफा गर्ने",
    {"topic": "माइक्रोवेभ"}, [("topic", "माइक्रोवेभ")], "cleaning steps")
add("gc-guide-005", "devanagari", "guide", "डिशवासर कसरी चलाउने",
    {"topic": "डिशवासर"}, [("topic", "डिशवासर")], "appliance how-to")
add("gc-guide-006", "devanagari", "guide", "मोबाइलमा फोटो कसरी खिच्ने",
    {"topic": "मोबाइल"}, [("topic", "मोबाइलमा")], "phone how-to")
add("gc-guide-007", "devanagari", "guide", "युट्युब कसरी खोल्ने",
    {"topic": "युट्युब"}, [("topic", "युट्युब")], "how to open an app")
add("gc-guide-008", "devanagari", "guide", "वाट्सएपमा भ्वाइस मेसेज कसरी पठाउने",
    {"topic": "वाट्सएप"}, [("topic", "वाट्सएपमा")], "messaging how-to")
add("gc-guide-009", "devanagari", "guide", "रेडियो कसरी अन गर्ने",
    {"topic": "रेडियो"}, [("topic", "रेडियो")], "device on/off")
add("gc-guide-010", "devanagari", "guide", "टिभीमा च्यानल कसरी फेर्ने",
    {"topic": "टिभी"}, [("topic", "टिभीमा")], "channel change")
add("gc-guide-011", "latin", "guide", "tv remote kasari chalaune",
    {"topic": "tv remote"}, [("topic", "tv remote")], "romanized how-to")
add("gc-guide-012", "latin", "guide", "microwave ma khana kasari tataune",
    {"topic": "microwave"}, [("topic", "microwave")], "romanized appliance how-to")
add("gc-guide-013", "devanagari", "guide", "फ्रिजमा तरकारी कसरी राख्ने",
    {"topic": "फ्रिज"}, [("topic", "फ्रिजमा")], "storage how-to")
add("gc-guide-014", "devanagari", "guide", "मोबाइल चार्ज कसरी गर्ने",
    {"topic": "मोबाइल"}, [("topic", "मोबाइल")], "charging how-to")
add("gc-guide-015", "devanagari", "guide", "वासिङ मेसिनमा कपडा कसरी हाल्ने",
    {"topic": "वासिङ मेसिन"}, [("topic", "वासिङ मेसिनमा")], "loading steps")
add("gc-guide-016", "devanagari", "guide", "इन्डक्सन चुलो कसरी चलाउने",
    {"topic": "इन्डक्सन चुलो"}, [("topic", "इन्डक्सन चुलो")], "appliance how-to")

# --- query (16) -------------------------------------------------------------
add("gc-query-001", "devanagari", "query", "भोलि मौसम कस्तो हुन्छ", {}, [], "")
add("gc-query-002", "devanagari", "query", "आज के दिन हो", {}, [], "date question")
add("gc-query-003", "devanagari", "query", "नेपालको राजधानी कहाँ हो", {}, [],
    "factual question")
add("gc-query-004", "devanagari", "query", "अहिले कति बज्यो", {}, [], "time question")
add("gc-query-005", "devanagari", "query", "आज कति गते हो", {}, [], "date-of-month")
add("gc-query-006", "devanagari", "query", "नेपालको प्रधानमन्त्री को हुन्", {}, [],
    "current-affairs question")
add("gc-query-007", "devanagari", "query", "काठमाडौंदेखि पोखरा कति टाढा छ", {}, [],
    "distance question")
add("gc-query-008", "devanagari", "query", "दसैँ कहिले पर्छ", {}, [], "festival date")
add("gc-query-009", "devanagari", "query", "नेपालमा कति जिल्ला छन्", {}, [],
    "count question")
add("gc-query-010", "devanagari", "query", "सगरमाथाको उचाइ कति हो", {}, [],
    "factual question")
add("gc-query-011", "latin", "query", "aaja ke din ho", {}, [], "romanized date question")
add("gc-query-012", "latin", "query", "nepalko rajdhani kaha ho", {}, [],
    "romanized factual question")
add("gc-query-013", "devanagari", "query", "भोलि बिदा छ", {}, [], "holiday question")
add("gc-query-014", "devanagari", "query", "अहिले साल कति भयो", {}, [], "year question")
add("gc-query-015", "devanagari", "query", "के काठमाडौंमा पानी परिरहेको छ", {}, [],
    "weather question")
add("gc-query-016", "devanagari", "query", "नेपालको झण्डामा के के छ", {}, [],
    "factual question")

# --- none (15): chit-chat, gibberish, fragments, refusals -------------------
add("gc-none-001", "devanagari", "none", "ऊ त्यो के भनें कुन्नि", {}, [],
    "fragmented elder speech — abstain (low confidence)")
add("gc-none-002", "devanagari", "none", "औषधि खाइनँ", {},
    [("medication", "औषधि")], "refusal — must not fire ack_med")
add("gc-none-003", "devanagari", "none", "पछि खान्छु", {}, [],
    "deferral/refusal of the medication reminder")
add("gc-none-004", "devanagari", "none", "होइन, औषधि खाएको छैन", {},
    [("medication", "औषधि")], "explicit refusal with negation")
add("gc-none-005", "latin", "none", "haina, ausadhi khayeko chhaina", {},
    [], "romanized refusal")
add("gc-none-006", "devanagari", "none", "खान मन लागेन", {}, [],
    "refusal of food/medicine, no amendment")
add("gc-none-007", "devanagari", "none", "हँ", {}, [], "filler particle")
add("gc-none-008", "devanagari", "none", "अहो", {}, [], "filler particle")
add("gc-none-009", "devanagari", "none", "के थाहा", {}, [], "no-knowledge reply")
add("gc-none-010", "devanagari", "none", "फोन... अरे होइन... के गर्ने भनेको थिएँ", {}, [],
    "self-interrupted fragment — abstain")
add("gc-none-011", "devanagari", "none", "ए... त्यो... हुँदैन", {}, [],
    "fragmented elder speech")
add("gc-none-012", "devanagari", "none", "आज बजार जानु छ", {}, [],
    "chit-chat, nothing to execute")
add("gc-none-013", "devanagari", "none", "भोलि छोरी आउँछे", {}, [],
    "chit-chat statement")
add("gc-none-014", "devanagari", "none", "आज गर्मी छ", {}, [], "chit-chat statement")
add("gc-none-015", "latin", "none", "hmm... thaha chhaina", {}, [],
    "romanized no-knowledge reply")

# --- create_calendar_event (15) --------------------------------------------
add("gc-calendar-001", "devanagari", "create_calendar_event",
    "भोलि दिउँसो ३ बजे डाक्टरको अपोइन्टमेन्ट राख",
    {"time": "भोलि दिउँसो ३ बजे"}, [("time", "भोलि दिउँसो ३ बजे")],
    "appointment with explicit time")
add("gc-calendar-002", "devanagari", "create_calendar_event",
    "पर्सि बिहान ११ बजे चेकअपको अपोइन्टमेन्ट मिलाउ",
    {"time": "पर्सि बिहान ११ बजे"}, [("time", "पर्सि बिहान ११ बजे")],
    "day-after-tomorrow + verb मिलाउ")
add("gc-calendar-003", "devanagari", "create_calendar_event",
    "आइतबार बिहान ९ बजे भेटघाट राख",
    {"time": "आइतबार बिहान ९ बजे"}, [("time", "आइतबार बिहान ९ बजे")],
    "weekday + period")
add("gc-calendar-004", "devanagari", "create_calendar_event",
    "भोलि बेलुका ६ बजे छोरीको घर जाने कार्यक्रम राख",
    {"time": "भोलि बेलुका ६ बजे"}, [("time", "भोलि बेलुका ६ बजे")],
    "visit programme")
add("gc-calendar-005", "devanagari", "create_calendar_event",
    "सोमबार दिउँसो २ बजे अस्पताल जाने अपोइन्टमेन्ट राख",
    {"time": "सोमबार दिउँसो २ बजे"}, [("time", "सोमबार दिउँसो २ बजे")],
    "hospital appointment")
add("gc-calendar-006", "devanagari", "create_calendar_event",
    "भोलि बिहान ८ बजे बजार जाने कार्यक्रम राख",
    {"time": "भोलि बिहान ८ बजे"}, [("time", "भोलि बिहान ८ बजे")],
    "market trip")
add("gc-calendar-007", "devanagari", "create_calendar_event",
    "शुक्रबार बेलुका ५ बजे पूजा राख",
    {"time": "शुक्रबार बेलुका ५ बजे"}, [("time", "शुक्रबार बेलुका ५ बजे")],
    "worship event")
add("gc-calendar-008", "code_switched", "create_calendar_event",
    "भोलि 10 baje meeting rakh",
    {"time": "भोलि 10 baje"}, [("time", "भोलि 10 baje")],
    "code-switched meeting")
add("gc-calendar-009", "latin", "create_calendar_event",
    "parsi 4 baje doctor ko appointment rakha",
    {"time": "parsi 4 baje"}, [("time", "parsi 4 baje")], "romanized appointment")
add("gc-calendar-010", "devanagari", "create_calendar_event",
    "आउँदो हप्ता मंगलबार १२ बजे खाजा खाने कार्यक्रम राख",
    {"time": "मंगलबार १२ बजे"}, [("time", "मंगलबार १२ बजे")],
    "next-week event — आउँदो हप्ता is not part of the time slot")
add("gc-calendar-011", "devanagari", "create_calendar_event",
    "भोलि दिउँसो १ बजे औषधि लिन जाने काम राख",
    {"time": "भोलि दिउँसो १ बजे"}, [("time", "भोलि दिउँसो १ बजे")],
    "pharmacy errand")
add("gc-calendar-012", "devanagari", "create_calendar_event",
    "बिहान १० बजे नातिनीलाई स्कुल लिन जाने कार्यक्रम राख",
    {"time": "बिहान १० बजे"}, [("time", "बिहान १० बजे")], "pickup errand")
add("gc-calendar-013", "devanagari", "create_calendar_event",
    "भोलि राति ८ बजे डिनरको कार्यक्रम राख",
    {"time": "भोलि राति ८ बजे"}, [("time", "भोलि राति ८ बजे")], "dinner event")
add("gc-calendar-014", "devanagari", "create_calendar_event",
    "पर्सि दिउँसो ४ बजे मिटिङ राख",
    {"time": "पर्सि दिउँसो ४ बजे"}, [("time", "पर्सि दिउँसो ४ बजे")], "meeting")
add("gc-calendar-015", "devanagari", "create_calendar_event",
    "आज बेलुका ७ बजे औषधि खाने समय क्यालेन्डरमा राख",
    {"time": "आज बेलुका ७ बजे"}, [("time", "आज बेलुका ७ बजे")],
    "calendar-explicit wording")

# --- suggest_video (15) -----------------------------------------------------
add("gc-video-001", "devanagari", "suggest_video", "युट्युबमा भजन देखाउ", {}, [],
    "video path — देखाउ, not बजाउ (music)")
add("gc-video-002", "devanagari", "suggest_video", "पुरानो नेपाली भिडियो लगाउ", {}, [],
    "video, era-qualified")
add("gc-video-003", "devanagari", "suggest_video", "भजनको भिडियो देखाउ", {}, [],
    "bhajan video")
add("gc-video-004", "devanagari", "suggest_video", "युट्युब खोलेर गीत देखाउ", {}, [],
    "open YouTube + video")
add("gc-video-005", "devanagari", "suggest_video", "नेपाली समाचारको भिडियो लगाउ", {}, [],
    "news video")
add("gc-video-006", "devanagari", "suggest_video", "पुरानो चलचित्र देखाउ", {}, [],
    "film")
add("gc-video-007", "devanagari", "suggest_video", "भिडियोमा योग देखाउ", {}, [],
    "exercise video")
add("gc-video-008", "latin", "suggest_video", "youtube ma bhajan dekhau", {}, [],
    "romanized video request")
add("gc-video-009", "latin", "suggest_video", "purano geet ko video lagau", {}, [],
    "romanized video request")
add("gc-video-010", "devanagari", "suggest_video", "म्युजिक भिडियो लगाउ", {}, [],
    "music video")
add("gc-video-011", "devanagari", "suggest_video", "युट्युबमा खाना बनाउने भिडियो देखाउ", {}, [],
    "cooking video")
add("gc-video-012", "devanagari", "suggest_video", "प्रकृतिको भिडियो लगाउ", {}, [],
    "nature video")
add("gc-video-013", "devanagari", "suggest_video", "हास्य कार्यक्रमको भिडियो देखाउ", {}, [],
    "comedy video")
add("gc-video-014", "devanagari", "suggest_video", "युट्युबमा कृष्णको भजन देखाउ", {}, [],
    "video + deity bhajan")
add("gc-video-015", "devanagari", "suggest_video", "पुरानो नेपाली चलचित्रको भिडियो लगाउ", {}, [],
    "film video")


# ---------------------------------------------------------------------------
# eval/emergency_nearmiss.jsonl — the spec §10 adversarial set
# ---------------------------------------------------------------------------

NEARMISS: list[dict] = []


def add_nm(*args, **kwargs) -> None:
    NEARMISS.append(row(*args, **kwargs))


# emergency paraphrases that MUST be emergency (recall >= 0.98)
add_nm("nm-emergency-001", "devanagari", "emergency", "मदत गर्नुहोस्", {}, [],
       "plea, मदत spelling variant", kind="emergency_paraphrase")
add_nm("nm-emergency-002", "devanagari", "emergency", "मदत चाहियो", {}, [],
       "bare help-needed", kind="emergency_paraphrase")
add_nm("nm-emergency-003", "devanagari", "emergency", "बचाउनुहोस्", {}, [],
       "bare rescue", kind="emergency_paraphrase")
add_nm("nm-emergency-004", "devanagari", "emergency", "मलाई अहिले सहयोग चाहियो", {}, [],
       "explicit now + help", kind="emergency_paraphrase")
add_nm("nm-emergency-005", "devanagari", "emergency",
       "छातीमा धेरै दुखाइ छ, मदत चाहियो", {}, [], "chest pain + plea",
       kind="emergency_paraphrase")
add_nm("nm-emergency-006", "devanagari", "emergency", "सास लिन गारो भयो", {}, [],
       "breathlessness", kind="emergency_paraphrase")
add_nm("nm-emergency-007", "devanagari", "emergency",
       "मलाई सास फेर्न गाह्रो भइरहेको छ", {}, [],
       "first-person breathing trouble", kind="emergency_paraphrase")
add_nm("nm-emergency-008", "devanagari", "emergency", "म लडेँ, उठ्न सक्दिन", {}, [],
       "fall + cannot rise", kind="emergency_paraphrase")
add_nm("nm-emergency-009", "devanagari", "emergency",
       "खुट्टा भाँच्चियो जस्तो छ, मदत गर्नुहोस्", {}, [], "suspected fracture",
       kind="emergency_paraphrase")
add_nm("nm-emergency-010", "devanagari", "emergency", "मलाई बेस्सरी टाउको दुख्यो, मदत", {}, [],
       "severe headache + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-011", "devanagari", "emergency", "पेटमा असह्य दुखाइ छ", {}, [],
       "unbearable pain", kind="emergency_paraphrase")
add_nm("nm-emergency-012", "devanagari", "emergency", "रगत आइरहेको छ, हतार", {}, [],
       "bleeding + urgency", kind="emergency_paraphrase")
add_nm("nm-emergency-013", "devanagari", "emergency", "म बेहोस हुन लागें", {}, [],
       "fainting", kind="emergency_paraphrase")
add_nm("nm-emergency-014", "devanagari", "emergency", "मेरो आँखा अलप भयो", {}, [],
       "sudden vision loss", kind="emergency_paraphrase")
add_nm("nm-emergency-015", "devanagari", "emergency", "मलाई डर लाग्यो, कोही आउनुहोस्", {}, [],
       "fear + call someone", kind="emergency_paraphrase")
add_nm("nm-emergency-016", "devanagari", "emergency", "म एक्लै छु, मदत चाहियो", {}, [],
       "alone + help", kind="emergency_paraphrase")
add_nm("nm-emergency-017", "devanagari", "emergency",
       "मदत गर्नुहोस्, मलाई के भइरहेको छ थाहा छैन", {}, [],
       "plea + confusion about own state", kind="emergency_paraphrase")
add_nm("nm-emergency-018", "devanagari", "emergency",
       "मेरो औषधि सकियो, मलाई सन्चो छैन, मदत गर्नुहोस्", {}, [],
       "medication out + unwell + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-019", "devanagari", "emergency",
       "मलाई ज्वरो धेरै आयो, उठ्न सक्दिन", {}, [],
       "high fever + cannot rise", kind="emergency_paraphrase")
add_nm("nm-emergency-020", "devanagari", "emergency", "श्वास फेर्न सकिन, मदत", {}, [],
       "cannot breathe + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-021", "latin", "emergency", "madat garnus", {}, [],
       "romanized plea", kind="emergency_paraphrase")
add_nm("nm-emergency-022", "latin", "emergency", "malai saas ferna garo bhayo", {}, [],
       "romanized breathlessness", kind="emergency_paraphrase")
add_nm("nm-emergency-023", "latin", "emergency", "ma lade, madat chahiyo", {}, [],
       "romanized fall + help", kind="emergency_paraphrase")
add_nm("nm-emergency-024", "latin", "emergency", "chhati dukhyo, madat garnus", {}, [],
       "romanized chest pain + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-025", "code_switched", "emergency",
       "help garnus, malai sancho chhaina", {}, [],
       "code-switched help + unwell", kind="emergency_paraphrase")
add_nm("nm-emergency-026", "devanagari", "emergency",
       "मलाई अचानक रिँगटा लाग्यो, मदत", {}, [],
       "sudden dizziness + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-027", "devanagari", "emergency",
       "खाना खाँदा गाँठो अड्कियो, मदत गर्नुहोस्", {}, [],
       "choking + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-028", "devanagari", "emergency", "मेरो हात काम गर्दैन, मदत चाहियो", {}, [],
       "limb failure + help", kind="emergency_paraphrase")
add_nm("nm-emergency-029", "devanagari", "emergency",
       "दुखाइ सहन सक्दिन, मदत गर्नुहोस्", {}, [],
       "unbearable pain + plea", kind="emergency_paraphrase")
add_nm("nm-emergency-030", "devanagari", "emergency",
       "मलाई अस्पताल लैजानुहोस्, मदत", {}, [],
       "hospital request + plea", kind="emergency_paraphrase")

# calm pain/health questions that MUST NOT be emergency (gold health_query)
add_nm("nm-calm-001", "devanagari", "health_query", "घुँडा दुख्दा कुन औषधि लाउने", {}, [],
       "calm knee-pain question, no plea", kind="calm_pain_health")
add_nm("nm-calm-002", "devanagari", "health_query", "पेट दुख्दा के औषधि खाने", {}, [],
       "medicine-choice question", kind="calm_pain_health")
add_nm("nm-calm-003", "devanagari", "health_query", "टाउको दुख्दा घरेलु उपाय के छ", {}, [],
       "home-remedy question", kind="calm_pain_health")
add_nm("nm-calm-004", "devanagari", "health_query",
       "छाती दुख्दा डाक्टरलाई कहिले देखाउनुपर्छ", {}, [],
       "calm question about chest pain care", kind="calm_pain_health")
add_nm("nm-calm-005", "devanagari", "health_query", "ज्वरो आए के गर्नुपर्छ", {}, [],
       "general fever question", kind="calm_pain_health")
add_nm("nm-calm-006", "devanagari", "health_query", "खोकी लागे कुन औषधि खाने", {}, [],
       "cough medicine question", kind="calm_pain_health")
add_nm("nm-calm-007", "devanagari", "health_query", "नाकबाट रगत आउँदा के गर्ने", {}, [],
       "nosebleed how-to, no event", kind="calm_pain_health")
add_nm("nm-calm-008", "devanagari", "health_query", "रक्तचाप बढ्दा के गर्नुपर्छ", {}, [],
       "calm BP question", kind="calm_pain_health")
add_nm("nm-calm-009", "devanagari", "health_query", "सुगर घट्दा के गर्नुपर्छ", {}, [],
       "calm sugar question", kind="calm_pain_health")
add_nm("nm-calm-010", "devanagari", "health_query", "मुटु ढुकढुक हुँदा के गर्नुपर्छ", {}, [],
       "palpitations question", kind="calm_pain_health")
add_nm("nm-calm-011", "devanagari", "health_query", "आँखा दुख्दा के गर्ने", {}, [],
       "eye-pain question", kind="calm_pain_health")
add_nm("nm-calm-012", "devanagari", "health_query", "कम्मर दुख्दा कुन व्यायाम गर्ने", {}, [],
       "exercise question", kind="calm_pain_health")
add_nm("nm-calm-013", "devanagari", "health_query", "जोर्नी दुख्दा के खानु हुन्छ", {}, [],
       "diet question for joint pain", kind="calm_pain_health")
add_nm("nm-calm-014", "devanagari", "health_query", "दाँत दुख्दा के गर्ने", {}, [],
       "toothache question", kind="calm_pain_health")
add_nm("nm-calm-015", "devanagari", "health_query", "कान दुख्दा के गर्ने", {}, [],
       "earache question", kind="calm_pain_health")
add_nm("nm-calm-016", "devanagari", "health_query", "ब्लड प्रेसरको औषधि कहिले खाने", {}, [],
       "medicine-timing question", kind="calm_pain_health")
add_nm("nm-calm-017", "latin", "health_query", "tauko dukhda ke garne", {}, [],
       "romanized pain question", kind="calm_pain_health")
add_nm("nm-calm-018", "latin", "health_query", "sugar badhda ke garnu parcha", {}, [],
       "romanized calm question", kind="calm_pain_health")
add_nm("nm-calm-019", "devanagari", "health_query", "औषधि नखाँदा के हुन्छ", {}, [],
       "consequence question", kind="calm_pain_health")
add_nm("nm-calm-020", "devanagari", "health_query", "पानी कति पिउनुपर्छ", {}, [],
       "hydration question", kind="calm_pain_health")


# ---------------------------------------------------------------------------

def _write(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for rec in rows:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def _summary(name: str, rows: list[dict]) -> str:
    from collections import Counter
    by_intent = Counter(r["intent"] for r in rows)
    by_script = Counter(r["script"] for r in rows)
    spans = Counter(s["label"] for r in rows for s in r["spans"])
    return (f"{name}: {len(rows)} rows; intents "
            + ", ".join(f"{k} {v}" for k, v in sorted(by_intent.items()))
            + "; scripts " + ", ".join(f"{k} {v}" for k, v in sorted(by_script.items()))
            + "; spans " + (", ".join(f"{k} {v}" for k, v in sorted(spans.items())) or "none"))


def _check_disjoint() -> None:
    """The two held-out sets must not share utterances (build_dataset's
    leakage guard refuses both, so a duplicate would silently shrink the
    independent near-miss sample). Uses the SAME normalization as the guard."""
    sys.path.insert(0, str(ROOT / "src"))
    from build_dataset import normalize  # noqa: PLC0415 (path set just above)

    corpus_keys = {normalize(r["utterance"]) for r in CORPUS}
    clashes = [r["id"] for r in NEARMISS if normalize(r["utterance"]) in corpus_keys]
    if clashes:
        raise SystemExit("[author] near-miss rows duplicate corpus utterances: "
                         + ", ".join(clashes))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify the committed files match this authoring data")
    args = parser.parse_args()

    corpus_path = ROOT / "eval" / "golden_corpus.jsonl"
    nearmiss_path = ROOT / "eval" / "emergency_nearmiss.jsonl"
    _check_disjoint()
    print("[author] " + _summary("golden_corpus", CORPUS))
    print("[author] " + _summary("emergency_nearmiss", NEARMISS))

    if args.check:
        ok = True
        for path, rows in ((corpus_path, CORPUS), (nearmiss_path, NEARMISS)):
            if not path.exists():
                print(f"[author] MISMATCH: {path} missing")
                ok = False
                continue
            committed = [json.loads(line) for line in
                         open(path, encoding="utf-8") if line.strip()]
            if committed != rows:
                print(f"[author] MISMATCH: {path} differs from authoring data")
                ok = False
            else:
                print(f"[author] OK: {path} matches ({len(rows)} rows)")
        sys.exit(0 if ok else 1)

    _write(corpus_path, CORPUS)
    _write(nearmiss_path, NEARMISS)
    print(f"[author] wrote {corpus_path} ({len(CORPUS)} rows)")
    print(f"[author] wrote {nearmiss_path} ({len(NEARMISS)} rows)")


if __name__ == "__main__":
    main()
