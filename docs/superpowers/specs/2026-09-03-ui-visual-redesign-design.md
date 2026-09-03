# UI Visual & UX Redesign — "Sahayak Home"

Status: approved via brainstorming session (visual companion), ready for implementation planning.

## 1. Goals & non-goals

**Goal:** redesign the iOS app's visual language and screen structure to feel modern and warmly approachable for elderly, non-English-speaking, technically-unconfident users — while making the primary voice interaction more trustworthy (visible feedback, confirmable outcomes) — without touching how the voice pipeline actually works.

**Non-goals (hard invariant):** this spec makes **zero changes** to `VoicePipeline`, `CommandRouter`, `LlamaCommandInterpreter`, `WhisperSpeechRecognizer`, `AudioSessionManager`, or `VoiceSessionStateMachine`'s state machine/transition logic. Every UI change either (a) consumes states/data these already expose, or (b) adds new `AppCoordinator`-level published UI state that has no effect on pipeline behavior. Where a UI idea would require a pipeline change (e.g. voice-triggered calling), it's called out explicitly as **out of scope**, deferred to the separate pipeline-improvement track.

## 2. Visual system

Evolves the existing "Warm & Soft" `DesignTokens` rather than replacing it — keeps the cream/terracotta world but pushes it toward something more considered:

- **Background:** existing cream `#FAF3E9` retained.
- **Accent (Talk button / signature element):** new warm amber gradient (`#F6B25E` → `#D9822E`), radial, used only for the Talk hero and its glow — the existing forest green `#2A7F62` stays the accent for confirmed/positive actions (cards, "success" states), so the two colors stay semantically distinct (amber = "listening/live", green = "done/confirmed").
- **Icon badges:** hub/dock icons move from bare `SF Symbol` glyphs to circular tinted badges (icon on a soft-tinted background matching its semantic color), replacing the current flat gray-on-white glyphs.
- **Typography:** greeting/display text moves from the current bold serif to **New York** (`Font.Design.serif`, iOS system font — free, ships with full Devanagari coverage, no custom-font risk). Body/status/labels move from default `SF Pro` to **SF Rounded** (`Font.Design.rounded`) — same legibility and Dynamic Type support, warmer terminal shapes without reading as childish. Point sizes stay governed by `DesignTokens`, but change from fixed literals to `@ScaledMetric`-wrapped values so they respect the user's Dynamic Type setting instead of capping at today's fixed 18pt/15pt (see §7).
- **Shape:** card corner radius increases slightly (14pt → 20pt) for a softer, more "cushioned" feel; tap targets, contrast ratios, and the 44pt/18pt accessibility floors are unchanged.
- **Signature motion element:** the Talk button breathes at rest — two concentric rings expand and fade on a ~3.2s cycle (`.idle`), tighten into a faster pulse during `.listening`, and freeze into a steady glow (no motion) during `.speaking`/`.transcribing`/`.understanding` — so the *rate and presence of motion itself* communicates state, not just color and text. Must respect `accessibilityReduceMotion` (see §7) by collapsing to a static glow with no animation when that setting is on.

## 3. Screen structure

### 3.1 Home — the only screen with voice UI

Home becomes a single-purpose "living" screen. Top bar: greeting (New York serif) + time on the left, a persistent small Emergency icon and Settings gear on the right (both 32×32pt circular buttons). Below that, the stage:

- **Talk hero**: the existing `TalkButton`, restyled with the breathing/pulse motion from §2, otherwise driving off the exact same `VoiceSessionState` it does today — no behavioral change.
- **Hint carousel** (new): directly below the hero in `.idle`, replaces relying on the status caption alone. Rotates through 3–4 example phrases the user can literally imitate (e.g. *"यसो भन्नुहोस्: 'छोरालाई फोन गर'"*), one at a time, ~4s each, with small dot indicators. Pulled from a static, localized catalog list (no ML involved) — this directly addresses the "blank button, unknown vocabulary" problem for first-time voice-assistant users.
- **Live caption pill** (new, `.listening`/`.transcribing`): a floating card above the dock showing the transcript as it becomes available. **Implementation caveat (see §6):** today's STT is batch-only, so v1 cannot show a truly live, word-by-word partial transcript — it should reveal the final transcript with a brief typewriter effect once STT completes, labeled "तपाईं भन्दै हुनुहुन्छ" during capture as a listening-in-progress affirmation, and swap to the real text once available. True word-level live captioning is a follow-on once the streaming STT work (flagged separately) lands — do not block this redesign on that.
- **Outcome card** (new, replaces relying on TTS alone): after routing completes, a strong visual card appears above the dock — an icon-flip-to-checkmark, one line of outcome text, a timestamp, and an "पूर्ववत् गर्नुहोस्" (undo) link that stays live for ~6s. This is shown *in addition to* the existing spoken reply, not instead of it — dual-channel confirmation for users with age-related hearing loss. Collapses to a small one-line chip after a few seconds; tapping/swiping the chip opens the history sheet below.
- **Conversation history sheet** (new): on-demand only — no permanent conversation card on Home (this replaces the current always-visible `conversationCard` in `HomeView.swift`). Opened by tapping the collapsed outcome chip; a standard bottom sheet listing recent exchanges, dismissible by swipe-down or scrim tap.
- **Dock** (replaces the 2×2 hub grid): a single translucent bar pinned above the safe area with 4 icon-only shortcuts (Medicine, Reminders, Call, Settings), each ≥44×44pt. The Call dock icon uses the top family contact's photo/initial avatar instead of a phone glyph when one exists.
- **Setup-incomplete reminder**: keeps its current function (reopens onboarding) but moves from a full-width card pushing content down to a slim dismissible strip directly under the top bar, so it doesn't compete with the hero for vertical space.

**Confirm-what-I-heard**: this pattern already exists in the pipeline as the `awaitingConfirmation` state (`ConfirmationChips`, `startVoiceAckConfirmation`) — the redesign's job here is purely visual: show the actual pending prompt text (already returned by `startVoiceAckConfirmation` and already spoken) inside the chip card, not just generic yes/no buttons, so the user can see what they're confirming, not just hear it. **This is a UI-only change** — it consumes data the coordinator already produces (`pendingConfirmationEntryId` + the prompt string already passed to `speak(text:)`), it does not add a new confirmation gate to `CommandRouter`. Extending "confirm what I heard" to general low-confidence LLM routing (not just medication ack) would require a `CommandRouter` change and is explicitly **out of scope** for this spec — it's a pipeline change, tracked separately.

### 3.2 Leaf screens — plain, full-screen, no voice chrome

`LeafScreen` (the existing shared wrapper in `LeafViews.swift`) gains one thing: a persistent small Emergency icon in its nav bar, matching Home's — this is the only voice/safety-related UI element that appears outside Home, because it's a safety invariant, not conversational chrome. No Talk hero, hint carousel, live caption, or dock appears on any pushed screen. Each leaf's content area uses the full available height (today's `LeafScreen` already does this reasonably — mostly a skin pass, not a structural rewrite):

- **MedsView**: keep the existing per-dose "लिएँ" button pattern (it already works well) — skin pass only (tinted badge instead of plain dot/icon, updated corner radii/type).
- **RemindersView**: skin pass only, same list pattern.
- **CallView**: structural change. Today this is a fail-closed placeholder (lock icon + "coming soon") because voice-triggered calling is blocked pending biometric auth. Replace it with the actual family contact list (`AppCoordinator.familyContacts`, already populated) rendered as face/initial-avatar tiles with name + relationship — this has standalone value (recognizable, warm, useful even before calling ships) regardless of the calling decision below.
  - **Decision needed, flagged not assumed:** should *tapping* a contact tile place a native `tel:` call directly? This is a touch-initiated action on the user's own unlocked phone — the same trust model as any contacts app — and does not touch `CommandRouter`'s `.call` handling at all (that stays blocked for **voice-triggered** "call X" commands, unchanged, per the existing constitution-driven auth gate). Recommend enabling direct tap-to-dial via `UIApplication.open(tel:)` since it's UI/AppCoordinator-layer only and meaningfully improves the app's usefulness, but this is a product call, not a design requirement — the visual redesign works either way (tile shows a disabled/"coming soon" state on tap if the team prefers to hold off).
- **SettingsView**: unchanged information architecture except AI Models (see §3.3).

### 3.3 Settings — bury, don't remove, the AI/model jargon

Per the reviewed tradeoff: the caregiver/companion app doesn't exist yet, so someone still needs a way to manage STT/LLM model downloads. Resolution: **AI Models stays reachable, but not as a normal visible Settings row.** Move it behind a long-press on the Settings screen's title (or an existing low-visibility affordance) rather than a plain list item — visible to whoever already knows to look (a family member setting the phone up), invisible to the elderly user's normal navigation. Everything else in Settings (Language, Family contacts, Medication schedule, Privacy) keeps its current place and gets only the visual skin pass from §2.

## 4. New components (SwiftUI)

| Component | Purpose | Backed by |
|---|---|---|
| `HintCarousel` | Rotating example-phrase hints on Home idle | Static localized string list, no new state |
| `LiveCaptionPill` | Shows transcript during capture | `AppCoordinator.lastTranscript` (existing), revealed post-hoc per §3.1 caveat |
| `OutcomeCard` | Visual confirmation + undo after routing | New: `AppCoordinator.lastOutcome: OutcomeSummary?` (new lightweight published struct: icon, text, timestamp, undo action) |
| `ConversationHistorySheet` | On-demand transcript history | New: small ring-buffer of past exchanges in `AppCoordinator` (e.g. last 20), replacing the single `lastTranscript`/`lastAssistantReply` pair currently shown permanently |
| `ContactTile` | Face/initial avatar + name row | `FamilyContact` (existing model) |
| `EmergencyIcon` | Persistent safety affordance | Existing emergency intent path; visual-only addition to nav bars |

`TalkButton` is restyled in place (motion + gradient), not replaced — its state bindings to `VoiceSessionStateMachine.state` are unchanged.

## 5. Data flow

No new data flows into the voice pipeline. New data flows are UI-state only, all owned by `AppCoordinator` (already the composition root for UI-facing state):

```
VoicePipeline / CommandRouter (unchanged)
        │  (existing: lastTranscript, lastAssistantReply, pendingConfirmationEntryId)
        ▼
AppCoordinator  ── + lastOutcome: OutcomeSummary?          (new, UI-only)
                 ── + conversationHistory: [Exchange]        (new, UI-only, capped ring buffer)
        │
        ▼
HomeView (hero, hint carousel, live caption, outcome card, history sheet)
```

`OutcomeSummary` and `conversationHistory` are populated from the same call sites that already set `lastTranscript`/`lastAssistantReply` (`recordTranscript`, `noteAssistantSpoke`) — additive fields, not a rerouting of existing calls.

## 6. Known implementation caveats (be upfront about these)

- **Live captions are not truly real-time in v1.** The current STT stack (`WhisperSpeechRecognizer` and the in-flight `WhisperKitSpeechRecognizer`) is batch-only — there is no partial-transcript stream to bind the caption pill to yet. Ship the typewriter-reveal-on-completion version now; upgrade to true word-level live captions only once the separately-tracked STT streaming work lands. Don't block this redesign on that.
- **Confirm-what-I-heard is scoped to the existing medication confirmation flow only.** Broader "always echo back low-confidence intents" is a `CommandRouter` change and explicitly out of scope here.
- **Tap-to-call is a product decision**, not a design blocker — see §3.2.

## 7. Accessibility

- Replace `DesignTokens`'s fixed-point font sizes with `@ScaledMetric`-driven values so 18pt/15pt become the *floor at the default Dynamic Type size*, not a hard ceiling — users who've increased their system text size should see it reflected here.
- All new motion (breathing rings, pulse, typewriter reveal) must check `UIAccessibility.isReduceMotionEnabled` / the `accessibilityReduceMotion` SwiftUI environment value and fall back to a static equivalent (steady glow, instant text) when set.
- New components need explicit `.accessibilityLabel`/`.accessibilityValue` the same way `TalkButton` already does — the hint carousel in particular should announce the current phrase via VoiceOver, not just show it.
- Contrast: amber-on-white (Talk hero label) and the new tinted icon badges need a manual WCAG AA contrast check before shipping — the amber gradient in particular skews lighter than the current flat accent green.

## 8. Explicitly deferred (raised during brainstorming, not in this spec's scope)

- Proactive daily check-in prompts (assistant speaks first) — needs scheduling design, family-configured opt-in.
- Onboarding reorder (lead with a "say hello" magic moment before permissions/model chores) — separate flow, own spec.
- Caregiver/companion app or web dashboard for family-side configuration (would eventually absorb AI Models entirely, resolving §3.3's "bury, don't remove" as an interim state).

## 9. Testing

- Extend existing `DesignTokens`-driven snapshot/unit tests to cover the new `@ScaledMetric` behavior at multiple Dynamic Type categories.
- New components (`HintCarousel`, `OutcomeCard`, `ConversationHistorySheet`, `ContactTile`) get standard SwiftUI preview + unit tests for their data-driven variants (empty state, populated state).
- No changes required to existing `VoicePipeline`/`CommandRouter`/scheduler test suites — this spec doesn't touch that code.
