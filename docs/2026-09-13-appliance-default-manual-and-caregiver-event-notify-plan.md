# Plan: Appliance default manuals + caregiver event notifications + real create_calendar_event

## Context

Three coordinated changes, all iOS-first:

1. **Appliance default manual** — the first user-created manual for an appliance category (e.g. microwave) becomes that category's *default*; later voice requests about that appliance serve the saved manual instead of re-opening the camera.
2. **Caregiver event notifications** — per-event-type settings (medicine reminders, routine reminders, calendar events) that notify configured caregivers when an event fires, so a caregiver can call the elder or check logs to see whether medication was taken on schedule.
3. **Fix `create_calendar_event`** — the voice intent is an honest "not yet" stub today; the user wants real event creation (their "meeting events" mental model).

User decisions (asked & answered):
- Notify channel: derived from the **default calling** preference — GSM → SMS, Messenger → Messenger message, WhatsApp → WhatsApp message; FaceTime → SMS fallback. Per-contact pick wins, else global `defaultCallApp`.
- Notify attachment: **per-event-type settings** (configure once; events of that type auto-notify). Defaults OFF.
- Default manual key: **appliance category**.
- Caregiver scope: **plumbing now, relay later** — the E2E relay + caregiver app (`docs/family-notifier-e2e-implementation-plan.md`) stays its own follow-up; today's APNs/FCM transport stubs stay honest stubs. No compose-sheet popups.

---

## Feature 1: Appliance default manual (iOS)

### Current behavior
- Voice "how to operate X" → `ApplianceHelperPlugin.handle` (`Services/Plugins/ApplianceHelperPlugin.swift:69`) → ALWAYS `.spokenAndPresented(cameraPrompt)` → camera auto-opens. No default-manual concept exists anywhere (confirmed); "Default manuals" in the UI = bundled shipped manuals (untouched).
- `ApplianceHelperSession.presentManual(entryID:)` (`ApplianceHelperSession.swift:126`) already renders a saved manual from cache — the serve mechanism to reuse.
- The guide-deferral path already sends `entities["appliance"]` to the plugin (CommandRouter ~2383, pinned by `GuidePluginDispatchTests.swift:73`).

### Design
- **Per-category default**: first manual per category wins; blank/"other" categories never promoted.
- **Category matching**: new pure normalizer `ApplianceCategoryKey` — lowercase/trim/collapse + short EN+NE synonym map (microwave/माइक्रोवेभ → "microwave", tv/टिभी/television/tv_remote → "tv_remote", washing machine/वासिङ मेसिन, fridge/फ्रिज/refrigerator, …). Unknown → normalized passthrough.
- **Question rule on voice serve**: serve the default when the questions don't conflict — default's question is nil, OR request question is nil, OR `ApplianceCache.questionsMatch(...)`. Else camera (different operation of same appliance).
- **Auto-promotion** after both pipeline stores (sites 4a and 5 in `ApplianceHelperSession.runPipeline`); **delete re-promotion** (deleting the default promotes most-recent same-category manual).
- **UI**: small `star.fill` badge on the default row in the library. Auto-only (no manual set/change-default UI this iteration).

### Changes
1. `Services/Appliance/ApplianceCache.swift`
   - `Entry.isDefault: Bool` (tolerant decode → false; init default false).
   - `func defaultEntry(forCategory:) -> Entry?` — read-only lookup (no LRU touch/persist).
   - `func setDefault(entryID:) -> Bool` — clear same-category defaults, set target.
   - `delete(entryID:)` — re-promote most-recent `createdAt` same-category entry when the deleted one was default.
   - `store(...)` → `@discardableResult -> UUID` (returns new entry id).
2. `Services/Appliance/ApplianceCategoryKey.swift` (new) — the normalizer + synonym map, pure/test-pinned.
3. `Services/Appliance/ApplianceHelperSession.swift` — `storeAndPromoteIfNone(...)` helper used at both store sites; new `pendingManualEntryID: UUID?` init param + `presentPendingManualIfNeeded() -> Bool`.
4. `Services/Plugins/ApplianceHelperPlugin.swift` — extend `intentContribution.promptFragment` to emit `"appliance": "<category keyword>"` in pluginEntities (cloud-only; no IntentPrompt core/seed change); `handle` resolves `entities["appliance"]` via `ApplianceCategoryKey`, on hit stashes entry id and returns `.spokenAndPresented(L10n.fmt("plugin.applianceHelper.defaultManualPrompt", displayName))`; `presentationView(for:)` passes the id into the session.
5. `Services/Appliance/ApplianceHelperView.swift` — `.onAppear`: pending manual first (via `presentPendingManualIfNeeded`), camera auto-open only if that fails.
6. `Services/Appliance/ApplianceManualLibraryModel.swift` + `ApplianceManualLibraryView.swift` — `Manual.isDefault`; star badge (accent circle, ~24pt) + a11y label.
7. `Resources/Localizable.xcstrings` — new keys en+ne: `plugin.applianceHelper.defaultManualPrompt` ("I have your %@ manual — here it is."), `appliance.manual.defaultBadge`. (`L10n.fmt` supports `%@`; pattern: `appliance.stepAccessibility`.)
8. Tests: `ApplianceCacheTests` (default APIs, tolerant decode, re-promotion, store-id), new `ApplianceCategoryKeyTests`, `ApplianceHelperSessionTests` (promotion rules, pending manual), `ApplianceHelperPluginTests` (serve vs camera, question conflicts), `ApplianceManualLibraryTests` (isDefault surfaced). Reuse `GeminiInMemoryStorage` fake (GeminiConfigStoreTests.swift:146).

---

## Feature 2: Caregiver event notifications + real `create_calendar_event`

Design verified in code by the Plan agent (fire paths, facade ordering, calendar import behavior). Key verified facts:
- `NotificationFacade.present` (NotificationFacade.swift:81–91) stops at the first handler claiming — a fire handler returning `false` never suppresses `NotificationReader` speech.
- `AppCoordinator` excludes the Sahayak calendar from `ExternalCalendarService` import (AppCoordinator.swift:2139–2141) → voice events must go to the **default** calendar to be imported (and thus armed + fire-notified) for free.
- `EKCalendarGateway.apply` sets `alarms = nil` (EventKitCalendarGateway.swift:327) → import arms the in-app notification; no native double-notify.
- `NepaliTimeParser.parse` already handles आज/भोलि/पर्सि/today/tomorrow/weekdays (NepaliTimeParser.swift:54–175).
- `.createCalendarEvent` is tier `.confirm` (ConfirmationTier.swift:21) → executor must ask a dual-channel yes/no itself, like `handleCall` → `requestCallConfirmation`.
- `InterpretedCommand` already carries `topic` + `time` (LlamaCommandInterpreter.swift:89–120); `IntentCommandCache.isCacheable(.createCalendarEvent) == false` — no cache learning.

### 2.1 Settings + channel derivation
- New `EventNotifyKind { medicationReminder, routineReminder, calendarEvent }` — one per firing system (voice `set_reminder` builds a `MedicationEntry`, so it's medication-kind).
- New `CaregiverNotifySettings: ObservableObject` (`Services/FamilyNotifier/`): 3 `@Published` bools persisted to UserDefaults (keys `caregiverNotify.*`), all default **false**; house pattern = `ExternalCalendarService.isEnabled/leadMinutes` (ExternalCalendarService.swift:98–126). UI prefs, not secrets — UserDefaults is right (unlike encrypted `ChannelPreferenceStore`).
- New `NotifyChannel { sms, whatsApp, messenger }` + pure mapping `resolve(from: CallApp)`: phone→sms, whatsApp→whatsApp, messenger→messenger, **faceTime→sms**; messenger with empty `messengerHandle` → sms (mirrors `resolvedCallChannel`, AppCoordinator.swift:1352–1358).
- Resolution rule at contact mapping (`AppCoordinator.emergencyContacts(from:)`, ~4416): use the contact's `preferredCallApp`; when it is `.phone` (the unconfigured default), fall back to the global `defaultCallApp`. Thread the resolved channel into `EmergencyContact.notifyChannel`.

### 2.2 FamilyNotifier seam
- `FamilyAlertType.eventReminder` added to `Services/MedicationScheduler/Models.swift:91–98` — one wire type; the kind rides in context, NOT the envelope (E2E payload stays `{v:1, alert_type, timestamp}`, no PII).
- New `FamilyAlertContext { kind, eventIdHash, eventTitle, fireAt }` (in-memory only); `notifyAll(alertType:at:context:)` with a default-nil protocol extension so existing call sites compile unchanged.
- `APNsFamilyNotifier`: gains `observabilityBus`; emits `family_event_alerted` with metadata (alert_type, kind, channel, event_id_hash — NEVER the title); `NotificationResult` gains `channel: String?`. Stub `APNsProvider.sendPush` untouched (honest).
- `EmergencyContact` gains `notifyChannel: NotifyChannel`.
- Doc comment on `FamilyAlertContext`: the no-PII tension is documented, and the future transport project must re-litigate title-on-wire explicitly.

### 2.3 Fire sites (fire-time, settings-resolved — NO per-event model flags)
- **Medication**: in `MedicationScheduler.triggerReminder(for:)` (MedicationScheduler.swift:162–201), before `reminder.lastFiredAt` is overwritten (line 182) — only the FIRST fire notifies (`lastFiredAt == nil` gate; the re-arm recovery path re-fires without re-notifying). Foreground/late delivery is honest + documented. Existing missed-dose (~408) and double-dose (~358) alerts unchanged. Init gains `caregiverNotifySettings`.
- **Routines**: wire the designed-but-unwired `RoutineScheduler.markDelivered(occurrenceId:)` hook (RoutineScheduler.swift:194–206) — fires notifier with kind `.routineReminder` + entry title. Init gains `familyNotifier` + `caregiverNotifySettings`.
- **Calendar/external**: new `CaregiverEventFireHandler: NotificationEventHandling` (`Services/FamilyNotifier/CaregiverEventFireHandler.swift`) — `willPresent` routes `routine_reminder` (→ `markDelivered`) and `external_reminder` (→ notifier with kind `.calendarEvent`, resolved by `external_id`); ALWAYS returns `false`. Registered third in the facade at AppCoordinator.swift:2227. Voice-created events inherit this for free (imported + armed with `external_` ids).

### 2.4 Real `create_calendar_event`
- `CommandRouter.dispatchInterpreted` (~2177–2182): split — `.createCalendarEvent → handleCreateCalendarEvent(command)`; `.suggestVideo` keeps the stub.
- `handleCreateCalendarEvent`: validate `topic` (else `router.calendarEventNoTitle`), `time` via `NepaliTimeParser.parse` + new pure `CalendarEventTimeResolver.resolveEventDate(from:now:calendar:)` (bare time → today, rolling to tomorrow if past) (else `router.calendarEventNoTime`); then `coordinator?.requestCalendarEventConfirmation(title:startDate:sourceTranscript:sourceCommand:)`; permission-denied → return nil → speak `router.calendarEventCalendarUnavailable` (never ask yes/no for an action that can only fail — mirror of the Messenger-no-handle pre-gate).
- `AppCoordinator`: `PendingCalendarEvent` (next to `PendingCallAction` ~4854); `requestCalendarEventConfirmation` pends + transitions `voiceSession` to `.awaitingConfirmation` (45s machine) + returns `L10n.fmt("router.calendarEventConfirm", title, SpokenTime.string(from:startDate))` (**SpokenTime is mandatory for all spoken times** — house rule); `handleConfirmationResponse` (6649) gains the branch: yes → `executePendingCalendarEvent()`, no → `router.calendarEventCancelled`; `isAwaitingConfirmation` (6725) includes the pending event.
- New seam `Services/CalendarSync/VoiceCalendarEventWriter.swift`: `protocol CalendarEventWriting { eventsAccess; requestAccess(); create(title:startDate:durationMinutes:) }` + `EventKitCalendarEventWriter` over the already-protocol-typed `EventKitCalendarGateway` — `createEvent(CalendarEventDraft(..., recurrence: nil), in: nil)` → **default calendar** (Sahayak is excluded from import). 30-min default duration, `alarms = nil`. `AppCoordinator` lazy property (house pattern, cf. `calendarSync` ~6331).
- Success → speak `router.calendarEventCreated` + outcome card; failure → honest `router.calendarEventCalendarUnavailable`. `VoiceCommandCoordinating` protocol gains the new method; `StubCoordinator` (IntentTestHelpers.swift) gains a recorder.

### 2.5 Settings UI + L10n
- New leaf `App/CaregiverNotifySettingsView.swift` — one card, three toggles (card + toggle-row pattern from `CalendarSettingsView.externalCalendarCard`, 193–244), SF Symbols `pills.fill`/`figure.walk`/`calendar`, plus two captions: channel hint (default-calling rule) and honesty hint (delivery activates with the family app; alerts are prepared + recorded today — constitution: no silent stubs).
- `SettingsView.SettingsSection` gains `caregiverNotifications` + row (icon `bell.badge.fill`) + `navigationDestination`.
- L10n keys en+ne: `settings.notifyCaregivers.*` (title, 3 toggles, channelHint, hint), `family.alertEventReminder`, `router.calendarEventNoTime`, `router.calendarEventNoTitle`, `router.calendarEventConfirm` ("…" %1$@ at %2$@ — should I add this to your calendar?), `router.calendarEventCancelled`, `router.calendarEventCreated`, `router.calendarEventCalendarUnavailable`.

### 2.6 Android mirror (minimal parity only)
- `Models.kt`: `EVENT_REMINDER` + `NotificationResult.channel`. `FamilyNotifier.kt`: `NotifyChannel` enum + mapping, `EmergencyContact.notifyChannel`, nullable-context `notifyAll` (existing call sites compile unchanged), `FamilyAlertContext`. New `NotifySettings.kt` (SharedPreferences, default false). `ElderlyAssistantApp.kt`: construct settings, keep honest `emptyList()`. Update `FamilyNotifierTest.kt`.
- NO Android fire-path wiring, NO Android calendar-event creation (v2-deferred, documented).

### 2.7 Tests (new files under ios/ElderlyAssistantTests/Services/FamilyNotifier/ + CalendarSync)
- `NotifyChannelTests` (mapping incl. faceTime→sms, empty-handle→sms, per-contact vs global), `CaregiverNotifySettingsTests` (defaults OFF, persistence via injectable UserDefaults suite), `CaregiverEventFireHandlerTests` (routine→markDelivered; external with setting ON→notifier+context+channel; OFF→no call; unknown type→no call; always returns false), `FamilyNotifierTests` (legacy alerts context-nil; observability metadata never contains the title), `VoiceCalendarEventWriterTests` (time resolver cases; create delegates `in: nil`, 30 min, no recurrence; access-denied → false).
- Edits: `MedicationSchedulerTests` (first-fire notify only), `RoutineSchedulerTests` (markDelivered notify), `CommandRouterTests` (calendar-event dispatch to confirmation; missing topic/time paths; suggestVideo still stubs).
- Reuse `MockFamilyNotifier` (MedicationSchedulerTests.swift:75–88), `RecordingObservabilityBus`/`StubEncryptedStorage` (IntentTestHelpers.swift).

### 2.8 Out of scope (explicit)
Relay/APNs/FCM transport + caregiver app (existing plan docs); remote log access; compose-sheet popups; `suggest_video`; `MedicalAppointmentCalendarWriting` Noop (calendar-2way worktree owns it); Android calendar creation + fire wiring; `isEmergencyContact: true` hardcode at AppCoordinator:4422.

### Feature 2 file list
iOS new: `NotifyChannel.swift`, `CaregiverNotifySettings.swift`, `CaregiverEventFireHandler.swift`, `VoiceCalendarEventWriter.swift` (incl. `CalendarEventTimeResolver`), `App/CaregiverNotifySettingsView.swift`.
iOS edits: `Services/MedicationScheduler/Models.swift` + `MedicationScheduler.swift`, `Services/FamilyNotifier/FamilyNotifier.swift`, `Services/Reminders/RoutineScheduler.swift`, `Services/Voice/CommandRouter.swift`, `App/AppCoordinator.swift` (settings wiring ~1533/1552, notifier init ~1475, `emergencyContacts` + 4 call sites, confirmation flow, facade handlers ~2227), `App/SettingsView.swift`, `Resources/Localizable.xcstrings`, `Tests/Services/Intents/IntentTestHelpers.swift`.
Android: `services/medication/Models.kt`, `services/family/FamilyNotifier.kt`, `services/family/NotifySettings.kt` (new), `ElderlyAssistantApp.kt`, `test/.../FamilyNotifierTest.kt`.

---

## Execution rules (project)
- All task work in dedicated git worktrees (branch `worktree-<slug>`), via subagents — never in the main checkout; main checkout is integration + verification only. Merge master into each worktree first (parallel sessions land commits often).
- Feature 1: worktree `worktree-appliance-default-manual` (subagent).
- Feature 2: worktree `worktree-event-caregiver-notify` (subagent — user explicitly asked).
- Features are independent → run both subagents in parallel, then integrate each into master in the main checkout sequentially after its tests pass.

## Verification
- iOS: `cd ios && ./build.sh generate` (REQUIRED after adding new Swift files — xcodegen directory scan), then `./build.sh test:impact` (fast gate) and `./build.sh test:unit` (full gate before merge). Per memory: use `xcodebuild test`, not `build` (swift-syntax shims); `./build.sh` is canonical. Targeted iteration via `-only-testing:` for the suites above.
- Android: `cd android && ./build.sh` + FamilyNotifierTest.
- Manual Feature 1: create microwave manual → star badge in library → voice "माइक्रोवेभ कसरी चलाउने" serves the saved manual (no camera); a conflicting specific question still opens the camera.
- Manual Feature 2: Settings → Family notifications toggles; voice "भोलि बिहान डाक्टर भेट्न जाने" → confirmation prompt → event lands in the default native calendar → in-app notification at start−5min → `family_event_alerted` observability with channel + kind recorded (delivery itself waits on the future relay, per scope).
