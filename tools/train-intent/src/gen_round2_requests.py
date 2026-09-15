"""Round-2 teacher request-list generator (ENCODER QUALITY ROUND-2, CPU-side).

Emits the REQUEST LIST consumed by the free local teacher — `gen_distill.py`
(the llama.cpp teacher runner) or any runner that speaks the same request
schema. One request = one (seed utterance, register, n-variants) job; the
teacher writes n labelled `intent/v2` rows for it.

Two recipes, from the v4 error analysis (see
docs/superpowers/specs/2026-09-15-round2-quality-campaign-plan.md):

  (a) EMERGENCY COVERAGE — additional emergency surface forms for the classes
      the error analysis flagged as coverage regressions (bare symptom,
      third-person collapse, urgency verbs, fall/inability, bleeding, breathing
      /cardiac, fear/safety, fragmented), authored to be DISTINCT from the
      golden corpus (revision 7f71b8ae) and from the held-out adversarial
      near-miss set.
  (b) CONFUSION PAIRS — contrastive rows for each pair the v4 error analysis
      named: create_calendar_event->set_reminder, guide breadth (plus its
      `query` boundary), health_query advice phrasings (plus the emergency
      boundary), ack_med declaratives (plus the refusal and missed-dose
      boundaries), suggest_video->music. Both sides of every pair are
      generated from matched frames so the discriminating cue — never the
      frame — is what differs.

Distinctness is enforced by construction, not asserted: every candidate seed is
dropped when its `build_dataset.normalize()` form is present in the golden
corpus OR the near-miss set (both held out; both are §10 gates). The dropped
count is reported.

Guards (reused by import, never copied):
  - `pipeline_guards.GOLDEN_CORPUS` / `golden_keys` / `write_json`
  - `build_dataset.load_golden_keys` / `normalize`
  - `encoder_rules.load_rules` (taxonomy, span labels, edge bands)

CPU-only, torch-free, network-free. No PII: the request list carries synthetic
seeds and counters only.

Outputs (defaults, all overridable):
  data/round2/round2_requests.jsonl   the request list
  data/round2/round2_requests_report.json  quota table + guard counters

Exit codes: 0 ok, 2 usage, 3 refused (a held-out file is missing, or a quota
cannot be met because too many seeds collided with the held-out sets).
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_dataset import load_golden_keys, normalize  # noqa: E402
from encoder_rules import load_rules  # noqa: E402
from pipeline_guards import (EXIT_GUARD, EXIT_OK, EXIT_USAGE, GOLDEN_CORPUS,  # noqa: E402
                             GuardError, golden_keys, utc_now, write_json)

ROOT = Path(__file__).resolve().parent.parent
NEARMISS = ROOT / "eval" / "emergency_nearmiss.jsonl"
SEEDS = ROOT / "seeds" / "intents.yaml"

# id convention: r2-<class>-<reg3>-<serial>; the STT-noise stage appends
# ":noise<n>" (stt_noise.py), so the class stays recoverable on noised rows.
REG3 = {"devanagari": "dev", "romanized": "rom", "code_switched": "cs",
        "elder_fragmented": "frag"}

# Register mix for the round-2 authoring. Derived from the clean-bucket split
# (mixture.targets: clean_devanagari 0.25 / romanized_codeswitched 0.15, and
# BUCKET_OF_REGISTER puts elder_fragmented on the Devanagari side), so the
# authored supply feeds both clean buckets in the ratio the build samples at:
#   devanagari 0.45 + elder_fragmented 0.17 = 0.62 of clean
#   romanized  0.22 + code_switched   0.16 = 0.38 of clean
REGISTER_WEIGHTS = {"devanagari": 45, "elder_fragmented": 17, "romanized": 22,
                    "code_switched": 16}

# Fillers used by the elder_fragmented transform (a SEED transform only — the
# teacher writes the final row; the transform exists so fragmented supply does
# not need a second hand-authored frame set).
FILLERS_HEAD = ["अँ", "त्यो", "के भनेको", "अनि"]
FILLERS_TAIL = ["अँ", "हो", "के भनेको थिएँ"]

# ---------------------------------------------------------------------------
# ASK: the authoring brief per class. `frames` are register-keyed seed frames;
# {slots} are filled from `slots`. `must_include`/`must_exclude` are the
# discriminating cues: the teacher sees them and the QA script re-checks them
# on the generated rows.
# ---------------------------------------------------------------------------

ASK: list[dict] = [
    # ---------------- (a) EMERGENCY COVERAGE ----------------
    {"class": "ec01", "family": "emergency_coverage", "intent": "emergency",
     "rows": 150, "title": "bare symptom, no plea",
     "why": "coverage: the corpus's emergency family is plea-anchored; a symptom "
            "stated alone must still fire",
     "must_include": [], "must_exclude": ["मद्दत", "बचाउ", "सहयोग", "help"],
     "slots": {"place": ["छाती", "टाउको", "पेट", "मुटु", "जिउ", "आँखा"],
               "verb": ["धेरै दुख्यो", "दुखिरहेको छ", "कस्सियो", "जल्यो"]},
     "frames": {
         "devanagari": ["{place} {verb}", "{place} निकै {verb}",
                        "आज {place} {verb}"],
         "romanized": ["{place_rom} {verb_rom}", "malai {place_rom} {verb_rom}"],
         "code_switched": ["{place} बाट pain भइरहेको छ", "{place} दुख्यो, very bad"]},
     "slots_rom": {"place_rom": ["chhati", "tauko", "pet", "mutu", "jyaan"],
                   "verb_rom": ["dukhyo", "dherai dukhyo", "kasiero"]}},

    {"class": "ec02", "family": "emergency_coverage", "intent": "emergency",
     "rows": 100, "title": "collapse of another person",
     "why": "coverage: third-person collapse is the family the corpus covers "
            "thinnest; the speaker is not the patient",
     "must_include": [], "must_exclude": [],
     "slots": {"person": ["आमा", "बुबा", "हजुरआमा", "हजुरबुबा", "दाइ", "दिदी"],
               "state": ["बेहोस भइन्", "लड्नुभयो", "उठ्न सकिनन्", "बोल्न सकिनन्",
                         "ढल्नुभयो"]},
     "frames": {
         "devanagari": ["{person} {state}", "{person} {state}, हेर्नुहोस्",
                        "हत्तार, {person} {state}"],
         "romanized": ["{person_rom} {state_rom}", "aama {state_rom}"],
         "code_switched": ["{person} unconscious भइन्", "dad {state_rom}, please"]},
     "slots_rom": {"person_rom": ["aama", "buwa", "hajurama", "dai", "didi"],
                   "state_rom": ["behos bhain", "ladnu bhayo", "uthna sakina"]}},

    {"class": "ec03", "family": "emergency_coverage", "intent": "emergency",
     "rows": 100, "title": "urgency / bring help",
     "why": "coverage: urgency verbs without a symptom are still emergencies; "
            "the call verb is excluded on purpose (that is `call`'s boundary)",
     "must_include": [], "must_exclude": ["फोन", "कल", "call", "phone"],
     "slots": {"noun": ["एम्बुलेन्स", "डाक्टर", "प्रहरी", "छिमेकी", "डाक्टरजी",
                        "हेल्पर", "गाउँका मान्छे"],
               "verb": ["बोलाउनुहोस्", "ल्याउनुहोस्", "खोज्नुहोस्", "पठाउनुहोस्"]},
     "frames": {
         "devanagari": ["{noun} {verb}", "हतार गर्नुहोस्, {noun} {verb}",
                        "तुरुन्तै {noun} {verb}", "ढिलो नगर्नुहोस्, {noun} {verb}"],
         "romanized": ["{noun_rom} {verb_rom}", "hatar garnus, {noun_rom} {verb_rom}",
                       "turuntai {noun_rom} {verb_rom}"],
         "code_switched": ["{noun} {verb_rom} please, urgent छ",
                           "{noun_rom} {verb_rom} fast"]},
     "slots_rom": {"noun_rom": ["ambulance", "doctor", "police", "chhimeki", "helper"],
                   "verb_rom": ["bolau", "lyaunu", "khojnus", "pathau"]}},

    {"class": "ec04", "family": "emergency_coverage", "intent": "emergency",
     "rows": 120, "title": "fall / inability to move",
     "why": "coverage: fall+inability is a high-frequency real-world emergency "
            "that the corpus carries in only a few surface forms",
     "must_include": [], "must_exclude": [],
     "slots": {"limb": ["खुट्टा", "हात", "कम्मर"], "verb": ["चल्दैन", "सक्दिन", "भाँच्चियो"]},
     "frames": {
         "devanagari": ["म लडेँ, {limb} {verb}", "{limb} {verb}, उठ्न सकिनँ",
                        "भुइँमा लडेँ, {limb} दुख्यो"],
         "romanized": ["ma lade, {limb_rom} {verb_rom}", "uthna sakdina",
                       "{limb_rom} {verb_rom}, ubhina sakdina"],
         "code_switched": ["म fell भएँ, {limb} दुख्यो",
                           "{limb} can't move, fell भएँ",
                           "{limb} भाँच्चियो, can't get up"]},
     "slots_rom": {"limb_rom": ["khutta", "haat", "kammar"],
                   "verb_rom": ["chaldaina", "sakdina", "bhachhiyo"]}},

    {"class": "ec05", "family": "emergency_coverage", "intent": "emergency",
     "rows": 80, "title": "bleeding / burn / injury",
     "why": "coverage: injury states with visible blood loss",
     "must_include": [], "must_exclude": [],
     "slots": {"site": ["हात", "खुट्टा", "टाउको", "औंला", "निधार", "कुहिनो"]},
     "frames": {
         "devanagari": ["{site} काटियो, रगत बगिरहेको छ", "रगत बगिरहेको छ, {site} जल्यो",
                        "{site} धेरै चोट लाग्यो", "{site} बाट रगत आइरहेको छ"],
         "romanized": ["{site_rom} katiyo, ragat bagiraheko chha", "jyaan jalyo",
                       "{site_rom} bata ragat aaairaheko chha", "{site_rom} jalyo"],
         "code_switched": ["{site} cut भयो, bleeding भइरहेको छ",
                           "{site} injured भयो, blood आइरहेको छ"]},
     "slots_rom": {"site_rom": ["haat", "khutta", "tauko", "aunla", "nidhar", "kuhino"]}},

    {"class": "ec06", "family": "emergency_coverage", "intent": "emergency",
     "rows": 120, "title": "breathing / chest / heart",
     "why": "coverage: the cardio-respiratory family is the highest-consequence "
            "miss class; the corpus has few surface variants",
     "must_include": [], "must_exclude": [],
     "slots": {"state": ["सास फेर्न गाह्रो भयो", "छाती कस्सियो", "मुटु ढुकढुक भयो",
                         "सास लिन सक्दिन", "छातीमा भारी भयो", "मुटु दुख्यो",
                         "सास फेर्दा दुख्छ"],
               "when": ["अचानक", "अहिले", "बिहानदेखि", "भर्खर"]},
     "frames": {
         "devanagari": ["{state}", "{when} {state}", "{state}, निकै गाह्रो",
                        "{when} {state}, सास फेर्न गाह्रो"],
         "romanized": ["{state_rom}", "{when_rom} {state_rom}",
                       "saas ferna garo bhayo, {when_rom}"],
         "code_switched": ["{state}, can't breathe", "{state}, धेरै गाह्रो भयो"]},
     "slots_rom": {"state_rom": ["saas ferna garo bhayo", "chhati kassiyo",
                                 "mutu dhukdhuk bhayo", "saas lina sakdina",
                                 "chhati ma bhari bhayo"],
                   "when_rom": ["achanak", "ahile", "bihanadekhi"]}},

    {"class": "ec07", "family": "emergency_coverage", "intent": "emergency",
     "rows": 80, "title": "fear / threat / safety",
     "why": "coverage: safety fear is a legitimate emergency the corpus carries "
            "thinly (डर लागिरहेको छ is one hand row)",
     "must_include": [], "must_exclude": [],
     "slots": {"source": ["कोही ढोका ढकढकाउँदै छ", "एक्लै छु", "बाटोमा कोही पछ्याइरहेको छ",
                          "घरमा कोही छिर्यो", "कोही कराइरहेको छ", "बत्ती निभ्यो"],
               "feel": ["डर लागिरहेको छ", "आत्तिएको छु", "सुरक्षित लागिरहेको छैन"]},
     "frames": {
         "devanagari": ["मलाई {feel}, {source}", "{source}, {feel}",
                        "बचाउनुहोस्, {source}", "{source}, मलाई {feel}"],
         "romanized": ["malai {feel_rom}, {source_rom}", "bachaunus",
                       "{source_rom}, {feel_rom}"],
         "code_switched": ["{source}, I am scared", "{source}, {feel_rom}"]},
     "slots_rom": {"source_rom": ["kohi dhoka dhakdhakaudai chha", "eklai chhu",
                                  "kohi pachhyairaheko chha"],
                   "feel_rom": ["dar lagiraheko chha", "aattieko chhu",
                                "surakshit lagiraheko chhaina"]}},

    {"class": "ec08", "family": "emergency_coverage", "intent": "emergency",
     "rows": 150, "title": "fragmented / self-interrupting (elder_fragmented)",
     "why": "coverage: elderly speech arrives in fragments; a fragmented "
            "emergency must not fall into the abstain band",
     "must_include": [], "must_exclude": [],
     "slots": {"place": ["छाती", "टाउको", "पेट", "मुटु", "हात", "खुट्टा", "आँखा"],
               "sym": ["दुख्यो", "घुम्यो", "लठ्ठ भयो", "काम्न थाल्यो", "जल्यो"]},
     "frames": {
         "devanagari": ["{place}... अँ... दुख्यो", "म... मद्दत...",
                        "{place} दुख्यो... हो... धेरै", "{place}... {sym}... अँ",
                        "मलाई... {place}... {sym}...", "अँ... {place}... {sym}..."],
         "romanized": ["{place_rom}... {sym_rom}...", "ma... madat...",
                       "{place_rom}... dukhyo... ho... dherai"],
         "code_switched": ["{place}... pain... धेरै", "{place}... can't... अँ"]},
     "slots_rom": {"place_rom": ["chhati", "tauko", "pet", "mutu", "haat", "khutta"],
                   "sym_rom": ["dukhyo", "ghumyo", "lattho bhayo", "kamna thalyo"]}},

    # ---------------- (b) CONFUSION PAIRS ----------------
    {"class": "cp1a", "family": "confusion_pair", "pair": "create_calendar_event~set_reminder",
     "side": "create_calendar_event", "intent": "create_calendar_event",
     "rows": 120, "title": "event booked with a time — राख / मिलाउ",
     "why": "confusion: create_calendar_event->set_reminder; both carry a time "
            "span, so the model must key on the event verb, not the time",
     "must_include": [], "must_exclude": ["सम्झाउ", "सम्झना", "सम्झाइ", "samjha"],
     "slots": {"time": ["भोलि दिउँसो ३ बजे", "पर्सि बिहान ११ बजे", "आइतबार बिहान ९ बजे",
                        "सोमबार दिउँसो २ बजे"],
               "event": ["डाक्टरको अपोइन्टमेन्ट", "चेकअपको अपोइन्टमेन्ट", "भेटघाट",
                         "छोरीको घर जाने कार्यक्रम", "अस्पताल जाने अपोइन्टमेन्ट",
                         "बजार जाने कार्यक्रम"]},
     "frames": {
         "devanagari": ["{time} {event} राख", "{time} {event} मिलाउ",
                        "{time} {event} राखिदिनुहोस्"],
         "romanized": ["{time_rom} {event_rom} rakha", "{time_rom} appointment milau"],
         "code_switched": ["{time} {event} rakha", "{time} appointment राख"]},
     "slots_rom": {"time_rom": ["bholi diuso 3 baje", "parsi bihana 11 baje",
                                "aitabar bihana 9 baje", "sombar diuso 2 baje"],
                   "event_rom": ["doctor ko appointment", "checkup ko appointment",
                                 "bhetghat"]}},

    {"class": "cp1b", "family": "confusion_pair", "pair": "create_calendar_event~set_reminder",
     "side": "set_reminder", "intent": "set_reminder",
     "rows": 120, "title": "same time span, reminder verb — सम्झाउनु",
     "why": "confusion twin: matched frames to cp1a; only the cue verb differs",
     "must_include": ["सम्झा", "samjha", "samjhana"],
     "must_exclude": ["अपोइन्टमेन्ट", "कार्यक्रम", "appointment"],
     "slots": {"time": ["भोलि दिउँसो ३ बजे", "पर्सि बिहान ११ बजे", "आइतबार बिहान ९ बजे",
                        "सोमबार दिउँसो २ बजे"],
               "task": ["डाक्टरलाई फोन गर्न", "औषधि खान", "पानी खान", "बजार जान",
                        "छोरीलाई भेट्न", "प्रेसरको औषधि खान", "बिहानको औषधि खान"]},
     "frames": {
         "devanagari": ["{time} {task} सम्झाउनु", "{time} {task} सम्झाइदिनु",
                        "{time} मलाई सम्झना गराउनुहोस्", "{time} {task} सम्झाउनुहोस्"],
         "romanized": ["{time_rom} {task_rom} samjhaunu", "{time_rom} samjhana garaunu",
                       "{time_rom} {task_rom} samjhaidinu",
                       "{time_rom} malai samjhana garaunu"],
         "code_switched": ["{time} {task} samjhai dinus", "{time} {task_rom} samjhaidinu"]},
     "slots_rom": {"time_rom": ["bholi diuso 3 baje", "parsi bihana 11 baje",
                                "aitabar bihana 9 baje", "sombar diuso 2 baje"],
                   "task_rom": ["doctor lai phone garna", "ausadhi khana",
                                "pani khana", "bajar jana", "chhori lai bhetna"]}},

    {"class": "cp2a", "family": "confusion_pair", "pair": "guide~query",
     "side": "guide", "intent": "guide",
     "rows": 120, "title": "operating an appliance — कसरी चलाउने",
     "why": "confusion: guide breadth; the corpus's guide family is narrow, so "
            "eval rows outside it drift to query/none",
     "must_include": [], "must_exclude": ["कहाँ", "कति", "के हो"],
     "slots": {"appliance": ["माइक्रोवेभ", "वासिङ मेसिन", "डिशवासर", "फ्रिज", "गिजर",
                             "प्रेसर कुकर", "इन्डक्शन चुलो", "टिभी रिमोट", "मोबाइल चार्जर",
                             "वाइफाइ राउटर"]},
     "frames": {
         "devanagari": ["{appliance} कसरी चलाउने", "{appliance} मा के बटन थिच्ने",
                        "{appliance} कसरी मिलाउने", "{appliance} कसरी बनाउने"],
         "romanized": ["{appliance_rom} kasari chalaune", "{appliance_rom} kun button thichne"],
         "code_switched": ["{appliance} kasari start garne", "{appliance} कसरी on गर्ने"]},
     "slots_rom": {"appliance_rom": ["microwave", "washing machine", "dishwasher",
                                     "fridge", "geyser", "pressure cooker"]}},

    {"class": "cp2b", "family": "confusion_pair", "pair": "guide~query",
     "side": "query", "intent": "query",
     "rows": 40, "title": "general knowledge, no operation — the boundary",
     "why": "confusion twin: the same topic asked as a fact question is `query`, "
            "not `guide`",
     "must_include": [], "must_exclude": ["कसरी चलाउ", "कसरी बनाउ", "बटन"],
     "slots": {"topic": ["मौसम", "आजको दिन", "नेपालको राजधानी", "तिहार", "दशैं"]},
     "frames": {
         "devanagari": ["भोलि {topic} कस्तो हुन्छ", "आज {topic} के हो",
                        "{topic} कहाँ हुन्छ"],
         "romanized": ["bholi {topic_rom} kasto hunchha", "{topic_rom} kaha hunchha"],
         "code_switched": ["भोलि {topic} kasto hunchha"]},
     "slots_rom": {"topic_rom": ["mausam", "aaja ko din", "nepal ko rajdhani"]}},

    {"class": "cp3a", "family": "confusion_pair", "pair": "health_query~emergency",
     "side": "health_query", "intent": "health_query",
     "rows": 140, "title": "calm advice question, pain allowed, no plea",
     "why": "confusion: health_query advice phrasings — the calm half of the "
            "boundary pair; the pain mention must NOT fire emergency",
     "must_include": [], "must_exclude": ["मद्दत", "बचाउ", "सहयोग", "help"],
     "slots": {"symptom": ["रक्तचाप", "सुगर", "मिर्गौला दुख्दा", "टाउको दुख्दा",
                           "ज्वरो आउँदा", "पेट दुख्दा"],
               "ask": ["के गर्नुपर्छ", "के खानु हुन्न", "कति हुँदा ठीक हुन्छ",
                       "कुन औषधि खाने", "के गर्ने"]},
     "frames": {
         "devanagari": ["{symptom} {ask}", "मेरो {symptom} {ask}",
                        "{ask} भने के गर्ने, {symptom}"],
         "romanized": ["{symptom_rom} {ask_rom}", "{symptom_rom} kati hunda thik hunchha"],
         "code_switched": ["{symptom} ma के गर्ने", "mero {symptom_rom} kasto hunchha"]},
     "slots_rom": {"symptom_rom": ["blood pressure", "sugar", "mirgaula"],
                   "ask_rom": ["ke garnuparchha", "ke khana hunna",
                               "kun ausadhi khane"]}},

    {"class": "cp3b", "family": "confusion_pair", "pair": "health_query~emergency",
     "side": "emergency", "intent": "emergency",
     "rows": 60, "title": "same symptom PLUS plea — the boundary",
     "why": "confusion twin: the SAME symptom vocabulary with a plea is "
            "emergency; this is the near-miss set's boundary, so the seeds are "
            "de-duplicated against it and the held-out rows are never copied",
     "must_include": ["मद्दत", "बचाउ", "सहयोग", "madat", "bachau", "sahayog"],
     "must_exclude": [],
     "slots": {"symptom": ["मिर्गौला दुख्यो", "टाउको धेरै दुख्यो", "छाती दुख्यो",
                           "सास फेर्न गाह्रो भयो", "ज्वरो धेरै आयो"],
               "plea": ["मद्दत गर्नुहोस्", "मद्दत चाहियो", "बचाउनुहोस्",
                        "सहयोग गर्नुहोस्"]},
     "frames": {
         "devanagari": ["{symptom}, {plea}", "{plea}, {symptom}", "{symptom} नै, {plea}"],
         "romanized": ["{symptom_rom}, {plea_rom}", "{plea_rom}, {symptom_rom}"],
         "code_switched": ["{symptom}, {plea_rom}", "{symptom_rom}, मद्दत गर्नुहोस्"]},
     "slots_rom": {"symptom_rom": ["mirgaula dukhyo", "tauko dherai dukhyo",
                                   "chhati dukhyo", "saas ferna garo bhayo"],
                   "plea_rom": ["madat garnus", "madat chahiyo", "bachaunus"]}},

    {"class": "cp4a", "family": "confusion_pair", "pair": "ack_med~none",
     "side": "ack_med", "intent": "ack_med",
     "rows": 90, "title": "declarative dose taken — खाएँ / खाइसकें / लिएँ",
     "why": "confusion: ack_med declaratives; the model under-fires on the "
            "first-person declarative and the dose-name variant",
     "must_include": [], "must_exclude": ["छैन", "होइन", "नाइँ", "खाइनँ", "पछि"],
     "slots": {"med": ["औषधि", "दवाई", "प्रेसरको औषधि", "सुगरको औषधि", "भिटामिन"],
               "verb": ["खाएँ", "खाइसकें", "लिएँ", "खाएको छु"]},
     "frames": {
         "devanagari": ["{med} {verb}", "आज {med} {verb}", "बिहानको {med} {verb}"],
         "romanized": ["{med_rom} {verb_rom}", "aaja {med_rom} {verb_rom}"],
         "code_switched": ["{med} खाइसकें, done"]},
     "slots_rom": {"med_rom": ["ausadhi", "dawai", "pressure ko ausadhi"],
                   "verb_rom": ["khaye", "khaisake", "liye"]}},

    {"class": "cp4b", "family": "confusion_pair", "pair": "ack_med~none",
     "side": "none", "intent": "none",
     "rows": 50, "title": "refusal / not-yet — must never fire ack_med",
     "why": "confusion twin: the refusal family shares the medication words and "
            "must be labelled none (annotation_rules refusal-marker guard)",
     "must_include": [], "must_exclude": [],
     "slots": {"med": ["औषधि", "दवाई", "प्रेसरको औषधि", "सुगरको औषधि"]},
     "frames": {
         "devanagari": ["{med} खाएको छैन", "{med} खाइनँ", "{med} पछि खान्छु",
                        "अहिले {med} खान्न"],
         "romanized": ["{med_rom} khainа", "{med_rom} pachhi khanchhu"],
         "code_switched": ["{med} not taken yet, पछि"]},
     "slots_rom": {"med_rom": ["ausadhi", "dawai", "pressure ko ausadhi"]}},

    {"class": "cp5a", "family": "confusion_pair", "pair": "suggest_video~music",
     "side": "suggest_video", "intent": "suggest_video",
     "rows": 80, "title": "watch / show — देखाउ, भिडियो, चलचित्र, समाचार",
     "why": "confusion: suggest_video->music; the same media noun appears on both "
            "sides, so the cue is the watch verb / video noun",
     "must_include": [], "must_exclude": ["बजाउ", "सुनाउ", "bajau", "sunau", "play"],
     "slots": {"media": ["भजनको भिडियो", "पुरानो नेपाली भिडियो", "नेपाली समाचारको भिडियो",
                         "पुरानो चलचित्र", "गीतको भिडियो", "युट्युबमा भजन",
                         "भजनको कार्यक्रम", "भजनको भिडियो हेर्न", "पुरानो चलचित्रको भिडियो"]},
     "frames": {
         "devanagari": ["{media} देखाउ", "{media} लगाउ", "{media} हेर्न मिल्छ",
                        "{media} हेराउ"],
         "romanized": ["{media_rom} dekhau", "{media_rom} hera"],
         "code_switched": ["{media} dekhau, youtube मा"]},
     "slots_rom": {"media_rom": ["bhajan ko video", "purano nepali video",
                                 "nepali samachar ko video", "git ko video"]}},

    {"class": "cp5b", "family": "confusion_pair", "pair": "suggest_video~music",
     "side": "music", "intent": "music",
     "rows": 80, "title": "play audio — बजाउ, चलाउ, सुनाउ",
     "why": "confusion twin: matched media nouns to cp5a; only the play verb "
            "differs (the corpus already pins भजन बजाउ vs भजनको भिडियो देखाउ)",
     "must_include": [], "must_exclude": ["देखाउ", "भिडियो", "चलचित्र", "हेर", "dekhau", "video", "hera"],
     "slots": {"media": ["भजन", "पुरानो नेपाली गीत", "गायत्री मन्त्र",
                         "ओम मणि पद्मे हूँ", "पुरानो नेपाली भजन", "लोक गीत",
                         "कीर्तन", "भजन संग्रह", "पुरानो गीत"]},
     "frames": {
         "devanagari": ["{media} बजाउ", "{media} चलाउ", "{media} सुनाउ",
                        "{media} सुन्न मन लाग्यो"],
         "romanized": ["{media_rom} bajau", "{media_rom} chalau",
                       "{media_rom} sunau"],
         "code_switched": ["{media} bajaunu, please", "{media} play गर"]},
     "slots_rom": {"media_rom": ["bhajan", "purano nepali git", "gayatri mantra",
                                 "lok git", "kirtan", "purano git"]}},
]


def _fill(frame: str, slots: dict, rng: random.Random) -> str | None:
    """Fill a frame's {placeholders} from `slots`; None when a slot is absent."""
    out = frame
    while "{" in out:
        start = out.index("{")
        end = out.index("}", start)
        name = out[start + 1:end]
        bank = slots.get(name)
        if not bank:
            return None
        out = out[:start] + rng.choice(bank) + out[end + 1:]
    return out


def _fragment(text: str, rng: random.Random, frozen=()) -> str:
    """Deterministic elder_fragmented seed transform (seed only — the teacher
    writes the final row): drop one interior word, add a filler.

    FROZEN MATERIAL (the TG-11 elision discipline, applied at seed level): a
    word carrying a class cue is never the dropped word, because elision must
    not manufacture a row the class's own cue check will reject — an emergency
    or reminder utterance that lost its discriminating verb is not a fragmented
    example of that class, it is a different class."""
    words = text.split()
    droppable = [i for i in range(1, max(1, len(words) - 1))
                 if not any(c and normalize(c) in normalize(words[i]) for c in frozen)]
    if len(words) > 2 and droppable:
        del words[rng.choice(droppable)]
        text = " ".join(words)
    return f"{rng.choice(FILLERS_HEAD)}... {text}... {rng.choice(FILLERS_TAIL)}"


def _register_plan(total: int) -> dict[str, int]:
    """Largest-remainder allocation of `total` rows over REGISTER_WEIGHTS."""
    wsum = sum(REGISTER_WEIGHTS.values())
    raw = {r: total * w / wsum for r, w in REGISTER_WEIGHTS.items()}
    plan = {r: int(v) for r, v in raw.items()}
    for r in sorted(raw, key=lambda k: -(raw[k] - int(raw[k]))):
        if sum(plan.values()) >= total:
            break
        plan[r] += 1
    return plan


def _candidates(spec: dict, register: str, rng: random.Random) -> list[str]:
    frames = list(spec["frames"].get(register) or [])
    if register == "elder_fragmented":
        frames = list(spec["frames"].get("devanagari") or [])
    slots = {**spec.get("slots", {}), **spec.get("slots_rom", {})}
    out: list[str] = []
    for frame in frames:
        for _ in range(200):                     # bounded fill attempts/frame
            text = _fill(frame, slots, rng)
            if not text:
                break
            if register == "elder_fragmented":
                text = _fragment(text, rng, spec.get("must_include") or ())
            if text not in out:
                out.append(text)
    rng.shuffle(out)
    return out


def confusion_alignment(specs: list, confusion: dict | None) -> dict:
    """Align the class plan against the MEASURED confusion of the model under
    repair (the v5 run), when a confusion file is supplied.

    File format (`--confusion`), produced on the box from the v5 artifact:

        {"schema": "confusion/v1", "rows": 8000,
         "pairs": {"gold_intent->pred_intent": count, ...},
         "recall": {"intent": {"hits": n, "total": n}, ...}}

    This is ADVISORY. It never rewrites a class quota: a campaign that silently
    re-sizes itself from a file whose provenance the operator has not read is a
    campaign nobody can audit. It reports, per class, the measured error mass
    the class is meant to repair, so the operator adjusts the ASK table
    knowingly (and the adjustment is a visible diff, not a hidden multiplier).
    """
    if not confusion:
        return {"supplied": False}
    pairs = confusion.get("pairs") or {}
    recall = confusion.get("recall") or {}
    out: dict = {"supplied": True, "rows": confusion.get("rows"),
                 "by_class": {}, "uncovered_pairs": {}}
    covered: set[str] = set()
    for spec in specs:
        cls = spec["class"]
        measured = None
        basis = ""
        if spec.get("pair"):
            # The pair this class repairs, read from ITS side: a class on side X
            # repairs X->Y errors, and the twin on side Y repairs Y->X.
            other = [s for s in spec["pair"].split("~") if s != spec["side"]]
            other = other[0] if other else ""
            key = f"{other}->{spec['side']}"
            measured = int(pairs.get(key, 0))
            basis = key
            covered.add(key)
            covered.add(f"{spec['side']}->{other}")
        elif spec["intent"] == "emergency":
            r = recall.get("emergency") or {}
            total, hits = int(r.get("total") or 0), int(r.get("hits") or 0)
            if total:
                measured = total - hits
                basis = f"emergency misses ({total - hits}/{total} in the corpus)"
        rec = None
        if measured is not None:
            planned = int(spec["rows"])
            per_err = (planned / measured) if measured else None
            rec = (f"{planned} planned rows / {measured} measured errors"
                   + (f" = {per_err:.1f} rows per error" if per_err else
                      " — no measured errors: keep the class small (it is "
                      "insurance, not repair)"))
        out["by_class"][cls] = {"intent": spec["intent"], "pair": spec.get("pair"),
                                "side": spec.get("side"), "planned_rows": int(spec["rows"]),
                                "measured_basis": basis or None,
                                "measured_errors": measured,
                                "recommendation": rec}
    out["uncovered_pairs"] = {k: v for k, v in sorted(pairs.items(), key=lambda kv: -kv[1])
                              if k not in covered and v > 0}
    return out


def prompt_for(spec: dict, seed: str, register: str, variants: int) -> str:
    """The teacher prompt for one request. Mirrors gen_teacher.py's PROMPT
    (intent/v2 fields, verbatim entity spans) plus the class constraint."""
    include = spec.get("must_include") or []
    exclude = spec.get("must_exclude") or []
    rules = []
    if include:
        rules.append("every utterance MUST contain one of: " + ", ".join(include))
    if exclude:
        rules.append("NO utterance may contain any of: " + ", ".join(exclude))
    if spec["family"] == "emergency_coverage":
        rules.append("emergency is recall-first: a plea, a symptom stated alone, "
                     "or an inability to move IS an emergency — never label it "
                     "health_query or none for being calm or short")
    if spec.get("pair"):
        rules.append(f"this row is the `{spec['side']}` side of the "
                     f"{spec['pair']} boundary: keep the frame and the entities "
                     "identical to the other side and vary ONLY the cue")
    rule_block = ("\nClass rules:\n- " + "\n- ".join(rules)) if rules else ""
    return (
        "You are generating training data for an on-device Nepali intent parser\n"
        "for an elderly person's voice assistant. For the seed utterance below,\n"
        f"produce {variants} natural paraphrases an elderly Nepali speaker might\n"
        f"actually say — including fragmented speech, repetitions, and\n"
        f"code-switching with English — in the \"{register}\" register. For EACH\n"
        "paraphrase output the intent/v2 label.\n"
        f"{rule_block}\n\n"
        f"Seed intent: {spec['intent']}\nSeed utterance: {seed}\n\n"
        "Output ONLY a JSON array, one object per paraphrase:\n"
        '[{"utterance": "...", "action": "' + spec["intent"] + '", "entryId": null,\n'
        '  "contact": string|null, "time": string|null, "medication": string|null,\n'
        '  "message": string|null, "callType": string|null, "requestedApp": string|null,\n'
        '  "topic": string|null, "steps": string[]|null,\n'
        '  "confidence": number, "reply": "short spoken reply in the user\'s language"}]\n\n'
        "Rules: copy entity spans VERBATIM from each paraphrase into the slot fields;\n"
        "never invent entities not present; requestedApp only if the paraphrase names\n"
        "the app; emergency recall-first (plea+pain = emergency).")


def build_requests(rng: random.Random, guards: set, variants: int,
                   only: set, counters: Counter) -> list:
    requests: list[dict] = []
    for spec in ASK:
        if only and spec["class"] not in only:
            continue
        plan = _register_plan(int(spec["rows"]))
        serial = 0
        for register, want_rows in plan.items():
            if want_rows <= 0:
                continue
            # The class quota is in teacher OUTPUT rows; each request asks the
            # teacher for `variants` rows, so the seed count is the row quota
            # divided by the variant count.
            want = -(-want_rows // variants)
            cands = _candidates(spec, register, rng)
            taken = 0
            for seed in cands:
                if taken >= want:
                    break
                if normalize(seed) in guards:
                    counters["seed_dropped_held_out"] += 1
                    continue
                serial += 1
                taken += 1
                rid = f"r2-{spec['class']}-{REG3[register]}-{serial:04d}"
                requests.append({
                    "request_id": rid,
                    "class": spec["class"], "family": spec["family"],
                    "pair": spec.get("pair"), "side": spec.get("side"),
                    "intent": spec["intent"], "register": register,
                    "class_rows": int(spec["rows"]),
                    "variants": variants,
                    "seed": seed,
                    "must_include": spec.get("must_include") or [],
                    "must_exclude": spec.get("must_exclude") or [],
                    "prompt": prompt_for(spec, seed, register, variants),
                    "row_id_prefix": rid,
                })
            counters[f"seeds_{register}"] += taken
            if taken < want:
                counters[f"short_{spec['class']}_{register}"] = want - taken
    return requests


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="data/round2/round2_requests.jsonl")
    parser.add_argument("--report", default="data/round2/round2_requests_report.json")
    parser.add_argument("--variants", type=int, default=3,
                        help="paraphrases requested per request (teacher n)")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--only", default="",
                        help="comma-separated class ids to emit (debug)")
    parser.add_argument("--confusion", default="",
                        help="optional confusion/v1 JSON measured from the model "
                             "under repair (the v5 run). Advisory only: it reports, "
                             "per class, the error mass the class repairs and the "
                             "pairs no class covers — it never rewrites a quota")
    parser.add_argument("--dry-run", action="store_true",
                        help="report only; write no files")
    args = parser.parse_args()

    if args.variants < 1:
        print("[round2-req] --variants must be >= 1", file=sys.stderr)
        return EXIT_USAGE

    try:
        rules = load_rules()
        guards = golden_keys(GOLDEN_CORPUS) | load_golden_keys(NEARMISS)
    except GuardError as e:
        print(f"[guard] REFUSED: {e}", file=sys.stderr)
        return EXIT_GUARD
    except Exception as e:  # noqa: BLE001 — a missing held-out file is a refusal
        print(f"[guard] REFUSED: {e}", file=sys.stderr)
        return EXIT_GUARD

    confusion = None
    if args.confusion:
        c_path = Path(args.confusion).expanduser()
        if not c_path.exists():
            print(f"[round2-req] --confusion not found at {c_path}", file=sys.stderr)
            return EXIT_USAGE
        confusion = json.loads(c_path.read_text(encoding="utf-8"))
        if confusion.get("schema") != "confusion/v1":
            print(f"[round2-req] --confusion {c_path.name}: unexpected schema "
                  f"{confusion.get('schema')!r}, expected 'confusion/v1'",
                  file=sys.stderr)
            return EXIT_USAGE

    rng = random.Random(args.seed)
    counters: Counter = Counter()
    only = {s.strip() for s in args.only.split(",") if s.strip()} or None
    requests = build_requests(rng, guards, args.variants, only, counters)
    plan = [s for s in ASK if not only or s["class"] in only]
    alignment = confusion_alignment(plan, confusion)

    quota = {s["class"]: int(s["rows"]) for s in ASK
             if not only or s["class"] in only}
    asked = {c: sum(r["variants"] for r in requests if r["class"] == c) for c in quota}
    by_intent: dict[str, int] = {}
    for r in requests:
        by_intent[r["intent"]] = by_intent.get(r["intent"], 0) + r["variants"]

    report = {
        "schema": "round2-request-report/v1",
        "created_utc": utc_now(),
        "rules": {"path": str(rules.path), "labels": list(rules.labels)},
        "held_out": {"golden_corpus": str(GOLDEN_CORPUS), "nearmiss": str(NEARMISS),
                     "guard_keys": len(guards)},
        "variants_per_request": args.variants,
        "requests": len(requests),
        "rows_requested_total": sum(asked.values()),
        "rows_requested_by_class": asked,
        "rows_requested_by_intent": dict(sorted(by_intent.items())),
        "quota_shortfalls": {k: v for k, v in counters.items()
                             if k.startswith("short_")},
        "counters": {k: v for k, v in sorted(counters.items()) if v},
        "id_convention": "r2-<class>-<reg3>-<serial>; the STT-noise stage appends "
                         ":noise<n> (stt_noise.py), so the class survives the noise pass",
        "confusion_alignment": alignment,
    }

    if not args.dry_run:
        out = ROOT / args.out
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            for r in requests:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        write_json(ROOT / args.report, report)
    print(f"[round2-req] {len(requests)} requests, "
          f"{sum(asked.values())} rows requested, "
          f"{sum(1 for k in counters if k.startswith('short_'))} short classes "
          f"(seed collisions with the held-out sets: "
          f"{counters.get('seed_dropped_held_out', 0)})")
    for c in sorted(quota):
        print(f"[round2-req]   {c:6s} {asked[c]:5d} / {quota[c]:5d} rows")
    print(f"[round2-req] by intent: "
          + ", ".join(f"{k}={v}" for k, v in sorted(by_intent.items())))
    if alignment.get("supplied"):
        print(f"[round2-req] confusion alignment (advisory, {alignment['rows']} eval rows):")
        for cls in sorted(alignment["by_class"]):
            a = alignment["by_class"][cls]
            if a["measured_errors"] is None:
                print(f"[round2-req]   {cls:6s} no measured basis in the "
                      f"confusion file — quota {a['planned_rows']} kept as authored")
            else:
                print(f"[round2-req]   {cls:6s} {a['recommendation']}  [{a['measured_basis']}]")
        for pair, n in list(alignment["uncovered_pairs"].items())[:10]:
            print(f"[round2-req]   UNCOVERED {pair}: {n} measured errors have no class")
    if not args.dry_run:
        print(f"[round2-req] requests -> {ROOT / args.out}")
        print(f"[round2-req] report   -> {ROOT / args.report}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
