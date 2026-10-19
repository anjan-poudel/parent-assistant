# T-191 — owner-descope record (2026-10-15)

**Status: DESCoped by the owner — not implemented in this run.** This record exists because
plan risk 10 requires descoping to never be silent: the leg completes with an explicit
owner-descope record instead of an artifact.

**Decision.** Owner decision of 2026-10-15 (relayed via the main session): P2 conversation
polish is separated from the CNR run as its own initiative — home
`docs/features/2026-10-15-p2-conversation-polish-initiative.md` (main checkout). The four P2
legs — T-188 (DPO on judge preferences), T-189 (romanized Nepali chat), T-190 (4B tier
candidate and admission), T-191 (this leg: consent-based real transcripts for future mixes,
FR-CNR-029) — are descoped from this run.

**Umbrella record.** `specs/plan-tasks/amendments/amendment-6-p2-descoped-2026-10-15.md`.

**Declared files.** Not produced by this run: `tools/train-intent/src/transcript_intake.py`.
This file (`specs/CNR-p2-transcripts-notes.md`) exists only as this descope record.

**Accounting (T-192).** T-192 (feasibility honesty statement) stays in this run and reports
this leg as owner-descoped, citing this record — no measured outcome is claimed here; the
consent-regime intake work is owned by the successor initiative. The data-provenance
constraint that motivated this leg (no unconsented user content reaching mixes; plan risk 3 /
advisory mapping) is unchanged and remains covered in this run by T-180's ship-mix manifest
enforcement.
