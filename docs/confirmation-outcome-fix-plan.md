# Confirmation Outcome Fix — Plan (#3)

**Status:** Plan (for implementation by a future session)
**Date:** 2026-08-30
**Problem:** The voice router speaks a fixed "Okay, marked as taken." whenever the user answers "yes" to a medication confirmation challenge — even when the dose was **blocked by the double-dose check (FR-D03)** or the answer arrived after the challenge deadline (FR-D02). The scheduler's `Result` is discarded in `AppCoordinator.handleConfirmationResponse`, so the actual outcome never reaches the user.

## 1. Why it happens today

```
CommandRouter.route → isAwaitingConfirmation → handleConfirmationResponse(.yes)
  → AppCoordinator.handleConfirmationResponse
      → medicationScheduler.acknowledgeWithConfirmation(...)   // Result ignored
      → ConfirmationChallenge.userResponds
          ├─ recordTaken          → DoubleDoseDetector.check
          │    ├─ duplicate → log .doubleDoseAttempt, notify family  ──┐
          │    └─ clean     → finalizeAcknowledgement (ACKNOWLEDGED)    │
          ├─ reEnterEscalation (denied / timed out) ────────────────────┤
          └─ noAction                                                    │
  → router (blind) speaks "Okay, marked as taken."   ← contradicts all of the above
```

Required wording exists in the requirements:
- FR-D02(b): "That's okay. I'll remind you again in a few minutes."
- FR-D03(a): "You already took your [medication name] earlier today. Let me check with [caregiver name]."

## 2. Changes

### 2.1 Scheduler: return a typed outcome — `MedicationScheduler.swift` / protocol

Replace the discarded `Result<Void, SafetyError>` of `acknowledgeWithConfirmation` with:

```swift
enum ConfirmationOutcome: Equatable {
    case doseRecorded                    // recorded as taken (FR-D01 passed, no duplicate)
    case doubleDoseBlocked               // FR-D03 — blocked + caregiver alerted
    case deniedReEnterEscalation         // user said "no" (FR-D02)
    case timedOutReEnterEscalation       // > 30 s (FR-D02)
    case noPendingChallenge              // challenge missing/expired — caller should fall back
}

func acknowledgeWithConfirmation(...) -> ConfirmationOutcome
```

Map each branch of `ConfirmationAction` to its outcome (the current switch already has all the branches; just return the enum instead of `.success`).

### 2.2 Coordinator: propagate the outcome — `AppCoordinator.swift`

`handleConfirmationResponse(_:)` returns `ConfirmationOutcome` (or stores it in `@Published var lastConfirmationOutcome`), always clears `pendingConfirmationEntryId`, and the router reads it.

### 2.3 Router: reply per outcome — `CommandRouter.swift`

Externalised Nepali/English templates (NFR-023 — no hard-coded strings), one per outcome:
- `doseRecorded` → "Okay, marked as taken." / "ठीक छ, औषधि लिएको भनेर राखेँ।"
- `doubleDoseBlocked` → FR-D03 wording incl. medication name + caregiver name, e.g. "तपाईंले [औषधि] पहिले नै खाइसक्नुभएको छ। म [हेरचाहकर्ता] सँग सोध्छु।"
- `deniedReEnterEscalation` / `timedOutReEnterEscalation` → FR-D02(b) "That's okay. I'll remind you again in a few minutes." / "हुन्छ, केही बेरमा फेरि सम्झाउँछु।"
- `noPendingChallenge` → fall back to the baseline ack message.

For the double-dose reply, `CommandRouter` needs the medication name — extend `handleConfirmationResponse` to return `(outcome, medicationName: String?)` or add `coordinator.confirmationContext` accessor. Keep it minimal: coordinator returns both from the scheduler call.

### 2.4 Tests

- **Scheduler**: `acknowledgeWithConfirmation` outcome mapping for all four paths (extend `MedicationSchedulerTests`).
- **Router**: new `CommandRouterTests` cases — each outcome selects the correct template; no "marked as taken" on blocked/denied.
- **Integration-ish**: coordinator-level test that `pendingConfirmationEntryId` clears on every outcome.

## 3. Non-goals (do not do in this task)

- No change to escalation timing, double-dose windows, or persistence.
- No new scheduler state; `ConfirmationOutcome` is derived from existing paths.

## 4. Verification

1. Unit suites green (`xcodebuild test` — see housekeeping plan for the test-target prerequisite).
2. Manual: schedule a reminder → ack → challenge → "yes" (recorded) / "no" (re-enter) / wait 31 s then "yes" (timed-out message) / ack same medication twice within window (blocked message with names).

## 5. Effort estimate

0.5–1 day including tests.
