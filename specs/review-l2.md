# Review — L2 Component Design (Live Camera Translation, EN → NE v1)

**Task:** `review-l2` (contract `review_report`) · **Agent:** `reviewer`
**Artifact under review:** `specs/design-component.md` (1,458 lines, contract `component_design_l2`)
**Feature:** `live-camera-translation` · branch `worktree-live-camera-translation` · 2026-09-16
**Workflow exit condition:** `review.decision == GO`.

**Inputs.** The artifact; `specs/define-requirements.md`, `specs/define-requirements/index.md` and
`specs/define-requirements.lock.yaml` (23 FR / 13 NFR, read-only); the per-requirement files under
`specs/define-requirements/FR/` and `specs/define-requirements/NFR/`; the owner-approved first-pass
design `docs/superpowers/specs/2026-09-16-live-camera-translation-design.md` (§10 open decisions,
§11 divergences); the feature constitution `specs/live-camera-translation/constitution.md`; the
project `constitution.md`; and the workflow `.ai-sdd/workflows/live-camera-translation.yaml`.

**Verification method.** The design was checked against the locked requirement set and both
constitutions, and every claim it makes about shipped code was verified by reading that code:
`Services/Gemini/` (`GeminiClient.swift`, `GeminiClient+Vision.swift`, `GeminiConfigStore.swift`,
`GeminiCostGovernor.swift`), `Services/Appliance/` (`ApplianceLabelLocalizer.swift`,
`ApplianceHelperView.swift`, `ApplianceCache.swift`, `ApplianceOverlayMapper.swift`),
`Services/Plugins/` (`ApplianceHelperPlugin.swift`, `AssistantPlugin.swift`, `PluginRegistry.swift`),
`Services/Storage/` (`StoragePlacement.swift`, `EncryptedFileStorage.swift`, `KeychainEncryptedStorage.swift`),
`Services/Voice/` (`InputSanitiser.swift`, `SpeakQueue.swift`, `Announcement.swift`),
`Services/Observability/` (`LogSanitiser.swift`, `ErrorCodeMapper.swift`),
`Services/MedicationScheduler/` `DependencyProtocols.swift`, `ios/tools/check-release-log-safety.py`
and `ios/project.yml`. This review is read-only: no artifact was modified.

## Summary

**All review criteria are met.** The L2 component design is a correct, complete and buildable fold of
the signed-off requirement set, it stays inside scope, it carries D1–D5 forward, and it implements
OD7/OD8 exactly as the owner directed. There are **no blocking findings**. The review records eight
non-blocking clarifications (CL-1 … CL-8), two of which are security-relevant, to be picked up by
`security-design-review`, `plan-tasks` and implementation; none changes the architecture or the scope.

**What is strong.** Requirement traceability is complete — all 23 FR and 13 NFR map to a named
component and, where behavioural, to a test seam; the error taxonomy declares an explicit, enumerated
error type on every fallible surface, with stable content-free `error_code` tokens; the 24-row
failure/retryability matrix states, per asynchronous operation, what fails and whether it retries,
and pins two invariants ("no failure path issues unbounded requests" and "every failure terminates in
a rendered state"); every operational constant is owned by one `LiveTranslateConfig` with documented
defaults and the base cloud timeout is single-sourced from the shipped client config; each security
invariant names its enforcement point and how a reviewer falsifies it; and deferred capability is
structurally unrepresentable (no tier-1 enum case, no direction flag, no photo output, no observer
that speaks on resolution) rather than present-but-disabled — D2's "absent, not stubbed" rule.

**Verdicts on the five items the author asked to be scrutinised.**

| Item | Verdict |
|---|---|
| R7 — per-day governor shared with the voice pipeline | **Accepted as designed; no design change needed.** Correctly characterised, requirement-sanctioned, and surfaced at the level FR-LCT-013 and FR-LCT-023 demand (see below). |
| R8 — FR-LCT-020 sharing delta on the appliance helper's presentation path | **Claim holds** under the design's localizer-precedence rule. One wording overclaim to fix (§C06) and one required test to name. The delta is *required* by FR-LCT-020 scenario 2, not an accident. |
| R12 — `blockedByProvider(reason:)` provider string on the log surface | **Deferring to `security-design-review` is the right call**, and the description of the shipped behaviour is accurate. One cross-reference fix requested so the design's own log-safety sentence is not read as unlimited. |
| Deliberate `TranslationResult` change (outcome enum as source of truth) | **Correct and required.** A non-optional `sourceTier` cannot satisfy FR-LCT-008 scenario 3 honestly. The four documented accessors are preserved; the change makes the FR-LCT-008/NFR-LCT-010 property structural. |
| Consent prompt with no timeout, by design | **Sound.** It is the only reading of FR-LCT-010 that does not manufacture implicit consent; the project's configurable-timeout principle bans hardcoded operational constants, not the absence of a value that would be wrong. |

**Findings at a glance** (none blocking; details and fixes in the sections below).

| # | Finding | Severity | Route to |
|---|---|---|---|
| CL-1 | In-flight dedupe: `BatchResult` has no stated terminal outcome for an already-claimed key, so a second observation of the same string could sit in `pending` forever | Correctness (moderate) | implementation; `plan-tasks` |
| CL-2 | The single retry must re-read the consent decision and honour cancellation, so C09's "no new request may be issued after the revoke returns" holds between attempt 1 and the retry | Security (moderate) | implementation; `security-design-review`, `security-test` |
| CL-3 | The `Origin` → `sourceTier` mapping is implied, not stated; it is load-bearing for FR-LCT-015 (a cached cloud string must never be drawn in place) | Correctness (low) | implementation |
| CL-4 | No error → `TranslationUnavailableReason` mapping table (27 error cases, 8 reasons) | Clarity (low) | implementation |
| CL-5 | The feature's event-metadata keys are not in `LogSanitiser.allowedKeys`; the shipped bus drops unknown keys silently | Evidence/completeness (low-moderate) | implementation; `security-test` |
| CL-6 | C07's "detect-only use of the shipped marker table" has no implementable seam — that table is `private` | Implementability / security-adjacent (low) | implementation |
| CL-7 | The R8 regression test is referred to but not named in the test-seam list; §C06's "every label the helper renders today renders identically" overclaims | Precision (low) | implementation; `plan-tasks` |
| CL-8 | Cosmetic set: `SpokenOutput` named but undefined, `App/Gemini+Translate` path, the `C23` reference, the FR-LCT-017 touch entry point, the untraced `repeatLast` command, mapper-math test coverage, `cloudRequestTimeout` duplication | Cosmetic / completeness (low) | `plan-tasks` |

## Scrutinised items

### R7 — the per-day governor is shared with the voice pipeline

**Verdict: accepted as designed; properly surfaced; no design change required.**

What the design gets right, verified against the shipped code:

- The bound is the shipped per-day `GeminiCostGovernor` (cap default 200, clamped 10 … 1000,
  family-editable, key `gemini.costGovernor.v1`), checked in `GeminiClient.send(_:)` **before any
  network work**, with `recordCall()` at the transport boundary ("the cost is the attempt"). OD7 is
  owner-settled, and the design implements it verbatim and marks the first-pass "per-session cap"
  wording as superseded.
- The design's addition — a session-scoped, monotone fail-closed latch — supplies exactly the
  behaviour FR-LCT-013 scenario 2 demands ("no cloud request is issued for the rest of the session")
  without inventing a new governor. Re-consulting the governor at the next session is the designed
  recovery, and the latch never degrades anything else: camera, dictionary and cache keep working,
  which FR-LCT-013 scenario 1 requires.
- Surfacing is at the level the requirements demand, and no more is demanded. FR-LCT-013's own text
  sanctions "the original text with the honest unavailable/offline indication", and FR-LCT-023's
  table groups *no network*, *no consent* and *no budget* under that same indication. The design
  keeps the cause distinguishable internally (`costBudgetExhausted`, a distinct `reason` token and
  the `cost_exhausted_latched` event) so cause-specific copy could be added later without a design
  change, and the family-visible signal (`daily_cap_warning` / `daily_cap_reached`) already exists
  and is untouched.
- The design correctly refuses to edit the FR-LCT-013 wording or the project constitution's Open
  Decision 13, and records the amendment as an owner action. That refusal is right and must stand:
  those files are downstream hash-locked and the amendment is not an agent action.

**Judgement.** An elder on a heavy voice day sees an honest unavailable indication with no statement
of cause. That is a real, accepted consequence of OD7 — recorded as R7 with the mechanism and the
owner — and it is the consequence the requirement set itself chose when it bound behaviour rather
than a per-session sub-cap. It does not need a design change. The residual worth stating for the
record: the elder-facing wording must stay cause-neutral (for example "unavailable", not "offline")
so it remains true when the device is online but the budget is spent; the OD3 copy review is where
that lands.

### R8 — the FR-LCT-020 sharing delta on the appliance helper's presentation path

**Verdict: the NFR-LCT-012 claim holds under the design's localizer-precedence rule, subject to one
wording fix (CL-7) and one required test.**

The requirement set contains a real tension, and the design resolves it the only way it can be
resolved:

- FR-LCT-020 scenario 2 **requires** the appliance helper to use the shared cache ("live translation
  has cached a label translation → when the appliance helper presents the same label, the same
  cached translation is used"). So an observable delta in the helper is mandated, not accidental.
- NFR-LCT-012's operative acceptance criteria are that the shared components' *public functions and
  behaviour* are unchanged, that the additions are "extensions (new entries, new callers), not
  modifications", and that the helper's existing tests stay green.
- The design satisfies both: `ApplianceLabelLocalizer` is untouched (data extension only, with the
  47 shipped entries pinned by a test — the shipped file holds exactly 47 dictionary entries), and
  the new behaviour arrives as a new caller-side resolver at the presentation seam
  (`Services/Appliance/` `ApplianceHelperView.swift`, the `controlSection` / `buttonLabel` path that
  today calls `ApplianceLabelLocalizer.display(for:locale:)`), with the localizer's own result taking
  precedence.

The delta is therefore exactly one class: a label the helper presents, that the localizer passes
through today (it is not a curated key and not already Devanagari, per the shipped `display(for:locale:)`
logic), and whose normalized form exists in the shared cache from a prior live-translation cloud
resolution. Every label the helper *translates* today renders identically. That is the honest claim,
and it is the one R8 makes.

Two corrections are required, neither architectural:

1. **§C06 overclaims.** It says "every label the helper renders today renders identically", which is
   false for the pass-through class — the very delta R8 then describes. Reword to "every label the
   helper *translates* today renders identically", keeping the R8 pointer (CL-7).
2. **The test must be named in the seam list.** §Interfaces → "Test seams and required unit coverage"
   does not list the helper-presentation regression test. Add it there with three cases: a
   dictionary-known label renders exactly as today; a cache-populated pass-through label renders the
   cached translation; and when both a localizer result and a cache entry exist, the localizer wins
   (CL-7).

One completeness note for the same section: the dictionary extension to ~120 entries is *also* a
change in what the helper renders for newly-curated labels. That form of extension is explicitly
sanctioned (FR-LCT-007 "extended, not forked"; NFR-LCT-012 "extended data set only"), so it is not a
finding — but R8 should name it alongside the cache delta so the helper's full behavioural delta is
on one page for `security-design-review` and the owner.

Implementation is feasible as designed: the presentation seam is synchronous view code, and the
cache's `lookup` is a synchronous, lock-guarded call, so no async plumbing is introduced into the
view path.

### R12 — the provider block reason on the log surface

**Verdict: deferring the question to `security-design-review` is the right call.**

The design's description of the shipped behaviour is accurate, and I verified it:

- `GeminiClient.send(_:)` emits `gemini_blocked` with `errorCode = blockReason` (the provider's
  `promptFeedback.blockReason` value) and then throws `blockedByProvider(reason:)`
  (`Services/Gemini/` `GeminiClient.swift`). The `LogSafeErrorCode` conformance for the error itself
  returns the constant `blocked_by_provider`; the *event field* carries the raw provider value. So
  the shipped value in question is genuinely emitted as an `error_code`, exactly as R12 states.
- On this feature's path, the throw is mapped to `cloudPolicyBlocked` → the constant
  `cloud_policy_blocked`, so the feature adds no second emission of the provider value.

Why deferral is correct rather than a gap:

- The emission lives in shared shipped code used by the voice and vision paths. Editing it would
  change behaviour the feature is required not to weaken (NFR-LCT-012), and it is not this feature's
  change to make.
- It is precisely a `security-design-review` line item: that gate's stated focus includes the cloud
  egress path and the log surface, and it owns STRIDE for this feature.
- The design states the question with its mechanism, its file and its owner instead of assuming an
  answer, which is the honest form of an unresolved question and exactly what this review was asked
  to confirm.

Refinements requested (not a blocker):

- Cross-reference R12 from the two places that state the log-safety invariant (the Observability
  paragraph and the security-invariant table), so a reader does not take "`errorCode` is always a
  `LogSafeErrorCode` constant or a status number" as unlimited on the shared chokepoint path.
- List R12 as a named input to `security-design-review` so the referral cannot be lost, and state
  what is already true: `LogSanitiser` enforces the code charset, redacts one unbroken 32+ character
  run and caps the length (`Services/Observability/` `LogSanitiser.swift`), so the residual exposure
  is a short upstream token. Whether a provider token of that shape is acceptable on the log surface
  is the question for the security review.

### The deliberate `TranslationResult` change

**Verdict: correct, and required by FR-LCT-008; the documented accessors are preserved.**

The first-pass design's flat shape (`text`, non-optional `sourceTier`, `isFinal`, `degraded`) is
internally inconsistent with FR-LCT-008 scenario 3 and NFR-LCT-010: a "no tier produced a
translation" result must not claim a tier, but a non-optional `sourceTier` forces it to name one.
Making `TranslationOutcome` the single source of truth and deriving `text`, `sourceTier`, `isFinal`
and `degraded` from it is the minimal fix, and it converts a procedural rule into a structural one:

- `sourceTier` is non-nil only for `.resolved`, so a tier that did not translate is not nameable —
  FR-LCT-008 scenario 3 by construction.
- `TranslationTier` has exactly two cases, so no resolution path can claim the deferred on-device
  tier — FR-LCT-008 scenario 4 and D2's "absent, not stubbed".
- `text` falls back to the original recognized text, `isFinal` is false only for `.pending`, and
  `degraded` is true only for `.degraded`, matching FR-LCT-008 scenario 3 and FR-LCT-018's three
  states. Monotonic transitions match FR-LCT-018 scenario 3.

Two small completeness items follow from it and are recorded as CL-3 and CL-4: the
`Origin` → `sourceTier` mapping (a persisted entry was produced by the cloud tier, so a cache hit
must report `.cloud` — this is what keeps a cached cloud string out of the in-place path FR-LCT-015
reserves for tier 0), and the error → reason mapping.

### The consent prompt's deliberate absence of a timeout

**Verdict: sound; the exception is correctly reasoned and correctly stated.**

- FR-LCT-010 requires the prompt at the first cloud need, before any request, and requires the gate
  to fail closed. Nothing requires a timeout, and no timeout value can be correct: if the prompt
  dismisses itself and that were treated as a grant, it would be implicit consent, which the
  requirement forbids; if it were treated as a denial, the elder would be silently denied a service
  they never declined.
- The project principle is that timeouts are configurable parameters rather than hardcoded
  constants — it forbids a buried literal, not the absence of a value. The design states the
  exception explicitly and says why the parameter does not exist (the parameter table lists it as
  "no timeout, by design … a value here would be a compliance defect"). That is the right treatment
  of a principle with a genuine exception, and its scope is correctly narrow: it is the only such
  exception, and it is named at exactly one place in the parameter table.
- The blocking semantics are consistent with the rest of the design: while the prompt is on screen
  no request is in flight, the cloud indicator is off (FR-LCT-011's "driven by actual activity"), and
  the affected regions sit in `pending`, which is not a stalled state because no request has been
  issued and the decision is the user's. The prompt is shown at most once per session until the user
  answers, so there is no prompt loop.

## Independent verification

### Interfaces and explicit error types

**Passes.** Every fallible surface declares an enumerated error type: `LiveTranslateError` with
typed reason enums; `LabelTranslationCache.CacheError`; `LiveTranslateConsentGate.ConsentError`;
`TranslationResponseParser.Defect`; `Result`-returning camera and detector entry points; `PluginResult`
for the plugin entry. No interface returns `any` or `unknown`, and no error field is untyped.

One deliberate exception is named and justified: `GeminiClient.translateStrings(items:targetLanguage:)`
keeps the shipped `throws`-based contract of the `send(_:)` chokepoint it must reuse (NFR-LCT-012
forbids a parallel request path), and `CloudTranslationTier` converts `GeminiClientError` into the
feature taxonomy at its own boundary. The error type is discoverable (the shipped `GeminiClientError`)
and the conversion point is stated, so the Agent Principle ("explicit error return types, not `any`
or `unknown`") is honoured rather than stretched. This is the right call.

Total functions with no failure mode say so: `TextRegionStabilizer`, `SceneTextSanitiser`,
`LiveOverlayPlacement`, `TranslationPrompt`, `TranslationResponseParser`, and the config value type.
`LiveTranslateCommandParser.parse` returns an optional, where `nil` means "not a command" (a re-prompt
path), not an error.

### Failure modes, retryability and timeouts

**Passes, with CL-1 and CL-2.** The Interfaces matrix covers 24 asynchronous operations with a
failure mode, a retry decision and the component that owns the policy. It contains no unbounded retry
(one automatic retry for transient failures, none for policy refusals, none for the cost latch, none
for speech), and it states the two invariants this review checked against the requirement text: no
failure path issues an unbounded number of requests, and every failure terminates in a rendered state
(translation, degraded-with-original, or the empty-state hint).

Timeouts and retry limits are configurable with documented defaults in one owner (`LiveTranslateConfig`):
`ocrSampleInterval`, `thermalCadenceFactor`, `regionMatchIoU` / `regionMatchCentroidDistance`,
`regionAppearPasses` / `regionMissPasses`, the declutter pair, the in-place pair, `cloudMaxRetries`,
`cloudBatchMaxStrings` / `cloudBatchMaxCharacters`, `sceneTextMaxLength`, `cacheGeneralEntryLimit`,
and the deadline composed from the client's `Config.default.timeoutSeconds` (25) plus
`cloudDeadlineGraceSeconds`. No operational literal appears in the request code, so NFR-LCT-011's two
acceptance scenarios are satisfiable as designed.

Notes, none blocking:

- `LiveTextDetector.recognize` and `LiveCameraSession.start()` / `resume()` are asynchronous without a
  numeric timeout. They are local, OS-bounded operations (Vision passes on a downscaled buffer; session
  start and permission) with no network leg, and no hardcoded constant exists for them — the principle
  forbids hardcoded values, not the absence of a value where none is meaningful. The design also states
  the deliberate absence for `LiveTranslatePlugin.handle` ("no timeout of its own … no cloud call
  happens during entry"), which is the honest form.
- `LiveTranslateConfig.cloudRequestTimeout` is declared while the deadline derivation reads the
  client's own config. The design says the base timeout has one source of truth (the client), which is
  right; the declared field should be documented as derived/read-only or dropped, so it cannot drift
  into the duplicated-divergent-constant shape NFR-LCT-011 warns about (CL-8).

**CL-1 (dedupe terminal state).** Step 5 of the tier's orchestration claims unresolved keys
atomically and leaves already-claimed keys to "resolve when the existing request completes", but
`BatchResult` only has `resolved` and `failures`, so the interface does not say what the second
caller receives. If an implementer returns nothing for a deduped key, that region sits in `pending`
for the rest of the scene — an unbounded pending state (NFR-LCT-001 scenario 2) and a de-facto silent
drop (NFR-LCT-010). State the mechanism: for an already-claimed key, `resolve` awaits the in-flight
task and returns its terminal outcome in the same `BatchResult`, or add an explicit third category.
Add the matching test (the second observation reaches the same terminal outcome, not merely that one
request was sent).

**CL-2 (consent on the retry path; security-relevant).** C09 asserts "no new request may be issued
after the revoke returns", and NFR-LCT-007 requires that no code path — "including retries" — reaches
the cloud tier without consent. The single retry is issued inside `resolve`, after the batch-level
consent check; if consent is revoked in the interval, the design does not say where the retry
re-reads the gate or honours cancellation. State it explicitly (re-read `currentDecision()` before
the second attempt, read-through and fail-closed, and check task cancellation, which revocation also
sets), and give `security-test` the evidence case: revoke between attempt 1 and the retry, then
assert zero further requests.

### Traceability and scope

**Passes.** The §8 table maps all 23 FR and 13 NFR to named components, and the interfaces section
gives each behavioural requirement a test seam. Every element of the design traces to a requirement
except one small extra — the `repeatLast` session command — which FR-LCT-022 explicitly permits
("at minimum: read this to me, the toggle phrase, and stop/close"). Keep it or drop it at
`plan-tasks`; either way it is not scope creep (CL-8).

No out-of-scope capability has crept in, and the §2 "absent by design" table shows each non-goal as
structurally unrepresentable rather than stubbed: no tier-1 case exists to return (D2, FR-LCT-008
scenario 4); no direction flag exists for the reverse phrase-card mode (OD6); no world-space input
reaches placement (no ARKit); the only `Announcement` construction sites are the tap handler and the
command handler (no auto-speak); nothing calls the appliance helper's one-shot guidance path (no
live full-scene explanation); `LiveTranslateConfig` has no UI (no family/caregiver surface beyond
the FR-LCT-017 toggle, which is required and is elder-facing); and nothing shared is on the feed
path. The requirement set's out-of-scope list is therefore fully honoured.

Verified claims about the shipped surface (all check out): 47 dictionary entries in
`ApplianceLabelLocalizer`; the localizer's exact-match, Devanagari pass-through and `isNepali` gating
unchanged; the plugin template's availability guard at `Services/Plugins/` `ApplianceHelperPlugin.swift`
(the guard `LiveTranslatePlugin` must not copy, correctly identified as a correctness bug rather than
a style choice); `PluginRegistry` has no deregistration (so the design's "no cross-session state in
the plugin" rule is the right mitigation); `EncryptedLocalStorage` has `write` / `read` / `delete`
only, no enumeration (so the single-key whole-payload shape is the established pattern, as
`ApplianceCache` already does); the three new storage keys are not in
`StoragePlacementPolicy.keychainResidentKeys`, so they land on the encrypted file channel (Application
Support, Data Protection class Complete, backups excluded) exactly as the design states; and the
`GeminiRequest` builder takes text parts with optional tools, with a `GeminiTransport` seam available
for the required stubbed-transport integration tests.

### Security invariants: enforceability

| Invariant | Enforceable as designed? |
|---|---|
| Consent before any tier-2 request | Yes — the gate is the feature's single cloud caller path; see CL-2 for the retry wording. The check lives in `CloudTranslationTier.resolve` rather than in the shared `GeminiClient`, which is the right layering (the client is shared); the design should state that `translateStrings` has exactly one caller and that `security-design-review` verifies that single-caller discipline, since "no code path reaches the cloud tier without consent" rests on it. |
| Text-only egress, no image | Yes — the builder exposes no media parameter and the capture session configures no photo output, so the feature has no image bytes to attach; the retry reuses the same payload shape (FR-LCT-014 scenario 3). Verified against the shipped request type; the vision path's media parts are not touched by the translation path. |
| No recognized or translated text on the log surface | Yes for the feature's own events (the schema admits counts, durations, tiers, reasons and statuses only), and the gate script walks the whole source tree so the new directories are covered automatically. The one carve-out is the shared chokepoint emission at R12, correctly referred to `security-design-review`. Wrap-up per CL-5 below. |
| Cache encrypted at rest, no plaintext file | Yes — placement, atomic whole-value write, no scene metadata, corrupt payload discarded and rebuilt, deletion by key. |
| Cost governor fails closed | Yes — the pre-network check is in shipped code and the session latch makes later attempts a no-op; no alternative request shape exists. The monotone-within-session reading is faithful to FR-LCT-013 scenario 2. |
| Truthful cloud indicator | Yes — one input (the in-flight counter, released in `defer`), not writable from settings or the overlay, no minimum-dwell timer. |
| Truthful tier attribution | Yes — structural, via the outcome enum (see above). |
| Scene text cannot act as a directive | Yes, with CL-6. Sanitise-and-bound before egress, data-delimited payload, no tools on the request, response accepted only for requested keys with string values, oversized values rejected, quarantine degrades honestly. |
| Withdrawal is immediate and total | Yes, subject to CL-2. |
| No photo output, so no image can be captured or written | Yes — one video data output, no photo output, no picker, no frame written to disk. |

**CL-5 (observability metadata allow-list).** The design's event catalogue introduces metadata keys
(`regionCount`, `stringCount`, `batchIndex` / `batchCount`, `resolvedCount` / `unresolvedCount`,
`reason`, `keyCount`, `count`, `origin`, `mode`, `disclosureVersion`) that are not all in the shipped
`LogSanitiser.allowedKeys` set (`Services/Observability/` `LogSanitiser.swift`), and the shipped bus
(`ConsoleObservabilityBus`) filters metadata through that set — unknown keys are dropped silently.
Name the additive extension of that allow-list (count-only, closed-vocabulary values) in the
integration list, and add a test that each new key survives sanitisation; otherwise the feature's
counters — and the observability evidence `security-test` is meant to collect — never reach the log.

**CL-6 (sanitiser seam).** C07's detect-only reuse of the shipped marker table, "referenced by name",
is not implementable as written: that table is `private` inside the `InputSanitiser` type
(`Services/Voice/` `InputSanitiser.swift`), and the shipped `sanitise` removes markers (that is the
quarantine-level action for transcripts) rather than reporting them. Specify the seam — a small
additive, single-sourced detect-only accessor on `InputSanitiser` (or a shared table) — so an
implementer does not copy the list and let it drift from the project's configured level. Also state
plainly that the scene-text application is strip-then-send, with a residual match degrading the
region and sending nothing, which is what the design already does and why the acceptance scenario
"the injection policy's configured action is applied before any request is sent" is satisfied.

### Divergences and open decisions

D1 … D5 are genuinely carried: D1 as an explicit four-condition predicate on placement (tier 0 only,
word bound, fit at the minimum point size, toggle off) with the callout-everywhere-else rule and the
toggle as the one-touch fallback; D2 as the structural absence of tier 1; D3 as the persistent
encrypted store with LRU and reserved non-evicting dictionary entries; D4 as the callout-never-covers
constraint plus the toggle plus the degraded state always showing the original; D5 as the declutter
rules and the batched request. OD7 and OD8 are implemented exactly as the owner directed (per-day
governor unmodified with a session latch; name kept, shape generalised), and OD1, OD2, OD3 and OD5
remain recorded with named parameters and resolution points. OD4 and OD6 are absent, not stubbed.
Nothing in the design re-opens a settled decision or edits a hash-locked file.

## Required clarifications (non-blocking)

These are wording/interface gaps to fold in at `plan-tasks` or before implementation. None of them
undermines the design's structure, and none is a reason to fail this gate.

- **CL-1 — Dedupe terminal outcome.** `BatchResult` must say how a caller whose key was claimed by
  an in-flight request receives a terminal outcome (await the in-flight task and return the same
  outcome, or an explicit third category), so no region can remain pending indefinitely. Add the
  matching test.
- **CL-2 — Consent re-check on retry.** State that the single retry re-reads
  `LiveTranslateConsentGate.currentDecision()` and honours cancellation immediately before issuing,
  and add the revoke-between-attempts evidence case for `security-test`.
- **CL-3 — `Origin` to `sourceTier` mapping.** The mapping from the shipped `Origin` values onto
  `TranslationOutcome` cases is implied by the ordering but not stated; it is load-bearing for
  FR-LCT-015's in-place predicate (tier 0 only), so name it explicitly (e.g. `.dictionary` → the
  tier-0 outcome; cloud/local-NMT origins are never tier 0).
- **CL-4 — Error to `TranslationUnavailableReason` mapping.** State the conversion table from
  `GeminiClientError` (and transport errors) onto the unavailable reasons, including which are
  transient and thus eligible for the single retry, so the retry matrix has one owner.
- **CL-5 — Observability metadata allow-list.** Name the additive extension of
  `LogSanitiser.allowedKeys` for the new feature keys, and test that each key survives sanitisation.
- **CL-6 — Sanitiser detect-only seam.** Specify the single-sourced, additive detect-only accessor
  used by `SceneTextSanitiser` (the shipped table is private; the shipped function removes markers
  rather than reporting them).
- **CL-7 — C06 wording and helper regression test.** §C06's description overclaims the shared-cache
  addition as behaviour-preserving "by construction" for the helper; the correct statement is the
  additive-caller resolution above (localizer precedence first, cache consulted only on a localizer
  miss), and a named regression test should exercise the helper's presentation path for a
  dictionary-hit label, a cache-hit label and a miss.
- **CL-8 — Cosmetic sweep.** `SpokenOutput` appears once and is otherwise undefined (use the shipped
  speech interface or define it); the `App/Gemini+Translate` source path should read
  `Services/Gemini/` `GeminiClient+Translate.swift` or wherever it will actually live; the `C23`
  cross-reference does not exist in the inventory; FR-LCT-017's touch entry point (a one-touch
  accessibility action on the overlay) should be named in the interface listing; the `repeatLast`
  command is permitted by FR-LCT-022 but is not traced in §8 — trace it or drop it; the overlay
  mapper math test-coverage note should name the new cases the requirement set calls for; and
  `cloudRequestTimeout` should be marked derived/read-only or removed (see above).

## Accepted risks and non-defects

Recorded so later gates do not re-litigate them:

- **R7 — governor shared with the voice pipeline.** Acceptable as designed. FR-LCT-013 intentionally
  binds per-day semantics with a fail-closed "rest of the session" local latch; a heavy voice day
  disabling translation for the rest of that day is the requirement's own authorised outcome, and the
  design surfaces it as an honest degraded state (FR-LCT-023) rather than an error or a retry loop.
  No design change.
- **R8 — additive cache lookup on the helper's presentation path.** The observable-output delta is
  mandated by FR-LCT-020 scenario 2, and the design's localizer-precedence-first ordering resolves
  the tension with NFR-LCT-012's "extensions, not modifications" constraint. The claim holds; the
  only work is CL-7's wording tightening and the named regression test.
- **R12 — provider block-reason string on the shared log surface.** Confirmed: the shipped
  `GeminiClient.send(_:)` emits the raw provider reason as the event's `error_code` while its
  `LogSafeErrorCode` is the content-free constant. Deferring "whether the shipped value is itself
  content-free" to `security-design-review` is correct — it is shared code whose emission the feature
  must not change (NFR-LCT-012), and bounding or redacting it is that gate's stated focus. The design
  should add a one-line cross-reference to that gate so the referral survives into `plan-tasks`.
- **The deliberate `TranslationResult` change.** Correct and required. The first-pass flat shape with
  a non-optional `sourceTier` cannot be honestly satisfied by a degraded result (there is no tier that
  produced a string that does not exist); making the outcome enum the single source of truth removes
  the possibility of an inconsistent pair and satisfies FR-LCT-008 scenario 3 structurally rather
  than by convention. Compatibility cost is contained because the type is new to this feature.
- **The consent prompt's absence of a timeout.** Sound. An auto-dismiss would turn elapsed time into
  an implicit decision, which is precisely what the consent basis (NFR-LCT-007, FR-LCT-010) forbids.
  The configurable-timeouts principle bans hardcoded constants where a value belongs to policy; here
  the only correct policy is "wait for the person", and the design states that reasoning explicitly.
- **`InputSanitiser` strip-then-send.** Consistent with the project's quarantine level as configured;
  no change to the shared sanitiser's behaviour for transcripts is proposed anywhere.

## Decision

decision: GO

All criteria met. The L2 component design at `specs/design-component.md` is complete, buildable,
internally consistent, faithful to the signed-off requirement set (23 FR / 13 NFR), and stays inside
scope. The five scrutinised items were resolved in the design's favour (R7 acceptable, R8 sound with
a wording tightening, R12's referral correct, the `TranslationResult` change correct and required,
the consent no-timeout exception sound). No blocking finding was identified; the eight clarifications
(CL-1 … CL-8) are non-blocking and should be folded in at `plan-tasks` or during implementation, with
CL-1 and CL-2 the two to fix first because they touch failure termination and the consent-retry path
respectively.

This review is read-only: no artifact was modified, and this report is the only file written.
