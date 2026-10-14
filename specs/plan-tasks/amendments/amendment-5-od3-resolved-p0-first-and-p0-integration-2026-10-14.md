# Amendment 5 — OD-3 resolved as P0-first; P0 integration plan (2026-10-14)

Status: **applied**. Source: **operator decision** relayed by the main session on 2026-10-14
(Slack question `q-ask-2f6a8883`) — recorded with operator provenance: this is an owner-level
decision that arrived via relay, not an in-session approval by any agent. Supersedes the
OD-3 "open owner question, not decided" status recorded in
`amendment-3-lean-review-gates-and-od3-2026-10-14.md` and mirrored in `plan.md`'s ordering note.

## The decision

OD-3 (P0-versus-P1 sequencing preference, recorded open by the design) is **RESOLVED:
P0-first**. The P0 runtime slice lands before the P1 training legs.

## Consequences for the run

- **P0 integration gate:** when **waves 0–4 are green and T-185 (release log-safety gate)
  passes**, prepare the P0 integration — push `feat/conversational-nepali-replies` and raise
  the PR against master (standing rule: integrate via PRs; no direct cherry-pick/merge). The
  **P0 package = waves 0–4 only**. The PR's review and merge remain a **normal reviewed
  merge** — the coordinator pushes the branch and raises the PR; merging is not autonomous.
- **P1 continues in the same worktree on top of the PR head** (T-183 QLoRA run, T-184 gated
  catalog swap). The swap stays behind its green gates regardless of the P0 PR.
- **Conflict/drift policy:** if merge conflicts or master drift complicate the PR, flag to the
  main session rather than force-resolving.
- The declared wave graph already matches the P0-first ordering; no re-layering is needed.
  `plan.md`'s ordering note is updated to record the resolution.
- Slack record: this agent has no Slack access — the main session resolves/closes the Slack
  question record (or re-surfaces it as a recorded decision) per its window.

## Tension recorded (plan phase-view wording vs the operator's package)

`plan.md`'s phase view describes P0 as "the runtime units (TG-34 ... TG-36) with the release
gate T-185 (wave 4) and the runtime half of T-186 (wave 7)". The operator's P0 package
definition is **waves 0–4 only** (T-186's sweep therefore stays post-PR, in the P1-window
continuation of the run). Recorded as received — the operator's definition governs; the plan
phase-view line should be read against this amendment.

## Housekeeping

- This amendment and the `plan.md` ordering-note edit ride the **Wave-2 close commit** (with
  `amendment-4` and its `plan.md`/`workflow.yaml` edits).
