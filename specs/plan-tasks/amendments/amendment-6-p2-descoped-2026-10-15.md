# Amendment 6 — P2 descoped from this run; P2 becomes its own initiative (2026-10-15)

Status: **applied**. Source: **owner decision** 2026-10-15, relayed via the main session —
recorded with owner provenance: an owner-level decision that arrived via relay, not an
in-session approval by any agent.

## The decision

P2 (conversation polish) is separated from the `conversational-nepali-replies` run as its own
initiative, whose home is `docs/features/2026-10-15-p2-conversation-polish-initiative.md`
(main checkout). The four P2 legs — T-188 (DPO on judge preferences), T-189 (romanized Nepali
chat), T-190 (4B tier candidate and admission), T-191 (consent-based real transcripts) — are
**descoped from this run**.

## Applied per the plan's own rule (risk 10 — descoping must never be silent)

- Each of T-188 … T-191 completes with an explicit **owner-descope record** at its declared
  notes path (`specs/CNR-p2-dpo-notes.md`, `specs/CNR-p2-romanized-notes.md`,
  `specs/CNR-p2-4b-tier-notes.md`, `specs/CNR-p2-transcripts-notes.md`), each citing the
  owner's 2026-10-15 decision and this amendment.
- Unit state: the four legs are closed by those records (phase `implement`); the workflow's
  5-task shape is unchanged — they were units inside implement.
- **T-192 stays in this run** and must account for all four descoped legs in the feasibility
  honesty statement.
- **Run scope now closes the critical path at T-187** (about 19 days, the descoped
  contingency already noted in plan.md); T-192 remains as the statement for the sign-off
  package.
- Nothing in this run's shipped scope depends on the legs: plan.md framed each as
  owner-descopable and gated after the P1 swap live + the DV protocol run — neither
  precondition was reached, so the descope timing is coherent.

## Housekeeping

- Files: this amendment + the four descope notes ride the next unit close commit of this run.
  Per the 2026-10-15 ceremony-strip directive, the descope records are the required evidence;
  no further notes docs are authored for descoped legs.
