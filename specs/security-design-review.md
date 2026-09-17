# Security Design Review — Live Camera Translation (STRIDE)

**Task:** `security-design-review` (contract `review_report`) · **Agent:** `reviewer`

**Workflow:** `live-camera-translation` · branch `worktree-live-camera-translation` · 2026-09-16
**Artifact under review:** `specs/design-component.md` — the L2 component design (1,459 lines, contract `component_design_l2`, GO at `review-l2`).
**Exit condition:** `review.decision == "SECURITY-GO"`.
**Constitution basis:** the project `constitution.md` — Architecture Constraint 1, Open Decisions 12 and 13, Standards → Security ("STRIDE threat model must be produced during security design review"), the release-gate block; the feature constitution `specs/live-camera-translation/constitution.md` — binding rules 1–5 and 10, the Security standard, the Gates table; and the mandated focus list in `.ai-sdd/workflows/live-camera-translation.yaml`.

**Verification method.** Every claim the design makes about shipped behaviour was checked by reading that code rather than accepting the design's summary of it: `Services/Observability/` `LogSanitiser.swift` and the sanitising bus in `App/` `AppCoordinator.swift`; `Services/Voice/` `InputSanitiser.swift`; `Services/Gemini/` `GeminiClient.swift`, `GeminiClient+Vision.swift` and `GeminiCostGovernor.swift`; `Services/Storage/` `StoragePlacement.swift` and `EncryptedFileStorage.swift`; `ios/tools/` `check-release-log-safety.sh` and its Python engine; `App/` `SettingsView.swift`; `Services/Plugins/` `ApplianceHelperPlugin.swift`. The requirement set was read per-file for the security-relevant items (FR-LCT-001, 008–014, 019, 020, 023; NFR-LCT-005 …010, 013).

**Read-only.** No artifact was modified, no workflow state was touched, nothing was committed. This report is the only file written.

## Summary

**The design is approvable for implementation.** It carries a real security architecture — not an intent statement — for the new camera surface and the new cloud egress boundary: image egress is structurally absent rather than policy-forbidden, the cloud request has no action surface, the consent gate has no default-on state and fails closed, and the cache is placed on the encrypted file channel with a bounded, evictable shape. Every STRIDE threat identified below has a designed mitigation, and the strongest of them are structural (unrepresentable states) rather than procedural.

**No blocking finding was identified, and no threat was found without a designed mitigation.** Six security findings (SD-1 … SD-6) and three carried clarifications (CL-2, CL-5, CL-6) are recorded. Three of these are **verified factual gaps between what the design claims and what the shipped code does** (SD-2, CL-5, CL-6) and must be closed — they are specification and tooling work, not architecture work, and none requires an owner decision. They are routed as mandatory amendments (AM-1 … AM-10) at the end of this report.

**What is strong, and verified.**

- **Image egress is not forbidden, it is impossible.** No photo output is configured, no frame is written anywhere, and `GeminiRequest.Content.Part` is the only way to attach media — the design's new builder takes no image parameter at all. The egress guarantee therefore does not rest on a filter or a check that could be removed.
- **The translation request has no action surface.** `GeminiRequest` carries only `contents`, `generationConfig` and `tools`; the design sets no tools (no search grounding) and accepts only requested ids with string values. Instruction-shaped scene text can therefore influence *what a string says*, and nothing else — there is no capability for it to reach.
- **The consent gate is fail-closed by construction.** `notRecorded`, `denied` and `unreadable` all deny; there is no configuration value that reaches tier 2; the record is version-stamped against the disclosure copy that was shown.
- **The indicator cannot drift from reality.** Its only input is the in-flight counter, released in a `defer`, and it is not writable from the settings or overlay layers. That is the correct shape for FR-LCT-011.
- **The cache is genuinely at rest under platform encryption, not just "in a file".** The three new keys are absent from `StoragePlacementPolicy.keychainResidentKeys`, so they land on the encrypted file channel — Data Protection class Complete, backups excluded, atomic whole-value writes, no plaintext intermediate.
- **Degradation is honest by construction.** The outcome enum makes "a tier that did not translate" unnameable, so a false success is not representable rather than merely forbidden.

**What must be fixed.** In descending order of consequence: (SD-2) the build-blocking log-safety gate that the design names as its enforcement point for NFR-LCT-006 **does not detect OCR or translation text** — its rules match the word `transcript` and raw error objects only, so a raw print of a recognised or translated string in the new sources would pass the gate; (CL-2) the single retry can re-issue after a consent withdrawal, because a cancelled request surfaces as a transient-looking error; (SD-1) a failed consent withdrawal currently leaves cloud egress running, which does not meet FR-LCT-012's floor; (CL-5) every count-shaped metadata key the feature introduces — and the two the shipped cap events already use — is silently dropped at the bus, so the consent and cost evidence `security-test` is meant to collect would not exist; (CL-6) the detect-only marker seam C07 depends on is not implementable, because the shipped marker table is `private` and the shipped function removes markers rather than reporting them.

**Findings at a glance.** None blocking; all routed to `plan-tasks` / implementation, with the ones that gate `security-test` marked.

| # | Finding | Security consequence | Severity | Route |
|---|---|---|---|---|
| SD-1 | A failed consent withdrawal (`revoke()` write failure) leaves the record granted, so egress continues; the design calls this "the safe direction" | FR-LCT-012's floor ("no further request is made") is not met on a failure path; a user who believed they had withdrawn consent can still have camera text leave the device | Moderate | design text + implement |
| SD-2 | The release log-safety gate does not recognise recognised or translated text as content (verified: its rules match `transcript` and raw error objects only) | The design's named enforcement point for NFR-LCT-006 does not enforce it; the defect class that previously produced a `SECURITY-NO_GO` on this project (B1) could re-enter through the new sources | Moderate-high | implement + `security-test` |
| SD-3 | The stored LRU field `lastAccessedAt` is written on lookup and therefore records when the text was last on camera | NFR-LCT-008 scenario 2 forbids a stored scene timestamp; a literal test of the acceptance criterion would fail | Low | implement (counter) or owner carve-out |
| SD-4 | The consent proof is procedural (checked in the tier) rather than structural (required by the request builder) | A future caller of the shared translation method would not be compelled to check consent | Low | implement (hardening) |
| SD-5 | With the cloud voice stack active, one view can hold two cloud paths but only the translation indicator | Disclosure completeness — the elder sees one indicator for two egress reasons | Low (informational) | OD-12 / OD-13 joint review |
| SD-6 | "Never concatenated into the instruction region" is a prompt-construction convention, not a wire-level boundary: the shipped request type has one text channel and no separate instruction field | Precision of the injection claim; the residual (a model that follows a directive inside the data block) is contained by the absent tool set and output validation, not by separation | Low (precision) | design text |
| CL-2 | The single retry does not re-read consent, and cancellation is not stated as terminal | A request can be issued after a withdrawal — a genuine consent-gate evasion window | Moderate | implement + `security-test` |
| CL-5 | The feature's metadata keys are absent from `LogSanitiser.allowedKeys`; unknown keys are dropped silently | The auditability evidence NFR-LCT-007 requires would not survive to any sink | Moderate | implement + `security-test` |
| CL-6 | C07's detect-only reuse of the shipped marker table has no seam (the table is `private`) | An implementer may copy the list, letting the scene-text policy drift from the project's configured quarantine level | Low | implement |
| SR-1 | The provider's block-reason token reaches the release log as `error_code` through shipped shared code | Recorded residual, ruled below: content-free by provider contract and shape-bounded at the bus | Low | `security-test` assertion |

## Assets, trust boundaries and egress paths

**Assets.**

| ID | Asset | Why it matters here |
|---|---|---|
| A1 | Live camera frames (in-memory pixel buffers) | Must never leave the device and never be persisted; the feature's defining privacy claim |
| A2 | Recognised scene text (OCR output) | User content and the **only** payload permitted to leave; attacker-influenceable before it is read |
| A3 | Translated text | Rendered, spoken, cached; user content |
| A4 | Persistent translation cache | User content at rest; shared with the appliance helper |
| A5 | Consent record | The feature's compliance basis (FR-LCT-010, NFR-LCT-007) |
| A6 | Provider credential (`gemini.apiKey`) | Keychain-resident, header-borne; the B2/T-050 precedent is binding |
| A7 | Observability / log surface | The only evidence trail for consent, cost and degradation |
| A8 | The daily cloud-call budget | Family-set cap shared with the voice pipeline (settled: OD7) |
| A9 | Cloud-activity indicator state | A user-facing disclosure statement that must be true |
| A10 | Other on-device personal content (health, contacts, profile, calendar, location, identifiers) | Must never be attached to a translation request |

**Trust boundaries.**

| ID | Boundary | Nature |
|---|---|---|
| TB1 | Device ⇄ cloud provider | **New in this feature.** The egress boundary that Open Decision 13 amends Architecture Constraint 1 for. TLS-protected; text-only by construction |
| TB2 | Physical world → camera sensor | Attacker-controlled input: anyone can print a sign, label or menu |
| TB3 | App process ⇄ on-device encrypted storage | Data Protection Complete; the cache and the consent record live here |
| TB4 | App ⇄ log sinks (console, sysdiagnose, telemetry) | Content-free by schema; the build gate is the backstop |
| TB5 | On-device microphone ⇄ in-session command path | Local, deterministic matching; single-utterance capture |
| TB6 | Family / remote configuration ⇄ consent and budget state | The cap is family-editable by design; consent must not be |
| TB7 | Provider response ⇄ app | Untrusted input: ids, values and sizes are all validated before use |

**Every path into the cloud tier (C08), enumerated for the consent analysis.** This is the check the workflow mandates; the design was searched for any other route to a request.

| # | Path | Issues a request? | Consent decision read? |
|---|---|---|---|
| E1 | Initial resolve from a region text-change event | Yes | Yes — `CloudTranslationTier.resolve` step 3, fail closed |
| E2 | The single automatic retry inside `resolve` | Yes | **Not stated — CL-2.** This is the one gap in the set |
| E3 | Session-resume re-attempt after an interruption | Yes | Yes — it re-enters `resolve`, which reads the gate per call |
| E4 | Second observation of a key already in flight (dedupe) | No | n/a — the existing request completes; no new egress |
| E5 | Plugin entry (`handle` / `presentationView`) | No | n/a — no cloud call during entry by design |
| E6 | Background / backgrounded app | No | n/a — `pause()` stops the frame stream, so no OCR means no text change means no request |
| E7 | Prefetch / speculative translation | n/a | **No such path exists.** The cache is populated only by a completed resolution; a dictionary-layer hit touches nothing |
| E8 | Cache hit (tier 0 or persisted) | No | n/a — resolution completes without egress |

Two structural observations follow. First, **egress cannot originate in the background**: the session pauses on the background notification and the frame stream stops, so the text-change gate that drives translation has no input. Second, **there is no prefetch surface at all**, which removes the usual "warmed the cache before consent" class of defect; the design should keep that property explicitly rather than incidentally.

## STRIDE threat model

Coverage: all six categories, against the components and data flows of this design. Each row names the asset, the boundary crossed, the threat, the designed mitigation with the component that enforces it, and the residual. **No row was found without a designed mitigation**, which is what permits a `SECURITY-GO` rather than a `SECURITY-NO_GO`.

### Spoofing

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| S-1 | A2, A3 / TB1 | An endpoint impersonating the provider to harvest scene text or return forged translations | Fixed vendor host over TLS; the credential travels in a header, never a query string (shipped client; Open Decision 12's precedent). Forged output cannot add ids or trigger anything: only requested ids are accepted, only string values, oversized values rejected (C08 `TranslationResponseParser`) | Provider trust is assumed; certificate pinning is absent project-wide and is not this feature's scope |
| S-2 | A5 / TB6, TB3 | A consent grant manufactured by something other than the elder's explicit action — a configuration write, a settings default, or a stale record | Only `LiveTranslateConsentGate.record(granted:)` writes the record, reachable solely from the consent prompt and the revocation control; `notRecorded` / `denied` / `unreadable` all deny; there is no default-on state and no configuration value that reaches tier 2 (C09, FR-LCT-010) | **Assertion to add:** no configuration or remote-config path can write the consent key (AM-10) |
| S-3 | A9 / UI | A false cloud-activity statement — lit while idle, dark while text is leaving the device, or suppressed by a UI mode | The indicator's only input is the tier's in-flight counter, incremented on issue and released in a `defer`; it is not writable from the settings or overlay layers and has no dwell timer (C10, FR-LCT-011) | None identified; the structure is sound |
| S-4 | A3 | A false "translated" claim — a region naming a tier that did not translate | The outcome enum is the single source of truth: `sourceTier` is non-nil only for `.resolved`, and no on-device tier case exists to return (C04, FR-LCT-008) | None; the false state is unrepresentable |

### Tampering

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| T-1 | A4 / TB3 | On-device modification of cached translations | Encrypted file channel, Data Protection Complete, backups excluded, atomic whole-value writes, schema version, key-mismatch detection on read; an unreadable payload is discarded and rebuilt (C05) | No application-level authentication tag over the payload; a device-level attacker is outside this feature's model — worth recording explicitly for `final-sign-off` |
| T-2 | A5 / TB3 | On-device modification of the consent record to manufacture a grant | Same channel protections as T-1; any corrupt or unreadable record denies (C09) | As T-1: integrity rests on platform file protection, not on a tag. Recommend recording this as a written residual (AM-10) |
| T-3 | A2, A6 / TB1 | In-flight modification of the request to attach media or unrelated content | TLS; the body is built from a typed value with fixed fields and no ambient state | None identified |
| T-4 | A3 / TB7 | A crafted or wrong translation rendered as truth, including a "translated" directive | Per-item id validation, string-only values, a size bound proportional to the source (C08); nothing in the feature acts on model output; the original text stays visible as the callout's secondary line and in every degraded state; in-place rendering is restricted to curated tier-0 whole-label matches, which a printed directive cannot occupy (C11 D1) | A plausible-but-wrong translation is inherent to translation; the always-visible original and the one-touch toggle are the mitigation, and both ship |
| T-5 | A3, A4 | Cross-surface poisoning: a cloud-resolved string enters the shared cache and appears in the appliance helper | Sharing is mandated (FR-LCT-020); the localizer's own result takes precedence at the helper's seam; response validation bounds the value's shape; the value is only ever displayed as text (C05, C06) | Low, and already recorded as R8 territory in `review-l2` |
| T-6 | A4 / TB3 | Upkeep logic driven to grow the cache without bound | Hard LRU bound on general entries; dictionary-resident entries are bounded by the curated set, which is a compiled static and not attacker-influenceable; the eviction predicate consults that set rather than a size heuristic (C05) | None identified |

### Repudiation

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| R-1 | A5, A7 / TB4 | A request whose consent state cannot be established after the fact | A timestamped, version-stamped record; a content-free event at every decision point, with `consentRecordUnreadable` kept distinct from `costBudgetExhausted` because the owner actions differ (C09) | **Gap found:** event *types* and *outcomes* survive the bus, but every count-shaped metadata key is dropped (CL-5). The core fact survives; the refinement does not |
| R-2 | A9, A7 | Disputing whether the indicator was shown, or why a region degraded | `cloud_indicator_shown` / `_hidden` and per-reason `translation_degraded` events, all content-free (C10, C15) | The `reason` token is dropped at the bus today (CL-5) — event type and outcome still survive |
| R-3 | A8, A7 | Disputing budget behaviour after a cap | The shipped governor's own events are unchanged, and the tier adds `cost_exhausted_latched`; attempts refused by the governor are never counted as translations (C15) | The governor's `count` / `cap` metadata is already dropped at the bus in the shipped build. The family-visible surface is the in-app mirror bound in `App/` `SettingsView.swift` (`callsToday` / `softDailyCap`), not the console — the design should say so rather than implying the log carries that signal |

### Information disclosure

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| I-1 | A1 / TB1, TB2 | A frame, photo or derived image leaving the device | Not configured and not reachable: no photo output is constructed, no frame is written to disk or a temporary file, and the one request builder exposes no media parameter (C01, C08) | None identified. This is the feature's strongest guarantee because it is structural |
| I-2 | A10 / TB1 | Health, contacts, profile, calendar, location, medication or identifier content swept into a request | `TranslationPrompt.build` is pure over `(items, targetLanguage)`; the request type carries text parts and an optional tool list only; the cache stores no image, box, scene timestamp, identifier or location (C05, C07, C08) | **Assertion to add:** the built body contains only the items and language parameters (AM-10) |
| I-3 | A2, A3, A7 / TB4 | Recognised or translated text reaching a log sink in any build | Content-free event schema; `errorCode` is a stable code constant or a status number; the build-blocking gate is wired ahead of every test scope | **Two verified gaps:** the gate does not recognise OCR or translation text as content (SD-2), and the feature's metadata keys do not survive the bus (CL-5) |
| I-4 | A4 / TB3 | Cache readable at rest by anything that can read files | Encrypted file channel, Data Protection Complete, backups excluded, whole-payload writes with no plaintext intermediate (C05; verified against the storage implementation) | None identified |
| I-5 | A4 | A stored ordering field that co-varies with when the text was on camera | The design flags `lastAccessedAt` explicitly as cache-internal bookkeeping rather than scene metadata | **SD-3:** because it is written on lookup, it is scene-derived in effect, and NFR-LCT-008 scenario 2 forbids a stored scene timestamp. Prefer a monotone ordering counter |
| I-6 | A2 / TB1 | Provider-side retention of the text that was sent | Inherent to the exception, and mitigated by design rather than denied: explicit consent at first cloud need, plain-language disclosure, a visible indicator while active, revocation that degrades rather than blocks, per-string and per-batch bounds, and the day cap (C07, C08, C09, C15; Open Decision 13) | The consent/disclosure copy review (OD3) remains the open release gate, as recorded |
| I-7 | A2, A7 / TB4 | The provider's block classification reaching the release log | Shape-bounded at the bus: charset gate, unbroken-run rejection, length cap (`LogSanitiser.boundErrorCode`) | **SR-1**, ruled in its own section below |
| I-8 | A8 | Translation activity inferable from the shared daily counter | Accepted by design: the family-visible budget is a deliberate product surface, and the cap is family-editable (settled OD7) | Accepted, not a finding |
| I-9 | A10 / TB5 | Audio from the in-session microphone, or its transcript, leaving the device | Command capture is single-utterance and matched locally and deterministically — no model, no cloud, no budget (C12) | **SD-5:** with the cloud voice engine active (the shipped default), an in-session utterance is governed by Open Decision 12's exception, whose consent and disclosure obligations are owned by that decision's review, while FR-LCT-011's indicator is scoped to the translation tier. Raise at the joint OD-12 / OD-13 review |

### Denial of service

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| D-1 | A8, provider quota / TB1, TB2 | A dense, hostile or simply busy scene driving unbounded requests or spend | Region cap and decluttering before emission; per-string bound; per-batch string and character bounds with sequential splitting; in-flight dedupe; at most one retry; the day cap plus the session latch (C03, C07, C08, C15) | None identified at design level |
| D-2 | A8 | Budget exhaustion of the shared cap by attacker-visible strings, degrading the voice pipeline | The cap is the bound (settled OD7); the session latch stops further attempts; the failure surfaces as an honest degraded state (C15) | Accepted as R7 in `review-l2`; not re-litigated |
| D-3 | Device resources | Thermal or battery exhaustion from sustained OCR | Cadence throttle, frame drop under backpressure rather than queueing, a thermal multiplier, and an honest degraded state instead of a silent stall (C01, C02) | Nominal values pending the OD1 device spike |
| D-4 | A3 | A region stuck in a non-terminal state forever if a deduped key has no stated terminal outcome | Designed intent: an already-claimed key resolves when the existing request completes (C08 step 5) | **CL-1 (carried):** the interface does not state what the second caller receives. Must be closed, or a region can sit pending indefinitely — an unbounded pending state and a de-facto silent drop |
| D-5 | Feature availability | A printed sign that trips the provider's policy disabling translation for the whole scene | Quarantine and policy refusal degrade only the affected region; other regions still translate; no retry storm (C07, C08) | Nuisance, not a security loss — this is the correct failure shape |
| D-6 | A5 | Withdrawal of consent that does not take effect because the failure looks transient | Required: withdrawal cancels in-flight work, and the tier must re-read the gate and treat a cancellation-shaped error as terminal (C09 + C08) | **CL-2** and **SD-1**; the sharpest of the carried items |
| D-7 | Feature availability | A storage or cache fault blocking the feature | Cache failures are non-fatal and self-healing; storage unavailability makes the gate deny, and the feature continues on tier 0 and cached entries (C05, C09) | None identified |

### Elevation of privilege

| ID | Asset / boundary | Threat | Designed mitigation (enforcer) | Residual |
|---|---|---|---|---|
| E-1 | The cloud capability, other app capabilities / TB1, TB2 | Instruction-shaped scene text making the model take an action, invoke a tool, or reach another capability of the app | The request carries no tools at all; scene text is carried as delimited structured data with per-item ids rather than interpolated into the instruction sentence; residual markers quarantine the region so nothing is sent; only requested ids with string values are accepted; nothing in the feature acts on model output (C07, C08, NFR-LCT-009) | The request has no action surface, so the ceiling of a successful injection is a misleading string on screen — see E-2 |
| E-2 | A3, the elder's own decision / UI | A translated directive the user then acts on | Callouts always show the original as secondary text; degraded states always show the original; in-place replacement is restricted to curated tier-0 whole-label matches, which an attacker-printed directive cannot satisfy; the "always show original" toggle is one touch away (C11 D1) | An attacker controlling both the print and the model's output could mislead a reader who ignores the original; bounded by the original always being visible |
| E-3 | A5, the cloud capability / TB6 | A request issued after consent was withdrawn — most plausibly by the retry (E2) | The gate is read per request and fails closed; withdrawal deletes the record, flips the mirror under the lock, and cancels in-flight work | **CL-2:** a cancelled transport surfaces as a transient-looking error, so the retry can re-issue after the withdrawal. Must be closed (AM-1) |
| E-4 | A5 | A future caller of the shared translation method that does not check consent | Today there is exactly one caller (`CloudTranslationTier`), and the design keeps the check in the tier rather than in the shared client — the correct layering, since the client is shared with the voice and vision paths | **SD-4:** the discipline is procedural. Prefer requiring a consent proof as a parameter of the request method so the check cannot be omitted |
| E-5 | The configured injection policy | Policy drift if the detect-only marker list is copied into the new sanitiser rather than shared | Designed: detect-only reuse of the shipped table, referenced by name | **CL-6:** the table is `private` and the shipped function removes markers rather than reporting them, so the seam does not exist. Must be closed (AM-3) |
| E-6 | A5 | Egress continuing after a withdrawal the user believed had taken effect | Withdrawal is reachable from the session view and Settings; a failed write is reported to the caller rather than swallowed | **SD-1:** the design's stated semantics leave the record granted and continue egress. Must be closed (AM-4) |

## Focus-area verdicts

The seven areas the workflow mandates, each answered against the design and the shipped code.

1. **Prompt injection via scene text — holds, with CL-6 and SD-6.** Scene text is sanitised and bounded before it can enter a payload; a residual marker match quarantines the region and sends nothing; the payload is delimited structured data with per-item ids; the request carries no tools; only requested ids with string values are accepted, and oversized values are rejected. The one correction to the design's own wording is SD-6: the shipped request type has a single text channel and no separate instruction field, so "not concatenated into the instruction region" is a prompt-construction property, not a wire-level separation. The property that actually bounds the damage is that the request has no action surface and nothing acts on model output — which is sound and is what the design should lead with.
2. **Consent-gate evasion — one gap, CL-2.** Of the eight entry paths enumerated above, seven are either consent-checked or cannot issue a request. The retry (E2) is the exception: a cancellation-shaped transport error looks transient, so after a withdrawal the tier can issue a second attempt. This is the one genuine evasion window, and it is narrow but real. Everything else is sound: the gate denies on every non-granted state, there is no default-on path, no prefetch exists, and background egress is impossible because the frame stream stops.
3. **Egress leakage — holds.** No photo output exists, no frame is written anywhere, the one translation request builder has no media parameter, and the prompt builder is pure over the item list and the target language. Health, contacts, profile and location content have no path into the request because nothing outside the item list is read.
4. **Persistent cache as user content at rest — holds, with SD-3.** Encryption, placement on the protected file channel with backups excluded, whole-value atomic writes, no plaintext intermediate, bounded LRU, the dictionary-resident non-evicting predicate decided by looking the key up in the curated set rather than by size, and deletion by key. The one defect is the stored ordering field (SD-3), which is scene-derived in effect because it is written on lookup.
5. **Cloud indicator integrity — holds.** One input, released in a `defer`, not writable from the settings or overlay layers, no dwell timer, and the dictionary-only path cannot touch it. It cannot drift from the egress state.
6. **Log surface — two verified gaps, SD-2 and CL-5.** The schema is content-free by construction and the design's rule against printing content is absolute; but the build-blocking gate does not recognise OCR or translation text as content, and the feature's counters and reasons are dropped at the bus. Both are fixable and neither is architectural. The provider-reason question referred to this review is ruled separately below.
7. **Fail-closed behaviour — holds, with SD-1.** The cost cap refuses before any network work and the session latch makes every later attempt a no-op with no alternative request shape; offline and provider failures terminate as degraded rather than as success; a degraded region is never removed from the overlay. The cap's independence is settled (OD7). The one failure path that does not currently deny is the withdrawal write (SD-1).

## Referred question: the provider block reason on the log surface

**Question referred.** The PE mapped the translation path to the content-free constant `cloud_policy_blocked` but deferred whether the shipped `GeminiClientError.blockedByProvider(reason:)` — whose raw provider value the existing client emits as the event's `error_code` — is itself content-free, or whether it is a log-safety defect that must be fixed before implementation.

**Ruling: not a log-safety defect, and not a blocker. It is a bounded residual (SR-1), and the feature must not add an emission site for it.**

**What I verified.** `Services/Gemini/` `GeminiClient.swift`, in `send(_:)`: on a block, the client emits `gemini_blocked` with `errorCode` set to the decoded `promptFeedback.blockReason` and then throws `blockedByProvider(reason:)`; the error's own `logSafeErrorCode` is the compile-time constant `blocked_by_provider`, and the code comment states the reason is left out deliberately because it is upstream text and the dedicated event carries it as a provider enum. The field is decoded as an unvalidated `String?` in `GeminiResponse.PromptFeedback`. At the bus, `LogSanitiser.boundErrorCode` scrubs PII shapes, then rejects anything that is not identifier-shaped (replacing it, not truncating it), then rejects a 32-or-more-character unbroken alphanumeric run, then caps the length at 64. `ConsoleObservabilityBus.emit` routes every event through that sanitiser, so the bound cannot be skipped by an emitter.

**Why the value is safe.** The provider's block reason is a fixed-vocabulary classification token, not free text and not the upstream response body — the body was already excluded by T-050/B2, and the code says so at the throw site. A classification token carries no scene text, no image, no credential and no personal content; the worst case is that it discloses which category of content tripped a safety filter, which is a weak property of the *category* and not of the content. Defence in depth applies on top: any prose-shaped value fails the charset gate and is replaced rather than logged, an unbroken key-shaped run is rejected, and the length is capped. A hostile or changed provider returning a short single-token value would be logged verbatim, but such a value is still bounded in length, arrives once per blocked call, and contains nothing the provider could have derived from the scene beyond its own classification.

**Why the feature is not exposed further.** The translation path maps the throw to `cloudPolicyBlocked` → the constant `cloud_policy_blocked`, so this feature adds **no** second emission and no new content-bearing code. The single emission site is the pre-existing shared transport that the `security-test` re-run at `57abb2e` reviewed and passed. Editing it would change shared behaviour that NFR-LCT-012 forbids this feature from weakening, and it is not this feature's change to make.

**What is required of this feature (AM-9, AM-10).** State in the design that this feature adds no emission of an upstream-derived `error_code`; cross-reference the R12 item from the two places that assert the log-safety invariant, so the sentence "`errorCode` is always a constant or a status number" is not read as unlimited on the shared path; and have `security-test` assert that the live-translate path introduces zero `error_code` values derived from upstream text. A worthwhile follow-up outside this feature's scope is to validate the block reason against the known token set at the decode site and fall back to the constant when it does not match — that converts a shape bound into a closed-set bound.

## Carried clarifications: CL-2, CL-5, CL-6

Each of the three security-relevant clarifications from `review-l2` was re-verified against the shipped code and is confirmed.

**CL-2 — consent on the retry path (confirmed; the sharpest item).** The design asserts that no new request may be issued after a withdrawal returns, and that every cloud path goes through `resolve`, where the gate is read. But the retry is a *second* attempt inside the same `resolve` call, after the batch-level read, and the design does not say that the gate is re-read before it or that cancellation is terminal. The concrete failure is worse than an omission: withdrawal cancels the in-flight task, a cancelled transport call surfaces as an error indistinguishable from a transient transport failure, and the design's own retry rule retries transient failures once. So the withdrawal path can produce the very request it is meant to prevent. **Required:** treat a cancellation-shaped error as terminal and never retryable, re-read `currentDecision()` immediately before the second attempt and deny on anything but `granted`, and give `security-test` the evidence case: withdraw consent between the first attempt and the retry, then assert zero further requests.

**CL-5 — observability metadata allow-list (confirmed, and slightly broader than reported).** I read `LogSanitiser.allowedKeys` and `ConsoleObservabilityBus.emit`: unknown metadata keys are dropped, and none of the feature's keys (`regionCount`, `stringCount`, `batchIndex`, `batchCount`, `resolvedCount`, `unresolvedCount`, `keyCount`, `count`, `origin`, `mode`, `reason`, `disclosureVersion`) is present. Event *types* and *outcomes* do survive, so the core facts reach the sink — but every count, reason and origin token is lost, which is exactly the evidence NFR-LCT-007 asks for and the classification NFR-LCT-006 permits. Two shipped keys on the cap path (`count`, `cap`) are also absent, so the governor's console events are already count-free; the family-visible surface is the in-app mirror bound in `App/` `SettingsView.swift`, and the design should say so. **Required:** an additive allow-list extension limited to count-shaped and closed-vocabulary keys, a test per new key that it survives sanitisation, and a decision on whether the cap events' keys are extended too.

**CL-6 — the detect-only marker seam (confirmed).** I read `Services/Voice/` `InputSanitiser.swift`: the marker list is `private static let`, and `sanitise(_:level:)` *removes* markers rather than reporting them. C07's "detect-only use of the shipped marker table, referenced by name" therefore has no implementable seam, and the risk is concrete: an implementer copies the list, and the scene-text policy drifts away from the project's configured quarantine level — the exact property the project's Security standard exists to hold. **Required:** a single-sourced, additive detect-only accessor on the shared sanitiser (or a shared table consumed by both call sites), a test pinning that both call sites agree, and an explicit prohibition on copying the list. The design's strip-then-send application is correct and should stay: a residual match after sanitisation degrades the region and sends nothing.

## Findings

**SD-1 — A failed consent withdrawal leaves cloud egress enabled.** The design states that withdrawal "deletes the record, flips the in-memory mirror under the lock, and cancels in-flight tier-2 tasks", and, in the failure matrix, that a failed withdrawal "leaves the record intact, which is the safe direction: the gate is still gated". Those two statements are inconsistent, and the second is wrong: with the record still granted, the gate is open, not gated, and FR-LCT-012's floor ("no further request is made") is not met. The failure is at least visible and marked retryable rather than silent, which is why this is not a blocking finding — but for a gate that is the feature's compliance basis, the correct semantics is to stop egress first and reconcile storage second. **Required:** on a withdrawal write failure, force the in-memory state to deny so the floor holds immediately, verify the delete by reading back, surface the failure to the user as a failure (never as success), and ensure a relaunch cannot silently re-grant from a record the user believes they withdrew. Note that the fail-closed read already covers the fully-unavailable-storage case; it is the partial failure that needs the rule.

**SD-2 — The release log-safety gate does not cover the feature's content.** The design names `check-release-log-safety.sh` as the enforcement point for the invariant "no recognised or translated text on the log surface", and asserts that it "scans" the new sources and "fails the build". The gate does walk the whole source tree, so the new files are visited — but its detection rules match the word `transcript` (bare or as a camelCase suffix), values tainted from a transcript-bearing expression, `String(describing:)` / `String(reflecting:)` / `.localizedDescription` / `.debugDescription`, and error objects passed to or interpolated into a print. Nothing in those rules matches a recognised string or a translation: `print(region.text)` or `print(translation)` in the new sources would pass the gate. The gate's own header says its content rule is transcript content and that other subsystems "are tracked separately and deliberately out of this gate's scope" — so the coverage the design claims is not what the tool does. This matters more than a normal documentation error because it is the same defect class (B1) that produced a `SECURITY-NO_GO` on this project previously. **Required:** extend the gate with a rule family for this feature's content class — a content-word set matching the feature's recognised and translated string accessors, and/or an explicit content-print prohibition scoped to the new source directories — and state the extension in the design's invariant table in place of the current claim. The design's existing falsification step (a manual grep of the new sources) should be kept as the second line, not the first.

**SD-3 — The stored LRU ordering field is scene-derived.** `lastAccessedAt` is written when an entry is touched, and touching happens on lookup — which happens when the text appears on camera. It therefore records, coarsely, when that text was last in view. NFR-LCT-008 scenario 2 requires that a stored entry contain "no image, bounding box, scene timestamp or location", and a literal test of that criterion would fail. The design anticipates the objection and calls the field cache-internal bookkeeping rather than scene metadata; the distinction does not hold as written. **Required (preferred):** order entries with a monotone counter incremented per touch, which preserves LRU semantics exactly and stores nothing scene-derived. **Alternative:** keep the timestamp and obtain an owner carve-out in the requirement text — an owner action, since the lock is read-only — and record the carve-out where the entry shape is specified.

**SD-4 — The consent check is procedural, not structural.** The design's own doctrine is that deferred or dangerous states should be unrepresentable rather than forbidden — no on-device tier case, no direction flag, no photo output, no auto-speak observer. The consent proof is the one security-critical property that is enforced by a convention (the tier happens to check it) rather than by the type system. The layering is correct — the check must not live in the shared client — but a future caller of the new translation method would not be compelled to check anything. **Required:** state that the method has exactly one caller and that the single-caller property is a reviewed invariant. **Strongly recommended:** make the consent proof a required parameter of the request builder, produced only by the gate, so the check cannot be omitted rather than merely being remembered.

**SD-5 — Two cloud paths, one indicator (informational).** In-session command capture reuses the plugin microphone precedent. If the active speech stack is the cloud voice engine — the shipped default — an in-session utterance travels under Open Decision 12's exception, whose consent and disclosure obligations belong to that decision's review, while FR-LCT-011's indicator is scoped to the translation tier. The elder would then be in a view with two cloud paths and one indicator. The design is compliant with its own requirement; the gap is at the project level. **Required:** none for this feature. Record it as an input to the joint Open Decision 12 / 13 review so the two disclosure surfaces are designed together.

**SD-6 — The prompt-boundary claim is a convention, not a wire property (precision).** The design says the payload is "carried as data inside a delimited block" and that "nothing is concatenated into the instruction region of the request". I verified the shipped request type: it carries `contents`, `generationConfig` and `tools`, with no separate instruction field, and the design's prompt builder returns a single string. There is therefore no wire-level separation between instruction and data — the separation is a prompt-construction property. That is normal and acceptable, but the design should say it plainly, because the sentence as written invites a reviewer to believe a boundary exists that the API does not provide. **Required:** reword to state that scene text is placed in a delimited data block within the same text channel and is never interpolated into the instruction sentence, and that the load-bearing controls are the absent tool set, the id-and-type-validated response, and the fact that nothing in the feature acts on model output.

## Verification of the design's security invariants

The design states ten invariants with their enforcement points and how each is falsified. I checked each by inspection against the shipped code and the design's own interfaces.

| Invariant | Verdict |
|---|---|
| No tier-2 request without a recorded consent decision | **Holds with CL-2.** Seven of eight entry paths are checked or cannot issue a request; the retry is the exception and must re-read the gate (AM-1) |
| Text-only egress: recognised strings and language parameters only | **Holds.** No media parameter exists on the builder, no photo output exists on the session, and the prompt builder reads nothing outside its item list |
| No recognised or translated text on the log surface | **Holds by schema, not by gate.** The schema is content-free by construction; the named gate does not enforce it (SD-2) and the counters are dropped (CL-5) |
| Cache encrypted at rest with no plaintext file | **Holds.** Verified against the storage placement policy and the encrypted file store |
| Cost governor fails closed and never retries around the cap | **Holds.** The refusal is pre-network in shipped code, the latch is monotone within the session, and no alternative request shape exists |
| Cloud-activity indicator cannot disagree with reality or be suppressed | **Holds.** Single input, released in a `defer`, not writable from the settings or overlay layers, no dwell timer |
| Truthful tier attribution; no success without a translation | **Holds structurally.** The outcome enum makes the inconsistent state unrepresentable |
| Scene text cannot function as a directive | **Holds with CL-6 and SD-6.** The controls are the absent tool set, delimited presentation, quarantine, response validation, and the absence of any action surface |
| Withdrawal is immediate and total | **Holds on the success path; fails on the write-failure path (SD-1).** The cancellation path also needs CL-2 |
| No photo output means no image can be captured or written | **Holds.** One video data output, no photo output, no picker, no frame written to disk |

## Review checklist

- **Explicit error return types on every interface method.** Passes. `LiveTranslateError` with typed reason enums, `CacheError`, `ConsentError`, `TranslationResponseParser.Defect`, `Result`-returning camera and detector entry points, and the plugin protocol's own `PluginResult`. The single `throws`-based exception is named and justified, and the conversion to the feature taxonomy happens at the tier boundary. No `any`, no `unknown`, no untyped error field.
- **Documented failure mode and recovery path for every asynchronous or external call.** Passes. The 24-row failure matrix states, per operation, what fails, whether it retries, and which component owns the policy; the two invariants it pins (no unbounded request count, every failure terminates in a rendered state) are the right ones. CL-1 is the one interface gap and is carried.
- **Timeouts and retry limits configurable, not hardcoded.** Passes, with one named exception. Every operational value is owned by `LiveTranslateConfig`; the base transport timeout is single-sourced from the shipped client config rather than duplicated. The consent prompt's deliberate absence of a timeout is the correct reading of FR-LCT-010 — an auto-dismiss would manufacture the consent the requirement forbids.
- **Every element traces to an FR or NFR; no unspecified features.** Passes. All 23 FR and 13 NFR map to a named component, and the one extra (`repeatLast`) is explicitly permitted by FR-LCT-022. The deferred capabilities are absent rather than stubbed, which is the harder and correct choice.
- **The design says what the operator sees when the feature runs and when it fails.** Passes. Per-region states are specified, degradation always shows the original text, a degraded region is never removed from the overlay, and the failure modes are visible rather than silent.

## Required amendments

Mandatory. `security-test` must not return `SECURITY-GO` while any of AM-1 … AM-9 is open, and AM-5 also gates `final-sign-off`.

| # | Amendment | Source | Blocks |
|---|---|---|---|
| AM-1 | Treat a cancellation-shaped transport error as terminal and never retryable; re-read the consent gate immediately before the second attempt and deny on anything but granted; add the withdrawal-between-attempts evidence case | CL-2 / E-3 / D-6 | implementation; `security-test` |
| AM-2 | Extend `LogSanitiser.allowedKeys` additively with the feature's count-shaped and closed-vocabulary keys, and decide the same for the cap events' keys; add a per-key test that it survives sanitisation | CL-5 / R-1 / R-3 | implementation; `security-test` |
| AM-3 | Add a single-sourced detect-only marker accessor shared with the transcript sanitiser; pin both call sites with a test; prohibit copying the list | CL-6 / E-5 | implementation |
| AM-4 | On a withdrawal write failure, deny in memory, verify the delete by reading back, surface a failure as a failure, and ensure a relaunch cannot silently re-grant | SD-1 / E-6 | implementation |
| AM-5 | Extend the release log-safety gate with a rule family for recognised and translated text (or an explicit content-print prohibition over the new sources), and correct the invariant table to describe what the gate actually enforces | SD-2 / I-3 | implementation; `security-test`; `final-sign-off` |
| AM-6 | Replace the stored wall-clock ordering field with a monotone counter, or obtain an owner carve-out in the requirement text and record it | SD-3 / I-5 | implementation (counter) or owner |
| AM-7 | State the single-caller invariant for the new translation method; preferably require a consent proof as a parameter of the request builder | SD-4 / E-4 | implementation |
| AM-8 | State what a caller receives for a key already claimed by an in-flight request, so no region can remain pending indefinitely; add the matching test | CL-1 (carried) / D-4 | implementation |
| AM-9 | Reword the prompt-boundary claim to describe the single text channel and to name the absent tool set, the validated response and the absence of an action surface as the load-bearing controls; record the provider-reason residual here | SD-6, SR-1 | implementation |
| AM-10 | `security-test` assertions, in addition to the design's own: zero image or media parts on every path including the retry; the built body contains only items and language parameters; the consent key cannot be written by any configuration path; cache-at-rest inspection of the app container; indicator not suppressible while a request is in flight; withdrawal mid-scene yields zero further requests including on the retry; the count of results claiming a tier without a translation is zero; no `error_code` derived from upstream text | this review | `security-test` |

## Accepted risks and non-defects

Recorded so later gates do not re-open them. Each was already settled or accepted before this review, and nothing here changes that.

- **OD7 — the shipped per-day governor is the bound**, with its family-editable cap. Implemented as directed; the session latch is the correct reading of FR-LCT-013's "for the rest of the session". Not re-litigated.
- **OD8 — the name `LabelTranslationCache` is kept** while the shape is generalised to persistent, encrypted and dictionary-seeded. Settled.
- **R7 — the governor is shared with the voice pipeline.** Accepted: a heavy voice day can exhaust translation for the rest of that day, and the honest degraded state is the requirement's own authorised outcome.
- **R8 — the helper presentation delta.** Mandated by FR-LCT-020 scenario 2, resolved by the localizer-precedence rule. Accepted by the prior review.
- **The `TranslationResult` outcome-enum change.** Correct and required by FR-LCT-008; accepted by the prior review.
- **The consent prompt has no timeout.** Correct: any value would manufacture or fabricate a decision. A paragraph-level exception to the configurable-timeout principle, correctly stated and correctly scoped.
- **D1 (smart-mix in-place replacement) and D2 (no on-device translation tier).** Owner-approved; the in-place rule is a four-condition predicate, and the absent tier has no enum case to return.
- **OD4 and OD6 are absent, not stubbed.** Verified: no reverse-direction flag exists and no on-device translation path exists to return.
- **Structural strengths that should not be traded away in implementation:** no photo output, no media parameter on the request builder, no tools on the request, and the outcome enum as the single source of truth.

## Limitations

- Device behaviour (camera permission flows, thermal response, the OCR cadence, the achievable in-place legibility at the minimum point size, and real provider block behaviour) was not measured here; those are the recorded OD1 / OD2 / OD5 device items.
- The provider's block-reason vocabulary was assessed from the provider's documented interface and the shipped client's own comment that the value is a provider enum. I could not exercise a live block, which is why SR-1 is stated as a bounded residual with a defence-in-depth bound rather than as a proof.
- The in-flight cancellation behaviour of the shipped transport (whether a cancelled call is distinguishable from a timeout) was not exercised. CL-2's requirement is written to hold regardless of how that resolves, by requiring an explicit cancellation check rather than relying on error classification alone.
- Consent-record integrity beyond platform file protection (there is no application-level authentication tag) is recorded as a residual rather than tested.
- Two shared files are worth flagging for the implementer's attention because they must be extended additively only: the sanitising observability layer (AM-2) and the transcript sanitiser (AM-3).

## Decision

decision: SECURITY-GO

**SECURITY-GO.** The L2 component design for live camera translation is approved for implementation. A STRIDE threat model covering all six categories against the actual components, assets and trust boundaries is set out above; every threat has a designed mitigation, the highest-value ones are structural rather than procedural, and no threat was found without one. The design stays inside its scope, holds the recorded exception's boundaries (recognised text only, never images, never unrelated personal content), and its consent, cost, cache, indicator and degradation properties hold under inspection.

This is an approval with mandatory amendments, not an unconditional sign-off. Six findings and three carried clarifications are recorded; none is architectural and none requires an owner decision, but AM-1 through AM-10 must be closed before the corresponding gate, with AM-1, AM-2 and AM-5 required before `security-test` can honestly return `SECURITY-GO`. The two that most need attention are the withdrawal-then-retry window (CL-2 with SD-1) — where a withdrawal intended to stop egress can produce one more request, because a cancelled call looks transient — and the log-safety gate's coverage (SD-2), where the design names an enforcement point that does not, as shipped, recognise this feature's content.

The referred question on the provider block reason is ruled in the feature's favour: the shipped value is a fixed-vocabulary provider classification token, doubly bounded at the observability bus, and this feature adds no new emission of it. It is recorded as residual SR-1 with an assertion for `security-test` and a recommended out-of-scope hardening.

No artifact was modified, no workflow state was written, and nothing was committed. This report is the only file written by this review.

*End of security design review.*
