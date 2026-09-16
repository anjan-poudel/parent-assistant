# Constitution — Live Camera Translation

> **Feature-scoped constitution.** It is merged *on top of* the project constitution
> (`constitution.md`) and `.ai-sdd/constitution.md`, so it adds and tightens rules for this
> feature only. It does not repeal anything project-level: the on-device inference constraint,
> the accessibility standards, the log-safety release gates, the security review gates and the
> Agent Principles all still apply. Where this document is silent, the project constitution governs.

Source of truth for the design: `docs/superpowers/specs/2026-09-16-live-camera-translation-design.md`
(first-pass component design, approved by the project owner 2026-09-16, awaiting spec review).
It inherits from `docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md` and its
addendum `docs/superpowers/specs/2026-09-05-appliance-helper-live-ar-and-local-knowledge-addendum.md` §13.

## Feature Purpose

The user points the camera at anything printed — an appliance panel, a remote, packaging, a sign,
a menu in a foreign country — and sees the text overlaid with a translation into the app's active
language, live, without ever taking a photo and without leaving the camera view. The feature ships
as a new voice-invokable plugin (`LiveTranslatePlugin`), sibling to the appliance helper, sharing
that helper's label dictionary and translation cache.

Primary user: elderly Nepali speakers (60+), including the senior-abroad scenario. Success = the
user reads an English appliance panel or a foreign menu **unassisted** — no photo, no screenshot,
no English literacy.

## Scope

**v1 (in scope):** English source text → Nepali target. Live `AVCaptureSession` preview (no photo
output configured). On-device OCR with automatic language detection. Translation tiers: tier 0
curated dictionary → tier 2 text-only cloud call, consent-gated. Smart-mix overlay (in-place
replacement for short dictionary-known labels, anchored callouts otherwise). Tap-to-hear and
"read this to me" via the existing Piper voices. Persistent translation cache. Any printed text,
including dense multi-region scenes (a menu page).

**v1 non-goals (must not be silently half-built):** NE→EN direction; reverse "phrase card" mode;
ARKit world-anchored 3D rendering; auto-speak of every new translation; live full-scene
explanation ("what does this panel do" stays the appliance helper's one-shot call); the on-device
NMT tier (tier 1 — a v1.1 candidate, and it may not land until addendum §13.5's non-goal is
revisited). Deferred work must be **absent**, not a silent stub: `TranslationResult.sourceTier`
must always report the tier that actually produced the string, and no tier may return success
without having translated.

## Binding Feature Rules

1. **Text only may leave the device — never images.** The cloud tier sends recognized text for
   translation and nothing else. The camera session configures no photo output at all, and no
   `inlineData`/image part may be attached to a translation request. No health, contacts, or
   profile content is included, ever.

2. **The cloud tier is consent-gated, and the gate is the feature's compliance basis.**
   Explicit user consent at the first cloud need, plain-language disclosure at the point of
   selection, a visible indicator while a cloud tier is active, and revocation that degrades the
   feature to dictionary-only offline mode — it must never block the feature or leave the user
   with nothing. This mirrors the project's Open Decision 12 (B7) exception for the cloud voice
   stack, which is the binding precedent for shape and wording.

3. **The exception amendment is a release gate.** The text-only cloud translation tier requires a
   *recorded* constitution exception amendment (owner action: Anjan Poudel), in the Open
   Decision 12 shape and appended to the project constitution's Open Decisions. Until it is
   recorded, the cloud tier must not ship: `final-sign-off` must verify the amendment exists, and
   the default configuration must not reach tier 2 without recorded consent. This constraint comes
   from the feature brief verbatim — it is a blocking gate, not a report.

4. **OCR text is untrusted input.** Scene text is attacker-influenceable (a malicious label or
   menu is an injection vector into the cloud prompt). It is sanitised and bounded on the way into
   the prompt with the same discipline `InputSanitiser` applies to transcripts.

5. **Recognized text and translated text are user content.** No raw OCR text, no translated
   string, and no upstream error body may be printed to a log in any build. `ios/tools/check-release-log-safety.sh`
   (wired into `ios/build.sh`) must cover every new path this feature adds, with the same standard
   as T-049/T-050.

6. **Accessibility is a feature requirement, not a polish item.** Tap targets ≥ 44 pt; overlay text
   ≥ 18 pt, bold, high contrast; light/dark adaptive via existing `DesignTokens`. The overlay must
   not obscure the original text except under the bounded in-place rule (short dictionary-known
   labels whose translation fits at ≥ 18 pt — an owner-approved divergence, D1), and the
   "always show original text" toggle must ship with it as the pure-callout fallback.

7. **Offline and failure behaviour is explicit and visible.** Tier 0 (dictionary) works fully
   offline. When no tier can resolve: show the original with an "offline" badge — never silently
   drop, never retry-loop, never report success. The cost governor fails closed for the rest of
   the session on cap. Every timeout is a configurable parameter, not a hardcoded constant.

8. **Localisation.** All new UI strings are externalised in the String Catalog with Nepali first;
   Devanagari rendering support is already in place and must be used for overlay text.

9. **The pipeline stays render-agnostic and language-direction-agnostic.** Detection,
   stabilisation, translation and caching must not assume the renderer, and adding a target
   language or the reverse direction must be model/prompt work — not architecture work.

10. **The cache is user content at rest.** Persistent, encrypted (existing `StoragePlacement`
    pattern), keyed `(normalizedText|targetLang)`, seeded from the dictionary, LRU (~200 entries)
    for general text. Label-vocabulary entries effectively do not evict.

## Standards

**Testing.** Pure-logic unit coverage is required for `TextRegionStabilizer` (hysteresis,
decluttering, change events), cache LRU/seeding, dictionary extension (exact whole-label match —
no fuzzy matching), overlay mapper math (new cases only; the function's contract is unchanged),
the Gemini batch prompt builder, in-flight dedupe, plugin command parsing, and the consent-gate
state machine. Integration tests run the full pipeline against a **stubbed tier-2 transport** —
no live network in tests — plus Vision OCR against fixture images on the simulator. Build and test
gate: `ios/build.sh` (which runs `xcodebuild test`; do not use bare `xcodebuild build`).

**Security.** STRIDE threat model at `security-design-review`, with the focus areas listed in the
feature workflow (injection via scene text, consent bypass, image egress, cache at rest, cloud
indicator). `security-test` must evidence consent enforcement, text-only egress, and log safety.

**Release gates.** `ios/tools/check-release-log-safety.sh` exits 0 and covers the new OCR /
translation text paths; consent and disclosure copy reviewed; camera purpose string
(`ios/ElderlyAssistant/Info.plist`, `NSCameraUsageDescription` — currently describes medication
verification and appliance photos only) updated to disclose live translation and the conditional
cloud text send.

**Known integration surface (for design and task breakdown).**
`ios/ElderlyAssistant/Services/Appliance/ApplianceLabelLocalizer.swift` (tier 0, extended to
~120 curated entries), `ApplianceOverlayMapper.swift` (coordinate math reused unchanged),
`ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift` (new text-only `translateStrings` on the
existing `send(_:)` request chokepoint, reusing `GeminiCostGovernor.swift`),
`ios/ElderlyAssistant/Services/Plugins/ApplianceHelperPlugin.swift` (the plugin/session/command
template — session-local commands, **no intent-encoder retraining**),
`ios/ElderlyAssistant/App/AppCoordinator.swift` (plugin registry + voice entry). The shared
translation cache does not exist yet — it is new work for this feature.

## Gates

| Gate | Task | Verified |
|---|---|---|
| Design review | `review-l2` | L2 component design is GO (folds in D1/D2 divergences and §10 decisions) |
| Security design | `security-design-review` | `SECURITY-GO` with STRIDE for the new camera + egress surface |
| Implementation | `implement` | Paired review, confidence ≥ 0.85, ≤ 5 rework iterations |
| Security test | `security-test` | `SECURITY-GO`: consent enforcement, text-only egress, log surface clean |
| Owner sign-off | `final-sign-off` | **T2 human gate**: exception amendment recorded, consent copy reviewed, purpose string updated, log-safety gate passing |

## Open Decisions

Carried from the design document (§10) — none of these block starting the workflow; each has an
owner-visible resolution point.

1. **OCR throttle rate.** ~4 fps nominal (addendum OD-11). Needs a device spike on mid-range
   hardware before it is committed; must land as a configurable parameter either way.
   Resolve at: implementation on device.
2. **In-place replacement default.** Owner approved smart mix (D1) with the "always show original
   text" toggle shipping alongside. Confirm the default at the first device demo.
   Resolve at: first device demo.
3. **Consent copy and exception amendment wording.** Draft alongside the Open Decision 12 review
   cycle (its time box expires 2026-10-13). Owner: Anjan Poudel.
   Resolve at: before `final-sign-off`.
4. **Tier-1 (on-device NMT) timing.** v1.1 candidate (NLLB-200 distilled 600M). Requires
   revisiting addendum §13.5's non-goal before any model work; the CoreML conversion is its own
   SDD task. Resolve at: v1.1 planning — **not** in this workflow.
5. **Declutter thresholds.** The §4.3 numbers (IoU ≥ 0.3, centroid distance 0.06, 8-region cap,
   longest-string merge) are nominal. Validate on device against a dense menu page; they may
   become per-scene settings. Resolve at: manual device testing.
6. **Reverse "phrase card" mode.** Out of v1 scope; a natural v1.x extension reusing this
   pipeline (show the waiter a phrase in their language). Not in this workflow.

## Agent Principles (feature-scoped, binding)

The project's Agent Principles apply unchanged — `complete-task` is the only completion
mechanism, output paths are contracts, no silent stubs, explicit error return types, configurable
timeouts. In addition for this feature: **no agent may add a cloud call path that is not behind
the consent gate**, and **no agent may weaken the contract of `ApplianceOverlayMapper` or
`ApplianceLabelLocalizer`** — both are shared with the shipped appliance helper and are extended,
not modified.

## Artifact Manifest

<!-- AUTO-GENERATED by ai-sdd engine after each task — do not edit this section -->
