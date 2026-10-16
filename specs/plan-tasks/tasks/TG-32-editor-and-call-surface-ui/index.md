# TG-32: Editor and Call-Surface UI

> **Jira Epic:** Editor and Call-Surface UI

## Description
Delivers every user-visible surface: the wizard find/link steps with steering, the wizard photo step and save flow with honest write states, the CallView face/caption presentation, and the family-list link chip with batch face-identity migration and deletion of the legacy photo API.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-159](T-159-wizard-find-and-link-steps.md) | Wizard find step: link section, prefill, steering and claimant guard | M | T-152, T-158 | MEDIUM |
| [T-160](T-160-wizard-photo-step-and-save.md) | Wizard photo step, write-access cards and save flow | M | T-159 | HIGH |
| [T-161](T-161-callview-faces-and-caption.md) | CallView faces and result-row caption | M | T-152, T-157 | MEDIUM |
| [T-162](T-162-family-list-link-chip-and-face-migration.md) | Family list link chip, face migration and legacy photo API deletion | S | T-157, T-160, T-161 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): ~4 days
- Realistic (2 devs): ~5 days

## Notes
- F4 UI decision lands in T-160: `.written` renders `family.photo.state.updatedInSystem`; the design-doc comment alignment is deferred to T-165.
- T-162 is the final UI unit and pins deletion of `contactPhoto(for:)` with `testSyncContactPhotoResolverIsRemoved`.
