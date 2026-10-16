# Voice App Launcher (Deeplink + Camera) — Design

**Date:** 2026-09-16
**Status:** Approved by user (design sections 1–5)

## Problem

The assistant is voice-first for elderly users. Users should be able to say, e.g.,
"क्यामेरा खोल" (open the camera) or "WhatsApp खोल्नुहोस्" (open WhatsApp) and have the
target app fire. Two sub-problems:

1. **Camera.** iOS has **no reliable public URL scheme for the Camera app**.
   `camera://` appears in community lists and works inside the Shortcuts app
   (iOS 17.2+), but from a third-party app it fails ("address is invalid").
   The supported way to achieve the requested UX — camera UI fires, user presses
   the shutter — is `UIImagePickerController` (`sourceType = .camera`), which
   presents the system camera UI in-app and returns the captured photo to us.
2. **Other apps.** Apple documents a small set of URL schemes (`tel`, `sms`,
   `facetime`, `mailto`, `maps` via http, `itms`); the rest are community
   documented and must be verified on device. The pipeline already has rich
   dedicated actions for call, message, YouTube play, maps, and reminders —
   this feature must not duplicate them.

## Decisions (user-confirmed)

| # | Decision | Choice |
|---|---|---|
| D1 | Camera UX | System camera UI via `UIImagePickerController` |
| D2 | Photo outcome | Auto-save to Photos + spoken "photo saved" |
| D3 | Safety model | Confirm-first before **every** external launch (voice yes/no) |
| D4 | Architecture | New `AssistantPlugin` (`launcher.open`) — zero core-enum changes, no intent-encoder retraining |

Rationale for D4: the on-device IntentEncoder is fine-tuned against the core
action list (`InterpretedCommand.Action`). Plugin actions ride the existing
`.plugin` escape hatch and the `IntentPrompt.pluginSections` mechanism, so the
classifier contract is untouched. The LLM output contract already reserves
`actionType`/`actionUrl` deep-link fields, but they are dropped at decode —
this feature does not rely on them.

## Architecture

### Components

- **`AppLauncherPlugin: AssistantPlugin`** (new file, `ios/ElderlyAssistant/Services/Plugins/AppLauncherPlugin.swift`)
  - pluginID `app_launcher`; action `launcher.open`; entity `app` (canonical catalog ID); reserved `target` slot (unused in v1).
  - Registered in `AppCoordinator.makePluginRegistry()` (`AppCoordinator.swift:1746-1763`) — one line.
  - Reuses `AssistantPlugin` contract (`Services/Plugins/AssistantPlugin.swift:21-49`), `PluginRegistry` (`Services/Plugins/PluginRegistry.swift`).
- **Catalog extension** of `AppLauncher.catalog` (`Services/Apps/AppLauncher.swift:72-99`): each entry = display name, `rootURL`, web fallback, reliability tier, Nepali aliases. Reuses `isInstalled` (:169) and `open` (:177).
- **Launch seam:** existing `CallLinkOpening` / `SystemCallLinkOpener` (`Services/Intents/CallLinks.swift:37/:44`, main-thread safe) for all URL opens; plugin takes an injected opener for tests.
- **Camera entry (special):** no URL. Plugin presents `UIImagePickerController` (`.camera`); delegate saves the image via `PHPhotoLibrary.performChanges` (add-only), then speaks "photo saved" or an honest failure message.
- **Confirmation:** reuse the router's existing confirmation-follow-up handling in `CommandRouter.route` (`CommandRouter.swift:582`). The plugin registers a pending launch and speaks "Should I open X?"; yes/no resumes it; timeout auto-dismisses without launching. Implementation must first read the existing confirmation flow (e.g., call confirmation) and extend it — no parallel confirmation system.
- **Keyword fast-path:** `KeywordIntentRule` entries (`Services/Voice/KeywordIntentRule.swift`) for camera, photos, settings, weather, WhatsApp, YouTube, and Facebook in Nepali + English so the highest-frequency launches work without the encoder path. Use exact full-lexeme matching — avoid partial-substring tricks (Devanagari Character-cluster matching is a known regression; see swift-devanagari-substring-graphemes note).
- **Info.plist changes** (`ios/ElderlyAssistant/Info.plist`):
  - New `NSPhotoLibraryAddUsageDescription` (add-only photo save; no read permission needed).
  - Extend `NSCameraUsageDescription` (:71-72) to cover general photo capture (today it mentions medication verification + appliance photos).
  - Extend `LSApplicationQueriesSchemes` (:34-55) for: `App-Prefs`/`app-prefs` (exact casing confirmed on device), `photos-redirect`, `weather`, `x-apple-health`, `apple-magnifier`.

### v1 catalog

Already-voice-handled apps (call, message, YouTube play, maps, reminders) are NOT duplicated.

| App | Mechanism | Tier | Fallback |
|---|---|---|---|
| Camera | in-app picker + auto-save | supported API | n/a (spoken guidance if unavailable) |
| Photos | `photos-redirect://` | community — device-verify | n/a |
| Settings top | `App-Prefs:root=` | community — device-verify | n/a |
| Settings: Wi-Fi | `App-Prefs:root=WIFI` | community — device-verify | n/a |
| Settings: Bluetooth | `App-Prefs:root=Bluetooth` | community — device-verify | n/a |
| Settings: Display | `App-Prefs:root=DISPLAY` | community — device-verify | n/a |
| Settings: Accessibility | `App-Prefs:root=ACCESSIBILITY` | community — device-verify | n/a |
| Weather | `weather://` | community — device-verify | n/a |
| Magnifier | `apple-magnifier://` | community — device-verify | n/a |
| Health | `x-apple-health://` | Apple-documented | n/a |
| Calendar (open app) | `calshow://` | community (already whitelisted) | n/a |
| Facebook | `fb://` | third-party (already whitelisted) | web |
| Instagram | `instagram://` | third-party (already whitelisted) | web |
| YouTube (open app) | `youtube://` | third-party (already whitelisted) | web |
| WhatsApp (open app) | `whatsapp://` | third-party (already whitelisted) | web |

### Out of scope (v1)

Shortcuts execution (`shortcuts://`), parameterized deep links (the `target`
slot is reserved but unused), custom camera UI, automatic "return to assistant"
(we speak "say 'assistant' to come back"), Notes/Voice Memos/Chrome/Gmail/Zoom
entries, and duplicating the existing rich actions (call/message/YouTube play/
maps/reminders).

## Data flow

```
voice "क्यामेरा खोल" → STT → CommandRouter.route
  → keyword rule OR encoder/LLM → launcher.open(app=camera)
  → PluginRegistry → AppLauncherPlugin
  → confirmation: "Should I open Camera?" → user yes
  → UIImagePickerController fires (full-screen camera + shutter)
  → shutter → delegate → PHPhotoLibrary add → speak "photo saved"
```

URL app variant, confirmation onward:

```
  → user yes → isInstalled (canOpenURL on main thread)
    → installed: SystemCallLinkOpener.open → speak "Opening X"
    → not installed: speak honestly + offer web fallback where available
```

## Error handling

- App not installed → honest spoken message + web fallback offer (pattern already in `AppCoordinator.performAppLaunch`, `AppCoordinator.swift:5224-5241`).
- Camera unavailable (simulator / no camera) or permission denied → honest spoken guidance; no crash.
- Photo save failure → spoken failure message.
- Confirmation timeout → auto-dismiss; never launch.
- Scheme not whitelisted → impossible by construction (consistency test, below).

## Testing

1. **Catalog ↔ Info.plist consistency unit test** — every catalog scheme must be present in `LSApplicationQueriesSchemes`. Catches the classic silent `canOpenURL`-always-false bug.
2. Confirmation state machine: yes / no / timeout paths.
3. Launch flows via injected `CallLinkOpening` mock — no real app switching in tests.
4. Camera: injected picker-presenter + photo-saver seams; simulator no-camera path; manual on-device capture + save test.
5. Voice end-to-end: Nepali + English phrases per catalog app through the encoder evaluation.

## Acceptance criteria

- Each community-tier scheme verified on a physical device and opens its target app.
- Confirmation gate proven for yes, no, and timeout.
- Camera capture on device → photo appears in library → spoken confirmation heard.
- Unit test proves catalog/plist consistency.
- Core `InterpretedCommand.Action` untouched; encoder contract unchanged.

## References

- [Apple URL Scheme Reference (archived)](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/Introduction/Introduction.html)
- [Defining a custom URL scheme for your app (Apple)](https://developer.apple.com/documentation/Xcode/defining-a-custom-url-scheme-for-your-app)
- [Stack Overflow: is there a URL scheme for the Camera app](https://stackoverflow.com/questions/65023111/is-there-a-ios-app-url-scheme-for-the-camera-app)
- [Stack Overflow: URL redirect to open camera app on iPhone](https://stackoverflow.com/questions/72395896/url-redirect-to-open-camera-app-on-iphone)
- [iOS 17.2 Shortcuts URL schemes (GadgetHacks)](https://ios.gadgethacks.com/how-to/ios-17-2-includes-50-new-url-schemes-you-can-use-shortcuts-your-iphone-0385465/)
- Related project specs: `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md`, `docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md`
