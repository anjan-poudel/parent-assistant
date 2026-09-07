# Voice-OS Pivot & Productionisation Proposal

Date: 2026-09-07 · Status: proposal (decisions recorded, v1 spec in `2026-09-07-voice-os-shell-v1-design.md`)

## 1. Product direction (user-stated)

The app evolves from an AI assistant into a **voice-driven personal operating system** for
seniors and tech-challenged users, targeting languages poorly supported by Siri and
general-purpose assistants (Nepali first).

- Most features should be **plugins**, so OS features stay isolated.
- The app will split into a **caregiver app** (all settings and notifications) and a
  **parent's app** (the voice-first runtime).
- Voice commands should cover most day-to-day operations.

## 2. Current-state findings (codebase audit, 2026-09-07)

**The pivot is a reframe of architecture that already half-exists — not a rewrite.**

- iOS has an OS skeleton: layered routing ladder in `CommandRouter.route` (deterministic
  safety nets run before any model), hot-swappable engine seams (4 STT impls, local-LLaMA
  and cloud interpreter paths with persisted stack toggle, Piper TTS with system fallback),
  and a real plugin contract (`AssistantPlugin`) with locale gating, collision rejection,
  and honest-failure rules.
- ai-sdd L1/L2 **already design the caregiver app + zero-knowledge E2E relay** (double
  ratchet over a ciphertext-only broker, T-032/TG-07). The split is a designed path.
- Platform machinery under the safety promise is missing: medication escalation registered
  with BGTaskScheduler but **never submitted** (no `UNUserNotificationCenterDelegate`
  anywhere), `FamilyNotifier` is a print-and-return stub, no auth, no HealthKit, no
  Critical Alerts entitlement, no `PrivacyInfo.xcprivacy`, console-only observability, no CI.
- Security review passed with 3 blockers: biometric liveness/PAD, PIN lockout policy,
  device pairing + relay `KEY_REGISTER` auth.
- Android is a medication/family skeleton with **zero voice code**. Constitution still
  declares React Native while everything is native (cleanup plan unapplied). ~29 stale
  worktrees; unmerged `ios-mvp-voice`; uncommitted weather-routing work in
  `CommandRouter`/`TopicPreAnswer`/`WeatherTool` + tests.
- `docs/ios-platform-integration-plan.md` exists (ChatGPT-generated in another session,
  **not yet adopted** as a project roadmap). It covers a health vertical slice, notification
  /broker reliability (Phase 4), background-mode audit (Phase 8), privacy/App Store
  (Phase 9) — Track 1 slices overlap it heavily; adoption decision deferred to Track 1
  spec time. Its platform *constraints* (single `UNUserNotificationCenterDelegate` with
  action categories, AppCoordinator-as-composition-root, background execution is
  opportunistic) are technically valid regardless of authorship and are honoured in §7.

## 3. The OS reframe

**Kernel (privileged core — never plugins):** `VoicePipeline` (I/O bus), `CommandRouter`
ladder (dispatcher), safety-critical services (medication, escalation, future emergency
module), auth, storage. Matches the existing constitution rule: emergency must not depend
on anything that can fail.

**Userland = plugins, extended from 1 type to 4:**

1. **Skill plugins** — today's `AssistantPlugin` (calendar, routines, appliance).
2. **Engine plugins** — formalize existing STT/TTS/wake-word/LLM seams as versioned
   manifests, swappable per language and device tier.
3. **Integration plugins** — WhatsApp, calendar, health providers; one chokepoint each
   (the Gemini cost-governor pattern).
4. **Source plugins** (new) — things that *push speech into the system*: notification
   read-aloud, sensors, proactive briefings.

Every plugin gets: signed manifest (version, permissions, resource budget), lifecycle
(install/enable/disable/update — remotely, from the caregiver app), async isolation with
timeouts, per-plugin storage namespace (existing rule), observability routing. Crash
isolation stays process-internal on iOS; loud-failure culture already exists (collision →
drop plugin, never crash boot).

**Voice as the shell.** Single-utterance pipeline becomes a conversation manager (dialog
state, follow-ups, barge-in). Kernel speak-queue with priorities (emergency
non-cancellable). First OS capabilities are composition on existing machinery:
notification read-aloud = kernel event bus → speak queue; morning briefing =
RoutineScheduler + calendar + TopicPreAnswer weather + Piper TTS; app control = existing
deep links formalized into a controllable-app registry.

**Caregiver control plane.** Build the double-ratchet relay once (fixes the FamilyNotifier
stub *and* enables the split). Parent app = locked-down, voice-first, big buttons, no
settings. Caregiver app = schedules, thresholds, plugin enable/disable per parent's
capability, model/voice management, health dashboards, alert inbox. Pairing first:
QR + short code + TOFU + key verification.

**Android reframe:** the caregiver app needs no STT/TTS/wake word — Android can ship the
caregiver app while iOS is the parent device.

## 4. Sequencing — DECIDED: dual-track

- **A. Harden first** — safe, slow, invisible progress.
- **B. OS experience first** — fast visible progress on shaky machinery.
- **C. Dual-track (chosen)** — Track 1: safety-critical platform machinery (background
  escalation, real family alerts, auth, pairing, compliance). Track 2: cheapest OS slices
  first (read-aloud + briefing → app control → dialog manager), each landing as kernel
  extension or plugin with tests. Caregiver app starts once relay + pairing land.

## 5. Sub-project decomposition (dependency order)

1. **Groundwork** — constitution cleanup (native per-platform), prune stale worktrees,
   reconcile ai-sdd state drift. Fold into first plan's preconditions.
2. **Track 1 · Slice A: Background escalation machinery** — submit BGTaskScheduler
   medication check, `UNUserNotificationCenterDelegate` for ack deadlines, time-sensitive
   notifications, keychain-as-database fix, strip phantom Info.plist background modes,
   `FamilyNotifier` stub → honest failure/unavailable state (critique Stage 0).
3. **Track 2 · Slice A: Voice-OS shell v1** — FIRST SPEC (chosen). Kernel speak-queue +
   notification read-aloud + morning briefing.
4. **Track 1 · Slice B: Family alerts + relay + pairing** — real FamilyNotifier path,
   double-ratchet broker, device pairing. Foundation of the caregiver app.
5. **Caregiver app v1** — settings, schedules, plugin management (Android can go first).
6. **Track 2 · Slice C: Repair model** — universal voice actions (undo/repeat/
   read-state/correct/cancel/ask-missing/escalate) on top of the shell's speak-queue
   and `OutcomeSummary.undo` slot. Then app-control registry + dialog manager.
7. Later: auth (enrolment, lockout, liveness), My Day expansion ("what is next?",
   "what did I miss?"), plugin manifest v2 with capability injection, MLOps.

## 6. Productionisation hardening roadmap

**Now — platform machinery that unblocks the product promise:**

- Wire medication escalation: submit registered BGTask + `UNUserNotificationCenterDelegate`
  for ack deadlines.
- Replace FamilyNotifier stub with E2E broker path (design exists).
- Apply for Critical Alerts entitlement (long approval lead time).
- Remove phantom Info.plist background modes (`voip`/`push-to-talk`/`processing` declared,
  unimplemented — App Store rejection risk).
- `PrivacyInfo.xcprivacy` manifest; time-sensitive notifications.
- Fix keychain-as-database (C14): med/reminder state in Data-Protected storage, keychain
  only for keys.
- Real PhotoVerifier; FamilyNotifier + kill/relaunch tests; 100% coverage on
  safety-critical paths.

**This quarter:**

- Auth: voice-biometric enrolment + liveness/PAD (blocker 1), PIN lockout (blocker 2),
  device pairing (blocker 3).
- Observability: disk-persistent sanitised event log, crash reporting (MetricKit),
  wake-loop battery telemetry.
- CI: build + test + golden-corpus e2e on simulator.
- MLOps: background model downloads with resume, eviction/rollback, real WhisperKit
  Nepali catalog entry, eval harness (WER benchmarks, TTS bake-off, intent bake-off).
- espeak-ng GPL resolution (App Store blocker); Nepali wake word; the 1 missing `ne` key;
  hardcoded-English sweep.

**Before launch:**

- HealthKit + health-monitoring fail-safe; isolated emergency-call module.
- Cert pinning; SPM pinned to releases not branches; key rotation; adversarial
  prompt-injection corpus.
- Android strategy decision (caregiver-first recommended).
- ai-sdd reconciliation: update L1/L2 to reality (plugins beyond language packs, dual
  engine stacks, native per-platform).

## 7. First spec — Voice-OS shell v1 (decisions)

- **Scope (chosen):** kernel speak-queue with priorities + notification read-aloud +
  morning briefing.
- **Read-aloud mode (chosen):** active-app only — foreground, or lock-screen while the
  process lives. Honest about iOS limits; true background delivery is Track 1 work.
- **Delegate composition:** `NotificationReader` hooks into the single
  `UNUserNotificationCenterDelegate` facade (per ios-platform-integration-plan.md
  Phase 4), never owns the delegate — action categories and read-aloud share one entry
  point.
- **Capability-layer rule:** `SpeakQueue` is a capability composed by `AppCoordinator`
  (per ios-platform-integration-plan.md §2.3), not more coordinator-owned behavior.
- **Precondition:** commit/merge the in-flight weather-routing work first.

## 8. Collision risks

- Android has no voice stack — caregiver-first reframes this.
- Don't fork the STT stack mid-WhisperKit migration (`ios-mvp-voice` unmerged).
- Respect the Gemini daily cost cap; on-device-first constitution.
- TTS espeak-ng GPL question open (App Store blocker).

## 9. First-principles alignment (per docs/first-principles-project-critique.md)

Adopted 2026-09-07. The critique's ordering matches this proposal's sequencing; the
mapping is now explicit:

```text
Trust            -> Track 1 slices (hardening, Stage 0: make current claims true)
Reliable voice   -> Track 2 slices (shell v1, repair model, app control)
My Day           -> briefing (shell v1) grown into the unified daily planner
Caregiver        -> Track 1 Slice B + caregiver app v1
Native iOS depth -> health/emergency phases (later)
Providers        -> one official adapter at a time, last
```

**Adopted recommendations (non-destructive):**

1. **Honest product framing.** "Personal operating system" stays as the *internal*
   architectural ambition; external language uses the critique's defensible framing
   ("voice-first daily-life layer for iPhone users in their own language") and
   measurable promises ("ask for today's plan in Nepali", "get clear confirmation of
   what was saved"). No health-monitoring / emergency / 24-7 claims until those
   implementations pass their release gates (critique §2.4, §4.6, Decision 5).
2. **My Day is the product center.** The morning briefing is the seed of a unified
   deterministic daily planner (medication, routines, calendar, tasks, shopping,
   family calls). Next Track 2 slices after shell v1: "what is next?", "what did I
   miss?", "repeat that". An LLM may phrase, never prioritise — deterministic ranking
   (critique §5.2, Decision 2).
3. **Repair model is a first-class voice capability.** Universal voice actions as the
   next Track 2 slice: undo last safe mutation, repeat last confirmation, read current
   state, correct one field, cancel pending confirmation, ask what's missing, escalate
   to caregiver. `OutcomeSummary` already carries an `undo` slot — wire it for safe
   mutations (critique §3.2).
4. **Plugin discipline.** Plugins stay compiled-in (no marketplace). Adopt capability
   injection: replace blanket `GeminiClient` + bus in `PluginExecutionContext` with a
   declared `PluginCapabilities` (storage, non-critical reminders, provider registry,
   speaking) — least privilege, better App Review story (critique §4.2, Decision 3).
   Rule: no new plugin enters implementation until one core workflow passes its
   end-to-end reliability gate (§4.1). Entity bags get per-plugin runtime schemas with
   rejection before side effects (§4.3).
5. **Stage 0 folded into Track 1 Slice A.** Explicitly added: `FamilyNotifier` stub
   becomes an *honest failure/unavailable state* until the broker exists (never a
   silent success); PII lock-screen/debug sweep; misleading health-monitoring copy
   removed in the groundwork doc sweep.
6. **Contradictions resolved in groundwork.** The on-device/cloud routing matrix
   (critique §4.5 table) is written into constitution during the cleanup; native
   per-platform decision replaces React Native (already planned).
7. **Voice-criticality taxonomy** (voice-critical / voice-preferred / touch-admin)
   adopted as a spec requirement for every new feature (§3.5).
8. **Workflow quality gate.** Golden corpus grows from utterance-level to
   workflow-level: correct end-state / attempted workflow per language, tracking
   correct mutation, confirmation, language, recovery, no false success (§3.4).
9. **Settings ownership.** Parent-facing vs caregiver-facing vs safety-core boundaries
   are created in the caregiver-app slice, not later (§4.4).
