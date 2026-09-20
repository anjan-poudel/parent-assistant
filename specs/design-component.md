# L2 Component Design — Live Camera Translation (EN → NE, v1)

**Feature:** `live-camera-translation` · **Branch:** `worktree-live-camera-translation`
**Task:** `design-component` (agent `pe`) · **Contract:** `component_design_l2` → `specs/design-component.md`
**Date:** 2026-09-16 · **Status:** for `review-l2`

**Inputs folded in.** `specs/define-requirements.md` + `specs/define-requirements/index.md` (23 FR /
13 NFR) and the lock `specs/define-requirements.lock.yaml`; the owner-approved first-pass design
`docs/superpowers/specs/2026-09-16-live-camera-translation-design.md` (§3 cache, §4 components, §4.4
cost, §8 errors, §10 open decisions, §11 divergences); the feature constitution
`specs/live-camera-translation/constitution.md`; the project `constitution.md` (Architecture
Constraint 1, Open Decision 13, Release gates, Agent Principles); and the shipped code this design
must match — `GeminiCostGovernor`, `GeminiClient`, `GeminiConfigStore`, `ApplianceLabelLocalizer`,
`ApplianceOverlayMapper`, `ApplianceCache`, `ApplianceHelperPlugin`, `ApplianceHelperView`,
`EncryptedLocalStorage` / `StoragePlacementPolicy`, `InputSanitiser`, `SpeakQueue`, `Announcer`,
`ObservabilityBus` / `ErrorCodeMapper`, `AssistantPlugin` / `PluginRegistry`.

**What this document is.** The reviewable L2 fold of the first-pass design: the component
decomposition, the contracts (with explicit error types), the failure/retryability matrix per
asynchronous operation, the configurable parameters with their defaults, and the enforcement points
for the security-critical invariants. It is not an implementation and adds no scope.

---

## Overview

### 1. Purpose and outcome

The elder points the camera at anything printed — an appliance panel, a remote, packaging, a sign,
a restaurant menu abroad — and reads it in the app's active language (`AppLanguage`, `ne` at
launch), live, overlaid on a full-bleed camera preview, **without a photo ever being taken and
without an image ever leaving the device**.

The feature is a new voice-invokable plugin, `LiveTranslatePlugin`, sibling to the shipped
`ApplianceHelperPlugin`. It detects printed text on-device (Vision), stabilises the detections into
stable regions with stable identifiers, resolves their text through a two-tier ladder (curated
on-device dictionary → consent-gated, text-only cloud translation), caches every resolved string in
one persistent encrypted store shared with the appliance helper, and renders a **smart-mix**
overlay: bounded in-place replacement for short dictionary-known labels, anchored callouts for
everything else.

The pipeline is deliberately **language-direction-agnostic and render-agnostic** (feature
constitution rule 9): source language comes from Vision's automatic detection, the target language
comes from `AppLanguage`, and nothing below the view layer knows what draws the result. That is what
makes the "senior abroad, any language → Nepali" roadmap model/prompt work rather than architecture
work.

### 2. Scope

**In v1 (delivered by this design).**

- Live `AVCaptureSession` preview with **no photo output configured at all** (FR-LCT-001).
- On-device OCR with automatic language detection, plus rectangle tracking between OCR passes
  (FR-LCT-003, FR-LCT-004).
- Region stabilisation with two-sided hysteresis and change-only events (FR-LCT-005), and
  decluttering for dense multi-region scenes (FR-LCT-006).
- Tier 0 curated dictionary (FR-LCT-007); tier 2 text-only, consent-gated, batched, deduplicated
  cloud translation (FR-LCT-009); truthful attribution with no success without a translation
  (FR-LCT-008).
- Consent gate, revocation, cloud-activity indicator, cost-governor fail-closed (FR-LCT-010 …
  FR-LCT-013), text-only egress (FR-LCT-014).
- Smart-mix overlay: bounded in-place replacement, anchored callouts, the "always show original
  text" toggle, pending/degraded states (FR-LCT-015 … FR-LCT-018).
- One persistent encrypted translation cache shared with the appliance helper (FR-LCT-019,
  FR-LCT-020).
- Tap-to-hear and session command "read this to me" through the shipped Piper voices (FR-LCT-021).
- Voice entry, session lifecycle, honest degradation (FR-LCT-022, FR-LCT-023).

**Absent by design (not stubbed).** The following are v1 non-goals and the design makes them
**structurally unrepresentable** rather than present-but-disabled:

| Absent capability | How absence is enforced |
|---|---|
| On-device NMT tier (tier 1) — D2, FR-LCT-008 | `TranslationTier` has exactly two cases (`dictionary`, `cloud`). There is no case to return, no branch to take, no passthrough that could claim it. Adding it in v1.1 is a new enum case plus a new resolution step — deliberately a visible change. |
| Reverse "phrase card" direction (user language → scene language) — OD6 | No direction flag exists; the pipeline carries `sourceLanguage?` per string and `targetLanguage` only. Nothing can be reversed without new API. |
| ARKit / world-anchored 3D rendering | `LiveOverlayPlacement` is a pure function of screen-space rects; no world coordinates enter the pipeline. |
| Auto-speak of every new translation | The only call sites of `Announcement` construction in this feature are the tap handler and the "read this to me" handler. There is no observer that speaks on resolution. |
| Live full-scene explanation | Nothing in this feature calls the appliance helper's one-shot guidance path; that stays its own call. |
| Family/caregiver configuration surface | `LiveTranslateConfig` has no UI. It is a single injectable value with code defaults. |
| Feed translation changes | No shared component in this design is on the feed path. |

### 3. Divergences carried forward (D1–D5)

These are inherited from the requirement set and the first-pass design and are **not re-litigated
here**; the design implements them as written.

**D1 — Smart-mix overlay (owner-approved 2026-09-16).** The addendum mandates callout-only. This
design replaces printed text **in place only** under all of the following, which are implemented as
an explicit, testable predicate (§C11) — not a heuristic and not an "replace when it seems to fit":

1. the translation came from **tier 0 only** (`TranslationTier.dictionary`);
2. the source string is **short** — at most `inPlaceMaxSourceWordCount` words (default **3**);
3. the translated string **fits** the region at **≥ `overlayMinPointSize` points** (default
   **18 pt**); and
4. the "always show original text" setting is off.

**Everything else uses the anchored callout**, which must not cover its own region's printed text.
The "always show original text" toggle ships alongside and reduces the overlay to pure callout mode.
D1 is the only case in which the overlay may cover the original print, and condition 4 makes it
user-reversible on the next rendered frame.

**D2 — On-device NMT deferred; v1 identical to the addendum (owner-approved 2026-09-16).** v1 ships
no translation model. Tier 1 is **absent, not stubbed** (see §2) — `TranslationResult.sourceTier`
is `nil` unless a tier actually produced the string, so no path can claim a tier it did not use. The
v1.1 candidate (NLLB-200 distilled 600M via the project's CoreML export pipeline) is recorded as
direction only and requires revisiting addendum §13.5's non-goal before any model work.

**D3 — `LabelTranslationCache` generalized (new requirement).** The addendum's in-memory,
never-evicting cache becomes a persistent encrypted store with an LRU bound for general text
(§C05). Labels stay effectively non-evicting.

**D4 — "never obscure/redraw reality" preserved.** The base design's §0/§5.1 principle holds for
every case except D1's bounded in-place rule. Witnessed in the design by: the callout-never-covers
constraint, the toggle, and the fact that the degraded state always shows the original text.

**D5 — Scope widened from appliance labels to any printed text**, including dense multi-region
scenes. Witnessed by the decluttering rules (§C03) and the batched cloud request (§C08).

### 4. Open decisions

**Resolved by this design.** Both are binding owner directives from the 2026-09-16 sign-off; the
resolutions below are the ones the owner stated, not alternatives.

**OD7 — Cost governor scope → RESOLVED: the shipped per-day `GeminiCostGovernor`, unmodified, with
its family-editable cap. No new per-session governor.** The first-pass design's "per-session cap"
wording is **superseded**. The binding is the per-day budget the app already enforces at the single
transport chokepoint (`GeminiClient.send(_:)` throws `GeminiClientError.dailyCapReached` *before*
any network work). This design adds only a **session-scoped fail-closed latch**: once the governor
refuses a tier-2 attempt during a live-translation session, that session stops attempting cloud
translation for its remainder and reports every cloud-bound region as degraded. See §C15. The cap
value is not a constant invented here — it is `GeminiCostGovernor.softDailyCap`
(`defaultSoftDailyCap = 200`, family-editable in the range 10 … 1000, clamped on load). Its
persistence key `gemini.costGovernor.v1` and its semantics ("the cost is the attempt", counted at
the transport boundary) are unchanged.

> **Owner follow-up (recorded, not performed here).** The requirement text at FR-LCT-013 and the
> project constitution's Open Decision 13 still say "per-session". The owner will amend that wording
> separately. **No agent may edit Open Decision 13 or `constitution.md` as part of this workflow** —
> it is hash-locked downstream and the amendment is an owner action.

**OD8 — Cache-shape naming → RESOLVED: the name stays `LabelTranslationCache`. No rename.** It is
**generalized** to be persistent, encrypted and dictionary-seeded, exactly as the first-pass design
§3 requires. The type name is kept even though the addendum's in-memory shape never shipped; the
requirement set deliberately does not fix a type name, and keeping the documented name avoids a
rename churn across the design, addendum and roadmap. See §C05 for the generalized shape.

**Recorded, deliberately unresolved here** (each has an owner-visible resolution point):

| # | Decision | Status in this design | Where it is recorded | Resolve at |
|---|---|---|---|---|
| OD1 | OCR throttle rate | Implemented as the single parameter `ocrSampleInterval` with nominal default `0.25 s` (≈4 fps). Not frozen; the value is a device-spike output, not a design commitment. | §C14, §Interfaces → Configurable parameters | device spike (implementation) |
| OD2 | In-place replacement default | The toggle exists and its effect is fully specified; the **default** is the parameter `alwaysShowOriginalDefault`, shipped as `false` (smart mix on) and confirmed at the first device demo. | §C11, §C14 | first device demo |
| OD3 | Consent / disclosure copy review | The consent gate is fully designed; the **copy** is a `String Catalog` entry set plus the `NSCameraUsageDescription` update, both of which are release-gate items, not implementation blockers. Consent records are version-stamped (`consentDisclosureVersion`) so a copy change can invalidate a stale grant. | §C09, §C13, §Components → Observability & release gates | before `final-sign-off` (2026-10-13 window) |
| OD5 | Menu-mode declutter thresholds | Implemented as named parameters with the design's nominal values (`regionMatchIoU = 0.3`, `declutterMergeCentroidDistance = 0.06`, `declutterMaxRegions = 8`, longest-string merge). Nominal only. | §C03, §C14 | manual device testing |
| OD4 | Tier-1 on-device NMT timing | Out of scope for this workflow. The requirement is that tier 1 is **absent, not stubbed**, which §2 and §C04 enforce structurally. | §2, §C04 | v1.1 planning (not this workflow) |
| OD6 | Reverse "phrase card" mode | Out of scope for this workflow. The pipeline must not assume a direction, which §Overview.1 and §C04's API satisfy. | §2, §C04 | not in this workflow |

### 5. Architecture and data flow

```
  Voice ("translate this" / "अनुवाद गर्ने") or a Home tile
      │
      ▼
  LiveTranslatePlugin.handle(_:context:)        → .spokenAndPresented
      │  presentationView(for:) builds the session + @MainActor view model
      ▼
  LiveCameraSession                              [captureQueue]
      │  AVCaptureVideoPreviewLayer (.resizeAspect), no photo output configured
      │  AVCaptureVideoDataOutput → downscaled CVPixelBuffer
      │  frame tap throttled to ocrSampleInterval; dropped, not queued, while OCR is busy
      ▼
  LiveTextDetector                               [visionQueue]
      │  tracking pass on sampled frames (VNTrackRectangleRequest) → box positions
      │  OCR pass at the cadence (VNRecognizeTextRequest, auto language detection)
      │  → DetectedTextRegion { text, normalizedBox, detectedLanguage, confidence }
      ▼
  TextRegionStabilizer                           [pure struct, owned by the pipeline actor]
      │  geometry + normalized-string matching → stable RegionID
      │  hysteresis: appear after 2 detections, remove after 2 misses
      │  declutter: merge / cap → at most declutterMaxRegions
      │  emits RegionChangeEvent ONLY on text change (the traffic gate)
      ▼
  LiveTranslationPipeline (actor)
      │
      ├─► CACHE/DICTIONARY LAYER  ── LabelTranslationCache.lookup(text:targetLanguage:)
      │     curated dictionary layer (shared with the appliance helper, read-through)
      │     persisted cloud layer   (encrypted file, LRU-bounded)
      │        ├── hit  → TranslationResult.resolved(text:, tier: <origin>)   [no network]
      │        └── miss ↓
      ├─► CONSENT LAYER ── LiveTranslateConsentGate.authorize()   [fails closed]
      │        └── not granted → TranslationResult.degraded(reason: .consentNotGranted)
      ├─► COST LAYER ── GeminiCostGovernor.allowsCall()  +  session latch
      │        └── refused → TranslationResult.degraded(reason: .costBudgetExhausted)
      └─► TIER 2 ── CloudTranslationTier (actor)
             sanitise + bound → batch → in-flight dedupe → ONE request
             GeminiClient.translateStrings(items:targetLanguage:)  → send(_:) chokepoint
             → resolved / degraded per item; latch on cap
      │
      ▼
  @MainActor LiveTranslateViewModel
      │  overlay state: regions, outcomes, placement, cloud indicator, consent sheet
      ▼
  LiveOverlayPlacement (pure)  →  LiveTranslateOverlayView (screen space, over the preview)
      │  in-place (tier 0 + ≤3 words + fits ≥18 pt + toggle off)  |  anchored callout
      │  tap on a bubble
      ▼
  SpokenOutput → Announcement(.interactive) → SpeakQueue → Piper voice (active language)
```

**Latency contract (NFR-LCT-001).** Tier-0 dictionary hit: no network, target < 50 ms. Cache hit:
filled on the first rendered frame carrying the region — no pending state is shown for a cached
string. Cloud miss: pending state on the next rendered frame, terminal state within the configured
deadline. Overlays render at the OCR cadence and are never blocked by an in-flight translation: the
translation tiers run off the render path, and the view model is updated from a terminal state
change, never awaited by the renderer.

### 6. Component inventory and source layout

New sources live under the areas the project's test-impact mapping already mirrors, so the impact
gate covers new suites without a mapping change.

| ID | Component | Source path | Test path |
|---|---|---|---|
| C01 | `LiveCameraSession` | `Services/LiveTranslate/` `LiveCameraSession.swift` | `Services/LiveTranslate/` |
| C02 | `LiveTextDetector` | `Services/LiveTranslate/` `LiveTextDetector.swift` | `Services/LiveTranslate/` |
| C03 | `TextRegionStabilizer` | `Services/LiveTranslate/` `TextRegionStabilizer.swift` | `Services/LiveTranslate/` |
| C04 | `TranslationResult` / `TranslationTier` | `Services/LiveTranslate/` `TranslationResult.swift` | `Services/LiveTranslate/` |
| C05 | `LabelTranslationCache` | `Services/LiveTranslate/` `LabelTranslationCache.swift` | `Services/LiveTranslate/` |
| C06 | `LabelDictionary` (tier-0 extension) | `Services/Appliance/` `ApplianceLabelLocalizer.swift` (data extension only) | `Services/Appliance/` |
| C07 | `SceneTextSanitiser` | `Services/LiveTranslate/` `SceneTextSanitiser.swift` | `Services/LiveTranslate/` |
| C08 | `CloudTranslationTier` + `GeminiClient+Translate` | `Services/LiveTranslate/` `CloudTranslationTier.swift`, `Services/Gemini/` `GeminiClient+Translate.swift` | `Services/LiveTranslate/`, `Services/Gemini/` |
| C09 | `LiveTranslateConsentGate` | `Services/LiveTranslate/` `LiveTranslateConsentGate.swift` | `Services/LiveTranslate/` |
| C10 | `CloudActivityIndicatorModel` | `Services/LiveTranslate/` `CloudActivityIndicatorModel.swift` | `Services/LiveTranslate/` |
| C11 | `LiveOverlayPlacement` + overlay views | `Services/LiveTranslate/` `LiveOverlayPlacement.swift`, `App/LiveTranslate/` `LiveTranslateOverlayView.swift` | `Services/LiveTranslate/` |
| C12 | `LiveTranslateCommandParser` + `SpokenOutput` | `Services/LiveTranslate/` `LiveTranslateCommandParser.swift` | `Services/LiveTranslate/` |
| C13 | `LiveTranslatePlugin` + `LiveTranslateSessionModel` | `Services/Plugins/` `LiveTranslatePlugin.swift`, `App/LiveTranslate/` `LiveTranslateView.swift` | `Services/Plugins/`, `App/` |
| C14 | `LiveTranslateConfig` + `LiveTranslateSettings` | `Services/LiveTranslate/` `LiveTranslateConfig.swift` | `Services/LiveTranslate/` |
| C15 | Cost-governor integration (no new type) | `Services/LiveTranslate/` `CloudTranslationTier.swift` (latch) | `Services/LiveTranslate/` |

**Shared components this feature extends but must not weaken** (NFR-LCT-012, feature Agent
Principles): `ApplianceLabelLocalizer` (data extension only — its exact-match rules,
`Display(primary:secondary:)` shape and `isNepali` gate are untouched), `ApplianceOverlayMapper`
(reused unchanged), `GeminiClient` (one new method on the existing `send(_:)` chokepoint),
`GeminiCostGovernor` (consumed, not modified), `PluginRegistry` (one more registration).

### 7. Concurrency, isolation, and deregistration

Isolation is stated per shared resource. There is no unsynchronised shared mutable state.

| Resource | Writers | Readers | Isolation mechanism |
|---|---|---|---|
| `AVCaptureSession` (start/stop/configure) | `captureQueue` | `captureQueue` | dedicated serial queue; all mutations from the same queue |
| Video output frames | `videoOutputQueue` → pipeline | pipeline actor | serial queue; an `ocrPassInFlight` flag **drops** a sampled frame rather than queueing it (bounded memory and a natural throttle) |
| Vision requests / `VNSequenceRequestHandler` | `visionQueue` | `visionQueue` | serial queue, one pass at a time |
| `TextRegionStabilizer` state | pipeline actor | pipeline actor | it is a `struct` owned exclusively by the actor; value semantics + actor isolation |
| `LabelTranslationCache` index + payload | any thread | any thread | `NSLock`-guarded index; persistence coalesced on a serial `persistenceQueue` (see below) |
| `LiveTranslateConsentGate` record | main (user action) / lock | request path (lock) | `NSLock`; every read is read-through and **fails closed** |
| In-flight key set (dedupe) | tier actor | tier actor | `NSLock` + an atomic `beginIfAbsent(_:)` check-and-insert so two concurrent passes cannot both fire |
| Session cost latch | tier actor | tier actor | monotone `Bool` under the same lock as the in-flight set |
| Cloud-activity indicator | main | main | `@MainActor` `ObservableObject` |
| Overlay / view-model state | main | main | `@MainActor` |
| Speech | main | `SpeakQueue` worker | the shipped `SpeakQueue` arbitration (unchanged) |

**Deregistration paths** (designed alongside registration, not after):

- **Session lifecycle.** `LiveCameraSession.stop()` on close: stop the session, remove the
  `UIApplication` background/foreground observers, cancel the frame stream continuation, and
  `LiveTextDetector.end()` releases the Vision request handler. No observer outlives the view.
- **In-flight keys.** Every `beginIfAbsent(_:)` has a matching `end(_:)` in a `defer`, including
  cancellation and error paths — a failed or cancelled request can never wedge a key into
  permanent "in flight", which would make a string permanently untranslatable.
- **Consent revocation.** Deletes the consent key, flips the in-memory mirror under the lock, and
  cancels in-flight tier-2 tasks (their regions terminate as degraded). No new request may be
  issued after the revoke returns.
- **Cache entries.** LRU eviction of general entries; the feature-data delete path removes the
  storage key wholesale; an unreadable payload is discarded and rebuilt from the dictionary layer
  (never fatal).
- **Plugin registration.** `PluginRegistry` has no deregistration API today and this feature adds
  none — the plugin registers once at `AppCoordinator.start()`. Relying on absence of a
  deregistration path would be a defect; the plugin therefore holds **no cross-session state**: all
  per-session state lives in the session model built by `presentationView(for:)`.

### 8. Requirements traceability

Every requirement maps to a named component and, where it is a behaviour, to a test seam in
§Interfaces.

| Requirement | Satisfied by |
|---|---|
| FR-LCT-001 live preview, no photo output | C01 (`AVCaptureVideoDataOutput` only; no `AVCapturePhotoOutput` is ever constructed; no frame is written to disk) |
| FR-LCT-002 camera permission + disclosure | C01 (`start()` returns `.cameraPermissionDenied` / `.cameraPermissionNotDetermined`), C13 (explanatory screen + Settings link), `Info.plist` `NSCameraUsageDescription` |
| FR-LCT-003 on-device OCR, auto language detection | C02 (`automaticallyDetectsLanguage`, `detectedLanguage` per observation; no network in the recognition path) |
| FR-LCT-004 tracking between OCR passes | C02 (`trackingPass`, `trackedBoxes`; tracked geometry only, text changes only on an OCR pass) |
| FR-LCT-005 stabilisation, hysteresis, change-only events | C03 |
| FR-LCT-006 decluttering for dense scenes | C03 (merge rule, region cap; both configurable) |
| FR-LCT-007 tier 0 curated dictionary | C06 (data extension, exact whole-label match, no fuzzy), C05 (read-through dictionary layer) |
| FR-LCT-008 truthful tier attribution, no false success | C04 (`TranslationOutcome` makes tier-1 attribution and degraded-with-a-tier unrepresentable) |
| FR-LCT-009 tier 2 text-only, batched, deduped, retry ≤ 1 | C08 + C07 |
| FR-LCT-010 consent gate, fail closed | C09 |
| FR-LCT-011 cloud-activity indicator | C10 (state derived only from the in-flight registry) |
| FR-LCT-012 revocation → dictionary-only offline | C09 (+ C05: cached entries stay usable — no egress needed) |
| FR-LCT-013 cost governor bound + fail closed | C15 |
| FR-LCT-014 text-only egress | C08 (the only translation request builder; text parts only) |
| FR-LCT-015 bounded in-place replacement | C11 (`LiveOverlayPlacement.forms`) |
| FR-LCT-016 anchored callouts, never covering the original | C11 |
| FR-LCT-017 "always show original text" toggle | C11 + C14 (`alwaysShowOriginal`), C12/C13 (touch + voice reachability) |
| FR-LCT-018 pending / resolved / degraded overlay states | C04 (`TranslationOutcome`) + C11 |
| FR-LCT-019 persistent encrypted cache, seeded, LRU | C05 |
| FR-LCT-020 shared dictionary and cache | C05 + C06 |
| FR-LCT-021 tap-to-hear and "read this to me" | C12 |
| FR-LCT-022 plugin voice entry and session lifecycle | C13 |
| FR-LCT-023 honest degradation | C04 + C08 + C15 + C23 table in §Interfaces |
| NFR-LCT-001 overlay responsiveness and latency | render path never awaits a tier; §Interfaces → Configurable parameters |
| NFR-LCT-002 OCR cadence, battery, thermal | C01 + C02 (`ocrSampleInterval`, backpressure, `thermalCadenceFactor`) |
| NFR-LCT-003 accessibility | C11 + C13 (≥ 44 pt targets, ≥ 18 pt bold, `DesignTokens`, VoiceOver labels) |
| NFR-LCT-004 localisation | all new strings in the String Catalog; C12 phrase table; no Swift-literal user-visible strings |
| NFR-LCT-005 no image or unrelated-content egress | C01 (no photo output) + C08 (text-only builder) |
| NFR-LCT-006 log safety | §Components → Observability (content-free event schema) + `check-release-log-safety.sh` coverage |
| NFR-LCT-007 consent enforcement and auditability | C09 |
| NFR-LCT-008 cache at rest | C05 |
| NFR-LCT-009 untrusted scene text hardening | C07 + C08 (response validation, no tools on the request) |
| NFR-LCT-010 offline degradation integrity | C04 + C15 (`degraded` count vs. tier claims is zero by construction) |
| NFR-LCT-011 configurable parameters | C14 (single owner of every default) |
| NFR-LCT-012 no regression to the appliance helper | §C05/C06 sharing rules + §Components → Technical risks R8 |
| NFR-LCT-013 compliance and release gates | §Components → Observability & release gates |

---

## Components

### C01 — `LiveCameraSession`

Owns the capture stack. Configures **video data output only**: there is no `AVCapturePhotoOutput`,
no `UIImagePickerController`, and no code path that writes frame bytes to the photo library, app
storage, or a temporary file (FR-LCT-001, NFR-LCT-005). The preview is an
`AVCaptureVideoPreviewLayer` with `videoGravity = .resizeAspect`, full-bleed, which is what lets the
shipped `ApplianceOverlayMapper` aspect-fit math apply unchanged (NFR-LCT-012).

Frame delivery is an `AsyncStream<CameraFrame>` where `CameraFrame` carries an in-memory
downscaled `CVPixelBuffer` (via `videoSettings`). The buffer is used for OCR and released; nothing
retains it beyond the pass. The tap is throttled to `ocrSampleInterval` and **drops** rather than
queues while a pass is in flight — this is simultaneously the cadence control and the memory bound
(NFR-LCT-002).

Lifecycle: `start()` requests permission at the point of use (FR-LCT-002) and returns an explicit
result; `pause()` / `resume()` are driven by `UIApplication` background/foreground notifications so
the session is never running in the background; `stop()` tears everything down. A system
interruption or a thermal pause surfaces as an honest degraded state in the view, never a silent
stall (NFR-LCT-002 scenario 3).

Failure modes: permission not yet asked (the caller shows the explanation, then re-calls `start()`);
permission denied (explanatory screen + Settings deep link — the shipped pattern
`UIApplication.openSettingsURLString`, used in `HomeSubviews` / `LeafViews`); no capture device or
configuration failure (degraded, not retryable in-process); interruption (retryable — the session
resumes on foreground).

### C02 — `LiveTextDetector`

Wraps Vision on a serial queue. Two distinct request kinds, deliberately not interchangeable:

- **Tracking pass** (`VNTrackRectangleRequest` over the previous pass's boxes) runs on sampled
  frames and produces **geometry only**. It carries a region's screen position between OCR passes so
  the overlay does not visibly jump at the OCR cadence (FR-LCT-004).
- **OCR pass** (`VNRecognizeTextRequest`, `automaticallyDetectsLanguage = true`) runs at the cadence
  and produces observations. This is the **only** source of recognized text: a tracked box never
  changes a region's text, and a tracking loss falls back to the last OCR-confirmed geometry rather
  than dropping or moving the overlay (FR-LCT-004's second scenario).

Recognition is entirely on-device; no model is downloaded, and no network request is made for
recognition (FR-LCT-003, NFR-LCT-005). When a pass yields no observations the caller shows the
empty-state hint and **no error** (FR-LCT-003). A failed pass is dropped without surfacing anything
to the elder; the next pass simply tries again.

`automaticallyDetectsLanguage` is an iOS 16-and-later capability and the app's deployment target
supports it; the design nevertheless keeps a capability check and, when the detected language is
unavailable, omits it from the tier-2 request rather than inventing a value. The pipeline never
hard-codes the source language (FR-LCT-003, feature rule 9).

### C03 — `TextRegionStabilizer`

Pure, deterministic, time-free logic — `struct` with mutating consumption, owned exclusively by the
pipeline actor. Everything it needs is passed in, so scripted frame sequences reproduce exactly in
unit tests. It emits `RegionChangeEvent` **only when a region's recognized text changes** (including
first appearance); this single gate is what bounds translation traffic (FR-LCT-005, design §2).

Matching: geometry (IoU ≥ `regionMatchIoU`, default **0.3**, or centroid distance within
`regionMatchCentroidDistance`) combined with **normalized-string equality**. A geometry match with a
different string is a text change on the same region, not a new region — that keeps the region
identifier and its overlay stable while the text updates.

Hysteresis (both directions, FR-LCT-005): a region appears after `regionAppearPasses` consecutive
detections (default **2**) and is removed after `regionMissPasses` consecutive misses (default
**2**). A single missed pass leaves the region and its translation intact.

Decluttering (FR-LCT-006), applied before emission so the render and the translation request see the
same set:

1. Regions with the **same normalized string** whose normalized centroids are closer than
   `declutterMergeCentroidDistance` (default **0.06**) on **either** axis merge into one region whose
   text is the **longest** string of the merged set. The merged region's box is the union of the
   merged boxes so the overlay still points at all of them.
2. If more than `declutterMaxRegions` (default **8**) regions remain, the highest-confidence ones are
   kept, tie-broken by centroid `y` then `x` for determinism.
3. Every kept region produces **exactly one** overlay. Duplicate callouts for the same text are
   structurally impossible because the merge happens before emission.

Every threshold is a `LiveTranslateConfig` parameter, not a literal (NFR-LCT-011, OD5).

Normalization (shared with the cache key): trim, collapse internal whitespace, case-fold. This is
identical to the key normalization used by `LabelTranslationCache`, so a region's text maps to
exactly one cache key. It is deliberately **not** extended with stemming or synonym folding — a
near-miss must not be served as if it were an exact match (FR-LCT-007).

### C04 — `TranslationResult`, `TranslationTier`, `TranslationOutcome`

This is where FR-LCT-008 and NFR-LCT-010 become structural rather than procedural. The first-pass
design's flat `struct TranslationResult { text, sourceTier, isFinal, degraded }` permits an
inconsistent value: a non-optional `sourceTier` forces a degraded result to name a tier that did not
translate. This design keeps the documented accessors but makes the **outcome enum the single source
of truth**, so the inconsistent states cannot be constructed:

- `TranslationTier` has exactly two cases: `.dictionary` (tier 0) and `.cloud` (tier 2). There is
  **no case for the deferred on-device NMT tier** (D2, FR-LCT-008 scenario 4). Ordinal tier
  numbering exists only in prose and in observability metadata, never as an enum case or a
  reservation.
- `TranslationOutcome` is `pending` / `resolved(translation:tier:)` /
  `degraded(originalText:reason:)`. A resolved outcome is the **only** way to obtain a non-nil
  `sourceTier`, and `sourceTier` is `nil` for pending and degraded — so "a tier that did not
  translate" is not nameable.
- `degraded` is true only for `.degraded`; `isFinal` is false only for `.pending`. `text` is the
  translation when resolved and the **original recognized text** otherwise, so the honest fallback
  is the default rather than something a caller must remember to apply.
- `TranslationUnavailableReason` carries the *reason*, never upstream text: `noNetwork`,
  `providerNotConfigured`, `consentNotGranted`, `costBudgetExhausted`, `providerRejected`,
  `textQuarantined`, `deadlineExceeded`, `noTierResolved`.

State transitions are monotonic: a region's outcome moves `pending → resolved` or
`pending → degraded` and never returns to `pending` while the region's text is unchanged
(FR-LCT-018). A text change produces a new outcome for the same region id; the previous outcome is
replaced, not merged.

### C05 — `LabelTranslationCache` (OD8: name kept, shape generalized)

One shared store, two layers, one name.

**Layer A — curated dictionary layer (read-through, not materialised on disk).** The store answers
from `ApplianceLabelLocalizer.dictionary` for any key the curated set contains. This satisfies
FR-LCT-019's "seeded from the curated dictionary, so the first use of a known label is already a
hit" **without writing curated data to disk**: a freshly installed app resolves a known label with
zero network and zero prior history because the seed is a lookup, not a copy. It also gives
FR-LCT-020's sharing property for free and by construction: the appliance helper's tier-0
translations and live translation's tier-0 translations are the **same table** (see C06), so a label
the appliance helper has rendered is available to live translation with no network call.

**Layer B — persisted cloud layer.** Cloud-resolved strings, stored encrypted under a single storage
key (the `EncryptedLocalStorage` protocol has no key enumeration, so one key holding the whole
payload is the established pattern — `ApplianceCache`, `GeminiCostGovernor`). `StoragePlacementPolicy`
places the key on the **encrypted file** channel (Application Support, Data Protection Complete,
excluded from backups), because the key is not in the keychain-resident allow-list. No plaintext
file is ever written, including no temporary file: the payload is encoded and handed to the storage
implementation, which performs its own atomic protected write.

**Key.** `normalizedText|targetLanguageCode` — exactly the addendum §13.2 key, with the same
normalization as C03. Stored entries carry the key, the translation, the LRU ordering field and
nothing else. **Deliberately absent**: any image, bounding box, scene timestamp, camera or device
identifier, or location (NFR-LCT-008 scenario 2).

The LRU ordering field is a **monotone counter** (`lastAccessSequence`), not a wall-clock timestamp
and not the earlier draft's `lastAccessedAt` (AM-6). A touch happens on lookup — that is, while the
text is on camera — so a timestamp written there would record, coarsely, when that text was last in
front of the camera: scene-derived metadata of exactly the kind NFR-LCT-008 scenario 2 forbids, and
one that survives into the next session. A counter preserves LRU ordering exactly (monotone
increments give the same comparisons) and stores nothing derived from the scene. The counter is
restored above the payload's maximum on load, so ordering stays total across sessions.

**Eviction.** `cacheGeneralEntryLimit` (default **200**) bounds the persisted layer by LRU. Tier-0 /
dictionary-resident entries are **non-evicting by policy**, not by size: the eviction predicate asks
the dictionary layer whether a key is curated, so the policy is a recorded decision and cannot
silently drift as the curated set grows. Entries whose key is curated are therefore never chosen as
LRU victims regardless of the LRU bound.

**Read path cost.** LRU touching is coalesced: a key is touched at most once per session
(`cacheTouchCoalescing`), because the overlay renders at the OCR cadence and rewriting the whole
payload on every frame would be a real thermal and battery cost (NFR-LCT-002). Dictionary-layer hits
touch nothing at all.

**Failure behaviour (self-healing, never fatal).** An unreadable or corrupt payload is discarded and
the store rebuilds from the dictionary layer; the feature still opens (NFR-LCT-008 scenario 3). A
write failure is non-fatal: the resolved translation is still rendered from the in-memory index, and
the next successful write persists it. Cache failures are never surfaced to the elder as errors —
the cache accelerates the feature and must never break it.

**Threading.** `NSLock`-guarded in-memory index (the shipped `GeminiCostGovernor` pattern), with
persistence coalesced on a serial queue. Concurrent readers are the live-translation pipeline and
the appliance helper's label presentation seam; the only writer is the live-translation tier-2
completion path plus the seed/LRU upkeep. One lock means a single writer at a time; no reader can
observe a partially-written payload because persistence writes the whole value.

**Feature-data removal.** Deleting the storage key removes the cache. Consent revocation does **not**
clear it (FR-LCT-012 scenario 3: cached translations remain usable — they are already on the device
and require no egress).

### C06 — `ApplianceLabelLocalizer` extension (tier 0)

Extended **by data only**, to the design's target of ~120 curated EN → NE entries covering appliance,
remote and general printed-label vocabulary. The extension is additive under an explicit rule: the
47 entries shipped today keep their exact keys and values, pinned by a test that fails if any
existing value changes. That is what makes NFR-LCT-012's "extensions, not modifications" checkable
rather than aspirational.

The localizer's contract is untouched: exact whole-label match after trim + case-fold, **no fuzzy or
substring matching**, pass-through for text already in Devanagari, the `Display(primary:secondary:)`
shape, and the `isNepali(locale)` gate. Two consequences the implementer must respect:

- The dictionary is **not reversible**. It already maps several English keys onto one Nepali value
  (for example two keys for "cold/cool", two for "source/input"). Any reverse lookup built from it
  would be ambiguous — the design forbids building one.
- A near-miss (different case, spacing or wording beyond the defined normalization) must not be
  reported as a tier-0 hit (FR-LCT-007 scenario 2).

The localizer's `dictionary` static is Layer A of `LabelTranslationCache`. Live translation gains one
new **caller-side** resolver at the appliance helper's label presentation seam, with the localizer's
result taking precedence whenever the localizer produces a translation, so **every label the helper
translates today renders identically** — the claim is about the labels the localizer actually
translates (a known, curated label), not about every label the helper displays. A label the localizer
*passes through* is not covered by that sentence: if the live path has already persisted a
translation for it, the seam now renders that translation instead of the printed English. That is the
one behavioural delta, it is recorded in R8, and it is pinned by
`ApplianceHelperLabelSeamTests.testR8CaseTwoACachePopulatedLabelRendersTheCachedTranslation` (whose
sibling cases `testR8CaseOneADictionaryKnownLabelRendersExactlyAsBeforeTheSeam` and
`testR8CaseThreeTheLocalizerWinsOverTheCacheWhenBothWouldAnswer` pin the unchanged case and the
precedence). Nothing else about the helper changes: no cloud tier, no consent gate, no cost latch,
no overlay behaviour — shared dictionary and shared storage, not shared translation policy.

### C07 — `SceneTextSanitiser`

Recognized scene text is **attacker-influenceable input**: anyone can print a label, sign or menu
whose text is shaped like a directive aimed at the translation model (feature constitution rule 4,
NFR-LCT-009). It is therefore sanitised and bounded before it can reach a request, with the same
discipline `InputSanitiser` already applies to transcripts at quarantine level — the project's
configured injection level.

`SceneTextSanitiser.sanitiseForEgress(_:)` returns an explicit verdict, never a bare string:

- `.sendable(text)` — the sanitised, bounded text may enter the request payload.
- `.truncated(text)` — the text exceeded `sceneTextMaxLength` (default **120** characters) and was
  cut to the bound. Truncation operates on `String.prefix(_:)`, which in Swift counts **extended
  grapheme clusters**, so it cannot split a Devanagari cluster or a conjunct — the regression the
  project has already pinned once for Nepali substring handling. Truncated text is still sent; the
  truncation is not a quarantine.
- `.quarantined(reason)` — the string still matches the shipped marker table after sanitisation.
  This is **detect-only** use of `InputSanitiser`'s marker table (referenced by name; the marker
  list is deliberately not reproduced in this document). The affected region **degrades honestly**
  (`TranslationUnavailableReason.textQuarantined`) and the payload is **not** sent. That is the
  configured quarantine policy in force: the text is not silently translated as if it were trusted
  content.

Bounding is per string **and** per batch: at most `cloudBatchMaxStrings` (default **12**) strings and
`cloudBatchMaxCharacters` (default **1200**) total per request. When a scene exceeds the bound, the
pipeline splits into multiple sequential batches rather than silently dropping strings, and the
pending state covers the whole set until each batch terminates.

The payload is carried as **data inside a delimited block**, never as free-form instruction text: the
request tells the model what the block is and that its contents are content to translate, and it
carries the strings in a structured array with per-item identifiers and an optional detected source
language. Nothing is concatenated into the instruction region of the request. Combined with the fact
that the request carries **no tools** (see C08), an embedded directive in scene text cannot reach any
other app capability — the request is a plain text completion with no action surface.

### C08 — `CloudTranslationTier` and `GeminiClient+Translate`

`GeminiClient.translateStrings(items:targetLanguage:)` is a **new method on the existing
`send(_:)` chokepoint** — same auth handling, same timeout, same observability, same cost governor.
It constructs `GeminiRequest` contents from `.text` parts only. There is no image, media or
`inlineData` part on this path, and the API deliberately exposes no parameter through which one could
be attached (FR-LCT-014, NFR-LCT-005). It sets **no tools** — in particular no search grounding — so
the translation request has no capability to invoke.

Wire shape:

- `generationConfig.responseMimeType = "application/json"`, consistent with the existing
  `generateJSON` path.
- Each item is `{ id, text, sourceLanguage? }` where `id` is a short opaque token (a per-request
  index), `text` is the sanitised string, and `sourceLanguage` is Vision's detected language or
  omitted.
- The response is expected as an object keyed by `id`. Index keying (rather than keying by source
  text) keeps the payload small, makes duplicate-source handling unambiguous, and makes output
  validation trivial.

`CloudTranslationTier` (an actor) orchestrates, in this order:

1. **Validate the request is needed** — every string is un-resolved by the cache/dictionary layer.
2. **Sanitise and bound** via C07; quarantined strings never enter the payload and are returned as
   degraded immediately.
3. **Consent** via C09 — fail closed.
4. **Budget** via C15 — the session latch and the shipped governor's `allowsCall()`.
5. **In-flight dedupe** — `beginIfAbsent(keys)` atomically claims the unresolved keys; keys already
   in flight are **not** re-requested and resolve when the existing request completes (FR-LCT-009
   scenario 2).
6. **One batched request** for the claimed keys (FR-LCT-009 scenario 1).
7. **Decode and validate the response.** Only requested ids are accepted; only string values are
   accepted; a translation longer than a sane bound (a small multiple of the source length plus a
   fixed allowance) is rejected as unusable rather than rendered. Everything else is discarded and
   never rendered or acted on (NFR-LCT-009).
8. **Store** validated translations in C05.
9. **Release** every claimed key in a `defer`.

**Failure classification and retry.** Retry policy is centralised here, never at the call site:

- *Transient* (retried **at most once**, per `cloudMaxRetries = 1`): transport timeout, offline /
  connection-lost, HTTP 408 / 429, HTTP 5xx, malformed response, empty response. The single retry
  re-uses the same text-only payload shape, so the egress guarantee holds on the retry path
  (FR-LCT-014 scenario 3).
- *Not retried*: provider policy refusal, provider not configured, invalid request, HTTP 4xx other
  than 408/429, deadline exceeded. Each terminates the affected regions as degraded.
- *Never retried within the session*: cost budget exhausted — the latch closes (C15).

**Deadline.** The tier wraps the call in a task with a deadline derived from the client's configured
`timeoutSeconds` — `GeminiClient.Config.default.timeoutSeconds` (25 s, the shipped value) plus
`cloudDeadlineGraceSeconds` (default 5). The base timeout has exactly **one** source of truth (the
client's config); the grace is a separate named parameter, not a duplicated constant. Exceeding the
deadline terminates the regions as degraded rather than leaving an unbounded pending state
(NFR-LCT-001 scenario 2).

### C09 — `LiveTranslateConsentGate`

The compliance basis of the feature (feature constitution rule 2). One record, read at the point of
use, **fails closed**.

**Record** (`ConsentRecord`): `granted`, `recordedAt` (timestamped, per NFR-LCT-007),
`disclosureVersion`. The version stamp matters: it binds a grant to the disclosure copy that was
shown, so a reviewed-and-changed copy can invalidate a stale grant rather than silently inheriting
it. This is the design's hook for OD3 — the copy review changes a string and a version constant, not
the gate's logic.

**Decisions returned by `currentDecision()`:** `granted` / `notRecorded` / `denied` / `unreadable`.
`notRecorded`, `denied` and `unreadable` all deny. There is **no default-on path**: nothing about
using the feature, opening the camera, or the family having configured a provider key implies
consent, and no configuration value can reach tier 2 without a record.

**Prompt timing.** The prompt is presented at the **first cloud need**, in the active language, as a
plain-language explanation before any request is sent — not buried in settings, and not on session
open (a dictionary-only scene never shows it). While the prompt is on screen, no request is in
flight and the cloud indicator is off. Because it is user-driven it has **no timeout**: it is a
blocking consent decision, and an auto-dismiss would be an implicit consent, which the requirement
forbids. This is stated as an explicit exception to the "timeouts are configurable parameters"
principle — the parameter does not exist because a value for it would be wrong.

**Revocation.** Reachable from the session view and from Settings. It takes effect for all subsequent
requests without a restart: the record is deleted, the in-memory mirror is flipped under the lock,
and any in-flight tier-2 task is cancelled (its regions terminate as degraded). The requirement's
floor is "no further request is made"; cancelling in flight is the stronger, honest choice. After
revocation the feature continues with tier 0 and cached translations, and unresolved strings keep
their original text with an honest unavailable indication — the feature is never blocked
(FR-LCT-012).

**Evidence.** Every decision point emits a content-free event (see §Observability), so
`security-test` can evidence both the positive case (consent recorded → a request observed) and the
negative case (no consent → zero requests observed, including under a dictionary miss, a batch, and
the retry path).

### C10 — `CloudActivityIndicatorModel`

A `@MainActor` observable whose only input is the tier's **in-flight request counter**. It appears
when the counter goes from zero to one and disappears when it returns to zero, driven by the tier's
`defer`-released registry, so the indicator cannot disagree with reality.

Consequences enforced by construction:

- It is **not** settable from the settings layer, the overlay layer, or the dictionary-only path.
  The "always show original text" toggle changes the overlay form and nothing else — it cannot hide
  the indicator (FR-LCT-011 scenario 3).
- It has **no minimum-dwell timer**. A lingering indicator after the request resolved would be a
  false statement about cloud activity, which is exactly what FR-LCT-011 forbids; flicker on a very
  fast response is the honest display of a very fast response.
- It renders as a symbol **plus** a plain-language label in the active language (not an icon alone).
  The label's final wording is part of the OD3 copy review; the design fixes only its semantics and
  its localisation requirement.

### C11 — `LiveOverlayPlacement` and the overlay view

`LiveOverlayPlacement` is a pure function of screen-space geometry — no camera state, no renderer,
no world coordinates (feature rule 9). It consumes stable regions, their outcomes, the container
size, the frame's pixel size, the already-placed button rects, and a text-measuring closure; it
returns the placement for every region. Being pure, it is directly unit-testable against scripted
rect sets, which is where the D1 predicate and the callout-never-covers rule are validated.

**In-place eligibility (D1, FR-LCT-015) — all conditions required:**

1. `outcome` is `.resolved` and its `tier == .dictionary` (a cloud translation is never drawn in
   place, even when it would fit);
2. the normalized source string has at most `inPlaceMaxSourceWordCount` words (default **3**);
3. the translation **fits the region rect at ≥ `overlayMinPointSize` points** (default **18**) with
   the same font and attributes the view will render with — the measurement and the render must not
   diverge, so both go through one shared measurer; and
4. `alwaysShowOriginal` is off.

When eligible, the translation is drawn in place with an opaque, high-contrast background **sized to
the region**. Otherwise the region gets an **anchored callout**.

**Callout constraints (FR-LCT-016).** A callout is a pill with a leader line to its region, showing
the translation as primary text (≥ 18 pt, bold, high contrast via the existing `DesignTokens`) and
the original recognized text as smaller secondary text. The hard constraint is that **a callout must
not cover its own region's printed text**. Candidate anchors are tried in a deterministic order
(above, below, right, left), and among those that satisfy the hard constraint the placement prefers
the one that overlaps the fewest other regions, then the one nearest the region. Where no candidate
satisfies the hard constraint (a genuinely full screen), the pill is clamped inside the safe area on
the side with the most free space — and that geometric corner case is recorded as a manual
device-validation item under OD5, not silently accepted.

Overlay states (FR-LCT-018) are per region and driven by `TranslationOutcome`: `.pending` renders the
"translating…" state with the original text still accessible; `.resolved` renders the translation;
`.degraded` renders the **original text** with an honest unavailable/offline indication and never a
translated-looking string. Degradation is never a removed overlay: no recognized stable region
disappears because a tier failed (NFR-LCT-010).

Accessibility (NFR-LCT-003): every bubble and control has a ≥ 44 × 44 pt hit target; translation text
is ≥ 18 pt bold; colours come from `DesignTokens` so light/dark adaptation is inherited; each bubble
exposes its translation as its accessibility label. The toggle path (pure callout mode) is always
available, so the "never obscure" fallback is one touch away.

### C12 — Spoken output: tap-to-hear and "read this to me"

Two entry points, both explicit, both ending in the shipped `Announcement(.interactive)` →
`SpeakQueue` path with the active-language Piper voice:

- **Tap-to-hear** — tapping a bubble speaks **that** region's translation and nothing else.
- **"read this to me"** — speaks the visible regions' translations **top-to-bottom**: sort by the
  region's normalized box `midY` ascending, tie-broken by `midX`, then speak sequentially. "stop"
  halts the reading.

**Nothing is spoken automatically.** There is no observer on resolution and no `didSet` that
enqueues speech; the only two construction sites of an `Announcement` in this feature are the tap
handler and the command handler. That is how the "no auto-speak" non-goal is enforced structurally
rather than by convention.

Speech failure degrades exactly as the shipped `SpeakQueue` already does: the visual translation
stays on screen, no retry loop starts, and no error is surfaced as a blocking state (FR-LCT-021,
FR-LCT-023).

In-session commands are parsed **locally and deterministically** by `LiveTranslateCommandParser`
against a small phrase table (English and Nepali forms, externalised in the String Catalog). The
command vocabulary is: read-all, stop, set-show-original(on/off), repeat-last, close. Matching is on
the normalized utterance; a miss re-prompts once and never silently drops the turn. Deterministic
matching is deliberate for this surface: it works offline, costs no cloud budget, and is more
reliable for an elder than a round trip for a two-word command. Command capture uses the plugin's
single-utterance in-session microphone (the `ApplianceHelperPlugin` precedent), not always-on
listening, and the microphone is paused while speech is playing so the feature does not hear itself.

### C13 — `LiveTranslatePlugin` and the session model

Follows the shipped plugin pattern exactly: `pluginID`, `displayNameKey`,
`isApplicable(locale:)` (universal), an `intentContribution` with the action name
`livetranslate.open` and a prompt fragment mapping "translate this" / "अनुवाद गर्ने" and close
paraphrases onto it, `handle(_:context:)` returning `.spokenAndPresented`, and
`presentationView(for:)` building the session model and the full-bleed view. Entry is the shared
intent encoder reading the plugin's own prompt fragment — **the shared encoder is not retrained and
no global intent vocabulary is added** (FR-LCT-022, feature constitution known-integration-surface).

**Deliberate divergence from the template.** `ApplianceHelperPlugin.handle` opens with a guard on
`context.geminiClient.isAvailable`. `LiveTranslatePlugin` **must not** copy that guard: the feature
must open and work with no provider key and no network at all (FR-LCT-007, FR-LCT-023). The plugin
opens unconditionally; the unavailability surfaces later, per region, as an honest degraded state.
Copying the guard would be a correctness bug, not a style choice.

Session presentation: full-bleed camera with minimal chrome, one obvious close control (≥ 44 pt) that
stops the capture session and returns to the assistant without further prompts. All new user-visible
strings live in the String Catalog with Nepali first; no user-visible string is a Swift literal
(NFR-LCT-004).

Session lifecycle (FR-LCT-022): backgrounding, a phone call, or an interruption pauses the session;
foregrounding resumes it. On resume the stabiliser restarts from empty (the camera moved), so visible
text re-enters resolution — and because previously resolved strings are in `LabelTranslationCache`,
they reappear **from cache with no new cloud request**. Strings that were degraded or in flight when
the interruption began are re-attempted once under the normal consent and budget rules, which is
exactly FR-LCT-023's recovery scenario, not a contradiction of it. No overlay state is silently lost.

### C14 — `LiveTranslateConfig` and `LiveTranslateSettings`

A single `Equatable` value holding **every** operational constant this feature introduces, with
documented defaults, injectable at construction. No component declares its own copy of a default and
no literal appears in the pipeline; that is what makes NFR-LCT-011's "changing a parameter requires
only the parameter" true rather than aspirational. There is **no user-facing configuration surface**
in v1 (family/caregiver configuration for this feature is out of scope); the device-spike values for
OD1 and OD5 land as edits to this one type.

Two settings are genuinely user-facing and therefore live in `LiveTranslateSettings` with persisted
state:

- `alwaysShowOriginal` — the FR-LCT-017 toggle. Reachable by touch and by voice, persists across
  sessions, and takes effect on the next rendered frame. It is a UI preference containing no user
  content, so it persists via `UserDefaults` (the `AppLanguage.persisted()` precedent). Its default
  is `false` and is confirmed at the first device demo (OD2).
- `consentDisclosureVersion` — not a setting so much as the version stamp carried by consent records
  (C09); it is owned here so the copy review (OD3) changes one place.

### C15 — Cost governance integration (OD7)

No new governor. The bound is the shipped per-day `GeminiCostGovernor` with its family-editable cap,
consumed exactly as every other cloud caller consumes it: `GeminiClient.send(_:)` checks
`allowsCall()` **before any network work** and throws `GeminiClientError.dailyCapReached`, and calls
`recordCall()` at the transport boundary for every attempt that actually left the device (success and
failure alike). Batching is the design's real cost lever: one scene's unresolved strings are one
attempt, not one per string.

On top of that, the tier adds a **session-scoped fail-closed latch**:

- The first time the tier observes a refusal (`dailyCapReached`) during a session, it sets
  `costExhausted = true` for that session.
- While latched, the tier issues **no** request — not a retry, not a smaller batch, not a different
  request shape — and every cloud-bound region terminates as degraded
  (`costBudgetExhausted`) with an honest offline indication.
- The latch is **monotone within the session**: raising the cap mid-session does not reopen the
  session, because FR-LCT-013 binds the failure "for the rest of the session". Reopening at the next
  session (where the governor is re-consulted) is the designed recovery. This specific consequence is
  called out for the reviewer as a deliberate reading of the requirement.
- The latch never degrades anything else: the camera view, the dictionary tier and the cache keep
  working, and no other feature's budget behaviour changes.

Refused attempts are not translations: they produce `degraded`, never a tier claim (FR-LCT-013
scenario 3). The governor's own events (`daily_cap_warning`, `daily_cap_reached` on component
`gemini_cost`) are unchanged and remain the family-visible signal; the tier adds its own
`cost_exhausted_latched` event so the feature's exposure is measurable per session.

### Persistence: keys and schemas

All keys go through `StoragePlacementPolicy`; none is in the keychain-resident allow-list, so all
three land on the **encrypted file** channel (Application Support, Data Protection Complete,
excluded from backups). There is no plaintext at rest, including no temporary file.

| Key | Payload | Written by | Notes |
|---|---|---|---|
| `plugin.live_translate.cache.v1` | `Persisted { schemaVersion: Int, entries: [Entry], producerToken: String? }` where `Entry { key, translation, lastAccessSequence, tierToken: String? }` (monotone counter, AM-6 — no timestamps) and `key = "<normalizedText>|<targetLanguageCode>"` | tier-1 (brain) and tier-2 (cloud) completion path; LRU/upkeep | Whole-payload single-key write (protocol has no enumeration). Contains no image, box, scene timestamp, identifier or location. Unreadable payload ⇒ discard and rebuild. `tierToken` records the tier that produced the entry (`nil` = the v1 default, cloud) and `producerToken` records the brain model its brain-produced entries were written under; a payload whose `producerToken` differs from the live brain's has its brain entries dropped on load ([BRAIN-CACHE], `invalidateSupersededBrainEntriesLocked`) — a translation is a fact about a model, so a replaced model's sentences must not be served from disk. Both fields are optional so a v1 payload is **adopted**, never discarded. |
| `plugin.live_translate.consent.v1` | `ConsentRecord { granted, recordedAt, disclosureVersion }` | consent prompt / revocation | Absent, corrupt or unreadable ⇒ **deny** (fail closed). Deleted on revocation. |
| `livetranslate.alwaysShowOriginal` | `Bool` | settings toggle | `UserDefaults`; a UI preference containing no user content. |

The cost governor's own key (`gemini.costGovernor.v1`) is **unchanged** and is not touched by this
feature (OD7).

A `schemaVersion` on the cache payload is present so a future shape change can be detected and the
payload rebuilt rather than mis-decoded; a payload whose version is unknown is treated exactly like a
corrupt one. The current version is **2** (`Entry.tierToken` was added; see the row above): a version-1
payload is adopted field-for-field rather than rebuilt, because the added fields are optional and their
absent value has a defined meaning — the tier that produced an entry with no token is cloud, the tier
that wrote before the brain cache existed.

### Observability: event catalogue and log-safety discipline

Recognized text and translated text are user content and may not appear in any log, in any build
(feature constitution rule 5, NFR-LCT-006). The design enforces that by **schema**, not by review:
the feature's events carry counts, durations, tiers and outcome classifications only, and the
`errorCode` field is always a `LogSafeErrorCode` constant or an HTTP status number — never a
description, never an upstream body, never a recognized or translated string.

Events emitted by component `livetranslate` (all content-free, except the two Debug-only rows at the
end of the table, whose content values the bus redacts — see the sanitised debug lane below):

| Event | Outcome values | Metadata (whitelisted) |
|---|---|---|
| `session_started` / `session_ended` | success | — |
| `camera_denied` / `camera_unavailable` / `camera_interrupted` / `camera_resumed` | failure / success | reason token |
| `ocr_pass` | success / empty | `regionCount` |
| `ocr_pass_failed` | failure | content-free code |
| `region_appeared` / `region_removed` | success | — |
| `text_change` | success | `regionCount` |
| `translation_batch_requested` | success | `stringCount`, `batchIndex`, `batchCount` |
| `translation_batch_resolved` | success / partial | `resolvedCount`, `unresolvedCount`, `durationMs` |
| `translation_degraded` | degraded | `reason` token, `regionCount` |
| `translation_dedupe_hit` | deduped | `keyCount` |
| `text_quarantined` | quarantined | `count` (no text) |
| `consent_prompt_shown` / `consent_recorded` / `consent_denied` / `consent_revoked` | success | `disclosureVersion` |
| `consent_unreadable` | failure | — |
| `cloud_indicator_shown` / `cloud_indicator_hidden` | success | — |
| `cost_exhausted_latched` | latched | — |
| `cache_hit` / `cache_miss` / `cache_evicted` | success | `origin` token, `count` |
| `cache_payload_reset` / `cache_write_failed` | failure | content-free code |
| `speak_requested` / `speak_failed` | success / failure | `mode` token |
| `translate_debug_ocr` (Debug only) | debug | `regionCount`, `recognized_text` (redacted at the bus) |
| `translate_debug_cloud` / `translate_debug_local` (Debug only) | debug | `source_text`, `translated_text` (redacted at the bus), `duration_ms` |

The observability record for a translation is the *fact* of a translation, never its content — which
is also what makes the family-visible cost and usage stories possible without a privacy exception.

`ios/tools/check-release-log-safety.sh` is a build-blocking gate wired into `ios/build.sh`. This
feature's sources are new scan roots — `Services/LiveTranslate/`, `App/LiveTranslate/`,
`Services/Plugins/LiveTranslatePlugin.swift` and the translation client
`Services/Gemini/GeminiClient+Translate.swift` — and the gate must exit 0 with those roots covered.
The design's rule for implementers is absolute: no `print`, no `debugPrint`, and no recognized or
translated string on a log surface — a log line or an event field — in any configuration.

**The sanitised debug lane (owner decision, 2026-09-20).** The owner's device-testing diagnostic
("both source and target strings") is not an exemption from that rule and is not a console write.
It is `LiveTranslateDebugLane`, a `#if DEBUG`-only type in `Services/Observability/`, emitting each
answered pair and the leg's timing onto the sanitising bus with the strings under keys
`LogSanitiser.redactedKeys` declares content-typed. `LogSanitiser` replaces those values with
`[redacted]` **before** the allow-list filter, so what a sink receives is the pair's existence, its
order and its timing — `translate_debug_cloud outcome=debug metadata=[source_text: [redacted],
translated_text: [redacted], duration_ms: 412]` — and never the text. The lane lives outside the
feature's scan roots precisely because a feature source may carry neither a console write nor a
content-typed event field; the redaction is the choke point's, so no call site can forget it; and
the three keys are declared in `LogSanitiser.allowedKeys` so the log surface keeps exactly one
declaration. `LiveTranslateDebugLaneTests` pins both ends of that route, and `LogSanitiserTests`
and `LiveTranslateAllowListTests` pin the redaction itself.

**What the gate actually enforces over those roots (corrected per AM-5).** Four rules were added to
the shipped B1/T-049 engine, and each is judged on the feature's roots only:

| Rule | Fires on | Configuration |
| --- | --- | --- |
| `feature-console-write` | any console write in the feature's sources | Release framing — a `#if DEBUG` region is exempt, as for the shipped rules |
| `feature-content-print` | a recognized or translated string in a console write | **every** configuration, including `#if DEBUG` |
| `feature-unlisted-metadata-key` | an event metadata key with no `LogSanitiser.allowedKeys` entry — including a `MetadataKey` case that is not allow-listed | every configuration |
| `feature-text-interpolated-into-event` | an `errorCode` or metadata value built by interpolating text or a raw error object, or by rendering a description | every configuration |

The gate also runs the engine's own fixture suite (`tools/log-safety-fixtures/`, one positive and one
negative tree per declared rule) as part of the same invocation, so a rule that stops firing fails
the next build rather than passing silently.

**Stated limits, not implied ones.** The gate is a source-level check and cannot follow indirection:
a value laundered through a helper's return, a `metadata:` variable, a wrapper function or a sink
spelled in a way the rule set does not know is a *documented gap*, not a covered case (the engine's
"Known limitations" section is the authoritative list). The primary safeguard is therefore the typed
event schema together with the runtime allow-list survival tests — `LiveTranslateAllowListTests` in
`ElderlyAssistantTests/Services/Observability/`, which proves key by key that a value under an
unlisted key is dropped and that the feature's keys reach the real console sink: the gate is the
backstop that catches the direct shape a reviewer would miss, and its coverage must not be restated
as stronger than this table.

**Release gates carried by this design (NFR-LCT-013):** the recorded exception amendment (Open
Decision 13, recorded 2026-09-16 — verified at `final-sign-off`, not created here); the
consent/disclosure copy review plus the `NSCameraUsageDescription` update (OD3); the log-safety gate
exiting 0 over the new paths; and `SECURITY-GO` from both security reviews.

### Performance and thermal implementation

- **Cadence.** OCR runs at `ocrSampleInterval` on downscaled frames; tracking runs between passes at
  a lower cost. Nothing else in the feature is continuous: no photo processing, no continuous upload,
  no background inference (NFR-LCT-002).
- **Backpressure.** A pass in flight causes the next sampled frame to be **dropped**, so a slow frame
  or a slow OCR pass degrades the effective rate instead of accumulating work. This is what makes
  the nominal rate safe on mid-range hardware before OD1 is measured.
- **Thermal.** Under `ProcessInfo.thermalState` of `.serious` or `.critical`, the effective sample
  interval is multiplied by `thermalCadenceFactor` (default **2.0**) as a first-line response; if iOS
  pauses or stops the session anyway, the view shows an honest degraded state and never stalls
  silently (NFR-LCT-002 scenario 3). The nominal factor is a device-validation item.
- **Render path.** The overlay renderer reads only main-confined view-model state; it never awaits a
  tier. A translation arriving re-renders one region, and the next OCR cadence renders regardless of
  what is in flight (NFR-LCT-001 scenario 3).
- **Cache write amplification.** LRU touching is coalesced per session and the payload is bounded, so
  the hot overlay path performs no storage I/O.
- **Battery framing.** The dominant cost is the throttled OCR plus preview; the design adds no second
  continuous cost centre, which is the honest statement of the budget until the OD1 device spike
  measures it.

### Technical risks and mitigations

| # | Risk | Impact | Mitigation | Owner / resolution |
|---|---|---|---|---|
| R1 | The nominal OCR cadence (≈4 fps) is unmeasured and may be wrong for mid-range devices, or may drive thermal throttling | Overlay lag, battery drain, thermal pause | Cadence and thermal factor are single parameters; backpressure drops frames; thermal probe; device spike is a gate on freezing the value | OD1 — device spike at implementation |
| R2 | "Fits at ≥ 18 pt" measured with different metrics than the view renders with ⇒ text clipped inside an in-place bubble | Unreadable overlay, and the D1 rule silently violated | One shared text measurer used by both placement and rendering; unit test pins measure-vs-render agreement for Devanagari and Latin samples | implementation; test seam in §Interfaces |
| R3 | Vision language detection returns no language for a region | The request would carry a wrong source language and produce a bad translation | `detectedLanguage` is optional end-to-end; when absent it is omitted rather than defaulted, and the model is instructed to translate the given string into the target language | designed (C02/C08) |
| R4 | Instruction-shaped scene text reaches the cloud translation request | Model misbehaviour, wasted spend, or a translated directive rendered on screen | Sanitise + bound + detect-only quarantining (C07); payload delimited as data; response validated against requested ids only; request carries no tools; quarantined regions degrade honestly. Residual: a *translated* directive is still only text on screen — nothing in this feature acts on model output | designed (C07/C08); probed at `security-design-review` |
| R5 | The model omits or mis-keys some ids | Strings silently untranslated | Any requested id without a validated string terminates as degraded with the original text shown; partial batches are reported per region, never silently dropped | designed (C08) |
| R6 | Whole-payload cache writes on the render path | Latency, thermal cost | Touch coalescing (one touch per key per session), dictionary-layer hits touch nothing, writes coalesced on a serial queue | designed (C05) |
| R7 | The per-day governor is **shared** with the voice pipeline, so a heavy voice day can exhaust the budget and break translation mid-session | Elder sees offline badges with no explanation of cause | Session latch + honest degraded state + `cost_exhausted_latched` event; accepted consequence of OD7 (per-day, family-editable). The family-visible signal already exists (`daily_cap_warning` / `daily_cap_reached`) | **accepted; recorded for review** |
| R8 | NFR-LCT-012 tension: sharing the cache with the appliance helper means a label it previously rendered as English can now render Nepali from a cached cloud translation | A behavioural delta in the shipped helper | The localizer's own output is unchanged and takes precedence whenever it produces a translation, so every currently-translated label renders identically; the only delta is a string the localizer passes through today. Constrained to labels the helper actually presents, requires one new test, and is recorded here explicitly | **flagged for `review-l2`** |
| R9 | Cache payload growth (≈200 general entries + reserved capacity) on a single storage key | Slower cold start, larger protected file | Hard bound enforced by LRU; dictionary layer is never materialised; payload carries no scene metadata | designed (C05) |
| R10 | Audio-session contention between in-session command capture and TTS playback | The feature hears its own speech; commands missed | Microphone paused while speaking; reuse the shipped `AudioSessionManager` mode switch; command capture is single-utterance, not always-on | designed (C12); verify on device |
| R11 | The consent gate is new work and the app has no shipped generic consent record (OD-12's voice consent is a different surface) | Two divergent consent implementations | The gate's shape is deliberately generic (record + version + fail-closed read + revoke); recorded as a reuse opportunity, **without absorbing OD-12's scope into this workflow** | noted; not in scope here |
| R12 | `GeminiClientError.blockedByProvider(reason:)` carries the provider's block reason, which the shipped client already emits as an `error_code` | A provider string on the log surface | The translation path maps blocks to the content-free `blocked_by_provider` code; whether the provider reason value itself is content-free is referred to `security-design-review` as an explicit question rather than assumed | **flagged for `security-design-review`** |
| R13 | Copy review (OD3) is a release gate, not an implementation blocker | Sign-off delay | Consent records are version-stamped so the copy change is a data change, not a logic change; the gate is visible in `NFR-LCT-013` | OD3 — before `final-sign-off` |

---

## Interfaces

Every interface this feature introduces declares an **explicit error type**. The one exception is
deliberate and named: `GeminiClient.translateStrings(items:targetLanguage:)` keeps the shipped
`throws`-based contract of the `send(_:)` chokepoint it must reuse (NFR-LCT-012 forbids adding a
parallel request path), and the tier layer immediately converts `GeminiClientError` into the feature
taxonomy below. No interface returns `any` or `unknown`, and no error field is untyped.

### Error taxonomy

One feature-scoped error type, plus small reason enums so that associated values stay content-free
and loggable. Every case conforms to `LogSafeErrorCode` with a **stable, content-free** code (the
shipped `ErrorCodeMapper` precedent); counts and statuses travel in observability metadata, never in
the code string.

```swift
enum LiveTranslateError: Error, Equatable, LogSafeErrorCode {
    // Camera
    case cameraPermissionNotDetermined
    case cameraPermissionDenied
    case cameraUnavailable(CameraUnavailableReason)
    case cameraSessionInterrupted(CameraInterruption)

    // Detection
    case ocrUnavailable(OCRUnavailableReason)
    case ocrPassFailed(OCRFailure)

    // Consent
    case consentNotRecorded
    case consentDenied
    case consentRecordUnreadable          // fail-closed read

    // Cost
    case costBudgetExhausted              // fail-closed, session-latched

    // Cloud translation
    case providerNotConfigured
    case cloudTransient(TransportFailure) // retryable once
    case cloudRejected(status: Int)       // retryable only for 408 / 429 / 5xx
    case cloudPolicyBlocked               // never retried
    case cloudResponseUnusable(ResponseDefect)
    case cloudDeadlineExceeded

    // Sanitisation
    case textQuarantined(QuarantineReason)

    // Cache
    case cacheReadFailed(CacheFailure)    // self-healing: reset + rebuild
    case cacheWriteFailed(CacheFailure)   // non-fatal

    // Speech
    case speechFailed
}

enum CameraUnavailableReason: Equatable { case noCaptureDevice, configurationFailed, resourceInUse }
enum CameraInterruption: Equatable { case backgrounded, systemInterruption, thermal }
enum OCRUnavailableReason: Equatable { case requestCreationFailed, languageDetectionUnsupported }
enum OCRFailure: Equatable { case requestFailed, noObservations }
enum TransportFailure: Equatable { case timedOut, offline, connectionLost, other }
enum ResponseDefect: Equatable { case notJSON, missingIDs, nonStringValue, oversizedValue }
enum QuarantineReason: Equatable { case markerResidual, emptyAfterSanitise }
enum CacheFailure: Equatable { case payloadUnreadable, storageUnavailable, writeRejected }
```

**Log-safe code mapping** (what actually reaches `error_code`): one stable token per case family —
for example `camera_permission_denied`, `camera_unavailable`, `ocr_pass_failed`,
`consent_not_recorded`, `consent_denied`, `consent_record_unreadable`, `cost_budget_exhausted`,
`provider_not_configured`, `cloud_transient`, `cloud_rejected_<status>`, `cloud_policy_blocked`,
`cloud_response_unusable`, `cloud_deadline_exceeded`, `text_quarantined`, `cache_read_failed`,
`cache_write_failed`, `speech_failed`. Associated reason enums refine the *event metadata*, not the
code, so dashboards stay stable while diagnosis stays possible.

**Two events are deliberately distinguishable for the compliance surface.** `consentRecordUnreadable`
and `costBudgetExhausted` both deny a call, but they are different failures with different owner
actions (a corrupt record is a bug to fix; an exhausted budget is a cap doing its job), so they are
never collapsed into a generic "denied".

### Core interface definitions

Signatures are the contract; bodies are implementation. Ties are to shipped types wherever one
exists.

**C01 `LiveCameraSession`**

```swift
final class LiveCameraSession {
    enum State: Equatable { case idle, starting, running, interrupted(CameraInterruption),
                            stopped, failed(LiveTranslateError) }

    struct CameraFrame { let pixelBuffer: CVPixelBuffer; let pixelSize: CGSize; let timestamp: CMTime }

    init(config: LiveTranslateConfig, observabilityBus: ObservabilityBus)
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer
    func start() async -> Result<Void, LiveTranslateError>
    func pause() -> Result<Void, LiveTranslateError>
    func resume() async -> Result<Void, LiveTranslateError>
    func stop()
    var state: State { get }
    var frames: AsyncStream<CameraFrame> { get }
}
```

**C02 `LiveTextDetector`**

```swift
final class LiveTextDetector {
    struct DetectedTextRegion: Equatable {
        let text: String
        let normalizedBox: NormalizedBox        // (x, y, width, height) in 0..1, origin top-left
        let detectedLanguage: String?           // Vision's detection; nil = not reported
        let confidence: Double
    }
    struct Pass: Equatable {
        let regions: [DetectedTextRegion]       // OCR pass output — the only text source
        let trackedBoxes: [String: NormalizedBox] // region id -> tracked geometry (tracking pass)
    }
    struct NormalizedBox: Equatable { let x, y, width, height: Double; var center: (x: Double, y: Double) }

    init(config: LiveTranslateConfig, observabilityBus: ObservabilityBus)
    func begin() -> Result<Void, LiveTranslateError>
    func recognize(_ frame: CameraFrame) async -> Result<Pass, LiveTranslateError>
    func end()
    var isPassInFlight: Bool { get }
}
```

**C03 `TextRegionStabilizer`** — pure; no error type because it has no failure mode (documented as
total: every input produces an output).

```swift
struct TextRegionStabilizer {
    struct RegionIdentity: Hashable { let rawValue: UUID }
    struct StableTextRegion: Equatable {
        let id: RegionIdentity
        let text: String                        // the longest string of a merged set
        let normalizedText: String              // normalized: trim, collapse, case-fold
        let box: NormalizedBox
        let detectedLanguage: String?
        let confidence: Double
    }
    enum RegionChangeEvent: Equatable {
        case appeared(StableTextRegion)
        case textChanged(StableTextRegion)
        case disappeared(RegionIdentity)
    }

    init(config: LiveTranslateConfig)
    mutating func consume(regions: [LiveTextDetector.DetectedTextRegion],
                          tracked: [String: NormalizedBox]) -> [RegionChangeEvent]
    var visible: [StableTextRegion] { get }
    mutating func reset()                        // process/system interruption
}
```

**C04 `TranslationResult`** — the outcome enum is the single source of truth.

```swift
enum TranslationTier: String, Equatable, Codable {
    case dictionary     // tier 0
    case cloud          // tier 2
    // No case exists for the deferred on-device tier (D2 / FR-LCT-008).
}

enum TranslationUnavailableReason: Equatable {
    case noNetwork, providerNotConfigured, consentNotGranted, costBudgetExhausted,
         providerRejected, textQuarantined, deadlineExceeded, noTierResolved
}

enum TranslationOutcome: Equatable {
    case pending(originalText: String)
    case resolved(originalText: String, translation: String, tier: TranslationTier)
    case degraded(originalText: String, reason: TranslationUnavailableReason)
}

struct TranslationResult: Equatable {
    let outcome: TranslationOutcome

    var text: String                 // translation when resolved; original otherwise
    var sourceTier: TranslationTier? // non-nil ONLY when a tier actually produced the string
    var isFinal: Bool                // false only for .pending
    var degraded: Bool               // true only for .degraded
    var originalText: String
}
```

**C05 `LabelTranslationCache`**

```swift
final class LabelTranslationCache {
    struct CacheError: Error, Equatable, LogSafeErrorCode {
        case payloadUnreadable, storageUnavailable, writeRejected
    }
    enum Origin: Equatable { case curatedDictionary, persisted }
    struct Hit: Equatable { let translation: String; let origin: Origin }

    init(storage: EncryptedLocalStorage,
         config: LiveTranslateConfig,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init)

    static func normalizationKey(text: String, targetLanguage: AppLanguage) -> String

    func lookup(text: String, targetLanguage: AppLanguage) -> Result<Hit?, CacheError>
    func store(text: String, targetLanguage: AppLanguage, translation: String)
        -> Result<Void, CacheError>
    func removeAll() -> Result<Void, CacheError>
    var generalEntryCount: Int { get }
}
```

**C07 `SceneTextSanitiser`** — pure and total.

```swift
enum SceneTextSanitiser {
    enum Verdict: Equatable {
        case sendable(String)
        case truncated(String)
        case quarantined(QuarantineReason)
    }
    static func sanitiseForEgress(_ raw: String, maxLength: Int) -> Verdict
    static func bound(_ items: [String], maxStrings: Int, maxCharacters: Int) -> [[String]]
}
```

**C08 `CloudTranslationTier`** and the client extension

```swift
actor CloudTranslationTier {
    struct Item: Equatable { let id: String; let text: String; let detectedSourceLanguage: String? }
    struct BatchResult: Equatable {
        let resolved: [String: String]                  // item id -> translation (validated)
        let failures: [String: LiveTranslateError]      // item id -> why no translation
    }

    init(cache: LabelTranslationCache,
         consentGate: LiveTranslateConsentGate,
         costGovernor: GeminiCostGovernor,
         client: GeminiClient,
         config: LiveTranslateConfig,
         observabilityBus: ObservabilityBus,
         indicator: CloudActivityIndicatorModel)

    func resolve(items: [Item], targetLanguage: AppLanguage) async -> BatchResult
    var isCostLatched: Bool { get }
}

extension GeminiClient {
    struct TranslationItem: Encodable, Equatable {
        let id: String
        let text: String
        let sourceLanguage: String?
    }
    /// New method on the existing `send(_:)` chokepoint. Text parts only; no tools.
    func translateStrings(items: [TranslationItem],
                          targetLanguage: String) async throws -> [String: String]
}

/// Pure, unit-testable prompt and response handling.
enum TranslationPrompt {
    static func build(items: [GeminiClient.TranslationItem], targetLanguage: String) -> String
}
enum TranslationResponseParser {
    static func parse(_ raw: String, expectedIDs: Set<String>)
        -> Result<[String: String], TranslationResponseParser.Defect>
    enum Defect: Error, Equatable { case notJSON, missingIDs(Int), nonStringValue, oversizedValue }
}
```

**C09 `LiveTranslateConsentGate`**

```swift
final class LiveTranslateConsentGate {
    enum Decision: Equatable { case granted, notRecorded, denied, unreadable }
    struct ConsentError: Error, Equatable, LogSafeErrorCode { case recordUnreadable, writeFailed }
    struct ConsentRecord: Codable, Equatable {
        let granted: Bool
        let recordedAt: Date
        let disclosureVersion: String
    }

    init(storage: EncryptedLocalStorage,
         disclosureVersion: String,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init)

    func currentDecision() -> Decision                    // read-through, fails closed
    func record(granted: Bool) -> Result<Void, ConsentError>
    func revoke() -> Result<Void, ConsentError>
}
```

**C10 `CloudActivityIndicatorModel`**

```swift
@MainActor
final class CloudActivityIndicatorModel: ObservableObject {
    @Published private(set) var isActive: Bool
    func requestBegan()
    func requestEnded()
}
```

**C11 `LiveOverlayPlacement`** — pure and total.

```swift
enum LiveOverlayPlacement {
    struct Policy: Equatable {
        let maxSourceWordCount: Int
        let minPointSize: CGFloat
        let alwaysShowOriginal: Bool
    }
    enum Form: Equatable {
        case inPlace(regionID: TextRegionStabilizer.RegionIdentity, rect: CGRect)
        case callout(regionID: TextRegionStabilizer.RegionIdentity,
                     anchor: CGPoint, pillRect: CGRect)
    }
    struct PlacedOverlay: Equatable {
        let region: TextRegionStabilizer.StableTextRegion
        let result: TranslationResult
        let form: Form
    }

    static func place(regions: [TextRegionStabilizer.StableTextRegion],
                      results: [TextRegionStabilizer.RegionIdentity: TranslationResult],
                      containerSize: CGSize,
                      framePixelSize: CGSize,
                      occupiedRects: [CGRect],
                      policy: Policy,
                      measure: (String, CGFloat) -> CGSize) -> [PlacedOverlay]

    static func inlineEligible(source: String,
                               translation: String,
                               regionRect: CGRect,
                               policy: Policy,
                               tier: TranslationTier,
                               measure: (String, CGFloat) -> CGSize) -> Bool
}
```

**C12 command parsing and speech**

```swift
enum LiveTranslateCommand: Equatable {
    case readAll, stopSpeaking, repeatLast, setShowOriginal(Bool), close
}
enum LiveTranslateCommandParser {
    static func parse(_ utterance: String, locale: Locale) -> LiveTranslateCommand?
}

enum LiveTranslateSpeech {
    static func orderedForReading(
        _ placed: [LiveOverlayPlacement.PlacedOverlay]
    ) -> [LiveOverlayPlacement.PlacedOverlay]     // top-to-bottom: midY, then midX
}
```

**C13 `LiveTranslatePlugin`** — conforms to the shipped `AssistantPlugin` protocol; `handle`
returns `PluginResult` (the protocol's own explicit outcome type: `.spoken`, `.spokenAndPresented`,
`.failed(spokenApology:)`). It is async and has no timeout of its own — it returns as soon as the
view is presented, because no cloud call happens during entry.

**C14 `LiveTranslateConfig`**

```swift
struct LiveTranslateConfig: Equatable {
    // Detection cadence (OD1)
    var ocrSampleInterval: TimeInterval              = 0.25      // ≈4 fps nominal, device spike
    var thermalCadenceFactor: Double                 = 2.0
    var thermalStateThreshold: ProcessInfo.ThermalState = .serious

    // Tracking / stabilisation
    var trackingEnabled: Bool                        = true
    var regionMatchIoU: Double                       = 0.3
    var regionMatchCentroidDistance: Double          = 0.35
    var regionAppearPasses: Int                      = 2
    var regionMissPasses: Int                        = 2

    // Decluttering (OD5)
    var declutterMergeCentroidDistance: Double       = 0.06
    var declutterMaxRegions: Int                     = 8

    // Overlay (D1, OD2)
    var inPlaceMaxSourceWordCount: Int               = 3
    var overlayMinPointSize: CGFloat                 = 18
    var alwaysShowOriginalDefault: Bool              = false

    // Tier 2
    var cloudRequestTimeout: TimeInterval            = GeminiClient.Config.default.timeoutSeconds // 25
    var cloudDeadlineGraceSeconds: TimeInterval      = 5
    var cloudMaxRetries: Int                         = 1
    var cloudBatchMaxStrings: Int                    = 12
    var cloudBatchMaxCharacters: Int                 = 1200
    var sceneTextMaxLength: Int                      = 120
    var translationMaxLengthRatio: Double            = 4.0       // response-size sanity bound
    var translationMaxLengthAllowance: Int           = 64

    // Cache
    var cacheGeneralEntryLimit: Int                  = 200
    var cacheTouchCoalescing: Bool                   = true

    // Disclosure
    var disclosureVersion: String                    = "<set at OD3 copy freeze>"

    static let `default` = LiveTranslateConfig()
}
```

### Failure modes and retryability per asynchronous operation

Every async operation in the feature, its failure modes, and whether a retry happens. "Retry"
here means an automatic re-attempt by the feature, not a user action.

| # | Operation | Failure modes | Retryable? | Where the policy lives |
|---|---|---|---|---|
| 1 | `LiveCameraSession.start()` | permission not determined (returns, then the caller shows the explanation and re-calls); permission denied; no capture device; configuration failed; resource in use | Permission-denied / configuration / no-device: **no** (user action required). Interruption during start: **yes** — one automatic resume on foreground | C01 |
| 2 | `LiveCameraSession.resume()` | session was torn down, resource still unavailable, thermal stop | **Yes**, driven by the foreground notification; bounded to one attempt per foreground transition (no loop) | C01 |
| 3 | `LiveTextDetector.begin()` / `.end()` | request creation failed; tracking request unsupported | **No** — degrades to OCR-only (tracking off) with an honest event; the feature stays usable because tracking is a SHOULD (FR-LCT-004) | C02 |
| 4 | `LiveTextDetector.recognize(_:)` | Vision failure; no observations | Vision failure: **yes** — silently dropped, next pass retries (never surfaced to the elder). No observations: **not a failure** (empty-state hint) | C02 |
| 5 | `TextRegionStabilizer.consume(_:)` | none — total function | n/a | C03 |
| 6 | `LabelTranslationCache.lookup(_:)` | payload unreadable; storage unavailable | **Yes** and self-healing: an unreadable payload is discarded, the store rebuilds from the dictionary layer, and the lookup resolves as a miss. Nothing user-visible | C05 |
| 7 | `LabelTranslationCache.store(_:)` | write rejected; storage unavailable | **Yes**, implicit: the next resolution of the same key tries again. The translation is rendered regardless | C05 |
| 8 | `LiveTranslateConsentGate.currentDecision()` | record unreadable / absent / denied | **Yes** for re-read (the next request re-reads), but the decision is `deny` every time until a record exists. No automatic re-prompt in a loop: the prompt is shown at most once per session until the user answers | C09 |
| 9 | `LiveTranslateConsentGate.record(_:)` / `.revoke()` | write failed | **Yes** — the caller re-prompts (record) or reports the failure (revoke). A failed revoke must deny in memory, verify the delete by read-back, surface the failure, and never let a relaunch silently re-grant (SD-1/AM-4 semantics; the earlier "record intact is the safe direction" claim was proved wrong in review) | C09 |
| 10 | `CloudTranslationTier.resolve(_:)` → provider not configured | `.providerNotConfigured` | **No** (configuration action required). Regions degrade; the feature keeps working | C08 |
| 11 | … → consent not recorded / denied | `.consentNotRecorded` / `.consentDenied` | **No** automatic retry. The prompt is the retry, and it is user-driven | C08/C09 |
| 12 | … → cost budget exhausted | `.costBudgetExhausted` | **No** — session-latched, fail closed, no alternative request shape | C15 |
| 13 | … → transport timeout / offline / connection lost | `.cloudTransient(...)` | **Yes, at most once** (`cloudMaxRetries = 1`); then degraded | C08 |
| 14 | … → HTTP 408 / 429 / 5xx | `.cloudRejected(status:)` | **Yes, at most once**; then degraded | C08 |
| 15 | … → HTTP 4xx (other) | `.cloudRejected(status:)` | **No** — a malformed request will not become well-formed by repeating it | C08 |
| 16 | … → provider policy refusal | `.cloudPolicyBlocked` | **No** | C08 |
| 17 | … → malformed / empty / unusable response | `.cloudResponseUnusable(...)` | **Yes, at most once** — treated as transient | C08 |
| 18 | … → deadline exceeded | `.cloudDeadlineExceeded` | **No** — the retry budget is inside the deadline; exceeding it terminates the batch | C08 |
| 19 | … → single item unresolved in an otherwise-valid response | per-item failure | **No** for that item within the batch (it already cost an attempt); the region degrades honestly, and a later text change or scene re-entry is a new request under the normal rules | C08 |
| 20 | `GeminiClient.translateStrings` | the full `GeminiClientError` set | Policy lives in C08; this layer only reports | C08 |
| 21 | `SceneTextSanitiser.sanitiseForEgress(_:)` | none — total function; quarantine is a verdict, not an error | n/a | C07 |
| 22 | `LiveTranslateSpeech` / `SpeakQueue` | speech failed or silent degradation | **No retry loop** (shipped `SpeakQueue` behaviour). The visual translation stays | C12 |
| 23 | `LiveTranslatePlugin.handle(_:context:)` | no provider key; no camera permission; view construction failed | **No** automatic retry; entry never fails for a cloud reason (the feature must open without a key). A construction failure returns `.failed(spokenApology:)` — never a silent no-op | C13 |
| 24 | Pipeline frame tick (`ingest(_:)`) | any of the above | **Yes** by construction: the next tick is the retry, at the OCR cadence. No tick is queued behind a failure | C01/C03 |

Two invariants follow from the table and are the ones `security-test` will look for: **no failure
path issues an unbounded number of requests**, and **every failure terminates in a rendered state**
(translation, degraded-with-original, or empty-state hint) — never a blank bubble and never a silent
drop.

### Configurable parameters and timeouts

Nominal defaults live in exactly one place (`LiveTranslateConfig.default`, C14). The base cloud
timeout is **not duplicated**: it is `GeminiClient.Config.default.timeoutSeconds` (25 s), the shipped
value that already covers the slowest curated model.

| Parameter | Nominal default | Failure it bounds | Change requires |
|---|---|---|---|
| `ocrSampleInterval` | 0.25 s (≈4 fps) — OD1, device spike | OCR load, thermal, battery | the parameter only |
| `thermalCadenceFactor` | 2.0 | thermal escalation | the parameter only |
| `regionMatchIoU` / `regionMatchCentroidDistance` | 0.3 / 0.35 | region identity churn | the parameter only |
| `regionAppearPasses` / `regionMissPasses` | 2 / 2 | overlay flicker, translation churn | the parameter only |
| `declutterMergeCentroidDistance` / `declutterMaxRegions` | 0.06 / 8 — OD5 | unreadable dense scenes | the parameter only |
| `inPlaceMaxSourceWordCount` / `overlayMinPointSize` | 3 / 18 pt — D1 | in-place legibility | the parameter only |
| `alwaysShowOriginalDefault` | false — OD2, first device demo | overlay mode | the parameter only |
| `cloudRequestTimeout` | 25 s (from `GeminiClient.Config.default`) | unbounded pending | the client's config |
| `cloudDeadlineGraceSeconds` | 5 s | a transport that outlives its own timeout | the parameter only |
| `cloudMaxRetries` | 1 | retry storms, cost | the parameter only |
| `cloudBatchMaxStrings` / `cloudBatchMaxCharacters` | 12 / 1200 | request size, cost per scene | the parameter only |
| `sceneTextMaxLength` | 120 characters | payload bounding (grapheme-safe) | the parameter only |
| `cacheGeneralEntryLimit` | 200 | unbounded cache growth | the parameter only |
| `costGovernor.softDailyCap` | 200 (range 10 … 1000) | runaway spend | the shipped family-editable setting (OD7) — **not owned by this feature** |
| Consent prompt | **no timeout, by design** | implicit consent | n/a — a value here would be a compliance defect |

`NFR-LCT-011`'s two acceptance scenarios are satisfied directly: changing the OCR cadence is a
change to `ocrSampleInterval` and nothing else, and the tier-2 timeout and retry settings resolve
from configuration with documented defaults and no magic literal in the request code.

### Security invariants and their enforcement points

These are the properties `security-design-review` and `security-test` will probe. Each is stated
with the mechanism that makes it true, so a reviewer can falsify it by inspection rather than by
trusting intent.

| Invariant | Requirement | Enforcement point | How it is falsified in review |
|---|---|---|---|
| No tier-2 request without a recorded consent decision | FR-LCT-010, NFR-LCT-007 | `CloudTranslationTier.resolve` consults `LiveTranslateConsentGate.currentDecision()` before building any payload; every cloud path (initial and the single retry) goes through `resolve`; the gate has no default-on state and fails closed on an unreadable record | Force a dictionary miss with no consent record and assert zero requests reach the transport, including on the retry path |
| Text-only egress: recognised strings and language parameters only | FR-LCT-014, NFR-LCT-005 | `GeminiClient.translateStrings` is the only translation request builder; it constructs `GeminiRequest` from `.text` parts and sets no tools; no image parameter exists to populate; the camera session configures no photo output, so the feature has no image bytes to attach | Inspect the built request: text parts only, no media part, no health/contacts/profile content, same shape on the retry |
| No recognized or translated text on the log surface | NFR-LCT-006 | The event schema (see §Components) admits counts, durations, tiers, reasons and statuses only; `errorCode` is a `LogSafeErrorCode` constant or a status number; the runtime allow-list (`LogSanitiser.allowedKeys`, key-by-key in `LiveTranslateAllowListTests`) drops any value under an unlisted key; `check-release-log-safety.sh` additionally fails the build on a console write, a content-bearing console write in any configuration, an unlisted metadata key or a text/error-interpolated event field across `Services/LiveTranslate/`, `App/LiveTranslate/`, `LiveTranslatePlugin.swift` and `GeminiClient+Translate.swift` — a source-level backstop whose stated limits are in §Components | Run the gate (it also runs its own fixture suite, so a rule that stopped firing fails here); probe the allow-list at runtime with an unlisted key; treat any log line that reaches a sink through an indirection the gate documents as a gap, not as covered |
| Cache encrypted at rest with no plaintext file | NFR-LCT-008 | `StoragePlacementPolicy` routes the key to the encrypted file channel (Data Protection Complete, backups excluded); on top of the channel, T-032 adds a cipher layer — AES-GCM via CryptoKit with a Keychain-held symmetric key and a versioned envelope (magic/nonce/ciphertext/tag), key-loss recovery as an empty cache; no intermediate plaintext file; entries carry no image, box, scene timestamp, identifier or location | Inspect the app container for readable translation text (byte-level ciphertext asserted by the T-032 tests); inspect the stored entry shape |
| Cost governor fails closed and never retries around the cap | FR-LCT-013 | `GeminiClient.send(_:)` refuses before any network work; the tier's session latch makes every subsequent attempt a no-op; no alternative request shape exists that could bypass it | Reach the cap and assert zero further requests for the rest of the session, on a changing scene |
| Cloud-activity indicator cannot disagree with reality or be suppressed | FR-LCT-011 | Its only input is the in-flight request counter, incremented on issue and released in `defer`; it is not writable from settings or the overlay; it has no minimum-dwell timer | Toggle the overlay mode mid-flight and assert the indicator state is unchanged; assert it is absent when idle |
| Truthful tier attribution; no success without a translation | FR-LCT-008, NFR-LCT-010 | `sourceTier` is non-nil only for `.resolved`; pending and degraded are the only other outcomes; there is no tier-1 case to return; `degraded` count vs. tier claims is zero by construction | Construct a degraded result and assert `sourceTier == nil`; assert no resolution path can name an on-device tier |
| Scene text cannot function as a directive | NFR-LCT-009 | C07 sanitises, bounds and detect-only-quarantines; the payload is delimited data with per-item ids, never concatenated into the instruction region; the request carries no tools; only requested ids with string values are accepted from the response, and oversized values are rejected | Submit an instruction-shaped string and assert the quarantine verdict, the payload exclusion, and the honest degraded region |
| Withdrawal is immediate and total | FR-LCT-012 | Revocation deletes the record, flips the mirror under the lock, and cancels in-flight tier-2 tasks; every subsequent `currentDecision()` denies | Revoke mid-scene and assert zero further requests and no indicator |
| No photo output means no image can be captured or written | FR-LCT-001, NFR-LCT-005 | Only `AVCaptureVideoDataOutput` is configured; no `AVCapturePhotoOutput`, no picker, no frame written to disk | Inspect the session configuration and the app container after a session |

### Test seams and required unit coverage

The design is shaped so that the security-critical and correctness-critical logic is pure and
directly testable without a device, a camera, or a network.

**Pure / deterministic — unit tested with no I/O:**

- `TextRegionStabilizer` — scripted frame sequences covering: appear only after two consecutive
  detections; survive a single miss; removed after two misses; repeated identical text emits no
  change event; geometry match with a changed string is a text change on the same region; merge rule
  (same string, close centroids, longest-string text, union box); region cap with deterministic
  tie-break.
- `LabelTranslationCache` — key normalization; read-through dictionary seeding with an empty payload
  (no network, FR-LCT-019 scenario 2); LRU eviction of general entries; dictionary-resident entries
  never evicted; touch coalescing; corrupt payload ⇒ reset and rebuild, feature still opens.
- `LiveOverlayPlacement` — the D1 predicate case by case (tier 0 + ≤3 words + fits ⇒ in place;
  cloud tier ⇒ callout even when it fits; long source ⇒ callout; does not fit at 18 pt ⇒ callout;
  toggle on ⇒ callout); callout never intersects its own region; deterministic anchor ordering;
  measure-vs-render agreement (R2).
- `SceneTextSanitiser` — per-string truncation at a grapheme boundary for Devanagari and Latin;
  batch bounding and split; quarantine verdicts; text that is empty after sanitisation.
- `TranslationPrompt` / `TranslationResponseParser` — payload delimiting; ids present in the
  prompt; unrequested ids discarded; non-string values discarded; oversized values rejected;
  malformed JSON handled.
- `LiveTranslateCommandParser` — every English and Nepali phrasing for the five commands; near-miss
  input returns nil (re-prompt path, never a silent drop).
- `LiveOverlayPlacement`/`LiveTranslateSpeech.orderedForReading` — top-to-bottom ordering with a
  tie-break.
- `TranslationResult` — `sourceTier` nil for pending and degraded; `degraded` true only for
  degraded; text fallback is the original.

**Integration — no live network:**

- Full pipeline against a **stubbed tier-2 transport** (the feature constitution's requirement):
  consent granted ⇒ exactly one batched request for a dictionary-miss scene; consent absent ⇒ zero
  requests, including on the retry path; cost cap reached ⇒ zero further requests and every region
  degraded; transient error ⇒ exactly one retry, then degraded; policy refusal ⇒ no retry.
- In-flight dedupe: the same string observed twice before a reply produces one request.
- Revocation mid-scene: zero further requests, indicator absent, feature still usable.
- Cache round-trip through the encrypted storage implementation, and a relaunch-with-no-network case.
- Appliance-helper label seam (T-013, FR-LCT-020 / R8) — `ApplianceHelperLabelSeamTests`, three named
  cases: `testR8CaseOneADictionaryKnownLabelRendersExactlyAsBeforeTheSeam` (every label the localizer
  translates renders byte-for-byte as shipped), `testR8CaseTwoACachePopulatedLabelRendersTheCachedTranslation`
  (the one recorded behavioural delta), `testR8CaseThreeTheLocalizerWinsOverTheCacheWhenBothWouldAnswer`
  (localizer precedence). The same file covers the shared-store hit for the live path, the absence of
  any cloud/consent dependency in the seam, and the one-store/one-dictionary scan.
- Vision OCR against fixture images on the simulator, including a dense menu-like page for the
  decluttering path.

**Manual device (recorded as validation for OD1, OD2, OD5 and R10):** appliance panel, packaging,
a real menu page in poor light; verify stabiliser behaviour, declutter legibility, in-place vs
callout selection, thermal behaviour under sustained use, offline degradation in airplane mode,
tap-to-hear and "read this to me", and the microphone/speech mutual exclusion.

---

*End of L2 component design. Nothing in this document adds scope beyond the signed-off requirement
set; the two resolved open decisions (OD7, OD8) are implemented exactly as the owner directed, and
OD1/OD2/OD3/OD5 remain recorded and unresolved.*
