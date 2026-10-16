# Live camera translation — device validation **results** record (T-030)

**Protocol this records:** `specs/LCT-device-validation-protocol.md` (DV-1 … DV-16), read with it.
**Written:** 2026-09-17.
**Governing rule, from the protocol:** the agent measures, the owner decides.

> **Headline, stated first because everything below depends on it: no device run happened.**
> No physical iPhone was available to this run and no genuine airplane-mode run was possible. Every
> device-only check is recorded below as **NOT RUN** with its reason. Nothing in this file is a
> device observation, and none of the simulator measurements below is a substitute for one.

---

## 1. What this run had

| Item | Value |
| --- | --- |
| Host | macOS 26.6.2 (build 25G83) |
| Xcode | 26.6 (build 17F113) |
| Simulator used | iPhone 17, iOS 26.5 (build 23F77) — `platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8` |
| Physical device attached | **none** |
| Physical device available to the run | **none** — this is why the device-only rows read NOT RUN |
| Source state | worktree `live-camera-translation`, branch `worktree-live-camera-translation`, based on `95eb635acfe637096bf87a45162429b06cefb5a3`, with the feature's changes **uncommitted** in the working tree (45 modified/untracked paths at the time of the run) |
| Build identifier | **none issued.** No archive, no TestFlight build, no device install exists for this feature yet, so there is no build number to record against a device measurement. A device run must record one; this record deliberately leaves the column empty rather than inventing a value |

## 2. Measurements actually taken (simulator, not device)

These are the only numbers in this file. They are simulator numbers, and they answer pipeline
questions, not camera questions.

| # | Measurement | Method (reproducible) | Result |
| --- | --- | --- | --- |
| M-1 | Dense menu-like page read through the real Vision path | `xcodebuild test … -only-testing:ElderlyAssistantTests/OCRFixturePageTests -resultBundlePath build/TG10-evidence.xcresult`, then `xcrun xcresulttool export attachments --path build/TG10-evidence.xcresult --test-id "OCRFixturePageTests/testADenseMenuLikePageIsReadAsSeveralRegionsWithSaneBoxes()"` | **Passed.** Attachment `ocr-fixture-measurement`: `{"fixtureLines": 8, "regions": 8, "nonEmptyRegions": 8, "expectedWordsRead": 6, "expectedWords": 6, "fixture": "menu-page-1200x800-44pt"}` — an 8-line synthetic menu page produced 8 regions, all non-empty, and all 6 expected words were read |
| M-2 | Test duration for M-1 | from the same result bundle | 28.89 s with the host at load average above 150 (simulator runtime processes from concurrent work); 3.58 s for the same test in an earlier, less loaded run of the same build. Recorded because the 8× spread is machine load, not a property of the feature |
| M-3 | Security evidence suites | same command, `-only-testing:` for `SecurityEvidenceBoundaryTests`, `SecurityEvidenceIndexTests` | **Passed**: boundary 7/7, index 5/5; 13 tests total across the three suites, 0 failures |
| M-4 | Release log-safety gate (AM-5) | `bash ios/tools/check-release-log-safety.sh` | **exit 0** — 24 fixtures over 12 declared rules, every rule with a positive and a negative fixture |
| M-5 | Rule falsification (is each rule load-bearing?) | `python3 ios/tools/check-release-log-safety-fixtures.py --falsify` | **exit 0** — 36 cases; disabling any one of the 12 rules makes that rule's positive fixture pass, i.e. every rule carries its own weight |

M-1's fixture is synthetic text rendered by the test itself. It is not a photograph and it is not
recognition *in the field*: it cannot show focus, exposure, motion blur, glare, paper stock or
viewing distance. Those are DV-1, DV-13 and DV-15, and they are NOT RUN.

## 3. Device-only checks — every one NOT RUN, with its reason

The reason is the same for all of them in substance — **no device was available to this run** — but
each row states what it specifically requires, so that a later run can be executed against this table
without re-reading the protocol.

| Check | Requires | Outcome | Device / OS / build | Measurement |
| --- | --- | --- | --- | --- |
| DV-1 Real menu page in poor light | A camera, real paper, real lighting | **NOT RUN** — no device | — | — |
| DV-2 Sustained use: cadence and thermal (OD1) | A device with a battery and a thermal envelope; 10 min continuous | **NOT RUN** — no device; a simulator has no thermal state and no meaningful battery | — | — |
| DV-3 In-place vs callout on a real sign (OD2) | Printed signs at arm's length | **NOT RUN** — no device | — | — |
| DV-4 Offline degradation in airplane mode | A real radio, real airplane mode, plus the Wi-Fi-off variant | **NOT RUN** — a genuine airplane-mode run is not possible here; a scripted `URLError` is what the test suite covers, and it is not a substitute for the real network stack | — | — |
| DV-5 Cache at rest on the real device | A device container (Xcode ▸ Devices export) and the device's file-protection class | **NOT RUN** — no device. The byte-level at-rest property is covered on the storage double by T-032's `LiveTranslateCipherStorageTests.testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext` and siblings; the *real container* and the *platform protection class* remain unverified | — | — |
| DV-6 Consent flow end to end, real copy (OD3) | A fresh install on a device, read aloud by a non-engineer | **NOT RUN** — no device. The prompt-before-request ordering and the request count are covered at the boundary in the evidence suite; the copy review is an owner action (§4) | — | — |
| DV-7 Tap-to-hear and "read this to me" | A device speaker, silent mode | **NOT RUN** — no device audio path | — | — |
| DV-8 Mic/speech exclusion, audio-session contention (R10) | A device with a microphone, speakers and Bluetooth | **NOT RUN** — no device. This row is input to the OD-12/OD-13 review and is not settled by any simulator result | — | — |
| DV-9 Indicator in bright light | Daylight on a device screen | **NOT RUN** — no device | — | — |
| DV-10 Sustained-session battery and heat | A battery and a thermal envelope | **NOT RUN** — no device | — | — |
| DV-11 Appliance panel and packaging (R10) | Real appliance labels and real packaging | **NOT RUN** — no device; the curated-dictionary precedence is covered by tests, the physical labels are not | — | — |
| DV-12 Relaunch with no network, cache intact | A device, airplane mode, a real container | **NOT RUN** — no device | — | — |
| DV-13 Dense page at arm's length (OD5) | A real dense page at 30–50 cm | **NOT RUN** — no device. The pipeline half of this question is M-1 above; the camera half is this row and it is unmeasured | — | — |
| DV-14 Peak memory in a dense scene (NFR-LCT-005) | A release build under Instruments on a device, 10 min | **NOT RUN** — no device, no release build, no Instruments run | — | — |
| DV-15 Frame pacing on the oldest supported device (NFR-LCT-002) | The oldest *supported* device | **NOT RUN** — no device. Note the protocol's rule: the oldest *available* device is not a substitute, so this row is not approximated | — | — |
| DV-16 Clamped callout on a full screen (OD5 corner case) | A device screen at arm's length | **NOT RUN** — no device | — | — |

**Consequence to carry into `final-sign-off`:** OD1, OD2 and OD5 have **no measurement** behind them
from this run. They are not "probably fine" — they are unmeasured.

## 4. Owner actions (decisions, not measurements)

Listed as actions because the protocol's rule is that the agent measures and the owner decides. None
of these is a decision this run took, and none is presented as one.

| # | Owner action | Why it is the owner's | State |
| --- | --- | --- | --- |
| OA-1 | **OD1 — fix or edit the cadence value** (`ocrSampleInterval` nominal 0.25 s, `thermalCadenceFactor` 2.0, `thermalStateThreshold`) | Needs DV-2/DV-10/DV-15 measurements, which need a device | Open — unmeasured |
| OA-2 | **OD2 — the "always show original" default** (`alwaysShowOriginalDefault`, `inPlaceMaxSourceWordCount` 3, `overlayMinPointSize` 18) | Needs the DV-3 device demo: does the smart mix read well on a real sign | Open — unmeasured |
| OA-3 | **OD3 — consent and disclosure copy review**, and the `NSCameraUsageDescription` wording | A copy/disclosure judgement, with a reader in front of the prompt (DV-6); if the copy changes, `LiveTranslateConfig.disclosureVersion` **must be bumped** so existing grants do not carry over | Open — owner review |
| OA-4 | **OD5 — declutter thresholds** (`regionMatchIoU` 0.3, `declutterMergeCentroidDistance` 0.06, `declutterMaxRegions` 8) | Needs DV-13/DV-16 on real dense pages, including the clamped-callout corner case | Open — unmeasured |
| OA-5 | **The device run itself** — execute DV-1 … DV-16 and fill this file's §3 rows | Only the owner has the hardware | Open |

## 5. Honesty notes about this record

- **No device model, OS version, build identifier, measurement or outcome in this file is
  fabricated.** Where a value does not exist, the cell says the value does not exist.
- **The simulator is named as a simulator.** Every measurement in §2 carries the simulator's OS build
  and device id, and no row presents it as a device result.
- **A failed bootstrap occurred once and the run was repeated.** One invocation of the evidence suites
  ended in `Early unexpected exit … Test crashed with signal term before establishing connection` —
  a simulator bootstrap failure under load, not a test failure. The re-run completed with 13/13
  passing. It is recorded because a reader of the gate log may see the discarded attempt's result
  bundle (`build/TG10-evidence.xcresult` was overwritten by the successful run; the failed attempt
  left no trace other than the log line quoted here).
- **No defect was found by the checks that ran.** The runnable subset (M-1 … M-5) passed, so there is
  no traced fix to report under the protocol's "a defect becomes a traced fix" rule. That statement
  is about the runnable subset only — it is not a statement that the feature has no defects, and the
  device-only checks that could find one have not run.
- **M-1's fixture words are synthetic** and are printed in the test source; the measurement attachment
  deliberately records **counts only**, never recognized text, matching the feature's own posture on
  the log surface.
