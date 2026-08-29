# Voice pipeline — setup and testing

The voice pipeline is scaffolded in `ios/ElderlyAssistant/Services/Voice/`.
For the iOS MVP, the app does **not** ship a production wake word. The
interaction model is a large in-app "Talk to Assistant" button plus scheduled
auto-activation around medication and routine reminders. Wake-word research
continues separately.

| Mode | Wake word | Speech-to-text | Test how |
|---|---|---|---|
| **MVP default** | disabled (`NullWakeWordEngine`) | Whisper when a pinned model is cached; SFSpeechRecognizer English fallback otherwise | Tap "Talk to Assistant" |
| **Research only** | openWakeWord / custom KWS experiment | same | Not part of v1 acceptance |

## What the pipeline does end-to-end

1. `AudioSessionManager` requests mic permission and configures the
   `AVAudioSession` for background audio (`playAndRecord`, `measurement`).
2. `VoicePipeline` installs an `AVAudioEngine` input tap and converts hardware
   audio to 16 kHz int16 mono.
3. On button tap or scheduled auto-activation, the pipeline captures the
   command. Whisper uses push-mode audio and the MVP `EnergyVAD`; the English
   fallback uses `SFSpeechRecognizer` with on-device recognition where
   supported.
4. The transcript goes to `CommandRouter`, which matches acknowledgement
   phrases in Nepali and English and calls
   `AppCoordinator.handleMedicationAcknowledgement(entryId:)`. Anything
   unrecognised gets a Nepali spoken clarification prompt.

## Scaffold mode — nothing to install

Works out of the box. On the phone:
1. Grant mic and speech-recognition permissions when prompted.
2. Wait for the green "Listening for wake word" dot.
3. Tap **Talk to Assistant** in the app.
4. Speak a command within 5 seconds. Either you'll see a "Medication
   acknowledged" notification (if a reminder is pending and you said an
   acknowledgement phrase) or "I heard: …" (otherwise).

The Null engine doesn't listen for anything on its own — the debug button
is the only way to trigger it.

## Wake Word Status

Do not enable Porcupine for the iOS MVP. The newer model-fine-tuning guide
records that the previous free-tier assumption is obsolete, and the v1 product
decision is to defer wake word. If wake word returns for v2, use a small
on-device KWS model with a Nepali evaluation set and measured locked-screen
battery impact.

## What the pipeline does NOT do yet

- LLM execution depends on a cached LLaMA model and the linked runtime. The
  deterministic Nepali/English keyword fallback remains the safety path.
- Piper Nepali model delivery is pinned in the catalog, but the runtime still
  falls back to `AVSpeechSynthesizer` until sherpa-onnx is wired.
- No language switching. Locale is baked in.
