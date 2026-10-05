# L1 Architecture — Profile Interview + Address-as (v1)

**Feature:** `profile-interview` · **Branch:** `feat/profile-interview`
**Task:** `design-l1` (agent `sdd-architect`) · **Contract:** `architecture_l1` → `specs/design-l1.md`
**Date:** 2026-10-05 · **Status:** for review at this task's HIL gate; feeds `design-l2`

**Inputs folded in.** `specs/define-requirements.md` and the locked snapshot
`specs/define-requirements.lock.yaml` (15 FR-PI / 11 NFR-PI, all MUST); the feature
constitution `specs/profile-interview/constitution.md` (Field Contract, Address-as
Behaviour Contract, Feature Constraints 1–7, OD-F1/OD-F2/OD-F3, and the owner
resolutions OD-PI-4 = presets + custom field, OD-PI-5 = plain Settings editor);
project `constitution.md` (Architecture Constraints 1–6, Standards, release gates,
Open Decision 11 B3 and 12); `specs/profile-interview/workflow.yaml`; and the shipped
code this design must match, read for this task:

- `ios/ElderlyAssistant/App/OnboardingState.swift` — 4 steps (`language`, `permissions`, `familyContact`, `models`), per-step status in `UserDefaults`, `pendingSteps` / `firstPendingStep` driving the Home reminder card and the reopen position.
- `ios/ElderlyAssistant/App/OnboardingWizardView.swift` — one step at a time, header Back/Skip, `finishOnboarding()` calls `coordinator.start()`.
- `ios/ElderlyAssistant/Services/Storage/EncryptedFileStorage.swift` + `KeychainEncryptedStorage.swift` + `StoragePlacement.swift` — the encrypted-storage pattern (Application Support / `EncryptedStore`, `.completeFileProtection`, `isExcludedFromBackup`, atomic writes, SHA-256 key filenames, byte-verbatim `RawEncryptedStorage` seam).
- `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` — `FamilyContact` model incl. the existing `isEmergencyContact` flag; `EncryptedLocalStorage` key `family.contacts`.
- `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` — the single shared builder (`build` / `buildChat` / `buildUnderstanding`); byte-mirror contract with `tools/train-intent/seeds/prompt_template.txt`; the 1,024-token on-device context story.
- `ios/ElderlyAssistantTests/Services/Voice/IntentPromptTests.swift` — the pinned character ceiling (3,000 chars for the fixture that measures 2,936).
- `ios/ElderlyAssistant/Services/Voice/VoicePipeline.swift` (`handleWakeDetected`, line 714) — wake detection currently starts capture with **no spoken greeting**; `wakeWordGate` (`WakeWordActivityGate`) gates detection while speaking.
- `ios/ElderlyAssistant/Services/Voice/InputSanitiser.swift` — quarantine level: control-strip, whitespace-collapse, marker removal, clamp to `maxLength` (200); `containsInjectionMarker` / `markerMatches` as the single-sourced detect-only seam.
- `ios/ElderlyAssistant/Services/Voice/Speaker.swift` — `Speaker.speak(_:locale:)`; `PiperVoiceSpeaker` synthesizes (Sherpa VITS) with a `SystemSpeechSpeaker` fallback, deletes its temp WAV after playback (`defer` line 882), applies `ResponsePlaybackModeSeam`.
- `ios/ElderlyAssistant/Services/Voice/SpeakerBiometricService.swift` / `VoiceEnrollmentRecorder.swift` / `Services/Voice/VoiceSettingsModel.swift` (`VoiceEnrollmentSession`) — the existing voice-fingerprint enrollment flow, `VoicePipelineSuspending` cycle, Secure-Enclave persistence.
- `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` (context construction at line 1412; `speakPreAck` fast lane at 3147) and `AppCoordinator.swift` (collapse context at 3601; `addFamilyContact` / `updateFamilyContact(id:…isEmergencyContact:)`; `preferredEmergencyContact(_:)` at 6249).
- `ios/ElderlyAssistant/App/SettingsTabs.swift` + `SettingsView.swift` — the five-tab Settings hub and `SettingsDestination` dispatch (pure tables, unit-pinned).
- `ios/ElderlyAssistant/Services/Observability/LogSanitiser.swift` — allow-list + redacted-keys choke point; `ios/tools/check-release-log-safety.py` — the source-scanning release gate with per-feature scan roots (`FEATURE_ROOTS`).
- `tools/train-intent/seeds/prompt_template.txt` and `tools/train-intent/src/intent_prompt.py` — the seed mirror and the Python renderer that fills its placeholders byte-identically.

**What this document is.** The feature-level L1 architecture for what `profile-interview`
adds or changes inside the shipped brownfield app: module boundaries, data model,
interface contracts (with explicit error types), the address-as integration over the
wake path and the shared prompt builder, the security architecture that feeds the STRIDE
review, the no-regression contract, requirement traceability, and the ADR log resolving
OD-F1, OD-F2, OD-F3 (OD-PI-4 / OD-PI-5 are owner-resolved and carried out here).
It is not a component design (that is `design-l2`) and adds no scope.

---

## 1. Scope and boundary

**In scope (from the locked requirements).** Three new first-run interview steps
(about-you, emergency contacts, voice fingerprint), the family & friends step extended
over the existing store, a new encrypted profile store, address-as injected into the
wake acknowledgment and the brain reply-style rules for both engines, a Settings profile
editor, the wizard reopen path for existing users, profile data made available to the
existing safety paths, and the error/fallback behaviour.

**Explicitly out of scope (unchanged by this design).** Wake-word recognition; any new
network egress or cloud processing; emergency-call logic changes; forcing address-as
into every sentence; new permissions, HealthKit, or voice-biometric mechanism changes;
scheduled auto-activation / daily-briefing copy; remote companion-app push; profile
export/deletion flows.

**No REST/OpenAPI surface is added.** The app has no server component and this feature
adds zero endpoints, request shapes, or payloads (NFR-PI-003). The "interfaces" in this
document are Swift protocols and composition seams inside the iOS app. **No Docker
services, no infrastructure topology change**: the only non-app artefact touched is the
training seed mirror under `tools/train-intent/` (§12).

---

## 2. Component inventory and boundaries

New components (**N**) and changed components (**C**) — everything else in the app is
untouched.

| # | Component | Kind | Responsibility | Lives in |
|---|-----------|------|----------------|----------|
| C01 | `UserProfile`, `UserProfileStore`, `ProfileLoadResult`, `ProfileStoreError` | N | Encrypted single-record profile store (name, address-as, DOB, GP, hospital). Single source of truth; absent/corrupt discrimination; atomic writes; in-memory cache with invalidation on save; no PII in any log path. | `Services/Storage/UserProfileStore.swift` |
| C02 | `OnboardingState.Step` extension (+ 3 step views in `OnboardingWizardView`) | C | `aboutYou`, `emergencyContacts`, `voiceFingerprint` cases inserted in the required order; per-step status/skip/pending semantics reused unchanged. `FamilyContactStep` extended to show the existing contact list alongside the inline add. | `App/OnboardingState.swift`, `App/OnboardingWizardView.swift` |
| C03 | `AddressAsField` (chips + custom entry) | N | The about-you / Settings address-as input: catalog-backed preset chips per active language plus a free-text field; grapheme-safe entry bound; filled = non-empty after trimming. | `App/Components/` (new view; shared by C02 and C04) |
| C04 | `ProfileSettingsView` + `SettingsDestination.profile` | N | Plain Settings editor (OD-PI-5 resolved): name, address-as (C03), DOB, GP, hospital; next-of-kin note pointing at the existing family-contacts editor. Saves through the coordinator (single writer). | `App/`, `App/SettingsTabs.swift` |
| C05 | `WakeAcknowledging` seam + `WakeAcknowledgmentService` + `VoicePipeline.beginCapture` extraction | N/C | Speaks `हजुर <address-as>` on wake detection when a term is recorded, bounded; nil seam = today's behaviour byte-identical. Owns the ack phrase composition, playback, timeout, fallback. | `Services/Voice/WakeAcknowledgment.swift`, `Services/Voice/VoicePipeline.swift` |
| C06 | `InterpreterContext.addressAs` + `IntentPrompt` personalization clause | C | One guarded term flows through both context-construction sites into the shared builders; reply-style rules use it naturally; no-term composition is byte-identical. | `Services/Voice/LlamaCommandInterpreter.swift`, `Services/Voice/IntentPrompt.swift`, `Services/Voice/CommandRouter.swift`, `App/AppCoordinator.swift` |
| C07 | `ProfilePromptTextGuard` | N | The injection discipline for profile strings entering prompts: `InputSanitiser.sanitise(.quarantine)` → residual-marker detect → grapheme-safe configured bound → `nil` (un-personalized) on residual. | `Services/Voice/` (name settled at L2) |
| C08 | Seed mirror + Python renderer | C | `prompt_template.txt` and `intent_prompt.py` updated in the same change as the C06 template edit; new `{address_as_clause}` placeholder rendered as `""` by default (training corpus bytes unchanged). | `tools/train-intent/` |
| C09 | L10n catalog additions | C | All new user-visible strings in `Localizable.xcstrings` (en + ne): three step titles/bodies/labels, chips' preset options, Settings editor labels, ack templates, error copy. No term or name as a catalog entry. | `Resources/Localizable.xcstrings` |
| C10 | Observability + log-safety coverage | C | New events with content-free metadata only; `LogSanitiser` redacted-keys coverage for profile fields; release gate scan roots extended to the new profile sources. | `Services/Observability/`, `ios/tools/check-release-log-safety.py` |
| C11 | Emergency contacts step wiring | N | GP + hospital into C01; next of kin = existing `isEmergencyContact` designation through the existing `FamilyContactStore` APIs (ADR-02). | `App/OnboardingWizardView.swift`, `App/AppCoordinator.swift` |
| C12 | Voice fingerprint step | N | Hosts the existing `VoiceEnrollmentSession` (same construction as `VoiceSettingsView`) as an optional step; adds a call site only — no mechanism change, no new permission. | `App/OnboardingWizardView.swift` |

**Boundary rule.** The wizard and Settings edit profile data only through the
coordinator's single writer methods; the wake path and prompt paths read only through the
store's cached snapshot accessor. No component except C01 reads the encrypted file, and
none except C10's choke point writes logs.

---

## 3. Data model and storage architecture

### 3.1 `UserProfile` (C01)

```swift
struct UserProfile: Codable, Equatable {
    var name: String            // required — gates the about-you Next
    var addressAs: String       // required — stored and spoken verbatim
    var dateOfBirth: DateComponents?   // optional; recorded, never consumed for behaviour
    var emergencyDoctor: String?       // "GP" — optional
    var localHospital: String?         // optional
}
```

- **No next-of-kin field.** OD-F1 resolves to the existing `FamilyContact.isEmergencyContact`
  designation (ADR-02); there is no second copy of a person anywhere.
- **Migration pattern matches the codebase.** The record is unversioned; every future
  addition is an optional key read as `nil` when absent (the `FamilyContact` convention:
  "an optional field IS its migration"). `name` and `addressAs` are non-optional: a
  payload missing them is **unreadable**, not defaulted — no fabricated values (FR-PI-015).
- DOB is stored as components, not a `Date`: no timezone shift, and it is never spoken or
  composed into any prompt (NFR-PI-003).

### 3.2 `UserProfileStore` (C01)

- Storage key `"user.profile"`; placed by the existing `StoragePlacementPolicy` on the
  **encrypted-file** channel (it is not in `keychainResidentKeys`): Application Support /
  `EncryptedStore/`, `<sha256(key)>.json`, written with `.atomic` + `.completeFileProtection`,
  excluded from backup — the same pattern `FamilyContactStore`/`EventExtrasStore` use, and
  the project Security standard's Data Protection Complete (NFR-PI-001).
- **Load result is explicit** — absence and corruption must not be confusable (FR-PI-015):

```swift
enum ProfileLoadResult {
    case absent                       // fresh install / never written
    case loaded(UserProfile)
    case unreadable(ProfileStoreError) // corrupt envelope, undecodable JSON, partial record
}

enum ProfileStoreError: Error, Equatable {
    case readFailed          // store unavailable (Application Support unresolvable)
    case decodeFailed        // payload present but not a valid UserProfile
    case writeFailed         // atomic write failed
}

protocol UserProfileStoring {
    /// Never throws; a failure is an explicit case. Any queue.
    func load() -> ProfileLoadResult
    /// Main-thread writer (UI-initiated via the coordinator). Atomic.
    func save(_ profile: UserProfile) -> Result<Void, ProfileStoreError>
}
```

- **Discrimination.** The store reads raw bytes through the existing `RawEncryptedStorage`
  seam and decodes itself, so a missing payload (`nil` bytes, no file) is `.absent`, while
  present-but-undecodable bytes are `.unreadable`. To tell "file exists but envelope
  unreadable" from "absent", `EncryptedFileStorage` gains one **additive** probe
  (`hasPayload(key:) -> Bool`) — an extension, not a modification, of a shared type; no
  existing call site changes (NFR-PI-010).
- **Corrupt handling (FR-PI-015).** `.unreadable` → the payload is discarded (best-effort
  delete) and the store reports un-personalized; never partially applied (the record is
  decoded whole — there is no per-field application path); never retried in a loop; the
  failure is emitted as `profile_store_unreadable` with an `errorCode` classification and
  **no content** (NFR-PI-002).
- **Caching.** One in-memory cached record, swapped under a lock; `save` writes the file
  then swaps the cache, so a reader never observes a half-written profile. Reads therefore
  never touch disk twice per turn and never block on the wake path.
- **Single writer.** Only `AppCoordinator` writes (wizard steps and the Settings editor
  call its methods); the store's own `save` is internal to that path. Steps merge: read the
  current record, set the step's fields, save.
- **Durability.** An interruption mid-write leaves the previous record intact (atomic
  temp-file + rename, the existing `EncryptedFileStorage` behaviour). A step that completes
  but fails to save surfaces an inline plain-language error on the step and stays pending;
  it never claims a save that did not happen.

### 3.3 Family contacts (existing, unchanged)

`FamilyContactStore` keeps its model, key (`family.contacts`), cap, and behaviour. The
family & friends step (C02) and the emergency contacts step (C11) both write through the
existing coordinator methods (`addFamilyContact`, `updateFamilyContact(id:…isEmergencyContact:)`
— the flag parameter already exists), so `preferredEmergencyContact(_:)` keeps working with
zero logic change (FR-PI-014).

### 3.4 Prompt data (no persisted schema change)

The only "prompt schema" change is the C06 clause and the C08 placeholders; no new wire
format, no new request shape (NFR-PI-003).

---

## 4. Onboarding wizard architecture (FR-PI-001 … FR-PI-005, FR-PI-013)

### 4.1 Step order and IDs

```swift
enum Step: String, CaseIterable, Identifiable {
    case language          // existing
    case permissions       // existing
    case aboutYou          // NEW   (FR-PI-002)
    case familyContact     // existing step, extended (FR-PI-005)
    case emergencyContacts // NEW   (FR-PI-006)
    case voiceFingerprint  // NEW   (FR-PI-007)
    case models            // existing, stays last
}
```

- `allCases` order **is** the wizard order and the `pendingSteps` order — the existing
  mechanics need no change (FR-PI-001, FR-PI-004, FR-PI-013).
- Raw values persist `UserDefaults`; old status maps simply lack the new IDs, so every
  existing user's new steps are pending **by construction** — the Home reminder card
  (`HomeView`, `pendingCount` and `startingAt: firstPendingStep`) and the reopen sheet pick
  them up with no new mechanism, and the wizard is never auto-presented (no force-migration).
- If an existing user still has an older skipped step pending, the reopen lands there first
  — the existing ordering rule, unchanged (FR-PI-013's "first pending new step in the
  configured order" holds once the earlier pending steps are done).
- Existing steps keep their positions relative to each other and their behaviour; new
  cases are insertions (NFR-PI-010).

### 4.2 About-you (C02 + C03)

- Fields: name (required), address-as (required, ADR-05), DOB (optional; a standard
  `DatePicker`, never gates).
- **Next gate:** enabled iff both required values are non-empty after trimming whitespace
  and newlines (FR-PI-002). Completion persists name + address-as + DOB-through the
  coordinator's merge-save (FR-PI-003); the term is stored exactly as entered
  (FR-PI-010 — no normalisation beyond the trim used for the filled-check).
- **OD-F3 resolved (ADR-04): the header Skip stays, as a soft deferral.** Next is gated;
  Skip marks the step skipped and advances, leaving it pending for the reminder card. The
  step's own copy explains why the two fields matter. Rationale: a first-run user who
  cannot type (the primary persona) must never be trapped out of the assistant entirely;
  the deferral machinery already exists. Both paths are pinned by tests (Next disabled;
  Skip advances with pending status).

### 4.3 Family & friends (extended)

The existing inline add form stays; the step additionally lists the contacts already in
`FamilyContactStore` so the user can **confirm** what exists (the requirement's words) and
see that a contact added here is the same list Settings shows. Writes still go through
`addFamilyContact` — no fork, no duplicate store (FR-PI-005). The step remains skippable
(FR-PI-004).

### 4.4 Emergency contacts (C11)

- **GP** and **local hospital** → `UserProfile.emergencyDoctor` / `localHospital`
  (optional, partial fill accepted, persisted on completion).
- **Next of kin** → the existing `isEmergencyContact` designation (ADR-02): the step shows
  the family-contact list (created in the step above or earlier) with a "next of kin"
  pick; picking sets the flag through `updateFamilyContact`. If the list is empty, the
  step offers the same minimal inline name/phone/relationship form calling
  `addFamilyContact(name:phone:relationship:isEmergencyContact: true)` — so a user can
  record next of kin without visiting the previous step.
- No emergency-call logic, trigger, or stub is added; the data simply becomes what the
  existing path already consumes (FR-PI-014).

### 4.5 Voice fingerprint (C12)

Hosts the existing `VoiceEnrollmentSession` state machine (constructed exactly as
`VoiceSettingsView` constructs it: `SpeakerBiometricService` + `VoiceEnrollmentRecorder` +
the coordinator as `VoicePipelineSuspending`). Optional and skippable; failure or skip
advances (FR-PI-007). Zero changes to `SpeakerBiometricService` /
`VoiceEnrollmentRecorder` / `VoiceBiometricStore`, zero new permissions, biometric data
stays in the existing Secure-Enclave-backed store (NFR-PI-009).

### 4.6 Skip/pending semantics (FR-PI-004)

Unchanged mechanism: `markSkipped` / `markCompleted` / `pendingSteps` / `firstPendingStep`.
New steps participate exactly like `familyContact` does today; a partially filled optional
step completes without requiring every field.

---

## 5. Settings profile editor (C04, FR-PI-012)

- New `SettingsDestination.profile` row on the **family** tab (alongside `.family`), title
  key `settings.profile.title`, leaf `ProfileSettingsView`. The `SettingsTabMappingTests`
  contract ("every row lands on exactly one tab") is extended with the new case.
- Fields: name, address-as (C03 — same component as the wizard), DOB, GP, hospital; a
  read-only note explains that the next of kin is set on a family contact and links to the
  existing family-contacts editor (which already edits the flag).
- **Plain editor, no biometric/PIN gate** — owner-resolved OD-PI-5. The project-wide gate
  (requirements.md FR-042; constitution Open Decision 11 B3) remains unwired and is
  recorded as a follow-up outside this feature. The editor is protected at rest by the
  device's Data Protection class (Complete) like every other settings surface.
- Saves go through the coordinator's merge-save; because the wake path and the prompt
  contexts read the store's cache (which `save` swaps), **the change takes effect on the
  next wake and the next reply with no relaunch, no re-onboarding** — the acceptance
  scenario's requirement.
- Editing name/address-as re-runs no wizard step and does not touch `OnboardingState`.

---

## 6. Address-as integration

### 6.1 Wake acknowledgment (C05, FR-PI-008, FR-PI-010, NFR-PI-008)

**Phrase.** `हजुर <address-as>` for the Nepali locale; the surrounding copy is a localized
template resolved against the **active** app locale through `L10n.fmt(template:locale:term:)`
with the term as a `%@` argument. Template keys (C09): `wakeAck.personalized` →
`हजुर %@` (ne). The term is **data passed into** the format — never a catalog lookup, never
translated, never substituted (FR-PI-010). If the template cannot be resolved, no greeting
is spoken (never speak a key or a placeholder).

**Mechanism (ADR-06).** On-demand synthesis through the existing `Speaker`
(`PiperVoiceSpeaker` with the existing `SystemSpeechSpeaker` fallback), not the
`AckFastLane` pre-rendered cache: the term is unbounded user data, and a cached WAV
containing it would be a persistent PII artifact on disk (NFR-PI-001). The Piper path
already deletes its temp WAV after playback (Speaker.swift line 882) — only an ephemeral
in-sandbox audio rendering exists during synthesis/playback.

**Wiring.** `VoicePipeline` gains a `wakeAcknowledger: WakeAcknowledging?` seam (nil
default). `handleWakeDetected`'s existing capture-start body is extracted verbatim into
`beginCapture(generation:)`; the handler becomes:

```swift
// Existing guards and per-capture resets unchanged.
if let ack = wakeAcknowledger {
    ack.begin { [weak self] in self?.beginCapture(generation: generation) }
} else {
    beginCapture(generation: generation)   // today's exact path
}
```

```swift
protocol WakeAcknowledging: AnyObject {
    /// Starts the acknowledgment if a term is recorded; always calls
    /// `completion` exactly once, on the main queue, within
    /// `wakeAckMaxHoldSeconds`. Never throws, never retries.
    func begin(completion: @escaping () -> Void)
    /// Cancels any in-flight ack (pipeline stop / new capture).
    func cancel()
}
```

- **No term recorded → completion fires synchronously → capture starts exactly as today**
  (FR-PI-011). The nil seam (tests and any unwired configuration) is byte-identical to
  today's behaviour.
- **Term recorded →** the service starts playback immediately (ack begins within the 1 s
  activation budget, NFR-PI-008) and calls completion at playback end, at
  `wakeAckMaxHoldSeconds` (configurable; default 2.5 s), or immediately on any failure —
  whichever comes first. The capture timeout counted by the recognizer starts when capture
  starts, so the user's speaking window is unchanged.
- **Sequencing rationale:** the mic must not hear the assistant (the capture/STT feed
  would otherwise ingest the greeting, and the VAD would treat it as the utterance). Ack
  first, bounded hold, then listen — the natural "हजुर आमा" exchange.
- **Speaking bookkeeping:** the service marks the existing `WakeWordActivityGate` speaking
  during playback, so a wake detection in flight cannot open a capture over the ack
  (mirroring how replies already gate detection).
- **Failure path:** synthesis/playback failure → completion immediately (silent start, no
  crash, no retry loop); the ack is best-effort within its bound, never a precondition for
  listening.
- **Talk button:** `simulateWakeWordDetection()` runs the same handler, so the Talk button
  gets the same acknowledgment. Recorded as a decision (ADR-06) — consistent behaviour,
  one code path.

### 6.2 Brain reply-style rules (C06, FR-PI-009)

- `InterpreterContext` gains one **defaulted** field: `let addressAs: String? = nil`.
  Every existing call site and test compiles unchanged (NFR-PI-010 — extension, not
  modification).
- The value is produced by a single accessor on the coordinator
  (`profilePersonalization?.addressAsForPrompt`, the guarded value from C07) and consumed
  at the two existing context-construction sites: `CommandRouter.swift:1412` (the main
  interpret path — covers `build` and `buildChat` via `LlamaCommandInterpreter` and the
  cloud interpreter) and `AppCoordinator.swift:3601` (the collapsed Gemini speak+understand
  provider — covers `buildUnderstanding`). One seam, both engines, both builders.
- `IntentPrompt` composes the personalization through one private helper used by all three
  builders, attached to the existing reply-style guidance (candidate wording, final tuned
  at L2):

```swift
private static func addressAsClause(_ term: String?) -> String {
    guard let term, !term.isEmpty else { return "" }
    return " Address them as \"\(term)\" where it fits, never every sentence."
}
```

  - `build`: appended to the line `… In Nepali, say "हजुर", one short idea per sentence.`
  - `buildUnderstanding`: appended to the Nepali warmth bullet of "Reply style".
  - `buildChat`: appended to its Nepali line.
- **Natural use only** (FR-PI-009): the clause says *where it fits / never every
  sentence*; no rule forces the term into every reply, and a reply that omits it remains
  valid.
- **No term recorded → the clause is `""` and every composed prompt is byte-identical to
  the pre-feature prompt** (FR-PI-011, NFR-PI-010). This is a pinned test obligation, not
  an aspiration.
- **Name is deliberately not composed into prompts** (ADR-07): no requirement needs it,
  and keeping it out minimises PII on the existing consent-gated cloud path (NFR-PI-003
  permits either; we choose the smaller disclosure).
- The term itself is called out to the model as data (quoted slot), never as instruction
  text (NFR-PI-004).

### 6.3 Budget and seed mirror (NFR-PI-005)

The pinned facts, from the code:

- `IntentPromptTests.testPromptStaysWithinOnDeviceCharacterBudget` pins **≤ 3,000
  characters** for the fixture currently measuring **2,936** — ~64 characters of headroom
  for the personalization. The ceiling must not be raised; `build()` runs in the
  1,024-token on-device context with ~300 tokens left for utterance + JSON.
- `tools/train-intent/seeds/prompt_template.txt` is the byte-mirror of `build`'s text with
  `{language_hint}` / `{medications}` / `{transcript}` standing in for the three
  interpolations; `tools/train-intent/src/intent_prompt.py` renders them and **fails
  loudly** if a placeholder is missing.

Design obligations:

1. The clause is measured with a **worst-case in-bound term** in the fixture. The budget
   proof is: base + clause + bound term ≤ 3,000 Swift characters (grapheme count). If the
   candidate wording does not fit, the room comes from trimming non-load-bearing prose
   elsewhere (the `[GEMINI-SOLIDIFY]` precedent) or shortening the clause / lowering the
   composition bound — **never** from raising the ceiling or weakening the
   emergency-classification guidance.
2. Seed mirror updated in the **same change**: the seed gains `{address_as_clause}` in the
   exact position the Swift template interpolates `addressAsClause(...)`, and
   `intent_prompt.py`'s `PLACEHOLDERS` gains `{address_as_clause}` rendered as `""` by
   default. With `""`, the rendered training prompt is byte-identical to today's — the
   training/inference identity holds for the no-term common case, and the placeholder
   cannot be silently left literal (the renderer already rejects a template missing a
   declared placeholder). A checksum comparison of seed vs extracted Swift text is the
   measurable property (a test or gate hook, settled at L2).
3. `buildChat` / `buildUnderstanding` are not seed-mirrored (they never were); they follow
   the same clause helper so the three cannot drift.

---

## 7. Security architecture (feeds `security-design-review` STRIDE)

### 7.1 Trust boundaries and data flow

```
[About-you / Settings UI]  (untrusted user-entered text; a helping family member types it)
        │  trim + entry bound (C03)                        ── trust boundary 1
        ▼
[UserProfileStore]  encrypted file, Data Protection Complete, not backed up
        │  guarded read (cache)                            ── trust boundary 2
        ├──────────────► [WakeAcknowledgmentService]  phrase = localized template + term-as-data
        │                                                  ── TTS only, never a prompt
        └──────────────► [ProfilePromptTextGuard]  sanitise → residual-detect → bound
                               │  nil on residual (un-personalized, FR-PI-011)
                               ▼
                     [InterpreterContext.addressAs]
                               │
                     [IntentPrompt.build/buildChat/buildUnderstanding]
                       │                              │
        on-device LLaMA brain               cloud Gemini (existing consent-gated path)
                                             ── trust boundary 3: existing egress only
```

- **Boundary 1 — entry.** The only content validation at entry is the trim/filled check
  and the grapheme bound. No claim is made that entry sanitisation makes the string safe;
  adversarial content is expected to be stored (it is the user's own data, spoken verbatim
  by the ack) and neutralised at composition.
- **Boundary 2 — store.** Values are readable only with the app's protection class
  (device unlock); the store is the app's own code path; no third party reads it.
- **Boundary 3 — egress.** Only the guarded term may enter the existing prompt paths,
  under the existing cloud-stack consent (Open Decision 12). DOB, GP, hospital, family,
  next-of-kin, and biometrics never enter a prompt or any payload (NFR-PI-003).

### 7.2 Injection discipline (NFR-PI-004, C07)

- Applied at the composition seam, before the value enters any `InterpreterContext`:
  1. `InputSanitiser.sanitise(value, level: .quarantine)` — control-strip, whitespace
     collapse, marker removal (the project's configured level, single-sourced; no copied
     marker table).
  2. **Strip-then-detect:** `InputSanitiser.containsInjectionMarker(residual)` — if the
     value still carries a marker shape after the quarantine action, the personalization
     is dropped for that use (nil term → un-personalized path) and `profile_prompt_text_quarantined`
     is emitted with no content. A hostile payload is never sent to any engine.
  3. **Configured bound:** clamp to `ProfilePersonalizationConfig.maxPromptTermGraphemes`
     (injectable, default settled at L2; a named configured parameter, never a magic
     literal), truncating on `Character` boundaries so a grapheme cluster is never split.
- **Passed as data:** the term appears only inside the quoted slot of the clause; it
  cannot re-role the system prompt, and the clause cannot be parsed as a rule.
  Model output remains untrusted exactly as today (existing parse/confidence/`ReplySanityGate`
  paths are unchanged); nothing from a reply can cause a profile write or an action.
- **Ack asymmetry (documented, deliberate):** the wake ack speaks the stored term
  verbatim (FR-PI-010) and does **not** apply the prompt quarantine action — TTS is not a
  prompt, and the value is already entry-bounded. The ack string is built from a localized
  template with the term as an argument; it can trigger no action. Flagged for STRIDE.

### 7.3 PII inventory and log safety (NFR-PI-002, C10)

| PII | Where stored | Log surface discipline |
|-----|--------------|------------------------|
| Name, address-as | `UserProfileStore` (encrypted file) | never logged; keys `profile_name` / `address_as` added to `LogSanitiser.redactedKeys` so a future diagnostic naming them renders `[redacted]` |
| DOB | `UserProfileStore` | never logged; same redacted-key discipline |
| GP, hospital | `UserProfileStore` | never logged |
| Next of kin / family | `FamilyContactStore` (existing, encrypted) | existing discipline unchanged |
| Voice fingerprint | existing Secure Enclave-backed store | unchanged; events already outcome-only |

- New events use **no content metadata**: `profile_store_saved`, `profile_store_loaded`,
  `profile_store_absent`, `profile_store_unreadable` (errorCode ∈ {`read_failed`,
  `decode_failed`}), `profile_prompt_text_quarantined`, `wake_ack_spoken`
  (duration; `term_present` boolean only), `wake_ack_failed` / `wake_ack_timeout`
  (errorCode only). The allow-list means any accidental new metadata key is dropped.
- The release gate `ios/tools/check-release-log-safety.sh` (build-blocking, wired into
  `ios/build.sh`) must cover the new paths: `FEATURE_ROOTS` in
  `ios/tools/check-release-log-safety.py` gains the feature's own source roots
  (the new store, the ack service, the guard), so a Release-compiled print in those files
  fails the gate (NFR-PI-002's scenario 3).

### 7.4 Encryption at rest (NFR-PI-001)

- All profile fields live in the encrypted-file channel (`completeFileProtection`,
  `isExcludedFromBackup`, atomic writes); no plaintext copy is written anywhere, including
  during saves (the temp file of the atomic write is the protected same-directory file and
  is renamed into place, not left behind).
- The only value-bearing artifact outside the store during normal operation is the Piper
  synthesis temp WAV of the spoken ack, deleted with `defer` after playback; it is an
  ephemeral audio rendering in the app sandbox's temporary directory (not backed up), and
  no personalized audio is cached persistently (ADR-06). Recorded so `security-test` can
  test the claim rather than discover it.
- Removing the app removes the data; no new backup or cloud path exists (NFR-PI-001's last
  bullet).

### 7.5 Voice biometrics (NFR-PI-009) and auth strategy

- Mechanism, contracts, algorithm, storage: **unchanged**; the diff is a new call site
  (C12). No new permissions or purpose strings — `Info.plist` untouched. The existing
  voice-biometric threat model applies unchanged; STRIDE covers it by reference.
- **Auth strategy: none is added.** The feature introduces no new authentication gate and
  no new sensitive action. The Settings profile editor is a plain editor (OD-PI-5); the
  project-wide biometric/PIN gate stays recorded-unwired (constitution Open Decision 11
  B3, review 2026-10-13). Profile confidentiality at rest rests on Data Protection
  Complete (device passcode), as with the existing contacts store.

---

## 8. No-regression contract (FR-PI-011, NFR-PI-010)

Until an address-as term is recorded — fresh install, skipped step, existing user not yet
re-interviewed, or any read failure — behaviour is **exactly today's**:

| Surface | No-term guarantee | Mechanism |
|---------|-------------------|-----------|
| Wake handling | capture starts exactly as today, no spoken greeting, no placeholder | nil-term path in C05; nil seam = today's code path |
| Prompt composition | byte-identical prompts, no term, no substitute | `addressAsClause(nil) == ""` |
| Existing wizard steps | unchanged position and behaviour | insertions only |
| Family contacts | store contract unchanged | writes via existing APIs |
| Safety paths | identical triggers/outputs/failures | designation only; no logic change |
| Voice biometrics | mechanism unchanged | new call site only |
| Startup | never blocked by a profile read failure; no crash/stall | explicit load-result handling |

No neutral placeholder is ever invented in any state. The affected existing test suites
(`OnboardingState`, `FamilyContactStore`, `IntentPromptTests`, `LlamaCommandInterpreter`,
wake/pipeline seams) stay green under `ios/build.sh`'s scope.

---

## 9. Interfaces, error taxonomy, and failure modes

Interfaces at L1 altitude (contracts firmed in `design-l2`):

- `UserProfileStoring` (§3.2) — `load() -> ProfileLoadResult` (never throws),
  `save(_:) -> Result<Void, ProfileStoreError>`.
- `WakeAcknowledging` (§6.1) — `begin(completion:)` / `cancel()`; completion exactly once,
  main queue, within `wakeAckMaxHoldSeconds`; no error to surface (failures are events, and
  the fallback is today's silent start).
- `ProfilePromptTextGuard` — `guard(_ value: String?) -> String?` (nil in → nil out; nil
  out on residual marker or empty after sanitising); pure, no I/O, unit-testable with
  adversarial fixtures.
- Coordinator seams — `profilePersonalization: ProfilePersonalizationReading?` (read-only
  snapshot), `saveProfile(name:addressAs:dateOfBirth:emergencyDoctor:localHospital:) -> Result<Void, ProfileStoreError>`
  on the existing `AppCoordinator`.
- `InterpreterContext.addressAs: String? = nil` (defaulted — source-compatible).

| Operation | Failure mode | Retryable? | Behaviour |
|-----------|--------------|-----------|-----------|
| Profile load | absent | n/a | un-personalized, no user-visible error |
| Profile load | unreadable (decode/read) | no (never loop) | discard payload, un-personalized, content-free event |
| Profile save (wizard step) | writeFailed | yes (user re-taps) | inline plain-language error; step stays pending; nothing claimed |
| Profile save (Settings) | writeFailed | yes | inline error; previous value remains in effect |
| Wake ack synthesis/playback | any failure | no | silent start, one attempt, no retry loop |
| Wake ack hold | bound exceeded | n/a | playback cancelled, listening starts |
| Prompt term guard | residual injection marker | no | term omitted for that turn (un-personalized), event emitted |
| Voice enrollment | existing failure states | existing behaviour | step advances; enrollment still available in Settings |

---

## 10. Concurrency and isolation

- `UserProfileStore`: reads from any queue behind one lock + cached record; writes
  main-thread (UI-initiated), file-first then cache swap; atomic writes guarantee no
  half-written payload; a reader never sees a partial record.
- `WakeAcknowledgmentService`: main-confined (it is driven from `handleWakeDetected`);
  at most one in-flight ack; `cancel()` on pipeline stop and on a superseding capture;
  completion exactly once (guarded), so the pipeline cannot double-start a capture.
- `VoicePipeline`: the extracted `beginCapture(generation:)` keeps the existing
  capture-generation guard semantics — a stale ack completion from a superseded capture is
  inert (the generation check it already performs).
- `ProfilePromptTextGuard`: pure function; the composed clause rides the immutable
  `InterpreterContext` value, so prompt composition on any interpreter queue is safe.
- Wizard/Settings: SwiftUI main-actor; `VoiceEnrollmentSession` keeps its existing
  `@MainActor` + `VoicePipelineSuspending` cycle.

---

## 11. Configurable parameters

Named, injectable, with defaults; none hardcoded at call sites (Agent Principles). Final
names/values settle at L2.

| Parameter | Default (proposed) | Purpose |
|-----------|--------------------|---------|
| `wakeAckMaxHoldSeconds` | 2.5 | bound on the ack-before-listen hold (NFR-PI-008) |
| `addressAsMaxGraphemes` (entry) | 24 | input bound; grapheme-safe |
| `nameMaxGraphemes` (entry) | 60 | input bound |
| `maxPromptTermGraphemes` (composition) | ≤ entry bound | NFR-PI-004's configured cap |
| `profileStoreKeyName` | `"user.profile"` | store key (constant, not tunable) |

---

## 12. Runtime and build topology

- **No server, no containers, no new services.** Runtime blocks: the iOS app
  (`AppCoordinator` owning the store, the pipeline, the speaker, the interpreters) —
  everything in §2; all on-device.
- **Build/test:** `ios/build.sh` (test scope) unchanged; the feature's test additions join
  the existing scopes. The release gate `ios/tools/check-release-log-safety.sh` gains the
  feature's scan roots (§7.3) and must exit 0 (NFR-PI-011).
- **Training tooling:** `tools/train-intent/` seed + renderer updated in the same change
  (C08); no retrain is part of this feature, but training/inference identity is preserved
  for the next run.
- **Release checklist item (NFR-PI-011 #2):** the App Store data-collection disclosure
  (Guideline 5.1.1) must cover name, address-as, DOB, and emergency contacts; drafted for
  the owner before the first submission, in the 2026-10-13 review window. Tracked here as
  a recorded follow-up, not code.

---

## 13. Requirements traceability

All items verified against `specs/define-requirements.lock.yaml` (15 FR / 11 NFR, all MUST).

| Requirement | Satisfied by | Notes |
|---|---|---|
| FR-PI-001 | C02 / ADR-03 | order language → permissions → aboutYou → familyContact → emergencyContacts → voiceFingerprint → models; existing steps' relative order kept |
| FR-PI-002 | C02, C03 / ADR-04, ADR-05 | Next gated on trimmed non-empty name + address-as; DOB never gates; values persisted on completion |
| FR-PI-003 | C01 / ADR-01 | encrypted single-record store; single source of truth; durable atomic writes; missing/corrupt → FR-PI-015 |
| FR-PI-004 | C02, C11, C12 / §4.6 | skip/pending pattern unchanged; new steps participate; partial fill accepted |
| FR-PI-005 | C02, C11 / §4.3 | existing step extended over `FamilyContactStore`; no fork/duplicate |
| FR-PI-006 | C11, C01 / ADR-02 | GP + hospital in the store; next of kin = designation on a family contact |
| FR-PI-007 | C12 / §4.5 | existing enrollment flow hosted as an optional step; call site only |
| FR-PI-008 | C05 / ADR-06 | ack spoken on detection when a term exists; today's silent start otherwise; failure → silent start |
| FR-PI-009 | C06 / ADR-07 | one clause via the shared builder; cloud + on-device; natural use only; no-term inert; budget + mirror obligations |
| FR-PI-010 | C09, C05, C06 / ADR-06, ADR-07 | term is data: template argument, never a catalog lookup; verbatim in ack and replies |
| FR-PI-011 | §8 / ADR-10 | byte-identical no-term prompts; today's wake path; no placeholder anywhere |
| FR-PI-012 | C04 / ADR-08 | Settings editor reachable, editable, persists, effective next use; plain (OD-PI-5) |
| FR-PI-013 | C02 / ADR-03 | new IDs pending by construction; reminder card + reopen unchanged; no force-migration |
| FR-PI-014 | ADR-02 / §3.3, §4.4 | next of kin flows to the existing `preferredEmergencyContact` with zero logic change; GP/hospital readable in the store |
| FR-PI-015 | C01, C05 / §3.2, §9 | explicit load result; discard-not-loop; no partial application; no fabrication; un-personalized fallback |
| NFR-PI-001 | C01 / ADR-01 / §7.4 | encrypted-file channel, Protection Complete, not backed up, atomic; no cache of personalized audio |
| NFR-PI-002 | C10 / §7.3 | content-free events; redacted keys; release gate covers new roots; no PII in any build |
| NFR-PI-003 | §7.1 / ADR-11 | zero new calls/endpoints/shapes; only the guarded term enters the existing prompt path, under the existing consent exception |
| NFR-PI-004 | C07 / §7.2 | quarantine action + strip-then-detect + configured grapheme bound + data-slot placement; no capability change; hostile value → un-personalized |
| NFR-PI-005 | C06, C08 / §6.3 | clause measured against the pinned 3,000-char ceiling with a worst-case term; seed + renderer updated in the same change |
| NFR-PI-006 | C09 | every new string catalogued (en + ne), zero hardcoded user-visible Swift strings; term/name never catalogued |
| NFR-PI-007 | C02, C04 / §4, §5 | existing wizard chrome and `DesignTokens` (44 pt targets, ≥18 pt body) reused; Devanagari via existing rendering |
| NFR-PI-008 | C05 / ADR-06 | ack starts within 1 s; bounded hold; TTS failure → today's silent start, no retry loop |
| NFR-PI-009 | C12 / §7.5 | mechanism/contracts/storage unchanged; no new permission; biometrics never in store/logs/payloads |
| NFR-PI-010 | §8 / ADR-10 | extension-not-modification across `OnboardingState`, `VoicePipeline`, `IntentPrompt`, `FamilyContactStore`; existing suites green |
| NFR-PI-011 | §12 + §7 | compliance items recorded: no new permissions; disclosure update tracked; STRIDE + security-test gates; release gates |

**Not yet resolvable at L1:** the ack synthesis latency evidence (OD-A1) and the English
ack copy (OD-A2). Neither changes the traceability above; both are evidence items, not
design gaps.

---

## 14. Decision log (ADR style)

**ADR-01 — Dedicated encrypted profile store on the `EncryptedFileStorage` pattern.**
*Decision:* C01 as specified in §3.2.
*Rationale:* the project Security standard (encrypted app storage, Data Protection
Complete) and the P1-6 placement policy (structured data → encrypted files, not Keychain);
one store as the single source of truth; explicit absent-vs-unreadable for FR-PI-015.
*Alternatives:* reuse `UserDefaults`/plain JSON (rejected: plaintext PII); a Keychain item
(rejected: placement policy, read cost, size); reuse `FamilyContactStore` (rejected: wrong
entity — a contact has name/phone, not DOB/GP/hospital).
*Consequences:* one additive `hasPayload` probe on the shared file store; new store
participates in the codebase's unversioned-optional-field migration convention.

**ADR-02 — OD-F1 resolved: next of kin is the existing `isEmergencyContact` designation.**
*Decision:* the emergency step flags a `FamilyContact`; GP and hospital live in C01; the
profile store holds no next-of-kin copy.
*Rationale:* a next of kin is a person with a name and a phone — already modelled, already
encrypted, already consumed by `preferredEmergencyContact(_:)`, so FR-PI-014 is satisfied
in substance with zero logic change; FR-PI-012 explicitly routes next-of-kin editing
through the family surface; no duplicate person data to keep in sync.
*Alternatives:* a standalone next-of-kin text field in C01 — rejected: dead data (no path
reads it without new logic, which FR-PI-014 forbids) and a second copy of a person.
*Consequences:* the emergency step depends on the existing contact APIs (both accept the
flag today); NFR-PI-001 coverage for next of kin is `FamilyContactStore`'s existing
encryption; the field table in the feature constitution's OD-F1 resolves to "designation".

**ADR-03 — Step insertion in `OnboardingState.Step` order; no new mechanism.**
*Decision:* three new cases inserted in the owner-brief order; persistence, pending, and
reopen mechanics untouched.
*Rationale:* `allCases` order already drives wizard order, `pendingSteps` order, and the
reopen position; absent IDs are pending by construction for existing users (FR-PI-013).
*Consequences:* existing users see the new steps on the reminder card without
force-migration; tests pin the order.

**ADR-04 — OD-F3 resolved: About-you keeps the Skip affordance (soft gate); Next is gated.**
*Decision:* Next disabled until name + address-as are filled; Skip remains, marking the
step skipped/pending and advancing.
*Rationale:* the primary persona may be unable to type, and a helping family member may
not be present at first run — a hard gate could strand a first-run user with no assistant
at all; the reminder card, reopen, and Settings editor are the existing deferral-and-nudge
machinery; the wizard's documented no-hard-gate contract is preserved (NFR-PI-010).
*Alternatives:* disable Skip (hard gate) — rejected for the stranding risk above; the
mandatory intent is enforced on the Next path and kept visible in the step copy.
*Consequences:* an installation can run un-personalized until the fields are supplied —
which is required behaviour anyway (FR-PI-011); tests pin both paths. **Owner-visible at
this gate.**

**ADR-05 — OD-PI-4 carried out: preset chips per language + custom field.**
*Decision:* C03 with catalog-backed preset options (ne: आमा, ममी, बुबा, दाइ, दिदी, …;
en: Mum, Mom, Dad, …) plus a free-text field; filled = non-empty after trimming; entry
bounds in §11.
*Rationale:* owner-resolved lowest typing burden; the chip's resolved display string
becomes the stored term (data), so the personalization paths never localize a term.
*Consequences:* the catalogs hold preset **options**; no code path ever resolves a stored
term through the catalog (FR-PI-010); the same component is reused in Settings.

**ADR-06 — OD-F2 resolved: on-demand TTS ack, localized template + term-as-data, ack-first
with a bounded hold; no pre-rendered personalized cache.**
*Decision:* §6.1 — `हजुर %@` (ne) via `L10n.fmt`, existing `Speaker`, nil seam,
bounded hold, immediate fallback; not routed through `AckFastLane`.
*Rationale:* the term is unbounded user data — pre-rendering variants would put
value-bearing audio on disk (NFR-PI-001) and cannot enumerate terms; on-demand synthesis
through the warmed Piper engine is the existing, temperature-controlled path; ack-first
avoids the mic hearing the assistant.
*Alternatives:* AckFastLane variants (rejected above); concurrent ack + capture (rejected:
echo/STT contamination — no precedent for TTS during capture in this codebase);
speaking via the reply lane (rejected: reply/turn bookkeeping state misuse).
*Consequences:* a device-measured latency obligation (OD-A1); the ack speaks on the Talk
button too (same handler); failure is always the silent start.

**ADR-07 — One guarded term in `InterpreterContext`, composed by one helper in three
builders; name excluded from prompts.**
*Decision:* §6.2.
*Rationale:* both engines share `IntentPrompt`, so one seam cannot drift; a defaulted
field keeps every existing call site and test source-compatible; excluding the name
minimises PII on the cloud path with no requirement lost (NFR-PI-003 permits, does not
require, the name).
*Consequences:* the two context-construction sites (`CommandRouter`,
`AppCoordinator` collapse provider) must read the same coordinator accessor; the no-term
byte-identity test is the guard rail.

**ADR-08 — OD-PI-5 carried out: plain Settings editor; no new auth.**
*Decision:* C04 as specified; the project-wide biometric/PIN gate stays unwired and is
recorded as a follow-up.
*Rationale:* owner-resolved; the feature adds no new sensitive action; the residual risk
is already recorded (constitution Open Decision 11 B3).
*Consequences:* `SettingsDestination`/tab-mapping tests updated; the editor's
accessibility and localization obligations ride the existing Settings chrome.

**ADR-09 — Prompt-side quarantine, ack-side verbatim (documented asymmetry).**
*Decision:* §7.2 — the guard drops personalization on residual markers; the ack speaks the
stored term verbatim.
*Rationale:* the injection risk is composition into prompts, not TTS; FR-PI-010 requires
verbatim speech; the entry bound keeps the utterance sane.
*Consequences:* STRIDE must treat the composition seam as the focus area and the ack path
as TTS-only; `security-test` presents both positive and negative evidence.

**ADR-10 — No-regression is a byte-level contract, not a behavioural claim.**
*Decision:* §8 — no-term prompt bytes identical, nil-seam wake path identical, insertions
only elsewhere; no placeholder ever.
*Rationale:* FR-PI-011/NFR-PI-010 demand "exactly as today"; byte identity is the
measurable form; `pluginSections` (`""` when no plugins) is the in-repo precedent.
*Consequences:* the clause helper returns `""`; the pipeline seam is optional; tests pin
both.

**ADR-11 — No new egress, no new cloud processing, no infrastructure.**
*Decision:* §7.1/§12 — only the guarded term may enter the existing prompt paths under the
existing cloud-stack consent; DOB/GP/hospital/next-of-kin/family/biometric values never
enter prompts or payloads.
*Rationale:* NFR-PI-003 and Architecture Constraint 1 with its recorded exceptions
untouched.
*Consequences:* the privacy disclosure update is a release-checklist item (§12).

---

## 15. Open decisions

**OD-A1 — Wake-ack synthesis latency vs the 1 s budget (evidence owed, not decidable on
paper).** The ack begins within `NFR-PI-008`'s 1 s from detection, but on-demand Piper
synthesis latency on the slowest target device is a measurement, not an assumption (the
ack fast lane exists precisely because the pre-ack synthesis path once felt sluggish at a
~200 ms budget).
*Recommendation:* proceed with on-demand synthesis; the implement/security-test tasks
measure detection → first audio on a device and record the number. If it fails the budget,
the fallback ladder is, in order: (1) warm the voice engine before first use (existing
WarmStart coverage), (2) a **memory-only** pre-synthesized ack (no disk artifact) keyed by
term + voice, (3) shorten the copy. No option may add a persistent PII artifact.

**OD-A2 — English ack copy (owner eyeball).** The Nepali form is pinned by the
requirements (`हजुर <address-as>`); the English-locale surrounding copy is not. 
*Recommendation:* `Yes, %@` — and, because the term must stay verbatim, no English
"translation" of the term is ever attempted. The exact string is a one-line catalog
decision the owner can adjust at this gate; it does not affect the architecture.

*Recorded, not open:* the App Store privacy-disclosure update for the new fields
(NFR-PI-011 #2) is an owner/compliance checklist item in the 2026-10-13 review window; the
project-wide biometric/PIN gate on sensitive settings remains a recorded follow-up outside
this feature (OD-PI-5, constitution Open Decision 11 B3).

---

## 16. Hand-off notes

- **`design-l2`** owns: exact clause wording and its measured budget proof; the final
  `ProfilePromptTextGuard` name and bound; the ack service's internal state machine; the
  C03 chip data structure; the `hasPayload` probe's exact signature; test seams for each
  contract in §9.
- **`security-design-review` (STRIDE)** focus, matching the workflow: the composition seam
  (C07 → C06) as the injection surface; the store (§3.2) and log surfaces (§7.3); the ack
  path as TTS-only (§7.2 asymmetry); voice-fingerprint reuse by reference (§7.5); egress
  (§7.1, ADR-11).
- **`plan-tasks`** should slice so the seed/template change (C06+C08) lands as one
  indivisible unit (checksum contract), and the store (C01) lands before its consumers
  (C02/C04/C05/C06).
- **`security-test`** evidence hooks: adversarial term fixtures through C07; no-PII
  log runs over a personalized session; container inspection for plaintext values;
  offline full-journey run; ack failure injection.

---

## 17. Verification hooks (acceptance mapping)

| Check | Where |
|-------|-------|
| Step order + pending semantics | unit tests on `OnboardingState` (order, pending for pre-feature maps) |
| Next gate / Skip / DOB optional | UI or view-model tests on the about-you step |
| Store round-trip, absent vs corrupt, atomicity | `UserProfileStore` unit tests with injectable storage |
| No plaintext PII on disk | container inspection (manual/scripted) + store tests |
| Prompt byte-identity (no term) | `IntentPromptTests` additions comparing against the pre-feature fixture |
| Prompt budget with worst-case term | `IntentPromptTests` ceiling test (constant unchanged) |
| Seed byte-identity | checksum comparison in the feature's test/gate hook |
| Guard behaviour | adversarial fixtures: marker strings, oversized terms, grapheme boundaries |
| Wake ack sequencing + fallback | pipeline seam tests (nil seam; failing/fake acknowledger; bound expiry) |
| Log surface | `ios/tools/check-release-log-safety.sh` with extended roots + `ios/build.sh` scope |
