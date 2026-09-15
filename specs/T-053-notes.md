# T-053 — Learning-Loop Privacy Review (R&D): the determination

**Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-053-learning-loop-privacy-review.md`
**Worktree:** `.claude/worktrees/tg10-rnd` (branch `worktree-tg10-rnd`, base master `41daeb6`).
**Scope discipline:** documentation only. No production code changed, no build, no test run, no device access, no merge. This determination is a **binding input** to T-054, T-055, T-056, T-057 and T-058, and the audit criterion for T-059.

**Status: every ruling below is a yes/no or a number, so T-059 can check it mechanically.** Two items are escalated to the project owner rather than decided here, and they are named as such with an owner and a date (§10). Nothing in this document is a principle offered in place of a decision.

---

## 1. What is actually collected — read before ruling

The determination must not describe a collection that does not exist, or bless one that does. Read at this revision:

| Fact | Source |
|---|---|
| The log is `JSONL` in Application Support under `NSFileProtectionComplete`, **deliberately content-bearing**, "deliberately separate from `ObservabilityBus` telemetry, which stays PII-free (C9)", and "leaves only via the family's explicit export" | `IntentLogStore.swift:3-17` (the claim at `:14`) |
| The shape: `id` (UUID), `timestamp`, `path`, `action`, `slots` (resolved values, **contact names included by design**), `outcome`, `correctedTo`, `latencyMs` | `IntentLogStore.swift:20-47`; field semantics at `:26-28` |
| Exactly two writers exist, both for `action: "call"`: the method-override correction and the confirmed call | `AppCoordinator.swift:5434-5438` (`:5413`), `:5572-5575` (`:5566`) — exhaustive grep, §3 of `T-052-notes.md` |
| The observability bus is **print-only** in its shipped implementation | `AppCoordinator.swift:7753-7771` (`emit` prints at `:7766-7770`) |
| The sanitiser drops every metadata key not on its allow-list, and scrubs allowed values for phone / e-mail / blood-pressure shapes only | `LogSanitiser.swift:56-80` (keys), `:94-108` (drop), `:82-92` (patterns), `:134-147` (`scrubValue`) |
| The export path writes **plaintext** JSONL to tmp and hands it to the share sheet — recorded, unfixed | `IntentLogStore.swift:108-123`; `docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` §7 ("encryption is a producer-side gap") |
| Consent-export ingestion is **not implemented and refuses loudly** | `run_encoder_pipeline.py:596-600` (`"consent_export_ingestion": "not implemented (NFR-015); --consent-export refuses loudly"`) |
| The teacher is a cloud model: Gemini 2.5 Flash Lite | `config.yaml:7`; `gen_teacher.py:1-20` |

**Finding that changes the copy, not just the code.** The shipped privacy policy body states, in both languages, *"Nothing is sent to the cloud for AI processing"* (`Localizable.xcstrings`, key `settings.privacy.body`). Under Open Decision 12 the shipped default engine stack **is** the cloud engine (`?? .gemini` — now at `AppCoordinator.swift:1987` and `:1997`; the OD-12 entry cites `:1612-1613`, which has drifted). NFR-032 requires the policy to describe what is transmitted accurately. **The policy is therefore already inaccurate, before the loop adds anything**, and the loop's amendment (§6) must fix the OD-12 gap at the same time rather than layering a second inaccuracy on top of the first.

---

## 2. Consent basis — the determination (resolves OQ-1)

**Ruling: the loop requires its own disclosure and consent. It is not covered by Open Decision 12's scope, and it must not be described as an amendment that extends OD-12. It is a *second* consent-gated, non-default path, built on OD-12's regime as the project's template, and recorded as its own Open Decision entry.**

**The clause relied on, and why the obvious reading fails.** OD-12's scope bullet reads: *"**Scope:** voice transcription (and only that) may be sent to the configured cloud voice provider when the cloud engine stack is active… no health data, contacts, or profile content is included"* (`constitution.md:128-132`). The words "and only that" are a closed scope. A hashed-signal egress is not voice transcription, is not sent to a voice provider, and is not conditioned on the cloud engine being active. Reading the loop into that clause would make the recorded exception mean less than it says — which is precisely the failure mode OD-12 exists to prevent, since OD-12's own entry was written because a divergence had been left implicit rather than recorded.

**What carries over from OD-12, and it is the whole shape.** The constitution's Privacy standard is consent-shaped already (*"except under the recorded cloud voice-stack exception…, which requires explicit user consent and plain-language disclosure"*, `constitution.md:72-76`), and OD-12 turns that into five concrete obligations: a fixed **scope**, **explicit consent**, **plain-language disclosure at the point of selection**, a **visible indicator while the path is active**, and **a way back without losing functionality**. The loop adopts all five, with the trigger moved from "engine selection" to "settings opt-in":

| OD-12 obligation (`constitution.md:128-132`) | The loop's equivalent | Where it lands |
|---|---|---|
| Fixed scope | The **published payload schema version** (§3.6) — a closed, enumerated field list | T-054 |
| Explicit consent | A default-OFF switch whose ON requires the consent copy (§5) | T-056 |
| Plain-language disclosure **at the point of selection** | The disclosure is on the same settings card as the switch, in the user's language, before the switch can be turned on | T-056 |
| Visible indicator while active | The settings card states the state in words, and the app surfaces it wherever the family reviews data | T-056 |
| A way back without losing functionality | Opt-out deletes what has not egressed and destroys the salt; **every feature still works**, and the loop never gates the safety net, emergency path or medication acknowledgement (design §7.1, FR-009) | T-056 |

**Escalation note.** Adding a second consent-gated path is a change to the project's recorded consent regime, and the constitution's Open Decisions are owner-decided (`constitution.md:99`). The determination *recommends and specifies* the entry; **recording it is Anjan Poudel's action** (§10, item 1).

**Does a payload change require re-obtaining consent?** Yes, conditionally — ruled as a checkable rule:

- **The consent's scope is the published payload definition, at a version.** The user accepts a payload **version**, and the accepted version is recorded alongside the consent.
- **Re-consent is required** if a new version *adds a field*, *widens a field's value space* (e.g. a finer confidence bucket, a finer time resolution), or *changes a field's meaning toward content*. Egress under such a version is refused until the user accepts it — **fail closed**, not fail open.
- **Re-consent is not required** if a new version *removes* a field or *narrows* a value space. Egress may proceed under the narrower version.
- The one-line test T-059 can apply: *does the new version's permitted value space contain any value the accepted version's did not?* If yes, re-consent.

---

## 3. The egress payload ruling (resolves the design's §5.1 rule)

The design fixes the rule as *"closed-vocabulary identifiers, buckets, counters, salted hashes"* (`…continuous-learning-loop-design.md` §5.1). **The rule is blessed and narrowed by three additions.** Every ruling below is per category and binary.

### 3.1 Per-category ruling

| Category | Examples | Ruling |
|---|---|---|
| Raw audio | STT input buffers | **Never.** The app does not record it; nothing to rule on beyond keeping it that way |
| Raw transcript | the sanitised utterance text | **Never, on any loop path.** Unconditional |
| Slot values | contact names, medication names, message bodies | **Never.** Note this is *stronger* than the design assumed: `slots` is a field on `Record` (`IntentLogStore.swift:26-28`) and holds resolved values, so any implementation that serialises `Record` egresses them |
| Profile / health | thresholds, readings, schedules | **Never** |
| Closed-vocabulary identifiers | `action`, `outcome`, correction kind | **Yes.** Each must be a member of a declared enumeration (see §3.2) |
| Buckets and counters | confidence bucket, latency bucket, counts | **Yes**, with §3.3's resolution limit. **Note:** the latency bucket has no data behind it — `latencyMs` is never populated by either writer (`T-052-notes.md` §3). Ruling: **the latency bucket may not appear in the payload until a writer populates it**; a field that is always `null` is a null collector and must not be disclosed as a collection |
| Hashes | per-record identity, corpus-revision prefix | **Yes**, salted and keyed — §3.4 |
| Telemetry | divergence counts/rates, error codes | **Yes**, through `LogSanitiser`'s allow-list only — §7 |

### 3.2 No free-text field, and the field list is enumerated

- **Every string field in the payload must be a member of a declared enumeration listed in the payload schema.** A field whose value space is "a string" is **forbidden**, even if today it only ever carries an enum value. The reason is not theoretical: the sanitiser's scrub patterns (`LogSanitiser.swift:82-92`) are phone / e-mail / blood-pressure shapes and would not catch a Nepali personal name, so a value space that is "any string" is a PII hole that the current defence-in-depth does not cover.
- The payload schema is a versioned artifact. **The schema's hash is recorded with the consent version** (§2), so "what did the user actually agree to" is answerable at audit time without trusting a code comment.
- `outcome` and `action` are already enum-shaped at the writer (`AppCoordinator.swift:5435-5438`, `:5573-5575`); `path` is **not** — it carries `"model"`, a value absent from its own documented vocabulary (`IntentLogStore.swift:23-24`). Ruling: a payload field sourced from `path` must carry the **observed** closed vocabulary, and if the observed set cannot be enumerated, `path` does not egress.

### 3.3 Timestamps are day-granular and timezone-free

- **No timestamp finer than a calendar day may egress; no timezone may egress.** A precise timestamp is a linkage vector against everything else on the device, and a weekly loop cannot use finer resolution. Day granularity is the maximum.
- **`Record.id` must never egress.** It is a `UUID` (`IntentLogStore.swift:21`) — a *stable per-record identifier*, not a hash, and it would make every egressed record joinable across corpus revisions. Called out explicitly because "serialise the Record and post it" is the natural implementation mistake the risk register already names (plan.md risk 30).

### 3.4 The hash ruling — salt **required**, keyed, rotating on events only

- **Per-install salt: REQUIREMENT (required — not optional, not forbidden).** A 256-bit key, generated on-device at opt-in time, stored in the Keychain with this-device-only accessibility, never synced.
- **Mechanism: HMAC-SHA256 keyed by the per-install salt**, not a bare `SHA256(salt ‖ utterance)`. A bare salted hash is weakened the moment the salt is read; a keyed MAC keeps the key out of the egressed value entirely.
- **Egressed digest length: a 16-hex-character prefix (64 bits).** Ample for within-revision dedup, strictly less identifying than the full digest, and it keeps the project's existing "no full 40-character hash in an artifact" discipline visible at the wire.
- **Unsalted hashes are NOT acceptable.** The reasoning, made explicit as the task requires: this app's utterance space is small and predictable — a bare call command has a handful of attested surface forms, all of which appear in the shipped seed taxonomy (`tools/train-intent/seeds/intents.yaml:24-30`). An unsalted digest of a member of a small, guessable set is invertible by enumeration in seconds. **The design's §5.2 position is adopted and made binding: a hash is a pseudonym, not anonymity.** The loop's claim is *hashed and salted*, never *anonymous*.
- **Rotation: event-driven, never calendar-driven.** Rotate on (a) opt-out and (b) any explicit "delete my data" action. **Scheduled rotation is not required and is discouraged** — it would silently break the cross-revision dedup the mining stage depends on while buying no protection that salt destruction does not already give.
- **Escrow: FORBIDDEN.** The salt is never escrowed, never uploaded, never placed in a syncable keychain item, and never included in a device backup that leaves the device. **The intended failure mode, stated as a property rather than an accident: if the salt is lost, every previously egressed digest becomes permanently unlinkable to the device that sent it.** That is a feature of the design, and it is what makes the opt-out copy in §5 truthful.
- **The low-entropy rule (narrowing).** Where a closed-vocabulary identifier exists for a signal, the payload **must** carry the identifier and **must not** carry a hash of the same surface. Hashes are for per-record identity and dedup only. T-059 can check this mechanically: *no payload field may pair a closed-vocabulary value with a digest of the surface that produced it.*

### 3.5 The one-line payload test

A field may egress if **and only if** all four hold: (1) it is in the versioned schema; (2) every value it can take is a member of a declared enumeration, or it is an integer counter; (3) it is not, and does not contain, a timestamp finer than a day; (4) it is not derived from raw audio, raw transcript, a slot value, or profile/health data. Any field failing one of the four does not egress, and the version does not ship.

---

## 4. Retention (resolves OQ-3)

`IntentLogStore`'s cap is a **size** bound, not a **time** bound (`IntentLogStore.swift:49`; `T-052-notes.md` §6), and the egress side has no bound at all. Ruling: **both sides get a time bound, with a named deleter.**

| Side | Retention | Deleter | Trigger |
|---|---|---|---|
| **On-device captured signals** | **90 days from capture, or the 500-record cap, whichever bites first** | The capture layer (T-056), automatically | Time bound applied as a **filter at egress time**, so a record older than 90 days can never be sent, even if it is still on disk |
| **Egressed records** | **180 days from receipt, or 30 days after the corpus revision they fed is superseded, whichever bites first** | A scheduled deletion job owned by the project owner (T-058/T-036 tooling boundary) | Supersession is observable from the corpus-revision binding (`results.csv` carries `@<hash8>`; `eval_golden.py:505-537`) |

**Why 90 days on-device.** The measured window at plausible call volumes is 25–100 days (`T-052-notes.md` §6), and the cadence is weekly. 90 days is ~12× the cadence — never the binding constraint in normal operation — while still bounding a device that sits untouched with a stale correction on it. A bound that never triggers in normal operation and always triggers in the pathological case is what a retention policy is for.

**Why 180 days egressed.** The window must outlive at least one full retrain-plus-promotion cycle including a gate failure or two (weekly cadence) and one governance review (the constitution's own re-review cadence is 30 days; `constitution.md:95`, `:121-126`, `:128-132`). 180 days puts at least one review inside every retention window, so no egressed record is ever deleted between reviews without a human having had the chance to look at it.

**Who can delete what, and by when:**

- **The family / device owner** deletes everything on-device instantly and without asking anyone: the existing review screen's clear action (`IntentLogReviewView.swift:89`) already does this for the log, and opt-out does it for the capture layer.
- **The project owner (Anjan Poudel)** owns deletion of egressed records, and owns the job that performs it. **A deletion job that has not run is a review-time finding, not a silent omission** — recorded so T-059 has something to check.

**Opt-out semantics — the honest split, which the consent copy must state:**

- **Deleted immediately, irreversibly, on opt-out:** every on-device derived signal not yet egressed, **plus the salt.**
- **Retained:** records already egressed, under the 180-day window, with **no further egress**.
- **Why the copy may say "cannot be linked to anything you say from now on", and may not say more:** salt destruction makes future linkage arithmetically impossible, and that is a guarantee. It does **not** guarantee that an already-egressed digest is un-re-identifiable in absolute terms — the low-entropy argument in §3.4 is what bounds that, and it is a bound, not a proof. The copy is written to the guarantee and not one word past it.

---

## 5. The consent copy (deliverable, not suggestion)

**Localisation convention, so nothing is hard-coded (NFR-023/NFR-024).** All strings live in `ios/ElderlyAssistant/Resources/Localizable.xcstrings` under the `settings.learningLoop.*` prefix, with **both** an `en` and a `ne` localization, exactly as `settings.privacy.*` and `voiceSettings.*` do today. Non-View code resolves them through `L10n.str(key, locale:)` / `L10n.fmt(key, locale:, …)` (`L10n.swift:18-30`, `:53-56`); Views resolve the same keys through the environment locale (the existing `Text("intentLog.export")` literal-key form in `IntentLogReviewView.swift:27` is the ship-standard precedent). **No literal user-facing string may appear in Swift.**

### 5.1 The strings

| Key | English | Nepali |
|---|---|---|
| `settings.learningLoop.title` | Help improve the assistant | सहायक सुधार्न मद्दत गर्नुहोस् |
| `settings.learningLoop.explanation` | When you turn this on, this phone counts the times you corrected the assistant, the times it had to ask you again, and how sure it was. Only those counts, small codes (which action, which kind of correction, how sure), and one scrambled code for each sentence leave this phone. The words you say, names, medicine names and messages never leave this phone. This helps the assistant get better at Nepali. You can turn it off at any time. | यो खोल्दा, तपाईंले सहायकलाई सुधार्नुभएको, सहायकले फेरि सोध्नु परेको, र सहायक कति विश्वस्त थियो भन्ने कुराको गन्ती यही फोनले राख्छ। यही फोनबाट बाहिर जाने कुरा: ती गन्ती, साना कोड (कुन काम, कस्तो सुधार, कति विश्वस्त), र हरेक वाक्यको एउटा अव्यवस्थित कोड मात्र जान्छ। तपाईंले भन्नुभएका शब्द, नाम, औषधिका नाम र सन्देश यही फोनमा रहन्छन्। यसले सहायकलाई नेपालीमा अझ राम्रो बनाउन मद्दत गर्छ। तपाईं जहिले पनि यो बन्द गर्न सक्नुहुन्छ। |
| `settings.learningLoop.consentQuestion` | Turn this on? Nothing you say is sent — only counts and codes. | यो खोल्ने हो? तपाईंले भन्नुभएको कुरा पठाइँदैन — गन्ती र कोड मात्र पठाइन्छ। |
| `settings.learningLoop.consentConfirm` | Yes, turn it on | हो, खोल्नुहोस् |
| `settings.learningLoop.consentCancel` | Not now | अहिले नहोस् |
| `settings.learningLoop.indicator` | Sharing counts and codes: ON | गन्ती र कोड पठाउने सुविधा: खुला छ |
| `settings.learningLoop.indicatorOff` | Sharing counts and codes: OFF | गन्ती र कोड पठाउने सुविधा: बन्द छ |
| `settings.learningLoop.neverLeaves` | Your words, contact names, medicine names, messages and health information never leave this phone, on any setting. | तपाईंका शब्द, सम्पर्कका नाम, औषधिका नाम, सन्देश र स्वास्थ्य जानकारी कुनै पनि सेटिङमा यही फोनबाट बाहिर जाँदैनन्। |
| `settings.learningLoop.optOut` | Turn off and delete | बन्द गरी मेट्नुहोस् |
| `settings.learningLoop.optOutConfirm` | Turn this off? Everything not yet sent is deleted right away. What was already sent is kept for up to 6 months, but it can no longer be linked to anything you say from now on. The assistant keeps working exactly as it does now. | यो बन्द गर्ने हो? अहिलेसम्म नपठाइएका सबै कुरा तुरुन्तै मेटिन्छन्। पहिले पठाइसकेका कुरा बढीमा ६ महिनासम्म राखिन्छन्, तर ती अब तपाईंले अबदेखि भन्ने कुनै पनि कुरासँग जोडिन सक्दैनन्। सहायक अहिले जस्तै चलिरहन्छ। |
| `settings.learningLoop.optOutCancel` | Cancel | रद्द गर्नुहोस् |

**Three copy rulings, stated so they are not softened in implementation:**

1. **The copy says "6 months", not "180 days".** Months are the unit the reader lives in; the retention *rule* is 180 days (§4) and the two must not be allowed to drift — a change to the rule changes this string.
2. **The copy never uses a word the reader would not use.** No "anonymised", no "aggregate", no "telemetry", no "hash". "Scrambled code" and "counts and codes" are the register of the existing shipped copy (`settings.privacy.body`), and staying in it is the point.
3. **The copy does not promise more than §4 delivers.** It says what is deleted now, what is kept, and the one thing salt destruction guarantees. It does not say the loop is anonymous, and it does not say the data cannot be used — it says it cannot be *linked to what you say from now on*.

### 5.2 The visible indicator

OD-12 requires *"a visible indicator while a cloud engine is active"* (`constitution.md:128-132`). The loop's equivalent, ruled concretely: **the settings card must state the state in words in both languages** (`settings.learningLoop.indicator` / `.indicatorOff`), and the same state must be readable from the screen the family already uses to review what the assistant recorded (`IntentLogReviewView`). A switch that is on but invisible on the review surface is **not** compliance with this ruling — the family reviews the data, so the family sees the state.

---

## 6. NFR-032 — the privacy-policy amendment

**The shipped policy is already inaccurate (§1). The loop does not get to add to that.** The amendment below fixes both in one pass and is delivered as replacement text for `settings.privacy.body` in both languages.

**Proposed `settings.privacy.body` (replacement):**

- **English.** "Your voice, health information, contacts, and conversations stay on this phone. The assistant can work fully on this phone. If you choose the Gemini voice engine, what you say is sent to Google to be written down as text; you can switch to an on-device engine at any time in Settings and keep every feature. If you turn on 'Help improve the assistant', only counts, small codes, and one scrambled code for each sentence leave the phone — never your words. Health data is only read from HealthKit with your permission. Family notifications are sent only when a configured alert fires."
- **Nepali.** "तपाईंको आवाज, स्वास्थ्य जानकारी, सम्पर्क र कुराकानी यही फोनमा रहन्छन्। सहायक यही फोनमै पूरै चल्न सक्छ। यदि तपाईं जेमिनी आवाज इन्जिन छान्नुहुन्छ भने, तपाईंले भन्नुभएको कुरा लेखाइको रूपमा परिणत गर्न Google मा पठाइन्छ; तपाईं जहिले पनि सेटिङमा गएर यन्त्रमै चल्ने इन्जिन छान्न सक्नुहुन्छ र सबै सुविधा यथावत् रहन्छ। यदि तपाईं 'सहायक सुधार्न मद्दत गर्नुहोस्' खोल्नुहुन्छ भने, गन्ती, साना कोड र हरेक वाक्यको एउटा अव्यवस्थित कोड मात्र फोनबाट बाहिर जान्छ — तपाईंका शब्द कदापि जाँदैनन्। स्वास्थ्य जानकारी तपाईंको अनुमतिमा मात्र HealthKit बाट पढिन्छ। परिवारलाई सूचना तोकिएको अलर्ट सक्रिय भएमा मात्र पठाइन्छ।"

**What this amendment does and does not claim.** It *does* name the cloud voice transit as the OD-12 exception already requires (`constitution.md:128-132`). It *does* name the loop's payload. It does *not* claim the loop is anonymous, and it does *not* claim nothing is transmitted — the current text's failure is exactly that it makes the second claim.

**Not in scope for this determination, flagged rather than silently skipped:** the export path writes **plaintext** JSONL (`IntentLogStore.swift:108-123`; strategy doc §7). An unencrypted bundle handed to a family member is a third collection surface, and NFR-032's "how it is stored" clause arguably reaches it. It is recorded here so it is not lost; fixing it is a device-side follow-up outside T-053 (the same conclusion the T-036 strategy doc reached).

---

## 7. Shadow mode — the privacy protocol (binding on T-055)

The design puts shadow scoring in §4.5 and owns the full protocol in T-055. **This determination rules only on what shadow scoring may collect and what may leave**, because a second interpreter scoring the same turn is a new processing of user content and the determination must say whether it is a new collection.

**Ruling: it is not a new collection, and no separate consent is required, because it processes only content the app already processes for the active brain, and it persists none of it.** The following are conditions of that ruling — break any one and it *becomes* a new collection requiring its own consent:

1. **Both outputs are discarded.** Neither the candidate's nor the active brain's interpretation is persisted, logged, or egressed. Only a divergence *summary* may persist.
2. **Only the summary leaves, and only through the allow-list.** Divergence telemetry rides `ObservabilityBus` (design §4.5), and therefore `LogSanitiser`. The bus's shipped implementation is print-only (§1), so this telemetry is **diagnostic, not retained** — if T-055 wants divergence retained across sessions it must be retained as counters in a dedicated content-free store, and **the ruling forbids doing that by widening the bus**. The bus's contract (PII-free local diagnostics) is what T-049/T-050 hardened; the loop's egress is deliberately a separate path (design §5.3), and so is any retained divergence counter.
3. **New allow-listed keys must be declared in `LogSanitiser`, and each must have a declared bounded value space.** The design already requires the declaration (§4.5). This determination adds the second half, and it is the half that matters: the sanitiser's scrub patterns (`LogSanitiser.swift:82-92`) catch phone / e-mail / blood-pressure shapes and **would not catch a Nepali name**, so the allow-list is the boundary and a key whose values are "any string" is a hole in it. Permitted keys and their value spaces:

| Proposed key | Value space | Source of the value space |
|---|---|---|
| `divergence_count` | integer ≥ 0 | computed |
| `divergence_rate_bucket` | a fixed enumeration of bands (e.g. `none`, `lt_5pct`, `5_25pct`, `gt_25pct`) — **not** a float | T-055 fixes the band edges |
| `action_id` | the 12 schema-v2 action values | `annotation_rules.yaml:31-43` |
| `escalation_reason` | `abstained`, `failed`, `subBandConfidence` | **already exists** — `LocalBrainChain.EscalationReason`, `LocalBrainChain.swift:44-55` |

4. **No shadow event may carry the transcript, either output, a slot value, or `Record.id`.**
5. **Shadow scoring stays off the reply path** (design §7.2, NFR-002's 4-second budget). This is a safety-adjacent constraint, not a performance preference: a slower reply is a harm to the primary user, and the loop is not permitted to cause one.

**Reusing what exists.** `EscalationReason` (`LocalBrainChain.swift:44-55`) is already a closed, content-free vocabulary that the cascade emits today, and `TurnTimingRecorder`'s `.cascadeDecision` stage (`LocalBrainChain.swift:146`, `:163`) already measures the decision off the reply path. **T-055 should build divergence telemetry on those two, not invent parallel ones** — a second vocabulary for the same fact is how a "content-free" key drifts into carrying content.

---

## 8. The promotion rule — the governance ruling (binding on T-058)

The design's rule (§6) is *all eight T-038 gates pass **AND** the candidate beats the incumbent on the corpus-revision-bound eval*, with D-4's human publish gate on top. T-053's interest is the human half, and the ruling is three constraints:

1. **The gate wires no deployment, and this is a consent-relevant requirement, not just a process preference.** D-4 exists because a machine gate measures the corpus and cannot measure whether a change is appropriate for *this household, this week*. Automating the publish would mean a change to what the user's assistant does without a person deciding — which is a different act from the one the consent copy describes. The rule can only **block**; publishing stays a human action through the existing `ModelStore` path (`run_encoder_pipeline.py` already refuses without an explicit artifact version and on any harness failure, `:303-330`, `:556-559`).
2. **A publish under a new payload version requires the privacy review to have cleared that version.** If the loop's payload version changes (§2), the next publish needs a fresh review by the project owner before it can be promoted. This is the hook that keeps the loop's consent honest across iterations, and it is checkable: the published artifact records the payload version it was trained under, and the owner's review is a recorded item. *(This constraint is T-053's; the comparison mechanics — including what "the incumbent" is per configuration, design OQ-4 — are T-058's and are not decided here.)*
3. **The fail-soft ladder is unchanged and is not a consent matter.** The ladder is the runtime healing guarantee (design §4.5) and it sits downstream of the keyword safety net (`CommandRouter.swift:707-715`; the design's `:651`, `:1429` citations have drifted). The loop may not gate it, and the promotion rule may not use it as a reason to publish earlier.

---

## 9. OQ-2 — the teacher-transit tension, ruled (this blocks T-057)

**The question.** `gen_teacher.py` uses a cloud teacher (Gemini 2.5 Flash Lite, `config.yaml:7`; `gen_teacher.py:1-20`). Feeding a *real user utterance* as a seed sends that text to the teacher. Does the family's export consent cover that transit?

**RULING: NO. The existing consent does not cover it, and no mined row may be fed to the teacher until a consent that names third-party teacher transit exists and has been accepted.**

The reasoning, from the recorded governance rather than from preference:

- The T-036 governance admits consented exports into the training batch "only for consented correction/gold sampling", and states the admission rules as *"no pipeline stage reads on-device log content except the exported bundle"* (`docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` §7). **"Admitted into the training batch" and "transmitted to a third-party AI service" are different acts.** The first is a statement about which stage may read the bundle; the second is a disclosure to a processor.
- The repository already records that this path is not implemented and refuses loudly: `"consent_export_ingestion": "not implemented (NFR-015); --consent-export refuses loudly"` (`run_encoder_pipeline.py:596-600`). That refusal is the current, honest state — no real user utterance has been admitted at all yet.
- NFR-015 forbids transmitting personal data to a cloud service **for AI processing** (`requirements.md:262-263`). A cloud teacher paraphrasing a real user utterance *is* AI processing of personal data. Reading the export consent as covering it would be exactly the misreading §2 rejects for OD-12.
- The family's export consent, as it exists, is consent to hand a file over — not consent to a named third party receiving the text inside it. A consent cannot be widened by inference.

**What this blocks, and what it does not.** Blocked: feeding a **mined real utterance** to `gen_teacher.py`. Not blocked: everything else. The hashed channel (D-2) is unaffected — it never carried text. On-device mining is unaffected. Teacher expansion of the **synthetic** seed taxonomy (`seeds/intents.yaml`) is unaffected: those rows are not user data and are what the pipeline does today. And the design already requires the loop to be buildable both ways (§4.3: *"The loop must be buildable both ways: the hashed channel (D-2) is unaffected either way"*), so the fallback is the design's own, not an invention of this review:

> **Carried forward for T-057: mined rows may enter the corpus as direct rows (validated, lower-trust, deduped, guard-checked as usual), and may not be sent to the teacher for rephrase expansion, until an explicit teacher-transit consent item exists and the user has accepted it.**

**This is escalated, not decided unilaterally, because the constitution's Open Decisions are owner-decided (`constitution.md:99`)** — see §10, item 2.

---

## 10. Open items: resolved and escalated

| # | Item | Status |
|---|---|---|
| **OQ-1** | Own disclosure vs. amendment to OD-12 | **RESOLVED (§2).** Own disclosure and consent, built on OD-12's regime, recorded as its own Open Decision entry. **Escalated to Anjan Poudel to record the entry in `constitution.md`** (§10.1) |
| **OQ-2** | Does the family's export consent cover teacher transit? | **RESOLVED (§9): NO.** T-057 is blocked from feeding mined rows to the teacher. **Escalated to Anjan Poudel for the decision whether to add an explicit teacher-transit consent item** (§10.2) |
| **OQ-3** | Retention window | **RESOLVED (§4).** 90 days on-device (or the cap), 180 days egressed (or 30 days after revision supersession); deleters named; opt-out semantics fixed |
| **OQ-4** | What "the incumbent" is per configuration | **Not T-053's.** Explicitly left to T-058 with its implementation context; noted in §8 only for the human-publish half |

**Escalation 1 — record the second consent-gated path.** Owner: **Anjan Poudel (project owner)**. Action: add an Open Decision entry to `constitution.md` recording the loop's opt-in hashed-signal path with the five OD-12-shaped obligations (§2), and note in the OD-12 entry that the project now has two consent-gated, non-default paths whose disclosures are separate. **Review by 2026-10-13**, aligned with OD-11, OD-12 and the post-deploy monitoring bullet (`constitution.md:95`, `:121-126`, `:128-132`). Reason it is escalated rather than decided: the constitution's Open Decisions are owner-decided (`constitution.md:99`), and a recorded exception is the owner's act by construction.

**Escalation 2 — the teacher-transit consent decision.** Owner: **Anjan Poudel (project owner)**. Action: decide whether to add an explicit consent item naming third-party teacher transit, or to keep the loop teacher-free for real utterances permanently. **Until that decision, the §9 ruling holds and T-057 must implement the teacher-free path.** Reason it is escalated: it decides whether real user text may reach a named third party, which is a product-level consent decision, not an engineering one — and it is a decision that would apply to the whole T-036 export path, not only to the loop.

**Review cadence for this determination itself.** Owner: **Anjan Poudel. Review by 2026-10-13**, folded into the existing cadence (OD-11, OD-12, post-deploy monitoring) rather than inventing a parallel one, as the task brief requires. The determination is re-reviewed **and its rulings re-checked against the shipped payload** at each review; a payload version change (§2) triggers a review ahead of the date rather than waiting for it.

---

## 11. PII and secret discipline

- **No PII in this document.** No utterance, contact name, medication name, message body, health value, hostname or credential appears. The consent copy in §5 and the policy text in §6 are the only user-facing prose, and they contain no example data.
- **No full hash and no credential-shaped value.** The only hash-shaped value named is the interface: "a 16-hex-character prefix of a keyed digest", described, never instantiated. Nothing in this document is a real key, salt or digest.
- **Deliberately not asserted:** that salted hashing makes the payload anonymous (§3.4 says the opposite, and the copy in §5 is written to that limit); that the loop's accuracy benefit justifies the collection (T-052's measurement says it does not clear any floor — `T-052-notes.md` §5); that the export-encryption gap is fixed (it is not, §6).

## 12. Hand-off

| Task | What this determination gives it |
|---|---|
| **T-054** | The per-category payload ruling (§3.1), the four-part payload test (§3.5), the enumerated-schema requirement and the schema-hash-with-consent rule (§3.2), the day-granularity and no-`Record.id` rules (§3.3), the HMAC/per-install-salt/16-hex/rotation/escrow rulings (§3.4), and the payload-version rule (§2). Also the capture-side field proposal it must accept or narrow: `T-052-notes.md` §4 |
| **T-055** | §7 in full: the not-a-new-collection conditions, the four permitted telemetry keys with their value spaces, the "do not widen the bus" ruling, and the instruction to reuse `EscalationReason` and the `cascadeDecision` timing stage |
| **T-056** | §5's exact strings and the localisation convention; the indicator ruling (§5.2); the opt-out semantics (§4); the fail-closed behaviour on an unaccepted payload version (§2); the NFR-032 text (§6) |
| **T-057** | §9: **the block on teacher transit** and the teacher-free fallback it must implement until the escalation is decided |
| **T-058** | §8: no deployment wiring; the publish-under-a-new-payload-version review hook |
| **T-059** | Every ruling in §2–§4 and §7 as a checkable criterion: payload-version match against recorded consent, the four-part field test, the no-`Record.id` rule, the timestamp granularity, the salt's accessibility class and non-escrow, both retention clocks, the opt-out's two halves, and the four telemetry keys' value spaces |
