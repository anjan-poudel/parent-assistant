# TG-30: Contacts Access, Link Verification and Matching

> **Jira Epic:** Contacts Access, Link Verification and Matching

## Description
Implements the read-path spine of the feature: the `.limited` contacts-access gate, the verified system-contact link service with generation-guarded snapshots, the link-aware missed-call resolver, the family contact index with nickname maps, the link-aware unified search with tier and dedupe passes, and the resolver banding that keeps ambiguous nicknames away from the wrong person.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-148](T-148-contacts-access-limited-gate.md) | ContactsAccess.limited gate and reading conformance | M | T-144, T-145 | MEDIUM |
| [T-149](T-149-system-contact-link-service.md) | SystemContactLinkService actor with verified-link snapshots | L | T-145, T-148 | HIGH |
| [T-150](T-150-missed-call-resolver-link-aware.md) | MissedCallContactResolver link-aware resolution | M | T-148, T-149 | MEDIUM |
| [T-151](T-151-family-contact-index.md) | FamilyContactIndex with nickname maps and perf ceilings | M | T-145 | MEDIUM |
| [T-152](T-152-unified-search-tiers-and-dedupe.md) | UnifiedContactSearch nickname tier and link-aware dedupe | L | T-149, T-151 | HIGH |
| [T-153](T-153-contact-resolver-bands.md) | ContactResolver bands, margin table and voice nickname resolution | M | T-145, T-151 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~8 days
- Realistic (2 devs): ~10.5 days

## Notes
- This group carries the critical path through T-148 → T-149 → T-152.
- Same-file chains: T-148 → T-149 both touch address-book reading types; T-151 → T-152 both touch index/search consumers. Dependencies already enforce sequential execution for those pairs.
