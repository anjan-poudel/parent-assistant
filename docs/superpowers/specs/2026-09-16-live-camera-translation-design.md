# Live Camera Translation — Component Design

Branch: `worktree-live-camera-translation`. Builds on: `docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md` (the base design) and its addendum `docs/superpowers/specs/2026-09-05-appliance-helper-live-ar-and-local-knowledge-addendum.md` §13 ("Live AR camera overlay"). Status: **first-pass component design, approved by the project owner 2026-09-16, awaiting spec review.**

## 0. Executive summary

The user points the camera at anything printed — appliance panels, remotes, packaging, signs, a menu in a foreign country — and sees the text overlaid with a translation into the app's active language, live, without ever taking a photo. v1 translates **English source text → the user's language** (Nepali at launch). The pipeline is deliberately direction- and language-agnostic: source-language detection is native Vision capability (automatic language detection), and the translation tiers are chosen so that "any language → user language" (the senior-abroad scenario: Chinese, Japanese, etc. menus) is model/prompt work later, not architecture work.

This spec inherits the addendum's two-layer architecture (§13.1: fast on-device Vision layer + slow text-only translation layer) and its cache keying (§13.2: `(recognizedText, targetLanguage)`), and **deliberately diverges** from it in two places, both owner-approved (2026-09-16):

- **D1 — Smart-mix overlay.** The addendum mandates callout-only ("never obscure/redraw reality", §13.3, §13.5). This design adds in-place replacement *only* for short, dictionary-known labels whose translation fits the region at ≥18 pt; everything else uses the addendum's adjacent callout. A settings toggle ("always show original text") reduces this to pure callout mode.
- **D2 — On-device translation tier, deferred.** The addendum explicitly scopes out on-device translation models (§13.5). This design records an owner-approved direction: v1 ships dictionary + Gemini tiers only (addendum-consistent), and a small on-device NMT tier (NLLB-200 distilled 600M, many-to-many) is a **v1.1 candidate** that will require revisiting the addendum's non-goal before it lands.

The feature is a new voice-invokable plugin (`LiveTranslatePlugin`), sibling to the appliance helper, sharing the label dictionary and translation cache with it.

## 1. Scope

**In scope (v1):**
- Live camera feed (AVCaptureSession + preview layer); no photo capture.
- On-device OCR with automatic language detection (Vision `VNRecognizeTextRequest`), English-source quality focus for v1.
- Translation to the app's active language (`AppLanguage`: `ne` at launch) via: curated dictionary → (deferred: on-device NMT) → text-only Gemini call, consent-gated.
- Smart-mix overlay: in-place replacement (dictionary-known, short, fits at ≥18 pt) + anchored callouts (everything else).
- Tap-to-hear (Piper TTS) and session voice command "read this to me" (reads visible regions top-to-bottom).
- Persistent translation cache shared with the appliance helper.
- Any-printed-text scenes, including text-dense scenes (a menu page) — batching + per-session cost governor.

**Explicitly out of scope (v1):**
- NE→EN and "any → user language" translation quality work (architecture supports it; see §10 Open decisions). English source only.
- Reverse direction for abroad use ("show the waiter a phrase in their language") — a later "phrase card" mode reusing this pipeline.
- On-device NMT tier (v1.1 candidate, D2).
- ARKit world-anchored rendering (3D). Screen-space overlay only; the pipeline is render-agnostic so a 3D renderer can be added later without touching detection/stabilization/translation.
- Auto-speak of every new translation (noise for multi-label scenes); tap + command only.
- Live full-scene explanation ("what does this panel do") — that stays the appliance helper's one-shot `identifyAppliance` call.

## 2. End-to-end data flow

```
Voice ("translate this" / "अनुवाद गर्ने") or big Home tile
   │
   ▼
LiveTranslatePlugin presented → LiveTranslatorView (full-bleed camera)
   │
   ▼
LiveCameraSession: preview layer + throttled frame tap (~4 fps, downscaled)
   │  each sampled frame
   ▼
LiveTextDetector: VNRecognizeTextRequest (auto language detection)
   │  observations: text + normalized bounding boxes + recognized language
   ├─ VNTrackRectangleRequest runs on *intermediate* frames (cheap, per-frame)
   │   → carries region screen position between OCR passes (no visible jumps)
   ▼
TextRegionStabilizer: match observations frame-to-frame (geometry IoU + normalized string)
   → stable region IDs; hysteresis (appear after 2 consecutive detections, survive 2 misses);
   → decluttering rule (§4.3); emits events ONLY when a region's text changes
   │  changed regions, batched
   ▼
TranslationTiers.resolve(texts, targetLanguage, detectedLanguage):
   Tier 0: dictionary (ApplianceLabelLocalizer, exact-match) — instant, offline
   Tier 1: (v1.1) on-device NMT — deferred
   Tier 2: Gemini, TEXT-ONLY, batched single request — consent-gated, deduped in-flight
   │  results
   ▼
TranslationCache (persistent, encrypted): key (normalizedText|targetLang) → translation
   │
   ▼
OverlayRenderer: smart-mix render of stable regions (§4.5)
   │  tap on bubble
   ▼
SpeakQueue (Piper TTS, active-language voice) — reads the translation aloud
```

Latency budget: dictionary hit = 0 network, <50 ms. Cache hit = instant overlay. Gemini miss = one round trip (~1–3 s), bubble shows "translating…" until filled. The user never waits on OCR — overlays update at the OCR cadence (~4 Hz), translations fill in as tiers resolve.

## 3. Relationship to existing code

- **`ApplianceLabelLocalizer`** — tier-0 dictionary, extended. Its `Display(primary:secondary:)` shape and locale gating (`isNepali`) are reused verbatim. New entries follow its conservative rules (exact whole-label match, no fuzzy).
- **`ApplianceOverlayMapper`** — the pure aspect-fit coordinate math is reused for OCR normalized boxes → screen points (preview layer uses `.resizeAspect` letterboxing so the same function applies). New unit tests, no changes to the function's contract.
- **`LabelTranslationCache`** (addendum §13.2) — generalized from in-memory to persistent (encrypted storage, `StoragePlacement` pattern), because the abroad scenario produces arbitrary strings worth keeping across launches, not just a saturating label vocabulary. Seed = the dictionary entries.
- **`GeminiClient`** — new text-only method `translateStrings(texts:targetLanguage:sourceLanguages:)` on the same `send(_:)` chokepoint (auth/timeout/observability). No `inlineData` images. Reuses `GeminiCostGovernor`.
- **`ApplianceHelperPlugin`** — the plugin/session/command-parsing pattern is the template. Session-local commands (not global intent-encoder retraining) per that precedent.

## 4. Components

### 4.1 `LiveCameraSession`

Owns `AVCaptureSession` + `AVCaptureVideoPreviewLayer` (full-bleed, `.resizeAspect`), exposes a frame tap throttled to ~4 fps (`AVCaptureVideoDataOutput`, downscaled via `videoSettings`; nominal value — addendum OD-11: needs a device spike before committing). No photo output configured at all. Failure modes: camera permission denied → explanatory screen + Settings deep link (existing pattern); session interruption (call, backgrounding) → pause, resume on foreground, drop no overlays (cache keeps translations). Battery/thermal: throttled OCR is the dominant cost; no other continuous work.

### 4.2 `LiveTextDetector`

Wraps `VNRecognizeTextRequest` with `automaticallyDetectsLanguage = true` (iOS 16+; the app's deployment target supports it) and `VNTrackRectangleRequest` for between-OCR-pass tracking (addendum §13.3). Output: `DetectedTextRegion { text, normalizedBox, recognizedLanguage, confidence }` plus per-frame tracked positions. On-device only, no model download. Failure mode: no text in frame → empty-state hint ("point at some writing"), no error surfaced to the elder.

### 4.3 `TextRegionStabilizer`

Pure logic, unit-testable. Matches OCR observations to existing regions by geometry (IoU ≥ 0.3 or centroid distance) + normalized string equality; assigns stable IDs; hysteresis: a region must be seen in 2 consecutive passes to appear and survive 2 consecutive misses before removal (anti-flicker). **Decluttering rule (answers addendum OD-12 for this feature):** regions whose normalized centroids are closer than 0.06 in either axis after merging same-string duplicates are merged into one callout whose text is the longest string; if more than 8 regions are visible, keep the 8 highest-confidence. Emits `RegionChange` events only on text change — this is the gate that bounds translation traffic.

### 4.4 `TranslationTiers`

```swift
struct TranslationResult: Equatable {
    let text: String          // translated string, or the original on total failure
    let sourceTier: Tier      // .dictionary / .onDeviceNMT / .cloud
    let isFinal: Bool         // false while a tier is still in flight ("translating…")
    let degraded: Bool        // true when all tiers failed → "offline" badge
}

enum TranslationTiers {
    func resolve(texts: [String], targetLanguage: AppLanguage,
                 sourceLanguage: String?) async -> [String: TranslationResult]
}
```

- **Tier 0 — dictionary**: `ApplianceLabelLocalizer` extended (target ~120 curated entries covering appliance/remote vocabulary). Exact-match only.
- **Tier 1 — (v1.1, D2) on-device NMT**: NLLB-200 distilled 600M via the project's CoreML conversion pipeline. Chosen over Opus-MT because many-to-many serves the multilingual roadmap. NOT in v1; requires revisiting addendum §13.5's non-goal.
- **Tier 2 — Gemini text-only**: batch of unresolved strings in ONE request, JSON response mapping source → translation. Prompt includes detected source language per string ("translate this zh text to ne"). In-flight dedupe: a pending key does not fire a second call (addendum §13.3). Consent-gated (§7). Bounded by `GeminiCostGovernor` (per-session cap; on cap, tier fails closed to "offline" display, never silent retry loop).

### 4.5 `OverlayRenderer`

SwiftUI over the preview layer. Per stable region, smart mix:

- **In-place replacement** iff: tier-0 dictionary hit AND translation length ≤ region width at 18 pt minimum AND the source string is short (≤ 3 words). Opaque high-contrast background sized to the region. (D1 divergence from addendum's callout-only mandate — owner-approved.)
- **Anchored callout** otherwise: pill with a leader line to the region, Nepali primary (≥ 18 pt, bold, high contrast), original source text as small secondary for cross-check. Never covers the original text (preserves the base design's "never obscure reality" principle where in-place doesn't apply).
- "translating…" state for pending tier-2 regions; "offline" badge when all tiers failed.
- Settings toggle: "always show original text" → all callouts (approach-C fallback, free).
- Bubble hit target ≥ 44 pt (constitution accessibility standard).

### 4.6 `LiveTranslatePlugin`

Follows `ApplianceHelperPlugin` (registry, `handle` entry, session state, presentPluginView). Voice entry: plugin-owned keyword matching ("translate", "अनुवाद") at the command router, same shape as the appliance helper's entry — no intent-encoder retraining. Session commands: "read this to me" (visible regions top-to-bottom via `SpeakQueue`), "stop", "always show original" toggle phrase. Consent gate for tier 2 (§7) presented on first cloud need with plain-language copy; visible cloud indicator while tier-2 is active (mirrors Open Decision 12's indicator requirement).

## 5. Data flow details (cadence and cost)

- OCR: ~4 fps on downscaled frames; `VNTrackRectangleRequest` on intermediate frames for smooth tracking (addendum §13.3).
- Region stability: 2-frame hysteresis both directions (§4.3).
- Translation fires only on region text change; multi-region scenes batch unresolved strings into one Gemini call; dedupe prevents duplicate in-flight requests for the same key.
- Cache: persistent, encrypted, keyed `(normalizedText|targetLang)`, seeded from the dictionary; general text entries use a simple LRU (≈200 entries) — label-vocabulary entries effectively never evict (addendum §13.2's saturation argument still holds for labels).
- Cost estimate per scene: a foreign menu page = 1 Gemini call for ~8–20 strings; repeat scenes (same restaurant) = 0 calls. The household appliance vocabulary saturates within a few sessions → effectively offline for daily use.

## 6. UI/UX (constitution standards)

- Full-bleed camera with minimal chrome; one large close button (≥ 44 pt); bubbles are the interaction surface.
- Voice-first: entry by voice; reading by tap or voice command. All spoken output via existing Piper voices (active-language voice selection already exists).
- Localization: all new UI strings externalized (String Catalog), including Devanagari rendering (existing support).
- High contrast bubble backgrounds (light/dark adaptive via existing `DesignTokens`).

## 7. Privacy & constitution impact

**Requires a recorded exception amendment before tier 2 ships** (owner action, mirroring Open Decision 12's shape):

- Scope: OCR'd *text only* (never images) may be sent to Gemini for translation, when the dictionary cannot resolve it and the user has consented. No photos, no health/contacts/profile data.
- Consent: explicit at first cloud need, plain-language disclosure, visible indicator while active, revocable (revert to dictionary-only = feature degrades to offline mode, never blocks).
- `Info.plist` `NSCameraUsageDescription` updated: live translation disclosed; text sent to the assistant's cloud service when needed.
- Log safety: translated text is content — same discipline as transcripts (no raw prints; `check-release-log-safety.sh` covers new paths; sanitizer audit in review).
- STRIDE threat model at security design review (constitution Standards). Threat to pay attention to: a malicious/compromised scene text feeding the cloud tier (injection) — treat OCR text as untrusted input to the prompt (same discipline as `InputSanitiser` for transcripts).

## 8. Error handling & degradation

| Failure | Behavior |
|---|---|
| No text in frame | Empty-state hint; no error |
| Dictionary miss, cloud unreachable/blocked/no consent | Bubble shows original + "offline" badge; never silently drops |
| Gemini transient error | One retry (configurable timeout, `GeminiClientError` semantics); then offline badge |
| Gemini block/policy error | No retry (existing semantics); offline badge |
| Cost governor cap hit | Fail closed to offline for the rest of the session; badge |
| Camera denied | Explanatory screen + Settings link (existing pattern) |
| Camera session interrupted | Pause/resume; overlays persist from cache |
| TTS failure | Visual translation remains; no retry loop (existing `SpeakQueue` degradation) |

All timeouts configurable parameters (constitution design-agent rules); no silent stubs.

## 9. Testing

- **Unit**: `TextRegionStabilizer` (scripted frame sequences: appear/hold/miss/change), decluttering rules, cache LRU/seeding, dictionary extension (exact-match rules), overlay mapper math (new cases), Gemini batch prompt builder, dedupe logic, plugin command parsing, consent-gate state machine.
- **Integration**: full pipeline with a stubbed tier-2 transport (deterministic, no network); Vision OCR against fixture images (runs on simulator); cache round-trip through encrypted storage.
- **Release gates**: `check-release-log-safety.sh` (no raw translation text in logs); consent/disclosure copy review before submission (aligns with OD-12 review); STRIDE at security review.
- **Manual device**: appliance panel scene, packaging, a dense menu page; verify stabilizer, decluttering, in-place/callout selection, offline degradation (airplane mode), tap-to-hear.

## 10. Open decisions

1. **OCR throttle rate** (addendum OD-11, still open): ~4 fps nominal; needs a device spike on mid-range hardware before commitment.
2. **In-place replacement default**: owner approved smart mix; the "always show original text" toggle ships with it. Confirm default = smart mix at first device demo.
3. **Consent copy + exception amendment wording**: draft alongside OD-12's review cycle (2026-10-13 window).
4. **Tier-1 timing (D2)**: v1.1 candidate; revisit addendum §13.5 non-goal, then model conversion (server pipeline, CoreML export) is its own SDD task.
5. **Menu-mode declutter thresholds** (§4.3 numbers): validated on device; may become per-scene settings.
6. **"Phrase card" reverse mode** (user language → scene language) for abroad use: out of v1 scope, natural v1.x extension reusing the pipeline.

## 11. Divergences from prior specs (collected)

| # | Prior spec says | This design says | Status |
|---|---|---|---|
| D1 | Addendum §13.3/§13.5: callout only, no text replacement | Smart mix: in-place only for short dictionary-known labels fitting ≥18 pt; callout everywhere else; toggle to callout-only | Owner-approved 2026-09-16 |
| D2 | Addendum §13.5: no on-device translation model | v1 identical (no model); v1.1 candidate NLLB-200 recorded as direction | Owner-approved 2026-09-16; revisit before v1.1 |
| D3 | Addendum §13.2: `LabelTranslationCache` in-memory, no LRU | Persistent encrypted cache, LRU for general text (labels still effectively non-evicting) | New requirement (abroad strings worth persistence) |
| D4 | Base design §0/§5.1: "never obscure/redraw reality" | Preserved for all non-in-place cases; in-place is bounded by D1's rule | Consequence of D1 |
| D5 | Addendum scope: appliance labels | Any printed text incl. dense multi-region scenes (menus) | Owner requirement (abroad scenario) |
