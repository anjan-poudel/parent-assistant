import SwiftUI
import UIKit
import PhotosUI

/// Settings hub (spec §4.4): one card per section — Appearance (skinnable
/// app background, 2026-09-07), Language & region, Gemini AI, Voice
/// engine, Voice activation, TTS voices, Quick apps, Family & friends,
/// Medication schedule, AI मोडेल, Privacy & about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Redesign spec §3.3: AI Models is buried behind a long-press on the
    /// title, not a normal row — there's no caregiver app yet for someone
    /// to manage STT/LLM downloads through, so the capability has to stay
    /// reachable, just not one plain tap away from an elderly user's
    /// normal navigation.
    @State private var showHiddenAIModels = false

    enum SettingsSection: Identifiable {
        case appearance, language, calling, places, family, meds, geminiAI, voiceEngine, wakeWord, ttsVoices, webSearch, quickApps, privacy, intentLog, toolLog

        var id: String {
            switch self {
            case .appearance: return "appearance"
            case .language: return "language"
            case .calling: return "calling"
            case .places: return "places"
            case .family: return "family"
            case .meds: return "meds"
            case .geminiAI: return "geminiAI"
            case .voiceEngine: return "voiceEngine"
            case .wakeWord: return "wakeWord"
            case .ttsVoices: return "ttsVoices"
            case .webSearch: return "webSearch"
            case .quickApps: return "quickApps"
            case .privacy: return "privacy"
            case .intentLog: return "intentLog"
            case .toolLog: return "toolLog"
            }
        }
    }

    var body: some View {
        ZStack {
            Color(theme: coordinator.appTheme).ignoresSafeArea()
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
                        // Skinnable app background (2026-09-07) — warm
                        // presets today; a photo-picker background is a
                        // noted future option.
                        sectionRow(.appearance, icon: "paintpalette.fill", titleKey: "settings.appearance.title")
                        sectionRow(.language, icon: "globe", titleKey: "settings.language.title")
                        // Default app for ADDRESS-BOOK call buttons
                        // (Phone-tab redesign, 2026-09-07).
                        sectionRow(.calling, icon: "phone.badge.plus", titleKey: "settings.calling.title")
                        // Saved places + the map voice navigation opens
                        // (directions task, 2026-09-07).
                        sectionRow(.places, icon: "mappin.and.ellipse", titleKey: "settings.places.title")
                        geminiSectionRow
                        voiceEngineSectionRow
                        wakeWordSectionRow
                        ttsVoicesSectionRow
                        // [LOCAL-TOOLS] (2026-09-07) Web search — Google CSE
                        // credentials for the on-device stack's search tool.
                        sectionRow(.webSearch, icon: "magnifyingglass.circle.fill",
                                   titleKey: "searchSettings.title")
                        sectionRow(.quickApps, icon: "square.grid.2x2.fill", titleKey: "settings.quickApps.title")
                        sectionRow(.family, icon: "person.2.fill", titleKey: "settings.family.title")
                        sectionRow(.meds, icon: "pills.fill", titleKey: "settings.meds.title")
                        sectionRow(.privacy, icon: "lock.shield.fill", titleKey: "settings.privacy.title")
                        sectionRow(.intentLog, icon: "checklist", titleKey: "settings.intentLog.title")
                        // [TOOL-DEBUG-LOG] (2026-09-07) Tool requests —
                        // the family-facing debug window over every live
                        // weather/web-search request the on-device stack
                        // made (see LocalToolLogStore).
                        sectionRow(.toolLog, icon: "text.magnifyingglass",
                                   titleKey: "settings.toolLog.title")
                        Text("settings.ai.hiddenHint")
                            .font(.system(size: 14))
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
            case .appearance: AppearanceSettingsView()
            case .language: LanguageSettingsView()
            case .calling: CallingSettingsView()
            case .places: PlacesSettingsView()
            case .family: FamilyContactsSettingsView()
            case .meds: MedicationScheduleSettingsView()
            case .geminiAI: GeminiAPISettingsView()
            case .voiceEngine: VoiceEngineSettingsView()
            case .wakeWord: WakeWordSettingsView()
            case .ttsVoices: TTSVoicesSettingsView()
            case .webSearch: SearchSettingsView()
            case .quickApps: QuickAccessAppsView()
            case .privacy: PrivacySettingsView()
            case .intentLog: IntentLogReviewView()
            case .toolLog: ToolLogReviewView()
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

// MARK: - Web search (local-tools, 2026-09-07)

/// [LOCAL-TOOLS] (2026-09-07) Google Custom Search credentials for the
/// on-device voice stack's web-search tool. Family-facing (the elderly
/// primary user is never asked to handle API keys — same framing as the
/// Gemini key screen): the two SecureFields mirror
/// `GeminiAPISettingsView`'s field style exactly. Search fires only when
/// BOTH halves of the pair exist and the voice engine is on-device; the
/// quota + privacy lines state plainly what the tool does with the
/// user's words.
struct SearchSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftAPIKey = ""
    @State private var draftEngineID = ""
    @State private var showClearConfirm = false

    var body: some View {
        LeafScreen(titleKey: "searchSettings.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("searchSettings.explanation")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)

                VStack(alignment: .leading, spacing: 14) {
                    credentialField(labelKey: "searchSettings.apiKey",
                                    placeholderKey: "searchSettings.apiKey",
                                    text: $draftAPIKey)
                    credentialField(labelKey: "searchSettings.engineId",
                                    placeholderKey: "searchSettings.engineId",
                                    text: $draftEngineID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

                Button {
                    // Empty drafts leave the stored value untouched —
                    // clearing is the explicit Remove action below.
                    let trimmedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedID = draftEngineID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedKey.isEmpty {
                        coordinator.searchConfigStore.saveAPIKey(trimmedKey)
                    }
                    if !trimmedID.isEmpty {
                        coordinator.searchConfigStore.saveSearchEngineID(trimmedID)
                    }
                    draftAPIKey = ""
                    draftEngineID = ""
                } label: {
                    Text("searchSettings.save")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: DesignTokens.minTapTargetSize)
                        .background(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && draftEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? DesignTokens.textSecondary.opacity(0.4) : DesignTokens.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && draftEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.searchConfigStore.isConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DesignTokens.accent)
                        Text("searchSettings.statusConnected")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("searchSettings.remove")
                                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 4)
                }

                Text("searchSettings.quotaNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("searchSettings.privacy")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("searchSettings.removeConfirm", isPresented: $showClearConfirm) {
            Button("searchSettings.remove", role: .destructive) {
                coordinator.searchConfigStore.clear()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    /// One labeled SecureField card — same visual recipe as the Gemini
    /// key field (monospaced, min tap height, outlined bubble).
    private func credentialField(labelKey: LocalizedStringKey,
                                 placeholderKey: LocalizedStringKey,
                                 text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(labelKey)
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            SecureField(placeholderKey, text: text)
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

                // Cloud fallback (cloud-fallback task, 2026-09-07): an
                // OPT-IN escalation for the ON-DEVICE stack — when the
                // local chain cannot answer a question, it may go to the
                // cloud brain. The card exists only under the on-device
                // selection: its captions ("Only the on-device brain
                // answers" …) would lie on the Gemini stack, where the
                // cloud answers by design and this flag is ignored. OFF
                // by default; the toggle's didSet re-applies the stack
                // instantly — no restart (see
                // `AppCoordinator.applyVoiceEngineStack`). A future
                // provider picker ("ask via …") hooks onto
                // `coordinator.cloudProvider` here — today only Gemini
                // exists, so the caption keys off the Gemini key's
                // presence exactly like the Gemini AI row above.
                if coordinator.voiceEngineStack == .onDevice {
                    cloudFallbackCard
                }
            }
        }
    }

    /// The on/off card for on-device cloud escalation — the Wake Word
    /// toggle card's visual language (a Toggle over an honest caption).
    /// Three caption states: ON with a live Gemini key (what happens),
    /// ON without one (stateError, points at Settings → Gemini AI —
    /// mirroring how the Gemini row shows a missing key), OFF.
    private var cloudFallbackCard: some View {
        let fallbackOn = coordinator.cloudFallbackEnabled
        let keyConfigured = coordinator.geminiConfigStore.isConfigured
        let captionKey: LocalizedStringKey
        let captionColor: Color
        switch (fallbackOn, keyConfigured) {
        case (true, false):
            captionKey = "cloudFallback.requiresKey"
            captionColor = DesignTokens.stateError
        case (true, true):
            captionKey = "cloudFallback.on"
            captionColor = DesignTokens.textSecondary
        case (false, _):
            captionKey = "cloudFallback.off"
            captionColor = DesignTokens.textSecondary
        }
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.cloudFallbackEnabled },
                set: { coordinator.cloudFallbackEnabled = $0 }
            )) {
                Text("cloudFallback.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text(captionKey)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(captionColor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
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

// MARK: - 2. Family & friends — curated contacts (spec §4.4.2)
//
// (family-wizard task, 2026-09-07) The Settings editor for the curated
// "Family and friends" list — the primary contact list of the Phone
// tab, capped at `FamilyContactStore.maxContacts`. Adding and editing
// share one five-step wizard (`FamilyContactWizardSheet`): search
// first, then a fixed relationship dropdown, then optional photo,
// messenger handle, nickname and home address (the last two on the
// final step — the address is the voice-navigation target, directions
// task, 2026-09-07) — manual name/number entry appears on
// step 1 only when the search found nobody. An edit opens on the
// relationship step with everything pre-filled and may step back to
// re-search. The row list below is unchanged. Every write goes
// through `AppCoordinator`, which owns the photo store and the record
// store; this view owns neither.

struct FamilyContactsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// The open add/edit sheet — nil when closed. Item-driven so a
    /// swipe-dismiss also clears it (same pattern as CallView's
    /// handle-capture sheet).
    @State private var editorTarget: FamilyContactEditorTarget?

    /// What the add/edit sheet is editing: a blank add, or an existing
    /// contact pre-filled for editing.
    enum FamilyContactEditorTarget: Identifiable {
        case add
        case edit(FamilyContact)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let contact): return contact.id.uuidString
            }
        }
    }

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
                    addButton
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            FamilyContactWizardSheet(target: target)
        }
    }

    /// Opens the add sheet (hidden at the cap — nothing to add).
    private var addButton: some View {
        Button {
            editorTarget = .add
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

    /// One curated-contact card: photo, name/relationship/phone/handle,
    /// and the edit + delete controls.
    private func contactRow(_ contact: FamilyContact) -> some View {
        HStack(spacing: 12) {
            contactPhotoThumb(contact)
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
            Button {
                editorTarget = .edit(contact)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 20))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.family.edit"))
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
            .accessibilityLabel(Text("settings.family.delete"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The row's 44pt visual: the stored photo when one is on file,
    /// else the initials avatar. Photos are best-effort — a missing or
    /// unreadable file reads back as nil and falls through to initials.
    @ViewBuilder
    private func contactPhotoThumb(_ contact: FamilyContact) -> some View {
        let diameter = DesignTokens.iconBadgeDiameter
        if let photo = coordinator.contactPhoto(for: contact) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            FaceAvatar(name: contact.name, diameter: diameter)
        }
    }
}

/// The add/edit wizard of the Family & friends screen (family-wizard
/// task, 2026-09-07). One shared five-step flow for both duties —
/// "search first, then a step wizard; manual entry only when the
/// search finds nobody":
///   1. Find the contact — the native-contacts search SELECTS a person
///      (its result prefills the name + number fields, which appear for
///      confirmation); a prominent "Add manually" action reveals those
///      name + number fields on THIS step. Next needs BOTH.
///   2. Relationship — a MANDATORY dropdown over a fixed localized list
///      (see `RelationshipOption`). The stored value is the chosen
///      option's label; editing recognizes it again by exact label or
///      by its `ContactResolver` anchor (see
///      `preselectedOption(for:)`).
///   3. Photo — OPTIONAL (add / change / remove over the initials
///      avatar).
///   4. Messenger handle — OPTIONAL (with the `messenger.handleHints.*`
///      where-to-look lines from the call leaf's capture sheet).
///   5. Nickname — OPTIONAL, plus the home address (also OPTIONAL;
///      directions task, 2026-09-07 — the address is what makes a
///      relative a voice-navigation target, blank saves as none).
///      Save lives here, enabled only when the
///      mandatory name + number + relationship contract holds.
/// An `.edit` target opens at Step 2 with every field pre-filled and
/// stays free to step back into the search. Save closes the sheet only
/// on success; a failed store write keeps the draft on screen for one
/// more tap (nothing is claimed that didn't happen — same rule as
/// CallView's handle-capture sheet).
///
/// Permission handling mirrors CallView's access card: the ask fires at
/// the point of use behind a plain-language card (the one place the
/// system prompt may appear), and a denial shows the honest blocked
/// line with the search hidden — the manual-entry path stays fully
/// usable with or without contacts access.
private struct FamilyContactWizardSheet: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let target: FamilyContactsSettingsView.FamilyContactEditorTarget

    /// The wizard's five steps, in order; `position` is the 1-based
    /// "Step N of 5" the indicator prints.
    private enum Step: Int, CaseIterable {
        case find, relationship, photo, messenger, nickname
        var position: Int { rawValue + 1 }
    }

    /// The relationship dropdown's FIXED options (family-wizard task,
    /// 2026-09-07). The `rawValue`s reuse the vocabulary concept of
    /// `ContactResolver.relationshipAnchors` — the anchor words voice
    /// matching normalizes stored relationships onto — so the picker's
    /// data stays resolver-shaped while only its presentation is
    /// localized (`family.relationship.*`). The case order is the
    /// user-specified list. `friend` is the one option the resolver
    /// table does not know; that is fine — it simply has no anchor to
    /// compare on edit (see `preselectedOption(for:)`), so
    /// cross-locale edits of a friend need one fresh pick.
    private enum RelationshipOption: String, CaseIterable, Identifiable {
        case daughter, son, mother, father, sister, brother, husband,
             wife, grandmother, grandfather, friend

        var id: String { rawValue }
        /// The `family.relationship.*` localization key for this option.
        var labelKey: String { "family.relationship.\(rawValue)" }
        /// The anchor word this option's labels normalize onto — nil
        /// for `friend`, which the resolver vocabulary lacks.
        var anchorWord: String? { rawValue == "friend" ? nil : rawValue }
    }

    // Wizard position. An add opens at the search; an edit opens on the
    // relationship step with data pre-filled (see `init`).
    @State private var step: Step = .find

    // Draft state — nothing touches the stores until Save.
    @State private var name = ""
    @State private var phone = ""
    @State private var relationshipOption: RelationshipOption?
    @State private var messengerHandle = ""
    @State private var nickname = ""
    // Home address for voice navigation (directions task, 2026-09-07) —
    // free-form text; blank saves as nil (no address = not a navigation
    // target).
    @State private var address = ""

    // Photo draft state: a just-picked image, whether the user asked to
    // remove the stored one, and the stored one itself (loaded once on
    // appear for an edit).
    @State private var pickedPhoto: UIImage?
    @State private var removingStoredPhoto = false
    @State private var storedPhoto: UIImage?
    @State private var photoPickerItem: PhotosPickerItem?

    // Address-book search state — CallView's shape: access read on
    // appear, entries fetched on a background task, honest failure card.
    @State private var searchText = ""
    /// nil while the authorization state is still being read.
    @State private var access: ContactsAccess?
    /// nil = not loaded yet (or load in flight).
    @State private var entries: [AddressBookEntry]?
    @State private var loadFailed = false

    /// Step 1 keeps the manual name/number fields hidden until the
    /// search has actually found somebody (a tap reveals them
    /// pre-filled for confirmation) or the user asked for manual entry.
    /// The flag LATCHES: once the fields are on screen, clearing them
    /// must never make the form vanish from under the user.
    @State private var showManualEntry = false

    private let directory = AddressBookDirectory()

    init(target: FamilyContactsSettingsView.FamilyContactEditorTarget) {
        self.target = target
        // An edit opens on the relationship step (data pre-filled by
        // `loadDraft`); "Back" from there reaches the search, so
        // re-searching stays one step away.
        if case .edit = target {
            _step = State(initialValue: .relationship)
        }
    }

    private var editingContact: FamilyContact? {
        if case .edit(let contact) = target { return contact }
        return nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedPhone: String {
        phone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Step 1's mandatory content: a name AND a number — from a search
    /// result or typed by hand; neither alone proceeds.
    private var hasNameAndPhone: Bool {
        !trimmedName.isEmpty && !trimmedPhone.isEmpty
    }

    /// Next is disabled until the current step's mandatory content is
    /// satisfied: Step 1 needs name + number, Step 2 needs a picked
    /// relationship. Photo and messenger are optional by design; the
    /// last step saves instead of continuing.
    private var canContinue: Bool {
        switch step {
        case .find: return hasNameAndPhone
        case .relationship: return relationshipOption != nil
        case .photo, .messenger: return true
        case .nickname: return false
        }
    }

    /// The save contract — the same mandatory trio the whole flow
    /// enforces: a name, a number, and a relationship. Save on the last
    /// step is dead without all three.
    private var canSave: Bool {
        hasNameAndPhone && relationshipOption != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                progressRow
                stepContent
                footerButtons
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            loadDraft()
            refreshSearchAccess()
        }
        .onChange(of: scenePhase) { phase in
            // Returning from Settings after the access card's
            // "Open Settings" is the denial → grant path; re-check then.
            if phase == .active {
                refreshSearchAccess()
            }
        }
        .onChange(of: photoPickerItem) { item in
            loadPickedPhoto(item)
        }
    }

    // MARK: Sheet chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            Text("settings.family.title")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer()
        }
    }

    /// The step indicator: five small dots for at-a-glance position and
    /// the explicit localized "Step 2 of 5" line. The dots are
    /// decorative — hidden from VoiceOver, which reads the text.
    private var progressRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue
                            ? DesignTokens.accent
                            : DesignTokens.textSecondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                }
            }
            .accessibilityHidden(true)
            Text(L10n.fmt("family.step.indicator",
                          locale: coordinator.activeLocale, step.position))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Step dispatch

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .find: findStep
        case .relationship: relationshipStep
        case .photo: photoStep
        case .messenger: messengerStep
        case .nickname: nicknameStep
        }
    }

    /// One step's section heading. Step 2 is the exception: its key
    /// labels the dropdown itself while nothing is chosen, so it
    /// renders no separate heading.
    private func stepTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textPrimary)
    }

    // MARK: Step 1 — find the contact

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.find")
            searchSection
            if showManualEntry {
                manualEntryFields
            } else {
                addManuallyButton
            }
        }
    }

    /// The prominent "search found nobody" escape hatch — it reveals
    /// the manual name + number fields ON this step. Entry by hand is
    /// the always-available fallback, contacts access or not.
    private var addManuallyButton: some View {
        Button {
            showManualEntry = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 17, weight: .bold))
                Text(LocalizedStringKey("family.addManually"))
            }
            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var manualEntryFields: some View {
        VStack(spacing: 10) {
            field(placeholderKey: "onboarding.stepFamily.name", text: $name)
            field(placeholderKey: "onboarding.stepFamily.phone", text: $phone)
                .keyboardType(.phonePad)
        }
    }

    private func field(placeholderKey: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(placeholderKey), text: text)
            .font(.system(size: DesignTokens.minBodyPointSize))
            .padding(14)
            .frame(height: 56)
            .background(DesignTokens.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    // MARK: Step 1 — the native-contacts search

    @ViewBuilder
    private var searchSection: some View {
        VStack(spacing: 10) {
            switch access {
            case .allowed:
                searchField
                if entries == nil {
                    if loadFailed {
                        loadFailedRow
                    } else {
                        loadingRow
                    }
                } else if !trimmedSearch.isEmpty {
                    searchResults
                }
            case .denied:
                blockedSearchCard
            case .notDetermined:
                askAccessCard
            case nil:
                // Authorization still being read — render nothing so the
                // ask card can never flash before onAppear resolves it.
                EmptyView()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(DesignTokens.textSecondary)
            TextField(LocalizedStringKey("family.addSearch.placeholder"), text: $searchText)
                .font(.system(size: DesignTokens.minBodyPointSize))
        }
        .padding(.horizontal, 14)
        .frame(height: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The matched address-book rows, most-recently-called first — the
    /// same pure search the Phone leaf runs over the same fetched book.
    /// Tapping a row SELECTS the person (see `prefill`).
    @ViewBuilder
    private var searchResults: some View {
        if let entries {
            let outcome = SystemContactSearch.search(query: trimmedSearch,
                                                     in: entries,
                                                     recency: coordinator.contactCallRecency)
            if outcome.entries.isEmpty {
                Text("call.search.noResults")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(outcome.entries) { entry in
                        Button {
                            prefill(entry)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 18))
                                    .foregroundColor(DesignTokens.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.system(size: DesignTokens.minBodyPointSize,
                                                      weight: .semibold))
                                        .foregroundColor(DesignTokens.textPrimary)
                                        .lineLimit(1)
                                    Text(entry.caption)
                                        .font(.system(size: DesignTokens.minCaptionPointSize))
                                        .foregroundColor(DesignTokens.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.background)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if outcome.moreAvailable {
                    Text("call.search.moreAvailable")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// A tapped result SELECTS the person: the name + number prefill
    /// the manual fields (which appear for confirmation — the fields
    /// stay editable), and the query clears so the results collapse
    /// and the chosen person is what is on screen.
    private func prefill(_ entry: AddressBookEntry) {
        name = entry.name
        phone = entry.phone
        showManualEntry = true
        searchText = ""
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("call.search.loading")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadFailedRow: some View {
        HStack(spacing: 10) {
            Text("call.search.loadFailed")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                loadEntries()
            } label: {
                Text("call.search.retry")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The one point-of-use ask — plain-language card first, the system
    /// prompt only after the user taps Allow (constitution; mirror of
    /// CallView's access card).
    private var askAccessCard: some View {
        VStack(spacing: 12) {
            Text("family.addSearch.allowTitle")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("family.addSearch.allowBody")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                grantAccess()
            } label: {
                Text("call.search.allowButton")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
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

    /// Denied/restricted: the honest blocked line with the search
    /// hidden — only the system Settings screen can lift it, so the
    /// card points there. The "Add manually" path below never depended
    /// on contacts access.
    private var blockedSearchCard: some View {
        VStack(spacing: 12) {
            Text("call.search.deniedTitle")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("family.addSearch.deniedBody")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("call.search.openSettings")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
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

    private func refreshSearchAccess() {
        let status = AddressBookDirectory.access()
        access = status
        guard status == .allowed else { return }
        if entries == nil || loadFailed {
            loadEntries()
        }
    }

    private func grantAccess() {
        Task {
            let granted = await directory.requestAccess()
            access = AddressBookDirectory.access()
            if granted {
                loadEntries()
            }
        }
    }

    private func loadEntries() {
        loadFailed = false
        Task {
            do {
                // A full-book enumerate can take a moment on first
                // access — never block the main thread for it.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try AddressBookDirectory().allEntries()
                }.value
                self.entries = loaded
            } catch {
                self.loadFailed = true
            }
        }
    }

    // MARK: Step 2 — relationship (mandatory dropdown)

    private var relationshipStep: some View {
        Menu {
            ForEach(RelationshipOption.allCases) { option in
                Button {
                    relationshipOption = option
                } label: {
                    HStack(spacing: 10) {
                        Text(L10n.str(option.labelKey,
                                      locale: coordinator.activeLocale))
                            .foregroundColor(DesignTokens.textPrimary)
                        Spacer(minLength: 8)
                        if relationshipOption == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(DesignTokens.accent)
                        }
                    }
                }
            }
        } label: {
            relationshipMenuLabel
        }
    }

    /// The closed dropdown row: the chosen relationship when there is
    /// one, else the step's key as the gray prompt — a mandatory pick
    /// from the fixed list is exactly what this step is.
    private var relationshipMenuLabel: some View {
        HStack(spacing: 8) {
            if let relationshipOption {
                Text(L10n.str(relationshipOption.labelKey,
                              locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            } else {
                Text(LocalizedStringKey("family.step.relationship"))
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    // MARK: Step 3 — photo (optional)

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.photo")
            photoPreview
                .frame(maxWidth: .infinity)
            photoControls
        }
        .frame(maxWidth: .infinity)
    }

    /// What the preview shows right now: a just-picked image wins over
    /// the stored one, and an explicit remove clears both.
    private var displayedPhoto: UIImage? {
        if let pickedPhoto { return pickedPhoto }
        if removingStoredPhoto { return nil }
        return storedPhoto
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let photo = displayedPhoto {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
        } else {
            FaceAvatar(name: name, diameter: 96)
        }
    }

    /// Add photo (none shown) / Change photo (one shown) over the
    /// system Photos picker; Remove photo only for a stored photo being
    /// edited (a fresh pick on an add is simply discarded by closing).
    private var photoControls: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Text(displayedPhoto == nil ? "family.photo.add" : "family.photo.change")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            if editingContact != nil, displayedPhoto != nil {
                Button {
                    pickedPhoto = nil
                    removingStoredPhoto = true
                } label: {
                    Text("family.photo.remove")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .padding(.horizontal, 18)
                        .frame(height: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.background)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            pickedPhoto = image
            removingStoredPhoto = false
        }
    }

    // MARK: Step 4 — messenger handle (optional)

    private var messengerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.messenger")
            field(placeholderKey: "onboarding.stepFamily.messenger", text: $messengerHandle)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            handleHints
        }
    }

    /// The "where to look" lines — the same numbered hints the call
    /// leaf's handle-capture sheet shows (`messenger.handleHints.*`),
    /// so every surface agrees on what a Messenger handle is.
    private var handleHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.str("messenger.handleHints.title",
                          locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(1...3, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index)")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(DesignTokens.accent)
                        .clipShape(Circle())
                    Text(L10n.str("messenger.handleHints.line\(index)",
                                  locale: coordinator.activeLocale))
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Step 5 — optional details (nickname, home address) + save

    private var nicknameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.nickname")
            TextField("", text: $nickname)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Text(L10n.str("settings.family.address", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("", text: $address)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Text("settings.family.addressHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Footer — Back / Next (Save on the last step)

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button {
                step = Step(rawValue: step.rawValue - 1) ?? .find
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                    Text(LocalizedStringKey("common.back"))
                }
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .padding(.horizontal, 18)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(step == .find)
            .opacity(step == .find ? 0.4 : 1)

            Spacer()

            primaryButton(titleKey: step == .nickname ? "onboarding.stepFamily.save"
                                                      : "family.step.next",
                          isEnabled: step == .nickname ? canSave : canContinue) {
                if step == .nickname {
                    save()
                } else {
                    step = Step(rawValue: step.rawValue + 1) ?? .nickname
                }
            }
        }
        .padding(.top, 4)
    }

    private func primaryButton(titleKey: String, isEnabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(isEnabled ? DesignTokens.accent
                                      : DesignTokens.textSecondary.opacity(0.5))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: Draft loading + save

    private func loadDraft() {
        guard let contact = editingContact else { return }
        name = contact.name
        phone = contact.phone
        messengerHandle = contact.messengerHandle ?? ""
        nickname = contact.nickname ?? ""
        address = contact.address ?? ""
        // Pre-select the stored relationship when it is one of the fixed
        // options (see `preselectedOption(for:)`). A legacy free-text
        // value that is none of them stays unselected — the step is
        // mandatory, so the user picks from the fixed list on the way
        // through (and the save then replaces the old text).
        relationshipOption = preselectedOption(for: contact.relationship)
        // Stepping back into the search must show the pre-filled fields.
        showManualEntry = true
        // The stored photo, for the preview and the remove control
        // (photos are best-effort — a missing file simply means none).
        if contact.photoFilename != nil {
            storedPhoto = coordinator.contactPhoto(for: contact)
        }
    }

    /// Maps a stored relationship string onto the dropdown, so an edit
    /// opens with the person's relationship already chosen. Two ways a
    /// stored value can match, mirroring how `ContactResolver` matches
    /// (the anchors are the shared vocabulary):
    ///   1. exactly — the option's label in the ACTIVE locale (the form
    ///      this wizard's own saves write);
    ///   2. by anchor — a label written in the OTHER locale, or a
    ///      legacy free-text spelling ("दिदी" for sister, "dad" for
    ///      father), normalizes onto the same anchor word as one of the
    ///      option labels. `friend` has no anchor (see
    ///      `RelationshipOption`), so only rule 1 can select it — a
    ///      friend saved in the other locale needs one fresh pick.
    private func preselectedOption(for stored: String) -> RelationshipOption? {
        let locale = coordinator.activeLocale
        if let exact = RelationshipOption.allCases.first(where: {
            L10n.str($0.labelKey, locale: locale) == stored
        }) {
            return exact
        }
        guard let storedAnchor = ContactResolver.relationshipAnchor(
            in: NepaliTextNormalizer.normalize(stored)) else { return nil }
        return RelationshipOption.allCases.first { $0.anchorWord == storedAnchor }
    }

    private func save() {
        let messenger = trimmedOrNil(messengerHandle)
        let nick = trimmedOrNil(nickname)
        // Blank address saves as nil — no address = not a navigation
        // target (directions task, 2026-09-07).
        let homeAddress = trimmedOrNil(address)
        // The stored relationship is the chosen option's label in the
        // active locale — the display word the picker showed, which is
        // what the free-text field before it used to store.
        let relationshipText = relationshipOption.map {
            L10n.str($0.labelKey, locale: coordinator.activeLocale)
        } ?? ""
        let succeeded: Bool
        if let contact = editingContact {
            succeeded = coordinator.updateFamilyContact(
                id: contact.id, name: trimmedName, phone: phone,
                relationship: relationshipText, messengerHandle: messenger,
                photo: pickedPhoto, removingPhoto: removingStoredPhoto,
                nickname: nick, address: homeAddress)
        } else {
            succeeded = coordinator.addFamilyContact(
                name: trimmedName, phone: phone,
                relationship: relationshipText, messengerHandle: messenger,
                photo: pickedPhoto, nickname: nick, address: homeAddress)
        }
        if succeeded { dismiss() }
        // A failed store write keeps the draft on screen — Save again to
        // retry; nothing was claimed that didn't happen.
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Saved places (directions task, 2026-09-07)

/// The "Places" screen (Settings hub row): which map surface voice
/// navigation opens, the saved-places list, and the add button. Map-app
/// radio rows copy `CallingSettingsView`'s channel-row pattern (the
/// elder's pick is stored on the coordinator; the OPEN decision still
/// re-derives installed-ness at request time — see `NavigationMapPolicy`).
/// Place rows show the category + default-home radio for `.home` places,
/// with edit/delete controls mirroring the Family & friends rows.
struct PlacesSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// The open add/edit sheet — nil when closed. Item-driven so a
    /// swipe-dismiss also clears it (same pattern as the family editor).
    @State private var editorTarget: PlacesEditorTarget?

    enum PlacesEditorTarget: Identifiable {
        case add
        case edit(SavedPlace)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let place): return place.id.uuidString
            }
        }
    }

    var body: some View {
        LeafScreen(titleKey: "settings.places.title") {
            VStack(spacing: 12) {
                mapAppSection
                savedPlacesSection
                if coordinator.savedPlaces.count < SavedPlaceStore.maxPlaces {
                    addButton
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            PlacesEditorSheet(target: target)
        }
    }

    // MARK: Map surface

    /// Which app opens when the user asks for directions. `.auto` — the
    /// default — opens whichever is actually installed (Google first),
    /// so the option rows carry no "requires X installed" caveat text;
    /// the request-time resolve handles absence honestly.
    private var mapAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.places.mapApp")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            ForEach(NavigationMapApp.allCases, id: \.self) { app in
                mapAppRow(app)
            }
            Text("settings.places.mapAppHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private func mapAppRow(_ app: NavigationMapApp) -> some View {
        let isSelected = app == coordinator.navigationMapApp
        return Button {
            coordinator.navigationMapApp = app
        } label: {
            HStack {
                Text(LocalizedStringKey(Self.nameKey(for: app)))
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

    /// Catalog key for a map-app option — same string every surface
    /// shows. Keyed by switch, not rawValue, so the stored id and the
    /// catalog key can't silently drift (the CallingSettingsView rule).
    static func nameKey(for app: NavigationMapApp) -> String {
        switch app {
        case .auto: return "settings.places.mapApp.auto"
        case .googleMaps: return "settings.places.mapApp.googleMaps"
        case .appleMaps: return "settings.places.mapApp.appleMaps"
        case .inApp: return "settings.places.mapApp.inApp"
        }
    }

    // MARK: Saved places

    private var savedPlacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.places.saved")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            if coordinator.savedPlaces.isEmpty {
                Text("settings.places.empty")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            } else {
                ForEach(coordinator.savedPlaces) { place in
                    placeRow(place)
                }
            }
        }
    }

    /// One saved place: name + address, a category line, the default-home
    /// radio (`.home` places only — "take me home" drives to the checked
    /// one), and edit/delete controls.
    private func placeRow(_ place: SavedPlace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: place.category == .home ? "house.fill" : "mappin.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Text(place.address)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    editorTarget = .edit(place)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 20))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(width: DesignTokens.minTapTargetSize,
                               height: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.places.edit"))
                Button(role: .destructive) {
                    coordinator.removePlace(id: place.id)
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 22))
                        .foregroundColor(DesignTokens.stateError)
                        .frame(width: DesignTokens.minTapTargetSize,
                               height: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.places.delete"))
            }
            if place.category == .home {
                HStack(spacing: 8) {
                    Image(systemName: place.isDefaultHome
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(place.isDefaultHome
                                         ? DesignTokens.accent : DesignTokens.textSecondary)
                    Text("settings.places.defaultHome")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    coordinator.setDefaultHomePlace(id: place.id)
                }
                .accessibilityAddTraits(place.isDefaultHome ? .isSelected : [])
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addButton: some View {
        Button {
            editorTarget = .add
        } label: {
            Text("settings.places.add")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.chipHeight)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }
}

/// The add/edit sheet of the Places screen — one form for both duties
/// (blank for `.add`, pre-filled for `.edit`), mirroring the family
/// editor: name, address, category (home / important place), the
/// default-home toggle for `.home` places, then Save. Save closes only on
/// success; a failed store write keeps the draft on screen (nothing is
/// claimed that didn't happen).
private struct PlacesEditorSheet: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let target: PlacesSettingsView.PlacesEditorTarget

    @State private var name = ""
    @State private var address = ""
    @State private var category: SavedPlace.Category = .home
    @State private var isDefaultHome = false

    private var editingPlace: SavedPlace? {
        if case .edit(let place) = target { return place }
        return nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// An address is REQUIRED — a place with no address can never be a
    /// navigation target, so saving one would only create a dead row.
    private var canSave: Bool {
        !trimmedName.isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field(placeholderKey: "settings.places.name", text: $name)
                    field(placeholderKey: "settings.places.address", text: $address)
                        .textInputAutocapitalization(.words)
                    categoryPicker
                    if category == .home {
                        defaultHomeToggle
                    }
                    saveButton
                }
            }
        }
        .padding(20)
        .onAppear { loadDraft() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            Text(editingPlace == nil
                 ? LocalizedStringKey("settings.places.add")
                 : LocalizedStringKey("settings.places.edit"))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer()
        }
    }

    private func field(placeholderKey: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(placeholderKey), text: text)
            .font(.system(size: DesignTokens.minBodyPointSize))
            .padding(14)
            .frame(height: 56)
            .background(DesignTokens.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    /// Home vs important place. Switching a place to `.important` clears
    /// its default-home flag in the store (a non-home place can never be
    /// "home"), and the flag auto-promotes the next `.home` — the toggle
    /// below simply reflects whatever the store ended up with.
    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.places.category")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            HStack(spacing: 10) {
                categoryChip(.home, key: "settings.places.category.home")
                categoryChip(.important, key: "settings.places.category.important")
            }
        }
    }

    private func categoryChip(_ value: SavedPlace.Category, key: String) -> some View {
        let isSelected = category == value
        return Button {
            category = value
            if value == .important {
                // Mirrors the store rule visibly: an important place can
                // never be the default home.
                isDefaultHome = false
            }
        } label: {
            Text(LocalizedStringKey(key))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(isSelected ? .white : DesignTokens.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(isSelected ? DesignTokens.accent : DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    /// The default-home toggle — only meaningful for `.home` places, so
    /// it only appears then. The store (not this sheet) is the referee
    /// for the at-most-one rule: the coordinator's update path demotes
    /// any previous default when this one is saved with the flag set.
    private var defaultHomeToggle: some View {
        Button {
            isDefaultHome.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDefaultHome ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundColor(isDefaultHome ? DesignTokens.accent : DesignTokens.textSecondary)
                Text("settings.places.defaultHomeToggle")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("onboarding.stepFamily.save")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.chipHeight)
                .background(canSave ? DesignTokens.accent
                                    : DesignTokens.textSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .padding(.top, 4)
    }

    private func loadDraft() {
        guard let place = editingPlace else { return }
        name = place.name
        address = place.address
        category = place.category
        isDefaultHome = place.isDefaultHome
    }

    private func save() {
        let succeeded: Bool
        if let place = editingPlace {
            succeeded = coordinator.updatePlace(id: place.id, name: trimmedName,
                                                address: address, category: category,
                                                isDefaultHome: isDefaultHome)
        } else {
            succeeded = coordinator.addPlace(name: trimmedName, address: address,
                                             category: category, isDefaultHome: isDefaultHome)
        }
        if succeeded { dismiss() }
        // A failed store write keeps the draft on screen — Save again to
        // retry; nothing was claimed that didn't happen.
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
                externalCalendarCard
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

    /// Native Calendar/Reminders import (calendar-driven task,
    /// 2026-09-07) — the mirror card above writes the app's schedule
    /// OUT to EventKit; this card reads the family's native events and
    /// due reminders IN (in-app notifications + today's lists). Ask
    /// happens at point of use (the toggle); the app never writes back.
    /// Same intent-vs-truth split as the mirror: the toggle is intent,
    /// the status line is the OS's answer.
    private var externalCalendarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.externalCalendar.isEnabled },
                set: { newValue in
                    Task { await coordinator.setExternalCalendarEnabled(newValue) }
                }
            )) {
                Label("externalReminders.toggle", systemImage: "calendar.badge.clock")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)

            if coordinator.externalCalendar.isEnabled {
                HStack {
                    Text("externalReminders.leadTitle")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    // Setting the lead re-scans immediately (the
                    // service's didSet) so armed notifications follow.
                    Stepper(value: Binding(
                        get: { coordinator.externalCalendar.leadMinutes },
                        set: { coordinator.externalCalendar.leadMinutes = $0 }
                    ), in: 0...ExternalCalendarService.maxLeadMinutes) {
                        Text(BikramSambat.devanagariDigits(coordinator.externalCalendar.leadMinutes))
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundColor(DesignTokens.accent)
                    }
                }
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

                Text(L10n.fmt("externalReminders.leadHint", locale: coordinator.activeLocale,
                              BikramSambat.devanagariDigits(coordinator.externalCalendar.leadMinutes)))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }

            Text(externalStatusText)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var externalStatusText: String {
        switch coordinator.externalCalendar.status {
        case .enabled: return L10n.str("externalReminders.statusOn", locale: coordinator.activeLocale)
        case .partial: return L10n.str("externalReminders.statusPartial", locale: coordinator.activeLocale)
        case .denied: return L10n.str("externalReminders.statusDenied", locale: coordinator.activeLocale)
        case .error: return L10n.str("externalReminders.statusError", locale: coordinator.activeLocale)
        case .notRequested: return L10n.str("externalReminders.statusHint", locale: coordinator.activeLocale)
        }
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
            // LeafScreen-style chrome, own background (skinnable home,
            // 2026-09-07): this screen predates LeafScreen and keeps its
            // full-screen layout, so the theme reads here directly.
            Color(theme: coordinator.appTheme).ignoresSafeArea()
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
