import SwiftUI
import UIKit

// MARK: - Profile-interview wizard steps (T-099, T-100, T-101)
//
// The three interview steps live in this file so the wizard shell keeps
// the step ORDER and the chrome, and this file keeps the step BODIES:
//
//   * `AboutYouStep`            — name + address-as + optional DOB (T-099)
//                                 + optional selfie (2026-10-06)
//   * `EmergencyContactsStep`   — next-of-kin designation + GP/hospital (T-100)
//   * `VoiceFingerprintStep`    — voice enrollment, skippable like every
//                                 step (T-101)
//
// Every step is skippable (the shell's Skip button is always available),
// but About-you ADDITIONALLY gates its own Next button while the two
// mandatory fields (trimmed non-empty name and address-as) are missing —
// that gate is `AboutYouDraft.isComplete`, single-sourced with the
// cold-start routing predicate so button and router can never disagree.
//
// All three views save through the coordinator's single profile writer
// (`saveProfile`); a write failure shows inline copy and keeps the step
// in place. Nothing here writes to the console or to event metadata —
// the file is inside the log-safety gate's FEATURE_ROOTS (T-104).

// MARK: - Step: About you (T-099)

struct AboutYouStep: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.appAppearance) private var appearance
    let onNext: (OnboardingState.Step) -> Void

    @State private var draft = AboutYouDraft()
    @State private var birthDate: Date = AboutYouStep.defaultBirthDate
    @State private var showSaveFailure = false
    @State private var didPrefill = false
    /// The selfie is optional everywhere (about-you selfie, 2026-10-06):
    /// `photoPreview` is the downsampled image the button shows,
    /// `stagedPhotoFilename` is a file this visit captured but has not
    /// persisted yet (cleaned up on the way out), and the two flags drive
    /// the camera sheet / the soft "no camera" note. A failed capture, an
    /// unavailable camera or a denied permission changes nothing and
    /// never blocks Next.
    @State private var photoPreview: UIImage?
    @State private var stagedPhotoFilename: String?
    @State private var showsCamera = false
    @State private var cameraUnavailable = false

    private let bounds = ProfileEntryBounds.default

    /// A neutral wheel position for a DOB the elder has not touched yet.
    static let defaultBirthDate: Date = Calendar.current.date(
        from: DateComponents(year: 1950, month: 1, day: 1)) ?? Date()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.aboutYou.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.aboutYou.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                TextField("onboarding.aboutYou.name", text: clampedName)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(appearance.colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(Text("onboarding.aboutYou.name"))

                VStack(alignment: .leading, spacing: 8) {
                    Text("onboarding.aboutYou.addressAs")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textSecondary)
                    AddressAsField(text: addressAsBinding,
                                   locale: coordinator.activeLocale,
                                   bounds: bounds)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("onboarding.aboutYou.dateOfBirthToggle",
                           isOn: $draft.hasDateOfBirth)
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(appearance.colors.textPrimary)
                        // iOS 16 single-parameter onChange (the two-
                        // parameter closure overload is iOS 17-only).
                        .onChange(of: draft.hasDateOfBirth) { isOn in
                            // Toggling on seeds the wheel's value so an
                            // untouched picker still records a date; the
                            // merge stores components only.
                            if isOn, draft.dateOfBirth == nil {
                                draft.dateOfBirth = birthDate
                            }
                        }
                    if draft.hasDateOfBirth {
                        DatePicker("",
                                   selection: birthDateBinding,
                                   displayedComponents: [.date])
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text("onboarding.aboutYou.dateOfBirthToggle"))
                    }
                }

                photoSection
            }

            if showSaveFailure {
                Text("profile.error.saveFailed")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
            }

            primaryButton(key: "onboarding.next", typography: appearance.typography) { saveAndAdvance() }
                .disabled(!draft.isComplete)
                .opacity(draft.isComplete ? 1 : 0.45)
        }
        .onAppear(perform: prefill)
        // The captured photo becomes the record's only at Next; a staged
        // file from a visit that ends any other way (Skip, Back, the
        // wizard dismissed) is cleaned up here — no orphaned selfie on
        // disk. After a successful save the staged name is already nil,
        // so the persisted file is never the one deleted.
        .onDisappear {
            if let staged = stagedPhotoFilename {
                coordinator.contactPhotoStore.delete(named: staged)
            }
        }
        .sheet(isPresented: $showsCamera) {
            SelfieCameraPicker(onCapture: handleCapturedPhoto) { showsCamera = false }
        }
    }

    // MARK: selfie (optional — about-you selfie, 2026-10-06)

    /// A neutral secondary button (accent on the control surface, like
    /// the family editor's photo controls): the step keeps ONE primary
    /// accent — Next. Once a photo exists the button shows it as the
    /// small circular thumbnail, and tapping again retakes it.
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { presentCamera() } label: {
                HStack(spacing: 12) {
                    if let photoPreview {
                        Image(uiImage: photoPreview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text("onboarding.aboutYou.takePhoto")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(appearance.colors.accent)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)

            if cameraUnavailable {
                // Soft, never blocking: the photo is optional, so this is
                // a note beside the button — not an error state.
                Text("onboarding.aboutYou.photoUnavailable")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // No camera at all (simulator, restricted device) — say so
            // plainly and carry on; a denied PERMISSION still presents
            // the system camera's own guidance and cancels back here.
            cameraUnavailable = true
            return
        }
        cameraUnavailable = false
        showsCamera = true
    }

    /// The picker's one callback. The FILE is written first (the store
    /// downscales to a ≤512px JPEG); only a successful write claims the
    /// filename in the draft. A failed write keeps whatever was there —
    /// soft, like every photo path in the app.
    private func handleCapturedPhoto(_ image: UIImage) {
        guard let filename = coordinator.contactPhotoStore.save(image) else { return }
        // A capture supersedes an earlier STAGED (never persisted) file:
        // delete it now. The record's own file is only deleted after a
        // successful save (see `saveAndAdvance`).
        if let superseded = stagedPhotoFilename {
            coordinator.contactPhotoStore.delete(named: superseded)
        }
        stagedPhotoFilename = filename
        draft.photoFilename = filename
        // Hold a downsampled copy for the thumbnail — the full-size
        // capture is not needed again (same treatment as the family
        // editor's picked photo).
        photoPreview = DownsampledImageCache.downsampled(
            image, maxPixelEdge: ContactPhotoStore.maxDimension) ?? image
    }

    /// The grapheme-safe name binding (60 Characters, same clamp helper
    /// as the address-as field so Devanagari conjuncts never split).
    private var clampedName: Binding<String> {
        Binding(
            get: { draft.name },
            set: { draft.name = ProfileText.clamped($0,
                                                    maxGraphemes: bounds.nameMaxGraphemes) }
        )
    }

    private var addressAsBinding: Binding<String> {
        Binding(get: { draft.addressAs },
                set: { draft.addressAs = $0 })
    }

    private var birthDateBinding: Binding<Date> {
        Binding(get: { draft.dateOfBirth ?? birthDate },
                set: { draft.dateOfBirth = $0; birthDate = $0 })
    }

    /// One-shot prefill so a reopen (reminder card → About-you) shows the
    /// stored values instead of an empty form. The draft still owns the
    /// edit; the merge on Next is against the fresh snapshot.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard case .loaded(let profile) = coordinator.currentProfileSnapshot() else { return }
        draft.name = profile.name
        draft.addressAs = profile.addressAs
        if let components = profile.dateOfBirth,
           let date = Calendar.current.date(from: components) {
            draft.dateOfBirth = date
            draft.hasDateOfBirth = true
            birthDate = date
        }
        // A stored selfie shows its thumbnail again; an unreadable or
        // vanished file simply leaves the button photo-less (soft).
        if let filename = profile.photoFilename {
            draft.photoFilename = filename
            photoPreview = coordinator.contactPhotoStore.load(named: filename)
        }
    }

    private func saveAndAdvance() {
        guard draft.isComplete else { return }
        let base = coordinator.currentProfileSnapshot().mergeBase
        let merged = draft.merged(into: base)
        let result = coordinator.saveProfile(
            name: merged.name,
            addressAs: merged.addressAs,
            dateOfBirth: merged.dateOfBirth,
            emergencyDoctor: merged.emergencyDoctor,
            localHospital: merged.localHospital,
            photoFilename: merged.photoFilename)
        switch result {
        case .success:
            // The record now points at the merged selfie: a replaced
            // file can go (the family editor's post-persist cleanup
            // order), and a staged file is no longer litter.
            if let previous = base.photoFilename, previous != merged.photoFilename {
                coordinator.contactPhotoStore.delete(named: previous)
            }
            stagedPhotoFilename = nil
            showSaveFailure = false
            onNext(.aboutYou)
        case .failure:
            showSaveFailure = true
        }
    }
}

// MARK: - Selfie capture (about-you selfie, 2026-10-06)

/// Front-camera capture for the About-you seed selfie — same wrapping
/// style as `VisualAidPhotoPicker` (VisualAidViews.swift), but
/// `UIImagePickerController` in `.camera` mode: PHPicker cannot TAKE a
/// photo, and the camera picker is the one built-in that presents the
/// real system camera with no preview plumbing of our own.
/// `NSCameraUsageDescription` already ships (live translation), so no
/// Info.plist change was needed.
///
/// The picker owns nothing but capture: the returned `UIImage` goes to
/// the step, which stores it through `ContactPhotoStore`. Cancellation
/// just finishes — the photo is optional everywhere.
struct SelfieCameraPicker: UIViewControllerRepresentable {

    /// Called once with the captured image; never on cancel.
    let onCapture: (UIImage) -> Void
    /// Called for BOTH capture and cancel — the caller ends the
    /// presentation (the SwiftUI sheet's binding owns dismissal; the
    /// picker never dismisses itself).
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // The true selfie: the front camera, by default.
        picker.cameraDevice = .front
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void,
             onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

// MARK: - Kin designation plan (T-100)

/// The pure one-tap designation plan (T-100): the tapped contact is
/// flagged true and every OTHER currently-flagged contact is cleared
/// in the same pass, so the wizard always produces the singular
/// designation. Contacts that are neither tapped nor flagged are
/// absent from the plan (no write happens). Each entry carries the
/// source contact's current values verbatim — the flag write can
/// never clear a field edited elsewhere.
enum KinDesignation {
    struct Entry: Equatable {
        let contact: FamilyContact
        let isEmergencyContact: Bool
    }

    static func plan(contacts: [FamilyContact],
                     tapped: FamilyContact) -> [Entry] {
        var entries: [Entry] = []
        for contact in contacts
        where contact.isEmergencyContact && contact.id != tapped.id {
            entries.append(Entry(contact: contact,
                                 isEmergencyContact: false))
        }
        entries.append(Entry(contact: tapped, isEmergencyContact: true))
        return entries
    }
}

// MARK: - Step: Emergency contacts (T-100)

struct EmergencyContactsStep: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.appAppearance) private var appearance
    let onNext: (OnboardingState.Step) -> Void

    @State private var draft = EmergencyContactsDraft()
    @State private var inlineName = ""
    @State private var inlinePhone = ""
    @State private var inlineRelationship = ""
    @State private var showSaveFailure = false
    @State private var didPrefill = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.emergency.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.emergency.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("onboarding.emergency.kinTitle")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textSecondary)
                kinSection
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("onboarding.emergency.doctor", text: $draft.emergencyDoctor)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(appearance.colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                TextField("onboarding.emergency.hospital", text: $draft.localHospital)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(appearance.colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if showSaveFailure {
                Text("profile.error.saveFailed")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
            }

            primaryButton(key: "onboarding.next", typography: appearance.typography) { saveAndAdvance() }
        }
        .onAppear(perform: prefill)
    }

    // MARK: kin list (or the minimal inline add form when none exists)

    @ViewBuilder
    private var kinSection: some View {
        if coordinator.familyContacts.isEmpty {
            inlineAddForm
        } else {
            VStack(spacing: 10) {
                ForEach(coordinator.familyContacts, id: \.id) { contact in
                    kinRow(contact)
                }
            }
        }
    }

    private var inlineAddForm: some View {
        VStack(spacing: 10) {
            Text("onboarding.stepFamily.body")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("onboarding.stepFamily.name", text: $inlineName)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(appearance.colors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            TextField("onboarding.stepFamily.phone", text: $inlinePhone)
                .keyboardType(.phonePad)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(appearance.colors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            TextField("onboarding.stepFamily.relationship", text: $inlineRelationship)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(appearance.colors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    /// One tap designates the single next-of-kin: the tapped contact is
    /// flagged true, every other flagged contact is cleared — the wizard
    /// produces the singular designation; plural flags remain legal in
    /// the store and keep resolving through the shipped preferred-rule.
    /// Current values (nickname/address/email) are passed through so the
    /// flag write never clears a field edited elsewhere.
    private func kinRow(_ contact: FamilyContact) -> some View {
        Button { designate(contact) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .medium))
                        .foregroundStyle(appearance.colors.textPrimary)
                    if !contact.phone.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(contact.phone)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if contact.isEmergencyContact {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(appearance.colors.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                    .stroke(contact.isEmergencyContact ? appearance.colors.accent : Color.clear,
                            lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(contact.name))
        .accessibilityHint(Text("onboarding.emergency.kinTitle"))
    }

    private func designate(_ contact: FamilyContact) {
        showSaveFailure = false
        var allSucceeded = true
        for entry in KinDesignation.plan(contacts: coordinator.familyContacts,
                                         tapped: contact) {
            if !coordinator.updateFamilyContact(
                id: entry.contact.id,
                name: entry.contact.name,
                phone: entry.contact.phone,
                relationship: entry.contact.relationship,
                messengerHandle: entry.contact.messengerHandle,
                nickname: entry.contact.nickname,
                address: entry.contact.address,
                email: entry.contact.email,
                isEmergencyContact: entry.isEmergencyContact) {
                allSucceeded = false
            }
        }
        showSaveFailure = !allSucceeded
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard case .loaded(let profile) = coordinator.currentProfileSnapshot() else { return }
        draft.emergencyDoctor = profile.emergencyDoctor ?? ""
        draft.localHospital = profile.localHospital ?? ""
    }

    private func saveAndAdvance() {
        showSaveFailure = false

        // No contacts yet: the inline form's non-empty name adds the
        // contact AS the emergency contact (one write, flag true).
        if coordinator.familyContacts.isEmpty {
            let name = inlineName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                guard coordinator.addFamilyContact(
                    name: name,
                    phone: inlinePhone.trimmingCharacters(in: .whitespacesAndNewlines),
                    relationship: inlineRelationship.trimmingCharacters(in: .whitespacesAndNewlines),
                    isEmergencyContact: true) else {
                    showSaveFailure = true
                    return
                }
            }
        }

        let base = coordinator.currentProfileSnapshot().mergeBase
        let merged = draft.merged(into: base)
        let result = coordinator.saveProfile(
            name: merged.name,
            addressAs: merged.addressAs,
            dateOfBirth: merged.dateOfBirth,
            emergencyDoctor: merged.emergencyDoctor,
            localHospital: merged.localHospital,
            // This step edits no photo; the merged record carries the
            // selfie an About-you visit stored (and never erases one).
            photoFilename: merged.photoFilename)
        switch result {
        case .success:
            onNext(.emergencyContacts)
        case .failure:
            showSaveFailure = true
        }
    }
}

// MARK: - Step: Voice fingerprint (T-101)

struct VoiceFingerprintStep: View {
    let coordinator: AppCoordinator
    @Environment(\.appAppearance) private var appearance
    let onNext: (OnboardingState.Step) -> Void

    @StateObject private var enrollment: VoiceEnrollmentSession

    /// Constructed exactly as `VoiceSettingsView` constructs its session
    /// (same embedder selection, same Keychain-backed store, same
    /// coordinator-owned recorder + pipeline suspender) — the wizard and
    /// the Settings screen enroll into the same template store.
    init(coordinator: AppCoordinator,
         onNext: @escaping (OnboardingState.Step) -> Void) {
        self.coordinator = coordinator
        self.onNext = onNext
        let service = SpeakerBiometricService(
            embedder: SpeakerEmbedderSelection.make(),
            store: .makeKeychainBacked())
        _enrollment = StateObject(wrappedValue: VoiceEnrollmentSession(
            service: service,
            recorder: coordinator.makeEnrollmentSampleRecorder(),
            pipelineSuspender: coordinator))
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepVoiceFingerprint.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepVoiceFingerprint.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                statusLine
                recordButton
                if case .failed = enrollment.phase {
                    Button {
                        enrollment.dismissFailure()
                    } label: {
                        Text("common.close")
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundStyle(appearance.colors.accent)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Skippable like every step: Next never depends on phase.
            primaryButton(key: "onboarding.next", typography: appearance.typography) { onNext(.voiceFingerprint) }
        }
        .onDisappear {
            // Same mid-recording teardown as `VoiceSettingsView` (rework
            // pass 1, D-1): every exit (Next, Skip, Back, dismissal) is
            // live while recording, and backing out must not leave the
            // pipeline suspended or the mic tap installed. stopRecording
            // is a no-op unless a sample is actually being recorded —
            // and it is also the normal resume path.
            Task { await enrollment.stopRecording() }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch enrollment.phase {
        case .idle, .failed:
            Text(L10n.fmt("onboarding.voiceFingerprint.progress",
                          locale: coordinator.activeLocale,
                          sampleNumber,
                          VoiceEnrollmentSession.requiredSampleCount))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
        case .recording:
            Text("voiceSettings.biometric.enroll.recordingHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.stateListening)
        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                Text("voiceSettings.biometric.enroll.processing")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(appearance.colors.accent)
                Text("onboarding.voiceFingerprint.done")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.accent)
            }
        }
        if case .failed(let failure) = enrollment.phase {
            Text(failureText(failure))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.stateError)
                .multilineTextAlignment(.center)
        }
    }

    private var recordButton: some View {
        let isRecording: Bool
        let isProcessing: Bool
        let isComplete: Bool
        switch enrollment.phase {
        case .recording: isRecording = true; isProcessing = false; isComplete = false
        case .processing: isRecording = false; isProcessing = true; isComplete = false
        case .idle, .failed: isRecording = false; isProcessing = false; isComplete = false
        case .ready: isRecording = false; isProcessing = false; isComplete = true
        }
        return Group {
            if isComplete {
                EmptyView()
            } else {
                Button {
                    if isRecording {
                        Task { await enrollment.stopRecording() }
                    } else {
                        Task { await enrollment.startRecording() }
                    }
                } label: {
                    Text(LocalizedStringKey(isRecording
                                            ? "onboarding.voiceFingerprint.stop"
                                            : "onboarding.voiceFingerprint.record"))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(isRecording ? DesignTokens.stateError : appearance.colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
    }

    /// 1-based number of the sample being recorded next (or the one just
    /// banked while idle) — same derivation as the Settings screen.
    private var sampleNumber: Int {
        switch enrollment.phase {
        case .recording:
            return enrollment.collectedCount + 1
        case .idle, .processing, .failed, .ready:
            return min(enrollment.collectedCount + 1,
                       VoiceEnrollmentSession.requiredSampleCount)
        }
    }

    /// Same copy mapping as `VoiceSettingsView.failureText` — the
    /// existing `voiceSettings.biometric.enroll.failed.*` keys, sample
    /// numbers 1-based, all resolved through `L10n` for the app language.
    private func failureText(_ failure: VoiceEnrollmentSession.VoiceEnrollmentFailure) -> String {
        switch failure {
        case .assistantBusy:
            return L10n.str("voiceSettings.biometric.enroll.failed.busy",
                            locale: coordinator.activeLocale)
        case .microphonePermissionDenied:
            return L10n.str("voiceSettings.biometric.enroll.failed.micDenied",
                            locale: coordinator.activeLocale)
        case .noAudioInput:
            return L10n.str("voiceSettings.biometric.enroll.failed.noInput",
                            locale: coordinator.activeLocale)
        case .audioUnavailable:
            return L10n.str("voiceSettings.biometric.enroll.failed.audioUnavailable",
                            locale: coordinator.activeLocale)
        case .sampleQualityFailed(let index, let issue):
            let sample = index + 1
            switch issue {
            case .speechTooShort:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.speechTooShort",
                                locale: coordinator.activeLocale, sample)
            case .tooNoisy:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.tooNoisy",
                                locale: coordinator.activeLocale, sample)
            case .tooQuiet:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.tooQuiet",
                                locale: coordinator.activeLocale, sample)
            case .none:
                return L10n.str("voiceSettings.biometric.enroll.failed.processing",
                                locale: coordinator.activeLocale)
            }
        case .sampleInconsistent(let index):
            return L10n.fmt("voiceSettings.biometric.enroll.failed.inconsistent",
                            locale: coordinator.activeLocale, index + 1)
        case .serviceDisabled:
            return L10n.str("voiceSettings.biometric.enroll.failed.disabled",
                            locale: coordinator.activeLocale)
        case .saveFailed:
            return L10n.str("voiceSettings.biometric.enroll.failed.save",
                            locale: coordinator.activeLocale)
        case .processingFailed:
            return L10n.str("voiceSettings.biometric.enroll.failed.processing",
                            locale: coordinator.activeLocale)
        }
    }
}
