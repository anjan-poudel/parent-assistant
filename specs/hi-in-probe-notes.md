# Capability probe — Devanagari (Nepali) OCR via Vision

**Status: capability record for a DROPPED v1 requirement. It changes no scope.**

An earlier directive briefly considered shipping a custom Devanagari recognizer in v1.
That was dropped: v1 is **English source → Nepali target**, and Nepali/Devanagari OCR is
**not v1 scope**. No requirement has been added or changed by this probe, and no product
source was touched. What follows is the short fact-finding check that puts on the record
what the platform can actually do, so the drop is documented against the real platform
rather than against an assumption.

## What was probed

The probe uses the same Vision API the feature uses — `VNRecognizeTextRequest` — configured
exactly as `VisionTextRecognitionEngine` configures it in
`ios/ElderlyAssistant/Services/LiveTranslate/LiveTextDetector.swift`:
`recognitionLevel = .accurate`, `automaticallyDetectsLanguage = true`, and **no**
`recognitionLanguages` (the platform default), so the answer describes the feature's actual
environment.

- **Devanagari image**: rendered at test time (no fixture added to the repo) — the shipped
  Nepali string `"अनुवाद हुँदैछ…"` from `Localizable.xcstrings` (the live-translation
  "translating…" status), black on white, 96 pt, 1600×600.
- **English control**: `"Emergency Exit"`, same render, so a null Devanagari result can be
  attributed to the script rather than to a broken harness.
- **Instrument**: `ios/ElderlyAssistantTests/Services/LiveTranslate/HiINCapabilityProbeTests.swift`
  (5 tests; asserts only that the harness runs, the request completes, and the English control
  is read — it does **not** assert that `hi-IN` works, nor that it does not).

### Environment

| | |
|---|---|
| Date | 2026-09-17 |
| Device | `LCT-HiIN` — iPhone 17 simulator, iOS 26.5 (build 23F77), runtime `com.apple.CoreSimulator.SimRuntime.iOS-26-5` |
| Xcode | 26.6 (17F113), iPhoneSimulator26.5 SDK |
| Gate | `xcodebuild test -only-testing:ElderlyAssistantTests/HiINCapabilityProbeTests`, private derived data + private device; result bundle `ios/build/HiINProbe-gate.xcresult` — **5 passed, 0 failed, 0 skipped** (verified with `xcrun xcresulttool get test-results summary`, not the exit code) |

## Findings (verbatim)

### 1. `VNRecognizeTextRequest.supportedRecognitionLanguages(for:revision:)` — the revision in use

The shipped engine's request resolves to **(default) revision 3** on this runtime.

```
revision: 3
count: 30
languages: ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT", "ar-SA", "ars-SA", "tr-TR", "id-ID", "cs-CZ", "da-DK", "nl-NL", "no-NO", "nn-NO", "nb-NO", "ms-MY", "pl-PL", "ro-RO", "sv-SE"]
devanagari-capable codes present: []
```

**No Devanagari-capable language code appears at all** — no `hi-IN`, and no `ne-NP`, `mr-IN`
or `sa-IN` either (the filter checked all four prefixes). Latin, CJK (incl. Cantonese),
Cyrillic, Arabic, Thai, Vietnamese and more are present; Devanagari is not one of the
supported scripts on this runtime.

### 2. Devanagari, no `recognitionLanguages` (platform default)

```
=== PROBE-2 (no recognitionLanguages) ===
observations: 0, candidates: 0
```

**Zero recognized strings, zero candidates.** (The request completed without error — this is
an empty result, not a failure.)

### 3. Devanagari, `recognitionLanguages = ["hi-IN"]`

```
=== PROBE-3 (recognitionLanguages = ["hi-IN"]) ===
request.recognitionLanguages after set: ["hi-IN"]
observations: 0, candidates: 0
```

**Zero recognized strings, zero candidates** — byte-for-byte the same observable outcome as
the platform default in (2), despite the request's language state differing.

### 4. Throw / silently ignored / honoured — and how it was determined

**Determination: accepted (honoured as request state) — it does not throw, and it is not
reverted — but requesting `hi-IN` buys nothing, because `hi-IN` is not a language this
revision supports (finding 1) and the observable output is unchanged (findings 2 vs 3).**

How this was determined, in three steps:

1. **It does not throw.** The setter is not a throwing API in Swift; the probe wrapped the
   assignment in a Swift `do/catch` and reported whether it threw. It did not — there is no
   error surface on this API at all, so a bad language code cannot be rejected at set time.
   The run completed normally.
2. **It is not silently reverted.** The request's own state was read back:
   ```
   === PROBE-4 ===
   default recognitionLanguages (before): ["en_US"]
   after setting ["hi-IN"]: ["hi-IN"]
   state: HONOURED (the value stayed on the request)
   ```
   The platform default on this runtime is `["en_US"]`; after the set, the request reports
   `["hi-IN"]`. So the value is stored as given — the setter accepts even a language that is
   absent from `supportedRecognitionLanguages(for:revision:)`.
3. **But it changes nothing observable.** The recognition output with `["hi-IN"]` set
   (finding 3) is identical to the output with the default (finding 2): both
   `observations: 0, candidates: 0`. The word "honoured" therefore describes the request's
   internal state only — on this runtime, setting `hi-IN` does not make Devanagari
   recognizable.

The single most useful fact, stated plainly: **the API silently accepts a Devanagari
language code and silently produces nothing — there is no error to notice, and no
capability gained.** Any future caller that assumes "I set `hi-IN`, so it is supported"
would be wrong on this runtime, and wrong without a diagnostic.

### 5. English control (no `recognitionLanguages`)

```
=== PROBE-5 (English control, no recognitionLanguages) ===
observations: 1, candidates: 5
observation 0: candidates=5
  candidate Emergency Exit (confidence 1.0)
  candidate Emergency Ext (confidence 1.0)
  candidate Emergency Exi (confidence 1.0)
  candidate Emergency xit (confidence 0.5)
  candidate mergency Exit (confidence 0.5)
```

The harness works and Vision reads the rendered frame: the control text is recognized
verbatim, first candidate exact, confidence 1.0. This is what makes the null Devanagari
result attributable to the script rather than to a broken probe.

## Conclusion

On this runtime (iOS 26.5 / revision 3), Vision text recognition has **no Devanagari
capability**: the language is absent from the supported list, a Devanagari frame yields zero
observations under both the platform default and an explicit `hi-IN` request, and the API
provides no error when asked for an unsupported language. The English control confirms the
probe is sound.

This is consistent with the drop of the custom-recognizer directive: nothing here contradicts
v1's English-source → Nepali-target design, and nothing here is a requirement. The one
non-obvious operational fact worth keeping on the record is the silent-acceptance behaviour
in finding 4, since it could mislead any future (post-v1) work that assumes setting a
language code is sufficient.

## Scope statement

- No product source changed. The probe lives entirely in the test target.
- No Devanagari requirement was added anywhere; `specs/plan-tasks/plan.md` and the feature's
  requirements are untouched.
- The test file is a resident instrument (a few seconds in the unit run); it intentionally
  asserts only harness health and the English control, so it cannot go red if the platform's
  Devanagari situation changes in either direction. If a future runtime adds Devanagari, the
  probe re-run will show it in the transcript, not as a failure.
