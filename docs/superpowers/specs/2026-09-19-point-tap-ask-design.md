# Design: Point, Tap & Ask (Phase 1 of 3)

**Date:** 2026-09-19
**Status:** Approved (research report: `docs/research-sections/2026-09-19-point-tap-ask-research.md`; all eight owner decisions accepted with the report's recommendations).

## 1. Approved decisions (locked)

1. **Constitution OD-14** — recorded photo-egress exception, wording per the report Q8 item 1: cropped-region-only egress to Gemini (answer) and optionally Google Vision webDetection (product provenance, Phase 2), plus barcode numbers to Open Food Facts (Phase 2); explicit consent at first cloud use, visible cloud indicator, revocable, master switch **default OFF**, degradation to the on-device answer, credential/log discipline per OD-12/13, re-reviewed with OD-11/12/13 by 2026-10-13.
2. Cloud default **OFF** — ladder-1 is a complete answer without egress.
3. Product vendor: Vision `webDetection` (Phase 2). SerpApi rejected (ToS), Bing retired, Rekognition redundant.
4. **Medicines:** the feature REFUSES to identify pill/medicine objects — answers route to "ask your doctor or family" (health-guideline safety). Enforced in Phase 1's prompt guidance + Phase 2's classification gate.
5. SearchTool CSE sunset: migration decision recorded as out-of-scope discovery.
6. Crop uploads ≤768 px JPEG, no EXIF.
7. On-device VLM deferred (Florence-2 memory risk) — Phases 1–2 are cloud-only for the VLM tier.
8. Point-ask daily cap: `GeminiCostGovernor` + `PointAskQuota` 50/day.

## 2. Pipeline (Phase 1 stages)

Tap → box+chip (<100 ms) → chip tap → parallel local passes (crop ≤15 ms, OCR 20–80 ms, classify 20–60 ms, dict/cache translation <150 ms) → consent gate → Gemini vision `identifyPointAsk` on the ≤768 px crop (1.5–6 s typical, 25 s timeout, one retry) → spoken answer first, card fills behind. Full stage/latency table in the research report §Q6.

## 3. Fallback ladder (honest, never fabricated)

1. No egress (default): box + OCR + dict-translate + classifier → *"It looks like a bottle. The label says: …"* — complete.
2. Quota-capped → announce cap, serve ladder-1.
3. Consent denied/revoked → cancel in-flight, ladder-1.
4. Cloud unconfigured → feature fully works on ladder-1; Settings leaf shows the state.
5. VLM low confidence (<0.4) → one grounded retry (Phase 2), then hedge line.
6. Transport/timeout/parse → one retry, then honest failure line.

## 4. State machine

`PointAskSessionModel` (`@Observable` + `ObservabilityBus` per stage): `.awaitingTap → .boxAnchored(point, box, chip) → .analyzing(progress) → .answered(spoken + card)`; `.failed` → retry/dismiss → `.awaitingTap`; `.consentPending` is a sheet (not a pipeline state). One box at a time; tap outside re-anchors; box ages out after 5 s without chip tap.

## 5. Consent

`PointAskConsentGate` mirrors `LiveTranslateConsentGate` (incl. `revoke()` and in-flight cancellation); `disclosureVersion = "pointask.disclosure.19sep2026.r1"`; `PointAskConfig.cloudEnabledDefault = false`; consent copy clones the shipped `livetranslate.consent.*` formula ("only that picture, never the rest… nothing until you agree… stop any time").

## 6. Phase 1 scope (this PR)

New (`Services/PointAsk/`): `PointAskConfig.swift`, `PointAskConsentGate.swift`, `PointAskSessionModel.swift`, `PointAskTargetResolver.swift` (tap hit-test vs `VisionObjectDetectionEngine` saliency boxes; `PointAskMaskEngine` wrapping `VNGenerateForegroundInstanceMaskRequest` behind a `supportsMasks` probe — opt-in, not default), `PointAskCrop.swift`, `PointAskAnalysisPipeline.swift`, `GeminiClient+PointAsk.swift` (`identifyPointAsk` via the existing `sendVision`; medicine refusal in the guidance).

Modified: `App/LiveTranslate/LiveTranslateOverlayView.swift` (tap box + chip), `LiveTranslateView.swift` (gesture plumbing), `AppCoordinator.swift` (host session), `Localizable.xcstrings` (`pointask.*` en+ne), `Info.plist` (camera purpose sentence mention).

Tests (`ElderlyAssistantTests/Services/PointAsk/`): consent gate (fail-closed, revoke cancels), target resolver (tap-in-box, tap-outside, stale cache), crop (pixel coords, ≤768 px, no EXIF), pipeline (stubbed engines; ladder-1 with cloud off; consent-gated VLM; medicine refusal), copy source-scan (no egress without Grant), `GeminiClientPointAskTests` (prompt/JSON decode, no network).

**Ship gate:** ladder-1 works with cloud OFF; consent fail-closed; device spike for mask-engine latency (opt-in stays behind the probe).

## 7. Phases 2–3 (after Phase 1 lands + device smoke test)

Phase 2: barcode + Open Food Facts, Vision `webDetection` provenance rows, amended disclosure + `disclosureVersion` bump. Phase 3: visually-similar rows, follow-up Q&A on the same crop, optional TinEye / Florence-2 spike / Visual Intelligence App Intent.

## 8. Verification

`ios/build.sh generate` + `check-release-log-safety.sh` + targeted `-only-testing` suites; Anzaan smoke: tap a moisturiser bottle → box+chip → cloud-off answer "looks like a bottle, label says…"; enable cloud + consent → full answer.
