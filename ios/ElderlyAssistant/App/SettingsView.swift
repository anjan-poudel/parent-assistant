import SwiftUI

/// Settings (spec §4.4): five sections — Language & region, Family &
/// emergency contacts, Medication schedule, AI मोडेल, Privacy & about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Redesign spec §3.3: AI Models is buried behind a long-press on the
    /// title, not a normal row — there's no caregiver app yet for someone
    /// to manage STT/LLM downloads through, so the capability has to stay
    /// reachable, just not one plain tap away from an elderly user's
    /// normal navigation.
    @State private var showHiddenAIModels = false

    enum SettingsSection: Identifiable {
        case language, family, meds, geminiAI, voiceEngine, wakeWord, ttsVoices, privacy, intentLog

        var id: String {
            switch self {
            case .language: return "language"
            case .family: return "family"
            case .meds: return "meds"
            case .geminiAI: return "geminiAI"
            case .voiceEngine: return "voiceEngine"
            case .wakeWord: return "wakeWord"
            case .ttsVoices: return "ttsVoices"
            case .privacy: return "privacy"
            case .intentLog: return "intentLog"
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
                        .onLongPressGesture(minimumDuration: 1.5) {
                            showHiddenAIModels = true
                        }
                    Spacer()
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 12) {
                        sectionRow(.language, icon: "globe", titleKey: "settings.language.title")
                        geminiSectionRow
                        voiceEngineSectionRow
                        wakeWordSectionRow
                        ttsVoicesSectionRow
                        sectionRow(.family, icon: "person.2.fill", titleKey: "settings.family.title")
                        sectionRow(.meds, icon: "pills.fill", titleKey: "settings.meds.title")
                        sectionRow(.privacy, icon: "lock.shield.fill", titleKey: "settings.privacy.title")
                        sectionRow(.intentLog, icon: "checklist", titleKey: "settings.intentLog.title")
                        Text("settings.ai.hiddenHint")
                            .font(.system(size: 11))
                            .foregroundColor(DesignTokens.textSecondary.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
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
            case .geminiAI: GeminiAPISettingsView()
            case .voiceEngine: VoiceEngineSettingsView()
            case .wakeWord: WakeWordSettingsView()
            case .ttsVoices: TTSVoicesSettingsView()
            case .privacy: PrivacySettingsView()
            case .intentLog: IntentLogReviewView()
            }
        }
        .sheet(isPresented: $showHiddenAIModels) {
            NavigationStack { AIModelsSettingsView() }
        }
    }

    /// Visible, not buried — unlike the legacy on-device AI Models screen,
    /// this is load-bearing infrastructure in v2 (no key = no assistant),
    /// so it stays a normal, prominent row with a live status indicator.
    @EnvironmentObject private var coordinator: AppCoordinator
    private var geminiSectionRow: some View {
        NavigationLink(value: SettingsSection.geminiAI) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .frame(width: 40)
                Text("settings.gemini.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(coordinator.geminiConfigStore.isConfigured ? DesignTokens.accent : DesignTokens.stateError)
                        .frame(width: 8, height: 8)
                    Text(coordinator.geminiConfigStore.isConfigured
                         ? "settings.gemini.statusConnected"
                         : "settings.gemini.statusMissing")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
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

    /// On-device vs Gemini A/B toggle. Visible (not buried) like the
    /// Gemini row above it — this is the control that actually decides
    /// which of the two live, since flipping it doesn't require a
    /// restart (see `AppCoordinator.applyVoiceEngineStack`).
    private var voiceEngineSectionRow: some View {
        NavigationLink(value: SettingsSection.voiceEngine) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .frame(width: 40)
                Text("settings.voiceEngine.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(DesignTokens.accent)
                        .frame(width: 8, height: 8)
                    Text(coordinator.voiceEngineStack == .gemini
                         ? "settings.voiceEngine.statusGemini"
                         : "settings.voiceEngine.statusOnDevice")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
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


    /// Voice activation — "Hey Sahayak" wake word (open item #4). The dot
    /// color + label come from the same `wakeWordStatus` derivation the
    /// destination screen shows, so the row can never disagree with the
    /// screen (unit-tested logic in `WakeWordStatusResolver`).
    private var wakeWordSectionRow: some View {
        let status = coordinator.wakeWordStatus
        return NavigationLink(value: SettingsSection.wakeWord) {
            HStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .frame(width: 40)
                Text("wakeWord.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.presentationColor)
                        .frame(width: 8, height: 8)
                    Text(status.shortTitleKey)
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
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

    /// On-device TTS voices (Piper VITS via sherpa-onnx). Status surfaces
    /// the 2026-09-06 failure mode — a build without the bundled voice
    /// files silently fell back to no speech for Nepali.
    private var ttsVoicesSectionRow: some View {
        NavigationLink(value: SettingsSection.ttsVoices) {
            HStack(spacing: 14) {
                Image(systemName: "speaker.waveform.2.fill")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .frame(width: 40)
                Text("settings.voices.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(ttsVoiceSummary.ok ? DesignTokens.accent : DesignTokens.stateError)
                        .frame(width: 8, height: 8)
                    Text(ttsVoiceSummary.key)
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
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

    /// Green when every catalog voice can speak (installed, or bundled
    /// and installable on first use); red the moment any voice is truly
    /// missing from the build.
    private var ttsVoiceSummary: (ok: Bool, key: LocalizedStringKey) {
        let entries = ModelCatalog.entries(kind: .tts)
        let allOK = entries.allSatisfy {
            TTSVoicesSettingsView.status(for: $0, modelStore: coordinator.modelStore) != .missing
        }
        let anyInstalled = entries.contains {
            TTSVoicesSettingsView.status(for: $0, modelStore: coordinator.modelStore) == .installed
        }
        if !allOK { return (false, "settings.voices.statusMissing") }
        return (true, anyInstalled
                ? "settings.voices.statusInstalled"
                : "settings.voices.statusBundled")
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

// MARK: - Gemini API key (v2 pivot — see
// docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md §3.2)

/// Lets a family member paste in the Gemini API key that powers the whole
/// v2 assistant (STT + intent understanding). Unlike the legacy on-device
/// "AI मोडेल" screen, this is NOT buried — without a key configured here,
/// the assistant falls all the way back to the deterministic keyword
/// layer and the English-only SFSpeechRecognizer bootstrap, so it needs
/// to be easy to find during setup.
struct GeminiAPISettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftKey: String = ""
    @State private var showClearConfirm = false
    @State private var customModel: String = ""

    private var isCustomModelSelected: Bool {
        !GeminiModelCatalog.entries.contains { $0.id == coordinator.geminiConfigStore.model }
    }

    var body: some View {
        LeafScreen(titleKey: "settings.gemini.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("settings.gemini.explanation")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)

                costGovernorCard

                modelPicker

                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.gemini.fieldLabel")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textSecondary)
                    SecureField("settings.gemini.fieldPlaceholder", text: $draftKey)
                        .font(.system(size: DesignTokens.minBodyPointSize, design: .monospaced))
                        .padding(14)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.background)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                                .stroke(DesignTokens.textSecondary.opacity(0.25), lineWidth: 1)
                        )
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

                Button {
                    coordinator.geminiConfigStore.save(draftKey)
                    draftKey = ""
                } label: {
                    Text("settings.gemini.save")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: DesignTokens.minTapTargetSize)
                        .background(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? DesignTokens.textSecondary.opacity(0.4) : DesignTokens.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.geminiConfigStore.isConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DesignTokens.accent)
                        Text("settings.gemini.statusConnected")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("settings.gemini.remove")
                                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .confirmationDialog("settings.gemini.removeConfirm", isPresented: $showClearConfirm) {
            Button("settings.gemini.remove", role: .destructive) {
                coordinator.geminiConfigStore.clear()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    /// Daily-cost card (open item #5, 2026-09-06): today's Gemini usage
    /// against the family-set soft cap + the cap editor. Family-facing
    /// only — the elderly primary user never sees this screen, and when
    /// the cap is hit the assistant's existing keyword fallback /
    /// reprompt carries the turn invisibly.
    private var costGovernorCard: some View {
        GeminiCostCard(governor: coordinator.geminiCostGovernor,
                       locale: coordinator.activeLocale)
    }

    /// Model picker (2026-09-04 field request — "let me try different
    /// options"). Curated list (`GeminiModelCatalog`) plus a free-text
    /// override for anything else, since the full live model catalog
    /// includes image/TTS/preview entries not worth enumerating here.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.gemini.modelLabel")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(GeminiModelCatalog.entries) { entry in
                modelRow(id: entry.id, labelKey: entry.labelKey, descriptionKey: entry.descriptionKey)
            }
            modelRow(id: nil, labelKey: "settings.gemini.model.custom", descriptionKey: "settings.gemini.model.custom.desc")
            if isCustomModelSelected || !customModel.isEmpty {
                TextField("settings.gemini.model.customPlaceholder", text: $customModel)
                    .font(.system(size: DesignTokens.minBodyPointSize, design: .monospaced))
                    .padding(12)
                    .background(DesignTokens.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit {
                        coordinator.geminiConfigStore.saveModel(customModel)
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// `id == nil` renders the "custom" row, selected whenever the active
    /// model isn't one of the curated entries.
    private func modelRow(id: String?, labelKey: String, descriptionKey: String) -> some View {
        let isSelected = id == nil ? isCustomModelSelected : coordinator.geminiConfigStore.model == id
        return Button {
            if let id {
                customModel = ""
                coordinator.geminiConfigStore.saveModel(id)
            }
            // Selecting "custom" just reveals the text field above —
            // saving happens on submit once they've typed something.
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? DesignTokens.accent : DesignTokens.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(labelKey))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Text(LocalizedStringKey(descriptionKey))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                Spacer()
            }
            .frame(minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }
}

/// Cost-governance card inside the Gemini settings screen (open item #5,
/// 2026-09-06). `@ObservedObject` on the governor so today's count and
/// the cap value update live while the screen is open (the governor
/// publishes from the main queue). Numbers render in Devanagari digits in
/// the Nepali locale — the same convention as the festival reminder card.
private struct GeminiCostCard: View {
    @ObservedObject var governor: GeminiCostGovernor
    let locale: Locale

    private var count: Int { governor.callsToday }
    private var cap: Int { governor.softDailyCap }
    private var warningThreshold: Int { GeminiCostGovernor.warningThreshold(cap: cap) }

    /// 0...1 for the progress bar; count may exceed cap (in-flight
    /// attempts after the cap was crossed), so clamp for display.
    private var progress: Double {
        cap > 0 ? min(1, Double(count) / Double(cap)) : 0
    }

    private var progressTint: Color {
        count >= cap ? DesignTokens.stateError : DesignTokens.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("settings.gemini.cost.title", systemImage: "number.circle.fill")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            HStack(spacing: 10) {
                Text(L10n.fmt("settings.gemini.cost.usage", locale: locale,
                              Self.number(count, locale: locale),
                              Self.number(cap, locale: locale)))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(count >= cap ? DesignTokens.stateError : DesignTokens.textPrimary)
                Spacer()
            }
            ProgressView(value: progress)
                .tint(progressTint)
            HStack {
                Text("settings.gemini.cost.capLabel")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                Stepper(value: Binding(
                    get: { cap },
                    set: { governor.setSoftDailyCap($0) }
                ), in: GeminiCostGovernor.minimumSoftDailyCap...GeminiCostGovernor.maximumSoftDailyCap,
                step: 10) {
                    Text(Self.number(cap, locale: locale))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            if count >= cap {
                Text("settings.gemini.cost.reachedToday")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.stateError)
            } else if count >= warningThreshold {
                Text("settings.gemini.cost.nearLimit")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.stateListening)
            }
            Text("settings.gemini.cost.explanation")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Devanagari digits in the Nepali locale (elder-facing numeral
    /// convention), Arabic elsewhere.
    private static func number(_ value: Int, locale: Locale) -> String {
        if locale.language.languageCode?.identifier == "ne" {
            return BikramSambat.devanagariDigits(value)
        }
        return String(value)
    }
}

// MARK: - On-device vs Gemini voice-engine toggle
//
// Lets the household A/B test the two voice engine stacks without
// rebuilding: the cloud v2 Gemini pivot (default) versus the legacy
// on-device Whisper+LLaMA pipeline it superseded (still present in the
// build, see `AppCoordinator.llamaCommandInterpreter` /
// `whisperSpeechRecognizer`). Switching is instant — no restart — via
// `AppCoordinator.applyVoiceEngineStack()`.
struct VoiceEngineSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.voiceEngine.title") {
            VStack(spacing: 16) {
                Text("settings.voiceEngine.explanation")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)

                stackRow(
                    .gemini,
                    titleKey: "settings.voiceEngine.gemini",
                    subtitleKey: coordinator.geminiConfigStore.isConfigured
                        ? "settings.voiceEngine.gemini.ready"
                        : "settings.voiceEngine.gemini.notReady"
                )

                stackRow(
                    .onDevice,
                    titleKey: "settings.voiceEngine.onDevice",
                    subtitleKey: coordinator.isOnDeviceStackReady
                        ? "settings.voiceEngine.onDevice.ready"
                        : "settings.voiceEngine.onDevice.notReady"
                )
            }
        }
    }

    private func stackRow(_ stack: VoiceEngineStack, titleKey: String, subtitleKey: String) -> some View {
        let isSelected = coordinator.voiceEngineStack == stack
        return Button {
            coordinator.voiceEngineStack = stack
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? DesignTokens.accent : DesignTokens.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(titleKey))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Text(LocalizedStringKey(subtitleKey))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Wake word "Hey Sahayak" (open item #4) — Voice activation
//
// Family-facing "Voice activation" screen. Its one job is honest status:
// everything that must be true for the wake word to actually listen (the
// Settings toggle ON, the Porcupine runtime linked into the build, a
// Picovoice access key, the trained keyword file bundled) is shown
// explicitly, and every non-active state names the concrete next step —
// no dead ends (spec §7). Until ALL pieces exist the app keeps
// `NullWakeWordEngine` (today's exact behavior), which this screen says
// plainly instead of pretending otherwise.
//
// Presentation mapping shared between the Settings row dot and this
// screen's banner (2026-09-06). `WakeWordStatus` itself is pure logic in
// Services/Voice/WakeWordConfig.swift (unit-tested); only the color/text
// choices live here.
extension WakeWordStatus {
    var presentationColor: Color {
        switch self {
        case .active: return DesignTokens.accent
        case .off: return DesignTokens.stateStopped
        case .needsSetup: return DesignTokens.stateError
        case .restartToActivate: return DesignTokens.stateListening
        }
    }

    /// Short label for the Settings row's status dot.
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .active: return "wakeWord.status.active"
        case .off: return "wakeWord.status.off"
        case .needsSetup: return "wakeWord.status.needsSetup"
        case .restartToActivate: return "wakeWord.status.restartToActivate"
        }
    }
}

struct WakeWordSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftKey: String = ""
    @State private var showRemoveConfirm = false

    var body: some View {
        LeafScreen(titleKey: "wakeWord.title") {
            VStack(alignment: .leading, spacing: 12) {
                Text("wakeWord.explanation")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)

                statusBlock(coordinator.wakeWordStatus)

                toggleCard

                accessKeyCard

                if coordinator.wakeWordStatus != .active {
                    Text("wakeWord.talkStillWorks")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .confirmationDialog("wakeWord.removeConfirm", isPresented: $showRemoveConfirm) {
            Button("wakeWord.remove", role: .destructive) {
                coordinator.wakeWordAccessKeyStore.clear()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    /// One colored card per status — title line plus a plain-language
    /// explanation. `.needsSetup` additionally lists the missing pieces
    /// (see `setupChecklist`).
    @ViewBuilder
    private func statusBlock(_ status: WakeWordStatus) -> some View {
        switch status {
        case .active:
            statusCard(color: DesignTokens.accent,
                       titleKey: "wakeWord.active.title",
                       detailKey: "wakeWord.active.detail")
        case .off:
            statusCard(color: DesignTokens.stateStopped,
                       titleKey: "wakeWord.off.title",
                       detailKey: "wakeWord.off.detail")
        case .needsSetup:
            statusCard(color: DesignTokens.stateError,
                       titleKey: "wakeWord.needsSetup.title",
                       detailKey: "wakeWord.needsSetup.detail")
            setupChecklist
        case .restartToActivate:
            statusCard(color: DesignTokens.stateListening,
                       titleKey: "wakeWord.restart.title",
                       detailKey: "wakeWord.restart.detail")
        }
    }

    private func statusCard(color: Color,
                            titleKey: LocalizedStringKey,
                            detailKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                Text(titleKey)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            Text(detailKey)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Renders ONLY the absent pieces, each keyed to the coordinator's own
    /// provisioning truth (`isWakeWordRuntimeLinked` /
    /// `isWakeWordAccessKeyConfigured` / `WakeWordModelFile.bundledPath()`
    /// — the same inputs the launch engine decision used), so the checklist
    /// can never contradict the status banner above it.
    private var setupChecklist: some View {
        VStack(spacing: 10) {
            if !AppCoordinator.isWakeWordRuntimeLinked {
                missingRow("wakeWord.setupNeedsRuntime")
            }
            if !coordinator.isWakeWordAccessKeyConfigured {
                missingRow("wakeWord.setupNeedsKey")
            }
            if WakeWordModelFile.bundledPath() == nil {
                missingRow("wakeWord.setupNeedsModel")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func missingRow(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(DesignTokens.stateError)
            Text(LocalizedStringKey(key))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// The on/off master switch. ON is the default (inert until the other
    /// pieces exist — see `WakeWordPreferences`); the coordinator's didSet
    /// persists it AND closes/opens the live audio gate, so switching OFF
    /// here stops the mic feed to the wake-word engine immediately. The
    /// battery trade-off is disclosed underneath (honesty requirement).
    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.wakeWordEnabled },
                set: { coordinator.wakeWordEnabled = $0 }
            )) {
                Text("wakeWord.toggleLabel")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            if coordinator.wakeWordEnabled {
                Text("wakeWord.batteryNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Picovoice access-key paste-in — an exact mirror of the Gemini key
    /// card. This is the family mechanism: get a free key at
    /// console.picovoice.ai, paste it here. Stored in the iPhone's secure
    /// Keychain via `EncryptedLocalStorage` (never UserDefaults, never
    /// hardcoded). The key card is always editable — even when Porcupine
    /// isn't linked yet — so setup survives a later app rebuild.
    private var accessKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("wakeWord.keyLabel")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            Text("wakeWord.keyDescription")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
            SecureField("wakeWord.keyPlaceholder", text: $draftKey)
                .font(.system(size: DesignTokens.minBodyPointSize, design: .monospaced))
                .padding(14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                        .stroke(DesignTokens.textSecondary.opacity(0.25), lineWidth: 1)
                )
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button {
                coordinator.wakeWordAccessKeyStore.save(draftKey)
                draftKey = ""
            } label: {
                Text("wakeWord.save")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? DesignTokens.textSecondary.opacity(0.4) : DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if coordinator.wakeWordAccessKeyStore.isConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DesignTokens.accent)
                    Text("wakeWord.keySaved")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                    Spacer()
                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Text("wakeWord.remove")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

// MARK: - 2. Family & emergency contacts (spec §4.4.2)

struct FamilyContactsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var showingAdd = false
    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""
    @State private var messengerHandle = ""

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
                if let handle = contact.messengerHandle, !handle.isEmpty {
                    Text(L10n.fmt("settings.family.messengerHandle",
                                  locale: coordinator.activeLocale, handle))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
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
            TextField(LocalizedStringKey("onboarding.stepFamily.messenger"), text: $messengerHandle)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .keyboardType(.asciiCapable)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Text("onboarding.stepFamily.messengerHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            Button {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let handle = messengerHandle.trimmingCharacters(in: .whitespacesAndNewlines)
                coordinator.addFamilyContact(name: trimmed, phone: phone,
                                             relationship: relationship,
                                             messengerHandle: handle.isEmpty ? nil : handle)
                name = ""; phone = ""; relationship = ""; messengerHandle = ""
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
                festivalReminderCard
                calendarSyncCard
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

    /// EventKit mirror toggle (v2 design §4.1) — requests calendar
    /// access at point of use; denial leaves the app fully working in
    /// local-only mode, honestly reported.
    private var calendarSyncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.calendarSync.isEnabled },
                set: { newValue in
                    Task { await coordinator.setCalendarSyncEnabled(newValue) }
                }
            )) {
                Label("calendarSync.toggle", systemImage: "calendar")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            Text(statusText)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Advance-reminder days for important festivals (BS calendar,
    /// 2026-09-06) — default 2, family-configurable. Changing it
    /// reschedules festival notifications immediately.
    private var festivalReminderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("festival.reminderTitle", systemImage: "bell.badge")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            HStack {
                Text("festival.reminderDays")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                Stepper(value: Binding(
                    get: { coordinator.festivalCalendar.advanceReminderDays },
                    set: { newValue in
                        coordinator.festivalCalendar.advanceReminderDays = newValue
                        coordinator.festivalCalendar.scheduleAll()
                    }
                ), in: 0...7) {
                    Text(BikramSambat.devanagariDigits(coordinator.festivalCalendar.advanceReminderDays))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            Text("festival.reminderHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var statusText: String {
        switch coordinator.calendarSync.status {
        case .enabled: return L10n.str("calendarSync.statusOn", locale: coordinator.activeLocale)
        case .denied: return L10n.str("calendarSync.statusDenied", locale: coordinator.activeLocale)
        case .error: return L10n.str("calendarSync.statusError", locale: coordinator.activeLocale)
        case .notRequested: return L10n.str("calendarSync.statusHint", locale: coordinator.activeLocale)
        }
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
                    // Every catalog STT engine is offered — cached AND
                    // not-yet-downloaded alike (a cached-only list hid
                    // everything but the user's 1–2 installed models).
                    // Picking an engine that isn't installed starts its
                    // download (see `sttSelection`); the downloads card
                    // below shows per-row progress.
                    Picker("settings.ai.selection",
                           selection: sttSelection) {
                        Text("settings.ai.automatic").tag(Optional<ModelID>.none)
                        ForEach(ModelCatalog.availableSTTEntries, id: \.id) { entry in
                            Text(Self.sttOptionLabel(entry: entry,
                                                     downloaded: isInstalled(entry.id),
                                                     locale: coordinator.appLanguage.locale))
                                .tag(Optional(entry.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DesignTokens.accent)
                    if !hasAnySTTInstalled {
                        Text("model.notDownloaded")
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.brain.selection")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    // Every real brain artifact is offered — cached AND
                    // not-yet-downloaded alike (the STT picker's lesson:
                    // a cached-only list hides everything but 1–2 rows).
                    // Picking one that isn't installed starts its
                    // download (`brainModelPreference`'s didSet does
                    // that, same contract as the STT picker); the
                    // downloads card below shows per-row progress.
                    Picker("settings.brain.selection",
                           selection: brainSelection) {
                        Text("settings.ai.automatic").tag(Optional<ModelID>.none)
                        ForEach(ModelCatalog.availableBrainEntries, id: \.id) { entry in
                            Text(Self.sttOptionLabel(entry: entry,
                                                     downloaded: isInstalled(entry.id),
                                                     locale: coordinator.appLanguage.locale))
                                .tag(Optional(entry.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DesignTokens.accent)
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
                                state: downloadState(for: id),
                                onStart: { downloads.start(id) },
                                onCancel: { downloads.cancel(id) },
                                onDelete: {
                                    try? coordinator.modelStore.delete(id)
                                    downloads.reset(id)
                                    if coordinator.sttModelPreference == id {
                                        coordinator.sttModelPreference = nil
                                    }
                                    // Deleting the brain the picker is
                                    // currently set to falls back to the
                                    // default (same truthfulness rule as
                                    // the STT handling above).
                                    if coordinator.brainModelPreference == id {
                                        coordinator.brainModelPreference = nil
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
            // A finished install can flip which recognizer/model the
            // "STT in use" caption should claim (e.g. WhisperKit lands →
            // the ANE recognizer becomes available) — the coordinator
            // only recomputes that label on preference/stack changes.
            .onReceive(downloads.$states) { states in
                let someCompleted = states.values.contains { state in
                    if case .completed = state { return true }
                    return false
                }
                if someCompleted {
                    coordinator.updateActiveSTTName()
                }
            }
        }
    }

    /// Picker selection: sets the persisted preference (existing
    /// `sttModelPreference` flow) AND — when the chosen engine is not
    /// installed yet — starts its download through the existing
    /// `ModelDownloadService` so a fresh pick works immediately. Rows
    /// below surface progress; once the install completes the picker
    /// label sheds its "not downloaded" suffix and the recognizer
    /// resolves the preference (it loads whatever model is cached).
    private var sttSelection: Binding<ModelID?> {
        Binding(
            get: { coordinator.sttModelPreference },
            set: { newValue in
                coordinator.sttModelPreference = newValue
                if let newValue {
                    startDownloadIfNeeded(newValue)
                }
            }
        )
    }

    /// Brain picker selection: writes `brainModelPreference`. The
    /// coordinator's didSet already starts the chosen model's download
    /// when it isn't cached (the same fresh-pick contract as the STT
    /// picker), so this binding stays a thin passthrough — no second
    /// download kick here.
    private var brainSelection: Binding<ModelID?> {
        Binding(
            get: { coordinator.brainModelPreference },
            set: { coordinator.brainModelPreference = $0 }
        )
    }

    private func startDownloadIfNeeded(_ id: ModelID) {
        guard !isInstalled(id) else { return }
        switch downloads.states[id] ?? .notStarted {
        case .notStarted, .failed, .cancelled:
            downloads.start(id)
        case .queued, .downloading, .verifying, .completed:
            break   // already in flight (or just finished)
        }
    }

    /// Directory-aware installed check: WhisperKit artifacts are model
    /// directories (`ModelStore.isCached` only sees single files), and a
    /// service `.completed` state counts even before the store query.
    private func isInstalled(_ id: ModelID) -> Bool {
        if downloads.states[id] == .completed { return true }
        guard let entry = ModelCatalog.entry(for: id) else { return false }
        return coordinator.modelStore.isInstalled(entry)
    }

    private var hasAnySTTInstalled: Bool {
        ModelCatalog.availableSTTEntries.contains { isInstalled($0.id) }
    }

    /// Row state for the downloads list: the service's live state wins;
    /// otherwise derive from what is on disk (directory-aware so an
    /// installed WhisperKit model reads as Ready, not Download).
    private func downloadState(for id: ModelID) -> ModelDownloadState {
        if let state = downloads.states[id] { return state }
        guard let entry = ModelCatalog.entry(for: id) else { return .notStarted }
        return coordinator.modelStore.isInstalled(entry) ? .completed : .notStarted
    }

    /// Picker row text: the localized model name, plus an honest
    /// "not downloaded yet" note whenever the artifact isn't installed.
    /// Pure (the view computes `downloaded` from store + service state)
    /// so tests can pin both label states.
    static func sttOptionLabel(entry: ModelCatalogEntry,
                               downloaded: Bool,
                               locale: Locale) -> String {
        let name = entry.displayName(locale: locale)
        guard !downloaded else { return name }
        return "\(name) — \(L10n.str("model.notDownloaded", locale: locale))"
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

// MARK: - TTS voices (on-device Piper VITS)

/// Per-voice install status for the on-device TTS voices
/// (docs/tts-implementation-plan.md). Exists because the 2026-09-06 field
/// failure was invisible: a build without the bundled voice files fell
/// back to silence for Nepali and nobody could tell why.
struct TTSVoicesSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    enum VoiceStatus {
        case installed   // in the ModelStore, ready to speak
        case bundled     // inside the app bundle; installs on first use
        case missing     // neither — this voice cannot speak in this build
    }

    static func status(for entry: ModelCatalogEntry,
                       modelStore: ModelStore,
                       bundle: Bundle = .main) -> VoiceStatus {
        if modelStore.isCached(entry.id) { return .installed }
        if let name = entry.bundledResourceName,
           bundle.url(forResource: name, withExtension: nil, subdirectory: "tts") != nil {
            return .bundled
        }
        return .missing
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
                    Text("settings.voices.title")
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(ModelCatalog.entries(kind: .tts)) { entry in
                            voiceRow(entry)
                        }
                        Button {
                            coordinator.speak(text: L10n.str("settings.voices.sampleGreeting",
                                                             locale: coordinator.activeLocale))
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundColor(DesignTokens.accent)
                                    .frame(width: 40)
                                Text("settings.voices.testButton")
                                    .font(.system(size: DesignTokens.minBodyPointSize,
                                                  weight: .semibold))
                                    .foregroundColor(DesignTokens.textPrimary)
                                Spacer()
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity)
                            .background(DesignTokens.card)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)

                        if ModelCatalog.entries(kind: .tts).contains(where: {
                            Self.status(for: $0, modelStore: coordinator.modelStore) == .missing
                        }) {
                            Text("settings.voices.missingHint")
                                .font(.system(size: DesignTokens.minCaptionPointSize))
                                .foregroundColor(DesignTokens.stateError)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private func voiceRow(_ entry: ModelCatalogEntry) -> some View {
        let status = Self.status(for: entry, modelStore: coordinator.modelStore)
        let nameKey = entry.id == ModelCatalog.piperNepali
            ? "settings.voices.nepali" : "settings.voices.english"
        let (statusKey, statusColor): (LocalizedStringKey, Color) = {
            switch status {
            case .installed: return ("settings.voices.statusInstalled", DesignTokens.accent)
            case .bundled:   return ("settings.voices.statusBundled", DesignTokens.accent)
            case .missing:   return ("settings.voices.statusMissing", DesignTokens.stateError)
            }
        }()
        return HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundColor(DesignTokens.accent)
                .frame(width: 40)
            Text(LocalizedStringKey(nameKey))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusKey)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
