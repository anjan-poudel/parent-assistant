# Elderly AI Assistant — Installation Guide

## Prerequisites

### Hardware
- iPhone 12 or newer (iOS 16.0+), OR
- Android phone with 6GB+ RAM, Android 8.0+ (API 26+)

### For iOS Building (macOS only)
- Mac with macOS 14+ (Sonoma)
- Xcode 15+ from the Mac App Store
- XcodeGen — `brew install xcodegen` (generates `ElderlyAssistant.xcodeproj` from `ios/project.yml`)
- Apple Developer account (free tier works for personal device install)

### For Android Building (macOS / Windows / Linux)
- JDK 17+ (`brew install openjdk@17` on macOS)
- Android Studio (or Android SDK command-line tools)
- USB cable for device install

---

## iOS — Build and Install on iPhone

### Step 1: Generate and open the Xcode project

```bash
cd ios
./build.sh generate     # runs XcodeGen on project.yml
open ElderlyAssistant.xcodeproj
```

`ios/project.yml` is the source of truth for target structure, sources,
Info.plist, and schemes. Do NOT edit `ElderlyAssistant.xcodeproj/project.pbxproj`
by hand — change `project.yml` and re-run `./build.sh generate`.

### Step 2: Configure signing

1. In Xcode, select the project → Signing & Capabilities
2. Check "Automatically manage signing"
3. Select your Apple ID as the Team
4. Change Bundle Identifier if needed (must be unique)

### Step 3: Add required capabilities

In Signing & Capabilities, add:
- **Background Modes**: Audio, AirPlay, Voice over IP, Background processing, Background fetch
- **HealthKit**: Enable

### Step 4: Build and run

1. Connect your iPhone via USB cable
2. Select your device from the scheme dropdown (top of Xcode window)
3. Press Cmd+R to build and run
4. On first run, on your iPhone: Settings → General → VPN & Device Management → Trust your developer certificate

### Step 5: Using the build script (alternative)

```bash
cd ios

# Build only
./build.sh build

# Build IPA for manual install
./build.sh ipa

# Run unit tests
./build.sh test
```

---

## Android — Build and Install on Phone

### Step 1: Set up Android SDK

```bash
# Set ANDROID_HOME (add to ~/.zshrc)
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/tools
```

If you don't have the Android SDK:
1. Install Android Studio: https://developer.android.com/studio
2. Open Android Studio → SDK Manager → Install Android SDK Platform 34

### Step 2: Enable USB debugging on your phone

1. Settings → About Phone → Tap "Build number" 7 times
2. Settings → Developer Options → Enable "USB Debugging"
3. Connect phone to computer via USB cable
4. Accept the "Allow USB debugging?" prompt on phone

### Step 3: Build and install

```bash
cd android

# Build and install in one command
./build.sh install

# Or step by step:
./build.sh build    # Build debug APK
./build.sh install  # Install on connected device
./build.sh test     # Run unit tests
```

### Step 4: Grant permissions on first launch

When you first open the app, grant these permissions:
- **Microphone**: Required for voice commands
- **Camera**: Optional — for medication photo verification
- **Health Connect**: Required for health monitoring
- **Notifications**: Required for medication reminders
- **Display over other apps**: Optional — for emergency announcements
- **Exact Alarms**: Required — for timely medication reminders

### Step 5: Verify installation

1. Find "Elderly Assistant" on your home screen
2. Open the app — you should see the main UI with "Say Hey Sahayak to begin"
3. Swipe down to see the persistent notification "Listening for Hey Sahayak..."
4. The medication scheduler restores any pending reminders on launch

---

## Verifying the Medication Scheduler

### Test that reminders fire

The medication scheduler is a safety-critical service that runs independently of the AI/LLM. To verify it works:

1. **Configure a test medication** (via in-app config or companion app):
   - Medication name: "Test Reminder"
   - Time: Set 2 minutes from now
   - Dose: "One tablet"

2. **Verify the reminder fires**:
   - At the scheduled time, a notification appears on screen
   - On Android: a foreground notification with sound
   - On iOS: a local notification with sound

3. **Verify escalation**:
   - Do not acknowledge the reminder
   - After the acknowledgement window (default 5 min), it re-fires
   - After 5 re-fires over 60 minutes, family alert is triggered

4. **Verify persistence**:
   - Schedule a reminder
   - Force-kill the app (swipe it away)
   - Re-launch the app
   - The reminder should still fire (recovered from encrypted storage)

### Run automated tests

```bash
# iOS
cd ios && ./build.sh test

# Android
cd android && ./build.sh test
```

---

## Project Structure

```
elderly-ai-assistant/
├── ios/
│   ├── ElderlyAssistant/
│   │   ├── App/                          # App entry, coordinator, views
│   │   │   ├── ElderlyAssistantApp.swift
│   │   │   ├── AppCoordinator.swift      # Service wiring
│   │   │   └── ContentView.swift
│   │   ├── Services/
│   │   │   ├── MedicationScheduler/      # Safety-critical (no LLM dep)
│   │   │   │   ├── Models.swift
│   │   │   │   ├── DependencyProtocols.swift
│   │   │   │   ├── EscalationEngine.swift
│   │   │   │   ├── ConfirmationChallenge.swift
│   │   │   │   ├── DoubleDoseDetector.swift
│   │   │   │   ├── MedicationScheduler.swift
│   │   │   │   ├── MedicationSchedulerProtocol.swift
│   │   │   │   ├── PlatformAlarmScheduler.swift
│   │   │   │   └── PhotoVerifier.swift
│   │   │   └── FamilyNotifier/
│   │   │       └── FamilyNotifier.swift
│   │   └── Info.plist
│   ├── ElderlyAssistantTests/            # Unit tests
│   └── build.sh
├── android/
│   ├── app/
│   │   ├── build.gradle
│   │   └── src/
│   │       ├── main/
│   │       │   ├── AndroidManifest.xml
│   │       │   ├── java/com/elderlyassistant/
│   │       │   │   ├── ElderlyAssistantApp.kt
│   │       │   │   ├── MainActivity.kt
│   │       │   │   └── services/
│   │       │   │       ├── AssistantForegroundService.kt
│   │       │   │       ├── medication/
│   │       │   │       │   ├── Models.kt
│   │       │   │       │   ├── DependencyProtocols.kt
│   │       │   │       │   ├── EscalationEngine.kt
│   │       │   │       │   ├── ConfirmationChallenge.kt
│   │       │   │       │   ├── DoubleDoseDetector.kt
│   │       │   │       │   ├── MedicationScheduler.kt
│   │       │   │       │   ├── PlatformAlarmScheduler.kt
│   │       │   │       │   ├── PhotoVerifier.kt
│   │       │   │       │   ├── BootReceiver.kt
│   │       │   │       │   └── PreferencesEncryptedStorage.kt
│   │       │   │       └── family/
│   │       │   │           ├── FamilyNotifier.kt
│   │       │   │           └── FCMService.kt
│   │       │   └── res/
│   │       │       ├── layout/activity_main.xml
│   │       │       ├── values/strings.xml
│   │       │       ├── values/themes.xml
│   │       │       └── xml/network_security_config.xml
│   │       └── test/                    # Unit tests
│   ├── build.gradle
│   ├── settings.gradle
│   ├── gradle.properties
│   └── build.sh
├── docs/
│   └── medication-scheduler-implementation-plan.md
└── requirements.md
```

---

## Troubleshooting

### iOS build fails with signing error
- Xcode → Preferences → Accounts → Add your Apple ID
- Project → Signing & Capabilities → Set Team to your account
- Change Bundle Identifier to something unique

### Android "device not found"
- Check USB cable (some cables are charge-only)
- Run `adb devices` — should show your device
- Toggle USB Debugging off/on in Developer Options
- On macOS: install Android File Transfer for MTP support

### Medication reminders not firing on Android
- Grant "Exact Alarm" permission: Settings → Apps → Elderly Assistant → Permissions → Alarms & reminders → Allow
- Disable battery optimization: Settings → Apps → Elderly Assistant → Battery → Unrestricted
- The foreground service notification must remain visible

### Medication reminders not firing on iOS
- The app must have been run at least once in the foreground
- Background App Refresh must be enabled: Settings → General → Background App Refresh
- Local notifications must be allowed: Settings → Elderly Assistant → Notifications → Allow
