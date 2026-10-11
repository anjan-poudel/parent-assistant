# L2 Component Design — Call Dialer Primary/Secondary

**Feature:** `call-dialer-primary-secondary` · **Branch:** `feat/call-dialer-primary-secondary` (worktree `elderly-ai-assistant-call-dialer-primary-secondary`)
**Task:** `design-l2` (agent `sdd-principal-engineer`) · **Contract:** `component_design_l2` → `specs/design-l2.md`
**Date:** 2026-10-12 · **Status:** for `review-l2` (GO gate), `security-design-review` (SECURITY-GO gate), `plan-tasks` and `implement`
**Refines:** `specs/design-l1.md` (binding architecture: ADR-CDP-01…11, components C1–C7, integration points 1–31, RES-1…RES-10) to implementation-grade component interfaces. No frozen-design shape (`Feasibility`, `Result`, `route`, the five catalog keys, the confirmation flow) is changed. The refinements this document adds are itemised in §5, each traceable to a named L1 anchor; L1 "Open items" is "None", so nothing here re-opens a decision.

**Path convention (inherited from L1).** Paths are repo-relative. Where one path would exceed the release-log sanitiser's token limit (40 consecutive characters from the class `[A-Za-z0-9/+=]`), it is split across adjacent code spans; `ios/ElderlyAssistant/Services/` + `Calls/CallChannelChain.swift` denotes the single path obtained by joining the spans directly. The split is a sanitiser convention only.

**Identifier-break convention.** The same 40-character run limit applies to any single identifier (test names included): where its text would form one run of 40 or more characters from that class, it is broken across adjacent code spans that join with no separator. Every break of this kind below follows this convention.

**Sanitizer discipline.** No credentials, no token samples, no secret material, no PII fixtures. Every quoted utterance is a benign fixture from the requirements corpus. No auth surface is touched by this feature.

**Sources verified for this document.** Every interface below was re-read against the worktree source at this baseline, not against L1 prose alone: `ios/ElderlyAssistant/App/AppCoordinator.swift` (`defaultCallApp` + key `:330-335`; init restore `:2851-2853`; `methodResolver` lazy `:1925-1926`; `resolvedCallChannel` `:2099-2105`; `canOpenURLOnMain` `:7312-7315`; the shipped `whatsapp://` literal `:7270`; `PendingCallAction` `:7518-7550`; slot `:7552`; `isAwaitingCallConfirmation` `:7553`; `requestCallConfirmation` `:7587-7647` incl. the Messenger-no-handle early return `:7620-7623` and the near-miss prefix `:7641-7645`; `handleCallConfirmationOverride` `:7656-7686` incl. the gate `:7665-7669`; `confirmationPrompt` `:7688-7709`; `performCallAction` `:7720-7803`; `noteConfirmedCallExecution` `:7811-7818`; `performContactCall` `:7831-7910` incl. the observability emit `:7834-7841`; `performSystemContactCall` `:7923-7937`; `performFaceTimeCall` `:7944-7961`; `performSystemContactWhatsApp` `:7971-8000`; `storedMessengerHandle` `:8009-8011`; `performSystemContactMessenger` `:8053-8083`; `noteSearchChannelTap` `:8088-8097`; `resolvedMissedCallChannel` `:8382-8390`; `MissedCallDialAction` `:8397-8416`; `missedCallDialAction` `:8423-8443`; `dialBackMissedCall` `:8457-8483`; `announceNoUsableNumber` `:8493-8497`; `recordConfirmationTimeout` `:10561-10569`; the call block `:10611-10628`; `setOutcome` `:752`; `speak(key:)` `:5397`; `speak(text:)` `:5405`); `ios/ElderlyAssistant/App/LeafViews.swift` (`whatsAppInstalled` `:1171-1174`; `dial` `:1536-1542`; `whatsApp` `:1546-1548`; `dialChannel` `:1564-1584` incl. the stale-state guard `:1573-1580`; `chooseChannel` `:1592-1597`; `rowChannelState` `:1605-1620`; `RowChannelState` `:2249-2266`); `ios/ElderlyAssistant/` + `App/CallingSettingsView.swift` (`channels` `:22`; `channelRow` `:40-64`; `nameKey` `:70-77`); `ios/ElderlyAssistant/Services/` + `Intents/MethodResolver.swift` (init `:22-26`; step 4 `:74-78`; `explicitMethod` `:87-114`); `Services/Intents/CallLinks.swift` (`CallApp` `:66-84` incl. `supportsVideo`/`supportsAudio`; `FaceTimeOutcome` `:114-123`; `MessengerOutcome` `:145-157`; `MessengerChatOutcome` `:163-171`; `WhatsAppCallOutcome` `:177-190`; `messengerHandle` `:234-243`; `openPhone` `:340`; `openFaceTime` `:351`; `openWhatsAppChat` `:366`; `openMessengerThread` `:400`; `openMessengerChat` `:431`; `openWhatsAppCallChat` `:457`); `Services/` + `Storage/FamilyContactStore.swift` (`resolvedVideoApp` `:156-158`, `resolvedAudioApp` `:162-164`); `Services/` + `Contacts/ChannelPreferenceStore.swift`; `App/VoiceSessionStateMachine.swift` (`confirmationTimeoutSeconds = 45` `:135`); `App/L10n.swift` (`str` `:18`, `fmt` `:53`); `Services/MedicationScheduler/` + `DependencyProtocols.swift` (`ObservabilityEvent` `:27-34`); `Info.plist` (`LSApplicationQueriesSchemes` `:59`, `whatsapp` `:94`); `ios/tools/` + `check-release-log-safety.py` (`FEATURE_ROOTS` `:141+`); `ios/build.sh` (`:431`); `ios/ElderlyAssistant/` + `Resources/Localizable.xcstrings` (the five new keys confirmed absent; the reused keys present); and the test bundle (`ios/ElderlyAssistantTests/` + `Services/Voice/` + `CallChannelResolutionTests.swift`; `Services/Intents/MethodResolverTests.swift`; `App/MissedCallDialBackTests.swift`; `App/L10nCatalogCoverageTests.swift`; `Services/Intents/` + `IntentLogStoreTests.swift` `:206`, `:224`).

---

## Overview

### 1. Purpose

Today one global pick (`defaultCallApp`) decides every call, and a pick that cannot place the call either dead-ends the tap or silently drops to another surface. This feature adds a settings **Primary** and **Fallback** dialer and routes every call through a feasibility-aware chain — preferred → secondary → GSM (`phone`) hard floor — announced out loud at resolution and on launch failure (frozen design; constitution Constraints 1–4, 6, 8).

This document is the bridge from L1 to code: it pins the exact Swift surfaces (types, initialisers, method signatures with access levels), the data shapes (the new UserDefaults key, the two additive struct fields), the chain and hop as testable pure-function tables with the 64-cell never-dead-end property, the exact edit each existing file and function receives at its verified anchor, the error/outcome taxonomy (there are no new thrown errors — the feature's failures are typed open outcomes), the observability and release-gate deltas, the concurrency story, the layer-by-layer traceability, and the technical risks `plan-tasks` and `implement` must respect. It is deliberately quiet on anything L1 already froze (frozen §3 `route` shape, the five keys, the confirmation flow) — those are quoted, not redesigned.

### 2. Inputs

- `specs/define-requirements.md` + `specs/define-requirements/index.md` + `specs/define-requirements/FR/` + `NFR/` + the lock — FR-CDP-001…019, NFR-CDP-001…010, 83 scenarios.
- `specs/design-l1.md` — binding architecture (ADR-CDP-01…11; C1–C7; integration points 1–31; data model; localization; log safety; security pre-map; testability; DV-1..7; traceability; RES-1…10).
- `specs/call-dialer-primary-secondary/constitution.md` — Feature Constraints 1–12, the Channel Resolution & Feasibility Contract, the DV-1..7 gate, "Open Decisions: **None**".
- `docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — the frozen owner-approved design (§1–§9, Decisions 1–5, Risks).
- `constitution.md` (root) — Architecture Constraints 1–6, error-typing / timeout / concurrency / observability standards, release gates.
- The worktree source at this baseline (the "Sources verified" list above).

### 3. Cross-cutting conventions

**Error typing — total functions, typed outcomes, no new throws.** Nothing in this feature throws. `CallChannelChain.route`, `attemptOrder`, `hopCandidates`, `isFeasible`, `nextLaunchFailCandidate`, `whatsAppInstalled(canOpen:)`, `method(for:isVideo:)`, `channel(for:)` are total over their inputs and return a concrete type (`Result`, `[CallApp]`, `Bool`, `CallApp?`, `CallMethod`); `nil` from `nextLaunchFailCandidate` is the defined exhaustion state, not an error (L1 C1 "Error paths"). The only failure channel is the typed open-outcome enums the shipped code already returns — `FaceTimeOutcome`, `MessengerOutcome`, `MessengerChatOutcome`, `WhatsAppCallOutcome`, and `openPhone`'s `Bool` — and the only untyped string the feature adds is whatever `canOpenURL` answers, which is immediately collapsed to a `Bool` (`false` ⇒ "not installed", never a timeout, never a hang). No `any`/`unknown`-style existential crosses a component boundary.

**Timeouts are configuration.** No new timeout, timer, retry loop or backoff exists in this feature. The only configurable window remains the shipped `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` (default 45 s, `VoiceSessionStateMachine.swift:135`), reused unchanged by the existing confirmation window and its timeout recorder (`recordConfirmationTimeout`, `:10561-10569`) — the chain runs before the window is used and adds no asynchronous step. The WhatsApp probe is a synchronous local call whose non-answer is an immediate `false` (NFR-CDP-004): "probe could not answer" is modelled as `false`, not as a wait.

**Concurrency is explicit.** Every changed production call site runs on the main actor (SwiftUI views and the coordinator's main-queue-confined methods); the new statics are value-typed and stateless, so no hop, lock, actor or atomics is introduced anywhere. The single `pendingCallAction` slot (`:7552`) remains the feature's one shared mutable resource: written by `requestCallConfirmation` before the window opens, cleared by `handleConfirmationResponse` before execution, and never touched by the hop (the hop copies an action locally after the slot is already `nil`). §26 states readers, writers and the deregistration paths.

**Deterministic-first.** Routing consults no model, no network and no cache: the chain is pure over four inputs (preferred, secondary, handle-on-file, probe result). Probes are local only (`canOpenURL`, address-book handle check) — zero new egress, zero new permission, zero new store (NFR-CDP-002).

**Announcement honesty — one honest line per outcome, never silent.** Every path that resolves or attempts a channel speaks exactly one truthful line for what happened: the tap/dial-back announcement at resolution when the chain skipped a channel (`call.announce.fallbackRouted`), the shipped failure line when an open fails, the hop line when the failure has a remaining candidate (`call.announce.launchFailedFallback`), and the routed-channel disclosure inside the confirmation prompt (`router.call.fallbackDisclosure`). When nothing falls back, nothing extra is spoken (FR-CDP-016 scenario 3 — no added noise); when a channel is skipped, the copy names `fellBackFrom.first` and the channel that will actually open, and never asserts an outcome that did not happen.

**Scope fence.** The feature extends five existing files, adds one new file (C1) and five catalog keys (C7). It adds no `CallRouter` service, no dialog flow, no per-contact primary/secondary storage, no emergency-path change, no network call, no logging statement, and no change to the shipped multi-turn machinery beyond the named `MethodResolver` seam and the `requestCallConfirmation` step (Feature Constraints 5–8; NFR-CDP-009).

### 4. L2 decision log (refinements of L1; each is implemented, tested and reviewable)

| ID | Decision | Rationale / pin |
|---|---|---|
| L2-D1 | **The hop candidate list is vocabulary-aware.** `CallChannelChain.hopCandidates(preferred:secondary:routed:vocabulary:)` returns the attempt-order suffix after `routed`, filtered by the surface vocabulary; when that empties it returns the vocabulary terminal unless the terminal is the routed channel. A vocabulary-SUBSTITUTED routed channel (not itself in the attempt order) has NO candidates — the substitution is the surface's floor, already routed. | FR-CDP-010 binds "video buttons never resolve to the GSM dialer, audio buttons never to FaceTime". L1's raw suffix rule (ADR-CDP-08) would hand a video-button hop to `.phone` and an audio-path hop to a FaceTime secondary. Case table §11.4; tests `testHopCandidatesRespectVocabulary`, `testSubstitutedTerminalHasNoCandidates`. |
| L2-D2 | **`hopCandidates` is a pure static on C1** (L1 RES-6 class, additive), used by the AppCoordinator seams (voice step, `missedCallDialAction`) and by `LeafViews.rowChannelState` — one implementation of the list, and the tests assert it directly. | Vocabulary is applied "at the AppCoordinator seam" (ADR-CDP-04); the list must therefore be computed from the same (preferred, secondary, routed, vocabulary) snapshot everywhere, including the row's per-outcome state. |
| L2-D3 | **The additive struct fields are `var` with `= []` defaults.** `PendingCallAction.fellBackFrom`/`hopCandidates` and `RowChannelState.fellBackFrom`/`hopCandidates` are `var … = []` so the synthesized memberwise initializer exposes them as DEFAULTED parameters; a `let` with an initial value is excluded from the memberwise init (which is why the shipped `requestedAt` cannot be passed today). Existing constructions (`:7624`, `:7670`, `IntentLogStoreTests.swift:206`, `:224`) compile unchanged. `requestedAt` becomes `var` for the same reason, so the hop copy can preserve the original question's clock (`replacing`). | RES-7 promises "additive, defaulted — existing constructions unchanged". The alternative for `requestedAt` (let the hop restart the clock) was rejected: the flywheel's latency is question → verdict, and the question was asked once. |
| L2-D4 | **One `LaunchHop` value instead of a bare candidate array.** The three search-shaped openers gain `hop: LaunchHop? = nil`, where `LaunchHop { let candidates: [CallApp]; let handle: String? }` (internal, nested in `AppCoordinator`, the `MissedCallDialAction` pattern). `nil` preserves today's behaviour byte-identically for the two callers outside the four chain-routed families (recent-activity re-init in `LeafViews`, `HistoryView`'s re-init). | L1 C5 says "optional parameters with `= []` default"; a list without the handle cannot run the messenger feasibility filter, and threading two independent optionals invites drift. One defaulted parameter makes "no hop outside the chain-routed families" structural. |
| L2-D5 | **Two attempt mechanisms over one decision step.** The hop's decide+announce is single-sourced in `launchFailHopStep(after:candidates:handle:name:locale:)` (the only `call.announce.launchFailedFallback` site, also the only hop observability site). The TAP paths attempt through L1's pinned helper `performLaunchFailHop(after:candidates:name:phone:handle:isVideo:locale:) -> Bool` (shipit verbatim), which dispatches to the shipped per-channel openers. The VOICE path attempts by re-entering `performCallAction` with a copied action (L1 ADR-08) — the same executor a fresh confirmation reaches. | The pinned helper's (name, phone, handle, isVideo, locale) cannot select a context-specific opener, and the voice path must stay on `performCallAction` (learning + capture live there). One copy delta is recorded (§11.5): a hopped tap attempt speaks the opener's own success line — for FaceTime `router.call.calling` instead of the family tile's `call.announce.faceTimeVideo`, preceded anyway by the hop line that just named FaceTime; every failure line is the same key in both contexts (verified: `announceNoUsableNumber` `:8493-8497` speaks `call.announce.noPhoneNumber`, the search openers' own line). |
| L2-D6 | **The messenger-without-handle filter lives only in `nextLaunchFailCandidate`.** `hopCandidates` keeps the raw (vocabulary-filtered) suffix — provenance stays consistent with `fellBackFrom` — and the handle filter is applied once, at hop-consumption time. `after:` is a defensive filter: the caller passes the channel that just failed. | One implementation (L1 C5 "Candidate computation is total (pure static)"); the tests can see the unfiltered list and the filtered decision separately. |
| L2-D7 | **A hop that lands is a real open and teaches the hop's method** (`noteConfirmedCallExecution` on the re-entered action; the tap openers record their own activity). A hop that fails records nothing, exactly like the shipped failed-open rule (`:7746-7750`, `:7795-7798`). | "The routed method — what executes and teaches" (ADR-05 step 8) extended to the hop, which is the channel that actually placed the call. `sourceTranscript`/`sourceCommand`/`requestedAt` travel unchanged, so the training pair keeps its provenance. |
| L2-D8 | **Channel labels single-sourced on C1**: `CallChannelChain.nameKey(for:)` (the shipped `app.name.*` keys verbatim: `app.name.facetime`, `app.name.phone`, `app.name.messenger`, `app.name.whatsapp`) and `label(_:locale:)`; `CallingSettingsView.nameKey` delegates to it. | ADR-CDP-10 requires one shared label helper; the picker, the confirmation disclosure and both announcements must never drift apart. Behaviour-identical for the picker (same four keys, same casing fix for `whatsApp`). |
| L2-D9 | **`MissedCallDialRoute { action, channel: CallApp?, fellBackFrom, hopCandidates }`**; the two numberless actions (`openPhoneApp`, `unusableNumber`) return before the chain and carry `channel: nil`, `fellBackFrom: []`, `hopCandidates: []`. Param-name clarification: L1 C2's `messengerHandleAvailable:` shorthand is the shipped `messengerHandle: String?` input (availability derived exactly as shipped at `:8435`: `messengerHandle?.isEmpty == false`). | The pure seam stays the single source of both the announcement's provenance and the hop input, so `dialBackMissedCall` re-derives no routing fact and `MissedCallDialBackTests` can assert the whole decision. |
| L2-D10 | **`RowChannelState` gains BOTH `fellBackFrom` and `hopCandidates`**, resolved from the same snapshot at `rowChannelState` time. | The state is the per-outcome snapshot; the circle, the announcement and the hop must agree with each other even if the settings change between outcome creation and the tap. |
| L2-D11 | **`hasUsableMessengerHandle(_:)`** — one private coordinator predicate (`!CallLinks.messengerHandle(raw ?? "").isEmpty`) used by the seams' feasibility inputs and the hop's filter. The two shipped inline gates (`:7620-7623`, `:7665-7669`) are left textually unchanged; they call the same `CallLinks.messengerHandle` normalization, so they cannot disagree with the predicate. | The shipped comment "the same normalization the opener uses decides 'usable', so the two checks can't disagree" is the precedent; minimal diff on the safety-relevant override gate (Constraint 6). |
| L2-D12 | **Log-gate delta: one `FEATURE_ROOTS` entry** (`Services/Calls`, the new file's root, with a comment in the shipped pattern) — the file must stay inside the gate's perimeter; it writes no console and builds no event field. No `LogSanitiser` allow-list change (no new metadata keys anywhere: `metadata: [:]` stays). One new classification event for hops on the existing bus (§24), plus the family tap outcome-string extension L1 names. | `check-release-log-safety.py` `FEATURE_ROOTS` `:141+`; `build.sh:431` must stay exit 0 (NFR-CDP-003/010). L1's log-safety section explicitly sanctions hop-classification tokens ("e.g. `phone:hop`, `faceTime:launchFailed`"). |

---

## Components

### 5. Component map

C1–C7 are design units, not new modules: five are existing files, one is new, one is a resource. (L1 §Components, verbatim mapping.)

| ID | Name | File | Status |
|---|---|---|---|
| C1 | `CallChannelChain` (+ `CallChannelVocabulary`) | `ios/ElderlyAssistant/Services/` + `Calls/CallChannelChain.swift` | NEW |
| C2 | Resolution seams (`resolvedCallChannel`, `resolvedMissedCallChannel`, `missedCallDialAction`, `MissedCallDialRoute`, `whatsAppInstalledNow`, `hasUsableMessengerHandle`) | `AppCoordinator.swift:2099`, `:8382`, `:8423`, `:7312` | extended |
| C3 | Voice path (`MethodResolver` global default + `requestCallConfirmation` + `PendingCallAction` + `confirmationPrompt` + `performCallAction` hop) | `MethodResolver.swift:47`, `AppCoordinator.swift:7587`, `:7518`, `:7688`, `:7720` | extended |
| C4 | Tap paths (address-book rows; family tiles; missed-call dial-back) | `LeafViews.swift:1564-1620`, `AppCoordinator.swift:7831`, `:8457` | extended |
| C5 | Launch-fail hop (`launchFailHopStep`, `performLaunchFailHop`, `LaunchHop`, `noteLaunchFailHop`) | `AppCoordinator.swift` (new privates) + every open site (`:7720`, `:7944`, `:7971`, `:8053`, `:7831`) | NEW helpers |
| C6 | Settings + persistence (`secondaryCallApp`; two-section picker) | `CallingSettingsView.swift` (whole file), `AppCoordinator.swift:330`/`:2851` | extended |
| C7 | Localization catalog | `ios/ElderlyAssistant/` + `Resources/Localizable.xcstrings` | +5 keys |

### 6. C1 — `CallChannelChain` (+ `CallChannelVocabulary`), new, pure static

**Responsibilities.** The complete, total routing function plus the pure supporting statics: route, attempt order, hop-candidate list, next-candidate step, WhatsApp probe helper, channel↔method mappings, channel labels, and the path-vocabulary value type.

**Full listing (interface-defining; bodies are the contract L1 requires to be deterministic and are pinned by tests).**

```swift
// NEW file: Services/Calls/CallChannelChain.swift
import Foundation

/// The call-launch preference chain (FR-CDP-007/008): preferred →
/// secondary → phone (the GSM hard floor), deduped, each channel
/// attempted at most once, never dead-ends. Pure and static — no
/// coordinator, no platform probes: every environment fact is an
/// argument (Constraint 12).
enum CallChannelChain {

    /// The environment facts the chain consults (FR-CDP-004/005/006) —
    /// both LOCAL-only (NFR-CDP-002).
    struct Feasibility: Equatable {
        /// A Messenger handle is on file for the target — never whether
        /// the Messenger app is installed (Constraint 2).
        let messengerHandleAvailable: Bool
        /// `canOpenURL("whatsapp://")`, injected by the caller (Constraint 3).
        let whatsAppInstalled: Bool
    }

    /// The routing outcome. `fellBackFrom` is the provenance every
    /// announcement composes from (FR-CDP-008): the skipped channels in
    /// attempt order, empty when the preferred channel was routed.
    struct Result: Equatable {
        let channel: CallApp
        let fellBackFrom: [CallApp]
    }

    // MARK: feasibility

    /// FaceTime and phone are always feasible (FR-CDP-006); phone is the
    /// hard floor and the chain's terminal (Constraint 1).
    static func isFeasible(_ channel: CallApp, feasibility: Feasibility) -> Bool {
        switch channel {
        case .faceTime, .phone: return true
        case .messenger: return feasibility.messengerHandleAvailable
        case .whatsApp: return feasibility.whatsAppInstalled
        }
    }

    /// The deduped attempt order (FR-CDP-007): preferred; secondary when
    /// different; `.phone` appended when absent. Always 1–3 DISTINCT
    /// channels; `.phone` is always IN the order — the route never
    /// dead-ends.
    static func attemptOrder(preferred: CallApp, secondary: CallApp) -> [CallApp] {
        var order: [CallApp] = [preferred]
        if secondary != preferred { order.append(secondary) }
        if !order.contains(.phone) { order.append(.phone) }
        return order
    }

    // MARK: routing

    /// The chain (frozen §3 shape, implemented verbatim). Never
    /// dead-ends: `.phone` is always IN the attempt order, and `.phone`
    /// is always feasible — the loop always returns from inside. The
    /// trailing return keeps the function total without a trap.
    static func route(preferred: CallApp,
                      secondary: CallApp,
                      feasibility: Feasibility) -> Result {
        var skipped: [CallApp] = []
        for candidate in attemptOrder(preferred: preferred, secondary: secondary) {
            if isFeasible(candidate, feasibility: feasibility) {
                return Result(channel: candidate, fellBackFrom: skipped)
            }
            skipped.append(candidate)
        }
        return Result(channel: .phone, fellBackFrom: skipped)   // unreachable
    }

    // MARK: launch-fail candidates (FR-CDP-015; L2-D1/D2)

    /// The hop candidates for a routed channel: the attempt order's
    /// suffix after `routed`, re-applied through the surface vocabulary
    /// (L2-D1). Vocabulary-illegal channels are dropped; when the
    /// filtered list empties, the vocabulary terminal is appended unless
    /// it is the routed channel itself. A vocabulary-SUBSTITUTED routed
    /// channel (not in the attempt order) has NO candidates: the
    /// substitution is the surface's floor, already routed.
    static func hopCandidates(preferred: CallApp,
                              secondary: CallApp,
                              routed: CallApp,
                              vocabulary: CallChannelVocabulary = .anyChannel) -> [CallApp] {
        let order = attemptOrder(preferred: preferred, secondary: secondary)
        var remaining = order.firstIndex(of: routed).map { Array(order[($0 + 1)...]) } ?? []
        remaining = remaining.filter { vocabulary.permits($0) }
        if remaining.isEmpty, vocabulary.terminal != routed {
            remaining = [vocabulary.terminal]
        }
        return remaining
    }

    /// The next attempt after a failed open: the first remaining
    /// candidate that can be attempted at all. Only Messenger is dropped
    /// without a handle on file (data-authoritative — the open cannot
    /// work); WhatsApp is attempted even when the earlier probe said
    /// absent (best-effort — the stale-probe residual is exactly what
    /// this hop covers; the open then lands on the shipped
    /// `needsNativeCompose` / `copiedNumber` recoveries, RES-10).
    /// `nil` is exhaustion: a defined state — the caller's shipped
    /// failure line already spoke, and nothing more is said.
    static func nextLaunchFailCandidate(after failed: CallApp,
                                        attemptOrder: [CallApp],
                                        messengerHandleAvailable: Bool) -> CallApp? {
        attemptOrder.first { candidate in
            candidate != failed
                && (candidate != .messenger || messengerHandleAvailable)
        }
    }

    // MARK: WhatsApp probe (FR-CDP-005)

    /// The probe URL — a compile-time literal, valid by construction
    /// (same form and rationale as the shipped constant at
    /// `AppCoordinator.swift:7270`).
    static let whatsAppProbeURL = URL(string: "whatsapp://")!

    /// The injected probe (Constraint 3): `canOpenURL` arrives as a
    /// closure so tests stub it. Any `false` (including a platform
    /// refusal) means "not installed", immediately — no caching, no
    /// polling, no timeout (NFR-CDP-004); the launch-fail hop covers the
    /// staleness residual (frozen Risks).
    static func whatsAppInstalled(canOpen: (URL) -> Bool) -> Bool {
        canOpen(whatsAppProbeURL)
    }

    // MARK: channel ↔ method (frozen §5 mapping; FR-CDP-012)

    /// The `CallMethod` a channel executes as, by call type. WhatsApp
    /// has one chat-shaped method for both call types (the surface has
    /// no call-type split).
    static func method(for channel: CallApp, isVideo: Bool) -> CallMethod {
        switch channel {
        case .phone: return .phone
        case .faceTime: return isVideo ? .facetimeVideo : .facetimeAudio
        case .messenger: return isVideo ? .messengerVideo : .messengerAudio
        case .whatsApp: return .whatsappChat
        }
    }

    /// The inverse mapping (`requestCallConfirmation` step 3, and the
    /// routed-channel label). Audio and video variants map to the same
    /// channel — the call type is not recoverable from a method alone,
    /// which is why callers keep their own `isVideo`.
    static func channel(for method: CallMethod) -> CallApp {
        switch method {
        case .phone: return .phone
        case .facetimeAudio, .facetimeVideo: return .faceTime
        case .messengerAudio, .messengerVideo: return .messenger
        case .whatsappChat: return .whatsApp
        }
    }

    // MARK: labels (single vocabulary; L2-D8)

    /// The catalog key for a channel — the shipped `app.name.*` keys
    /// verified at `CallingSettingsView.swift:70-77`.
    static func nameKey(for channel: CallApp) -> String {
        switch channel {
        case .faceTime: return "app.name.facetime"
        case .phone: return "app.name.phone"
        case .messenger: return "app.name.messenger"
        case .whatsApp: return "app.name.whatsapp"
        }
    }

    /// The localized channel label — used by the confirmation disclosure
    /// and both announcements; the picker delegates here too (L2-D8).
    static func label(_ channel: CallApp, locale: Locale) -> String {
        L10n.str(nameKey(for: channel), locale: locale)
    }
}

/// The call surfaces' channel vocabulary (ADR-CDP-04) — applied at the
/// AppCoordinator seam only; the frozen `route` is untouched. Reuses the
/// shipped `CallApp.supportsAudio` / `supportsVideo` gates
/// (`CallLinks.swift:80-83`), so the vocabulary IS the shipped button
/// semantics, not a second table.
enum CallChannelVocabulary: Equatable {
    /// All four channels; the GSM floor (address-book rows, voice path).
    case anyChannel
    /// FaceTime excluded — audio buttons and missed-call dial-back.
    case audio
    /// The GSM dialer excluded — video buttons.
    case video

    func permits(_ app: CallApp) -> Bool {
        switch self {
        case .anyChannel: return true
        case .audio: return app.supportsAudio
        case .video: return app.supportsVideo
        }
    }

    /// The always-feasible channel of this vocabulary — where the seam
    /// substitutes a routed channel the surface may not open.
    var terminal: CallApp {
        switch self {
        case .anyChannel, .audio: return .phone
        case .video: return .faceTime
        }
    }

    /// Step 1 normalization of the preferred input (ADR-CDP-04). The
    /// substitution is SILENT (no `fellBackFrom` entry): it is the
    /// shipped button gate, not a feasibility skip — today's
    /// `guard resolved.supportsAudio else { return .phone }` also
    /// returned without a word.
    func normalized(_ app: CallApp) -> CallApp {
        permits(app) ? app : terminal
    }
}
```

**Attempt-order invariant and its test (M-2).** `.phone` is always IN the attempt order (containment) — the containment form is the binding wording, because a last-element property would be literally false when `preferred == .phone` (the order is then `[.phone, secondary]`). The order is never reordered to satisfy the superseded wording: attempting the secondary ahead of the preferred channel would deviate from FR-CDP-007. The planned order test is `testOrderContainsPhonePreferredFirst` (V-6; executed in T-145) and asserts containment of `.phone`, `isFeasible(routed)` and preferred-first — NEVER last-element.

**Error paths (C1).** None by construction: every function is total over enum/struct inputs; `route` has no failure case and no input can produce an empty `fellBackFrom` with a non-attemptable `channel` (the floor is unconditional); `nextLaunchFailCandidate` returns `nil` exactly at exhaustion (a defined state); `method(for:isVideo:)`/`channel(for:)` are total on the documented pairs.

**Concurrency (C1).** Value types with no mutable state — callable from any isolation domain; all production call sites are already main-actor, so no new hop or lock is introduced.

**Timeouts / limits (C1).** None added: `route` is O(1) with at most three comparisons; `attemptOrder` ≤ 3 elements; `hopCandidates` O(3); no probe, no clock, no I/O.

### 7. C2 — Resolution seams (`AppCoordinator`)

**Responsibilities.** Assemble inputs (explicit pick, `defaultCallApp`, `secondaryCallApp`, handle availability, WhatsApp probe), apply the path vocabulary, run C1, expose the `Result`; own the pure statics the view layer and tests call; own the single probe property.

```swift
    /// The one WhatsApp probe (ADR-CDP-02): the pure static over the
    /// shipped main-thread `canOpenURL` hop (`:7312-7315`). Computed at
    /// call time only — no caching, no polling.
    var whatsAppInstalledNow: Bool {
        CallChannelChain.whatsAppInstalled(canOpen: canOpenURLOnMain)
    }

    /// A usable Messenger handle on file, by the shipped normalization
    /// (L2-D11) — the same predicate the confirmation gates use.
    private func hasUsableMessengerHandle(_ raw: String?) -> Bool {
        !CallLinks.messengerHandle(raw ?? "").isEmpty
    }

    static func resolvedCallChannel(explicit: CallApp?,
                                    defaultApp: CallApp,
                                    secondaryApp: CallApp,
                                    messengerHandleAvailable: Bool,
                                    whatsAppInstalled: Bool,
                                    vocabulary: CallChannelVocabulary = .anyChannel)
                                    -> CallChannelChain.Result {
        resolveChannel(preferred: explicit ?? defaultApp,
                       secondaryApp: secondaryApp,
                       messengerHandleAvailable: messengerHandleAvailable,
                       whatsAppInstalled: whatsAppInstalled,
                       vocabulary: vocabulary)
    }

    static func resolvedMissedCallChannel(familyContact: FamilyContact?,
                                          defaultApp: CallApp,
                                          secondaryApp: CallApp,
                                          messengerHandleAvailable: Bool,
                                          whatsAppInstalled: Bool)
                                          -> CallChannelChain.Result {
        // ADR-CDP-03 step 4: the shipped `supportsAudio` guard's own
        // semantics ARE this seam's vocabulary — a FaceTime preference
        // on an audio path still routes to `.phone`, exactly as today.
        resolveChannel(preferred: familyContact?.resolvedAudioApp ?? defaultApp,
                       secondaryApp: secondaryApp,
                       messengerHandleAvailable: messengerHandleAvailable,
                       whatsAppInstalled: whatsAppInstalled,
                       vocabulary: .audio)
    }

    /// The shared seam algorithm (ADR-CDP-03 steps 1–3), one
    /// implementation for both public seams.
    private static func resolveChannel(preferred: CallApp,
                                       secondaryApp: CallApp,
                                       messengerHandleAvailable: Bool,
                                       whatsAppInstalled: Bool,
                                       vocabulary: CallChannelVocabulary)
                                       -> CallChannelChain.Result {
        let routed = CallChannelChain.route(
            preferred: vocabulary.normalized(preferred),
            secondary: secondaryApp,
            feasibility: CallChannelChain.Feasibility(
                messengerHandleAvailable: messengerHandleAvailable,
                whatsAppInstalled: whatsAppInstalled))
        guard !vocabulary.permits(routed.channel) else { return routed }
        // ADR-CDP-04 step 3: substitute the vocabulary terminal;
        // `fellBackFrom` is unchanged by the substitution (the
        // substitution never fabricates provenance).
        return CallChannelChain.Result(channel: vocabulary.terminal,
                                       fellBackFrom: routed.fellBackFrom)
    }
```

**Call-site change note.** `resolvedCallChannel` grows two parameters, which is a compile-time-detected change at every current call site — exactly the two production sites plus the tests: `LeafViews.swift:1612-1615` (row state) and `AppCoordinator.swift:8387` (`resolvedMissedCallChannel`, which now calls the shared helper instead), and `CallChannelResolutionTests`' `assertResolved` helper (extended to read `.channel` and the provenance; L1 C1 "Consequences").

**`MissedCallDialRoute` and the pure dial-back decision (L2-D9).**

```swift
    /// The dial-back decision plus its routing provenance (FR-CDP-011):
    /// the action to dispatch and everything the announcement and the
    /// launch-fail hop need, so `dialBackMissedCall` never re-derives a
    /// routing fact (single source — the pure seam).
    struct MissedCallDialRoute: Equatable {
        let action: MissedCallDialAction
        /// The routed channel — nil for the two numberless actions,
        /// which return before the chain (nothing to route).
        let channel: CallApp?
        /// Skipped channels in attempt order (empty = no fallback).
        let fellBackFrom: [CallApp]
        /// The launch-fail candidates for `channel` ([] when nil).
        let hopCandidates: [CallApp]
    }

    static func missedCallDialAction(phone: String,
                                     familyContact: FamilyContact?,
                                     defaultApp: CallApp,
                                     secondaryApp: CallApp,
                                     messengerHandle: String?,
                                     whatsAppInstalled: Bool,
                                     name: String) -> MissedCallDialRoute {
        guard !phone.isEmpty else {
            return MissedCallDialRoute(action: .openPhoneApp, channel: nil,
                                       fellBackFrom: [], hopCandidates: [])
        }
        guard !ContactNumberKey.normalized(phone).isEmpty else {
            return MissedCallDialRoute(action: .unusableNumber(name: name), channel: nil,
                                       fellBackFrom: [], hopCandidates: [])
        }
        let preferred = familyContact?.resolvedAudioApp ?? defaultApp
        let route = resolvedMissedCallChannel(
            familyContact: familyContact, defaultApp: defaultApp,
            secondaryApp: secondaryApp,
            messengerHandleAvailable: messengerHandle?.isEmpty == false,
            whatsAppInstalled: whatsAppInstalled)
        let action: MissedCallDialAction
        switch route.channel {
        case .phone: action = .call(name: name, phone: phone)
        case .faceTime: action = .faceTime(name: name, phone: phone)
        case .whatsApp: action = .whatsApp(name: name, phone: phone)
        case .messenger: action = .messenger(name: name, phone: phone,
                                             handle: messengerHandle ?? "")
        }
        return MissedCallDialRoute(
            action: action, channel: route.channel, fellBackFrom: route.fellBackFrom,
            hopCandidates: CallChannelChain.hopCandidates(
                preferred: preferred, secondary: secondaryApp,
                routed: route.channel, vocabulary: .audio))
    }
```

**Error paths (C2).** All total; `explicit: nil` is the default-input case; `whatsAppInstalled: false` biases to the floor — never throws. The two shipped guards of `missedCallDialAction` are preserved verbatim (`:8428-8431`). Emergency resolution is deliberately NOT part of these seams (`emergencyContacts` `:6463` untouched; non-goal).

**Concurrency (C2).** Pure statics, except `whatsAppInstalledNow` which runs on the main actor through the existing main-thread hop. No mutation of coordinator state inside the seams: resolution is a pure function of the settings snapshot, the contact data and the probe result. Two readers can call the seams concurrently in principle (they are pure) — in production all callers are main-actor views/coordinator methods.

**Timeouts (C2).** No timeout exists or is added; probe non-answer = immediate `false`.

### 8. C3 — Voice path (`MethodResolver` + confirmation + execution)

**MethodResolver (ADR-CDP-06).**

```swift
    init(preferenceStore: CallMethodPreferenceStore,
         historyStore: ConfirmedMethodHistoryStore,
         globalDefault: @escaping (_ isVideo: Bool) -> CallMethod = { _ in .phone }) {
        self.preferenceStore = preferenceStore
        self.historyStore = historyStore
        self.globalDefault = globalDefault
    }
```

`AppCoordinator.methodResolver` (`:1925-1926`) constructs it with the settings primary mapped by call type:

```swift
    private lazy var methodResolver = MethodResolver(
        preferenceStore: callMethodPreferences,
        historyStore: confirmedMethodHistory,
        globalDefault: { [weak self] isVideo in
            CallChannelChain.method(for: self?.defaultCallApp ?? .phone, isVideo: isVideo)
        })
```

Steps 1–3 of `resolve` are byte-for-byte unchanged; step 4 (`:74-78`) calls `globalDefault(isVideo)` instead of the hardcoded `.phone`, keeping `source: .globalDefault`. The defaulted closure keeps every other construction (tests) compiling and behaviour-identical, and the feasibility fallback deliberately does NOT live here (ADR-CDP-06 "Consequences").

**`PendingCallAction` additions (L2-D3, L2-D7).**

```swift
    struct PendingCallAction {
        let contact: FamilyContact
        let method: CallMethod
        let unsupportedRequestedApp: String?
        let sourceTranscript: String?
        let sourceCommand: InterpretedCommand?
        /// [INTENTLOG-CAPTURE] When the confirmation question was asked —
        /// the flywheel's latency start. `var` (L2-D3) so the hop's copy
        /// can preserve the ORIGINAL question's clock.
        var requestedAt: Date = Date()
        /// Channels the chain attempted and skipped, in attempt order —
        /// empty when nothing fell back (FR-CDP-008). Drives the prompt
        /// disclosure (FR-CDP-013); never mutated after construction.
        var fellBackFrom: [CallApp] = []
        /// The launch-fail candidates: the attempt order's
        /// vocabulary-filtered suffix after the routed channel
        /// (FR-CDP-015, L2-D1). Empty for touch-shaped constructions and
        /// after an override (the amended action deliberately drops
        /// provenance so a stale disclosure is never re-spoken).
        var hopCandidates: [CallApp] = []

        var capture: IntentLogStore.Capture { /* unchanged (:7543-7549) */ }

        /// The hop's re-entry copy (FR-CDP-015; L2-D3/D7): routed method
        /// and remaining candidates replaced; the flywheel pair carries
        /// over; `fellBackFrom` deliberately resets to `[]` (not passed
        /// below) so the hop never re-speaks the disclosure while the
        /// training context survives.
        func replacing(method: CallMethod, hopCandidates: [CallApp]) -> PendingCallAction {
            PendingCallAction(contact: contact,
                              method: method,
                              unsupportedRequestedApp: nil,
                              sourceTranscript: sourceTranscript,
                              sourceCommand: sourceCommand,
                              requestedAt: requestedAt,
                              hopCandidates: hopCandidates)
        }
    }
```

**`requestCallConfirmation` — the new order (ADR-CDP-05).** Steps 1–2 (contact resolution incl. the near-miss path, `methodResolver.resolve`) are unchanged; step 3 inserts the chain and step 4 builds the action with the ROUTED method; the shipped Messenger-no-handle early return (`:7620-7623`) is removed here (it lives on in the override gate and the leaf stale-state guard); `repetitionGuard`, `openConfirmationWindow()` and the near-miss prefix are untouched.

```swift
        let resolved = methodResolver.resolve(contactId: contact.id,
                                              requestedApp: requestedApp,
                                              callType: callType)
        // ADR-CDP-05 step 3: the chain runs BEFORE the action is pended —
        // the feasibility fallback replaces the shipped Messenger-no-
        // handle refusal, so the elder is never asked to yes/no an action
        // that can only fail.
        let intentIsVideo = resolved.method == .facetimeVideo
            || resolved.method == .messengerVideo
        let preferred = CallChannelChain.channel(for: resolved.method)
        let route = Self.resolvedCallChannel(
            explicit: preferred,
            defaultApp: defaultCallApp,
            secondaryApp: secondaryCallApp,
            messengerHandleAvailable: hasUsableMessengerHandle(contact.messengerHandle),
            whatsAppInstalled: whatsAppInstalledNow)
        let action = PendingCallAction(contact: contact,
                                       method: CallChannelChain.method(for: route.channel,
                                                                       isVideo: intentIsVideo),
                                       unsupportedRequestedApp: resolved.unsupportedRequestedApp,
                                       sourceTranscript: sourceTranscript,
                                       sourceCommand: sourceCommand,
                                       fellBackFrom: route.fellBackFrom,
                                       hopCandidates: CallChannelChain.hopCandidates(
                                           preferred: preferred,
                                           secondary: secondaryCallApp,
                                           routed: route.channel))
```

**`confirmationPrompt` (L2-D8).** The disclosure clause is appended after the repeat/unsupported notices and before the method sentence, so the utterance order is `[near-miss prefix][repeat notice][unsupported-app notice][fallback disclosure][method sentence][confirm question]`:

```swift
        if let skipped = action.fellBackFrom.first {
            parts.append(L10n.fmt("router.call.fallbackDisclosure", locale: locale,
                                  CallChannelChain.label(skipped, locale: locale),
                                  action.contact.name,
                                  CallChannelChain.label(
                                      CallChannelChain.channel(for: action.method),
                                      locale: locale)))
        }
```

The routed-channel label derives from the ROUTED method (`action.method` is already the routed method), so the clause can never name a channel other than the one that will open. With an empty `fellBackFrom` the function produces exactly the previous wording (FR-CDP-013 scenario 3, byte-identical — asserted).

**Override path (`:7656-7686`) — unchanged.** The no-handle gate (`:7665-7669`) keeps speaking `router.call.messengerNoHandle` and keeps the original action pending; the amended action is constructed without the new fields, so a stale disclosure is never re-spoken and the hop candidates die with the amendment (the amendment is the user's own explicit choice — no hop). The original action's capture is appended as `.corrected` exactly as shipped.

**`performCallAction` — failures hop; the phone branch checks its Bool (ADR-CDP-08).**

```swift
        case .phone:
            guard callLinks.openPhone(action.contact.phone) else {
                // RES-8/RES-10: the floor is terminal but its open can
                // still fail (an undialable number) — the shipped honest
                // line, no hop exists from the floor.
                announceNoUsableNumber(contact: action.contact, locale: locale)
                return
            }
            /* … shipped success path unchanged (:7725-7732) … */
        case .facetimeVideo, .facetimeAudio:
            /* … shipped switch unchanged … */
            case .unavailable, .invalidHandle:
                /* … shipped lines unchanged (:7751-7753) … */
                hopFromCallAction(after: .faceTime, action: action,
                                  isVideo: isVideo, locale: locale)
        case .messengerAudio, .messengerVideo:
            /* … shipped switch unchanged … */
            case .invalidHandle:
                /* … shipped lines unchanged (:7798-7800) … */
                hopFromCallAction(after: .messenger, action: action,
                                  isVideo: action.method == .messengerVideo, locale: locale)
```

`hopFromCallAction` is the voice path's attempt mechanism over the shared decision step (L2-D5):

```swift
    /// FR-CDP-015 for the voice path (ADR-08): decide + announce through
    /// `launchFailHopStep`, then re-enter `performCallAction` with the
    /// copied action — the same executor a fresh confirmation reaches,
    /// and the routed (hopped) method is what the success branch records
    /// and teaches (L2-D7).
    private func hopFromCallAction(after failed: CallApp, action: PendingCallAction,
                                   isVideo: Bool, locale: Locale) {
        guard let step = launchFailHopStep(after: failed,
                                           candidates: action.hopCandidates,
                                           handle: action.contact.messengerHandle,
                                           name: action.contact.name,
                                           locale: locale) else { return }
        performCallAction(action.replacing(
            method: CallChannelChain.method(for: step.next, isVideo: isVideo),
            hopCandidates: step.remaining))
    }
```

The `.whatsappChat` branch keeps the shipped opener and gains the M-1 disposition (i): `openWhatsAppChat` is `@discardableResult func openWhatsAppChat(_ rawPhone: String) -> Bool`, returning `false` only when `whatsAppChatURL` is nil because no dialable digits remain (`CallLinks.swift:283-287`, `:366-370`); on a `false` result the branch speaks the shipped `call.announce.noPhoneNumber` line and records no success, no learning and no activity — no hop (RES-10). It has no absent-app path and no recovery chain of its own: `needsNativeCompose` / `copiedNumber` belong to `openWhatsAppCallChat` only (`CallLinks.swift:457-470`).

**Error paths (C3).** `resolve` keeps its no-throw contract; `requestCallConfirmation` keeps its `String?` return contract (the nil no-contact path unchanged); every failure branch keeps its shipped line and then optionally hops. Unsupported-requested-app and fallback disclosures compose (both, neither replaces — FR-CDP-014 scenario 3).

**Concurrency / isolation (C3).** Main-actor coordinator code. The single `pendingCallAction` slot is the concurrency boundary; the chain computation completes before the slot is written, and `handleConfirmationResponse` sets the slot to `nil` before `performCallAction` runs (`:10611-10615`) — so the hop's local copies never race another answer, and no parallel pending action can exist.

**Timeouts (C3).** The 45 s window is reused, untouched, and not duplicated; the hop runs inline, synchronous, with no timer (the candidate list bounds it at ≤ 2 re-entries).

### 9. C4 — Tap paths

**9.1 Address-book rows (`LeafViews`).** `rowChannelState` becomes the 5-argument call (six-argument signature, defaulted vocabulary — L1 integration #19) and the row state carries both provenance fields (L2-D10):

```swift
    private func rowChannelState(for result: UnifiedContactSearch.Result) -> RowChannelState {
        _ = channelStateVersion
        let storeKey = ContactNumberKey.normalized(result.phone)
        let storedPreference = storeKey.isEmpty
            ? nil
            : coordinator.storedChannelPreference(forNormalizedPhone: storeKey)
        let hasHandle = resolvedMessengerHandle(for: result) != nil
        let preferred = storedPreference ?? coordinator.defaultCallApp
        let route = AppCoordinator.resolvedCallChannel(
            explicit: storedPreference,
            defaultApp: coordinator.defaultCallApp,
            secondaryApp: coordinator.secondaryCallApp,
            messengerHandleAvailable: hasHandle,
            whatsAppInstalled: coordinator.whatsAppInstalledNow)
        return RowChannelState(storedPreference: storedPreference,
                               resolvedChannel: route.channel,
                               hasHandle: hasHandle,
                               storeKey: storeKey,
                               fellBackFrom: route.fellBackFrom,
                               hopCandidates: CallChannelChain.hopCandidates(
                                   preferred: preferred,
                                   secondary: coordinator.secondaryCallApp,
                                   routed: route.channel))
    }
```

`RowChannelState` (`:2249-2266`) gains `var fellBackFrom: [CallApp] = []` and `var hopCandidates: [CallApp] = []` (L2-D3; the single construction site above passes both). `dialChannel` announces at resolution (ADR-CDP-07) and threads the hop into the openers; the switch's branches, including the stale-state `messengerNoHandle` guard (`:1573-1580`), are otherwise unchanged:

```swift
    private func dialChannel(_ result: UnifiedContactSearch.Result) {
        let state = rowChannelState(for: result)
        let locale = coordinator.activeLocale
        if let skipped = state.fellBackFrom.first {
            // ADR-CDP-07: at resolution, BEFORE the open — a successful
            // open may background the app before post-open speech could
            // be heard. Nothing is spoken when nothing fell back.
            coordinator.speak(text: L10n.fmt("call.announce.fallbackRouted",
                                             locale: locale,
                                             CallChannelChain.label(skipped, locale: locale),
                                             result.name,
                                             CallChannelChain.label(state.resolvedChannel,
                                                                    locale: locale)))
        }
        let hop = AppCoordinator.LaunchHop(candidates: state.hopCandidates,
                                           handle: resolvedMessengerHandle(for: result))
        switch state.resolvedChannel {
        case .phone:
            dial(result)                                   // floor: no hop
        case .faceTime:
            coordinator.performFaceTimeCall(name: result.name, phone: result.phone,
                                            video: false, hop: hop)
        case .whatsApp:
            whatsApp(result, hop: hop)
        case .messenger:
            guard let handle = resolvedMessengerHandle(for: result) else {
                /* … shipped stale-state line unchanged (:1577-1580) … */
                return
            }
            coordinator.performSystemContactMessenger(name: result.name, handle: handle,
                                                      hop: hop)
        }
    }
```

`whatsApp(_:hop:)` (formerly `:1546-1548`) forwards the hop into `performSystemContactWhatsApp(name:phone:hop:)`; `dial(_:)` (`:1536-1542`) is untouched (GSM floor, recency bump). The view-level probe delegates to C1 (`whatsAppInstalled` `:1171-1174` becomes `CallChannelChain.whatsAppInstalled(canOpen: { UIApplication.shared.canOpenURL($0) })`) — one probe implementation, still main-thread, no coordinator dependency added to the view.

**9.2 Family tiles (`performContactCall`).** Chain at the top with the button's vocabulary, announcement after the existing observability emit, then the shipped switch on the ROUTED channel; each failure branch appends the hop; the phone branch keeps its shipped guard (the floor never hops):

```swift
    func performContactCall(_ contact: FamilyContact, kind: ContactCallKind) {
        let locale = activeLocale
        let preferred = kind == .video ? contact.resolvedVideoApp : contact.resolvedAudioApp
        let vocabulary: CallChannelVocabulary = kind == .video ? .video : .audio
        let route = Self.resolvedCallChannel(
            explicit: preferred,
            defaultApp: defaultCallApp,
            secondaryApp: secondaryCallApp,
            messengerHandleAvailable: hasUsableMessengerHandle(contact.messengerHandle),
            whatsAppInstalled: whatsAppInstalledNow,
            vocabulary: vocabulary)
        observabilityBus.emit(ObservabilityEvent(
            component: "contact_call_buttons",
            eventType: "tap",
            durationMs: nil,
            outcome: "\(kind == .video ? "video" : "audio"):\(route.channel.rawValue):"
                + (route.fellBackFrom.isEmpty ? "direct" : "fellBack"),
            errorCode: nil,
            metadata: [:]  // no contact identifiers — C9 policy
        ))
        if let skipped = route.fellBackFrom.first {
            speak(text: L10n.fmt("call.announce.fallbackRouted", locale: locale,
                                 CallChannelChain.label(skipped, locale: locale),
                                 contact.name,
                                 CallChannelChain.label(route.channel, locale: locale)))
        }
        let candidates = CallChannelChain.hopCandidates(preferred: preferred,
                                                        secondary: secondaryCallApp,
                                                        routed: route.channel,
                                                        vocabulary: vocabulary)
        switch route.channel {
        case .faceTime:
            /* … shipped switch body unchanged (:7846-7858) … */
            case .unavailable, .invalidHandle:
                /* … shipped line unchanged … */
                performLaunchFailHop(after: .faceTime, candidates: candidates,
                                     name: contact.name, phone: contact.phone,
                                     handle: contact.messengerHandle,
                                     isVideo: kind == .video, locale: locale)
        case .phone:
            /* … shipped guard + success path unchanged (:7860-7869) … */
        case .messenger:
            /* … shipped switch body unchanged (:7871-7888) … */
            case .invalidHandle:
                /* … shipped line unchanged … */
                performLaunchFailHop(after: .messenger, candidates: candidates,
                                     name: contact.name, phone: contact.phone,
                                     handle: contact.messengerHandle,
                                     isVideo: kind == .video, locale: locale)
        case .whatsApp:
            /* … shipped switch body unchanged (:7890-7908) … — the
               shipped `invalidPhone` arm is a data failure and never
               hops (RES-10); `needsNativeCompose`/`copiedNumber` are
               recoveries, not failures. */
        }
    }
```

**9.3 Missed-call dial-back (`dialBackMissedCall`).** Announce at resolution, then dispatch with the route's hop input:

```swift
    func dialBackMissedCall(_ entry: AppActivityEntry) {
        /* … identity + family lookup unchanged (:8458-8461) … */
        let route = Self.missedCallDialAction(
            phone: entry.phone,
            familyContact: family,
            defaultApp: defaultCallApp,
            secondaryApp: secondaryCallApp,
            messengerHandle: family?.messengerHandle,
            whatsAppInstalled: whatsAppInstalledNow,
            name: identity)
        if let skipped = route.fellBackFrom.first, let channel = route.channel {
            speak(text: L10n.fmt("call.announce.fallbackRouted", locale: activeLocale,
                                 CallChannelChain.label(skipped, locale: activeLocale),
                                 identity,
                                 CallChannelChain.label(channel, locale: activeLocale)))
        }
        let hop = LaunchHop(candidates: route.hopCandidates, handle: family?.messengerHandle)
        switch route.action {
        case .openPhoneApp:            PhoneAppOpener.openDialer()
        case .unusableNumber:          /* … shipped line unchanged (:8471-8473) … */
        case .call(let name, let phone):
            performSystemContactCall(name: name, phone: phone)          // floor: no hop
        case .faceTime(let name, let phone):
            performFaceTimeCall(name: name, phone: phone, video: true, hop: hop)
        case .whatsApp(let name, let phone):
            performSystemContactWhatsApp(name: name, phone: phone, hop: hop)
        case .messenger(let name, _, let handle):
            performSystemContactMessenger(name: name, handle: handle, hop: hop)
        }
    }
```

**Error paths (C4).** Every branch keeps its shipped no-silent-failure line; the hop intervenes only between a failure outcome and its already-spoken line. A tap never dead-ends: the chain's floor is always attemptable, and if the floor's own open fails, the shipped honest line speaks (`router.call.facetimeUnavailable`, `call.announce.noPhoneNumber`, `announceNoUsableNumber`, `router.call.messengerNoHandle`).

**Concurrency (C4).** All view/coordinator code on the main actor; `channelStateVersion` (`:1596`) remains the re-resolution trigger after a chooser pick or a saved handle; the chain runs synchronously inside the tap handler — no async boundary, no interleaving window.

**Timeouts (C4).** None; the probe is synchronous and local. Tap targets and accessibility tokens unchanged.

### 10. C5 — Launch-fail hop

**10.1 The failure classification (RES-10, verified per outcome).**

| Open site | Outcome | Class | Action |
|---|---|---|---|
| `performCallAction` `.phone` | `openPhone == false` | **failed, terminal** | shipped honest line (`announceNoUsableNumber`); NO hop — the floor is the last resort |
| `performCallAction` `.faceTime` | `.unavailable`, `.invalidHandle` | failed | shipped line, then hop |
| `performCallAction` `.messenger*` | `.invalidHandle` | failed | shipped line, then hop |
| `performCallAction` `.whatsappChat` | `openWhatsAppChat` returns `Bool` — `@discardableResult func openWhatsAppChat(_ rawPhone: String) -> Bool`; `false` only when `whatsAppChatURL` is nil because no dialable digits remain (`CallLinks.swift:283-287`, `:366-370`) | **failed, data** (M-1 disposition (i)) | shipped honest line (`call.announce.noPhoneNumber`); NO hop (RES-10) — no success, no learning, no activity |
| `performContactCall` `.faceTime` | `.unavailable`, `.invalidHandle` | failed | shipped line, then hop |
| `performContactCall` `.messenger` | `.invalidHandle` | failed | shipped line, then hop |
| `performContactCall` `.messenger` | `.openedWebChat` | recovery | shipped web-fallback disclosure; no hop |
| `performContactCall` `.phone` | `openPhone == false` | **failed, terminal** | `announceNoUsableNumber`; no hop |
| `performContactCall` `.whatsApp` | `.needsNativeCompose`, `.copiedNumber` | recovery | shipped disclosures; no hop |
| `performContactCall` `.whatsApp` | `.invalidPhone` | failed, data | `announceNoUsableNumber`; no hop — nothing dialable anywhere |
| `performFaceTimeCall` | `.unavailable`, `.invalidHandle` | failed | shipped line, then hop |
| `performSystemContactWhatsApp` | `.invalidPhone` | failed, data | shipped line; no hop (RES-10) |
| `performSystemContactWhatsApp` | `.needsNativeCompose`, `.copiedNumber` | recovery | shipped disclosures; no hop |
| `performSystemContactMessenger` | `.invalidHandle` | failed | shipped line, then hop |
| `performSystemContactMessenger` | `.fellBackToWeb` | recovery | shipped disclosure; no hop |
| `performSystemContactCall` | `PhoneDialer.url == nil` | **failed, terminal** | shipped line; no hop (floor or last hop target) |

**M-1 disposition (i) — the `.whatsappChat` false case (recorded; implemented in T-150).** A `false` result is a data failure — nothing dialable anywhere — and is handled exactly like the `.phone` floor's `openPhone == false`: the voice `.whatsappChat` branch speaks the shipped `call.announce.noPhoneNumber` line and records no success, no learning and no activity. Silence is not an acceptable disposition; the pre-existing silent drop (`AppCoordinator.swift:7755-7765`) is the counterexample this row exists to close. The chat opener's recovery chain is not consulted here: `needsNativeCompose` / `copiedNumber` belong to `openWhatsAppCallChat` only (`CallLinks.swift:457-470`), never to `openWhatsAppChat`.

**10.2 The shared decision step + the tap attempt helper (L2-D5).**

```swift
    /// The launch-fail hop input a per-channel opener may carry
    /// (FR-CDP-015): the remaining candidates at THIS attempt, plus the
    /// contact's resolved Messenger handle (the feasibility filter).
    /// `nil` means "no hop" — the shipped behaviour, byte-identical.
    struct LaunchHop: Equatable {
        let candidates: [CallApp]
        let handle: String?
    }

    /// The shared hop decision + announcement (the ONLY
    /// `call.announce.launchFailedFallback` site, FR-CDP-015). Returns
    /// the next channel and the remaining candidates (the input list
    /// minus everything up to and including `next`), or nil at
    /// exhaustion — the caller's shipped failure line already spoke.
    private func launchFailHopStep(after failed: CallApp, candidates: [CallApp],
                                   handle: String?, name: String,
                                   locale: Locale) -> (next: CallApp, remaining: [CallApp])? {
        guard let next = CallChannelChain.nextLaunchFailCandidate(
                after: failed,
                attemptOrder: candidates,
                messengerHandleAvailable: hasUsableMessengerHandle(handle)) else {
            return nil
        }
        noteLaunchFailHop(after: failed, next: next)
        speak(text: L10n.fmt("call.announce.launchFailedFallback", locale: locale,
                             CallChannelChain.label(failed, locale: locale),
                             name,
                             CallChannelChain.label(next, locale: locale)))
        let remaining = Array(candidates.drop(while: { $0 != next }).dropFirst())
        return (next, remaining)
    }

    /// The TAP-path hop (FR-CDP-015, ADR-08; L1 C5 signature, verbatim):
    /// on a failed open, speak the hop announcement and attempt the next
    /// channel through the shipped per-channel opener for its type.
    /// Returns true when a hop was attempted. The candidate list is
    /// consumed one item per hop and the recursion is synchronous, so at
    /// most one hop is in flight per tap and no channel is attempted
    /// twice.
    @discardableResult
    private func performLaunchFailHop(after failed: CallApp,
                                      candidates: [CallApp],
                                      name: String, phone: String, handle: String?,
                                      isVideo: Bool, locale: Locale) -> Bool {
        guard let step = launchFailHopStep(after: failed, candidates: candidates,
                                           handle: handle, name: name,
                                           locale: locale) else { return false }
        switch step.next {
        case .phone:
            performSystemContactCall(name: name, phone: phone)   // floor: its own honest line
        case .faceTime:
            performFaceTimeCall(name: name, phone: phone, video: isVideo)
        case .whatsApp:
            performSystemContactWhatsApp(name: name, phone: phone,
                                         hop: LaunchHop(candidates: step.remaining, handle: handle))
        case .messenger:
            guard let handle, !handle.isEmpty else { return true }  // filtered above; defensive
            performSystemContactMessenger(name: name, handle: handle,
                                          hop: LaunchHop(candidates: step.remaining, handle: handle))
        }
        return true
    }

    /// The hop's classification event (L2-D12): category strings only, no
    /// names, no numbers, `metadata: [:]`. The failed attempt's own
    /// event (where the context emits one) already recorded the attempt.
    private func noteLaunchFailHop(after failed: CallApp, next: CallApp) {
        observabilityBus.emit(ObservabilityEvent(
            component: "call_launch_fallback",
            eventType: "hop",
            durationMs: nil,
            outcome: "\(failed.rawValue):\(next.rawValue)",
            errorCode: nil,
            metadata: [:]
        ))
    }
```

The three search-shaped openers gain `hop: LaunchHop? = nil` and call `performLaunchFailHop` in exactly the failure branches of §10.1, passing `hop?.candidates ?? []` and `hop?.handle`. The tap contexts pass their hop in (`dialChannel`, `dialBackMissedCall`); the two non-chain callers pass nothing (`nil`), which is today's behaviour with today's lines — the recent-activity re-init in `LeafViews` and `HistoryView` are outside the four chain-routed families by construction, not by accident (L2-D4).

**10.3 Termination proof (the never-loop property).** `launchFailHopStep` selects `next` from `candidates` and returns `remaining = candidates` minus everything up to and including `next`; each re-entry therefore receives a STRICTLY shorter list, and `nextLaunchFailCandidate` excludes the channel that just failed. With `|hopCandidates| ≤ 2` (one secondary + the floor; the substitution case yields 0), the recursion depth is ≤ 2 and every channel appears at most once — pinned by `testHopConsumesCandidatesNeverLoops`.

**10.4 The vocabulary case table (L2-D1; test `testHopCandidatesRespectVocabulary`).**

| Surface | preferred → routed | attempt order | candidates | Why |
|---|---|---|---|---|
| `.anyChannel` (row/voice) | `.messenger` → `.messenger` | `[.messenger, .phone]` | `[.phone]` | raw suffix, all permitted |
| `.anyChannel` | `.faceTime` → `.faceTime` | `[.faceTime, .phone]` | `[.phone]` | secondary skipped when equal; floor |
| `.audio` (family audio/dial-back) | `.messenger` → `.messenger`, secondary `.faceTime` | `[.messenger, .faceTime, .phone]` | `[.phone]` | `.faceTime` filtered (audio never FaceTime) |
| `.video` (family video) | `.messenger` → `.messenger`, secondary `.phone` (default) | `[.messenger, .phone]` | `[.faceTime]` | `.phone` filtered; terminal appended (video never GSM) |
| `.video` | `.whatsApp` → `.whatsApp` | `[.whatsApp, .phone]` | `[.faceTime]` | same rule |
| `.video`, both infeasible | `.messenger` → routed `.phone` → substituted `.faceTime` | `[.messenger, .phone]` | `[]` | the substitution is the floor, already routed (L2-D1) |
| `.audio`, both infeasible | `.messenger` → routed `.faceTime` → substituted `.phone` | `[.messenger, .faceTime, .phone]` | `[]` | same rule |
| `.anyChannel`, preferred `.phone` | `.phone` → `.phone` | `[.phone]` | `[]` | terminal |

**Error paths (C5).** Candidate computation is total; exhaustion speaks nothing beyond the already-spoken failure line; a hop attempt that itself fails recurses into the same step with the shorter list and finally exhausts. Failed opens never record learning and never write history (shipped rule `:7746-7750`, `:7795-7798`); the hop's own failures behave identically.

**Concurrency (C5).** Runs inline on the main actor immediately after the failed open returns; no queue, no detached task, no timer; the candidate list is consumed so no channel is attempted twice.

**Timeouts (C5).** None. "iOS reports failure" is the open call's own return value, never a wait. The candidate count is bounded by the chain (≤ 2 hops).

### 11. C6 — Settings + persistence

**Coordinator property (ADR-CDP-09; L1 integration #1/#2), sibling of `defaultCallApp` `:330-335`:**

```swift
    /// The fallback dialer (frozen §1): the chain's second step,
    /// persisted under its own key with the shipped pattern. Absent or
    /// unknown stored value → `.phone` (GSM) — exactly the frozen
    /// default for existing installs (Constraint 4).
    @Published var secondaryCallApp: CallApp {
        didSet {
            UserDefaults.standard.set(secondaryCallApp.rawValue,
                                      forKey: Self.secondaryCallAppKey)
        }
    }
    private static let secondaryCallAppKey = "secondaryCallApp"
```

Init restore at the `defaultCallApp` site (`:2851-2853`), same shape:

```swift
        self.secondaryCallApp = UserDefaults.standard
            .string(forKey: Self.secondaryCallAppKey)
            .flatMap(CallApp.init(rawValue:)) ?? .phone
```

`secondary == primary` is legal; dedupe happens at routing time in the chain, not at storage. No migration, no version bump, no new store.

**`CallingSettingsView` — two sections, one row pattern (L1 C6).** `channelRow` (`:40-64`) gains a selection binding and a pick closure so the identical row serves both sections; the section titles are the two new keys, set in the shipped caption style:

```swift
            LeafScreen(titleKey: "settings.calling.title") {
                VStack(spacing: 16) {
                    section(titleKey: "settings.calling.primaryTitle") { app in
                        coordinator.defaultCallApp = app
                    }
                    section(titleKey: "settings.calling.secondaryTitle") { app in
                        coordinator.secondaryCallApp = app
                    }
                    /* … shipped `calling.defaultCaption` text unchanged (:32-35) … */
                }
            }

    private func section(titleKey: String, pick: @escaping (CallApp) -> Void) -> some View {
        /* section header Text(titleKey) in the shipped caption style +
           ForEach(Self.channels) of channelRow(app, pick:) — the shipped
           row body (:45-63) verbatim, with `isSelected` computed against
           the section's own property */
    }

    /// Catalog name key for a channel — one vocabulary (L2-D8).
    private static func nameKey(for app: CallApp) -> String {
        CallChannelChain.nameKey(for: app)
    }
```

**Error paths (C6).** None: binding writes are total; a corrupted/absent stored raw value restores to `.phone` (fail-safe GSM default).

**Concurrency (C6).** Main-actor SwiftUI state identical to `defaultCallApp`'s shipped pattern; the two properties are independent (no cross-talk). Accessibility (NFR-CDP-006; V-4): the shipped row pattern (Button, checkmark, ≥44 pt) is kept, and selection is conveyed non-visually — the selected row of BOTH picker sections carries a selected accessibility trait (or a selected accessibility value), so the checkmark is not the only indication of selection; the two section titles carry a heading accessibility trait (a plain `Text` header alone is not a VoiceOver heading, so the trait is added rather than claimed); no token sizes change.

**Timeouts (C6).** None.

### 12. C7 — Localization catalog (+5 keys, ADR-CDP-10)

| Key | Surface | Parameters (binding contract) | Composed at |
|---|---|---|---|
| `settings.calling.primaryTitle` | Settings section title | none | `CallingSettingsView.section` |
| `settings.calling.secondaryTitle` | Settings section title | none | `CallingSettingsView.section` |
| `router.call.fallbackDisclosure` | confirmation disclosure clause | `%1$@` skipped label, `%2$@` contact name, `%3$@` routed label | `confirmationPrompt` |
| `call.announce.fallbackRouted` | tap/dial-back announcement | `%1$@` skipped label, `%2$@` contact name, `%3$@` routed label | `dialChannel`, `performContactCall`, `dialBackMissedCall` |
| `call.announce.launchFailedFallback` | launch-fail hop announcement | `%1$@` failed label, `%2$@` contact name, `%3$@` next label | `launchFailHopStep` |

All five are ne/en entries; labels resolve through `CallChannelChain.label(_:locale:)` (the `app.name.*` keys); the skipped-channel label is `fellBackFrom.first` (RES-4); every string is `L10n.fmt` with numbered positionals, never string-concatenated.

**Error paths (C7).** A missing or format-mismatched key fails `L10nCatalogCoverageTests` and the build-time catalog checks; `L10n.str`/`L10n.fmt` behaviour for absent keys is the shipped behaviour and is not changed.

**Concurrency / timeouts (C7).** Static read-only resources; none.

### 13. Per-file edit list (implementation units for `plan-tasks`)

| # | File | Function / site (verified anchor) | Change |
|---|---|---|---|
| 1 | `Services/` + `Calls/CallChannelChain.swift` | whole file (NEW) | the listing in §6 |
| 2 | `AppCoordinator.swift` | `:330-335` (`defaultCallApp`) | sibling `secondaryCallApp` + key (§11) |
| 3 | `AppCoordinator.swift` | `:2851-2853` (init restore) | `secondaryCallApp` restore, same shape |
| 4 | `AppCoordinator.swift` | `:2099-2105` | `resolvedCallChannel` six-arg → `Result`; shared `resolveChannel` |
| 5 | `AppCoordinator.swift` | `:8382-8390` | `resolvedMissedCallChannel` five-arg → `Result` (vocab `.audio`) |
| 6 | `AppCoordinator.swift` | `:8397-8443` | `MissedCallDialRoute`; `missedCallDialAction` new params → route |
| 7 | `AppCoordinator.swift` | `:8457-8483` | `dialBackMissedCall`: announce + hop threading |
| 8 | `AppCoordinator.swift` | `:7312`/`whatsAppInstalledNow` + `hasUsableMessengerHandle` | new probe property + predicate (§7) |
| 9 | `AppCoordinator.swift` | `:7518-7550` | `PendingCallAction`: `var requestedAt`, + two `var … = []` fields, `replacing` (§8) |
| 10 | `AppCoordinator.swift` | `:7587-7647` | chain before pending; early return removed; action carries routed method + provenance |
| 11 | `AppCoordinator.swift` | `:7688-7709` | disclosure clause when `fellBackFrom` non-empty |
| 12 | `AppCoordinator.swift` | `:7720-7803` | `.phone` guard; failure branches → `hopFromCallAction` (§8) |
| 13 | `AppCoordinator.swift` | `:7831-7910` | chain + vocab + announcement + hop in failure branches (§9.2) |
| 14 | `AppCoordinator.swift` | `:7944-7961`, `:7971-8000`, `:8053-8083` | `hop: LaunchHop? = nil`; failure branches hop |
| 15 | `AppCoordinator.swift` | new privates (near `:7831`) | `LaunchHop`, `launchFailHopStep`, `performLaunchFailHop`, `noteLaunchFailHop` (§10) |
| 16 | `AppCoordinator.swift` | `:1925-1926` | `MethodResolver` third closure argument (§8) |
| 17 | `AppCoordinator.swift` | `:7656-7686` | **unchanged** (verify only: gate intact, amended action drops provenance) |
| 18 | `AppCoordinator.swift` | `:6463-6480` | **untouched** (emergency path) |
| 19 | `AppCoordinator.swift` | `:752`, `:5397`, `:5405`, `:7170-7189`, `:10561-10569`, `:10611-10628` | **reused as-is** (outcome lane, speak, window, timeout, yes/no block) |
| 20 | `LeafViews.swift` | `:1171-1174` | probe delegates to `CallChannelChain` |
| 21 | `LeafViews.swift` | `:1605-1620` (+ `RowChannelState` `:2249-2266`) | 5-arg seam call; two new fields; hop candidates |
| 22 | `LeafViews.swift` | `:1564-1584` (+ `whatsApp` `:1546-1548`) | announce before the switch; hop threaded; stale-state guard kept |
| 23 | `LeafViews.swift` | `:1536-1542`, `:2654-2660`, recent-activity re-init | **unchanged** (floor dial; tiles' call surface; non-chain re-init keeps `hop: nil`) |
| 24 | `MethodResolver.swift` | `:22-26`, `:74-78` | injected `globalDefault`; step 4 uses it (§8) |
| 25 | `App/` + `CallingSettingsView.swift` | `:22`, `:40-64`, `:70-77` | two sections; row binding; `nameKey` delegates (§11) |
| 26 | `Resources/Localizable.xcstrings` | — | the five keys, ne/en (§12) |
| 27 | `ios/tools/` + `check-release-log-safety.py` | `FEATURE_ROOTS` `:141+` | + `Services/Calls` entry with a comment (L2-D12) |
| 28 | Tests | §28 | extended suites + new chain/hop suites |

## Interfaces

### 14. Interface summary (every signature this feature introduces or changes)

| Surface | Signature (return type included) | Error / failure type |
|---|---|---|
| C1 route | `static func route(preferred: CallApp, secondary: CallApp, feasibility: Feasibility) -> Result` | none — total |
| C1 attempt order | `static func attemptOrder(preferred: CallApp, secondary: CallApp) -> [CallApp]` | none — total |
| C1 hop list | `static func hopCandidates(preferred: CallApp, secondary: CallApp, routed: CallApp, vocabulary: CallChannelVocabulary = .anyChannel) -> [CallApp]` | none — total |
| C1 hop step | `static func nextLaunchFailCandidate(after failed: CallApp, attemptOrder: [CallApp], messengerHandleAvailable: Bool) -> CallApp?` | `nil` = exhaustion (defined state) |
| C1 probe | `static func whatsAppInstalled(canOpen: (URL) -> Bool) -> Bool` | `false` = not installed (defined) |
| C1 mappings | `static func method(for channel: CallApp, isVideo: Bool) -> CallMethod` / `static func channel(for method: CallMethod) -> CallApp` | none — total bijections on the documented pairs |
| C1 labels | `static func nameKey(for channel: CallApp) -> String` / `static func label(_ channel: CallApp, locale: Locale) -> String` | none — total |
| C1 vocabulary | `CallChannelVocabulary.permits(_:) -> Bool` / `.terminal -> CallApp` / `.normalized(_:) -> CallApp` | none — total |
| C2 seam | `static func resolvedCallChannel(explicit: CallApp?, defaultApp: CallApp, secondaryApp: CallApp, messengerHandleAvailable: Bool, whatsAppInstalled: Bool, vocabulary: CallChannelVocabulary = .anyChannel) -> CallChannelChain.Result` | none — total |
| C2 seam | `static func resolvedMissedCallChannel(familyContact: FamilyContact?, defaultApp: CallApp, secondaryApp: CallApp, messengerHandleAvailable: Bool, whatsAppInstalled: Bool) -> CallChannelChain.Result` | none — total |
| C2 dial-back | `static func missedCallDialAction(phone: String, familyContact: FamilyContact?, defaultApp: CallApp, secondaryApp: CallApp, messengerHandle: String?, whatsAppInstalled: Bool, name: String) -> MissedCallDialRoute` | none — total; the two shipped guards keep their honest actions |
| C2 probe | `var whatsAppInstalledNow: Bool` | none — computed |
| C3 resolver | `init(preferenceStore:historyStore:globalDefault: @escaping (_ isVideo: Bool) -> CallMethod = { _ in .phone })` | none — defaulted, non-throwing |
| C3 action | `func replacing(method: CallMethod, hopCandidates: [CallApp]) -> PendingCallAction` | none — total |
| C4/C5 hop | `private func performLaunchFailHop(after failed: CallApp, candidates: [CallApp], name: String, phone: String, handle: String?, isVideo: Bool, locale: Locale) -> Bool` | none — `false` = exhausted (defined) |
| C5 step | `private func launchFailHopStep(after:candidates:handle:name:locale:) -> (next: CallApp, remaining: [CallApp])?` | none — `nil` = exhaustion |
| C5 openers | `performFaceTimeCall(name:phone:video:hop: LaunchHop? = nil)`, `performSystemContactWhatsApp(name:phone:hop: = nil)`, `performSystemContactMessenger(name:handle:hop: = nil)` | none — the openers' typed outcomes are consumed internally |
| C6 settings | `@Published var secondaryCallApp: CallApp` (key `secondaryCallApp`, default `.phone`) | absent/corrupt raw value → `.phone` |

### 15. Path 1 — voice-initiated call (end-to-end contract)

1. Utterance → `CommandRouter` → `requestCallConfirmation(contactQuery:callType:requestedApp:sourceTranscript:sourceCommand:) -> String?`.
2. Contact resolution (incl. one near-miss retry) unchanged.
3. `methodResolver.resolve(...)` — steps 1–3 unchanged; step 4 = `globalDefault(isVideo)` = `CallChannelChain.method(for: defaultCallApp, isVideo:)`.
4. Chain: `intentIsVideo` from the resolved method; `preferred = channel(for: resolved.method)`; feasibility = handle-on-file + `whatsAppInstalledNow`; vocabulary `.anyChannel`; routed method = `method(for: route.channel, isVideo: intentIsVideo)`.
5. `PendingCallAction` built with the ROUTED method, `fellBackFrom`, `hopCandidates`; slot written; window opened (45 s, reused); prompt spoken: `[near-miss][repeat][unsupported][disclosure if any][method sentence][question]`. Nothing fell back ⇒ byte-identical shipped wording.
6. Yes → slot cleared → `performCallAction(action)`:
   - success on the routed channel → shipped success lines + `noteConfirmedCallExecution` (routed method) + activity record;
   - typed failure → shipped failure line, then `hopFromCallAction`: announce `call.announce.launchFailedFallback` and re-enter with `action.replacing(method: method(for: next, isVideo:), hopCandidates: remaining)`; exhaustion ⇒ nothing further (the failure line already spoke);
   - `.phone` open false ⇒ `announceNoUsableNumber` (terminal).
7. No → `appendCapture(action.capture, .denied)` + shipped cancel line. Timeout → `recordConfirmationTimeout` unchanged (captures the routed action).
8. Override ("होइन, फोन नै गर") → shipped gate + amended action (no provenance, no hop) + one re-confirmation.

### 16. Path 2 — family-contact buttons

`ContactTile.videoCall()/audioCall()` (`LeafViews.swift:2654-2660`) → `performContactCall(contact, kind:)` → vocabulary `.video`/`.audio` → chain over `resolvedVideoApp`/`resolvedAudioApp` → announce `call.announce.fallbackRouted` if a skip occurred (after the shipped tap event, whose outcome string now classifies the routing) → switch on the routed channel → shipped success/recovery lines → failure branches run `performLaunchFailHop` with the family's (name, phone, handle, isVideo) → the hop attempts through the shipped openers (`performSystemContactCall`, `performFaceTimeCall`, `performSystemContactWhatsApp`, `performSystemContactMessenger`) with the remaining candidates. The phone branch keeps its shipped guard and never hops.

### 17. Path 3 — address-book rows (unified contact search)

`rowChannelState(for:)` (once per outcome) → 5-arg seam → `RowChannelState` (channel + provenance + hop list) → the circle shows the routed channel → tap `dialChannel`: announce if a skip occurred → dispatch: `.phone` → `dial` (floor); `.faceTime` → `performFaceTimeCall(video: false, hop:)`; `.whatsApp` → `performSystemContactWhatsApp(hop:)`; `.messenger` → `performSystemContactMessenger(handle:, hop:)` after the shipped stale-state guard. `channelStateVersion` still re-resolves after a chooser pick or a saved handle.

### 18. Path 4 — missed-call dial-back

`dialBackMissedCall(entry)` → identity + family lookup unchanged → `missedCallDialAction(...)` (pure) → `MissedCallDialRoute` → announce if a skip occurred → dispatch: numberless rows keep the shipped Phone-app open / honest dead-row line; `.call` → `performSystemContactCall` (floor); `.faceTime`/`.whatsApp`/`.messenger` → the openers with `hop`.

### 19. The ordered resolution algorithm (single reference implementation)

1. **Inputs**: `explicit` (per-contact/family pick, or the voice path's resolved-method channel) ?? `defaultApp`; `secondaryApp`; `messengerHandleAvailable`; `whatsAppInstalled`; `vocabulary`.
2. **Step 1 normalization**: `vocabulary.normalized(preferred)` (audio never FaceTime; video never GSM; `.anyChannel` permits all). Silent by design (shipped button gate).
3. **Chain**: `route(preferred:secondary:feasibility:)` over `attemptOrder` — first feasible; `fellBackFrom` = the skipped channels in attempt order; dedupe on equal picks; at most three distinct channels; `.phone` is always IN the order (containment), so the route never dead-ends.
4. **Post-check**: if the routed channel is vocabulary-illegal, substitute the vocabulary terminal; `fellBackFrom` unchanged.
5. **Provenance → speech**: `fellBackFrom.first` + routed channel feed the disclosure (prompt) and the announcement (taps/dial-back). Empty ⇒ silent.
6. **Hop**: `hopCandidates(preferred:secondary:routed:vocabulary:)` stored on the action/state; on a failed open, `nextLaunchFailCandidate` (messenger filtered) decides; announce + attempt; strictly shrinking lists bound the recursion; exhaustion speaks nothing beyond the shipped failure line.
7. **Never dead-ends**: `.phone` is always feasible and always in the order; `.video` substitutes `.faceTime`, also always feasible; the invariant asserted across all cells is `isFeasible(result.channel)` ∧ `vocabulary.permits(result.channel)` (§28).

## Data model & persistence

### 20. Stores and keys (no database, no schema, no migration)

| Store | Key | Type | Default | Notes |
|---|---|---|---|---|
| UserDefaults | `defaultCallApp` | `CallApp` raw value | `.phone` | unchanged (`:330-335`, `:2851-2853`) |
| UserDefaults (this feature) | `secondaryCallApp` | `CallApp` raw value | `.phone` (absent/unknown → GSM) | same protection class and lifecycle; `didSet` write, init-time restore (`:2851-2853` site) |
| `ChannelPreferenceStore` | per-contact pick | `CallApp` | none | unchanged; the chain's `explicit` input |
| `CallMethodPreferenceStore` / `ConfirmedMethodHistoryStore` | `call.methodPreferences` / `call.confirmedMethodHistory` | existing formats | — | unchanged; MethodResolver steps 2–3 |
| `MessengerHandleStore` | per normalized phone | handle (PII) | none | unchanged; feasibility input only |
| `Localizable.xcstrings` | 5 new keys | ne/en values | — | §12 |

**Round-trip contract (NFR-CDP-005).** Write `secondaryCallApp = <raw>` → read back the same `CallApp`; an absent key and an unknown raw value both restore `.phone`; `secondary == primary` stores without complaint. Tested over the real UserDefaults seam (house pattern `SpotifySettingsSurfaceTests`): `testSecondaryRoundTripAndAbsentDefault`-class assertions (`testSecondaryAbsentRestoresPhone`, `testSecondaryRoundTrip`).

### 21. Struct pins (memberwise-initializer discipline)

- `PendingCallAction`: `var requestedAt: Date = Date()`, `var fellBackFrom: [CallApp] = []`, `var hopCandidates: [CallApp] = []` — `var` + default ⇒ defaulted memberwise parameters; the four shipped labelled constructions compile unchanged (verified: `:7624`, `:7670`, `IntentLogStoreTests.swift:206`, `:224`).
- `RowChannelState` (`private struct`, `LeafViews.swift:2249-2266`): `var fellBackFrom: [CallApp] = []`, `var hopCandidates: [CallApp] = []` — same reason; the single construction site (`:1616-1619`) passes both explicitly.
- `MissedCallDialRoute`, `LaunchHop`: internal nested types on `AppCoordinator` (the `MissedCallDialAction` precedent) — `LaunchHop` must be visible to `LeafViews`.

## Error handling & observability

### 22. Error / outcome taxonomy

No new error type, no throw, no `Result`-with-`Error`. The feature's failure vocabulary is the shipped typed outcomes; each has exactly one handling class (§10.1): **recorded success** (shipped success lines + activity/learning), **recovery** (shipped disclosure lines; still an open — `needsNativeCompose`, `copiedNumber`, `fellBackToWeb`), **failed-with-hop** (shipped line then `launchFailedFallback`), **failed-terminal** (shipped line only: `.phone` open false, `invalidPhone`, `PhoneDialer.url` nil), **exhaustion** (nothing further after the shipped line). Every class speaks; none is silent.

### 23. Announcements as the user-facing error channel

| Situation | Spoken line | When |
|---|---|---|
| Chain skipped a channel (voice) | `router.call.fallbackDisclosure` inside the prompt | before the window's yes |
| Chain skipped a channel (tap/dial-back) | `call.announce.fallbackRouted` | at resolution, before the open |
| Open failed, candidate remains | `call.announce.launchFailedFallback` | immediately after the failure line |
| Open failed at the floor / exhaustion | the shipped line only | immediately |

All copy composes from the same `Result` (`fellBackFrom.first` + `.channel`) — one source, so a spoken line can never diverge from the executed action (security pre-map row 4). Session language via `activeLocale`; names/numbers are spoken, never logged.

### 24. Observability and log-gate deltas

- **No new console writes, prints, `os_log` or `NSLog`** anywhere in the feature.
- `contact_call_buttons` tap outcome (family path) extended to classify routing: `"video:faceTime:fellBack"` / `"audio:phone:direct"` — classification only, `metadata: [:]` (L1 integration #12).
- One new classification event (the only one): component `"call_launch_fallback"`, eventType `"hop"`, outcome `"<failed>:<next>"` — channel raw values only, `metadata: [:]`.
- Search-row taps keep their shipped tokens (`"whatsapp:openedChat"` etc.); a hopped re-attempt emits through the same site as the first attempt.
- No new metadata keys anywhere ⇒ no `LogSanitiser.allowedKeys` change (rule 5 stays clean).
- `FEATURE_ROOTS` (`check-release-log-safety.py:141+`) gains `Services/Calls` with a comment in the shipped pattern, so the new file sits inside the gate.
- `ios/build.sh:431` (`check-release-log-safety.sh`) must stay exit 0 — a release-gate item of NFR-CDP-010.
- Announcements and prompts are speech only; they never route through logging APIs.

## Concurrency & isolation

### 25. Isolation model

- **Main actor / main queue**: every changed production call site (`AppCoordinator` methods, `LeafViews` view code, `CallingSettingsView` bindings) is main-confined. The probe helper runs on main via the shipped `canOpenURLOnMain` hop (`:7312-7315`).
- **Shared resource — the pending action slot** (`:7552`): writers = `requestCallConfirmation` (before the window opens), `handleCallConfirmationOverride` (amended action), and `handleConfirmationResponse` (→ `nil` before execution); on expiry the timeout path records the capture — `recordConfirmationTimeout` reads the slot (`:10562`), and the timeout closure clears the other pending slots (`:3054-3066`), not the call slot. Readers = `confirmationPrompt`, the override gate, `isAwaitingCallConfirmation` (`:7553`; its consumers are `CommandRouter.swift:1003` and `:1017` via its coordinator protocol member `CommandRouter.swift:60`, plus the home pill `HomeView.swift:1207`; the routing-busy check `:10717-10723` reads the slot directly at `:10720`), and `recordConfirmationTimeout` (`:10561-10569`, which reads the slot); the call block reads and nils the slot (`:10611-10612`). This reader set matters because removing the shipped early return (`:7620-7623`) changes when the slot can be live. The chain computation completes before the slot is written; the hop never touches the slot (it operates on local copies after the slot is `nil`). Isolation mechanism: main-queue confinement only — no locks, no actors, no atomics.
- **Value-only statics**: C1 and the C2 seam statics are pure; concurrent reads are safe by construction (no state).
- **No new asynchronous work**: no `Task`, no `DispatchQueue` addition, no timer, no retry. The hop is synchronous recursion on the main thread.
- **Deregistration paths**: the window's existing teardown (`handleConfirmationResponse` on yes/no — the only nil write of the call slot; on expiry the timeout path records the capture and clears the other pending slots at `:3054-3066`, leaving the call slot pended) is unchanged and remains the only lifecycle of a pending action; the hop's copies are stack-local and die with the call; the settings properties have no observers beyond `didSet` persistence.

## Performance & security implementation patterns

### 26. Performance (NFR-CDP-004)

- The chain is O(1) with ≤ 3 comparisons; `hopCandidates` O(3); the whole resolution adds well under the 100 ms p95 budget on top of the shipped path (no allocation beyond small arrays).
- The only platform call is `canOpenURL` (a local LaunchServices query) executed once per resolution where a `whatsAppInstalled` input is needed (row state, family tap, dial-back, voice step). No caching, no polling — the staleness residual is covered by the hop (frozen Risks).
- The prompt grows by at most one clause (a few seconds of speech) inside the unchanged 45 s window; the window is armed at `openConfirmationWindow` exactly as shipped.
- No retry loop exists; exhaustion is reached in ≤ 2 synchronous re-entries.

### 27. Security implementation patterns

- **Zero new egress / collection**: only `canOpenURL` and the address-book handle check; no network, no file, no keychain write, no plist change (`Info.plist` already lists `whatsapp`, `:94`).
- **PII discipline**: handles and numbers are seam inputs only; the new code adds no log statement, no event field and no metadata key — `metadata: [:]` on every emitted event; announcements are speech only (NFR-CDP-003).
- **Misuse cases**: a corrupted setting fails safe to GSM (never a dead end); a stale probe is corrected by the announced hop; the override gate stays the only side door for amending a pending call, and the hop never re-opens a confirmed question (no re-pending, no re-prompt — the elder's yes stands).
- **Tampering surface**: settings are local-only, same store class as the shipped preference; no remote input path exists.
- **Emergency precedence**: untouched — no chain, probe or hop runs on the emergency path (`:6463-6480`, `NotifyChannel.resolve`).

## Test seams and gate suites

### 28. Suites, seams and the property assertions

| Suite | Seam | Assertions (test names ≤ the sanitiser limit) |
|---|---|---|
| `Services/Voice/` + `CallChannelResolutionTests.swift` | pure statics; `assertResolved` extended to `.channel` + provenance | `testChainNeverDeadEndsAcrossAllCells` (all 64 (preferred, secondary, handle, probe) cells: `isFeasible(result.channel)` is true, `result.channel` vocabulary-legal per vocabulary, `fellBackFrom` disjoint from the channel and in attempt order); `testSecondaryEqualsPrimaryDedupes`; `testExplicitPickWinsAsPreferred`; `testOrderContainsPhonePreferredFirst` (V-6 rename — asserts containment of `.phone` + `isFeasible(routed)` + preferred-first, NEVER last-element; the prior name is retired; the rename executes in T-145); `testHopCandidatesRespectVocabulary`; `testSubstitutedTerminalHasNoCandidates`; `testProbeFalseRoutesToSecondary`; `testProbeStubbedFalseHops` |
| `Services/Intents/MethodResolverTests.swift` | injected `globalDefault`; `StubEncryptedStorage` stores | `testGlobalDefaultClosureMapsCallType` (Messenger primary → `.messengerAudio`/`.messengerVideo`; WhatsApp → `.whatsappChat`); `testDefaultConstructionStillPhone` |
| Confirmation-wording tests (in the resolution suite or the confirmation suite) | `confirmationPrompt` via the real catalog | `testDisclosureNamesSkippedAndRouted`; `testNoFallbackKeepsPromptByteIdentical` |
| Picker UI / settings persistence tests | real UserDefaults seam (house `SpotifySettingsSurfaceTests` pattern); value-level assertions + source scan for the two sections | `testSecondaryAbsentRestoresPhone`; `testSecondaryRoundTrip`; `testPickerTwoSectionsPersist`; `testPickerRowExposesSelectedState` (the selected row's non-visual signal in both sections); `testPickerTitlesExposeHeadingTrait` |
| `App/MissedCallDialBackTests.swift` | pure `missedCallDialAction` | route struct fields incl. `fellBackFrom`/`hopCandidates`; the two numberless actions carry `channel == nil` |
| `App/L10nCatalogCoverageTests.swift` | catalog resolution | the five keys resolve in both locales and differ |
| Hop behaviour (unit-level, coordinator seams) | `nextLaunchFailCandidate` + `launchFailHopStep` boundaries via the pure step | `testHopConsumesCandidatesNeverLoops` (strictly shrinking, ≤ 2 hops); `testLaunchFailedFallbackSpokenOnce`; `testMessengerWithoutHandleSkippedInHop`; `testAdditiveFieldsKeepOldCallSites` (the five-arg constructions still build) |

Baseline discipline: the full-bundle unit baseline is pre-existing red; scoped `-only-testing` runs are the honest gate, with baseline failures recorded rather than silently included or excluded (NFR-CDP-008). DV-1..7 on Anzaan remains the completion gate (FR-CDP-019).

## Traceability (component → requirement)

### 29. Requirement coverage per component

| Requirement | Primary components | Where in this document | Test/DV |
|---|---|---|---|
| FR-CDP-001/002 primary + fallback pickers | C6 | §11 | picker UI; DV-1 |
| FR-CDP-003 `secondaryCallApp` persistence, GSM default | C6 | §11, §20 | persistence tests; DV-1 |
| FR-CDP-004 Messenger feasibility = handle on file | C1 (`Feasibility`), C2 (`hasUsableMessengerHandle`) | §6, §7 | chain matrix; DV-2 |
| FR-CDP-005 WhatsApp probe via injected closure | C1 (`whatsAppInstalled`), C2 (`whatsAppInstalledNow`) | §6, §7 | stubbed-closure tests; DV-3 |
| FR-CDP-006 FaceTime/phone always feasible; phone floor | C1 | §6, §19 | 64-cell matrix; DV-4 |
| FR-CDP-007 chain, dedupe, at-most-once | C1, C2 | §6, §7, §19 | `CallChannelResolutionTests` |
| FR-CDP-008 `fellBackFrom` attempt order, single source | C1, C3, C4 | §6, §8, §9 | provenance assertions; wording tests |
| FR-CDP-009 explicit pick wins as preferred | C2 | §7, §19 step 1 | matrix "pick wins" cells; DV-6 |
| FR-CDP-010 tap buttons route the chain, vocabulary preserved | C4 (+ C1 vocabulary) | §9, §10.4 | row/tile tests; DV-6 |
| FR-CDP-011 missed-call dial-back routes the chain | C2, C4 | §7, §18 | `MissedCallDialBackTests`; DV-6 |
| FR-CDP-012 MethodResolver global default = settings primary | C3 | §8 | `MethodResolverTests`; DV-6 |
| FR-CDP-013 fallback before confirmation; names routed channel | C3 | §8, §15 | wording tests; DV-2 |
| FR-CDP-014 override + near-miss preserved | C3 | §8 (override verified unchanged) | override tests; DV-5 |
| FR-CDP-015 launch-fail hop announced, never silent | C5 (+ C3/C4 threading) | §10 | hop tests; DV-3 |
| FR-CDP-016 automatic routing + announcement | C3, C4 | §9, §15 | announcement tests; DV-2/3 |
| FR-CDP-017 ne/en strings | C7 | §12 | `L10nCatalogCoverageTests`; DV-7 |
| FR-CDP-018 preserved behaviours (no new dialogue; emergency; no silent failures) | C3, C5 | §8, §10.1, §27 | regression suites; DV-5/6 |
| FR-CDP-019 DV gate recorded | all | §28 | DV pack at final sign-off |
| NFR-CDP-001 zero dead ends across cells | C1 | §6, §10.3, §19 step 7 | exhaustive matrix |
| NFR-CDP-002 probes local, no new surface | C1, C2 | §7, §27 | zero-egress review |
| NFR-CDP-003 log safety | C5, C7 | §24 | log gate exit 0 |
| NFR-CDP-004 ≤ 100 ms added latency; immediate probe | C1–C5 | §26 | on-device timing (DV-2) |
| NFR-CDP-005 persistence round-trip | C6 | §20 | round-trip tests; DV-1 |
| NFR-CDP-006 picker accessibility | C6 | §11 | picker UI tests; DV-1 |
| NFR-CDP-007 ne/en parity | C7 | §12 | `L10nCatalogCoverageTests`; DV-7 |
| NFR-CDP-008 deterministic scoped suites | all | §28 | scoped runs recorded |
| NFR-CDP-009 no regression (voice pipeline, emergency, dial-back) | C2, C3 | §8 edit #17/#18; §10.1 | regression suites |
| NFR-CDP-010 compliance/review/release gates; DV acceptance | all | §24, §28 | GO/SECURITY-GO; log gate; DV pack |

## Technical risks and mitigations

### 30. Risks

| # | Risk | Likelihood × impact | Mitigation (this design) |
|---|---|---|---|
| R1 | Regression in the just-shipped voice pipeline (PRs #161–#168) from the confirmation/execute edits | Low × High | The chain replaces exactly one rule (Messenger-no-handle early return) and one hardcoded default (MethodResolver step 4); steps 1–3 and every shipped speech/learning line are untouched; edit #17 (`handleCallConfirmationOverride`) is verified unchanged; the four search-shaped openers gain one defaulted parameter (`hop: nil` = today's behaviour). |
| R2 | A hopped attempt speaks slightly different copy than a direct attempt (FaceTime success: `router.call.calling` vs `call.announce.faceTimeVideo`) | Certain (by L2-D5) × Low | The hop line just named the channel, so nothing false is said; every failure line is the same key across contexts (verified); recorded for `review-l2` as the one accepted copy delta; the alternative (a context enum threaded through `LaunchHop`) was rejected as a diff beyond the named seams. |
| R3 | `hopCandidates` without the vocabulary filter would send a video hop to the GSM dialer (or an audio hop to FaceTime) | Was certain × High | L2-D1 + §10.4 case table + the vocabulary-aware static; tests pin the filtered list and the substitution-has-no-candidates rule. |
| R4 | Hop loops or double-attempts a channel | Low × High | Strictly shrinking consumed lists + `after:` filter; depth ≤ 2; `testHopConsumesCandidatesNeverLoops`. |
| R5 | Learning the wrong thing after a hop (flywheel history/capture) | Medium × Medium | L2-D7 records the honest rule: the hop's method is what executed and teaches; failed attempts record nothing; `sourceTranscript`/`sourceCommand`/`requestedAt` travel unchanged so the training pair keeps its provenance. Flagged for `review-l2` as a behaviour decision, not a silent one. |
| R6 | `canOpenURL` staleness (iOS caches scheme availability) | Medium × Low | Frozen-risk acceptance: probes run at call time, user-paced; the launch-fail hop covers the residual; no cache is added. |
| R7 | Prompt grows by one clause inside the 45 s window | Low × Low | The window is armed as shipped and its length is unchanged; the clause is one short sentence; the near-miss prefix already exercises the same pattern. |
| R8 | Row state staleness (setting changes between outcome creation and tap) | Low × Low | L2-D10: channel, provenance and hop list are one snapshot; `channelStateVersion` re-resolves on pick/handle-write; the stale-state guards stay in place. |
| R9 | Memberwise-init surprise (`let` + default excluded) silently drops the new fields | Was certain × Medium | L2-D3 pins `var` + default for all four fields; `testAdditiveFieldsKeepOldCallSites` compiles the shipped five-arg constructions; `replacing` is the only writer of the hop copy. |
| R10 | Log-gate failure or PII leak in the new code | Low × High | §24: no console writes, one classification event with channel raw values, `metadata: [:]`, the `Services/Calls` `FEATURE_ROOTS` entry, `build.sh:431` exit 0. |
| R11 | Family-hop copy paths diverge (openers vs the family switch bodies) | Medium × Low | L2-D5's recorded delta + §10.2's structure: the hop always re-enters the shipped openers, never a second implementation of an open. |

## Not in this design

### 31. Scope fence (explicit non-goals — nothing here is left half-built)

- A dedicated `CallRouter` service (Constraint 7): the feature extends the named seams only.
- Per-contact primary/secondary storage (Constraint 5): per-contact and family picks stay the chain's `explicit` input; the settings-level pair is the only new storage.
- Emergency-contact semantics (`:6463-6480`, `NotifyChannel.resolve`): untouched; no probe, chain or hop wraps escalation.
- A new dialogue flow: the multi-turn confirmation is reused exactly; the disclosure is a clause in the existing question, not a new question.
- Any new network, data, identity or privacy surface (Constraint 8 / NFR-CDP-002): probes are local; no analytics, no telemetry, no permission widening; `Info.plist` unchanged.
- Changes to the voice pipeline beyond the named `MethodResolver` seam and the `requestCallConfirmation`/`performCallAction` steps (Constraint 7; NFR-CDP-009).
- Android scope, new compliance regimes, model/prompt changes, and the weak edge of the brief's open items (out of scope per the requirements index).
- Catalog copy beyond the five keys' parameter contracts (copy wording is catalog-time work inside C7).
