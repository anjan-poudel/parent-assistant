# Scaffold Report

**Mode:** brownfield-quickfix

**Bug:** Voice-turn OOM hardening: jetsam kills mid-conversation — completes and verifies the stopped direct-agent seed (changes A–F). Not a new feature surface: internal model-lifecycle/UI policy only; no new network or security surface; safety implications: none.

## Files Created

- `.ai-sdd/workflows/quickfix-voice-turn-oom-hardening-jetsam-kills-mid-conversation.yaml` (minimal quickfix pipeline: task `implement-fix`, tests-must-pass T1 gate, HIL off)
- `docs/quickfix-voice-turn-oom-hardening-jetsam-kills-mid-conversation-report.md` (this report)

## Seed Branch State (implementation seed — authoritative for the implement task)

- **Branch:** `worktree-voice-oom-hardening` @ `688f980` — worktree `.claude/worktrees/voice-oom-hardening`, clean tree, 5 commits, nothing pushed.
- **Commit map:**
  - `56073e8` — E: STT default v3→v6 (both construction sites; 4 test pins updated)
  - `30514b2` — D: encoder slot `evictable: true` (+ `testCriticalPressureEvictsTheLightEncoder`)
  - `22103bc` — A: post-turn over-budget short-circuit + generalized headroom gate
  - `870d186` — brief doc + HANDOFF NOTE (`docs/2026-10-10-voice-oom-hardening-brief.md` in that worktree — full spec for B'/F and all code anchors)
  - `688f980` — WIP C: warm-start low-headroom gate — **INERT** (missing `AppCoordinator.startBootWarmPhase` wiring + WarmStart tests)
- **CRITICAL:** ZERO tests were executed on this branch and nothing is compile-verified. SourceKit hints that change A's `WhisperPostTurnPolicy.ResidencyConfig` may not satisfy `Equatable` — must-check item.
- **Implement task order:** (1) compile-check + run the scoped suites on the seed (`-only-testing` shape in the HANDOFF NOTE); (2) finish C wiring + tests; (3) implement B′ (pressure-tiered brain pick — installed-only, never download under pressure) and F (degraded-mode pill, ne/en copy in the note).
- **Merge gate:** device smoke on Anzaan (conversation → no jetsam) + fresh `JetsamEvent` pull, with the PR against master.
- **Out of app scope:** the system-layer wired-memory leak on the beta OS (mitigation: reboot + leave the beta).

## Next Steps

1. Review the quickfix workflow and the seed HANDOFF NOTE above.
2. Run `ai-sdd validate-config` to verify configuration.
3. Type `/sdd-run` to start — work continues on the seed branch `worktree-voice-oom-hardening` (verify branch continuity when the run starts; the seed state must be the run's base).
