# P2 — Conversational polish initiative (deferred from CNR)

**Status:** deferred — separated out of the `conversational-nepali-replies` (CNR) feature run by owner decision, 2026-10-15. Each leg was descoped from the CNR run with an explicit owner-descope record; CNR's T-192 feasibility-honesty report accounts for all four legs.

**Prerequisite to start:** the CNR v17 chat-aware model is live via the gated catalog swap (T-184), and the DV protocol (T-187) has run.

**Re-entry:** scaffold this as its own ai-sdd feature (`/sdd-scaffold`) when the owner chooses to start it. The unit specs already exist under `specs/plan-tasks/tasks/TG-39-p2-polish-and-feasibility-honesty/` in the CNR worktree and carry over as-is.

## The four legs

| Unit | Leg | What it delivers |
|---|---|---|
| T-188 | DPO on judge preferences | Preference-optimization training run on the judge's grammar/warmth pairs — the second GPU cycle to de-robotize replies further. ~3 dev-days + training time on the box. |
| T-189 | Romanized-Nepali chat | Chat handles romanized Nepali input (the "aja ke bar ho?" register); extends the 15% code-switch mixture to conversational turns. |
| T-190 | 4B-tier candidate + admission | The 4B chat variant for newer devices, behind latency/memory admission gates (jetsam risk #6 is the gate). |
| T-191 | Consent-based real transcripts | Opt-in pipeline to capture real Anzaan conversations as future training data (the long-term gold source). Best started after the consent UX is settled. |

## Context

These four were waves 9–10 of the CNR plan (the "owner-descopable P2 legs"). They are polish with clear re-entry points; nothing in the CNR run blocks on them. The CNR plan's critical path shortens from ~23 to ~19 dev-days without them.
