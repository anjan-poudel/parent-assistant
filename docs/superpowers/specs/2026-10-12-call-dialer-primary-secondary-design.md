# Call Dialer Primary/Secondary — Design (frozen)

Status: **Approved by owner 2026-10-12.** Frozen reference for feature
`call-dialer-primary-secondary` (`specs/call-dialer-primary-secondary/`). The feature
constitution distils the binding rules below; this document is the full design.

## Problem

Today the app has ONE global dialer preference (`defaultCallApp` on `AppCoordinator`,
picked in `CallingSettingsView`). When that channel cannot actually place the call —
Messenger with no handle on file, WhatsApp not installed — the app either dead-ends the
tap or silently drops to a different surface. The elder cannot recover from this without
a family member reconfiguring the phone. Calls need a **primary → secondary → GSM**
fallback chain so a call always goes through, with the actually-routed channel spoken out
loud before dialing.

## Current state (master 8089c735)

- `CallApp` enum (`Services/Intents/CallLinks.swift:66`): `faceTime`, `phone` (GSM),
  `messenger`, `whatsApp`; `supportsVideo`/`supportsAudio` gates per channel.
- `AppCoordinator.defaultCallApp` (UserDefaults key `defaultCallApp`) — the single global
  pick, rendered as four selectable rows in `CallingSettingsView`.
- `AppCoordinator.resolvedCallChannel(explicit:defaultApp:messengerHandleAvailable:)`
  (`AppCoordinator.swift:2099`) — per-contact pick wins, else global default; one hard
  rule: Messenger without a handle drops to `.phone`.
- `resolvedMissedCallChannel` (`AppCoordinator.swift:8382`) + `missedCallDialAction`
  (`:8423`) — missed-call dial-back runs the same resolution.
- `ChannelPreferenceStore` — per-contact `CallApp` for address-book rows (the "explicit"
  input above).
- Voice path: `MethodResolver.resolve` (`Services/Intents/MethodResolver.swift`) chain —
  explicit app → family preference (`CallMethodPreferenceStore`) → confirmed history →
  hardcoded `.phone` global default. `requestCallConfirmation`
  (`AppCoordinator.swift:7586`) gates Messenger-no-handle (refusal line) and pends
  `PendingCallAction` into the existing multi-turn confirmation window; the override
  protocol ("होइन, फोन नै गर") amends the method pre-confirmation.
- `CallLinks` open outcomes (`openedThread`, `fellBackToWeb`, `invalidHandle`) +
  `CallLinkOpening`/`SystemCallLinkOpener` protocol — the launch seam.
- `Info.plist` `LSApplicationQueriesSchemes` already lists `whatsapp`, `fb-messenger`,
  `facetime`, `tel` — `canOpenURL` probes are usable without plist changes.
- Localization: `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (ne/en).

## Goals

1. **Primary + Fallback dialer pickers** in `CallingSettingsView`, persisted via the
   `AppCoordinator` UserDefaults seam.
2. **Feasibility-aware chain**: preferred → fallback → `phone` (GSM hard floor). A call
   never dead-ends: resolution always returns a channel that can be attempted.
3. **All call paths route the chain**: address-book and family-contact call buttons,
   missed-call dial-back, and voice-initiated calls (MethodResolver's global-default step).
   Per-contact and family picks keep winning as the chain's preferred input.
4. **The existing multi-turn confirmation is reused exactly**: fallback resolves BEFORE the
   spoken confirmation, which names the actually-routed channel; the override protocol is
   unchanged. No new dialogue flow.

## Non-goals (binding — see constitution constraints)

- No dedicated `CallRouter` service — extend the existing resolution seams only.
- No per-contact primary/secondary storage.
- Emergency-contact semantics untouched.
- No new network, data, identity, or privacy surface — feasibility probes are local.
- No changes to the just-shipped voice pipeline beyond the named MethodResolver seam
  (regression context: PRs #161–#168).

## Design

### 1. Settings & persistence

`AppCoordinator` gains `secondaryCallApp: CallApp` next to `defaultCallApp` — same
`@Published` + UserDefaults pattern, key `secondaryCallApp`, **default `.phone`**.
`CallingSettingsView` renders two sections: **Primary dialer** and **Fallback dialer**,
each the existing four-channel row pattern. `secondary == primary` is legal and dedupes
at routing time (each channel is attempted at most once).

### 2. Feasibility contract

| Channel | Feasibility check | Note |
|---|---|---|
| `messenger` | handle on file for the target contact | NOT gated on the app being installed — the m.me web chat still connects, and shipped tap behavior is preserved |
| `whatsApp` | app installed — `canOpenURL("whatsapp://")`, injected as a closure for tests | local probe only |
| `faceTime` | always feasible | |
| `phone` | always feasible — the GSM hard floor | terminal channel of the chain |

### 3. Chain resolver (new pure-static file)

New file (house-seam pattern of `resolvedCallChannel`, e.g.
`Services/Voice/CallChannelChain.swift`):

```swift
enum CallChannelChain {
    struct Feasibility {
        let messengerHandleAvailable: Bool
        let whatsAppInstalled: Bool
    }
    struct Result: Equatable {
        let channel: CallApp
        /// Channels that were preferred but infeasible, in attempt order —
        /// empty when nothing fell back. Announcements compose from this.
        let fellBackFrom: [CallApp]
    }
    static func route(preferred: CallApp,
                      secondary: CallApp,
                      feasibility: Feasibility) -> Result
}
```

Rules: attempt `preferred`; if infeasible, attempt `secondary` (skipped when equal);
if that is infeasible too, `phone`. `phone` is always feasible, so the chain never
dead-ends.

### 4. Tap paths

`resolvedCallChannel` / `resolvedMissedCallChannel` run the chain: the explicit
per-contact/family pick (when present) is `preferred`, else `defaultCallApp`;
`secondaryCallApp` is `secondary`; feasibility comes from the target's handle and the
WhatsApp probe. The Messenger-no-handle drop becomes one case of the chain rather than a
special rule. Call sites updated: address-book row buttons (`LeafViews.swift:1612`),
family-contact buttons, missed-call dial-back. Emergency-contact resolution semantics are
unchanged.

### 5. Voice path

- `MethodResolver`'s global-default step (currently hardcoded `.phone`) becomes the
  **settings primary**, mapped `CallApp → CallMethod` by call type:
  `phone → .phone`; `faceTime → video ? .facetimeVideo : .facetimeAudio`;
  `messenger → video ? .messengerVideo : .messengerAudio`; `whatsApp → .whatsappChat`.
  Injected (closure/config struct) so `MethodResolver` stays coordinator-free and
  unit-testable.
- `requestCallConfirmation` runs the feasibility fallback BEFORE pending the action: the
  existing Messenger-no-handle refusal becomes a chain hop (Messenger w/o handle →
  secondary → phone). The confirmation prompt names the routed channel and discloses what
  was skipped — "Messenger isn't available — call Syanu via WhatsApp, okay?". The
  override protocol and near-miss disclosure are preserved unchanged.

### 6. Launch-fail fallback (best-effort)

If the resolved channel's open itself fails (iOS reports failure, or `CallLinks` returns a
failure outcome), attempt the fallback, then `phone`, announcing via the existing
spoken-outcome lane. Never silent.

### 7. Localization

New ne/en keys in `Localizable.xcstrings`: settings section titles
(`settings.calling.primaryTitle`, `settings.calling.secondaryTitle`), confirmation
fallback disclosure template (`router.call.fallbackDisclosure`), routed-channel
announcement (`call.announce.fallbackRouted`), launch-fail announcement
(`call.announce.launchFailedFallback`).

### 8. Tests (scoped suites — the honest gate; full-bundle baseline is pre-existing red)

- `CallChannelResolutionTests`: full chain matrix — preferred feasible; preferred
  infeasible → secondary; both infeasible → phone; `secondary == primary` dedupe;
  per-contact pick wins as preferred; fellBackFrom content.
- `MethodResolverTests`: global-default step = settings primary (mapped by call type);
  fallback applied before confirmation.
- Settings persistence: `secondaryCallApp` round-trip + `.phone` default.
- Confirmation-prompt wording: fallback disclosure names the routed channel.
- Picker UI: two sections render and persist.

### 9. Delivery

Feature branch `feat/call-dialer-primary-secondary` in the ai-sdd-managed sibling
worktree; integrate via PR against `master` (house rule — never work in the main
checkout). Completion gate: DV-1..7 device validation on Anzaan (see constitution).

## Decisions (owner-approved 2026-10-12)

1. Fallback trigger = pre-flight feasibility + launch-failure; routing is automatic with a
   spoken announcement — no ask-before-fallback step for the elder.
2. Scope = all call paths (buttons, dial-back, voice global-default step).
3. Messenger feasibility = handle on file only; m.me web-chat behavior unchanged.
4. Secondary defaults to GSM (`.phone`); GSM is the hard floor; duplicate picks dedupe.
5. Multi-turn confirmation reused exactly (per owner instruction: use the existing
   multi-turn conversation machinery for any dialogue while handling calls).

## Risks & mitigations

- **Regression on just-shipped call paths (PRs #161–#168):** the chain replaces only the
  single Messenger hard-rule and the hardcoded voice default; the resolver is pure-static
  and closure-injected; scoped tests pin the matrix.
- **`canOpenURL` probe staleness:** iOS caches scheme availability; acceptable here —
  probes run at call time, user-paced, and the launch-fail hop covers the residual case.
- **Full-bundle red baseline:** scoped `-only-testing` runs are the gate (existing house
  practice).
