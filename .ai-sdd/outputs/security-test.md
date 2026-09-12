# Security Test — security-test (phase: review, risk tier T1)

- Task: `security-test` (ai-sdd workflow `elderly-ai-assistant-sdd`)
- Report path: `specs/security-test.md` (SDD project: `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`)
- Code repo under test: `/Users/anjan/workspace/projects/elderly-ai-assistant` (iOS at `ios/ElderlyAssistant/`, Android at `android/`)
- Reviewed revision: `master` at **`fb6e03c`** (as instructed), working tree clean at review start. A concurrent commit (`34c81b9`, 02:31:30) landed mid-review — see Revision note.
- Verification performed: static analysis (grep/rg + reading the cited code) plus the canonical unit gate, run by me at `fb6e03c` (result below). No code or artifact was modified; this file is the only write.

## Summary

Two library categories (SQL injection, input validation) and the voice-injection focus area pass with verified controls; audit logging is scoped-GO. Five categories fail: PII in logs, secrets in output, error leakage, auth bypass, and (as workflow focus areas) emergency-call trigger validation and encrypted config payload verification. The failures are a mix of concrete defects in shipped code (raw transcript prints to the console in Release builds; the Gemini API key leaking into logs through the allow-listed `error_code`) and unimplemented safety features whose security properties cannot be verified (voice-biometric/PIN gating, emergency call module, encrypted remote config). Blocking findings B1–B7 below. No softening: the two shipped-code leaks alone are release-blocking for a product holding an elderly user's health speech.

## Decision

**SECURITY-NO_GO** — the workflow exit condition `review.decision == "SECURITY-GO"` is **not met**. Per-category and focus-area verdicts are tabulated below (every category is carried, none is a bare N/A); blocking findings are B1–B7; the itemised path back to GO is the section "What would move the failing categories to SECURITY-GO" at the end of this report.

> Orchestrator note (not a reviewer finding): two mechanical edits were made to this artifact after the
> reviewer wrote it, so it would pass `complete-task` validation. (1) The 40-character baseline commit
> SHA quoted from the unit-gate output was abbreviated to `fb6e03c…` — the raw SHA matched the ai-sdd
> secret scanner's AWS-access-key regex (`[A-Za-z0-9/+=]{40}`) as a false positive. (2) This `## Summary`
> heading was added and the verdict restated under a `## Decision` heading, because the `review_report`
> contract requires both section headers. No finding, verdict, evidence item or conclusion was changed.

## Revision note (master moved during the review)

The review targeted `fb6e03c` as instructed, and the unit gate ran and passed against that revision (`✓ recorded green baseline: fb6e03c...`). Mid-review, master advanced to `34c81b9` ("ship the gate-passing 4B intent brain", 02:31:30), touching exactly two files: `AppCoordinator.swift` (default brain) and `ModelCatalog.swift` (new catalogue entry). All line citations in this report were verified against `fb6e03c`; the delta does not change any verdict, and it adds a *second* instance of the cleartext-LAN-URL issue (finding B5): at `34c81b9`, `ModelCatalog.swift:546` is the new default brain's `http://192.168.1.117:8765/...` URL (list at `:812`), and the previously cited `qwen4BNepali` URL moved to `:651`.

## Sources read

- `constitution.md` — Standards (Privacy `:73-77`, Security `:79-85`, Quality `:87-91`); these are the acceptance criteria for this review.
- `.ai-sdd/outputs/security-design-review.md` — STRIDE THREAT-001…010; BLOCKER-1 (`:370`), BLOCKER-2 (`:384`), BLOCKER-3 (`:398`), REC-1…REC-8 (`:413-455`).
- `specs/review-implementation.md` (T-042, GO) and `specs/implement-notes.md` — residual-risk notes (`review-implementation.md:173-175`: hardcoded `InputSanitiser.maxLength`, DEBUG-only raw-transcript print).
- Code and tests at `fb6e03c`, plus `docs/review-2026-08-30.md` as prior evidence (and its C9 leak claims re-checked, see Non-blocking N8).

## Verification performed (raw evidence)

### Canonical unit gate — run by me at `fb6e03c`

Command (from the main checkout): `./ios/build.sh test:unit` (runs `xcodebuild test -scheme ElderlyAssistant -skip-testing:ElderlyAssistantUITests`). Raw tail:

```
Test Suite 'ElderlyAssistantTests.xctest' passed at 2026-09-13 02:31:11.863.
	 Executed 2672 tests, with 6 tests skipped and 0 failures (0 unexpected) in 271.548 (278.796) seconds
Test Suite 'All tests' passed at 2026-09-13 02:31:11.872.
	 Executed 2672 tests, with 6 tests skipped and 0 failures (0 unexpected) in 271.548 (278.806) seconds
** TEST SUCCEEDED **

Testing started
  ✓ unit tests passed
=== Unit tests passed ===
  ✓ recorded green baseline: fb6e03c…  (full 40-char SHA elided at this one site to clear the
  ai-sdd secret scanner's AWS-key false positive; the verbatim SHA is in the xcresult)
[exited with code 0]
```

xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.09.13_02-25-53-+1000.xcresult`. The gate is green; it does not by itself demonstrate the absence or presence of the security defects below (they are static/runtime properties), and it does not measure coverage.

### Targeted static and empirical checks (each cited claim below resolves to code)

| Check | Command / method | Result |
|---|---|---|
| Injection sanitisation at every LLM boundary | `rg -n "InputSanitiser.sanitise"` | `GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, `LocalIntentInterpreter.swift:101`; plus plugin path `CommandRouter.swift:2376-2384` |
| Prompt-construction sites | `rg -n "IntentPrompt\.(build|buildUnderstanding)"` | `LocalIntentInterpreter.swift:106`, `GeminiCommandInterpreter.swift:74`, `LlamaCommandInterpreter.swift:453`, `GeminiClient.swift:180,234` — all receive sanitised text or audio-only context |
| Raw transcript prints / DEBUG guards | `rg -n "transcript="` + `rg -n "#if DEBUG|#if"` in both Whisper engines | `WhisperSpeechRecognizer.swift:815` and `WhisperKitSpeechRecognizer.swift:488` are **unguarded** (files contain only `#if canImport(...)`, no `#if DEBUG`) |
| DEBUG compilation condition scope | `rg -n "SWIFT_ACTIVE_COMPILATION_CONDITIONS" ios/seniOS.xcodeproj/project.pbxproj` | single hit `:2702`, config `name = Debug` at `:2706`; Release has none — DEBUG prints are compiled out of Release |
| API key in request URLs | `rg -n "key=\\\\(apiKey)"` in `GeminiClient.swift` | `:230` (streaming), `:395` (unary) |
| Transport errors rethrown raw | read `GeminiClient.swift` | `:259-263` and `:414-418` rethrow the untouched `URLError`; `:428-429` throws `httpError` carrying the raw upstream `body` |
| Error stringification sites | `rg -n "String\(describing: error\)"` | 6 sites: `GeminiClient+Vision.swift:117`, `NepaliCalendarPlugin.swift:90`, `ApplianceHelperSession.swift:190`, `GeminiCommandInterpreter.swift:107`, `GeminiSpeechRecognizer.swift:139`, `VoicePipeline.swift:855` |
| LogSanitiser behaviour | read `LogSanitiser.swift` | allowlist `:21-35` includes `error_code` `:30`; `sanitise` copies `errorCode` unscrubbed `:59`; value scrubbing only for allowed metadata keys `:64-76` with phone/email/BP regexes `:37-47` |
| URLError leaks the keyed URL | standalone Swift repro forced a transport error on a keyed URL-shaped request | `String(describing: URLError)` excerpt: `...key=SECRET_API_KEY_VALUE, NSErrorFailingURLKey=https://no-such-host.invalid/v1beta/models/...`; `error.failingURL.absoluteString.contains(key) == true` |
| No SQL/DB surface | `rg -in "sqlite|CoreData|NSPersistentContainer|GRDB|FMDB|Realm"` over iOS + Android first-party sources | no matches |
| Secrets in the repo / SDD outputs | regex scan for `AIza…`, `sk-…`, private-key blocks, `key=:"…"` literals over first-party paths in both directories | no matches (vendored `ios/vendor` excluded after false positives from minified JS) |
| Voice-biometric scope | read `SpeakerBiometricService.swift`, `rg "SpeakerBiometricService\("`, `rg "\.verify\("` | `:10-20` states CommandRouter gating / liveness / PIN lockout NOT WIRED; no production `.verify(` caller; only production construction is `VoiceSettingsView.swift:73-75` with no bus |
| Cleartext model URL + ATS | `rg -n "192.168.1.117"`; `plutil -p Info.plist` | `ModelCatalog.swift:632` (fb6e03c; `:546` and `:651` at 34c81b9); `NSAllowsLocalNetworking=true` (`Info.plist:45-46`) |
| Alert stubs | read `FamilyNotifier.swift`, Android `FamilyNotifier.kt` | `FamilyNotifier.swift:104-115` prints a token prefix and returns `true` unconditionally; Android FCM provider mirrors it |
| Voice audio + health data to cloud | `rg -n "audioData|inlineData"` in `GeminiSpeechRecognizer.swift`; read `IntentPrompt.swift:153-198` | WAV audio sent at `:113/:118/:129`; prompt embeds pending medication names `:154-156,166`; default stack is `.gemini` (`AppCoordinator.swift:1612-1613`) |

## Category verdicts (task library categories, mapped to this codebase)

Each category gets one of the exact strings `SECURITY-GO` or `SECURITY-NO_GO`. Where a category has no literal analogue, the mapping and the proof of absence are stated — an unexamined N/A is not used anywhere.

| # | Library category | Mapping on this codebase | Verdict | Evidence |
|---|---|---|---|---|
| 1 | SQL injection | Proven-absent analogue: no server, no relational store, no SQL layer anywhere in first-party iOS/Android code; persistence is Keychain/`EncryptedLocalStorage`/JSON files (`LocalToolLogStore`, `IntentLogStore`, `ModelStore`) | `SECURITY-GO` | `rg` for sqlite/CoreData/GRDB/Realm/FMDB → no matches; repo is client-only (no HTTP server in `ios/`, `android/`); every network call is outbound |
| 2 | Input validation (400s) | No HTTP server → no 400 surface to test; nearest analogue is **voice/STT text intake** (the workflow's voice-injection focus) | `SECURITY-GO` | Gibberish/repetition guard at route entry `CommandRouter.swift:534-544` (`TranscriptSanityGuard`); sanitiser at all three LLM boundaries (`:56`, `:444`, `:101`); plugin transcript sanitised `:2376-2384`; model-output gate `ReplySanityGate`; LLM `actionUrl` validated and not carried (`LlamaCommandInterpreter.swift:787`) so no model-provided URL is ever opened; tests incl. `InputSanitiserTests` (length clamp, Devanagari pass-through) |
| 3 | Auth bypass (401/403) | No server auth; on-device analogue is the voice-biometric/PIN gate on sensitive commands (FR-011–015) | `SECURITY-NO_GO` | Gating NOT WIRED (`SpeakerBiometricService.swift:16-20`); no PIN/Argon2/lockout code at all; no production `.verify(` callers; sensitive call phrases fail closed on the deterministic path (`CommandRouter.swift:1489-1496`) but the LLM-interpreted call path proceeds on confirmation alone (`handleCall` `:2224+`); BLOCKER-1/2 open |
| 4 | PII in logs | Health/contact/conversation speech must never reach logs (NFR-016, constitution Privacy) | `SECURITY-NO_GO` | Raw transcripts printed unguarded in Release builds: `WhisperSpeechRecognizer.swift:815`, `WhisperKitSpeechRecognizer.swift:488` (plus `:493` raw error); device-token prefix printed `FamilyNotifier.swift:112`; see B1 |
| 5 | Secrets in output | No secrets committed (verified); runtime secret = user's Gemini API key | `SECURITY-NO_GO` | Repo and SDD-output scans clean; key placed in URL query (`GeminiClient.swift:230,395`) and surfaced through `String(describing: URLError)` → `error_code` (allow-listed, unscrubbed) → console; see B2 |
| 6 | Audit log completeness | Auth attempts / emergency triggers / config application / permission grants. Only emergency triggers (both paths) and command/confirmation transitions exist today | `SECURITY-GO` (scoped) | Emergency emits `command_emergency_keyword` (`:567`, `:1435`) and `command_emergency` (`:2117`) through the sanitising bus; test asserts it (`CommandRouterSafetyNetTests.swift:32`); auth/config/permission event classes have no feature to audit — see Scope statement below |
| 7 | Error leakage | Stack traces / internals / raw upstream bodies in logs | `SECURITY-NO_GO` | `String(describing: error)` at six sites flows into `errorCode`; `GeminiClientError.httpError` retains the raw upstream body (`GeminiClient.swift:53,428-429`); see B2, and the UI itself renders only localized text (`HomeView.swift:322-332`) so this is a log/exposure issue, not a screen issue |

Scope statement for category 6: this `SECURITY-GO` covers the events that exist. Audit logging is console-only (no durable store — observation N4) and the auth/config/permission event classes are **N/A because those features do not exist**, evidenced in categories 3 and the focus areas below. If `security-test` is re-run after those features ship, this category must be re-tested.

## Focus-area verdicts (workflow overrides)

| Focus area | Verdict | Evidence |
|---|---|---|
| Voice input injection (quarantine sanitiser, all interpreters, router paths, wake-word/keyword/cancel paths) | `SECURITY-GO` | Sanitisation verified at every LLM entry point (`GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, `LocalIntentInterpreter.swift:101`, plugin helper `CommandRouter.swift:2376-2384`); marker blocklist `InputSanitiser.swift:24-40`, control-char strip + whitespace collapse + 200-char clamp `:42-75`; deterministic keyword path builds no prompt and blocks sensitive phrases fail-closed (`:1489-1496`); cancels are parsed from the raw transcript only (`AlarmTimerCommandParser.parseTimerCancel` `:803`), never from model output; `ReplySanityGate` gates model text before speech; tests: `InputSanitiserTests`, `CommandRouterSafetyNetTests.swift:22-33` (emergency fires before interpreter; `callCount == 0`) |
| Health data PII in logs | `SECURITY-NO_GO` | B1: raw voice transcripts (which carry medications, symptoms, contacts) printed to console in Release builds by both on-device STT engines; the sanitised-bus contract is bypassed, not just weakened |
| Auth bypass (voice biometric, ECAPA-TDNN, Secure Enclave, PIN salted hash, three-failure lockout, sensitive commands without auth) | `SECURITY-NO_GO` | Enrollment + verification service exists and stores templates in Keychain `WhenUnlockedThisDeviceOnly` (`VoiceBiometricStore.swift:6,63`; `KeychainEncryptedStorage.swift:82`) — the storage bullet is met; but ECAPA is a candidate slot with MFCC today, `SpeakerBiometricService.swift:10-15`; CommandRouter gating, liveness, PIN fallback and lockout are explicitly NOT WIRED (`:16-20`); no PIN code exists (no Argon2/bcrypt anywhere); sensitive commands execute without authentication (confirmation only) |
| Emergency call trigger validation (false-cancellation, threshold suppression, LLM isolation, 100% coverage on safety-critical paths) | `SECURITY-NO_GO` | LLM isolation of the keyword safety net is implemented and unit-tested (`CommandRouter.swift:562-570`, `:1429-1484`; test `CommandRouterSafetyNetTests.swift:22-33`); but no emergency call module exists — `handleEmergency` only posts a local notification and speaks an ack (`:2213-2217`), corroborated by `docs/review-2026-08-30.md:65-67` ("no emergency dispatch module", FR-031–037 0%); cancel-countdown/threshold suppression have no code to validate; 100% coverage of a non-existent call path is unsatisfiable |
| Encrypted config payload verification (Signal Protocol, T-031 decryptor/validator/applicator, key handling, replay/tamper resistance, TLS 1.2+ outbound) | `SECURITY-NO_GO` | No Signal Protocol/libsignal/WebSocket/companion app/`ConfigPayload*` types exist (searched); remote config is design-only (`docs/review-2026-08-30.md:145`), so replay/tamper resistance is unverifiable; additionally the TLS 1.2+ constitution bullet is violated by cleartext LAN model-download URLs shipped in the brain catalogue (B5) |

## Blocking findings

### B1. Raw voice transcripts are printed to the console in Release builds (NFR-016 violation)

- `WhisperSpeechRecognizer.swift:815` — `print("[whisper_stt] transcript=" + joined)` (the surrounding comment at `:812-814` concedes it is a dev-facing print, but there is no compile-time guard: the file contains only `#if canImport(SwiftWhisper)` blocks, no `#if DEBUG`).
- `WhisperKitSpeechRecognizer.swift:488` — `print("[whisperkit_stt] transcript=" + joined)`; same file structure (only `#if canImport(WhisperKit)`), so also Release-compiled. `:493` also prints the raw `error`.
- Contrast: the Gemini STT/interpreter prints ARE `#if DEBUG` guarded (`GeminiSpeechRecognizer.swift:122-135`, `GeminiCommandInterpreter.swift:62-70`) and `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` exists only in the Debug config (`project.pbxproj:2702`, `name = Debug` `:2706`) — those are compiled out of Release. The two Whisper sites are not.
- Impact: on the on-device stack, everything the user says — medication names, symptoms, family names, an emergency utterance — is written verbatim to the device console, retrievable via sysdiagnose/Xcode, exactly the content the constitution's Privacy bullet and NFR-016 forbid. This bypasses `LogSanitiser` and `ConsoleObservabilityBus` entirely.
- Minimal fix: route the transcript through the sanitised bus (hashed/metadata only), or delete the print; if a WER-review transcript is needed, guard it with `#if DEBUG`.

### B2. The user's Gemini API key leaks into logs through the allow-listed `error_code`

Chain, all verified: the key is embedded in the request URL query (`GeminiClient.swift:230`, `:395`) → transport failures rethrow the untouched `URLError` (`:259-263`, `:414-418`) → six emit sites stringify it with `String(describing: error)` (`GeminiClient+Vision.swift:117`, `NepaliCalendarPlugin.swift:90`, `ApplianceHelperSession.swift:190`, `GeminiCommandInterpreter.swift:107`, `GeminiSpeechRecognizer.swift:139`, `VoicePipeline.swift:855`) → `LogSanitiser` copies `errorCode` without scrubbing (`LogSanitiser.swift:59`; `error_code` is allow-listed at `:30`; the value-scrub regexes `:37-47` target phone/email/BP and do not match key material) → `ConsoleObservabilityBus` prints it (`AppCoordinator.swift:7062-7066`).

Empirical proof (fresh, this review): a standalone Foundation repro of the request shape with a forced transport error yields, in `String(describing: URLError)`, `...key=SECRET_API_KEY_VALUE, NSErrorFailingURLKey=https://no-such-host.invalid/v1beta/models/...`, and `error.failingURL.absoluteString.contains(key) == true`. The app path differs only in that the host resolves and can fail later for the same transport reasons (offline, DNS, TLS, timeout).

Related, same chain: `GeminiClientError.httpError(status:body:)` (`GeminiClient.swift:53`, thrown `:428-429`) retains the raw upstream error body, which is also stringified at the same sites — raw upstream internals into logs (error-leakage category).

Minimal fix: map `URLError`/transport errors to a short code before logging (never `String(describing:)` on a URL-bearing error), or move the key to the `x-goog-api-key` header, and drop/limit `errorCode` at the bus boundary (it is the one field that bypasses the sanitiser's key allowlist).

### B3. Sensitive-action authentication is not wired (BLOCKER-1/2 remain open)

`SpeakerBiometricService.swift:10-20` is an honest scope statement: enrollment/verify/persistence are wired, but CommandRouter gating, challenge-response liveness (BLOCKER-1), and PIN fallback + lockout ladder (BLOCKER-2) are NOT WIRED. Fact checks: no production `.verify(` caller exists; the only production construction is `VoiceSettingsView.swift:68-75`, which deliberately passes no observability bus; there is no PIN storage code (no Argon2/bcrypt), and no lockout policy anywhere. The deterministic keyword layer blocks call-ish phrases and reports `command_sensitive_blocked_auth_unavailable` (`CommandRouter.swift:1489-1496`), which is fail-closed; but the LLM-interpreted `call` path executes on confirmation alone (`handleCall` `:2224+`), and `ConfirmationTier` has no auth tier (`ConfirmationTier.swift`). Consequence: for the auth-bypass category there is no control to bypass — and nothing to verify as resistant to bypass. Either the gate must be wired, or the workflow must record an explicit, time-boxed risk acceptance with the confirmation-only path as the shipped control.

### B4. Emergency call module and alert delivery are absent (trigger validation unverifiable)

`handleEmergency()` posts a local notification and speaks an acknowledgement (`CommandRouter.swift:2213-2217`); there is no dispatcher, no cancel listener, no threshold evaluation, no HealthKit. `docs/review-2026-08-30.md:65-67` confirms "no emergency dispatch module" and FR-031–FR-037 at 0%. The security design review's emergency actions (THREAT-003, BLOCKER-3 threshold bounds, REC-1 cancel false-positive) have no implementation to apply to. Compounding it, the family-alert path that an emergency would use is a silent stub: `APNsProvider.sendPush` prints a token prefix and returns `true` unconditionally (`FamilyNotifier.swift:104-115`); Android's FCM provider mirrors it. "100% unit test coverage on safety-critical paths" (constitution Quality) is met for the paths that exist (keyword safety net, medication flows) but not for an emergency call path that does not exist. Verdict cannot move to GO by testing alone — the module must be built (or explicitly descoped by the workflow with the keyword ack documented as the shipped net).

### B5. Encrypted config payload verification: absent chain, and the TLS 1.2+ bullet is violated

No Signal Protocol/libsignal, WebSocket relay client, companion-app config channel, or `ConfigPayloadDecryptor/Validator/Applicator` exists (searched; `docs/review-2026-08-30.md:145` "Design only"), so key handling, replay and tamper resistance are unverifiable now. Independently, the constitution requires TLS 1.2+ on all outbound connections; the brain catalogue ships cleartext HTTP model URLs: at `fb6e03c`, `ModelCatalog.swift:632` (`http://192.168.1.117:8765/intent-ne-qwen3-4b-nepali-q4_k_m.gguf`, present in `availableBrainEntries`), and at `34c81b9` additionally `:546` (the new default brain) and `:651`. ATS permits it via `NSAllowsLocalNetworking` (`Info.plist:45-46`, scoped — not arbitrary loads). SHA-256 verification on promotion (`ModelStore.swift:354-402`) provides integrity but not confidentiality; the download itself is unauthenticated and unencrypted on the LAN. Android sets `cleartextTrafficPermitted="false"` but its certificate pin-set is an empty placeholder.

### B6. Silent-success alert stubs (safety-relevant)

Covered as part of B4 but recorded separately because it is a distinct failure mode: callers of `APNsProvider.sendPush` (e.g. `APNsFamilyNotifier`) receive `true` while nothing is sent and only a token prefix is printed (`FamilyNotifier.swift:110-113`). Any future emergency/family-alert wiring that trusts this return value will report success on undelivered alerts. The comment marks it as a T-028-a stub; until implemented it must fail closed (return `false`/throw), never silently succeed.

### B7. Constitution Privacy bullet vs. the cloud stack (standards deviation; blocking for sign-off)

`constitution.md:74`: "No personal data (voice, health, contacts, conversations) transmitted to cloud for AI processing." The shipped cloud stack contradicts it as written: the user's raw WAV audio is sent to Gemini (`GeminiSpeechRecognizer.swift:113/118/129`), and the audio-path prompt embeds the user's pending medication names (`IntentPrompt.swift:154-156,166`). The default `voiceEngineStack` is `.gemini` (`AppCoordinator.swift:1612-1613`, "always-Gemini behavior for anyone who's never touched the toggle"); the Settings disclosure is only "Gemini uses the internet" (`Localizable.xcstrings`, `settings.voiceEngine.explanation`). The SDD requirements/design corpus never mentions the cloud engine (no "Gemini"/cloud-AI entry in `define-requirements.md` or `design-l2.md`), so no exception was recorded at design time. This is not one of the eight library categories; it is flagged because constitution Standards are acceptance criteria for this review. Resolution is a product/design decision: amend the constitution (and record the consent/disclosure design) or change the default and gate cloud transmission behind explicit enrollment. In practice a user must configure an API key before audio can leave the device, which is why this is framed as a sign-off blocker rather than a covert leak.

## Non-blocking observations

1. **Hardcoded sanitiser limit.** `InputSanitiser.maxLength = 200` (`InputSanitiser.swift:22`) against the threat model's 2000 (carried from `specs/review-implementation.md:173-175`). Truncation happens after marker removal; it is functionality-strictness, not a security weakening, but it is a hardcoded constant on a security control (reviewer checklist) and truncates long Nepali utterances.
2. **Denylist coverage.** The injection control is a 12-entry English/transliterated blocklist (`InputSanitiser.swift:24-40`). REC-5 asked for an adversarial blocklist plus observability; the blocklist exists and is tested, but denylists cannot be complete — the real protections are the confirmation tiers, the LLM-isolated emergency path, and the fact that no model output is executed as a URL.
3. **`reason` metadata silently dropped.** Emitters pass `reason`/`sampleIndex` metadata (e.g. `AudioSessionManager.swift:356`, `LocalIntentInterpreter.swift:271-276`, `IntentRouter.swift:380,400`, `WarmStart.swift:491`, `SpeakerBiometricService.swift:89-123`) but the LogSanitiser allowlist omits `reason`, so enrolment-failure reasons and selection reasons are invisible in sanitised output. Debug-fidelity issue only.
4. **Console-only telemetry.** `ConsoleObservabilityBus` prints; nothing persists. No durable audit trail for emergency events beyond console output. Acceptable for debug telemetry, insufficient if an audit trail is later required.
5. **DEBUG-only raw-content prints.** `GeminiCommandInterpreter.swift:62-70` prints raw + sanitised transcript, `GeminiSpeechRecognizer.swift:122-135` prints transcripts, `CommandRouter.swift:2499-2506` prints spoken text — verified compiled out of Release (single `DEBUG` condition, Debug config only). Fine for Debug; do not distribute Debug builds to families.
6. **`voiceError` holds raw error text.** `VoicePipeline.swift:855-857` passes `"STT: \(err)"` to `voiceError`; `voiceErrorKind` string-matches English substrings (`AppCoordinator.swift:36-46`); the UI renders localized text only (`HomeView.swift:322-332`). No raw error reaches the screen, but the coupling is fragile.
7. **PII-bearing on-device stores are design-sanctioned.** `LocalToolLogStore` (`:66-76`, encrypted Keychain-backed, export only by explicit family action), `IntentLogStore` (`:8-14`, `NSFileProtectionComplete`, contact names by design) and encrypted chat history hold user speech. A literal reading of "Logs must not contain PII" collides with them; they are deliberate, encrypted, on-device and not the observability bus. Recorded so the sign-off can confirm this reading.
8. **Prior-evidence drift.** `docs/review-2026-08-30.md` C9's "Llama logs a 160-char raw LLM output preview into `metadata['state']`" and "postDebugNotification posts raw transcripts to lock-screen notifications" are FIXED at the reviewed revision (`LlamaCommandInterpreter.swift:426` now stores only the entry id; `postDebugNotification` no longer exists). The raw Whisper prints (B1) and token-prefix print (B6) remain. The stale doc should not be used as current evidence for those two fixed items.

## Pre-existing residual risk (not introduced here; out of scope for this review)

- BLOCKER-1 (voice-biometric liveness/PAD), BLOCKER-2 (PIN lockout policy), BLOCKER-3 (device pairing + relay `KEY_REGISTER` auth + all health-threshold bounds) from `.ai-sdd/outputs/security-design-review.md:370-410` — all open; none has code to fix yet.
- REC-1 (cancel false-positive rate), REC-3 (empty medication schedule), REC-4 (wake-word session timeout) — depend on modules that do not exist; REC-5's blocklist is implemented; REC-6 (Android permissions review) and REC-7 (HealthAlertLog encryption confirmation) are unverified (Android dormant).
- Android is deferred reference scaffolding (`docs/review-2026-08-30.md`); its FCM stub mirrors iOS B6; not exercised in this review.
- C-series findings in `docs/review-2026-08-30.md` (e.g. C12 confirmation timeout) are outside the security categories and were not re-tested; their status is unchanged as far as this review is concerned.
- T-042 residual notes (hardcoded `maxLength`, DEBUG print) are carried forward in observations 1 and 5.

## What would move the failing categories to SECURITY-GO

1. B1: guard or remove the two raw transcript prints; add a test or CI grep that fails on unguarded transcript content prints.
2. B2: no URL-bearing error stringification into logs; key out of the URL; scrub/limit `error_code`; drop raw upstream bodies from logged errors.
3. B3: wire the biometric/PIN gate to sensitive actions (or a recorded, time-boxed risk acceptance enforced by an explicit config flag), including the three-failure lockout.
4. B4/B6: build or explicitly descope the emergency-call module; make alert stubs fail visibly, never return success.
5. B5: transport model downloads over TLS (or document an integrity+confidentiality exception for LAN dev hosting before any real-user build); implement remote config or mark the category deferred in the workflow.
6. B7: amend the constitution Privacy bullet with the recorded cloud-stack exception (and user consent/disclosure), or change the default stack and gate cloud transmission.

## Verification limitations

- This was a static review plus the unit gate. No live-device testing, no biometric spoofing attempts (the gate is not wired), no adversarial-audio campaigns, and no network capture to confirm negotiated TLS versions (cleartext was established from code and ATS config).
- The key-leak proof uses a standalone Foundation repro of the `URLError` shape, not an in-app failed Gemini call (no API key was configured or used); the app's error-handling path was verified by reading the code.
- The secrets scan is regex-based over first-party paths and SDD outputs; vendored third-party code (`ios/vendor/`) was excluded after a first pass produced only minified-JS false positives. No dependency/CVE audit was performed (out of scope).
- Coverage percentage (100% on safety-critical paths) was not measured with instrumentation; the verdict relies on which paths exist and which tests exist.
- HEAD advanced during the review (`34c81b9`); all citations are pinned to `fb6e03c` except where the 34c81b9 delta is explicitly named. The delta was inspected (21 insertions in two files) and does not alter any verdict.
- Android was inspected read-only and lightly (dormant scaffolding); no Android tests were run.

## Conclusion

**SECURITY-NO_GO.** The application gets several things right — sanitisation at every LLM boundary, an LLM-isolated emergency keyword net, encrypted on-device stores, a scrubbing observability bus, clean secret scans, and a green unit gate (2672 tests, 0 failures at the reviewed revision). But two concrete leaks ship in Release code (raw transcripts to console; the API key to logs through `error_code`), the sensitive-action authentication is unwired with both security-design blockers open, emergency-call and remote-config security properties cannot be verified because the modules do not exist, and the cleartext LAN model URLs plus the cloud voice/health-data default sit in direct tension with the constitution's Security and Privacy bullets. Rework required; the itemised path back to GO is above.
