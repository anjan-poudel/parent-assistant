# Requirements — Live Camera Translation

Feature: `live-camera-translation` (worktree branch `worktree-live-camera-translation`).
Status: **awaiting owner HIL sign-off** (the `define-requirements` task carries a HIL gate).
Task: `define-requirements`, agent `ba`, contract `requirements_doc` + `requirements_lock`.

## Summary
- Functional requirements: **23**
- Non-functional requirements: **13**
- Areas covered: Camera Capture, Text Detection, Region Stabilisation, Translation, Privacy &
  Consent, Cost Governance, Overlay, Caching, Voice Output, Plugin & Session, Error Handling;
  NFR categories: Performance, Accessibility, Localisation, Privacy, Security, Reliability,
  Compliance
- v1 scope: English source → Nepali target; live `AVCaptureSession` preview with no photo output;
  on-device OCR with automatic language detection; tier 0 curated dictionary → tier 2 text-only
  cloud call (consent-gated); smart-mix overlay; tap-to-hear and "read this to me"; persistent
  translation cache; new voice-invokable `LiveTranslatePlugin` sharing the appliance helper's
  dictionary and cache; dense multi-region scenes (a menu page).
- Sources of truth: `docs/superpowers/specs/2026-09-16-live-camera-translation-design.md`
  (owner-approved first-pass component design), the project `constitution.md` (Architecture
  Constraint 1, Open Decision 13 recorded 2026-09-16), `specs/live-camera-translation/constitution.md`
  (feature constitution), and the inherited design + addendum §13.

## Contents
- [FR/index.md](FR/index.md) — functional requirements (23 files, `FR-LCT-001` … `FR-LCT-023`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (13 files, `NFR-LCT-001` … `NFR-LCT-013`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

### Functional requirements
Camera & capture: [FR-LCT-001](FR/FR-LCT-001-live-camera-preview.md),
[FR-LCT-002](FR/FR-LCT-002-camera-permission-and-disclosure.md) ·
Detection & stabilisation: [FR-LCT-003](FR/FR-LCT-003-on-device-ocr-language-detection.md),
[FR-LCT-004](FR/FR-LCT-004-region-tracking-between-ocr-passes.md),
[FR-LCT-005](FR/FR-LCT-005-region-stabilisation-hysteresis.md),
[FR-LCT-006](FR/FR-LCT-006-decluttering-dense-scenes.md) ·
Translation: [FR-LCT-007](FR/FR-LCT-007-dictionary-tier-0.md),
[FR-LCT-008](FR/FR-LCT-008-truthful-tier-attribution.md),
[FR-LCT-009](FR/FR-LCT-009-cloud-tier-text-only-translation.md) ·
Consent & cloud governance: [FR-LCT-010](FR/FR-LCT-010-consent-gate.md),
[FR-LCT-011](FR/FR-LCT-011-cloud-activity-indicator.md),
[FR-LCT-012](FR/FR-LCT-012-consent-revocation-offline-mode.md),
[FR-LCT-013](FR/FR-LCT-013-cost-governor-fails-closed.md),
[FR-LCT-014](FR/FR-LCT-014-text-only-egress.md) ·
Overlay: [FR-LCT-015](FR/FR-LCT-015-smart-mix-in-place-replacement.md),
[FR-LCT-016](FR/FR-LCT-016-anchored-callouts.md),
[FR-LCT-017](FR/FR-LCT-017-always-show-original-toggle.md),
[FR-LCT-018](FR/FR-LCT-018-overlay-progress-and-failure-states.md) ·
Cache: [FR-LCT-019](FR/FR-LCT-019-persistent-encrypted-cache.md),
[FR-LCT-020](FR/FR-LCT-020-shared-cache-and-dictionary.md) ·
Voice & session: [FR-LCT-021](FR/FR-LCT-021-tap-to-hear-and-read-this-to-me.md),
[FR-LCT-022](FR/FR-LCT-022-plugin-voice-entry-and-session.md) ·
Degradation: [FR-LCT-023](FR/FR-LCT-023-honest-degradation-and-offline.md)

### Non-functional requirements
[NFR-LCT-001](NFR/NFR-LCT-001-overlay-responsiveness.md) responsiveness ·
[NFR-LCT-002](NFR/NFR-LCT-002-ocr-cadence-and-thermal-budget.md) OCR cadence/thermal ·
[NFR-LCT-003](NFR/NFR-LCT-003-accessibility-standards.md) accessibility ·
[NFR-LCT-004](NFR/NFR-LCT-004-localisation.md) localisation ·
[NFR-LCT-005](NFR/NFR-LCT-005-no-image-or-unrelated-content-egress.md) privacy/egress ·
[NFR-LCT-006](NFR/NFR-LCT-006-log-safety.md) log safety ·
[NFR-LCT-007](NFR/NFR-LCT-007-consent-enforcement-and-auditability.md) consent evidence ·
[NFR-LCT-008](NFR/NFR-LCT-008-cache-at-rest.md) cache at rest ·
[NFR-LCT-009](NFR/NFR-LCT-009-untrusted-scene-text-hardening.md) injection hardening ·
[NFR-LCT-010](NFR/NFR-LCT-010-offline-degradation-integrity.md) degradation integrity ·
[NFR-LCT-011](NFR/NFR-LCT-011-configurable-parameters.md) configurability ·
[NFR-LCT-012](NFR/NFR-LCT-012-shared-component-integrity.md) no regression ·
[NFR-LCT-013](NFR/NFR-LCT-013-compliance-and-release-gates.md) compliance gates

## Open decisions
Carried forward from the design's §10 and the feature constitution. None blocks design work; each
has an owner-visible resolution point.

| # | Decision | Status in this requirement set | Resolve at |
|---|---|---|---|
| 1 | **OCR throttle rate** — ~4 fps nominal needs a device spike before commitment | Required as a configurable parameter; nominal value not frozen (NFR-LCT-002, NFR-LCT-011) | implementation on device |
| 2 | **In-place replacement default** — smart mix with the "always show original text" toggle; default value to be confirmed | Requirement binds the toggle's existence and effect, not the default (FR-LCT-017) | first device demo |
| 3 | **Consent/disclosure copy** — the exception amendment is recorded (OD-13, 2026-09-16); the copy review is outstanding | Recorded as a release gate with the 2026-10-13 review window (NFR-LCT-013, FR-LCT-002) | before final-sign-off |
| 4 | **Tier-1 on-device NMT timing** — v1.1 candidate; requires revisiting addendum §13.5's non-goal | Recorded as a v1 non-goal and as an explicit "absent, not stubbed" requirement (FR-LCT-008) | v1.1 planning (not this workflow) |
| 5 | **Menu-mode declutter thresholds** — validated on device; may become per-scene settings | Required as configurable parameters with nominal values (FR-LCT-006, NFR-LCT-011) | manual device testing |
| 6 | **Reverse "phrase card" mode** — out of v1 scope | Recorded as out of scope; the pipeline must not assume direction (FR-LCT-003 note, out-of-scope list) | not in this workflow |
| 7 | **Cost governor scope** (raised in this elicitation) — design §4.4 and OD-13 say "per-session", the shipped `GeminiCostGovernor` counts **per day** with a family-editable cap | Requirement binds the behaviour (bounded, fail closed, no retry loop); the mechanism is a design decision (FR-LCT-013) | design-component |
| 8 | **Cache-shape naming** (raised in this elicitation) — design calls the shared store `LabelTranslationCache` while the feature constitution says the shared cache does not exist yet and must be new work | Requirement states the behaviour (single shared, persistent, encrypted store) without fixing the type name (FR-LCT-019, FR-LCT-020) | design-component |

## Out of scope
Explicit v1 non-goals — recorded so they are **not** silently half-built (absent, not stubbed):

- **NE→EN direction** — v1 is English source → Nepali target; the pipeline must not hardcode the
  direction (FR-LCT-003), but no reversed translation is delivered.
- **Reverse "phrase card" mode** (show the waiter a phrase in their language) — later v1.x mode.
- **ARKit world-anchored 3D rendering** — screen-space overlay only; the pipeline stays
  render-agnostic so a 3D renderer can be added later.
- **Auto-speak of every new translation** — tap-to-hear and "read this to me" only (FR-LCT-021).
- **Live full-scene explanation** ("what does this panel do") — remains the appliance helper's
  one-shot `identifyAppliance` call.
- **The on-device NMT tier (tier 1)** — a v1.1 candidate (NLLB-200 distilled 600M, many-to-many),
  blocked until addendum §13.5's non-goal is revisited. `TranslationResult.sourceTier` must always
  report the tier that actually produced the string, and no tier may return success when it did
  not translate (FR-LCT-008).
- **Family/caregiver configuration surface for this feature** — elder-initiated, in the moment.
- **Feed translation changes** — the existing feed translation path is untouched by this feature.

## Divergences carried forward
| # | Prior spec says | This set carries | Status |
|---|---|---|---|
| D1 | Addendum §13.3/§13.5: callout only, no text replacement | Bounded in-place replacement (dictionary-known, ≤ 3 words, fits ≥ 18 pt) + callout everywhere else + "always show original" toggle (FR-LCT-015/016/017) | Owner-approved 2026-09-16 |
| D2 | Addendum §13.5: no on-device translation model | v1 identical (no model); tier 1 absent and recorded as a v1.1 candidate (FR-LCT-008) | Owner-approved 2026-09-16; revisit before v1.1 |
| D3 | Addendum §13.2: `LabelTranslationCache` in-memory, no LRU | Persistent encrypted cache with LRU for general text; labels effectively non-evicting (FR-LCT-019) | New requirement |
| D4 | Base design §0/§5.1: "never obscure/redraw reality" | Preserved for all non-in-place cases; in-place bounded by D1 (FR-LCT-016) | Consequence of D1 |
| D5 | Addendum scope: appliance labels | Any printed text, including dense multi-region scenes (FR-LCT-006) | Owner requirement (abroad scenario) |

## Related
- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
