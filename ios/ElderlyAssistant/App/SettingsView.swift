import SwiftUI

/// Settings (spec §4.4): five sections — Language & region, Family &
/// emergency contacts, Medication schedule, AI मोडेल, Privacy & about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    enum SettingsSection: Identifiable {
        case language, family, meds, aiModels, privacy

        var id: String {
            switch self {
            case .language: return "language"
            case .family: return "family"
            case .meds: return "meds"
            case .aiModels: return "ai"
            case .privacy: return "privacy"
            }
        }
    }

    var body: some View {
        ZStack {
            DesignTokens.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(DesignTokens.textPrimary)
                            .frame(width: DesignTokens.minTapTargetSize,
                                   height: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.card)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(Text("common.back"))
                    Text("settings.title")
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 12) {
                        sectionRow(.language, icon: "globe", titleKey: "settings.language.title")
                        sectionRow(.family, icon: "person.2.fill", titleKey: "settings.family.title")
                        sectionRow(.meds, icon: "pills.fill", titleKey: "settings.meds.title")
                        sectionRow(.aiModels, icon: "brain.head.profile", titleKey: "settings.ai.title")
                        sectionRow(.privacy, icon: "lock.shield.fill", titleKey: "settings.privacy.title")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
        // Value-based navigation (iOS 16 pattern) — see HomeView: the
        // isPresented + derived-binding form is fragile on iOS 16.
        .navigationDestination(for: SettingsSection.self) { section in
            switch section {
            case .language: LanguageSettingsView()
            case .family: FamilyContactsSettingsView()
            case .meds: MedicationScheduleSettingsView()
            case .aiModels: AIModelsSettingsView()
            case .privacy: PrivacySettingsView()
            }
        }
    }

    private func sectionRow(_ section: SettingsSection, icon: String,
                            titleKey: String) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .frame(width: 40)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 1. Language & region (spec §4.4.1)

struct LanguageSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.language.title") {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    ForEach(AppLanguage.allCases) { language in
                        languageRow(language)
                    }
                }
                Text("settings.language.region")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = language == coordinator.appLanguage
        return Button {
            coordinator.appLanguage = language
        } label: {
            HStack {
                Text(LocalizedStringKey(language.displayNameKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? DesignTokens.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 2. Family & emergency contacts (spec §4.4.2)

struct FamilyContactsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var showingAdd = false
    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""

    var body: some View {
        LeafScreen(titleKey: "settings.family.title") {
            VStack(spacing: 12) {
                if coordinator.familyContacts.isEmpty {
                    Text("settings.family.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                } else {
                    ForEach(coordinator.familyContacts) { contact in
                        contactRow(contact)
                    }
                }

                if coordinator.familyContacts.count < FamilyContactStore.maxContacts {
                    addForm
                }
            }
        }
    }

    private func contactRow(_ contact: FamilyContact) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(contact.relationship)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                Text(contact.phone)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button(role: .destructive) {
                coordinator.removeFamilyContact(id: contact.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundColor(DesignTokens.stateError)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addForm: some View {
        VStack(spacing: 10) {
            TextField(LocalizedStringKey("onboarding.stepFamily.name"), text: $name)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            TextField(LocalizedStringKey("onboarding.stepFamily.phone"), text: $phone)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .keyboardType(.phonePad)
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            TextField(LocalizedStringKey("onboarding.stepFamily.relationship"), text: $relationship)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Button {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                coordinator.addFamilyContact(name: trimmed, phone: phone,
                                             relationship: relationship)
                name = ""; phone = ""; relationship = ""
            } label: {
                Text("settings.family.add")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.chipHeight)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

// MARK: - 3. Medication schedule editor (spec §4.4.3)

struct MedicationScheduleSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var name = ""
    @State private var time = Date()
    @State private var errorKey: String?

    var body: some View {
        LeafScreen(titleKey: "settings.meds.title") {
            VStack(spacing: 12) {
                if coordinator.medicationEntries.isEmpty {
                    Text("settings.meds.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                } else {
                    ForEach(coordinator.medicationEntries) { entry in
                        medRow(entry)
                    }
                }
                addForm
            }
        }
    }

    private func medRow(_ entry: MedicationEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.medicationName)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(timesText(entry.scheduleTimes))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button(role: .destructive) {
                coordinator.removeMedication(id: entry.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundColor(DesignTokens.stateError)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addForm: some View {
        VStack(spacing: 10) {
            TextField(LocalizedStringKey("settings.meds.name"), text: $name)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            HStack(spacing: 12) {
                Text("settings.meds.time")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.locale, coordinator.appLanguage.locale)
            }
            .padding(14)
            .frame(height: 56)
            .background(DesignTokens.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

            if let errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
            }

            Button {
                let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                errorKey = coordinator.addMedication(name: name, time: components)
                if errorKey == nil { name = "" }
            } label: {
                Text("settings.meds.save")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.chipHeight)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func timesText(_ times: [DateComponents]) -> String {
        times
            .compactMap { components in
                guard let hour = components.hour, let minute = components.minute else {
                    return nil
                }
                return Calendar.current.date(from: components)?.formatted(date: .omitted, time: .shortened)
            }
            .joined(separator: " · ")
    }
}

// MARK: - 4. AI मोडेल (spec §4.4.4, §4.5)

struct AIModelsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed DIRECTLY — the service publishes download state changes;
    // reading through the coordinator never re-renders the rows.
    @EnvironmentObject var downloads: ModelDownloadService

    var body: some View {
        LeafScreen(titleKey: "settings.ai.title") {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.ai.selection")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    if cachedWhisperModels.isEmpty {
                        Text("model.notDownloaded")
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    } else {
                        Picker("settings.ai.selection",
                               selection: $coordinator.sttModelPreference) {
                            Text("settings.ai.automatic").tag(Optional<ModelID>.none)
                            ForEach(cachedWhisperModels, id: \.rawValue) { id in
                                if let entry = ModelCatalog.entry(for: id) {
                                    Text(entry.displayName(locale: coordinator.appLanguage.locale))
                                        .tag(Optional(id))
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(DesignTokens.accent)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.ai.downloads")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    ForEach(coordinator.requiredModelIds, id: \.rawValue) { id in
                        if let entry = ModelCatalog.entry(for: id) {
                            ModelManagementRow(
                                entry: entry,
                                state: downloads.states[id]
                                    ?? (coordinator.modelStore.isCached(id)
                                        ? .completed : .notStarted),
                                onStart: { downloads.start(id) },
                                onCancel: { downloads.cancel(id) },
                                onDelete: {
                                    try? coordinator.modelStore.delete(id)
                                    downloads.reset(id)
                                    if coordinator.sttModelPreference == id {
                                        coordinator.sttModelPreference = nil
                                    }
                                }
                            )
                            Divider()
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundColor(DesignTokens.textSecondary)
                        Text(L10n.fmt("model.sttInUse", locale: coordinator.appLanguage.locale,
                                     L10n.str(coordinator.activeSTTNameKey,
                                              locale: coordinator.appLanguage.locale)))
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            }
        }
    }

    /// Cached whisper models, in required-model download order (spec §4.4.4
    /// picker lists available Whisper variants; only cached ones are
    /// pickable).
    private var cachedWhisperModels: [ModelID] {
        coordinator.requiredModelIds.filter { id in
            guard ModelCatalog.entry(for: id)?.kind == .whisperBase else { return false }
            return coordinator.modelStore.isCached(id)
        }
    }
}

private struct ModelManagementRow: View {
    @Environment(\.locale) private var locale
    let entry: ModelCatalogEntry
    let state: ModelDownloadState
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.displayName(locale: locale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                actionButton
                if case .completed = state {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                            .foregroundColor(DesignTokens.stateError)
                            .frame(width: DesignTokens.minTapTargetSize,
                                   height: DesignTokens.minTapTargetSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            statusLine
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notStarted, .failed, .cancelled:
            Button(action: onStart) {
                Text("model.download")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        case .queued, .downloading, .verifying:
            Button(action: onCancel) {
                Text("model.cancel")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                            .stroke(DesignTokens.textSecondary, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
        case .completed:
            Label("model.active", systemImage: "bolt.fill")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .notStarted:
            Text("model.notDownloaded")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        case .queued:
            Text("model.queued")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        case .downloading(let received, let total):
            let ratio = total > 0 ? Double(received) / Double(total) : 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: ratio)
                    .tint(DesignTokens.accent)
                Text("\(bytes(received)) / \(bytes(total))")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        case .verifying:
            Text("model.verifying")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        case .completed:
            Text("model.ready")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.accent)
        case .failed(let reason):
            Text(L10n.fmt("model.failed", locale: locale, reason))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.stateError)
        case .cancelled:
            Text("model.cancelled")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
    }

    private func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: n)
    }
}

// MARK: - 5. Privacy & about (spec §4.4.5)

struct PrivacySettingsView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        LeafScreen(titleKey: "settings.privacy.title") {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundColor(DesignTokens.accent)
                Text("settings.privacy.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(L10n.fmt("settings.about.version", locale: locale, version))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
            }
            .padding(20)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
    }
}
