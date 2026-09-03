# V2 Design — Gemini 2.5 Flash Lite Pivot

Branch: `v2-gemini-flash-lite`. Source brief: `design-v2-gemini-flash-lite.md` (repo root).
Status: **autonomous first-pass design, awaiting review.** Every open decision is flagged
explicitly in §10 rather than silently assumed — read that section even if nothing else.

## 0. Executive summary

v1 spent most of its engineering budget fighting on-device model constraints: whisper.cpp
hangs and 90-second timeouts, LLaMA memory ceilings on 6 GB devices, no real streaming, wake
word never shipped. The instruction for v2 is explicit: stop spending time on the local audio
pipeline, pivot effort to UX/UI and features, and use Gemini 2.5 Flash Lite (cheap, fast,
multimodal) as the AI backbone for speech understanding, conversation, and vision.

This is not a feature add — it is an architecture reversal. v1's constitution has a
non-negotiable constraint: *"All AI inference must run on-device. No cloud LLM calls."* v2
deliberately breaks that constraint. That trade is almost certainly the right call for
"genuinely helpful," but it has real privacy/compliance consequences that this document
surfaces plainly (§6) rather than papering over.

The good news: almost none of v1's *non-AI* engineering is wasted. The audio capture
pipeline, the deterministic safety-net keyword layer, the medication/escalation system, and
the entire UI redesign from the previous work session are architecture-agnostic — they stay.
Only the "brain" (`LlamaCommandInterpreter`) and the "ears" (`WhisperSpeechRecognizer`) get
replaced.

## 1. What changes vs. `constitution.md`

| Constraint | v1 | v2 |
|---|---|---|
| AI inference location | On-device only (LLaMA 3.2, whisper.cpp) | Cloud — Gemini 2.5 Flash Lite |
| Voice/photo data | Never leaves device | Sent to Google's Gemini API |
| Network dependency for core conversation | None (fully offline-capable) | Required for anything beyond the deterministic keyword layer |
| Safety-critical paths (med ack, emergency) | Local, zero network dependency | **Stays local, zero network dependency — unchanged** |
| STT/LLM model management UI | Multi-GB downloads, model picker | Mostly disappears — no large on-device models to manage |
| Wake word | Deferred to v2 (constitution decision #10) | **In scope now** — the brief asks for "always on mic like Siri" |

The one property carried over unconditionally: the constitution's safety-critical
requirement that *"Emergency calling logic... must not be blocked by the on-device LLM being
busy or unavailable"* generalizes cleanly to *"...must not be blocked by Gemini being slow,
rate-limited, or unreachable."* The deterministic keyword layer already built in
`CommandRouter.routeKeyword` is what makes that true regardless of which cloud/on-device brain
sits behind it — this pivot doesn't touch that layer, it just changes what sits behind the
LLM-first branch.

## 2. Architecture overview

```
mic → AudioSessionManager → WakeWordEngine (Porcupine, actually shipped this time)
    → VoiceActivityDetector (VAD gates end-of-utterance, still fully local)
    → [audio clip, WAV/FLAC-encoded]
    → GeminiClient.understand(audio, context)     ← ONE round trip does STT + intent + reply
    → CommandRouter
         ├─ deterministic keyword layer (unchanged, zero network, safety net)
         └─ GeminiCommandInterpreter result → dispatch (same action-enum shape as today,
                                                          extended — see §3.2)
    → Speaker (local AVSpeechSynthesizer/Piper — NOT Gemini audio-out, see §3.1)
```

The critical simplification: **one Gemini call replaces the STT step and the LLM-interpret
step combined.** Gemini's multimodal input accepts audio directly — there is no separate
transcription pass to hang, time out, or reload a model for. This directly removes the single
biggest source of v1's latency and reliability problems (`WhisperSpeechRecognizer`'s
per-attempt-context/watchdog machinery existed *only* because whisper.cpp inference could wedge
forever — Gemini's hosted inference doesn't have that failure mode; a single HTTP timeout
covers it).

**Offline/degraded-network behavior is a required design property, not an edge case.** Since
the core conversation now depends on network reachability, `CommandRouter` must fail soft:
on any Gemini timeout/error, fall back to the keyword layer exactly as it falls back today when
the LLM is "not confident." A user with no signal can still say "औषधि खाएँ" and have it work,
say "emergency," and get the local alert path — they just can't ask an open-ended question
until connectivity returns. This is the same fallback shape v1 already has for LLM
unavailability; it just needs "no network" added as a trigger alongside "timeout" and
"not confident."

## 3. Gemini integration design

### 3.1 Model/capability selection

- **Understanding (STT + NLU + reply generation): `gemini-2.5-flash-lite`.** Cheapest tier,
  multimodal (audio + image + text in, text out), supports function calling. This is the
  workhorse for the entire conversational loop.
- **TTS: stay local (AVSpeechSynthesizer today, Piper later — both already built in
  `Speaker.swift`).** Recommendation, not a given: round-tripping audio *out* through Gemini
  adds latency and cost to every single reply, while local TTS is instant, free, and works
  fully offline. Gemini-generated speech is a plausible future upgrade for voice quality, not
  a v2.0 requirement. Flagged in §10 for explicit sign-off since "STS" in the brief could be
  read as wanting Gemini's voice output too.
- **Vision (appliance/TV photos): `gemini-2.5-flash-lite` first; upgrade to `gemini-2.5-flash`
  per-call if flash-lite's accuracy on a specific appliance/manual task proves insufficient.**
  Keep the model name behind one client interface so this is a config change, not a rewrite.
- **Annotated "circle the button" images: do NOT use an image-generation model.** Use Gemini's
  vision *grounding* output (bounding boxes / points for named objects in an image) to get
  real pixel coordinates of the button on the ORIGINAL photo, then draw the circle/arrow
  client-side (SwiftUI `Canvas` / Core Graphics overlay) over the real, unaltered photo. This
  is cheaper, faster, and can't hallucinate a fake-looking appliance the way asking a
  generative model to redraw the photo could. See §4.4.

### 3.2 API client design

New `GeminiClient` (Foundation/URLSession-based, no cloud SDK dependency needed — the
Generative Language REST API is plain JSON over HTTPS):

- Auth: API key stored in Keychain (never hardcoded, never in `Info.plist`), configured during
  a family-assisted setup step — this is exactly the kind of thing the *family* configures
  remotely per the constitution's existing "secondary users configure remotely" pattern, not
  something the elderly primary user manages.
- One request builder for `generateContent` accepting a mix of inline audio bytes, inline
  image bytes, and text (conversation context: pending medications, recent turns, language
  hint — the same `InterpreterContext` shape used today, extended).
- **Function calling**, not "ask for JSON and hand-parse it." Gemini's native function-calling
  is a real reliability upgrade over v1's approach (a hand-rolled GBNF grammar that
  `LlamaCommandInterpreter`'s own comments admit isn't actually enforced at decode time by the
  LLM.swift binding — see the earlier pipeline review). Declare tools mirroring today's
  `InterpretedCommand.Action` enum, extended with the new intents:
  `ack_med`, `call`, `send_message`, `emergency`, `set_reminder` (generalized — see §4.1),
  `create_calendar_event`, `identify_appliance`, `get_instructions`, `suggest_video`,
  `health_query`, `music`, `query`, `none`.
- **Timeout + fallback**: hard 6-second timeout per call (generous for Flash Lite's typical
  latency, tight enough to keep the "instant enough" feel v1 never achieved). Any timeout,
  5xx, or connectivity failure routes back to `CommandRouter.routeKeyword` — same fallback
  shape as today's "LLM not confident" path, new trigger conditions.
- **Cost governance**: a local, per-day call counter (`UserDefaults` or the existing encrypted
  storage) with a family-configurable soft cap. On exceeding it, degrade to keyword-only mode
  and notify family through the existing `FamilyNotifier` channel rather than silently
  continuing to spend — a wedged wake-word loop (false triggers) should not be able to produce
  a runaway bill. Emit every call's estimated token/audio cost through `ObservabilityBus` so a
  future family-facing usage screen is a display layer away, not a re-plumb.

### 3.3 Audio pipeline changes

`AudioSessionManager`, `WakeWordEngine`, and the VAD layer are **unchanged** — they still do
exactly what they do today: gate when the mic is "hot" and detect end-of-utterance. What
changes is what happens to the captured PCM buffer: instead of handing it to
`WhisperSpeechRecognizer.feed()`/`finish()`, it gets encoded (WAV is simplest, FLAC if
bandwidth matters) and sent as inline audio data in a single `GeminiClient.understand(...)`
call alongside the conversation context. The response carries the transcript (for the UI's
live-caption/history features — still real, still displayed, just sourced differently),
the structured intent, and the spoken-reply text.

This also directly fixes the redesigned UI's one honestly-flagged limitation from the previous
work: the live-caption pill's "v1 caveat" was that STT was batch-only with no partial-result
stream. Gemini's `generateContent` can be used in streaming mode
(`streamGenerateContent`) — a genuine path to incremental, real-time-feeling captions that
whisper.cpp's blocking C++ calls could never offer. Worth doing in Phase 0 rather than
deferring, since the UI component is already built to consume progressively-revealed text.

## 4. Feature designs

### 4.1 Reminders, unified (medication, exercise ×2/day, walk, gym, meals, bedtime, reading,
"call a relative")

The brief lists nine categories of reminder. Building nine parallel reminder systems would be
the same mistake v1 nearly made with model management sprawl. Instead: generalize
`MedicationEntry` into `RoutineEntry` with a `category` enum
(`.medication, .exercise, .meal, .walk, .gym, .bedtime, .reading, .callRelative, .custom`),
reusing `MedicationScheduler`/`EscalationEngine`/`DoubleDoseDetector`'s already-hardened
ack/escalation/re-fire machinery for all of them — that code has nothing medication-specific
about its *scheduling and escalation* logic; only display strings and photo-verification are
category-specific.

Per the brief's explicit requirement — **"all reminders are created using native calendar"**
— every `RoutineEntry` gets a mirrored `EKEvent` in the iOS Calendar app via `EventKit`
(`EKEventStore`), not a private-only store. This buys two things for free: the family can see
the elder's schedule in any calendar app, and the reminder survives even if our app's own
notification scheduling ever misfires (belt-and-suspenders, matching the constitution's
existing "medication reminder must persist / re-fire on relaunch" safety requirement).

Google Calendar sync (OAuth via Google Sign-In) is a separate, additive layer on top: lets
family review/edit the elder's schedule from their own Google account, and pull shared family
events onto the elder's device. This needs a one-time consent/OAuth dance — treat it as
family-assisted setup, not something the elderly user does alone, consistent with the existing
onboarding pattern.

### 4.2 Nepali religious calendar

Google Calendar's built-in "Hindu Calendar" interest calendar is India-centric and will not
reliably match Nepali Bikram Sambat-specific observances (exact BS dates for Dashain, Tihar,
Nepali New Year, Teej can differ from Indian dates or not exist on that calendar at all).
**Recommendation: don't build Panchanga/BS-date math ourselves for v2.0.** Instead, have the
family subscribe the elder's Google Calendar to an existing, community-maintained Nepali
calendar ICS feed (several public ones exist) during setup — the app then just reads whatever
lands in Google Calendar via the sync built in §4.1. This punts calendar-accuracy risk to an
already-vetted external source instead of us re-deriving lunar calendar math with all its edge
cases. Flagged in §10 as a decision needing a specific source picked and verified, not because
the approach is uncertain.

### 4.3 Calling, messaging, WhatsApp, FaceTime

Grounded directly in `docs/messaging-calling-platform-research.md` (already in this repo, from
earlier v1 research — its conclusions don't change with the Gemini pivot, since they're about
iOS platform capability, not which AI powers the assistant):

| Ask (from the brief) | Feasible on iOS? | Mechanism |
|---|---|---|
| Make phone calls by voice | **Yes** — already built | `tel:` deep link (`AppCoordinator.placeCall`, shipped in the previous session) |
| FaceTime audio/video calls | **Yes, genuinely initiates the call** — not yet built | `facetime://` / `facetime-audio://` deep link |
| Send text messages | **Yes, with a caveat** — already built | `MFMessageComposeViewController` — Apple requires the user's own tap on Send; no third-party app can send SMS silently |
| Read incoming text messages | **No public API at all** | iOS has zero API for reading another app's or even the system's SMS/iMessage inbox |
| WhatsApp/Messenger **messages** | **Partial** — outbound only | `https://wa.me/<phone>?text=...` deep link opens a pre-filled chat; user still taps send inside WhatsApp |
| WhatsApp/Messenger **calls** | **No public API** | There is no documented, public mechanism to initiate a WhatsApp or Messenger voice/video call from a third-party app on iOS. Building this is not a matter of effort — the API doesn't exist. |
| "Accessibility API" for any of the above | **No** | iOS accessibility APIs are outbound-only (declaring your own app to VoiceOver); there is no cross-app control API like Android's `AccessibilityService`. This was already researched and rejected in v1. |

**Recommendation**: build FaceTime deep-link calling (net-new, easy, genuinely works). Support
WhatsApp for outbound pre-filled text only, with the same "you still tap send" framing as SMS.
Drop Messenger from scope — no integration point exists. Reframe "read text message" as "read
me what my family sent through Sahayak" using the existing/planned encrypted family-notifier
channel (`docs/remote-config-channel-design.md`), since reading the user's actual SMS/WhatsApp
inbox is not something any app can do on iOS, Gemini or not.

### 4.4 Vision Helper — appliance manuals and TV/remote guidance

This is the most novel ask in the brief and the one most worth simplifying aggressively rather
than over-building:

1. Elder photographs an appliance (or the remote, or the TV's smart-hub screen).
2. Photo → `GeminiClient` vision call: identify the appliance/remote, and answer the user's
   actual question directly from the photo using Gemini's own world knowledge of common
   appliance UIs — **do not build an automated manual-download/scraping pipeline for v2.0.**
   That's a separate, fragile project (finding the right PDF for an arbitrary brand/model,
   parsing it, handling copyright/quality variance) that may not even be necessary: Gemini
   already has broad knowledge of how a "Panasonic microwave control panel" or "generic Sky
   remote" works from the photo alone. Validate whether that's good enough before building
   manual retrieval at all — recommend treating manual-fetching as a v2.2+ stretch goal, gated
   on evidence that photo-only answers aren't good enough.
3. For steps referencing a specific physical control, request Gemini's vision grounding
   (bounding box / point for the named button/dial in the ORIGINAL image) and render a
   circle/arrow overlay at those real coordinates over the real photo client-side. This is the
   brief's "AR-style annotated instructions," achieved without image generation (see §3.1).
4. Caching: cache every successful appliance identification locally (photo hash or
   brand+model key → last instruction set). A household owns a handful of appliances — cache
   everything, evict by simple LRU/age, no need for a second AI-driven caching-policy decision.
5. Generalize step 1-4 into one "AI Visual Helper" capability rather than building a
   microwave-specific feature and a separate TV-remote feature — same pipeline, different
   subject.

### 4.5 Video bookmarks and proactive suggestions

`VideoBookmark` (URL + title + tags + preferred time-of-day), added by family via Settings
(and, as a stretch, by the elder saying "यो सम्झनामा राख" while a link is shareable). The
*decision* of when to proactively suggest a bookmarked video ("बिहान भयो, योग भिडियो हेर्ने
हो?") should be a simple local heuristic (time-of-day + tag match) — this genuinely doesn't
need a Gemini call and works offline; only route to Gemini when the elder asks an open-ended
"something nice to watch?" and a natural-language answer over the bookmark list adds value.

## 5. Always-on mic ("like Siri")

The brief elevates wake-word from v1's explicitly-deferred status to an in-scope v2
requirement. The engine already exists (`PorcupineWakeWordEngine`, gated behind a missing
access key + trained `.ppn` file per `WakeWordEngine.swift`) — this is a matter of actually
completing that integration (Picovoice account, wake-word training, bundling the file), not
new engineering.

**Wake word stays 100% on-device regardless of the Gemini pivot.** This is a deliberate,
important design line: you do not want to stream microphone audio to Gemini continuously —
for cost, for battery, and because it would make the privacy trade in §6 far worse than it
needs to be. The architecture is exactly Siri/Alexa's own shape: a cheap, always-on local
classifier gates a much more expensive cloud brain that only wakes up after the trigger phrase.

## 6. Privacy, consent, and compliance — the section not to skip

Moving STT/NLU/vision to Gemini means raw voice recordings, transcripts, and photos of the
user's home now leave the device to Google's servers. This directly reverses
`constitution.md`'s privacy standard ("No personal data transmitted to cloud for AI
processing") and Architecture Constraint #1. Concretely required, not optional:

- **A genuinely plain-language consent screen**, walked through with family present at setup
  (matching the existing family-assisted onboarding pattern), stating in the elder's own
  language that their voice and photos are sent to Google's AI to be understood. Not a legal
  wall of text — this population is exactly who consent theater fails.
- **Confirm the Gemini API billing/terms tier before shipping to a real user.** Google's
  default consumer-tier Gemini API terms currently permit using submitted content to improve
  models unless a different tier/agreement is in place. Given medication-adjacent conversation
  content, this needs explicit verification — don't assume the free/default tier is
  acceptable and check Google's current terms before this reaches a real elderly user's
  medication conversations.
- Revisit the constitution's HIPAA/GDPR "assumed not applicable" open decisions — that
  assumption was partly *because* data stayed on-device. It needs re-evaluation now that it
  doesn't.
- **The deterministic safety-net keyword layer keeps working with zero network dependency and
  zero cloud transmission, unchanged from v1.** This is the load-bearing mitigation: the single
  most safety-critical path (medication ack, emergency) never depends on the privacy trade at
  all. Only the open-ended "assistant conversation" layer opts into cloud processing.

## 7. Cost model

Flash Lite is priced for exactly this kind of high-volume-but-simple workload. Rough
back-of-envelope at generous usage (dozens of exchanges/day/household) stays in
cents-per-month territory on list pricing — but the actual number matters less than having a
**hard local circuit breaker** (§3.2) so a failure mode (false wake-word triggers looping) can't
turn into a surprise bill. Build the daily-call counter and soft-cap-with-fallback in Phase 0,
not as a later hardening pass.

## 8. What gets deleted / simplified vs. v1

**Removed** (replaced, not just deprecated):
- `LlamaCommandInterpreter.swift`, `LlamaGrammar`, the LLM.swift SPM dependency, the LLaMA
  GGUF catalog entries.
- `WhisperSpeechRecognizer.swift`, `WhisperKitSpeechRecognizer.swift`, vendored SwiftWhisper,
  whisper.cpp CoreML encoder assets — and with them, the entire per-attempt-context /
  watchdog / two-strike-throttle machinery that existed solely to defend against whisper.cpp
  hangs. That machinery was good engineering for the problem it had; the problem goes away
  with hosted inference.
- Most of `ModelStore`/`ModelDownloadService`/the buried AI Models settings screen — no more
  multi-GB STT/LLM downloads. (A small download may remain for the Piper TTS voice and the
  Porcupine wake-word file — tiny by comparison.)

**Unchanged** (this pivot is narrower than it sounds):
`VoicePipeline`'s state machine, `AudioSessionManager`, `WakeWordEngine`,
`VoiceActivityDetector`, `CommandRouter`'s deterministic keyword layer,
`MedicationScheduler`/`EscalationEngine`/`DoubleDoseDetector`, `FamilyNotifier`, and the entire
UI redesign from the previous session (Home hero, dock, outcome cards, live-caption pill,
face-tile contacts, emergency icon, buried AI-model settings pattern). None of it is
Gemini-specific; all of it is still exactly right.

## 9. Phased roadmap

- **Phase 0 — Foundation.** `GeminiClient` + `GeminiCommandInterpreter` replacing the LLaMA
  path; direct audio understanding replacing Whisper in `VoicePipeline`; streaming responses
  for live captions; real network-failure → keyword-fallback wiring; cost circuit breaker;
  ship wake-word for real. This alone fixes v1's #1 usability complaint (latency/hangs) and
  unlocks everything else.
- **Phase 1 — Reminders.** Generalized `RoutineEntry` + `EventKit` integration covering all
  nine reminder categories from the brief on one system.
- **Phase 2 — Calling/messaging expansion.** FaceTime deep link (net-new), WhatsApp
  outbound-text (net-new), drop Messenger, reframe "read messages" around the family channel.
- **Phase 3 — Vision Helper.** Appliance + TV/remote guidance via photo + coordinate-grounded
  annotation, no manual-scraping pipeline yet.
- **Phase 4 — Calendar depth + culture.** Google Calendar OAuth sync, Nepali calendar via ICS
  subscription, video bookmarks + proactive suggestion heuristic.
- **Phase 5 — Governance polish.** Family-facing usage/cost visibility, consent-flow hardening,
  revisit manual-retrieval and Gemini-TTS stretch goals based on real usage.

## 10. Open decisions requiring explicit sign-off

Each has a stated recommendation; two are now confirmed, four remain open:

1. **Accept the cloud-AI architecture reversal as a real product decision.** Update
   `constitution.md`'s Architecture Constraint #1 to reflect it, or keep v2 permanently
   separate from `main` as an experimental track? This is the single biggest decision in this
   document. **Still open.**
2. **TTS**: stay local (recommended — free, instant, offline-safe) vs. adopt Gemini audio-out
   (better/more natural voice, adds latency and cost to every reply)? **Still open.**
3. ~~**WhatsApp/Messenger calling**~~ **RESOLVED (2026-09-04): confirmed not achievable on
   iOS — dropped from scope.** WhatsApp stays outbound-text-only (§4.3); Messenger dropped
   entirely.
4. **Nepali religious calendar**: subscribe to a community ICS feed (recommended — fast, but
   depends on an external source's accuracy) vs. build BS/Panchanga date math ourselves
   (accurate to our own verification, slow to build correctly)? If the ICS route, which
   specific feed — needs picking and vetting, not just "one exists somewhere." **Still open.**
5. ~~**Appliance manuals**~~ **RESOLVED (2026-09-04): coordinate-grounding + client-side
   overlay confirmed over image generation (§3.1/§4.4)**; automated manual retrieval/scraping
   stays out of scope for v2.0 — Gemini answers from its own knowledge + the photo.
6. **Gemini API terms tier**: confirm and select the specific billing/terms tier that disables
   using submitted content for model training before any real user's medication-adjacent
   conversations reach the API. This is a compliance gate, not a nice-to-have — needs an
   explicit answer, not a default assumption. **Still open.**
