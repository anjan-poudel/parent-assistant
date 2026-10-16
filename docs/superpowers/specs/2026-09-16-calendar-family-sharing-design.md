# Design: Calendar & Family Sharing — Emergency-Contact Email + Google Calendar Bridge

**Date:** 2026-09-16
**Status:** Approved (brainstorming session; user decisions recorded below)
**Scope:** Piece A (contact email + emergency-mandatory) + Piece B (calendar sharing via Google Calendar). Piece C (companion caregiver app notification → call/video) is explicitly TBD / out of scope — it depends on the TG-07 broker relay, which is not built.

## 1. Context

Shipped 2026-09-13 (plan `docs/2026-09-13-appliance-default-manual-and-caregiver-event-notify-plan.md`) delivered:

- `FamilyContact.isEmergencyContact` + Emergency Contact toggle in the family editor (`SettingsView.swift:2330`).
- Real voice `create_calendar_event` → default EventKit calendar (`VoiceCalendarEventWriter`).
- `CaregiverNotifySettings` — three OFF-by-default toggles (medication / routine / calendar-event) controlling fire-time caregiver notifications; `FamilyNotifier` transport is an honest stub (delivery waits on the TG-07 relay).

Hard constraint verified in code: **EventKit cannot set attendees on an event** — "create the invite from the native calendar" is impossible by construction. The only mechanism that lands an invitation in a caregiver's native calendar app (iOS or Android) is creating the event in a Google Calendar with the caregiver as an attendee; Google then emails the invite. Constitution lists Google Calendar API as a required integration, so this is the sanctioned path.

## 2. User decisions (asked & answered)

1. **Scope:** Pieces A + B now; caregiver companion app (C) stays TBD.
2. **Invite policy:** emergency-flagged contacts are ALWAYS invited to every shared event; other family contacts follow the existing per-type toggles (`CaregiverNotifySettings`), default OFF.
3. **Google account:** the elder's own Google account, signed in on-device via app-level OAuth (family-assisted, one-time). **If no Google account exists, the Settings card offers an explicit "Create a Google account" option** (opens Google's account-creation flow) alongside sign-in — Google's OAuth screen itself also offers account creation.
4. **Recurring reminders:** one invite per recurring series (Google Calendar recurrence rule), not per occurrence.
5. **Event titles:** plain-language consent screen first (en+ne); after consent, full titles — including medication names — are shared.
6. **Mechanism:** Approach A — app-level bridge: GoogleSignIn SDK + hand-rolled REST (Calendar v3 + People v1), immediate mirroring at create/edit/delete, bounded retry queue.

## 3. Piece A — Contact email field

**Model** (`Services/Storage/FamilyContactStore.swift`):

- `FamilyContact` gains `var email: String?` — optional, same migration pattern as `address`/`nickname`: custom decoder reads a missing key as `nil`; pre-field payloads load fine. The store is already encrypted (`EncryptedLocalStorage`).

**Editor** (`App/SettingsView.swift` family editor):

- New email field (`.keyboardType(.emailAddress)`, autocapitalization off, autocorrection off), L10n keys en+ne.
- **Validation:** while the Emergency Contact toggle is ON, email is mandatory — Save is disabled with an inline hint until a well-formed address is entered (simple check: `@` + dot in domain). Toggle OFF → email optional again.
- Emergency-flagged contacts saved before the field existed (including the synthetic fallback contact at `AppCoordinator.swift:4907`) keep loading; the editor shows a hint to add an email, and invite logic simply skips them until they have one.

## 4. Piece B — Google Calendar bridge

### 4.1 Architecture

```
                    elder's iPhone (local-first, unchanged)
voice/UI event ──► EventKit (default cal) ──► alarms + fire-time notify (existing)
        │ create/edit/delete hooks
        ▼
CalendarShareService ──(immediate, bounded retry)──► GoogleAccountSession
        │                                              │ Calendar v3 REST
        ▼                                              ▼ People v1 REST
 "Sahayak Family" Google calendar ──attendees──► caregivers' native calendars
        ▲
        └── inbound poll: auto-accept invites where elder is attendee,
            import to local EventKit with external_ ids (existing import arms them)
```

Local behavior is untouched: events still land in EventKit first, alarms still fire from there. The Google layer is a share-only mirror plus an inbound import path.

### 4.2 Components (new, under `Services/CalendarSync/`)

- **`GoogleAccountSession`** — GoogleSignIn SDK wrapper (app-level OAuth, no server; scopes `openid/email`, calendar, people). Tokens in Keychain via `KeychainEncryptedStorage` (house pattern). `isSignedIn`, sign-in, sign-out, token refresh.
- **`GoogleCalendarGateway`** — hand-rolled REST over `URLSession` (house style, cf. `GeminiClient`):
  - find-or-create the dedicated calendar (summary `"Sahayak Family"`),
  - create / update / delete events with attendees + recurrence,
  - `ensureContact(email:name:)` via People v1: create the caregiver as a Gmail contact before first invite (keeps invites out of spam; matches the user's "auto-generate contact in Gmail"),
  - `listIncoming` + accept: events on the elder's primary calendar where the elder is a `needsAction` attendee → patch attendee response to accepted.
- **`CalendarShareMapper`** (pure, test-pinned) — local source → twin draft: full title (post-consent), start, duration (30-min default, house default), timezone, recurrence rule when the source entry is recurring, attendee list per policy (§4.3).
- **`LocalGoogleEventMappingStore`** — encrypted map `localEventID ↔ googleEventID` plus the persisted pending-ops queue (creates, updates, tombstones).
- **`CalendarShareService`** — orchestrator; hooks `eventCreated / eventEdited / eventDeleted`; retry flush on foreground + interval; inbound sync.

### 4.3 Invite policy (from decision 2)

- Emergency-flagged contacts: always attendees.
- Other contacts: attendees only when the toggle for the event's kind is ON.
- Contacts without email: skipped (emergency-mandatory makes this a config error, surfaced in the editor + Settings).
- No sign-in / no consent / zero eligible invitees → zero API calls; local behavior unchanged.

### 4.4 Lifecycle wiring (fire sites)

- `VoiceCalendarEventWriter` create/edit → hooks with kind `.calendarEvent`.
- `MedicationScheduler` create/delete → `.medicationReminder` (recurring series for daily entries).
- `RoutineScheduler` create/delete → `.routineReminder` (exercise lives here).
- Edits update the whole twin series (v1: no per-instance exceptions); deletes queue tombstones.

### 4.5 Inbound (the other half of "sharable")

On foreground + interval, poll Google for events where the elder is a `needsAction` attendee → programmatically accept → create locally in the default calendar with an `external_` id (mapping stored, cf. `ExternalReminderMapping`) → existing `CaregiverEventFireHandler` arms the notification and fire-time notify. A caregiver creating "Mom's doctor visit" in their own calendar and adding the elder's Gmail makes it ring on the elder's phone — no broker needed.

**Honest limitation:** inbound arrives at next app foreground (no push channel until TG-07).

## 5. Consent & Settings UI

**Two gates, in order:**

1. Google sign-in / account creation (decision 3) — family-assisted, one-time.
2. Plain-language disclosure (en+ne) shown in Settings before sharing activates: *"Event titles, including medication names, will be sent to your Google Calendar and shared with invited family contacts."* Acceptance stored as a UserDefaults bool (`calendarShare.consentAccepted` — prefs, not secrets; house pattern cf. `ExternalCalendarService.isEnabled`).

Sign-out or revoked consent pauses sharing; local behavior never affected.

**Settings UI:**

- New `CalendarShareSettingsView` leaf:
  - Google account card — signed out: "Sign in" + "Create a Google account" actions; signed in: account email + Sign out.
  - Consent card with re-readable disclosure.
  - Honest status card — pending-share count ("3 events waiting to share"), last sync time, "Google unreachable — will retry". Constitution: no silent stubs — when Google isn't connected, the card states exactly what's not happening and why.
- `CaregiverNotifySettingsView` toggles gain a caption: *calendar invites follow these toggles; emergency contacts are always invited.*
- Contact editor: email field + emergency-mandatory rule (Section 3).

## 6. Failure handling

- Every mutation enqueued locally first (persisted, encrypted) → applied immediately; failures retry with backoff on foreground/next launch; status surfaced in Settings.
- Deletes queued as tombstones so a failed create cannot orphan a twin on Google.
- Token expiry → silent refresh; revoked → pause + honest status.
- Logs carry counts + error classes only — never titles or emails (same no-PII rule as `FamilyAlertContext`); release log-safety gate applies.

## 7. Testing (house style: protocol fakes + pure mappers)

- `CalendarShareMapperTests` — invite-policy matrix (emergency always / toggle kinds / no-email skip / no-signin, no-consent, no-invitee → zero API calls), recurrence mapping, title passthrough post-consent.
- `GoogleCalendarGatewayTests` — request building (attendees JSON, RRULE, find-or-create calendar, `ensureContact` create-vs-existing, inbound accept).
- `CalendarShareServiceTests` — create→twin, edit→update, delete→tombstone, retry persistence, inbound accept→import with `external_` id, sign-out pause.
- `FamilyContactStoreTests` — email decode/migration; editor validation (Save blocked when emergency + blank/invalid email).
- Pinned existing suites: `MedicationSchedulerTests`, `RoutineSchedulerTests`, `VoiceCalendarEventWriterTests` (hook calls).

## 8. Execution (project rules)

- Implementation in this worktree (`worktree-calendar-share`) via subagent; `./build.sh generate` after adding files (xcodegen directory scan), then `test:impact` → `test:unit`; integrate via PR against master.
- GoogleSignIn SDK added via `project.yml` (vendored per house pattern if SPM is not already the convention).
- Android deferred to v2 — no mirror (consistent with the 2026-09-13 plan).

## 9. Out of scope (explicit)

- Companion caregiver app + notification tap → call/video (TG-07); broker relay; APNs push.
- Backfill of events created before sharing was enabled (only events created/edited after activation mirror).
- System-level Google account setup on the elder's phone (not required; app-level OAuth suffices — if the family later adds it, mild duplicate display in the Calendar app is accepted).
- Per-instance edits of a recurring series (v1 updates the whole series).

## 10. Open risks

- Google API quota (per-event create/edit/delete + inbound polling) — mitigated by the no-invitee short-circuit and foreground-only polling.
- Recurrence series edits: caregiver-side accepted invites stay linked to the series; updates propagate (Google handles it), deletions of the series remove caregiver events.
- Email validation is deliberately simple; undeliverable invites surface as a failed operation in Settings rather than being pre-validated.
