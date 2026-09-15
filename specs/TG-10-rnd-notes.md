# TG-10 — Continuous Learning Loop: R&D notes (T-052 + T-053)

**Task:** R&D phase of TG-10 — the two tasks the group says "start immediately" and on which "nothing is built until both answer" (`.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/index.md`).
**Worktree:** `.claude/worktrees/tg10-rnd` (branch `worktree-tg10-rnd`, base master `41daeb6`).
**Scope discipline:** documentation only. No production code changed, no build, no test run, no training run, no GPU, no `xcodebuild`, no device access, no merge, no push. Every artifact here is Markdown.

## Artifacts committed

| File | Deliverable | Task |
|---|---|---|
| `specs/T-052-notes.md` | The capture/signal-quality feasibility assessment: the derivability table, the measured roll-off under the 500 cap, the yield arithmetic against the AUGMENT floors, the proposed capture-schema extension, and the recommendation | T-052 |
| `specs/T-053-notes.md` | The privacy determination: the consent basis, the per-category payload ruling (including the salt), the retention windows, the exact consent copy in both languages, the NFR-032 policy amendment, the shadow-mode privacy protocol, the promotion-rule governance ruling, and the OQ-2 teacher-transit ruling | T-053 |
| `specs/TG-10-rnd-notes.md` | This file — what was produced, how it was verified, and what is handed to whom | both |
| `.ai-sdd/outputs/plan-tasks/plan.md` | TG-10's done-count and the total | both |

**No TG-10 task file was edited.** The task descriptions, acceptance criteria and Definitions of Done in `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/` are unchanged; the results are recorded here and in the two reports, per the brief.

## The answers, in brief

**T-052 — do the recorded signals justify the loop?** Not on supply. The shipped `IntentLogStore.Record` has eight fields and neither a confidence field nor an utterance field; exactly two writers exist and both hard-code `action: "call"`. So of the three claimed signals, **correction** is derivable as a *trigger* but not as a *training row* (no utterance), and **repeat-after-abstention** and **low-confidence cluster** are **not derivable at all** — no writer ever appends an abstention, and there is no confidence field to cluster on. The 500-record cap turns out **not** to be the binding constraint: the break-even for a weekly window is ~71 records/day, and a call-only store cannot plausibly reach that, so the effective window is 25–100 days. The binding constraint is **what gets written**, not the cap or the cadence. Against the floors (§5.3 of `T-052-notes.md`): 11 of 12 actions yield exactly zero mined rows by construction, and for `call` the floor is already cleared by synthetic supply, so mined rows cannot be the thing that clears any floor. **Recommendation: proceed to T-054 only with the named schema extension, and do not justify the loop on its supply benefit.**

**T-053 — is the hashed egress path defensible?** Yes, under conditions. The loop needs **its own disclosure and consent**, not an amendment extending Open Decision 12 — OD-12's scope clause says "voice transcription (and only that)", and reading a hashed-signal path into it would make the recorded exception mean less than it says. The loop adopts OD-12's five obligations with the trigger moved from engine selection to a settings opt-in. The payload rule is blessed and narrowed: a versioned enumerated schema, no free-text field, no timestamp finer than a day, no `Record.id`, an HMAC-SHA256 keyed by a **required** per-install device-held salt, no escrow, rotation on opt-out only, and unsalted hashes ruled **not acceptable**. Retention is 90 days on-device and 180 days egressed, with named deleters. **OQ-2 is ruled NO: the family's export consent does not cover sending a mined utterance to the cloud teacher, and T-057 is blocked from that transit until an explicit consent item exists.**

## Decisions made during this task

- **The two reports live in `specs/T-052-notes.md` and `specs/T-053-notes.md`,** matching the house convention already used by T-034, T-035, T-036, T-037, T-038 and T-046, and satisfying each task's "committed under `specs/` (T-0NN notes)" Definition-of-Done line. This file is the group-level index and the record of what was verified.
- **The measurements are structural, not behavioural, and they say so.** No consented real store exists in the repository and reading an on-device log without consent is out of bounds (NFR-015), so T-052 measures what the code can produce (append-site call graph, record shape, cap mechanics, expansion factors) and parameterises what only a household can produce (arrival rate, correction rate) — with break-even points named rather than a fabricated number. The two behavioural quantities are marked **UNKNOWN** in the report rather than asserted. This is the honest form of the answer the task asks for, which explicitly permits a "not worth it" outcome.
- **The task files' line citations had drifted, and the reports cite the current revision.** T-052's brief cites `AppCoordinator.swift:4938-4944` and `:5076-5079`; at master `41daeb6` the append sites are `:5434-5438` and `:5572-5575`. T-053's brief cites `:1612-1613` for the cloud-engine default, now at `:1987`/`:1997`. The design doc's `CommandRouter.swift:651`, `:1429` for the safety net is now `:707-715`. Every line number in both reports was re-read at the worktree's own revision; the drift is noted where it matters so a reader following the older citations is not misled.
- **The documented `path` vocabulary is already wrong.** `Record`'s field comment lists `local | cloud | keyword | cache | override` (`IntentLogStore.swift:23-24`) while the confirmation writer emits `path: "model"` (`AppCoordinator.swift:5573`). Recorded in T-052 §2 and carried into T-053 §3.2 as a reason a `path`-sourced payload field must be validated against the *observed* vocabulary. Not fixed here — `IntentLogStore` is out of T-052's scope by its own brief.
- **`latencyMs` is a dead field, and T-053 rules it out of the payload until a writer populates it.** Neither writer passes it and nothing reads it (grep: three hits, all in the struct and its `init`). A field that is always `null` is a null collection and must not be disclosed as one.
- **The shipped privacy policy is already inaccurate under OD-12, and the T-053 amendment fixes both problems at once.** `settings.privacy.body` says, in both languages, "Nothing is sent to the cloud for AI processing", while OD-12 records that the shipped default engine stack *is* the cloud engine. NFR-032 requires accuracy. Rather than layering the loop's disclosure onto a false sentence, T-053 §6 delivers replacement text covering both paths.
- **Two items are escalated rather than decided.** The constitution's Open Decisions are owner-decided (`constitution.md:99`), so (1) recording the loop as a second consent-gated path in `constitution.md` and (2) deciding whether an explicit teacher-transit consent item should exist are both handed to Anjan Poudel with the reason stated, rather than decided unilaterally. Both are in T-053 §10 with the review date **2026-10-13**, folded into the existing OD-11/OD-12/post-deploy-monitoring cadence rather than a new parallel one.
- **`plan.md`'s done-count was updated surgically, and it is a shared file.** TG-11's and TG-12's agents are authoring into `plan.md` concurrently in their own worktrees. Only TG-10's own row in the Task Group Summary and the total row were touched; the traceability table (requirements coverage) was verified to already be correct for T-052/T-053 and left alone.

## Verification performed (documentation-only)

- **Every `file:line` citation in both reports was read against this worktree before being written.** Where a citation was copied from a task file or the design doc and found stale, it was corrected to the current line and the drift recorded (above).
- **The append-site set is exhaustive, not sampled.** `grep -rn "intentLogStore" ios/` returns five references: one declaration (`AppCoordinator.swift:1467`), two appends (`:5434`, `:5572`), and two reads in the review screen (`IntentLogReviewView.swift:82-83`, `:89`). The claim "only two writers, both for `call`" is the result of enumerating the complete set, not of reading the two the brief names.
- **The cap mechanics were corroborated against the shipped test.** T-052 §6's read of the trim (`maxRecords + 50` threshold, suffix-of-500 write-back) is confirmed by `IntentLogStoreTests.testCapTrimsOldest` (`:36-43`), which asserts exactly `maxRecords` records remain after `maxRecords + 51` appends and "oldest 51 trimmed".
- **The floors and the expansion factors were read from the code that enforces and consumes them**, not from prose: `build_encoder_dataset.py:359-383` for the floor logic, `encoder_rules.py:175-177` for the `0.25` literal, `annotation_rules.yaml:51-63` and `:230-232` for the targets and floor values, `config.yaml:9`/`:28` and `gen_teacher.py:72` for the per-seed expansion (`6 × 4 registers = 24`), `stt_noise.py:121` for the noise factor.
- **The floor table's arithmetic was computed, not estimated:** 12 actions, targets summing to 10 000, floors summing to 2 500, and the seeds-per-floor column derived from the structural expansion bound. The optimistic bound is labelled as a bound; the round-2 dedup collapse (`docs/OPEN-ITEMS.md:135-138`, 29 304 noised rows → 2 458 distinct) is cited as the reason the bound is not an expectation, and is attributed to a different stage.
- **The consent copy was checked against the shipped copy's register** before being written: it matches the tone and the plain-language level of `settings.privacy.body`, `settings.voiceEngine.explanation` and `voiceSettings.privacy` as they exist in `Localizable.xcstrings`, and the localisation convention (key shape, both locales, `L10n.str`/`L10n.fmt` for non-View code at `L10n.swift:18-30`, `:53-56`) was read from those shipped examples.
- **The salt, rotation and escrow rulings were checked against the existing egress-adjacent code** so they are implementable as stated: the design's §5.2 hash convention (`gen_teacher.py:41-43`, `pipeline_guards.sha256_file`) is on the training box and is explicitly **not** reused at the boundary — T-053 §3.4 says so and cites why.
- **The shadow-mode telemetry ruling was checked against `LogSanitiser`'s actual mechanism.** The finding that matters: the allow-list drops unknown keys (`:94-108`) but the value scrubber only knows phone / e-mail / blood-pressure shapes (`:82-92`, `:134-147`), so a Nepali personal name under an allowed key would pass. T-053 §7 therefore requires a **declared bounded value space** per new key, which is a stronger requirement than the design's §4.5 and is checkable by T-059.
- **Secret / PII scan over all three deliverables:** no 40-character hex run, no 13–39-character hex run, no e-mail address, no 7+ digit run, no credential-shaped `key=value`, no hostname, no path outside the repository, and no real utterance, contact name, medication name or message body. The consent copy and the policy text are the only user-facing prose and contain no example data. The only hash-shaped value named anywhere is the interface description ("a 16-hex-character prefix of a keyed digest"), never an instantiation.
- **No build, test, simulator, training or device command was run** — out of scope, and the constraint was explicit.

## Open items and hand-offs

**Handed to the next tasks as binding inputs:**

- **T-054** (Capture Schema & Egress Contract Design) — the proposed field set and the writer gap (`T-052-notes.md` §4); the per-category payload ruling, the four-part field test, the enumerated-schema and schema-hash-with-consent rules, the day-granularity and no-`Record.id` rules, and the HMAC / per-install-salt / 16-hex / event-only-rotation / no-escrow rulings (`T-053-notes.md` §2, §3).
- **T-055** (Shadow Scoring & Healing Protocol Design) — the not-a-new-collection conditions, the four permitted telemetry keys with their value spaces, the "do not widen the bus" ruling, and the instruction to reuse `LocalBrainChain.EscalationReason` and the existing `cascadeDecision` timing stage (`T-053-notes.md` §7).
- **T-056** (Capture & Egress Implementation) — the exact strings and localisation convention, the indicator ruling, the opt-out semantics, the fail-closed behaviour on an unaccepted payload version, and the NFR-032 text (`T-053-notes.md` §2, §4, §5, §6).
- **T-057** (Correction Miner Implementation) — the teacher-transit **block** and the teacher-free fallback it must implement until the escalation is decided (`T-053-notes.md` §9).
- **T-058** (Promotion Gate Implementation) — no deployment wiring; the publish-under-a-new-payload-version review hook (`T-053-notes.md` §8).
- **T-059** (Privacy Audit) — every ruling in §2–§4 and §7 of `T-053-notes.md` as a mechanical criterion.

**Escalated to the project owner (Anjan Poudel), review by 2026-10-13:**

1. Record the loop as a **second consent-gated, non-default path** in `constitution.md`, with the five OD-12-shaped obligations, and note in the OD-12 entry that the two disclosures are separate.
2. Decide whether an explicit **third-party teacher-transit consent item** should exist — the decision that gates T-057's teacher path. Until it is made, the §9 ruling holds.

**Carried forward, not resolved here (so they are not lost):**

- **The export path writes plaintext JSONL to tmp** (`IntentLogStore.swift:108-123`; recorded in `2026-09-13-encoder-training-data-strategy.md` §7). A device-side follow-up, outside T-052/T-053.
- **`latencyMs` is never populated and `denied`/`timeout` are never written**, though the field comment documents all three. Either a writer appears or the design's egress table and the field comment should both be corrected — T-054's call.
- **Whether a content-free abstention marker is enough to author a row, or whether the on-device surface join at MINE time is required** — T-054 owns the shape, T-057 owns whether the join is possible.
- **Design OQ-4** (what "the incumbent" is when the household runs the cloud engine) remains T-058's with its implementation context; T-053 did not decide it.

## Requirement traceability

No traceability-table change was needed. `plan.md`'s task-to-requirements mapping already carries `T-052 | NFR-015, NFR-016` and `T-053 | NFR-015, NFR-016, NFR-032` (lines 166-167), which is exactly what both task files declare and what both reports serve. Only the Task Group Summary's done-count for TG-10 and the total row were updated.

## Escalation decisions (user, 2026-09-15)
1. **Consent path: APPROVED** — the learning loop is recorded as a second consent-gated, non-default path (opt-in, OD-12's five obligations, strict payload rules), review-by 2026-10-13.
2. **Teacher transit: LOCAL TEACHER ONLY** — mined/corrected utterances may go to the local teacher; Gemini transit stays blocked unless a separate explicit consent exists.
