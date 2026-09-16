# Live camera translation — on-device validation protocol (T-030)

**Feature:** live-camera-translation (EN→NE live camera translation)
**Written:** 2026-09-17, before any device run — the record of what was run is
`specs/LCT-device-validation-results.md`, kept separate on purpose.
**Owner of the device run:** the project owner. Every check below is written so that a person holding
the phone can execute it without this document's author present, and so that a failure points at one
named parameter rather than at "tune the thresholds".

## Why this protocol exists

Three of the design's open decisions are *device* questions, not design questions, and none of them
may be settled by argument:

| Decision | Parameter(s) | Settled by |
| --- | --- | --- |
| **OD1** | `ocrSampleInterval` (nominal 0.25 s), `thermalCadenceFactor` (2.0), `thermalStateThreshold` | A cadence/thermal spike on the target hardware |
| **OD2** | `alwaysShowOriginalDefault` (shipped `false`), `inPlaceMaxSourceWordCount` (3), `overlayMinPointSize` (18) | The first device demo: does the smart mix read well on a real sign |
| **OD5** | `regionMatchIoU` (0.3), `declutterMergeCentroidDistance` (0.06), `declutterMaxRegions` (8) | Manual device testing on dense, real pages |

The rule this protocol encodes: **the agent measures, the owner decides.** A number produced here is
a measurement; the change it implies is an owner action, recorded as such in the results file.

## What can be done without a device (and is)

Two classes of check are runnable on the simulator, and are run in the standard invocation rather
than by hand:

- **Fixture-image OCR** — `OCRFixturePageTests` renders a dense menu-like page and reads it through
  the real `LiveTextDetector`/Vision path. It answers the *pipeline* half of the density question
  (several regions, sane boxes, honest count). It cannot answer the *camera* half: focus, exposure,
  motion blur, glare, paper stock, viewing distance. Those are DV-1, DV-13 and DV-15 below and are
  NOT RUN without a device. The measurement this pass produced is recorded as M-1 in
  `specs/LCT-device-validation-results.md`.
- **The security evidence suite** — `SecurityEvidenceBoundaryTests` and `SecurityEvidenceIndexTests`,
  indexed in `specs/LCT-security-evidence-index.md`. These are behavioural checks at instrumented
  boundaries and are not device questions.

Neither is a substitute for the checks below, and nothing in this protocol is marked passed on the
strength of a simulator run.

## Device-only checks

Each check gives: the procedure, the pass condition, how to measure, where to record, and which
design parameter a failure would edit. "Record" means: write the observed value in
`specs/LCT-device-validation-results.md`, in the row of that check — never in this file.

### DV-1 — A real menu page in poor light

- **Procedure.** Print or obtain a real menu (at least 8 distinct lines, mixed lengths, prices). Hold
  the phone at reading distance, 20–40 cm, in dim indoor light, then repeat under a window.
- **Pass condition.** At least four detectable lines are recognized and rendered as separate bubbles
  in a single steady frame; the bubble count does not collapse to one; no bubble is empty.
- **Measure.** Count of distinct bubbles after 5 s of steady holding (photo of the screen, or the
  on-screen count if the debug HUD is enabled).
- **Failure edits.** OD5 — `declutterMaxRegions`, `declutterMergeCentroidDistance`, `regionMatchIoU`,
  in that order of suspicion.
- **Record as.** `DV-1` row, with the count under each lighting condition.

### DV-2 — Sustained use: cadence and thermal behaviour (OD1)

- **Procedure.** Point the phone at a busy page and keep the feature running for 10 minutes
  continuously, screen on, charger disconnected.
- **Pass condition.** No thermal-pause state is reached before 10 minutes on the target device; the
  overlay stays responsive (a moved page re-renders within ~1 s); battery drop ≤ 10 % over the run.
- **Measure.** Battery percentage at start and end; the time stamp of the first
  `thermal` degradation (Settings ▸ Battery, or the recorded `camera_interrupted`/thermal event in a
  device log); subjective responsiveness at the 1-minute and 9-minute marks.
- **Failure edits.** OD1 — `ocrSampleInterval` (raise the interval), then `thermalStateThreshold`,
  then `thermalCadenceFactor`.
- **Record as.** `DV-2` row: minutes to first thermal event, battery delta, responsiveness notes.

### DV-3 — In-place versus callout, on a real sign (OD2)

- **Procedure.** Show a sign with a **one- or two-word** label ("Lift", "Push") and a sign with a
  **long** line ("Please wait here until you are called"). Observe both with the toggle off (smart
  mix) and on (always show original).
- **Pass condition.** Short labels the curated dictionary knows render in place and read as
  replaced; long lines render as callouts with the original visible; toggling takes one touch and
  the visual change is immediate and obvious; no text is clipped at the default point size.
- **Measure.** Which presentation each of the two signs used, and whether any line was clipped or
  set below the accessibility floor.
- **Failure edits.** OD2 — `alwaysShowOriginalDefault`, `inPlaceMaxSourceWordCount`,
  `overlayMinPointSize`.
- **Record as.** `DV-3` row: per-sign presentation, clipping observed (yes/no), legibility at arm's
  length (comfortable / squint / unreadable).

### DV-4 — Offline degradation in airplane mode

- **Procedure.** With consent already granted and the cache warm, enable airplane mode, then point
  at a page containing at least one string never seen before, and one string seen before. Repeat the
  whole check as a **Wi-Fi-off variant** (airplane mode off, Wi-Fi off, cellular off), because the
  two are different network stacks and the claim is about both.
- **Pass condition.** Zero network requests are attempted (no indicator, no spinner beyond the
  dictionary path); the previously-seen string still renders from the cache; the new string shows the
  original with an honest unavailable indication; nothing crashes; the feature stays usable and the
  camera keeps running.
- **Measure.** Presence/absence of the cloud indicator; rendering of each of the two strings; any
  crash or frozen frame.
- **Failure edits.** No parameter — a defect is a defect (the degraded path is fully specified).
- **Record as.** `DV-4` row: with the two strings named.

### DV-5 — Cache at rest on the real device

- **Procedure.** Translate several strings, force-quit the app, then inspect the app container
  (Xcode ▸ Devices ▸ *device* ▸ app ▸ Download Container, or a device backup manifest inspection).
- **Pass condition.** No file in the container contains a recognized string or a translation in
  readable form; the translation store is the encrypted payload (`LTCE` envelope); the consent
  record holds no plaintext field and never the translation provider key.
- **Measure.** Search the container for the exact strings that were translated (a plain-text search
  for two of them is sufficient and reproducible).
- **Failure edits.** No parameter — NFR-LCT-008 is an invariant.
- **Record as.** `DV-5` row: strings searched for, hit/no-hit, and how the container was obtained.

### DV-6 — Consent flow end to end, with the real copy (OD3)

- **Procedure.** Fresh install (or delete the app), run a scene that needs the cloud tier, read the
  prompt aloud as it appears, grant, translate, then revoke from the session view and again from
  Settings.
- **Pass condition.** The prompt appears **before** the first request, states what leaves the device,
  who receives it and why, at the app's accessibility floors; granting produces exactly one request
  for the scene; revoking stops egress immediately and the feature degrades rather than blocking;
  the system camera-permission string matches what the app actually does.
- **Measure.** Whether a non-engineer can restate, after reading the prompt, what is sent and to
  whom; the request count in the device log for the granted scene.
- **Failure edits.** OD3 — copy and disclosure wording (owner review), and
  `LiveTranslateConfig.disclosureVersion` **must be bumped** when the copy changes, so existing
  grants do not carry over.
- **Record as.** `DV-6` row: the reader's restatement (verbatim), the request count, whether
  `disclosureVersion` was bumped.

### DV-7 — Tap-to-hear and "read this to me"

- **Procedure.** Tap a translated bubble, then a bubble in a degraded state, then the "read this to
  me" action; repeat once with the phone in silent mode.
- **Pass condition.** The spoken form is the translation when one exists and the original otherwise;
  no spoken time is read as digits aloud in the wrong language (the spoken-time formatter is the only
  path for times); silent mode respects the app's own switch behaviour; speech never speaks
  quarantined text.
- **Measure.** What was spoken in each of the four cases; whether the microphone window opened during
  speech.
- **Failure edits.** No parameter — a defect is a defect.
- **Record as.** `DV-7` row: the four cases with what was heard.

### DV-8 — Microphone/speech mutual exclusion, and the cloud voice engine question

- **Procedure.** While a translation session is running, use the in-session voice command ("repeat
  that", "stop"); then, with the app's cloud voice engine active (the shipped default), speak a
  sentence and observe whether the translation indicator changes. Then repeat both with **other audio
  already playing** — music through the phone's speaker, and a podcast over Bluetooth — and check
  whether the elder's audio ducks, stops or is interrupted.
- **Pass condition.** The command window never opens while the feature is speaking and a transcript
  arriving during speech is discarded; the translation indicator is unaffected by the voice path; a
  spoken command does not self-trigger (the feature's own speech is not recognised as a command); and
  the elder's own audio keeps playing (or ducks and recovers) rather than being stopped by the
  feature's audio session (R10).
- **Note (SD-5, owner action).** Whether an in-session utterance under the cloud voice engine should
  carry its own disclosure is the **joint OD-12/OD-13 review's** question, raised by the design
  review. This check records the observation; it does not settle the question.
- **Measure.** Whether the microphone window opened mid-speech; whether the translation indicator
  changed while only the voice path was in use; what happened to the playing audio in each of the two
  cases (kept playing / ducked and recovered / stopped).
- **Failure edits.** No parameter — record the observation for the OD-12/OD-13 review.
- **Record as.** `DV-8` row, flagged as input to the OD-12/OD-13 review, with the audio-session
  observations in their own column.

### DV-9 — The indicator in bright light

- **Procedure.** Trigger a cloud translation outdoors in daylight and watch the indicator area.
- **Pass condition.** The indicator is visible and unambiguously "on" while a request is in flight,
  and off within a moment of the last response; it cannot be dismissed or covered by the overlay.
- **Measure.** Visible yes/no at arm's length; time from last response to indicator off.
- **Failure edits.** No parameter — the indicator's presence is an invariant; its size/contrast, if
  found lacking, is a design change, not a threshold edit.
- **Record as.** `DV-9` row: visibility, and the observed off-delay.

### DV-10 — Sustained-session battery and heat (supporting OD1)

- **Procedure.** A second 10-minute run on a static page (no scene changes), then a third on a moving
  scene.
- **Pass condition.** No thermal pause; the two runs' battery deltas differ by less than the noise of
  the device's own reporting; the phone is not uncomfortably warm to hold.
- **Measure.** Battery percentage and subjective temperature at the end of each run.
- **Failure edits.** OD1 — the same parameters as DV-2.
- **Record as.** `DV-10` row: three deltas and the temperature notes.

### DV-11 — The appliance panel and packaging (R10)

- **Procedure.** Use the feature on the fridge panel, the microwave label and a medicine box; also
  check a delivery parcel.
- **Pass condition.** The curated dictionary's known labels render exactly as they did before the
  feature existed; a cached label renders the cached translation; a known label that both layers
  could answer prefers the curated one.
- **Measure.** For each of ≥ 8 labels: what was rendered, and whether it matched the pre-feature
  string byte for byte.
- **Failure edits.** No parameter — the seam's precedence is specified.
- **Record as.** `DV-11` row: label list with per-label outcome.

### DV-12 — Relaunch with no network, cache intact

- **Procedure.** After DV-1, force-quit the app, enable airplane mode, relaunch, and re-point at the
  page that was translated before.
- **Pass condition.** Previously translated strings render from the encrypted cache with no request
  and no consent re-prompt (the grant persists at the same disclosure version); new strings degrade
  honestly.
- **Measure.** Which strings came from the cache (rendered) and which degraded.
- **Failure edits.** No parameter — a defect is a defect.
- **Record as.** `DV-12` row.

### DV-14 — Peak memory in a dense scene (NFR-LCT-005)

- **Procedure.** With Instruments (Allocations + VM Tracker) attached, run a continuous session on the
  densest page available for 10 minutes, waving the camera slowly so regions keep being created and
  discarded at the configured caps (`declutterMaxRegions`, `maxActiveRegions`).
- **Pass condition.** Peak resident memory stays under the ceiling recorded for the target device in
  this row, and the trend over the last 5 minutes is flat rather than rising — a rising trend is a
  leak however low the peak.
- **Measure.** Peak resident size (MB) and the resident size at the 1-, 5- and 10-minute marks; the
  headroom against the device's jetsam limit. Instrument a release build, not a debug build.
- **Failure edits.** No parameter — a leak or an over-large peak is a defect, and the ceilings are
  design parameters that only move if the measurement justifies it (NFR-LCT-005).
- **Record as.** `DV-14` row: peak, the three samples, the trend, and the ceiling used.

### DV-15 — Frame pacing on the oldest supported device (NFR-LCT-002)

- **Procedure.** Install on the oldest device the app supports, enable the on-screen frame-pacing HUD
  (or attach Instruments' Core Animation instrument), and run a session on a dense page while moving
  the phone.
- **Pass condition.** The camera preview holds a usable rate on that device; the overlay does not
  stutter ahead of or behind the preview; degradation is a predictable reduction in OCR cadence rather
  than a stall or a freeze; nothing crashes (NFR-LCT-002).
- **Measure.** Observed preview rate and the longest stall (ms) over a 5-minute run, named by device.
  A device that cannot be obtained is recorded as NOT RUN — the oldest *available* device is not a
  substitute for the oldest *supported* one.
- **Failure edits.** OD1 — `ocrSampleInterval`, then `thermalCadenceFactor`; if the preview itself
  cannot hold a usable rate, that is a design change to the preview pipeline, not a threshold edit.
- **Record as.** `DV-15` row: device, observed rate, longest stall.

### DV-16 — The clamped callout on a genuinely full screen (OD5, the corner case T-020 deferred)

- **Procedure.** Manufacture a scene where **every** callout anchor violates the never-cover-its-own-
  region constraint — a page dense enough that the region the callout belongs to is the only place the
  callout could go (a full menu page, or a page whose regions tile the whole frame). Let the feature
  place the callouts without moving the phone.
- **Pass condition.** The pills that must be clamped stay inside the safe area; each clamped pill is
  still legible at arm's length and does not become unreachable or render off-screen; the region it
  belongs to is not covered by its own pill; no pill overlaps the surface it describes so completely
  that the original cannot be read.
- **Measure.** For each clamped pill: whether it is inside the safe area (yes/no), whether it is
  legible (comfortable / squint / unreadable), whether it covers its own region (yes/no), and the
  count of pills that had to be clamped.
- **Failure edits.** OD5 — `declutterMaxRegions` first (fewer pills, fewer forced clamps), then
  `declutterMergeCentroidDistance`, then `regionMatchIoU`; if no clamp is legible at any of those
  settings, the placement rule is a design change, recorded as such.
- **Record as.** `DV-16` row: the clamped count and the per-pill readings. This is the check T-020
  deferred here rather than accepting silently.

### DV-13 — The dense page at arm's length (OD5, the device half of the fixture test)

- **Procedure.** Stand 30–50 cm from a densely printed page (a real menu, a timetable, a leaflet) and
  hold the phone steady for 5 s.
- **Pass condition.** The declaration of how many bubbles appear matches the number of lines a person
  reads when they look at the same page; no two adjacent lines merge into one bubble; nothing is
  dropped silently — a line that cannot be translated shows its original.
- **Measure.** Bubble count vs the human line count; note any merge or drop with the line text.
- **Failure edits.** OD5 — `declutterMergeCentroidDistance` first, then `declutterMaxRegions`, then
  `regionMatchIoU`.
- **Record as.** `DV-13` row: human count, bubble count, merges/drops named.

## Recording rules

1. **Every row gets a value or NOT RUN with a reason.** No row is left blank, and no row is filled
   from a simulator observation. Every row also names the **device model, OS version and build
   identifier** it was observed on, in a column of its own: a check without a measurement is an
   opinion, and a measurement without a device and a build is not reproducible.
2. **Measurements and decisions are different columns.** A measured cadence is not a decision to
   change `ocrSampleInterval`; the decision is an owner action recorded as such.
3. **A failed check is a finding, not a tuning invitation.** Fixing DV-1 by moving a threshold is a
   valid outcome **only** with the measurement that justified it recorded next to the change.
4. **The protocol is not edited to match the results.** If a check turns out to be unexecutable as
   written, the results file records that, and this file is updated in a separate, visible edit.
