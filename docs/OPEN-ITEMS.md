# Open Items

Tracked work not yet landed on `master`. New items get added at the top of
the table; completed items are struck through with the landing commit noted.


> **Ready-to-merge (2026-09-06):** the Home widget system merge is complete
> and verified on branch `merge/home-widgets` (commit `e1b9999`, 555 unit
> tests green) — one fast-forward step ahead of `master`. It is deliberately
> NOT on master yet because the main tree has another session's in-flight
> contacts work in 4 files; run `git merge merge/home-widgets` once that
> tree is clean. (A cross-session message was sent too, but may be pending
> approval — this note is the reliable channel.)

| # | Item | Status | Branch / Worktree | Notes |
|---|------|--------|-------------------|-------|
| 4 | Wake word ("Hey Sahayak") | not started | `task/wake-word` (`.claude/worktrees/wake-word`) | Brief at `TASK.md` in that worktree |
| 5 | ~~Gemini cost governance~~ | landed `a50b61c` | ~~`task/cost-governance` (`.claude/worktrees/cost-governance`)~~ | ~~Brief at `TASK.md` in that worktree~~ |

---

## #4 — Wake word ("Hey Sahayak")

**Goal:** always-on mic activation per the original product brief ("always on
mic — like Siri"), replacing tap-to-talk as the primary entry point.

**Scope (per the staged `TASK.md`):**
- Settings → "Voice activation" screen: honest status (active / needs setup),
  plain-language (en+ne) explanation, a persisted on/off toggle. Disabled or
  unconfigured = today's exact behavior, no dead ends.
- `AppCoordinator.makeWakeWordEngine()` honors the toggle (off →
  `NullWakeWordEngine` even when key + .ppn exist) and gains an
  `EncryptedLocalStorage` fallback read for the Picovoice access key (paste-in
  field on the Settings screen) when the Info.plist key is absent.
- `docs/wake-word-setup.md`: family-facing steps — Picovoice Console account,
  train "Hey Sahayak" (document the no-Nepali-phonemes caveat and the
  English-phoneme phrase choice), drop the iOS `.ppn` into
  `ios/ElderlyAssistant/Resources/`, enter the key.
- Self-hearing mitigation: suppress wake-word processing while the speaker is
  speaking (flag consulted from `noteSpeakingStarted/Ended`; do NOT switch the
  global audio-session mode — regression risk).
- Battery-honesty copy on the Settings screen (always-listening costs battery).

**Hard constraints:** no fake/placeholder keys or .ppn files anywhere;
`NullWakeWordEngine` stays the honest default until real artifacts exist; do
not touch HomeView, CommandRouter, VoicePipeline's state machine, or
GeminiClient.

**Activation requires (not in repo, by design):** a Picovoice access key and a
trained `hey-sahayak_ios.ppn`.

## #5 — Gemini cost governance (daily counter + soft cap)

**Goal:** a local per-day Gemini call counter with a family-configurable soft
daily cap, so a failure mode (false wake-word loops, retry storms) can never
become a runaway bill. Flagged as the blocking prerequisite for safely shipping
the vision features to a real user (v2 design §3.2/§7; appliance design §8).

**Scope (per the staged `TASK.md`):**
- `GeminiCostGovernor` (new, `Services/Gemini/`): persisted daily counts
  (date-rolled, old days pruned), `softDailyCap` (default 200,
  family-editable), `allowsCall()` / `recordCall()`. Thread-safe (serial queue
  or lock — `send(_:)` is called concurrently). Date injected for testability.
- `GeminiClient` takes an optional governor (default nil = unlimited, current
  behavior preserved). Cap reached → throw `dailyCapReached` BEFORE the network
  call; success AND HTTP/network failures count as billable attempts;
  `notConfigured` does not count. Plugins inherit the cap for free through the
  shared client (no per-plugin special-casing).
- Settings → Gemini AI screen (extend, no new row): today's count + cap,
  cap editor, plain-language en+ne explanation.
- Observability: `gemini_cost/daily_cap_reached` event; `daily_cap_warning`
  once per day at 80%.
- User-facing behavior at cap: invisible to the elder — the existing
  deterministic keyword fallback (medication/emergency keep working with zero
  network). Verify `GeminiCommandInterpreter.interpret`'s generic error path
  actually engages the fallback for `dailyCapReached`.

**Hard constraints:** no time-zone cleverness beyond local-calendar day
rollover; do not touch IntentPrompt, CommandRouter, HomeView, or the plugin
registry/plugins.

---

*Process note: each item ships via its own worktree branch, full build + test
(`310` baseline has since grown — current suite is `552` unit tests), commit
with the bracketed label prefix, merge to `master` after verification, then
strike the row here with the landing commit.*
