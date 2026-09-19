# Point, Tap & Ask — Deep Research

**Status:** Research / Recommendation
**Date:** 2026-09-19
**Scope:** Design research for a "point, tap & ask" utility layered on the live camera: the elder
taps a region; the app draws a box around the object there; a "what is this?" chip appears; tapping
it runs OCR + translation of any text in the box (existing capability), object/product detection,
an optional reverse-image search, and finally a spoken + card answer. This report answers the eight
research questions, proposes the pipeline, state machine, consent wording, and a 3-phase plan in
this codebase's own patterns. Report only — no code was written and no file other than this one
was modified.
**Companion artifacts (repo, read-only):** `constitution.md` (AC-1, OD-12/OD-13),
`ios/ElderlyAssistant/Services/LiveTranslate/` (consent gate, tiers, object pass),
`ios/ElderlyAssistant/Services/Gemini/GeminiClient+Vision.swift`,
`ios/ElderlyAssistant/Services/Voice/SearchTool.swift`,
`ios/ElderlyAssistant/Resources/Localizable.xcstrings` (consent copy),
`ios/ElderlyAssistant/Info.plist` (camera disclosure).

---

## Findings

### Q1. On-device object detection + bounding box at the tapped point

**The shortest path already ships in this repo.** `LiveTextDetector.swift` contains
`VisionObjectDetectionEngine` — the shipped "object pass" — which composes exactly the two
requests this feature needs on device:

1. **Where.** `VNGenerateObjectnessBasedSaliencyImageRequest` (iOS 13+) returns
   `salientObjects`: normalized `VNRectangleObservation` bounding boxes of the distinct
   object-like regions in the frame. Class-agnostic, no model download, runs on the ANE/GPU.
   Run at `objectPassCadenceSeconds = 2` already (`LiveTranslateConfig.swift`).
2. **What.** `VNClassifyImageRequest` with `regionOfInterest` set to one box returns the
   classifier's top label for that crop — Apple documents **~1,300 ImageNet-derived labels**
   ("remote control", "television", "microwave", "bottle", …). Categories only — no brands,
   no fine-grained product identity — but the right tier-0 gist. It is also the fallback
   "answer" when everything else is unconfigured.

**Important 2026 fact verified against the shipped SDK (repo comment, `LiveTextDetector.swift`
header):** `VNRecognizeObjectsRequest` (the old built-in object detector with labels + boxes)
was deprecated in iOS 13 and **is absent from the iOS 26.5 SDK headers entirely**.
`VNRecognizedObjectObservation` survives only via `VNRecognizeAnimalsRequest` (dogs/cats).
Any design that says "use VNRecognizeObjects" is wrong on current SDKs — the composed
saliency + classify pass is the correct replacement and is already implemented and tested.

**The other candidates, ranked for this feature:**

| API | Box/mask? | Notes |
|---|---|---|
| `VNGenerateObjectnessBasedSaliencyImageRequest` (iOS 13+) | Boxes | Already shipped + tested here. Fast (tens of ms). Boxes are coarse (object-ish regions, may merge two close objects). |
| `VNGenerateForegroundInstanceMaskRequest` (iOS 17+, Swift redesign `GenerateForegroundInstanceMaskRequest` iOS 18+) | Per-instance masks | Class-agnostic foreground instance segmentation, built into the OS, no download. Returns `VNInstanceMaskObservation` (`allInstances` IndexSet + `instanceMask` UInt8 CVPixelBuffer, 0 = background) and `generateScaledMaskForImage(forInstances:from:)`. WWDC23 session 10176 ("Lift subjects from images in your app"). On-device, "fast" per Apple and practitioner reports; **no published latency number — a device spike is required**. Fails on the iOS Simulator with "Could not create inference context" (Vision error 9) — real-device testing only. Redesigned Swift API in iOS 18. |
| `VNClassifyImageRequest` | No boxes | Labels only; combine with `regionOfInterest`. Already used. |
| `VNDetectRectangles` / `VNDetectContours` | Boxes/contours | Geometric, not semantic — not an object detector. |
| `VNGenerateAttentionBasedSaliencyImageRequest` | Heat map | Attention (what a human looks at), not object extent; objectness is the right sibling. |
| YOLO family via Core ML | Boxes (+NMS) | See below. |
| `VNDetectBarcodesRequest` (iOS 11+) | Boxes + symbology + payload | Not object detection, but the single highest-value *product* signal on device — see Q2. |

**YOLO on ANE (2025/2026 evidence):** YOLO11n converted to Core ML (`yolo11n-coreml-fp16`,
Hugging Face `SharpAI/yolo11n-coreml-fp16`) runs ~8.77 ms average inference on Mac arm64
(114 FPS), COCO mAP@0.5 = 41.7 % for that export (fp32 export: 16 ms). On-device reports for
iPhone: ~1.2–2.1 ms ANE forward pass on an A17-class device (CSDN mobile-game write-up,
0.7 W), and ~30 ms full detection time in a SwiftUI iOS 18 app (`chenyuqing/yolo11-ios`).
The honest envelope is **~2 ms (bare ANE forward) to ~30 ms (app-level, pre/post + NMS
included) on iPhone 14 Pro Max-class hardware; end-to-end mobile pipelines can reach
100–150 ms/frame** once capture and I/O are counted. YOLO11n mAP is ~56 mAP@0.5 / ~39.5
mAP@50-95 on COCO. It buys 80 classes with fine boxes at the cost of a 5–50 MB model +
custom NMS wiring — and COCO's 80 classes are no better for *product identity* than
Vision's classifier.

**Recommendation (fastest path to "box around the object at the tapped point"):**
**Use what is already shipped.** On tap, hit-test the tap point against the existing
`VisionObjectDetectionEngine` boxes (re-run the saliency pass on the current frame if the
2 s cache is stale — one request, tens of ms). That gives the chip a box with zero new
model infrastructure. **Phase-1 quality upgrade (spike, not default):** swap the box source
for `VNGenerateForegroundInstanceMaskRequest` — read the instance label at the tapped pixel,
then derive the bounding box from the mask's row/column extents (vImage/Accelerate extents,
or `VNGeometryUtils`/contour scan). Masks give an object-shaped box that handles overlapping
objects and avoids the saliency pass's "two objects merged into one region" failure, but they
cost a fresh Vision request per tap and need a real-device latency spike before adoption.
**YOLO11n is not needed for Phase 1–2** — adopt only if a later phase wants custom/COCO-class
boxes at video cadence (tracking many objects), not for tap-to-identify.

### Q2. Product recognition options, 2026 reality check

The landscape moved a lot in 2025–2026. Two of the four classic answers are dead or dying,
and the "Google Lens API" does not exist as a search API.

| Option | Status (2026-09) | Cost | Accuracy for product ID | Legal/ToS safety |
|---|---|---|---|---|
| **Google Cloud Vision `webDetection`** | **Alive.** Not on the official deprecations page (only Celebrity Recognition and OCR On-Prem were deprecated, 2024-09-16, shut down 2025-09-16). Proto still active (2025–2026 copyrights). | First 1,000 units/month **free per feature**, then **$3.50 / 1,000** units. Default project quota ≈ 1,800 requests/min (configurable). | Good for *entity* level: `webEntities` (Knowledge-Graph IDs), `bestGuessLabels`, `fullMatchingImages`, `pagesWithMatchingImages`, `visuallySimilarImages`. Identifies branded products as entities ("Coca-Cola", "Panadol") with pages; not a product catalog with SKU prices. | Clean: official API, own key, own ToS. App-Store-safe. |
| **Google Lens via SerpApi** (`engine=google_lens`) | Unofficial scraper. Tabs `all`, `exact_matches`, `products`, `visual_matches`, `about_this_image`. **The `products` tab is the best raw "what product is this" signal anywhere** (matches to shopping results). | Free 250 searches/mo; Starter $25/mo per 1,000; Developer $75/5,000; Legal Shield only at Production $150/mo+. | Highest raw product-match accuracy (it *is* Lens). | **ToS risk: high.** Scraping Google violates Google's ToS; Google's DMCA suit against SerpApi is **live — first complaint dismissed July 2026, amended complaint pending**. No legal shield below $150/mo. Not recommendable for an App Store consumer app. |
| **Bing Visual Search API** | **DEAD.** Microsoft retired the entire Bing Search APIs suite (Web, Image, News, Video, Visual, Autosuggest, Entity, Spell Check, Custom) — announced 2025-05-15, **retired 2025-08-11**; keys decommissioned. No Azure replacement for reverse image search; Microsoft's own docs point to Google Vision or TinEye. | — | — | — |
| **Google Vision Product Search** | **Maintenance mode.** Not shut down, but no new development; Vision Warehouse is the replacement. Not worth building on. | — | — | — |
| **Amazon Rekognition `DetectLabels`** | Alive. | $0.001/image (first 1M/month), 5,000 images/mo free for 12 months. Custom Labels: $1/hr training + $4/hr inference (provisioned — expensive). | ~3,000 generic labels with hierarchy. Fine as a second opinion on category; **weak for "which product/brand is this"** — no SKU/product catalog. | Clean. But adds an AWS account + key to the household's setup. |
| **On-device `VNClassifyImageRequest`** | Already in repo. | Free, offline. | ~1,300 ImageNet labels — category gist only ("bottle", "packet", "remote"). **Not a product ID.** It is the honest tier-0 answer and the degrade-state answer. | Perfect. |
| **On-device barcode → Open Food Facts (OFF)** | Alive and free. `VNDetectBarcodesRequest` (EAN-13/UPC/QR/etc., iOS 11+) reads the number on device; `GET https://world.openfoodfacts.org/api/v3/product/{code}` returns name/brand/ingredients. **No API key** (User-Agent identification required), ~15 product reads/min/IP, 3M+ products, ODbL data, v3 still marked "under development". Nepal-specific coverage is thin — treat as opportunistic. | Free. | Exact, when a barcode exists and is in the DB — the only *deterministic* product ID on the table. | Cleanest of all cloud options: **only the 13-digit number leaves the device, never a photo.** |

**Ranking for product identification in this app:** (1) **barcode → OFF** for food/packaged goods
(privacy-optimal, free, deterministic); (2) **Gemini VQA with Google Search grounding** — the app's
own cloud brain answering "what is this product?" from the photo, optionally grounded in live search
(the `google_search` tool is already wired and verified live in `GeminiClient+Vision.swift`); (3)
**Vision `webDetection`** for entity labels + image provenance; (4) SerpApi Lens — reject on ToS
grounds; (5) Rekognition — reject as redundant (adds an AWS dependency for labels Vision's
classifier already gives roughly for free).

### Q3. Public + App-Store-safe reverse image search APIs in 2026

The honest summary: **this category is contracting, not growing.**

- **Google Custom Search JSON API `searchType=image`** — the long-standing "public reverse
  image search" (image *query*-search, not pixel search): **closed to new customers** (doc
  update 2026-02-18: "This API is not available for new customers") and **discontinued
  2027-01-01**. Existing keys keep 100 free queries/day ($5/1,000 beyond) until then.
  **This directly affects the shipped `SearchTool`:** its credential onboarding (`SearchConfigStore`)
  is already non-functional for NEW households — an owner decision is needed (see Open Decisions).
- **Bing Image / Visual Search** — retired 2025-08-11 (see Q2). Gone.
- **Google Cloud Vision `webDetection`** (`visuallySimilarImages`, `fullMatchingImages`,
  `pagesWithMatchingImages`) — the only remaining *official Google* "find similar images /
  pages for this picture" API. $3.50/1,000 after the 1,000/mo free tier. Returns image URLs +
  page URLs, not shopping links. This is the recommended Phase-3 engine.
- **TinEye API** — alive, commercial, clean ToS. Prepaid bundles: $200 / 5,000 searches
  ($0.04), $1,000 / 50,000 ($0.02), 2-year validity, no free tier. Fine as an opt-in
  add-on; pricey for a household assistant.
- **SerpApi / Bright Data / Oxylabs scrapers** — exist and work, but are unofficial
  scrapers of Google; ToS risk (Q2) and the app would be reselling scraped Google data to
  elders. Rejected.
- **Gemini "Grounding with Google Search"** — the *official* replacement for "search the
  web about this image", and it is already implemented in this repo (`google_search` tool,
  opt-in). It returns a grounded prose answer + `groundingSupports` source URLs, not an
  image list; the Gemini license requires displaying the returned Google links. Free up to
  500 grounded requests/day (free tier) or 1,500/day (paid tier), then **$35 / 1,000
  grounded prompts**. This is the highest-value "search" stage for the elder — the answer,
  not raw image hits.

**Recommendation:** skip a standalone reverse-image-search API in Phases 1–2. Phase 3 uses
`webDetection` provenance (images/pages for the card) and, only if the owner wants a
commercial similar-image engine, TinEye. The grounded Gemini answer covers the elder's
actual need ("what is this, where is it from") without a raw hit list.

### Q4. Multimodal Q&A over the cropped image

**Prompt shape — follow the shipped convention, add a second variant.** The repo already has
the right shape: `GeminiClient+Vision.swift::identifyPrompt(question:languageHint:)` — a
persona line ("Sahayak's visual helper for an elderly speaker"), an honesty clause ("you do
not have access to any manual or external database, so never claim to be quoting one"),
a strict single-JSON-object contract, normalized 0–1 boxes, and a reply-language directive.
For point-tap, add `identifyPointAsk` with a `PointAskGuidance` contract:

```
{ "identity": { "category": string, "brand": string|null, "model": string|null, "displayName": string },
  "answer": string,                       // plain-language answer to the user's question
  "spokenSummary": string,                // ≤2 sentences for TTS, in the user's language
  "confidence": number,                   // 0-1
  "needsProductSearch": boolean,          // true → the app should run the Phase-2 product tier
  "hedge": boolean }                      // false-positive guard; spoken with appliance.hedgeNotice
```

Reuse the existing plumbing wholesale: same `sendVision` transport (one auth/timeout/
observability chokepoint), same JSON-mode decode with the outer-`{...}` tolerant slice
(`decodeGuidance`), same `groundedControls`-free policy. Attach the **cropped region**
(not the full frame) as `inlineData`; optionally attach the full frame as a second part only
when the model reports `needsProductSearch: true` on a retry (context matters for product
labels) — and only then, because the crop is the privacy-minimal default (mirrors OD-13's
"only the text, never the picture" spirit).

**On-device VLM viability — confirmed NO for the current models, and a cautious maybe for a
future one.** The project's on-device stack is text-only: the 1B/1.7B Qwen NMT fine-tunes
(`nmtEnNeQwen17bR2bQ4/Q8`) and the 4B intent brain (`intentQwen4BS43`) are GGUF text
transformers run through llama.cpp (`n_ctx` 1024, `json_schema` outputs). **None has a
vision tower; none can take pixels.** They cannot answer "what is in this picture" — the
cloud VLM is the only viable answer tier today.

On-device VLM candidates exist but none is a drop-in:
- **Florence-2 (0.23B, Microsoft)** — Core ML port exists (`mlboydaisuke/Florence-2-base-CoreML`,
  229 MB in three packages, iOS 17+, **cpuOnly** by necessity — FP16/ANE conversions hit
  attention overflow and crashes; peak RAM ~1.2 GB; autoregressive decode loop in Swift).
  Mac arm64 reference: 59.7 ms vision encoder + 4.7 ms/token decode → **~0.14 s for a
  15-token caption**; no iPhone numbers published. Supports `<OD>` open-vocabulary
  detection, `<CAPTION>`, `<REGION_PROPOSAL>` — a genuinely useful on-device tier.
- **moondream2 (1.8B)** — ~0.9 s on Jetson-class edge (2026 IPDPSW benchmark); no
  maintained iPhone Core ML numbers; ~1.5 GB resident.

Given this repo's own 2026-09-19 memory-pressure history (1.4 GB live-camera footprint on a
5.5 GB device, jetsam kills, the 30 s critical-pressure window in `LiveTranslateConfig`),
**adding a 1.2 GB-peak cpuOnly model alongside the camera is a real kill risk.** Verdict:
cloud-only for the VLM answer in Phases 1–3; a Florence-2 spike is a Phase-3 optional
experiment behind the same pressure-safety discipline (`ModelBudgetPolicy`/headroom checks).

**Cost per VLM query (gemini-2.5-flash-lite, the shipped default model):** input $0.10/1M
tokens (images billed as ~258 tokens ≤384 px, ~1,290 tokens for larger images) ≈ **$0.00013
per 768 px crop**; a ~300-token JSON answer ≈ $0.00012 output. Negligible per query; the
real cost lever is grounding ($35/1,000 after free allowance) and the existing
`GeminiCostGovernor` (soft daily cap 200) stays the single cap (OD-7: one cap, never two).

### Q5. Constitution / privacy split and the consent pattern

**What must be cloud vs on-device:**

- **On-device (constitutional default, no egress):** tap → box (saliency or instance mask),
  crop, OCR (`VNRecognizeTextRequest`), tier-0 dictionary translation + cached translations,
  tier-1 on-device brain translation (OD-13's existing tiers), `VNClassifyImageRequest`
  class, barcode reading. These give the complete **degrade-state answer** ("It looks like
  a bottle. The label says: …") with zero egress.
- **Cloud (must be consent-gated):** (a) the cropped photo to Gemini for the VLM answer —
  this is a **new egress class (images)** beyond OD-12 (voice) and OD-13 (text), though
  strictly a sibling of the already-shipped, already-disclosed appliance-photo path
  (`Info.plist` discloses it); (b) the cropped photo to Google Vision `webDetection` for
  product/provenance; (c) optionally the barcode number to Open Food Facts (a number, not a
  photo — disclose it in the same wording family); (d) grounding searches inside Gemini.
- **Privacy mechanics to copy:** crop-only egress (never the full frame), downscale to ≤768 px
  JPEG for upload, strip EXIF/GPS (the capture path already owns frames; the crop must be
  re-encoded, never the original), `size_bucket`-only logging (no photo, no brand in
  metadata — `GeminiClient+Vision`'s existing T-050/B2 discipline), key in `EncryptedLocalStorage`
  header-only transport, `InputSanitiser` on OCR text entering prompts.

**Consent wording — copy the shipped `livetranslate.consent.*` pattern exactly.** The house
formula (from `Localizable.xcstrings`): *what leaves* (with an "only X, never Y" scope
sentence) + *where it goes* ("the assistant's cloud service") + *nothing until you agree* +
*revocable any time*. Proposed `pointask.consent.*` keys (en; ne to be authored in the same
voice — short Nepali sentences, the existing translations are the tone reference):

- `pointask.consent.title` — "Use the internet to look at the picture?" / ne: "तस्बिर हेर्न इन्टरनेट प्रयोग गर्ने?"
- `pointask.consent.body` — "When you tap 'what is this?', the small picture of the thing
  you tapped — only that picture, and nothing else from your camera — is sent to the
  assistant's cloud service to work out what it is. Nothing is sent until you agree, and
  you can stop it any time."
- `pointask.consent.grant` — "Yes, use the internet" / decline: "No, keep it on this phone"
  (reuse the exact existing strings for these two buttons).
- `pointask.cloudIndicator.label` — "Looking online" (mirror of "Translating online").
- `pointask.settings.cloud.title` — "Use online object recognition (Gemini)" and
  `pointask.settings.cloud.note` — "When this is off, the phone only tells you what it can
  see by itself — nothing is sent anywhere."

Gate mechanics: a new `PointAskConsentGate` mirroring `LiveTranslateConsentGate` — four-state
`Decision` (`granted`/`notRecorded`/`denied`/`unreadable`), a private-initialiser `Grant`
proof the request builder must take (compile-error-if-missing, AM-7), read-through
`authorize()` per attempt, versioned record (`disclosureVersion =
"pointask.disclosure.19sep2026.r1"`, new storage key `plugin.point_ask.consent.v1`),
deny-first revocation with read-back verification and in-flight cancellation. Plus the
**master switch** pattern from `geminiCloudEnabledDefault = false`: the point-ask cloud tier
is **off by default** — the elder opts in from the feature's Settings leaf, and the switch is
a policy, not consent (the gate still enforces per attempt). `Info.plist`
`NSCameraUsageDescription` gains one sentence: "When you tap 'what is this?', the small
picture of the tapped thing — only that picture — is sent to the assistant's cloud service
to work out what it is." The constitution gains a recorded exception (**Open Decision 14**,
see Open Decisions) in the OD-12/OD-13 shape, since the photo is a new egress class.

### Q6. Pipeline, latency budgets, parallelism, fallback ladder, state machine

**Stage table (iPhone 14 Pro Max-class, iOS 26, ANE):**

| # | Stage | Where | Budget (honest) | Parallel? |
|---|---|---|---|---|
| 1 | Tap → hit-test existing saliency boxes (refresh pass if cache stale) | on-device | <50 ms | — |
| 2 | Crop at pixel coords; ≤768 px JPEG re-encode for cloud, full-res crop for OCR | on-device | <15 ms | with 3–6 |
| 3 | OCR on crop (accurate, language correction on) | on-device | 20–80 ms | with 2,4,5,6 |
| 4 | Translate OCR text: dict → cache → brain (25 s deadline) → cloud text tier (existing OD-13 machinery, consent already applies) | on-device → cloud-text | <150 ms typical; brain ≤28 s deadline | with 2,3,5,6 |
| 5 | Classify crop (`VNClassifyImageRequest`, regionOfInterest) | on-device | 20–60 ms | with 2,3,4,6 |
| 6 | Barcode read (`VNDetectBarcodesRequest`) + OFF lookup (number only) | on-device + 1 GET | 20–50 ms + 200–600 ms network | with 2,3,4,5 |
| 7 | VLM answer: `identifyPointAsk` on the crop (flash-lite; 6 s typical, 25 s timeout, 1 retry) | cloud, consent-gated | 1.5–6 s | after 2–6 (needs crop + text) |
| 8 | Product/provenance tier: `webDetection` (Phase 2) | cloud, consent-gated | 300–900 ms | with 7 (card fills behind the spoken answer) |
| 9 | Spoken answer (TTS, `SpokenTimeFormatter`-class discipline for any spoken words) | on-device | first byte <200 ms | starts when 7 or fallback 5+4 lands |
| 10 | Card render (answer + translated text + class + provenance rows) | on-device | with 9 | fills as 8 lands |

Tap → box + chip: **<100 ms**. Tap chip → spoken answer: **~2 s typical, 6 s p95
(cloud); <1 s in the no-egress path.** Card provenance may trail the spoken answer by
~1 s; the card has a pending row, never a spinner that blocks speech.

**Fallback ladder (the repo's honest per-stage degradation, `CloudTranslationTier`
cascade shape):**

1. **No egress at all (default, consent absent or cloud switch off):** box → OCR → dict/cache
   translate → classify → barcode/OFF if food. Answer: "It looks like a bottle. The label
   says: …" — spoken + card, `hedge` applied. This is a *complete* product answer, not an
   error state.
2. **Quota-capped** (`GeminiCostGovernor.softDailyCap` hit, or `SearchQuota`-style daily
   point-ask cap): announce the cap (mirror `search.capReached`), serve the ladder-1 answer.
3. **Consent denied/revoked mid-flight:** in-flight registration cancelled, no retry
   (`LiveTranslateConsentGate` AM-1), ladder-1 answer.
4. **Cloud unconfigured (no key):** feature still fully works on ladder 1; the Settings leaf
   shows the unconfigured state (mirror `searchSettings.statusConnected`).
5. **VLM low confidence** (`confidence < 0.4`): retry once with `needsProductSearch` +
   grounding (opt-in tier, costs a real search — the `ApplianceHelperSession` pattern);
   on second low confidence, speak the hedge line (`appliance.hedgeNotice`: "I'm not
   completely sure about this — please double-check yourself.").
6. **Transport/timeout/parse failure:** one retry, then spoken honest failure (reuse the
   live-translate failure copy style) — never a fabricated answer, never a silent empty card.

**View-model state machine** (`PointAskSessionModel`, house pattern of one `@Observable`
model + `ObservabilityBus` events per stage):

```
                     tap(chip hidden) / tap outside box / box aged out (5 s no chip tap)
        ┌──────────────────────────────────────────────┐
        ▼                                              │
  .awaitingTap ──tap──▶ .boxAnchored(point, box, chip) ─┼──chipTap──▶ .analyzing
        ▲                    │  (chip visible)          │               │ stages:
        │                    │                          │               │  ocr → translate
        │                    └───── box moves/retires ──┘               │  classify → barcode
        │                                                              │  [consent gate] → vlm
        │   newTap                                                      ▼
        └──────────── .answered(spoken + card) ◀──── (any stage lands a spoken-able result)
               │
               ▼
        .failed(error) ──retry / dismiss──▶ .awaitingTap        (consent pending opens the
                                                                 ConsentView; deny → ladder-1
                                                                 answer, not .failed)
```

Phases/states: `.awaitingTap`, `.boxAnchored`, `.analyzing(progress)`, `.answered`,
`.failed` — plus `.consentPending` as a presentation sheet, not a pipeline state (mirror
`ConsentPromptController`). Revocation from Settings during `.analyzing` cancels in-flight
work via the gate's `registerInFlight` and falls to ladder 1. One box at a time; a new tap
re-anchors (the elder's hand tremor makes a two-finger two-box gesture a non-goal).

### Q7. Risks

- **App Store review exposure: LOW for the category itself.** Apple ships Visual
  Intelligence (camera → object analysis → LLM answer) as a system feature, and since
  WWDC25 third-party apps can *participate* in it via App Intents
  (`@AppIntent(schema: .visualIntelligence.semanticContentSearch)` with
  `IntentValueQuery`/`SemanticContentDescriptor`). "Point camera at object, get answer" is
  a blessed pattern, not a novel review risk. The real review exposure is **Guideline
  5.1.1 (privacy disclosures)** — photo egress must appear in the App Privacy label and
  purpose string — and **health-adjacent claims**: if a pill bottle is tapped, the answer
  must never make medical claims (Guideline 1.4.1 territory). Route medicines to "ask your
  doctor / ask your family" or refuse the class entirely (owner decision).
- **ToS risks:** Gemini API and Vision API use — clean (own keys, official APIs, no
  scraping; Gemini grounding requires displaying returned source links — the card's
  provenance rows satisfy this). SerpApi/Bright Data scraping — **rejected** (Google DMCA
  litigation against SerpApi ongoing into 2026). Open Food Facts — clean (keyless, ODbL,
  User-Agent identification + rate courtesy required).
- **Privacy:** a product photo can capture a home interior, a hand, a medicine label —
  identifiable household context. Mitigations: crop-only (the tapped box, never the frame),
  ≤768 px re-encode (strips most readable detail beyond the label), no EXIF/GPS, no
  photo in logs (size buckets only), consent gate + master switch + visible cloud
  indicator during any egress, revocation cancels in-flight requests. This is materially
  better than the already-shipped appliance path (full photos, disclosed in Info.plist).
- **Cost per query (worst realistic case, all cloud tiers on):** VLM ~$0.00025 +
  webDetection $0.0035 + one grounded retry $0.035 (only after the 1,500/day free
  grounding allowance) ≈ **$0.04 worst case; ~$0.004 typical**. At the shipped governor cap
  (200/day) that is a family-editable ceiling, exactly as today.
- **Latency worst case:** brain stage 28 s deadline + cloud 25 s timeout + 1 retry ≈ ~60 s
  before an honest failure is spoken; mitigated by per-stage deadlines, the ladder-1
  answer being local and instant, and speech-first ordering (speak what is known, card
  catches up).
- **Memory/jetsam:** adding any on-device VLM (Florence-2, 1.2 GB peak) next to the 1.4 GB
  camera stack on a 5.5 GB device is a kill risk per this repo's own 2026-09-19 evidence —
  keep Phase 1–2 cloud-only for the VLM tier.

### Q8. Phased plan (smallest first, this repo's file/test patterns)

**Phase 1 — Tap → box → crop → OCR/translate + Gemini "what is this" (no new cloud vendors).**
New: `Services/PointAsk/PointAskConfig.swift` (single `Equatable` config: consent
`disclosureVersion = "pointask.disclosure.19sep2026.r1"`, `cloudEnabledDefault = false`,
crop pad fraction, `maxUploadSide = 768`, stage timeouts, hedged thresholds);
`PointAskConsentGate.swift` (mirror `LiveTranslateConsentGate` incl. `revoke()`);
`PointAskSessionModel.swift` (state machine above); `PointAskTargetResolver.swift` (tap
hit-test against `VisionObjectDetectionEngine` boxes + a `PointAskMaskEngine` wrapper around
`VNGenerateForegroundInstanceMaskRequest` behind a `supportsMasks` probe — spike, not
default); `PointAskCrop.swift` (pixel-coord crop; JPEG re-encode; no EXIF);
`PointAskAnalysisPipeline.swift` (parallel local passes, then consent-gated VLM);
`GeminiClient+PointAsk.swift` (`identifyPointAsk`, reuse `sendVision`).
Modified: `App/LiveTranslate/LiveTranslateOverlayView.swift` (tap box + chip),
`App/LiveTranslate/LiveTranslateView.swift` (gesture plumbing), `AppCoordinator.swift`
(host the session), `Localizable.xcstrings` (`pointask.*` keys), `Info.plist` (camera
sentence). Tests (in `ElderlyAssistantTests/Services/PointAsk/`): `PointAskConsentGateTests`,
`PointAskTargetResolverTests`, `PointAskCropTests`, `PointAskAnalysisPipelineTests`
(stubbed engines), `PointAskCopyTests` (source scan: no image egress without a Grant —
mirror `FeatureSourceScan.swift`), `GeminiClientPointAskTests` (prompt/JSON decode, no
network — mirror `GeminiClientVisionTests`).
**Ship gate:** ladder-1 answer works with the cloud switch off; consent gate fail-closed;
device spike for mask-engine latency (mask opt-in stays behind the probe).

**Phase 2 — Product detection (barcode + webDetection).**
New: `PointAskBarcodeReader.swift` (`VNDetectBarcodesRequest`), `Services/PointAsk/ProductLookupTool.swift`
(Open Food Facts client in the `SearchTool` house pattern: pure URL construction + parsing,
source line "— openfoodfacts.org", `isFoodBarcode` gate, ~15/min courtesy throttle),
`PointAskWebDetectionClient.swift` (Vision `webDetection`; key via a
`PointAskCloudConfigStore` mirroring `SearchConfigStore`; `webEntities`/`bestGuessLabels` →
card provenance rows), quota via existing `GeminiCostGovernor` + a `PointAskQuota` daily
attempt cap (mirror `SearchQuota`, 50/day). Tests mirror `SearchToolTests` and the
LiveTranslate tier tests. Consent: one amended disclosure ("…and to look up the product on
the internet") → `disclosureVersion` bump invalidates stale grants (the C09 mechanism).

**Phase 3 — Reverse-image search + richer QA (+ optional bets).**
`webDetection` `visuallySimilarImages`/`pagesWithMatchingImages` rows on the card; follow-up
Q&A over the same crop (`getApplianceInstructions` pattern → `askFollowUp`); optional TinEye
client behind the same gate; optional Florence-2 spike (cpuOnly, pressure-gated, never
co-resident with the camera + brain); optional Visual Intelligence App Intent
(`semanticContentSearch` schema) so Sahayak appears in Apple's own visual search results.

## Open owner decisions

1. **Constitution OD-14 (photo-egress exception).** Proposed recorded amendment, in the
   OD-12/OD-13 shape: "**Cloud object-identification exception (point, tap & ask).** The
   point-tap feature resolves what the on-device layers cannot answer (object identity and
   product provenance) by sending the CROPPED region the user tapped — never the full
   camera frame — to Gemini (answer) and optionally Google Vision webDetection (product
   provenance), plus barcode numbers to Open Food Facts. Explicit consent at first cloud use
   with plain-language disclosure; visible indicator while cloud is active; revocable at any
   time, revocation degrades to the on-device answer (OCR + dictionary + classifier), never
   blocks the feature; master switch default OFF; credential/header and log-safety discipline
   per OD-12/OD-13; re-reviewed with OD-11/12/13 by 2026-10-13."
2. **Cloud default OFF vs ON.** Recommend OFF (`geminiCloudEnabledDefault = false`
   precedent): the ladder-1 answer is complete without egress; opt-in is the elder's choice.
3. **Product-search vendor.** Recommend Vision `webDetection` (official, priced, clean);
   SerpApi Google Lens rejected on ToS grounds; Rekognition rejected as redundant.
4. **Medicine/pill objects.** Refuse to identify medicines (health-guideline risk) or route
   to a "ask your doctor/family" response — decide before Phase 2.
5. **SearchTool CSE sunset.** Google CSE JSON API is closed to NEW customers and ends
   2027-01-01 — the shipped `SearchTool` cannot be configured by new households today.
   Owner decision needed on migrating text search (e.g., SerpApi web search) — outside this
   feature's scope but discovered by this research.
6. **Upload crop resolution.** ≤768 px JPEG recommended (privacy + cost); confirm.
7. **On-device VLM investment.** Florence-2 spike now (memory-risk) or defer post-Phase 3.
8. **Point-ask daily attempt cap.** Reuse `GeminiCostGovernor` (OD-7: one cap) + a
   `PointAskQuota` 50/day mirroring `SearchQuota` — confirm the number.

## Executive summary

Point-tap-and-ask is buildable almost entirely from parts this codebase already ships: the
tap-box answer is the existing `VisionObjectDetectionEngine` (objectness saliency +
`VNClassifyImageRequest` — already the correct replacement for the `VNRecognizeObjectsRequest`
API that no longer exists in the iOS 26 SDK), the crop feeds the existing OCR/dictionary/brain
translation tiers, and the "what is this" answer is a prompt variant of the shipped
`identifyAppliance` Gemini vision path (flash-lite, ~$0.0003/query) — so Phase 1 adds a
consent gate, a crop, a state machine and L10n copy, and no new vendors. The 2025–2026
vendor landscape dictates the cloud tiers: Bing Visual Search is dead (Aug 2025), Google's
CSE image search is closed to new customers (ending Jan 2027), SerpApi's Google Lens is
ToS-risky (live Google litigation), leaving Google Vision `webDetection` ($3.50/1k after a
free tier) as the clean product/provenance engine, on-device barcode → Open Food Facts as
the free deterministic product path, and Gemini Search-grounding as the official
"search about this picture" answer (free to 1,500/day, then $35/1k). On-device VLMs are
confirmed out of reach for the current 1B–4B text-only brains, with Florence-2 a
memory-risky Phase-3 option. Constitutionally the photo crop is a new egress class needing
a recorded OD-14 exception and a consent gate cloned from `LiveTranslateConsentGate`, with
wording in the shipped `livetranslate.consent.*` formula ("only that picture … nothing is
sent until you agree … you can stop it any time"), a cloud tier defaulted OFF, and an
honest fallback ladder whose no-egress state is already a complete answer — the box, the
label text, and "it looks like a bottle." App Store exposure is low (Apple's own Visual
Intelligence blessed the category), with the real review attention on photo-egress
disclosure and refusing medicine identification.
