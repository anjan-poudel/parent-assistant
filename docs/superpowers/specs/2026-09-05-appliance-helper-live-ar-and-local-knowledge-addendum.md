# Appliance/Vision Helper — Live AR + Local Manual Knowledge (Addendum)

Branch: `v2-gemini-flash-lite`. Revises: `docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md`
("the base design"). Status: **first-pass design, awaiting review.**

## 0. Why this addendum, not a rewrite

The base design (static photo → one Gemini call → circle-overlay-on-the-photo) is sound and
mostly unchanged by this addendum — its data model, cache, error handling, and cost/telemetry
sections all still apply. Two requirements came in after it was written that the base design
explicitly scoped OUT (its own §9 "What is explicitly NOT built"):

1. **"Not always Gemini's own knowledge — for some appliances, download manuals to build local
   knowledge, and store that knowledge locally."**
2. **"Live AR — button translation via camera view,"** not a one-shot photo.

Both are real architecture changes, not parameter tweaks, so this is a proper addendum, not an
edit to the base doc. Section numbers below are new (§12+) to avoid colliding with the base
doc's §1–11.

## 12. Manual/local-knowledge fallback — verified approach, not a PDF pipeline

### 12.1 What "download manuals" should actually mean here

Building our own manual-fetching pipeline (search the web, find a PDF, download it, parse it —
often scanned-image PDFs with no text layer) is a real project: legal/copyright exposure for
redistributing manufacturer PDFs, OCR-on-PDF quality variance, and a maintenance burden that
doesn't decay (manuals move URLs, get taken down, formats vary). Before designing that, I tested
whether Gemini's own **search-grounding tool** covers the actual need — it does:

**Verified live (2026-09-05)**, this API key, `gemini-2.5-flash-lite`, request with
`"tools": [{"google_search": {}}]` added to a normal `generateContent` call, asking about a real
microwave model and how to boil water for tea — returned a real, correct, cited answer
(`groundingMetadata.searchEntryPoint` present in the response), with zero code changes beyond
adding that one `tools` field to the existing request shape.

**This means:** we don't fetch or parse a manual at all. Gemini does the web search and
synthesis server-side; we send the same photo+question we already send, just with grounding
enabled, and get back the same `ApplianceGuidance` JSON shape the base design already defines —
this is additive to `GeminiClient`, not a new subsystem.

### 12.2 When to use search grounding vs. photo-only

Two-tier call, both going through the existing `identifyAppliance`/`getApplianceInstructions`
methods with one new parameter:

```swift
func identifyAppliance(
    imageData: Data, mimeType: String, question: String?, languageHint: String,
    allowSearchGrounding: Bool = false     // NEW
) async throws -> ApplianceGuidance
```

- **First attempt: `allowSearchGrounding: false`** — photo + Gemini's own knowledge, exactly as
  the base design specifies. Cheaper, faster, no external dependency.
- **Retry with `allowSearchGrounding: true`** when the first attempt's `confidence < 0.4` (the
  base design's own threshold for "hedge, don't present as fact") OR the elder's follow-up
  question wasn't satisfied by the first answer (e.g. they ask again, differently-worded, within
  the same session — a proxy for "that didn't help"). Adds `"tools": [{"google_search": {}}]` to
  the same request. Same response shape, decoded the same way — the grounding tool changes what
  Gemini can draw on, not the JSON contract we ask for.
- **Never grounded by default.** Search grounding costs more (a real web search per call) and
  adds latency — reserved for the case the photo-only tier is honestly unconfident about, not a
  blanket "always search" policy.

### 12.3 Storing the result locally — extending, not replacing, `ApplianceCache`

The base design's `ApplianceCache` (§4.3) already persists `ApplianceGuidance` keyed by
brand+model / photo-hash via `EncryptedLocalStorage` — this already satisfies "knowledge stored
locally" for whichever tier answered. One field addition:

```swift
struct ApplianceGuidance: Codable, Equatable {
    // ...existing fields unchanged...
    let knowledgeSource: KnowledgeSource   // NEW
}

enum KnowledgeSource: String, Codable {
    case onDeviceModelKnowledge   // Gemini's own training knowledge, no search
    case webSearchGrounded        // Gemini + google_search tool
}
```

Why this matters beyond bookkeeping: a cached `webSearchGrounded` entry is worth protecting from
casual eviction more than an `onDeviceModelKnowledge` guess (it cost a real search + more tokens,
and it's more likely to be specific/correct for that exact model) — `ApplianceCache`'s LRU should
weight `webSearchGrounded` entries as "touched" less aggressively, or simply: never evict a
`webSearchGrounded` entry purely on LRU while any `onDeviceModelKnowledge` entry exists to evict
first. Small policy change to the existing `maxEntries`/LRU logic, not a new cache.

We do **not** store the raw search results, page content, or any manual text/PDF — only the same
`ApplianceGuidance` shape the base design already caches, sourced differently. This sidesteps the
redistribution/copyright question entirely: nothing manufacturer-authored is retained, only
Gemini's own synthesized answer (same as the photo-only tier).

## 13. Live AR camera overlay — the actual architecture change

### 13.1 Why this can't be "the same design, just faster"

A live camera feed is ~30 frames/sec; a Gemini round trip is 1–5+ seconds (verified this session,
both for text and vision calls). Sending frames to Gemini in real time is a non-starter — not a
tuning problem, a two-orders-of-magnitude latency mismatch. Live AR has to split into two very
different-speed layers:

- **Fast layer (on-device, every frame or near it): find and track text regions in the live
  feed.** Apple's Vision framework (`VNRecognizeTextRequest` for OCR,
  `VNTrackRectangleRequest`/`VNDetectedObjectObservation` for frame-to-frame tracking) does this
  entirely on-device, free, at real-time speed. This is not a new dependency — Vision has shipped
  in iOS since 2017 and needs no model download, unlike everything else in this app's AI stack.
- **Slow layer (Gemini, once per unique label, then cached forever): translate/explain a
  specific recognized string.** Not a photo call at all — once Vision has OCR'd the literal text
  "POWER" off a button, translating "POWER" → "पावर / शक्ति" is a **text-only** Gemini call
  (`generateJSON`-shaped, no `inlineData` image needed), using infrastructure that already exists
  in this client.

### 13.2 The key insight: button vocabulary is tiny and shared across appliances

"Power," "Start," "Stop," "Timer," "Cancel," "Defrost," "Menu," "OK," "Cook Time" — this
vocabulary is maybe 100-200 distinct English strings across every microwave, washer, AC unit,
and remote a household owns, repeated across brands. That means the RIGHT cache key is
**`(recognizedText, targetLanguage) → translation`**, not per-appliance:

```swift
final class LabelTranslationCache {
    // key: "power|ne", "timer|ne", etc. — lowercased, trimmed recognized text + language code
    // value: { translation: String, briefExplanation: String?, cachedAt: Date }
    // No LRU/eviction needed in practice — total vocabulary size is small and bounded;
    // unlike ApplianceCache (photos/models are numerous), this saturates fast and stays small.
}
```

Practical effect: after a household's first few appliance sessions, MOST button labels they
encounter (including on a brand-new appliance they've never photographed) are already cached —
this cache generalizes across appliances in a way `ApplianceCache` (keyed by brand+model)
structurally cannot. Worth building even before full live-AR ships, since `ApplianceHelperView`'s
existing static-photo `groundedControls` labels could use it too.

### 13.3 Live capture surface

Reverses the base design's §9 explicit non-goal ("No custom `AVCaptureSession` camera... not a
v2.0 requirement") — that was correct for a one-shot photo (where `UIImagePickerController` is
genuinely simpler and sufficient) but live AR requires a continuous feed, which
`UIImagePickerController` cannot provide. New surface:

```
ApplianceLiveARView (new SwiftUI view, wraps AVCaptureSession via UIViewRepresentable)
   │
   ├─ AVCaptureSession + AVCaptureVideoPreviewLayer — live feed, full-bleed
   ├─ VNRecognizeTextRequest on a throttled frame sample (recommend ~4-5 fps, not 30 —
   │  OCR doesn't need every frame, and this is the main battery/thermal cost to control)
   ├─ For each recognized text region this frame:
   │    - normalize text (lowercase, trim) → LabelTranslationCache lookup
   │    - cache hit → have translation immediately, no network
   │    - cache miss → queue ONE text-only Gemini call (debounced/deduped — many frames may
   │      see the same new label before the first lookup returns; don't fire duplicate calls
   │      for the same pending key)
   ├─ Vision rectangle tracking carries the text region's screen position frame-to-frame between
   │  OCR passes, so the overlay doesn't visibly "jump" only every 200ms — tracking is cheap and
   │  can run every frame even though OCR itself doesn't
   └─ Canvas overlay: translated label rendered as an adjacent callout (small pill with a leader
      line to the detected button), NOT drawn on top of / replacing the original printed text.
      Deliberately consistent with the base design's "no image generation, never obscure/redraw
      reality" principle (§0, §5.1) — we are not attempting inpainting or text replacement, which
      is a materially different (and much harder, more error-prone) problem than a nearby
      translated label.
```

### 13.4 Two complementary modes, not a replacement

Recommend keeping **both** flows rather than replacing the base design's static mode:

- **"Guide me" (base design, unchanged):** elder takes one photo, gets a full numbered
  step-by-step for a task ("how do I make tea") with circled controls on that photo. Best for
  a complete task with several steps.
- **"What does this say?" (this addendum, new):** live camera, pan around the control panel,
  see labels translated in place as you move. Best for orienting on an unfamiliar panel, or a
  quick single-button question, without a step-by-step task in mind.

Both share `LabelTranslationCache`; only the live mode needs `AVCaptureSession`/Vision tracking.
An elder can start in live mode to find the right button, then back out to "Guide me" for the
full task steps — they're two views onto the same underlying knowledge, not two separate
features to maintain independently.

### 13.5 What stays out of scope, explicitly (mirrors base design's discipline)

- **No live full-scene re-analysis.** Only text-region OCR + translation is real-time; "what does
  this whole control panel do" stays a `identifyAppliance` one-shot call (base design), not
  something attempted continuously.
- **No on-device translation model.** Translation goes through Gemini (text-only calls), not a
  bundled offline translation model — consistent with this branch's overall pivot away from
  maintaining on-device models. Once `LabelTranslationCache` is warm for a household's actual
  vocabulary, most real usage is already effectively offline (cache hit), without needing to
  ship and maintain a translation model to get there.
- **No text replacement/inpainting on the live feed.** Per §13.3 — adjacent callout only.

## 14. Open decisions (additive to base design's §11)

10. **Search-grounding retry policy.** §12.2 proposes confidence<0.4 or a same-session
    re-ask as the trigger. Needs sign-off — an alternative is an explicit elder-facing "search
    for the manual?" prompt (more transparent, adds a turn) instead of an automatic silent
    retry. **Open.**
11. **OCR throttle rate (§13.3's "~4-5 fps" is a starting guess, not measured)** against real
    mid-range/older iPhones this population is likely to own — needs an on-device perf spike
    before committing to a number. **Open, needs a device spike.**
12. **Callout placement collision handling** — a busy control panel could surface many
    recognized labels close together; needs a concrete decluttering rule (e.g. merge/suppress
    callouts under some pixel-distance threshold) before this looks legible rather than
    cluttered. **Open.**
13. **`LabelTranslationCache` seeding.** Should the app ship with a small seed set of the ~50
    most common appliance button words pre-translated (zero network needed on first use ever),
    or start empty and build up purely from real usage? Pre-seeding is cheap (a static bundled
    JSON) and removes the "first button is always a network call" cold-start. **Recommend
    pre-seeding; open for confirmation.**
