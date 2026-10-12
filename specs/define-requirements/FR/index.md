# Functional Requirements — Call Dialer Primary/Secondary

19 functional requirements. IDs are namespaced `FR-CDP-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`) and multi-turn-conversation used (`FR-MTC-NNN`).
This page covers the `call-dialer-primary-secondary` set (`FR-CDP-*`) only; the earlier feature
files remain in this folder and are not part of this feature's requirements or lock.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-CDP-001](FR-CDP-001-primary-dialer-setting.md) | Primary dialer setting — four channels, persisted | Settings / Primary Dialer | MUST |
| [FR-CDP-002](FR-CDP-002-fallback-dialer-setting.md) | Fallback dialer setting — four channels, equal picks legal | Settings / Fallback Dialer | MUST |
| [FR-CDP-003](FR-CDP-003-secondary-call-app-persistence.md) | `secondaryCallApp` persistence seam with GSM default | Settings / Persistence | MUST |
| [FR-CDP-004](FR-CDP-004-messenger-feasibility-handle-on-file.md) | Messenger feasibility — handle on file only | Channel Feasibility / Messenger | MUST |
| [FR-CDP-005](FR-CDP-005-whatsapp-feasibility-installed-probe.md) | WhatsApp feasibility — local installed-app probe via injected closure | Channel Feasibility / WhatsApp | MUST |
| [FR-CDP-006](FR-CDP-006-facetime-and-phone-always-feasible.md) | FaceTime and phone are always feasible — phone is the GSM hard floor | Channel Feasibility / GSM Hard Floor | MUST |
| [FR-CDP-007](FR-CDP-007-chain-preferred-secondary-phone.md) | Chain resolver — preferred → secondary → phone, dedupe, at-most-once, never dead-ends | Chain Resolution / Core | MUST |
| [FR-CDP-008](FR-CDP-008-fellbackfrom-attempt-order.md) | `fellBackFrom` carries skipped channels in attempt order | Chain Resolution / Announcement Data | MUST |
| [FR-CDP-009](FR-CDP-009-explicit-pick-wins-as-preferred.md) | Preferred input — an explicit per-contact/family pick wins as the chain's preferred | Chain Resolution / Input | MUST |
| [FR-CDP-010](FR-CDP-010-tap-buttons-route-the-chain.md) | Address-book and family-contact call buttons route the chain | Call Paths / Tap Buttons | MUST |
| [FR-CDP-011](FR-CDP-011-missed-call-dial-back-routes-the-chain.md) | Missed-call dial-back routes the chain | Call Paths / Missed-Call Dial-back | MUST |
| [FR-CDP-012](FR-CDP-012-voice-global-default-settings-primary.md) | Voice path — MethodResolver global default becomes the settings primary, mapped by call type | Voice Path / Method Resolution | MUST |
| [FR-CDP-013](FR-CDP-013-fallback-before-spoken-confirmation.md) | Fallback resolves before the spoken confirmation; the prompt names the routed channel | Voice Path / Spoken Confirmation | MUST |
| [FR-CDP-014](FR-CDP-014-override-protocol-preserved.md) | Override protocol and near-miss disclosure preserved unchanged | Voice Path / Override Protocol | MUST |
| [FR-CDP-015](FR-CDP-015-launch-fail-fallback-announced.md) | Launch-fail fallback (best-effort), announced via the existing spoken-outcome lane | Launch / Recovery | MUST |
| [FR-CDP-016](FR-CDP-016-automatic-routing-with-announcement.md) | Automatic routing with a spoken announcement — no ask-before-fallback | Call Paths / Announcement | MUST |
| [FR-CDP-017](FR-CDP-017-localisation-new-strings.md) | Localisation — new ne/en strings; spoken language matches the session | Localisation | MUST |
| [FR-CDP-018](FR-CDP-018-preserved-behaviours.md) | Preserved behaviours — no new dialogue flow, emergency semantics untouched, no silent failures | Safety Boundary / Regression | MUST |
| [FR-CDP-019](FR-CDP-019-device-validation-completion-gate.md) | DV-1..7 device validation recorded and passed (completion gate) | Validation / Completion Gate | MUST |

## Priority semantics

Every requirement is **MUST**. The frozen design has no phase structure — it is a single-release
feature whose every item is bound by the feature constitution's Success Criteria and the DV-1..7
completion gate (including the "best-effort" launch-fail hop, whose binding part — the
never-silent announcement — is a DV-3 item). No item is optional or deferrable within the frozen
scope; nothing is added beyond it (see the top-level index "Out of scope").

## Areas

Settings / Primary Dialer (1), Settings / Fallback Dialer (1), Settings / Persistence (1),
Channel Feasibility / Messenger (1), Channel Feasibility / WhatsApp (1), Channel Feasibility /
GSM Hard Floor (1), Chain Resolution / Core (1), Chain Resolution / Announcement Data (1),
Chain Resolution / Input (1), Call Paths / Tap Buttons (1), Call Paths / Missed-Call Dial-back
(1), Voice Path / Method Resolution (1), Voice Path / Spoken Confirmation (1), Voice Path /
Override Protocol (1), Launch / Recovery (1), Call Paths / Announcement (1), Localisation (1),
Safety Boundary / Regression (1), Validation / Completion Gate (1).

## Traceability anchors

Every requirement traces to the owner-approved, frozen design
(`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md` — §1 Settings &
persistence, §2 Feasibility contract, §3 Chain resolver, §4 Tap paths, §5 Voice path, §6
Launch-fail fallback, §7 Localisation, §8 Tests, §9 Delivery, "Decisions (owner-approved)"
1–5, "Non-goals", "Risks & mitigations"), the feature constitution
(`specs/call-dialer-primary-secondary/constitution.md` — Feature Purpose & Scope, Channel
Resolution & Feasibility Contract, Safety & Compliance Delta, Feature Constraints 1–12,
Integration Surfaces, Success Criteria & Completion Gate DV-1..7), the workflow scope comment and
security focus areas (`.ai-sdd/workflows/call-dialer-primary-secondary.yaml`), and/or the
project constitution (`constitution.md` — Architecture Constraints, Standards, Release gates).
Nothing is derived from outside those sources.

## Related

- [NFR index](../NFR/index.md) — 10 non-functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
- [Feature constitution](../../call-dialer-primary-secondary/constitution.md)
- [Frozen design](../../../docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md)
