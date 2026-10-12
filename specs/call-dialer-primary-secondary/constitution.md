# Constitution — call-dialer-primary-secondary (feature supplement)

Applies to the `call-dialer-primary-secondary` workflow only (`.ai-sdd/workflows/call-dialer-primary-secondary.yaml`). The project constitution (`/constitution.md`) is inherited unchanged — Architecture Constraints 1–6, Standards, release gates, and Agent Principles all bind this feature. This supplement does not restate project-level rules; it records only what the feature adds, what it must not change, and the decisions left open. See `specs/call-dialer-primary-secondary/init-report.md` for the scaffold probe.

Frozen design reference: `docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — approved by the owner 2026-10-12 and frozen. The doc is to be written and committed on the feature branch by the brainstorming flow. This supplement distils the design's binding rules; if a conflict with the approved design is found, raise it as a recorded amendment rather than resolving it silently.

## Feature Purpose & Scope

Purpose: let the user choose a **Primary dialer** and a **Fallback dialer** (FaceTime / phone / Messenger / WhatsApp) in Settings, and route every call through a feasibility-aware chain: preferred channel → fallback channel → GSM (phone) hard floor. Today the dialer is a single global default; this feature makes call initiation resilient when the preferred channel cannot actually place the call (Messenger with no handle on file, WhatsApp not installed). It builds on the existing resolution seams — it does not replace them.

Primary user: the elderly parent using the phone hands-free (voice-first). The owner (family member) configures the settings on their behalf. Success is observable: calls never dead-end when the preferred dialer is infeasible, and the existing spoken confirmation names the actually-routed channel (e.g. "Messenger isn't available — call Syanu via WhatsApp, okay?").

In scope:

- Settings-level Primary + Fallback dialer preference (4 channels: `faceTime` / `phone` / `messenger` / `whatsApp`), stored via the `AppCoordinator` UserDefaults seam (`secondaryCallApp` next to the existing `defaultCallApp`); secondary defaults to GSM (phone).
- A new pure-static feasibility resolver (the house-seam pattern of `resolvedCallChannel`): Messenger feasible ⇔ handle on file for the target; WhatsApp feasible ⇔ app installed (`canOpenURL`, injected as a closure for tests); FaceTime and phone always feasible.
- The chain preferred → fallback → phone with `fellBackFrom` carried in the result so announcements can name the actually-routed channel.
- Applying the chain to **all** call paths: address-book + family-contact call buttons, missed-call dial-back, and voice-initiated calls through MethodResolver's global-default step (the settings primary, mapped `CallApp`→`CallMethod` by call type).
- Fallback resolves **before** the spoken confirmation; the existing multi-turn dialogue confirmation is reused exactly and names the routed channel. The override protocol ("होइन, फोन नै गर") is preserved unchanged.
- Launch-fail fallback (best-effort) announced via the existing spoken-outcome lane.
- ne/en localization for all new user-visible strings; scoped test suites (chain matrix, MethodResolver, settings persistence, confirmation-prompt wording, picker UI).

Out of scope (must not change):

- A dedicated `CallRouter` service — the feature extends the existing resolution seams only.
- Per-contact primary/secondary storage — per-contact and family picks keep winning as the **input** to the chain; the chain itself is settings-level.
- Emergency-contact semantics.
- A new dialogue flow — the existing multi-turn confirmation is reused.
- The no-silent-failure principle, and any new network, data, identity, or privacy surface.
- The just-shipped voice pipeline beyond the named MethodResolver seam (regression context: PRs #161–#168).

## Channel Resolution & Feasibility Contract

Channels (the `CallApp` values): `faceTime`, `phone`, `messenger`, `whatsApp`.

| Channel | Feasibility check | Note |
|---|---|---|
| `messenger` | handle on file for the target contact/family contact | **Not** gated on the app being installed |
| `whatsApp` | app installed — `canOpenURL` (injected as a closure so tests can stub it) | Local probe only |
| `faceTime` | always feasible | |
| `phone` | always feasible — the GSM hard floor | The chain's terminal channel |

Chain rule: resolve the input channel (a per-contact/family pick when present, else the settings primary) → if infeasible, the settings secondary → if infeasible (or deduped), `phone`. A channel is attempted at most once — `secondary == primary` is legal and simply dedupes. The chain **never dead-ends**: whatever the settings and feasibility state, resolution returns a channel that can be attempted, and `phone` is the floor.

Resolution happens in the existing seams — `resolvedCallChannel` / `resolvedMissedCallChannel` run the chain, with the feasibility logic in the new pure-static resolver file. The fallback outcome is computed before the spoken confirmation is rendered; the confirmation copy names the actually-routed channel.

## Safety & Compliance Delta

No new compliance category: no new data, network, identity, or privacy surface — the feasibility probes are local (`canOpenURL`, address-book handle check) and emergency-contact semantics are untouched. The change is nonetheless safety-relevant because it re-routes call initiation for elderly users, including missed-call dial-back, so it is treated as such: the chain must never dead-end, GSM (phone) is the always-feasible hard floor, and the existing spoken confirmation + override protocol must be preserved unchanged. Review-worthy at the project baseline: paired review / T2 gates on implementation (the workflow file already carries the T2 review gates). No feature-specific review gate beyond the project baseline is added.

## Feature Constraints

1. **GSM hard floor — no dead ends.** `phone` is always feasible and is the chain's terminal channel. Any resolution returns an attemptable channel even when primary and secondary are both infeasible. This is the feature's core guarantee.
2. **Messenger feasibility stays "handle on file".** It is never gated on whether the Messenger app is installed.
3. **WhatsApp feasibility is the `canOpenURL` probe**, injected as a closure so tests stub it deterministically.
4. **Secondary defaults to GSM (phone).** `secondary == primary` is allowed and routes with dedupe — each channel is attempted at most once.
5. **No per-contact primary/secondary storage.** Per-contact and family picks keep winning as the input to the chain; this feature adds only the settings-level preference.
6. **The existing confirmation flow is reused exactly.** Fallback resolves before the spoken confirmation; the confirmation names the actually-routed channel; the override protocol ("होइन, फोन नै गर") is preserved unchanged. No new dialogue flow is introduced.
7. **No `CallRouter` service.** Extend the existing resolution seams (`resolvedCallChannel` / `resolvedMissedCallChannel`, MethodResolver's global-default step). The regression risk is to the just-shipped voice pipeline, emergency-contact and dial-back paths (PRs #161–#168) — do not refactor beyond the named seams.
8. **No new network/data surface; no silent failures.** Probes are local; launch-fail fallback is best-effort and announced via the existing spoken-outcome lane; emergency-contact semantics are unchanged; the no-silent-failure principle is unchanged.
9. **Localization discipline.** All new user-visible strings — settings labels, pickers, confirmation and announcement copy — are localized ne/en in `ios/ElderlyAssistant/Resources/Localizable.xcstrings`.
10. **Frozen design.** `docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` is the approved, frozen reference (owner sign-off 2026-10-12); the brainstorming flow commits it on the feature branch. Implementation follows it; deviations are recorded amendments.
11. **Delivery method — house rule.** Work in the feature worktree/branch `worktree-<slug>`; integrate via PR against `master`; never work in the main checkout.
12. **Test gate.** Scoped/focused test suites are the honest gate (the full-bundle baseline has pre-existing failures): the chain matrix (`CallChannelResolutionTests`), `MethodResolverTests`, settings persistence, confirmation-prompt wording, and picker UI. The new resolver is pure-static and closure-injected so the chain matrix is deterministic without platform stubs.

## Integration Surfaces (mapped by the scaffold brief)

| Surface | Change |
|---|---|
| `ios/ElderlyAssistant/App/CallingSettingsView.swift` | New Primary dialer + Fallback dialer sections/pickers. |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | `resolvedCallChannel` / `resolvedMissedCallChannel` run the chain; `secondaryCallApp` UserDefaults persistence next to `defaultCallApp`; dial-back paths. |
| `ios/ElderlyAssistant/App/LeafViews.swift` | Address-book row call buttons (~L1612) and family-contact buttons route the chain. |
| `ios/ElderlyAssistant/Services/Intents/MethodResolver.swift` | The global-default step becomes the settings primary, mapped `CallApp`→`CallMethod` by call type. |
| **NEW** pure-static feasibility resolver file | The house-seam pattern of `resolvedCallChannel`; `canOpenURL` injected as a closure for tests. |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | New ne/en strings. |
| Tests: `ios/ElderlyAssistantTests/Services/Voice/CallChannelResolutionTests.swift` (chain matrix), `ios/ElderlyAssistantTests/Services/Intents/MethodResolverTests.swift` | Settings persistence, confirmation-prompt wording, picker UI. |

The surface table above is the scaffold brief's mapping — the planning input for requirements/design, referenced here rather than re-derived.

## Success Criteria & Completion Gate

Success:

- Calls never dead-end: zero dead-end call attempts when the primary is infeasible — the call completes via the fallback with a spoken announcement naming the actually-routed channel.
- The spoken confirmation names the routed channel (e.g. "Messenger isn't available — call Syanu via WhatsApp, okay?") and the override protocol still works unchanged.
- Primary and Fallback dialers are configurable in Settings and persist.
- Every call path routes the chain: address-book and family-contact buttons, missed-call dial-back, voice-initiated calls.

Completion gate — DV-* device validation on the reference device (Anzaan), the DV pattern of prior shipped features, recorded with the feature spec:

- DV-1 — Settings: Primary + Fallback pickers persist across relaunch (`secondaryCallApp` next to `defaultCallApp`).
- DV-2 — Primary infeasible (Messenger, no handle on file) → call completes via the fallback with the spoken announcement naming the routed channel.
- DV-3 — WhatsApp not installed (`canOpenURL` false) → chain lands on the fallback/GSM with the announcement; a launch failure is announced via the existing spoken-outcome lane (no silent failure).
- DV-4 — `secondary == primary` dedupes; both primary and secondary infeasible → `phone` is attempted; zero dead ends.
- DV-5 — Override preserved: "होइन, फोन नै गर" still switches to a phone call.
- DV-6 — All call paths route the chain: address-book row, family-contact, missed-call dial-back, voice-initiated call (MethodResolver global-default).
- DV-7 — ne/en copy: pickers, confirmation, and announcement strings localized; spoken language matches the session.

## Open Decisions

**None.** The design is approved and frozen (owner sign-off 2026-10-12; reference above), including secondary defaulting to GSM, Messenger feasibility as "handle on file", and the reuse of the existing confirmation flow. The requirements/design phases elaborate the frozen design; they do not re-open it. If the design doc has not yet been committed to the feature branch when requirements starts, obtaining it is a precondition (blocker to elaborate against), not an open decision.
