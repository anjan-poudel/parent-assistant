# Implementation Plan: Calendar & Family Sharing — Emergency Email + Google Calendar Bridge

**Date:** 2026-09-16
**Design:** `docs/superpowers/specs/2026-09-16-calendar-family-sharing-design.md` (approved)
**Scope:** Piece A (contact email + emergency-mandatory) + Piece B (Google Calendar sharing). Piece C (caregiver companion app) out — TG-07.
**Platform:** iOS only (Android deferred v2, consistent with the 2026-09-13 plan).

## 0. Prerequisites (user-owned, blocking for E2E but not for build/tests)

GoogleSignIn-iOS needs an OAuth client from a Google Cloud project:
- Create iOS OAuth client ID; the app's `GIDClientID` comes from an Info.plist key (house choice: `GoogleSignIn` plist key or code constant — implementation picks the documented one).
- Configure `CFBundleURLTypes` reverse-client-id URL scheme in `project.yml`.
- OAuth consent screen: scopes `openid`, `email`, `https://www.googleapis.com/auth/calendar.events`, `https://www.googleapis.com/auth/contacts`.
- **Graceful degradation is required:** a missing client ID must leave the Settings card in the honest "not configured" state, never crash (constitution: no silent stubs).

## 1. Piece A — contact email (model + editor)

1. `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift`
   - `FamilyContact` gains `var email: String?` (optional — custom decoder `try? decodeIfPresent` → nil; pre-field payloads load fine). Init param default nil.
2. `ios/ElderlyAssistant/App/SettingsView.swift` (family editor, ~2280–2660)
   - New email field step (`.keyboardType(.emailAddress)`, autocapitalization off, autocorrection off), placed with the optional-details step.
   - **Validation:** while `isEmergencyContact == true`, Save is disabled until email is non-blank AND well-formed (simple check: `@` + dot in domain). Inline hint. Toggle OFF → optional again.
   - Existing emergency-flagged contacts without email: editor shows a hint to add one.
   - Update the two `FamilyContact` constructors at save (~2634/2640) with the email.
3. L10n (`Resources/Localizable.xcstrings`): en+ne keys `family.contact.email`, `family.contact.emailRequired`, `family.contact.emailInvalid`, `family.contact.emailHintEmergency`.
4. Tests: `FamilyContactStoreTests` — email decode/round-trip/missing-key nil; editor validation via model-level helper if extracted (recommend extracting a small pure validator `FamilyContactValidation` so the save-gate is testable without UI).

## 2. Piece B — Google bridge components (new, `ios/ElderlyAssistant/Services/CalendarSync/`)

All Google IO behind protocols; production impls over `URLSession` (house style, cf. `GeminiClient`). No GTLR dependency.

1. **`GoogleAccountSession.swift`** — GoogleSignIn SDK wrapper (SPM: `packages: GoogleSignIn: url: https://github.com/google/GoogleSignIn-iOS.git` in `project.yml`, latest stable 8.x). Keychain token storage via `KeychainEncryptedStorage`. API: `isSignedIn`, `signIn(presenting:)`, `createAccount(presenting:)` (opens Google account-creation flow), `signOut()`, `accessToken() async -> String?` (silent refresh).
2. **`GoogleCalendarGateway.swift`** — protocol `GoogleCalendarGatewayProtocol` + REST impl:
   - `ensureFamilyCalendar() async -> String?` — find-or-create by summary `"Sahayak Family"`.
   - `createEvent(_ twin:) / updateEvent(id:with:) / deleteEvent(id:) async -> Bool`.
   - `ensureContact(email:name:) async` — People v1: search by email, create if absent (phone carried when present).
   - `listIncoming(syncToken:) / acceptInvitation(eventId:) async` — elder's primary calendar, `needsAction` attendees → patch response to accepted.
3. **`CalendarShareMapper.swift`** — pure: `CalendarTwinDraft` (title, start, duration 30-min default, timezone, recurrence rule when source recurring, attendee emails, kind). Invite policy: emergency contacts always; others only when `caregiverNotifySettings.isEnabled(for: kind)`. No-email contacts skipped. Returns nil (no-op) when: not signed in / no consent / zero invitees.
4. **`LocalGoogleEventMappingStore.swift`** — encrypted (`EncryptedLocalStorage`) map `localKey ↔ googleEventId` + persisted pending-ops queue (creates/updates/tombstones). Local key format `kind:uuid` (entry ids for med/routine, EventKit event id for calendar events).
5. **`CalendarShareService.swift`** — orchestrator:
   - `func reconcileMedication(_ entries: [MedicationEntry])`, `func reconcileRoutines(_ entries: [RoutineEntry])` — diff against last-known snapshot (create/update/delete twins), called from the schedulers' `onScheduleChanged` seams.
   - `func eventCreated(localEventId:title:start:duration:)` — calendarEvent twin create.
   - `func syncInbound()` — foreground + interval: accept incoming invites → create local EventKit event in the default calendar using the `external_` id convention (`ExternalReminderScheduling`) → run the existing `ExternalCalendarService` scan so import/arm/`CaregiverEventFireHandler` fire for free.
   - `func flushPending()` — retry queue with backoff; tombstone deletes; stale-twin cleanup (local event gone → delete twin).
   - Observability: `calendar_share_*` events with counts + error classes ONLY (no titles/emails).

## 3. Wiring (edits)

1. `ios/ElderlyAssistant/Services/MedicationScheduler/MedicationScheduler.swift`
   - Add `var onScheduleChanged: (() -> Void)?` fired at the end of `loadSchedule` (house pattern, mirror of `RoutineScheduler.onScheduleChanged`). All three mutation sites (`AppCoordinator.addMedication` ~6870, `removeMedication` ~6904, `addVoiceReminder` ~7443) flow through it — no other edits needed.
2. `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift` — no change: existing `onScheduleChanged` already fires on `addEntry`/`setEnabled`/`removeEntry`/native-edit mutators.
3. `ios/ElderlyAssistant/Services/CalendarSync/VoiceCalendarEventWriter.swift`
   - `CalendarEventWriting` gains an optional callback seam `var onEventCreated: ((String, String, Date, Int) -> Void)?` (local event id, title, start, duration) OR `create` returns the `eventIdentifier` — implementation picks; `EventKitCalendarEventWriter.create` invokes it. `AppCoordinator` wires it to `shareService.eventCreated`.
4. `ios/ElderlyAssistant/App/AppCoordinator.swift`
   - Construct `CalendarShareService` in init after `caregiverNotifySettings` (~1858) and the schedulers: inject `storage`, `observabilityBus`, `caregiverNotifySettings`, `consentStore`, `contactsProvider: { [weak self] in self?.familyContacts ?? [] }`, `mappingStore`, `gateway`, `session`.
   - Wire `medicationScheduler.onScheduleChanged` → `shareService.reconcileMedication(medicationScheduler.medicationEntries())`; `routineScheduler.onScheduleChanged` already wired to `calendarSync.syncNow` — extend that closure (or add a second assignment) to also call `shareService.reconcileRoutines(...)`.
   - Wire the writer callback; add foreground-flush + interval inbound sync to the existing foreground hooks.
5. `ios/ElderlyAssistant/App/SettingsView.swift`
   - `SettingsSection` gains `calendarSharing` case (+ id), row (icon `calendar.badge.plus`), `navigationDestination` → `CalendarShareSettingsView` (pattern of `caregiverNotifications`, line ~220).
   - New leaf `ios/ElderlyAssistant/App/CalendarShareSettingsView.swift`: Google account card (Sign in / **Create a Google account** / account email / Sign out), consent card (re-readable en+ne disclosure; `calendarShare.consentAccepted` UserDefaults flag), honest status card (pending count, last sync, "Google unreachable — will retry", "not configured" when client ID missing).
   - `CaregiverNotifySettingsView` gains a caption: invites follow these toggles; emergency contacts are always invited.
6. L10n: en+ne keys `settings.calendarSharing.*` (~12), `calendarShare.consent.*` (~4), `family.contact.*` (Piece A), `caregiverNotify.inviteCaption`.
7. `ios/project.yml`: GoogleSignIn package + Info.plist URL scheme entry; then `./build.sh generate` (REQUIRED — xcodegen scan).

## 4. Tests (new, `ios/ElderlyAssistantTests/Services/CalendarSync/` + existing dirs)

- `CalendarShareMapperTests` — invite-policy matrix (emergency always / toggle kinds / no-email skip / no-signin, no-consent, no-invitee → nil), recurrence mapping, title passthrough, 30-min default.
- `GoogleCalendarGatewayTests` — request building (attendees JSON, RRULE, find-or-create, ensureContact create-vs-existing, inbound accept) against a stub `URLProtocol`-style transport.
- `CalendarShareServiceTests` — reconcile diff (create/update/delete), tombstone + retry persistence, stale-twin cleanup, inbound accept→import with `external_` id, sign-out pause.
- `LocalGoogleEventMappingStoreTests` — encrypted round-trip, pending-ops queue, tolerant decode (pre-store payloads).
- Edits: `FamilyContactStoreTests` (email), `MedicationSchedulerTests` (onScheduleChanged fired on loadSchedule), `VoiceCalendarEventWriterTests` (callback invoked with id/title/start/duration), `CaregiverNotifySettings` unaffected (no change).
- Reuse: `GeminiInMemoryStorage` fake, `RecordingObservabilityBus`, `StubEncryptedStorage` (`IntentTestHelpers.swift`).

## 5. Verification

- `cd ios && ./build.sh generate` then `./build.sh test:impact` (fast gate) and `./build.sh test:unit` (full gate before merge). Per memory: `xcodebuild test`, not `build`; `./build.sh` is canonical; release log-safety gate runs inside every scope automatically.
- Manual (needs the Google Cloud client ID from §0):
  1. Settings → Family → edit contact: toggle Emergency → Save blocked without email; add email → saves.
  2. Settings → Calendar sharing: connect account (or Create account), accept disclosure → status shows connected.
  3. Voice "भोलि बिहान डाक्टर भेट्न जाने" → confirm → event in default calendar AND twin in "Sahayak Family" Google calendar with the emergency contact invited (Gmail contact auto-created).
  4. Add a medication with a caregiver toggle ON → recurring twin invite.
  5. Caregiver accepts invite → event visible in their native calendar app.
  6. Inbound: caregiver creates an event in Google Calendar with the elder's address → next app foreground → event appears in elder's calendar + notification armed.
  7. Sign out → pending count grows honestly; local events still fire.

## 6. Execution rules (project)

- All work in THIS worktree (`.claude/worktrees/calendar-share`, branch `worktree-calendar-share`) via a subagent (house rule; user's standing memory: task work ONLY in worktrees).
- Merge master into the worktree first — parallel sessions land commits often (memory: intent-engine-impl).
- Integrate via PR against master (memory: integrate-via-prs); verification in the main checkout.

## 7. Out of scope (explicit)

Companion caregiver app + notification tap → call/video (TG-07); broker relay; APNs push; backfill of pre-enable events; system-level Google account setup; per-instance series edits (v1 updates whole series); Android.
