# Health triage & medication knowledge — feature spec (owner-directed, 2026-10-19)

Status: DESIGN SPEC — implementation in waves (prompt changes first, then the add-time research pipeline, then training-data augmentation).

## 1. The problem

The assistant answers "I'm not feeling well" with well-wishing ("hope you feel well") — passive, unhelpful, and the exact AI-flavored behavior an elderly-care product must never have. The owner's directive: complaint turns must lead an active HELP flow, not close the loop.

## 2. Health-triage dialogue flow

On a health complaint turn ("सन्चो छैन", "दुखेको छ", "i'm not feeling well"):

1. **Acknowledge + ask what's wrong** — "के भयो? कहाँ दुखेको छ?"
2. **Medication ask** — "औषधि खानुभयो?" — naming the pending dose when the scheduler has one ("बिहानको प्रेसरको चक्की खानुभयो?")
3. **Missed-dose hypothesis** — cross-reference the app's own adherence data + the medication knowledge base: "बिहानको चक्की छुटेको देखिन्छ — चक्कर आउनु त्यससँग सम्बन्धित हुन सक्छ।" Phrased as a possibility, never a cause.
4. **Possible causes** — internal knowledge and/or web (cloud grounding, consent-gated): "यस्तो पनि हुन सक्छ…" — never assertive, never a diagnosis.
5. **Guide to the right help**:
   - Serious (सास फेर्न गाह्रो, छाती दुख्यो, लडेँ, रगत) → emergency arm (call/ambulance), immediately
   - Moderate → offer concrete calls: "छोरालाई बोलाऊँ? डाक्टरलाई बोलाऊँ?" (user's "हो" routes into the existing call confirmation + dial flow)
   - Mild → rest guidance + safety line ("बिग्रियो भने भन्नुहोस् न।")
6. **Doctor deferral is the default close** — "डाक्टरलाई भेट्नुहोस्" — diagnosis and treatment always deferred.

## 3. Safety boundaries (non-negotiable)

- **Never instruct taking medication** — no doses, no timing, no "take X now"
- **Never assert a diagnosis** — possibilities only ("हुन सक्छ")
- **Reminders only from the app's own schedules** — never invented
- **Informational dosage content** shown as "सामान्यतया…" reference only
- **Well-wishing is banned** from health replies — it answers nothing

## 4. Medication knowledge base (add-time research)

Every time a medication is added (screenshot/manual/photo):

1. Extract the drug name (OCR from the saved screenshot — the meds mirror already reads photos)
2. **Research pass**: purpose, side effects, typical dosages, when to take (food timing, time of day), warnings — via web search + Gemini grounding when on-device knowledge is insufficient
3. Store a structured **medication knowledge record** (purpose / side-effect list / dosage reference / timing / warnings) in the on-device encrypted store
4. Reminders become informed: "प्रेसरको चक्की खाने बेला भयो" — the assistant knows why the med matters

**Consent posture (owner call recorded):** researching a medication sends the drug name to the cloud/web — health data egress. Same discipline as cloud chat: explicit opt-in ("औषधिको जानकारी खोज्न अनुमति दिनुहुन्छ?") through the existing consent machinery; declined → knowledge base builds from on-device data only.

**Triage integration:** the missed-dose hypothesis cross-references side effects — "चक्कर आउनु तपाईंको चक्कीको सम्भावित साइड-इफेक्टसँग मिल्छ — खानुभयो हजुर?" — and the med-ask explains each med's purpose.

## 5. Visual med-ask

When a missed dose is named and the user asks "कुन चाहिँ हो?" / "what medicine?":

- The app shows the **saved photo of that medication** in the conversation card
- Reply copy: **"यो औषधि हो"** — NOT "यो हो हजुर"
- Same for regular reminders ("प्रेसरको चक्की खाने बेला भयो" → "कुन?" → picture)
- No new capture flow — the schedule already stores images; this is the linkage (active med-ask context + entry image → surface it)

## 6. Style refinements (owner-directed)

- **हजुर sparingly** — at most once per reply, at a natural juncture (opening acknowledgment or agreement). Never per-sentence, never stacked. Over-politeness stacking reads as fake AI.
- Respectful register unchanged: तपाईं + honorific verb agreement (the 0.98 honorific gate), the particle budget (है/नि/ला), ≤2 short sentences.

## 7. Implementation waves

| Wave | What | Where |
|---|---|---|
| 1 | Triage + safety persona rules (both personas: on-device chat + cloud), हजुर budget, med-photo reply copy | prompt/copy changes — one batched deploy (with the queued correction-gate + care-ask fixes) |
| 2 | Add-time medication research pipeline + knowledge record schema + consent flow | iOS service + store + Settings consent |
| 3 | Photo-on-ask linkage (active med-ask context → image card) | Home conversation UI |
| 4 | Training-data augmentation: triage dialogues (complaint → ack+ask → med-ask → missed-dose hypothesis → help routing), non-assertive cause explanations, de-हजुर post-edit | next training round on the box |

## 8. English

The v17 conversational fine-tunes are Nepali-only. English conversational quality (including triage) requires a dedicated English chat variant — a separate training ask, recorded here as open.
