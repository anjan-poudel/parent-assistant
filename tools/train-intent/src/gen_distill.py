"""Stage 8 — data distillation from the gate-passing 4B teacher
(phase 2, 2026-09-13).

Why: the 1.7B student (qwen s42/43/44) misses the §10 gates on
closed-intent accuracy and the slot F1s (best 0.941/0.833/0.909 over k=3,
mean 0.863) while the 4B teacher passes every gate (qwen4b-s43:
1.000/1.000/1.000, emergency 1.000). The student's headroom is data, not
capacity: the teacher's DECISION BOUNDARY on the same taxonomy is the
thing worth copying, and it can be copied as labelled rows.

What this script does:
  1. SYNTHESIS — expands the seeds/intents.yaml taxonomy into NEW
     utterances: new entity values (names, relationships, times,
     medications, appliances, message bodies), new phrasings per intent,
     per-intent politeness/lead-in axes, and the romanized/code-switched
     registers the mixture needs. The golden corpus's own surface forms
     are refused (same normalize() the builder's leak guard uses), and so
     is any utterance whose lossless key already exists in
     teacher/noised/edge supply — a row that duplicates existing text
     cannot ADD a training example, it can only displace one
     (build_dataset dedupes on lossless_key).
  2. TEACHER LABELLING — each new utterance goes to the teacher through
     the SAME slim template training and eval use (render_prompt; raw,
     no chat-template wrapper — the suite's prompt-identity rule) and the
     teacher's completion is parsed with the GATE'S OWN parser
     (eval_golden._first_complete_json: first complete object with a
     canonical string `intent`). A completion the gate would score as
     no-JSON can therefore never become a training label.
  3. Row assembly — the teacher's canonical fields are written verbatim
     (that IS the distillation: its slots, its confidence, its spoken
     response), and the row is schema-validated with build_dataset's own
     valid_row() before it is written.

Deliberately NOT distilled: rows where the teacher's intent differs from
the taxonomy's declared intent for that utterance. Those are not "the
teacher's boundary" — they are the teacher disagreeing with the label the
gate itself is derived from, and teaching them would inject a
contradiction the mixture's conflict guard would drop anyway. They are
counted and reported (`--probe` prints them; the full run lists the first
10).

Determinism (anchored, same discipline as build_dataset): the candidate
set is a pure function of the banks/frames below, selection is by
content-addressed key (blake2b over seed|namespace|intent|utterance — no
RNG stream), and labelling runs GREEDY at temperature 0 from a fixed
context, so the same inputs regenerate the same file byte-for-byte.

Output: data/distill.jsonl (append-safe: ids already present are kept, new
ids appended — re-running after a partial GPU run resumes).

Usage:
  .venv/bin/python src/gen_distill.py --probe 48          # sanity sample
  .venv/bin/python src/gen_distill.py                     # full run (GPU)
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import sys
from collections import Counter
from pathlib import Path

from build_dataset import lossless_key, normalize, valid_row
from config import load_config
from intent_prompt import render_prompt

ROOT = Path(__file__).resolve().parent.parent
OUT_PATH = ROOT / "data" / "distill.jsonl"

SOURCE_PREFIX = "distill"
TEACHER_DEFAULT = "checkpoints/qwen4b-s43-merged"   # gate-passing 4B, merged
MAX_NEW_TOKENS = 220
BATCH_SIZE = 12
PER_FRAME_CAP = 48      # bank × decorator combinations sampled per frame

# ---------------------------------------------------------------------------
# Entity banks. Values deliberately NOT in seeds/intents.yaml's banks where
# possible (new supply), and every time/medication string is a shape the app's
# NepaliTimeParser or the scheduler can actually resolve.
# ---------------------------------------------------------------------------
BANKS = {
    "name": ["सीता", "कमला", "राधा", "लक्ष्मी", "पार्वती", "अनिता", "सञ्जु",
             "मीना", "दुर्गा", "तुलसी", "गोपाल", "विष्णु", "प्रकाश", "शान्ति"],
    "rel": ["छोरी", "आमा", "बुबा", "दिदी", "दाइ", "बहिनी", "भाइ", "नाति",
            "नातिनी", "बुहारी", "सासू", "ससुरा", "मामा", "काका"],
    "name_l": ["sita", "kamala", "radha", "laxmi", "parvati", "anita", "sanju",
               "mina", "durga", "tulsi", "gopal", "bishnu", "prakash", "shanti"],
    "rel_l": ["chhori", "aama", "buwa", "didi", "dai", "bahini", "bhai",
              "nati", "natini", "buhari", "sasu", "sasura", "mama", "kaka"],
    "time": ["बिहान ६ बजे", "बिहान ७ बजे", "बिहान ९ बजे", "दिउँसो १ बजे",
             "दिउँसो ३ बजे", "साँझ ५ बजे", "साँझ ६ बजे", "बेलुका ८ बजे",
             "राति १० बजे", "साढे ६", "साढे ९", "पौने ७", "सवा ५",
             "भोलि बिहान", "आज राति", "हरेक बिहान"],
    "med": ["प्रेसरको औषधि", "सुगरको औषधि", "भिटामिन", "क्याल्सियम",
            "आइरनको चक्की", "दुखाइको औषधि", "थाइराइडको औषधि", "दवाई"],
    "app": ["वाट्सएप", "फेसटाइम", "भाइबर", "मेसेन्जर"],
    "app_l": ["whatsapp", "facetime", "viber", "messenger"],
    "topic": ["माइक्रोवेभ", "प्रेसर कुकर", "वासिङ मेसिन", "टिभी", "रिमोट",
              "मोबाइल", "फ्रिज", "इन्डक्सन", "ग्यास चुलो", "चिया मेसिन"],
    "topic_l": ["microwave", "pressure cooker", "washing machine", "tv",
                "remote", "mobile", "fridge", "induction"],
    "msg": ["भोलि आउँछु", "घर आउनुहोस्", "म ठीक छु", "खाना खाएँ",
            "फोन गर्नुहोस्", "भेट्न आउनुहोस्", "ढिलो हुन्छ"],
    "song": ["भजन", "आरती", "गीत", "पुरानो गीत", "शिव भजन", "कीर्तन",
             "गीता", "मन्त्र"],
    "song_l": ["bhajan", "aarti", "geet", "purano geet", "shiv bhajan",
               "kirtan", "geeta", "mantra"],
    "symptom": ["घुँडा", "पेट", "टाउको", "कम्मर", "हात", "आँखा"],
    "condition": ["प्रेसर", "सुगर", "कोलेस्ट्रोल", "युरिक एसिड",
                  "हिमोग्लोबिन"],
    "condition_l": ["pressure", "sugar", "cholesterol", "uric acid",
                    "hemoglobin"],
    # A body-level distress clause — the emergency side of the §9.4
    # boundary (gc-emergency-002's family). The CALM counterpart of the
    # same symptom is a health_query frame below, never emergency.
    "distress": ["साह्रै गाह्रो भयो", "सास फेर्न गाह्रो भयो", "जिउ काँप्यो",
                 "टाउको घुम्यो", "आँखा अँध्यारो भयो", "बेहोस जस्तो भयो",
                 "खुट्टा लरखराउँदै छ", "पेट बिझ्यो", "रगत आयो",
                 "निधार पसिना आयो"],
    "state": ["मैले औषधि खाइनँ", "आज औषधि खान बाँकी छ", "औषधि खान भ्याइनँ",
              "औषधि सकियो", "औषधि हरायो", "अहिले केही खानु हुन्न है"],
    # Non-actionable refusals — the `none` side of the side-effect boundary
    # (nothing to execute, so a side-effect intent here would be a false
    # trigger). "पछि" forms are the ones an elder repeats to a device that
    # keeps asking.
    "refuse": ["यो चाहिँदैन", "यो नगर्नुस्", "पछि गरौँला", "अहिले नगर",
               "मलाई नचाहिने कुरा", "पर्खनुस् त"],
}

# Per-intent politeness endings (command register, spoken to a device) and
# lead-ins. These are the paraphrase axis the mixture actually needs: same
# intent, same slots, different surface — which is what STT noise disturbs.
POLITE = {
    "call": ["", " है", " न", " भन्नुहोस्", " गरिदिनुस्"],
    "send_message": ["", " है", " न", " भन्नुहोस्", " गरिदिनुस्"],
    "set_reminder": ["", " है", " न", " भन्नुहोस्"],
    "music": ["", " न", " है", " सुन्नुहोस्"],
    "guide": ["", " भन्नुहोस्", " न"],
    "query": ["", " न", " भन्नुहोस्"],
    "ack_med": ["", " है", " न"],
    "none": ["", " है", " न"],
}
LEAD = {
    "call": ["", "सुन्नुहोस्, ", "अलि छिटो, "],
    "send_message": ["", "सुन्नुहोस्, ", "अलि छिटो, "],
    "set_reminder": ["", "सुन्नुहोस्, ", "अलि छिटो, "],
    "music": ["", "सुन्नुहोस्, "],
    "guide": ["", "सुन्नुहोस्, "],
    "query": ["", "भन्नुहोस् त, "],
}
ROMANIZED_POLITE = ["", " na", " hai", " bhannus"]

# ---------------------------------------------------------------------------
# Frames: (intent, register, template, slots). {polite}/{lead} are the
# decorator axes (per-intent values above); every other {token} must be a
# bank token, and one a slot the frame declares (or a token in UNCHECKED —
# a bank the frame draws from that maps to no schema field, so there is
# nothing for the probe to compare).
# ---------------------------------------------------------------------------
FRAMES: list[tuple[str, str, str, tuple[str, ...]]] = [
    # ---- call -------------------------------------------------------------
    ("call", "devanagari", "{lead}{contact}लाई फोन लगाइदेऊ{polite}", ("contact",)),
    ("call", "devanagari", "{lead}{contact} लाई सम्झेर फोन गर्नु{polite}", ("contact",)),
    ("call", "devanagari", "{lead}मैले {contact} लाई फोन गर्नुपर्छ{polite}", ("contact",)),
    ("call", "devanagari", "{lead}{contact} सँग कुरा गर्न मन छ{polite}", ("contact",)),
    ("call", "devanagari", "{lead}फोन मिलाउनुस् {contact} लाई{polite}", ("contact",)),
    ("call", "devanagari", "{lead}{contact} लाई भिडियोमा कुरा गराउनुस्{polite}", ("contact",)),
    ("call", "devanagari", "{lead}{contact} लाई {app} मा सम्पर्क गर{polite}", ("contact", "app")),
    ("call", "devanagari", "{contact} को फोन नम्बर मिलाइदेऊ{polite}", ("contact",)),
    ("call", "devanagari", "{contact} लाई फेरि फोन गर{polite}", ("contact",)),
    ("call", "romanized", "{contact_l} lai phone lagaideu{polite}", ("contact_l",)),
    ("call", "romanized", "{contact_l} sanga kura garna man chha{polite}", ("contact_l",)),
    ("call", "romanized", "malai {contact_l} lai call garnu chha{polite}", ("contact_l",)),
    ("call", "romanized", "{contact_l} lai {app_l} ma sampark gara{polite}", ("contact_l", "app_l")),
    ("call", "code_switched", "{contact} लाई {app_l} मा call गर{polite}", ("contact", "app_l")),
    ("call", "code_switched", "{contact_l} lai video call gara{polite}", ("contact_l",)),
    ("call", "code_switched", "{rel_l} lai {app} मा call लगाउ{polite}", ("contact", "app")),
    # ---- send_message -----------------------------------------------------
    ("send_message", "devanagari", "{lead}{contact} लाई मेसेज पठाइदेऊ{polite}", ("contact",)),
    ("send_message", "devanagari", "{lead}{contact} लाई '{message}' भन्ने सन्देश पठाउ{polite}", ("contact", "message")),
    ("send_message", "devanagari", "{lead}{contact} लाई {app} मा खबर गर{polite}", ("contact", "app")),
    ("send_message", "devanagari", "सन्देश पठाउ {contact} लाई, '{message}' भनेर{polite}", ("contact", "message")),
    ("send_message", "devanagari", "{rel} लाई '{message}' लेखेर पठाइदेऊ{polite}", ("contact", "message")),
    ("send_message", "romanized", "{lead}{contact_l} lai message pathaideu{polite}", ("contact_l",)),
    ("send_message", "romanized", "{contact_l} lai '{message}' bhanera pathau{polite}", ("contact_l", "message")),
    ("send_message", "code_switched", "{contact} लाई WhatsApp मा message पठाउ{polite}", ("contact",)),
    ("send_message", "code_switched", "{contact_l} lai '{message}' message pathaideu{polite}", ("contact_l", "message")),
    # ---- set_reminder -----------------------------------------------------
    ("set_reminder", "devanagari", "{lead}{time} मलाई औषधि खान सम्झाउनुहोस्{polite}", ("time",)),
    ("set_reminder", "devanagari", "{time} को औषधि सम्झना गराइदिनुस्{polite}", ("time",)),
    ("set_reminder", "devanagari", "मैले {time} {medication} खानुपर्छ, सम्झाउनु{polite}", ("time", "medication")),
    ("set_reminder", "devanagari", "{time} अलार्म राख्नुहोस्{polite}", ("time",)),
    ("set_reminder", "devanagari", "{time} पानी खान सम्झाउनु{polite}", ("time",)),
    ("set_reminder", "devanagari", "{time} हिँड्न सम्झाउनुहोस्{polite}", ("time",)),
    ("set_reminder", "devanagari", "हरेक दिन {time} {medication} खान सम्झाउनु{polite}", ("time", "medication")),
    ("set_reminder", "devanagari", "{time} {medication} खाने बेला भयो भन्ने सम्झना{polite}", ("time", "medication")),
    ("set_reminder", "romanized", "{time} ma ausadhi khana samjhaunu{polite}", ("time",)),
    ("set_reminder", "romanized", "malai {time} uthna samjhaideu{polite}", ("time",)),
    ("set_reminder", "code_switched", "{time} medicine खान reminder राख्नु{polite}", ("time",)),
    ("set_reminder", "code_switched", "{time} मा {med_l} को reminder राख{polite}", ("time", "medication")),
    # ---- emergency --------------------------------------------------------
    ("emergency", "devanagari", "{distress}, मद्दत गर्नुहोस्", ()),
    ("emergency", "devanagari", "मद्दत गर्नुहोस्, {distress}", ()),
    ("emergency", "devanagari", "छिटो, {distress}, मद्दत चाहियो", ()),
    ("emergency", "devanagari", "{distress} — कोही आउनुहोस्", ()),
    ("emergency", "devanagari", "{symptom} दुख्यो, {distress}", ("symptom",)),
    ("emergency", "devanagari", "मलाई {symptom} एकदम दुख्यो, मद्दत गर्नुहोस्", ("symptom",)),
    ("emergency", "devanagari", "{symptom} दुख्यो, छिटो मद्दत पठाउनुहोस्", ("symptom",)),
    ("emergency", "devanagari", "मद्दत गर्नुहोस्, मलाई {symptom} दुखेको छ", ("symptom",)),
    ("emergency", "devanagari", "{symptom} दुख्यो, म बचाउनुहोस्", ("symptom",)),
    ("emergency", "devanagari", "मलाई साह्रै गाह्रो भयो, कोही आउनुहोस्", ()),
    ("emergency", "devanagari", "मेरो छाती दुख्यो, चाँडो आउनुहोस्", ()),
    ("emergency", "devanagari", "मलाई उठ्न गाह्रो भयो, मद्दत चाहियो", ()),
    ("emergency", "devanagari", "म बेहोस भएँ, बचाउनुहोस्", ()),
    ("emergency", "devanagari", "रगत बगिरहेको छ, मद्दत गर्नुहोस्", ()),
    ("emergency", "devanagari", "सास फेर्न गाह्रो छ, मद्दत", ()),
    ("emergency", "devanagari", "मलाई डर लाग्यो, कोही आउनुहोस्", ()),
    ("emergency", "devanagari", "खुट्टा भाँच्चियो, चाँडो मद्दत पठाउनुहोस्", ()),
    ("emergency", "devanagari", "म लडेँ, उठ्न सक्दिनँ, मद्दत", ()),
    ("emergency", "romanized", "madat garnuhos, malai saas ferna garo bhayo", ()),
    ("emergency", "romanized", "ma lade, uthna sakina, madat chahiyo", ()),
    ("emergency", "romanized", "chhati dukhyo, chhito aaunuhos", ()),
    ("emergency", "romanized", "ambulance bolau, saas ferna garo chha", ()),
    ("emergency", "code_switched", "help गर्नुहोस्, मलाई {symptom} दुख्यो", ("symptom",)),
    ("emergency", "code_switched", "emergency छ, छिटो help गर्नुहोस्", ()),
    ("emergency", "elder_fragmented", "मद्दत... मद्दत गर्नुहोस्... {symptom} दुख्यो", ("symptom",)),
    ("emergency", "elder_fragmented", "ऊ... {distress}... मद्दत", ()),
    # ---- health_query (calm, no plea — the boundary's other half) ---------
    ("health_query", "devanagari", "{symptom} दुख्दा के खानु हुन्न", ("symptom",)),
    ("health_query", "devanagari", "{symptom} दुख्दा के गर्नुपर्छ", ("symptom",)),
    ("health_query", "devanagari", "{symptom} दुख्दा कस्तो व्यायाम गर्ने", ("symptom",)),
    ("health_query", "devanagari", "{condition} कति हुँदा सामान्य हुन्छ", ()),
    ("health_query", "devanagari", "{condition} बढ्दा के लक्षण देखिन्छ", ()),
    ("health_query", "devanagari", "{condition} को औषधि कहिले खानु राम्रो", ()),
    ("health_query", "devanagari", "{medication} खानुअघि के खान हुन्छ", ("medication",)),
    ("health_query", "devanagari", "{medication} खाली पेटमा खान हुन्छ", ("medication",)),
    ("health_query", "devanagari", "{symptom} दुख्दा कस्तो औषधि खाने", ("symptom",)),
    ("health_query", "devanagari", "{symptom} दुख्दा डाक्टरलाई कहिले देखाउने", ("symptom",)),
    ("health_query", "devanagari", "क्याल्सियम कहिले खानु राम्रो", ()),
    ("health_query", "devanagari", "दुखाइको औषधि दिनको कति चोटि खाने", ()),
    ("health_query", "romanized", "{condition_l} badhda ke lakshan dekhinchha", ()),
    ("health_query", "romanized", "ausadhi khana agadi ke khana hunchha", ()),
    ("health_query", "code_switched", "BP high हुँदा के गर्ने", ()),
    ("health_query", "code_switched", "sugar level कति हुनुपर्छ", ()),
    # ---- music ------------------------------------------------------------
    ("music", "devanagari", "{lead}{song} लगाइदेऊ{polite}", ("song",)),
    ("music", "devanagari", "{song} सुनाउनु{polite}", ("song",)),
    ("music", "devanagari", "{song} बजाउनुहोस् त{polite}", ("song",)),
    ("music", "devanagari", "{lead}मन शान्त गर्ने संगीत बजाऊ{polite}", ()),
    ("music", "devanagari", "{song} सुन्न मन छ{polite}", ("song",)),
    ("music", "romanized", "{song_l} bajaideu{polite}", ("song",)),
    ("music", "romanized", "purano geet sunna man chha{polite}", ()),
    ("music", "code_switched", "{song} play गर{polite}", ("song",)),
    ("music", "code_switched", "{song_l} गीत लगाउ{polite}", ("song",)),
    # ---- guide ------------------------------------------------------------
    ("guide", "devanagari", "{lead}{topic} कसरी सफा गर्ने{polite}", ("topic",)),
    ("guide", "devanagari", "{topic} कसरी बन्द गर्ने{polite}", ("topic",)),
    ("guide", "devanagari", "{topic} चलाउन के गर्ने{polite}", ("topic",)),
    ("guide", "devanagari", "{topic} कसरी प्रयोग गर्ने{polite}", ("topic",)),
    ("guide", "devanagari", "{topic} को बटन कहाँ छ{polite}", ("topic",)),
    ("guide", "devanagari", "{topic} बिग्रियो, कसरी ठीक गर्ने{polite}", ("topic",)),
    ("guide", "romanized", "{topic_l} kasari chalaune{polite}", ("topic_l",)),
    ("guide", "code_switched", "{topic} कसरी on गर्ने{polite}", ("topic",)),
    # ---- query ------------------------------------------------------------
    ("query", "devanagari", "{lead}आज मौसम कस्तो छ{polite}", ()),
    ("query", "devanagari", "{lead}अहिले समय कति भयो{polite}", ()),
    ("query", "devanagari", "आज कति तारिख भयो{polite}", ()),
    ("query", "devanagari", "यो हप्ता बिदा कति दिन छ{polite}", ()),
    ("query", "devanagari", "दसैँ कहिले पर्छ{polite}", ()),
    ("query", "devanagari", "भोलिको मौसम कस्तो हुन्छ{polite}", ()),
    ("query", "devanagari", "बाहिर घाम लागेको छ{polite}", ()),
    ("query", "devanagari", "आज पानी पर्छ कि{polite}", ()),
    ("query", "devanagari", "अहिले कति बजे भयो{polite}", ()),
    ("query", "devanagari", "आज दिन कस्तो छ{polite}", ()),
    ("query", "devanagari", "भोलि बिदा छ कि{polite}", ()),
    ("query", "romanized", "aaja ko mausam kasto chha{polite}", ()),
    ("query", "romanized", "ahile kati baje bhayo{polite}", ()),
    ("query", "code_switched", "आज weather कस्तो छ{polite}", ()),
    # ---- none (refusals + fragments — the ack_med attractor) --------------
    ("none", "devanagari", "{lead}{state}{polite}", ()),
    ("none", "devanagari", "{refuse}{polite}", ()),
    ("none", "devanagari", "होइन, {refuse}{polite}", ()),
    ("none", "devanagari", "{refuse}, मलाई नचाहिने{polite}", ()),
    ("none", "devanagari", "होइन, पछि खान्छु{polite}", ()),
    ("none", "devanagari", "मलाई यो चाहिँदैन{polite}", ()),
    ("none", "devanagari", "अहिले नगर, पछि गरौँला{polite}", ()),
    ("none", "devanagari", "मैले औषधि खाइनँ{polite}", ()),
    ("none", "devanagari", "थाहा भएन, फेरि भन्नुहोस्{polite}", ()),
    ("none", "romanized", "ausadhi khainna aaja{polite}", ()),
    ("none", "romanized", "ke thalha, bhannai sakina{polite}", ()),
    ("none", "code_switched", "कुनै काम छैन, thank you{polite}", ()),
    ("none", "elder_fragmented", "ऊ... त्यो... फेरि... के भनें", ()),
    ("none", "elder_fragmented", "हँ... होइन... अहिले होइन", ()),
    ("none", "elder_fragmented", "भन्न खोजेको... ऊ... बिर्सें", ()),
    # ---- ack_med ----------------------------------------------------------
    ("ack_med", "devanagari", "औषधि खाइसकें{polite}", ()),
    ("ack_med", "devanagari", "मैले औषधि खाएँ{polite}", ()),
    ("ack_med", "devanagari", "{medication} खाएँ{polite}", ("medication",)),
    ("ack_med", "devanagari", "आजको {medication} खाइसकें{polite}", ("medication",)),
    ("ack_med", "devanagari", "{medication} खाइसकें{polite}", ("medication",)),
    ("ack_med", "devanagari", "{medication} खान भ्याएँ{polite}", ("medication",)),
    ("ack_med", "devanagari", "बिहानको {medication} खाएँ{polite}", ("medication",)),
    ("ack_med", "devanagari", "औषधि खान भ्याएँ{polite}", ()),
    ("ack_med", "romanized", "ausadhi khaen{polite}", ()),
    ("ack_med", "code_switched", "medicine खाइसकें{polite}", ()),
]

# Slot token -> bank. The *_l variants exist because a romanized row's slot
# value must itself be romanized (a Devanagari value inside "sita lai
# phone lagaideu" would be a script mix the register never has).
BANK_OF = {
    "contact": "name", "contact_l": "name_l",
    "rel": "rel", "rel_l": "rel_l",
    "time": "time", "medication": "med", "med_l": "med",
    "app": "app", "app_l": "app_l",
    "topic": "topic", "topic_l": "topic_l",
    "message": "msg", "song": "song", "song_l": "song_l",
    "symptom": "symptom", "condition": "condition",
    "condition_l": "condition_l", "distress": "distress", "state": "state",
    "refuse": "refuse",
}
# Slot aliases: several bank tokens feed ONE schema field (an utterance
# that calls a relative fills `contact`; a romanized frame fills it from a
# romanized bank). The frame declares the FIELD, the token may be any alias.
SLOT_ALIASES = {
    "contact": ("contact", "contact_l", "rel", "rel_l"),
    "topic": ("topic", "topic_l"),
    "app": ("app", "app_l"),
    "song": ("song", "song_l"),
    "medication": ("medication", "med_l"),
}
TOKEN_SLOT = {tok: slot for slot, toks in SLOT_ALIASES.items() for tok in toks}
# Where a frame slot lands in the app schema. `symptom`/`song` have no
# field of their own — the schema carries a generic `topic`, which is
# where the teacher puts them (verified in the probe), so the probe's
# slot check reads that back through the same mapping.
FIELD_OF_SLOT = {"app": "requestedApp", "symptom": "topic", "song": "topic"}
# Bank tokens that map to NO schema field: drawn to make the utterance
# realistic, but there is nothing to compare the teacher's output against.
UNCHECKED = {"condition", "condition_l", "distress", "state", "refuse"}
DECORATOR_ANCHOR = 2     # axes before the bank axes: lead, polite

# --- teacher-label repair ([DISTILL] phase-2) ------------------------------
# The teacher's slot habits on synthesized frames contradict the corpus's own
# convention in measurable ways (measure with src/audit_distill_labels.py):
# 6.2% of the phase-2 rows carry a `time` that drops or swaps the utterance's
# qualifier (`बिहान ७ बजे` -> `७ बजे`, `सवा ५` -> `साढे ५ बजे` — 5:15 taught
# as 5:30) against 0.9% in the pre-distill corpus and 0 of 20 in the golden
# corpus, and some contacts come back romanized (`सुनिता` -> `sunita`) where
# the corpus keeps Devanagari. Phase-2 arm A showed the student copies the
# habit straight into the gate (time F1 0.500 -> 0.000 unconstrained), so
# these two fields are taken from the UTTERANCE — the frame wrote the phrase
# verbatim, and the utterance cannot be wrong about itself. The teacher keeps
# every field the frame did not dictate.
TIME_BANK_SORTED = sorted(BANKS["time"], key=len, reverse=True)
NEPALI_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
ROMAN2DEV = {lat: dev for dev, lat in
             list(zip(BANKS["name"], BANKS["name_l"]))
             + list(zip(BANKS["rel"], BANKS["rel_l"]))}


def norm_text(value) -> str:
    return " ".join(str(value).translate(NEPALI_DIGITS).split())


def canonical_time(phrase: str) -> str:
    """Bank time phrase -> corpus form: a clock time keeps a trailing बजे
    (bank `साढे ६` -> `साढे ६ बजे`, matching the golden corpus's
    `साढे ७ बजे`); a day-scale phrase (`भोलि बिहान`) is left as it is."""
    if phrase.endswith("बजे") or not any(c.isdigit() for c in phrase):
        return phrase
    return phrase + " बजे"


def repair_time(utterance: str, value):
    """Rewrite ONLY a time label that contradicts the utterance's own
    qualifiers (see audit_distill_labels.qualifier_mismatch); the label then
    becomes the phrase the utterance actually says. A teacher value that
    keeps the qualifiers is left alone even when it is longer than the bank
    phrase — `हरेक दिन बिहान ७ बजे` is a better reminder time than the bank's
    `बिहान ७ बजे`, and an over-eager repair would drop the recurrence."""
    from audit_distill_labels import qualifier_mismatch

    if not value or qualifier_mismatch(utterance, value) is None:
        return value
    u = norm_text(utterance)
    for phrase in TIME_BANK_SORTED:
        if norm_text(phrase) in u:
            return canonical_time(phrase)
    return value


# A contact is a name, not a clause. The corpus labels a name as the
# transcript writes it (`nati lai call gar na` -> `nati`, `Buba lai ...` ->
# `Buba`; see the audit's contact@* rows — only 3/1481 pre-distill contacts
# carry a space-separated case marker), so any contact longer than two
# tokens, or containing a verb, is a teacher mislabel regardless of that
# convention: the phase-2 teacher put the entire clause
# `सन्देश पठाउ सञ्जु लाई` in `contact` on 3 send_message rows.
CONTACT_MAX_TOKENS = 2
CONTACT_VERBS = ("पठाउ", "पठा", "भन", "गर", "कल", "फोन")


def bank_name_in(utterance: str) -> str:
    """The longest bank name/relationship the utterance itself names."""
    u = norm_text(utterance)
    best = ""
    for name in list(BANKS["name"]) + list(BANKS["rel"]):
        if len(name) > len(best) and norm_text(name) in u:
            best = name
    return best


def repair_contact(utterance: str, value):
    """Two contact mislabels, both checked against the corpus's own rule
    (the label is the name AS THE TRANSCRIPT WRITES IT):

    1. a romanized bank name the utterance says in Devanagari is written
       back in Devanagari (`सुनितालाई...` labelled `sunita` — the corpus
       labels that transcript `सुनिता`);
    2. a whole clause in the field (`सन्देश पठाउ सञ्जु लाई`) is replaced by
       the bank name the utterance actually names.

    Anything else is left exactly as the teacher wrote it: the corpus
    mixes Devanagari and romanized contact labels by register, so
    "Devanagari everywhere" would be an over-correction."""
    if not value or not isinstance(value, str):
        return value
    v = value.strip()
    dev = ROMAN2DEV.get(v.lower())
    if dev and norm_text(dev) in norm_text(utterance):
        return dev
    if (len(v.split()) > CONTACT_MAX_TOKENS
            or any(tok in CONTACT_VERBS for tok in v.split())):
        name = bank_name_in(utterance)
        if name:
            return name
    return value

# Per-intent take. Shape follows what the gates measure: closed-intent
# accuracy is dominated by call/reminder/message, the emergency gate by
# pleas (incl. the plea+pain boundary), and the two slot F1 gates by
# contact (call/message) and time (reminder). These are CAPS — the
# achieved counts are supply-limited and reported at the end.
INTENT_TARGETS = {
    "call": 420, "send_message": 260, "set_reminder": 380,
    "emergency": 320, "health_query": 260, "music": 180,
    "guide": 160, "query": 190, "none": 250, "ack_med": 180,
}


def pick_response(intent: str, row: dict, seed: int) -> str:
    """The spoken reply for a distilled row, from the house-style pools.

    `response` is NOT scored by the §10 gate (the golden corpus carries no
    response field at all) but it IS what the app speaks, so it needs to be
    right. Verbatim copying is not safe here: on these out-of-distribution
    utterances the teacher's reply degenerates or invents medical content
    ("हात दुख्यो, टाउको घुम्यो" → "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको
    छ।"; "अहिले कति बजे भयो" → "अहिले बजे भन्नुभयो।"), measured at ~1/3 of
    probed rows — and the add-on is ~40% of the mixture, so copying it
    would visibly degrade the app's replies. The pools below are the
    shipped data/edge_cases.jsonl house style ("ठीक छ, सम्झाउँछु।",
    "मद्दत पठाउँदै छु।", "औषधि खानुभएको रेकर्ड गरें।"). The teacher remains
    the source of everything the gates measure: intent, slots, confidence.
    """
    pool = RESPONSE_POOLS.get(intent) or ["ठीक छ।"]
    # Anchored pick (content-addressed, like every other draw) — a rebuild
    # reassigns nothing, and the choice varies across rows of one intent.
    idx = int.from_bytes(akey(seed, "response", intent,
                              row["utterance"]), "big") % len(pool)
    for offset in range(len(pool)):
        text = pool[(idx + offset) % len(pool)]
        slots = {name: row.get(name) for name in ("contact", "time",
                                                  "medication")}
        if any("{" + name + "}" in text and not slots[name] for name in slots):
            continue        # slot absent on this row — take the next reply
        return _fill(text, {k: v for k, v in slots.items() if v})
    return pool[-1]


# Per-intent spoken replies, in the data/edge_cases.jsonl house style.
RESPONSE_POOLS = {
    "ack_med": ["औषधि खानुभएको रेकर्ड गरें।", "खानुभएको टिपोट भयो।",
                "ठीक छ, टिपोट गरें।"],
    "call": ["{contact} लाई फोन गर्दै छु।", "ठीक छ, फोन लगाउँदै छु।",
             "फोन मिलाउँदै छु।"],
    "emergency": ["मद्दत पठाउँदै छु।", "ठीक छ, मद्दत बोलाउँदै छु।",
                  "चिन्ता नलिनुस्, म तुरुन्तै मद्दत बोलाउँदै छु।"],
    "health_query": ["यो विषयमा डाक्टरसँग सोध्नु राम्रो हुन्छ।",
                     "सामान्य जानकारी दिन्छु, डाक्टरलाई पनि सोध्नुहोस्।"],
    "music": ["हुन्छ, बजाउँदै छु।", "गीत बजाउँदै छु।", "संगीत लगाउँदै छु।"],
    "guide": ["यसरी गर्न सकिन्छ।", "ठीक छ, भन्दै छु।", "यसो गर्नुहोस्।"],
    "query": ["हेर्दै छु।", "एक छिन, हेरौँ।", "अहिले भन्दै छु।"],
    "none": ["ठीक छ।", "के भन्नुभयो?", "हुन्छ।"],
    "send_message": ["{contact} लाई सन्देश पठाउँदै छु।", "ठीक छ, पठाउँदै छु।",
                     "सन्देश पठाइयो।"],
    "set_reminder": ["{time} सम्झाउँछु।", "ठीक छ, रिमाइन्डर राख्दै छु।",
                     "ठीक छ, सम्झाउँछु।"],
}


def akey(seed, namespace: str, intent: str, utterance: str) -> bytes:
    """Content-addressed selection key (build_dataset.draw_key's discipline:
    pure function of seed + namespace + content, no RNG stream, so pool
    growth can never re-draw an existing row)."""
    return hashlib.blake2b(
        f"{seed}|{namespace}|{intent}|{utterance}".encode("utf-8"),
        digest_size=8).digest()


def _fill(template: str, values: dict[str, str]) -> str:
    out = template
    for token, value in values.items():
        out = out.replace("{" + token + "}", value)
    return out


def _slot_tokens(template: str) -> list[str]:
    return [t for t in BANK_OF if "{" + t + "}" in template]


def _intended(name: str, values: dict[str, str]):
    """The value the utterance was BUILT from, for the probe's slot check."""
    for key in SLOT_ALIASES.get(name, (name,)):
        if values.get(key) is not None:
            return values[key]
    return None


def candidates(seed: int):
    """Every (intent, register, utterance, intended-slots) the frames can
    build, in a deterministic order. Decorator axes iterate FIRST so the
    per-frame cap spends itself on bank coverage (product varies the last
    axis fastest)."""
    for intent, register, template, slot_names in FRAMES:
        tokens = _slot_tokens(template)
        declared = {TOKEN_SLOT.get(s, s) for s in slot_names}
        unknown = {t for t in tokens if t not in UNCHECKED
                   and TOKEN_SLOT.get(t, t) not in declared}
        assert not unknown, f"frame {template!r} uses undeclared slots {unknown}"
        if register in ("devanagari", "elder_fragmented"):
            axes = [LEAD.get(intent, [""]), POLITE.get(intent, [""])]
        else:
            axes = [[""], ROMANIZED_POLITE]
        axes += [BANKS[BANK_OF[t]] for t in tokens]
        combos = itertools.islice(itertools.product(*axes), PER_FRAME_CAP)
        keys = ("lead", "polite") + tuple(tokens)
        for combo in combos:
            values = dict(zip(keys, combo))
            utterance = _fill(template, values).strip()
            assert "{" not in utterance, f"unfilled token in {utterance!r}"
            intended = {}
            for name in slot_names:
                name = TOKEN_SLOT.get(name, name)
                field = FIELD_OF_SLOT.get(name, name)
                intended[field] = _intended(name, values)
            yield {"intent": intent, "register": register,
                   "utterance": utterance, "intended": intended}


def select(seed: int, existing_keys: set[str], golden_keys: set[str]):
    """Deterministic, anchored selection of the NEW rows to label."""
    by_intent: dict[str, list[dict]] = {}
    seen: set[str] = set()
    for cand in candidates(seed):
        utterance = cand["utterance"]
        key = lossless_key(utterance)
        if key in seen:
            continue
        seen.add(key)
        if normalize(utterance) in golden_keys:
            continue        # the builder would refuse it — don't spend a call
        if key in existing_keys:
            continue        # duplicate text adds no example (build_dataset dedupes)
        by_intent.setdefault(cand["intent"], []).append(cand)
    chosen = []
    for intent, target in INTENT_TARGETS.items():
        pool = sorted(by_intent.get(intent, []),
                      key=lambda c: akey(seed, "distill", intent, c["utterance"]))
        chosen.extend(pool[:target])
    return chosen


def _existing_keys() -> set[str]:
    keys: set[str] = set()
    for name in ("teacher.jsonl", "noised.jsonl", "edge_cases.jsonl",
                 "distill.jsonl"):
        path = ROOT / "data" / name
        if not path.exists():
            continue
        for line in open(path, encoding="utf-8"):
            if line.strip():
                keys.add(lossless_key(json.loads(line)["utterance"]))
    return keys


def golden_keys() -> set[str]:
    return {normalize(json.loads(l)["utterance"])
            for l in open(ROOT / "eval" / "golden_corpus.jsonl",
                          encoding="utf-8") if l.strip()}


def label_rows(rows: list[dict], teacher: str, template: str,
               batch_size: int, log_every: int = 40) -> list[dict]:
    """Greedy batched labelling with the local teacher (GPU).

    Returns rows annotated with the teacher's parsed object + raw text.
    The parse uses eval_golden._first_complete_json — the same strict
    reader the §10 gate uses — so a label that would score as no-JSON at
    gate time cannot enter the training file.
    """
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    from eval_golden import _first_complete_json

    tok = AutoTokenizer.from_pretrained(teacher)
    tok.pad_token = tok.pad_token or tok.eos_token
    tok.padding_side = "left"
    model = AutoModelForCausalLM.from_pretrained(
        teacher, dtype=torch.bfloat16, device_map="auto")
    model.eval()

    out: list[dict] = []
    for start in range(0, len(rows), batch_size):
        chunk = rows[start:start + batch_size]
        prompts = [render_prompt(template, r["utterance"]) for r in chunk]
        enc = tok(prompts, return_tensors="pt", padding=True, truncation=True,
                  max_length=1536).to(model.device)
        with torch.inference_mode():
            gen = model.generate(**enc, max_new_tokens=MAX_NEW_TOKENS,
                                 do_sample=False,
                                 pad_token_id=tok.pad_token_id)
        texts = tok.batch_decode(gen[:, enc["input_ids"].shape[1]:],
                                 skip_special_tokens=True)
        for row, text in zip(chunk, texts):
            row = dict(row)
            row["teacher_obj"] = _first_complete_json(text)
            row["teacher_raw"] = text
            out.append(row)
        if log_every and (start // batch_size) % log_every == 0:
            print(f"[distill] labelled {min(start + batch_size, len(rows))}"
                  f"/{len(rows)}", flush=True)
    return out


def to_row(row: dict, seed: int) -> dict | None:
    """Teacher object -> training row (None when the label is unusable).

    Every field is the teacher's own EXCEPT `response`, which comes from
    the house-style pools — see pick_response for the measurement behind
    that choice. `intent` is re-checked here (not just in the caller) so
    the invariant lives next to the row it constrains.
    """
    obj = row["teacher_obj"]
    if obj is None:
        return None
    if obj.get("intent") != row["intent"]:
        return None                      # teacher contradicts the taxonomy
    out = {"utterance": row["utterance"], "register": row["register"],
           "source": f"{SOURCE_PREFIX}:{row['register']}"}
    for field in ("intent", "entryId", "contact", "time", "medication",
                  "message", "callType", "requestedApp", "topic", "steps",
                  "confidence"):
        if field == "confidence":
            try:
                value = float(obj.get("confidence", 0.0))
            except (TypeError, ValueError):
                return None
            value = max(0.0, min(1.0, value))
        else:
            value = obj.get(field)
        out[field] = value
    # Repair the two fields the teacher proved unreliable on synthesized
    # frames (time qualifiers, contact script) — see TIME_BANK_SORTED.
    out["time"] = repair_time(row["utterance"], out["time"])
    out["contact"] = repair_contact(row["utterance"], out["contact"])
    out["response"] = pick_response(row["intent"], out, seed)
    out["id"] = hashlib.sha256(
        f"{SOURCE_PREFIX}|{row['register']}|{row['intent']}|{row['utterance']}"
        .encode("utf-8")).hexdigest()[:16]
    if not valid_row(out):
        return None
    return out


def revalidate(path: Path) -> None:
    """Apply the label repair to an ALREADY-labelled distill file — no
    teacher, no GPU. The untouched teacher rows are written once to
    <name>_teacher_raw.jsonl so the difference between what the teacher said
    and what the student is taught stays auditable, and the repaired file is
    re-audited with the same qualifier check that found the problem."""
    from audit_distill_labels import qualifier_errors

    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    raw_path = path.with_name(path.stem + "_teacher_raw.jsonl")
    if not raw_path.exists():
        raw_path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n"
                                    for r in rows), encoding="utf-8")
    changed = Counter()
    for r in rows:
        before = (r.get("time"), r.get("contact"))
        r["time"] = repair_time(r["utterance"], r.get("time"))
        r["contact"] = repair_contact(r["utterance"], r.get("contact"))
        changed["time"] += r["time"] != before[0]
        changed["contact"] += r["contact"] != before[1]
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n"
                            for r in rows), encoding="utf-8")
    left = qualifier_errors(rows)
    print(f"[distill/revalidate] {len(rows)} rows; repaired "
          f"time {changed['time']}, contact {changed['contact']}; "
          f"teacher originals -> {raw_path.name}")
    print(f"[distill/revalidate] qualifier contradictions left: {len(left)} "
          f"(was 105 before the repair)")
    for r, said, wrote in left[:5]:
        print(f"    {r['intent']:14s} utt={r['utterance'][:44]!r} "
              f"time={r['time']!r} (said {said}, wrote {wrote})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teacher", default=TEACHER_DEFAULT)
    parser.add_argument("--revalidate", action="store_true",
                        help="repair an existing data/distill.jsonl in place "
                             "(time from the utterance's bank phrase, "
                             "contacts back to Devanagari) and re-audit; "
                             "no teacher, no GPU")
    parser.add_argument("--probe", type=int, default=0,
                        help="label only N rows spread across intents, "
                             "print a table, write nothing")
    parser.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    parser.add_argument("--limit", type=int, default=0)
    args, cfg = load_config(parser)

    seed = int(cfg.get("mixture.seed", 42))
    template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")

    if args.revalidate:
        revalidate(OUT_PATH)
        return

    chosen = select(seed, _existing_keys(), golden_keys())
    if args.limit:
        chosen = chosen[:args.limit]

    if args.probe:
        # Spread the probe across intents so every gate-relevant class shows.
        per = max(1, args.probe // len(INTENT_TARGETS))
        probe: list[dict] = []
        for intent in INTENT_TARGETS:
            probe.extend([c for c in chosen if c["intent"] == intent][:per])
        probe = probe[:args.probe]
        labelled = label_rows(probe, args.teacher, template, args.batch_size,
                              log_every=0)
        agree_intent = agree_slot = total = 0
        for row in labelled:
            obj = row["teacher_obj"]
            total += 1
            ok_intent = obj is not None and obj.get("intent") == row["intent"]
            agree_intent += ok_intent
            slots = []
            for field, want in row["intended"].items():
                got = (obj or {}).get(field)
                slots.append(f"{field}={got!r}"
                             + ("" if got == want else f" (want {want!r})"))
                agree_slot += got == want
            print(f"\n{row['register']:14s} declared={row['intent']:16s} "
                  f"teacher={(obj or {}).get('intent')!r} "
                  f"{'OK' if ok_intent else 'MISMATCH'}")
            print(f"  utt   : {row['utterance']}")
            print(f"  resp  : {(obj or {}).get('response')!r} "
                  f"conf={(obj or {}).get('confidence')!r}")
            if slots:
                print(f"  slots : {'; '.join(slots)}")
            print("  obj   : " + json.dumps(
                {k: v for k, v in (obj or {}).items()
                 if v not in (None, "", 0, 0.0)}, ensure_ascii=False)[:280])
            if not ok_intent and row["teacher_raw"]:
                print(f"  raw   : {row['teacher_raw'][:200]!r}")
        print(f"\n[distill/probe] {total} rows, intent agreement "
              f"{agree_intent}/{total}, slot agreement {agree_slot}")
        return

    print(f"[distill] {len(chosen)} new utterances selected "
          f"(seed={seed}, teacher={args.teacher})")
    labelled = label_rows(chosen, args.teacher, template, args.batch_size)

    rows, dropped = [], {"no_json": 0, "disagree": 0, "invalid": 0}
    disagreements: list[tuple[str, str, str]] = []
    for row in labelled:
        out = to_row(row, seed)
        if out is None:
            if row["teacher_obj"] is None:
                dropped["no_json"] += 1
            elif row["teacher_obj"].get("intent") != row["intent"]:
                dropped["disagree"] += 1
                disagreements.append((row["utterance"], row["intent"],
                                      str(row["teacher_obj"].get("intent"))))
            else:
                dropped["invalid"] += 1
            continue
        rows.append(out)

    have = {json.loads(l)["id"] for l in open(OUT_PATH, encoding="utf-8")
            if l.strip()} if OUT_PATH.exists() else set()
    new = [r for r in rows if r["id"] not in have]
    with open(OUT_PATH, "a", encoding="utf-8") as f:
        for row in new:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"[distill] wrote {len(new)} new rows to {OUT_PATH.name} "
          f"({len(rows) - len(new)} already present); dropped {dropped}")
    print("[distill] by intent: "
          + str(dict(sorted(Counter(r["intent"] for r in rows).items()))))
    print("[distill] by register: "
          + str(dict(sorted(Counter(r["register"] for r in rows).items()))))
    if disagreements:
        print(f"[distill] teacher disagreed with the taxonomy on "
              f"{len(disagreements)} rows — first 10:")
        for utt, want, got in disagreements[:10]:
            print(f"    {want:16s} -> {got:16s} {utt}")
    sys.exit(0)


if __name__ == "__main__":
    main()
