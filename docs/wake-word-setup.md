# Wake word ("Hey Sahayak") — setup guide for a family member

The app listens for the phrase **“Hey Sahayak”** so the elderly user can give
a command by voice alone — no button press. The wake word runs on-device via
Picovoice's [Porcupine](https://picovoice.ai/products/porcupine/) engine. This
guide is the one-time setup; until **every** step below is done, the app keeps
its honest default (`NullWakeWordEngine`) and behaves exactly as before the
wake-word feature — the Talk button always works, wake word or not.

The whole flow can also be done from the app's **Settings → Voice activation**
screen, which shows exactly what is still missing (it can never claim to be
listening when it isn't).

| Piece | Where it lives | Done when |
|---|---|---|
| 1. Picovoice account + access key | Picovoice Console | pasted into Settings (or Info.plist) |
| 2. Trained keyword file | `ios/ElderlyAssistant/Resources/hey-sahayak_ios.ppn` | file is in the app bundle |
| 3. Porcupine runtime | `ios/project.yml` | SPM package uncommented + project regenerated |
| 4. Toggle ON (default) | Settings → Voice activation | switch is on |
| 5. Restart the app once | — | everything above + a fresh launch |

---

## 1. Create a Picovoice account and get the access key

1. Sign up at <https://console.picovoice.ai/> (free tier is enough).
2. From the console, copy your **AccessKey** (a long base-64 string).

**Simplest family mechanism — paste it into the app, no build needed:**

- In the app: **Settings → Voice activation**, paste the key into the
  "Picovoice access key" box, tap **Save**.
- The key is stored in the iPhone's secure Keychain (Data Protection
  Complete), never in UserDefaults and never hardcoded into the app.
  Removing it (the "Remove key" button on the same screen) revokes it
  immediately.

**Alternative for team builds** (a key baked in at build time wins over the
Settings value): add the `PicovoiceAccessKey` string to
`ios/ElderlyAssistant/Info.plist`. The app checks Info.plist first, then the
Settings/Keychain store (`WakeWordAccessKeyStore.resolvedAccessKey`). Never
commit a real key into the repository.

## 2. Train "Hey Sahayak" and download the `.ppn`

1. In the Picovoice Console, open **Create Wake Word**.
2. Type the phrase exactly as the user will say it: **`Hey Sahayak`**
   (record or keep the default synthetic voice).
3. Train it, then download the **iOS** format (`.ppn`).
4. Drop the file into the repo as
   `ios/ElderlyAssistant/Resources/hey-sahayak_ios.ppn`
   (the filename **must** stay `hey-sahayak_ios` — that is the name the app
   looks up in the bundle).

### Why English phonemes — the Nepali caveat

Picovoice's console phonemizes the phrase for you. Its phoneme set is
**English-only**; it has no Devanagari/Nepali phonemes. Any Nepali word would
be approximated by the closest English phonemes, which degrades accuracy and
makes a trained-in-Nepali keyword unreliable in real rooms. That is why the
wake phrase is “Hey Sahayak” — a short English phrase around a familiar
name — rather than a pure Nepali sentence. Porcupine detects it
speaker-independently from raw audio; the command that follows can still be
spoken in Nepali (that part is handled by the STT layer, not Porcupine).

## 3. Enable the Porcupine runtime

1. In `ios/project.yml`, uncomment the `Porcupine` package block:
   ```yaml
   packages:
     Porcupine:
       url: https://github.com/Picovoice/porcupine.git
       from: 3.0.0
   ```
   and add `- package: Porcupine` under the `ElderlyAssistant` target's
   `dependencies`.
2. Regenerate the project and build:
   ```sh
   cd ios && xcodegen generate --spec project.yml --project . && ./build.sh build
   ```
3. Confirm the app now reports the runtime as present: **Settings → Voice
   activation** no longer lists "The listening engine (Porcupine) is not part
   of this build".

The runtime check mirrors the code's compile-time guard
(`#if canImport(Porcupine)`), so the Settings screen can never claim the
engine exists when this step hasn't happened.

## 4. The listening toggle (default ON)

The toggle lives on **Settings → Voice activation**. It defaults to **ON** so
that, once steps 1–3 are done, listening starts at the next launch without an
extra Settings visit. Until then ON changes nothing (the engine is Null
regardless). Switching it OFF stops the mic feed to the wake-word engine
immediately and is the honest battery answer — always-on listening costs a
little extra battery, and the screen says so.

## 5. Restart the app once

The wake-word engine is chosen **once, at launch**. If you enable everything
while the app is already running, Settings will show **"Restart to
activate"** — close the app fully (swipe it away) and open it again. After the
relaunch the status should read **Active**.

## What the Settings statuses mean

| Status | Meaning | Next step |
|---|---|---|
| **Active** | Real engine built at launch, toggle ON | nothing — say “Hey Sahayak” |
| **Setup needed** | Toggle ON, but a piece is missing (listed on the screen) | do the missing piece, then restart |
| **Off** | Toggle switched OFF | turn the switch on |
| **Restart to activate** | All pieces present, but engine was built while OFF | restart the app once |

## Honest behavior notes (by design)

- **No dead ends.** Every non-active status names the concrete missing piece
  right on the Settings screen.
- **Talk button unaffected.** The home-screen Talk button and the debug
  "Simulate wake word" path never depend on the wake word — they keep working
  with listening switched off.
- **No self-wake-ups.** While the assistant speaks its own reply, the
  wake-word path is suppressed (the mic hears the speaker, and the audio
  session is `.measurement` mode without echo cancellation). This is done per
  reply in the pipeline — the global audio-session mode is deliberately not
  switched.
- **Key hygiene.** No real (or placeholder) access key or `.ppn` is committed;
  the app ships with `NullWakeWordEngine` until a family member performs this
  setup. Tests and logic live in `WakeWordConfig.swift`, which is free of
  Porcupine types so the whole decision table is testable without the package.
