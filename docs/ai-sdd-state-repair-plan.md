# ai-sdd State Repair & Repo Hygiene — Plan (#6)

**Status:** Plan (for implementation by a future session)
**Date:** 2026-08-30
**Problem:** `.ai-sdd/state/workflow-state.json` shows `implement` as PENDING (no outputs) while substantial iOS/Android implementation exists, and its `project` path points at the old location (`/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`), so `/sdd-run` will behave incorrectly. Additionally `ios.bak/` sits untracked at the repo root and risks accidental commits.

## 1. `ios.bak/` disposal

1. **Confirm intent with the owner** before deleting: `ios.bak/` is a manual backup of `ios/` created during the other session's work.
2. If the backup is confirmed redundant (current `ios/` is the good state — the commit `95cc3d1` contains it):
   - Delete `ios.bak/`, **or** move it outside the repo (e.g. `~/backups/elderly-ai-assistant-ios-bak-<date>`).
3. Add to `.gitignore`: `ios.bak/`, plus verify `ios/build/`, `*.xcuserdata`, `.DS_Store`, `.serena/` are ignored.

## 2. `.ai-sdd/state/workflow-state.json` repair

1. Update `project` → `/Users/anjan/workspace/projects/elderly-ai-assistant`.
2. Reflect reality in `tasks`:
   - `define-requirements` … `plan-tasks`: stay `COMPLETED` (outputs exist on disk).
   - `implement`: set `status: "RUNNING"` with `started_at` = the commit date of `95cc3d1` (2026-08-30) and record the known output paths (native code dirs are not single-file outputs; note them in a comment or `outputs` array pointing at `ios/` + `android/`).
   - `review-implementation`, `security-test`, `final-sign-off`: stay PENDING.
3. Back up the file first (`cp workflow-state.json workflow-state.json.bak-<date>`), since the state manager writes atomically and a bad edit is annoying to unwind.

## 3. Validate

- If the ai-sdd CLI is available: run `ai-sdd status` (or `bun run …/cli/index.ts status`) and confirm the task table reads COMPLETED/RUNNING/PENDING as edited, and that `/sdd-run` next advances to `review-implementation` rather than re-running anything.
- If the CLI is unavailable, verify the JSON parses (`python3 -m json.tool`) and document in this plan that manual state repair was used.

## 4. Optional follow-ups (flag, don't block)

- The audit history shows `/sdd-run` repeatedly failed on nested-session launches and state resets; if that recurs, prefer the direct-agent + `complete-task` pattern documented in `audit-history.md`.
- Consider committing `docs/*plan*.md` (including this one) alongside the state fix so the session trail is in git.

## 5. Effort estimate

0.5 day (mostly owner confirmation + one JSON edit + validation).
