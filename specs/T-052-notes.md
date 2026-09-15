# T-052 — Continuous-Learning Signal Quality (Feasibility, R&D) (rev 2)

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-052-continuous-learning-signal-quality-feasibility.md`
- **Worktree:** `.claude/worktrees/t052-signal-feasibility` (branch `worktree-t052-signal-feasibility`, base `7289b95`, which contains `f2cbbab`).
- **Scope discipline:** measurement over code and data that already exist. No production code changed, no build, no test run, no training run, no device access, no merge, no push. Every artifact here is Markdown.
- **Supersedes:** rev 1 of this file, landed at `331db76` (`worktree-tg10-rnd`, base `41daeb6`). Rev 1's text is preserved in git at that commit; **it should not be cited as current.**

**Revision note — what rev 2 is, and why it exists.** Rev 1 measured the capture layer as it stood before `f2cbbab` (`[INTENTLOG-CAPTURE] Widen flywheel capture to every confirm-tier verdict`). That commit landed after rev 1 was written and changed the thing rev 1 was measuring: the record gained `confidence` and a *live* `latencyMs`, the two writers became one seam with seven callers, `denied` and `timeout` gained writers, and a tolerant `init(from:)` replaced direct `Codable` synthesis. Four of rev 1's load-bearing findings are therefore **stale as facts** — most importantly its central one ("`Record` carries no confidence field, so the low-confidence signal is not derivable") — and its proposed schema extension over-corrects for a gap that no longer exists. Rev 2 re-derives every ruling against the code in *this* tree, cites line numbers as they are here, and records each re-decided ruling in the delta table in §12 so nothing is silently re-ruled. Two arithmetic corrections are also carried: the anchor divisor is 0.60, not the 0.55 hard floor (§7.3), and a mined utterance expands to `1 + 0–1` corpus rows, not "up to 48", because `stt_noise.py` is deterministic (§7.5). Rev 2 adds what the task brief asks for and rev 1 did not supply: a capture-rate estimate (§5), mining rules with acceptance thresholds (§8.3), an explicit comparison against the synthetic teacher supply (§9), and the conditions attached to the verdict (§10).

**Status:** complete as an R&D measurement; the quantities that need a pilot are named as UNKNOWN and parameterised, not asserted.

**Answer in one line.** Of the design's three claimed mining signals, **one is now half-derivable, one is still not derivable at all, and one is derivable but cannot become a training row.** The missing field is **not** confidence — the widening added that, and it works. The missing field is the **utterance**: `IntentLogStore.Record` still carries no transcript and no join key to one, so a captured record tells the miner *that* a specific plan was rejected at a specific confidence for a specific contact, and never *how the elder said it*. **Verdict: FEASIBLE-WITH-CONDITIONS** — the capture layer is now sufficient to drive a *trigger*, not a *corpus*; the conditions are in §10.

---

## 0. Verdict

### 0.1 The verdict

# **FEASIBLE-WITH-CONDITIONS**

Narrower verdicts, so the verdict is not read more broadly than it was measured:

| Question | Verdict | Where |
|---|---|---|
| Is the widened capture layer sufficient to drive a **trigger** (a retrain signal, an addressing cursor)? | **YES** | §3.2, §4 |
| Is it sufficient to produce a **training row**? | **NO — the yield is 0 rows today** | §4, §8.2 |
| Is the missing field **confidence**? | **NO.** Confidence ships and is populated for every voice-originated `call` | §3.4 |
| Is the 500-record cap the binding constraint on a weekly cadence? | **NO** — break-even is ~71 records/day sustained | §6.2 |
| Is the weekly-over-monthly rationale (D-3) sound as written? | **NO** — its stated reason contradicts the cap's own sizing | §6.3 |
| Can the loop be justified on **supply** (moving an action's floor)? | **NO** — 10 of 12 actions are 0 by construction; `call` is redundant supply | §7.6 |
| Is `create_calendar_event` a mining source? | **NO** — its capture carries no slots, no confidence, no title | §3.1, §3.4 |
| Is the "teacher-rephrased" acceptance rule available? | **YES — owner decision 2026-09-15** (T-053 §9 amended: the family's export consent covers teacher transit; whitelisted mined rows may be teacher-rephrased under C-1/C-3/D-1) | §8.3, §9 |
| Is the pipeline open to real rows today? | **NO** — `real_user_rows: 0`; `--consent-export` refuses | §8.4 |

### 0.2 What the loop can and cannot mine, in one line

The capture layer records **that** a plan was confirmed, denied, corrected or timed out, at what confidence and after how long — for **two** actions — and it records **no text at all**, so the loop can count, age and address its signal but cannot yet author a single row from it.

### 0.3 The head-line findings

| # | Finding | Grounded in |
|---|---|---|
| **F-1** | The widening did real work: `confidence` exists, is populated for every voice-originated `call`, and `latencyMs` is live. Rev 1's three pessimistic premises are all out of date | §2, §3.1, §3.4 |
| **F-2** | The record still carries **no utterance and no join key to one**. This is the single field that turns a trigger into a row, and it is still absent | §3.1, §4.1 |
| **F-3** | One append seam, **seven** callers, **four** verdicts, **two** actions (`call`, `create_calendar_event`). **10 of 12** schema-v2 actions produce zero records by construction | §3.2, §3.3 |
| **F-4** | Capture is the **narrow tail** of app traffic: `call` needs the LLM path, a unique contact match, a handle gate and a yes/no/45 s; `create_calendar_event` shipped 2026-09-13 with no behavioural history | §5.1 |
| **F-5** | Capture rate is **UNKNOWN by measurement**; the planning range is **~5–40 records per household-week**, right-tailed, and the store's own sizing implies ≤ ~16.7/day | §5.2 |
| **F-6** | The cap is **not** binding (break-even ~71 records/day sustained, and the store holds everything until its 552nd record). The real addressing gap is the absence of a **mined cursor** | §6.2, §6.3 |
| **F-7** | The corpus floor means **`n_noised` ≥ 4,800** (the anchor divides by **0.60**, not the 0.55 hard floor). Adding clean rows cannot move the anchor; only the noised bucket can | §7.3 |
| **F-8** | Two capture defects distort counts: a **timed-out confirmation is not terminal** (one interaction, two records), and a correction's derived `confirmed` twin carries the **rejected** plan's confidence | §3.5 |
| **F-9** | The measured supply reality: the built corpus is **2,561 rows** against the 8,000 floor with **all three floors waived**, and only **2,458 distinct** noised texts exist against the 4,800 the anchor needs | §7.4 |
| **F-10** | The loop's minable gold is **2–6 corrected/denied records per household-week**, and the current schema can deliver **none** of them. The loop reaches exactly the gap it cannot fill (`create_calendar_event`) and misses the action it could (`call`) | §5.3, §8.2, §9 |

---

## 1. Method, and what the evidence is

**No consented real store exists in the repository.** `IntentLogStore` is device-local by design (`IntentLogStore.swift:17-21`); there is no exported bundle anywhere in the tree, and reading on-device log content that has not been exported under the family's consent is out of bounds (NFR-015). **This task did not read one.** No behavioural quantity below is presented as measured unless it is measured from code or from a file in this worktree.

| Evidence class | What it is | Strength |
|---|---|---|
| **Record shape** | the `Codable` struct and its tolerant decoder | **Complete** — every field read (`IntentLogStore.swift:26-88`) |
| **Append-site call graph** | the complete set of writers into the store | **Complete** — enumerated by exhaustive grep, not sampled (§3.2) |
| **Reachable-verdict matrix** | which (action, outcome) pairs the shipped flows can produce | **Complete** — derived from the append call sites plus `ConfirmationTier` |
| **Cap mechanics** | trim threshold, write-back size, amortisation | **Complete**, and corroborated by the shipped test |
| **Fixture behaviour** | the `IntentLogStoreTests` cases | **Complete** — they exercise the verdict mapping and the cap |
| **Corpus supply/targets** | the T-034 target table, the AUGMENT floors, the golden corpus, the T-036 measure of the built corpus | **Complete** — read from the files that enforce and report them |
| **Household arrival rate** | records per household-day | **UNKNOWN — parameterised.** The repository records no usage telemetry, and this report does not invent one (§5.2) |
| **Verdict mix** (confirmed/denied/corrected/timeout split) | the share each outcome takes | **UNKNOWN — parameterised.** No field or log records it; §5.3 gives a sensitivity table instead of a number |

**Line-number note.** The task file cites `IntentLogStore.swift:20-47` for the record shape and `AppCoordinator.swift:4938-4944` / `:5076-5079` for the two append sites. All three have drifted. At this revision the record is `:26-88`, the seam is `:7127-7132` and the writer sites are the seven in §3.2. Every `file:line` in this report was read in this worktree at this revision and is cited as current, not copied from the brief.

---

## 2. What the widening changed — every rev-1 claim re-adjudicated

`f2cbbab` changed five files (`App/AppCoordinator.swift`, `App/IntentLogReviewView.swift`, `Services/Intents/IntentLogStore.swift`, `Resources/Localizable.xcstrings`, `ElderlyAssistantTests/Services/Intents/IntentLogStoreTests.swift`). Against the claims the design and rev 1 make about what is recorded:

| Claim (design §4.2/§8.2, and rev 1 §2–§4) | Status at this revision |
|---|---|
| "The two append sites are the correction pair and the confirmed call" | **Superseded.** One seam with **seven** callers, four verdicts, two actions (§3.2) |
| "`confidence` is not derivable — `Record` carries no confidence field" | **Resolved.** `confidence: Double?` exists (`IntentLogStore.swift:50`) with a tolerant decoder (`:76-87`) and is populated for every voice-originated `call` record (§3.4) |
| "`latencyMs` is dead — nobody writes it and nothing reads it" | **Resolved.** Computed as the question→verdict span by `Capture.latencyMs(at:)`, floored at 0, nil when the start is unknown (`IntentLogStore.swift:256-259`) |
| "`denied` and `timeout` are documented but have no writer" | **Resolved.** Two callers each (§3.2 rows 4–7) |
| "`Record` is a plain `Codable` struct with no custom `init(from:)` — a non-optional new field breaks every existing on-disk line" | **Superseded as a fact, retained as a rule.** A tolerant `init(from:)` now exists (`:76-87`; pinned by `IntentLogStoreTests.testLegacyRecordWithoutConfidenceDecodes`, `:86-104`), so a legacy line missing `confidence`/`latencyMs` still decodes. The decode-compatibility *requirement* stands; the claim that no mitigation exists does not |
| "`path`'s documented vocabulary is missing the values actually written" | **Unchanged.** The comment lists `local`/`cloud`/`keyword`/`cache`/`override` (`:30`) while the only writable values are `"model"` (the `Capture.record` default, `:243-247`) and `"override"` (the correction site) (§3.5c) |
| "the remaining actions' outcomes are not logged at all today" | **Half-resolved.** `create_calendar_event` gained a writer; the other **10** actions remain at zero (§3.3) |
| "A corrected call writes two records, not one" | **Retained and extended.** Still true — and a *timed-out* confirmation is not terminal either, so it can also write two (§3.5a, §3.5b) |
| "Neither site passes `timestamp`; the `init` default fires, so this one is fine" | **Unchanged.** Correct then and now |

**What did *not* change: the record still has no utterance field and no utterance join key.** The design's D-2 egress model is built on "hashed-only, content does not leave", which presumes a hash *of* an utterance exists to send. It does not (`IntentLogStore.swift:26-88`). This is the single most consequential finding in this report (F-2).

---

## 3. The capture layer, as shipped

### 3.1 Record shape (`IntentLogStore.swift:26-88`)

| Field | Type | Written by | Observed vocabulary |
|---|---|---|---|
| `id` | `UUID` | `Record.init` | fresh per record — **no join key to any other store** |
| `timestamp` | `Date` | verdict time | — |
| `path` | `String` | `Capture.record(path:)` | **observed: `"model"`, `"override"`** (§3.5c) |
| `action` | `String` | pending action's `capture` | **observed: `"call"`, `"create_calendar_event"`** |
| `slots` | `[String: String]?` | pending action's `capture` | `call`: `{contact, method}`; calendar: **`nil`** (`AppCoordinator.swift:5176-5184`) |
| `outcome` | `String` | the verdict | `confirmed` / `denied` / `corrected` / `timeout` |
| `correctedTo` | `[String: String]?` | correction only | `{method: <CallMethod>}` |
| `confidence` | `Double?` | `sourceCommand?.confidence` | `call`: **always non-nil** except touch-originated; calendar: **always `nil`** |
| `latencyMs` | `Int?` | question→verdict | nil when `requestedAt` is unknown; floored at 0 |

**No field carries text.** There is no `utterance`, no `transcript`, no `utteranceHash`, and no foreign key into `IntentCommandCache` (which *does* hold normalized transcript → command, `IntentCommandCache.swift:70-103`). A miner holding only a `Record` cannot produce a row: the row format requires a non-empty `utterance` (`build_encoder_dataset.py:1-20`), and the pipeline's own row validator rejects a row whose `confidence` will not parse (`:241-248`).

**The verdict→record mapping is single-sourced.** `IntentLogStore.Verdict` (`:197-207`) is the persisted vocabulary, and `Capture.record(_:path:correctedTo:at:)` (`:243-255`) is the only place a verdict becomes an `outcome` string — which is why the seven callers cannot disagree about what `"corrected"` means.

### 3.2 The append sites (exhaustive)

`grep -rn "intentLogStore" ios/ElderlyAssistant/` returns exactly five references: one declaration (`AppCoordinator.swift:1467`), **one** append (`:7131`, inside `appendCapture`), and two reads plus a delete in the review screen (`IntentLogReviewView.swift:82`, `:83`, `:89`). There is no third writer. `appendCapture` (`:7127-7132`) has seven callers:

| # | Line | Verdict | Action | Capture identity | Notes |
|---|---|---|---|---|---|
| 1 | `AppCoordinator.swift:5301` | `confirmed` | `create_calendar_event` | `PendingCalendarEvent.capture` | written on the **write**, not on the "yes" |
| 2 | `:5481` | `corrected` | `call` | `PendingCallAction.capture` (the **original**, rejected plan) | `path: "override"`, `correctedTo: {method: …}` |
| 3 | `:5617` | `confirmed` | `call` | `PendingCallAction.capture` | written only on a **successful open** |
| 4 | `:7141` | `timeout` | `call` | pending call | 45 s window |
| 5 | `:7143` | `timeout` | `create_calendar_event` | pending event | 45 s window |
| 6 | `:7197` | `denied` | `call` | pending call | |
| 7 | `:7222` | `denied` | `create_calendar_event` | pending event | |

### 3.3 Reachable-verdict matrix

`ConfirmationTier` classifies the twelve schema-v2 actions (`ConfirmationTier.swift:17-34`):

- **`confirm` tier (4):** `call`, `sendMessage`, `setReminder`, `createCalendarEvent`
- **`neverGated` (2):** `emergency`, `ackMed`
- **`free` (6, incl. `plugin`):** `music`, `suggestVideo`, `guide`, `healthQuery`, `query`, `none`

The capture layer covers **2 of the 4 confirm-tier actions and 2 of the 12 taxonomy actions**:

- **`call`** — all four verdicts (§3.2 rows 2, 3, 4, 6).
- **`create_calendar_event`** — all four verdicts (§3.2 rows 1, 5, 7).
- **`send_message`** — **not captured.** No yes/no verdict exists to record; the compose sheet *is* the confirmation.
- **`set_reminder`** — **not captured.** Executes immediately; no verdict.
- **`ack_med`** — **not captured.** `neverGated`, with a scheduler-owned flow.
- **The remaining 8** — **not captured, and never can be under this design**: they are `free` tier, so no confirmation is ever pended and there is no verdict to record.

So **10 of 12 actions yield exactly zero records by construction**, and that is a property of the confirmation flow, not of the store.

### 3.4 Confidence coverage — the widening's real win

`InterpretedCommand.confidence` is a non-optional `Double` (`LlamaCommandInterpreter.swift:129`), and the call-confirmation path is reached only from the router's interpreted path with a non-nil `sourceCommand` (`CommandRouter.swift:2388-2391`, `AppCoordinator.swift:5406`). Therefore:

- **every voice-originated `call` record carries a non-nil confidence**, including records whose command arrived via an intent-cache hit (`IntentCommandCache.command(for:)` returns a full `InterpretedCommand`);
- **every `create_calendar_event` record carries `nil`** — deliberately, and for a good reason: `PendingCalendarEvent.capture` carries no slots and no confidence because the event title is user content with no reviewed capture policy (`AppCoordinator.swift:5176-5184`), pinned by `IntentLogStoreTests.testCalendarPendingEventCaptureHasNoSlots` (`:237-251`).

So "low-confidence cluster" is **derivable for one action and structurally impossible for the other**. Any cluster rule must be written action-conditionally or it will silently read `nil` as "low confidence" for 100% of calendar records.

### 3.5 Three defects in the widened path that affect signal quality

All are observations, not fixes — `IntentLogStore` and `AppCoordinator` are outside T-052's scope by its own brief.

**(a) A timed-out confirmation is not terminal, so one interaction can write two records.** The timeout handler records the verdict and clears only `pendingConfirmationEntryId` and `pendingRephrase` (`AppCoordinator.swift:2079-2091`); `pendingCallAction` and `pendingCalendarEvent` are cleared in exactly two places, both inside `handleConfirmationResponse` (`:7188`, `:7212`). Because the router routes the *next* transcript as a yes/no whenever the coordinator reports it is awaiting a confirmation (`CommandRouter.swift:631`, `:683-700`), a late "yes" after a window expiry executes the action and appends a **second** record for the same pending action. One interaction → a `timeout` record **and** a `confirmed` record.

**(b) A correction writes a pair, and the second half is derived, not observed.** `handleCallConfirmationOverride` appends `corrected` for the original plan and then re-pends an **amended** action that inherits the original's `sourceTranscript` and `sourceCommand` (`AppCoordinator.swift:5456-5486`). A subsequent "yes" therefore appends a `confirmed` record whose `slots["method"]` is the *amended* method but whose `confidence` is the **rejected** interpretation's. One interaction → a `corrected` record **and** a `confirmed` record, and the confirmed record's confidence attribution is wrong. The code comments this as intentional for the cache (the original→corrected pair); for mining it means the confirmed half must not be counted as an independent sample.

**(c) `path`'s documented vocabulary is still wrong.** The field comment lists `local | cloud | keyword | cache | override` (`IntentLogStore.swift:30`) while the only values the code can write are `"model"` (the `Capture.record` default) and `"override"` (the correction site). One of five documented values is real. Any T-054 payload field sourced from `path` must be validated against the **observed** vocabulary, not the comment.

---

## 4. Acceptance scenario 1 — per-signal derivability

The three claimed signals, measured against `Record` as shipped. "Derivable" means *recoverable from a `Record` alone, without reading any other store*.

| # | Signal (design §4.2) | Fields it needs | **Derivable from `Record`?** | **Usable as a training row?** |
|---|---|---|---|---|
| 1a | **Correction — the trigger** ("a correction happened, of this kind, at this confidence, for this contact") | `outcome == "corrected"`, `correctedTo`, `slots`, `confidence` | **YES — `call` only.** `correctedTo` is only ever written at `:5481`; no other action has a correction protocol | n/a (a trigger is not a row) |
| 1b | **Correction — the training pair** (original plan → negative row, amended plan → gold row) | + the **original utterance** and the **correction utterance** | **NO.** Neither is stored. The original's `sourceTranscript` is held in memory on `PendingCallAction` and never written; the correction utterance reaches `handleCallConfirmationOverride(utterance:)` and is **discarded after the method keyword is parsed** (`:5456-5458`) | **NO — 0 rows** |
| 2 | **Repeat-after-abstention** | a record of an abstention, then the same action again | **NO — structurally.** `Verdict` has exactly four raw values, all confirm-tier verdicts (`IntentLogStore.swift:197-207`); an abstention never pends a confirmation, so no append site is reachable. The searchers confirm the seven call sites in §3.2 are the complete set | **NO — 0 rows** |
| 3a | **Low-confidence cluster — `call`** | `confidence` + (to make a row) the utterance | **PARTIAL.** The confidence half is now derivable and populated (§3.4); the utterance half is not | **NO — 0 rows** without an utterance source |
| 3b | **Low-confidence cluster — `create_calendar_event`** | `confidence` | **NO.** The capture deliberately omits it (`:5176-5184`) | **NO — 0 rows** |

**Explicitly, as the acceptance scenario requires:** *"low-confidence cluster" was not derivable when T-052's brief was written and is now derivable for `call` only*; it remains **not derivable for `create_calendar_event`**, not because the field is missing from the schema but because the capture seam declines to populate it. The brief's statement that "`Record` carries no confidence field" is **no longer true** and must not be carried into T-054 unamended (rev 1's proposed `confidenceBucket` was a response to exactly that stale premise — §12).

### 4.1 The field the schema actually still needs

Not confidence. Confidence ships. What is missing is **one of**:

1. an `utterance: String?` field on `Record` — the raw sanitised transcript, written at verdict time from the value the flow already holds (`PendingCallAction.sourceTranscript`); or
2. an `utteranceKey: String?` — a per-install-salted hash of the normalized transcript, plus an on-device lookup the miner runs where the content is (design D-2's "MINE runs where the content is", §4.1). The normalized-transcript → command map already exists in `IntentCommandCache` (`:70-103`), but it is capped at 200 LRU entries (`:42`) and gated to three cacheable actions (`:51-65`), so it is a *partial* index, not a complete one.

**This report recommends (2) — the join key — for the log, and (1) only if T-053's consent determination concludes that the log itself may hold text.** Rev 1 offered `surfaceRef` as one option among three; the widening has since removed the other two from the schema discussion, and the reasoning that favours a key over the text is T-053's (§12 records the change of emphasis). Either shape satisfies the design's hashed-only egress **only if the transcript itself never leaves the device**; both are strictly more useful than the status quo, and (1) is strictly more sensitive than (2).

---

## 5. Acceptance scenario 1 (continued) — the capture rate

### 5.1 What has to be true for a record to exist

A record is written only when a **confirm-tier action reaches a confirmation and the confirmation resolves**. For the two covered actions that means:

- **`call`**: the utterance took the **LLM-interpreted** path — the deterministic keyword layer blocks call-ish phrases unconditionally and has no entity extraction (`CommandRouter.swift:2381-2388`) — the interpreter returned action `call` at confidence **≥ 0.4** (below that the router abstains; accept at ≥ 0.7, rephrase band 0.4–0.7, `IntentRouter.swift:56-58`, `:316-330`), `ContactResolver` returned exactly **one** match (ambiguous and not-found prompt and pend nothing), the resolved method passed the Messenger-handle pre-gate, and the elder then answered yes/no or let 45 s elapse.
- **`create_calendar_event`**: the interpreter extracted a non-empty `topic` **and** a parsable time, and calendar access was not denied/restricted — three separate honest dead ends, each of which pends nothing and writes nothing (`CommandRouter.swift:2340-2369`). The flow itself shipped **2026-09-13**, so it has no behavioural history to reason from.

Each of those gates removes records. The capture layer is therefore the **narrow tail** of the app's interaction volume, not a sample of it.

### 5.2 Arrival rate — parameterised, with the anchors that exist

**UNKNOWN by measurement.** The repository records no usage telemetry: there is no usage-volume figure anywhere in `requirements.md` (its NFRs are latency/availability/security only), and the per-turn observability events that would allow counting (`command_dispatched_to_llm`, `CommandRouter.swift:1170`) go to the observability bus, whose only shipped implementation prints sanitised lines to the console (`ConsoleObservabilityBus`, `AppCoordinator.swift:7831`) — no sink, no counter, no export.

What the code and design *do* fix:

| Anchor | Value | What it implies |
|---|---|---|
| `IntentCommandCache.maxEntries` | 200 (`IntentCommandCache.swift:42`) | the repetitive-command vocabulary is sized at O(100) *distinct phrases*, not turns |
| `RepetitionGuard.maxRecords` / `windowSeconds` | 50 / 600 s (`RepetitionGuard.swift:22`, `:27`) | **bursts are a recognised pattern**: repeated same-target confirmations inside ten minutes are a dementia pattern the design hardens against. A 50-record buffer is the designer's answer to "how many can pile up" |
| `VoiceSessionStateMachine.confirmationTimeoutSeconds` | 45 s (`VoiceSessionStateMachine.swift:95`) | an upper bound on how many confirmations can be *outstanding*, not on how many occur |
| Gemini cost model's "generous usage" | "dozens of exchanges/day/household" (`docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md:289`) | the only recorded per-day *usage* figure, and it is a design-time envelope, not a measurement |
| `GeminiCostGovernor.defaultSoftDailyCap` | 200 calls/day (`GeminiCostGovernor.swift:50`) | a circuit breaker, not an expectation; relevant only as an upper bound on cloud-bound turns |

**Estimate, stated as a range with its shape.** Records per household-week, for the two covered actions:

| Household | Records/day | Records/week | Shape |
|---|---|---|---|
| Light (assistant used occasionally; calendar flow untouched) | 0–0.5 | **0–3** | mostly zero days |
| Typical engaged | 1–3 | **7–20** | a handful of call confirmations a week |
| Heavy / repetition episode | 10–60 | **70–400** | episodic, not sustained; bounded in practice by the 45 s window and the repetition guard |

**The range to plan against is 5–40 records per household-week**, with the median nearer 10. It is **heavily right-tailed**: the interesting engineering case is not the median day but the repetition episode, which can put dozens of records in the store in an hour. **This is the report's least reliable number, and it is parameterised rather than asserted** — the design's R-1 asks whether the signal is worth the loop, and the honest answer is that no one can say from this repository until a pilot produces a log.

### 5.3 Verdict mix — sensitivity, not a number

The split between confirmed / denied / corrected / timeout is **UNKNOWN**: nothing records it, and the four are not equally interesting (a correction is the gold, a confirmation is the bulk, a timeout is often just an elder who walked away). Rather than invent a split, here is the arithmetic at the plausible ends, applied to a 20-record week:

| Assumption | corrected | denied | timeout | confirmed |
|---|---|---|---|---|
| Confirmation-heavy (elder answers, mostly yes) | 2 | 2 | 1 | 15 |
| Correction-heavy (the model is still bad for this household) | 6 | 4 | 5 | 5 |

**Only the `corrected`/`denied` columns are signal the teacher cannot synthesise.** That is **2–6 records per household-week** in the worked range — and, per §4, currently **0 usable rows** from them.

---

## 6. Acceptance scenario 3 — roll-off under the 500-record cap

### 6.1 Mechanics, read from the store

- `maxRecords = 500` (`IntentLogStore.swift:90`).
- Trim fires only when `estimatedCount > maxRecords + 50` (`:129`), i.e. **above 551**; the write-back keeps the newest `maxRecords` (`:130-132`), and `estimatedCount` is set to the retained count.
- Therefore the store holds **every record ever written until the 552nd**, and thereafter between **500 and 551** records. The shipped test pins this: `maxRecords + 51` appends leave exactly 500 records with the oldest 51 dropped (`IntentLogStoreTests.swift:29-45`).
- `recent(limit:)` reads the whole file and returns the newest `limit` (`:141-143`); `count` reads the whole file (`:145`). There is no time-window query, and no record of what has already been mined.

### 6.2 The effective window

With `R` = records/day, the retained window is `500 / R` days, and the fraction of a 7-day window that survives to a weekly retrain is `min(1, 500 / 7R)`:

| R (records/day) | week's records | fraction of the week surviving | retained window |
|---:|---:|---:|---:|
| 1 | 7 | **100%** | 500 days |
| 5 | 35 | **100%** | 100 days |
| 16.7 (the cap's own implied sizing) | 117 | **100%** | 30 days |
| 50 | 350 | **100%** | 10 days |
| **71.4** | 500 | **100%** — the break-even | **7 days** |
| 100 | 700 | 71% (oldest 29% lost) | 5 days |
| 200 | 1400 | 36% (oldest 64% lost) | 2.5 days |

**The cap is not the binding constraint at any plausible rate.** Break-even is **71 records/day sustained**, which for two confirm-tier actions means a confirmation every 20 minutes, all day, every day. Even the repetition-episode case in §5.2 is episodic, and the whole-store-holds-everything regime extends to the 552nd record, so a store that has never trimmed keeps its entire history.

**Recency bias is a boundary effect, not a sampling bias.** Trimming drops the **oldest** records, so within whatever survives there is no age-related under-representation — the store is a *censored* window, not a weighted sample. At `R > 71.4` the loss is a contiguous prefix: the earliest days of the week vanish first, and a weekly miner would silently see a 5-day week and read it as a 7-day one.

### 6.3 What actually has to change — and it is neither the cap nor the cadence

**The cap survives measurement. The weekly cadence's stated rationale does not.**

D-3 justifies weekly over the spec's monthly cadence on the grounds that a monthly cadence can roll the signal out of the window before it is ever mined. From §6.2 that is true only above **~16.7 records/day** — which is exactly the rate the 500-cap was sized against for a *monthly* cadence. The two recorded positions contradict each other: the cap was chosen on the assumption that a month fits inside it, and D-3 was written on the assumption that a month does not. At the §5.2 estimate the cap does not bind at **either** cadence.

Where weekly still wins: latency-to-benefit (a correction is learned a week sooner, not a month), and the T-036 pipeline's resumability makes an empty or failing weekly run cheap (`run_encoder_pipeline.py:303-330`). Those are real, but they are *not* the reason D-3 gives.

**The thing that has to change is the addressing.** The store has no notion of "already mined": no cursor, no `minedAt`, no digest, and `Record.id` is a fresh UUID that joins to nothing (§3.1). A weekly miner reading `recent(limit:)` would re-read the **same** records every week — the signal does not roll off, it *accumulates in place*, and every week's run would re-mine all of it. The `lossless_key` dedup in the build makes that idempotent rather than harmful, but it also means week N's mine is not "new signal" — it is the same signal, and no measurement of the loop's *marginal* value is possible without a high-water mark. **A mined-cursor or a compact derived-signal digest is required for the weekly cadence to mean anything**, which is precisely the artefact T-054 is already charged with ("a compact derived-signal summary that survives trimming"). This report supplies the evidence that T-054's digest is load-bearing for **addressing**, not for **survival**.

---

## 7. Acceptance scenario 2 — yield against the AUGMENT floors

### 7.1 The floors, as enforced

`build_encoder_dataset.py:31-35` (module docstring) and the frame-floor check (`:364-382`): `stt_noised` share **≥ 0.55**, corpus **≥ 8000 rows**, per-action **≥ 0.25 × target** — violation is exit 4 unless waived with a recorded reason. The values come from `annotation_rules.yaml:230-232` and are read into `EncoderRules.floors` at `encoder_rules.py:175-177` (`per_action_min_frac: 0.25` at `:177`). The targets (`annotation_rules.yaml:51-63`) and their floors:

| action | target | per-action floor (0.25×) | mined rows available |
|---|---:|---:|---|
| `call` | 1500 | **375** | the only action with any (and none usable today, §4) |
| `set_reminder` | 1200 | 300 | 0 |
| `send_message` | 1000 | 250 | 0 |
| `emergency` | 1000 | 250 | 0 |
| `query` | 1000 | 250 | 0 |
| `ack_med` | 800 | 200 | 0 |
| `health_query` | 700 | 175 | 0 |
| `music` | 600 | 150 | 0 |
| `guide` | 600 | 150 | 0 |
| `create_calendar_event` | 600 (proposed) | 150 | 0 usable rows (§4, signal 3b) |
| `none` | 500 | 125 | 0 |
| `suggest_video` | 500 (proposed) | 125 | 0 |
| **total** | **10,000** | **2,500** | |

### 7.2 The synthetic side is *target-driven*, so scarcity is not the problem it looks like

`gen_teacher.py` does not generate "as much as it can" — it generates **to the target**. `rows_per_job = gemini.variants_per_seed × len(registers)` = **6 × 4 = 24** rows per job (`gen_teacher.py:71-72`; `config.yaml:9`; registers at `gen_teacher.py:288-289`), and it enqueues `ceil((target − already_have) / 24)` jobs per intent, **cycling a handful of templates** because paraphrase diversity comes from sampling temperature, not template count (`gen_teacher.py:94-131`). The seed templates behind those targets are few — `call` 7, `emergency` 6, `music` 4, and 3 each for `send_message`, `set_reminder`, `health_query`, `guide`, `query`, `none` — expanded over entity banks (`seeds/intents.yaml`).

Two consequences for the loop's claim on supply:

- **The per-action floors are a target the generator is already driven to satisfy.** `call`'s floor of 375 is 25% of a target the pipeline fills by construction. Mined `call` rows are therefore **strictly redundant supply**, not gap-filling.
- **Only actions with zero seed templates can fall short**, and there are exactly three: `ack_med`, `create_calendar_event`, `suggest_video` (`annotation_rules.yaml:66-69`, `seed_gaps`; absent from `seeds/intents.yaml` — verified: 9 core intents present, these three absent). **The loop covers the verdicts of one of them (`create_calendar_event`) and none of its text** (§4). Its records carry no slots, no confidence and no title (§3.1).

### 7.3 The anchor, and the corrected arithmetic

The mixture anchors on the scarce noised bucket: `n_noised = len(kept["stt_noised"])`, `total = math.ceil(n_noised / frac["stt_noised"])` (`build_encoder_dataset.py:338-339`), where `frac["stt_noised"]` is the configured **0.60** (`config.yaml:32`), and the noised bucket is never reduced to fit a clean-bucket target.

- **The corpus floor is a statement about `n_noised`: `≥ 8000` ⟺ `n_noised ≥ 4,800`.** The repo's own measurement states the same figure from the other direction: "The >=4,800 figure is 0.60 × `corpus_floor` 8,000" (`specs/T-036-notes.md:558`).
- **The `0.55` figure is a different check.** It is `hard_floor_stt_noised` (`annotation_rules.yaml:230`), enforced on the **built corpus's achieved share** (`build_encoder_dataset.py:367-371`), i.e. a quality floor on the finished mixture. It is *not* the divisor that sets the target size. Rev 1 conflated the two and derived a 4,400-row requirement; the operative number is **4,800** (delta in §12).
- **Adding clean rows does not move `total`.** A mined row's natural bucket is clean; it gives the sampler more to choose from but leaves the anchor untouched. A mined row can move `total` only by entering the noised bucket — which the build decides by `source`/`register` tagging (`bucket_of`, `build_encoder_dataset.py:296-300`: a row whose `source` prefix is `stt_noise` is `stt_noised`, everything else is classified by `register`). That tagging is a T-054/T-057 decision, and §7.5 gives the arithmetic under both branches.
- **The per-action floors sum to 2,500 — below the 8,000 corpus floor.** Clearing every per-action floor is not sufficient for the corpus floor, and it is the `stt_noised` anchor, not mined supply, that decides whether the corpus floor is met.

### 7.4 The measured supply reality — what the pipeline actually has

This is the part rev 1 did not have, and it reframes §7.6. Measured from the training side and recorded in this repo:

| Measure | Value | Source |
|---|---|---|
| Built corpus, current | **2,561 rows** against the 8,000 floor, **all three floors waived** | `specs/T-036-notes.md:565` |
| Clean-side shortfalls | `set_reminder` 48/300, `ack_med` 11/200, `guide` 13/150, `query` 41/250 | `specs/T-036-notes.md:565-566` |
| Zero-row actions | `create_calendar_event`, `suggest_video` — no seeds, 0 teacher rows, unfixable by any STT pass | `specs/T-036-notes.md:559-561` |
| Distinct noised texts available | **2,458** (from 29,304 rows — a ~12× duplication collapse) | `specs/T-036-notes.md:554-556`; `docs/OPEN-ITEMS.md:137` |
| Round-2 corpus for comparison | 2,827 rows = 1,696 `stt_noised` (60.0%) | `docs/OPEN-ITEMS.md:127-130` |
| Golden corpus (held-out) | **8,000 rows**, per-intent exactly 0.8 × target | `eval/golden_corpus.jsonl` (line count + histogram, this worktree) |
| Ingestion of real rows | `"real_user_rows": 0`; `--consent-export` refuses loudly | `run_encoder_pipeline.py:598-600`, `:387-390` |

So the pipeline's own measured position is: the anchor needs 4,800 distinct noised texts, and **2,458 distinct exist** — a shortfall of 2,342 that no amount of *mining* addresses on its own, because the bottleneck is the diversity of the TTS→Whisper pass, not the supply of phrasings (`specs/T-036-notes.md:556-561`).

### 7.5 The expansion arithmetic — corrected

Rev 1 bounded a mined seed's expansion at "72 rows" via `6 variants × 4 registers × ...`. Two corrections:

- **The teacher path is closed to real utterances.** T-053 rules that the family's export consent does not cover sending a real utterance to the Gemini teacher and blocks T-057 from that transit (`specs/T-053-notes.md:208-240`). The teacher multiplies *seed templates*; it does not multiply mined rows. So the 24-rows-per-job factor does not apply to mined supply at all. **AMENDED 2026-09-15 (owner decision): this ruling is superseded.** The project owner ruled the family's export consent DOES cover teacher transit (T-053 §9 amended). A whitelisted mined utterance may now be teacher-rephrased like any seed — the `variants_per_seed × registers` factor DOES apply to mined supply (under C-1/C-3/D-1). The expansion numbers below (§7.5) therefore understate the post-amendment yield; the direction of change is upward by the teacher factor, capped by the 2–6 minable records per household-week (§5.3) and still at 0 rows until the schema carries an utterance (T-054).
- **The local noised path multiplies by 0–1, not 2.** `stt_noise.py` is deterministic end to end: the synthesiser receives no variant index and the transcriber decodes greedily, so `variants_per_utterance: 2` (`config.yaml:28`, consumed at `stt_noise.py:137-138`) writes **two identical** transcripts per parent — and a round trip identical to its parent is **skipped** (`stt_noise.py:150-151`, "identical round-trip teaches nothing"). Measured on the server corpora, 29,304 noised rows collapse to 2,458 distinct texts (`specs/T-036-notes.md:554-556`).

**Therefore: one mined utterance expands to a clean row (1) plus 0 or 1 distinct noised rows = 1–2 corpus rows**, and only the noised half can move the anchor. The expansion depends entirely on whether the round trip differs from the parent and on which bucket the ingest tags the row into (§7.3) — it is a *decision*, not a constant.

### 7.6 Can one week's mined rows move any action toward its floor?

At the §5.2 mid-range (**20 records/household-week**), post-T-054 (i.e. *assuming* the utterance gap is closed), and at the §8.2 assumption that **~50%** of captured records yield a usable utterance:

- usable mined utterances/week ≈ **10** (≈12 at the optimistic 60%)
- corpus rows/week ≈ **10–20** (1–2 each, §7.5)
- of those, rows entering the **anchored** bucket: **0–10/week**, decided by the ingest tagging branch (§7.3)

Against `call`'s floor of **375**: ≤ **2.7%** of one action's floor per household-week, and only in the optimistic branch where every mined row lands in the anchored bucket.

Against the corpus floor (`n_noised ≥ 4,800`): 10 anchored rows/household-week → **480 household-weeks** to reach the anchor floor from mining alone; across a **20-household** pilot that is **~24 weeks**, and it assumes every household is at the mid-range, every record yields an utterance, and every mined row lands in the anchored bucket — all three optimistic at once.

**Answer, stated plainly as the scenario demands.** For **10 of the 12 actions the answer is a flat no — the yield is exactly 0 by construction** (§3.3), and no week's mining can move them toward anything. For `call` the answer is a qualified yes: ~3% of one floor per household-week, *conditional on the schema extension and on the tagging branch*. But `call`'s floor is not the reason the corpus fails or passes a gate — `call` is the **best-supplied** action in the taxonomy (1,500 target, the largest; 1,200 of 8,000 golden rows), and its synthetic supply comes from a seeded intent with 7 templates.

**Therefore: no single week's mined rows can move any action toward its floor by an amount that decides a gate, and this report does not recommend proceeding to T-054 on the strength of the loop's accuracy benefit alone.** The case for the loop, if there is one, is the *household-specific* case in §9, not supply.

---

## 8. The mining-quality question — what fraction is actually usable

### 8.1 Measured quality defects in the captured stream

Four defects are visible in the code. Each is a rule, not a complaint:

1. **No utterance (§4).** The single largest defect: **100% of records are unusable as rows today**.
2. **Double-counting on timeout** (§3.5a): a timed-out interaction that is later answered writes two records. It inflates raw counts and would teach the miner a false "the user was asked twice" story.
3. **Derived confirmations after a correction** (§3.5b): the `confirmed` half of a correction pair is a *consequence* of the correction, carries the **rejected** plan's confidence, and must not be sampled as an independent confirmation.
4. **Cross-day duplication.** At the cap the store holds 500–551 records; the same utterance attempted on two days produces two records with different `id`s and no shared key (§3.1), so cross-day duplicates are invisible to anything but a normalized-text comparison — which requires the utterance, which is missing.

### 8.2 What fraction is usable — the honest decomposition

Per 100 captured records at the §5.2 mid-range shape (≈70 `call`, ≈30 `create_calendar_event`):

| Filter | Passes | Why |
|---|---:|---|
| raw records | 100 | |
| − collapse timeout→late-verdict pairs (§3.5a) | ~92 | ≈8% of records are the second half of an already-recorded interaction |
| − collapse correction→confirmed pairs (§3.5b) | ~85 | corrections run ~5–10% and each carries a derived twin |
| − calendar records with no supervised surface (`slots == nil`, no confidence) | ~55 | the calendar third is a **count**, not a row — no slot, no utterance, no confidence |
| − no utterance stored (today) | **0** | §4 |
| **usable today** | **0** | |
| **usable after T-054 adds an utterance** | **~45–55** | of which ~2–6 per week are the high-value corrected/denied rows; the rest are confirmations of a brain that was already right |

The row counts in this table are a **stated decomposition, not a measurement** — the two collapses are derived from the code paths, not from observed data. So: **today, 0%.** With the schema extension, **~50%** of captured records become candidate rows — and the design's own §8.2 ("all turns, indiscriminately — rejected: most of the corpus would be confirmations of a brain that is already right, at real privacy cost and no accuracy gain") applies with full force to the confirmation half. **The rows actually worth mining are 2–6 per household-week**, and they are precisely the rows the current schema cannot produce.

### 8.3 Proposed mining rules, with acceptance thresholds

Each rule is stated so it can be implemented as a predicate and rejected mechanically.

| Rule | Statement | Threshold |
|---|---|---|
| **M0 — join** | A record is mineable only if it carries an utterance or a join key to one. Records without one are counted as `unmineable` and never turned into rows | `utterance != nil` (or `utteranceKey` resolves) — **0 rows today** |
| **M1 — correction is a change** | Accept a correction only when `outcome == "corrected"` **and** `correctedTo["method"]` exists **and** `slots["method"] != correctedTo["method"]`. A no-op amendment is not a correction | equality check; drop otherwise |
| **M2 — correction recurrence** | A correction becomes a row only when the **same** (normalized original utterance, corrected method) pair occurs **≥ 2 times** in the window. A single correction is a personal preference, not a pattern | **≥ 2 occurrences**; 1-occurrence corrections counted and dropped |
| **M3 — correction needs both ends** | Both utterances must be present — the original (from the record's utterance field) and the amendment (which today is discarded at `AppCoordinator.swift:5456-5458` and must be captured at the correction site). One end alone is not a pair | both non-nil |
| **M4 — pair collapsing** | A `corrected` record and the `confirmed` record that follows it for the same pending action are **one interaction**; keep the `corrected`, drop the derived `confirmed` | same `slots["contact"]`; the two records' timestamps within one confirmation window |
| **M5 — timeout collapsing** | A `timeout` record followed by any other verdict for the same pending action is **one interaction**; the timeout is dropped when a later verdict exists | same action + contact within one confirmation session |
| **M6 — no unattributed calendar rows** | Never mine a record with `slots == nil` or `confidence == nil` as a row. Count it only | hard drop for rows; count-only otherwise |
| **M7 — cluster rule (action-conditional)** | A low-confidence cluster requires `confidence != nil` **and** `action == "call"`. Cluster = ≥ 3 records sharing the same normalized-utterance hash and the **same** action. Disagreeing records are dropped as a label conflict, mirroring the build's conflict guard | **≥ 3 records**, all `confidence < 0.4` (the router's abstain band) and action-agreeing |
| **M8 — register honesty** | A mined transcript is **raw Whisper output**, not clean Devanagari. Its tag must place it in the `stt_noised` bucket or in a distinct declared register — never presented as a clean row, and never blind-expanded through `stt_noise.py` as if its parent were clean | `source`/`register` tag decides the bucket (`build_encoder_dataset.py:296-300`) |
| **M9 — golden refusal unchanged** | Mined rows go through the existing normalized-membership refusal exactly as teacher rows do; refusals are counted, never silently dropped | `normalize(utterance) not in golden_keys` |
| **M10 — cursor** | Mining is keyed to a high-water mark (a `minedAt` cursor or the T-054 digest), so week N mines only what week N−1 had not (§6.3) | monotonic cursor persisted across runs |

**On "teacher-rephrased", which the task brief offers as an example acceptance rule:** **available as of the owner decision 2026-09-15** (T-053 §9 amended: the family's export consent covers teacher transit). Mined rows may now take BOTH expansion paths: direct rows + local `stt_noise.py` variants, and teacher rephrasing of whitelisted mined utterances under C-1/C-3/D-1 (the same conditions as every other teacher job). M1–M10 were written teacher-free; the teacher-available branch is additive to them, not a replacement — T-057 should still prefer the teacher-free path where a mined row needs no rephrasing.

### 8.4 Is the pipeline even open to real rows today?

**No.** `run_encoder_pipeline.py` records `"real_user_rows": 0` in its run manifest and refuses `--consent-export` loudly (`:598-600`, `:387-390`); consent-export ingestion is stated as "not implemented (NFR-015)". So the incumbent corpus is **100% synthetic**, and T-057 additionally needs an ingestion seam that does not exist yet. This is not a T-052 finding about signal quality — it is the state the yield numbers must be read against: **the loop's mined rows have nowhere to land** until both T-054's schema and an ingestion path exist.

---

## 9. Does mined signal add anything the teacher does not?

Read against what the teacher actually produces (`gen_teacher.py`), how the gold half is expanded (`stt_noise.py`), and what T-036/T-038 found in practice.

| Candidate advantage | Verdict | Evidence |
|---|---|---|
| **Rare phrasings the teacher never generates** | **Real but currently unreachable.** The strongest argument for the loop, and it depends entirely on the missing utterance field. A real misheard phrasing is by construction outside the teacher's imagination | §4; `gen_teacher.py` expands *seeds*, so it can only produce what a seed author thought of |
| **Household-specific names and places** | **Does not transfer.** The encoder learns the *span* (a name-shaped surface), not the identity. Contact→person resolution is deterministic and lives in `ContactResolver`, not in the model. Teaching the encoder one household's roster buys nothing the resolver does not already do | `AppCoordinator.swift:5406-5418`; `IntentCommandCache.swift:23-29` |
| **The correction pair (method A → B)** | **Already learned at runtime, without training.** The confirmed method is recorded into method history and teaches the intent cache on execution. The *plan-level* correction is a resolver input, not a model input | `AppCoordinator.swift:5611-5617` |
| **`create_calendar_event` supply** | **A genuine gap the loop cannot fill — and the sharpest negative result in this report.** This action is one of only three with **zero seed templates** (`annotation_rules.yaml:66-69`) and 0 teacher rows (`specs/T-036-notes.md:559-561`), so it is the one action whose supply the target-driven generator cannot satisfy — and the loop, which covers its *verdicts*, carries **no text, no slots and no confidence** for it (§3.1, §3.4). The loop reaches exactly the gap it cannot fill, and misses the action (`call`) it could. Closing it is a `seeds/intents.yaml` job, not a loop job | `annotation_rules.yaml:51-69`; `seeds/intents.yaml` |
| **`corrections_overrides` duplication** | **Partly redundant.** The pipeline already synthesises the correction family the loop would mine from: `edge_classes_as_labels` maps it to `call` with a target of 400 (`annotation_rules.yaml:70-75`), and `gen_teacher.py`'s corrections prompt generates action `"call"` with a mirrored `requestedApp` at confidence 0.8–0.95 (`gen_teacher.py:218-242`). Mined corrections would be a *real-distribution* version of a family that already exists synthetically | `annotation_rules.yaml:70-75`; `gen_teacher.py:218-242` |
| **A real distribution over correction kinds** | **Small but real.** Which methods get corrected to which, and at what confidence, is a distribution the teacher cannot invent — usable as a *weighting* input for the `corrections_overrides` family. It is a prior, not a row | §3.2 row 2 |

**Summary.** The teacher's job is *breadth*: ~35 core seed templates plus 5 edge templates, cycled and expanded 24 rows per job over four registers, sampled at temperature, then TTS→Whisper-varied. It cannot produce the one thing a household produces for free — the phrasing that actually defeated the deployed model, which is by construction outside a small template bank's imagination. The loop's value proposition is therefore **entirely concentrated in the corrected/denied/low-confidence rows** (2–6 per household-week, §5.3), and **the current schema cannot deliver any of them**. Everything else the loop would mine is confirmations of a brain that was already right — which the design itself rejects.

---

## 10. The conditions (C-1 … C-7), and which task owns each

**C-1 — T-054 must add an utterance (or an utterance join key) to the capture record.** Confidence ships; the transcript does not. Without this, the mined yield is **exactly zero** (§4, §8.2). `PendingCallAction.sourceTranscript` already holds the value; it is simply never written. *Owner: T-054.* **Blocking.**

**C-2 — T-054 must add a mined-cursor or the derived-signal digest for *addressing*, not for survival.** The cap does not lose the signal (§6.2); the absence of a high-water mark means every weekly run re-mines the same records and the loop's marginal value is unmeasurable (§6.3). *Owner: T-054, consumed by T-057.*

**C-3 — the correction site must capture the amendment utterance**, which today is discarded after the method keyword is parsed (`AppCoordinator.swift:5456-5458`). M3 cannot be satisfied without it. *Owner: T-054 (shape) + T-056 (wiring).*

**C-4 — the two double-counting defects must be collapsed by rule, or fixed in the flow** (§3.5a, §3.5b). Either is acceptable; silently counting both halves is not (§8.3 M4, M5). *Owner: T-054/T-056 (fix) or T-057 (rule).*

**C-5 — the miner must be teacher-free** until the owner decision recorded in `specs/T-053-notes.md` creates a consent item naming third-party teacher transit (§8.3). *Owner: T-057.*

**C-6 — `create_calendar_event` is not a mining source.** Its capture carries no slots, no confidence and no title — by design and for good privacy reasons. It is a counter (§3.4, §8.3 M6). Anyone closing its supply gap must do it in `seeds/intents.yaml`. *Owner: TG-10 design + T-054.*

**C-7 — the loop must not be justified on supply.** The teacher is target-driven (§7.2), so `call`'s floor is a target the generator is already driven to satisfy and mined `call` rows are **redundant supply**; to the other 10 actions the yield is zero by construction; and to the `stt_noised`/corpus floors it is zero unless a mined row is tagged into the anchored bucket (§7.3–7.6). The case for proceeding is the household-specific phrasing in §9, which is a *quality* argument, and it is unproven until a pilot log exists. *Owner: TG-10 design.*

**And one design ruling the loop's own sizing contradicts.** D-3's rationale for weekly over monthly fails measurement (§6.3): the cap was sized for a monthly cadence, so at any rate below ~16.7 records/day monthly loses nothing. Weekly is still defensible on latency-to-benefit and on the pipeline's cheap resumability — but the design should say *that*, and stop saying the cap loses the signal, because it does not. *Owner: TG-10 design.*

---

## 11. Acceptance criteria that cannot be satisfied from static analysis

Stated plainly, as the task's fourth scenario requires ("a claim that cannot be grounded in a file read is marked UNKNOWN rather than asserted"):

1. **"the measured per-signal yield over a real or fixture-populated store"** — **not delivered as a measurement.** No consented real store exists in the repository and reading an on-device log without consent is out of bounds (NFR-015). A fixture-filled store would be evidence about *my own* fixture, not about the app, and the task permits one only "provided the report says so" — so this report says so: **the yields in §5 and §8 are parameterised, not measured.** The derivability table (§4), the reachability matrix (§3.3) and the roll-off arithmetic (§6) are complete and measured, because they are properties of code that exists.
2. **"the report gives the fraction of a weekly window that survives … and the recency bias"** — **delivered as a function of a rate that is itself UNKNOWN.** §6.2 gives the closed form and a table across plausible rates; the single number a reader wants (this household's survival fraction) needs a store to exist.
3. **"the measured per-week signal yield projected onto the T-034 target table"** — **delivered for the code-determined part, parameterised for the rest.** §7.1, §7.2, §7.3 and §7.4 are exact (targets, floors, the target-driven generator, the anchor rule, the measured supply, the 0-for-10-actions result). §7.6's row counts inherit §5.2's uncertainty.
4. **The verdict mix** (how many confirmed vs denied vs corrected vs timeout) — **UNKNOWN.** Nothing records it; §5.3 gives a sensitivity table instead.
5. **Per-action supply in the current built corpus** — **partially closed.** T-036's measurement supplies the corpus total, the clean-side shortfalls and the zero-row actions (§7.4), all read from `specs/T-036-notes.md`. What remains UNKNOWN is the *per-action* row count of the currently built corpus in this repo: the corpus itself lives on the training box, `tools/train-intent/data/` is not present in this worktree, and `eval/results.csv` records gate metrics, not row counts. Where §7.2 says an action's floor "is already cleared by synthetic supply" it is reasoning from the seed/target table (`annotation_rules.yaml:51-69`) and the golden corpus's per-intent shape, not from a measured row count of the built corpus.

Nothing in this report depends on reading a device, a private key, a hostname, or any log content. Every count, rate and distribution is either computed from a file in this worktree or explicitly flagged as an estimate.

---

## 12. Delta from rev 1 (so nothing is silently re-ruled)

| Rev 1 said | Rev 2 says | Why |
|---|---|---|
| The record is **eight** fields: "There is no confidence field and no utterance field" | **Nine** fields; `confidence: Double?` exists, and the utterance is still the missing one | `f2cbbab`; `IntentLogStore.swift:26-88`; §3.1 |
| "Exactly two writers exist, both for `action: call`" | **One seam, seven callers, two actions, four verdicts** | `f2cbbab`; §3.2 |
| "`denied` and `timeout` are documented and have **no writer**" | Both are written, two callers each | §3.2 rows 4–7 |
| "`latencyMs` is `nil` on every record ever written … there is no latency data to bucket" | **Re-ruled: `latencyMs` is live**, computed as the question→verdict span, floored at 0 | `Capture.latencyMs(at:)`; §3.1. (T-053 is the authority on whether it may egress, and at what resolution) |
| "`Record` is a plain `Codable` struct with **no custom `init(from:)`**; a non-optional new field would make every existing on-disk line fail to decode" | **The decode-compatibility requirement stands; the factual premise does not.** A tolerant `init(from:)` now exists and legacy lines are pinned by a test | `IntentLogStore.swift:76-87`; `IntentLogStoreTests.swift:86-104` |
| Signal 3, low-confidence cluster: "**0 records.** Confirmed by reading the struct" | **Half-derivable.** Derivable for `call` (confidence non-nil on every voice-originated record); structurally `nil` for `create_calendar_event` | §3.4, §4 |
| Proposed T-054 field `confidenceBucket` (`lt_0_4` / `0_4_0_7` / `ge_0_7`), "not the raw float" | **Withdrawn as a capture-schema proposal.** The raw `Double?` shipped. A *bucket* is now an **egress** decision (T-053's), not a capture gap; the capture side needs nothing | §4.1 |
| Proposed `outcome: "abstained"` + a third append site; `abstentionReason` | **Retained, unchanged.** Still a writer gap, not a schema gap — an abstention never pends a confirmation, so only a new append site produces one | §4, signal 2 |
| Proposed `surfaceRef` — the third of rev 1's three named schema items, defined as "an opaque on-device handle, never the text" | **Retained, and promoted to the primary recommendation.** Rev 2 adds the explicit fallback (a raw transcript field in the log) contingent on T-053's ruling, and drops rev 1's framing of the field as merely one item in a list | §4.1 |
| Proposed widening the `action` vocabulary at the writers | **Half-done.** `create_calendar_event` gained writers; the other 10 actions remain at zero, and 8 of them structurally cannot be captured | §3.3 |
| "A corrected call writes two records, not one" | **Retained, and extended:** a *timed-out* confirmation is not terminal either, so it can write a second record after its own timeout was recorded | §3.5a, §3.5b |
| "Neither site passes `timestamp`; the `init` default fires — this one is fine" | **Unchanged.** Correct then and now | §2 |
| Rev 1 listed the three floors as bare values — "`stt_noised` share ≥ 0.55" among them — without deriving what they require of the noised supply | **Now derived: the mixture anchor divides by 0.60, so `≥ 8000` ⟺ `n_noised ≥ 4,800`.** The 0.55 is a floor on the *built* share, a different check; the repo's own measurement states the 4,800 figure | `build_encoder_dataset.py:338-339`, `config.yaml:32`, `annotation_rules.yaml:230`, `specs/T-036-notes.md:558`; §7.3 |
| Expansion "up to 48 noised rows" / "72 rows per mined seed" via the teacher path | **Corrected down: the teacher path is closed to real utterances** (T-053 §9), and the local noised path yields **0–1 distinct rows**, not 2, because `stt_noise.py` is deterministic | `specs/T-053-notes.md:208-240`; `stt_noise.py:150-151`; `specs/T-036-notes.md:554-556`; §7.5 |
| "**11 of 12** schema-v2 actions produce zero records" | **10 of 12** — `create_calendar_event` gained writers | §3.3 |
| "the 500-record cap … the binding constraint is that one action and one correction type are the only things ever logged" | **Cap ruling re-confirmed**; the binding constraint is now stated precisely as **addressing** (no mined cursor) plus the missing utterance | §6.3 |
| No capture-rate estimate; no mining rules with thresholds; no comparison against the synthetic supply; no verdict | **Added: §5, §8.3, §9, §10** — the task brief requires all four | task brief |
| Report ended with "Recommendation" and a hand-off | **FEASIBLE-WITH-CONDITIONS**, with C-1…C-7 mapped to owning tasks | §0, §10 |

Everything else in rev 1 that this table does not re-decide — the `path`-vocabulary divergence, the "derived but not observed" correction pair, the 500-cap mechanics and the break-even, the observation that the store holds resolved slot values and no transcript, and the PII discipline — is **retained, and now cited to this revision's line numbers**. Rev 1 is superseded by this document at the moment this commit lands.

---

## 13. PII and evidence discipline

- **No PII in this document.** Only counts, rates, distributions, field names and `file:line` citations. No utterance, contact name, medication name or message body appears; no hostname, credential or key. The store's own contents were not read (§1).
- **Every claim is grounded in a file read at this worktree's revision.** The two exceptions are marked **UNKNOWN** rather than asserted: the household arrival rate and the household correction rate (§1, §5.2, §5.3, §6.2 are parameterised on them, with break-even points named).
- **Deliberately not claimed:** any measured per-seed pipeline yield from mined rows; any claim about the encoder's runtime confidence distribution; anything about the loop's accuracy effect, which no measurement here can support; and any per-action row count of the currently built corpus beyond what T-036 recorded (§11.5).

---

## 14. Hand-off

| Task | What this report gives it |
|---|---|
| **T-054** (capture schema & egress contract) | The derivability table (§4) as its schema input; the three named gaps — **utterance/join key**, **mined cursor**, **amendment utterance at the correction site** — as C-1…C-3; §3.5's two defects as C-4. Its brief's premise that "the confidence signal is not derivable today (no confidence field exists)" is now **false** and must be corrected before it designs around a stale gap. Rev 1's `confidenceBucket` proposal is withdrawn (§12) |
| **T-057** (correction miner) | The expected-yield baseline: **2–6 corrected/denied records per household-week**, **0 usable rows today**, ~45–55 candidate rows per 100 records after the schema extension; M0–M10 as the mining rules and thresholds; C-5's teacher-free constraint and the T-053 block it comes from |
| **T-053** (privacy review) | Already ruled on teacher transit (its §9); this report additionally identifies the transcript (or a join key to one) as the *specific* field the loop wants, which is what the consent copy has to name |
| **TG-10 design** | C-7: the loop must not be justified on supply, and D-3's rationale is contradicted by its own cap arithmetic (§6.3, §7.6). The measured supply reality in §7.4 is the correct context for the loop's expected benefit |

## Open items

- The two capture defects in §3.5 are **observations, not fixes** — `IntentLogStore` and `AppCoordinator` are outside T-052's scope by its own brief. They are handed to T-054/T-056 as rules (M4, M5) and, if the flows are changed instead, as a behavioural bug each (a timed-out confirmation stays pended; a correction's confirmed twin carries the rejected plan's confidence).
- **`latencyMs` is live but nothing reads it.** It now has a writer; whether it may egress, and at what resolution, is T-053's ruling, not this report's.
- **No behavioural number in this report should be quoted without its range.** §5.2's arrival rate and §5.3's verdict mix are the two quantities a pilot would have to produce, and the repository cannot.
