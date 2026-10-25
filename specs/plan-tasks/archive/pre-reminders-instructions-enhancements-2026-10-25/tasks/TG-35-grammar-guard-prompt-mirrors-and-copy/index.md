# TG-35 — Grammar Guard, Prompt Mirrors and Localised Copy

> **Jira Epic:** Grammar Guard, Prompt Mirrors and Localised Copy

## Description
The verification and words layer behind the chat surfaces: the deterministic grammar guard (verify-never-rewrite), the machine-checked prompt mirrors that make the style spec a single source of truth in fact, and the bilingual copy (consent, disclosure, indicator, revocation, safe templates) every elder-facing surface speaks. Nothing in this group sends anything anywhere; it exists so that what is spoken is verified and what is written is human.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-169](T-169-nepali-grammar-guard-core.md) | NepaliGrammarGuard: deterministic verdict, never a rewrite | M | T-166 | HIGH |
| [T-170](T-170-prompt-mirror-discipline.md) | Prompt mirror discipline: chat template seed, persona clauses, guard lexicons | S | T-166, T-167, T-168, T-169 | MEDIUM |
| [T-171](T-171-localisation-consent-and-safe-template-copy.md) | Localisation: consent, disclosure, indicator, revocation and safe-template copy | M | T-166 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): ~4.5 days
- Realistic (2 devs): ~3 days

## Group-wide gates and conventions
- Scoped-suite gate and the pre-existing baseline note hold as in TG-34. The mirror script runs inside the scoped flow; its exit code is part of each unit's evidence.
- Guard integrity is the group's hard rule: the guard verifies, it never rewrites. Any diff that has the guard producing replacement text fails review on sight — the shipped polisher rule ("grammar stays the models' job") stands.
- Copy is data, not prose: every string ships through the catalogue with both languages and slot parity; no user-visible string is authored in code.
- Byte-identity, not semantic equality, governs every mirror: a legitimate change edits the source and regenerates the mirrored seed in the same commit.
