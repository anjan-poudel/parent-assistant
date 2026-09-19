# Supported URL Schemes & Deep Links

The launcher's catalog (`Services/Apps/AppLauncher.swift`) is the single source of truth for
what a tile opens; `Info.plist`'s `LSApplicationQueriesSchemes` whitelist is what makes
`canOpenURL` answer honestly (50-scheme cap — add deliberately). This document is the
human-readable map of every supported scheme, its surface, and its caveats.

## Native Apple surfaces

| Surface | Scheme | Notes |
|---|---|---|
| Phone — dialer (empty) | `tel:` | The ONLY stock-supported Phone surface. Slashes-less on purpose (`tel://` with no number opens a dead confirmation sheet). The call path uses `tel:<number>`. |
| Phone — Recents / Contacts / Favorites / Voicemail | **none** | DEVICE-VERIFIED 2026-09-19: `mobilephone-recents://` and siblings fail `canOpenURL` with OSStatus -10814 (application not found) on stock iOS — Apple registers no public deep link for these tabs. Do not reintroduce them. |
| Messages | `sms:` | Same slashes-less rule. |
| Calendar | `calshow://` | |
| Maps | `maps://` / `maps.apple.com` | Directions auto-start via `daddr` (house `MapsLinks` builder). |
| FaceTime | `facetime://`, `facetime-audio://` | |
| Health | `x-apple-health://` | |
| Reminders | `x-apple-reminderkit://` | |
| Magnifier | `apple-magnifier://` | |
| Photos (redirect) | `photos-redirect://` | |
| Settings | `App-Prefs:root=` (+ `app-prefs` casing) | Panes via `urlOverride` (`WIFI`, `Bluetooth`, `DISPLAY`, `ACCESSIBILITY`). Private API — fallback to `UIApplication.openSettingsURLString` is the house behavior. |

## Third-party apps

| App | Root scheme | Recents equivalent | Contacts deep link |
|---|---|---|---|
| WhatsApp | `whatsapp://` | Root opens the chat list (recents). | **None documented.** Direct chat: `whatsapp://send?phone=<number>`. |
| Facebook Messenger | `fb-messenger://` | Root opens the recent-threads list. | **None documented.** Direct thread: `fb-messenger://user/<id>`. |
| Facebook | `fb://` | | |
| Instagram | `instagram://` | | |
| Telegram | `tg://` | | |
| Viber | `viber://` | | |
| imo | `imo://` | | |
| Zoom | `zoomus://` | | |
| YouTube | `youtube://` | | |
| Chrome | `googlechrome://` | | |
| Gmail | `googlegmail://` | | |
| Google Maps | `comgooglemaps://` | Directions auto-start via `daddr` + `directionsmode=driving` (house `MapsLinks` fallback). | |

## Rules

- Every catalog scheme MUST be declared in `LSApplicationQueriesSchemes` (pinned by
  `AppLauncherTests` against both the running bundle and the source plist).
- Probe before opening: `canOpenURL(rootURL)`; a failed probe speaks the honest
  not-installed line, never a guess.
- Apple telephony schemes (`tel`, `sms`) are the ONLY slashes-less roots.
- Adding a scheme is two edits: catalog entry + plist whitelist + the exact-pins test.
