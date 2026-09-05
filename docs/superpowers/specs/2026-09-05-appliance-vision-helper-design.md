# Phase 3 Component Design — Appliance / Vision Helper

Branch: `v2-gemini-flash-lite`. Parent design: `docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md`
(§3.1, §3.2, §4.4, §10 item 5). Status: **first-pass component design, awaiting review.** This
document goes one level deeper than the parent doc's outline — concrete types, method
signatures, and wiring against the code as it actually stands on this branch today (not the
aspirational shape the parent doc sketched). Every place where this design diverges from, or
had to guess past, the parent doc is called out inline and collected in §11.

## 0. Executive summary

The elder photographs an appliance, remote, or TV screen and asks (by voice or a button tap)
"how do I use this?" or a follow-up like "what does this button do?". The app sends the photo
to Gemini, gets back plain-language steps plus (when a step references a named physical
control) a normalized bounding box for that control, and draws a circle on the **original,
unaltered photo** client-side — no image generation, no manual-scraping pipeline. Results are
cached locally so a household's handful of appliances only cost one real Gemini round trip
each, not one per use.

This is explicitly **not** a new UI paradigm: it reuses the existing pending-action/outcome-card
pattern (`AppCoordinator.pendingCallAction`, `pendingMessageDraft`), the existing
`CommandRouter` dispatch shape, the existing `Speaker` for TTS, and the existing
`ObservabilityBus`/keyword-fallback philosophy. What's genuinely new: a camera capture surface
(none exists in the codebase today — verified, no `AVCapturePhoto`/`UIImagePickerController`
usage anywhere), two `GeminiClient` methods, a handful of new value types, a small on-device
cache, and a coordinate-mapping overlay view.

## 1. Scope

**In scope (v2.0 / Phase 3):**
- Photo → identify appliance/remote/screen + answer the elder's question from the photo and
  Gemini's own world knowledge.
- Grounded circle/arrow overlay for named controls, drawn over the real photo.
- Local cache keyed by brand+model (preferred) or photo hash (fallback).
- One shared "AI Visual Helper" pipeline for both appliance and TV/remote guidance (parent doc
  §4.4 item 5) — no appliance-specific and remote-specific code paths.

**Explicitly out of scope (parent doc §4.4, §10 item 5 — RESOLVED, not re-opened here):**
- Any automated manual PDF download/scrape/parse pipeline. If photo-only answers prove
  insufficient, that's a v2.2+ decision gated on real usage evidence, not something this design
  builds a stub for.
- Server-side/generated re-imaging of the appliance ("AR redraw"). Circle overlay only, drawn
  by this app, on the pixels the camera actually captured.

## 2. End-to-end data flow

```
Trigger (voice "यो कसरी चलाउने" / dock button "Show Me")
   │
   ├─ Voice path: GeminiCommandInterpreter returns action = identify_appliance
   │  (no photo attached — see §6.1 on why voice can't carry a photo today)
   │  → CommandRouter.dispatchInterpreted → coordinator.presentApplianceHelper(question:)
   │
   └─ Button path: dock/Home tile → same coordinator.presentApplianceHelper(question: nil) directly,
      skipping the LLM round trip entirely (no ambiguity to resolve — the tap IS the intent)
   │
   ▼
ApplianceHelperView presented (new SwiftUI view — camera capture UI)
   │
   ▼
Elder takes photo → UIImage captured (full camera resolution)
   │
   ├─ Uniform-scale downsize (longest edge ≈1024px, NO crop — aspect ratio preserved exactly;
   │  see §5.3 for why cropping here would silently break the overlay)
   ├─ SHA-256 hash of the (post-resize) JPEG bytes → cache lookup by photo hash
   │  (near-instant path if the elder re-triggers on the same still-cached photo instance)
   │
   ▼  [cache miss]
GeminiClient.identifyAppliance(imageData:mimeType:question:languageHint:) async throws
   → ApplianceGuidance
   │
   ├─ Cache lookup by brand+model key (if Gemini returned one with reasonable confidence) —
   │  checked AFTER the call too: a second physical appliance of the same brand/model should
   │  hit cache on ITS first photo, not just on retakes of the same unit
   ▼
Cache write (photo-hash key always; brand+model key when available) — LRU/TTL per §4.3
   │
   ▼
ApplianceHelperView renders:
   - the captured photo, full-bleed, aspect-fit
   - a Canvas overlay drawing one pulsing circle + step number per GroundedControl
     at its normalizedBox, mapped into on-screen coordinates (§5)
   - a step list below/beside the photo (plain text, always shown — overlay is additive, not
     load-bearing for understanding the steps)
   │
   ▼
Speaker.speak(guidance.spokenSummary, locale:) — spoken immediately; full step list stays on
screen for as long as the elder wants to re-read it (redesign spec's "don't rely on hearing
alone" principle, same as the outcome card)
   │
   ▼ [optional follow-up, same screen]
Elder asks a further question ("दुई नम्बर बटन के हो?") → voice or a "पुनः सोध्नुहोस्" mic button
on ApplianceHelperView itself (NOT routed through the general voice pipeline/CommandRouter —
see §6.2) →
GeminiClient.getApplianceInstructions(imageData:mimeType:appliance:followUpQuestion:languageHint:)
→ new ApplianceGuidance (partial: usually just new/updated groundedControls + a short spoken
answer, not a full re-identification) → same render step above.
```

## 3. `GeminiClient` API surface additions

The existing `GeminiClient` (`ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift`) already
has `analyzeImage(imageData:mimeType:prompt:) async throws -> String` — a generic vision call
that returns raw text, built "so this feature can be added without touching this client." This
design adds two purpose-built methods that call the same underlying `send(_:)` transport but
request/parse structured JSON, following the exact pattern `generateJSON` already established
(`generationConfig.responseMimeType = "application/json"`), not a new calling convention.

```swift
extension GeminiClient {
    /// Vision call: identify what's in `imageData` and answer `question`
    /// (or "how do I use this?" if nil) from the photo + Gemini's own
    /// world knowledge. No manual-lookup pipeline — see design doc §1.
    /// Throws GeminiClientError on transport/timeout/block/parse failure;
    /// callers must NOT treat a thrown error as "no such appliance" —
    /// only a successfully-decoded low-confidence result means that.
    func identifyAppliance(
        imageData: Data,
        mimeType: String,
        question: String?,
        languageHint: String
    ) async throws -> ApplianceGuidance

    /// Follow-up call once an appliance is already identified this
    /// session (`get_instructions`). `imageData` is optional: pass it
    /// again ONLY when `followUpQuestion` plausibly needs a NEW grounded
    /// control (a fresh bounding box), because boxes must be computed
    /// against actual pixel data — a text-only follow-up ("what do I do
    /// next") can omit it and cost far fewer tokens. See §11 item 8 for
    /// why this distinction is flagged as an open question, not a solved
    /// classifier.
    func getApplianceInstructions(
        imageData: Data?,
        mimeType: String?,
        appliance: ApplianceIdentity,
        followUpQuestion: String,
        languageHint: String
    ) async throws -> ApplianceGuidance
}
```

Both methods build a `GeminiRequest` with a text part (prompt below) + an `inlineData` image
part when present, exactly like `analyzeImage` does today, but set
`generationConfig.responseMimeType = "application/json"` and decode into `ApplianceGuidance`
(§4) instead of returning a bare `String`. Decoding failure is treated identically to
`GeminiCommandInterpreter`'s existing `parsed == nil` path: log `outcome: "parse_failed"`,
throw/propagate, caller falls back (§7) — not a crash, not a silent empty result.

### 3.1 Prompt shape (JSON mode, not native function calling — flag)

**Important discrepancy, stated plainly rather than silently assumed:** the parent design doc's
§3.2 calls for Gemini's native function-calling (`tools`/`functionDeclarations`) as "a real
reliability upgrade over ask-for-JSON." The code that actually shipped
(`GeminiClient.generateJSON`, `GeminiCommandInterpreter.buildPrompt`) does **not** use function
calling at all — it exclusively uses prompt-engineered JSON mode
(`responseMimeType: "application/json"`) with no `responseSchema`. This design's two new
methods follow the **shipped** pattern, not the parent doc's aspiration, for consistency with
the one calling convention that actually exists in this codebase today. If/when the team
migrates the conversational path to real function calling, this vision path should migrate at
the same time — see §11 item 9.

Example prompt shape for `identifyAppliance` (prose, not a literal template — mirrors
`GeminiCommandInterpreter.buildPrompt`'s style of describing the JSON contract in the prompt
body):

```
You are Sahayak's visual helper for an elderly speaker. Look at the attached photo of an
appliance, remote control, or screen. Answer using your own general knowledge of how such
devices work PLUS what you can see in the photo — you do not have access to any manual or
external database, so never claim to be quoting one.

Reply with ONLY a single JSON object:
{
  "identity": { "brand": string|null, "model": string|null,
                "category": one of "microwave","tv_remote","smart_hub","washing_machine",
                            "air_conditioner","other",
                "displayName": string },
  "steps": [string, ...],
  "groundedControls": [
    { "label": string, "stepNumber": number|null,
      "normalizedBox": { "xMin": number, "yMin": number, "xMax": number, "yMax": number },
      "confidence": number }
  ],
  "spokenSummary": string,
  "confidence": number
}
Normalize all box coordinates to the range 0.0-1.0, origin top-left of the ORIGINAL photo,
independent of any resizing. If you cannot confidently locate a named control's real position
in this image, omit it from groundedControls rather than guessing.
User's question (if any): "<question or '(none — general how-to-use)'>"
Reply language: <languageHint>.
```

### 3.2 The bounding-box "grounding" claim — unverified, flagged explicitly

The parent doc's §3.1/§4.4 describes this as using "Gemini's vision *grounding* output
(bounding boxes / points for named objects)". This needs a correction/flag: in the Generative
Language REST API as publicly documented, `groundingMetadata` is the field returned for
**search-grounded** answers (citations back to Google Search results) — it is not a dedicated
object-localization API. Getting bounding boxes for named objects in an *uploaded* image is a
documented but different pattern: **prompt the model to emit box coordinates as structured JSON
in its normal text/JSON response** (the same mechanism as everything else this client already
does), typically normalized 0–1 or 0–1000 relative to the image. That is what §3.1's prompt
above does — it is plain JSON-mode output, not a distinct "grounding" API surface.

This matters for two reasons: (1) it means no new request field (like a `groundingConfig`) is
needed — the existing request/response wire types in `GeminiClient.swift` are already
sufficient, no schema changes to `GeminiRequest`/`GeminiResponse`; (2) it means bounding-box
*accuracy* is exactly as reliable as any other prompted-JSON field — i.e., it can be wrong or
omitted, and this design must (and does, §7) treat "no box returned" and "box returned but
wrong" as expected, handled cases, not exceptional ones.

**This is stated as the working assumption, not a verified fact** — it has not been exercised
against a live endpoint in this environment, matching the existing honesty note already in
`GeminiClient.swift`'s file header. Recommend a short live spike (send one real appliance photo,
inspect the actual returned coordinates against the actual pixel location) before relying on
this for anything user-facing. See §11 item 1.

## 4. New Swift types

```swift
/// What Gemini identified in the photo. `brand`/`model` are nil when
/// Gemini can't tell (generic/unlabeled remote, worn-off text) — callers
/// must treat that as "no reliable cache key", not "identification
/// failed" (§4.3).
struct ApplianceIdentity: Codable, Equatable {
    let brand: String?
    let model: String?
    let category: String       // see §3.1's enum; stored as raw String,
                                // not a Swift enum, so an unrecognized
                                // future category from Gemini decodes
                                // instead of failing the whole payload
    let displayName: String    // spoken-friendly, e.g. "Panasonic microwave"
}

/// Normalized [0,1] box, origin top-left, in the ORIGINAL photo's
/// coordinate space — resolution-independent by construction (§5.3).
struct NormalizedBox: Codable, Equatable {
    let xMin: Double
    let yMin: Double
    let xMax: Double
    let yMax: Double
    var center: (x: Double, y: Double) { ((xMin + xMax) / 2, (yMin + yMax) / 2) }
}

struct GroundedControl: Codable, Equatable {
    let label: String
    let stepNumber: Int?
    let normalizedBox: NormalizedBox
    let confidence: Double
}

/// The full result of an identify/follow-up call. Codable so it can be
/// cached as-is (§4.3) with no separate persistence model.
struct ApplianceGuidance: Codable, Equatable {
    let identity: ApplianceIdentity
    let steps: [String]
    let groundedControls: [GroundedControl]
    let spokenSummary: String
    let confidence: Double
}
```

### 4.1 Confidence thresholds (concrete numbers, not "some threshold")

- **Identification confidence < 0.4** → speak/show as an explicit guess ("पक्का छैन, तर देखिन्छ
  कि यो एउटा माइक्रोवेभ हो..."), never silently present a low-confidence guess as fact. Reuses
  the same spirit as `GeminiCommandInterpreter.Config.confidenceThreshold` (0.7) but a *lower*
  bar here deliberately: for the voice-intent router, low confidence means "fall back to
  keywords" (a working alternative exists). For the vision helper, there is no keyword
  fallback for "what is this appliance" — a lower-confidence best-effort answer is strictly
  more useful than refusing, as long as it's disclosed as uncertain.
- **Per-control confidence < 0.5** → omit that control's overlay circle entirely; still show its
  instruction step as plain text. Never draw a circle for a sub-threshold box — a wrong circle
  actively misleads an elderly user in a way a missing circle does not (same "can't hallucinate"
  principle the parent doc invokes against image generation, applied here to overlay placement).

## 4.3 `ApplianceCache`

```swift
final class ApplianceCache {
    struct Entry: Codable {
        let guidance: ApplianceGuidance
        let photoHash: String?          // SHA-256 of the (resized) JPEG bytes
        let brandModelKey: String?      // normalized "brand|model", lowercased, trimmed
        var lastAccessedAt: Date
        let createdAt: Date
    }

    static let maxEntries = 40
    /// 180 days. An appliance's controls don't change; this is a
    /// staleness *hint* for a background low-priority re-check, not a
    /// hard expiry that blanks a working cache entry the elder is
    /// actively relying on (stale-while-revalidate, not stale-while-block).
    static let staleAfter: TimeInterval = 180 * 24 * 3600

    private let storage: EncryptedLocalStorage   // same Keychain-backed
                                                  // store as GeminiConfigStore/
                                                  // FamilyContactStore — no new
                                                  // storage mechanism introduced
    // lookup(photoHash:), lookup(brand:model:), store(_:) — LRU eviction by
    // lastAccessedAt when count exceeds maxEntries after a write.
}
```

**Why 40 entries / 180 days:** the parent doc's own framing is "a household owns a handful of
appliances" — 40 is generous headroom over "a handful" (TV + 2-3 remotes + microwave + washer +
AC + a few more) without needing a second AI-driven eviction policy, matching the parent doc's
explicit "no need for a second AI-driven caching-policy decision" instruction. 180 days is long
enough that a household's re-use pattern (same appliances, indefinitely) mostly hits cache
forever, while still bounding how long a wrong/outdated entry could theoretically persist
without ever being revisited.

**Cache key reality check (flagged, not glossed over):** the *photo-hash* key mostly only pays
off within one capture session (re-asking about the same photo instance) or on a byte-identical
retake, which is rare. The *brand+model* key is what actually generalizes across "the elder
photographs their microwave again tomorrow" — but only when Gemini identifies brand+model
confidently, which won't always happen (worn labels, generic remotes, handwritten stickers).
When neither identity field is present, the entry is cached under photo-hash only, and a future
photo of the same physical device will not hit cache even though it's "the same appliance" to a
human. Accepted as a known v2.0 gap — see §11 item 5.

## 5. Overlay rendering

`ApplianceHelperView` (new SwiftUI view, not built as part of this design task) shows the
captured `UIImage` full-bleed with `.resizable().aspectRatio(contentMode: .fit)` inside a
`GeometryReader`, and a `Canvas` layered on top in the same `ZStack` cell.

### 5.1 Coordinate mapping

`.aspectRatio(.fit)` letterboxes: the displayed image rect is smaller than (or equal to) the
container in one dimension. The overlay must compute that displayed rect itself — SwiftUI does
not expose it directly — using the image's own pixel size vs. the `GeometryReader` proxy's size:

```
containerSize = geometry.size
imageSize     = uiImage.size   // pixel dimensions of the ORIGINAL captured photo
scale         = min(containerSize.width / imageSize.width,
                     containerSize.height / imageSize.height)
displayedSize = imageSize * scale
displayedOrigin = ((containerSize.width - displayedSize.width) / 2,
                    (containerSize.height - displayedSize.height) / 2)   // centered letterbox
```

For each `GroundedControl`, its `normalizedBox.center` (0–1, 0–1) maps to a screen point via:

```
screenPoint = displayedOrigin + (normalizedCenter.x * displayedSize.width,
                                  normalizedCenter.y * displayedSize.height)
```

The `Canvas` draws a fixed-radius (not box-scaled) high-contrast circle — e.g. a thick
orange/yellow stroke, ~28pt diameter regardless of the actual button's size in the photo — plus
a small numbered badge matching `stepNumber`, at `screenPoint`. Fixed radius rather than
box-scaled is deliberate: real buttons are often tiny in a photo of a full control panel; a
box-accurate circle could be a few pixels wide and effectively invisible/untappable-looking to
an elderly user, whereas a consistent, generous circle is legible regardless of the actual
control's size. A subtle pulse animation (scale 1.0↔1.15, looping) draws the eye without relying
on color alone (accessibility: don't require color perception).

Recomputed on every `GeometryReader` size change (rotation, Dynamic Type-driven layout shifts)
— it's a pure function of `(containerSize, imageSize, normalizedBox)`, so no cached/stale
mapping state to invalidate.

### 5.2 Multiple controls / steps

When more than one `GroundedControl` is returned (e.g. "press Power, then turn the Timer
dial"), draw all of them simultaneously with distinct step-number badges rather than only the
"current" one — the elder can look at the whole panel once rather than stepping through screens.
The step list beside/below the photo is the same numbering, so text and overlay are always in
sync by `stepNumber`.

### 5.3 Why uniform-scale resize (no crop) before upload is load-bearing

`normalizedBox` coordinates are resolution-independent (0–1 fractions), so resizing the image
before sending it to Gemini is always safe *as long as the resize is a pure uniform scale of the
full frame*. Cropping before upload would not be safe: Gemini would return a box normalized to
the *cropped* frame, but the overlay renders against the *original, uncropped* `UIImage` (per
§0's "no manual pipeline, real photo" principle) — the box would then land in the wrong place on
the displayed photo. This is a concrete implementation constraint for whatever resize step
prepares `imageData`, not just a note: **resize, never crop**, before calling
`identifyAppliance`/`getApplianceInstructions`. Recommended target: longest edge ≈1024px JPEG,
~0.7 quality — small enough to keep upload latency/token cost reasonable, large enough that
small button labels are still legible to the model. This specific number is a recommendation,
not verified against real accuracy data — see §11 item 4.

## 6. Intent/action wiring

### 6.1 New `InterpretedCommand.Action` cases

`ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift`'s `InterpretedCommand.Action`
enum (shared by both the legacy LLaMA path and `GeminiCommandInterpreter`, via
`LlamaCommandInterpreter.parse(json:)`) gains two new raw values:

```swift
case identifyAppliance = "identify_appliance"
case getInstructions = "get_instructions"
```

`GeminiCommandInterpreter.buildPrompt` needs its action enum list and instruction prose extended
to describe these two, e.g.: *"Set action to `identify_appliance` when the user wants to know how
to use, operate, or understand a physical appliance, remote, or screen they will show you (e.g.
"यो कसरी चलाउने", "मेरो माइक्रोवेभ बुझ्न सहयोग गर्नुहोस्") — do NOT expect them to have already
attached a photo; that comes next. Set action to `get_instructions` only when they're asking a
follow-up about an appliance already being helped with in this session (e.g. "अब के गर्ने",
"दुई नम्बर बटन के हो")."*

**Important limitation, stated plainly:** `GeminiCommandInterpreter.interpret(transcript:...)`
only ever sends *text* — there is no image parameter, and no code path today attaches a photo
to a voice utterance. So `identify_appliance` recognized via voice can only ever mean "open the
camera and wait for a photo next" — it cannot mean "here's my question AND my photo in one
turn." This is a real UX-shape decision, not an implementation detail, and it is flagged as open
in §11 item 3 rather than silently assumed.

`CommandRouter.dispatchInterpreted`'s `switch` over `InterpretedCommand.Action` is exhaustive
(no `default:` case) — adding the two new enum cases will not compile until the switch handles
them, which is a useful forcing function, not an obstacle. New cases:

```swift
case .identifyAppliance:
    emit(eventType: "command_identify_appliance", outcome: "success")
    coordinator?.presentApplianceHelper(question: command.reply.isEmpty ? nil : nil /* see below */)
case .getInstructions:
    emit(eventType: "command_get_instructions", outcome: "success")
    coordinator?.presentApplianceHelper(question: <the follow-up text extracted by the prompt>)
```

(The exact field the prompt uses to carry the follow-up question text — reusing `message` or
adding a new `visualQuestion` field to `InterpretedCommand` — is an open naming decision, not
resolved here; either works mechanically.)

### 6.2 `VoiceCommandCoordinating` / `AppCoordinator` additions

New protocol method, following the exact shape of the already-shipped
`requestCallConfirmation`/`composeMessage` pattern (present state via a `@Published` optional,
consumed by a SwiftUI sheet):

```swift
protocol VoiceCommandCoordinating {
    // ...existing...
    func presentApplianceHelper(question: String?)
}
```

`AppCoordinator` implementation:

```swift
struct ApplianceHelperRequest: Identifiable {
    let id = UUID()
    let initialQuestion: String?   // nil = general "how do I use this"
}
@Published var pendingApplianceHelperRequest: ApplianceHelperRequest?

func presentApplianceHelper(question: String?) {
    DispatchQueue.main.async { [weak self] in
        self?.pendingApplianceHelperRequest = ApplianceHelperRequest(initialQuestion: question)
    }
}
```

A SwiftUI `.sheet(item: $pendingApplianceHelperRequest)` at the same level as the existing
`MessageComposeView`/call-confirmation presentation drives `ApplianceHelperView`. The dock/Home
"Show Me" button calls `coordinator.presentApplianceHelper(question: nil)` directly — no LLM
round trip needed for a deliberate tap.

**Follow-up questions inside `ApplianceHelperView` do not re-enter `CommandRouter`.** Once the
sheet is open, a follow-up mic tap should go straight to
`GeminiClient.getApplianceInstructions`, not back through the general voice pipeline/keyword
layer — there's no keyword vocabulary for "what does button 2 do," and routing it through the
full pipeline would risk the keyword layer intercepting words like "call" or "help" that might
appear incidentally in an appliance-related sentence. This mirrors how
`ApplianceHelperView`-internal follow-ups are architecturally closer to a normal iOS
view-model/service call than to a `CommandRouter`-dispatched command.

### 6.3 Safety-critical path — unaffected, explicitly

Nothing here touches `CommandRouter.routeKeyword`, the emergency-phrase check, or the
medication-ack path — those run *before* the LLM-interpreter branch and are structurally
untouched by adding two new post-interpretation switch cases. This feature is not
safety-critical and does not claim to be; consistent with constitution's scoping of "safety
critical" to emergency/medication paths only.

## 7. Error / fallback handling

| Condition | Elder sees/hears | Notes |
|---|---|---|
| No network at capture time | Immediate (no spinner wait) spoken+visible: "अहिले इन्टरनेट उपलब्ध छैन" | Check reachability / catch `URLError.notConnectedToInternet` before even opening the camera if feasible, so the elder isn't asked to take a photo that can't be used |
| Gemini timeout | "बुझ्न धेरै समय लाग्यो, फेरि प्रयास गर्नुहोस्" + retry button | Uses `GeminiClient.Config.default.timeoutSeconds` — **currently 25s in code, not the 6s the parent doc's §3.2 specified** (bumped 2026-09-04 for slower model tiers per the client's own doc comment); this design inherits whatever that shared constant is rather than defining a separate one, since the "three coupled numbers" comment in `AppCoordinator` already warns against per-feature timeout drift |
| Identification confidence < 0.4 | Best-effort answer, explicitly hedged ("पक्का छैन, तर...") | §4.1 — never silently presented as certain |
| Grounded-control confidence < 0.5 | That step's text still shown; no circle drawn for it | §4.1 — never draws a guessed-location circle |
| `blockedByProvider` (safety filter) | Generic "मदत गर्न सकिन" fallback | Same `GeminiClientError.blockedByProvider` case already defined; no appliance-specific handling needed |
| Malformed/undecodable JSON response | Same generic fallback as above | Logged `outcome: "parse_failed"`, mirroring `GeminiCommandInterpreter`'s existing pattern |
| Daily cost cap exceeded (§8) | Explicit, honest "आजको लागि यो सुविधा उपलब्ध छैन" (not available today) — distinct from the generic network/timeout message | There's no keyword-layer equivalent for vision help, so this can't quietly "fall back" the way conversational intents do — it must say so |
| Camera permission denied | Standard iOS permission-denied guidance, matching `AppCoordinator.VoiceErrorKind.permission`'s existing pattern for mic | New permission (`NSCameraUsageDescription`) needs adding to Info.plist and the plain-language onboarding disclosure (constitution §Compliance: "permissions requested at point of use with clear plain-language explanation") |

## 8. Cost / telemetry

**Flagged dependency, not assumed to already exist:** the parent doc's §3.2/§7 calls for "a
local, per-day call counter... with a family-configurable soft cap" as a Phase-0 foundational
piece. It does **not exist in the codebase yet** (verified — no `dailyCall`/`callCounter`/
`costCap` symbols anywhere in `ios/ElderlyAssistant`). This design does not re-derive a
parallel, vision-specific budget; it assumes the shared counter lands as part of the general
Gemini foundation work and vision calls increment the *same* counter as conversational calls,
through the same `GeminiClient.send(_:)` chokepoint every request already funnels through. If
that shared counter isn't built before Phase 3 ships, it is a blocking prerequisite for this
feature, not something Phase 3 should build a one-off version of — see §11 item 2.

Every vision call emits through the existing `ObservabilityBus`/`ObservabilityEvent` shape
(`component/eventType/durationMs/outcome/errorCode/metadata`), reusing the naming style already
in `GeminiClient` (`gemini_call`, `gemini_http_error`, `gemini_blocked`, `gemini_empty_response`):

- `gemini_vision_identify` — outcome success/failure, `durationMs`, metadata may include an image
  size bucket (`"size_bucket": "≤1MB"`) and `"cache": "hit"|"miss"` — never the photo itself,
  never brand/model in metadata (consistent with the existing "no PII in metadata" log-sanitiser
  policy, applied conservatively even though appliance brand is arguably not PII).
- `gemini_vision_followup` — same shape, for `getApplianceInstructions`.
- `gemini_vision_cache_hit` — emitted on a cache hit with zero network call, so a future
  family-facing usage screen (per parent doc §3.2) can distinguish "calls avoided" from "calls
  made," which is exactly the kind of number that makes the cache's value visible.

## 9. What is explicitly NOT built by this design (v2.0)

- No manual/PDF retrieval — confirmed out of scope (parent doc §10 item 5).
- No perceptual/fuzzy photo-hash matching — exact SHA-256 only (§4.3's known limitation,
  accepted).
- No family-side configuration surface for this feature (no "pre-register these appliances"
  remote-config screen) — 100% elder-initiated, in-the-moment. Flagged as a decision needing
  explicit sign-off in §11 item 7, since every other Phase in the parent doc got a stated
  family/elder split and this one hasn't yet.
- No custom `AVCaptureSession` camera (recommend `UIImagePickerController`'s built-in camera
  source for v2.0 — standard, accessible, no custom capture UI to build/test); a custom capture
  pipeline is a plausible later upgrade for better exposure/focus control on tricky lit control
  panels, not a v2.0 requirement.

## 10. Testing notes (brief)

Per constitution Quality standards, this feature is **not** on the "100% coverage,
safety-critical" list (it isn't medication/emergency/health-alert), but the coordinate-mapping
math in §5.1 is exactly the kind of pure, easily-wrong function that should get direct unit
tests (given `containerSize`/`imageSize`/`normalizedBox` fixtures, assert the expected
`screenPoint`) independent of any live Gemini call. `ApplianceCache`'s LRU eviction and
photo-hash/brand-model key resolution should also be unit-testable against a fake
`EncryptedLocalStorage`, matching how `GeminiConfigStore`/`FamilyContactStore` are already
tested against the same protocol.

## 11. Open decisions / risks

Each item below is something the parent markdown doc either didn't resolve or got wrong/
ambiguous when checked against the actual shipped code. None of these are silently assumed away
in the design above — this section is where they're made explicit.

1. **Bounding-box response shape is unverified against a live API call.** §3.2 explains why the
   parent doc's "grounding" language likely conflates Gemini's search-grounding metadata with
   prompted-JSON box coordinates. Recommend a live spike (one real photo, one real API key,
   inspect actual returned coordinates against actual pixel location) before implementation
   relies on any specific field name or coordinate convention (0–1 vs. 0–1000, origin
   corner). **Open.**
2. **Cost-governance dependency.** The per-day call counter/soft cap the parent doc requires in
   Phase 0 does not exist in the code today. Is it being built now, elsewhere, in parallel? If
   not, it's a blocking prerequisite for Phase 3, not something to defer further. **Open.**
3. **Voice-triggered `identify_appliance` UX contract.** Since a voice utterance can never carry
   a photo in the current pipeline, recognizing this intent by voice can only mean "now open the
   camera and wait" — a multi-turn UX, not the one-shot Q&A shape every other voice intent has.
   Needs explicit sign-off that this is the intended contract (recommended in §6.1) rather than,
   e.g., requiring the photo to already be on-screen (button-only trigger) with voice limited to
   in-sheet follow-ups only. **Open.**
4. **Upload image size/resize policy.** §5.3 recommends ≈1024px longest edge, JPEG ~0.7 quality,
   as a starting number — not verified against real accuracy-vs-cost tradeoffs for this model
   tier. **Open**, low risk (easy to tune later since it's one constant, and the
   resize-never-crop constraint is the actually load-bearing part).
5. **Cache-key coverage gap.** Photo-hash-only fallback (when brand+model isn't confidently
   identified) means a re-photographed *same* appliance won't hit cache. Accepted as a known
   v2.0 limitation; flagging in case a perceptual-hash follow-up is wanted sooner than "later."
   **Open, low priority.**
6. **Consent-screen specificity.** Parent doc §6's consent language covers "voice and photos"
   generically. Confirm the Vision Helper is called out by name/demonstrated during onboarding
   consent, not left to boilerplate coverage — this feature is the first place photos of the
   elder's home/appliances actually leave the device. **Open**, small but compliance-adjacent.
7. **Family configuration split.** Every other Phase in the parent doc has an explicit
   family-vs-elder configuration split (API key, contacts, thresholds set by family; day-to-day
   use by the elder). This feature currently has none — 100% elder-initiated with no family
   config surface at all. Confirm that's intended, not an oversight. **Open.**
8. **`get_instructions` photo-resend heuristic.** §3's `getApplianceInstructions` treats
   "does this follow-up need a fresh bounding box" as a caller-side decision, but no concrete
   classifier is specified for telling "what do I do next" (text-only, cheap) apart from "what's
   this button" (needs the photo again, for grounding). Needs a concrete rule (e.g.: always
   resend the photo when the follow-up mentions a physical control noun, otherwise don't) before
   implementation, or it'll default to "always resend" (safe but needlessly expensive) or
   "never resend" (cheap but breaks grounding for legitimate follow-ups). **Open.**
9. **Function-calling vs. JSON-mode inconsistency (parent-doc vs. shipped code).** The parent
   doc's §3.2 specifies native Gemini function calling; the actual `GeminiClient`/
   `GeminiCommandInterpreter` code uses prompt-engineered JSON mode exclusively. This design
   follows the shipped pattern for consistency (§3.1). If the team migrates the conversational
   path to real function calling, this vision path should move at the same time to avoid two
   permanently-diverging calling conventions in the same client. **Open**, informational —
   not a Phase-3 blocker on its own.
