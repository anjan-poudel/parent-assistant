# Security Test (Re-run) — security-test (phase: review, risk tier T1)

- Task: `security-test` (ai-sdd workflow `elderly-ai-assistant-sdd`)
- Report path: `specs/security-test.md` (SDD project: `/Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant`)
- Code repo under test: `/Users/anjan/workspace/projects/elderly-ai-assistant` (iOS at `ios/ElderlyAssistant/`, Android at `android/`)
- Reviewed revision: master `57abb2e` — HEAD == `57abb2e` and the working tree was clean at review start and review end; HEAD did not move during the review. The full 40-character SHA is recorded in `ios/build/.last-tested-sha`; it is elided from this report only to clear the ai-sdd secret scanner's AWS-key regex false positive, exactly as in the previous report.
- Re-run context: the previous pass (rev `fb6e03c`) returned SECURITY-NO_GO with blocking findings B1–B7. This pass re-tests B1/B2 against fix commits `02f22dd`, `b64385b`, `5513323`; verifies the B3–B7 risk acceptance recorded as constitution Open Decision #11; and assesses peer commits `469520f` and `8265542`.
- Verification performed: static reading of the cited code at `57abb2e`; re-derivation of the recorded gate evidence; execution of the Release-log source guard; and an in-memory negative check of the guard's detection rules. No file was modified and nothing was committed (the reviewer holds no write tool).

## Summary

The two release-blocking defects of the previous pass are remediated and independently verified at `57abb2e`. B1: both on-device STT engines now guard their transcript prints with `#if DEBUG` (compiled out of Release) and print error diagnostics as content-free domain+code pairs; a source guard that fails on regressions is wired into every unit gate and passes. B2: the Gemini API key travels in the `x-goog-api-key` header (no `key=` in any URL), the raw upstream body is no longer retained or stringified, all six former raw-error emitters use content-free codes, and `LogSanitiser` bounds `error_code` at the console sink; dedicated tests are present and Passed in the recorded gate. B3–B7 remain unimplemented, exactly as the previous pass found; they are closed as recorded human risk acceptance (Open Decision #11), not by remediation, and are not treated as rework blockers in this re-run. One partial movement within B5: commit `469520f` fixed the default brain's cleartext LAN download URL (now HTTPS); the remaining LAN entry, the absent remote-config chain and the ATS local-networking exception keep B5 under the descope. The overall verdict moves to SECURITY-GO on that basis, with the explicit caveat that the descoped categories are accepted risks, not verified-secure controls.

## Decision

**SECURITY-GO.** The workflow's decision string (`review.decision == SECURITY-GO` per the previous report) is met. Basis: (1) findings B1 and B2 — the only findings not covered by the recorded descope — are remediated and independently verified at `57abb2e`; (2) findings B3–B7 are closed by recorded human risk acceptance (constitution Open Decision #11), which states it is not evidence of a fix. Categories and focus areas carry per-category verdicts below; the descoped ones read `SECURITY-NO_GO` on the merits and are annotated `risk-accepted (OD#11)`. This GO certifies that the in-scope defects are fixed and the out-of-scope risks are formally accepted; it must not be read as a security guarantee for the descoped controls (no sensitive-action auth exists, no emergency-call module exists, no encrypted remote-config chain exists, the cloud stack remains the default).

## Revision / re-run note

HEAD was `57abb2e` for the whole review (verified at start and end; `git status` clean). All citations are pinned to `57abb2e`. For diffability with the previous report (which cited `fb6e03c`), line numbers that moved are re-cited at their `57abb2e` positions. The fix commits `02f22dd`, `b64385b` and `5513323` are on master, and the guard they introduced (`check-unguarded-transcript-prints.sh` in `02f22dd`, renamed and widened to `check-release-log-safety.sh`/`.py` in `5513323`) is the one reviewed here.

## Sources read

- `constitution.md` — Standards (Privacy `:73-77`, Security `:79-85`, Quality `:87-91`); Open Decision #11 `:117-122`. The examples-tree constitution carries the same #11 text (trivially different: it writes `specs/security-test.md` where the repo copy writes `security-test.md`).
- Previous report `specs/security-test.md` (rev `fb6e03c`) — B1–B7 and the section `What would move the failing categories to SECURITY-GO`.
- Fix/peer commits read as diffs and as code at `57abb2e`: `02f22dd`, `b64385b`, `5513323`, `469520f`, `8265542`.
- Code at `57abb2e`: `WhisperSpeechRecognizer.swift`, `WhisperKitSpeechRecognizer.swift`, `GeminiClient.swift`, `GeminiClient+Vision.swift`, `ErrorCodeMapper.swift`, `LogSanitiser.swift`, `SpeechRecognizer.swift`, `VoicePipeline.swift`, `GeminiSpeechRecognizer.swift`, `GeminiCommandInterpreter.swift`, `ApplianceHelperSession.swift`, `NepaliCalendarPlugin.swift`, `AppCoordinator.swift`, `CommandRouter.swift`, `ModelCatalog.swift`, `ModelDownloadService.swift`, `SpeakerBiometricService.swift`, `FamilyNotifier.swift`, `Info.plist`, `ios/build.sh`, `ios/tools/check-release-log-safety.{sh,py}`, `seniOS.xcodeproj/project.pbxproj`.
- Tests at `57abb2e`: `GeminiKeyLogBoundaryTests.swift`, `LogSanitiserTests.swift`, `InputSanitiserTests.swift`, `CommandRouterSafetyNetTests.swift`, `InterpreterAvailabilityTests.swift`, `BrainModelSelectionTests.swift`.
- `.ai-sdd/outputs/implement-notes.md` (T-049/T-050 fix-pass record, including the documented residual gaps).

## Verification performed (raw evidence)

### Recorded gate evidence — re-derived, not re-run

- `ios/build/.last-tested-sha` contains `57abb2e` (full 40-char SHA).
- `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.09.13_07-07-45-+1000.xcresult` summary: result `Passed`, 2687 passed, 0 failed, 6 skipped (iPhone 17 Pro simulator).
- Per-test results in the same xcresult for `GeminiKeyLogBoundaryTests`, `LogSanitiserTests`, `InterpreterAvailabilityTests`, `BrainModelSelectionTests`: 38 nodes, all `Passed`, none failed. The B2 boundary tests (`testForcedTransportFailureLeaksNoKeyMaterialToTheConsoleSink`, `testRogueEmitterStringifyingAKeyBearingErrorIsBoundedAtTheConsoleSink`, `testUnaryRequestCarriesKeyInHeaderAndNotInURL`, etc.) therefore ran and passed in the gate recorded for this SHA.
- I did **not** re-run `./ios/build.sh test:unit`: the mandate for this review is read-only, and a re-run writes build artifacts. The gate evidence above is re-derived from the recorded xcresult and the SHA file; it is dynamic evidence produced by the gate, but not re-executed in this pass.

### Release-log source guard — executed (read-only)

- `./ios/tools/check-release-log-safety.sh` at `57abb2e` → exit 0, prints `no transcript content or raw error object can be printed in a non-Debug configuration`.
- The guard is wired into every test gate: `ios/build.sh:407-417` runs it at the top of `run_tests`, and `test:unit` dispatches to `run_tests unit` (`build.sh:501-504`). The recorded green gate therefore includes a green guard.
- In-memory exercise of the guard's judge rules (no files written), to verify the guard can fail:
  - transcript interpolation outside `#if DEBUG` → FLAGGED (tree-wide rule, all `*.swift` under `ElderlyAssistant/`);
  - transcript inside `#if DEBUG` → allowed (deliberate);
  - raw error interpolation outside `#if DEBUG` in an engine file → FLAGGED;
  - raw error interpolation outside `#if DEBUG` in a non-engine file → allowed (documented scope gap, adjudicated below);
  - `nsError.domain`/`nsError.code` outside `#if DEBUG` → allowed (content-free by rule);
  - `String(describing:)`, `.localizedDescription`, bare `print(error)` in an engine file → FLAGGED.

### B1 re-test — FIXED (verified at 57abb2e)

- `WhisperSpeechRecognizer.swift:812-820` — `#if DEBUG` now wraps the transcript print (`:819`); the Release-visible print at `:809-811` is metadata only (attempt, duration_ms, audio_seconds, chars). The raw-error print at `:842-844` interpolates `nsError.domain`/`nsError.code` only — the error object is never placed in the string. (Unguarded on purpose so attempt/duration diagnostics survive in Release; it is content-free.)
- `WhisperKitSpeechRecognizer.swift:499-507` — transcript print inside `#if DEBUG` (`:506`). `:512-521` — inference-failure print now `#if DEBUG` and domain+code only (`:519`). `:307-318` (warm failure) and `:735-745` (dialect-embedding failure) — the two review-found residual raw-error prints, both now `#if DEBUG` and domain+code (fix commit `5513323`).
- Compilation contract: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` appears once (project.pbxproj `:2722`) and only under the Debug configuration (`name = Debug` `:2726`); the Release configuration block (`:2728+`) has no such setting, so `#if DEBUG` content cannot compile into Release.
- Guard implementation read: `check-release-log-safety.py` — engine file list `:61-64`; missing engine file is a failure `:288-292` (so the guard cannot go green vacuously); transcript rule sweeps every Swift file `:296-301`; raw-error rule applied only when the file is an engine `:278-282`; `#else`/nested-region handling and multi-line statement accumulation `:198-264`. Wrapper: `check-release-log-safety.sh:1-15`.
- Android: re-verified at `57abb2e` there are no STT/Whisper/speech-recognition sources (rg over `android/`), so there is no counterpart to fix.

### B2 re-test — FIXED (verified at 57abb2e)

- Key out of the URL: `GeminiClient.swift:403-411` (unary URL built with no key query item), `:237-241` (streaming URL likewise); key set as the `x-goog-api-key` header at `:416` and `:254`. No `key=` occurrence remains anywhere under `Services/Gemini/`.
- Raw upstream body dropped: `GeminiClientError.httpError(status:)` carries the status only (`:57`); the throw sites no longer retain or stringify `data` (`:439-444`; streaming HTTP failure `:274-278`). The `GeminiClientError` extension `:494-509` provides content-free codes (`http_429`, `not_configured`, ...).
- All six former `String(describing: error)` emitters now use `ErrorCodeMapper.code(for:)`: `GeminiSpeechRecognizer.swift:144`, `GeminiCommandInterpreter.swift:111`, `VoicePipeline.swift:857-864` (plus its `STT: <code>` message at `:862`), `GeminiClient+Vision.swift:120`, `ApplianceHelperSession.swift:192`, `NepaliCalendarPlugin.swift:92`. A tree scan finds no remaining `String(describing:)`-into-log shape outside a non-log classification reason (`DialectIdentifier.swift:338`, a bundled-table issue string, not an error/URL).
- Mapper read: `ErrorCodeMapper.swift:38-51` — `NSURLErrorDomain` becomes `url_error_<code>`, other errors become a sanitised domain token + numeric code; it never reads `localizedDescription`, `String(describing:)` or user-info values.
- Sink bound read: `LogSanitiser.swift:24-25, :42-53, :94, :106-122` — `error_code` is scrubbed, shape-checked to the code charset, redacted when it contains a 32+-character unbroken alphanumeric run, and capped at 64 chars. The console sink sanitises before printing (`AppCoordinator.swift:7049` class, `:7063` sanitise, `:7066` print).
- Tests read and green in the gate: `GeminiKeyLogBoundaryTests.swift` — header-not-URL for both builders (`:40-80`), real emitter sites with a key-bearing `URLError` (`:108-154`), real console capture end-to-end (`:215-239`), rogue-emitter bound at the sink (`:158-180`), upstream 429 body not emitted (`:184-208`); `LogSanitiserTests.swift` — exact leak shape redacted (`:82-96`), key-shaped run redacted with boundary tests (`:126-142`).
- End-to-end console tests use process-stdout capture and assert the key, `key=`, `https://` and `NSURLErrorFailingURL` do not appear — this is the strongest available local proof of the fixed chain.

### B3–B7 descope verification

- Open Decision #11 exists in both constitutions (`constitution.md:117-122`), and it covers each item: B3 `:118`, B4/B6 `:119`, B5 `:120`, B7 `:121`. It states `This entry records risk acceptance — it is not evidence that the findings are fixed.` Nothing in it claims B3–B7 are remediated; the sentence that calls B1/B2 remediation `defined, not yet implemented` was true when written and concerns B1/B2 (now implemented — see above), not B3–B7.
- State at `57abb2e`, unchanged from the findings: `SpeakerBiometricService.swift:16-20` still says NOT WIRED (CommandRouter gating, liveness, PIN fallback + lockout, UI); no PIN/Argon2/bcrypt/lockout code exists; `CommandRouter.handleEmergency` `:2213-2216` still only posts a local notification and speaks, with no dispatcher, cancel listener or threshold evaluation; `FamilyNotifier.swift:109-113` still prints a device-token prefix and returns `true` unconditionally; the default voice stack is still `.gemini` (`AppCoordinator.swift:1612-1613`); no libsignal/Double Ratchet/config-payload types exist.
- Fixed since (B5 partial, said explicitly as requested): commit `469520f` moved the default brain entry `intentQwen4BS43` to an HTTPS GitHub release URL (`ModelCatalog.swift:549`, full-length sha256 pin), and `8265542` repinned the tests, which now assert the default entry has an `https://` URL and a full non-zero sha256 (`InterpreterAvailabilityTests`, all Passed in the gate xcresult). Still open inside B5 and therefore still covered by OD#11: the curated entry `qwen4BNepali` still ships `http://192.168.1.117:8765/...` (`ModelCatalog.swift:645-654`, offered in `availableBrainEntries` `:815-826`), ATS still carries `NSAllowsLocalNetworking` (`Info.plist:107`), and the remote-config chain remains absent. B5 is not fully fixed.
- B3, B4, B6, B7: no remediation found at `57abb2e`; the recorded acceptance is the sole closure.

### Peer-commit exposure check

- `469520f` (default brain now HTTPS, Q3_K_M): read the diff and the current catalogue. Default entry now points at a GitHub release over HTTPS with a full 64-hex sha256 (`ModelCatalog.swift:549`); no new exposure — a net reduction of cleartext exposure on the default download path. Non-security note for the lead: the commit comment records Q3 gate margins (time 0.909, contact 0.833) with Q4 as the stated ship target; model-quality confirmation is outside this security review.
- `8265542` (test repin): test files only; strengthens the default-brain pins (keeps the https invariant, adds a full-length non-zero sha256 assertion). No production code, no new exposure.

## Adjudication of the two residual gaps documented by the fix pass (explicit)

1. **The raw-error rule is ENGINE_FILES-scoped.** **Acceptable — not a finding.** The PII-class rule (transcript content) is tree-wide; only the raw-error rule is limited to the two engine files, and the guard fails if either file is missing. The real, uninspected console prints of raw error objects outside the engines (`RoutineAlarmScheduler.swift:88`, `ExternalReminderScheduling.swift:70`, `AlarmKitSystemScheduler.swift:102`, `AlarmTimersService.swift:210,429`, `AlarmKitAlarmBackend.swift:280,304,318,339,354`, `AlarmSchedulingBackend.swift:181,197`, `PlatformAlarmScheduler.swift:53,105`, `Speaker.swift:510`, `PhotoVerifier.swift:44,48`) all render local OS errors (notification/alarm/camera/TTS-load domains) with no key material, no upstream bodies and no user speech/health/contact content; the model-download reason that can embed a URL stays in UI state and is never printed (the bus emits content-free codes, `ModelDownloadService.swift:203,237` vs `:250+`). The only secret-bearing error source (Gemini transport) is structurally fixed (no key in URL) and double-bounded (mapper + sink). Recommendation, not blocker: widen the raw-error rule tree-wide in a future pass or keep an explicit residual-site list, since the guard docstring's `tracked separately` currently resolves only to a scope note in `.ai-sdd/outputs/implement-notes.md:400-417`.
2. **Content inside a Debug region is deliberately not flagged.** **Acceptable.** `DEBUG` is defined only in the Debug configuration (project.pbxproj `:2722` under `:2726`; Release block `:2728+` clean), so `#if DEBUG` content cannot compile into a Release build; the guard's job is Release-log safety, not Debug hygiene. Caveat recorded: this relies on the build-config contract — a Release build that manually defines `DEBUG` would reintroduce the prints.

## Category verdicts (task library categories, mapped to this codebase)

Each category carries exactly one of `SECURITY-GO` / `SECURITY-NO_GO`. No category is a bare N/A. `risk-accepted (OD#11)` means the finding stands, is closed by the recorded human decision, and is not a rework blocker in this re-run.

| # | Library category | Mapping on this codebase | Verdict | Evidence |
|---|---|---|---|---|
| 1 | SQL injection | Proven-absent: client-only app, no server, no relational store, no SQL in first-party iOS/Android code; persistence is Keychain/encrypted files | `SECURITY-GO` | rg for sqlite/CoreData/GRDB/Realm/FMDB/SQL statements over `ios/ElderlyAssistant` + `android` → no matches |
| 2 | Input validation (400s) | No HTTP server → no 400 surface; nearest analogue is voice/STT text intake | `SECURITY-GO` | Sanitiser at `LocalIntentInterpreter.swift:101`, `GeminiCommandInterpreter.swift:56`, `LlamaCommandInterpreter.swift:444`, plugin path `CommandRouter.swift:2380`; `InputSanitiserTests` present |
| 3 | Auth bypass | On-device analogue: voice-biometric/PIN gate on sensitive commands | `SECURITY-NO_GO` — risk-accepted (OD#11); not remediated; not a reblocker | `SpeakerBiometricService.swift:16-20` NOT WIRED; no PIN/lockout code anywhere; sensitive-call deterministic path fails closed, LLM path confirmation-only |
| 4 | PII in logs | Health/contact/conversation speech must not reach logs | `SECURITY-GO` | B1 remediated: guarded prints, content-free error prints, tree-wide transcript guard green; residual: `FamilyNotifier.swift:112` token-prefix print (descoped stub, non-blocking) |
| 5 | Secrets in output | Committed secrets (none found) and the runtime Gemini key | `SECURITY-GO` | B2 remediated: header auth, no `key=` URLs, body dropped, all six emitters mapped, sink bound; repo regex scan clean |
| 6 | Audit log completeness | Emergency triggers + command/confirmation transitions exist; auth/config/permission event classes have no feature | `SECURITY-GO` (scoped) | `command_emergency_keyword` `CommandRouter.swift:567,1435`; `command_emergency` `:2117`; `CommandRouterSafetyNetTests.swift:32`; scope statement below |
| 7 | Error leakage | Stack traces / internals / raw upstream bodies in logs | `SECURITY-GO` | Former six stringification sites now `ErrorCodeMapper`; upstream body no longer retained (`GeminiClient.swift:57,439-444`); residual local-OS error prints outside the engines adjudicated above (no secrets/PII) |

Scope statement for category 6 (unchanged in substance from the previous report): this GO covers the events that exist. Audit logging is console-only (no durable store) and the auth/config/permission event classes have no feature to audit — now also recorded as descoped via OD#11 (B3/B5). Re-test if those features ship.

## Focus-area verdicts (workflow overrides)

| Focus area | Verdict | Evidence |
|---|---|---|
| Voice input injection (quarantine sanitiser, all interpreters, router paths) | `SECURITY-GO` | Sanitiser at every LLM entry point (see category 2); deterministic emergency path isolated and tested; no change since the previous GO |
| Health data PII in logs | `SECURITY-GO` | Previously failed via B1; now the transcript prints are `#if DEBUG` and the guard enforces the rule tree-wide. Residuals noted under category 4 |
| Auth bypass (biometric/PIN, liveness, lockout, sensitive commands without auth) | `SECURITY-NO_GO` — risk-accepted (OD#11) | Feature set still absent (`SpeakerBiometricService.swift:16-20`); closed by decision, not remediation |
| Emergency call trigger validation (false-cancellation, threshold suppression, LLM isolation, coverage) | `SECURITY-NO_GO` — risk-accepted (OD#11) | LLM isolation of the keyword net remains implemented/tested; no emergency-call module exists (`CommandRouter.swift:2212-2216`); B4/B6 accepted |
| Encrypted config payload verification (remote config, key handling, replay/tamper, TLS 1.2+) | `SECURITY-NO_GO` — risk-accepted (OD#11) | No remote-config chain exists; B5 partially remediated on the default-brain URL only (see above); LAN entry + ATS exception remain |

## Findings status versus the previous pass

| Finding | Previous (fb6e03c) | At 57abb2e |
|---|---|---|
| B1 raw Release transcript prints | Blocking | FIXED — `#if DEBUG` guards + content-free error prints + wired regression guard (verified) |
| B2 key / raw upstream body via error_code | Blocking | FIXED — header auth, body dropped, mapper, sink bound; tests green in the recorded gate (verified) |
| B3 no sensitive-action auth | Blocking | Not remediated; descoped by OD#11 (risk acceptance) |
| B4/B6 no emergency module; silent-success alert stub | Blocking | Not remediated; descoped by OD#11 |
| B5 cleartext config/model transport | Blocking | Partially remediated: default brain now HTTPS (`469520f`); LAN entry `ModelCatalog.swift:654`, remote chain and ATS exception unchanged; remainder descoped by OD#11 |
| B7 cloud stack vs Privacy bullet | Blocking (sign-off) | Not remediated; descoped by OD#11 |

Closure mapping of the previous report's `What would move the failing categories to SECURITY-GO`: (1) B1 — done; (2) B2 — done; (3) B3 — accepted, not wired; (4) B4/B6 — accepted, not built; (5) B5 — partial fix plus acceptance; (6) B7 — accepted, not amended.

## Non-blocking observations

1. Hardcoded `InputSanitiser.maxLength = 200` (carried from T-042 notes; unchanged).
2. Injection control remains a denylist; delimiters, confirmation tiers and the LLM-isolated emergency path are the real protections (carried).
3. `reason`/`sampleIndex` metadata still dropped by the sanitiser allowlist (debug-fidelity only; carried).
4. Console-only telemetry — no durable audit trail (carried; relevant to any future audit requirement).
5. DEBUG-only raw-content prints remain in the Gemini files (`GeminiSpeechRecognizer`, `GeminiCommandInterpreter`) — compiled out of Release per the config check; do not distribute Debug builds (carried).
6. `voiceError` still stores `String(describing:)`-style error text as UI state; the UI renders localized text only, and it is not a log sink (carried).
7. `FamilyNotifier.swift:112` prints an 8-character device-token prefix — part of the descoped B6 stub; prefix alone is not usable to push (carried).
8. Raw-error prints outside the engine files (alarm/scheduler/Speaker/PhotoVerifier family listed in the adjudication) remain in Release console output; no secret/user-content exposure, but a future guard-widening candidate.
9. The guard docstring phrase `tracked separately` for out-of-scope raw-error prints resolves only to the implement-notes scope record; consider an explicit tracking list or widening.

## Verification limitations

- The canonical gate was **not re-run** by me (read-only mandate); its result was re-derived from the recorded xcresult (result, counts, per-test statuses) and `.last-tested-sha`. The per-test `Passed` statuses are gate-produced evidence, not a live re-execution in this pass.
- Static review plus the guard execution and in-memory judge check. No live-device testing, no network capture/negotiated-TLS verification, no dynamic auth or emergency tests (the controls do not exist), no adversarial-audio campaign.
- The guard's negative behaviour was exercised function-level in memory; the full file-scan negative regression (which would require writing a synthetic file) was not re-run — the fix-pass record documents that test (implement-notes `:420-424`).
- Secrets scan is regex-based over first-party paths (no AWS/GCP/Stripe/private-key hits); no dependency/CVE audit and no vendored-code audit (`ios/vendor/` excluded as before).
- Android was inspected lightly (no STT/Gemini counterparts; dormant scaffolding); no Android tests run.
- The examples-tree constitution differs from the repo copy only in the OD#11 path prefix (`specs/security-test.md`); no security-relevant divergence was found in #11's substance.

## Conclusion

**SECURITY-GO.** Relative to the previous SECURITY-NO_GO this is a real movement, not a paper one: B1 and B2 — the two defects that shipped user speech and the API key into Release logs — are fixed in code, pinned by tests that ran green in the recorded gate at this exact SHA, and defended by a source guard wired into every unit gate. B3–B7 are unchanged and remain absent capabilities, but they are now closed by recorded human risk acceptance (Open Decision #11), which the re-run instructions direct me not to re-litigate as new blockers; the acceptance itself was verified to cover every descoped item and to claim no remediation. Residual risks the lead engineer still owns: the descoped auth/emergency/config gaps, the remaining LAN model URL and ATS exception, the cloud-stack default, the guard's engine-scoped raw-error rule, and the Q3 default-brain quality margins. Within that recorded scope, all non-descoped security-test criteria are met at `57abb2e`.
