# Design: Rich Free-Form Events, Full Native-Calendar Mirroring, and Maps Auto-Start

**Date:** 2026-09-17
**Status:** Approved (brainstorming session; user decisions recorded below)
**Approach:** A — native-first events (approved).

## 1. User decisions (asked & answered)

1. **"Broken" mirroring** = nothing appears in the native Calendar (meds never mirrored). The routine reconcile path is not implicated; the fix is extending the mirror, and the smoke test re-verifies the existing routine path.
2. **Recurrence options:** none / daily / weekly.
3. **Navigation:** same as the existing directions flow — `MapsLinks` (Apple Maps `maps://?daddr=<lat>,<lng>` auto-start; Google Maps `comgooglemaps://…&navigation=1` fallback per installed-app preference), forward-geocoded at tap time.
4. **Architecture:** Approach A — free-form events ARE native EventKit events (default calendar); the app keeps only a side-index for what EventKit cannot hold (photo). Everything else rides the existing import → alarm → caregiver-notify → Google-bridge pipeline.

## 2. S1 — Free-form event creation

- `SettingsTabs` gains an **Events** row (Reminders tab) → `EventsListView` (upcoming app events, newest first) with a **＋** add form, house form styling (≥44pt targets, en+ne L10n).
- Form fields: **title** (required), **date/time**, **duration** (default 30 min — the house default), **recurrence** (none/daily/weekly), **notes** (optional), **photo** (optional — PhotosPicker + `DownsampledImageCache` + app-side photo store, the PHOTO-AIDS/ContactPhotoStore pattern), **address** (optional free text).
- Save writes an `EKEvent` to the **default calendar** (`alarms = nil`, house rule — the app's own notification is the fire signal) with `location = address` (plain string: the native Calendar app shows it, and the Google twin inherits it).
- `EventExtrasStore` (encrypted, `EncryptedLocalStorage`) side-index: `eventId → photoFilename`. EventKit has no attachment API, so photos show in the app (event list/detail + large at fire time via the PHOTO-AIDS pattern) — honestly never in the native Calendar app or Google Calendar.
- Edit/delete in the form touch the same native event; delete removes the side-index row (photo file deleted via the photo store's remove path).

## 3. S2 — Everything lands in the native calendar; two-way works

- **Medications:** extend `CalendarSyncService` (today routines-only) to medication entries — one recurring mirror event per schedule slot in the **Sahayak calendar** (visible in the native Calendar app; excluded from the app's import so meds cannot double-alarm — the routine mirror's existing rule). Same `MirrorLinkToken` / `ExternalEventLinkStore` / pure planner pattern: family retimes or drops slots in the Calendar app and the med schedule follows; deleting a slot's mirror never resurrects it. Same safety rules as routines (meds edits still go through `loadSchedule` + re-arm).
- **Routines:** already mirrored — no code change. The smoke test re-verifies the reconcile path end to end.
- **Free-form events:** native by construction (S1) — family edits in the Calendar app flow back because there is one event.
- **Google sharing parity:** free-form events ride the PR #8 bridge — create via the existing writer hook; edits/deletes via a foreground reconcile of side-index-tracked events (title/time/location changed → update twin; deleted → tombstone). `CalendarShareMapper` gains the `location` field (twin draft + REST body).

## 4. S3 — Address → notification → Maps auto-start

- Events with an address: the fire notification's category gains an **Open** action that deep-links into the app's event detail (extends the existing `NotificationFacade` categories; the action performs no background work). No address → plain reminder, no action.
- Event detail (and the fire-time card when a photo is present) shows a **Navigate** button when the event has an address: forward-geocode at tap time, then `MapsLinks` — Apple Maps auto-start, Google Maps `navigation=1` fallback per the existing preference logic. Zero new navigation code.
- New small coordinator route: notification "Open" action → event detail screen (deep-link by event id).

## 5. Tests

- New: `EventExtrasStoreTests` (photo index round-trip, tolerant decode, delete cleanup), `FreeFormEventFormTests` (validation matrix, recurrence → `EKRecurrenceRule` mapping, default duration), `CalendarSyncServiceTests` additions (meds slot→recurring-event mapping; family retime/drop reconcile for meds), `CalendarShareServiceTests` additions (free-form edit reconcile → twin update/tombstone; location in twin draft), notification-category tests (action present only when address exists), `MapsLinks` reuse pin (auto-start URLs unchanged).
- Pinned existing: `VoiceCalendarEventWriterTests`, `CaregiverEventFireHandlerTests`, `ExternalCalendarServiceTests`, `CalendarShareMapperTests`.

## 6. Execution

- Worktree `worktree-rich-events` → sdd-run → `./build.sh generate` → targeted `-only-testing` gate on the dedicated simulator → PR → merge. One PR — the pieces are one feature surface.
- **Anzaan smoke test (after merge):**
  1. Reminders → Events → create "डाक्टर भेट" + address + photo → appears in the native Calendar app with the address → notification at start−5 min with Open → Navigate auto-starts driving in Apple Maps.
  2. Add a medication → its slot appears as a recurring event in the Calendar app → family edits the time in Calendar → the med schedule follows.
  3. Caregiver Gmail receives the Google invitation for the free-form event, location included.

## 7. Out of scope (explicit)

Monthly/yearly/custom recurrence (none/daily/weekly only); photos in the native Calendar app or Google Calendar (platform APIs don't support event photos); a general-purpose calendar grid view (list only); editing Google-twin attendees per-event beyond the existing invite policy; Android (v2).
