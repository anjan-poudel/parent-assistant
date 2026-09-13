# Continuous Learning Loop — Design

- **Task group:** TG-10 (`.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/index.md`,
  tasks T-052–T-060)
- **Branch:** `worktree-tg10-continuous-learning` (base `5a908ac`) — design + task group only;
  no training run, no model download, no build, no device work
- **Status:** design deliverable. The loop is designed and its tasks are specified; nothing
  in `ios/` or `tools/` is changed by this document.
- **Inputs (read for this design, not recalled):** the shipped flywheel log
  (`ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift`), its review screen
  (`ios/ElderlyAssistant/App/IntentLogReviewView.swift`), the observability boundary
  (`Services/MedicationScheduler/DependencyProtocols.swift`,
  `Services/Observability/LogSanitiser.swift`, `App/AppCoordinator.swift:7258-7278`), the
  fail-soft runtime (`Services/Intents/LocalBrainChain.swift`,
  `Services/Intents/IntentEncoderInterpreter.swift`, `Services/Intents/IntentEncoderFeature.swift`),
  the T-036 tooling (`tools/train-intent/src/`), the T-038 harness
  (`tools/train-intent/src/eval_golden.py`), the T-036 pipeline driver
  (`tools/train-intent/src/run_encoder_pipeline.py`), `constitution.md` and `requirements.md`.
- **Consumers:** T-052 (feasibility) and T-053 (privacy review) start immediately; T-054
  (capture/egress contract) and T-055 (shadow/healing protocol) consume this document's
  boundaries; T-056–T-060 implement and verify.

---

## 1. Purpose and scope

The shipped flywheel is a **manual** loop: `IntentLogStore` records what the user confirmed
and corrected, the family reads it in `IntentLogReviewView`, and a
`ShareLink` on `IntentLogStore.exportURL()` hands an exported file to whoever then runs the
next training batch (`IntentLogStore.swift:3-17`, `:108-123`;
`IntentLogReviewView.swift:23-27`). Its own docstring calls this "the periodic export →
retrain loop", and the spec that created it names the cadence ("retrain monthly or at 500
corrections, whichever first" — `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md:588-612`).

TG-08 built the engine that a loop would feed: a joint intent + BIO-slot encoder, a T-036
training pipeline with gates, and a T-038 harness that exits non-zero when a candidate
misses a gate. What does not exist is the thing between the two: a way for the correction
signal that the app already captures to reach the corpus, and a rule that decides when a
retrained candidate is allowed to replace the brain that is serving an elderly user today.

This design fixes the **signal path and the promotion boundary** for that loop. It covers:

1. what is captured, on-device and opt-in, and what a captured record may contain (§4.1);
2. how captured signals become labelled rows (§4.2) and how those rows enter the **existing**
   corpus authoring — `gen_teacher.py` rephrase → `stt_noise.py` variants, with
   `pipeline_guards.py`'s leak guards and the existing dedup unchanged (§4.3);
3. how a candidate is retrained (§4.4) and what must be true before it is published (§6);
4. how a published brain is monitored and healed at runtime (§4.5, §7).

Out of scope by decision: any change to the safety stages (§3), any raw-content egress
(§5), any new model architecture or taxonomy (TG-08 owns both), and Android (§9).

---

## 2. Recorded decisions

These four decisions are **made**. They are recorded here with their rationale and their
consequences so they are not re-litigated task by task; each task below treats them as
constraints, not options.

### D-1 — Opt-in, not opt-out

The loop exists only for a household that has explicitly turned it on. Nothing is captured,
mined or egressed for a household that has not.

- **Rationale.** The product's primary user is an elderly person whose utterances include
  medication names, symptoms and family names; the family member who configures the device
  is not necessarily the person whose voice is recorded. The constitution's Privacy standard
  is a consent-shaped standard already (`constitution.md:72-76`), and the only recorded
  content-bearing exception in the project — the cloud voice stack — is itself
  consent-gated with point-of-selection disclosure (`constitution.md:128-132`). A loop that
  harvested corrections by default would be a larger divergence than the exception the
  project already had to record.
- **Consequence.** The loop's default state is OFF and the consent is revocable; the
  opt-out path must delete what has not yet been egressed and stop future egress. This is
  designed in T-054 and executed in T-056.

### D-2 — Hashed-only egress

Signals leave the device; content does not. What crosses the boundary is hashes, closed
vocabulary identifiers (action, outcome, correction kind), confidence and latency buckets,
and counters. Raw audio, raw transcripts, slot values (contact names, medication names,
message bodies), and health values never leave the device on any loop path.

- **Rationale.** This is the only form of the loop that is compatible with Architecture
  Constraint 1 as written — "User voice, conversations, health data, and personal profiles
  must never leave the device for AI processing" (`constitution.md:43`) — and with NFR-015
  (`requirements.md:262-263`). It also keeps the loop outside the cloud voice-stack
  exception, so it adds no new disclosure obligation of its own beyond the opt-in.
- **Consequence.** The mining stage and the retraining stage see *different* things: MINE
  runs where the content is (on-device or on the family's exported bundle), and the hashed
  channel carries only the signal that says "this is worth mining". A hash of a transcript
  is a pseudonym, not anonymity, so the egress payload must use a per-install salt held on
  the device (§5.2) — T-053 rules on this and T-054 fixes it.

### D-3 — Weekly retrain cadence

The loop proposes a retrain **weekly**, gated by the promotion rule (§6). The proposal is a
schedule, not an authority: a week with no new signal produces no run, and a week whose
candidate fails a gate produces no publish.

- **Rationale.** The spec's recorded cadence ("monthly or at 500 corrections",
  `…intent-engine-finetuned-llm-design.md:610`) predates two facts: the log is capped at
  500 records with oldest-first trimming (`IntentLogStore.swift:17`, `:49`), so a monthly
  cadence can roll the signal out of the window before it is ever mined; and the T-036
  pipeline is resumable and gate-checked, so a weekly run that produces nothing is cheap
  and a weekly run that produces a failing candidate is *safe* — the gate stops it. Weekly
  therefore trades a little GPU time for not losing the signal.
- **Consequence.** The 500-record cap bounds the reviewable window, not the training
  window: the capture path (T-056) must roll its *derived signals* into a compact,
  deduplicated summary that survives trimming, or the weekly run will mine an
  ever-shrinking set. This is the first thing T-052 measures.

### D-4 — Human publish gate

No model publishes without a person deciding to publish it. The promotion rule (§6) is a
machine gate that can only ever *block*; it cannot promote. The publish decision — and the
privacy review of the loop's first egress — stay human.

- **Rationale.** The gates measure the corpus; they cannot measure whether a change is
  appropriate for this household, this week. `run_encoder_pipeline.py` already refuses to
  publish without an explicit artifact version and on any harness gate failure
  (`:303-330`, `:556-559`), and that shape — mechanical refusal, human release — is the
  existing precedent. The constitution's release-gate bullets are likewise human-owned
  checks with named owners and dates (`constitution.md:92-95`).
- **Consequence.** T-058 wires the machine half (non-zero exit, no publish) and explicitly
  does *not* wire an automatic deployment. A published artifact still needs a human to
  install it.

---

## 3. Ground truth read for this design

Every claim below is grounded in a file read for this task, not recalled.

| Fact | Source (verified) |
|---|---|
| Flywheel log: on-device JSONL, `NSFileProtectionComplete`, holds slot values by design, "leaves only via the family's explicit export", capped at 500 | `Services/Intents/IntentLogStore.swift:3-17`, `:20-47`, `:49`, `:58-65`, `:108-123` |
| Record shape: `path` ∈ {local, cloud, keyword, cache, override}, `action`, `slots`, `outcome` ∈ {confirmed, denied, corrected, timeout}, `correctedTo`, `latencyMs` | `IntentLogStore.swift:20-47` |
| The two append sites today: the correction pair (`outcome: "corrected"`, `correctedTo`) and the confirmed call | `App/AppCoordinator.swift:4938-4944`, `:5076-5079` |
| Review screen is read-only; corrections happen by voice; Export = `ShareLink` on the export URL | `App/IntentLogReviewView.swift:3-7`, `:23-27`, `:108-115` |
| Export writes plaintext JSONL to tmp (the known encryption gap) | `IntentLogStore.swift:108-123`; recorded in `docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` §7 |
| Observability bus contract: `component/eventType/durationMs/outcome/errorCode/metadata` | `Services/MedicationScheduler/DependencyProtocols.swift:23-34` |
| Every event is sanitised before printing: `ConsoleObservabilityBus.emit` calls `sanitiser.sanitise` then `print` | `App/AppCoordinator.swift:7260-7278` (`:7274`, `:7277`) |
| Allow-listed metadata keys (unknown keys dropped); `error_code` bounded; PII patterns | `Services/Observability/LogSanitiser.swift:56-70`, `:84-97`, `:106-122`, `:72-82` |
| T-049/T-050 precedent: transcript prints removed from Release, key/URL-bearing errors barred from `error_code` | `docs/…`; `LogSanitiser.swift:22-49` records the T-050 rationale in-code |
| Band policy: accept ≥ 0.7, rephrase 0.4–0.7, abstain < 0.4 | `Services/Intents/IntentRouter.swift:49-58`, `:318-319` |
| Fail-soft chain: `preferred` when available, else `standIn`; availability = either | `Services/Intents/LocalBrainChain.swift:28-69` |
| Encoder abstention reasons are content-free machine strings that travel as `errorCode` | `Services/Intents/IntentEncoderInterpreter.swift:16-32` |
| The encoder is behind a compile-time feature gate and is not the shipped brain | `Services/Intents/IntentEncoderFeature.swift:29-40`, `:57-61` |
| Safety net runs before any model | `Services/Voice/CommandRouter.swift:651`, `:1429` |
| Teacher generation: resumable at CALL level; edge classes incl. `abstain_low_confidence`, `gibberish_to_none`, `corrections_overrides`; `edge_ok` validator | `tools/train-intent/src/gen_teacher.py:12-16`, `:179-243`, `:246-261` |
| STT-noise: `text → piper TTS → app's bundled Whisper → noisy text`; id `"{source_id}:noise{n}"`; inherits the parent label | `tools/train-intent/src/stt_noise.py:1-18`, `:140-145` |
| Leak guards: golden corpus refused as input by construction; normalized-utterance membership refusal; "reports paths, counts and hashes only" | `tools/train-intent/src/pipeline_guards.py:16`, `:36-38`, `:88-100`, `:103-120` |
| GPU discipline: never overlap another CUDA stage | `tools/train-intent/src/pipeline_guards.py:130-177` |
| Corpus-revision binding: results rows and baselines carry `@<hash8>`; no baseline for this revision = UNEVALUATED and the gate fails closed | `tools/train-intent/src/eval_golden.py:505-537`, `:603-606`, `:742-763`, `:814-815` |
| Gate table and non-zero exit | `tools/train-intent/src/eval_golden.py:821-838`, `:895-898`; `tools/train-intent/config.yaml:56-69` |
| Publish decision already refuses on harness failure, calibration failure, provenance mismatch, missing version | `tools/train-intent/src/run_encoder_pipeline.py:303-330`, `:556-559`, `:581-583` |
| Consent export ingestion is deliberately NOT implemented and refuses loudly | `tools/train-intent/src/run_encoder_pipeline.py:598-600` |
| Encoder dataset build: leak guard, mixture floors, edge priority-keeping, refusal counters, no utterance in any report | `tools/train-intent/src/build_encoder_dataset.py:1-38` |
| Training determinism: seed 42; resumable state; guards before torch | `tools/train-intent/src/train_encoder.py:1-30` |
| Calibration fitted on the valid split, never the golden corpus; gate ±10 pp | `tools/train-intent/src/calibrate_encoder.py:1-27` |
| Constitution: on-device inference constraint + recorded cloud exception | `constitution.md:43` |
| Constitution: Privacy standard incl. log-sanitiser requirement | `constitution.md:72-76` |
| Constitution: post-deploy monitoring bullet, owner and review date | `constitution.md:95` |
| Constitution: Open Decision 11 (descoped B3–B7, review 2026-10-13) and Open Decision 12 (cloud exception, consent amendment) | `constitution.md:121-126`, `:128-132` |
| NFR-015 (no personal data to cloud for AI processing), NFR-016 (no PII in logs; sanitiser required) | `requirements.md:262-266` |
| NFR-013 (quarantine-level sanitisation), NFR-011 (TLS 1.2+), NFR-012 (E2E remote config) | `requirements.md:252-253`, `:246-247`, `:249-250` |
| NFR-023/NFR-024 (externalised strings; Nepali + English), NFR-029 (0.85 safety threshold) | `requirements.md:294-298`, `:316-317` |
| NFR-032 (privacy policy describes collected/stored/transmitted data) | `requirements.md:329-330` |
| The spec's flywheel section (log schema, family export, "monthly or 500 corrections" cadence) | `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md:588-612` |
| Correction protocol: "होइन, फोन नै गर" is a slot override, re-planned and re-confirmed once | same spec `:444-447` |

---

## 4. The loop

Five stages. Four of them already exist in some form; the loop is the wiring and the rule,
not a new science project.

```
 (a) CAPTURE          (b) MINE            (c) AUGMENT            (d) RETRAIN         (e) SHADOW/HEAL
 on-device, opt-in →  corrections,     →  gen_teacher rephrase →  T-036 pipeline  →  shadow scoring
 IntentLogStore +     repeat-after-       stt_noise variants      + 8 gates +        vs the active
 observability bus    abstention,         + leak guards +         beat incumbent    brain; divergence
 (hashed egress)      low-confidence      dedup (unchanged)       on the bound      telemetry; fail-soft
                      clusters                                    eval              ladder; rollback
```

### 4.1 CAPTURE — the on-device signal

**What already exists.** `IntentLogStore` records, per turn: the path that produced the
result, the action, the resolved slot values, the outcome, the correction target and the
latency (`IntentLogStore.swift:20-47`). Both append sites are real: the correction pair at
`AppCoordinator.swift:4938-4944` and the confirmed call at `:5076-5079`. The record is
already the highest-value signal the system produces — a correction is the user telling the
assistant that its plan was wrong, which no synthetic corpus can generate.

**What CAPTURE adds.** Nothing to the record's *content*; two things to its *reach*:

1. an **opt-in control** (D-1) that turns the derived-signal channel on and off, with a
   revocable consent record;
2. a **hashed egress path** (D-2) that emits signals to the training pipeline — not content.

The capture record extends `IntentLogStore.Record`; the exact shape is T-054's deliverable
and T-052 measures whether the existing shape is sufficient to mine at all. The only
extension this design fixes is the constraint that any new field is **optional and
defaulted**, so an existing on-disk JSONL from a shipped install still decodes — the current
`Record` is a `Codable` struct with no custom `init(from:)`, so a non-optional new field
would make every existing line fail to decode (`IntentLogStore.swift:20-47`, `:131-137`).

**Reconciliation with the log's stated contract (required).** `IntentLogStore`'s docstring
says the log is "deliberately separate from `ObservabilityBus` telemetry, which stays
PII-free (C9)" and that it "leaves only via the family's explicit export"
(`IntentLogStore.swift:11-14`). After this loop, that second sentence is no longer literally
true: *derived signals* leave over the opt-in hashed channel, while *content* still leaves
only through the family's export. Leaving the docstring as-is would make the shipped source
lie about its own data flow, so **T-056's definition of done includes amending that
docstring** to name both channels. This is not a hidden divergence; it is a stated
amendment to a stated contract.

The first sentence stays true, and the loop keeps it true deliberately: the hashed channel
does **not** ride `ObservabilityBus`. See §5.3.

### 4.2 MINE — signals into labelled rows

Three mining sources, in descending order of value per record:

| Signal | Where it is in the record | What it becomes |
|---|---|---|
| **Correction** | `outcome == "corrected"` + `correctedTo` (`AppCoordinator.swift:4938-4944`) | a labelled row pair: the original plan (negative example) and the corrected plan (gold), mapped onto the schema-v2 action + slot surfaces |
| **Repeat-after-abstention** | an abstention (`path == "override"` / a `nil` result re-prompted) followed by the same action within the record window | a row for the action the user had to say twice — the first utterance is added as an additional surface for the same label |
| **Low-confidence cluster** | repeated low-confidence results for one action surface | a `corrections_overrides`-family row (§4.3) or an abstain row, depending on what the user did next |

The output of MINE is the T-034 row format (`{id, utterance, action, register, source,
confidence, spans, slots}` — `build_encoder_dataset.py:1-20`), with spans authored on the
row's own utterance under the existing invariant (`utterance[start:end] == text`; a
non-alignable row is refused, never masked — `build_encoder_dataset.py:24-30`).

Two boundaries MINE must respect:

- **The golden corpus is never a mining source and never receives a mined row**
  (`pipeline_guards.py:88-100`, `:103-120`; the normalized-membership refusal is
  `build_encoder_dataset.py:17-19`). A real user utterance that happens to match a golden
  row is refused and counted, exactly as the build already does.
- **A mining verdict is not a label.** A correction tells us the user preferred a different
  plan; it does not tell us the transcript was right, or that the corrected plan was
  executed. Mined rows enter at a *lower* trust tier than teacher rows and are additionally
  validated before the AUGMENT stage accepts them; a row that fails validation is counted
  and dropped (T-057).

### 4.3 AUGMENT — the existing corpus authoring, unchanged

Mined rows are not a new corpus. They are seeds for the **existing** authoring chain, which
already knows how to turn a few real utterances into a mixture:

1. **`gen_teacher.py` rephrase.** The teacher expands a seed template into labelled rows
   across the four registers, with the edge classes including `corrections_overrides`
   (`gen_teacher.py:179-243`, `:341-356`). Mined rows enter as seed templates and/or as
   direct rows, never as a replacement for the seed taxonomy.
2. **`stt_noise.py` variants.** Each row round-trips through piper TTS and the app's actual
   bundled Whisper, emitting `"{source_id}:noise{n}"` rows with the parent's label
   (`stt_noise.py:1-18`, `:140-145`).
3. **Leak guards and dedup unchanged.** `pipeline_guards.assert_not_golden_input` and
   `golden_keys`/`leak_refusals` (`:88-120`) run exactly as they do today; the build's
   dedup, label-conflict dropping and refusal counters are untouched
   (`build_encoder_dataset.py:20-24`).
4. **The mixture floors and caps unchanged** — `stt_noised ≥ 0.55`, corpus ≥ 8 000, per
   action ≥ 0.25 × target (`build_encoder_dataset.py:31-35`). AUGMENT adds supply; it does
   not lower a floor.

Mined rows must not be able to bypass the guards by arriving through a side door: T-057's
definition of done requires that they enter the pipeline as files inside `tools/train-intent`
that the existing stages read, so every guard that fires today fires on them too.

**Two constraints on AUGMENT, stated now because they are load-bearing:**

- The teacher sees the seed text. Feeding a *real user utterance* to `gen_teacher.py` sends
  that text to the Gemini teacher at training time. Whether the family's export consent
  covers that transit is a genuine open question and is not resolved here (see Open
  questions, OQ-2). The loop must be buildable both ways: the hashed channel (D-2) is
  unaffected either way, and T-053's privacy determination owns the answer.
- No PII in reports. Counters and hashes only (`pipeline_guards.py:16`,
  `run_encoder_pipeline.py:601-602`).

### 4.4 RETRAIN — the T-036 pipeline, weekly

The retrain *is* `run_encoder_pipeline.py` (`build → train → calibrate → eval → publish`),
unchanged except for the promotion rule (§6). Two loop-specific facts:

- **Cadence (D-3).** Weekly proposal. The pipeline is resumable, gates its own stages and
  refuses to publish on any failure (`:303-330`, `:556-559`), so a weekly run is a bounded
  cost with a mechanical abort; the loop never has to decide "is it worth training" before
  it can afford to ask.
- **The gates are the self-healing mechanism.** Eight gates in `config.yaml:56-69`:
  `closed_intent_accuracy: 0.95`, `slot_f1: 0.90`, `emergency_recall: 1.00` (hard),
  `side_effect_precision: 0.97` (call + send_message), `max_gap_vs_gemini: 0.03`,
  `abstention_precision: 0.90`, `calibration_tolerance: 0.10`
  (+ `calibration_min_n: 5`, `calibration_max_underfloor_fraction: 0.20`), and
  `emergency_recall_nearmiss: 0.98`. `eval_golden.py` enforces them and exits non-zero on
  any failure (`:821-838`, `:895-898`), including the fail-closed case where no baseline
  exists at the current corpus revision (`:814-815`). A weekly cadence is only safe because
  every one of these is a stop, not a warning.

The weekly run is *proposed*, not scheduled: a week with no new mined rows produces no run,
and T-058's promotion gate is what decides whether a produced run may publish.

### 4.5 SHADOW/HEAL — runtime convergence and the guarantee

The loop's runtime half has one job: make a wrong brain survivable at the moment it is
wrong, not at the next retrain.

**Shadow scoring.** After a candidate is trained and before (or while) it is considered for
promotion, it is scored locally against the *active* brain on real on-device turns: both
interpreter outputs are computed for the same sanitised transcript, and only the divergence
*summary* leaves — never either transcript, and never either output's content. This is
where the loop's runtime telemetry comes from, and it is what tells a human that a candidate
is worth promoting (or reverting).

**Divergence telemetry through the existing bus.** Events go through `ObservabilityBus`
(`DependencyProtocols.swift:23-34`), and therefore through `LogSanitiser`
(`AppCoordinator.swift:7274`). The bus drops every metadata key that is not allow-listed
(`LogSanitiser.swift:56-70`), so a divergence event carries only: counts, a rate bucket, the
action id, and a content-free error code. T-049 and T-050 are the binding precedent for
why: transcript content must not reach a log sink even when it is convenient
(`LogSanitiser.swift:22-49`), and the sanitiser is a boundary that must hold for emitters
that do not exist yet. **T-055's definition of done includes declaring the new allow-listed
keys in `LogSanitiser` rather than passing content through an existing one.**

**The fail-soft ladder is the healing guarantee.** The runtime already heals by falling
*through*, not by predicting:

```
keyword safety net (CommandRouter, before any model — :651, :1429)
  → intent cache
    → preferred local brain (the active encoder)
      → [on abstention] standIn (LLaMA)
        → cloud brain, when configured
          → re-prompt
```

`LocalBrainChain` consults `preferred` only while it is available and falls to `standIn`
otherwise (`LocalBrainChain.swift:28-69`); the encoder's own abstention is a stated,
content-free outcome rather than a failure (`IntentEncoderInterpreter.swift:16-32`). A
promoted brain that turns out to diverge is therefore never a cliff: an unavailable or
abstaining brain degrades to the incumbent, and the safety net and confirmation flow are
upstream of every interpreter.

**Rollback.** "Rollback" is the absence of a publish, plus the ability to re-install the
previous artifact through the same `ModelStore` path. The loop does not build a second
deployment mechanism; the promotion gate (§6) is the rollback's first line, and the ladder
is its second.

---

## 5. What leaves and what never leaves

### 5.1 The egress contract (in one table)

| Category | Examples | Leaves the device? |
|---|---|---|
| Raw audio | STT input buffers | **Never** (the app does not record it at all) |
| Raw transcript | the sanitised utterance text | **Never** on any loop path |
| Slot values | contact names, medication names, message bodies | **Never** — `IntentLogStore` holds them, and it is not what egresses |
| Profile / health | thresholds, readings, schedules | **Never** |
| Closed-vocabulary identifiers | action id (`call`, `ack_med`, …), outcome, correction kind | Yes — these are enum values, not content |
| Buckets and counters | confidence bucket, latency bucket, counts | Yes |
| Hashes | per-record hash, corpus-revision prefix | Yes — salted (§5.2) |
| Telemetry | divergence counts/rates, error codes | Yes, through `LogSanitiser`'s allow-list |

The exact payload — field names, types, and which are mandatory — is T-054's deliverable,
reviewed against T-053's privacy determination. This design fixes the rule, not the wire
format.

### 5.2 A hash is a pseudonym: the salt requirement

An unsalted hash of an utterance can be confirmed by an observer who can guess the
utterance — which, for a household whose utterances are drawn from a small, predictable
command vocabulary, is a real risk for the low-entropy cases. The egress payload therefore
uses a **per-install, device-held salt** so the same utterance does not hash to the same
value across installs and cannot be checked against an external dictionary. The repo's
existing hashing (`gen_teacher.row_id`'s SHA-256 over register/action/utterance,
`gen_teacher.py:41-43`; `pipeline_guards.sha256_file`) happens on the training box and is
not an egress mechanism; it is cited here only to show that hashing is an established,
inspectable convention in this suite — not to justify reusing an unsalted form at the
boundary. Salt handling, rotation and the decision-not-to-rotate are T-053's to rule on and
T-054's to specify.

### 5.3 Why the hashed channel is not the observability bus

The bus is a local logging boundary with an allow-list, and its shipped implementation is
`ConsoleObservabilityBus`, which prints (`AppCoordinator.swift:7260-7278`). An egress path
that reused it would either have to add a network sink to the bus — widening the contract
that T-049/T-050 just hardened — or route device data through a console printer. The
separate, opt-in uploader keeps the bus's contract intact (PII-free local diagnostics) and
gives the egress path its own, narrower contract (hashed-only, opt-in, TLS 1.2+ per
NFR-011). The loop's *telemetry* goes through the bus; the loop's *egress* does not. T-054
fixes the transport; T-059 audits it end to end.

---

## 6. The promotion rule

**A candidate may be published only when all eight T-038 gates pass AND the candidate beats
the incumbent on the corpus-revision-bound eval.**

The two halves are both necessary:

- **The eight gates are absolute floors** (`config.yaml:56-69`), enforced by
  `eval_golden.py` with a non-zero exit (`:821-838`, `:895-898`). They answer "is this model
  acceptable?".
- **"Beats the incumbent" answers "is this model better than what the user has?"** A
  candidate can clear every floor and still be a regression on a household's actual traffic.
  This comparison is only meaningful because the harness binds every results row and every
  baseline to a corpus revision with the `@<hash8>` label suffix
  (`eval_golden.py:505-537`, `:603-606`), and fails **closed** when no baseline exists for
  the current revision — UNEVALUATED is a failure, not a pass (`:742-763`, `:814-815`).

The existing pipeline driver already refuses on harness failure, calibration failure,
provenance mismatch and an unset artifact version
(`run_encoder_pipeline.py:303-330`, `:556-559`); it does **not** yet compare against the
incumbent. T-058 adds exactly that half, into the same single non-zero-exit decision — not
as a second, parallel gate runner. No model publishes without it (D-4: the rule can only
block; a human still performs the publish).

---

## 7. Boundaries and invariants

1. **Safety stages stay deterministic, forever.** The keyword safety net, emergency
   handling, explicit medication acknowledgement and the confirmation flow are not
   participants in the loop: they run before any model (`CommandRouter.swift:651`, `:1429`),
   and no loop artifact can gate, suppress or replace them. Neither the capture path nor
   the shadow path is allowed on their critical path.
2. **Nothing in the loop may degrade the runtime budget.** Shadow scoring runs off the
   reply path; it must not turn one inference into two inside the user's response time
   (NFR-002). T-055 specifies the measurement.
3. **No new threshold.** The band policy (`IntentRouter.swift:49-58`, `:318-319`) is not
   modified by the loop; divergence is telemetry, and a divergence rate never becomes a
   runtime decision by itself.
4. **The golden corpus is never a training input**, at any stage of the loop, and mined rows
   go through the same refusal (`pipeline_guards.py:88-120`).
5. **No PII in any report, manifest or log**, per NFR-016; T-049/T-050 are the standard.
6. **Android is out of scope.** The loop is designed for the iOS MVP; the encoder's Android
   runtime (T-037-b) is unaffected, and no Android capture path is designed here.

---

## 8. Options weighed

### 8.1 Egress model

| Option | Verdict | Why |
|---|---|---|
| **(A) Keep only the family export** (today's shipped state, no loop) | Retained for *content*, rejected as *the loop* | Requires a human to carry a file before a retrain can see anything; the 500-record cap can trim signal before anyone exports it (D-3). It stays the only way content leaves. |
| **(B) Replicate the log to a server, encrypted** | Rejected | This is exactly what Architecture Constraint 1 and NFR-015 forbid: personal data leaving the device for AI processing. Encryption in transit does not change who processes it. |
| **(C) Hashed/signal-only egress (chosen)** | Chosen | The smallest payload that can still drive a weekly mine and a divergence telemetry loop; compatible with Constraint 1 as written. |
| **(D) On-device mining only, zero egress** | Kept as the fallback floor | If T-053's privacy review says no egress is defensible, the loop degrades to: mine on-device, and let the family export content explicitly, exactly as today. The retrain and promotion halves still work; only the telemetry and the automatic "worth mining" signal are lost. |

### 8.2 Mining sources

| Option | Verdict | Why |
|---|---|---|
| Corrections only | Rejected as *the* set | Highest value per row, but the yield is whatever the household happens to correct; T-052 measures it. |
| **Corrections + repeat-after-abstention + low-confidence clusters (chosen)** | Chosen | The three signals are already recorded (`outcome`, `path`, confidence buckets) and target different failure modes: wrong plan, unanswered utterance, uncertain model. |
| All turns, indiscriminately | Rejected | Most of the corpus would be confirmations of a brain that is already right, at real privacy cost and no accuracy gain. |

### 8.3 Promotion

| Option | Verdict | Why |
|---|---|---|
| Gates only (existing plumbing) | Insufficient | Absolute floors do not detect a regression against the brain the user actually has. |
| **Gates + beat the incumbent on the bound eval (chosen)** | Chosen | Uses the harness's existing corpus-revision binding, so the comparison is meaningful and fails closed; the "beat" half is additive to the existing publish decision. |
| Human review only | Rejected as the *gate* | Human review stays on the publish decision (D-4), but review without a measurement is an opinion. |
| Automatic publish on pass | Rejected | D-4. |

---

## 9. Deliberately out of scope

- **Any change to the encoder, its taxonomy, its loss or its data contract.** TG-08 owns
  those (T-034/T-035/T-036); the loop consumes them.
- **Any change to the safety stages, the router, or the confirmation flow** (§7.1).
- **A model-serving or deployment mechanism.** Publication is the existing
  manifest + copy path (`run_encoder_pipeline.py`); rollback is re-installing a prior
  artifact through `ModelStore`.
- **An Android capture or shadow path.**
- **Any on-device training.** The loop's training stays on the training box; the device
  produces signals.
- **A consent UX implementation.** T-053 determines what the copy must say and T-056
  implements it; this document fixes only that it is opt-in (D-1) and revocable.

---

## 10. Requirements traceability

| Requirement | Where this design serves it |
|---|---|
| NFR-015 (no personal data to cloud for AI processing) | §4.1, §5.1, D-2 — hashed-only egress; content leaves only via the family export |
| NFR-016 (no PII in logs; sanitiser required) | §4.5, §5.3, §7.5 — telemetry rides the allow-listed bus; T-049/T-050 precedent |
| NFR-013 (quarantine sanitisation) | §4.2 — mined rows are authored on the sanitised transcript, as the encoder consumes it |
| NFR-011 (TLS 1.2+) | §5.3 — the egress transport; T-054 specifies, T-059 audits |
| NFR-023 / NFR-024 (externalised strings; Nepali + English) | §4.1, §9 — the consent and opt-out copy; T-056's DoD |
| NFR-029 (0.85 safety threshold; rework) | §6 — promotion is safety-critical code, gated and reviewable |
| NFR-032 (privacy policy truth) | §4.1, §5.1 — the policy must describe the loop's collection and egress; T-053 and T-059 own the wording check |
| FR-009 (no LLM dependency in safety-critical paths) | §7.1 — the loop never touches the safety net, emergency call or medication paths |

---

## 11. Task mapping

| Task | Title | This design's input |
|---|---|---|
| T-052 | Continuous-Learning Signal Quality — Feasibility (R&D) | §4.1, D-3 — measure whether the three signals predict errors, at what yield, over the shipped record shape |
| T-053 | Learning-Loop Privacy Review (R&D) | D-1, D-2, §5.1–5.3 — the consent basis, salt, retention and disclosure obligations |
| T-054 | Capture Schema & Egress Contract Design | §4.1, §5 — the record extension and the exact egress payload |
| T-055 | Shadow Scoring & Healing Protocol Design | §4.5, §7 — divergence telemetry, the ladder, rollback |
| T-056 | Capture & Egress Implementation (opt-in) | D-1, D-2, §4.1, §5 — the capture path, the consent control and the §4.1 docstring amendment |
| T-057 | Correction Miner Implementation | §4.2, §4.3 — mined rows into the existing AUGMENT chain |
| T-058 | Promotion Gate Implementation | §6 — the single non-zero-exit promotion decision |
| T-059 | Privacy Audit (verification) | §5 — end-to-end evidence that nothing raw left, and that the opt-in is honest |
| T-060 | Loop End-to-End Fixture (verification) | §4, §6 — a deterministic capture → mine → augment → promotion fixture |

---

## Risks and mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R-1 | **The correction signal is too sparse to be worth the loop.** Corrections are rare by construction; a household may produce a handful per week. | The loop's cost (weekly GPU runs, privacy surface) buys nothing, and a model trained on 20 mined rows over-fits them. | T-052 measures yield before anything is built, and its report can conclude "not worth it" — that is a valid outcome, not a failure. Minimum-row floors stay in force; AUGMENT adds supply, never lowers a floor (§4.3). |
| R-2 | **The `IntentLogStore` cap loses signal between retrains.** 500 records, oldest trimmed (`IntentLogStore.swift:17`, `:49`). | A weekly retrain sees an ever-shrinking, recency-biased window. | D-3 names this as the cadence's cost; T-052 measures the roll-off rate, and T-054 owns the compact derived-signal summary that survives trimming. If the roll-off is severe, the cadence or the cap changes — an explicit decision, not drift. |
| R-3 | **A hash is re-identifiable.** Low-entropy utterances can be confirmed against a dictionary. | The "hashed-only" claim overstates anonymity; the privacy review would be relying on a false premise. | §5.2 requires a per-install salt; T-053 rules on retention and necessity; T-059 tries to break the claim. The design does not claim anonymity — it claims hashing plus salt, and says so. |
| R-4 | **The teacher transit question is unresolved.** Feeding real utterances to `gen_teacher.py` sends them to the Gemini teacher (Open questions OQ-2). | Mined rows could create an unintended cloud path for user text under a consent that did not cover it. | The hashed channel (D-2) is unconditionally safe; the content path is unchanged from today's explicit-export precedent (T-036 §7). T-053 must rule before T-057 feeds any mined row to the teacher; T-057's DoD requires the ruling on record. |
| R-5 | **Shadow scoring competes with the user's response budget.** Two interpreters on one turn is real work. | NFR-002's 4-second budget would be spent on a measurement the user did not ask for. | §7.2 makes off-the-reply-path a hard requirement; T-055 specifies where it runs and how it is measured; T-060's fixture proves the loop's stages are not on the turn path. |
| R-6 | **Divergence telemetry leaks by accretion.** A new metadata key is added to a divergence event and carries content. | NFR-016 violated through the loop's own diagnostics — the exact failure mode T-049/T-050 were raised for. | §4.5 requires new allow-listed keys to be declared in `LogSanitiser` explicitly, and T-059's audit covers the loop's own telemetry, not just the egress payload. |
| R-7 | **Promotion passes on a corpus that no longer represents the household.** Gates are measured on the held-out corpus, not on this user's traffic. | A "better" model regresses on the real distribution, and the loop's own numbers said it was fine. | Shadow scoring (§4.5) is the counter-measure — divergence is measured against the live brain on live turns, which is the only signal the corpus cannot supply. The promotion rule is deliberately stricter than "gates passed". |
| R-8 | **The opt-out is dishonest.** A user turns the loop off and the already-egressed signals keep being used. | D-1's consent is not actually revocable, which is a deeper failure than any accuracy issue. | T-056's DoD includes the deletion of not-yet-egressed signal and the stop of future egress; T-059 audits the honesty of the opt-in and the opt-out end to end, and is a verification task for exactly this reason. |
| R-9 | **Weekly cadence becomes weekly publishes.** A schedule plus an automated gate drifts into automated release. | D-4's human publish gate erodes silently. | §6's rule is expressed as "can only block"; T-058's DoD states explicitly that the gate wires no deployment; T-060's fixture drives the blocking case, not the publishing case. |

## Open questions

1. **OQ-1 — Does the loop need its own disclosure, or is it an amendment to Open Decision
   12's consent?** The recorded cloud exception (`constitution.md:128-132`) establishes the
   project's pattern for a consent-gated, non-default path. The loop is not a cloud AI
   processing path for content — but its *existence* changes what the privacy policy must
   say (NFR-032). Whether that is a new consent screen, an addition to the existing one, or
   an amendment to the recorded exception is genuinely undecidable from the code and is
   T-053's determination. **Cannot be resolved from evidence; owned by T-053.**
2. **OQ-2 — Does the family's export consent cover teacher transit?** The AUGMENT stage
   (§4.3) sends seed text to the Gemini teacher. Existing T-036 governance admits consented
   exports into the training batch (`…encoder-training-data-strategy.md` §7), but "admitted
   into the training batch" and "sent to a third-party teacher" are different acts, and the
   repo records that consent-export ingestion is not implemented and refuses loudly
   (`run_encoder_pipeline.py:598-600`). **A real unresolved tension; T-053 rules before
   T-057 may feed a mined row to the teacher.**
3. **OQ-3 — Retention window for captured signals and for the egress log.** The
   `IntentLogStore` cap is a device-side bound, not a retention policy; the egress side has
   no bound at all today. T-053 must set one (its brief requires "the retention window it
   requires"), and T-054 must be able to enforce it. **Not inferable from the code.**
4. **OQ-4 — Does the incumbent in the promotion comparison include the cloud brain?** §6
   compares the candidate to "the incumbent on the corpus-revision-bound eval". The harness
   can baseline against Gemini (`--backend gemini`, `eval_golden.py:505-537`) and the gate
   `max_gap_vs_gemini: 0.03` already bounds the gap, but "beat the incumbent" for a
   household whose active brain is the cloud engine is a different comparison from one on
   the on-device encoder. T-058 must define the incumbent per configuration. **Decidable
   only with T-058's implementation context.**
