# TG-39 — P2 Polish and Feasibility Honesty

> **Jira Epic:** P2 Polish and Feasibility Honesty

## Description
The owner-gated polish legs — preference tuning from the judge's own rubric, romanized chat, the 4B tier candidate, and consent-based real-transcript intake — plus the feasibility honesty statement the final sign-off consumes. Every leg here is descopable only by an explicit owner decision, each lands (or reports itself) as a gated, non-default candidate behind the full harness, and the statement records what was delivered, what was not, and the evidence for both.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-188](T-188-p2-dpo-on-judge-preferences.md) | P2: DPO on judge preferences (gated, non-default candidate) | L | T-181, T-182, T-184, T-187 | MEDIUM |
| [T-189](T-189-p2-romanized-nepali-chat.md) | P2: romanized Nepali chat, additive and measured | M | T-182, T-184, T-187 | MEDIUM |
| [T-190](T-190-p2-4b-tier-candidate-and-admission.md) | P2: the 4B tier candidate and its admission verdict | L | T-184, T-187 | MEDIUM |
| [T-191](T-191-p2-consent-based-real-transcripts.md) | P2: consent-based real transcripts for future mixes | M | T-180, T-184, T-187 | HIGH |
| [T-192](T-192-feasibility-honesty-report.md) | Feasibility honesty statement for the sign-off package | S | T-186, T-187, T-188, T-189, T-190, T-191 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~10 days (with box time for the two training legs)
- Realistic (2 devs): ~7 days

## Group-wide gates and conventions
- Descoping is an owner act, recorded explicitly (who, when, why) — never a silent skip. A descoped leg still completes with that record as its deliverable, and the feasibility statement reports it as descoped.
- Every leg that produces a model lands as a new gated, non-default candidate behind the full harness; no leg mutates a shipped entry in place.
- The romanized leg is additive or it does not land: Devanagari behaviour and every gate are unchanged by construction, and an unreliable outcome is reported, not hidden.
- Real transcripts enter mixes only through the consent regime (T-191); nothing in this group changes the app's STT, permissions or collection paths (FR-CNR-015's boundary stands).
- Honesty is the group's product: the feasibility statement quotes recorded evidence verbatim — a red measured as green, or a leg omitted, is a defect of the statement.
