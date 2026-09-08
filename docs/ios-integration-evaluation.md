# iOS Integration Evaluation

## Executive assessment

The iOS project has a solid voice-assistant foundation, but it is not yet an iOS health/safety platform.

### Strong foundation already present

- Native SwiftUI architecture rather than a generic cross-platform abstraction.
- On-device speech/model pipeline using WhisperKit/CoreML/ANE and LLaMA.
- Good protocol seams around reminders, contacts, calendar scanning, storage, notifications, and observability.
- EventKit integration for Calendar and Reminders.
- Contacts integration through `CNContactStore`.
- Core Location integration for weather/navigation.
- Local notification scheduling and background-task registration.
- Encrypted local storage and explicit PII sanitization intent.
- Voice commands for reminders, calls, messages, calendar, navigation, appliance guidance, and emergency intent routing.

Relevant code:

- `ios/ElderlyAssistant/App/AppCoordinator.swift`
- `ios/ElderlyAssistant/Services/Voice/`
- `ios/ElderlyAssistant/Services/MedicationScheduler/`
- `ios/ElderlyAssistant/Services/ExternalCalendar/`
- `ios/ElderlyAssistant/Services/Contacts/`

### Critical gaps

The following are currently absent from the iOS target:

- No concrete `HealthKit` implementation.
- No `HKHealthStore`, observer queries, anchored queries, or background HealthKit delivery.
- No `CoreBluetooth` implementation.
- No Apple Watch target or `WatchConnectivity`.
- No sensor normalization layer.
- No health-monitoring service.
- No hardened health-triggered emergency dispatch module.
- No production APNs provider.
- No implemented remote-config broker.

The repository's own review confirms that FR-031–FR-037, the health and emergency safety path, are effectively unimplemented: `docs/review-2026-08-30.md:65-67`.

The project should not yet describe itself as providing continuous health monitoring or emergency protection. It has reminder infrastructure and safety-oriented intent routing, but not the data acquisition and dispatch path required to make those claims.

---

## 1. Make HealthKit the primary health integration

Do not start with arbitrary Bluetooth scanning. Start with HealthKit.

Apple positions HealthKit as the central, permission-controlled repository for iPhone and Apple Watch health data:

[Apple HealthKit documentation](https://developer.apple.com/documentation/healthkit)

HealthKit should be the first source for:

- Heart rate.
- Resting heart rate.
- Blood pressure systolic/diastolic.
- Oxygen saturation where available.
- Respiratory rate.
- Step count and activity.
- Walking steadiness or mobility-related metrics.
- Weight.
- Medication-related data only if the product has a clear reason to read or write it.

Do not request every health type. Request only the types needed by a specific feature.

### Recommended HealthKit architecture

Do not add health code to `AppCoordinator.swift`. It is already approximately 195 KB and functions as a composition root/god object. Adding HealthKit, Bluetooth, watch, and threshold logic there will make the future caregiver split harder.

Create a separate platform layer:

```text
Services/
  Health/
    HealthDataProvider.swift
    HealthKitDataProvider.swift
    HealthPermissionState.swift
    HealthSample.swift
    HealthSampleNormalizer.swift
    HealthObservationCoordinator.swift
    HealthFreshnessPolicy.swift
    HealthSafetyMonitor.swift
    HealthQueryService.swift
```

Use protocol boundaries:

```swift
protocol HealthDataProviding {
    func requestReadAuthorization() async throws
    func latestHeartRate() async throws -> HealthSample?
    func latestBloodPressure() async throws -> BloodPressureReading?
    func observeChanges() async throws
}
```

The production implementation owns `HKHealthStore`. Tests use a fake provider.

The app-facing model should not expose raw HealthKit objects:

```swift
struct HealthSample: Codable, Equatable {
    enum Metric: String, Codable {
        case heartRate
        case systolicBloodPressure
        case diastolicBloodPressure
        case oxygenSaturation
        case respiratoryRate
    }

    let metric: Metric
    let value: Double
    let unit: String
    let startDate: Date
    let endDate: Date
    let sourceName: String?
    let deviceName: String?
}
```

This separation is important because:

- HealthKit types should not cross concurrency boundaries.
- Sensors use different units and timestamps.
- Caregiver configuration should operate on stable serializable models.
- The future parent/caregiver split needs a stable domain contract.

### Use incremental HealthKit queries

Use:

- `HKObserverQuery` to learn that new data exists.
- `HKAnchoredObjectQuery` to fetch only new or deleted samples.
- `HKHealthStore.enableBackgroundDelivery` for supported data types.
- Persist the anchor and last successful observation time.

References:

- [HKObserverQuery](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [HKAnchoredObjectQuery](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)
- [HealthKit background delivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))

Do not repeatedly issue large date-range queries. That wastes battery, increases duplicate processing, and complicates recovery.

---

## 2. Do not treat HealthKit as a real-time emergency channel

HealthKit background delivery is not equivalent to a guaranteed real-time stream. A heart-rate sample may arrive late. The user may revoke permission. The Apple Watch may be off-wrist, disconnected, charging, or out of range. The iPhone may be suspended.

Every health reading needs:

- Sample timestamp.
- Ingestion timestamp.
- Source/device identity.
- Freshness classification.
- Unit normalization.
- Data-quality status.
- Duplicate identity.
- Whether the sample is measured, imported, or derived.

A safety rule should never be:

```text
heart rate > threshold -> call emergency services
```

It should be closer to:

```text
fresh trusted sample
+ clinically validated threshold
+ persistence or repeated observation
+ user context
+ explicit emergency policy
-> safety response
```

Even then, thresholds should be treated as alert heuristics, not diagnoses.

### Recommended safety pipeline

```text
HealthKit / BLE / Watch
        |
        v
HealthSampleNormalizer
        |
        v
Freshness + quality policy
        |
        v
HealthSafetyMonitor
        |
        v
Hardened SafetyDecisionEngine
        |
        +--> local voice alert
        +--> local notification
        +--> emergency call path
        +--> durable caregiver alert queue
```

The LLM must not be in this path.

The existing `CommandRouter` emergency keyword net is useful as a voice-input safeguard, but it is not a health-monitoring implementation. Health threshold evaluation should be deterministic and independently testable.

---

## 3. Apple Watch should be the first peripheral

You do not initially need a custom watch app to benefit from Apple Watch data.

The first approach should be:

1. User grants HealthKit read permission.
2. Apple Watch writes heart-rate/activity samples into HealthKit.
3. iPhone reads and interprets those samples.
4. The parent app speaks the result in the configured language.
5. The caregiver app receives only the minimum alert state required.

This is simpler and more reliable than building a watchOS app immediately.

### Add a watchOS app later for specific capabilities

Build a watch companion only when you need:

- Immediate medication acknowledgement from the wrist.
- A caregiver-configurable watch complication.
- A custom “I need help” action.
- A short-lived active monitoring session.
- Faster watch-to-phone state transfer.
- A large wrist-based status surface.

Use `WatchConnectivity` for user-visible state and commands, not as a replacement for HealthKit storage:

[WatchConnectivity documentation](https://developer.apple.com/documentation/watchconnectivity)

A watch app should not be treated as an always-on emergency monitor. Battery, watch placement, Bluetooth range, watchOS scheduling, and user behavior all limit that assumption.

For live heart-rate monitoring, an active workout/session model may be required. That is substantially different from passively reading HealthKit samples and should be designed as a separate feature.

---

## 4. Add Bluetooth through a device-adapter layer

Bluetooth should be a second-stage integration, not the first health path.

Use this order of preference:

### Tier 1: HealthKit-compatible vendor devices

Prefer cuffs, scales, pulse oximeters, and other devices whose companion apps already write validated data into HealthKit.

Advantages:

- Less GATT implementation.
- Less pairing complexity.
- Better device compatibility.
- Health data remains in Apple's health data model.
- Easier caregiver and Health app interoperability.

### Tier 2: Standard Bluetooth health profiles

For devices that must connect directly, support standards-based GATT profiles first:

- Blood Pressure Service.
- Pulse Oximeter Service.
- Weight Scale Service.
- Health Thermometer Service.
- Glucose Service where appropriate.

Do not build a generic “scan every Bluetooth device” feature.

Create a registry:

```text
Services/
  Peripherals/
    PeripheralDevice.swift
    PeripheralDeviceRegistry.swift
    BluetoothTransport.swift
    GATTValueDecoder.swift
    BloodPressurePeripheral.swift
    PulseOximeterPeripheral.swift
    WeightScalePeripheral.swift
```

Every adapter should produce the same domain-level `HealthSample` model as HealthKit.

### Tier 3: Vendor SDKs

Only add a vendor SDK when:

- The device cannot provide data through HealthKit.
- The device's standard GATT data is insufficient.
- The vendor provides a stable, supported iOS SDK.
- The device is clinically appropriate for your intended use.

### Use AccessorySetupKit where possible

`AccessorySetupKit` is available from iOS 18 and provides privacy-preserving accessory discovery and configuration:

[AccessorySetupKit documentation](https://developer.apple.com/documentation/accessorysetupkit)

The project currently targets iOS 16, so use:

```swift
if #available(iOS 18.0, *) {
    // AccessorySetupKit path
} else {
    // CoreBluetooth fallback
}
```

AccessorySetupKit should become the modern pairing path. CoreBluetooth remains the compatibility layer for older supported devices.

CoreBluetooth background behavior is constrained and must not be treated as unlimited background execution:

[Core Bluetooth documentation](https://developer.apple.com/documentation/corebluetooth)

Add Bluetooth only when you also add:

- `NSBluetoothAlwaysUsageDescription`.
- Connection restoration.
- Reconnect policy.
- Peripheral offline detection.
- Data freshness rules.
- Payload validation.
- Unit validation.
- Duplicate handling.
- Pairing/authentication handling.
- A clear user-facing “device unavailable” state.

---

## 5. Current iOS background configuration needs an audit

`Info.plist` currently declares:

```text
audio
fetch
processing
push-to-talk
remote-notification
voip
```

It also declares:

```text
com.elderlyassistant.health.monitor
```

as a permitted background-task identifier.

However:

- No health monitor is registered.
- `AppCoordinator.registerBackgroundTasks()` registers medication and calendar work, not health monitoring.
- The current implementation relies on local notifications and scheduled background refreshes.
- `BGTaskScheduler` does not provide an arbitrary always-running process.

The current `AppCoordinator` comment says it starts a health monitor, but the coordinator has no concrete health-monitor service wired into its initialization.

Do not claim “24/7 heart-rate monitoring” based on `BGProcessingTask`, `BGAppRefreshTask`, or `audio` background mode.

Use HealthKit observer/background delivery for data changes, local notifications for scheduled safety events, and background tasks for reconciliation and repair.

[Apple BackgroundTasks documentation](https://developer.apple.com/documentation/backgroundtasks)

Audit every declared background mode against actual product behavior. Over-declaring `voip`, audio, or other modes increases App Review risk and creates misleading operational assumptions.

---

## 6. Notification and emergency integration need hardening

The current notification architecture has a serious safety gap.

`ios/ElderlyAssistant/Services/FamilyNotifier/FamilyNotifier.swift` contains an `APNsProvider` whose `sendPush` method prints a message and returns `true` without delivering anything.

The intended architecture in `docs/remote-config-channel-design.md` is the right direction:

```text
Parent app
   -> encrypt alert envelope
   -> broker relay
   -> APNs/FCM wake-up
   -> caregiver app fetches and decrypts
```

The parent app should never directly send APNs requests using a caregiver device token.

For local safety notifications:

- Implement `UNUserNotificationCenterDelegate`.
- Handle medication action responses explicitly.
- Persist acknowledgement before reporting success.
- Use notification categories and actions.
- Add Critical Alerts only after obtaining the entitlement and App Store approval.
- Do not assume `.defaultCritical` alone creates a critical alert.

Current onboarding requests only ordinary alert/sound permissions. The critical-alert path needs separate product, entitlement, and review work.

---

## 7. Use App Intents, but do not depend on Siri for Nepali

App Intents can expose actions to:

- Siri.
- Shortcuts.
- Spotlight.
- Widgets.
- Controls.
- Action Button.
- Apple Watch hardware actions.

[App Intents documentation](https://developer.apple.com/documentation/appintents)

Good App Intent candidates:

- Acknowledge medication.
- Ask for today's routine.
- Open the voice assistant.
- Start a guided appliance session.
- Call a configured family contact.
- Create a reminder.
- Read the latest available health summary.
- Trigger a caregiver check-in.

However, App Intents do not solve Nepali voice recognition. Siri language support and intent resolution are controlled by Apple. The app's own on-device voice pipeline must remain the canonical interface for Nepali and other underserved languages.

Use App Intents as a system integration layer, not as the primary language interface.

---

## 8. Preserve the strongest existing iOS integrations

The existing EventKit and Contacts work uses a good pattern:

- Thin Apple-framework adapter.
- Value-type snapshots.
- Pure mapping logic.
- Fakes for tests.
- Point-of-use permission prompts.
- Honest partial-access status.

Apply this exact pattern to HealthKit and Bluetooth.

The current EventKit design is particularly good because the app keeps its own scheduler as the source of truth and treats Calendar as a mirror. Use the same principle for health:

- HealthKit remains the source of truth for imported health data.
- The app stores only normalized samples, anchors, derived summaries, and safety events.
- Do not duplicate the entire HealthKit database locally.
- Do not write to HealthKit unless there is a clear user-facing need.

---

## 9. Recommended implementation sequence

### Phase 1 — HealthKit vertical slice

Build only:

- Heart-rate read.
- Blood-pressure read.
- Permission state.
- Latest-value query.
- Spoken response.
- Honest “not available” response.
- No emergency automation yet.

Acceptance:

```text
"मेरो मुटुको धड्कन कति छ?"
```

returns:

- Latest trustworthy value with timestamp, or
- “Health data is unavailable,” without inventing a value.

### Phase 2 — Background observation

Add:

- Observer queries.
- Anchored queries.
- Persisted anchors.
- Background delivery.
- Reconciliation on foreground.
- Permission-revoked detection.
- Stale-data detection.

Test:

- Permission denied.
- Permission revoked in Settings.
- Health data deleted externally.
- Duplicate samples.
- App killed and relaunched.
- Watch disconnected.
- No new data for a configured period.
- Device clock/time-zone changes.

### Phase 3 — Safety decision engine

Add:

- Threshold validation.
- Minimum sample freshness.
- Repeated-reading policy.
- Hysteresis.
- Durable safety-event storage.
- Local voice warning.
- Cancel window.
- Independent emergency dispatcher.
- Durable caregiver-alert queue.

Do not pass readings through the LLM.

### Phase 4 — Apple Watch

Add a watchOS target only for a demonstrated product need:

- Wrist acknowledgement.
- Complication.
- Immediate help action.
- Active monitoring session.

Use HealthKit as the health-data authority and WatchConnectivity for app state/control.

### Phase 5 — Bluetooth peripherals

Start with one validated blood-pressure cuff or pulse oximeter.

Prove:

- Pairing.
- Reconnection.
- Offline behavior.
- Measurement validation.
- HealthKit write/read policy.
- Caregiver visibility.
- Battery behavior.
- Background behavior.

Then expand through the adapter registry.

### Phase 6 — System surfaces

Add:

- App Intents.
- Widgets and controls.
- Action Button integration.
- Watch complication.
- Live Activity only where it conveys useful, non-sensitive current state.
- Caregiver-app notification handoff.

---

## 10. Highest-priority risks to resolve

1. HealthKit is currently absent despite being central to the product promise.
2. The declared health background task is not implemented.
3. The APNs provider returns success without delivering alerts.
4. The emergency health path is not isolated because it does not yet exist.
5. The app currently has an oversized `AppCoordinator`; new platform integrations should not increase its responsibilities.
6. The constitution says all AI is on-device, while the iOS project has Gemini cloud and vision paths. Health data must never reach those paths.
7. The app's current audio/background configuration needs an App Review and battery audit.
8. The project targets iOS 16, while AccessorySetupKit requires an iOS 18-gated implementation.
9. “Heart-rate monitoring” must be defined precisely: imported HealthKit samples, near-real-time watch data, or active sensor sessions are different capabilities.
10. Clinical defaults and emergency thresholds need medical/safety review before remote caregiver configuration is allowed to control them.

## Bottom line

Build the iOS product as a **local voice runtime plus a typed Apple platform capability layer**:

```text
Voice runtime
   |
Capability layer
   +-- HealthKit
   +-- Apple Watch
   +-- CoreBluetooth / AccessorySetupKit
   +-- EventKit
   +-- Contacts
   +-- Core Location
   +-- UserNotifications
   +-- App Intents
```

HealthKit first, Apple Watch second, BLE third. Keep all sensor ingestion deterministic and independent of the LLM. Treat iOS background execution as constrained, not guaranteed. This gives the project deeper Apple integration without turning `AppCoordinator` into an untestable platform monolith or making the caregiver app dependent on the parent's internal implementation.
