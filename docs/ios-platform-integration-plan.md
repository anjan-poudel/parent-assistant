# iOS Platform Integration Improvement Plan

## Status

Proposed implementation roadmap. iOS only; Android is intentionally out of scope.

## Purpose

Turn the existing voice assistant into a deeply integrated iOS personal operating system for seniors and technology-challenged users while preserving these properties:

- Voice remains the primary interaction model.
- Nepali and other underserved languages remain first-class, even when Siri language support is unavailable.
- Health and emergency paths never depend on the LLM or network availability.
- Apple platform APIs are isolated behind testable adapters.
- The future caregiver app communicates through stable, serializable domain models rather than parent-app internals.
- The parent app remains useful without an Apple Watch, Bluetooth peripheral, caregiver app, or cloud connection.

This plan is based on the findings in `docs/ios-integration-evaluation.md` and the current code under `ios/ElderlyAssistant/`.

---

## 1. Current baseline and non-negotiable findings

### 1.1 What is already working as a foundation

The current iOS app already has useful native integration patterns:

- SwiftUI application and composition root.
- Local voice pipeline with WhisperKit/CoreML/ANE and LLaMA components.
- `UNUserNotificationCenter`-based medication and routine alarms.
- EventKit adapters for Calendar and Reminders.
- Contacts adapters using `CNContactStore`.
- Core Location for point-of-use weather/navigation.
- Encrypted local storage.
- Protocol seams and fakeable pure mapping logic around several platform integrations.

Strong patterns to copy:

- Keep Apple framework objects inside thin adapter types.
- Convert framework objects to plain value types immediately.
- Ask for permissions at point of use.
- Persist the app's own intent separately from the operating system's permission truth.
- Treat denied or partial permission as an explicit state, not as an exception hidden from the user.
- Keep safety-critical local scheduling independent of optional platform integrations.

### 1.2 Current blockers

The following are not implemented in the iOS target:

- HealthKit data acquisition.
- HealthKit background observation.
- Health freshness and quality policy.
- Health threshold evaluation.
- Hardened health-triggered emergency dispatch.
- CoreBluetooth peripherals.
- Apple Watch target or WatchConnectivity.
- Production APNs delivery.
- E2E remote configuration broker.

Evidence:

- `docs/review-2026-08-30.md:65-67` records HealthKit and emergency monitoring as absent.
- `ios/ElderlyAssistant/Services/FamilyNotifier/FamilyNotifier.swift` contains an APNs provider stub that prints and returns success.
- `ios/ElderlyAssistant/App/AppCoordinator.swift` registers medication and calendar background tasks, but no health-monitor task.
- `ios/ElderlyAssistant/Info.plist` declares `com.elderlyassistant.health.monitor`, but no corresponding health implementation exists.

### 1.3 Current structural risk

`AppCoordinator.swift` is already approximately 195 KB and `SettingsView.swift` is approximately 149 KB. New health, Bluetooth, watch, and caregiver logic must not be added directly to either file.

The next architectural unit should be a capability layer composed by `AppCoordinator`, not more coordinator-owned behavior.

---

## 2. Target architecture

### 2.1 Layered structure

```text
App / SwiftUI
    |
    v
Voice and interaction orchestration
    |
    v
Domain capabilities
    +-- Reminders
    +-- Health summaries
    +-- Safety decisions
    +-- Contacts and calls
    +-- Calendar and navigation
    +-- Caregiver configuration
    |
    v
Platform adapters
    +-- HealthKit
    +-- WatchConnectivity
    +-- CoreBluetooth / AccessorySetupKit
    +-- EventKit
    +-- Contacts
    +-- Core Location
    +-- UserNotifications
    +-- App Intents
    |
    v
Persistence and transport
    +-- encrypted local state
    +-- durable safety event queue
    +-- E2E caregiver channel
```

### 2.2 Proposed source layout

```text
ios/ElderlyAssistant/
  Domain/
    Health/
      HealthMetric.swift
      HealthSample.swift
      BloodPressureReading.swift
      HealthSource.swift
      HealthFreshness.swift
      HealthDataPolicy.swift
    Safety/
      SafetyDecision.swift
      SafetyEvent.swift
      SafetyPolicy.swift
      SafetyDecisionEngine.swift
      EmergencyDispatching.swift
    Configuration/
      ParentConfiguration.swift
      HealthAlertPolicy.swift
      ConfigurationValidator.swift

  Services/
    Health/
      HealthDataProviding.swift
      HealthKitDataProvider.swift
      HealthPermissionState.swift
      HealthSampleNormalizer.swift
      HealthObservationCoordinator.swift
      HealthQueryService.swift
      HealthFreshnessPolicy.swift
      HealthSafetyMonitor.swift
    Peripherals/
      PeripheralDevice.swift
      PeripheralDeviceRegistry.swift
      BluetoothTransport.swift
      GATTValueDecoder.swift
      BloodPressurePeripheral.swift
      PulseOximeterPeripheral.swift
      WeightScalePeripheral.swift
    Watch/
      WatchConnectivityBridge.swift
      WatchMessage.swift
    Safety/
      EmergencyDispatcher.swift
      SafetyEventStore.swift
      CaregiverAlertQueue.swift
    Notifications/
      NotificationActionCoordinator.swift
      CriticalAlertAuthorization.swift
    Caregiver/
      RemoteConfigurationChannel.swift
      ConfigurationApplyService.swift
```

The exact directory names may follow current repository conventions, but the ownership boundaries are required.

### 2.3 Composition root responsibilities

`AppCoordinator` should only:

- Construct services.
- Connect protocol dependencies.
- Forward published state to SwiftUI.
- Route voice intents to domain services.
- Handle app lifecycle events.

`AppCoordinator` should not:

- Execute raw `HKQuery` logic.
- Decode GATT characteristic bytes.
- Evaluate clinical thresholds.
- Store HealthKit anchors directly.
- Build APNs payloads.
- Decide whether a health sample is clinically actionable.
- Contain caregiver configuration validation rules.

### 2.4 Domain invariants

These invariants apply to every implementation phase:

1. The LLM never decides whether a health event is an emergency.
2. A missing, stale, denied, or malformed sample never becomes a zero-valued sample.
3. HealthKit, WatchConnectivity, and Bluetooth samples are normalized into one domain model.
4. Every sample carries source and timestamp provenance.
5. Caregiver configuration cannot directly mutate live safety services without schema validation and atomic application.
6. Emergency dispatch does not depend on Gemini, LLaMA, the caregiver broker, or a successful UI render.
7. The parent app continues with local defaults when no caregiver app or peripheral is paired.
8. No health value, medication name, contact name, raw transcript, or device token enters ordinary logs.
9. Background execution is treated as opportunistic except for already-scheduled local notifications and platform-supported health delivery.
10. Every platform permission has a user-visible state: not requested, allowed, partial, denied, restricted, unavailable, or error.

---

## 3. Phase 0: architecture extraction and capability contracts

### Objective

Create the seams required for HealthKit and safety work without changing user-visible behavior.

### Tasks

1. Extract the current health-related placeholder types from generic scheduler dependencies.
2. Introduce domain models for metrics, samples, sources, freshness, safety events, and policies.
3. Add a capability registry that reports whether HealthKit, Watch, Bluetooth, and caregiver transport are available.
4. Move all future HealthKit state behind protocols.
5. Add a dedicated `Health` service container instead of adding more properties to `AppCoordinator`.
6. Add an encrypted anchor store abstraction.
7. Add a durable safety-event store abstraction.
8. Add a dedicated `SafetyDecisionEngine` protocol.
9. Establish a configuration schema version for health policies.
10. Add observability event names without logging health values.

### Proposed core models

```swift
struct HealthSample: Codable, Equatable, Identifiable {
    let id: String
    let metric: HealthMetric
    let value: Double
    let unit: HealthUnit
    let measuredAt: Date
    let receivedAt: Date
    let source: HealthSource
    let quality: HealthSampleQuality
}

enum HealthSampleQuality: String, Codable {
    case measured
    case imported
    case derived
    case stale
    case invalid
}

enum HealthSource: Codable, Equatable {
    case healthKit(sourceName: String?, deviceName: String?)
    case bluetooth(deviceIdentifier: String)
    case watch(deviceIdentifier: String?)
}
```

### Acceptance gates

- No UI behavior changes.
- All new models are Codable and Equatable where practical.
- No Apple framework types appear in domain models.
- A fake health provider can be injected into a service without `HKHealthStore`.
- Safety decisions can be tested from deterministic sample fixtures.
- `AppCoordinator` remains a composition root rather than a health implementation.

---

## 4. Phase 1: HealthKit read-only vertical slice

### Objective

Make spoken health queries truthful for heart rate and blood pressure without implementing automatic emergency dispatch yet.

Apple references:

- [HealthKit](https://developer.apple.com/documentation/healthkit)
- [HKHealthStore](https://developer.apple.com/documentation/healthkit/hkhealthstore)
- [HKQuantityType](https://developer.apple.com/documentation/healthkit/hkquantitytype)

### Initial data types

Start with the smallest useful set:

- Heart rate.
- Systolic blood pressure.
- Diastolic blood pressure.

Do not request oxygen saturation, respiratory rate, glucose, mobility, or medication data until each has a defined user-facing feature and privacy justification.

### Implementation tasks

1. Add the HealthKit capability in the iOS target.
2. Add only the required usage descriptions.
3. Implement `HealthKitDataProvider` around `HKHealthStore`.
4. Request read authorization only from a dedicated Health settings/onboarding action.
5. Map `HKQuantitySample` into `HealthSample`.
6. Preserve source, device, start date, end date, and unit.
7. Normalize heart rate to beats per minute.
8. Normalize blood pressure to mmHg.
9. Implement latest-value queries with explicit date sorting.
10. Add voice query handling for the existing `health_query` intent.
11. Return a localized “unavailable” response when permission is denied or no data exists.
12. Keep the health query path independent of Gemini.

### User experience

Voice examples:

- “What is my heart rate?”
- “मेरो मुटुको धड्कन कति छ?”
- “What was my blood pressure?”
- “मेरो प्रेसर कति छ?”

The response must include the measurement time when the reading is not recent enough to be considered current.

Example behavior:

```text
Your latest heart-rate reading was 78 beats per minute, recorded 12 minutes ago.
```

Do not imply that the app is measuring the user at the moment of speaking unless it actually is.

### Acceptance gates

- HealthKit permission is requested only at point of use.
- Denied permission produces a clear localized response and no crash.
- No data produces a clear localized response and no invented value.
- Units are correct.
- Source and timestamp are preserved.
- English and Nepali responses are covered.
- Health values do not appear in logs or caregiver notifications.
- The query succeeds with Gemini disabled and without network access.

---

## 5. Phase 2: HealthKit change observation and recovery

### Objective

Keep the local health view current without repeatedly scanning the entire HealthKit database.

### Apple query strategy

Use:

- `HKObserverQuery` for change notification.
- `HKAnchoredObjectQuery` for incremental reads and deletions.
- `enableBackgroundDelivery` where supported.
- Foreground reconciliation on every app activation.
- Background tasks only for repair and reconciliation.

References:

- [HKObserverQuery](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [HKAnchoredObjectQuery](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)
- [HealthKit background delivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))
- [BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks)

### State to persist

Persist through encrypted local storage:

- Query anchor per metric type.
- Last successful query time.
- Last received sample time per metric.
- Last permission state.
- Last observation failure category.
- Current health-service generation/version.

Do not persist raw HealthKit query objects.

### Recovery behavior

The observation coordinator must handle:

- App termination.
- Device restart.
- Health permission revocation.
- Health data deletion.
- Query anchor invalidation.
- Temporary HealthKit errors.
- Watch disconnection.
- No sample for a configured freshness window.
- Duplicate sample delivery.
- System time and time-zone changes.

If an anchor becomes invalid, discard only that anchor and perform a bounded resynchronization. Do not silently clear all health state.

### Acceptance gates

- New samples are processed once.
- Deleted samples are removed or marked according to the data policy.
- Relaunch resumes from the persisted anchor.
- Permission revocation produces a user-visible state.
- Observation failures produce a caregiver alert only when the failure policy says monitoring is genuinely interrupted.
- A delayed HealthKit delivery is represented as delayed, not as current.
- Background delivery is treated as best effort, not guaranteed real time.

---

## 6. Phase 3: health freshness, quality, and safety decisions

### Objective

Create a deterministic safety layer that is independent of voice recognition and LLM inference.

### Components

```text
HealthSampleNormalizer
        |
HealthFreshnessPolicy
        |
HealthQualityPolicy
        |
HealthSafetyMonitor
        |
SafetyDecisionEngine
        |
SafetyEventStore + AlertQueue + EmergencyDispatcher
```

### Freshness policy

For every metric, define:

- Expected source cadence.
- Maximum age for “current” display.
- Maximum age for automated decision-making.
- Behavior when a sample is missing.
- Behavior when the source is disconnected.

A stale reading may remain available for a spoken historical query but must not trigger a new emergency decision.

### Quality policy

Validate:

- Unit.
- Numeric range.
- Timestamp ordering.
- Source identity.
- Duplicate identity.
- Required paired values, such as systolic and diastolic pressure.
- Minimum interval between readings.

Reject invalid values. Do not clamp invalid medical data into apparently safe values.

### Threshold policy

Remote configuration may adjust user-specific alert policy only within product-defined safe bounds.

The policy must include:

- Schema version.
- Metric.
- Direction/operator.
- Threshold.
- Required persistence duration.
- Required number of samples.
- Cooldown.
- Hysteresis/reset threshold.
- User acknowledgement window.
- Escalation behavior.
- Policy source and revision.

Never allow an arbitrary caregiver payload to define unrestricted emergency behavior.

### Decision model

```swift
enum SafetyDecision: Equatable {
    case ignore(reason: SafetyIgnoreReason)
    case informUser(messageKey: String)
    case requestAcknowledgement(eventID: UUID)
    case escalate(eventID: UUID)
    case monitoringInterrupted(reason: MonitoringInterruption)
}
```

The decision engine must be pure and deterministic. It receives samples, policy, time, and current state. It does not access UI, HealthKit, Bluetooth, APNs, or the LLM.

### Emergency dispatcher

The emergency dispatcher must:

- Be callable without the LLM.
- Persist the pending emergency event before starting escalation.
- Provide a cancellable countdown where policy permits.
- Handle duplicate trigger suppression.
- Resume or reconcile after relaunch.
- Record the final outcome without storing unnecessary health values.
- Keep family notification delivery separate from carrier emergency calling.

### Acceptance gates

- Identical inputs produce identical decisions.
- A single malformed sample cannot trigger escalation.
- Stale samples cannot trigger a new emergency.
- Repeated samples obey persistence and cooldown policy.
- A pending escalation survives app termination.
- Cancellation is persisted before the user is told it succeeded.
- The decision path does not initialize or call the LLM.
- Failures produce explicit states instead of silent success.

---

## 7. Phase 4: notification and caregiver alert reliability

### Objective

Replace the current APNs stub and make caregiver alerting durable without exposing health data.

### Current defect

`APNsProvider.sendPush` currently prints a token prefix and returns `true`. This must not remain in any safety path.

### Target transport

```text
Parent app
  -> create minimal alert event
  -> encrypt envelope with caregiver session
  -> durable local outgoing queue
  -> broker upload
  -> provider push contains wake-up only
  -> caregiver app fetches ciphertext
  -> caregiver app decrypts and displays alert
```

The broker must never receive:

- Health values.
- Medication names.
- Contact display names.
- Raw transcripts.
- Voice audio.

### Required alert queue behavior

The parent-side queue needs:

- Durable storage.
- Per-recipient delivery state.
- Retry schedule with bounded backoff.
- Maximum retention period.
- Duplicate envelope identity.
- Acknowledgement state.
- Broker-unavailable state.
- User-visible “caregiver notification pending/failed” state where appropriate.

Emergency carrier calling must not wait for this queue.

### Notification actions

Implement `UNUserNotificationCenterDelegate` and explicit categories for:

- Medication acknowledgement.
- Medication refusal or “not now.”
- Emergency countdown cancellation.
- Caregiver check-in response.
- Health monitoring interrupted.

Persist the action before announcing success.

### Critical alerts

Treat Critical Alerts as a separate entitlement and App Review workstream. `.defaultCritical` does not by itself establish permission or entitlement.

Acceptance gates:

- Failed provider delivery is reported as failure.
- Retry state survives relaunch.
- The parent app never directly impersonates APNs provider infrastructure.
- Notification payloads contain no health values.
- An emergency call remains possible when the broker is unavailable.

---

## 8. Phase 5: Apple Watch integration

### Objective

Use Apple Watch data without making a custom watch app a prerequisite for the parent app.

### Stage 1: HealthKit-only Watch support

- Read Apple Watch samples through HealthKit.
- Display source/device provenance where useful.
- Tell the user when the latest reading is old or unavailable.
- Do not assume that Watch presence means continuous monitoring.
- Do not trigger emergency behavior from an unqualified single sample.

### Stage 2: WatchConnectivity companion

Add a watchOS target only for a concrete workflow:

- Medication acknowledgement.
- “I need help” action.
- Caregiver-defined check-in.
- Complication showing the next routine.
- Short active-monitoring session.

Use `WatchConnectivity` for commands and state, not as the health database.

Reference:

[WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity)

### Watch message model

All messages must be versioned and idempotent:

```swift
struct WatchMessage: Codable, Equatable {
    let schemaVersion: Int
    let messageID: UUID
    let kind: Kind
    let createdAt: Date
    let payload: Payload
}
```

No raw health values should be sent over WatchConnectivity unless a specific feature requires it and the data is protected by the app's privacy policy.

### Acceptance gates

- Parent app works without a paired Watch.
- Watch disconnection produces an honest state.
- Messages can arrive out of order or more than once without duplicating actions.
- Medication acknowledgement is durable and idempotent.
- Watch actions do not bypass voice-biometric/PIN rules for sensitive operations.

---

## 9. Phase 6: Bluetooth peripherals

### Objective

Support a small, validated set of health peripherals through a common adapter contract.

### Integration priority

1. Devices whose companion apps already write to HealthKit.
2. Standard Bluetooth SIG health profiles.
3. Vendor SDKs only when necessary.

Do not begin with a general-purpose Bluetooth scanner.

### Initial device recommendation

Choose exactly one first device category:

- Blood-pressure cuff, or
- Pulse oximeter.

The category should be selected based on availability of a testable device, stable standard profile, and clear clinical/product use case.

### Adapter contract

```swift
protocol HealthPeripheral {
    var identifier: String { get }
    var displayName: String { get }
    var capabilities: Set<PeripheralCapability> { get }

    func connect() async throws
    func disconnect()
    func readMeasurements() async throws -> [HealthSample]
}
```

The adapter must never emit raw characteristic bytes outside the peripheral module.

### Pairing and discovery

Use AccessorySetupKit on iOS 18 and later, with a CoreBluetooth fallback for iOS 16/17.

References:

- [AccessorySetupKit](https://developer.apple.com/documentation/accessorysetupkit)
- [CoreBluetooth](https://developer.apple.com/documentation/corebluetooth)

Add:

- `NSBluetoothAlwaysUsageDescription`.
- Known service UUID filtering.
- State restoration.
- Reconnection policy.
- Pairing removal.
- Device rename/support flow.
- Device unavailable state.
- Secure characteristic validation.

### Peripheral security

Validate:

- Expected service and characteristic UUIDs.
- Pairing/authentication state.
- Payload length and encoding.
- Numeric range.
- Unit.
- Timestamp.
- Device identity.
- Duplicate measurement identity.

A connected device is not automatically a trusted medical source.

### Acceptance gates

- The app does not scan continuously without a user-facing reason.
- Pairing succeeds and can be removed.
- Reconnection succeeds after app suspension where iOS allows it.
- Offline peripherals do not block the parent app.
- Measurements are normalized into the same `HealthSample` model as HealthKit.
- Invalid device payloads are rejected and observable without logging raw data.
- Background behavior is tested on physical devices, not only the simulator.

---

## 10. Phase 7: App Intents, widgets, and system surfaces

### Objective

Make the assistant discoverable across iOS without replacing the app's own Nepali voice pipeline.

Apple reference:

[App Intents](https://developer.apple.com/documentation/appintents)

### Initial App Intents

Expose a small set of safe, deterministic actions:

- Open assistant.
- Read today's routine.
- Create a general reminder.
- Acknowledge a medication.
- Call a configured family contact.
- Start a caregiver check-in.
- Read the latest available health summary.

Sensitive actions must retain confirmation and authentication policy.

### Widgets and controls

Recommended first widgets:

- Next routine item.
- Medication acknowledgement state.
- “Talk to assistant” launch control.
- Health monitoring status: active, unavailable, or permission needed.

Do not put raw heart-rate or blood-pressure values in a lock-screen surface by default. The caregiver chooses whether a health summary is visible in the caregiver app.

### Accessibility and language

App Intents should supplement, not replace:

- In-app Nepali voice commands.
- Localized spoken feedback.
- Large touch targets.
- Voice-driven navigation.
- Honest offline responses.

Do not promise that Siri can understand Nepali simply because an App Intent exists.

---

## 11. Phase 8: background execution and entitlement hardening

### Objective

Make the declared iOS capabilities match actual behavior and remove unsupported assumptions.

### `Info.plist` audit

Review every current background mode:

- `audio`
- `fetch`
- `processing`
- `push-to-talk`
- `remote-notification`
- `voip`

For each mode, document:

- The exact feature requiring it.
- The corresponding entitlement.
- The lifecycle callback or framework code using it.
- App Review justification.
- Battery impact.
- Failure behavior when the OS does not grant runtime time.

Remove modes that are not justified by a real feature.

### Background-task rules

- Local notifications remain the primary mechanism for scheduled reminders.
- HealthKit observer delivery is the primary mechanism for health changes.
- `BGAppRefreshTask` is a refresh opportunity, not a schedule guarantee.
- `BGProcessingTask` is for reconciliation and maintenance, not continuous monitoring.
- A background task that cannot complete must report failure and leave durable state for retry.
- Every task must have an expiration handler.

### Acceptance gates

- Every permitted task identifier has a registered handler or is removed.
- Task handlers are idempotent.
- Task expiration leaves no corrupt state.
- Background delivery failure is visible to the monitoring state machine.
- Physical-device tests cover locked screen, terminated app, low-power mode, Focus/DND, and network loss.

---

## 12. Phase 9: privacy, security, and medical-data controls

### Health data minimization

- Request only required HealthKit read types.
- Do not send health data to Gemini or any cloud AI path.
- Do not include health values in push notifications.
- Do not include medication names in caregiver envelopes unless a later approved policy explicitly requires them.
- Avoid storing full raw HealthKit history locally.
- Provide deletion and revocation behavior.
- Document what remains in HealthKit versus local storage.

### Logging policy

The current sanitization architecture must be enforced at every output path.

Remove or route through the sanitized bus:

- Raw LLM output previews.
- Raw transcripts in lock-screen notifications.
- Device-token prefixes in `print` statements.
- Health values.
- Medication names.
- Contact display names.

Use stable hashes or event categories instead.

### Configuration security

Health policies received from the caregiver channel must be:

1. Authenticated and decrypted.
2. Schema validated.
3. Version checked.
4. Range checked.
5. Applied atomically.
6. Recorded as a configuration revision.
7. Acknowledged only after successful application.

A malformed policy must leave the previous policy active.

### App Store readiness

Before any health-related release:

- HealthKit capability and usage descriptions are accurate.
- Privacy policy accurately describes collection and use.
- Health data is not used for advertising.
- Medical claims are reviewed and scoped.
- Critical Alerts entitlement status is explicit.
- Health data deletion and permission-revocation behavior is documented.
- The app does not claim guaranteed emergency response where iOS cannot guarantee execution or delivery.

---

## 13. Testing strategy

### Unit tests

Pure tests should cover:

- Health unit conversion.
- Sample identity and deduplication.
- Freshness classification.
- Stale-data handling.
- Paired blood-pressure validation.
- Threshold validation.
- Hysteresis.
- Persistence windows.
- Cooldown behavior.
- Safety decision precedence.
- Configuration schema validation.
- GATT decoding.
- Watch message idempotency.
- Alert envelope construction without PII.

### Integration tests with fakes

Use fake providers for:

- HealthKit authorization and queries.
- Observer delivery.
- Anchored query pages.
- Deleted samples.
- Bluetooth connection state.
- Peripheral payloads.
- Watch messages.
- Notification center.
- Emergency dispatcher.
- Caregiver alert queue.

### Physical-device tests

Required before claiming platform support:

- iPhone with permission granted.
- iPhone with permission revoked.
- Apple Watch paired and disconnected.
- Bluetooth device paired and unavailable.
- Screen locked.
- App terminated.
- Low Power Mode.
- Focus/DND.
- No network.
- Broker unavailable.
- Device restart.
- Time-zone change.
- Daylight-saving transition.
- Background delivery delayed.

### Safety-path invariants

Every safety test should prove:

- No LLM invocation.
- No network dependency for local escalation.
- Durable state before user-facing success.
- No duplicate emergency event.
- No raw health data in logs.
- No partial configuration application.
- Clear failure state when an external dependency is unavailable.

---

## 14. Delivery sequence and work breakdown

### Workstream A — contracts and extraction

- Add domain health/safety models.
- Add provider protocols.
- Add fake providers.
- Create the capability registry.
- Keep behavior unchanged.

### Workstream B — HealthKit read-only

- Add capability and permission descriptions.
- Implement heart rate and blood pressure reads.
- Wire `health_query` to the local provider.
- Add English/Nepali responses.
- Add permission and no-data UI.

### Workstream C — HealthKit observation

- Add observer queries.
- Add anchored queries.
- Persist anchors.
- Add foreground reconciliation.
- Add stale and permission-revoked states.

### Workstream D — deterministic safety

- Implement freshness/quality policies.
- Implement threshold validation.
- Implement pure decision engine.
- Add durable safety events.
- Add emergency dispatcher independent of LLM.

### Workstream E — alert reliability

- Replace APNs stub with broker-backed transport.
- Add durable outgoing queue.
- Add notification action delegate.
- Add retry and failure states.
- Add caregiver acknowledgement.

### Workstream F — Apple Watch

- Consume Watch-originated HealthKit samples.
- Add WatchConnectivity only for a selected workflow.
- Add idempotent message handling.
- Add watch disconnection UX.

### Workstream G — Bluetooth

- Select one real device category.
- Implement one adapter.
- Add AccessorySetupKit path for iOS 18+.
- Add CoreBluetooth compatibility path for iOS 16/17.
- Add reconnection and validation.

### Workstream H — system surfaces and release hardening

- Add App Intents.
- Add widgets/controls.
- Audit background modes and entitlements.
- Enforce PII logging policy.
- Complete HealthKit/App Store privacy review.

Do not start Workstream G before Workstreams A–D have stable domain contracts.

---

## 15. Release gates

The iOS product must not claim health monitoring or emergency protection until all of the following are true:

- HealthKit read path is implemented and physically verified.
- Background observation and foreground reconciliation are implemented.
- Permission revocation and stale-data states are user-visible.
- Safety decisions are deterministic and LLM-independent.
- Emergency events are durable across termination/relaunch.
- Local escalation does not depend on broker delivery.
- Caregiver alert delivery has a real failure signal and retry queue.
- No health PII reaches logs, lock-screen notifications, Gemini, or unencrypted transport.
- Physical-device tests cover expected iOS lifecycle failures.
- Medical thresholds and product claims receive domain review.
- App Store entitlements, usage descriptions, and privacy disclosures match actual behavior.

---

## 16. Explicit non-goals

This plan does not propose:

- Replacing Apple Health with a private health database.
- Building a generic Bluetooth device marketplace.
- Treating an iPhone background task as a 24/7 daemon.
- Using the LLM for medical diagnosis or emergency decisions.
- Making an Apple Watch mandatory.
- Making the caregiver app a prerequisite for daily voice operation.
- Sending health data to cloud AI services.
- Adding Android implementation work.

## Final recommendation

Implement one complete vertical slice before expanding breadth:

```text
HealthKit heart rate + blood pressure
        -> normalized HealthSample
        -> spoken local query
        -> observer/anchored recovery
        -> deterministic freshness policy
        -> tested safety decision engine
        -> durable local alert event
```

Only after this path is correct should the project add Apple Watch actions, Bluetooth cuffs, widgets, or broader health metrics. This sequence creates a safe, reusable Apple platform layer and prevents the project from accumulating superficial integrations that cannot support the promised senior safety experience.
