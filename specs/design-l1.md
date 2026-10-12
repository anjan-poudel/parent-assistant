# Design L1 — Call Dialer Primary/Secondary

| Field | Value |
|---|---|
| Task | `design-l1` (ai-sdd workflow `call-dialer-primary-secondary`) |
| Contract | `architecture_l1` — requires literal `## Overview`, `## Architecture`, `## Components` headers |
| Feature | `call-dialer-primary-secondary` |
| Worktree / branch | `elderly-ai-assistant-call-dialer-primary-secondary` / `feat/call-dialer-primary-secondary` |
| Agent | `sdd-architect` |
| Date | 2026-10-12 |
| Status | Draft for `review-l2` (GO gate) then `security-design-review` (SECURITY-GO) |
| Stack | Swift / SwiftUI iOS app — no web stack; REST/OpenAPI and Docker sections are adapted honestly below (this platform has none) |

Inputs read for this design (all on the feature branch):

1. `specs/call-dialer-primary-secondary/constitution.md` — Feature Constraints 1–12, channel
   table, integration surfaces, DV-1..7 completion gate, "Open Decisions: None".
2. `specs/define-requirements.md` + `specs/define-requirements/index.md` + `FR/index.md` +
   `NFR/index.md` — 19 `FR-CDP-*` + 10 `NFR-CDP-*`, all MUST; lock baseline
   `specs/define-requirements.lock.yaml` (every locked requirement is covered by the
   traceability matrix at the end of this document).
3. `docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — the frozen,
   owner-approved design (2026-10-12). Authoritative for types, shapes and flow; divergences
   are recorded as numbered resolutions/amendments in the closing section — none are silent.
4. `.ai-sdd/workflows/call-dialer-primary-secondary.yaml` — scope comment and the five security
   focus areas (pre-mapped in the Security section).
5. The worktree source itself — every integration point below carries a verified `file:line`.

## Overview

### Context

The app today has a single global dialer preference (`AppCoordinator.defaultCallApp`,
`ios/ElderlyAssistant/App/AppCoordinator.swift:330`, restored at `:2851-2853`, key
`defaultCallApp`), picked as one of four rows in `CallingSettingsView.swift:22-64`. When the
picked channel cannot actually place the call — Messenger with no handle on file, WhatsApp not
installed — the app either dead-ends the tap or silently drops to a different surface, and the
elderly, voice-first user cannot recover.

This feature adds a settings-level **Primary** and **Fallback** dialer (four channels:
`faceTime`, `phone`, `messenger`, `whatsApp`) and routes every call path through a
feasibility-aware chain: **preferred → secondary → phone (GSM hard floor)** — dedupe on equal
picks, each channel attempted at most once, never dead-ends. The fallback resolves *before* the
existing spoken confirmation, which names the actually-routed channel; tap paths announce the
routing out loud; launch failures hop down the chain and are announced via the existing spoken
outcome lane; emergency-contact semantics and the override protocol are untouched.

### Goals (traceable to frozen design Goals 1–4)

1. Two Settings pickers (Primary + Fallback), persisted through the existing `AppCoordinator`
   UserDefaults seam; `secondaryCallApp` defaults to `.phone`.
2. A pure-static feasibility resolver (`CallChannelChain`) whose result — channel plus
   `fellBackFrom` provenance — feeds every announcement and confirmation.
3. The chain runs on **all** call paths: address-book rows, family-contact buttons,
   missed-call dial-back, and voice-initiated calls via MethodResolver's global-default step.
4. The existing multi-turn confirmation is reused exactly, with no new dialogue flow, state or
   question kind; the override protocol is preserved unchanged.

### In scope

As frozen (constitution lines 13–21): the two pickers and persistence; the pure-static resolver
with injected feasibility closures; chain application to all four call-path families; fallback
resolved before the spoken confirmation; launch-fail hop announced via the spoken-outcome lane;
ne/en localization of every new string; scoped test suites.

### Non-goals (binding — must not change)

| Non-goal | Source |
|---|---|
| No dedicated `CallRouter` service — extend the existing seams only | Constitution Constraint 7; frozen design Non-goals |
| No per-contact primary/secondary storage — picks stay the chain's *input* | Constitution Constraint 5 |
| Emergency-contact semantics untouched (`emergencyContacts` at `AppCoordinator.swift:6463` and the `NotifyChannel.resolve` path at `Services/FamilyNotifier/NotifyChannel.swift:39,58` are **not** rewired) | Constitution "Out of scope"; FR-CDP-018 |
| No new dialogue flow — the multi-turn confirmation machinery is reused exactly | Constitution Constraint 6; Decision 5 |
| No new network, data, identity or privacy surface — probes are local (`canOpenURL`, handle-on-file check); numbers/handles are PII | Constitution Constraint 8; NFR-CDP-002 |
| Do not refactor the just-shipped voice pipeline beyond the named MethodResolver seam (PRs #161–#168) | Constitution Constraint 7; NFR-CDP-009 |

### Out-of-scope platform surfaces (honest adaptation)

This is a native iOS app, not a web service. Three sections of the generic architecture
template do not exist here, and this design says so explicitly instead of inventing them:

- **REST API surface / OpenAPI paths — none.** The feature's "API" is a set of internal Swift
  seams (enumerated in Components) plus user-visible surfaces. No HTTP endpoint, no schema, no
  service boundary is added.
- **Infrastructure topology (Docker services) — none.** Build and test infrastructure is
  `xcodebuild` in the worktree, run through `ios/build.sh` (whose release log gate at
  `ios/build.sh:431` is part of the acceptance evidence), with scoped `-only-testing` suites as
  the honest unit gate and the DV-1..7 device sweep on Anzaan (reference device) as the
  completion gate. No container, no server process is part of this feature.
- **Auth strategy — no change.** Settings remain local-only (UserDefaults, same store and
  protection class as `defaultCallApp`); no credential, session, token or identity surface is
  added. The trust model is unchanged: the owner configures the phone, the elder uses it; a tap
  on the elder's own unlocked phone is its own confirmation (unchanged, `AppCoordinator.swift:7822-7829`).

## Architecture

### System context

```
        ┌──────────────────────────── Settings (owner) ───────────────────────────┐
        │  CallingSettingsView:  Primary dialer  (defaultCallApp)                  │
        │                        Fallback dialer (secondaryCallApp — NEW, def .phone)
        └────────────────────────────────────┬─────────────────────────────────────┘
                                             │ UserDefaults seam (AppCoordinator)
     ┌───────────────────────┐    ┌──────────▼──────────┐
     │ Feasibility producers │    │  CallChannelChain    │  (NEW, pure static)
     │  handle on file ──────┼───▶│  route(preferred,    │
     │  canOpenURL probe ────┼───▶│   secondary, feas.)  │──▶ Result{ channel,
     │  (injected closure)   │    │  → never dead-ends   │        fellBackFrom }
     └───────────────────────┘    └──────────┬──────────┘
                                             │
   Call paths consuming the Result:          │
   1. Address-book row dial     (LeafViews) ─┤─▶ announce (call.announce.fallbackRouted)
   2. Family audio/video buttons (tiles)   ──┤─▶ open via CallLinks (one tested home)
   3. Missed-call dial-back                ──┤─▶ launch-fail hop (call.announce.launchFailedFallback)
   4. Voice path                (MethodResolver global-default → requestCallConfirmation)
                                             │
              Spoken confirmation (existing multi-turn window, reused exactly):
              fallback resolved BEFORE pending; prompt composes the disclosure
              (router.call.fallbackDisclosure) from fellBackFrom; override unchanged
```

### ADR-CDP-01 — The chain resolver is a new pure-static file under `Services/Calls/`

**Context.** The frozen design (`§3`) fixes the type shape (`CallChannelChain.Feasibility`,
`CallChannelChain.Result` with `fellBackFrom`, `static func route(preferred:secondary:feasibility:)`)
and names the file only illustratively ("e.g. `Services/Voice/CallChannelChain.swift`"). The
requirements explicitly leave placement to design (index, "Assumptions", lines 153–155).

**Decision.** New file `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` (new
`Services/Calls/` group — the feature's own service home; `Services/` currently has Intents,
Voice, Contacts, Storage, FamilyNotifier, Observability, and no Calls directory). The file
contains exactly:

```swift
enum CallChannelChain {
    struct Feasibility: Equatable {
        let messengerHandleAvailable: Bool
        let whatsAppInstalled: Bool
    }
    struct Result: Equatable {
        let channel: CallApp
        let fellBackFrom: [CallApp]        // attempt order; empty when nothing fell back
    }
    static func route(preferred: CallApp, secondary: CallApp,
                      feasibility: Feasibility) -> Result
    static func attemptOrder(preferred: CallApp, secondary: CallApp) -> [CallApp]  // deduped; .phone always IN the order — never dead-ends
    static let whatsAppProbeURL: URL                                   // URL(string: "whatsapp://")!
    static func whatsAppInstalled(canOpen: (URL) -> Bool) -> Bool      // injected closure (FR-CDP-005)
    static func method(for channel: CallApp, isVideo: Bool) -> CallMethod   // frozen §5 mapping
    static func channel(for method: CallMethod) -> CallApp                  // inverse mapping
    static func nextLaunchFailCandidate(after failed: CallApp,
                                        attemptOrder: [CallApp],
                                        messengerHandleAvailable: Bool) -> CallApp?
}
enum CallChannelVocabulary: Equatable {   // path vocabulary, applied at the AppCoordinator seam
    case anyChannel, audio, video         // permits(_:) + terminal (see ADR-CDP-04)
}
```

**Consequences.** One tested home for routing; deterministic matrices need no platform stubs
(Constraint 12); the frozen shape is implemented verbatim, with three additive statics
(`attemptOrder`, `nextLaunchFailCandidate`, plus the vocabulary enum) justified by FR-CDP-015's
hop and FR-CDP-010's vocabulary — recorded as resolutions RES-1 and RES-6, not silent.

### ADR-CDP-02 — Feasibility producers: handle-on-file is data, the WhatsApp probe is an injected closure

**Context.** Feasibility = local-only checks (FR-CDP-004/005/006). Messenger ⇔ handle on file
(never app-installed); WhatsApp ⇔ `canOpenURL("whatsapp://")`; FaceTime/phone always feasible.
`Info.plist` already lists the `whatsapp` scheme under `LSApplicationQueriesSchemes`
(`ios/ElderlyAssistant/Info.plist:94`) — no plist change. A probe that cannot answer is a
local, immediate result — never a timeout (NFR-CDP-004).

**Decision.** A single probe home on the coordinator: `whatsAppInstalledNow: Bool` computed via
`CallChannelChain.whatsAppInstalled(canOpen: canOpenURLOnMain)` — the existing main-thread
probe hop `canOpenURLOnMain(_:)` at `AppCoordinator.swift:7312-7315` (already the house probe
for Maps/WhatsApp surfaces). The probe URL is the compiled constraint constant
`CallChannelChain.whatsAppProbeURL` (precedent: the `whatsapp://` constant at
`AppCoordinator.swift:7270`). LeafViews' existing view-level probe
(`LeafViews.swift:1171-1174`) is rewritten to delegate to the same static, so there is exactly
one probe implementation. `canOpenURL` returning false for any reason (including platform
refusal) is treated as **not installed** — an immediate local `false`, chain hops on, announced
(never a hang, never a silent retain). Messenger feasibility is the handle-on-file data check:
`CallLinks.messengerHandle(_:)` at `Services/Intents/CallLinks.swift:234-243` (returns "" for
unusable) / `storedMessengerHandle(forNormalizedPhone:)` at `AppCoordinator.swift:8009`.
Handles and numbers are PII and never enter logs (see Log safety).

**Consequences.** Deterministic tests stub the closure (`whatsAppInstalled(canOpen:)` is called
with `{ _ in true/false }` in unit tests; the coordinator seam takes the Bool as a parameter).
No caching, no polling: probes run at call time only (NFR-CDP-004; the staleness residual is
covered by the launch-fail hop, frozen Risks).

### ADR-CDP-03 — The resolution seams return the chain `Result` (provenance-carrying), not a bare channel

**Context.** `resolvedCallChannel(explicit:defaultApp:messengerHandleAvailable:)` at
`AppCoordinator.swift:2099-2105` currently returns a `CallApp` and implements the one hard rule
(Messenger-no-handle → `.phone`). `resolvedMissedCallChannel(familyContact:defaultApp:messengerHandleAvailable:)`
at `:8382-8390` delegates to it behind the shipped `supportsAudio` guard. FR-CDP-016 requires
the tap paths to speak what was skipped — the provenance must reach the tap.

**Decision.** Both seams keep their names (constitution "Integration Surfaces"; frozen §4) and
their pure-static nature, and their **return becomes `CallChannelChain.Result`**; channel-only
consumers read `.channel`. Full signatures:

```swift
static func resolvedCallChannel(explicit: CallApp?,
                                defaultApp: CallApp,
                                secondaryApp: CallApp,
                                messengerHandleAvailable: Bool,
                                whatsAppInstalled: Bool,
                                vocabulary: CallChannelVocabulary = .anyChannel) -> CallChannelChain.Result

static func resolvedMissedCallChannel(familyContact: FamilyContact?,
                                      defaultApp: CallApp,
                                      secondaryApp: CallApp,
                                      messengerHandleAvailable: Bool,
                                      whatsAppInstalled: Bool) -> CallChannelChain.Result   // vocabulary .audio
```

Resolution algorithm (one shared private helper):

1. `preferred = (explicit ?? defaultApp)` normalized through the vocabulary (ADR-CDP-04).
2. `CallChannelChain.route(preferred:secondary:feasibility:)` — the single chain
   implementation; the Messenger-no-handle hard rule disappears (it is now one case of the
   chain, frozen §4).
3. Post-check: if the routed channel is vocabulary-illegal, substitute the vocabulary terminal
   (ADR-CDP-04); `fellBackFrom` is unchanged by the substitution.
4. The missed-call seam adds the shipped `supportsAudio` normalization as step 1's vocabulary
   (`.audio`): a FaceTime audio-preference still routes to `.phone` — today's behavior,
   preserved exactly.

**Consequences.** The row circle, chooser and dial-back keep reading a channel via
`.channel`; the tap paths get `fellBackFrom` for the announcement. `CallChannelResolutionTests`
extends its `assertResolved` helper to `.channel` and adds provenance assertions. Recorded as
RES-2.

### ADR-CDP-04 — Path vocabulary is preserved at the seam (audio never FaceTime, video never GSM)

**Context.** FR-CDP-010 binds: "audio buttons never resolve to FaceTime and video buttons never
to the GSM dialer (`CallApp.supportsAudio`/`supportsVideo` gates unchanged)". The frozen
`route` returns `.phone` as the terminal; on a *video* button that would violate the binding.
Conversely a routed `.faceTime` on an *audio* path would violate it. The frozen design did not
fix this interplay — the requirements did; the mechanism is design's.

**Decision.** `CallChannelVocabulary` applied only at the AppCoordinator seam (the frozen
`route` is untouched):

| Vocabulary | `permits(_:)` | `terminal` | Used by |
|---|---|---|---|
| `.anyChannel` | all four channels | `.phone` | address-book rows (GSM floor per FR-CDP-010 scenario 3); voice path |
| `.audio` | `faceTime` excluded | `.phone` | family audio button; missed-call dial-back |
| `.video` | `phone` excluded | `.faceTime` (the only always-feasible video channel) | family video button |

- Step 1 normalizes the preferred input (`resolvedVideoApp`/`resolvedAudioApp` at
  `Services/Storage/FamilyContactStore.swift:156-164` already do the shipped part of this;
  the seam re-applies it defensively).
- Step 3 substitutes: audio/any routed `.faceTime` → `.phone`; video routed `.phone` →
  `.faceTime`. The substitution never fabricates provenance: `fellBackFrom` keeps only the
  feasibility-skipped channels, and the announcement (composed from `fellBackFrom` +
  `.channel`) always names the channel that will actually open.
- The voice path uses `.anyChannel`: MethodResolver's vocabulary already includes
  `.facetimeAudio`, so the chain must not narrow it (RES-9).

**Consequences.** No `supportsAudio`/`supportsVideo` gate changes; the family buttons and
dial-back keep their exact channel vocabularies; every routed channel is attemptable and
legal for its surface. Matrix tests pin the substitution cells.

### ADR-CDP-05 — Fallback resolves BEFORE the spoken confirmation; the disclosure composes from `fellBackFrom`; the override path is untouched

**Context.** `requestCallConfirmation(contactQuery:callType:requestedApp:sourceTranscript:sourceCommand:)`
at `AppCoordinator.swift:7587-7647` resolves the method (MethodResolver, `:7609-7611`), refuses
Messenger-without-handle with `router.call.messengerNoHandle` (`:7620-7623`), then pends a
`PendingCallAction` (`:7624-7628`, struct at `:7518-7550`) into the existing confirmation
window (`openConfirmationWindow()`, `:7635`, definition `:7170-7189`). Near-miss disclosure is
prepended at `:7641-7645`. FR-CDP-013 requires the chain to run before the pending action and
the prompt to name the routed channel; FR-CDP-014 requires the override and near-miss lines
preserved.

**Decision.** New order inside `requestCallConfirmation`:

1. Contact resolution unchanged (including the near-miss path at `:7604-7608`).
2. `methodResolver.resolve(...)` unchanged (`:7609-7611`).
3. NEW chain step: `intentIsVideo = (resolved.method == .facetimeVideo || .messengerVideo)`;
   `preferred = CallChannelChain.channel(for: resolved.method)`; feasibility =
   (handle-on-file for this contact, `whatsAppInstalledNow`); route via `resolvedCallChannel`
   (ADR-CDP-03, vocabulary `.anyChannel`); routed method =
   `CallChannelChain.method(for: route.channel, isVideo: intentIsVideo)`.
4. `PendingCallAction` is built with the **routed** method (not the originally preferred one),
   `unsupportedRequestedApp` as before, plus two additive fields:
   `fellBackFrom: [CallApp] = []` and `hopCandidates: [CallApp] = []` (attempt-order suffix
   after the routed channel, messenger-without-handle filtered — the launch-fail input,
   ADR-CDP-08).
5. The Messenger-no-handle early return (`:7620-7623`) is **removed from this function** — the
   refusal became a chain hop (frozen §5). The same refusal line and gate remain fully intact
   on the **override** path (`handleCallConfirmationOverride`, `:7665-7669`) per FR-CDP-014
   scenario 2 — that is what "preserved unchanged" binds.
6. `repetitionGuard` (`:7632`), `openConfirmationWindow()` (`:7635`) and the near-miss prefix
   (`:7641-7645`) are unchanged.
7. `confirmationPrompt(for:isRepeat:)` (`:7688-7709`) gains, when
   `!action.fellBackFrom.isEmpty`, the disclosure clause — `L10n.fmt("router.call.fallbackDisclosure", …)`
   — placed after the repeat/unsupported notices and before the method sentence, so the final
   utterance order is: `[near-miss prefix][repeat notice][unsupported-app notice][fallback
   disclosure][method sentence][confirm question]`. The question stays terminal; no extra
   question is added (FR-CDP-016 scenario 2). When nothing fell back, the exact previous
   wording is produced (FR-CDP-013 scenario 3).
8. On "yes", `handleConfirmationResponse` (`:10576+`, call block `:10611-10628`) executes the
   pending action's routed method through `performCallAction` (`:7720-7803`) and the flywheel
   capture records the routed method (`capture` on `PendingCallAction`; `noteConfirmedCallExecution`,
   `:7811-7818`) — the routed channel, never the preferred one, is what executes and teaches.
9. The override path keeps its shipped shape (`:7656-7686`): no-handle gate intact, amended
   action re-confirmed once, `appendCapture(…, .corrected, …)` intact — the amended action omits
   the new fields, so a stale disclosure is never re-spoken after an override.

**Consequences.** One utterance carries routing + disclosure (no ask-before-fallback). The
pending action's contract grows two defaulted fields (RES-7). `router.call.messengerNoHandle`
remains in use (override gate, and stale-state guard at `LeafViews.swift:1573-1580`),
so the key is not orphaned.

### ADR-CDP-06 — MethodResolver's global-default step becomes the settings primary via an injected closure

**Context.** `MethodResolver.resolve(contactId:requestedApp:callType:)` at
`Services/Intents/MethodResolver.swift:47-79` runs four steps; step 4 (`:74-78`) hardcodes
`.phone` with `source: .globalDefault`. The class is deliberately coordinator-free (init
`:22-26`, stores only). Frozen §5: the step becomes the settings primary, mapped
`CallApp → CallMethod` by call type, injected so the resolver stays unit-testable.

**Decision.** `MethodResolver.init` gains a third parameter:

```swift
init(preferenceStore: CallMethodPreferenceStore,
     historyStore: ConfirmedMethodHistoryStore,
     globalDefault: @escaping (_ isVideo: Bool) -> CallMethod = { _ in .phone })
```

Default value preserves today's behavior (and keeps existing constructions compiling).
`AppCoordinator` constructs it at `:1925-1926` with:

```swift
MethodResolver(preferenceStore: callMethodPreferences,
               historyStore: confirmedMethodHistory,
               globalDefault: { [weak self] isVideo in
                   CallChannelChain.method(for: self?.defaultCallApp ?? .phone, isVideo: isVideo)
               })
```

Mapping (frozen §5 table, implemented as `CallChannelChain.method(for:isVideo:)`):
`phone → .phone`; `faceTime → video ? .facetimeVideo : .facetimeAudio`;
`messenger → video ? .messengerVideo : .messengerAudio`; `whatsApp → .whatsappChat`.
Steps 1–3 are byte-for-byte unchanged. Note the shipped property that a bare "video call"
never reaches step 4 (step 1 returns `.facetimeVideo` — `explicitMethod`, `:87-114`), so the
global-default step serves audio-shaped requests; the mapping stays general regardless.

**Consequences.** `MethodResolverTests` gains cases driving the closure (primary Messenger,
primary WhatsApp) and an assertion that the default construction still yields `.phone`.
The feasibility fallback itself does NOT live in MethodResolver — it lives one step later in
`requestCallConfirmation` (ADR-CDP-05), keeping the resolver a pure method mapper (single
responsibility; RES-7).

### ADR-CDP-07 — Tap-path announcement trigger: at resolution, before the open attempt

**Context.** FR-CDP-016 fixes the trigger point as design's to choose ("The exact trigger point
of the tap-path announcement (at the open) is design's to fix at design-l1"). The spoken-outcome
lane already exists: `setOutcome` (`:752`), `speak(key:)` (`:5397`), `speak(text:)` (`:5405+`,
queued Announcement `.interactive` lane).

**Decision.** The announcement is spoken **immediately after the chain resolves and before the
open is attempted**:

- Address-book row: inside `dialChannel` (`LeafViews.swift:1564-1584`), the row state is
  computed once (`rowChannelState`, `:1605-1620` — the seam call at `:1612-1615` gains
  `secondaryApp:` and `whatsAppInstalled:`); when `fellBackFrom` is non-empty,
  `coordinator.speak(text: L10n.fmt("call.announce.fallbackRouted", …))` fires before the
  channel switch at `:1565` dispatches.
- Family buttons: at the top of `performContactCall` (`:7831-7910`) after the chain call and
  before the open switch (the existing observability emit at `:7834-7841` stays; its outcome
  string is extended to classify the routing, e.g. `"video:faceTime:fellBack"` — still
  classification-only, `metadata: [:]`).
- Missed-call dial-back: in `dialBackMissedCall` (`:8457-8483`) after the route decision and
  before dispatching the action.

Rationale: (a) a successful open may background the app before a post-open utterance could be
heard — pre-open is the only ordering that guarantees the phrase is spoken; (b) it matches the
frozen example's declarative tone ("…— call Syanu via WhatsApp"); (c) if the open then fails,
the launch-fail announcement (ADR-CDP-08) follows in the same lane — never silent, and never a
claim about an outcome that did not happen. When `fellBackFrom` is empty, nothing is spoken
(FR-CDP-016 scenario 3 — no added noise).

### ADR-CDP-08 — Launch-fail hop: one helper, observed at every open outcome, candidates from the attempt order

**Context.** Frozen §6 + FR-CDP-015: if the resolved channel's open itself fails (iOS reports
failure, or `CallLinks` returns a failure outcome), attempt the next channel (remaining
fallback step, then `phone`), announcing via the spoken-outcome lane. The failure outcomes
already exist as structured enums: `FaceTimeOutcome.unavailable/.invalidHandle`
(`CallLinks.swift:114-123`), `MessengerOutcome.invalidHandle` (`:145-157`), phone via the
`openPhone` Bool (`:340-344`). WhatsApp has no hard failure case: `WhatsAppCallOutcome`
(`:177-190`) walks the shipped absent-app chain (`needsNativeCompose`, `copiedNumber`) — those
are shipped success-side recoveries with their own spoken disclosures, not launch failures.

**Decision.**

- **Observation points** (every open, exactly once):
  `performCallAction` voice branches (`:7746-7753` FaceTime, `:7794-7800` Messenger),
  `performFaceTimeCall` (`:7955-7959`), `performSystemContactWhatsApp` (`:7992-7998`
  `invalidPhone` = data failure, no hop — nothing dialable anywhere), 
  `performSystemContactMessenger` (`:8074-8081`), `performContactCall`'s per-channel outcomes
  (`:7854-7858`, `:7886-7888`), and the phone Bool checks (`:7860-7862` family; the voice
  `.phone` branch `:7723-7732` currently ignores the Bool — it stops ignoring it, below).
- **Candidates**: `hopCandidates` = the deduped `attemptOrder(preferred:secondary:)` suffix
  after the routed channel, filtered by `nextLaunchFailCandidate(after:in:messengerHandleAvailable:)`
  — dropping only messenger-without-handle (data-authoritative). WhatsApp is attempted even if
  the probe earlier said absent (best-effort: the stale-probe residual is exactly what this hop
  covers; the open then lands on the shipped `needsNativeCompose`/`copiedNumber` recoveries,
  which speak their own disclosures).
- **The hop**: on a failure outcome with a candidate, speak
  `L10n.fmt("call.announce.launchFailedFallback", …)` (failed channel + next channel), then
  attempt the next channel via the existing per-channel open for the context (the routed
  method re-derived with `method(for:isVideo:)`; voice path re-enters `performCallAction` with
  a copied action whose method is the next channel's). At most one announcement per hop; hop
  recursion terminates because candidates are deduped and consumed. Learning follows the
  shipped rule unchanged: a failed open records nothing (`:7746-7750` comment) — teaching never
  happens from a failure.
- **Exhaustion**: a non-phone failure with no candidate can only happen at the floor. The
  `.phone` branch now checks the `openPhone` Bool; false → the shipped honest line
  `call.announce.noPhoneNumber` (the same line the family path already speaks at `:7860-7862`
  and `announceNoUsableNumber` at `:8493-8497`) — a spoken outcome, never a claim. No sixth
  catalog key is needed (RES-8). This closes FR-CDP-015 scenario 3 ("never silent") with the
  five-key budget intact.
- Emergency paths are untouched: none of the above touches `emergencyContacts` or
  `NotifyChannel.resolve`; no probe or hop ever wraps escalation.

### ADR-CDP-09 — Persistence: `secondaryCallApp` on the existing UserDefaults seam; existing installs default to GSM

**Context.** Frozen §1: `AppCoordinator.secondaryCallApp: CallApp` next to `defaultCallApp`,
same `@Published` + UserDefaults pattern, key `secondaryCallApp`, default `.phone`.
`defaultCallApp` is a `@Published` var with `didSet` persistence (`:330-335`) and an init
restore using `.flatMap(CallApp.init(rawValue:)) ?? .phone` (`:2851-2853`).

**Decision.** `secondaryCallApp` is declared identically (property with `didSet` writing the
raw value under key `secondaryCallApp`; restore at the same init site with the same
`.flatMap(CallApp.init(rawValue:)) ?? .phone` shape). An existing install has no stored value →
`.phone` (GSM) — exactly the frozen default and Feature Constraint 4. `secondary == primary`
is legal; dedupe happens at routing time in the chain, not at storage. No migration, no
version bump, no new store. `NFR-CDP-005` round-trip is a unit test over the same
UserDefaults-stepping seam the settings tests already use.

### ADR-CDP-10 — Localisation: the frozen five keys, ne/en parity, composition rules

**Context.** Frozen §7 lists five new keys; all five were confirmed **absent** from
`ios/ElderlyAssistant/Resources/Localizable.xcstrings` at requirements time and again during
this design. Existing keys reused: `settings.calling.title`, `calling.defaultCaption`,
`app.name.facetime|phone|messenger|whatsapp`, `router.call.confirmQuestion`,
`router.call.messengerNoHandle`, `router.call.method*`, `call.announce.*`.
`L10n.str(_:locale:)` / `L10n.fmt(_:locale:_:)` (`App/L10n.swift`) are the resolution
discipline; `L10nCatalogCoverageTests` is the en/ne parity automation.

**Decision.** Five new ne/en entries with fixed parameter contracts (all formatted via
`L10n.fmt`, never string-concatenated):

| Key | Surface | Parameters (contract) |
|---|---|---|
| `settings.calling.primaryTitle` | Settings section title | none |
| `settings.calling.secondaryTitle` | Settings section title | none |
| `router.call.fallbackDisclosure` | confirmation disclosure clause | `%1$@` skipped-channel label, `%2$@` contact name, `%3$@` routed-channel label |
| `call.announce.fallbackRouted` | tap/dial-back announcement | `%1$@` skipped-channel label, `%2$@` contact name, `%3$@` routed-channel label |
| `call.announce.launchFailedFallback` | launch-fail hop announcement | `%1$@` failed-channel label, `%2$@` contact name, `%3$@` next-channel label |

Channel labels resolve through the existing `app.name.*` keys via one shared helper
(`channelLabel(_:locale:)`); the skipped-channel label is `fellBackFrom.first` (attempt order —
the preferred channel that was skipped). When two channels were both infeasible, the clause
names the primary skip and the routed channel; naming the full two-item list would require an
additional list-connector key beyond the frozen five, which FR-CDP-013/016 acceptance does not
require (their scenarios bind: routed channel named + what was skipped disclosed + honest copy)
— recorded as RES-4. Because both templates take (skipped, name, routed) in the same order, one
composition helper serves the confirmation and the tap announcement (single source for copy,
FR-CDP-008). All values are authored ne/en at implementation; sample English copy (illustrative
only — the keys/parameters above are the binding part): `"Messenger isn't available — call Syanu
via WhatsApp"`, `"FaceTime didn't open — trying WhatsApp"`.

### ADR-CDP-11 — Interfaces, data model and topology: adapted honestly (no REST, no DB, no Docker, no auth change)

**Decision.** The feature's interface surface is its Swift seams (Components below); its data
model is local UserDefaults plus the string catalog (Data model section); its "infrastructure"
is the xcodebuild/test/device pipeline (DV-1..7); there is no auth surface to change. These
statements are part of the design so downstream reviewers do not look for artifacts this
platform does not have.

## Components

Component map (C1–C7 are design units, not new modules — five are existing files):

| ID | Name | File | Status |
|---|---|---|---|
| C1 | `CallChannelChain` (+ `CallChannelVocabulary`) | `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` | NEW |
| C2 | Resolution seams (`resolvedCallChannel`, `resolvedMissedCallChannel`, `missedCallDialAction`, feasibility producers) | `AppCoordinator.swift:2099`,`:8382`,`:8423`,`:7312` | extended |
| C3 | Voice path (`MethodResolver` global default + `requestCallConfirmation` + `PendingCallAction` + `confirmationPrompt`) | `MethodResolver.swift:47`, `AppCoordinator.swift:7587`,`:7518`,`:7688` | extended |
| C4 | Tap paths (address-book rows; family buttons; missed-call dial-back) | `LeafViews.swift:1564-1620`, `AppCoordinator.swift:7831`,`:8457` | extended |
| C5 | Launch-fail hop + announcement composition | `AppCoordinator.swift` (new private helper) + open sites (`:7720`,`:7944`,`:7971`,`:8053`,`:7831`) | NEW helper |
| C6 | Settings + persistence | `CallingSettingsView.swift` (whole file), `AppCoordinator.swift:330`/`:2851` | extended |
| C7 | Localization catalog | `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | +5 keys |

### C1 — `CallChannelChain` (new, pure static)

**Responsibilities.** The complete, total routing function plus the pure supporting statics:
route, attempt order, candidate hop step, WhatsApp probe helper, channel↔method mappings, and
the path-vocabulary value type.

**Interfaces.** As listed in ADR-CDP-01. Signatures are frozen-shape (`route`,
`Feasibility`, `Result`) plus the additive statics (RES-1/RES-6).

**Error paths.** None by construction: `route` is total over its enum/struct inputs — every
input combination returns a `Result`; there is no throw, no optionals, no failure case, and no
input can produce an empty `fellBackFrom` with a non-attemptable `channel` (the floor is
unconditional). `nextLaunchFailCandidate` returns `nil` exactly when no candidate remains
(exhaustion), which callers must treat as "speak the shipped outcome line" — a defined state,
not an error. `method(for:isVideo:)`/`channel(for:)` are total bijections on the documented
pairs.

**Concurrency / isolation.** Value types with no mutable state — callable from any isolation
domain; all production call sites are already main-actor (SwiftUI/coordinator), so no new hop
or lock is introduced.

**Timeouts / limits.** None and none added: the function is O(1) with at most three candidate
comparisons; no probe, no clock, no I/O. The latency budget (NFR-CDP-004) is met structurally
(pure computation + at most two local probes at the call sites).

### C2 — Resolution seams (`AppCoordinator`)

**Responsibilities.** Assemble inputs (explicit pick, `defaultCallApp`, `secondaryCallApp`,
handle availability, WhatsApp probe), apply the path vocabulary, run C1, expose the `Result`;
own the pure statics that the view layer and tests call.

**Interfaces.**

```swift
static func resolvedCallChannel(explicit:defaultApp:secondaryApp:
                                messengerHandleAvailable:whatsAppInstalled:
                                vocabulary:) -> CallChannelChain.Result
static func resolvedMissedCallChannel(familyContact:defaultApp:secondaryApp:
                                      messengerHandleAvailable:whatsAppInstalled:)
                                      -> CallChannelChain.Result
static func missedCallDialAction(phone:familyContact:defaultApp:secondaryApp:
                                 messengerHandleAvailable:whatsAppInstalled:name:)
                                 -> MissedCallDialRoute      // { action, channel, fellBackFrom }
var whatsAppInstalledNow: Bool                               // CallChannelChain.whatsAppInstalled(canOpen: canOpenURLOnMain)
```

**Error paths.** All total; `explicit: nil` is the default-input case (settings primary);
`whatsAppInstalled: false` biases to the floor — never throws. `missedCallDialAction` keeps its
shipped guards (empty family contact → the plain `dialPhone` action; empty phone →
`announceNoUsableNumber`, `:8493-8497`). Emergency resolution is deliberately **not** part of
these seams (non-goal; `emergencyContacts` `:6463` untouched).

**Concurrency / isolation.** Pure statics; the probe helper runs on the main actor (the
existing `canOpenURLOnMain` hop, `:7312-7315`). No mutation of coordinator state inside the
seams — resolution is a pure function of (settings snapshot, contact data, probe result).

**Timeouts / limits.** No timeout exists or is added; probe non-answer = immediate `false`
(treated as not installed, chain hops on). The only configurable window in the feature remains
`VoiceSessionStateMachine.config.confirmationTimeoutSeconds` (default 45,
`ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift:135`) — reused unchanged, not
duplicated anywhere.

### C3 — Voice path (MethodResolver + confirmation)

**Responsibilities.** Map the settings primary into the global-default step; run the chain
before pending; carry provenance into the prompt; keep the override path byte-for-byte.

**Interfaces.** `MethodResolver.init(preferenceStore:historyStore:globalDefault:)` (default
`{ _ in .phone }`); `resolve(...)` unchanged signature and sources; `PendingCallAction` fields:
existing ones (`AppCoordinator.swift:7518-7550`) plus `fellBackFrom: [CallApp] = []`,
`hopCandidates: [CallApp] = []`; `confirmationPrompt(for:isRepeat:)` unchanged signature.

**Error paths.** `methodResolver.resolve` keeps its no-throw contract. `requestCallConfirmation`
keeps its `String?` return contract; the Messenger-no-handle early return is replaced by the
hop (ADR-CDP-05); the no-contact path (nil) is unchanged. Unsupported-requested-app disclosure
(`ResolvedMethod.unsupportedRequestedApp`) is unchanged and composes with the fallback
disclosure (both compose, neither replaces — FR-CDP-014 scenario 3). The override no-handle
gate (`:7665-7669`) keeps speaking `router.call.messengerNoHandle` and keeps the original
action pending.

**Concurrency / isolation.** Main-actor coordinator code; the confirmation window
(`openConfirmationWindow` `:7170-7189`) and timeout (`:10561-10569` today,
`VoiceSessionStateMachine.swift:276-319`) are the existing isolation — no new state machine,
no parallel pending action (the single `pendingCallAction` slot at `:7552` is the concurrency
boundary; the chain computation completes before it is written).

**Timeouts / limits.** Reused, configurable, single-sourced: `confirmationTimeoutSeconds`.
No new timer, no probe timeout, no retry loop.

### C4 — Tap paths

**Responsibilities.** Route rows/tiles/dial-back through C2, announce the routing at
resolution (ADR-CDP-07), open through the shipped per-channel functions.

**Interfaces (seams consumed / extended).**

- `LeafViews.rowChannelState(for:)` (`:1605-1620`) — seam call updated to C2's six-argument
  form; `RowChannelState` (`:2249-2266`) gains `fellBackFrom: [CallApp] = []`.
- `LeafViews.dialChannel(_:)` (`:1564-1584`) — announce-then-switch (ADR-CDP-07); dispatch
  branches unchanged (including the stale-state `messengerNoHandle` guard at `:1573-1580`).
- `LeafViews.whatsAppInstalled` (`:1171-1174`) — delegates to `CallChannelChain`.
- `performContactCall(_:kind:)` (`:7831-7910`) — chain at the top with
  `.video`/`.audio` vocabulary; routed channel drives the existing switch.
- `missedCallDialAction` / `dialBackMissedCall` (`:8423-8443` / `:8457-8483`) — new parameters;
  the route struct carries `fellBackFrom` to the announcement.
- Family tiles reach `performContactCall` via `ContactTile.videoCall()/audioCall()`
  (`LeafViews.swift:2654-2660`).

**Error paths.** Every branch keeps its shipped no-silent-failure line
(`router.call.facetimeUnavailable`, `call.announce.messenger*`, `call.announce.noPhoneNumber`,
`announceNoUsableNumber`). The hop (C5) intervenes only between failure outcomes and their
existing lines. A tap never dead-ends (FR-CDP-010 scenarios 1/3).

**Concurrency / isolation.** All view/coordinator code on the main actor; `channelStateVersion`
bump (`:1592-1597`) remains the re-resolution trigger after a chooser pick. The chain runs
synchronously inside the tap handler — no async boundary, no interleaving window.

**Timeouts / limits.** None in the tap paths; the probe is synchronous and local
(NFR-CDP-004). Tap target size/accessibility tokens unchanged (`DesignTokens` pattern).

### C5 — Launch-fail hop (new private helper)

**Responsibilities.** Observe failure outcomes at every open site; compute the next candidate;
announce; re-attempt; stop honestly.

**Interfaces (internal).**

```swift
private func performLaunchFailHop(after failed: CallApp,
                                  candidates: [CallApp],
                                  name: String, phone: String, handle: String?,
                                  isVideo: Bool, locale: Locale) -> Bool   // true if a hop was attempted
```

plus `hopCandidates` threaded through the executes (`PendingCallAction.hopCandidates`;
optional parameters with `= []` default on `performFaceTimeCall`, `performSystemContactWhatsApp`,
`performSystemContactMessenger`).

**Error paths.** Candidate computation is total (pure static). A hop attempt that itself fails
recurse-terminates on the consumed candidate list; exhaustion speaks the shipped outcome line
(ADR-CDP-08). Failed opens never record learning and never write history (shipped rule,
`:7746-7750`). No raw error content is spoken or logged — the announcement names channels, in
the session language (NFR-CDP-003).

**Concurrency / isolation.** Runs inline on the main actor immediately after the failed open
returns; no new queue, no detached task. At most one in-flight hop per tap (synchronous
recursion), so no interleaving and no double-attempt of a channel.

**Timeouts / limits.** The candidate count is bounded by the chain (≤ 2 hops: secondary, then
floor); no timers. "iOS reports failure" is the open call's own return value, never a wait.

### C6 — Settings + persistence

**Responsibilities.** Two pickers (Primary + Fallback) over the four channels; persistence
through the coordinator seam; accessibility parity with the shipped rows.

**Interfaces.** `AppCoordinator.secondaryCallApp: CallApp` (`@Published`, `didSet` →
UserDefaults key `secondaryCallApp`, restore `?? .phone`). `CallingSettingsView` renders two
sections: Primary = existing rows bound to `defaultCallApp` under `settings.calling.primaryTitle`;
Fallback = the same row pattern bound to `secondaryCallApp` under `settings.calling.secondaryTitle`;
`channelRow` (`:40-64`) gains a selection binding parameter; `nameKey` (`:70-77`) and the
`app.name.*` labels are reused verbatim.

**Error paths.** None: binding writes are total; a corrupted/absent stored raw value restores
to `.phone` (fail-safe GSM default). `secondary == primary` is accepted and legal by design.

**Concurrency / isolation.** Main-actor SwiftUI state, identical to `defaultCallApp`'s shipped
pattern; the two properties are independent (no cross-talk).

**Timeouts / limits.** None.

### C7 — Localization catalog (+5 keys)

**Responsibilities.** ne/en entries with the parameter contracts of ADR-CDP-10.

**Error paths.** A missing/format-mismatched key fails `L10nCatalogCoverageTests` (and the
build-time catalog checks); `L10n.str`/`L10n.fmt` behavior for absent keys is the shipped
behavior and is not changed by this feature. Format strings never concatenate — every
new string with parameters is `L10n.fmt` with numbered positionals, so ne/en argument order
cannot drift.

**Concurrency / isolation.** Static resources; read-only.

**Timeouts / limits.** None.

## Integration points (verified `file:line` at design time)

| # | File:line | Current role | Feature change |
|---|---|---|---|
| 1 | `AppCoordinator.swift:330-335` | `defaultCallApp` + UserDefaults didSet (key `defaultCallApp`) | unchanged; new sibling property added |
| 2 | `AppCoordinator.swift:2851-2853` | init restore `.flatMap(CallApp.init(rawValue:)) ?? .phone` | `secondaryCallApp` restore added with the same shape, default `.phone` |
| 3 | `AppCoordinator.swift:2099-2105` | `resolvedCallChannel` — per-contact pick wins; Messenger-no-handle hard rule | runs the chain, returns `CallChannelChain.Result`; six-arg signature |
| 4 | `AppCoordinator.swift:8382-8390` | `resolvedMissedCallChannel` — `supportsAudio` guard + delegate | runs the chain (vocab `.audio`), returns `Result` |
| 5 | `AppCoordinator.swift:8423-8443` | `missedCallDialAction` — pure decision | new params; returns `MissedCallDialRoute` (action + channel + `fellBackFrom`) |
| 6 | `AppCoordinator.swift:8457-8483` | `dialBackMissedCall` dispatch | announce at resolution, then dispatch; hop candidates threaded |
| 7 | `AppCoordinator.swift:7587-7647` | `requestCallConfirmation`; Messenger-no-handle early return `:7620-7623` | chain before pending; early return replaced by hop; prompt disclosure |
| 8 | `AppCoordinator.swift:7518-7550` / `:7552` / `:7553` | `PendingCallAction` + singleton slot + `isAwaitingCallConfirmation` | + `fellBackFrom`, + `hopCandidates` (defaulted) |
| 9 | `AppCoordinator.swift:7656-7686` | `handleCallConfirmationOverride` (`:7665-7669` no-handle gate) | unchanged (FR-CDP-014); amended action drops provenance |
| 10 | `AppCoordinator.swift:7688-7709` | `confirmationPrompt(for:isRepeat:)` | composes `router.call.fallbackDisclosure` when `fellBackFrom` non-empty |
| 11 | `AppCoordinator.swift:7720-7803` | `performCallAction` (voice execution) | failure branches hop; `.phone` branch checks `openPhone` Bool |
| 12 | `AppCoordinator.swift:7831-7910` | `performContactCall` (family tiles; observability `:7834-7841`) | chain + vocab + announcement at top; hop in failure branches |
| 13 | `AppCoordinator.swift:7944-7961` / `:7971-8000` / `:8053-8083` | per-channel openers for rows/search | optional `hopCandidates`; failure branches hop |
| 14 | `AppCoordinator.swift:8009-8011` | `storedMessengerHandle` | feasibility input (unchanged) |
| 15 | `AppCoordinator.swift:7312-7315` | `canOpenURLOnMain` | the WhatsApp probe seam (unchanged) |
| 16 | `AppCoordinator.swift:1925-1926` | `methodResolver` construction | third closure argument (ADR-CDP-06) |
| 17 | `AppCoordinator.swift:6463-6480`; `NotifyChannel.swift:39,58` | emergency resolution | **untouched** (non-goal) |
| 18 | `AppCoordinator.swift:752`, `:5397`, `:5405+`; `:7170-7189`; `:10611-10628` | outcome lane, speak, window, yes/no execution | reused as-is |
| 19 | `LeafViews.swift:1605-1620` (call at `:1612-1615`) | `rowChannelState` 3-arg seam call | 5-arg seam call + `fellBackFrom` on `RowChannelState` (`:2249-2266`) |
| 20 | `LeafViews.swift:1564-1584` | `dialChannel` switch on resolved channel | announcement before the switch |
| 21 | `LeafViews.swift:1171-1174` | local `whatsAppInstalled` probe | delegates to `CallChannelChain` |
| 22 | `LeafViews.swift:2654-2660` | tile video/audio call actions | unchanged call surface into `performContactCall` |
| 23 | `MethodResolver.swift:22-26`, `:47-79` (step 4 `:74-78`) | resolver init + 4-step chain | injected `globalDefault`; steps 1–3 unchanged |
| 24 | `FamilyContactStore.swift:156-164` | `resolvedVideoApp` / `resolvedAudioApp` | the vocabulary-respecting picks (unchanged; feed the seam) |
| 25 | `CallMethod.swift:32-39,45-84,98-144` | method enum + preference/history stores | unchanged |
| 26 | `CallOverrideParser.swift:17-49` | override utterance → `CallMethod` | unchanged |
| 27 | `CallLinks.swift:114-190` (outcomes), `:340-344` (`openPhone` Bool), `:400-470` (openers) | open outcomes | consumed as launch-fail signals (C5) |
| 28 | `CallingSettingsView.swift:22,40-64,70-77` | one picker | two sections; same rows/labels |
| 29 | `VoiceSessionStateMachine.swift:135` | `confirmationTimeoutSeconds = 45` | reused, unchanged (the only configurable window) |
| 30 | `Info.plist:94` | `LSApplicationQueriesSchemes` includes `whatsapp` | no change needed |
| 31 | `ios/build.sh:431` | release log-safety gate wiring | must stay exit 0 (NFR-CDP-003/010) |

## Data model & persistence

No database, no schema, no migration. The feature's persisted data:

| Store | Key | Type | Default | Notes |
|---|---|---|---|---|
| UserDefaults (existing seam) | `defaultCallApp` | `CallApp` raw value string | `.phone` | unchanged |
| UserDefaults (this feature) | `secondaryCallApp` | `CallApp` raw value string | `.phone` (absent → GSM; ADR-CDP-09) | new; same protection class and lifecycle as `defaultCallApp` |
| `ChannelPreferenceStore` | per-contact pick | `CallApp` | none | unchanged; the chain's `explicit` input |
| `CallMethodPreferenceStore` / `ConfirmedMethodHistoryStore` | `call.methodPreferences` / `call.confirmedMethodHistory` | existing formats | — | unchanged; MethodResolver steps 2–3 |
| `MessengerHandleStore` | per normalized phone | handle string (PII) | none | unchanged; feasibility input only |
| `Localizable.xcstrings` | 5 new keys | ne/en values | — | ADR-CDP-10 |

## Localization

- New keys: the five in ADR-CDP-10 (ne/en, both required; parity enforced by
  `L10nCatalogCoverageTests`, which resolves every key in both locales and requires the values
  to differ).
- Reused keys: `settings.calling.title`, `calling.defaultCaption`, `app.name.*`,
  `router.call.confirmQuestion`, `router.call.messengerNoHandle`, `router.call.method*`,
  `call.announce.*`.
- Spoken language follows the session (`activeLocale` → `L10n.fmt(_:locale:_:)`), matching the
  shipped dual-channel honesty convention (`LeafViews.swift:1577` precedent).
- Numbered positional placeholders (`%1$@ … %3$@`) in every parameterized string; composition
  happens in Swift, never by concatenating catalog values.

## Log safety

- No new console writes, prints, `os_log` or `NSLog` anywhere in the feature. All surface
  signals ride the existing observability bus with classification-only outcomes (precedent:
  `"audio:whatsapp"` at `:7838`, `"whatsapp:openedChat"` at `:7978`) and `metadata: [:]` — no
  numbers, no handles, no names (C9 policy comment at `:7840`).
- New/updated outcome tokens classify routing and hops only (e.g. `phone:hop`,
  `faceTime:launchFailed`) — category strings, not content.
- The announcement strings carry names/numbers **spoken to the user in the session language**;
  they never route through logging APIs (NFR-CDP-003).
- `ios/tools/check-release-log-safety.sh` (wired at `ios/build.sh:431`) flags transcript
  mentions, raw error prints and feature-root console writes; the feature must keep it at
  exit 0 — a release gate item in NFR-CDP-010.

## Security pre-map (STRIDE seed for `security-design-review`)

Pre-mapped to the workflow's five focus areas; each row is design-level evidence the security
review will verify against the implementation.

| # | Focus area | STRIDE seed | Design anchor / mitigation |
|---|---|---|---|
| 1 | GSM hard floor — no configuration dead-ends | **Tampering** (misconfiguration removing the floor), **Denial of service** (chain stalls) | `route` is total with an unconditional `.phone` terminal (C1); dedupe can only shorten, never empty, the attempt order; vocabulary substitution preserves attemptability (`.video` lands `.faceTime` — always feasible); NFR-CDP-001's exhaustive 64-cell matrix is a required test; no timeout/blocking exists to DoS (ADR-02/04/08) |
| 2 | Emergency precedence untouched | **Tampering / Elevation** (routing wrapping escalation) | `emergencyContacts` (`:6463`) and `NotifyChannel.resolve` (`NotifyChannel.swift:39,58`) are outside every changed seam; no probe, chain or hop runs on the emergency path; FR-CDP-018 pins it; NFR-CDP-009 regression tests |
| 3 | Probes local-only; no new egress/collection | **Information disclosure** (scheme probing leaking, new egress) | Only `canOpenURL` (local XPC to LaunchServices) and the handle-on-file check; zero network calls in the feature; no new permission or plist entry (Info.plist unchanged at `:94`); handles/numbers never leave the seam inputs |
| 4 | Announcement honesty — no silent route changes | **Spoofing / Repudiation** (spoken line diverging from executed action) | All copy composes from the same `CallLink Result.fellBackFrom` + `.channel` (single source, FR-CDP-008); the pending action stores the routed method (what executes and teaches); tap announcements precede the open; launch-fail lines name the outcome; tests pin wording and the no-fallback case (no added noise) |
| 5 | Log sanitisation | **Information disclosure** (PII in logs) | No new log statements; classification-only observability outcomes; release log gate (`build.sh:431`) must exit 0 (NFR-CDP-003/010) |

Additional seeds: **Elevation** — override protocol still routes through the same pending-action
gate (no side-door execution); **Tampering** — settings are local-only, same store as the
shipped preference, no remote input path exists.

## Testability & deterministic seams

| Seam | Determinism mechanism | Gate suite (scoped `-only-testing`) |
|---|---|---|
| `CallChannelChain.route` / `attemptOrder` / `nextLaunchFailCandidate` | pure statics over enums/structs; exhaustive enumeration, no stubs needed | `CallChannelResolutionTests` — full chain matrix incl. the 64-combination never-dead-end case (4×4×4), dedupe, `fellBackFrom` content/order, vocabulary substitution cells |
| WhatsApp probe | `whatsAppInstalled(canOpen:)` closure — tests pass `{ _ in true/false }`; coordinator seam takes the Bool | `CallChannelResolutionTests`, `MethodResolverTests` |
| Messenger feasibility | handle-on-file Bool input | same |
| MethodResolver global default | injected `globalDefault` closure; stub stores (house `StubEncryptedStorage` pattern in `MethodResolverTests.swift`) | `MethodResolverTests` |
| Confirmation prompt wording | `L10n.fmt` output asserted against the catalog; no-fallback case asserted byte-identical to the shipped wording | confirmation-wording tests (FR-CDP-013/014) |
| Settings persistence | real stores over the UserDefaults seam (house pattern of `SpotifySettingsSurfaceTests.swift`); round-trip + `.phone` default | settings persistence tests |
| Picker UI / accessibility | value-level assertions + `FeatureSourceScan` modifier pin (rendered-tree limits recorded as DV items — house pattern) | picker UI tests (FR-CDP-001/002, NFR-CDP-006) |
| Catalog parity | every new key resolves in both locales and differs | `L10nCatalogCoverageTests` (extended) |
| Dial-back | `MissedCallDialBackTests.swift` extended to the route struct + provenance | `MissedCallDialBackTests` |

Baseline discipline: the full-bundle unit baseline is pre-existing red; scoped suites are the
honest gate, with baseline failures recorded rather than silently included or excluded
(NFR-CDP-008). The new resolver requires no platform stubs (Constraint 12).

## Device validation plan (DV-1..7, Anzaan)

Executed at `final-sign-off` (T2 + HIL); each item records evidence into the feature spec
(FR-CDP-019). Design hook per item:

| DV | Constitution text (abridged) | Design coverage / how to observe |
|---|---|---|
| DV-1 | Settings Primary + Fallback persist across relaunch | C6 paths + `secondaryCallApp` restore (ADR-CDP-09): set both, relaunch, reopen Settings |
| DV-2 | Primary infeasible (Messenger, no handle) → call completes via fallback with spoken announcement naming the routed channel | ADR-05 + ADR-07: voice request and a row tap both speak the routed channel; prompt disclosure present |
| DV-3 | WhatsApp not installed → chain lands on fallback/GSM with announcement; launch failure announced (no silent failure) | ADR-02 probe false → hops; C5: force a FaceTime/other failure → hop line heard |
| DV-4 | `secondary == primary` dedupes; both infeasible → `phone`; zero dead ends | ADR-04 + C1: equal picks, tap, hear the routing, GSM opens; repeat per path |
| DV-5 | Override preserved: "होइन, फोन नै गर" still switches to a phone call | ADR-05 step 9: override after a fallback-bearing confirmation |
| DV-6 | All call paths route the chain: row, family, dial-back, voice | C4 + ADR-06: one fallback-triggering exercise per path, announcement each time |
| DV-7 | ne/en copy localized; spoken language matches the session | ADR-CDP-10 + L10n session wiring: repeat DV-2/3 in Nepali |

## Traceability matrix (lock coverage — every FR-CDP/NFR-CDP)

| Requirement | Design coverage | Primary component(s) | Test/DV evidence |
|---|---|---|---|
| FR-CDP-001 primary dialer setting | ADR-09, C6 | C6, C2 (input) | picker UI suite; DV-1 |
| FR-CDP-002 fallback dialer setting (equal picks legal) | ADR-09, ADR-04 (dedupe), C6 | C6, C1 | picker UI suite; DV-1, DV-4 |
| FR-CDP-003 `secondaryCallApp` persistence, GSM default | ADR-09 | C6 | persistence suite; DV-1 |
| FR-CDP-004 Messenger feasibility = handle on file | ADR-02 | C1 (`Feasibility`), C2 | chain matrix; DV-2 |
| FR-CDP-005 WhatsApp probe via injected closure, local only | ADR-02 | C1 (`whatsAppInstalled`), C2 | chain matrix with stubbed closure; DV-3 |
| FR-CDP-006 FaceTime/phone always feasible; phone floor | ADR-01, ADR-04 | C1 | 64-cell matrix; DV-4 |
| FR-CDP-007 chain preferred→secondary→phone, dedupe, at-most-once | ADR-01, ADR-03 | C1, C2 | `CallChannelResolutionTests` |
| FR-CDP-008 `fellBackFrom` attempt order, single source | ADR-01, ADR-05, ADR-10 | C1, C3, C4 | chain matrix provenance assertions; wording tests |
| FR-CDP-009 explicit pick wins as preferred | ADR-03, ADR-04 | C2, C4 | matrix "pick wins" cells; DV-6 |
| FR-CDP-010 tap buttons route the chain, vocabulary preserved | ADR-04, ADR-07, C4 | C4 | row/tile tests; DV-6 |
| FR-CDP-011 missed-call dial-back routes the chain | ADR-03, C4 | C2, C4 | `MissedCallDialBackTests`; DV-6 |
| FR-CDP-012 MethodResolver global default = settings primary, mapped by call type | ADR-06 | C3 | `MethodResolverTests`; DV-6 |
| FR-CDP-013 fallback before spoken confirmation; prompt names routed channel | ADR-05 | C3 | wording tests; DV-2 |
| FR-CDP-014 override + near-miss preserved | ADR-05 (step 9), C3 | C3 | override tests; DV-5 |
| FR-CDP-015 launch-fail hop announced (never silent) | ADR-08 | C5 | hop tests; DV-3 |
| FR-CDP-016 automatic routing + announcement (no ask) | ADR-07, ADR-05 (step 7), ADR-10 | C4, C3 | announcement tests; DV-2/3 |
| FR-CDP-017 ne/en new strings | ADR-10, C7 | C7 | `L10nCatalogCoverageTests`; DV-7 |
| FR-CDP-018 preserved behaviours (no new dialogue, emergency untouched, no silent failures) | ADR-05, ADR-08, non-goals, integration #17 | C3, C5 | regression suites; DV-5/6 |
| FR-CDP-019 DV-1..7 gate recorded | Device validation plan | all | DV evidence pack at final-sign-off |
| NFR-CDP-001 zero dead ends across 64 cells | ADR-01, ADR-04 | C1 | exhaustive matrix (deterministic) |
| NFR-CDP-002 probes local, no new surface | ADR-02, ADR-11 | C2 | zero-network assertion; review |
| NFR-CDP-003 log safety | Log safety section, ADR-08 | C5, C7 | release log gate exit 0; observability tokens |
| NFR-CDP-004 ≤ 100 ms added latency; probe non-answer immediate | ADR-02, C1–C5 timeouts | C1, C2 | on-device timing measurements (DV-2 run); no-timeout design |
| NFR-CDP-005 persistence round-trip | ADR-09 | C6 | round-trip suite; DV-1 |
| NFR-CDP-006 picker accessibility | C6 (+ house token pattern) | C6 | picker UI tests; DV-1 (VoiceOver on device) |
| NFR-CDP-007 100% ne/en parity | ADR-10 | C7 | `L10nCatalogCoverageTests`; DV-7 |
| NFR-CDP-008 deterministic scoped suites | Testability section | all | scoped `-only-testing` runs recorded |
| NFR-CDP-009 no regression (voice pipeline, emergency, dial-back) | Non-goals; integrations #17/#23 | C3, C2 | scoped regression suites; baseline recorded |
| NFR-CDP-010 compliance/review/release gates; DV acceptance | Security pre-map; DV plan | all | GO/SECURITY-GO gates; log gate; DV pack |

## Amendments and design-time resolutions to the frozen design

No amendment to the frozen design's owner decisions (1–5), type shapes (`Feasibility`,
`Result.route`) or flow is required. The items below are the design choices the frozen design
or the requirements explicitly left to `design-l1`, plus two additive shapes required by
locked requirements; each is recorded rather than resolved silently.

| ID | Item | Resolution | Authority |
|---|---|---|---|
| RES-1 | Resolver file placement (frozen §3 says "e.g. `Services/Voice/…`") | `ios/ElderlyAssistant/Services/Calls/CallChannelChain.swift` — the feature's own service group; requirement index leaves placement to design | Frozen §3 "e.g."; requirements index assumption |
| RES-2 | `resolvedCallChannel`/`resolvedMissedCallChannel` return type | Return `CallChannelChain.Result` (channel + provenance); channel-only consumers read `.channel` | FR-CDP-016 needs provenance at the tap seams; frozen §4 wording ("run the chain") preserved |
| RES-3 | Vocabulary application mechanism (FR-CDP-010 vs the raw chain floor) | `CallChannelVocabulary` at the AppCoordinator seam; the frozen `route` is untouched; `.video` terminal is `.faceTime`, `.audio`/`.anyChannel` terminal `.phone` | FR-CDP-010 binding; frozen §3 shape unchanged |
| RES-4 | Skipped-channel naming with multiple skips | Disclosure/announcement copy names `fellBackFrom.first` (the primary skip) + the routed channel — within the frozen five-key budget; FR-CDP-013/016 scenarios bind no more than this; the copy never asserts anything false | ADR-CDP-10; scope discipline |
| RES-5 | Tap-path announcement trigger point (frozen §FR-CDP-016 leaves it to design) | Spoken immediately after resolution, before the open attempt, via the existing lane | ADR-CDP-07 rationale (app-switch may silence post-open speech) |
| RES-6 | `attemptOrder` / `nextLaunchFailCandidate` statics | Added to `CallChannelChain` (pure, testable) to power the FR-CDP-015 hop | FR-CDP-015; frozen §6 |
| RES-7 | `PendingCallAction` gains `fellBackFrom` and `hopCandidates` (defaulted); `MethodResolver` gains the injected `globalDefault` closure (defaulted to today's `.phone`) | Additive, defaulted — existing constructions and shipped behavior unchanged | FR-CDP-013 provenance; frozen §5 injection requirement |
| RES-8 | Launch-fail exhaust-case copy key | The hop speaks `call.announce.launchFailedFallback`; an exhausted floor-open speaks the shipped `call.announce.noPhoneNumber` line — no sixth catalog key added (five-key budget intact) | FR-CDP-015 scenario 3; frozen §7 key list |
| RES-9 | Voice-path vocabulary | `.anyChannel` (no path filter): MethodResolver's vocabulary already includes `.facetimeAudio`, and the resolved method's `isVideo` shapes the re-mapped method; bare video requests never reach the global-default step | Frozen §5; FR-CDP-012 |
| RES-10 | Launch-fail observation points | Every open outcome site enumerated in ADR-CDP-08; WhatsApp's `needsNativeCompose`/`copiedNumber` remain shipped recoveries (not launch failures); failed opens never teach | Frozen §6; FR-CDP-018/NFR-CDP-009 (shipped behavior preserved) |

## Open items

None at design level. Items the requirements recorded as design-inputs are all resolved above
(RES-1..RES-10); copy wording beyond the binding key parameters is catalog-time work inside
C7. Anything discovered during `review-l2`/`security-design-review` that would change a frozen
shape returns here as a numbered amendment rather than a silent edit.
