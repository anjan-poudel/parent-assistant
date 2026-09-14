"""Deterministic batch generator for the 8,000-row calibration corpus (T-038).

Why this file exists
--------------------
`eval/golden_corpus.jsonl` is the held-out corpus the calibration gate is
measured on. The contract (encoder_contract.yaml `calibration.gate`) pins
`corpus_floor: 8000` — the same floor annotation_rules.yaml:232 puts on the
training supply (`mixture.supply_caps.corpus_floor`) — and
`src/calibrate_encoder.py` only reports a calibration PASS when BOTH
`measurable_today` is true AND the corpus clears that floor (line 357:
`measurable = measurable_today and len(grows) >= floor`).

The hand-authored section of `author_golden_corpus.py` covers the taxonomy at
15-25 rows per action (spec §9.1). That is enough to pin the boundary cases
(gc-emergency-002, gc-ack-002, ...) and nowhere near enough to fill ten
confidence buckets. This module generates the remaining rows.

What it produces
----------------
Row SPECS, not files. `author_golden_corpus.py` runs every spec through its
own `row()`, so the T-034 invariants (offsets located not counted, no
overlapping spans, no adjacent same-label spans, slot surfaces present in the
utterance) are enforced by the same code path as the hand rows — this module
cannot introduce a row the authoring script would refuse.

Design rules
------------
- Deterministic. No RNG anywhere: a row is a pure function of its position in
  its action's stream (mixed-radix decoding over the shape's dimension banks,
  round-robin over shapes). Re-running on any machine reproduces the corpus
  byte for byte, which is what `--check` compares.
- Reversible. The corpus is `hand rows` + `batch 1` + ... + `batch N`, each
  batch a contiguous block carrying all twelve actions proportionally. Run
  fewer batches and the corpus is still valid, still checkable, still
  revision-taggable (the tag is sha256(corpus)[:8]).
- Held out, not leaked. Every candidate utterance is refused when its
  `build_dataset.normalize` key is already spoken for, by any of four holders:
  a hand row; the adversarial near-miss set; the encoder-pipeline test fixture
  (tests/fixtures.py — a training-shaped corpus the leak guard would otherwise
  strip row by row, emptying the builder tests); or the training-source proxy
  (seeds/intents.yaml templates x entity banks — the templates gen_teacher.py
  paraphrases, so an exact instantiation there would cost a training row to
  build_dataset.py's leak guard). Refusals are counted and reported; the
  generator draws on until the quota is met.

Quotas
------
Per-action quota = 0.8 x the T-034 taxonomy target (annotation_rules.yaml
`taxonomy.targets`, which carries spec §9.1's numbers plus the T-036 proposed
values for create_calendar_event / suggest_video). Those sum to exactly 8,000,
and every action lands at 0.8x target — comfortably above
`mixture.supply_caps.per_action_floor` (0.25 x target), the floor the T-038
tests assert.

Registers: 70% devanagari / 20% latin / 10% code_switched (the loop below),
against the hand rows' 85/12/3 — the generated section deliberately carries
more romanized and code-switched mass than the pinned section, because the
hand section is boundary-case shaped rather than runtime shaped.

Template DSL
------------
    "{c}लाई [app:{m.s}] {v}"     {key} or {key.field} -> filler surface
                                 [label:...]       -> a span, offsets computed
A span group's text is located by author_golden_corpus._locate with an
occurrence index derived from the render position, so a surface that repeats
inside the utterance cannot bind to the wrong occurrence.
"""
from __future__ import annotations

import argparse
import itertools
import re
import sys
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
ROOT = EVAL_DIR.parent                      # tools/train-intent/
sys.path.insert(0, str(ROOT / "src"))
from build_dataset import normalize  # noqa: E402  (same key as the leak guard)

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# annotation_rules.yaml taxonomy.targets: spec_9_1 where it exists, else T-036's
# proposed count for the two shipped-but-unlisted actions.
TAXONOMY_TARGETS = {
    "call": 1500,
    "set_reminder": 1200,
    "send_message": 1000,
    "emergency": 1000,
    "health_query": 700,
    "music": 600,
    "guide": 600,
    "query": 1000,
    "none": 500,
    "ack_med": 800,
    "create_calendar_event": 600,
    "suggest_video": 500,
}
QUOTA_SCALE = 0.8                     # 0.8 x target; sums to exactly 8,000
CORPUS_FLOOR = 8000                   # encoder_contract.yaml corpus_floor
N_BATCHES = 12                        # 12 x ~651 rows
MARGIN = 900                          # spare draws per action for refused candidates
MAX_DRAWS_PER_ROW = 60                # loop guard: capacity exhausted => loud stop

# File order of the generated batches (also the concat order of the blocks).
ORDER = ["call", "emergency", "health_query", "ack_med", "set_reminder",
         "send_message", "music", "guide", "query", "none",
         "create_calendar_event", "suggest_video"]

# id family per action — same stems the hand rows use (gc-call-001, gc-health-004)
FAMILY = {"call": "call", "emergency": "emergency", "health_query": "health",
          "ack_med": "ack", "set_reminder": "reminder", "send_message": "message",
          "music": "music", "guide": "guide", "query": "query", "none": "none",
          "create_calendar_event": "calendar", "suggest_video": "video"}

QUOTA = {a: int(round(t * QUOTA_SCALE)) for a, t in TAXONOMY_TARGETS.items()}
assert sum(QUOTA.values()) == CORPUS_FLOOR, sum(QUOTA.values())

REGISTERS = ("devanagari", "latin", "code_switched")
REGISTER_CYCLE = ("devanagari",) * 7 + ("latin",) * 2 + ("code_switched",)
# per-action rotation so registers interleave differently in every block
REGISTER_SALT = {"call": 0, "emergency": 3, "health_query": 6, "ack_med": 1,
                 "set_reminder": 4, "send_message": 7, "music": 2, "guide": 5,
                 "query": 8, "none": 0, "create_calendar_event": 3,
                 "suggest_video": 6}


# ---------------------------------------------------------------------------
# Template DSL
# ---------------------------------------------------------------------------

_OPEN, _CLOSE = "{", "}"
_GRP_OPEN, _GRP_CLOSE = "[", "]"
# Only `[<label>: ...]` opens a span group; any other bracket is literal text.
# The label test (not the bracket alone) is what tells a span from a stray
# bracket in an utterance.
SPAN_LABELS = ("contact", "time", "medication", "message", "topic", "app")
_GROUP_RE = re.compile(r"\[(" + "|".join(SPAN_LABELS) + r"):")


def _resolve(path: str, fillers: dict):
    """`{m}` / `{m.s}` / `{m.s.deep}` -> filler value (field access for dicts)."""
    parts = path.split(".")
    value = fillers[parts[0]]
    for part in parts[1:]:
        if not isinstance(value, dict) or part not in value:
            raise KeyError(f"filler {path!r} has no field {part!r}")
        value = value[part]
    return value


def _text(template: str, fillers: dict) -> str:
    """Render literal text + {placeholders}; rejects unstructured fillers."""
    out, i = [], 0
    while i < len(template):
        ch = template[i]
        if ch == _OPEN:
            j = template.index(_CLOSE, i)
            out.append(str(_resolve(template[i + 1:j], fillers)))
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def render(template: str, fillers: dict) -> tuple[str, list[tuple]]:
    """Render a template, returning (utterance, [(label, text, occurrence), ...]).

    `[label:...]` groups become spans; everything else is literal. The group's
    occurrence index is derived from its render position, so a repeated surface
    binds to the occurrence the template actually meant.
    """
    out: list[str] = []
    spans: list[tuple] = []
    i = 0
    while i < len(template):
        ch = template[i]
        if ch == _OPEN:
            j = template.index(_CLOSE, i)
            out.append(str(_resolve(template[i + 1:j], fillers)))
            i = j + 1
        elif ch == _GRP_OPEN and _GROUP_RE.match(template, i):
            j = template.index(_GRP_CLOSE, i)
            label, _, body = template[i + 1:j].partition(":")
            if not body:
                raise SystemExit(f"[batches] malformed span group {template[i:j + 1]!r}")
            start = len("".join(out))
            text = _text(body, fillers)
            out.append(text)
            utterance = "".join(out)
            spans.append((label, text, utterance[:start].count(text)))
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), spans


def _slot(value, fillers: dict):
    """Render one slot value; a whole-value placeholder resolving to None stays
    None (the corpus distinguishes a missing slot from the string 'None')."""
    if value is None:
        return None
    if isinstance(value, str) and value.startswith("{") and value.endswith("}") \
            and value.count("{") == 1:
        resolved = _resolve(value[1:-1], fillers)
        return None if resolved is None else str(resolved)
    return _text(value, fillers)


def _decode(dims, index: int) -> dict:
    """Mixed-radix decode; the LAST dimension varies fastest."""
    fillers = {}
    rest = index
    for key, bank in reversed(dims):
        fillers[key] = bank[rest % len(bank)]
        rest //= len(bank)
    return fillers


def _capacity(shape: dict) -> int:
    n = 1
    for _key, bank in shape["dims"]:
        n *= len(bank)
    return n


def S(template: str, slots: dict, dims: list, note: str = "") -> dict:
    """One shape: a template + slot map + the banks its placeholders draw from."""
    return {"t": template, "slots": slots, "dims": dims, "note": note}


# ---------------------------------------------------------------------------
# Banks — call contacts / methods
# ---------------------------------------------------------------------------

CONTACTS = ["माइया", "सुनिता", "राम", "हरि", "गीता", "कृष्ण", "सरस्वती", "दिल",
            "सिमा", "बिनोद", "कमला", "श्याम", "छोरा", "छोरी", "आमा", "बुबा",
            "दिदी", "दाइ", "बहिनी", "भाइ", "नाति", "नातिनी", "बुहारी", "ज्वाइँ"]
CONTACTS_LAT = ["maiya", "sunita", "ram", "hari", "gita", "krishna", "saraswati",
                "dil", "sima", "binod", "kamala", "shyam", "chhora", "chhori",
                "aama", "buwa", "didi", "dai", "bahini", "bhai", "nati",
                "natini", "buhari", "jwai"]

# {s: surface in the span, app: requestedApp, ct: callType} — the hand rows'
# convention: a bare फोन leaves both resolved fields None, भिडियो कल sets
# callType, a named app sets requestedApp (encoder_contract app_span_projection).
METHODS = [{"s": "फोन", "app": None, "ct": None},
           {"s": "भिडियो कल", "app": None, "ct": "video"},
           {"s": "वाट्सएपमा", "app": "whatsapp", "ct": None},
           {"s": "ह्वाट्सएपमा", "app": "whatsapp", "ct": None},
           {"s": "फेसटाइममा", "app": "facetime", "ct": None},
           {"s": "भाइबरमा", "app": "viber", "ct": None},
           {"s": "मेसेन्जरमा", "app": "messenger", "ct": None}]
METHODS_LAT = [{"s": "phone", "app": None, "ct": None},
               {"s": "video call", "app": None, "ct": "video"},
               {"s": "whatsapp", "app": "whatsapp", "ct": None},
               {"s": "facetime", "app": "facetime", "ct": None},
               {"s": "viber", "app": "viber", "ct": None},
               {"s": "messenger", "app": "messenger", "ct": None}]
CALL_VERBS = ["गर", "गर्नुहोस्", "गर न", "गर त", "गरिदिनुहोस्"]
CALL_VERBS_LAT = ["gara", "garnus", "gara na", "garnu hos", "garidinus"]
CALL_VERBS_CS = ["गर", "गर्नुहोस्", "गर न", "gara", "garnus"]
CALL_SLOTS = {"contact": "{c}", "callType": "{m.ct}", "requestedApp": "{m.app}"}

CALL_SHAPES_DEV = [
    S("[contact:{c}लाई] [app:{m.s}] {v}", CALL_SLOTS,
      [("c", CONTACTS), ("m", METHODS), ("v", CALL_VERBS)], "clitic merged into the contact span"),
    S("[contact:{c} लाई] [app:{m.s}] {v}", CALL_SLOTS,
      [("c", CONTACTS), ("m", METHODS), ("v", CALL_VERBS)], "particle is its own word"),
    S("[contact:{c}लाई] [app:{m.s}] {v} है", CALL_SLOTS,
      [("c", CONTACTS), ("m", METHODS), ("v", CALL_VERBS)], "trailing particle"),
    S("मलाई [contact:{c}] सँग कुरा गर्नु छ", {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS)], "talk-to phrasing — no method word"),
    S("[contact:{c}लाई] कल {v}", {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS), ("v", CALL_VERBS)], "bare कल — generic method, not spanned"),
    S("[contact:{c}लाई] [app:फोन] गर्नुहोस्", {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS)], "explicit फोन"),
    S("होइन, [app:{m.s}] नै {v}", {"contact": None, "callType": "{m.ct}", "requestedApp": "{m.app}"},
      [("m", METHODS), ("v", CALL_VERBS)],
      "correction: schema-v2 meaning is the amended method, not a rejection"),
    S("[contact:{c}लाई] [app:{m.s}] {v} भनेको", CALL_SLOTS,
      [("c", CONTACTS), ("m", METHODS), ("v", CALL_VERBS)], "echoed instruction"),
]
CALL_SHAPES_LAT = [
    S("[contact:{c}] lai [app:{m.s}] {v}", CALL_SLOTS,
      [("c", CONTACTS_LAT), ("m", METHODS_LAT), ("v", CALL_VERBS_LAT)], "romanized call"),
    S("[contact:{c}] lai {v} garnus hai", {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS_LAT), ("v", CALL_VERBS_LAT)], "romanized, no method word"),
    S("malai [contact:{c}] sanga kura garna chha",
      {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS_LAT)], "romanized talk-to phrasing"),
    S("haina, [app:{m.s}] nai {v}", {"contact": None, "callType": "{m.ct}", "requestedApp": "{m.app}"},
      [("m", METHODS_LAT), ("v", CALL_VERBS_LAT)], "romanized correction"),
    S("[contact:{c}] lai [app:{m.s}] ma {v}", CALL_SLOTS,
      [("c", CONTACTS_LAT), ("m", METHODS_LAT), ("v", CALL_VERBS_LAT)], "postposition variant"),
]
CALL_SHAPES_CS = [
    S("[contact:{c}] lai [app:{m.s}] {v}",
      {"contact": "{c}", "callType": "{m.ct}", "requestedApp": "{m.app}"},
      [("c", CONTACTS_LAT), ("m", METHODS), ("v", CALL_VERBS_CS)],
      "code-switched: latin contact + devanagari method"),
    S("[contact:{c}लाई] [app:{m.s}] {v} न",
      {"contact": "{c}", "callType": "{m.ct}", "requestedApp": "{m.app}"},
      [("c", CONTACTS), ("m", METHODS_LAT), ("v", CALL_VERBS_CS)],
      "code-switched: devanagari contact + latin method"),
    S("[contact:{c}] lai [app:{m.s}] call {v}",
      {"contact": "{c}", "callType": None, "requestedApp": None},
      [("c", CONTACTS_LAT), ("m", METHODS_LAT), ("v", CALL_VERBS)],
      "code-switched: English method + devanagari verb"),
]

# ---------------------------------------------------------------------------
# Banks — emergency (no spans; recall-first phrasing)
# ---------------------------------------------------------------------------

EMERGENCY_SYMPTOMS = [
    "छाती धेरै दुख्यो", "छातीमा असह्य दुखाइ छ", "टाउको बेस्सरी दुख्यो",
    "पेटमा असह्य दुखाइ छ", "मुटु ढुकढुक भयो", "सास फेर्न सकिन",
    "सास फेर्न गाह्रो भयो", "म लडेँ", "म लडें", "उठ्न सकिन", "उठ्न सक्दिन",
    "बेहोस हुन लागें", "आँखा अलप भयो", "रगत बगिरहेको छ", "खुट्टा भाँच्चियो",
    "हात चल्दैन", "ज्वरो धेरै आयो", "रिँगटा लाग्यो", "खाना अड्कियो",
    "मिर्गौला दुख्यो", "जोर्नी दुख्यो", "कम्मर दुख्यो", "मुटु दुख्यो",
    "टाउको घुम्यो", "शरीर काम्न थाल्यो", "नाकबाट रगत आयो", "घुँडा दुख्यो",
    "औँला चल्दैन", "जिब्रो लर्बराउँछ", "आँखा देख्दिन", "सुन्न सक्दिन",
    "म बेहोस भएँ", "सन्चो छैन", "धेरै कमजोर छु", "पिसाब रोकियो",
    "वाकवाकी लाग्यो", "खोकीले सतायो", "श्वास फेर्न गारो भयो",
    "टाउको दुखेर आत्तिएँ", "छाती कस्सियो",
]
EMERGENCY_PLEAS = [
    "मद्दत गर्नुहोस्", "बचाउनुहोस्", "मदत चाहियो", "हतार गर्नुहोस्",
    "कोही आउनुहोस्", "एम्बुलेन्स बोलाउनुहोस्", "छिटो आउनुहोस्",
    "मलाई अस्पताल लैजानुहोस्", "मद्दत चाहियो", "गुहार गर्नुहोस्",
    "जोगाउनुहोस्", "सहयोग गर्नुहोस्", "डाक्टरलाई बोलाउनुहोस्",
]
EMERGENCY_SYMPTOMS_LAT = [
    "chhati dukhyo", "tauko dukhyo", "saas ferna sakina", "ma lade",
    "uthna sakdina", "behos huna lage", "aankha alop bhayo", "ragat bagiraheko chha",
    "khutta bhanchiyo", "jworo dherai aayo", "ringata lagyo", "khanu adkiyo",
    "mirgaula dukhyo", "hata chaldaina", "sancho chhaina", "dherai kamjor chhu",
]
EMERGENCY_PLEAS_LAT = [
    "madat garnus", "bachaunus", "madat chahiyo", "hatar garnus",
    "kohi aaunus", "ambulance bolanus", "chhito aaunus", "madat garna parcha",
]

EMERGENCY_PLEAS_CS = ["मद्दत गर्नुहोस्", "बचाउनुहोस्", "कोही आउनुहोस्"]

EMERGENCY_SHAPES_DEV = [
    S("{sym}, {plea}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "symptom then plea"),
    S("{plea}, {sym}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "plea then symptom"),
    S("{sym}। {plea}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "danda break"),
    S("मलाई {sym}, {plea}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "first-person opener"),
    S("{plea} — {sym}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "plea first, dash"),
    S("{sym} नै भयो, {plea}", {}, [("sym", EMERGENCY_SYMPTOMS), ("plea", EMERGENCY_PLEAS)],
      "emphatic"),
]
EMERGENCY_SHAPES_LAT = [
    S("{sym}, {plea}", {}, [("sym", EMERGENCY_SYMPTOMS_LAT), ("plea", EMERGENCY_PLEAS_LAT)],
      "romanized symptom + plea"),
    S("{plea}, {sym}", {}, [("sym", EMERGENCY_SYMPTOMS_LAT), ("plea", EMERGENCY_PLEAS_LAT)],
      "romanized plea + symptom"),
    S("malai {sym}, {plea}", {}, [("sym", EMERGENCY_SYMPTOMS_LAT), ("plea", EMERGENCY_PLEAS_LAT)],
      "romanized first-person"),
]
EMERGENCY_SHAPES_CS = [
    # Each shape carries a fixed devanagari anchor so the other bank can stay
    # romanized and every row still mixes scripts.
    S("{sym} — मद्दत गर्नुहोस्", {}, [("sym", EMERGENCY_SYMPTOMS_LAT)],
      "code-switched plea"),
    S("मद्दत गर्नुहोस्, {sym}", {}, [("sym", EMERGENCY_SYMPTOMS_LAT)],
      "code-switched help"),
    S("{sym} भयो, help garnus", {}, [("sym", EMERGENCY_SYMPTOMS)],
      "code-switched help verb"),
    S("{plea} — {sym}", {}, [("sym", EMERGENCY_SYMPTOMS_LAT), ("plea", EMERGENCY_PLEAS_CS)],
      "code-switched symptom"),
    S("{sym} छ, ambulance बोलाउनुहोस्", {}, [("sym", EMERGENCY_SYMPTOMS_LAT)],
      "code-switched ambulance"),
]

# ---------------------------------------------------------------------------
# Banks — health_query (calm questions; no plea anywhere)
# ---------------------------------------------------------------------------

HQ_SUBJECTS = ["रक्तचाप", "सुगर", "ब्लड सुगर", "मिर्गौला", "कलेजो", "मुटु",
               "टाउको", "पेट", "घुँडा", "जोर्नी", "कम्मर", "आँखा", "कान",
               "दाँत", "छाला", "निद्रा", "तौल", "भोक", "खोकी", "ज्वरो",
               "दम", "थाइराइड", "कोलेस्ट्रोल", "हाड", "नसा", "पिसाब",
               "औषधि", "भिटामिन", "नुन", "पानी", "चिनी", "तेल", "दूध",
               "आँत", "फोक्सो", "नाडी", "खून", "घाँटी", "शरीरको तापक्रम",
               "मुटुको धड्कन", "मिर्गौलाको ढुंगा", "जोर्नीको दुखाइ"]
HQ_TAILS = [
    "{s} कति हुनुपर्छ", "{s} कस्तो हुनुपर्छ", "{s} बढी भए के गर्नुपर्छ",
    "{s} घटी भए के गर्नुपर्छ", "{s} दुख्दा के गर्नुपर्छ",
    "{s} दुख्दा कुन औषधि खाने", "{s} को औषधि कहिले खाने",
    "{s} को जाँच कति दिनमा गर्नुपर्छ", "{s} मा के खानु हुन्छ",
    "{s} मा के खानु हुन्न", "{s} को घरेलु उपाय के छ",
    "{s} कति हुँदा ठीक हुन्छ", "{s} को लक्षण के हो",
    "{s} सँगै कुन औषधि खान हुन्छ", "{s} को मात्रा कति हुनुपर्छ",
    "{s} कहिले जाँच गर्नुपर्छ", "{s} को समस्या कसरी थाहा हुन्छ",
    "{s} राम्रो हुन कति समय लाग्छ", "{s} कस्तो भए डाक्टर जाने",
    "{s} को औषधि खाँदा के हुन्छ", "{s} बढ्न नदिन के गर्ने",
    "{s} को जाँच कहाँ हुन्छ", "{s} मा व्यायाम गर्न हुन्छ",
    "{s} को दुखाइ कति दिन रहन्छ", "{s} कस्तो खानेकुरा खान हुन्छ",
    "{s} को औषधि बिर्सें भने के हुन्छ", "{s} सामान्य कति हुन्छ",
]
HQ_SUBJECTS_LAT = ["raktachaap", "sugar", "blud sugar", "mirgaula", "kalejo",
                   "mutu", "tauko", "pet", "ghunda", "jorni", "kammar", "aankha",
                   "kaan", "daant", "chhala", "nidra", "taul", "bhok", "khoki",
                   "jworo", "dam", "thyroid", "cholesterol", "haad", "pisaab",
                   "aushadhi", "vitamin", "nun", "pani", "chini", "tel", "dudh",
                   "aanta", "phokso", "naadi", "khun", "ghaanti", "taapkram"]
HQ_TAILS_LAT = [
    "{s} kati hunuparchha", "{s} kasto hunuparchha", "{s} badhi bhaye ke garnuparchha",
    "{s} ghati bhaye ke garnuparchha", "{s} dukhda ke garnuparchha",
    "{s} dukhda kun aushadhi khane", "{s} ko aushadhi kahile khane",
    "{s} ko jaanch kati dinma garnuparchha", "{s} ma ke khanu hunchha",
    "{s} ko gharelu upaya ke chha", "{s} ko maatra kati hunuparchha",
    "{s} kahile jaanch garnuparchha", "{s} ko lakshan ke ho",
    "{s} ramro huna kati samaya lagchha", "{s} kasto bhaye doctor jane",
    "{s} normal kati hunuparchha",
]
HQ_TAILS_CS = [
    "{s} kati हुनुपर्छ", "{s} ma के खानु हुन्छ", "{s} ko जाँच कति दिनमा गर्नुपर्छ",
    "{s} दुख्दा ke गर्नुपर्छ", "{s} ko मात्रा कति हुनुपर्छ",
    "{s} बढी भए ke गर्नुपर्छ", "{s} ko औषधि कहिले खाने",
    "{s} normal ma kati हुन्छ", "{s} ko लक्षण के हो",
    "{s} kahile जाँच गर्नुपर्छ", "{s} ma ke खानु हुन्न",
    "{s} ko घरेलु उपाय ke छ",
]

# ---------------------------------------------------------------------------
# Banks — ack_med (past/completive only; refusal markers would be schema errors)
# ---------------------------------------------------------------------------

MEDS = ["औषधि", "दवाई", "प्रेसरको औषधि", "सुगरको औषधि", "भिटामिन",
        "क्याल्सियम", "आइरनको औषधि", "पेन किलर", "सुगरको गोली",
        "प्रेसरको गोली", "निद्राको औषधि", "एन्टिबायोटिक"]
MEDS_LAT = ["aushadhi", "dabai", "presser ko aushadhi", "sugar ko aushadhi",
            "vitamin", "calcium", "iron ko aushadhi", "pain killer",
            "sugar ko goli", "pressure ko goli", "nidra ko aushadhi"]
ACK_VERBS = ["खाएँ", "खाइसकें", "लिएँ", "लिइसकें", "खाएको छु", "लिएको छु",
             "खाइसक्यो", "सकें"]
ACK_VERBS_LAT = ["khaen", "khaisake", "lien", "lisake", "khayeko chhu",
                 "liyeko chhu", "khaisakyo"]
# CS verbs stay latin here: paired with the devanagari MEDS bank every row
# mixes scripts by construction (a mixed verb bank would emit dev-only rows).
ACK_VERBS_CS = ["khaen", "khaisake", "lien", "khayeko chhu", "lisake", "khaisakyo"]
ACK_SCOPES = ["", "आजको ", "बिहानको ", "बेलुकाको ", "दिउँसोको ", "रातको ",
              "अहिले ", "समयमै "]
ACK_SCOPES_LAT = ["", "aaja ko ", "bihana ko ", "beluka ko ", "ahiile ", "samayama "]

# ---------------------------------------------------------------------------
# Banks — time expressions (shared by set_reminder + create_calendar_event)
# ---------------------------------------------------------------------------

HOURS_DEV = ["१", "२", "३", "४", "५", "६", "७", "८", "९",
             "१०", "११", "१२"]
HOURS_LAT = [str(i) for i in range(1, 13)]
PERIODS_DEV = ["बिहान", "दिउँसो", "बेलुका", "राति", "साँझ"]
PERIODS_LAT = ["bihana", "diuso", "beluka", "rati", "saanj"]
STYLES_DEV = ["", "साढे ", "सवा ", "पौने "]
STYLES_LAT = ["", "saadhe ", "sawa ", "paune "]
DAYS_DEV = ["", "भोलि ", "आज ", "पर्सि "]
DAYS_LAT = ["", "bholi ", "aaja ", "parsi "]


def _times(periods, styles, days, hours, joiner: str) -> list[str]:
    return [f"{d}{p} {s}{h}{joiner}" for d in days for p in periods
            for s in styles for h in hours]


TIMES_DEV = _times(PERIODS_DEV, STYLES_DEV, DAYS_DEV, HOURS_DEV, " बजे")
TIMES_LAT = _times(PERIODS_LAT, STYLES_LAT, DAYS_LAT, HOURS_LAT, " baje")
# Every CS time carries script from BOTH sides: the latin day word is
# non-empty in the first block, and the latin period word is non-empty in the
# second — so no combination renders as a single-script row.
DAYS_LAT_FULL = ["aaja ", "bholi ", "parsi ", "yo hapta ", "arko hapta "]
TIMES_CS = ([f"{d} {p} {s}{h} बजे" for d in DAYS_LAT_FULL for p in PERIODS_DEV
             for s in STYLES_DEV for h in HOURS_DEV][:900]
            + [f"{d}{p} {s}{h} baje" for d in DAYS_DEV for p in PERIODS_LAT
               for s in STYLES_LAT for h in HOURS_LAT][:900])

# ---------------------------------------------------------------------------
# Banks — reminders / calendar / messages / media / guide / query / none
# ---------------------------------------------------------------------------

REMIND_VERBS = ["सम्झाउनु", "सम्झाउनुहोस्", "सम्झना गराउनुहोस्", "सम्झाइदिनुहोस्",
                "सम्झना दिलाउनुहोस्"]
REMIND_VERBS_LAT = ["samjhaunu", "samjhaunus", "samjhana garaunus",
                    "samjhaidinus"]
REMIND_VERBS_CS = ["samjhaunu", "samjhaunus", "samjhaidinus", "samjhana garaunus"]
ACTIVITIES = ["पानी खान", "खाना खान", "हिँड्न", "व्यायाम गर्न", "चिया खान",
              "दूध खान", "आराम गर्न", "टहलिन", "योग गर्न", "फलफूल खान"]
ACTIVITIES_LAT = ["pani khana", "khana khana", "hidna", "vyayam garna",
                  "chiya khana", "dudh khana", "aaram garna", "tahalin"]

MESSAGE_BODIES = [
    "आज भेट्नुहोस्", "भोलि आउनु", "घर आउँदै छु", "म ठीक छु",
    "औषधि खान बिर्सनु हुन्न", "शुभकामना", "परीक्षा राम्रो होस्", "फोन गर्नु",
    "मलाई फोन गर्नु", "भोलि बिहान आउनु", "आज आउनुहोस्", "खाना खान आउनु",
    "बजार जाँदै छु", "ढिलो हुन्छ", "म पुगें", "तपाईंलाई सम्झें",
    "आराम गर्नुहोस्", "चिसो लाग्यो", "नयाँ वर्षको शुभकामना", "घर पुगें",
    "भोलि भेटौँला", "आज आउन सक्दिन", "पछि फोन गर्छु", "दसैँको शुभकामना",
]
MESSAGE_BODIES_LAT = [
    "aaja bhetnus", "bholi aaunu", "ghara aaudai chhu", "ma thik chhu",
    "aushadhi khana birsanu hunna", "shubhakamana", "aaja aaunus",
    "bholi bihana aaunu", "khana khana aaunu", "ma pugen", "aaram garnus",
]
# Every CS body carries real Devanagari (romanized-only bodies would render as
# a latin row); the CS verbs stay latin so the pairing always mixes.
MESSAGE_BODIES_CS = ["औषधि khana birsanu hunna", "aaja भेट्नुहोस्", "ma ठीक chhu",
                     "bholi आउनु", "आज घर आउँदै छु", "aushadhi खान बिर्सनु हुन्न"]
MSG_VERBS = ["मेसेज पठाउ", "मेसेज गर", "सन्देश पठाउ", "मेसेज पठाउनुहोस्",
             "मेसेज गर्नुहोस्"]
MSG_VERBS_LAT = ["message patha", "message gara", "message pathaunus"]
MSG_VERBS_CS = ["message patha", "message pathaunus", "pathaunus", "patha"]

MUSIC_ITEMS = [
    "भजन", "गीत", "पुरानो नेपाली गीत", "लोक गीत", "मन्त्र", "आधुनिक गीत",
    "चलचित्रको गीत", "शास्त्रीय संगीत", "दोहोरी", "राष्ट्रिय गीत",
    "बाल गीत", "किर्तन", "ओम मणि पद्मे हूँ", "गायत्री मन्त्र",
    "श्रीमद्भगवद्गीता", "रामायण", "हनुमान चालिसा", "दुर्गा कवच",
    "महामृत्युंजय मन्त्र", "कृष्णको भजन", "शिवको भजन", "सरस्वती वन्दना",
    "भैरवी भजन", "आरतीको भजन", "तिब्बती मन्त्र", "नयाँ गीत", "पुरानो भजन",
    "शान्ति मन्त्र", "गुरुको भजन", "बुद्धको भजन",
]
MUSIC_VERBS = ["बजाउ", "बजाउनुस्", "लगाउ", "लगाउनुहोस्", "चलाउ", "चलाउनुस्",
               "सुनाउ", "सुनाउनुस्"]
MUSIC_PREFIX = ["अलि ठूलो स्वरमा ", "फेरि ", "अर्को ", "रेडियोमा ",
                "अहिले ", "फेरि एक पटक "]
MUSIC_PREFIX_LAT = ["", "ali thulo swarma ", "feri ", "arko ", "ahiile "]
MUSIC_ITEMS_LAT = ["bhajan", "purano nepali geet", "lok geet", "mantra",
                   "gayatri mantra", "kirtan", "purano geet", "bhakti geet",
                   "aarti", "shanti mantra", "naya geet", "buddha ko bhajan"]
MUSIC_VERBS_LAT = ["bajau", "bajaunus", "lagau", "chalau", "chalaunus", "sunaunus"]
# CS: devanagari items x latin verbs (every row mixes scripts by construction)
MUSIC_ITEMS_CS = ["भजन", "गीत", "मन्त्र", "पुरानो नेपाली गीत", "लोक गीत"]
MUSIC_VERBS_CS = ["bajau", "bajaunus", "lagau", "chalaunus"]

GUIDE_TOPICS = ["माइक्रोवेभ", "वासिङ मेसिन", "टिभी रिमोट", "डिशवासर", "मोबाइल",
                "युट्युब", "वाट्सएप", "रेडियो", "टिभी", "फ्रिज",
                "इन्डक्सन चुलो", "ग्यास चुलो", "प्रेसर कुकर", "मिक्सर",
                "हिटर", "पंखा", "लाइट", "चार्जर", "क्यामेरा", "घडी",
                "इलेक्ट्रिक केतली", "ओभन", "स्मार्टफोन", "ल्यापटप",
                "फ्यान", "इस्त्री", "धुलाई मेसिन", "सिलाई मेसिन",
                "पानी तान्ने मोटर", "इन्भर्टर", "सोलार", "ब्याट्री",
                "कम्प्युटर", "ट्याबलेट", "प्रिन्टर", "स्पिकर", "माइक",
                "हेडफोन", "पावर बैंक", "बिजुली मिटर"]
GUIDE_TAILS = [
    "[topic:{t}मा] चिया कसरी तताउने", "[topic:{t}मा] के बटन थिच्ने",
    "[topic:{t}] कसरी चलाउने", "[topic:{t}] कसरी खोल्ने",
    "[topic:{t}] कसरी बन्द गर्ने", "[topic:{t}] कसरी सफा गर्ने",
    "[topic:{t}मा] कसरी सेट गर्ने", "[topic:{t}मा] कसरी जोड्ने",
    "[topic:{t}] कहाँ राख्ने", "[topic:{t}] कति बेर चलाउने",
    "[topic:{t}] कसरी चार्ज गर्ने", "[topic:{t}मा] फोटो कसरी खिच्ने",
    "[topic:{t}मा] भिडियो कसरी हेर्ने", "[topic:{t}बाट] म्युजिक कसरी बजाउने",
    "[topic:{t}] को बटन कुन हो", "[topic:{t}] प्रयोग कसरी गर्ने",
    "[topic:{t}] कसरी बनाउने", "[topic:{t}] कहिले बन्द गर्ने",
    "[topic:{t}को] आवाज कसरी बढाउने", "[topic:{t}मा] कति समय लाग्छ",
    "[topic:{t}बाट] फोन कसरी गर्ने", "[topic:{t}मा] इन्टरनेट कसरी जोड्ने",
    "[topic:{t}] किन चल्दैन", "[topic:{t}] कसरी मर्मत गर्ने",
    "[topic:{t}मा] के के हुन्छ", "[topic:{t}] कहाँ मिलाउने",
    "[topic:{t}] को रिमोट कहाँ छ", "[topic:{t}] कसरी बन्द हुन्छ",
]
GUIDE_TOPICS_LAT = ["microwave", "washing machine", "tv remote", "dishwasher",
                    "mobile", "youtube", "whatsapp", "radio", "tv", "fridge",
                    "induction", "mixer", "charger", "camera", "laptop",
                    "fan", "iron", "motor", "inverter", "solar",
                    "battery", "computer", "tablet", "printer"]
GUIDE_TAILS_LAT = [
    "[topic:{t}] kasari chalaune", "[topic:{t}] kasari kholne",
    "[topic:{t}] kasari banda garne", "[topic:{t}] kasari safa garne",
    "[topic:{t}] ma ke button thichne", "[topic:{t}] kasari set garne",
    "[topic:{t}] kasari charge garne", "[topic:{t}] kaha rakhne",
    "[topic:{t}] kasari jodne", "[topic:{t}] kati ber chalaune",
    "[topic:{t}] kasari banaune", "[topic:{t}] kahile banda garne",
    "[topic:{t}] ko awaaj kasari badhaune", "[topic:{t}] kasari marmaat garne",
    "[topic:{t}] kina chaldaina", "[topic:{t}] ko remote kaha chha",
    "[topic:{t}] kasari banda hunchha", "[topic:{t}] kati samaya lagchha",
]
# CS is built from two structurally mixed pairings: devanagari topic x latin
# tail, and latin topic x devanagari tail.
GUIDE_TOPICS_CS_DEV = ["माइक्रोवेभ", "टिभी रिमोट", "युट्युब", "रेडियो", "मोबाइल",
                       "फ्रिज", "चार्जर", "क्यामेरा", "मिक्सर", "ल्यापटप"]
GUIDE_TOPICS_CS_LAT = ["washing machine", "mobile", "tv remote", "fridge",
                       "mixer", "charger", "computer", "printer", "tablet",
                       "induction"]
GUIDE_TAILS_CS_LAT = [
    "[topic:{t}] kasari chalaune", "[topic:{t}] kasari kholne",
    "[topic:{t}] kasari set garne", "[topic:{t}] kaha rakhne",
    "[topic:{t}] kasari charge garne", "[topic:{t}] kasari safa garne",
]
GUIDE_TAILS_CS_DEV = [
    "[topic:{t}] कसरी चलाउने", "[topic:{t}मा] के बटन थिच्ने",
    "[topic:{t}] कसरी खोल्ने", "[topic:{t}] कसरी बन्द गर्ने",
    "[topic:{t}मा] कसरी जोड्ने", "[topic:{t}] कहाँ राख्ने",
]

QUERY_FACTS = ["नेपालको राजधानी", "सगरमाथाको उचाइ", "नेपालको क्षेत्रफल",
               "नेपालमा जिल्ला", "काठमाडौंको जनसंख्या", "पोखरा", "लुम्बिनी",
               "जनकपुर", "नेपालको झण्डा", "राष्ट्रिय पक्षी", "राष्ट्रिय फूल",
               "नेपालको प्रधानमन्त्री", "नेपालको राष्ट्रपति", "नेपालको मुद्रा",
               "नेपालको भाषा", "हिमालको नाम", "कोशी नदी", "फेवा ताल",
               "राष्ट्रिय खेल", "नेपालको इतिहास", "काठमाडौंको उचाइ",
               "नेपालको साक्षरता", "माउन्ट एभरेस्ट", "अन्नपूर्ण",
               "नेपालको संविधान", "नेपालको झन्डाको रंग", "कञ्चनजङ्घा",
               "मकालु", "लाङटाङ", "रारा ताल", "तिलिचो ताल", "बौद्ध स्तूप",
               "पशुपतिनाथ", "स्वयम्भूनाथ", "मनकामना", "चितवन राष्ट्रिय निकुञ्ज",
               "शुक्लाफाँटा", "बर्दिया", "धौलागिरि", "गौरीशंकर"]
QUERY_FACTS_LAT = ["nepal ko rajdhani", "sagarmatha ko uchai", "nepal ko kshetrafal",
                   "kathmandu ko janasankhya", "pokhara", "lumbini", "janakpur",
                   "nepal ko jhanda", "rastriya pakshi", "rastriya phul",
                   "nepal ko pradhanmantri", "nepal ko rastrapati",
                   "nepal ko mudra", "koshi nadi", "phewa tal", "rastriya khel",
                   "mount everest", "annapurna"]
QUERY_TAILS = ["{s} कहाँ हो", "{s} कति हो", "{s} के हो", "{s} कहिले भयो",
               "{s} कति छ", "{s} के के छ", "{s} कति छन्", "{s} को नाम के हो",
               "{s} कस्तो छ", "{s} कति टाढा छ", "{s} मा के छ",
               "{s} किन प्रसिद्ध छ", "{s} को जानकारी दिनुहोस्",
               "{s} बारेमा भन्नुहोस्", "{s} कहाँ पाइन्छ", "{s} कहाँ छ",
               "{s} कहाँ हुन्छ", "{s} को बारेमा बताउनुहोस्", "{s} कति राम्रो छ",
               "{s} को नाम भन्नुहोस्"]
QUERY_TAILS_LAT = ["{s} kaha ho", "{s} kati ho", "{s} ke ho", "{s} ko naam ke ho",
                   "{s} kati chha", "{s} kaha chha", "{s} ko jankari dinus",
                   "{s} barema bhanus"]
QUERY_TAILS_CS = ["{s} kaha ho", "{s} kati हो", "{s} ko नाम के हो",
                  "{s} ke हो", "{s} barema भन्नुहोस्"]
QUERY_DAYS = ["आज", "भोलि", "पर्सि", "आइतबार", "सोमबार", "मंगलबार",
              "बुधबार", "बिहीबार", "शुक्रबार", "शनिबार", "अर्को हप्ता",
              "यो महिना"]
QUERY_DAY_TAILS = ["{d} के दिन हो", "{d} कति गते हो", "{d} बिदा छ",
                   "{d} मौसम कस्तो हुन्छ", "{d} पानी पर्छ",
                   "{d} को मिति के हो", "{d} गर्मी हुन्छ", "{d} कहिले पर्छ"]
QUERY_FESTS = ["दसैँ", "तिहार", "छठ", "लोसार", "होली", "शिवरात्रि",
               "बुद्ध जयन्ती", "नयाँ वर्ष", "कृष्ण जन्माष्टमी", "गाईजात्रा",
               "इन्द्रजात्रा", "रामनवमी"]
QUERY_FEST_TAILS = ["{f} कहिले पर्छ", "{f} कति दिनको हुन्छ", "{f} मा के गर्ने",
                    "{f} कहिले हो", "{f} कसरी मनाउने", "{f} बिदा हुन्छ"]
QUERY_PLACES = ["काठमाडौं", "पोखरा", "ललितपुर", "भक्तपुर", "चितवन", "बुटवल",
                "धरान", "विराटनगर", "नेपालगन्ज", "जनकपुर", "हेटौंडा", "इलाम",
                "गोरखा", "बागलुङ", "सुर्खेत", "धनगढी"]
QUERY_PLACES_TO = ["पोखरा", "काठमाडौं", "लुम्बिनी", "जनकपुर", "चितवन", "इलाम",
                   "गोरखा", "बागलुङ", "सुर्खेत", "धनगढी", "नाम्चे", "मुस्ताङ",
                   "सोलुखुम्बु", "ताप्लेजुङ", "डोल्पा", "मनाङ"]
QUERY_TIME_QS = ["अहिले कति बज्यो", "अहिले कति बजेको छ", "अहिले समय के भयो",
                 "आज कति गते भयो", "अहिले साल कति भयो", "महिना के भयो",
                 "आज महिनाको कति गते", "अहिले दिनको कति बज्यो",
                 "बिहानको समय कति भयो", "अब कति बज्यो", "घडीमा कति भयो",
                 "अहिले बेलुका भयो कि", "आज शुक्रबार हो", "भोलि के बार हो",
                 "आज कुन तिथि हो", "अहिले राति भयो", "साँझ भयो कि",
                 "अहिले दिउँसो हो", "यो महिना कति दिनको छ", "अर्को हप्ता के बार हो"]
QUERY_MISC = [
    "आज मौसम कस्तो छ", "भोलि पानी पर्छ", "हिजो गर्मी थियो",
    "यो हप्ता जाडो बढ्छ", "काठमाडौंमा अहिले पानी परिरहेको छ",
    "पोखरामा हिउँ पर्छ", "अहिले कति डिग्री छ", "आज हावा चल्छ",
    "भोलि घाम लाग्छ", "नेपालमा कति ऋतु हुन्छ", "अहिले कुन ऋतु हो",
    "यो वर्ष वर्षा कस्तो हुन्छ", "दसैँमा काठमाडौं कस्तो हुन्छ",
    "चाडपर्वमा बाटो भीड हुन्छ", "आज ट्राफिक कस्तो छ",
    "भोलि बिदा छ कि", "यो हप्ता वर्षा हुन्छ", "अहिले हावा कति छ",
    "आज घाम लाग्छ कि", "भोलि जाडो बढ्छ", "यो महिना गर्मी हुन्छ",
    "अहिले आकाश कस्तो छ", "भोलि हिउँ पर्छ", "आज बाटो खुला छ",
]
QUERY_MISC_LAT = ["aaja mausam kasto chha", "bholi pani parchha",
                  "aaja ke din ho", "nepalko rajdhani kaha ho",
                  "ahiile kati bajyo", "aaja kati gate ho",
                  "sagarmathako uchai kati ho", "aaja garmi chha ki chhaina",
                  "bholi bida chha", "yo hapta jado badhchha"]

NONE_TOPICS = ["आज", "भोलि", "हिजो", "अहिले", "बिहान", "बेलुका", "राति",
               "यो वर्ष", "अर्को हप्ता", "दसैँमा", "जाडोमा", "गर्मीमा",
               "बजारमा", "गाउँमा", "बिहानको", "बेलुकाको", "अहिलेको",
               "हिजोको", "यो हप्ता", "अघिल्लो महिना", "साँझमा", "दिउँसो",
               "छिमेकमा", "घरमा"]
NONE_PREDICATES = ["गर्मी छ", "जाडो छ", "पानी परिरहेको छ", "हावा चलेको छ",
                   "मेला छ", "भीड छ", "छोरी आउँछे", "नाति खेल्दै छ",
                   "तरकारी सस्तो छ", "दूध महँगो भयो", "बाटो खुल्यो",
                   "बिजुली गयो", "फोन आएन", "पानी आएन", "खाना पाक्यो",
                   "फूल फुल्यो", "घाम लाग्यो", "बादल लाग्यो", "चिया पाक्यो",
                   "नातिनी पढ्दै छ", "छोरा आउँदै छ", "बजार सुनसान छ",
                   "खेत सुक्यो", "गाई बिराएकी छ", "कुकुर भुक्दै छ",
                   "मिठाई आयो", "तिहार नजिक छ", "पूजा भयो"]
NONE_TALK = ["नमस्ते", "तपाईंलाई कस्तो छ", "खाना खानुभयो", "सञ्चै हुनुहुन्छ",
             "बिहानको खाना खानुभयो", "आउनुभयो त", "गएको हप्ता कहाँ हुनुहुन्थ्यो",
             "आज मन राम्रो छ", "गीत सुन्दा राम्रो लाग्छ",
             "नाति नआउँदा एक्लो लाग्छ", "छिमेकी आएका थिए",
             "बिहान हिँड्न गएको थिएँ", "आज चिया राम्रो थियो",
             "यो गाउँ राम्रो छ", "मौसम राम्रो भयो", "आँगन सफा छ",
             "फूल राम्रो फुलेको छ", "छोरीले फोन गरेकी थिइन्", "आज शान्त दिन छ",
             "पुरानो कुरा सम्झें", "छिमेकीको छोरीको बिहे भयो", "खेतमा काम भयो",
             "बिहानको हावा राम्रो छ", "आज बजार गएको थिएँ"]
NONE_REFUSALS = ["औषधि खाइनँ", "औषधि खाएको छैन", "होइन, औषधि खाएको छैन",
                 "पछि खान्छु", "आज नखाने", "औषधि चाहिँदैन", "खान मन लागेन",
                 "अहिले नखाने", "औषधि सकियो", "दवाई लिन मन छैन",
                 "भोलि खान्छु", "औषधि बिर्सें", "औषधि खान बिर्सें",
                 "आज औषधि खान बिर्सें", "प्रेसरको औषधि खाइनँ", "सुगरको औषधि खाइनँ"]
NONE_REFUSAL_TAILS = ["", " मैले", " त", " नि", " है"]
NONE_FRAGMENTS = ["ऊ त्यो के भनें कुन्नि", "ए... त्यो... हुँदैन", "खै कुन्नि",
                  "के भनेको थिएँ", "अनि त्यो", "होइन होइन", "ल अब",
                  "ठीक छ त", "हो कि होइन", "अनि", "हँ", "अहँ", "ओहो", "आहा",
                  "खै", "फेरि भन", "भन्न आउँदैन", "के थाहा",
                  "त्यो... त्यो कहाँ राखें", "अनि तँ", "कुन हो", "ल त",
                  "अँ", "ए", "होइन", "अब के भन्ने", "थाहा भएन", "जे होस्",
                  "अनि त्यो कुरा", "एकछिन रुक", "के गर्दै छौ", "हुन्छ त",
                  "ल ठीक", "अनि फेरि", "त्यो होइन"]
NONE_FRAGMENTS_LAT = ["hmm thaha chhaina", "khai kunnu", "haina haina",
                      "k bhaneko thiye", "la aba", "thik chha ta", "ani tyo",
                      "ho ki hoina", "ka bhanne", "thaha bhayena",
                      "ekchhin ruk", "ke gardai chhau", "hunchha ta",
                      "la thik", "ani feri", "tyo hoina"]
NONE_TALK_LAT = ["namaste", "tapai lai kasto chha", "khana khanubhayo",
                 "sancho hunuhunchha", "aaja mann ramro chha",
                 "yo gaun ramro chha", "mausam ramro bhayo", "aangan safa chha",
                 "aaja shanta din chha", "purano kura samjhe",
                 "bihana ko hawa ramro chha", "aaja bajar gayeko thiye",
                 "chhimekiko chhori ko bihe bhayo", "khet ma kaam bhayo"]

CAL_EVENTS = ["डाक्टरको अपोइन्टमेन्ट", "चेकअपको अपोइन्टमेन्ट", "अस्पताल जाने",
              "बजार जाने", "छोरीको घर जाने", "पूजा", "भेटघाट", "मिटिङ",
              "डिनर", "खाजा खाने", "औषधि लिन जाने",
              "नातिनीलाई स्कुल लिन जाने", "नातिलाई स्कुल छोड्ने",
              "कपाल काट्न जाने", "बैंक जाने", "तीर्थ जाने", "गाउँ जाने",
              "भेट्न जाने", "दान गर्ने", "व्यायाम गर्ने"]
CAL_VERBS = ["राख", "राख्नुहोस्", "राख न", "मिलाउ", "मिलाउनुहोस्",
             "राखिदिनुहोस्"]
CAL_EVENTS_LAT = ["doctor ko appointment", "checkup ko appointment",
                  "hospital jane", "bajar jane", "puja", "bhetghat", "meeting",
                  "dinner", "khaja khane", "aushadhi lina jane", "bank jane"]
CAL_VERBS_LAT = ["rakha", "rakhnus", "milaunus"]
CAL_EVENTS_CS = ["doctor ko appointment", "meeting", "चेकअपको appointment",
                 "अस्पताल जाने", "puja", "bank जाने"]
CAL_VERBS_CS = ["राख", "rakha", "राख्नुहोस्", "rakhnus"]

VIDEO_ITEMS = ["भजनको भिडियो", "पुरानो नेपाली भिडियो", "नेपाली समाचारको भिडियो",
               "पुरानो चलचित्र", "योगको भिडियो", "खाना बनाउने भिडियो",
               "प्रकृतिको भिडियो", "हास्य कार्यक्रमको भिडियो", "कृष्णको भजन",
               "म्युजिक भिडियो", "गीतको भिडियो", "मन्त्रको भिडियो",
               "डोकुमेन्ट्री", "यात्राको भिडियो", "स्वास्थ्यको भिडियो",
               "खेतीको भिडियो", "मौसमको समाचार", "चलचित्रको गीत",
               "बालबालिकाको भिडियो", "पुरानो गीतको भिडियो", "दसैँको भिडियो",
               "तिहारको भिडियो", "पूजाको भिडियो", "शिक्षाको भिडियो",
               "नृत्यको भिडियो", "हिमालको भिडियो", "नदीको भिडियो",
               "चराको भिडियो", "पशुको भिडियो", "प्रवचनको भिडियो"]
VIDEO_VERBS = ["देखाउ", "देखाउनुस्", "लगाउ", "लगाउनुहोस्", "हेर्नुस्",
               "खोल्नुस्", "सुनाउनुस्", "चलाउनुस्"]
VIDEO_PLACE = ["", "युट्युबमा ", "टिभीमा ", "मोबाइलमा ", "फोनमा ", "ल्यापटपमा "]
VIDEO_ITEMS_LAT = ["bhajan ko video", "purano nepali video", "nepali news",
                   "purano chalachitra", "yoga ko video", "khana banaune video",
                   "prakriti ko video", "hasya karyakram", "krishna ko bhajan",
                   "music video", "geet ko video", "swasthya ko video",
                   "kheti ko video", "himal ko video"]
VIDEO_VERBS_LAT = ["dekhau", "dekhau nus", "lagau", "lagau nus", "hernus", "kholnus"]
VIDEO_PLACE_LAT = ["", "youtube ma ", "tv ma ", "mobile ma ", "phone ma "]
# CS: devanagari items x latin verbs — mixed scripts by construction.
VIDEO_ITEMS_CS = ["भजनको भिडियो", "पुरानो नेपाली भिडियो", "योगको भिडियो",
                  "मन्त्रको भिडियो", "गीतको भिडियो", "प्रकृतिको भिडियो",
                  "समाचारको भिडियो", "हास्य कार्यक्रम", "म्युजिक भिडियो",
                  "चलचित्रको गीत", "पूजाको भिडियो", "खेतीको भिडियो"]
VIDEO_VERBS_CS = ["dekhau", "dekhau nus", "lagau", "lagau nus", "hernus", "kholnus"]

# ---------------------------------------------------------------------------
# Shapes per action
# ---------------------------------------------------------------------------

SHAPES: dict[str, dict[str, list]] = {}


def _register(action: str, register: str, shapes: list) -> None:
    SHAPES.setdefault(action, {})[register] = shapes


_register("call", "devanagari", CALL_SHAPES_DEV)
_register("call", "latin", CALL_SHAPES_LAT)
_register("call", "code_switched", CALL_SHAPES_CS)

_register("emergency", "devanagari", EMERGENCY_SHAPES_DEV)
_register("emergency", "latin", EMERGENCY_SHAPES_LAT)
_register("emergency", "code_switched", EMERGENCY_SHAPES_CS)

_register("health_query", "devanagari",
          [S(t, {}, [("s", HQ_SUBJECTS)], "calm health question") for t in HQ_TAILS])
_register("health_query", "latin",
          [S(t, {}, [("s", HQ_SUBJECTS_LAT)], "romanized calm question") for t in HQ_TAILS_LAT])
_register("health_query", "code_switched",
          [S(t, {}, [("s", HQ_SUBJECTS)], "code-switched calm question") for t in HQ_TAILS_CS])

_register("ack_med", "devanagari",
          [S("{scope}[medication:{m}] {v}", {"medication": "{m}"},
             [("scope", ACK_SCOPES), ("m", MEDS), ("v", ACK_VERBS)], "dose acknowledgement"),
           S("[medication:{m}] {v} नि", {"medication": "{m}"},
             [("m", MEDS), ("v", ACK_VERBS)], "ack + particle"),
           S("मैले [medication:{m}] {v}", {"medication": "{m}"},
             [("m", MEDS), ("v", ACK_VERBS)], "explicit subject")])
_register("ack_med", "latin",
          [S("{scope}[medication:{m}] {v}", {"medication": "{m}"},
             [("scope", ACK_SCOPES_LAT), ("m", MEDS_LAT), ("v", ACK_VERBS_LAT)],
             "romanized acknowledgement"),
           S("maile [medication:{m}] {v}", {"medication": "{m}"},
             [("m", MEDS_LAT), ("v", ACK_VERBS_LAT)], "romanized explicit subject")])
_register("ack_med", "code_switched",
          [S("[medication:{m}] {v}", {"medication": "{m}"},
             [("m", MEDS), ("v", ACK_VERBS_CS)], "code-switched acknowledgement"),
           S("[medication:{m}] khaisake", {"medication": "{m}"},
             [("m", MEDS)], "code-switched completive")])

_register("set_reminder", "devanagari",
          [S("[time:{time}] [medication:{med}] खान {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_DEV), ("med", MEDS), ("rv", REMIND_VERBS)], "medication reminder"),
           S("[time:{time}] {act} {rv}", {"time": "{time}", "medication": None},
             [("time", TIMES_DEV), ("act", ACTIVITIES), ("rv", REMIND_VERBS)], "activity reminder"),
           S("हरेक दिन [time:{time}] [medication:{med}] खान {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_DEV), ("med", MEDS), ("rv", REMIND_VERBS)], "recurring daily"),
           S("[time:{time}] मलाई सम्झना गराउनुहोस्", {"time": "{time}", "medication": None},
             [("time", TIMES_DEV)], "generic reminder, no medication"),
           S("मलाई [time:{time}] [medication:{med}] खान {rv} भन्नु",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_DEV), ("med", MEDS), ("rv", REMIND_VERBS)], "quoted instruction")])
_register("set_reminder", "latin",
          [S("[time:{time}] [medication:{med}] khana {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_LAT), ("med", MEDS_LAT), ("rv", REMIND_VERBS_LAT)],
             "romanized reminder"),
           S("[time:{time}] {act} {rv}", {"time": "{time}", "medication": None},
             [("time", TIMES_LAT), ("act", ACTIVITIES_LAT), ("rv", REMIND_VERBS_LAT)],
             "romanized activity reminder"),
           S("harek din [time:{time}] [medication:{med}] khana {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_LAT), ("med", MEDS_LAT), ("rv", REMIND_VERBS_LAT)],
             "romanized recurring")])
_register("set_reminder", "code_switched",
          [S("[time:{time}] [medication:{med}] खान {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_CS), ("med", MEDS), ("rv", REMIND_VERBS_CS)],
             "code-switched reminder"),
           S("[time:{time}] [medication:{med}] khana {rv}",
             {"time": "{time}", "medication": "{med}"},
             [("time", TIMES_LAT), ("med", MEDS), ("rv", REMIND_VERBS_CS)],
             "code-switched latin reminder")])

_register("send_message", "devanagari",
          [S("[contact:{c}लाई] [message:{b}] भनेर {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS), ("b", MESSAGE_BODIES), ("mv", MSG_VERBS)], "dictated body"),
           S("[contact:{c}लाई] {mv}", {"contact": "{c}", "message": None},
             [("c", CONTACTS), ("mv", MSG_VERBS)], "no body dictated"),
           S("[contact:{c} लाई] [message:{b}] भनेर {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS), ("b", MESSAGE_BODIES), ("mv", MSG_VERBS)],
             "particle as its own word"),
           S("[message:{b}] भनेर [contact:{c}लाई] {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS), ("b", MESSAGE_BODIES), ("mv", MSG_VERBS)], "body first")])
_register("send_message", "latin",
          [S("[contact:{c}] lai [message:{b}] bhanera {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS_LAT), ("b", MESSAGE_BODIES_LAT), ("mv", MSG_VERBS_LAT)],
             "romanized dictated body"),
           S("[contact:{c}] lai {mv}", {"contact": "{c}", "message": None},
             [("c", CONTACTS_LAT), ("mv", MSG_VERBS_LAT)], "romanized, no body")])
_register("send_message", "code_switched",
          [S("[contact:{c}] lai '[message:{b}]' bhanera {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS_LAT), ("b", MESSAGE_BODIES_CS), ("mv", MSG_VERBS_CS)],
             "code-switched dictated body"),
           S("[contact:{c}लाई] [message:{b}] भनेर {mv}",
             {"contact": "{c}", "message": "{b}"},
             [("c", CONTACTS), ("b", MESSAGE_BODIES_CS), ("mv", MSG_VERBS_CS)],
             "code-switched body")])

_register("music", "devanagari",
          [S("{pre}{item} {v}", {}, [("pre", [""] + MUSIC_PREFIX),
                                       ("item", MUSIC_ITEMS),
                                       ("v", MUSIC_VERBS)], "play request"),
           S("{item} {v} न", {}, [("item", MUSIC_ITEMS), ("v", MUSIC_VERBS)],
             "play request + particle"),
           S("मलाई {item} {v} मन पर्छ", {}, [("item", MUSIC_ITEMS),
                                               ("v", MUSIC_VERBS[:3])],
             "preference framing")])
_register("music", "latin",
          [S("{pre}{item} {v}", {}, [("pre", MUSIC_PREFIX_LAT),
                                       ("item", MUSIC_ITEMS_LAT),
                                       ("v", MUSIC_VERBS_LAT)], "romanized play request")])
_register("music", "code_switched",
          [S("{item} {v}", {}, [("item", MUSIC_ITEMS_CS), ("v", MUSIC_VERBS_CS)],
             "code-switched play request"),
           S("{pre}{item} {v}", {}, [("pre", MUSIC_PREFIX_LAT),
                                       ("item", MUSIC_ITEMS_CS),
                                       ("v", MUSIC_VERBS_CS)],
             "code-switched prefixed play request"),
           S("{item} {v} न", {}, [("item", MUSIC_ITEMS_CS), ("v", MUSIC_VERBS_CS)],
             "code-switched play request + particle")])

_register("guide", "devanagari",
          [S(t, {"topic": "{t}"}, [("t", GUIDE_TOPICS)], "how-to") for t in GUIDE_TAILS])
_register("guide", "latin",
          [S(t, {"topic": "{t}"}, [("t", GUIDE_TOPICS_LAT)], "romanized how-to")
           for t in GUIDE_TAILS_LAT])
_register("guide", "code_switched",
          [S(t, {"topic": "{t}"}, [("t", GUIDE_TOPICS_CS_DEV)],
             "code-switched how-to (devanagari topic)")
           for t in GUIDE_TAILS_CS_LAT]
          + [S(t, {"topic": "{t}"}, [("t", GUIDE_TOPICS_CS_LAT)],
               "code-switched how-to (latin topic)")
             for t in GUIDE_TAILS_CS_DEV])

_register("query", "devanagari",
          [S(t, {}, [("s", QUERY_FACTS)], "factual question") for t in QUERY_TAILS]
          + [S(t, {}, [("d", QUERY_DAYS)], "date question") for t in QUERY_DAY_TAILS]
          + [S(t, {}, [("f", QUERY_FESTS)], "festival question") for t in QUERY_FEST_TAILS]
          + [S("{a} देखि {b} कति टाढा छ", {}, [("a", QUERY_PLACES), ("b", QUERY_PLACES_TO)],
               "distance question")]
          + [S("{a} बाट {b} जान कति समय लाग्छ", {},
               [("a", QUERY_PLACES), ("b", QUERY_PLACES_TO)], "travel-time question")]
          + [S(q, {}, [], "time/date question") for q in QUERY_TIME_QS]
          + [S(q, {}, [], "weather/small factual question") for q in QUERY_MISC])
_register("query", "latin",
          [S(q, {}, [], "romanized question") for q in QUERY_MISC_LAT]
          + [S(t, {}, [("s", QUERY_FACTS_LAT)], "romanized factual question")
             for t in QUERY_TAILS_LAT]
          + [S("aaja ke din ho", {}, [], "romanized date question"),
             S("bholi mausam kasto hunchha", {}, [], "romanized weather question"),
             S("nepal ma kati jilla chhan", {}, [], "romanized count question"),
             S("kathmandu dekhi pokhara kati tadha chha", {}, [], "romanized distance"),
             S("ahiile kati bajyo", {}, [], "romanized time question"),
             S("aaja kati gate ho", {}, [], "romanized date question"),
             S("bholi bida chha ki", {}, [], "romanized date question"),
             S("yo hapta pani parchha", {}, [], "romanized weather question")])
_register("query", "code_switched",
          [S("aaja ko मौसम कस्तो छ", {}, [], "code-switched weather")]
          + [S(t, {}, [("s", QUERY_FACTS)], "code-switched factual question")
             for t in QUERY_TAILS_CS]
          + [S("नेपालको capital कहाँ हो", {}, [], "code-switched factual"),
             S("aaja ke दिन हो", {}, [], "code-switched date"),
             S("ahiile kati बज्यो", {}, [], "code-switched time"),
             S("nepal ko राजधानी kaha ho", {}, [], "code-switched factual"),
             S("भोलि weather kasto hunchha", {}, [], "code-switched weather"),
             S("yo हप्ता pani parchha ki", {}, [], "code-switched weather")])

_register("none", "devanagari",
          [S("{d} {p}", {}, [("d", NONE_TOPICS), ("p", NONE_PREDICATES)], "chit-chat"),
           S("{d} {p} नि", {}, [("d", NONE_TOPICS), ("p", NONE_PREDICATES)], "chit-chat + particle")]
          + [S(q, {}, [], "small talk") for q in NONE_TALK]
          + [S("{r}{tail}", {}, [("r", NONE_REFUSALS), ("tail", NONE_REFUSAL_TAILS)],
               "refusal/deferral — must abstain")]
          + [S(q, {}, [], "fragment") for q in NONE_FRAGMENTS])
_register("none", "latin",
          [S(q, {}, [], "romanized small talk") for q in NONE_TALK_LAT]
          + [S(q, {}, [], "romanized fragment") for q in NONE_FRAGMENTS_LAT]
          + [S("aushadhi khayena", {}, [], "romanized refusal"),
             S("haina, aushadhi khayeko chhaina", {}, [], "romanized refusal"),
             S("pachhi khanchhu", {}, [], "romanized deferral"),
             S("aushadhi chahidaina", {}, [], "romanized refusal"),
             S("khana mann lagena", {}, [], "romanized refusal")])
_register("none", "code_switched",
          [S(q, {}, [], "code-switched chit-chat") for q in [
              "आज mood राम्रो छ", "aaja गर्मी छ", "आज मन ramro छ",
              "bihana हावा ramro छ", "आज बजार gayeko thiye",
              "chhimekiko छोरी को bihe bhayo", "khet मा काम भयो",
              "आज शान्त din छ", "yo गाउँ ramro छ", "मौसम ramro भयो"]]
          + [S(q, {}, [], "code-switched refusal/deferral") for q in [
              "aushadhi खाइनँ", "aushadhi khayeko छैन", "pachhi खान्छु",
              "आज nakhane भनें", "aushadhi चाहिँदैन", "भोलि khanchhu"]]
          + [S(q, {}, [], "code-switched fragment") for q in [
              "khai, थाहा भएन", "haina haina, त्यो होइन", "la aba के भन्ने",
              "ekchhin रुक", "thaha भएन", "के bhaneko thiye"]])

_register("create_calendar_event", "devanagari",
          [S("[time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_DEV), ("ev", CAL_EVENTS), ("cv", CAL_VERBS)], "appointment"),
           S("[time:{time}] {ev} को कार्यक्रम {cv}", {"time": "{time}"},
             [("time", TIMES_DEV), ("ev", CAL_EVENTS), ("cv", CAL_VERBS[:3])],
             "programme wording"),
           S("क्यालेन्डरमा [time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_DEV), ("ev", CAL_EVENTS), ("cv", CAL_VERBS[:3])],
             "calendar-explicit"),
           S("आउँदो हप्ता [time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_DEV[:200]), ("ev", CAL_EVENTS), ("cv", CAL_VERBS[:3])],
             "next-week framing")])
_register("create_calendar_event", "latin",
          [S("[time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_LAT), ("ev", CAL_EVENTS_LAT), ("cv", CAL_VERBS_LAT)],
             "romanized appointment"),
           S("calendar ma [time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_LAT), ("ev", CAL_EVENTS_LAT), ("cv", CAL_VERBS_LAT)],
             "romanized calendar-explicit")])
_register("create_calendar_event", "code_switched",
          [S("[time:{time}] {ev} {cv}", {"time": "{time}"},
             [("time", TIMES_CS[:250]), ("ev", CAL_EVENTS_CS), ("cv", CAL_VERBS_CS)],
             "code-switched appointment"),
           S("[time:{time}] meeting rakha", {"time": "{time}"},
             [("time", TIMES_CS[:250])], "code-switched meeting")])

_register("suggest_video", "devanagari",
          [S("{pre}{item} {v}", {}, [("pre", VIDEO_PLACE), ("item", VIDEO_ITEMS),
                                       ("v", VIDEO_VERBS)], "video request")])
_register("suggest_video", "latin",
          [S("{pre}{item} {v}", {}, [("pre", VIDEO_PLACE_LAT), ("item", VIDEO_ITEMS_LAT),
                                       ("v", VIDEO_VERBS_LAT)], "romanized video request")])
_register("suggest_video", "code_switched",
          [S("{pre}{item} {v}", {}, [("pre", VIDEO_PLACE_LAT), ("item", VIDEO_ITEMS_CS),
                                       ("v", VIDEO_VERBS_CS)], "code-switched video request"),
           S("{item} {v} न", {}, [("item", VIDEO_ITEMS_CS), ("v", VIDEO_VERBS_CS)],
             "code-switched video request + particle")])


# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

def _render_spec(action: str, register: str, shape: dict, index: int) -> dict:
    fillers = _decode(shape["dims"], index)
    utterance, spans = render(shape["t"], fillers)
    slots = {key: _slot(value, fillers) for key, value in shape["slots"].items()}
    return {"script": register, "intent": action, "utterance": utterance,
            "slots": slots, "spans": spans, "shape": shape["note"]}


def _action_stream(action: str, need: int) -> tuple[list[dict], int]:
    """Deterministic, duplicate-free candidate stream for one action.

    Shapes are consumed round-robin from a rotating register cycle; a shape
    that has exhausted its Cartesian product drops out of the rotation. No RNG:
    every candidate is a pure function of the draw index."""
    reg_shapes = SHAPES[action]
    state = {}
    for register in REGISTERS:
        shapes = reg_shapes.get(register) or []
        caps = [_capacity(s) for s in shapes]
        state[register] = {"shapes": shapes, "caps": caps,
                           "next": [0] * len(shapes),
                           "active": [i for i, c in enumerate(caps) if c],
                           "ptr": 0}
    out: list[dict] = []
    seen: set[str] = set()
    refused = 0
    draws = 0
    limit = need * MAX_DRAWS_PER_ROW + 1000
    while len(out) < need:
        draws += 1
        if draws > limit:
            raise SystemExit(
                f"[batches] capacity exhausted for {action}: {len(out)} distinct rows "
                f"from shape banks, {need} needed (widen a bank in "
                f"golden_corpus_batches.py)")
        register = REGISTER_CYCLE[(draws + REGISTER_SALT[action]) % len(REGISTER_CYCLE)]
        st = state[register]
        if not st["active"]:
            continue
        i = st["active"][st["ptr"] % len(st["active"])]
        st["ptr"] += 1
        index = st["next"][i]
        st["next"][i] += 1
        if index >= st["caps"][i]:
            st["active"].remove(i)
            continue
        spec = _render_spec(action, register, st["shapes"][i], index)
        key = normalize(spec["utterance"])
        if key in seen:
            refused += 1
            continue
        seen.add(key)
        out.append(spec)
    return out, refused


# ---------------------------------------------------------------------------
# Training-source proxy (conservative overlap refusal)
# ---------------------------------------------------------------------------

_MESSAGE_FILLER_BANK = ["आज भेट्नुहोस्", "भोलि आउनु", "म ठीक छु"]


def training_source_proxy() -> set[str]:
    """Normalized utterances the training build can produce verbatim.

    seeds/intents.yaml templates are what gen_teacher.py expands, so an exact
    instantiation of one of them is a row build_dataset.py's leak guard would
    refuse at build time. This is a PROXY (paraphrases are unknowable here) and
    deliberately over-inclusive: refusing a candidate costs one draw, a
    collision costs a training row."""
    import yaml  # local import: the authoring path stays importable without it

    with open(ROOT / "seeds" / "intents.yaml", encoding="utf-8") as f:
        seeds = yaml.safe_load(f) or {}
    banks = seeds.get("entity_banks") or {}
    keymap = {"contact": "contact_names", "contact_latin": "contact_names_latin",
              "app": "apps", "time": "times", "medication": "medications",
              "bhajan": "bhajans", "appliance": "appliances"}
    out: set[str] = set()
    for spec in (seeds.get("intents") or {}).values():
        for template in spec.get("templates") or []:
            keys = list(dict.fromkeys(re.findall(r"\{(\w+)\}", template)))
            banks_for = []
            usable = True
            for key in keys:
                if key == "message":
                    banks_for.append(_MESSAGE_FILLER_BANK)
                elif key in keymap and keymap[key] in banks:
                    banks_for.append(banks[keymap[key]])
                else:
                    usable = False
                    break
            if not usable:
                continue
            for combo in itertools.product(*banks_for):
                out.add(normalize(template.format(**dict(zip(keys, combo)))))
    for spec in (seeds.get("edge_classes") or {}).values():
        for template in spec.get("templates") or []:
            out.add(normalize(template))
    return out


# ---------------------------------------------------------------------------
# Batches
# ---------------------------------------------------------------------------

def test_fixture_keys() -> set[str]:
    """Normalized utterances the encoder-pipeline test fixture uses.

    tests/fixtures.py is a synthetic TRAINING-shaped corpus: the leak guard
    refuses any row whose utterance collides with the golden corpus, and
    test_build_encoder_dataset.py pins `leak == 0` for it — a collision would
    silently empty the builder tests. Those 40 rows are spoken for, exactly
    like the near-miss set, so the generator refuses them too."""
    sys.path.insert(0, str(ROOT / "tests"))
    import fixtures  # noqa: PLC0415 (path set just above)

    return {normalize(r["utterance"]) for r in fixtures.all_rows()}


def generated_specs(existing_rows: list[dict], reserved_rows: list[dict],
                    upto: int | None = None) -> tuple[list[dict], dict]:
    """The generated section, batch block by batch block.

    The corpus is ALWAYS partitioned into `N_BATCHES` blocks; `upto` only
    decides how many blocks are emitted. That makes every intermediate corpus a
    literal prefix of the full one — the shas a per-batch manifest records stay
    valid whether the batches were generated in one run or twelve, so stopping
    after any block leaves a corpus that is still valid, still checkable and
    still reversible (drop the last block, or author one more).

    Returns (specs, report). `specs` are ordered batch 1 ... batch `upto`, and
    within a batch by ORDER; each spec carries the id it was assigned."""
    reserved = {normalize(r["utterance"]) for r in existing_rows}
    reserved |= {normalize(r["utterance"]) for r in reserved_rows}
    proxy = training_source_proxy()
    fixtures = test_fixture_keys()
    reserved |= proxy | fixtures

    seen = {normalize(r["utterance"]) for r in existing_rows}
    per_action: dict[str, list[dict]] = {}
    report = {"proxy_keys": len(proxy), "fixture_keys": len(fixtures),
              "reserved_keys": len(reserved), "actions": {}, "batches": []}
    for action in ORDER:
        have = sum(1 for r in existing_rows if r["intent"] == action)
        need = QUOTA[action] - have
        if need < 0:
            raise SystemExit(f"[batches] {action} already has {have} rows, quota is "
                             f"{QUOTA[action]} — the quota table is wrong")
        candidates, dup_refused = _action_stream(action, need + MARGIN)
        kept, refused_reserved = [], 0
        for spec in candidates:
            if len(kept) == need:
                break
            key = normalize(spec["utterance"])
            if key in reserved or key in seen:
                refused_reserved += 1
                continue
            seen.add(key)
            kept.append(spec)
        if len(kept) < need:
            raise SystemExit(f"[batches] {action}: {len(kept)} usable rows, {need} needed "
                             "after the held-out refusals — widen the shape banks")
        per_action[action] = kept
        report["actions"][action] = {
            "quota": QUOTA[action], "hand": have, "generated": len(kept),
            "refused_held_out": refused_reserved, "refused_intra_duplicate": dup_refused,
        }

    if upto is None:
        upto = N_BATCHES
    if not 1 <= upto <= N_BATCHES:
        raise SystemExit(f"[batches] --batches must be 1..{N_BATCHES}, got {upto}")
    specs: list[dict] = []
    for batch in range(N_BATCHES):
        counts: dict[str, int] = {}
        block: list[dict] = []
        for action in ORDER:
            rows = per_action[action]
            n = len(rows)
            lo = (n * batch) // N_BATCHES
            hi = (n * (batch + 1)) // N_BATCHES
            for seq, spec in enumerate(rows[lo:hi], start=1):
                spec = dict(spec)
                spec["id"] = f"gc-b{batch + 1:02d}-{FAMILY[action]}-{seq:04d}"
                spec["batch"] = batch + 1
                block.append(spec)
            counts[action] = hi - lo
        report["batches"].append({"batch": batch + 1, "rows": len(block),
                                  "actions": counts, "emitted": batch < upto})
        if batch < upto:
            specs.extend(block)
    report["generated_rows"] = len(specs)
    report["total_rows"] = len(existing_rows) + len(specs)
    return specs, report


# ---------------------------------------------------------------------------
# Self-check CLI
# ---------------------------------------------------------------------------

def _selftest() -> int:
    failures = []
    for action in ORDER:
        for register, shapes in SHAPES[action].items():
            for si, shape in enumerate(shapes):
                for index in (0, 1, _capacity(shape) - 1):
                    if index < 0:
                        continue
                    spec = _render_spec(action, register, shape, index)
                    utt = spec["utterance"]
                    tag = f"{action}/{register}/shape{si}"
                    if "{" in utt or "}" in utt:
                        failures.append(f"{tag}: unrendered template artefact in {utt!r}")
                    has_dev = any("ऀ" <= ch <= "ॿ" for ch in utt)
                    has_lat = bool(re.search(r"[A-Za-z]", utt))
                    if register == "devanagari" and has_lat:
                        failures.append(f"{tag}: latin letters in a devanagari row {utt!r}")
                    if register == "latin" and has_dev:
                        failures.append(f"{tag}: devanagari in a latin row {utt!r}")
                    if register == "code_switched" and not (has_dev and has_lat):
                        failures.append(f"{tag}: code_switched row is single-script {utt!r}")
                    for label, text, _occ in spec["spans"]:
                        if not text or text not in utt:
                            failures.append(f"{tag}: span {label} {text!r} not in {utt!r}")
                    if len(utt.split()) > 20:
                        failures.append(f"{tag}: {len(utt.split())}-word utterance {utt!r}")
    import json
    hand_counts: dict[str, int] = {}
    corpus_path = EVAL_DIR / "golden_corpus.jsonl"
    with open(corpus_path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec["id"].startswith("gc-b"):     # generated block, not hand section
                continue
            hand_counts[rec["intent"]] = hand_counts.get(rec["intent"], 0) + 1
    for action in ORDER:
        capacity = sum(_capacity(s) for shapes in SHAPES[action].values()
                       for s in shapes)
        hand = hand_counts.get(action, 0)
        needed = QUOTA[action] - hand + MARGIN
        status = "ok" if capacity >= needed else "SHORT"
        print(f"[capacity] {action:22s} quota {QUOTA[action]:4d} hand {hand:3d} "
              f"generated {QUOTA[action] - hand:4d} + margin {MARGIN} = {needed:4d} "
              f"| shape capacity {capacity:6d}  {status}")
        if capacity < needed:
            failures.append(f"{action}: capacity {capacity} < {needed}")
    for line in failures:
        print(f"[selftest] FAIL {line}")
    print(f"[selftest] {len(failures)} failure(s)")
    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--selftest", action="store_true",
                        help="render every shape and check the register/span rules")
    parser.add_argument("--plan", action="store_true",
                        help="print per-action quotas and batch shapes")
    args = parser.parse_args()
    if args.plan:
        print(f"corpus floor {CORPUS_FLOOR}, {N_BATCHES} batches, "
              f"quota = {QUOTA_SCALE} x taxonomy target")
        for action in ORDER:
            print(f"  {action:22s} target {TAXONOMY_TARGETS[action]:5d} "
                  f"quota {QUOTA[action]:5d}")
        print(f"  {'TOTAL':22s} {'':12s} {sum(QUOTA.values()):5d}")
        for batch in range(N_BATCHES):
            sizes = []
            for action in ORDER:
                n = QUOTA[action]
                sizes.append((n * (batch + 1)) // N_BATCHES - (n * batch) // N_BATCHES)
            print(f"  batch {batch + 1:02d}: {sum(sizes)} rows")
        return
    if args.selftest:
        sys.exit(_selftest())
    parser.error("one of --selftest / --plan is required")


if __name__ == "__main__":
    main()
