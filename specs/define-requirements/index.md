# Requirements — Call Dialer Primary/Secondary

Feature: `call-dialer-primary-secondary` (worktree branch `feat/call-dialer-primary-secondary`,
worktree `elderly-ai-assistant-call-dialer-primary-secondary`).
Status: **submitted for owner HIL approval** (risk tier T1, per the feature workflow's
`define-requirements` task); no owner amendment is recorded at requirements time — the locked
snapshot in `define-requirements.lock.yaml` (produced after owner sign-off) is the
drift-detection baseline.
Task: `define-requirements`, agent `ba`, contract `requirements_doc` + `requirements_lock`.
Date: 2026-10-12.
Frozen design (the feature brief, owner-approved 2026-10-12):
`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`.

## Summary

- Functional requirements: **19** (`FR-CDP-001` … `FR-CDP-019`)
- Non-functional requirements: **10** (`NFR-CDP-001` … `NFR-CDP-010`)
- Acceptance scenarios: **83** (56 across the FRs, 27 across the NFRs)
- Areas covered: Settings (Primary dialer, Fallback dialer, persistence), Channel Feasibility
  (Messenger handle-on-file, WhatsApp local probe, FaceTime/phone always feasible), Chain
  Resolution (chain rules, `fellBackFrom` provenance, preferred input), Call Paths (address-book
  and family-contact buttons, missed-call dial-back, announcements), Voice Path (MethodResolver
  global default, spoken confirmation, override protocol), Launch / Recovery (launch-fail hop),
  Localisation, Safety Boundary / Regression, Validation / Completion Gate. NFR categories:
  Reliability/Safety, Privacy, Privacy/Security, Performance, Reliability (Persistence),
  Accessibility, Localisation, Reliability/Testability, Reliability (Regression), Compliance.
- Feature scope: two Settings pickers — **Primary dialer** (`defaultCallApp`) and **Fallback
  dialer** (new `secondaryCallApp`, default `.phone`) over the four channels (`faceTime`,
  `phone`, `messenger`, `whatsApp`) — feeding a feasibility-aware chain **preferred → secondary →
  phone (GSM hard floor), dedupe on equal picks, each channel attempted at most once, never
  dead-ends**; the chain runs in every call path (address-book + family-contact buttons,
  missed-call dial-back, voice-initiated calls through MethodResolver's global-default step,
  which becomes the settings primary mapped `CallApp → CallMethod` by call type); feasibility is
  local-only (Messenger ⇔ handle on file, never gated on app-installed; WhatsApp ⇔
  `canOpenURL("whatsapp://")` via an injected closure; FaceTime/phone always feasible); the
  existing multi-turn confirmation is reused exactly, with the fallback resolved **before** the
  spoken confirmation, which names the actually-routed channel and discloses the skip; routing
  is automatic with a spoken announcement (no ask-before-fallback), launch failures hop down the
  chain and are announced via the existing spoken-outcome lane (never silent); new ne/en strings
  in `Localizable.xcstrings`; completion is the DV-1..7 device-validation gate on Anzaan.
- Primary sources of truth: the **frozen design**
  (`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — §1–§9, owner
  Decisions 1–5, non-goals, risks); the **feature constitution**
  (`specs/call-dialer-primary-secondary/constitution.md` — Purpose & Scope, Channel Resolution &
  Feasibility Contract, Safety & Compliance Delta, Feature Constraints 1–12, Integration
  Surfaces, Success Criteria, DV-1..7 completion gate, "Open Decisions: **None**"); the **workflow
  file** (`.ai-sdd/workflows/call-dialer-primary-secondary.yaml` — scope comment, security
  focus); the **project constitution** (`constitution.md` — Architecture Constraints 1–6,
  Standards, Release gates); the project **stakeholder brief** (`requirements.md`, read-only).
- Read-only stakeholder brief: `requirements.md` — it does not address dialer preferences, so no
  supersession is needed. Its §1.4 Messenger call-intent clauses (FR-016…FR-019) are the upstream
  context this feature makes resilient (initiation gains a guaranteed attemptable channel), and
  its §4 Post-MVP "WhatsApp integration" line was already overtaken by the shipped WhatsApp chat
  surfaces in `CallLinks` that this feature's feasibility probe now gates — this feature extends
  the shipped surfaces rather than re-opening the placement.

## Contents

- [FR/index.md](FR/index.md) — functional requirements (19 files, `FR-CDP-001` … `FR-CDP-019`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (10 files, `NFR-CDP-001` …
  `NFR-CDP-010`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- `../define-requirements.lock.yaml` — locked snapshot with per-requirement content hashes (the
  `requirements_lock` contract artifact; produced after the T1 HIL owner sign-off)

Note: the `FR/` and `NFR/` folders also still contain the previously shipped
live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`), profile-interview (`FR-PI-*`, `NFR-PI-*`),
spotify-music-integration (`FR-SP-*`, `NFR-SP-*`) and multi-turn-conversation (`FR-MTC-*`,
`NFR-MTC-*`) requirement files, left in place untouched; the indexes on this page and the lock
cover the `call-dialer-primary-secondary` set only.

### Functional requirements

Settings and persistence: [FR-CDP-001](FR/FR-CDP-001-primary-dialer-setting.md),
[FR-CDP-002](FR/FR-CDP-002-fallback-dialer-setting.md),
[FR-CDP-003](FR/FR-CDP-003-secondary-call-app-persistence.md) ·
Channel feasibility: [FR-CDP-004](FR/FR-CDP-004-messenger-feasibility-handle-on-file.md),
[FR-CDP-005](FR/FR-CDP-005-whatsapp-feasibility-installed-probe.md),
[FR-CDP-006](FR/FR-CDP-006-facetime-and-phone-always-feasible.md) ·
Chain resolution: [FR-CDP-007](FR/FR-CDP-007-chain-preferred-secondary-phone.md),
[FR-CDP-008](FR/FR-CDP-008-fellbackfrom-attempt-order.md),
[FR-CDP-009](FR/FR-CDP-009-explicit-pick-wins-as-preferred.md) ·
Tap paths: [FR-CDP-010](FR/FR-CDP-010-tap-buttons-route-the-chain.md),
[FR-CDP-011](FR/FR-CDP-011-missed-call-dial-back-routes-the-chain.md) ·
Voice path: [FR-CDP-012](FR/FR-CDP-012-voice-global-default-settings-primary.md),
[FR-CDP-013](FR/FR-CDP-013-fallback-before-spoken-confirmation.md),
[FR-CDP-014](FR/FR-CDP-014-override-protocol-preserved.md) ·
Launch and announcements: [FR-CDP-015](FR/FR-CDP-015-launch-fail-fallback-announced.md),
[FR-CDP-016](FR/FR-CDP-016-automatic-routing-with-announcement.md) ·
Localisation and preserved behaviours: [FR-CDP-017](FR/FR-CDP-017-localisation-new-strings.md),
[FR-CDP-018](FR/FR-CDP-018-preserved-behaviours.md) ·
Completion gate: [FR-CDP-019](FR/FR-CDP-019-device-validation-completion-gate.md)

### Non-functional requirements

[NFR-CDP-001](NFR/NFR-CDP-001-chain-never-dead-ends.md) never-dead-end matrix ·
[NFR-CDP-002](NFR/NFR-CDP-002-local-probes-no-new-egress.md) local-only probes ·
[NFR-CDP-003](NFR/NFR-CDP-003-log-safety.md) log safety ·
[NFR-CDP-004](NFR/NFR-CDP-004-fallback-resolution-latency.md) latency budget ·
[NFR-CDP-005](NFR/NFR-CDP-005-persistence-round-trip.md) persistence round-trip ·
[NFR-CDP-006](NFR/NFR-CDP-006-picker-accessibility.md) picker accessibility ·
[NFR-CDP-007](NFR/NFR-CDP-007-localisation-completeness.md) localisation completeness ·
[NFR-CDP-008](NFR/NFR-CDP-008-deterministic-testability.md) deterministic testability ·
[NFR-CDP-009](NFR/NFR-CDP-009-no-regression-shipped-call-paths.md) no regression ·
[NFR-CDP-010](NFR/NFR-CDP-010-compliance-and-release-gates.md) compliance and release gates

## Open decisions

**None.** The feature constitution records "Open Decisions: **None**" — the design is approved
and frozen (owner sign-off 2026-10-12), including secondary defaulting to GSM, Messenger
feasibility as "handle on file", and the reuse of the existing confirmation flow. This
requirements pass found **no new owner-level ambiguity**: every behaviour it binds traces to the
frozen design, the feature constitution or the project constitution. Items the design explicitly
leaves to the design phase (exact user-facing copy beyond the named keys, the tap-path
announcement's trigger point, the launch-fail observation point, the resolver's file placement)
are recorded as **assumptions / design inputs** below — not as decisions re-opened, and not
silently resolved.

### Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list belongs in the lock file (`assumptions`) when the lock is produced.

- The frozen design doc is present and committed on the feature branch at requirements time
  (precondition of the constitution satisfied).
- Integration anchors were spot-verified against the worktree source at requirements time:
  `defaultCallApp` property `AppCoordinator.swift:330-335` and its restore default
  (`? .phone`) at `:2851-2853`; `resolvedCallChannel` `:2099-2105`; `resolvedMissedCallChannel`
  `:8382-8390`; `missedCallDialAction` `:8423-8443`; `dialBackMissedCall` `:8457+`;
  `requestCallConfirmation` `:7587-7647` (Messenger-no-handle gate at `:7620-7623`);
  `handleCallConfirmationOverride` `:7656-7686` (override no-handle gate at `:7665-7669`);
  `confirmationPrompt` `:7688-7707`; `MethodResolver` step 4 `MethodResolver.swift:74-78`;
  `CallApp` enum `CallLinks.swift:66-84` with the open outcomes (`MessengerOutcome`
  `openedThread`/`fellBackToWeb`/`invalidHandle` at `:145-157`, `FaceTimeOutcome.unavailable`
  at `:114-123`); `FamilyContact.resolvedAudioApp` `FamilyContactStore.swift:162-164`;
  `CallingSettingsView` four-channel rows `:22-77`; `LeafViews` row channel state ~`:1612`;
  the emergency path via `NotifyChannel.resolve` at `AppCoordinator.swift:6464-6468`;
  existing catalog keys (`settings.calling.title`, `router.call.*`, `call.announce.*`) —
  the five new keys were confirmed absent from `Localizable.xcstrings` at requirements time.
- Exact user-facing copy (section titles' wording, the fallback disclosure sentence, the two
  announcements) is design/catalog-time copy: the design's example ("Messenger isn't available —
  call Syanu via WhatsApp, okay?") is illustrative; the **keys** and the content they must carry
  (routed channel, skipped channel, contact name) are binding (FR-CDP-013/016/017).
- The tap-path `call.announce.fallbackRouted` announcement's exact trigger point (with the open)
  is the design's to fix at design-l1; its existence, routed-channel content and ne/en key are
  binding (FR-CDP-016).
- The ≤ 100 ms p95 added-latency budget (NFR-CDP-004) is this requirement set's measurement
  threshold elaborating the design's "probes run at call time, user-paced"; design-l1 may refine
  the number but not weaken the never-dead-end / never-silent guarantees.
- The `canOpenURL` probe's staleness is an accepted residual risk (design Risks); the launch-fail
  hop covers it, and no caching requirement is implied.
- The chain resolver's file placement/name (`CallChannelChain.route(preferred:secondary:feasibility:)`
  with `Result.fellBackFrom`) is the design's frozen shape; requirements bind behaviour and the
  pure-static, closure-injected properties — exact placement is design's.
- The existing audio/video button vocabulary gates (`supportsAudio` / `supportsVideo`, FaceTime
  excluded from audio buttons and dial-back) are preserved; the feature changes only the
  global-default/secondary resolution inside them.
- Emergency-contact resolution (`NotifyChannel.resolve`-based) is **not** rewired to the chain
  (non-goal); FR-CDP-018/FR-CDP-011 pin its no-change.
- The full-bundle unit baseline is pre-existing red (house practice); scoped `-only-testing`
  suites are the honest gate (NFR-CDP-008), with baseline failures recorded rather than silently
  included or excluded.
- DV-1..7 are the constitution's completion gate on the reference device (Anzaan), executed at
  `final-sign-off` (T2 + HIL) — FR-CDP-019.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the design's
non-goals and the workflow scope comment's explicit non-goals) — recorded so nothing is silently
half-built:

| Non-goal | Why it is stated |
|---|---|
| A dedicated `CallRouter` service | The feature extends the existing resolution seams only (`resolvedCallChannel` / `resolvedMissedCallChannel`, MethodResolver's global-default step, `requestCallConfirmation`) — no new routing service (constitution Constraint 7; design non-goals). |
| Per-contact primary/secondary storage | Per-contact and family picks keep winning as the **input** to the chain; the chain itself is settings-level (constitution Constraint 5; FR-CDP-009). |
| Emergency-contact semantics changes | Emergency-contact resolution and escalation are untouched; the chain/probes/announcements never wrap or delay them (design non-goals; FR-CDP-018). |
| A new dialogue flow | The existing multi-turn confirmation is reused exactly; no new question kind, state or prompt sequence (design Goal 4 / Decision 5; FR-CDP-013/018). |
| Any new network, data, identity or privacy surface | Feasibility probes are local (`canOpenURL`, address-book handle check); no new egress, permission, store or collection (constitution Constraint 8; NFR-CDP-002). |
| Changes to the just-shipped voice pipeline beyond the named MethodResolver seam | Regression context PRs #161–#168: the chain replaces only the single Messenger hard-rule and the hardcoded voice default; do not refactor beyond the named seams (constitution Constraint 7; NFR-CDP-009). |
| The weak/empty edge of the brief's open items | No Android scope, no new compliance regime, no permission widenings, no analytics/telemetry additions (NFR-CDP-002/010). |

## Related

- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Feature constitution: [`../call-dialer-primary-secondary/constitution.md`](../call-dialer-primary-secondary/constitution.md)
- Feature workflow (scope comment + security focus): [`../../.ai-sdd/workflows/call-dialer-primary-secondary.yaml`](../../.ai-sdd/workflows/call-dialer-primary-secondary.yaml)
- Frozen design (the feature brief): [`../../docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`](../../docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md)
