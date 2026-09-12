# T-050: API key and raw upstream error bodies reach logs through `error_code`

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../index.md)
- **Component:** LogSanitiser allow-list and scrub pass (`Services/Observability/LogSanitiser.swift`), GeminiClient transport and error contract (`Services/Gemini/GeminiClient.swift`), and the six `error_code` emitter sites that stringify errors into the bus
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-004](T-004-observability-bus-log-sanitiser.md) (owns the LogSanitiser contract this task amends)
- **Blocks:** —
- **Requirements:** NFR-016, NFR-010, NFR-011
- **Origin:** `security-test` **SECURITY-NO_GO**, finding **B2** (`specs/security-test.md`)

## Description

The user's Gemini API key reaches the console, and it does so through the one field that bypasses the sanitiser's key allow-list. A second, same-chain defect rides along: raw upstream response bodies are retained on the error type and stringified into the same field.

**Placement rationale.** The subject is the cross-cutting PII/secret log boundary, and the single most load-bearing fix is in `LogSanitiser.swift` — TG-01's file, in the group whose charter is "the cross-cutting observability bus with PII log sanitisation". The emit sites themselves span several groups (TG-02 `GeminiSpeechRecognizer.swift`, `VoicePipeline.swift`; TG-03 `GeminiCommandInterpreter.swift`; TG-09 `NepaliCalendarPlugin.swift`; plus `ApplianceHelperSession.swift` and `GeminiClient+Vision.swift`), so no single feature group owns this. TG-01 is the only group that can hold it without splitting the fix across owners, and T-004 is the task whose contract it amends.

**The chain, verified end to end.**

1. The key is placed in the request URL query string: `GeminiClient.swift:230` (streaming, `...:streamGenerateContent?alt=sse&key=\(apiKey)`) and `:395` (unary, `...:generateContent?key=\(apiKey)`).
2. Transport failures rethrow the untouched `URLError`, which carries the failing URL: `GeminiClient.swift:258-263` (`catch { … throw error }`, throw at `:262`) and `:413-418` (throw at `:417`).
3. Six sites stringify it with `String(describing: error)` into the `error_code` field: `GeminiSpeechRecognizer.swift:139`, `GeminiCommandInterpreter.swift:107`, `VoicePipeline.swift:855`, `GeminiClient+Vision.swift:117`, `ApplianceHelperSession.swift:190`, `NepaliCalendarPlugin.swift:90`. `VoicePipeline.swift:856` additionally builds `let msg = "STT: \(err)"` for the error callback.
4. `LogSanitiser` copies `errorCode` without scrubbing: `:59` (`errorCode: event.errorCode`), because `error_code` is allow-listed at `:30` and the scrub pass (`:64-76`, patterns at `:37-47`) only runs over allow-listed **metadata** values and only matches phone / e-mail / blood-pressure shapes — none of which match key material or a URL.
5. `ConsoleObservabilityBus.emit` prints it: `AppCoordinator.swift:7049` (class), `:7062` (emit), `:7066` (the `print` that includes `errorCode=`).

**Empirical proof of record.** `security-test` reproduced the leak with a standalone Foundation repro of the request shape under a forced transport error: `String(describing: URLError)` contains `...key=SECRET_API_KEY_VALUE, NSErrorFailingURLStringKey=https://no-such-host.invalid/v1beta/models/...`, and `error.failingURL.absoluteString.contains(key) == true`. The app path differs only in that a resolvable host fails later for the same transport reasons (offline, DNS, TLS, timeout) — the leak does not depend on the host being unreachable.

**Second defect on the same chain.** `GeminiClientError.httpError(status:body:)` (`GeminiClient.swift:53`) retains the raw upstream response body, and is thrown with it at `:428-429` (`body: String(data: data, encoding: .utf8)`). That body is stringified at the same six sites, so raw upstream internals reach the console too — the error-leakage category of the same security test.

**Why `error_code` is the crux.** The allow-list (`:21-35`) is the sanitiser's primary control: unlisted **metadata** keys are dropped outright. `error_code` is not metadata — it is a top-level `ObservabilityEvent` field copied through at `:59` with no scrub at all. It is therefore the only content-bearing field that no allow-list decision and no scrub pattern ever touches, which is exactly why a URL-bearing error description survives the sanitiser intact.

**Options to weigh, with their consequences.** The fix has two independent halves and both should land:
- *(a) Stop putting the key in the URL.* Move to the `x-goog-api-key` header. This removes the root cause rather than the symptom, and is the only option that also removes the key from proxy logs, crash reports and any future error path. Cost: touches both request builders (`:230`, `:395`) and any test asserting the URL shape.
- *(b) Never stringify a URL-bearing error.* Map transport errors to a short code (domain + code) before emitting, at the six sites or in a shared helper. Bounded diff; must not silently drop the diagnostic value (an `NSURLErrorDomain` code is PII-free and useful).
- *(c) Bound `error_code` at the bus boundary.* Scrub or length-limit `errorCode` in `LogSanitiser` alongside `scrubValue`, or drop it from the allow-list path entirely. This is the defence-in-depth half and the only one that protects against emitters not yet written; it is also the half that must not break T-042's and the sanitiser's existing contract.
- *(d) Drop the raw upstream body from the logged error.* Keep the status code, discard or truncate the body before it reaches any emitter.

Doing (a) alone leaves (b)/(c) to catch the next key-bearing error; doing (c) alone hides the leak from the console while leaving the key in the URL. The task should land (a) plus at least (b) or (c), and record which half covers what.

## Acceptance criteria

```gherkin
Feature: The Gemini API key and raw upstream bodies no longer reach logs

  Scenario: The key is not carried in a URL that can reach an error description
    Given GeminiClient.swift:230 and :395 place the key in the query string as key=\(apiKey)
    And transport failures rethrow the untouched URLError at GeminiClient.swift:258-263 and :413-418
    When the fix lands
    Then the API key is no longer present in a request URL (moved to the x-goog-api-key header or equivalent), or every path that could surface that URL is proven to emit no URL-derived text
    And a test demonstrates that a forced transport failure on a configured client emits no key material, proven against the real error-handling path and not by inspection alone

  Scenario: No emit site stringifies a URL-bearing error into the bus
    Given the six sites GeminiSpeechRecognizer.swift:139, GeminiCommandInterpreter.swift:107, VoicePipeline.swift:855, GeminiClient+Vision.swift:117, ApplianceHelperSession.swift:190 and NepaliCalendarPlugin.swift:90 pass String(describing: error) as errorCode
    And VoicePipeline.swift:856 builds "STT: \(err)" for the error callback
    When the fix lands
    Then no site passes a String(describing:) of a transport or HTTP error to errorCode or to any other logged field
    And each site passes a short content-free code (error domain plus code, or an explicit mapped code) whose diagnostic value is preserved

  Scenario: The bus boundary defends against emitters not yet written
    Given error_code is allow-listed at LogSanitiser.swift:30 and copied unscrubbed at :59
    And the scrub pass (:64-76, patterns at :37-47) runs only over allow-listed metadata values and matches only phone, e-mail and blood-pressure shapes
    When the fix lands
    Then errorCode is bounded at the sanitiser boundary (scrubbed, length-limited, or restricted to a known-safe code set) so that a future emitter cannot leak through it
    And the change is made in LogSanitiser and does not depend on every emitter being correct

  Scenario: Raw upstream response bodies do not reach logs
    Given GeminiClientError.httpError(status:body:) retains the raw upstream body (GeminiClient.swift:53) and is thrown with it at :428-429
    When the fix lands
    Then no raw upstream response body is stringified into error_code or any other logged field
    And the HTTP status remains available for diagnostics

  Scenario: The fix satisfies the standards it is measured against
    Given NFR-016 requires logs to contain no PII and requires a log sanitiser to strip it before writing
    And NFR-010 establishes that credential material must never be written to logs
    And NFR-011 requires TLS 1.2+ on all outbound connections
    When the fix lands
    Then no secret, credential, URL-bearing error description, or raw upstream body reaches the console or any other sink in any build configuration
    And the sanitiser's existing guarantees for the other allow-listed keys (LogSanitiser.swift:21-35) are unchanged, verified by the existing tests still passing

  Scenario: The remediation is pinned against regression
    Given the leak was demonstrated by reproducing a forced transport error
    When the fix completes
    Then a test fails if a key-bearing URL or a raw upstream body can again reach error_code, exercising the configured-client error path rather than a mock-free unit of the formatter
    And the canonical iOS gate ./ios/build.sh test:unit passes with no new failures
```

## Implementation notes

- This is a rework task from the `security-test` NO_GO. Finding B2 is the primary input; its analysis is not re-derived here. B1 (Release-build transcript prints) is **T-049** and is out of scope — do not edit the Whisper STT engines here.
- Verified facts to cite when implementing: URLs `GeminiClient.swift:230`, `:395`; rethrow sites `:258-263` (throw at `:262`) and `:413-418` (throw at `:417`); `httpError` case `:53`, thrown `:428-429`; emit sites `GeminiSpeechRecognizer.swift:139`, `GeminiCommandInterpreter.swift:107`, `VoicePipeline.swift:855-856`, `GeminiClient+Vision.swift:117`, `ApplianceHelperSession.swift:190`, `NepaliCalendarPlugin.swift:90`; sanitiser `LogSanitiser.swift:21` (allowedKeys), `:30` (`error_code`), `:37` (piiPatterns), `:49` (sanitise), `:51` (metadata loop), `:59` (errorCode copy), `:64` (scrubValue); bus `AppCoordinator.swift:7049`, `:7062`, `:7066`.
- `LogSanitiser` is a shared control: T-042 established that the same sanitiser is reused rather than duplicated (`CommandRouter.swift:2376-2384`), and `stages` (`:35`) and `error_code` (`:30`) are its only content-bearing allowances. Tightening `error_code` must not break `stages` or the router/plugin paths; run the existing sanitiser and router tests.
- Prefer one shared mapping helper over six local rewrites, so the next emitter inherits the safe behaviour by construction rather than by review.
- Android: the Gemini client and the observability bus are iOS-side; verify rather than assume, and record the verification. If an Android equivalent exists, the same two halves apply.
- No PII in tests or fixtures (NFR-016). Do not put a realistic-looking key in a test: use an obvious sentinel value and assert on the sentinel, and remember that `specs/security-test.md` itself tripped the ai-sdd secret scanner on a 40-character hex commit SHA — long opaque strings in artifacts are a known false-positive source.
- The gate is green today (2672 tests, 0 failures at `fb6e03c`). Keep it green; do not weaken, skip or delete an assertion to land this fix.

## Definition of done
- [ ] Key removed from the request URL (header-based auth or equivalent), with both request builders updated (`GeminiClient.swift:230`, `:395`)
- [ ] No emit site stringifies a URL-bearing or HTTP error into any logged field; all six sites plus `VoicePipeline.swift:856` carry a content-free code with diagnostic value preserved
- [ ] `errorCode` bounded at the sanitiser boundary so a future emitter cannot leak through it, made in `LogSanitiser` itself
- [ ] Raw upstream body no longer retained or stringified into logs (`GeminiClient.swift:53`, `:428-429`), status code retained
- [ ] Test proves no key material can reach a log sink on a forced transport failure, exercising the real error path; canonical gate `./ios/build.sh test:unit` green
- [ ] Existing sanitiser/router guarantees unchanged — `LogSanitiser.swift:21-35` behaviour for other keys verified by the existing tests still passing
- [ ] Android equivalent verified and recorded, not assumed
- [ ] No PII or realistic secret in any added test or fixture (NFR-016); no T-049 scope (Whisper STT engines) touched
