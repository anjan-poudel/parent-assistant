# TTS reply volume: loudness fix (2026-10-14)

**Bug (owner field report):** the assistant's spoken replies are "less than 50%
of the normal volume I hear in other apps" — even with the shipped volume
boost at its top. Target users are elderly; high severity.

## Root cause (ranked, with evidence)

1. **Category-driven gain staging (the dominant cause).** Replies played under
   the shared `.playAndRecord` session — iOS tunes that category for
   telephony/VoIP: output uses call/voice gain staging and the call volume
   scale, far below media apps. The alarm bell — the one audio path the field
   calls LOUD — switches the session to `.playback` for its duration
   (`TimerAlarmBellPlayer.swift:60-62`). The reply path only ever switched the
   session MODE (`.voicePrompt`), never the category
   (`AudioSessionManager.beginResponsePlayback`), and `.voicePrompt` carries no
   documented gain behavior.
2. **The shipped sample boost was saturated.** The [VOLUME-BOOST] gain was a
   pure peak limiter (`applied = ceiling / peak`); bundled Piper speech peaks
   near full scale, so at 150 % the limiter applied ≈ 1.0× — the slider bought
   almost nothing (the code's own honest-limits note admitted this).

## Changes (branch `worktree-tts-loudness`)

1. **Reply playback switches to the bell's loud configuration**
   (`AudioSessionManager.swift`): `beginResponsePlayback()` now sets category
   `.playback`, mode `.default`, options `[.duckOthers, .defaultToSpeaker]` —
   byte-identical to `TimerAlarmBellPlayer` — and `endResponsePlayback()`
   restores the capture preset (`.measurement`, or `.voiceChat` + VPIO re-arm)
   IN PLACE, session left active. Accepted trade: `.playback` has no input, so
   the mic is unavailable while the assistant speaks; wake-word processing is
   already suppressed during replies (AppCoordinator's wake gate), so no
   listening feature is lost. Failures are emitted on the observability bus
   (`audio_response_playback` began/restored/failed/restore_failed) instead of
   the old silent `try?`.
2. **The boost now actually boosts** (`Speaker.swift`): `VoiceOutputGain` is a
   gain + soft-knee limiter — full requested gain below a −12 dBFS knee, tanh
   soft-knee above toward the −1 dBFS ceiling — so low-RMS speech with
   near-full-scale peaks gets the body amplified instead of ~nothing.
   Attenuation (≤ 100 %) stays pure linear. Range extended to **50–200 %**
   (+6 dB linear region). 100 % remains the byte-identical no-processing path.
3. **Seam balance + hang fixes** (`Speaker.swift`): `PiperVoiceSpeaker.cancel()`
   ends the playback seam only if this speaker opened it (a cancel during
   synthesis can no longer consume an ack's outstanding begin and restore the
   capture preset under the ack's tail); `player.play()` returning false now
   settles instead of hanging the turn with the session stranded in
   `.playback`.
4. Settings copy updated (en + ne): the old note's "a reply that is already
   near full volume will change little" described the bug, not a limit.

## Verification

- Scoped unit gate: `SpeakerTests`, `VoiceSettingsModelTests`,
  `AckFastLaneTests`, `AudioSessionPresetTests` (run in the worktree).
- **Device validation on Anzaan (merge gate — STT is the invariant):**
  - DV-1 Reply is clearly louder, comparable to other apps at the same device
    volume; no distortion at 200 %.
  - DV-2 After a reply, the wake word still fires immediately (restore leaves
    the session active; wake latency unchanged).
  - DV-3 Reply → reply back-to-back: no category ping-pong glitches; ack tails
    stay loud.
  - DV-4 `audio_response_playback` events show began/restored with no failed /
    restore_failed during a normal conversation.
  - DV-5 With VPIO A/B ON (if exercised): voice processing re-arms after a
    reply (`audio_session_vpio_unavailable` absent).

## Honest limits

- Broadband gain + soft knee only — not a hearing aid, no frequency shaping.
- High settings trade dynamics for loudness (speech sounds denser at 200 %).
- The system-speech fallback (`AVSpeechUtterance`) cannot exceed unity.
- If the device's hardware volume is very low, no in-app lever can exceed
  Apple's media-volume ceiling — but at equal device volume, replies now sit
  on the same media scale as other apps.
