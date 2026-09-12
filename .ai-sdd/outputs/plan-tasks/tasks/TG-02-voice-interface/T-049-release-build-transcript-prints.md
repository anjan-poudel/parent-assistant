# T-049: Release-build transcript prints in the on-device STT engines

## Metadata
- **Group:** [TG-02 — Voice Interface](../index.md)
- **Component:** WhisperSpeechRecognizer (SwiftWhisper engine), WhisperKitSpeechRecognizer (WhisperKit engine); the LogSanitiser / ConsoleObservabilityBus contract (T-004) is the standard they must meet
- **Agent:** dev
- **Effort:** S
- **Risk:** HIGH
- **Depends on:** [T-009](T-009-stt-engine/) (owns both engine files), [T-004](../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md) (LogSanitiser contract)
- **Blocks:** —
- **Requirements:** NFR-016, NFR-013
- **Origin:** `security-test` **SECURITY-NO_GO**, finding **B1** (`specs/security-test.md`)

## Description

Both on-device STT engines print the recognised transcript verbatim to the console, and both prints are compiled into **Release** builds. This is the one B1 defect and it is a direct NFR-016 violation: the transcript is exactly the material the constitution's Privacy bullet and the log-sanitiser contract exist to keep out of log output.

**Placement rationale.** The two offending files are TG-02's STT engines (T-009's deliverable), so the fix is owned here. The contract it must satisfy is T-004's `LogSanitiser` / `ConsoleObservabilityBus`, cited as an input rather than re-specified. This mirrors how T-042 was placed in the group owning the plugin contract while citing the sanitiser it had to honour.

**The defect, exactly.** `WhisperSpeechRecognizer.swift:815` prints `"[whisper_stt] transcript=" + joined`; the adjacent comment (810-814) states the intent honestly — "Transcript content on the console (requested for on-device WER review) — dev-facing print, not the sanitised observability bus" — but there is no compile-time guard above it. `WhisperKitSpeechRecognizer.swift:488` prints `"[whisperkit_stt] transcript=" + joined`, and `:493` prints the raw `error` in the failure path. Neither file contains a `#if DEBUG` region: the only preprocessor conditionals in `WhisperSpeechRecognizer.swift` are `#if canImport(SwiftWhisper)` (`:3`, `:186`, `:544`, `:932`) and in `WhisperKitSpeechRecognizer.swift` the `#if canImport(WhisperKit)` equivalents (`:4`, `:71`, `:104`, `:161`, `:293`, `:319`, `:417`, `:646`). The `:815` site sits inside the `canImport` region opened at `:544`, so it is live in every configuration that compiles the engine at all.

**Why this is Release, not Debug.** `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set at `ios/seniOS.xcodeproj/project.pbxproj:2702`, inside the configuration closed by `name = Debug;` at `:2706`; the `Release` configuration (`:2708`) does not set it. Any print guarded by `#if DEBUG` is therefore compiled out of Release. These two are not guarded, so they are not.

**The pattern to align with already exists in this codebase.** The Gemini STT and interpreter prints are correctly guarded: `GeminiSpeechRecognizer.swift:122-125` and `:129-135`, and `GeminiCommandInterpreter.swift:62-70`, each wrapped in `#if DEBUG` with a comment recording why ("Debug-build-only, per explicit request while diagnosing a live bug (2026-09-04) — never compiled into Release"). This task brings the two on-device engines to that same standard; it does not invent a new one.

**Blast radius.** On the on-device stack — a supported and first-class configuration, not a fallback — every utterance the user speaks (medication names, symptoms, family names, an emergency phrase) is written verbatim to the device console, where it is retrievable through sysdiagnose or a tethered Xcode session. The print bypasses `LogSanitiser` and `ConsoleObservabilityBus` (`AppCoordinator.swift:7049`) entirely, so it is a bypass of the sanitiser contract, not a weakening of it.

**What must not be lost.** The neighbouring metadata prints are PII-free and must survive: `WhisperSpeechRecognizer.swift:809-812` (attempt id, duration_ms, audio_seconds, chars) and `WhisperKitSpeechRecognizer.swift:487` (duration_ms, chars). They carry counts and timings, never content, and they are legitimate diagnostics. The fix removes content, not observability — a content-free `chars`/`duration_ms` signal routed through the sanitised bus is strictly better than what is there now.

**Options to weigh, with their consequences.** (a) Guard both prints with `#if DEBUG`, matching the Gemini pattern exactly — smallest diff, keeps the WER-review workflow, and is sufficient because the evidence of record is that these prints exist for development. (b) Delete the transcript prints and rely on the existing metadata prints — smallest blast radius, loses on-device WER review convenience. (c) Replace the content print with a sanitised-bus emit carrying a hash or character count only — the most architecturally correct and keeps a production-usable signal, at the cost of a slightly larger diff and a new event to declare. Option (a) or (b) is expected to suffice; whichever is chosen, the raw `error` print at `WhisperKitSpeechRecognizer.swift:493` is in scope and must be handled the same way.

**Regression guard.** The security-test report recommends a CI grep that fails on unguarded transcript-content prints. Whether that lands in this task or is recorded as a follow-up is this task's decision, but the outcome must be stated: a guard that cannot fail is not a guard.

## Acceptance criteria

```gherkin
Feature: On-device STT engines no longer print transcripts in Release builds

  Scenario: The two transcript prints are no longer Release-compiled
    Given WhisperSpeechRecognizer.swift:815 prints "[whisper_stt] transcript=" + joined
    And WhisperKitSpeechRecognizer.swift:488 prints "[whisperkit_stt] transcript=" + joined
    And neither file contains a #if DEBUG region (only #if canImport guards at WhisperSpeechRecognizer.swift:3, 186, 544, 932 and WhisperKitSpeechRecognizer.swift:4, 71, 104, 161, 293, 319, 417, 646)
    And SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG is set only in the Debug configuration (project.pbxproj:2702, closed by name = Debug; at 2706; Release at 2708 does not set it)
    When the fix lands
    Then neither transcript string is compiled into a Release build, proven by the mechanism the fix uses (a #if DEBUG guard, deletion, or replacement by a content-free bus emit) and not by inspection alone

  Scenario: The sanitisation contract, not a local convention, is what the fix satisfies
    Given NFR-016 forbids PII in application logs and requires a log sanitiser to strip it before writing
    And the prints bypass LogSanitiser and ConsoleObservabilityBus (AppCoordinator.swift:7049) entirely
    And NFR-013 requires quarantine-level sanitisation of voice transcriptions before processing
    When the fix lands
    Then no transcript content reaches the console or any log sink outside the sanitised bus in any build configuration
    And if any production-visible diagnostic is added in place of the print, it carries no content (count, hash or duration only) and is emitted through the bus under an allow-listed key (LogSanitiser.swift:21-35)

  Scenario: The Gemini pattern is matched, not re-invented
    Given GeminiSpeechRecognizer.swift:122-125 and :129-135 and GeminiCommandInterpreter.swift:62-70 guard their content prints with #if DEBUG
    When the fix chooses the guard option
    Then both engine prints use the same #if DEBUG construct, with a comment recording why the print exists and that it is Debug-only
    And no new sanitiser, bus or logging abstraction is introduced for this fix

  Scenario: The failure-path raw error print is handled too
    Given WhisperKitSpeechRecognizer.swift:493 prints the raw error object
    When the fix lands
    Then that print is guarded, deleted or reduced to a content-free code by the same mechanism as the transcript prints
    And no raw error object, upstream response body or key-bearing URL is printed by either engine

  Scenario: PII-free observability is preserved, not removed
    Given the adjacent metadata prints carry counts and timings only — WhisperSpeechRecognizer.swift:809-812 (attempt, duration_ms, audio_seconds, chars) and WhisperKitSpeechRecognizer.swift:487 (duration_ms, chars)
    When the fix lands
    Then those metadata signals remain available in Release (kept as-is, or routed through the sanitised bus under an allow-listed key)
    And the fix does not reduce the project's ability to diagnose STT latency and throughput on a Release build

  Scenario: The fix is pinned and the gate stays green
    Given the canonical iOS gate is ./ios/build.sh test:unit
    When the fix completes
    Then a test or CI check fails if a transcript-content print is compiled into a non-Debug configuration, or the absence of such a check is recorded as a named follow-up with its residual risk stated
    And the canonical unit gate passes with no new failures
```

## Implementation notes

- Sites in scope: `WhisperSpeechRecognizer.swift:815` (content print, comment at 810-814), `WhisperKitSpeechRecognizer.swift:488` (content print) and `:493` (raw error). Sites explicitly out of scope and to be preserved: `WhisperSpeechRecognizer.swift:809-812`, `WhisperKitSpeechRecognizer.swift:487`.
- Contract inputs, do not re-derive: `LogSanitiser.swift:21-35` (allow-list — note `error_code` at `:30` and `stages` at `:35` are the only content-bearing allowances, both documented as PII-free), `:59` (the sanitised copy), `:64-76` (the scrub pass). `ConsoleObservabilityBus` is at `AppCoordinator.swift:7049`; its print site is `:7062-7066`.
- This is a rework task from the `security-test` NO_GO. Its finding B1 is the primary input; do not re-derive the leak analysis, and do not re-open B2 (the `error_code` API-key leak) — that is T-050, which edits `LogSanitiser`'s allow-list and is the only task that should.
- Android has no counterpart: the STT engines are iOS-only components. Verify rather than assume, and record the verification in the task's completion notes.
- No PII in tests or fixtures: use synthetic utterances, never real speech, names or health values (NFR-016). A regression test that itself logs transcripts re-creates the defect in the test target.
- If the fix changes what appears in a Debug console, that is acceptable and expected; the requirement is about Release and about the sanitisation boundary, and the Debug affordance was explicitly requested for WER review.
- The gate is green today (2672 tests, 0 failures at `fb6e03c`, `specs/security-test.md`). Keep it green; do not weaken, skip or delete an assertion to land this fix.

## Definition of done
- [ ] `WhisperSpeechRecognizer.swift:815` and `WhisperKitSpeechRecognizer.swift:488` no longer compile transcript content into a Release build, by guard, deletion or content-free replacement — mechanism stated in the completion notes
- [ ] `WhisperKitSpeechRecognizer.swift:493`'s raw error print handled by the same mechanism
- [ ] The `#if DEBUG` pattern matches `GeminiSpeechRecognizer.swift:122-125` / `GeminiCommandInterpreter.swift:62-70` if the guard option is chosen; no new logging abstraction introduced
- [ ] Metadata-only diagnostics preserved (`WhisperSpeechRecognizer.swift:809-812`, `WhisperKitSpeechRecognizer.swift:487`) and still available in Release
- [ ] Regression guard landed (test or CI grep that can actually fail), or its absence recorded as a named follow-up with residual risk stated
- [ ] Canonical gate `./ios/build.sh test:unit` run and green; no assertion weakened, skipped or deleted
- [ ] Android absence verified and recorded, not assumed
- [ ] No PII in any added test or fixture (NFR-016)
