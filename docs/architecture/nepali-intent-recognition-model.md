# Local Intent Recognition Model for a Nepali Voice Assistant

Yes. For this project, I think a **small local intent model is a better architectural choice than asking Qwen3.5-4B to interpret every utterance**.

The closest off-the-shelf model I found is **`cartesinus/multilingual_minilm-amazon-massive-intent`**. It is about **100M parameters**, MIT licensed, and was specifically fine-tuned on Amazon's MASSIVE dataset for voice-assistant intent recognition.

MASSIVE contains more than 1M utterances covering **60 intents and 55 slot types** across assistant domains such as alarms, calendar, email, weather, music, lists, social, transport, etc.

The checkpoint reports approximately **82.34% accuracy/F1**.

Model:

`cartesinus/multilingual_minilm-amazon-massive-intent`

However, I wouldn't use that checkpoint unchanged. For a Nepali senior assistant, there is a considerably better route.

---

# Recommended Architecture

I would make the pipeline approximately:

```text
Nepali speech
      │
      ▼
     ASR
      │
      ▼
┌──────────────────────┐
│ Local Intent Model   │  ~50–270M
│ + slot extraction    │
└──────────────────────┘
      │
      ├── CALL_PERSON ─────────► native phone action
      │
      ├── SEND_MESSAGE ────────► messaging action
      │
      ├── READ_MESSAGES ───────► messages
      │
      ├── MISSED_CALLS ────────► call history
      │
      ├── SET_REMINDER ────────► reminder
      │
      ├── WEATHER ─────────────► weather
      │
      └── GENERAL_QUERY
                 │
                 ▼
          Qwen3.5-4B
```

This means Qwen doesn't even start for:

> छोरीलाई फोन गरिदेऊ।

The intent model could return:

```json
{
  "intent": "CALL_CONTACT",
  "contact": "छोरी",
  "confidence": 0.994
}
```

You can execute that through the native action layer.

For:

> आज नेपालमा के भइरहेको छ?

the model could return:

```json
{
  "intent": "GENERAL_QUERY",
  "confidence": 0.97
}
```

and **then** wake up Qwen.

This should provide much lower latency, memory usage and power consumption than putting every request through a 2–4B model.

---

# My Preferred Starting Model

## 1. AI4Bharat IndicBERT-v3-270M

My first choice would be:

**`ai4bharat/IndicBERT-v3-270M`**

This is a roughly **270M parameter bidirectional encoder** from AI4Bharat.

Most importantly, **Nepali is explicitly included among its training languages**.

The language coverage includes:

* Hindi
* Telugu
* Tamil
* Bengali
* Malayalam
* Marathi
* Kannada
* Gujarati
* Assamese
* Odia
* Punjabi
* Sindhi
* Urdu
* **Nepali**
* and others

The model family was continually trained using approximately **35 billion tokens** from corpora including Sangraha, FineWeb-2 and IndicCorpV2.

It is MIT licensed.

Because IndicBERT is **bidirectional**, it is particularly well suited to classification.

For example:

```text
मलाई भोलि ८ बजे औषधि खान सम्झाइदिनु
```

the model examines the complete utterance when deciding what the user wants.

That is exactly the kind of task BERT-style models are designed for.

---

# Why Use an Intent Encoder Instead of Qwen?

The problem is essentially:

```text
utterance → one of ~15–30 intents
```

rather than:

```text
utterance → arbitrary natural-language generation
```

A 4B autoregressive language model is overkill for the first problem.

A rough comparison:

| Requirement                      | Intent Encoder | 4B LLM |
| -------------------------------- | -------------: | -----: |
| Latency                          |          ★★★★★ |     ★★ |
| RAM usage                        |          ★★★★★ |     ★★ |
| Battery efficiency               |          ★★★★★ |     ★★ |
| Determinism                      |          ★★★★★ |    ★★★ |
| Classification consistency       |          ★★★★★ |   ★★★★ |
| General reasoning                |              ★ |  ★★★★★ |
| Handling completely new requests |             ★★ |  ★★★★★ |

The two models therefore complement each other.

The intent classifier handles common actions.

Qwen handles the long tail.

---

# MASSIVE Is Extremely Relevant

Amazon's **MASSIVE** dataset is useful because it was specifically designed around **intelligent voice assistant interactions**.

Its intents include examples such as:

```text
alarm_set
alarm_remove
alarm_query

calendar_set
calendar_query
calendar_remove

email_sendemail
email_query

weather_query
news_query

lists_createoradd
lists_query
lists_remove

datetime_query

audio_volume_up
audio_volume_down
audio_volume_mute

play_music
play_radio
play_podcasts

transport_taxi
transport_query
```

MASSIVE contains approximately:

* **60 intents**
* **55 slot types**
* **18 scenarios**
* more than **1 million utterances**
* **52 languages**

This makes it a very good source dataset for your project.

However, MASSIVE doesn't solve Nepali for you.

I would borrow its **training methodology and intent/slot structure**, rather than necessarily using its final taxonomy.

---

# Another Strong Option: SetFit

Another architecture I would test is **SetFit**.

SetFit uses a sentence encoder followed by a very lightweight classifier.

Conceptually:

```text
Nepali text
    │
    ▼
Sentence encoder
    │
    ▼
384-dimensional embedding
    │
    ▼
Linear classifier
    │
    ▼
CALL_CONTACT
```

A recent study using MASSIVE-style intent routing reported approximately **91.1% intent classification accuracy with only eight examples per class**, with inference on the order of a few milliseconds in its benchmark environment.

That makes SetFit particularly interesting for your use case because your intent taxonomy is relatively small.

---

# NyayaBench Is Also Worth Using

Another dataset worth looking at is **NyayaBench v2**.

It contains approximately:

* 8,514 real-world agent interactions
* 528 fine-grained intents
* 20 higher-level intent classes
* 63 languages

A fully fine-tuned BERT classifier achieved around **97.3% accuracy** on the English 20-class task in the published evaluation.

However, multilingual transfer was considerably weaker.

That reinforces an important point for your project:

> **Train on actual Nepali examples rather than relying entirely on multilingual zero-shot transfer.**

---

# mmBERT Is Another Excellent Candidate

I would also benchmark:

### `jhu-clsp/mmBERT-small`

Approximately:

**140M parameters**

and potentially:

### `jhu-clsp/mmBERT-base`

Approximately:

**307M parameters**

mmBERT was trained on more than **3 trillion tokens across more than 1,800 languages** and was specifically designed to improve low-resource multilingual representation learning.

It is particularly interesting as a potential **small production model**.

There is already an intent-classification ecosystem around mmBERT.

For example:

`llm-semantic-router/mmbert-intent-classifier-lora`

is an mmBERT model trained for semantic intent routing.

Its existing taxonomy is not useful for your project because it predicts categories such as:

```text
biology
business
chemistry
computer science
economics
...
```

But the architecture and training approach are directly relevant.

---

# Candidate Ranking for This Project

| Candidate                         | Parameters | Already Intent-Trained? | Nepali Strength | Recommendation                   |
| --------------------------------- | ---------: | ----------------------: | --------------: | -------------------------------- |
| **IndicBERT-v3-270M**             |       270M |                      No |           ★★★★★ | **My #1 base model**             |
| **mmBERT-small**                  |      ~140M |                      No |            ★★★★ | **Potential production student** |
| **MASSIVE MiniLM**                |  ~100–120M |                     Yes |              ★★ | Excellent teacher/baseline       |
| **mmBERT intent classifier**      |      ~307M |                     Yes |            ★★★★ | Useful training recipe           |
| **SetFit + multilingual encoder** |   ~20–150M |              Fine-tuned | Depends on base | Very interesting                 |
| **Qwen3.5-2B/4B**                 |       2–4B |     General instruction |           ★★★★★ | Long-tail fallback               |

My expected production outcome would probably be around **50–150M parameters**, after distillation.

---

# Don't Train Only Intent Classification

This is an important distinction.

Consider:

> रामलाई भन कि म आज अलि ढिलो आउँछु।

The intent might be:

```text
SEND_MESSAGE
```

But that alone isn't sufficient.

You also need:

```text
recipient = राम
message = म आज अलि ढिलो आउँछु
```

Or consider:

> भोलि बिहान नौ बजे डाक्टरलाई फोन गर्न सम्झाइदिनु।

You need:

```text
intent = SET_REMINDER

slots:
    time = tomorrow 09:00
    task = call doctor
```

So I would train **joint intent recognition + slot filling**.

Conveniently, MASSIVE itself uses this structure:

* 60 intents
* 55 slot types

Architecturally:

```text
                      ┌── Intent head ─────► SEND_MESSAGE
IndicBERT encoder ────┤
                      │
                      └── Token head ──────► recipient / content / time / etc.
```

Both tasks can be handled in a single encoder pass.

---

# Your Intent Taxonomy Can Be Much Smaller Than MASSIVE

I would not use all 60 MASSIVE labels.

For the first version of your senior assistant, something like this may be enough:

```text
CALL_CONTACT
CALL_BACK
ANSWER_CALL

SEND_MESSAGE
READ_MESSAGE
REPLY_MESSAGE
CHECK_MISSED_CALLS

SET_REMINDER
LIST_REMINDERS
CANCEL_REMINDER

CHECK_TIME
CHECK_DATE
CHECK_WEATHER

OPEN_APP

GENERAL_QUESTION
CASUAL_CHAT

HELP
REPEAT
CANCEL

UNKNOWN
```

That is roughly **15–25 primary intents**.

Then associate slots with individual intents.

For example:

```text
CALL_CONTACT
    contact
    relationship
```

```text
SEND_MESSAGE
    recipient
    message_text
```

```text
SET_REMINDER
    datetime
    recurrence
    reminder_text
```

```text
WEATHER
    location
    date
```

```text
OPEN_APP
    app_name
```

A taxonomy of this size should be considerably easier to make reliable.

---

# I Would Make the Classifier Hierarchical

Instead of immediately predicting among 20–30 very similar intents, first classify the broad category:

```text
ACTION
QUESTION
CONVERSATION
SYSTEM
UNKNOWN
```

Then classify the subtype:

```text
ACTION
    ├── CALL
    ├── MESSAGE
    ├── REMINDER
    └── APP
```

Then potentially:

```text
MESSAGE
    ├── SEND_MESSAGE
    ├── READ_MESSAGE
    ├── REPLY_MESSAGE
    └── CHECK_MESSAGES
```

This gives you two benefits:

1. Better separation between similar intents.
2. Better safety around actions.

For example:

```text
ACTION      0.61
QUESTION    0.35
```

should probably **not execute an action**.

Instead, send the request to Qwen or ask for clarification.

---

# Distillation Makes a Lot of Sense

Since you're willing to distill, I would use approximately this training process.

## Teacher

Use:

**Qwen3.5-4B**

to generate and label a large Nepali training corpus.

Start with:

* MASSIVE
* NyayaBench-style examples
* your own intent taxonomy
* manually written Nepali phrases
* eventually real anonymised user utterances

Then generate multiple versions of each command.

---

# Generate Different Forms of Nepali

## Formal Nepali

```text
कृपया मेरी छोरीलाई फोन गरिदिनुहोस्।
```

## Ordinary Spoken Nepali

```text
छोरीलाई फोन गरिदेऊ।
```

## Very Colloquial Nepali

```text
छोरीलाई एकचोटि फोन लगा त।
```

## Romanised Nepali

```text
chori lai phone gardinu
```

## Nepali-English Code Switching

```text
mero daughter lai call gardinu
```

## ASR-Like Output

```text
chori lai fon gardinu na
```

I'd explicitly generate examples from the kinds of speech patterns older Nepali speakers are likely to use.

For important intents, you could generate something like:

**1,000–10,000 utterances per intent**

and then manually review a carefully selected subset.

---

# Proposed Distillation Pipeline

I would roughly use:

```text
Qwen3.5-4B
      │
      │ synthetic + labelled Nepali data
      ▼
IndicBERT-v3-270M
      │
      │ knowledge distillation
      ▼
50–150M student model
```

The 270M model becomes the high-quality NLU teacher.

Then you shrink it for the phone.

---

# The Final Model Could Be Very Small

I would initially aim for:

> **50–150M parameters**

rather than a 1B model.

Very roughly, before runtime overhead:

```text
INT8

50M params   ≈ 50 MB
100M params  ≈ 100 MB
150M params  ≈ 150 MB
```

Further quantisation or platform-specific compression could potentially reduce that more.

The model only needs to process short utterances.

Typically something like:

```text
5–30 tokens
```

rather than large contexts.

This means inference can potentially be extremely fast.

---

# UNKNOWN Is One of the Most Important Intents

I would explicitly train:

```text
UNKNOWN
```

or:

```text
GENERAL_QUERY
```

Otherwise, a classifier will try to force every utterance into one of your known actions.

For example:

> मेरो घुँडा किन दुखेको होला?

means roughly:

> Why might my knee be hurting?

You definitely don't want the model incorrectly forcing that into something like:

```text
SET_REMINDER
```

or:

```text
CALL_CONTACT
```

I'd create a very large out-of-domain dataset containing:

* general questions
* stories
* partial speech
* accidental microphone activation
* TV dialogue
* medical questions
* recipes
* politics
* family conversation
* irrelevant commands
* noise-corrupted ASR transcripts

and explicitly label these as:

```text
UNKNOWN
```

or:

```text
GENERAL_QUERY
```

Those then get routed to Qwen.

---

# Confidence-Based Routing

I would make confidence part of the architecture.

For example:

```text
confidence >= 0.95
        │
        └── execute safe/common intent

confidence 0.75–0.95
        │
        └── Qwen verifies interpretation

confidence < 0.75
        │
        └── clarification / conversational fallback
```

You can also vary the threshold based on the action.

For harmless operations such as:

```text
CHECK_TIME
CHECK_WEATHER
```

you can tolerate a somewhat lower threshold.

For consequential actions such as:

```text
SEND_MESSAGE
CALL_CONTACT
DELETE_REMINDER
```

you can use a higher threshold and/or confirmation.

For example:

> "Do you want me to call Sita?"

before actually initiating the call.

---

# One Architecture I Would Not Recommend Initially

There are speech models that perform:

```text
audio → intent
```

directly.

Some Wav2Vec2/HuBERT models, for example, have been trained against the SLURP spoken-language-understanding dataset.

Technically, this means you could skip ASR.

I would **not** do that for this project.

You need the transcript anyway for:

* recipient names
* message content
* reminder text
* dates and times
* LLM fallback
* UI transcript
* confirmation
* logging/debugging with user permission

Therefore:

```text
ASR → text NLU
```

is a cleaner architecture.

---

# My Recommended Implementation

If I were implementing this component now, I would begin with:

> **`ai4bharat/IndicBERT-v3-270M` → fine-tune jointly for intent classification and slot filling → distill later.**

I would use:

### MASSIVE

For:

* voice assistant taxonomy
* intent classification structure
* slot filling structure

### NyayaBench v2

For:

* messy real-world agent requests
* compound requests
* out-of-domain behaviour

### Qwen3.5-4B

As the teacher for:

* Nepali synthetic generation
* Romanised Nepali
* English/Nepali code switching
* paraphrasing
* ASR corruption variants
* intent labelling
* slot annotation

### Your Own Nepali Dataset

For the actual production domain.

This ultimately matters the most.

---

# Benchmark mmBERT-Small as the Student

I would also explicitly benchmark:

**`jhu-clsp/mmBERT-small`**

because if a roughly **140M model** gets within around 1–2 percentage points of IndicBERT-v3-270M after fine-tuning, I would probably prefer it for the final on-device deployment.

The resulting architecture could therefore become:

```text
                    ┌─────────────────────────┐
Speech ──► ASR ───► │ mmBERT / IndicBERT NLU │
                    └────────────┬────────────┘
                                 │
                ┌────────────────┼────────────────┐
                │                │                │
                ▼                ▼                ▼
             CALL           REMINDER          MESSAGE
                │                │                │
                ▼                ▼                ▼
          Native APIs       Native APIs       Native APIs

                                 │
                           UNKNOWN / QUERY
                                 │
                                 ▼
                           Qwen3.5-4B
                                 │
                                 ▼
                                TTS
```

---

# Bottom Line

You probably **do not need a 1B model for intent recognition**.

For a tightly defined senior-assistant taxonomy, I think there is a very realistic path toward a:

> **50–150M parameter local Nepali NLU model**

handling most routine assistant commands.

My preferred development path would be:

```text
1. Design 15–25 production intents
2. Define slot schemas
3. Start with MASSIVE examples
4. Generate Nepali variants with Qwen3.5-4B
5. Include formal, spoken, Romanised and code-switched Nepali
6. Fine-tune IndicBERT-v3-270M
7. Train joint intent + slot heads
8. Add a strong UNKNOWN/OOD class
9. Add confidence-based routing
10. Distill into mmBERT-small or another ~50–150M student
11. Keep Qwen3.5-4B as the long-tail reasoning fallback
```

For this particular application, I think this architecture is actually **better than trying to make a 2B–4B LLM do everything**.

The intent model handles the predictable 80–90% of interactions cheaply and deterministically, while the LLM remains available for the genuinely conversational or ambiguous cases.
