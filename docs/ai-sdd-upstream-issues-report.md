# ai-sdd: Root Cause and Long-Term Fix — Toward a Self-Healing Workflow

- **Date:** 2026-09-29
- **Audit basis:** all stalled ai-sdd sessions across elderly-ai-assistant and ai-coaching-assistant (Claude transcripts + on-disk `.ai-sdd/` state)
- **Framework repo:** `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude` (line references to this checkout)

---

## 1. Executive summary

**The decision: yes to self-healing — but not as a monitor bolted onto today's framework.** A
background agent that audits and repairs stalled work is the right end state. However, a monitor
built on the current state machine would inherit the same bugs that stalled the sessions it is
supposed to save: it would have to complete tasks with `complete-task`, resolve gates with `hil`,
and clear locks with `task reset` — the exact machinery that failed in every stall recorded
below. Worse, an auto-fixer with unguarded authority could paper over genuine human gates (the
T-013-a T2 safety sign-off) and mark unreviewed work as done.

The correct order is:

1. **Fix the root cause in the framework**: replace the single-writer state machine with an
   **evidence-based, multi-writer state model** with an idempotent reconciler (Section 4).
2. **Add a deterministic watchdog** (cheap, non-agentic) that detects divergence in seconds
   (Section 5).
3. **Add a bounded-autonomy remediation agent** that consumes watchdog findings and repairs
   only what its charter allows (Section 6).

This is the difference between patching symptoms (a dozen more workarounds) and removing the
failure mode (no state can diverge undetected).

---

## 2. Root cause — why the sessions stall

### 2.1 The single-writer assumption

The framework is built around **one trusted driver**: the `ai-sdd run` engine. Every piece of
state machinery assumes only the engine writes state:

| Machinery | File | Assumption |
|---|---|---|
| Task transitions | `src/core/state-manager.ts`, `src/types/index.ts:42-55` | only the engine moves PENDING→RUNNING→COMPLETED |
| HIL queue | `src/cli/commands/hil.ts` | only engine-driven gates create/block on items |
| PID lock | `src/cli/bootstrap/pid-lock.ts` | engine owns the session lock |
| Manifest | `src/constitution/manifest-writer.ts:99` | regenerated from the engine's single state view |
| Session resolution | `src/core/session-resolver.ts:103-192` | one feature = one active session = one state file |

`workflow-state.json` is a **single mutable file, single-writer**. There is no append-only
evidence store anywhere in the framework (verified: `grep -rn "evidence" src/` finds only overlay
decision metadata, not records).

### 2.2 The multi-writer reality

The operating pattern that actually evolved across both repos is **many writers**:

- orchestrator sessions spawning task subagents directly (the repo's `/sdd-run` skill, deliberately);
- forks running unit batches in parallel and reporting back by message, not by state write;
- crashed-and-resumed sessions (laptop crashes, killed agents) picking up mid-flight work;
- humans deferring gates ("owner directive") and never being re-asked;
- work continuing outside any engine process for days (the pilot-journey `implement` phase was
  worked by at least five sessions and one fork).

This is not misuse to be trained away. It is the natural scaling pattern — the framework's own
`max_concurrent_tasks`, paired review, and fork-friendly design encourage it. The framework just
never gave those writers a legal way to record their work.

### 2.3 State divergence — the failure mode

When work is done outside the engine, `workflow-state.json` stops describing reality. **Every
stalled session in this audit is an instance of state divergence going undetected:**

| Stall (evidence) | Divergence | Why the machinery can't see or fix it |
|---|---|---|
| pilot-journey `implement` RUNNING since 2026-09-21, fork delivered its final report | work complete, state stuck RUNNING | no writer other than the engine may move RUNNING→COMPLETED; the fork had no API to record completion |
| T-013-a `DEFERRED_BY_OWNER_DIRECTIVE` since 2026-09-21, reviewer verdict GO | gate open, owner never re-asked | DEFERRED is not in the framework's status vocabulary; `status` only shows PENDING items |
| "Invalid transition PENDING → COMPLETED" (repeated across sessions) | direct-dispatch wrote artifacts but no state | `VALID_TRANSITIONS.PENDING = ["RUNNING","CANCELLED"]`; nothing in the dispatch path sets RUNNING |
| gemini-validation-pilot all-PENDING since 2026-09-20, abandoned | work pivoted, state never written | branch-driven resolution silently targeted the wrong run |
| `sessions/default` + `sessions/oatutor-port`: dead `engine.pid` (40941, 83914), RUNNING/PENDING tasks for months | engine died, lock and tasks orphaned | stale-pid cleanup only runs on the *next* engine start for that session; no session ever restarts |
| "workflow definition could not be loaded" when completing plan units (T-0XX) | unit work done, unrecordable | `complete-task.ts:299-337` returns the same error for "task not in workflow" as for "workflow broken"; units aren't tasks at all |
| Manifest rows for other features dropped after each `complete-task` | multi-feature state, single-view writer | `manifest-writer.ts:99` regenerates from one run's state only |
| SEC-002 NEEDS_REWORK flips on 40-char file paths | a validator bug **writing state** | `patterns.ts:169` allows `/` in the 40-char class; quarantine level turns each false positive into a state mutation |

### 2.4 Why patching the symptoms won't hold

Each of the eight issues could be patched (auto-advance in `complete-task`, better error messages,
a regex fix). Those patches reduce friction but **re-encode the single-writer model**. The next
new writer — another fork, another crash, another deferred gate — recreates divergence in a new
shape. The audit found exactly this: the elderly repo already applied workarounds
(`task reset`, state repair plans) in August–September, and the same class of stalls re-appeared
in the coaching repo in late September. Workarounds did not compound; they were re-derived from
scratch each time.

The long-term fix must change the invariant itself: **state must be derived from evidence, and
evidence must be writable by every legitimate writer.**

---

## 3. The self-healing question, answered

**Should a separate background agent audit, monitor, and automatically fix stalled sessions?**

**Yes, as the end state — but only after Section 4, and with a bounded charter.** The reasoning:

**Why a monitor on today's framework fails.** To fix a stall, the monitor must use the same
machinery that caused it: `complete-task` (rejects PENDING→COMPLETED), `hil` (can't see deferred
items), `task reset` (plugin command behind an env flag), or raw JSON edits (what human sessions
resorted to). A monitor that edits state JSON directly is the most dangerous possible writer —
it operates exactly where the human gates live.

**Why a monitor on the fixed framework is cheap and safe.** Once state is derived from
append-only evidence (Section 4), "fixing a stall" becomes: (a) detect missing/inconsistent
evidence — a deterministic diff, not agentic judgment; (b) append the missing evidence records;
(c) re-run the reconciler. Mechanical, idempotent, and safe by construction. The agent never
edits state; it only appends evidence the charter allows.

**Bounded autonomy — the monitor's charter:**

| Action | Authority | Rationale |
|---|---|---|
| Remove confirmed-stale `engine.pid` files | **AUTO** | pid liveness is a deterministic fact |
| Append heartbeat evidence for work it observes live | **AUTO** | keeps RUNNING phases honest |
| Close a phase whose evidence is complete and whose gates are all RESOLVED | **AUTO** | pure reconciliation; no judgment |
| Re-raise open gates older than N days to the owner (DEFERRED, PENDING) | **AUTO** | notification, not resolution |
| Archive runs abandoned > N days with no evidence and no gates | **AUTO** (with report) | policy decision pre-recorded by owner |
| Resolve a T1/T2 human gate, or mark NEEDS_REWORK/FAILED on judgment | **NEVER** | human authority; the T-013-a case |
| Touch code, merge, push | **NEVER** | outside the monitor's system boundary |
| Anything else | **ESCALATE** | report with recommendation, wait for owner |

This matches the autonomy grant already in use for overnight sessions ("decide everything
loggable, no HIL until end, no merges, morning report") — the monitor formalizes exactly that
charter as infrastructure.

**Economics.** An always-on agent polling every N minutes burns tokens for mostly-empty checks.
The right split: a **deterministic watchdog** (milliseconds, no model) runs at session start and
on a cron (~every 6 h); the **agentic remediator** is spawned only when the watchdog reports
findings. Detection is continuous and free; judgment is paid for only when there is something to judge.

---

## 4. Target architecture, Layer 1 — evidence-based multi-writer state (the framework fix)

### 4.1 Evidence store

New append-only store: `.ai-sdd/state/evidence/` (one JSONL per record stream). Any writer —
engine, CLI, task subagent, fork, orchestrator session, watchdog, remediator — appends records
through a tiny typed library (`record-evidence.ts`). Record types:

```
task-started        { task, writer, started_at }
unit-completed      { unit, phase, outputs[], hashes[], gates_required[] }   ← new: makes unit work first-class
output-written      { task, path, sha256, contract? }
heartbeat           { task|run, writer, at }                                  ← fixes orphaned-RUNNING detection
hil-created / hil-resolved / hil-deferred / hil-rejected
                    { gate_id, task, risk_tier, by, at, reason }              ← deferred becomes vocabulary
phase-close-request { task, evidence_refs[] }                                 ← fork's "final report" becomes a record
run-archived        { run, by, at, reason }
```

Append-only + per-record integrity (write temp + fsync + rename; sha of previous line) makes the
store corruption-resistant; the reconciler is idempotent, so replays are safe.

### 4.2 Reconciler

`workflow-state.json`, the constitution manifest, and the spec-graph become **derived views**,
recomputed from evidence by an idempotent reconciler on every command (cheap: one pass over small
JSONL files). Consequences, mapped to the stall catalog:

- **No invalid-transition errors possible.** Completion = evidence present + guards satisfied.
  The PENDING→COMPLETED rejection (UP-1) disappears structurally — there is no transition table
  to violate; a direct-dispatch writer's `output-written` + `phase-close-request` records close
  the phase exactly like the engine's would.
- **Unit tasks become first-class** (UP-2): `unit-completed` records feed the phase's evidence
  set; `complete-task` gains a `--unit` mode that appends evidence instead of mutating a phase.
- **Manifest merge is automatic** (UP-4): the reconciler renders from *all* runs' evidence, so
  no feature's rows can drop another's.
- **Orphaned RUNNING becomes detectable** (UP-5/UP-8): the reconciler flags any RUNNING task
  whose latest `heartbeat` is older than a threshold; stale `engine.pid` is checked the same way.
- **Gates block closure by evidence** (UP-7): a phase with an open `hil-*` gate whose latest
  record is not `hil-resolved` cannot close; `status` lists open gates with age — including
  DEFERRED ones.
- **Resolution cross-check** (UP-6): the resolver must confirm the target feature's run exists
  in the resolved project before accepting evidence; mismatch → loud warning, require explicit
  `--feature`/`--project`; never prompt in non-TTY.

### 4.3 Kept from the patch list

Two defects are validator bugs independent of the architecture and stay as straightforward fixes:

- **SEC-002 regex** (`src/security/patterns.ts:169`): drop `/` from the 40-char class
  (`[A-Za-z0-9/+=]` → `[A-Za-z0-9+=]`) — AWS keys never contain `/`; add the failing fixture as
  a regression test.
- **Error-message hygiene** in `complete-task.ts:299-337`: distinguish "workflow not found" from
  "task not in workflow" (discriminated return, no partial writes).

### 4.4 Migration

Existing state imports as baseline evidence on first run of the new reconciler
(`workflow-state.json` tasks → synthetic records; `hil/*.json` items → `hil-*` records;
`engine.pid` → checked and dropped if stale). One-time, backward-compatible.

---

## 5. Target architecture, Layer 2 — deterministic watchdog

Extend the existing `sdd-debug` skill into `sdd-health`, a pure CLI check (no model):

- stale `engine.pid` (pid liveness),
- RUNNING tasks with stale/missing heartbeat ("orphaned"),
- open gates (PENDING or DEFERRED) older than N days,
- runs with all tasks PENDING older than N days (abandoned scaffolds),
- evidence↔state divergence (reconciler would change something),
- manifest drift vs evidence.

Output: machine-readable findings JSON (plus human summary). Triggers: session start
(automatically, before any `/sdd-run`) and a cron (~6 h). This is what turns the audit I did
manually today — reading transcripts, diffing state files, checking pids — into a free,
continuous check.

---

## 6. Target architecture, Layer 3 — bounded-autonomy remediation agent

A background agent (cron-triggered, or spawned by the harness when the watchdog returns
findings) applies the charter table in Section 3. It:

1. reads the watchdog findings,
2. for each finding, determines AUTO / NEVER / ESCALATE,
3. AUTO items → appends evidence via the record library, re-runs the reconciler, logs the action,
4. NEVER items → leaves untouched, includes in the report as "awaiting owner",
5. produces a morning-style report (mirrors the existing overnight-autonomy-grant pattern).

**Dry-run first:** ship the remediator in "propose-only" mode (reports what it *would* do) for
one week; enable AUTO repairs only after the charter's behavior is verified against real stalls.

---

## 7. Roadmap

| Phase | Work | Eliminates | Verification |
|---|---|---|---|
| **A — framework** | evidence store + record library + reconciler (derived state/manifest/spec-graph) + gates-first-class + heartbeat + resolution cross-check + migration + SEC-002 fix + complete-task error split | UP-1, UP-2, UP-4, UP-5, UP-6, UP-7, UP-8 (structural) and UP-3 (validator fix) | replay this audit's stalled fixtures against the new reconciler — each must be detected and closable via evidence alone |
| **B — watchdog** | `sdd-health` CLI + session-start hook + 6 h cron | time-to-detect goes from weeks (human notices) to ≤6 h | inject a synthetic stall; assert the cron report flags it |
| **C — remediator** | bounded agent per Section 6, dry-run week, then AUTO subset | time-to-repair goes from per-session re-derivation to automatic | T-013-a gate re-raised to owner within one cycle; orphaned locks cleaned; no gate ever auto-resolved |
| **D — measurement** | emit metrics: stalls-at-rest, median detect/repair time, AUTO actions/week, ESCALATE rate | continuous proof the system converges | review after 4 weeks; extend AUTO subset only for actions with zero misrepair |

---

## 8. Risks and mitigations

- **Gate integrity** (the T-013-a class): remediator can never resolve human gates; reconciler
  cannot close a phase with an open gate; both are enforced in code, not by prompt.
- **Monitor cost**: watchdog is deterministic and free of model calls; agent runs only on findings.
- **Authority creep**: charter is a whitelist (AUTO items enumerated); anything new defaults to ESCALATE.
- **Evidence corruption**: append-only JSONL with per-line checksums; reconciler is idempotent and
  its output is always rebuildable from evidence.
- **Framework scope**: this is upstream work in ai-sdd-claude; the repo-side changes are limited
  to adopting the record library in the `/sdd-run` skill and the watchdog/remediator config.

---

## 9. Success criteria

1. **No stall can be silent**: any state↔reality divergence is flagged within one watchdog cycle (≤6 h).
2. **No stall is unrecoverable**: every divergence has a mechanical repair path through evidence,
   except open human gates, which are re-raised to the owner automatically.
3. **Human authority untouched**: zero T1/T2 gates resolved by any agent in any recorded run.
4. **Workarounds die**: `task reset`, manifest-union restoration, 12-char hash prefixes, and
   state-JSON hand-edits disappear from session transcripts.

---

## Appendix — audit artifacts

- Coaching state: `/Users/anjan/workspace/projects/ai-coaching-assistant/.ai-sdd/{runs,sessions}/…`
- Deferred gate: `…/runs/pilot-journey-navigation/hil/0c0828b6-8703-4e4e-a548-2a5338fdc05b.json`
- Transcripts: `~/.claude/projects/-Users-anjan-workspace-projects-{ai-coaching-assistant,elderly-ai-assistant}/*.jsonl`
- Framework files: `src/types/index.ts`, `src/core/state-manager.ts`, `src/core/session-resolver.ts`,
  `src/core/engine.ts`, `src/core/project-root.ts`, `src/cli/commands/complete-task.ts`,
  `src/cli/commands/hil.ts`, `src/cli/bootstrap/pid-lock.ts`, `src/security/patterns.ts`,
  `src/constitution/manifest-writer.ts`
