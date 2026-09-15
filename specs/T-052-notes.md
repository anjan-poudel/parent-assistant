# T-052 — Continuous-Learning Signal Quality Feasibility (R&D): findings

**Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-052-continuous-learning-signal-quality-feasibility.md`
**Worktree:** `.claude/worktrees/tg10-rnd` (branch `worktree-tg10-rnd`, base master `41daeb6`).
**Scope discipline:** measurement over code and data that already exist. No production code changed, no build, no test run, no training run, no device access, no merge. Every artifact here is Markdown.

**Answer in one line.** The three claimed mining signals are **not** what the shipped store records. One of the three (correction) is derivable as a *trigger* but not as a *training row*; the other two (repeat-after-abstention, low-confidence cluster) are **not derivable at all**, because the shipped `Record` has no confidence field and no writer ever appends an abstention. The 500-record cap is **not** the binding constraint on a weekly cadence — the binding constraint is that one action and one correction type are the only things ever logged.

---

## 1. Method, and what the evidence is

**No consented real store exists.** `IntentLogStore` is device-local by design; there is no exported bundle anywhere in the repository (`find . -name '*intent-log*'` → no hits outside `.git`; the only files that mention the log are the store, the review view, its tests and the UI). Reading on-device log content that has not been exported under the family's consent is out of bounds (NFR-015), so **this task did not read one**.

What the measurement therefore rests on, and it is stronger than a fixture for the derivability question:

| Evidence class | What it is | Strength |
|---|---|---|
| **Append-site call graph** | The complete set of writers into `IntentLogStore`, found by exhaustive grep | **Complete.** Both append sites are enumerated below; there is no third writer |
| **Record shape** | The `Codable` struct itself | **Complete.** Every field is read |
| **Store mechanics** | Cap, trim threshold, trim target, read/export paths | **Complete** (and corroborated by the shipped test's own assertion) |
| **Downstream expansion factors** | `config.yaml` / `annotation_rules.yaml` values consumed by the authoring chain | **Complete** |
| **A real household's arrival rate and correction rate** | — | **UNKNOWN. Not measurable from the repository.** Reported below as a parameterised window with the break-even point named, never as a number |

Because the arrival rate is UNKNOWN, the "yield" section below is written as **arithmetic against a stated rate**, with the structural upper bound (what the code can produce at all) separated from the behavioural quantity (what a household will produce). That separation is the honest form of the answer; presenting a single fabricated rate would not be.

**Line-number note.** The task file cites `AppCoordinator.swift:4938-4944` and `:5076-5079` for the two append sites. Those citations have **drifted** — at master `41daeb6` the sites are at `:5434-5438` and `:5572-5575`. Every line number in this report was re-read at the worktree's own revision and is cited as current, not copied from the task file.

---

## 2. The shipped record shape

`IntentLogStore.Record` (`ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift:20-47`):

| Field | Type | Line | Populated by | Notes |
|---|---|---|---|---|
| `id` | `UUID` | 21 | `init` (38) | always generated, round-trips through JSON |
| `timestamp` | `Date` | 22 | `init` default `Date()` (37) | set |
| `path` | `String` | 23-24 | both sites | documented vocabulary `local \| cloud \| keyword \| cache \| override` |
| `action` | `String` | 25 | both sites | |
| `slots` | `[String: String]?` | 26-28 | both sites | resolved **values** — contact names included, by design (docstring `:12-14`) |
| `outcome` | `String` | 29-30 | both sites | documented vocabulary `confirmed \| denied \| corrected \| timeout` |
| `correctedTo` | `[String: String]?` | 31-32 | site 1 only | |
| `latencyMs` | `Int?` | 33 | **nobody** | see §3 |

**There is no confidence field and no utterance field.** Both absences are load-bearing and both are confirmed by reading the struct, not inferred: the struct is eight fields and neither is among them. The docstring's own summary of the file (`:11-14`) says the log "is TRAINING DATA" that "leaves only via the family's explicit export" — a claim TG-10's design (§4.1) already records as needing amendment by T-056.

**The `path` vocabulary is already divergent from what is written.** The field comment lists `local | cloud | keyword | cache | override` (`:23-24`), but the confirmation site writes `path: "model"` (`AppCoordinator.swift:5573`) — a value not in the documented set. Any miner that switches on a closed vocabulary must be built against the *observed* value, not the comment.

**`slots` holds resolved values, not surfaces.** Site 2 writes `"method": action.method.rawValue` (`:5574`) — an enum raw value, and site 1 writes the same. The contact is written as `action.contact.name` — a person's name. This is correct for the store's stated purpose (it is the training payload) and it is exactly why the record can never be the egress payload (design D-2, §5.1).

---

## 3. The complete set of writers — and what they never write

Exhaustive grep for `intentLogStore` across `ios/` returns **five** references: one declaration, two appends, and two reads from the review screen (`IntentLogReviewView.swift:82-83`, `:89`). The two appends:

**Site A — the correction pair.** `AppCoordinator.swift:5434-5438`, inside `handleCallConfirmationOverride` (`:5413`). Fires when the user answers a call confirmation with a *method amendment* ("होइन, फोन नै गर"):

```swift
path: "override", action: "call",
slots: ["contact": action.contact.name, "method": action.method.rawValue],
outcome: "corrected",
correctedTo: ["method": override.rawValue]
```

**Site B — the confirmed call.** `AppCoordinator.swift:5572-5575`, inside `noteConfirmedCallExecution` (`:5566`):

```swift
path: "model", action: "call",
slots: ["contact": action.contact.name, "method": action.method.rawValue],
outcome: "confirmed"
```

What follows from those two sites being the *only* two:

| Fact | Consequence for the loop |
|---|---|
| Both sites hard-code `action: "call"` | **11 of the 12 schema-v2 actions produce zero records.** `ack_med`, `set_reminder`, `send_message`, `emergency`, `health_query`, `music`, `guide`, `query`, `none`, `create_calendar_event`, `suggest_video` have no append site at all |
| Only `outcome` values `"corrected"` and `"confirmed"` are ever written | `"denied"` and `"timeout"` are documented in the field comment (`IntentLogStore.swift:29-30`) and have **no writer**. A denial — the user saying no to a proposed plan — is currently unrecorded |
| **Neither site passes `latencyMs`** | `latencyMs` is `nil` on every record ever written. The design's egress table lists a "latency bucket" (design §5.1); there is no latency data to bucket |
| Neither site passes `timestamp` | the `init` default `Date()` fires, so `timestamp` is correct — this one is fine |
| Site A records only a **method** correction | a corrected contact, a corrected action, or a corrected time produces nothing. The correction signal is narrower than "the user corrected the plan" |

**A corrected call writes two records, not one.** The override protocol (`:5413-5441`) appends the correction at site A and then re-confirms; if the user says yes, execution appends the confirmation at site B. So one corrected call costs **2 of the 500 slots**, one of which is the minable correction.

---

## 4. Per-signal derivability against `Record` as shipped

The three signals the design claims (`…continuous-learning-loop-design.md` §4.2), adjudicated against §2 and §3:

| # | Signal | Derivable from `Record`? | What is missing | Verdict |
|---|---|---|---|---|
| 1 | **Correction** — `outcome == "corrected"` + `correctedTo` | **Partly.** The *trigger* is fully derivable: filter on `outcome == "corrected"`, read `correctedTo["method"]`, read `slots["method"]`. | The **utterance**. `Record` carries no transcript, so the row format MINE must emit — `{id, utterance, action, register, source, confidence, spans, slots}` (`build_encoder_dataset.py:6-8`) — cannot be filled from a `Record` alone. `register` is also absent. | **Derivable as a pointer, not as a row.** The record says *that* a `call`-method plan was amended; it does not carry the text that must become the row's `utterance` |
| 2 | **Repeat-after-abstention** — an abstention followed by the same action | **No.** | Everything. No writer appends an abstention. The design's own definition (design §4.2) looks for "an abstention (`path == "override"` / a `nil` result re-prompted)"; the only `path: "override"` record ever written is a *correction* (site A), and it is written **after** the user amended, not when the model abstained. `outcome` has no `"abstained"` value | **0 records.** The signal as designed has no trace in the store |
| 3 | **Low-confidence cluster** — repeated low-confidence results for one action surface | **No.** | The **confidence field**. As the T-052 acceptance criteria anticipated: `Record` carries no confidence field, so this signal is not derivable today. The task file's phrasing "if that is what the measurement shows" resolves to: **it is** | **0 records.** Confirmed by reading the struct |

**Where the missing signals actually live (and why that does not rescue them).** Confidence, abstention and escalation *are* computed at runtime — they are simply never persisted:

| Value | Exists at | Persisted? |
|---|---|---|
| Encoder confidence for a decoded command | `IntentEncoderInterpreter` `.command(action, confidence, slots)` (`:534`), threshold default `0.4` (`:168`) | **No** |
| Abstention reason (`low_confidence`, `empty_after_sanitise`, …) | `IntentEncoderAbstention` (`IntentEncoderInterpreter.swift:21-37`, `lowConfidence` at `:36`) | **No** |
| Band decision (`accept ≥ 0.7`, `rephrase 0.4–0.7`, else nil) | `IntentRouter.Config.default` (`:56`), `bandChecked` (`:316-330`) | **No** — `emit("rephrase_band_dropped", …)` → bus only |
| Cascade escalation reason (`abstained` / `failed` / `subBandConfidence`) | `LocalBrainChain.EscalationReason` (`LocalBrainChain.swift:44-55`) | **No** — the cascade callback is observability-only |
| An abstention event | `emit("encoder_abstained", …, errorCode: reason.rawValue)` (`:300`, `:531`) | **No** |

The reason all of these are "No": the observability bus has exactly one shipped implementation, `ConsoleObservabilityBus` (`AppCoordinator.swift:7753-7771`), and its `emit` **prints** (`:7766-7770`) after sanitising. There is no file sink, no ring buffer, no persisted event store. Everything above is gone when the console scrolls. This is not a defect — it is the bus's stated contract (design §5.3, T-049/T-050) — but it means **the loop's two richest signals are computed on every turn and thrown away on every turn.**

**Hand-off to T-054 — the proposed capture-schema extension.** The derivability table is the schema input. Named minimally, the fields the three signals need and do not have:

1. `confidence` (a bucket or the raw number) — unblocks signal 3, and gives signal 1 a quality filter;
2. an abstention record — a third append site, or an `outcome` value plus an append whenever the ladder falls through. This is a **writer** gap as much as a schema gap: adding a field without a writer changes nothing;
3. an **utterance surface or a content-free reference to one** — unblocks turning any trigger into a row. This is the sharpest of the three, because it is the one that touches the privacy boundary: the design (D-2) forbids the transcript leaving the device, so the reference must be resolvable on-device at MINE time (T-057), not carried in the egress payload.

Constraint carried from the design (§4.1) and worth restating to T-054 because all three are additive: **any new field must be optional and defaulted.** `Record` is a `Codable` struct with no custom `init(from:)` (`IntentLogStore.swift:20-47`, `:131-137`), so a non-optional new field would make every existing on-disk line fail to decode.

The shape this measurement supports, **proposed for T-054 to accept, narrow or replace** — it is a design input, not a decision, and T-053 rules on which of these may egress:

| Proposed field | Type (optional, defaulted) | Why | Written by |
|---|---|---|---|
| `confidenceBucket` | `String?` — a fixed enumeration (`lt_0_4`, `0_4_0_7`, `ge_0_7`), **not** the raw float | Signal 3. The band edges are the router's own (`IntentRouter.swift:56`), so the bucket is a restatement of a decision already made, not a new one. A bucket is also all the egress side needs (§4 of `T-053-notes.md`), so nothing is lost by not storing the float | both existing sites + the new abstention site |
| `outcome` value `"abstained"` + a new append site | — | Signal 2. Requires a **writer**: the ladder's fall-through points are `LocalBrainChain` (`:137-168`) and `IntentEncoderInterpreter`'s abstention path (`:531`), neither of which appends today. Without the writer this is a no-op | new site (third) |
| `abstentionReason` | `String?`, closed vocabulary — the existing `IntentEncoderAbstention` raw values (`IntentEncoderInterpreter.swift:21-37`) | Rides the record above; content-free by construction, already a machine string | new site (third) |
| `surfaceRef` | `String?` — an **opaque on-device handle**, never the text | Turns every trigger into an authorable row at MINE time without the transcript entering the log or the payload. Its resolution scope (which store holds the surface, how long it lives) is T-054's and T-057's | both existing sites + the new abstention site |
| `action` vocabulary | — (no new field; a **writer** widening) | The cheapest yield win in this report (§6): site A and site B hard-code `"call"`. A single site that records the *other* actions' confirmations and corrections multiplies the addressable signal by the number of actions it covers | widened existing sites |

Two explicit **non**-proposals, recorded so they are not re-litigated: **no** new confidence *float* (the bucket is sufficient and is strictly less identifying); **no** transcript or slot-value widening (the store already holds what it needs for its own purpose, and anything more is egress risk for no mining gain — §4 of `T-053-notes.md` rules on the boundary).

---

## 5. Yield, against the floors the loop must feed

### 5.1 The floors

`build_encoder_dataset.py:359-383` enforces three floors, whose values come from `annotation_rules.yaml` (`:230-232`), read through `encoder_rules.py:175-177`:

- `stt_noised` share ≥ **0.55**
- corpus ≥ **8 000** rows
- per-action ≥ **0.25 × target** (the `0.25` is the literal in `encoder_rules.py:177`; `per_action_floor` at `annotation_rules.yaml:231` states the same rule)

The targets (`annotation_rules.yaml:51-63`) and the floors they imply:

| action | target | floor (0.25 × target) | seed templates needed to clear it (see §5.2) |
|---|---:|---:|---:|
| `call` | 1500 | **375** | 6 |
| `set_reminder` | 1200 | 300 | 5 |
| `send_message` | 1000 | 250 | 4 |
| `emergency` | 1000 | 250 | 4 |
| `query` | 1000 | 250 | 4 |
| `ack_med` | 800 | 200 | 3 |
| `health_query` | 700 | 175 | 3 |
| `music` | 600 | 150 | 3 |
| `guide` | 600 | 150 | 3 |
| `create_calendar_event` | 600 | 150 | 3 |
| `none` | 500 | 125 | 2 |
| `suggest_video` | 500 | 125 | 2 |
| **total** | **10 000** | **2 500** | |

### 5.2 The expansion factor per mined seed

A mined correction is one utterance. Fed into the existing authoring chain it multiplies:

- `gen_teacher.py` requests `gemini.variants_per_seed: 6` per register (`config.yaml:9`), over **4** registers (`annotation_rules.yaml:216`; the count is `variants_per_seed × len(registers)` at `gen_teacher.py:72`) → **24 teacher rows per seed**.
- `stt_noise.py` writes up to `stt_noise.variants_per_utterance: 2` noisy variants per row (`config.yaml:28`, used at `stt_noise.py:121`) → **up to 48 noised rows**.

**Structural upper bound: 72 rows per mined seed**, before every guard, dedup and refusal that follows. The bound is not the expectation: the round-2 evidence in `docs/OPEN-ITEMS.md:135-138` records 29 304 noised rows collapsing to **2 458 distinct utterances** (≈12 copies per text, most removed by dedup). The realistic figure is far below 72 and this report does not claim one, because no measured per-seed rate exists at this revision.

### 5.3 Can one week's mined rows move an action toward its floor?

**For 11 of the 12 actions: no, by construction.** There is no append site for them (§3), so their mined yield is exactly **0 rows per week, forever**, until a writer exists.

**For `call`: the arithmetic does not support a floor argument either.**

- The floor is 375 built rows (§5.1). At the structural upper bound of 72 rows/seed that is **6 real method-override corrections per week** with zero pipeline losses.
- But that floor is a *minimum on the built corpus*, and the synthetic supply already clears it: the held-out corpus alone carries 1 200 `call` rows (`eval/golden_corpus.jsonl`), and the `call` target is 1 500. Mined rows are **additive supply above a floor that is already met**, not the supply that meets it.
- Against the corpus floor the mined contribution is small: even a generous **6 corrections/week × 72 = 432 rows**, i.e. **5.4 %** of the 8 000-row floor, and that is the optimistic bound, not a measurement.

**Therefore, per the acceptance criterion: no single week's mined rows can be the thing that moves any action to its floor, and this report does not recommend proceeding to T-054 on the strength of the loop's accuracy benefit alone.** If the loop proceeds, it must be for the reason R-7 already names — distribution shift against *this household's* traffic, which no synthetic corpus can supply — and not for a supply argument the arithmetic does not support.

---

## 6. Roll-off under the 500-record cap

**The mechanics, read from the store and corroborated by its own test:**

- `maxRecords = 500` (`IntentLogStore.swift:49`).
- Trim fires only when the amortised count exceeds `maxRecords + 50 = 551` (`:88`), and trims to the newest `500` (`:89`). So the file oscillates between **500 and 551 lines**; `assertEqual(recent.count, maxRecords)` and "oldest 51 trimmed" in `IntentLogStoreTests.testCapTrimsOldest` (`IntentLogStoreTests.swift:36-43`) pin exactly this.
- Trimming drops a **contiguous oldest suffix**. It introduces **truncation**, not sampling skew: what survives is the newest N, unbiased *within itself*. The recency bias is therefore entirely a function of how much older than the window the signal is.

**The effective window, and the break-even.** Window (days) = 500 ÷ records-per-day:

| arrival rate | effective window | share of a 7-day week that survives |
|---:|---:|---:|
| 5 /day | 100 days | 100 % |
| 20 /day | 25 days | 100 % |
| **71 /day** | **7.0 days** | **100 % (break-even)** |
| 100 /day | 5.0 days | 71 % |
| 500 /day | 1.0 day | 14 % |

**The D-3 risk does not materialise at the only arrival rate this store can actually have.** Because both append sites are `action: "call"`, a record is written only when the household places or amends a call. The break-even is **~71 records/day**, which for a call-only store means ~71 call events per day for one elderly user — implausible by an order of magnitude. At a plausible 5–20 call events/day the window is **25–100 days**, comfortably longer than a weekly cadence.

**So which of the three does D-3 name have to change?** The design's D-3 says the cap, the cadence, or the derived-signal summary must change. The measurement says:

- **The cadence (weekly) is not the problem** — the window is weeks-to-months long at any plausible call volume.
- **The cap is not the problem either** — for `call`-only logging it is generous.
- **The derived-signal summary still has to exist**, but for a different reason than D-3 gives: not because trimming would eat the signal, but because the minable fraction of the store is small. A corrected call writes **two** records, of which one is the minable correction (§3). At a correction rate of *c* corrections per confirmed call, the minable share of the 500-slot window is `c / (1 + c)` — at a 5 % method-override rate, **~24 of 500 records** are corrections, ~2.4 per week at 20 call events/day. That is the number the loop's cost has to be justified against, and it is small.

**This is the T-052 finding of greatest consequence for T-054 and T-057:** the constraint is not the cap and not the cadence — it is **what is written**. Widening the writers (more actions, more correction kinds, an abstention record) buys far more than any change to the cap or the schedule.

---

## 7. Cross-check against the recorded flywheel cadence

The spec's cadence is "retrain monthly or at 500 corrections, whichever first" (`docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md:610`). The measurement's verdict:

- **"At 500 corrections" is unreachable.** 500 *corrections* would need 500 correction records; at the plausible rate in §6 that is years, and 500 corrections plus their paired confirmations would fill the 500-slot cap before the trigger ever fires. The trigger as written can only fire if corrections are nearly all of the traffic, which is the opposite of what the store is for.
- **"Monthly" loses to weekly on safety, not on yield.** Monthly is *safe* against the cap (a 25–100-day window mostly survives it) but it lets a week's correction sit un-mined for a month. The design's weekly proposal (D-3) beats monthly on the pipeline's own terms: `run_encoder_pipeline.py` is resumable and refuses to publish on any gate failure (`:303-330`, `:556-559`), so a week with nothing to train is cheap and a week producing a bad candidate is blocked. **Weekly is the better cadence and the measurement does not contradict it** — it simply removes the reason D-3 gave for it (that the cap would trim the signal).
- The spec's log schema (`…intent-engine-finetuned-llm-design.md:596-604`) also lists a `"resolved": {"contactId": …, "method": …}` field that the shipped `Record` does not have. Another confirmation that the spec's schema and the shipped struct have diverged — resolved ids are the one thing the loop must never egress (design §5.1), so `Record` is *more* conservative than the spec, not less.

---

## 8. Recommendation

**Proceed to T-054 only with a named schema extension, and do not justify the loop on supply.** Concretely:

1. **Stop / re-scope the "accuracy benefit" argument as the primary reason.** §5.3 shows mined rows cannot be the supply that clears any floor, and for 11 of 12 actions the yield is structurally zero. The loop's remaining justification is R-7's distribution shift, which is real but unmeasured, and which T-055's shadow scoring is the way to measure. **A "not worth it" answer on the supply argument is the correct answer on the supply argument.**
2. **Name the three extensions for T-054** (derivability table, §4): `confidence`; an abstention record *with its writer*; and an on-device-resolvable utterance reference. All optional and defaulted, because of the decode compatibility rule.
3. **Do not propose a cap or cadence change.** §6 shows neither is binding. If R-2's mitigation ("if the roll-off is severe, the cadence or the cap changes") is to be acted on, this measurement says it should not be: the roll-off is not severe.
4. **Correct the record on the two sites' `path` values.** The `Record` comment's `path` vocabulary (`IntentLogStore.swift:23-24`) is missing `"model"`, which is what is actually written (`AppCoordinator.swift:5573`). Cheap to fix, and it prevents a miner being written against a comment instead of the data.
5. **T-053's input:** what is collected today is *stricter* than the design assumed. The store contains resolved slot values (contact names) and **no transcript at all**, and it is written for one action. Consent copy that describes "what we capture" must be built on §2–§3, not on the design's intent.

---

## 9. PII and evidence discipline

- **No PII in this report.** Only counts, rates, distributions, field names and `file:line` citations. No utterance, contact name, medication name or message body appears; no hostname, credential or key. The store's own contents were not read (§1).
- **Every claim is grounded in a file read at this worktree's revision.** The two exceptions are marked **UNKNOWN** rather than asserted: the household arrival rate and the household correction rate (§1, §5.3, §6 are parameterised on them, with break-even points named).
- **Deliberately not claimed:** any measured per-seed pipeline yield (§5.2 gives the structural bound and cites the observed dedup collapse, which is from a different stage and is labelled as such); any claim about the encoder's runtime confidence distribution; anything about the loop's accuracy effect, which no measurement here can support.

## 10. Open questions this task does not resolve

1. **How would a marker for repeat-after-abstention be written without a transcript?** A content-free marker (an abstention record with `action` and a bucket) is enough to *count* repeats; it is not enough to author a row, because the row needs a surface (§4). T-054 owns the shape; T-057 owns whether the on-device join at MINE time can supply the surface.
2. **`latencyMs` is dead.** Neither site populates it and nothing reads it (grep: the field appears only in the struct and the encoder tests). Either a site starts populating it or the design's "latency bucket" (§5.1) should be struck — T-054's call.
3. **Are `denied` and `timeout` intended to be recorded?** The field comment says yes; no writer exists. A denial is a user-visible rejection of a plan and would be a genuine signal. Raised for T-054, not decided here.
4. **Does the store's 500-cap test's exact-trim assertion (`maxRecords + 51` appends → exactly `maxRecords`) hold when appends interleave with reads?** The store's `estimatedCount` is amortised (`:52-56`) and the test drives it single-threaded. Not measured here; relevant only if T-054 changes the write path.
