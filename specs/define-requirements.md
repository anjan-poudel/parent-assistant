# Requirements — Call Dialer Primary/Secondary (feature)

**Project:** Elderly AI Assistant · **Feature:** `call-dialer-primary-secondary` ·
**Branch:** `feat/call-dialer-primary-secondary` (worktree
`elderly-ai-assistant-call-dialer-primary-secondary`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-12 · **Status:** submitted for owner HIL approval (risk tier T1, per the feature
workflow's `define-requirements` task); no owner amendment recorded at requirements time — the
locked snapshot in `define-requirements.lock.yaml` (produced after the T1 HIL owner sign-off) is
the drift-detection baseline.
**Frozen design (the feature brief, owner-approved 2026-10-12):**
`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `review-implementation`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-CDP-NNN` / `NFR-CDP-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`) and multi-turn-conversation used (`FR-MTC-NNN`). One
file per requirement; every requirement carries at least one Gherkin scenario (83 scenarios across
29 requirements), and every safety-relevant requirement carries a failure or edge scenario.

**Relationship to the frozen design.** This set elaborates the owner-approved, frozen design
(2026-10-12) — it does not re-open the design's "Decisions (owner-approved)" 1–5, its non-goals or
its risks. Where the design fixes mechanics (the chain's shape and `fellBackFrom`, the feasibility
contract, the reuse of the existing confirmation, the key names), the requirements bind them; where
the design leaves detail to design-l1 (exact copy wording, the tap-path announcement's trigger
point, the launch-fail observation point, file placement), that is recorded as an assumption — a
design input, not a re-opened decision.

**Relationship to the stakeholder brief (`requirements.md`).** No supersession is needed: the
brief does not address dialer preferences. Its §1.4 Messenger call-initiation clauses
(FR-016…FR-019) are the upstream context this feature makes resilient — initiation gains a
guaranteed attemptable channel — without changing the documented surfaces. Its §4 Post-MVP
"WhatsApp integration" line was already overtaken by the shipped WhatsApp chat surfaces in
`CallLinks` that this feature's feasibility probe now gates; this feature extends the shipped
surfaces rather than re-opening the placement.

## Summary

- **Functional requirements: 19** (`FR-CDP-001` … `FR-CDP-019`)
- **Non-functional requirements: 10** (`NFR-CDP-001` … `NFR-CDP-010`)
- **Acceptance scenarios: 83** (56 across the FRs, 27 across the NFRs)
- **Areas covered:** Settings (Primary dialer, Fallback dialer, persistence), Channel Feasibility
  (Messenger handle-on-file, WhatsApp local probe, FaceTime/phone always feasible), Chain
  Resolution (chain rules, `fellBackFrom` provenance, preferred input), Call Paths (address-book
  and family-contact buttons, missed-call dial-back, announcements), Voice Path (MethodResolver
  global default, spoken confirmation, override protocol), Launch / Recovery (launch-fail hop),
  Localisation, Safety Boundary / Regression, Validation / Completion Gate. NFR categories:
  Reliability/Safety, Privacy, Privacy/Security, Performance, Reliability (Persistence),
  Accessibility, Localisation, Reliability/Testability, Reliability (Regression), Compliance.
- **Feature scope:** two Settings pickers — **Primary dialer** (`defaultCallApp`) and **Fallback
  dialer** (new `secondaryCallApp`, default `.phone`) over the four channels (`faceTime`, `phone`,
  `messenger`, `whatsApp`) — feeding a feasibility-aware chain **preferred → secondary → phone
  (GSM hard floor), dedupe on equal picks, each channel attempted at most once, never dead-ends**;
  the chain runs in every call path (address-book + family-contact buttons, missed-call dial-back,
  voice-initiated calls through MethodResolver's global-default step, which becomes the settings
  primary mapped `CallApp → CallMethod` by call type); feasibility is local-only (Messenger ⇔
  handle on file, never gated on app-installed; WhatsApp ⇔ `canOpenURL("whatsapp://")` via an
  injected closure; FaceTime/phone always feasible); the existing multi-turn confirmation is
  reused exactly, with the fallback resolved **before** the spoken confirmation, which names the
  actually-routed channel and discloses the skip; routing is automatic with a spoken announcement
  (no ask-before-fallback), launch failures hop down the chain and are announced via the existing
  spoken-outcome lane (never silent); new ne/en strings in `Localizable.xcstrings`; completion is
  the DV-1..7 device-validation gate on Anzaan.
- **Primary sources of truth:** the frozen design
  (`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — §1–§9, owner
  Decisions 1–5, non-goals, risks); the feature constitution
  (`specs/call-dialer-primary-secondary/constitution.md` — Purpose & Scope, Channel Resolution &
  Feasibility Contract, Safety & Compliance Delta, Feature Constraints 1–12, Integration Surfaces,
  Success Criteria, DV-1..7 completion gate, "Open Decisions: **None**"); the workflow file
  (`.ai-sdd/workflows/call-dialer-primary-secondary.yaml` — scope comment, security focus);
  the project constitution (`constitution.md` — Architecture Constraints 1–6, Standards, Release
  gates).
- **Read-only stakeholder brief:** `requirements.md` (see the relationship note above).

## Contents

- [`define-requirements/index.md`](define-requirements/index.md) — top-level feature index
- [`define-requirements/FR/index.md`](define-requirements/FR/index.md) — functional requirement
  list (19 files: `define-requirements/FR/FR-CDP-NNN-*.md`)
- [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md) — non-functional
  requirement list (10 files: `define-requirements/NFR/NFR-CDP-NNN-*.md`)
- `define-requirements.lock.yaml` — locked snapshot with per-requirement content hashes (contract
  `requirements_lock`; produced after the T1 HIL owner sign-off)
- Sections below: [Functional requirements](#functional-requirements) ·
  [Non-functional requirements](#non-functional-requirements) ·
  [Open decisions](#open-decisions) · [Out of scope](#out-of-scope) ·
  [How this set is verified downstream](#how-this-set-is-verified-downstream)

The `define-requirements/FR/` and `define-requirements/NFR/` folders also still contain the
previously shipped live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`), profile-interview
(`FR-PI-*`, `NFR-PI-*`), spotify-music-integration (`FR-SP-*`, `NFR-SP-*`) and
multi-turn-conversation (`FR-MTC-*`, `NFR-MTC-*`) requirement files, left in place untouched; the
indexes, this document and the lock cover the `call-dialer-primary-secondary` set only.

### Requirement index

| ID | Title | Area / Category | Priority | File |
|----|-------|-----------------|----------|------|
| [FR-CDP-001](define-requirements/FR/FR-CDP-001-primary-dialer-setting.md) | Primary dialer setting — four channels, persisted | Settings / Primary Dialer | MUST | `FR-CDP-001-primary-dialer-setting.md` |
| [FR-CDP-002](define-requirements/FR/FR-CDP-002-fallback-dialer-setting.md) | Fallback dialer setting — four channels, equal picks legal | Settings / Fallback Dialer | MUST | `FR-CDP-002-fallback-dialer-setting.md` |
| [FR-CDP-003](define-requirements/FR/FR-CDP-003-secondary-call-app-persistence.md) | `secondaryCallApp` persistence seam with GSM default | Settings / Persistence | MUST | `FR-CDP-003-secondary-call-app-persistence.md` |
| [FR-CDP-004](define-requirements/FR/FR-CDP-004-messenger-feasibility-handle-on-file.md) | Messenger feasibility — handle on file only | Channel Feasibility / Messenger | MUST | `FR-CDP-004-messenger-feasibility-handle-on-file.md` |
| [FR-CDP-005](define-requirements/FR/FR-CDP-005-whatsapp-feasibility-installed-probe.md) | WhatsApp feasibility — local installed-app probe via injected closure | Channel Feasibility / WhatsApp | MUST | `FR-CDP-005-whatsapp-feasibility-installed-probe.md` |
| [FR-CDP-006](define-requirements/FR/FR-CDP-006-facetime-and-phone-always-feasible.md) | FaceTime and phone are always feasible — phone is the GSM hard floor | Channel Feasibility / GSM Hard Floor | MUST | `FR-CDP-006-facetime-and-phone-always-feasible.md` |
| [FR-CDP-007](define-requirements/FR/FR-CDP-007-chain-preferred-secondary-phone.md) | Chain resolver — preferred → secondary → phone, dedupe, at-most-once, never dead-ends | Chain Resolution / Core | MUST | `FR-CDP-007-chain-preferred-secondary-phone.md` |
| [FR-CDP-008](define-requirements/FR/FR-CDP-008-fellbackfrom-attempt-order.md) | `fellBackFrom` carries skipped channels in attempt order | Chain Resolution / Announcement Data | MUST | `FR-CDP-008-fellbackfrom-attempt-order.md` |
| [FR-CDP-009](define-requirements/FR/FR-CDP-009-explicit-pick-wins-as-preferred.md) | Preferred input — an explicit per-contact/family pick wins as the chain's preferred | Chain Resolution / Input | MUST | `FR-CDP-009-explicit-pick-wins-as-preferred.md` |
| [FR-CDP-010](define-requirements/FR/FR-CDP-010-tap-buttons-route-the-chain.md) | Address-book and family-contact call buttons route the chain | Call Paths / Tap Buttons | MUST | `FR-CDP-010-tap-buttons-route-the-chain.md` |
| [FR-CDP-011](define-requirements/FR/FR-CDP-011-missed-call-dial-back-routes-the-chain.md) | Missed-call dial-back routes the chain | Call Paths / Missed-Call Dial-back | MUST | `FR-CDP-011-missed-call-dial-back-routes-the-chain.md` |
| [FR-CDP-012](define-requirements/FR/FR-CDP-012-voice-global-default-settings-primary.md) | Voice path — MethodResolver global default becomes the settings primary, mapped by call type | Voice Path / Method Resolution | MUST | `FR-CDP-012-voice-global-default-settings-primary.md` |
| [FR-CDP-013](define-requirements/FR/FR-CDP-013-fallback-before-spoken-confirmation.md) | Fallback resolves before the spoken confirmation; the prompt names the routed channel | Voice Path / Spoken Confirmation | MUST | `FR-CDP-013-fallback-before-spoken-confirmation.md` |
| [FR-CDP-014](define-requirements/FR/FR-CDP-014-override-protocol-preserved.md) | Override protocol and near-miss disclosure preserved unchanged | Voice Path / Override Protocol | MUST | `FR-CDP-014-override-protocol-preserved.md` |
| [FR-CDP-015](define-requirements/FR/FR-CDP-015-launch-fail-fallback-announced.md) | Launch-fail fallback (best-effort), announced via the existing spoken-outcome lane | Launch / Recovery | MUST | `FR-CDP-015-launch-fail-fallback-announced.md` |
| [FR-CDP-016](define-requirements/FR/FR-CDP-016-automatic-routing-with-announcement.md) | Automatic routing with a spoken announcement — no ask-before-fallback | Call Paths / Announcement | MUST | `FR-CDP-016-automatic-routing-with-announcement.md` |
| [FR-CDP-017](define-requirements/FR/FR-CDP-017-localisation-new-strings.md) | Localisation — new ne/en strings; spoken language matches the session | Localisation | MUST | `FR-CDP-017-localisation-new-strings.md` |
| [FR-CDP-018](define-requirements/FR/FR-CDP-018-preserved-behaviours.md) | Preserved behaviours — no new dialogue flow, emergency semantics untouched, no silent failures | Safety Boundary / Regression | MUST | `FR-CDP-018-preserved-behaviours.md` |
| [FR-CDP-019](define-requirements/FR/FR-CDP-019-device-validation-completion-gate.md) | DV-1..7 device validation recorded and passed (completion gate) | Validation / Completion Gate | MUST | `FR-CDP-019-device-validation-completion-gate.md` |
| [NFR-CDP-001](define-requirements/NFR/NFR-CDP-001-chain-never-dead-ends.md) | The chain never dead-ends — zero dead ends across the exhaustive configuration matrix | Reliability / Safety | MUST | `NFR-CDP-001-chain-never-dead-ends.md` |
| [NFR-CDP-002](define-requirements/NFR/NFR-CDP-002-local-probes-no-new-egress.md) | Feasibility probes are local — no new network, data, identity or privacy surface | Privacy | MUST | `NFR-CDP-002-local-probes-no-new-egress.md` |
| [NFR-CDP-003](define-requirements/NFR/NFR-CDP-003-log-safety.md) | Log safety — numbers, handles and announcement content never reach logs beyond the existing policy | Privacy / Security | MUST | `NFR-CDP-003-log-safety.md` |
| [NFR-CDP-004](define-requirements/NFR/NFR-CDP-004-fallback-resolution-latency.md) | Fallback-resolution latency budget — local probes at call time, user-paced | Performance | MUST | `NFR-CDP-004-fallback-resolution-latency.md` |
| [NFR-CDP-005](define-requirements/NFR/NFR-CDP-005-persistence-round-trip.md) | `secondaryCallApp` persistence round-trip reliability | Reliability (Persistence) | MUST | `NFR-CDP-005-persistence-round-trip.md` |
| [NFR-CDP-006](define-requirements/NFR/NFR-CDP-006-picker-accessibility.md) | Accessibility of the Primary and Fallback dialer pickers | Accessibility | MUST | `NFR-CDP-006-picker-accessibility.md` |
| [NFR-CDP-007](define-requirements/NFR/NFR-CDP-007-localisation-completeness.md) | Localisation completeness — 100% ne/en parity for every new string | Localisation | MUST | `NFR-CDP-007-localisation-completeness.md` |
| [NFR-CDP-008](define-requirements/NFR/NFR-CDP-008-deterministic-testability.md) | Deterministic testability under the scoped-suite gate | Reliability / Testability | MUST | `NFR-CDP-008-deterministic-testability.md` |
| [NFR-CDP-009](define-requirements/NFR/NFR-CDP-009-no-regression-shipped-call-paths.md) | No regression to the shipped voice pipeline, emergency and dial-back paths | Reliability (Regression) | MUST | `NFR-CDP-009-no-regression-shipped-call-paths.md` |
| [NFR-CDP-010](define-requirements/NFR/NFR-CDP-010-compliance-and-release-gates.md) | Compliance, review and release gates; DV-1..7 acceptance | Compliance | MUST | `NFR-CDP-010-compliance-and-release-gates.md` |

## Functional requirements

### FR-CDP-001: Primary dialer setting — four channels, persisted

#### Metadata
- **Area:** Settings / Primary Dialer
- **Priority:** MUST
- **Source:** Frozen design §1 ("`CallingSettingsView` renders two sections: **Primary dialer** and **Fallback dialer**, each the existing four-channel row pattern") and Goal 1; feature constitution "In scope" bullet 1 and "Integration Surfaces" (`CallingSettingsView.swift` — "New Primary dialer + Fallback dialer sections/pickers"); workflow scope comment ("two settings sections (Primary dialer, Fallback dialer) over the 4 channels ... `defaultCallApp` = primary"); DV-1.

#### Description
Calling Settings (the existing `CallingSettingsView`, reached under `settings.calling.title`) **must** present a **Primary dialer** section letting the user choose exactly one of the four channels — FaceTime, phone (GSM), Messenger, WhatsApp — using the existing selectable-row pattern (app-name label + selected-state checkmark; the existing `app.name.*` catalog keys are reused so the option labels agree with every other surface in both scripts).

Selecting a channel **must** bind the coordinator's existing `defaultCallApp` preference (the existing `@Published` + UserDefaults seam, key `defaultCallApp`; `didSet` persists, the single init-time restore assigns directly, and an absent/unknown stored value resolves to `.phone`). The selection **must** persist across relaunch. The section title **must** come from the new catalog key `settings.calling.primaryTitle` (ne/en — FR-CDP-017).

This pick is the chain's preferred input whenever a call target has no explicit per-contact/family pick (FR-CDP-009).

#### Acceptance criteria

```gherkin
Feature: Primary dialer setting

  Scenario: The Primary dialer section renders the four channels with the current pick selected
    Given the user opens Settings, Calling
    Then a "Primary dialer" section is shown with the four channels: FaceTime, phone, Messenger, WhatsApp
    And each row shows the channel's app-name label
    And the row matching the current defaultCallApp shows the selected state

  Scenario: Selecting a primary channel persists across relaunch
    Given the Primary dialer is FaceTime
    When the user selects WhatsApp
    Then the coordinator's defaultCallApp is whatsApp
    And after the app is relaunched the WhatsApp row still shows the selected state
    And the preference is the global default used by call resolution
```

#### Related
- FR: FR-CDP-002 (fallback picker), FR-CDP-003 (secondary persistence seam), FR-CDP-009 (preferred input), FR-CDP-012 (voice-path mapping)
- NFR: NFR-CDP-005 (persistence round-trip), NFR-CDP-006 (picker accessibility), NFR-CDP-007 (localisation completeness)

### FR-CDP-002: Fallback dialer setting — four channels, equal picks legal

#### Metadata
- **Area:** Settings / Fallback Dialer
- **Priority:** MUST
- **Source:** Frozen design §1 ("`CallingSettingsView` renders two sections ... **Fallback dialer** ... `secondary == primary` is legal and dedupes at routing time") and Goal 1; feature constitution "In scope" bullet 1 and Feature Constraint 4 ("`secondary == primary` is allowed and routes with dedupe"); workflow scope comment; DV-1, DV-4.

#### Description
Calling Settings **must** present a **Fallback dialer** section beside the Primary dialer section, using the same four-channel selectable-row pattern, letting the user choose exactly one fallback channel. Selecting a channel **must** bind a new coordinator preference `secondaryCallApp` (FR-CDP-003 carries its persistence contract).

Rules:
- Choosing the same channel as the primary is legal: both sections may show the same selection and the app **must not** block, warn against, or silently alter an equal pick — routing dedupes instead (FR-CDP-007; each channel attempted at most once).
- Selecting in one section **must not** change the other section's selection (`defaultCallApp` and `secondaryCallApp` are independent).
- The section title **must** come from the new catalog key `settings.calling.secondaryTitle` (ne/en — FR-CDP-017), and the option labels reuse the existing `app.name.*` keys.

#### Acceptance criteria

```gherkin
Feature: Fallback dialer setting

  Scenario: The Fallback dialer section renders and persists a selection
    Given the user opens Settings, Calling
    Then a "Fallback dialer" section is shown with the four channels
    When the user selects phone as the fallback
    Then secondaryCallApp is phone
    And after the app is relaunched the phone row still shows the selected state

  Scenario: An equal primary and fallback pick is accepted
    Given the user selects Messenger as the primary
    When the user selects Messenger as the fallback
    Then both sections show Messenger as selected
    And no error, warning or auto-correction is shown
    And call resolution dedupes the equal channels at routing time

  Scenario: The two pickers are independent
    Given the primary is FaceTime and the fallback is phone
    When the user changes the fallback to WhatsApp
    Then secondaryCallApp is whatsApp
    And defaultCallApp is still faceTime
```

#### Related
- FR: FR-CDP-001 (primary picker), FR-CDP-003 (persistence), FR-CDP-007 (dedupe in the chain)
- NFR: NFR-CDP-005 (persistence round-trip), NFR-CDP-006 (picker accessibility), NFR-CDP-007 (localisation completeness)

### FR-CDP-003: `secondaryCallApp` persistence seam with GSM default

#### Metadata
- **Area:** Settings / Persistence
- **Priority:** MUST
- **Source:** Frozen design §1 ("`AppCoordinator` gains `secondaryCallApp: CallApp` next to `defaultCallApp` — same `@Published` + UserDefaults pattern, key `secondaryCallApp`, **default `.phone`**"); feature constitution "In scope" bullet 1 and Feature Constraint 4; workflow `design-l1` scope ("persistence for existing installs (secondaryCallApp absent → GSM)"); DV-1.

#### Description
`AppCoordinator` **must** expose `secondaryCallApp: CallApp` next to `defaultCallApp`, using the same persistence pattern the primary preference uses (the existing house seam: a `@Published` property whose `didSet` writes to `UserDefaults` under key `secondaryCallApp`, with the single init-time restore assigning directly so `didSet` does not fire there — `AppCoordinator.swift:330-335, 2851-2853`).

Binding rules:
- **Default is GSM**: a fresh install — and an existing install upgrading where the key is absent — **must** resolve the fallback to `.phone` with no user action. An unrecognised stored raw value **must** also resolve to `.phone`, mirroring the existing `defaultCallApp` restore rule (`.flatMap(CallApp.init(rawValue:)) ?? .phone`).
- **Round-trip**: each of the four channels written through the Fallback dialer picker **must** read back identically after relaunch (NFR-CDP-005 carries the measurable target).
- **No cross-talk**: writing `secondaryCallApp` **must never** mutate `defaultCallApp`, and vice versa.

#### Acceptance criteria

```gherkin
Feature: Fallback dialer persistence

  Scenario: An install without a stored fallback resolves to GSM
    Given no value has ever been stored for secondaryCallApp (fresh install or an existing install upgrading)
    When the app launches
    Then secondaryCallApp is phone
    And call resolution treats GSM as the fallback channel

  Scenario: The fallback selection round-trips across relaunch for every channel
    Given the user selects a fallback channel in Calling Settings
    When the app is relaunched
    Then secondaryCallApp equals the selected channel
    And this holds for each of FaceTime, phone, Messenger and WhatsApp

  Scenario: An unrecognised stored value falls back to GSM
    Given the stored secondaryCallApp raw value is unrecognised
    When the app launches
    Then secondaryCallApp is phone
```

#### Related
- FR: FR-CDP-002 (the picker that writes this seam), FR-CDP-007 (the chain that reads it)
- NFR: NFR-CDP-005 (round-trip reliability target)

### FR-CDP-004: Messenger feasibility — handle on file only

#### Metadata
- **Area:** Channel Feasibility / Messenger
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`messenger` — handle on file for the target contact — **NOT** gated on the app being installed — the m.me web chat still connects, and shipped tap behavior is preserved") and Decision 3; feature constitution "Channel Resolution & Feasibility Contract" and Feature Constraint 2; DV-2.

#### Description
For a given target (family contact or address-book row), the `messenger` channel **must** be treated as feasible if and only if a usable handle is on file for that target — decided by the same normalization the opener uses (`CallLinks.messengerHandle`), so the feasibility gate and the opener can never disagree. The feasibility check **must not** consult whether the Messenger app is installed.

Binding consequences:
- With a usable handle, `messenger` stays feasible even when the app is absent — shipped tap behaviour is preserved and the existing open-time web-chat fallback (`fb-messenger://user-thread/` absent-app chain → `https://m.me/<handle>`, `fellBackToWeb`) still applies and is disclosed out loud.
- Without a usable handle, `messenger` is infeasible and the chain (FR-CDP-007) skips it. Today's single hard rule ("a `.messenger` result without a handle drops to `.phone`") becomes one case of the chain rather than a special rule.

#### Acceptance criteria

```gherkin
Feature: Messenger feasibility

  Scenario: A handle on file makes Messenger feasible
    Given the target contact has a usable Messenger handle on file
    When the channel chain resolves against this target
    Then messenger is treated as feasible
    And the chain's preferred channel is returned without a Messenger skip

  Scenario: No handle makes Messenger infeasible and the chain skips it
    Given the target contact has no usable Messenger handle
    When the channel chain resolves with messenger as the preferred channel
    Then messenger is not resolved as the routed channel
    And the chain attempts its next step (the fallback, then GSM)

  Scenario: An absent Messenger app does not make the channel infeasible
    Given the target contact has a usable handle on file
    And the Messenger app is not installed
    When the chain resolves
    Then messenger is still treated as feasible
    And a tap opening this channel keeps the shipped behaviour (the https://m.me web-chat fallback, disclosed out loud)
```

#### Related
- FR: FR-CDP-005 (WhatsApp probe), FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-010 (tap paths)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-002 (local-only feasibility)

### FR-CDP-005: WhatsApp feasibility — local installed-app probe via injected closure

#### Metadata
- **Area:** Channel Feasibility / WhatsApp
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`whatsApp` — app installed — `canOpenURL("whatsapp://")`, injected as a closure for tests — local probe only") and §3 (closure-injected feasibility); feature constitution "Channel Resolution & Feasibility Contract" and Feature Constraint 3 ("WhatsApp feasibility is the `canOpenURL` probe, injected as a closure so tests stub it deterministically"); DV-3.

#### Description
The `whatsApp` channel **must** be treated as feasible if and only if WhatsApp can be opened on this device, probed as `canOpenURL("whatsapp://")`. The scheme is already declared in `Info.plist` `LSApplicationQueriesSchemes`, so no plist change is required.

Binding rules:
- **Local probe only**: the check runs on-device at call time and performs no network I/O and launches no app.
- **Injected seam**: the probe **must** be supplied through injection (a closure/config seam) so tests stub it deterministically and the resolver stays free of platform calls (NFR-CDP-008).
- **Staleness accepted**: iOS may cache scheme availability; this is an accepted residual risk (design Risks) — the probe still runs at call time, user-paced, and the launch-fail hop (FR-CDP-015) covers the residual case.
- **Skip when infeasible**: when the probe is false, `whatsApp` is infeasible and the chain skips it (DV-3: WhatsApp not installed → the chain lands on the fallback/GSM with the announcement).

#### Acceptance criteria

```gherkin
Feature: WhatsApp feasibility

  Scenario: The probe reporting installed makes WhatsApp feasible
    Given the injected probe reports whatsapp:// can be opened
    When the channel chain resolves with whatsApp as the preferred channel
    Then whatsApp is treated as feasible
    And it can be returned as the routed channel

  Scenario: The probe reporting not installed makes WhatsApp infeasible and the chain skips it
    Given the injected probe reports whatsapp:// cannot be opened
    When the channel chain resolves with whatsApp preferred
    Then whatsApp is not resolved as the routed channel
    And the chain attempts its next step (the fallback, then GSM)

  Scenario: Probing is local — no network and no app launch
    Given a build exercising the feasibility probe
    When the chain resolves any target
    Then the probe performs no network request
    And the probe opens no app
```

#### Related
- FR: FR-CDP-004 (Messenger feasibility), FR-CDP-007 (the chain), FR-CDP-015 (launch-fail hop covering probe staleness)
- NFR: NFR-CDP-002 (no new egress), NFR-CDP-008 (deterministic testability)

### FR-CDP-006: FaceTime and phone are always feasible — phone is the GSM hard floor

#### Metadata
- **Area:** Channel Feasibility / GSM Hard Floor
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`faceTime` — always feasible"; "`phone` — always feasible — the GSM hard floor — terminal channel of the chain") and Goal 2; feature constitution Feature Constraint 1 ("GSM hard floor — no dead ends. `phone` is always feasible and is the chain's terminal channel."); DV-4.

#### Description
`faceTime` and `phone` **must** both be treated as feasible under all circumstances: no installation state, handle state, contact state or picker configuration can make them infeasible pre-flight.

`phone` (GSM, `tel:`) **must** be the chain's terminal channel — the always-feasible hard floor — so that whenever every other channel is infeasible or deduped away, resolution returns `.phone` and the call can still be attempted. This is the feature's core guarantee: no configuration of the pickers (including equal picks) may remove, reorder or make unreachable the floor.

Scope note: "always feasible" is the pre-flight contract only — FaceTime can still fail to open at launch (`FaceTimeOutcome.unavailable`); that residual is covered by the launch-fail hop (FR-CDP-015), not by marking the channel infeasible.

#### Acceptance criteria

```gherkin
Feature: Always-feasible channels and the GSM floor

  Scenario: The GSM floor is reachable whenever every other channel is infeasible
    Given the preferred channel is infeasible
    And the fallback channel is infeasible (or deduped into the same infeasible channel)
    When the chain resolves
    Then phone is the routed channel
    And the call can be attempted via tel:

  Scenario: FaceTime and phone are feasible regardless of app and handle state
    Given the target has no Messenger handle
    And WhatsApp is not installed
    When the chain resolves with a preferred channel of faceTime, or of phone
    Then the channel is treated as feasible and returned as routed

  Scenario: No picker configuration produces a resolution with no attemptable channel
    Given any pair of primary and fallback picks (including equal picks)
    And any feasibility state
    When the chain resolves
    Then it returns exactly one attemptable channel
    And phone is always reachable as the floor
```

#### Related
- FR: FR-CDP-007 (the chain that ends at the floor), FR-CDP-015 (launch-fail residual), FR-CDP-018 (emergency path untouched)
- NFR: NFR-CDP-001 (exhaustive never-dead-end matrix)

### FR-CDP-007: Chain resolver — preferred → secondary → phone, dedupe, at-most-once, never dead-ends

#### Metadata
- **Area:** Chain Resolution / Core
- **Priority:** MUST
- **Source:** Frozen design §3 ("Rules: attempt `preferred`; if infeasible, attempt `secondary` (skipped when equal); if that is infeasible too, `phone`. `phone` is always feasible, so the chain never dead-ends.") and Goal 2; feature constitution "Channel Resolution & Feasibility Contract" ("A channel is attempted at most once — `secondary == primary` is legal and simply dedupes. The chain **never dead-ends**") and Feature Constraints 1, 4; workflow scope comment; DV-4.

#### Description
Call-channel resolution **must** run a fixed three-step chain:

1. attempt the **preferred** channel (the explicit per-contact/family pick when present, else the settings primary — FR-CDP-009);
2. if infeasible, attempt the **settings secondary** (`secondaryCallApp`) — skipped when it equals the preferred channel (`secondary == primary` is legal and simply dedupes);
3. if that is infeasible too, resolve to **`phone`** (the always-feasible GSM floor, FR-CDP-006).

Binding properties:
- **Each channel is attempted at most once** — including the deduped equal pair.
- **Never dead-ends** — whatever the picker pair and the feasibility state, resolution returns a channel that can be attempted (NFR-CDP-001 measures this exhaustively).
- **Pure-static seam** — implemented in the design's new pure-static resolver (the design fixes the contract: `CallChannelChain.route(preferred:secondary:feasibility:)`, with `Feasibility` carrying `messengerHandleAvailable` + `whatsAppInstalled`), following the house-seam pattern of `resolvedCallChannel`: no coordinator state, no platform calls — so the full matrix is unit-testable without stubs (NFR-CDP-008).
- **Existing seams run it** — `resolvedCallChannel` / `resolvedMissedCallChannel` (and the voice-path mapping, FR-CDP-012) delegate to this one resolver rather than re-implementing the chain.

#### Acceptance criteria

```gherkin
Feature: Preferred to secondary to GSM chain

  Scenario: A feasible preferred channel is routed and the secondary is never attempted
    Given the preferred channel is feasible
    When the chain resolves
    Then the routed channel is the preferred channel
    And the secondary channel is not attempted

  Scenario: An infeasible preferred channel falls to the secondary
    Given the preferred channel is infeasible
    And the secondary channel is feasible and different
    When the chain resolves
    Then the routed channel is the secondary channel

  Scenario: Both channels infeasible fall to the GSM floor
    Given the preferred channel is infeasible
    And the secondary channel is infeasible
    When the chain resolves
    Then the routed channel is phone

  Scenario: An equal primary and fallback dedupes
    Given the preferred and secondary channels are the same channel
    And that channel is infeasible
    When the chain resolves
    Then the channel is attempted at most once
    And the routed channel is phone
```

#### Related
- FR: FR-CDP-004/005/006 (feasibility inputs), FR-CDP-008 (fellBackFrom output), FR-CDP-009 (preferred input), FR-CDP-013 (voice-path fallback timing)
- NFR: NFR-CDP-001 (never dead-ends, exhaustively), NFR-CDP-004 (latency budget), NFR-CDP-008 (deterministic matrix)

### FR-CDP-008: `fellBackFrom` carries skipped channels in attempt order

#### Metadata
- **Area:** Chain Resolution / Announcement Data
- **Priority:** MUST
- **Source:** Frozen design §3 (`Result` field: "Channels that were preferred but infeasible, in attempt order — empty when nothing fell back. Announcements compose from this."); feature constitution "In scope" bullet 3 ("with `fellBackFrom` carried in the result so announcements can name the actually-routed channel"); workflow `security-design-review` focus ("Announcement honesty: the spoken confirmation names the actually-routed channel (`fellBackFrom`); no silent route changes")); DV-2.

#### Description
The chain's result **must** carry `fellBackFrom`: the channels that were attempted and found infeasible, in attempt order, so announcements and the spoken confirmation can name both the routed channel and what was skipped. Binding properties:

- **Empty when nothing fell back** — a feasible preferred channel produces an empty `fellBackFrom`.
- **Attempt order** — when the preferred channel is infeasible and the secondary is routed, `fellBackFrom` is `[preferred]`; when both are infeasible and `phone` is routed, it is `[preferred, secondary]` in that order.
- **The routed channel never appears** in `fellBackFrom`.
- **Dedupe is not duplicated** — an equal secondary skipped by dedupe is listed at most once.
- **Single source for copy** — the confirmation disclosure (FR-CDP-013), the routed-channel announcement (FR-CDP-016) and the launch-fail announcement (FR-CDP-015) **must** compose from this field, never from independently re-derived state, so the spoken line always matches the actual routing.

#### Acceptance criteria

```gherkin
Feature: Fallback provenance in the result

  Scenario: A skipped preferred channel is reported in attempt order
    Given the preferred channel is infeasible
    And the secondary channel is feasible
    When the chain resolves
    Then fellBackFrom contains exactly the preferred channel
    And the routed channel is not present in fellBackFrom

  Scenario: Both skips are reported in order, deduplicated
    Given the preferred channel is infeasible
    And the secondary channel is infeasible
    When the chain resolves
    Then fellBackFrom contains the preferred channel and the secondary channel in attempt order
    And with an equal primary and fallback, the channel appears at most once
    And the routed channel is phone

  Scenario: Nothing fell back when the preferred channel is feasible
    Given the preferred channel is feasible
    When the chain resolves
    Then fellBackFrom is empty
```

#### Related
- FR: FR-CDP-007 (the chain), FR-CDP-013 (confirmation composes from it), FR-CDP-015/016 (announcements compose from it)
- NFR: NFR-CDP-008 (matrix pins its content)

### FR-CDP-009: Preferred input — an explicit per-contact/family pick wins as the chain's preferred

#### Metadata
- **Area:** Chain Resolution / Input
- **Priority:** MUST
- **Source:** Frozen design §4 ("the explicit per-contact/family pick (when present) is `preferred`, else `defaultCallApp`; `secondaryCallApp` is `secondary`") and Goal 3 ("Per-contact and family picks keep winning as the chain's preferred input"); feature constitution Feature Constraint 5 ("No per-contact primary/secondary storage. Per-contact and family picks keep winning as the input to the chain; this feature adds only the settings-level preference."); workflow scope comment ("per-contact pick wins as preferred").

#### Description
The chain's **preferred** input **must** be determined as follows:

- When the call target has an explicit pick, that pick is preferred. Sources, per existing seam: the address-book row's `ChannelPreferenceStore` preference (`resolvedCallChannel`'s `explicit`), and the family contact's pick as the button/dial-back vocabulary yields it (audio buttons: `FamilyContact.resolvedAudioApp`; video buttons: `resolvedVideoApp`; missed-call dial-back: the matched family contact's audio pick, as today).
- When no explicit pick exists, the settings **primary** (`defaultCallApp`) is preferred.

The settings **fallback** (`secondaryCallApp`) is always the chain's secondary step, and `.phone` always the terminal floor (FR-CDP-007). Consequence to pin: when an explicit pick exists and is infeasible, the next attempt is the settings fallback — the settings primary is not consulted in that case (the chain is `preferred → secondary → phone`, not `explicit → primary → secondary → phone`).

**No per-contact primary/secondary storage is introduced**: explicit picks remain inputs to the settings-level chain only (Feature Constraint 5, out of scope otherwise).

#### Acceptance criteria

```gherkin
Feature: Chain preferred input precedence

  Scenario: An explicit per-contact pick is the preferred input
    Given an address-book row has an explicit channel preference of WhatsApp
    And the settings primary is FaceTime
    When the row's call resolves
    Then the chain's preferred input is whatsApp

  Scenario: Without an explicit pick the settings primary is the preferred input
    Given the target has no per-contact or family pick
    And the settings primary is Messenger
    When the call resolves
    Then the chain's preferred input is messenger

  Scenario: An infeasible explicit pick moves to the settings fallback, not the settings primary
    Given the target's explicit pick is Messenger with no handle on file
    And the settings primary is FaceTime
    And the settings fallback is WhatsApp
    When the call resolves
    Then the chain attempts whatsApp next
    And FaceTime is not consulted as a chain step
```

#### Related
- FR: FR-CDP-007 (the chain), FR-CDP-010/011 (call paths that supply the explicit input), FR-CDP-012 (voice path's separate chain)
- NFR: NFR-CDP-009 (regression pin on per-contact behaviour)

### FR-CDP-010: Address-book and family-contact call buttons route the chain

#### Metadata
- **Area:** Call Paths / Tap Buttons
- **Priority:** MUST
- **Source:** Frozen design §4 ("`resolvedCallChannel` ... run the chain ... Call sites updated: address-book row buttons (`LeafViews.swift:1612`), family-contact buttons ...") and Goal 3; feature constitution "In scope" ("Applying the chain to **all** call paths: address-book + family-contact call buttons"); workflow scope comment; DV-6.

#### Description
Every tap-initiated call button **must** resolve through the chain (FR-CDP-007):

- **Address-book row call buttons** (`LeafViews.swift` ~L1612, resolving through `AppCoordinator.resolvedCallChannel`) — the row's explicit `ChannelPreferenceStore` pick (when present) is preferred, else the settings primary; feasibility from the target's handle (FR-CDP-004) and the WhatsApp probe (FR-CDP-005); GSM terminal.
- **Family-contact call buttons** (audio/video) — the contact's preference as the button vocabulary yields it is preferred, else the settings primary; same chain and feasibility.

Binding properties:
- The existing button vocabulary **must** be preserved: audio buttons never resolve to FaceTime and video buttons never to the GSM dialer (`CallApp.supportsAudio` / `supportsVideo` gates unchanged); a deliberate tap still needs no voice confirmation (the tap IS the confirmation — unchanged).
- The previous Messenger-no-handle hard rule **must** become one case of the chain (an infeasible preferred channel hops to the fallback, then GSM).
- A tap **must never dead-end**: when the row's or contact's preferred channel is infeasible, the chain routes to the next attemptable channel and the call is attempted.

#### Acceptance criteria

```gherkin
Feature: Tap call buttons route the chain

  Scenario: An infeasible row preference falls back instead of dead-ending
    Given an address-book row resolves to Messenger with no handle on file
    And the settings fallback is phone
    When the user taps the row's call button
    Then the call is attempted via the fallback channel
    And the tap never dead-ends

  Scenario: A feasible preference keeps today's behaviour
    Given a row's preferred channel is feasible
    When the user taps the row's call button
    Then the preferred channel is opened exactly as before the feature

  Scenario: Equal picks with an infeasible preferred channel reach the GSM floor
    Given the preferred and fallback channels are the same infeasible channel
    When the user taps a row's call button
    Then the channel is attempted at most once
    And the call is attempted via tel: (GSM)
```

#### Related
- FR: FR-CDP-004/005 (feasibility inputs), FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-011 (dial-back), FR-CDP-016 (routed-channel announcement)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-009 (no regression to shipped tap behaviour)

### FR-CDP-011: Missed-call dial-back routes the chain

#### Metadata
- **Area:** Call Paths / Missed-Call Dial-back
- **Priority:** MUST
- **Source:** Frozen design §4 ("`resolvedMissedCallChannel` ... run the chain ... missed-call dial-back") and Goal 3; feature constitution "In scope" ("missed-call dial-back") and Out of scope ("Emergency-contact semantics"); workflow `security-design-test` focus ("dial-back must never delay an emergency escalation"); DV-6.

#### Description
Missed-call dial-back **must** run the chain: `resolvedMissedCallChannel` / `missedCallDialAction` resolve preferred → secondary → `.phone` with feasibility from the row's matched family contact (handle availability) and the WhatsApp probe (FR-CDP-005). The preferred input is the matched family contact's audio pick when one exists (as today, FaceTime excluded by the audio vocabulary), else the settings primary (`defaultCallApp`).

Existing honest dial-back behaviours **must** be preserved unchanged:
- A row with no number opens the Phone app (the call genuinely lives in Recents) — no resolution chain involved.
- A number that normalizes to nothing dialable speaks the existing honest line (`call.announce.noPhoneNumber`) and places no call — never a silent dead tap.
- No silent tap: every dial-back outcome is either an open or a spoken line.

Emergency-contact semantics are untouched by this requirement (FR-CDP-018); dial-back routing **must not** delay or reroute an emergency escalation.

#### Acceptance criteria

```gherkin
Feature: Missed-call dial-back routes the chain

  Scenario: A dial-back with an infeasible preferred channel falls back
    Given a missed-call row matches a family contact
    And the preferred channel for that dial-back is infeasible (e.g. Messenger with no handle)
    And the settings fallback is feasible
    When the user taps the row to dial back
    Then the chain resolves to the fallback (or GSM) channel
    And the dial-back is attempted, never dead-ended

  Scenario: A numberless row keeps the honest Phone-app open
    Given a missed-call row has no number
    When the user taps the row
    Then the Phone app opens (the call lives in Recents)
    And no call is placed by the app

  Scenario: A non-dialable number keeps the honest spoken line
    Given a missed-call row has a number that normalizes to nothing dialable
    When the user taps the row
    Then the app speaks the existing honest line (call.announce.noPhoneNumber)
    And no call is placed
    And no silent tap occurs
```

#### Related
- FR: FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-010 (button paths), FR-CDP-016 (routed-channel announcement), FR-CDP-018 (emergency semantics untouched)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-009 (regression pin on dial-back)

### FR-CDP-012: Voice path — MethodResolver global default becomes the settings primary, mapped by call type

#### Metadata
- **Area:** Voice Path / Method Resolution
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 1 ("`MethodResolver`'s global-default step (currently hardcoded `.phone`) becomes the **settings primary**, mapped `CallApp → CallMethod` by call type ... Injected (closure/config struct) so `MethodResolver` stays coordinator-free and unit-testable") and Goal 3; feature constitution "In scope" bullet 4 and "Integration Surfaces"; workflow scope comment ("MethodResolver global-default step → settings primary, mapped CallApp→CallMethod by call type"); DV-6.

#### Description
`MethodResolver`'s global-default step (step 4, today hardcoded `.phone` at `MethodResolver.swift:74-78`) **must** resolve to the settings primary (`defaultCallApp`), mapped `CallApp → CallMethod` by call type:

| Settings primary | Audio call | Video call |
|---|---|---|
| `phone` | `.phone` | `.phone` |
| `faceTime` | `.facetimeAudio` | `.facetimeVideo` |
| `messenger` | `.messengerAudio` | `.messengerVideo` |
| `whatsApp` | `.whatsappChat` | `.whatsappChat` |

Binding rules:
- Steps 1–3 of the existing chain (explicit mention → family preference → confirmed history) **must** be unchanged and keep outranking the global-default step (`ResolutionSource` values still pin which step won).
- The mapped value **must** be supplied through injection (closure/config struct) so `MethodResolver` stays coordinator-free and unit-testable — it **must not** read coordinator state directly.
- Out of the box the settings primary defaults to `.phone`, so the zero-configuration behaviour remains the universal GSM fallback.

#### Acceptance criteria

```gherkin
Feature: Voice-path global default

  Scenario: With nothing else configured, the settings primary is used, mapped by call type
    Given no explicit app mention, no family preference and no confirmed history
    And the settings primary is FaceTime
    When the user asks to call a contact without naming an app (audio)
    Then the resolved method is .facetimeAudio with source .globalDefault
    And when the request is a video call, the resolved method is .facetimeVideo

  Scenario: The mapping covers every channel
    Given no explicit app mention, no family preference and no confirmed history
    Then a settings primary of WhatsApp resolves to .whatsappChat
    And a settings primary of Messenger resolves to .messengerAudio (audio) or .messengerVideo (video)
    And a settings primary of phone resolves to .phone

  Scenario: Explicit mentions still outrank the global default
    Given the settings primary is FaceTime
    When the user explicitly asks for WhatsApp
    Then the resolved method is .whatsappChat with source .explicit
    And family preferences and confirmed history likewise still outrank the settings primary
```

#### Related
- FR: FR-CDP-013 (fallback applied before the confirmation), FR-CDP-017 (localised copy), FR-CDP-014 (override preserved)
- NFR: NFR-CDP-008 (MethodResolverTests pin the mapping), NFR-CDP-009 (no regression to steps 1–3)

### FR-CDP-013: Fallback resolves before the spoken confirmation; the prompt names the routed channel

#### Metadata
- **Area:** Voice Path / Spoken Confirmation
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 2 ("`requestCallConfirmation` runs the feasibility fallback BEFORE pending the action ... The confirmation prompt names the routed channel and discloses what was skipped — \"Messenger isn't available — call Syanu via WhatsApp, okay?\"") + Goal 4 + Decision 5; feature constitution "In scope" bullet 5 and Feature Constraint 6; workflow `security-design-review` focus ("the spoken confirmation names the actually-routed channel (`fellBackFrom`); no silent route changes"); DV-2.

#### Description
`requestCallConfirmation` **must** run the feasibility fallback **before** pending the action and rendering the prompt:

- The existing Messenger-no-handle refusal becomes a chain hop: Messenger without a usable handle → the settings secondary → GSM. The elder is never asked to yes/no an action that can only fail (the existing no-yes/no-trap property is preserved).
- The confirmation prompt **must** name the actually-routed channel and disclose what was skipped, composed from `fellBackFrom` (FR-CDP-008) — e.g. "Messenger isn't available — call Syanu via WhatsApp, okay?" — via the new catalog key `router.call.fallbackDisclosure` (ne/en, FR-CDP-017).
- On "yes", the call executes on the routed channel; the context carries the routed channel (not the originally-preferred one) into execution and the flywheel capture.
- The existing multi-turn confirmation machinery **must** be reused exactly (Decision 5, Feature Constraint 6): pend → open the existing confirmation window → yes/no → execute/override/timeout, with **no new dialogue flow**, no new question kind and no new state.
- When nothing falls back, the prompt is exactly today's wording.

#### Acceptance criteria

```gherkin
Feature: Fallback applied before the spoken confirmation

  Scenario: The prompt names the routed channel and discloses the skip
    Given the settings primary is Messenger and the contact has no handle on file
    And the settings fallback is WhatsApp
    When the user asks to call the contact without naming an app
    Then the pending action is built for WhatsApp (not the infeasible Messenger)
    And the spoken confirmation names WhatsApp as the channel and discloses that Messenger was unavailable
    And on "yes" the call executes via WhatsApp

  Scenario: Both channels infeasible route to GSM with the floor announced
    Given the settings primary and fallback are both infeasible for the target
    When the user asks to call the contact
    Then the pending action is a phone (GSM) call
    And the spoken confirmation names the phone channel via the floor

  Scenario: No fallback keeps today's prompt
    Given the preferred channel is feasible
    When the user asks to call the contact
    Then the confirmation prompt is unchanged from before the feature
    And no fallback disclosure is appended
```

#### Related
- FR: FR-CDP-007/008 (chain + provenance), FR-CDP-012 (method resolution feeding this), FR-CDP-014 (override lines compose with the disclosure), FR-CDP-016 (no ask-before-fallback)
- NFR: NFR-CDP-003 (no content leakage in prompts/logs), NFR-CDP-008 (wording pinned by tests)

### FR-CDP-014: Override protocol and near-miss disclosure preserved unchanged

#### Metadata
- **Area:** Voice Path / Override Protocol
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 2 ("The override protocol and near-miss disclosure are preserved unchanged") + Goal 4 + Decision 5; feature constitution Feature Constraint 6 ("the override protocol (\"होइन, फोन नै गर\") is preserved unchanged"); workflow scope comment; DV-5.

#### Description
The call-confirmation correction protocol **must** keep working exactly as today (`handleCallConfirmationOverride`):

- "होइन, फोन नै गर" (or any method-amendment utterance) **must** still amend the pending call action's method, re-confirm once, and let the following yes/no execute as normal — the override pair remains the flywheel's capture.
- The existing no-handle gate on overrides **must** be preserved: amending to Messenger for a contact with no usable handle speaks the existing refusal line (`router.call.messengerNoHandle`) and keeps the original action pending, so "हो" still places the original and a further correction still re-plans.
- The **near-miss disclosure** **must** be preserved: a near-miss contact resolution is still disclosed in the same utterance as the confirmation (heard name + proposed name), before the yes that gates the call.
- The fallback disclosure (FR-CDP-013) **must** compose with — never replace or suppress — these existing lines; an override after a fallback still executes the amended method through the normal confirmation.

#### Acceptance criteria

```gherkin
Feature: Override protocol and near-miss disclosure preserved

  Scenario: The phone override still switches the call and re-confirms once
    Given a call confirmation is pending (with a fallback disclosure if a fallback occurred)
    When the user says "होइन, फोन नै गर"
    Then the pending method is amended to a phone call
    And the confirmation is re-asked once
    And a following "हो" executes the phone call

  Scenario: The override no-handle gate is preserved
    Given a call confirmation is pending for a contact with no usable Messenger handle
    When the user overrides to Messenger
    Then the existing refusal line is spoken
    And the original pending action stays pending
    And "हो" still places the original call

  Scenario: Near-miss disclosure is preserved alongside a fallback disclosure
    Given the heard name resolves only as a near miss and the chain fell back to another channel
    When the confirmation is spoken
    Then the utterance discloses the heard name and the proposed name
    And it also names the routed channel and the skipped channel
    And the call executes only after "yes"
```

#### Related
- FR: FR-CDP-012/013 (voice path + fallback disclosure), FR-CDP-018 (no new dialogue flow)
- NFR: NFR-CDP-009 (regression pin on the override machinery)

### FR-CDP-015: Launch-fail fallback (best-effort), announced via the existing spoken-outcome lane

#### Metadata
- **Area:** Launch / Recovery
- **Priority:** MUST
- **Source:** Frozen design §6 ("If the resolved channel's open itself fails (iOS reports failure, or `CallLinks` returns a failure outcome), attempt the fallback, then `phone`, announcing via the existing spoken-outcome lane. Never silent.") and Decision 1 ("Fallback trigger = pre-flight feasibility + launch-failure"); feature constitution "In scope" bullet 6 and Feature Constraint 8; DV-3.

#### Description
If the resolved channel's open itself fails — iOS reports the open failed, or `CallLinks` returns a failure outcome (e.g. `FaceTimeOutcome.unavailable`, an open refused) — the app **must** attempt the next channel down the chain (the remaining fallback step, then `.phone` as the floor), announcing the outcome via the existing spoken-outcome lane (new key `call.announce.launchFailedFallback`, ne/en).

Binding rules:
- The hop is **best-effort** (an extra attempt is made); the binding guarantees are: it is attempted **automatically** (no ask — FR-CDP-016), and a launch failure is **never silent** — the final outcome is always spoken through the existing lane.
- This covers the accepted `canOpenURL` staleness residual (FR-CDP-005): even a stale probe whose channel then fails to open lands on an announced fallback.
- The failure announcement **must not** leak raw error detail beyond the existing log policy (NFR-CDP-003); it names the channel outcome in the user's language, not internal error content.
- Emergency paths are untouched (FR-CDP-018): this hop applies to ordinary call initiation, never to emergency escalation.

#### Acceptance criteria

```gherkin
Feature: Launch-fail fallback

  Scenario: A failed open attempts the next chain step and is announced
    Given the resolved channel's open fails
    And a fallback step remains
    When the call is initiated
    Then the next channel is attempted automatically
    And the outcome (the fallback routing/failure) is announced via the existing spoken-outcome lane

  Scenario: A failed open with no fallback left attempts GSM
    Given the resolved channel's open fails
    And the fallback step was already used or deduped
    When the call is initiated
    Then phone (tel:) is attempted as the floor
    And the outcome is announced — never silent

  Scenario: A launch failure is never a silent failure
    Given any open fails at launch time
    When the chain exhausts
    Then a spoken-outcome line is always produced
    And no failure detail beyond the existing policy reaches logs
```

#### Related
- FR: FR-CDP-005 (probe staleness residual), FR-CDP-006 (floor), FR-CDP-007 (chain), FR-CDP-016 (automatic announced routing), FR-CDP-018 (emergency untouched)
- NFR: NFR-CDP-003 (log safety), NFR-CDP-001 (never dead-ends)

### FR-CDP-016: Automatic routing with a spoken announcement — no ask-before-fallback

#### Metadata
- **Area:** Call Paths / Announcement
- **Priority:** MUST
- **Source:** Frozen design "Decisions (owner-approved)" 1 ("Fallback trigger = pre-flight feasibility + launch-failure; routing is automatic with a spoken announcement — no ask-before-fallback step for the elder"); design §7 (new key `call.announce.fallbackRouted` — "routed-channel announcement"); feature constitution Success ("the call completes via the fallback with a spoken announcement naming the actually-routed channel"); workflow `security-design-review` focus ("no silent route changes"); DV-2, DV-3.

#### Description
Fallback routing **must** be automatic: the elder is **never** asked "may I fall back?" before the chain routes — the routing happens, and the spoken output names what happened (owner decision 1).

Whenever the chain routes away from the preferred channel, the app **must** speak the routed channel and the skip:

- **Voice path** — inside the existing confirmation utterance (FR-CDP-013), composing from `fellBackFrom`; the confirmation is the announcement (no extra question).
- **Tap and dial-back paths** — via the existing spoken-outcome lane (the `call.announce.*` family the tap paths already use), composed from `fellBackFrom`, under the new key `call.announce.fallbackRouted` (ne/en).
- **Launch failure** — via the same lane, under `call.announce.launchFailedFallback` (FR-CDP-015).

Binding rules: there **must** be no silent route change on any path; and when nothing fell back, no fallback announcement is spoken (no added noise for the unchanged case). The exact trigger point of the tap-path announcement (at the open) is design's to fix at design-l1 — the existence, the routed-channel content and the ne/en key are binding.

#### Acceptance criteria

```gherkin
Feature: Automatic, announced fallback routing

  Scenario: A tap-path fallback routes automatically and speaks the routed channel
    Given a tap resolves to an infeasible preferred channel
    When the user taps the call button
    Then the chain routes without asking the user first
    And the routed channel is spoken (call.announce.fallbackRouted), naming what was skipped

  Scenario: The voice path carries routing and disclosure in one confirmation
    Given the preferred channel is infeasible for the target
    When the user asks to call the contact
    Then a single confirmation utterance carries the routing decision and the disclosure
    And no separate ask-before-fallback question is spoken

  Scenario: No fallback produces no fallback announcement
    Given the preferred channel is feasible
    When any call path initiates the call
    Then no fallback announcement is spoken
```

#### Related
- FR: FR-CDP-008 (provenance driving the copy), FR-CDP-013 (voice-path disclosure), FR-CDP-015 (launch-fail lane), FR-CDP-017 (localised keys)
- NFR: NFR-CDP-003 (announcement content/log policy), NFR-CDP-007 (localisation)

### FR-CDP-017: Localisation — new ne/en strings; spoken language matches the session

#### Metadata
- **Area:** Localisation
- **Priority:** MUST
- **Source:** Frozen design §7 ("New ne/en keys in `Localizable.xcstrings`: settings section titles (`settings.calling.primaryTitle`, `settings.calling.secondaryTitle`), confirmation fallback disclosure template (`router.call.fallbackDisclosure`), routed-channel announcement (`call.announce.fallbackRouted`), launch-fail announcement (`call.announce.launchFailedFallback`)"); feature constitution Feature Constraint 9 ("Localization discipline"); project Standards (Localisation); DV-7.

#### Description
All new user-visible strings of this feature **must** be externalised in `ios/ElderlyAssistant/Resources/Localizable.xcstrings` with Nepali **and** English values:

| Key | Surface |
|---|---|
| `settings.calling.primaryTitle` | Primary dialer section title |
| `settings.calling.secondaryTitle` | Fallback dialer section title |
| `router.call.fallbackDisclosure` | Spoken-confirmation fallback disclosure template (contact name + routed channel + skipped channel) |
| `call.announce.fallbackRouted` | Routed-channel announcement on tap/dial-back paths |
| `call.announce.launchFailedFallback` | Launch-fail announcement via the spoken-outcome lane |

Binding rules:
- No hard-coded user-visible string may be introduced; templates take their contact/channel parameters through the existing `L10n.fmt` discipline.
- Spoken output **must** use the session's active language (`activeLocale`), matching the rest of the call flow.
- Channel names **must** reuse the existing `app.name.*` catalog keys, so the picker labels, the confirmation and the announcements agree in both scripts.
- A missing or unknown key **must never** be spoken raw (NFR-CDP-007 pins the completeness check).

#### Acceptance criteria

```gherkin
Feature: Localisation of the new strings

  Scenario: A Nepali session hears and sees Nepali
    Given the session's active language is Nepali
    When the user opens the dialer settings and a fallback/launch-fail occurs on a call
    Then the two section titles render in Nepali
    And the confirmation disclosure and both announcements are spoken in Nepali
    And the channel names match the picker labels

  Scenario: An English session hears and sees English
    Given the session's active language is English
    When the same surfaces are exercised
    Then every new string renders and is spoken in English
    And the channel names still match the picker labels

  Scenario: No user-visible surface falls back to a raw key
    Given both language resources are present
    When the new surfaces are exercised in either language
    Then no raw catalog key or untranslated fallback string is shown or spoken
```

#### Related
- FR: FR-CDP-001/002 (section titles), FR-CDP-013 (disclosure), FR-CDP-015/016 (announcements)
- NFR: NFR-CDP-007 (completeness/parity check)

### FR-CDP-018: Preserved behaviours — no new dialogue flow, emergency semantics untouched, no silent failures

#### Metadata
- **Area:** Safety Boundary / Regression
- **Priority:** MUST
- **Source:** Frozen design Goal 4 and non-goals ("No dedicated `CallRouter` service"; "Emergency-contact semantics untouched"; "No changes to the just-shipped voice pipeline beyond the named MethodResolver seam") + Decision 5; feature constitution Out of scope ("A dedicated `CallRouter` service"; "Per-contact primary/secondary storage"; "Emergency-contact semantics"; "A new dialogue flow"; "The no-silent-failure principle ...") and Feature Constraints 6, 7, 8; workflow scope non-goals ("no change to emergency-contact semantics; a new dialogue flow; any new network surface") and `security-design-review` focus ("Emergency precedence untouched ... dial-back must never delay an emergency escalation").

#### Description
The feature **must not** change the following behaviours:

- **No new dialogue flow** — the existing multi-turn confirmation (pend → existing confirmation window → yes/no → override/timeout → execute) is reused exactly; no new question kind, no new session state, no new prompt sequence (Decision 5, Feature Constraint 6).
- **Emergency-contact semantics untouched** — emergency-contact resolution (the existing `NotifyChannel.resolve`-based path) and emergency escalation keep their exact current semantics; the feasibility chain, the probes and the fallback announcements **must not** wrap, reroute or delay emergency paths (Feature Constraint 7's non-goal; workflow security focus).
- **No silent failures** — every infeasible-preferred, both-infeasible and launch-fail outcome on the new paths is announced through an existing lane (FR-CDP-013/015/016); the existing honest lines (dial-back dead row, override refusal, web-chat disclosure) stay intact.
- **No `CallRouter` service** — the feature extends the existing resolution seams only; **no per-contact primary/secondary storage** — explicit picks remain chain inputs only (Feature Constraints 5, 7).

#### Acceptance criteria

```gherkin
Feature: Preserved behaviours at the safety boundary

  Scenario: The emergency path is functionally unchanged
    Given the emergency-contact resolution and escalation paths
    When their existing matrix is exercised against a build with this feature
    Then their outputs are identical to pre-feature behaviour
    And the chain, feasibility probes and fallback announcements are not applied to them
    And no escalation is delayed or rerouted

  Scenario: The confirmation mechanics introduce no new dialogue
    Given a call confirmation is pending
    When the user answers yes, no, overrides, or lets it time out
    Then each behaviour is exactly as before the feature
    And no new question, state or prompt appears

  Scenario: No outcome on the new paths is silent
    Given an infeasible preferred channel, an infeasible pair, or a launch failure
    When the call is initiated on any path (tap, dial-back, voice)
    Then a spoken line names the outcome
    And zero silent failures occur
```

#### Related
- FR: FR-CDP-013/014 (reused confirmation + override), FR-CDP-015/016 (never-silent announcements), FR-CDP-011 (dial-back does not delay escalation)
- NFR: NFR-CDP-009 (regression evidence), NFR-CDP-002 (no new surface)

### FR-CDP-019: DV-1..7 device validation recorded and passed (completion gate)

#### Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Feature constitution "Success Criteria & Completion Gate" (DV-1 … DV-7 on the reference device, the DV pattern of prior shipped features, recorded with the feature spec); frozen design §9 ("Completion gate: DV-1..7 device validation on Anzaan"); workflow `final-sign-off` comment ("DV-* device validation on Anzaan is part of the completion gate ...").

#### Description
The feature **must not** be considered complete until the DV-1..7 checklist from the feature constitution is executed on the reference device (Anzaan), recorded with this feature set, and passed:

- **DV-1** — Settings: Primary + Fallback pickers persist across relaunch (`secondaryCallApp` next to `defaultCallApp`).
- **DV-2** — Primary infeasible (Messenger, no handle on file) → the call completes via the fallback with the spoken announcement naming the routed channel.
- **DV-3** — WhatsApp not installed (`canOpenURL` false) → the chain lands on the fallback/GSM with the announcement; a launch failure is announced via the existing spoken-outcome lane (no silent failure).
- **DV-4** — `secondary == primary` dedupes; both primary and secondary infeasible → `phone` is attempted; zero dead ends.
- **DV-5** — Override preserved: "होइन, फोन नै गर" still switches to a phone call.
- **DV-6** — All call paths route the chain: address-book row, family-contact, missed-call dial-back, voice-initiated call (MethodResolver global default).
- **DV-7** — ne/en copy: pickers, confirmation and announcement strings localised; spoken language matches the session.

Any unresolved or failed DV item **must** block sign-off (the `final-sign-off` task is T2 + HIL); a partial pass is not a completion. The release log-safety gate (`ios/tools/check-release-log-safety.sh`) must also exit 0 as part of the same closure (NFR-CDP-003, NFR-CDP-010).

#### Acceptance criteria

```gherkin
Feature: Device-validation completion gate

  Scenario: The DV checklist is recorded and passed
    Given the feature build is installed on the reference device (Anzaan)
    When DV-1 through DV-7 are executed per the constitution's checklist
    Then each item passes and its evidence is recorded with the feature spec
    And the completion gate is satisfied for sign-off

  Scenario: An unresolved DV item blocks completion
    Given any DV item is unresolved or fails on the device
    When final sign-off is considered
    Then the feature is not signed off
    And the item is reworked and re-validated (no partial pass)
```

#### Related
- FR: FR-CDP-001/002/003 (DV-1), FR-CDP-013 (DV-2), FR-CDP-005 (DV-3), FR-CDP-007 (DV-4), FR-CDP-014 (DV-5), FR-CDP-010/011/012 (DV-6), FR-CDP-017 (DV-7)
- NFR: NFR-CDP-010 (release/compliance gates the closure runs), NFR-CDP-003 (release log gate)

## Non-functional requirements

### NFR-CDP-001: The chain never dead-ends — zero dead ends across the exhaustive configuration matrix

#### Metadata
- **Category:** Reliability / Safety
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 ("GSM hard floor — no dead ends ... Any resolution returns an attemptable channel even when primary and secondary are both infeasible. This is the feature's core guarantee.") and Success ("Calls never dead-end: zero dead-end call attempts when the primary is infeasible"); frozen design Goal 2 ("A call never dead-ends"); workflow `security-design-review` focus ("GSM hard floor ... no configuration (including secondary == primary) may produce a dead-end chain"); DV-4.

#### Description
The resolution chain **must** return an attemptable channel under every possible configuration. Measurable properties:

- **Exhaustive matrix**: for all 4 preferred channels × 4 secondary channels × 4 feasibility states (Messenger handle {available, not on file} × WhatsApp {installed, not installed}) — 64 combinations — the resolver returns exactly one attemptable channel: **100% of combinations, 0 dead ends**.
- **GSM reachability**: in every combination where the preferred and secondary channels are both infeasible (including a deduped equal pair), the result is `.phone`: **100% of those cells**.
- **Attempt-at-most-once**: **0** combinations route through the same channel more than once.
- **No configuration escapes the floor**: no picker pair (including equal values and any ordering) can produce a resolution with no attemptable channel; verified by the exhaustive unit matrix (NFR-CDP-008) rather than by sampling.

#### Acceptance criteria

```gherkin
Feature: Zero dead ends — the GSM floor guarantee

  Scenario: The exhaustive configuration matrix never dead-ends
    Given all 4 preferred × 4 secondary × 4 feasibility combinations (64 cells)
    When the chain resolves each cell
    Then every cell returns exactly one attemptable channel
    And zero cells dead-end

  Scenario: Dedupe cannot remove the floor
    Given secondary == primary
    And that channel is infeasible
    When the chain resolves
    Then the channel is attempted at most once
    And the result is phone (the floor is still reachable)

  Scenario: The floor is the terminal result whenever nothing else is attemptable
    Given the preferred and secondary channels are infeasible
    When the chain resolves
    Then phone is returned in 100% of those cases
```

#### Related
- FR: FR-CDP-006 (always-feasible channels / floor), FR-CDP-007 (chain), FR-CDP-010/011 (tap paths)
- NFR: NFR-CDP-008 (deterministic matrix proves this), NFR-CDP-009 (regression evidence)

### NFR-CDP-002: Feasibility probes are local — no new network, data, identity or privacy surface

#### Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Frozen design non-goals ("No new network, data, identity, or privacy surface — feasibility probes are local") and §2 ("local probe only"); feature constitution "Safety & Compliance Delta" ("no new data, network, identity, or privacy surface — the feasibility probes are local (`canOpenURL`, address-book handle check)") and Feature Constraint 8; workflow `security-design-review` focus ("Feasibility probes are local-only: canOpenURL + address-book handle check; no new egress, no new data collection (handles/numbers are PII)").

#### Description
The feature **must** add no network, data, identity or privacy surface. Measurable properties:

- **Zero new egress**: neither the Messenger handle check nor the WhatsApp probe performs network I/O — **0** socket/HTTP operations on the resolution path (the probe is a local `canOpenURL` scheme check; the handle check reads the existing on-device store).
- **Zero new hosts/endpoints/permissions**: no new URL host, no new `Info.plist` permission or query-scheme entry (the schemes are already declared), no new entitlement.
- **Zero new data stores**: the only new persisted datum is the `secondaryCallApp` preference string; numbers/handles remain in their existing stores under the existing policy; no new telemetry or analytics event carries target content.
- **PII stays local**: no phone number, handle or contact name leaves the device through any new path; the existing egress surfaces and their disclosures are untouched.

#### Acceptance criteria

```gherkin
Feature: Local-only feasibility

  Scenario: Resolution performs no network I/O
    Given a build exercising the feasibility probe and handle check
    When any target is resolved through the chain
    Then zero network requests are made by the resolution path
    And the probe only queries the local scheme availability

  Scenario: No new permission, store or host is introduced
    Given the feature's build diff
    When permissions, Info.plist declarations, stored data and network hosts are inspected
    Then zero additions exist beyond the secondaryCallApp preference string
    And the existing privacy surfaces and disclosures are unchanged
```

#### Related
- FR: FR-CDP-004/005 (the two probes), FR-CDP-018 (no new surface)
- NFR: NFR-CDP-003 (log surface), NFR-CDP-010 (compliance gates)

### NFR-CDP-003: Log safety — numbers, handles and announcement content never reach logs beyond the existing policy

#### Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("Log sanitisation: numbers/handles must not reach logs beyond the existing transcript policy (B2/T-050)") and the workflow header ("The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into ios/build.sh) must cover the new fallback/announcement paths"); project constitution Release gates (release-build log-surface gate; pre-release device check) and Standards (logs must not contain PII — log sanitiser required); feature constitution "Safety & Compliance Delta".

#### Description
No phone number, Messenger handle, contact name or announcement content **must** reach any log, telemetry event or diagnostic surface beyond the existing transcript policy (the B2/T-050 precedent is binding). Measurable properties:

- **Zero raw content**: a Release build exercising the chain (a fallback hop, a dedupe-to-GSM, a launch failure, a tap and a voice fallback) produces **0** raw numbers, handles, contact names or announcement strings in console/log output.
- **Classification-only observability**: chain/fallback events may carry non-content classifications (event name, channel enum values, `fellBackFrom` channel enum values) — never the target's number, handle or name.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) **exits 0** with the new chain/fallback/announcement paths in scope.
- **Pre-release device check**: the pre-release console/sysdiagnose check covers a fallback and a launch failure on the reference device.

#### Acceptance criteria

```gherkin
Feature: Log safety for the chain and fallback paths

  Scenario: Exercising the fallback paths produces no PII in logs
    Given a Release build
    When a preferred-infeasible fallback, a dedupe-to-GSM and a launch failure are exercised on tap and voice paths
    Then zero raw numbers, handles, contact names or announcement strings appear in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's chain, fallback and announcement paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new resolution/announcement call sites
```

#### Related
- FR: FR-CDP-013 (confirmation content), FR-CDP-015/016 (announcements), FR-CDP-018 (no silent failures)
- NFR: NFR-CDP-002 (local-only probes), NFR-CDP-010 (release gates)

### NFR-CDP-004: Fallback-resolution latency budget — local probes at call time, user-paced

#### Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Frozen design Risks ("`canOpenURL` probe staleness: iOS caches scheme availability; acceptable here — probes run at call time, user-paced, and the launch-fail hop covers the residual case"); workflow scope comment (probes "local", injected); workflow `define-requirements` ("Fallback-resolution latency budget (local probes at call time, user-paced)").

#### Description
Chain resolution (handle check + local scheme probe + the pure chain computation) **must** add no perceptible delay to call initiation. Measurable properties (reference device: Anzaan):

- **Added latency budget**: ≤ **100 ms** p95 added to the tap path (tap → open attempt) and to the voice path (final utterance → confirmation prompt rendered/spoken), measured over repeated runs.
- **Zero network waits**: the resolution path performs 0 network operations, so it can add no network-dependent wait (0 ms network-attributable latency).
- **Call-time evaluation**: probes are evaluated at call time (no background polling loops, no periodic re-probing) — matching the design's "runs at call time, user-paced" model.
- **No trade against safety**: meeting the budget **must not** be achieved by weakening the never-dead-end guarantee (NFR-CDP-001) or the never-silent announcements (FR-CDP-015/016).
- **Failure mode**: a probe that cannot answer (platform refusal) is a local, immediate result (treated per the feasibility contract) — it never blocks on a timeout.

#### Acceptance criteria

```gherkin
Feature: Resolution stays within the latency budget

  Scenario: The tap path stays within the added-latency budget
    Given the reference device
    When a call button with a fallback is tapped repeatedly
    Then the added resolution latency is ≤ 100 ms p95
    And no network wait contributes to the total

  Scenario: The voice path is not perceptibly delayed
    Given a voice-initiated call that falls back
    When the confirmation prompt is rendered
    Then the prompt appears within the existing turn envelope with ≤ 100 ms added resolution latency
    And the guarantee of naming the routed channel is intact
```

#### Related
- FR: FR-CDP-005 (the probe), FR-CDP-007 (the chain), FR-CDP-013 (confirmation timing)
- NFR: NFR-CDP-001 (guarantees preserved while meeting the budget), NFR-CDP-002 (zero network)

### NFR-CDP-005: `secondaryCallApp` persistence round-trip reliability

#### Metadata
- **Category:** Reliability (Persistence)
- **Priority:** MUST
- **Source:** Frozen design §1 (UserDefaults seam, default `.phone`) and §8 ("Settings persistence: `secondaryCallApp` round-trip + `.phone` default"); feature constitution Feature Constraint 4 and DV-1; workflow `design-l1` scope ("persistence for existing installs (secondaryCallApp absent → GSM)").

#### Description
The `secondaryCallApp` preference **must** be durably persisted through the existing house seam. Measurable properties:

- **Round-trip**: for each of the four channels, select → relaunch → the restored value equals the selection in **100%** of runs of the settings-persistence suite (0 mismatches across repeated runs).
- **Default**: a fresh install and an upgraded install without the key resolve to `.phone` in **100%** of runs; an unrecognised raw value also resolves to `.phone`.
- **Immediate durability**: the write is bound to the selection action (`didSet` house pattern) and survives a process kill immediately after selection (relaunch returns the just-selected value).
- **Isolation**: writing `secondaryCallApp` never mutates `defaultCallApp` and vice versa — **0 cross-writes** in the suite; no other stored key changes value on a fallback selection.

#### Acceptance criteria

```gherkin
Feature: Fallback preference durability

  Scenario: Every channel round-trips identically
    Given each of FaceTime, phone, Messenger and WhatsApp is selected as the fallback in turn
    When the app relaunches after each selection
    Then the restored secondaryCallApp equals the selection in 100% of runs

  Scenario: Upgraded installs default to GSM
    Given an install whose stored state has no secondaryCallApp key
    When the app launches after the upgrade
    Then the fallback is phone with no user action required

  Scenario: The two preferences are isolated
    Given a stored primary and a stored fallback
    When either preference is re-selected
    Then the other preference's stored value is unchanged
```

#### Related
- FR: FR-CDP-003 (the seam), FR-CDP-002 (the picker), FR-CDP-007 (the chain reading it)
- NFR: NFR-CDP-008 (the suite that pins this), NFR-CDP-010 (DV-1 evidence)

### NFR-CDP-006: Accessibility of the Primary and Fallback dialer pickers

#### Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards — Accessibility ("Touch UI ... must use large tap targets (minimum 44x44 pt iOS) ... minimum 18pt font size for body text"; voice-first) and requirements.md NFR-019…NFR-022; frozen design §1 ("each the existing four-channel row pattern" — the elderly first audience); DV-1; feature constitution "Primary user: the elderly parent".

#### Description
Both new settings sections **must** be accessible to elderly users on the reference device. Measurable properties:

- **Tap targets**: every channel row in both sections is ≥ **44 × 44 pt**; the whole row remains the tap target (the existing full-width row pattern).
- **Text size**: visible labels are ≥ **18 pt** and respect Dynamic Type; at the largest accessibility text size **no channel label or section title is clipped, truncated to ambiguity, or shrunk below the minimum**; the sizes are consistent with the app's typography tokens (`appearance.typography`).
- **VoiceOver**: each row exposes section title + channel name + selected state; the selected row is announced as selected (checkmark is not the only selected signal — the state is conveyed non-visually).
- **Contrast**: the picker text and selected-state affordance meet WCAG AA (≥ 4.5:1 body text, ≥ 3:1 UI components).

#### Acceptance criteria

```gherkin
Feature: Accessible dialer pickers

  Scenario: VoiceOver announces the pickers usefully
    Given VoiceOver is enabled
    When the user moves through the Primary and Fallback dialer sections
    Then each row announces its section, the channel name and, for the selected row, that it is selected
    And the checkmark is not the only indication of selection

  Scenario: The largest text size does not break the pickers
    Given the system text size is set to the largest accessibility size
    When the dialer settings are shown
    Then both section titles and all four channel labels in each section remain fully readable
    And no label is clipped or reduced below the 18 pt minimum

  Scenario: Minimum target and contrast requirements hold
    Given the rendered picker rows
    Then every channel row provides at least a 44 × 44 pt tap target
    And text/component contrast meets WCAG AA
```

#### Related
- FR: FR-CDP-001/002 (the pickers), FR-CDP-017 (localised labels)
- NFR: NFR-CDP-007 (labels present in both languages)

### NFR-CDP-007: Localisation completeness — 100% ne/en parity for every new string

#### Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Project constitution Standards (Localisation — "all UI strings must be externalised"; minimum: support the primary user's configured language for all TTS) and requirements.md NFR-023/NFR-024; frozen design §7 (the new key list); feature constitution Feature Constraint 9; DV-7.

#### Description
Every new user-visible string **must** be fully localised in Nepali and English. Measurable properties:

- **Key parity**: each new key — `settings.calling.primaryTitle`, `settings.calling.secondaryTitle`, `router.call.fallbackDisclosure`, `call.announce.fallbackRouted`, `call.announce.launchFailedFallback` — has **both** a non-empty `ne` and `en` value in `Localizable.xcstrings`: **100% of keys, 0 missing** (automated catalog check).
- **No raw keys**: **0** user-visible surfaces show or speak a raw key or an untranslated fallback string in either language.
- **Template integrity**: parameterised strings (contact name, channel name, skipped channel) render with the parameters substituted correctly in both languages through the existing `L10n.fmt` discipline — **0** format-break placeholders (no `%@`/`%@@` leftovers).
- **Spoken language matches the session**: in **100%** of the DV-7 checks, spoken picker-adjacent copy, confirmation disclosure and announcements use the session's active language.
- **Shared channel labels**: picker, confirmation and announcements reference the same `app.name.*` strings per language (single source — no divergent channel wording).

#### Acceptance criteria

```gherkin
Feature: Localisation completeness

  Scenario: Every new key has both languages
    Given the Localizable.xcstrings catalog with this feature's keys
    When the parity check runs
    Then every new key has non-empty ne and en values
    And zero new keys are missing either language

  Scenario: Nepali and English sessions both render fully
    Given the session language is Nepali, and repeated with English
    When the pickers, a fallback confirmation and both announcements are exercised
    Then every string renders/spoken in the session language
    And no raw key or format placeholder remains visible

  Scenario: Channel wording is single-sourced
    Given a fallback in either language
    When the picker label, the confirmation and the announcement name the channel
    Then they use the same catalog string for that channel
```

#### Related
- FR: FR-CDP-017 (the localisation requirement), FR-CDP-013/015/016 (announcement surfaces)
- NFR: NFR-CDP-006 (accessibility of the rendered labels), NFR-CDP-010 (DV-7 evidence)

### NFR-CDP-008: Deterministic testability under the scoped-suite gate

#### Metadata
- **Category:** Reliability / Testability
- **Priority:** MUST
- **Source:** Frozen design §8 ("scoped suites — the honest gate; full-bundle baseline is pre-existing red") and Risks ("the resolver is pure-static and closure-injected; scoped tests pin the matrix"); feature constitution Feature Constraint 12 ("Scoped/focused test suites are the honest gate ... The new resolver is pure-static and closure-injected so the chain matrix is deterministic without platform stubs."); workflow scope comment; project house practice (unit gates: focused tests + typecheck per unit; full suite once at the end).

#### Description
The chain and its integration **must** be testable deterministically, without platform stubs. Measurable properties:

- **Zero platform dependencies in the matrix**: the WhatsApp probe is injected as a closure, Messenger handle availability is a plain boolean, and the resolver is pure-static — the chain matrix runs with **0 network calls and 0 app-installation requirements**.
- **Named scoped suites exist and pass**:
  - `CallChannelResolutionTests` — the full chain matrix: preferred feasible; preferred infeasible → secondary; both infeasible → phone; `secondary == primary` dedupe; per-contact pick wins as preferred; `fellBackFrom` content; the exhaustive 64-combination never-dead-end case (NFR-CDP-001).
  - `MethodResolverTests` — global-default step = settings primary mapped by call type; fallback applied before the confirmation.
  - Settings persistence — `secondaryCallApp` round-trip + `.phone` default (NFR-CDP-005).
  - Confirmation-prompt wording — the fallback disclosure names the routed channel.
  - Picker UI — the two sections render and persist.
- **Gate discipline**: scoped `-only-testing` runs are the honest gate; the full-bundle pre-existing red baseline is **recorded, not silently included or excluded**; the touched scoped suites show **0 new failures** versus the recorded baseline.

#### Acceptance criteria

```gherkin
Feature: Deterministic coverage of the chain

  Scenario: The chain matrix runs without platform stubs
    Given the scoped test suites on a machine with no device and no installed apps
    When CallChannelResolutionTests runs the full matrix including the 64-combination case
    Then it completes deterministically with zero network calls
    And every cell's routed channel and fellBackFrom are asserted

  Scenario: The named suites cover the integration seams
    Given the feature's scoped suites
    When MethodResolverTests, the settings-persistence suite, the confirmation-wording checks and the picker-UI checks run
    Then each passes
    And the pre-existing full-bundle baseline is recorded alongside the results

  Scenario: No new failures are introduced in touched suites
    Given the recorded pre-feature baseline for the touched suites
    When the suites run against the feature build
    Then zero new failures appear
```

#### Related
- FR: FR-CDP-005 (injected probe), FR-CDP-007/008 (the chain and its output), FR-CDP-012/013 (MethodResolver and wording)
- NFR: NFR-CDP-001 (the matrix that proves never-dead-ends), NFR-CDP-009 (baseline discipline)

### NFR-CDP-009: No regression to the shipped voice pipeline, emergency and dial-back paths

#### Metadata
- **Category:** Reliability (Regression)
- **Priority:** MUST
- **Source:** Frozen design Risks ("Regression on just-shipped call paths (PRs #161–#168): the chain replaces only the single Messenger hard-rule and the hardcoded voice default; the resolver is pure-static and closure-injected; scoped tests pin the matrix") and non-goals ("No changes to the just-shipped voice pipeline beyond the named MethodResolver seam"); feature constitution Feature Constraint 7 ("The regression risk is to the just-shipped voice pipeline, emergency-contact and dial-back paths (PRs #161–#168) — do not refactor beyond the named seams"); workflow `security-design-review`/`security-test` focus (emergency precedence; dial-back).

#### Description
The feature **must** leave every behaviour it does not explicitly re-specify identical to the pre-feature build, and its change surface **must** stay limited to the named seams. Measurable properties:

- **Change surface**: the touched production files are the named seams only — `resolvedCallChannel`, `resolvedMissedCallChannel`/`missedCallDialAction`, MethodResolver's global-default step, `requestCallConfirmation`'s gating/prompt composition, the new pure-static resolver, `CallingSettingsView`, `AppCoordinator`'s new preference, and the string catalog: **0 refactors beyond**.
- **Emergency path**: emergency-contact resolution outputs are **identical to pre-feature** for its pinned matrix (0 diffs in its suite); nothing on the emergency path consults the chain.
- **Dial-back path**: dial-back identity resolution and the honest lines (numberless row → Phone app; non-dialable number → spoken line) are unchanged (0 diffs in their pinned cases).
- **Voice pipeline (#161–#168)**: the override protocol, near-miss disclosure and multi-turn confirmation mechanics behave identically; their suites show **0 new failures** versus the recorded pre-feature baseline.
- **Scoped-suite evidence**: the touched suites run green against the baseline; deviations are reworked, not waived.

#### Acceptance criteria

```gherkin
Feature: No regression outside the re-specified behaviour

  Scenario: Emergency behaviour is bit-identical
    Given the emergency-contact resolution matrix
    When it is exercised against the feature build and compared with the pre-feature baseline
    Then zero output differences exist
    And the emergency path performs no chain resolution

  Scenario: Dial-back and voice-pipeline suites stay green
    Given the recorded pre-feature baselines for the dial-back, override, near-miss and multi-turn confirmation suites
    When the feature build runs the same suites
    Then zero new failures exist
    And the honest dial-back lines behave exactly as before

  Scenario: The change surface stays within the named seams
    Given the feature's build diff
    Then it touches only the named seams, the new resolver, the settings view and the catalog
    And no CallRouter service or per-contact preference storage is introduced
```

#### Related
- FR: FR-CDP-011 (dial-back), FR-CDP-014 (override/near-miss), FR-CDP-018 (preserved behaviours)
- NFR: NFR-CDP-008 (scoped suites and baseline discipline), NFR-CDP-010 (gates)

### NFR-CDP-010: Compliance, review and release gates; DV-1..7 acceptance

#### Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Workflow `call-dialer-primary-secondary.yaml` (`review-l2` GO; `security-design-review` SECURITY-GO with the five focus areas; `security-test` SECURITY-GO; `final-sign-off` T2 + HIL; "The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into ios/build.sh) must cover the new fallback/announcement paths"); project constitution Release gates and Standards/Quality (paired review, 0.85 confidence, max rework 5); feature constitution "Safety & Compliance Delta" and completion gate.

#### Description
The feature **must** pass its workflow gates with **no new compliance surface**:

- **Design/review gates**: `review.decision == GO` (review-l2).
- **Security gates**: `security-design-review` returns `SECURITY-GO` with a STRIDE threat model covering the five workflow focus areas — (1) the GSM hard floor can never be configured away (no dead-end chain, including `secondary == primary`); (2) emergency-contact semantics and the override protocol unchanged, dial-back never delays escalation; (3) feasibility probes local-only, no new egress, handles/numbers remain PII with no new collection; (4) announcement honesty — the spoken confirmation/announcements always name the actually-routed channel from `fellBackFrom`, no silent route changes; (5) log sanitisation of numbers/handles. `security-test` returns `SECURITY-GO` with chain-matrix and log evidence.
- **Release gate**: `ios/tools/check-release-log-safety.sh` exits **0** with the new fallback/announcement paths in scope (wired into `ios/build.sh`).
- **Sign-off**: `final-sign-off` is T2 (senior human approval) + HIL with the DV-1..7 results (FR-CDP-019) recorded; implementation runs paired review at the 0.85 confidence threshold, max rework 5.
- **No new compliance regime**: 0 new permissions, data stores, egress hosts or privacy disclosures; the existing privacy/consent surfaces are untouched (NFR-CDP-002).

#### Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The review and security gates pass with the named focus areas
    Given the feature's design and implementation
    When review-l2, security-design-review and security-test are executed
    Then review-l2 returns GO
    And both security gates return SECURITY-GO with the five focus areas covered

  Scenario: The release log-safety gate passes with the new paths in scope
    Given a build with the feature
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And the new fallback and announcement paths are covered

  Scenario: Completion is recorded at T2 with the DV evidence
    Given the DV-1..7 results from the reference device
    When final sign-off is executed
    Then it runs at risk tier T2 with HIL
    And the DV evidence is recorded with the feature spec
    And no new permission, store, egress host or compliance regime was introduced
```

#### Related
- FR: FR-CDP-019 (DV completion gate), FR-CDP-018 (preserved boundaries)
- NFR: NFR-CDP-003 (log safety gate), NFR-CDP-002 (no new surface), NFR-CDP-009 (regression evidence)

## Open decisions

**None.** The feature constitution records "Open Decisions: **None**" — the design is approved and
frozen (owner sign-off 2026-10-12), including secondary defaulting to GSM, Messenger feasibility
as "handle on file", the WhatsApp `canOpenURL` probe, the GSM hard floor, dedupe on equal picks,
and the reuse of the existing confirmation flow. This requirements pass found **no new
owner-level ambiguity**: every behaviour it binds traces to the frozen design, the feature
constitution or the project constitution. Items the design explicitly leaves to the design phase
are recorded as assumptions (below) — design inputs, not re-opened decisions, and not silently
resolved.

### Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list belongs in the lock file (`assumptions`) when the lock is produced.

- The frozen design doc
  (`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`) is present on the
  feature branch at requirements time — the constitution's precondition for this pass.
- Integration anchors were spot-verified against the worktree source at requirements time:
  `defaultCallApp` property `AppCoordinator.swift:330-335` and its restore default (`? .phone`) at
  `:2851-2853`; `resolvedCallChannel` `:2099-2105`; `resolvedMissedCallChannel` `:8382-8390`;
  `missedCallDialAction` `:8423-8443`; `dialBackMissedCall` `:8457+`; `requestCallConfirmation`
  `:7587-7647` (Messenger-no-handle gate at `:7620-7623`); `handleCallConfirmationOverride`
  `:7656-7686` (override no-handle gate at `:7665-7669`); `confirmationPrompt` `:7688-7707`;
  `MethodResolver` step 4 `MethodResolver.swift:74-78`; `CallApp` enum `CallLinks.swift:66-84`
  with its open outcomes (`MessengerOutcome` `openedThread`/`fellBackToWeb`/`invalidHandle` at
  `:145-157`, `FaceTimeOutcome.unavailable` at `:114-123`); `FamilyContact.resolvedAudioApp`
  `FamilyContactStore.swift:162-164`; `CallingSettingsView` four-channel rows `:22-77`;
  `LeafViews` row channel state ~`:1612`; the emergency path via `NotifyChannel.resolve` at
  `AppCoordinator.swift:6464-6468`; existing catalog keys (`settings.calling.title`,
  `router.call.*`, `call.announce.*`) — the five new keys were confirmed absent from
  `Localizable.xcstrings` at requirements time.
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
- The chain resolver's file placement/name
  (`CallChannelChain.route(preferred:secondary:feasibility:)` with `Result.fellBackFrom`) is the
  design's frozen shape; requirements bind behaviour and the pure-static, closure-injected
  properties — exact placement is design's.
- The existing audio/video button vocabulary gates (`supportsAudio` / `supportsVideo`, FaceTime
  excluded from audio buttons and dial-back) are preserved; the feature changes only the
  global-default/secondary resolution inside them.
- Emergency-contact resolution (`NotifyChannel.resolve`-based) is **not** rewired to the chain
  (non-goal); FR-CDP-018 / FR-CDP-011 pin its no-change.
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
| Emergency-contact semantics changes | Emergency-contact resolution and escalation are untouched; the chain, probes and announcements never wrap or delay them (design non-goals; FR-CDP-018). |
| A new dialogue flow | The existing multi-turn confirmation is reused exactly; no new question kind, state or prompt sequence (design Goal 4 / Decision 5; FR-CDP-013/018). |
| Any new network, data, identity or privacy surface | Feasibility probes are local (`canOpenURL`, address-book handle check); no new egress, permission, data store or collection (constitution Constraint 8; NFR-CDP-002). |
| Changes to the just-shipped voice pipeline beyond the named MethodResolver seam | Regression context PRs #161–#168: the chain replaces only the single Messenger hard-rule and the hardcoded voice default; no refactoring beyond the named seams (constitution Constraint 7; NFR-CDP-009). |
| Any Android scope, new compliance regime, permission widening or analytics addition | No platform scope beyond the existing iOS app; no new compliance category, permission, data store or egress host (feature constitution; NFR-CDP-002/010). |

## How this set is verified downstream

| Gate | What it checks against this set |
|---|---|
| `design-l1` / `design-l2` | Resolve/design the mechanical details the frozen design leaves open: the feasibility resolver's shape and injectable seams (the `canOpenURL` closure, handle lookup) for tests; the chain's integration points in `resolvedCallChannel` / `resolvedMissedCallChannel` and every tap call site (`LeafViews` address-book rows ~L1612, family-contact buttons); the MethodResolver global-default replacement and the `CallApp`→`CallMethod` mapping per call type; where the fallback decision sits relative to the confirmation window and `PendingCallAction` so the confirmation names the routed channel; the announcement strings and their ne/en catalog entries; persistence for existing installs (`secondaryCallApp` absent → GSM); the launch-fail observation point and its interaction with the spoken-outcome lane; the tap-path `call.announce.fallbackRouted` trigger point. Conflicts with the frozen design are recorded amendments, never silent resolutions. |
| `review-l2` | `review.decision == GO` against the component design and this set. |
| `security-design-review` | STRIDE with the five workflow focus areas: (1) the GSM hard floor can never be configured away — no dead-end chain, including `secondary == primary` (NFR-CDP-001, FR-CDP-006/007); (2) emergency-contact semantics and the override protocol unchanged, dial-back never delays escalation (FR-CDP-011/014/018, NFR-CDP-009); (3) probes local-only, no new egress, handles/numbers remain PII (NFR-CDP-002, FR-CDP-004/005); (4) announcement honesty — the confirmation/announcements always name the actually-routed channel from `fellBackFrom`, no silent route changes (FR-CDP-008/013/015/016); (5) log sanitisation of numbers/handles (NFR-CDP-003). `SECURITY-GO` required. |
| `plan-tasks` / `implement` | Units trace back to `FR-CDP-*` / `NFR-CDP-*` ids; paired review and the 0.85 confidence threshold on implementation output; rework bound 5; unit-based dependency waves. |
| `security-test` | Evidence: the chain never dead-ends for any (primary, fallback) pair — including equal values (dedupe) and uninstalled apps — and the GSM floor is reachable with every other channel infeasible (NFR-CDP-001); the confirmation wording always names the routed channel (FR-CDP-013); emergency/dial-back escalation is unaffected (FR-CDP-018, NFR-CDP-009); number/handle PII does not reach logs, with `check-release-log-safety.sh` coverage of the new paths (NFR-CDP-003); no new egress from the feasibility probes (NFR-CDP-002). `SECURITY-GO` required. |
| `final-sign-off` | T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) exits 0 (NFR-CDP-003/010); the DV-1..7 checklist is recorded and passed on the reference device Anzaan — settings persistence; primary-infeasible fallback with the spoken routed-channel announcement; WhatsApp-not-installed chain + launch-fail announcement; dedupe/GSM floor; override preserved; all call paths route the chain; ne/en copy (FR-CDP-019). |

## Related

- Consolidated copy: [`define-requirements.md`](define-requirements.md) (this document)
- Folder index: [`define-requirements/index.md`](define-requirements/index.md)
- FR index: [`define-requirements/FR/index.md`](define-requirements/FR/index.md) ·
  NFR index: [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md)
- Feature constitution: [`specs/call-dialer-primary-secondary/constitution.md`](specs/call-dialer-primary-secondary/constitution.md)
- Feature workflow (scope comment + security focus):
  [`.ai-sdd/workflows/call-dialer-primary-secondary.yaml`](.ai-sdd/workflows/call-dialer-primary-secondary.yaml)
- Frozen design (the feature brief):
  [`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`](docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md)
- Project constitution: [`constitution.md`](constitution.md) · Stakeholder brief
  (read-only): [`requirements.md`](requirements.md)
