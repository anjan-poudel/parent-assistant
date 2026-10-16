# TG-29: Sequencing Gate and Identity Foundations

> **Jira Epic:** Sequencing Gate and Identity Foundations

## Description
Delivers the precondition gate for all shared-surface work (call-dialer merge verification per NFR-FCU-008) plus the identity foundations everything else compiles against: the `FamilyContact` model with `SystemContactLink` and multi-nickname storage, byte-level photo-store access, and the frozen localisation/disclosure surface.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-144](T-144-sequencing-gate-call-dialer-merge.md) | Sequencing gate: call-dialer merge verification + master merge | S | — | MEDIUM |
| [T-145](T-145-family-contact-identity-model-and-nicknames.md) | FamilyContact identity model, link storage and multi-nickname migration | L | T-144 | HIGH |
| [T-146](T-146-contact-photo-store-bytes.md) | ContactPhotoStore byte access and unlink copy helper | S | — | LOW |
| [T-147](T-147-localisation-keys-and-usage-disclosure.md) | Frozen L10n keys (21, en+ne), coverage pins and NSContactsUsageDescription | M | T-144 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): ~4 days
- Realistic (2 devs): ~4.5 days

## Notes
- T-144 is the single hard precondition of the whole plan: it must complete (and report) before any unit touching AppCoordinator, wizard files, SettingsView/CallingSettingsView-adjacent surfaces or LeafViews begins.
- T-146 is deliberately surface-independent and may start immediately in parallel with T-144.
