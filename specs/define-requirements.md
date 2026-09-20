# Requirements — Live Camera Translation

**Project:** Elderly AI Assistant · **Feature:** `live-camera-translation` (v1) ·
**Branch:** `worktree-live-camera-translation`
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-09-16 · **Status:** awaiting owner HIL sign-off — the task carries a HIL gate, and
the locked snapshot in `define-requirements.lock.yaml` is presented for that sign-off.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-component`, `review-l2`, `security-design-review`, `plan-tasks`) consume.

**ID convention.** Requirement IDs are namespaced `FR-LCT-NNN` / `NFR-LCT-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention the
dementia supplement uses (`FR-D01`…). One file per requirement; every requirement carries at
least one Gherkin scenario, and every security-relevant requirement carries a failure scenario.

## Summary

- **Functional requirements: 23** (`FR-LCT-001` … `FR-LCT-023`)
- **Non-functional requirements: 13** (`NFR-LCT-001` … `NFR-LCT-013`)
- **Areas covered:** Camera Capture, Text Detection, Region Stabilisation, Translation,
  Privacy & Consent, Cost Governance, Overlay, Caching, Voice Output, Plugin & Session,
  Error Handling. NFR categories: Performance, Accessibility, Localisation, Privacy, Security,
  Reliability, Compliance.
- **v1 scope:** English source → Nepali target; live `AVCaptureSession` preview with no photo
  output configured; on-device OCR (Vision, automatic language detection); translation via tier 0
  curated dictionary → tier 1 on-device brain (the installed Nepali language model, no egress) →
  tier 2 text-only cloud call (consent-gated); smart-mix overlay
  (in-place replacement for short dictionary-known labels, anchored callouts otherwise);
  tap-to-hear and "read this to me" via the existing Piper voices; persistent translation cache;
  ships as a new voice-invokable plugin `LiveTranslatePlugin` sibling to the appliance helper,
  sharing its label dictionary and translation cache; must work on dense multi-region scenes
  (a menu page).
- **Primary source of truth:** `docs/superpowers/specs/2026-09-16-live-camera-translation-design.md`
  (first-pass component design, owner-approved 2026-09-16, awaiting spec review) — its §10 Open
  Decisions and §11 divergences (D1, D2) are carried forward below.
- **Governing rules:** `constitution.md` (project — Architecture Constraint 1, Open Decision 13
  recorded 2026-09-16 for the cloud text-translation exception with its consent amendment),
  `specs/live-camera-translation/constitution.md` (feature constitution), and the inherited
  base design + addendum §13.

## Contents

- [`define-requirements/index.md`](define-requirements/index.md) — top-level feature index
- [`define-requirements/FR/index.md`](define-requirements/FR/index.md) — functional requirement list
  (23 files: `define-requirements/FR/FR-LCT-NNN-*.md`)
- [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md) — non-functional requirement list
  (13 files: `define-requirements/NFR/NFR-LCT-NNN-*.md`)
- [`define-requirements.lock.yaml`](define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (contract `requirements_lock`)
- Sections below: [Functional requirements](#functional-requirements) ·
  [Non-functional requirements](#non-functional-requirements) ·
  [Open decisions](#open-decisions) · [Out of scope](#out-of-scope) ·
  [Divergences carried forward](#divergences-carried-forward)

### Requirement index

| ID | Title | Area / Category | Priority | File |
|----|-------|-----------------|----------|------|
| [FR-LCT-001](define-requirements/FR/FR-LCT-001-live-camera-preview.md) | Live camera preview without photo capture | Camera Capture | MUST | `FR-LCT-001-live-camera-preview.md` |
| [FR-LCT-002](define-requirements/FR/FR-LCT-002-camera-permission-and-disclosure.md) | Camera permission and purpose disclosure | Camera Capture / Compliance | MUST | `FR-LCT-002-camera-permission-and-disclosure.md` |
| [FR-LCT-003](define-requirements/FR/FR-LCT-003-on-device-ocr-language-detection.md) | On-device OCR with automatic language detection | Text Detection | MUST | `FR-LCT-003-on-device-ocr-language-detection.md` |
| [FR-LCT-004](define-requirements/FR/FR-LCT-004-region-tracking-between-ocr-passes.md) | Region tracking between OCR passes | Text Detection | SHOULD | `FR-LCT-004-region-tracking-between-ocr-passes.md` |
| [FR-LCT-005](define-requirements/FR/FR-LCT-005-region-stabilisation-hysteresis.md) | Stable text regions with hysteresis and change-only events | Region Stabilisation | MUST | `FR-LCT-005-region-stabilisation-hysteresis.md` |
| [FR-LCT-006](define-requirements/FR/FR-LCT-006-decluttering-dense-scenes.md) | Decluttering for dense multi-region scenes | Region Stabilisation | MUST | `FR-LCT-006-decluttering-dense-scenes.md` |
| [FR-LCT-007](define-requirements/FR/FR-LCT-007-dictionary-tier-0.md) | Tier 0 curated dictionary translation | Translation | MUST | `FR-LCT-007-dictionary-tier-0.md` |
| [FR-LCT-008](define-requirements/FR/FR-LCT-008-truthful-tier-attribution.md) | Truthful tier attribution and no success without translation | Translation | MUST | `FR-LCT-008-truthful-tier-attribution.md` |
| [FR-LCT-009](define-requirements/FR/FR-LCT-009-cloud-tier-text-only-translation.md) | Tier 2 text-only cloud translation | Translation | MUST | `FR-LCT-009-cloud-tier-text-only-translation.md` |
| [FR-LCT-010](define-requirements/FR/FR-LCT-010-consent-gate.md) | Consent gate before any cloud translation | Privacy & Consent | MUST | `FR-LCT-010-consent-gate.md` |
| [FR-LCT-011](define-requirements/FR/FR-LCT-011-cloud-activity-indicator.md) | Visible cloud-activity indicator | Privacy & Consent | MUST | `FR-LCT-011-cloud-activity-indicator.md` |
| [FR-LCT-012](define-requirements/FR/FR-LCT-012-consent-revocation-offline-mode.md) | Consent revocation degrades to dictionary-only offline mode | Privacy & Consent | MUST | `FR-LCT-012-consent-revocation-offline-mode.md` |
| [FR-LCT-013](define-requirements/FR/FR-LCT-013-cost-governor-fails-closed.md) | Cost governor bound and fail-closed behaviour | Cost Governance | MUST | `FR-LCT-013-cost-governor-fails-closed.md` |
| [FR-LCT-014](define-requirements/FR/FR-LCT-014-text-only-egress.md) | Text-only egress guarantee | Privacy & Consent | MUST | `FR-LCT-014-text-only-egress.md` |
| [FR-LCT-015](define-requirements/FR/FR-LCT-015-smart-mix-in-place-replacement.md) | Smart-mix in-place replacement (bounded) | Overlay | MUST | `FR-LCT-015-smart-mix-in-place-replacement.md` |
| [FR-LCT-016](define-requirements/FR/FR-LCT-016-anchored-callouts.md) | Anchored callouts that never obscure the original | Overlay | MUST | `FR-LCT-016-anchored-callouts.md` |
| [FR-LCT-017](define-requirements/FR/FR-LCT-017-always-show-original-toggle.md) | "Always show original text" toggle | Overlay | MUST | `FR-LCT-017-always-show-original-toggle.md` |
| [FR-LCT-018](define-requirements/FR/FR-LCT-018-overlay-progress-and-failure-states.md) | Pending and failed translation states in the overlay | Overlay | MUST | `FR-LCT-018-overlay-progress-and-failure-states.md` |
| [FR-LCT-019](define-requirements/FR/FR-LCT-019-persistent-encrypted-cache.md) | Persistent encrypted translation cache | Caching | MUST | `FR-LCT-019-persistent-encrypted-cache.md` |
| [FR-LCT-020](define-requirements/FR/FR-LCT-020-shared-cache-and-dictionary.md) | Shared dictionary and translation cache with the appliance helper | Caching | MUST | `FR-LCT-020-shared-cache-and-dictionary.md` |
| [FR-LCT-021](define-requirements/FR/FR-LCT-021-tap-to-hear-and-read-this-to-me.md) | Tap-to-hear and "read this to me" | Voice Output | MUST | `FR-LCT-021-tap-to-hear-and-read-this-to-me.md` |
| [FR-LCT-022](define-requirements/FR/FR-LCT-022-plugin-voice-entry-and-session.md) | LiveTranslatePlugin voice entry and session lifecycle | Plugin & Session | MUST | `FR-LCT-022-plugin-voice-entry-and-session.md` |
| [FR-LCT-023](define-requirements/FR/FR-LCT-023-honest-degradation-and-offline.md) | Honest degradation — never silently report success | Error Handling | MUST | `FR-LCT-023-honest-degradation-and-offline.md` |
| [NFR-LCT-001](define-requirements/NFR/NFR-LCT-001-overlay-responsiveness.md) | Overlay responsiveness and translation latency | Performance | MUST | `NFR-LCT-001-overlay-responsiveness.md` |
| [NFR-LCT-002](define-requirements/NFR/NFR-LCT-002-ocr-cadence-and-thermal-budget.md) | OCR cadence, battery and thermal budget | Performance | MUST | `NFR-LCT-002-ocr-cadence-and-thermal-budget.md` |
| [NFR-LCT-003](define-requirements/NFR/NFR-LCT-003-accessibility-standards.md) | Accessibility — tap targets, overlay text, contrast | Accessibility | MUST | `NFR-LCT-003-accessibility-standards.md` |
| [NFR-LCT-004](define-requirements/NFR/NFR-LCT-004-localisation.md) | Localisation of new UI strings | Localisation | MUST | `NFR-LCT-004-localisation.md` |
| [NFR-LCT-005](define-requirements/NFR/NFR-LCT-005-no-image-or-unrelated-content-egress.md) | Privacy — no image or unrelated-content egress | Privacy | MUST | `NFR-LCT-005-no-image-or-unrelated-content-egress.md` |
| [NFR-LCT-006](define-requirements/NFR/NFR-LCT-006-log-safety.md) | Log safety — no recognized or translated text in logs | Privacy / Security | MUST | `NFR-LCT-006-log-safety.md` |
| [NFR-LCT-007](define-requirements/NFR/NFR-LCT-007-consent-enforcement-and-auditability.md) | Consent enforcement and auditability | Compliance / Security | MUST | `NFR-LCT-007-consent-enforcement-and-auditability.md` |
| [NFR-LCT-008](define-requirements/NFR/NFR-LCT-008-cache-at-rest.md) | Cache at rest — encrypted, keyed, bounded | Security / Privacy | MUST | `NFR-LCT-008-cache-at-rest.md` |
| [NFR-LCT-009](define-requirements/NFR/NFR-LCT-009-untrusted-scene-text-hardening.md) | Untrusted scene text hardening (injection) | Security | MUST | `NFR-LCT-009-untrusted-scene-text-hardening.md` |
| [NFR-LCT-010](define-requirements/NFR/NFR-LCT-010-offline-degradation-integrity.md) | Offline degradation integrity — no false success | Reliability | MUST | `NFR-LCT-010-offline-degradation-integrity.md` |
| [NFR-LCT-011](define-requirements/NFR/NFR-LCT-011-configurable-parameters.md) | Configurable parameters — no hardcoded operational constants | Reliability / Maintainability | SHOULD | `NFR-LCT-011-configurable-parameters.md` |
| [NFR-LCT-012](define-requirements/NFR/NFR-LCT-012-shared-component-integrity.md) | Shared-component integrity — no regression to the appliance helper | Reliability | MUST | `NFR-LCT-012-shared-component-integrity.md` |
| [NFR-LCT-013](define-requirements/NFR/NFR-LCT-013-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST | `NFR-LCT-013-compliance-and-release-gates.md` |


## Functional requirements


### FR-LCT-001: Live camera preview without photo capture

#### Metadata
- **Area:** Camera Capture
- **Priority:** MUST
- **Source:** Design §1 (scope), §4.1; feature constitution "Scope" (no photo output configured); addendum §13.3

#### Description
The system **must** present a live, full-bleed camera preview from an `AVCaptureSession` +
`AVCaptureVideoPreviewLayer` (`.resizeAspect`) as the whole surface of the live translation view.
The capture session **must not** configure any photo output: no `AVCapturePhotoOutput`, no
`UIImagePickerController`, no frame written to photo library, app storage, or any temporary file.
A sampled video frame is used in memory for OCR only and is discarded.

The preview **must** remain the primary surface: overlays are drawn screen-space on top of it and
must never replace the camera feed with a synthetic view.

#### Acceptance criteria

```gherkin
Feature: Live camera preview

  Scenario: Live preview starts with no photo output configured
    Given the elder opens live translation
    When the capture session starts
    Then a live, full-bleed camera preview is displayed
    And the capture session has no photo output configured
    And no still image or video frame is written to storage

  Scenario: The elder leaves the view while the camera is live
    Given the live translation view is open and the preview is running
    When the elder closes the view
    Then the capture session stops
    And no captured frame remains on disk
```

#### Related
- NFR: NFR-LCT-005 (no image egress), NFR-LCT-002 (OCR cadence and thermal budget)
- Depends on: FR-LCT-002 (camera permission)


### FR-LCT-002: Camera permission and purpose disclosure

#### Metadata
- **Area:** Camera Capture / Compliance
- **Priority:** MUST
- **Source:** Design §4.1, §7; feature constitution "Standards → Release gates"; project constitution Compliance constraints; Open Decision 13 (recorded 2026-09-16)

#### Description
The system **must** request camera permission at the point of use with a plain-language
explanation in the active language, and **shall** handle every permission state without leaving
the elder at a dead end:

- **Not yet asked** — the explanation is shown before the system prompt.
- **Denied** — an explanatory screen with a Settings deep link (the existing permission-denied
  pattern used for the microphone), never a silent blank view.
- **Granted** — the live translation view opens directly.

`ios/ElderlyAssistant/Info.plist` `NSCameraUsageDescription` **must** disclose the live
translation use and the conditional text-to-cloud send, in addition to the existing medication
verification and appliance photo uses (the final consent/disclosure copy is reviewed before the
first App Store submission — design §10 Open Decision 3).

#### Acceptance criteria

```gherkin
Feature: Camera permission and purpose disclosure

  Scenario: Permission granted on first use
    Given the elder has not yet granted camera permission
    When the elder invokes live translation
    Then a plain-language explanation of the camera use is shown in the active language
    And on granting, the live translation view opens

  Scenario: Permission denied
    Given the elder has denied camera permission
    When the elder invokes live translation
    Then an explanatory screen is shown in the active language with a link to Settings
    And the elder can return to the assistant without being trapped in the view

  Scenario: Purpose string discloses live translation and the cloud text send
    Given the shipped Info.plist
    When the camera purpose string is inspected
    Then it states that live translation uses the camera
    And it states that recognized text (never images) may be sent to the assistant's cloud service when the dictionary cannot translate it
```

#### Related
- NFR: NFR-LCT-013 (compliance and release gates)
- Depends on: —


### FR-LCT-003: On-device OCR with automatic language detection

#### Metadata
- **Area:** Text Detection
- **Priority:** MUST
- **Source:** Design §1, §4.2; feature constitution "Scope" (on-device OCR with automatic language detection)

#### Description
The system **must** recognize printed text from the sampled camera frames entirely on-device
using Vision (`VNRecognizeTextRequest` with `automaticallyDetectsLanguage = true`), producing for
each observation: the recognized string, a normalized bounding box, the recognized source
language, and a confidence value. No OCR model may be downloaded and no image or text may leave
the device for recognition.

v1 quality focus is **English source text**; the pipeline must not hard-code the source language,
because the same path serves the any-language → user-language roadmap without architectural change
(feature rule 9).

When no text is recognized in the frame, the system **must** show an empty-state hint ("point at
some writing") and **must not** surface an error.

#### Acceptance criteria

```gherkin
Feature: On-device OCR with automatic language detection

  Scenario: Text in frame is recognized on-device
    Given the camera preview shows printed text
    When a frame is sampled
    Then each recognized region carries its text, normalized bounding box, detected language and confidence
    And no network request is made to perform recognition

  Scenario: No text in frame
    Given the camera preview shows no readable text
    When frames are sampled
    Then an empty-state hint is shown in the active language
    And no error state is presented to the elder

  Scenario: A non-English sample is still recognized
    Given the camera preview shows printed text in a language other than English
    When a frame is sampled
    Then the observation reports the detected source language rather than assuming English
```

#### Related
- NFR: NFR-LCT-002 (OCR cadence), NFR-LCT-009 (untrusted text hardening)
- Depends on: FR-LCT-001 (live preview)


### FR-LCT-004: Region tracking between OCR passes

#### Metadata
- **Area:** Text Detection
- **Priority:** SHOULD
- **Source:** Design §2, §4.2; addendum §13.3 (VNTrackRectangleRequest between OCR passes)

#### Description
The system **should** carry detected text-region screen positions between OCR passes with
`VNTrackRectangleRequest`, so that a region's overlay follows the camera movement smoothly
instead of jumping at the OCR cadence. Tracking runs on intermediate frames at a lower cost than
OCR and **must not** be treated as a source of recognized text: a tracked region's text changes
only when OCR confirms it.

If tracking fails or loses a region, the system **must** fall back to the last confirmed OCR
geometry for that region rather than dropping or misplacing the overlay.

#### Acceptance criteria

```gherkin
Feature: Region tracking between OCR passes

  Scenario: Overlay follows the scene between OCR passes
    Given a stable region has a confirmed translation
    When the camera moves between OCR passes
    Then the overlay is repositioned from tracking observations without waiting for the next OCR pass

  Scenario: Tracking loses the region
    Given a region is being tracked
    When tracking reports no observation for that region
    Then the overlay keeps the last confirmed OCR geometry
    And no new text is attributed to the region without OCR confirmation
```

#### Related
- NFR: NFR-LCT-002 (OCR cadence)
- Depends on: FR-LCT-003 (OCR), FR-LCT-005 (stable regions)


### FR-LCT-005: Stable text regions with hysteresis and change-only events

#### Metadata
- **Area:** Region Stabilisation
- **Priority:** MUST
- **Source:** Design §4.3, §5; addendum §13.3

#### Description
The system **must** stabilise OCR observations into stable text regions with stable identifiers,
by matching an observation to an existing region on geometry (IoU ≥ 0.3 or centroid distance)
combined with normalized string equality. Anti-flicker hysteresis is mandatory in both
directions: a region appears only after **2 consecutive detections** and is removed only after
**2 consecutive misses**.

The stabiliser **must** emit a change event only when a region's recognized text actually
changes (including first appearance). This is the gate that bounds translation traffic: an
unchanged scene must not re-enter the translation tiers.

#### Acceptance criteria

```gherkin
Feature: Region stabilisation

  Scenario: A region appears only after two consecutive detections
    Given no regions are visible
    When the same text is detected in one OCR pass only
    Then no stable region is emitted and no translation is requested

  Scenario: A region survives a single missed pass
    Given a stable region exists
    When it is missed in one OCR pass
    Then the region is retained with its translation

  Scenario: A region is removed after two consecutive misses
    Given a stable region exists
    When it is missed in two consecutive OCR passes
    Then the region and its overlay are removed

  Scenario: Repeated identical text does not re-trigger translation
    Given a stable region with a resolved translation
    When subsequent OCR passes return the same normalized text
    Then no change event is emitted
    And no new translation request is made for that region
```

#### Related
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-010 (no false success)
- Depends on: FR-LCT-003 (OCR)


### FR-LCT-006: Decluttering for dense multi-region scenes

#### Metadata
- **Area:** Region Stabilisation
- **Priority:** MUST
- **Source:** Design §4.3 (answers addendum Open Decision 12); Design §1 scope ("text-dense scenes (a menu page)")

#### Description
The system **must** remain legible on text-dense scenes, including a full menu page. Before
rendering, regions **must** be decluttered:

1. Duplicate regions with the same normalized string whose normalized centroids are closer than
   **0.06** on either axis are merged into one region whose text is the longest string of the
   merged set.
2. When more than **8** regions are visible after merging, the 8 highest-confidence regions are
   kept.
3. Every kept region must still produce exactly one overlay (never overlapping duplicate
   callouts for the same text).

The decluttering thresholds are nominal values that are validated on a real device against a dense
menu page and may become per-scene settings (design §10 Open Decision 5); they **must** be
implemented as configurable parameters, not hardcoded constants (constitution Agent Principles).

#### Acceptance criteria

```gherkin
Feature: Decluttering for dense scenes

  Scenario: Same label repeated across the scene merges into one overlay
    Given two detected regions carry the same normalized text with centroids closer than 0.06 on either axis
    When the overlay is rendered
    Then a single overlay is shown carrying the longest of the merged strings

  Scenario: A dense menu page is bounded to the region cap
    Given more than 8 distinct regions are visible in a menu page
    When the overlay is rendered
    Then at most 8 overlays are shown
    And the kept regions are the 8 highest-confidence ones
```

#### Related
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)


### FR-LCT-007: Tier 0 curated dictionary translation

#### Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Design §2, §4.4 (tier 0), §3; feature constitution "Binding feature rule" on exact whole-label match

#### Description
The system **must** resolve recognized text through a curated, on-device dictionary (tier 0)
before any other tier is considered. The dictionary is the existing
`ApplianceLabelLocalizer`, **extended** to a target of ~120 curated English→Nepali entries
covering appliance and remote vocabulary. The extension **must** keep the existing conservative
rules: exact whole-label match after normalization, **no fuzzy matching**, pass-through of text
that is already in the active language, and the existing `Display(primary:secondary:)` shape with
its locale gating (`isNepali`). The contract of `ApplianceLabelLocalizer` must not be weakened —
it is shared with the shipped appliance helper.

A tier-0 hit is resolved with **zero network access** and must be available with the device in
airplane mode.

#### Acceptance criteria

```gherkin
Feature: Tier 0 dictionary translation

  Scenario: Known label resolves without network
    Given the device has no network connection
    When a recognized label exactly matches a curated dictionary entry
    Then the translation is resolved by tier 0
    And the result reports sourceTier = dictionary

  Scenario: Near-miss is not translated as if exact
    Given a recognized string differs from a dictionary entry (case, spacing or wording)
    When the dictionary is consulted
    Then no tier-0 match is claimed unless the normalized whole-label match is exact

  Scenario: Text already in the active language passes through
    Given the recognized text is already Nepali
    When the dictionary is consulted
    Then the text is passed through unchanged
    And it is never re-translated
```

#### Related
- NFR: NFR-LCT-012 (shared-component integrity), NFR-LCT-010 (no false success)
- Depends on: FR-LCT-003 (OCR)


### FR-LCT-008: Truthful tier attribution and no success without translation

#### Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Feature constitution "v1 non-goals" (deferred work must be absent, not a silent stub); Design §4.4, §11 (D2).
  **Amended 2026-09-17** by owner directive (see "Amendment" below): the deferred-tier clause is
  superseded by the on-device brain tier.
  **Amended 2026-09-20** by owner-approved reliability routing (see "Amendment" below): the tier
  order above is narrowed **by string class** — the device leads for the short forms the gate data
  shows it is exact on, the cloud leads for the sentence class when it can lead, and anything the
  cloud does not answer falls back to the device.

#### Description
Every translated string **must** carry the tier that actually produced it
(`TranslationResult.sourceTier`), and a tier **must not** return success when it did not translate.

- The tiers that may produce a translation, in the order the pipeline consults them, are
  **tier 0 (dictionary)**, **tier 1 (on-device brain, no egress)** and **tier 2 (cloud,
  consent-gated)**. A string is asked of the next tier only when the tier before it did not
  answer it, and a result is always attributed to the tier that produced it — never to a tier
  that did not run.
- The **on-device brain tier is the app's own installed Nepali language model**, running entirely
  on the device. It is "tier 1 in spirit": a device-local translation stage between the curated
  dictionary and the consent-gated cloud. It is not a dedicated NMT model, and it is not a stub,
  a passthrough or a "translate later" placeholder: it either produces a translation from a model
  that is installed, or it reports an honest reason and the string continues down the cascade.
- **It requires no consent and no network.** Nothing about this tier leaves the device, so
  Open Decision 13 (consent/disclosure) is untouched by it, and the consent prompt still appears
  at the point of first **cloud** need — not over a scene the device could answer by itself.
- A tier that cannot be used **must not** hold the cycle open or answer silently: an unavailable
  model, a failed load, a failed generation and a generation that outlives its configured deadline
  are each recorded with a closed-vocabulary reason, and the unresolved strings fall through to
  the next tier.
- When no tier produced a translation, the result **must** report the failure honestly:
  `isFinal = true`, `degraded = true`, and the text shown is the original recognized text — never a
  fabricated or unmarked string.

#### Acceptance criteria

```gherkin
Feature: Truthful tier attribution

  Scenario: A dictionary hit is attributed to tier 0
    Given a recognized label matches the curated dictionary
    When the translation resolves
    Then sourceTier reports dictionary
    And isFinal is true and degraded is false

  Scenario: An on-device brain translation is attributed to tier 1
    Given a recognized string is unresolved by the dictionary and a brain model is installed
    When the on-device brain returns a translation
    Then sourceTier reports the on-device brain tier
    And the cloud tier is never asked
    And no consent is required and no network request is made

  Scenario: A cloud translation is attributed to tier 2
    Given a recognized string is unresolved by the dictionary and the brain
    And consent is recorded
    When the cloud tier returns a translation
    Then sourceTier reports cloud
    And degraded is false

  Scenario: No tier can translate
    Given the dictionary cannot resolve the string, the brain cannot be used, and the cloud tier is unavailable
    When the resolution completes
    Then sourceTier does not claim a tier that did not translate
    And degraded is true
    And the text shown is the original recognized text

  Scenario: An unavailable brain is reported rather than stubbed
    Given the on-device brain tier cannot run (no model installed, no runtime, or a failed attempt)
    When the resolution completes
    Then the reason is recorded with a closed-vocabulary outcome
    And the string is left unresolved for the next tier rather than answered with a fabricated, empty or echoed string

  Scenario: The sentence class leads with the cloud when the cloud can lead
    Given a recognized sentence-class string is unresolved by the dictionary
    And the household's cloud switch is on and a network path exists
    And the cloud tier is consent-gated and consent is recorded
    When the cloud returns a translation
    Then sourceTier reports cloud
    And the device brain tier was not asked for this string

  Scenario: A string the cloud cannot answer falls back to the device
    Given a recognized sentence-class string led with the cloud
    And the cloud produced no translation for it
    When the resolution completes
    Then the string is translated on the device rather than degraded
    And sourceTier reports the on-device brain tier
```

#### Amendment
**2026-09-17, owner directive (supersedes the deferred-tier clause of Design §11 D2 for v1).**
The original text required the on-device tier to be *absent* from v1 — not a stub, not a
placeholder. The owner's directive re-opens that non-goal and lands the tier as **tier 1 (the
on-device brain)**, because the shipped cascade (dictionary → consent-gated cloud) degrades every
string the ~120-label dictionary misses to "can't translate" the moment the elder is offline or
has declined the cloud — and the model that fixes that is already installed on the device.

What the original requirement existed to protect is unchanged and is what the amended acceptance
criteria still pin: **no success without translation**, and **no result attributed to a tier that
did not translate it**. The prohibition was never on the tier existing; it was on the tier lying.
The narrow "must be absent" clause is what this amendment retires.

**2026-09-20, owner-approved reliability routing (narrows the order in the description by string
class).** The order in the description — tier 1 then tier 2, for every string — is the order the
pipeline runs for the class the round-1/2/3 gate data shows the device model is **exact** on:
short labels, menu items and pharmaceutical names (at most four words, at most forty characters,
no clause punctuation). For the **sentence class** — instructions, sentences, anything longer —
the same gate data does not show that, and the owner approved leading with the cloud for that
class **when and only when the cloud can lead**: the household's switch on and a live network
path. Whatever the cloud does not answer for those strings comes back to the device, so the
routing trades a *tier order* for reliability and never trades a translation away.

What this narrowing keeps is the whole of what the requirement protects: **no success without
translation** (a string the cloud fails is translated on the device rather than degraded) and **no
result attributed to a tier that did not translate it** (the router decides only the *order*; the
tier that answers is always the tier named). The cloud stays consent-gated at the point of need
(FR-LCT-011, FR-LCT-020), and a string the device answers still costs no request and no egress.

The rule lives in one place, `TranslationReliabilityRouter`, and it is keyed on **measured
reliability** — the class the gate data separates — deliberately not on negation, keywords or any
other shape a translator could game.

#### Related
- NFR: NFR-LCT-010 (offline degradation integrity)
- Depends on: FR-LCT-007 (tier 0), FR-LCT-009 (tier 2), FR-LCT-020 (consent at the point of cloud need)


### FR-LCT-009: Tier 2 text-only cloud translation

#### Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Design §2, §4.4 (tier 2), §7; project constitution Open Decision 13 (recorded 2026-09-16)

#### Description
Strings the dictionary cannot resolve **may** be translated by the cloud tier (tier 2) through
the existing `GeminiClient` request chokepoint, subject to FR-LCT-010 (consent), FR-LCT-013 (cost
governor) and FR-LCT-014 (text-only egress).

- The request is **text-only**: the unresolved strings plus the target language and the detected
  source language per string. No image, no `inlineData` part, no photo, ever.
- Unresolved strings from one scene **must** be sent as **one batched request** where the batch
  size permits, not one request per string.
- **In-flight deduplication is mandatory**: while a key is pending, no second request may be
  fired for it.
- A transient provider error is retried at most once; a provider block/policy error is not
  retried. Timeouts are configurable parameters, not hardcoded constants.
- The tier **must** fail honestly on any failure (FR-LCT-008, FR-LCT-023); it must never silently
  drop a string or report success without a translation.

#### Acceptance criteria

```gherkin
Feature: Tier 2 cloud translation

  Scenario: Unresolved strings from one scene are batched into a single call
    Given consent is recorded and the dictionary cannot resolve 8 recognized strings
    When the cloud tier resolves them
    Then exactly one request is sent carrying all 8 strings
    And the request carries text only

  Scenario: A pending key does not fire a duplicate request
    Given a string is already in flight to the cloud tier
    When the same string is observed again before the reply arrives
    Then no second request is sent for that string

  Scenario: Transient failure is retried once then reported honestly
    Given the cloud tier returns a transient error
    When the retry also fails
    Then the region is reported as degraded (original text plus an offline indication)
    And no further retries are attempted for that region

  Scenario: Provider policy block
    Given the cloud tier refuses the request under its policy
    When the response is received
    Then no retry is attempted
    And the region is reported as degraded
```

#### Related
- FR: FR-LCT-010 (consent), FR-LCT-013 (cost governor), FR-LCT-014 (text-only egress), FR-LCT-018 (overlay states)
- NFR: NFR-LCT-009 (untrusted text hardening), NFR-LCT-001 (latency)
- Depends on: FR-LCT-003 (OCR), FR-LCT-007 (tier 0)


### FR-LCT-010: Consent gate before any cloud translation

#### Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rules 2 and 3; project constitution Open Decision 13 (recorded 2026-09-16); design §4.6, §7

#### Description
No tier-2 (cloud) translation request **may** be made unless the user has given recorded, explicit
consent for text-to-cloud translation. The gate is the feature's compliance basis.

- The consent request is presented at the **first cloud need**, not buried in settings, in
  plain language in the active language, before any request is sent.
- Consent is **recorded** on-device and is **revocable** (FR-LCT-012).
- The gate **must fail closed**: a missing, unreadable or absent consent record denies the call.
  There is no default-on path, no "implicit consent by using the feature", and no configuration
  that reaches tier 2 without a recorded consent.
- The data sent is limited to what Open Decision 13 records: OCR'd text strings only (FR-LCT-014).

#### Acceptance criteria

```gherkin
Feature: Consent gating of cloud translation

  Scenario: First cloud need asks for consent
    Given the dictionary cannot resolve a recognized string
    And no consent has been recorded
    When the translation tiers select a tier
    Then a plain-language consent request is shown before any request is sent
    And no network request to the cloud provider is made while consent is absent

  Scenario: Recording consent enables the cloud tier
    Given the elder gives consent
    When the consent is recorded
    Then the unresolved strings may be sent to the cloud tier
    And the consent decision persists across app launches

  Scenario: Consent denied
    Given the elder declines consent
    When unresolved strings remain
    Then no cloud request is made
    And the affected regions keep their original text with an honest unavailable indication
    And the feature remains usable with the dictionary alone

  Scenario: Consent record missing or unreadable at the point of use
    Given the stored consent record cannot be read
    When a cloud translation would otherwise be needed
    Then the gate denies the request (fails closed)
    And no cloud request is made
```

#### Related
- FR: FR-LCT-011 (cloud indicator), FR-LCT-012 (revocation), FR-LCT-014 (text-only egress)
- NFR: NFR-LCT-007 (consent enforcement and auditability), NFR-LCT-013 (compliance gates)
- Depends on: FR-LCT-009 (tier 2)


### FR-LCT-011: Visible cloud-activity indicator

#### Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 2; project constitution Open Decision 12 (indicator precedent) and Open Decision 13; design §4.6

#### Description
While the cloud tier is active — that is, from the moment a tier-2 request is issued until its
result (or failure) has been applied — the system **must** show a visible indicator in the live
translation view that text is being translated by the cloud service.

- The indicator's state **must** be driven by actual tier-2 activity, not by settings or by a
  static decoration: it appears only when a request is in flight and disappears when the tier is
  idle.
- The indicator **must not** be spoofable or suppressible by any state that does not reflect
  cloud activity (e.g. it must not be hidden by the "always show original text" toggle, by a
  dictionary-only session, or by an overlay mode).
- The indicator must be understandable to the elder: a symbol plus a plain-language label in the
  active language, not an icon alone (pending final consent/disclosure copy review — design §10
  Open Decision 3).

#### Acceptance criteria

```gherkin
Feature: Cloud-activity indicator

  Scenario: Indicator appears while a cloud request is in flight
    Given consent is recorded
    When a tier-2 request is issued
    Then a visible indicator states that text is being translated by the cloud service
    And the indicator remains visible until the request resolves or fails

  Scenario: Indicator is absent when the cloud tier is idle
    Given no tier-2 request is in flight
    When the elder uses live translation offline with the dictionary
    Then no cloud-activity indicator is shown

  Scenario: Indicator cannot be suppressed while the cloud tier is active
    Given a tier-2 request is in flight
    When the overlay mode is changed (for example the always-show-original toggle)
    Then the cloud-activity indicator remains visible
```

#### Related
- FR: FR-LCT-010 (consent gate), FR-LCT-013 (cost governor)
- NFR: NFR-LCT-007 (consent enforcement and auditability)
- Depends on: FR-LCT-009 (tier 2)


### FR-LCT-012: Consent revocation degrades to dictionary-only offline mode

#### Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 2; project constitution Open Decision 13 ("revoking degrades the feature to offline mode, never blocks it"); design §7

#### Description
The elder (or a family member on their behalf) **must** be able to revoke consent for cloud
translation at any time. Revocation **must** take effect for subsequent tier-2 activity without a
reinstall and **must never block the feature**:

- After revocation the feature continues with tier 0 (dictionary) and cached translations.
- Unresolved strings keep the original text with an honest unavailable indication (FR-LCT-018,
  FR-LCT-023) — the elder always sees the recognized text.
- Cached translations remain usable (they are already on the device and require no egress), so
  prior scenes keep working.

#### Acceptance criteria

```gherkin
Feature: Consent revocation

  Scenario: Revocation stops cloud traffic
    Given consent was recorded and a cloud request is not in flight
    When the elder revokes consent
    Then no further tier-2 request is made
    And the cloud-activity indicator is not shown

  Scenario: The feature still works after revocation
    Given consent has been revoked
    When the elder points the camera at a dictionary-known label
    Then the translation is resolved by tier 0
    And the feature remains usable without any error blocking the view

  Scenario: Cached translations survive revocation
    Given a string was translated before revocation and is in the persistent cache
    When the same string is recognized after revocation
    Then the cached translation is shown
    And no cloud request is made
```

#### Related
- FR: FR-LCT-010 (consent gate), FR-LCT-019 (persistent cache), FR-LCT-023 (degradation)
- NFR: NFR-LCT-007 (consent enforcement and auditability)
- Depends on: FR-LCT-010


### FR-LCT-013: Cost governor bound and fail-closed behaviour

#### Metadata
- **Area:** Cost Governance
- **Priority:** MUST
- **Source:** Design §4.4 (tier 2), §5, §8; feature constitution binding rule 7; project constitution Open Decision 13 ("bounded per-session by the existing GeminiCostGovernor")

#### Description
Tier-2 activity **must** be bounded by the existing cost governor (`GeminiCostGovernor`), through
which every cloud call in this app already passes. When the governor refuses a call:

- the tier **must fail closed**: no request is issued and the affected regions show the original
  text with the honest unavailable/offline indication;
- after the cap is reached, the failure applies **for the rest of the session** — the system
  **must not** enter a silent retry loop or fall back to a different unmetered request shape;
- the refusal **must not** degrade any other feature or leave the elder without the camera view.

**Known inconsistency to be resolved by design (recorded open decision):** the shipped
`GeminiCostGovernor` counts calls **per day** with a family-editable cap, while design §4.4
describes a "per-session" cap. The requirement binds the *behaviour* (bounded calls, fail closed,
no retry loop); whether v1 adds a per-session sub-cap inside the per-day governor or relies on the
per-day cap is for `design-component` to decide and record. Either way the cap value must be a
configurable parameter, not a hardcoded constant.

#### Acceptance criteria

```gherkin
Feature: Cost governor fails closed

  Scenario: The cap is reached mid-session
    Given the cost governor reports no budget remaining
    When an unresolved string would otherwise be sent to the cloud tier
    Then no request is issued
    And the affected regions show the original text with an honest unavailable indication
    And the camera view and dictionary translations keep working

  Scenario: No silent retry loop after the cap
    Given the cap has been reached
    When the scene changes and new unresolved strings appear
    Then no cloud request is issued for the rest of the session
    And no repeated retry attempts are made for the same key

  Scenario: Attempts refused by the governor are not counted as translations
    Given a cloud request is refused by the cost governor
    When the region's result is reported
    Then the result reports degraded (no tier produced a translation)
```

#### Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-023 (degradation)
- NFR: NFR-LCT-010 (offline degradation integrity), NFR-LCT-011 (configurable parameters)
- Depends on: FR-LCT-009


### FR-LCT-014: Text-only egress guarantee

#### Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 1; project constitution Open Decision 13 (Scope); design §7

#### Description
The live translation feature **must** send **only OCR'd text strings and the language parameters
needed to translate them**. It **must never** send:

- any image, frame, photo, thumbnail, or `inlineData`/media part — the camera session configures no
  photo output at all (FR-LCT-001) and no translation request may attach image data;
- health, contacts, profile, calendar, medication, or any other personal content from the app;
- metadata beyond what the translation request needs (no device identifiers, no location).

The guarantee **must** hold on every path that reaches the cloud tier, including retries and
batched requests, and must be verifiable by inspection of the request construction (a single
chokepoint) and by test evidence at `security-test`.

#### Acceptance criteria

```gherkin
Feature: Text-only egress

  Scenario: A translation request carries text only
    Given consent is recorded and unresolved strings exist
    When the tier-2 request is constructed
    Then the request contains text parts only
    And no image, media or inline data part is present
    And no health, contacts or profile content is present

  Scenario: No photo output means no image can be attached
    Given the live translation camera session
    When the session configuration is inspected
    Then no photo output is configured
    And the translation path has no source of image bytes to attach

  Scenario: The guarantee holds on retry and on batched requests
    Given a tier-2 request is retried after a transient error
    When the retry is constructed
    Then the retry carries the same text-only payload shape
```

#### Related
- NFR: NFR-LCT-005 (no image or unrelated-content egress), NFR-LCT-007 (consent enforcement)
- Depends on: FR-LCT-009 (tier 2), FR-LCT-001 (no photo output)


### FR-LCT-015: Smart-mix in-place replacement (bounded)

#### Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.5, §11 D1 (owner-approved divergence from addendum §13.3/§13.5); feature constitution binding rule 6

#### Description
The overlay **may** replace the original printed text **in place** (opaque high-contrast
background sized to the region) only when **all** of these conditions hold:

1. the translation came from **tier 0** (the curated dictionary), and
2. the source string is **short** (≤ 3 words), and
3. the translated string **fits** the region at a minimum of **18 pt**.

Every other case **must** use an anchored callout (FR-LCT-016). This bounded in-place rule is the
owner-approved D1 divergence; it is the only case in which the overlay may obscure the original
printed text, and it must be implemented as the explicit, testable condition above — not as a
heuristic or an unbounded "replace when it seems to fit".

#### Acceptance criteria

```gherkin
Feature: Smart-mix in-place replacement

  Scenario: A short dictionary-known label is replaced in place
    Given a stable region carries a short dictionary-known label
    And the translation fits the region at 18 pt or larger
    When the overlay is rendered
    Then the translation is drawn in place with an opaque high-contrast background sized to the region

  Scenario: A cloud translation is never drawn in place
    Given a region's translation came from the cloud tier
    When the overlay is rendered
    Then an anchored callout is used instead of in-place replacement

  Scenario: A long or non-fitting translation is not drawn in place
    Given a dictionary-known label whose source is longer than 3 words, or whose translation does not fit at 18 pt
    When the overlay is rendered
    Then an anchored callout is used instead of in-place replacement
```

#### Related
- FR: FR-LCT-016 (anchored callouts), FR-LCT-017 (always-show-original toggle), FR-LCT-007 (tier 0)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)


### FR-LCT-016: Anchored callouts that never obscure the original

#### Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.5; addendum §13.3; base design §0/§5.1 ("never obscure/redraw reality"), preserved for all non-in-place cases; design §11 D4

#### Description
Every region that is **not** covered by the bounded in-place rule (FR-LCT-015) **must** be
rendered as an anchored callout: a pill with a leader line to the detected region, showing the
translation as the primary text (≥ 18 pt, bold, high contrast) and the original recognized text as
smaller secondary text for cross-check. The callout **must not** cover the original printed text
or the camera view it annotates.

Callout placement must remain legible on dense scenes: callouts must not be drawn on top of one
another for distinct regions (the declutter rules of FR-LCT-006 bound how many exist).

#### Acceptance criteria

```gherkin
Feature: Anchored callouts

  Scenario: Non-dictionary text gets an anchored callout
    Given a stable region whose translation is not eligible for in-place replacement
    When the overlay is rendered
    Then a callout with a leader line to the region is shown
    And the translation is the primary text at 18 pt or larger
    And the original recognized text is shown as smaller secondary text

  Scenario: The callout does not cover the original text
    Given a callout is rendered for a region
    When the region's printed text is inspected on screen
    Then the callout does not cover that printed text
```

#### Related
- FR: FR-LCT-015 (in-place rule), FR-LCT-006 (decluttering), FR-LCT-017 (toggle)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)


### FR-LCT-017: "Always show original text" toggle

#### Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §1, §4.5, §10 Open Decision 2; feature constitution binding rule 6 (the toggle ships with the D1 divergence)

#### Description
The system **must** provide an "always show original text" setting that reduces the overlay to
**pure callout mode**: when enabled, no in-place replacement is drawn and every translated region
uses an anchored callout (FR-LCT-016). The setting ships alongside the D1 in-place rule, is
reachable by touch and by voice (FR-LCT-022), persists across sessions, and takes effect on the
next rendered frame without restarting the feature.

The default value of this setting is confirmed at the first device demo (design §10 Open Decision
2); the requirement binds its existence, reachability and effect, not the default.

#### Acceptance criteria

```gherkin
Feature: Always-show-original toggle

  Scenario: Enabling the toggle removes in-place replacement
    Given a short dictionary-known label that would otherwise be drawn in place
    When the elder enables "always show original text"
    Then the original printed text is no longer covered by the overlay
    And an anchored callout carries the translation

  Scenario: The setting persists
    Given the elder enabled "always show original text"
    When the elder closes and reopens live translation
    Then the setting is still enabled
```

#### Related
- FR: FR-LCT-015 (in-place rule), FR-LCT-016 (callouts), FR-LCT-022 (voice control)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-015


### FR-LCT-018: Pending and failed translation states in the overlay

#### Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.4 (`isFinal`), §4.5, §8 (error handling table); feature constitution binding rule 7

#### Description
Each region's overlay **must** reflect the real state of its translation:

- **pending** — while a tier is still resolving, the region shows a "translating…" state
  (`isFinal = false`); the elder is never shown a blank bubble or a fabricated string;
- **resolved** — the translated string with the tier that produced it (FR-LCT-008);
- **degraded** — when no tier produced a translation, the original text remains visible with an
  honest unavailable/offline indication; nothing is silently dropped.

State transitions must be monotonic from pending to a terminal state; a region must not flip back
to pending once a translation is shown, and must not show "translating…" indefinitely after a
failure (FR-LCT-009, FR-LCT-013).

#### Acceptance criteria

```gherkin
Feature: Overlay progress and failure states

  Scenario: A region shows the pending state while a tier resolves
    Given a region's text is unresolved and a tier is in flight
    When the overlay is rendered
    Then the region shows a "translating…" state in the active language
    And the original recognized text is still accessible

  Scenario: A failed translation shows the original with an honest indication
    Given all tiers failed for a region
    When the overlay is rendered
    Then the original text is shown with an unavailable/offline indication
    And no translated-looking string is shown

  Scenario: A resolved region does not revert to pending
    Given a region has a resolved translation
    When the scene is unchanged
    Then the region does not return to the "translating…" state
```

#### Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-013 (governor), FR-LCT-023 (degradation)
- NFR: NFR-LCT-010 (no false success)
- Depends on: FR-LCT-005 (stable regions)


### FR-LCT-019: Persistent encrypted translation cache

#### Metadata
- **Area:** Caching
- **Priority:** MUST
- **Source:** Design §3, §5 (cache), §11 D3 (generalizes addendum §13.2's in-memory `LabelTranslationCache`); feature constitution binding rule 10

#### Description
Translated strings **must** be cached persistently on-device, keyed
`(normalizedText|targetLanguage)`, so that a repeat scene needs no network. The cache is **user
content at rest**:

- stored **encrypted** using the existing `StoragePlacement` / encrypted-storage pattern;
- **seeded from the curated dictionary**, so the first use of a known label is already a hit;
- general (non-dictionary) entries evicted by **LRU with a bound of ~200 entries**; dictionary /
  label-vocabulary entries effectively never evict;
- never written in plaintext and never sent to the cloud as a cache (only individual unresolved
  strings go to the cloud tier, subject to consent).

A cache hit produces the translation with zero network calls and must be preserved across app
launches and across camera session interruptions.

#### Acceptance criteria

```gherkin
Feature: Persistent encrypted translation cache

  Scenario: A cached translation survives a relaunch without network
    Given a string was translated in a previous session and is cached
    When the app is relaunched with no network and the same string is recognized
    Then the cached translation is shown
    And no network request is made

  Scenario: The cache is seeded from the dictionary
    Given a freshly installed app with no prior translation history
    When a dictionary-known label is recognized
    Then it is resolved from the seeded cache/dictionary with no network request

  Scenario: The cache is bounded by LRU eviction
    Given the cache holds its maximum number of general entries
    When a new general entry is inserted
    Then the least recently used general entry is evicted
    And dictionary/label entries are not evicted by that policy

  Scenario: The cache is not stored in plaintext
    Given a translation has been cached
    When the on-device storage is inspected
    Then the cached content is not readable as plaintext
```

#### Related
- FR: FR-LCT-020 (shared cache), FR-LCT-012 (revocation keeps cache usable)
- NFR: NFR-LCT-008 (cache at rest encryption)
- Depends on: FR-LCT-007 (tier 0)


### FR-LCT-020: Shared dictionary and translation cache with the appliance helper

#### Metadata
- **Area:** Caching
- **Priority:** MUST
- **Source:** Design §0, §3, §5; feature constitution "Known integration surface"; user-task scope

#### Description
The live translation feature **must** be a **new plugin** that shares the appliance helper's
label dictionary and translation cache rather than owning private copies:

- the tier-0 dictionary is the same `ApplianceLabelLocalizer` data set used by the appliance
  helper, extended (not forked);
- the persistent translation cache (FR-LCT-019) is a **single shared store** used by both the
  appliance helper and live translation, keyed `(normalizedText|targetLanguage)`;
- a translation resolved in one surface is available in the other without a new network call;
- sharing **must not** change or weaken the behaviour of the shipped appliance helper
  (`ApplianceLabelLocalizer`, `ApplianceOverlayMapper` are extended/reused, not modified).

#### Acceptance criteria

```gherkin
Feature: Shared dictionary and translation cache

  Scenario: A translation cached in the appliance helper is reused by live translation
    Given the appliance helper has translated a label that is now in the shared cache
    When live translation recognizes the same label
    Then the cached translation is shown with no network request

  Scenario: A translation cached in live translation is reused by the appliance helper
    Given live translation has cached a label translation
    When the appliance helper presents the same label
    Then the same cached translation is used

  Scenario: There is exactly one cache store
    Given both features are installed
    When the app's storage is inspected
    Then a single translation cache exists, shared by both entry points
```

#### Related
- FR: FR-LCT-019 (persistent cache), FR-LCT-007 (dictionary)
- NFR: NFR-LCT-012 (no regression to the appliance helper)
- Depends on: FR-LCT-019


### FR-LCT-021: Tap-to-hear and "read this to me"

#### Metadata
- **Area:** Voice Output
- **Priority:** MUST
- **Source:** Design §1, §4.6, §6; feature constitution "Scope" (tap-to-hear and "read this to me" via the existing Piper voices)

#### Description
The system **must** support hearing translations through the existing on-device speech stack
(`SpeakQueue` with the active-language Piper voice):

- **tap-to-hear**: tapping a region's bubble speaks that region's translation (tap target ≥ 44 pt);
- **"read this to me"**: a session voice command that speaks the visible regions' translations
  **top-to-bottom** in screen order; "stop" halts the reading;
- auto-speak of every new translation is a **non-goal** — nothing is spoken without an explicit
  tap or command (design §1 non-goals, to avoid noise in multi-label scenes);
- if speech fails, the visual translation **must** remain visible and no retry loop may start
  (existing `SpeakQueue` degradation).

#### Acceptance criteria

```gherkin
Feature: Hearing translations

  Scenario: Tap-to-hear speaks one region
    Given a region has a resolved translation
    When the elder taps its bubble
    Then the translation is spoken in the active language
    And no other region is spoken

  Scenario: "Read this to me" reads visible regions top-to-bottom
    Given several stable regions with resolved translations are visible
    When the elder says "read this to me"
    Then the translations are spoken in top-to-bottom screen order
    And saying "stop" halts the reading

  Scenario: Nothing is spoken automatically
    Given a new region gains a resolved translation
    When the elder does not tap or ask
    Then no speech is produced

  Scenario: Speech failure does not remove the visual translation
    Given a tap-to-hear request fails in the speech stack
    Then the visual translation remains visible
    And no retry loop is started
```

#### Related
- FR: FR-LCT-018 (overlay states), FR-LCT-022 (session commands)
- NFR: NFR-LCT-003 (accessibility), NFR-LCT-004 (localisation)
- Depends on: FR-LCT-005 (stable regions)


### FR-LCT-022: LiveTranslatePlugin voice entry and session lifecycle

#### Metadata
- **Area:** Plugin & Session
- **Priority:** MUST
- **Source:** Design §0, §2, §4.6; feature constitution "Known integration surface" (session-local commands, no intent-encoder retraining); `ApplianceHelperPlugin` precedent

#### Description
Live translation **must** ship as a new voice-invokable plugin, `LiveTranslatePlugin`, registered
in the plugin registry as a sibling of `ApplianceHelperPlugin`:

- **voice entry** — the elder opens it by voice ("translate this" in English or Nepali); the
  plugin's entry is session-local command matching in the same shape as the appliance helper's
  entry. The shared intent encoder is **not** retrained and no global intent vocabulary is added
  for this feature.
- **session commands** — at minimum: "read this to me" (FR-LCT-021), the "always show original"
  toggle phrase (FR-LCT-017), and "stop"/close. Commands are session-local, parsed in the plugin's
  session.
- **presentation** — the plugin presents its own full-bleed SwiftUI view; there is one obvious
  close control (≥ 44 pt) that stops the camera session and returns the elder to the assistant.
- **session lifecycle** — backgrounding, a phone call, or an interruption pauses the capture
  session; returning to the foreground resumes it. Overlays for the visible scene reappear from
  the cache without a new cloud request. No overlay state may be silently lost on resume.

#### Acceptance criteria

```gherkin
Feature: Plugin entry and session lifecycle

  Scenario: Voice entry opens live translation
    Given the assistant is listening
    When the elder says "translate this" (or the Nepali equivalent)
    Then the live translation view opens with the camera preview
    And the shared intent encoder has not been retrained or extended for this feature

  Scenario: Interruption pauses and resumes the session
    Given the live translation view is open and showing overlays
    When the app is backgrounded (or a phone call arrives) and then returns to the foreground
    Then the capture session is paused and resumed
    And previously resolved overlays reappear from the cache without a new cloud request

  Scenario: One obvious exit
    Given the live translation view is open
    When the elder taps the close control
    Then the capture session stops
    And the elder returns to the assistant without further prompts
```

#### Related
- FR: FR-LCT-021 (voice reading), FR-LCT-017 (toggle), FR-LCT-001 (preview)
- NFR: NFR-LCT-003 (accessibility), NFR-LCT-004 (localisation), NFR-LCT-012 (no regression)
- Depends on: FR-LCT-001, FR-LCT-002


### FR-LCT-023: Honest degradation — never silently report success

#### Metadata
- **Area:** Error Handling
- **Priority:** MUST
- **Source:** Design §4.2, §8 (error handling table), §4.4 (`degraded`); feature constitution binding rule 7

#### Description
Every degradation path **must** be visible and honest. No path may report success without a
translation, retry-loop, or leave the elder without the information that the text on screen is
not translated:

| Condition | Required behaviour |
|---|---|
| No text in frame | Empty-state hint in the active language; no error surfaced |
| No network / no consent / no budget | Original text plus an "offline"/unavailable indication; the dictionary and cache keep working |
| Transient provider error | At most one retry, then the offline indication |
| Provider policy block | No retry; the offline indication |
| Camera denied | Explanatory screen plus Settings link (FR-LCT-002) |
| Camera session interrupted | Pause and resume; cached overlays persist |
| Speech failure | The visual translation remains; no retry loop |
| App killed while the view is open | Nothing is half-written; the cache is consistent on relaunch |

Timeouts and retry counts are configurable parameters, not hardcoded constants. Deferred or
absent capability is never faked: see FR-LCT-008.

#### Acceptance criteria

```gherkin
Feature: Honest degradation

  Scenario: Offline with no dictionary hit
    Given the device is offline and a recognized string is not in the dictionary or cache
    When the translation tiers resolve
    Then the original text is shown with an offline indication
    And the feature does not block or crash
    And the result reports degraded rather than success

  Scenario: Nothing is silently dropped when a tier fails
    Given a region was sent to the cloud tier and the request failed
    When the overlay is rendered
    Then that region still shows its original text with an honest indication
    And no region with a failure is removed without explanation

  Scenario: Recovery when connectivity returns
    Given the app showed offline indications for unresolved regions
    When connectivity returns and the scene is still visible
    Then the unresolved regions are retried once under the normal consent and cost rules
    And their overlays update to the translation when it arrives
```

#### Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-013 (governor), FR-LCT-018 (overlay states)
- NFR: NFR-LCT-010 (offline degradation integrity), NFR-LCT-011 (configurable parameters)
- Depends on: FR-LCT-003, FR-LCT-009


## Non-functional requirements


### NFR-LCT-001: Overlay responsiveness and translation latency

#### Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Design §2 (latency budget), §5

#### Description
The overlay **must** never make the elder wait on the network or on OCR for feedback:

- **Dictionary hit (tier 0):** translation available in **< 50 ms**, zero network calls.
- **Cache hit:** overlay filled on the first rendered frame that carries the region (no
  "translating…" state shown for a cached string).
- **Cloud miss (tier 2):** the region shows the pending state immediately and is filled within one
  round trip; the design's measured expectation is **1–3 s** for a typical batch, and the
  configured request timeout is the bound. A request that exceeds its timeout must produce the
  degraded state, not an unbounded pending state.
- **Overlay cadence:** overlays update at the OCR cadence (nominally ~4 Hz) and are never blocked
  by an in-flight translation.

#### Acceptance criteria

```gherkin
Feature: Overlay responsiveness

  Scenario: Dictionary hit is effectively instant
    Given a recognized label is in the curated dictionary
    When the region becomes stable
    Then its translation is shown without a pending state
    And no network request is made

  Scenario: A cloud-bound region shows pending immediately and resolves within the timeout
    Given a recognized string is unresolved and consent allows the cloud tier
    When the region becomes stable
    Then the region shows the pending state on the next rendered frame
    And it is filled with the translation or the degraded state within the configured timeout

  Scenario: An overlay is not blocked by an in-flight translation
    Given a translation request is in flight for one region
    When the scene updates with other regions
    Then the other regions' overlays render at the OCR cadence
```

#### Related
- FR: FR-LCT-005, FR-LCT-018, FR-LCT-023
- NFR: NFR-LCT-002 (OCR cadence), NFR-LCT-011 (configurable parameters)


### NFR-LCT-002: OCR cadence, battery and thermal budget

#### Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Design §4.1, §5; addendum Open Decision 11; feature constitution Open Decision 1

#### Description
On-device OCR runs on a throttled frame tap, nominally **~4 fps** on downscaled frames
(`AVCaptureVideoDataOutput` with `videoSettings`), and **must** be implemented as a **configurable
parameter**, not a hardcoded constant. The nominal rate is not yet committed: it requires a
device spike on mid-range hardware before it is fixed (design §10 Open Decision 1), and the
shipped default must be adjustable without a code change beyond that parameter.

The feature **must not** introduce continuous work beyond the throttled OCR, Vision tracking and
overlay rendering: no photo processing, no continuous cloud upload, no background inference. Under
sustained use the app must not trigger iOS thermal throttling or a low-power shutdown of the
camera session: if iOS interrupts the session for thermal or resource reasons, the feature
degrades visibly per FR-LCT-023 rather than failing silently.

#### Acceptance criteria

```gherkin
Feature: OCR cadence and thermal behaviour

  Scenario: OCR runs at the configured cadence
    Given live translation is open
    When frames are sampled for a sustained period
    Then OCR runs at the configured throttle rate (nominal ~4 fps)
    And no frame is submitted to OCR more often than that rate

  Scenario: No continuous cloud or photo work
    Given a scene with no text changes
    When the session is idle
    Then no cloud requests are issued
    And no photo capture or image processing runs

  Scenario: Thermal interruption degrades visibly
    Given iOS pauses or stops the capture session for thermal or resource reasons
    When the session cannot continue
    Then the elder sees an honest degraded state in the active language
    And the app does not crash or silently stall
```

#### Related
- FR: FR-LCT-003, FR-LCT-001, FR-LCT-023
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-011 (configurable parameters)


### NFR-LCT-003: Accessibility — tap targets, overlay text, contrast

#### Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Feature constitution binding rule 6; project constitution Standards (Accessibility); design §6

#### Description
Accessibility is a feature requirement, not polish:

- Every interactive element (translation bubbles, close control, consent prompts) **must** have a
  tap target of at least **44 × 44 pt**.
- Overlay translation text **must** be at least **18 pt**, bold, and high contrast against its
  background; the original-text secondary line must remain legible at the smallest supported
  dynamic type step used by the overlay.
- Bubble backgrounds **must** adapt to light and dark appearance via the existing `DesignTokens`.
- The overlay **must not** obscure the original printed text except under the bounded in-place
  rule (FR-LCT-015), and the pure-callout fallback (FR-LCT-017) must always be available.
- The camera view must remain usable with VoiceOver: each bubble exposes its translation as its
  accessibility label.

#### Acceptance criteria

```gherkin
Feature: Accessibility of the live translation overlay

  Scenario: Tap targets meet the minimum size
    Given a rendered translation bubble or control
    When its hit area is measured
    Then it is at least 44 by 44 points

  Scenario: Overlay text meets the minimum size and contrast
    Given a rendered translation
    When its presented size is inspected
    Then the translation text is at least 18 pt and bold
    And it uses the high-contrast design token for the current appearance

  Scenario: VoiceOver can read a bubble
    Given VoiceOver is enabled
    When the elder focuses a translation bubble
    Then the translation is announced
```

#### Related
- FR: FR-LCT-015, FR-LCT-016, FR-LCT-017
- NFR: NFR-LCT-004 (localisation)


### NFR-LCT-004: Localisation of new UI strings

#### Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution binding rule 8; project constitution Standards (Localisation); design §6

#### Description
All new UI strings introduced by this feature — empty-state hint, pending state, offline
indication, consent copy, cloud-activity label, settings toggle, session command prompts, error
and degraded messages — **must** be externalised in the String Catalog
(`ios/ElderlyAssistant/Resources/Localizable.xcstrings`) with Nepali first, and rendered in the
app's active language. No user-visible string may be hardcoded in a Swift literal.

Overlay translation text and all spoken output **must** use the Devanagari rendering path already
in place; spoken output uses the active-language Piper voice.

#### Acceptance criteria

```gherkin
Feature: Localisation of the feature's strings

  Scenario: New UI strings are externalised
    Given the feature's user-visible strings (empty state, pending, offline, consent, indicator, toggle)
    When the String Catalog is inspected
    Then each string has a catalog entry with a Nepali translation
    And no feature string is hardcoded in the view code

  Scenario: Overlay renders Devanagari in the active language
    Given the active language is Nepali and a translation is resolved
    When the overlay is rendered
    Then the translation is displayed in Devanagari using the app's existing text rendering
```

#### Related
- FR: FR-LCT-018, FR-LCT-023, FR-LCT-021
- NFR: NFR-LCT-003 (accessibility)


### NFR-LCT-005: Privacy — no image or unrelated-content egress

#### Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution binding rule 1; project constitution Architecture Constraint 1 and Open Decision 13 (Scope); design §7

#### Description
The privacy boundary is absolute and measurable:

- **Zero images leave the device** from this feature: no frame, photo, thumbnail, or derived image
  data in any request, at any time, including retries and error paths.
- **Zero unrelated personal content leaves the device**: no health values, contacts, profile,
  calendar, medication, location or device identifiers are attached to a translation request.
- The only content that may leave is the recognized text strings and the language parameters
  needed to translate them (FR-LCT-014), under recorded consent (FR-LCT-010) and within the cost
  governor cap (FR-LCT-013).
- Recognition itself is on-device: OCR performs no network access.

#### Acceptance criteria

```gherkin
Feature: Privacy boundary of the translation egress

  Scenario: A full session with a text-dense scene leaks no image data
    Given consent is recorded and a text-dense scene is translated
    When every outbound request from the session is inspected
    Then no request contains image or media data
    And no request contains health, contacts, profile, calendar or location content
    And every request contains only recognized text plus language parameters

  Scenario: OCR is performed without network access
    Given the device has no network connection
    When recognitions run
    Then recognition completes on-device
    And no network request is attempted for recognition
```

#### Related
- FR: FR-LCT-014 (text-only egress), FR-LCT-001 (no photo output), FR-LCT-003 (on-device OCR)
- NFR: NFR-LCT-006 (log safety), NFR-LCT-007 (consent)


### NFR-LCT-006: Log safety — no recognized or translated text in logs

#### Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution binding rule 5; project constitution release gate (T-049/T-050 precedent); design §7

#### Description
Recognized text and translated text are **user content**: they may not appear in any log, in any
build.

- No raw OCR string, no translated string, and no upstream provider error body may be printed to
  the console, written to a file, or included in telemetry metadata.
- Observability for this feature may record non-content facts only: counts, durations, tier used,
  cache hit/miss, outcome classification.
- `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) **must** cover every new
  log path this feature adds, with the same standard as the existing transcript paths, and must
  exit 0 — this is a build-blocking gate, not a report.

#### Acceptance criteria

```gherkin
Feature: Log safety for translation content

  Scenario: A translated scene produces no content in logs
    Given a Release build translating a text-dense scene
    When the console and log output are inspected
    Then no recognized string appears
    And no translated string appears
    And no upstream error body appears

  Scenario: The release log-safety gate covers the new paths
    Given the feature's logging paths exist in the build
    When `ios/tools/check-release-log-safety.sh` runs
    Then it exits 0
    And it inspects the new OCR/translation paths
```

#### Related
- FR: FR-LCT-003, FR-LCT-009
- NFR: NFR-LCT-005 (privacy), NFR-LCT-013 (release gates)


### NFR-LCT-007: Consent enforcement and auditability

#### Metadata
- **Category:** Compliance / Security
- **Priority:** MUST
- **Source:** Feature constitution binding rules 2 and 3; project constitution Open Decision 13; design §7; workflow security-test focus areas

#### Description
Consent enforcement must be **evidence-producing**, not merely intended:

- **No tier-2 call without recorded consent** — enforced at the single request chokepoint, so no
  code path (including retries, background retries, or a family-config change) can reach the cloud
  tier without it.
- The consent record is stored **on-device**, timestamped, and revocable; revocation takes effect
  for **all subsequent requests** without an app restart.
- The gate is **fail-closed**: an absent, corrupt or unreadable consent record denies the request.
- `security-test` must be able to evidence both the positive case (consent recorded → request
  observed) and the negative case (no consent → zero requests observed, including under a
  dictionary-miss, a batch, and a retry).

#### Acceptance criteria

```gherkin
Feature: Consent enforcement is evidenced

  Scenario: Without consent, zero cloud requests are observed
    Given no consent is recorded
    When a scene full of unresolved strings is processed, including a forced retry path
    Then zero requests reach the cloud provider

  Scenario: With consent, the request is observed and attributed
    Given consent is recorded
    When an unresolved string is processed
    Then a request is observed at the single request chokepoint
    And consent state at request time is auditable

  Scenario: Revocation is enforced immediately
    Given consent is revoked while the feature is open
    When a new unresolved string appears
    Then no request is made
```

#### Related
- FR: FR-LCT-010 (consent gate), FR-LCT-011 (indicator), FR-LCT-012 (revocation)
- NFR: NFR-LCT-005 (privacy), NFR-LCT-013 (compliance gates)


### NFR-LCT-008: Cache at rest — encrypted, keyed, bounded

#### Metadata
- **Category:** Security / Privacy
- **Priority:** MUST
- **Source:** Feature constitution binding rule 10; design §3, §5; workflow security-design-review focus ("persistent cache = user content at rest")

#### Description
The persistent translation cache is user content and must be protected accordingly:

- **Encrypted at rest** using the app's existing `StoragePlacement` / encrypted-storage pattern
  (the same classes used for other user content); no plaintext cache file may exist on disk,
  including temporary files used during writes.
- **Keyed** `(normalizedText|targetLang)` so entries are addressable without storing scene context;
  no image, bounding box, timestamp of the scene, or location is stored alongside the translation.
- **Bounded and evictable**: the general-entry LRU bound (~200 entries) is enforced, so the cache
  cannot grow without limit; dictionary/label entries are effectively non-evicting by policy
  (a recorded policy choice, not an accident of size).
- **Deletable**: removing the feature's stored data (or the app) removes the cache; a corrupt cache
  must be discarded and rebuilt, never crash the feature.

#### Acceptance criteria

```gherkin
Feature: Cache at rest

  Scenario: No plaintext cache on disk
    Given translations have been cached
    When the app container is inspected
    Then no file contains readable translation text

  Scenario: Stored entries carry no scene metadata
    Given a translation is cached
    When the stored entry is inspected
    Then it contains the normalized source text, the target language and the translation only
    And it contains no image, bounding box, scene timestamp or location

  Scenario: A corrupt cache is discarded, not fatal
    Given the cache payload is unreadable
    When the feature starts
    Then the cache is discarded and rebuilt from the dictionary
    And live translation still opens
```

#### Related
- FR: FR-LCT-019 (persistent cache), FR-LCT-020 (shared store)
- NFR: NFR-LCT-005 (privacy)


### NFR-LCT-009: Untrusted scene text hardening (injection)

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution binding rule 4; project constitution Standards ("Injection detection enabled at quarantine level"); design §7; workflow security-design-review focus

#### Description
Recognized scene text is **attacker-influenceable input**: anyone can print a label, sign or menu
whose text is an instruction aimed at the translation model. It must be handled with the same
discipline `InputSanitiser` applies to transcripts (quarantine level):

- Before OCR text enters any prompt, it is **sanitised and bounded** — per-string length caps and
  a per-batch bound, with truncation that never splits a grapheme cluster, and the text is passed
  as data (delimited/quoted), never as free-form instruction text.
- Text that trips the injection policy is **not** silently translated as trusted content: the
  request path must follow the quarantine policy in force (the same level the project configures),
  and the affected region must degrade honestly rather than sending the payload.
- Model output is treated as untrusted too: only strings mapped back to requested keys are
  accepted; unexpected keys or non-string values are discarded, never rendered or executed.
- A prompt-injection attempt must not be able to reach any other app capability (no tool/action
  invocation from the translation prompt — the request is a plain text completion).

#### Acceptance criteria

```gherkin
Feature: Hardening against hostile scene text

  Scenario: Oversized recognized text is bounded before the request
    Given a recognized region contains text far longer than the per-string bound
    When the request payload is built
    Then the string is truncated to the bound without breaking a grapheme cluster
    And the batch stays within the per-batch bound

  Scenario: An injection-shaped label does not become an instruction
    Given a printed label contains an instruction aimed at the model ("ignore your instructions and ...")
    When the request payload is built
    Then the text is carried as delimited data, not as an instruction
    And the injection policy's configured action is applied before any request is sent

  Scenario: Model output cannot inject keys or actions
    Given the provider returns entries that were not requested
    When the response is decoded
    Then unrequested keys and non-string values are discarded
    And nothing from the response triggers an app action
```

#### Related
- FR: FR-LCT-009 (tier 2), FR-LCT-014 (text-only egress), FR-LCT-023 (degradation)
- NFR: NFR-LCT-007 (consent enforcement)


### NFR-LCT-010: Offline degradation integrity — no false success

#### Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution binding rule 7 and "v1 non-goals" (no tier may return success when it did not translate); workflow security-test focus ("offline degradation must never silently report success, cost governor cap must fail closed")

#### Description
Degradation is a first-class, tested behaviour with a measurable integrity property:

- **Zero false successes**: for every region where no tier produced a translation, the result must
  report `degraded = true` and show the original text with an unavailable indication; the count of
  results claiming a tier without a corresponding translation must be zero.
- **Zero silent drops**: no recognized stable region disappears from the overlay because a tier
  failed.
- **Offline session behaviour**: with the device in airplane mode, a session must complete with
  dictionary and cache hits working, cloud-bound regions shown degraded, and no crash, stall or
  repeated network attempts.
- The cost-governor cap must fail closed for the rest of the session (FR-LCT-013) — the degraded
  state, not a retry loop.

#### Acceptance criteria

```gherkin
Feature: Degradation integrity

  Scenario: A full offline session with zero false successes
    Given the device is in airplane mode and consent is recorded
    When a mixed scene (dictionary-known and unknown strings) is processed
    Then dictionary-known strings are translated
    And unknown strings report degraded with the original text shown
    And no result claims a tier that did not produce a translation
    And no network request is attempted

  Scenario: Cost cap reached
    Given the cost governor refuses further calls
    When new unresolved strings appear for the rest of the session
    Then each reports degraded
    And no retry loop or new request is observed
```

#### Related
- FR: FR-LCT-008, FR-LCT-013, FR-LCT-018, FR-LCT-023
- NFR: NFR-LCT-007 (consent), NFR-LCT-011 (configurable parameters)


### NFR-LCT-011: Configurable parameters — no hardcoded operational constants

#### Metadata
- **Category:** Reliability / Maintainability
- **Priority:** SHOULD
- **Source:** Project constitution Agent Principles (design agents: timeouts are configurable parameters, not hardcoded constants); feature constitution binding rule 7; design §8 ("All timeouts configurable parameters")

#### Description
Every operational constant this feature introduces **must** be a named, configurable parameter
with a documented default — not a literal buried in the pipeline. At minimum:

| Parameter | Nominal default | Source |
|---|---|---|
| OCR throttle rate | ~4 fps (device spike gate) | design §10 OD-1 |
| Declutter thresholds (IoU ≥ 0.3, centroid 0.06, region cap 8, merge rule) | as designed | design §10 OD-5 |
| Hysteresis (2 detections / 2 misses) | as designed | design §4.3 |
| Cloud request timeout & retry count (1 retry) | existing `GeminiClient.Config.default` semantics | design §8 |
| In-place rule bounds (≤ 3 words, ≥ 18 pt minimum) | as designed | design §4.5 |
| Cache LRU bound (~200 general entries) | as designed | design §5 |

Changing a parameter must not require editing multiple modules; the same constant must not be
duplicated with divergent values in different layers.

#### Acceptance criteria

```gherkin
Feature: Configurable operational parameters

  Scenario: Changing the OCR cadence requires only the parameter
    Given the OCR throttle rate parameter
    When its value is changed
    Then the sampler uses the new rate with no other code change

  Scenario: Timeouts are not hardcoded
    Given the tier-2 request path
    When the timeout and retry settings are inspected
    Then they resolve from configuration with documented defaults
    And no magic literal for them exists in the request code
```

#### Related
- FR: FR-LCT-006, FR-LCT-009, FR-LCT-013, FR-LCT-005
- NFR: NFR-LCT-001, NFR-LCT-002


### NFR-LCT-012: Shared-component integrity — no regression to the appliance helper

#### Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Agent Principles" (no agent may weaken `ApplianceOverlayMapper` or `ApplianceLabelLocalizer`); design §3

#### Description
This feature extends components that the shipped appliance helper already depends on. It **must
not** change their contracts or behaviour:

- `ApplianceLabelLocalizer` — extended data set only; its exact-match rules, `Display(primary:
  secondary:)` shape and locale gating remain intact. No fuzzy matching is introduced.
- `ApplianceOverlayMapper` — reused unchanged for OCR normalized box → screen point conversion;
  its function contract is not modified.
- `GeminiClient` — the new text-only translation method goes through the existing `send(_:)`
  chokepoint (auth, timeout, observability, cost governor); no parallel request path is added.
- The appliance helper's existing behaviour and tests stay green; the shared cache addition must
  not change its observable outputs.

#### Acceptance criteria

```gherkin
Feature: No regression to the shipped appliance helper

  Scenario: The appliance helper's existing tests still pass
    Given the feature's changes are in the build
    When the appliance helper's existing unit tests run under `ios/build.sh`
    Then they pass unchanged

  Scenario: The shared components' contracts are unchanged
    Given `ApplianceOverlayMapper` and `ApplianceLabelLocalizer` as used by the appliance helper
    When the feature's changes are inspected
    Then their existing public functions and behaviour are unchanged
    And the feature's additions are extensions (new entries, new callers), not modifications

  Scenario: One request chokepoint
    Given the new translation request path
    When outbound requests are traced
    Then they pass through the existing `GeminiClient.send(_:)` chokepoint
    And no alternate request construction bypasses it
```

#### Related
- FR: FR-LCT-007, FR-LCT-020, FR-LCT-009
- NFR: NFR-LCT-005 (privacy)


### NFR-LCT-013: Compliance and release gates

#### Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Open Decision 13 (recorded 2026-09-16) and release gates; feature constitution "Gates"; design §7, §9

#### Description
The feature may ship only with the following gates satisfied and evidenced:

1. **Recorded exception amendment** — Open Decision 13 "Cloud text-translation exception (live
   camera translation)", recorded 2026-09-16 (Owner: Anjan Poudel), exists in the project
   constitution and covers OCR'd text only; the default configuration must not reach tier 2
   without recorded consent.
2. **Consent/disclosure copy reviewed** — the plain-language consent text and the
   `NSCameraUsageDescription` update are drafted and reviewed before the first App Store
   submission, alongside the Open Decision 12 review window (2026-10-13); this half is still open
   (design §10 Open Decision 3).
3. **Release log-safety gate** — `ios/tools/check-release-log-safety.sh` exits 0 and covers the
   new OCR/translation text paths (NFR-LCT-006).
4. **App Store compliance** — camera permission requested at the point of use with plain-language
   explanation; no health data policy exposure (the feature touches no health data).
5. **Security evidence** — `security-design-review` returns `SECURITY-GO` with a STRIDE threat
   model for the camera + cloud-egress surface, and `security-test` returns `SECURITY-GO`
   evidencing consent enforcement, text-only egress and a clean log surface.

#### Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The recorded exception amendment covers the shipped behaviour
    Given the project constitution's Open Decisions
    When the amendment for the cloud text-translation tier is inspected
    Then it is recorded with scope (OCR'd text only), consent, revocation and review terms
    And the shipped default does not reach tier 2 without recorded consent

  Scenario: Release gates are evidenced before sign-off
    Given the feature is ready for sign-off
    When the release checklist is assembled
    Then the log-safety script has exited 0
    And the security reviews have returned SECURITY-GO
    And the consent/disclosure copy review is recorded (or explicitly open for the deadline)
```

#### Related
- FR: FR-LCT-002, FR-LCT-010, FR-LCT-014
- NFR: NFR-LCT-006 (log safety), NFR-LCT-007 (consent)


## Open decisions

Carried forward from the design's §10 and the feature constitution; two additional items were
raised during requirements elicitation. None blocks design work; each has an owner-visible
resolution point.

| # | Decision | Status in this requirement set | Resolve at |
|---|---|---|---|
| 1 | **OCR throttle rate** — ~4 fps nominal needs a device spike on mid-range hardware before commitment | Required as a configurable parameter; nominal value not frozen (NFR-LCT-002, NFR-LCT-011) | implementation on device |
| 2 | **In-place replacement default** — owner approved smart mix with the "always show original text" toggle; default to be confirmed | Requirement binds the toggle's existence and effect, not the default (FR-LCT-017) | first device demo |
| 3 | **Consent/disclosure copy** — the exception amendment is settled and recorded (Open Decision 13, 2026-09-16); drafting and reviewing the copy is outstanding | Recorded as a release gate with the 2026-10-13 review window (NFR-LCT-013, FR-LCT-002) | before `final-sign-off` |
| 4 | **Tier-1 on-device NMT timing** — a *dedicated* NMT model (NLLB-200 distilled 600M) is a v1.1 candidate; the tier itself is not | The tier landed in v1 as the on-device **brain** — the app's own installed Nepali language model, no egress, no consent — by owner directive 2026-09-17 (FR-LCT-008's amendment, which retires the original "must be absent" clause). The dedicated NMT model stays deferred until addendum §13.5's non-goal is revisited | v1.1 planning for the dedicated model — not this workflow |
| 5 | **Menu-mode declutter thresholds** — validated on device; may become per-scene settings | Required as configurable parameters with nominal values (FR-LCT-006, NFR-LCT-011) | manual device testing |
| 6 | **Reverse "phrase card" mode** — out of v1 scope; natural v1.x extension reusing this pipeline | Recorded as out of scope; the pipeline must not assume direction (FR-LCT-003) | not in this workflow |
| 7 | **Cost governor scope** (raised in elicitation) — design §4.4 and Open Decision 13 say "per-session"; the shipped `GeminiCostGovernor` counts calls **per day** with a family-editable cap | Requirement binds the behaviour (bounded calls, fail closed, no retry loop); the mechanism (per-session sub-cap vs per-day cap) is a design decision (FR-LCT-013) | `design-component` |
| 8 | **Shared cache ownership** (raised in elicitation) — the design names the shared store `LabelTranslationCache` (addendum §13.2's in-memory shape), while the feature constitution records that the shared cache does not exist yet and is new work | Requirement states the behaviour (one persistent, encrypted, shared store with the documented key and eviction policy) without fixing a type name (FR-LCT-019, FR-LCT-020) | `design-component` |

## Out of scope

Explicit v1 non-goals, recorded so they are **not** silently half-built (absent, not stubbed):

| Non-goal | Why it is stated |
|---|---|
| NE→EN direction | v1 is English source → Nepali target. The pipeline must not hardcode the direction (FR-LCT-003), but no reversed translation is delivered. |
| Reverse "phrase card" mode (user language → scene language) | Later v1.x mode reusing this pipeline; out of v1 (design §10 OD-6). |
| ARKit world-anchored 3D rendering | Screen-space overlay only; the pipeline stays render-agnostic so a 3D renderer can be added later without touching detection/stabilisation/translation. |
| Auto-speak of every new translation | Noise in multi-label scenes; tap-to-hear and "read this to me" only (FR-LCT-021). |
| Live full-scene explanation ("what does this panel do") | Remains the appliance helper's one-shot `identifyAppliance` call. |
| A dedicated on-device NMT model (NLLB-200 distilled 600M) | v1.1 candidate, blocked until addendum §13.5's non-goal is revisited. The *tier* it was once the only shape of is in v1 as the on-device brain (FR-LCT-008, amended 2026-09-17), and what the deferral protects is unchanged: deferred work must be absent, not a silent stub — `TranslationResult.sourceTier` must always report the tier that actually produced the string, and no tier may return success when it did not translate. |
| Family/caregiver configuration surface for this feature | 100 percent elder-initiated, in the moment. |
| Feed translation changes | The existing feed translation path is untouched by this feature. |

## Divergences carried forward

| # | Prior spec says | This set carries | Status |
|---|---|---|---|
| D1 | Addendum §13.3/§13.5: callout only, no text replacement | Smart mix: in-place replacement only for short dictionary-known labels whose translation fits at ≥ 18 pt; anchored callouts everywhere else; "always show original text" toggle ships with it (FR-LCT-015, FR-LCT-016, FR-LCT-017) | Owner-approved 2026-09-16 |
| D2 | Addendum §13.5: no on-device translation model | **Diverged by owner directive, 2026-09-17**: tier 1 is in v1 as the on-device brain — the app's own installed Nepali language model, running entirely on the device with no egress and no consent (FR-LCT-008, amended; the "must be absent" clause is retired). A *dedicated* on-device NMT model remains a v1.1 candidate against the addendum's non-goal | Owner-approved 2026-09-17; revisit the dedicated model before v1.1 |
| D3 | Addendum §13.2: `LabelTranslationCache` in-memory, no LRU | Persistent encrypted cache, LRU for general text (~200 entries); label-vocabulary entries effectively non-evicting (FR-LCT-019) | New requirement (abroad strings worth persistence) |
| D4 | Base design §0/§5.1: "never obscure/redraw reality" | Preserved for all non-in-place cases; in-place bounded by D1's rule (FR-LCT-016) | Consequence of D1 |
| D5 | Addendum scope: appliance labels | Any printed text, including dense multi-region scenes (a menu page) (FR-LCT-006) | Owner requirement (abroad scenario) |

## How this set is verified downstream

| Gate | What it checks against this set |
|---|---|
| `review-l2` | L2 component design folds in D1/D2 and resolves Open Decisions 1, 2, 5, 7, 8 where resolvable on paper |
| `security-design-review` | STRIDE for the camera + cloud-egress surface; focus areas map to NFR-LCT-005/007/008/009 and FR-LCT-010/011/013/014 |
| `security-test` | Evidence: consent enforcement (NFR-LCT-007), text-only egress (NFR-LCT-005/FR-LCT-014), clean log surface (NFR-LCT-006), offline degradation never reporting success (NFR-LCT-010/FR-LCT-023), governor cap failing closed (FR-LCT-013) |
| `final-sign-off` | Recorded exception amendment (Open Decision 13), consent copy review, camera purpose string (FR-LCT-002), log-safety gate (NFR-LCT-006/NFR-LCT-013) |
