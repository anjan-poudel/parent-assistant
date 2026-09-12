# Local Intent Recognition: Options, Recommendation and Plan

## 1. Available Options

| Option                            | Approx. Size | Nepali Support                           | Already Intent-Trained                     | Best Use                                                          |
| --------------------------------- | -----------: | ---------------------------------------- | ------------------------------------------ | ----------------------------------------------------------------- |
| **IndicBERT-v3-270M**             |         270M | **Strong; Nepali explicitly supported**  | No                                         | Best base model to fine-tune for Nepali intent + slots            |
| **mmBERT-small**                  |        ~140M | Strong multilingual/low-resource support | No                                         | Smaller production model / distillation target                    |
| **MiniLM MASSIVE Intent**         |        ~100M | Multilingual, but not Nepali-focused     | **Yes**                                    | Good baseline/teacher; already trained on voice-assistant intents |
| **SetFit + multilingual encoder** |     ~20–150M | Depends on encoder                       | Requires fine-tuning                       | Extremely lightweight intent classifier                           |
| **mmBERT Intent Classifier**      |        ~307M | Strong multilingual base                 | Yes, but wrong intent taxonomy             | Useful training/reference model                                   |
| **Qwen3.5-2B/4B**                 |         2–4B | **Strong Nepali support**                | General-purpose, not specialist classifier | Fallback for ambiguous/general requests                           |

### Relevant datasets

**Amazon MASSIVE**

* Designed specifically for voice-assistant NLU
* 60 intents
* 55 slot types
* Useful as the foundation for intent/slot training

**NyayaBench v2**

* Real-world agent interactions
* Useful for difficult, compound and out-of-domain requests

---

# 2. Recommendation

## Recommended approach

### Fine-tune **IndicBERT-v3-270M** for joint intent recognition + slot extraction, then optionally distill it into a smaller ~50–150M model.

Use **Qwen3.5-4B only as the fallback** when the local classifier is unsure or the request is genuinely conversational.

Proposed architecture:

```text
Speech
  │
  ▼
ASR
  │
  ▼
IndicBERT Intent + Slot Model
  │
  ├── CALL_CONTACT ─────────► Native action
  ├── SEND_MESSAGE ────────► Native action
  ├── SET_REMINDER ────────► Native action
  ├── CHECK_WEATHER ───────► Native action
  │
  └── UNKNOWN / GENERAL_QUERY
                   │
                   ▼
              Qwen3.5-4B
```

## Why IndicBERT-v3-270M

The biggest advantage is that **Nepali is explicitly included in its training**, while it is still small enough to run locally.

It is also a bidirectional encoder, which is better suited to classification tasks than a generative LLM.

It gives a good balance between:

* Nepali capability
* small model size
* low latency
* deterministic classification
* ability to fine-tune
* commercial-friendly licensing
* suitability for intent + slot extraction

---

# Pros and Cons Compared With the Alternatives

## IndicBERT-v3-270M

### Pros

* Nepali explicitly supported
* Built for Indic and South Asian languages
* Strong starting representation for Nepali
* Good size for local inference
* Suitable for both **intent classification and slot extraction**
* MIT licence
* Can later be distilled into a smaller model

### Cons

* Not already trained specifically on assistant intents
* Requires custom fine-tuning
* Larger than MiniLM or a very small SetFit solution

### Verdict

**Best starting point for this project.**

---

## MiniLM MASSIVE Intent

### Pros

* Already trained on voice-assistant intent classification
* Very small at roughly 100M parameters
* MASSIVE taxonomy closely resembles the application's needs
* Fast and easy to deploy

### Cons

* Not specifically trained for Nepali
* Likely weaker on colloquial Nepali, Romanised Nepali and Nepali-English code switching
* Existing 60-intent taxonomy will not exactly match the app

### Verdict

**Excellent baseline, but not my preferred final Nepali model.**

---

## mmBERT-small

### Pros

* Only around 140M parameters
* Designed for multilingual and low-resource languages
* Good candidate for local/mobile deployment
* Potentially significantly smaller than IndicBERT

### Cons

* Not specifically optimised for Nepali
* Not already trained on the app's intent taxonomy
* Needs custom fine-tuning

### Verdict

**Excellent candidate for the eventual production/student model.**

I would benchmark it against IndicBERT after training.

---

## SetFit

### Pros

* Can be extremely small and fast
* Works well with relatively little labelled data
* Excellent for simple intent classification
* Very attractive for on-device execution

### Cons

* Slot extraction is less natural than with a token-level encoder model
* Performance depends heavily on the underlying sentence encoder
* May struggle more with ambiguous or compound commands

### Verdict

**Worth benchmarking, particularly if model size and latency become the highest priority.**

---

## Qwen3.5-2B/4B

### Pros

* Strong Nepali understanding
* Handles ambiguous and unseen requests extremely well
* Excellent reasoning capability
* Can interpret complex natural-language commands

### Cons

* Far larger than necessary for simple intent recognition
* Higher latency
* Higher memory usage
* Higher battery usage
* Less deterministic than a classifier

### Verdict

**Use as the fallback reasoning model rather than the primary intent classifier.**

---

# 3. High-Level Implementation Plan

## Phase 1 — Define the Intent Taxonomy

Start with approximately **15–25 intents**, rather than all 60 MASSIVE intents.

Example:

```text
CALL_CONTACT
C
```
