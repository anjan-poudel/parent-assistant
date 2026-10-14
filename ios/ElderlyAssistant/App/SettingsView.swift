import SwiftUI
import UIKit
import PhotosUI

/// Settings hub (spec §4.4) — tabbed reorg 2026-09-16: five tabs of cards
/// (Voice, Family, Reminders, Tools, System) instead of one 23-row scroll,
/// plus the long-press door to the technical settings. The tab table, the
/// leaf routing and the hidden sheet live in `SettingsTabs.swift`.
struct SettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    /// [BOOT-REVIEW, design item] Observed so the diagnostics card below
    /// re-renders when a capability fails or (via recovery) comes back.
    @EnvironmentObject private var boot: StartupBoot
    @Environment(\.locale) private var locale
    /// [AX-VIEWPORT] The hub root does not scroll, so the diagnostics
    /// block and the TabView below it have to share the screen by
    /// agreement at accessibility text sizes — this is the switch that
    /// bounds the block (see `degradationDiagnosticsSection`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedTab: SettingsSection = .voice

    /// Redesign spec §3.3 + 2026-09-16 reorg §3: the technical settings
    /// (Gemini/cloud AI, the voice engine stack, web search, the two review
    /// logs, the model screen) are NOT rows on any tab — there's no
    /// caregiver app yet for someone to manage STT/LLM downloads through,
    /// so the capability has to stay reachable, just not one plain tap away
    /// from an elderly user's normal navigation.
    @State private var showHiddenSheet = false
    /// Spec §3 decision 2: the sheet's ellipsis affordance appears only
    /// after the household has opened the sheet once, so the first meeting
    /// is the hint caption, not an unexplained button.
    @AppStorage(HiddenSettingsSheetUsage.defaultsKey) private var hiddenSheetUsed = false

    /// Long-press duration on the title (spec §3: "e.g., 0.8s").
    static let hiddenSheetLongPressDuration: TimeInterval = 0.8

    var body: some View {
        ZStack {
            VoiceBridgeBackground(theme: coordinator.appTheme)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .card, cornerRadius: 999)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.back"))
                    .accessibilityIdentifier("settings.back")
                    Spacer(minLength: 8)
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                titleBlock

                // [BOOT-REVIEW, design item] Capability diagnostics live
                // HERE, not in a transient capsule: every failed boot
                // capability is named, its affected control named, and
                // exactly one recovery action offered — routed through the
                // same seam the coordinator installed. It sits ABOVE the
                // tab bar, not inside a tab: a failed capability concerns
                // the whole app and must not wait for the household to
                // guess which tab hid the notice (it is empty — and takes
                // no space — while every capability is healthy).
                degradationDiagnosticsSection

                SettingsTabBar(selection: $selectedTab)

                TabView(selection: $selectedTab) {
                    ForEach(SettingsSection.allCases) { tab in
                        tabPage(tab)
                            .tag(tab)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // [AX-VIEWPORT] A page-style TabView is a flexible child,
                // so an unbounded sibling above it could (and did) shrink
                // it to zero height at accessibility sizes — every tab
                // page unreachable. The diagnostics block above is bounded
                // at AX; this floor keeps a workable page viewport even on
                // the smallest phone. 0 (no constraint) at standard sizes,
                // so today's layout is untouched.
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 200 : 0)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Value-based navigation (iOS 16 pattern) — see HomeView: the
        // isPresented + derived-binding form is fragile on iOS 16.
        .navigationDestination(for: SettingsDestination.self) { destination in
            SettingsDestinationView(destination: destination)
        }
        .sheet(isPresented: $showHiddenSheet) {
            HiddenSettingsSheet()
        }
    }

    // MARK: - Title (and the two doors to the hidden sheet)

    /// The title keeps the long-press the spec names (0.8 s) and adds the
    /// accessibility alternative it asks for: once the sheet has been
    /// opened, a small ellipsis button sits next to the title, so a
    /// VoiceOver user — or anyone who cannot hold a gesture — has a plain
    /// target. Until that first open, the caption underneath says the
    /// gesture exists at all.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("settings.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: Self.hiddenSheetLongPressDuration) {
                        openHiddenSheet()
                    }
                if hiddenSheetUsed {
                    Button(action: openHiddenSheet) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .card, cornerRadius: 999)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("settings.hidden.open"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            if !hiddenSheetUsed {
                Text("settings.hidden.hint")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    /// One tab's page. The rows come from the tab table in
    /// `SettingsTabs.swift` in table order — the view never decides what
    /// belongs where.
    @ViewBuilder
    private func tabPage(_ tab: SettingsSection) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(tab.rows) { destination in
                    // [CNR T-177] (2026-10-14) The cloud-chat consent row
                    // (design-l1 §8.6 "family/caregiver paths") sits
                    // immediately above `.privacy` in the System tab —
                    // where the privacy-shaped household controls live,
                    // the same placement rationale the LiveTranslate row
                    // records for its own branch.
                    if tab == .system, destination == .privacy {
                        cloudChatSettingsRow
                    }
                    SettingsSectionRow(destination: destination)
                }
                // [ENCODER-RUNTIME-TOGGLE] Visible door to the internal AI
                // screen: a single tap opens the same hidden sheet the title
                // long-press opens, so the A/B card needs no gesture hunt.
                // Gated by the same IntentEncoderFeature.isEnabled, which
                // [ENCODER-ALWAYS-ON] is now part of this target's DEFAULT
                // compilation conditions — the door is present in every
                // build, and what keeps the encoder out of service is the
                // toggle inside (default OFF), not the absence of the UI.
                // It rides the System tab: an app-plumbing door, not a
                // household control.
                if tab == .system, IntentEncoderFeature.isEnabled {
                    Button(action: openHiddenSheet) {
                        SettingsRowChrome(icon: "brain.head.profile",
                                          titleKey: "settings.encoder.title")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
    }

    /// Both doors land here: the first open is what makes the ellipsis
    /// affordance (and the absence of the hint) permanent.
    private func openHiddenSheet() {
        HiddenSettingsSheetUsage.markUsed()
        hiddenSheetUsed = true
        showHiddenSheet = true
    }

    /// [CNR T-177] (2026-10-14) The cloud-chat consent row — the Settings
    /// revocation surface (design-l1 §8.6: the row toggles cloud chat off
    /// and the write goes "through the gate's one writer"). The switch is
    /// the shipped `LiveTranslateToggleRow` (usage only — the row type and
    /// its leaf are untouched), with the cloud-chat family's own words
    /// (`settings.cloudChat.toggleLabel` / `.toggleNote`, T-171; both are
    /// zero-format-slot catalogue values, so nothing here mints copy).
    ///
    /// The binding reads the gate's CURRENT decision through the
    /// coordinator on every render and writes through the coordinator's
    /// one Settings entry point — deliberately no `@State` mirror and no
    /// `onAppear` re-read (the LiveTranslate leaf's pattern): the gate is
    /// the single source of truth, a mirror could go stale against a voice
    /// revoke, and a failed write must read back as what is actually on
    /// disk. The `toggleNote` is the visible disclosure, so the flip is
    /// silent here like every other Settings control.
    @ViewBuilder
    private var cloudChatSettingsRow: some View {
        LiveTranslateToggleRow(
            title: L10n.str("settings.cloudChat.toggleLabel", locale: locale),
            note: L10n.str("settings.cloudChat.toggleNote", locale: locale),
            identifier: "settings.cloudChat.toggleLabel",
            isOn: Binding(
                get: { coordinator.cloudChatEnabled },
                set: { coordinator.setCloudChatEnabledFromSettings($0) }
            ))
    }

    /// [BOOT-REVIEW, design item] Capability-specific diagnostics — the
    /// review moves detailed failure information OUT of the transient
    /// boot capsule and INTO Settings. Each failed capability is named,
    /// its diagnostic detail shown, and exactly ONE recovery action
    /// offered (routed through the coordinator's real retry seam). The
    /// card disappears the moment every failure recovers.
    @ViewBuilder
    private var degradationDiagnosticsSection: some View {
        let degradations = StartupDegradation.degradations(forFailedStages: boot.failedStages)
        if !degradations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.str("settings.diagnostics.title", locale: locale))
                    .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                               weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                // [AX-VIEWPORT] At accessibility text sizes a couple of
                // failure cards are taller than the phone, and this hub
                // root does NOT scroll — the unbounded cards pushed the
                // TabView below them (the only way to reach a tab's rows)
                // to zero height. Bounding the cards and scrolling them
                // internally keeps every card reachable while leaving the
                // TabView a workable viewport. Standard sizes keep the
                // unbounded block: every card is visible, nothing scrolls
                // inside it.
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        diagnosticCards(degradations)
                    }
                    .frame(maxHeight: 220)
                } else {
                    diagnosticCards(degradations)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    /// The failure cards themselves — one implementation shared by the
    /// standard (unbounded) and accessibility (scroll-bounded) arms above,
    /// so the two can never drift apart.
    private func diagnosticCards(_ degradations: [StartupDegradation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(degradations) { degradation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: appearance.typography.captionPointSize,
                                          weight: .bold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                        Text(L10n.str(degradation.titleKey, locale: locale))
                            .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                       weight: .semibold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            StartupDegradationRecoverySeam.perform(degradation.capability)
                        } label: {
                            Text(L10n.str(degradation.recoveryKey, locale: locale))
                                .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                           weight: .bold)).foregroundStyle(appearance.colors.accentForeground)
                                .frame(minHeight: DesignTokens.minTapTargetSize)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(L10n.str(degradation.diagnosticKey, locale: locale))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                   weight: .regular))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            }
        }
    }
}


// MARK: - 1. Language & region (spec §4.4.1)

struct LanguageSettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.language.title") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 12) {
                    ForEach(AppLanguage.allCases) { language in
                        languageRow(language)
                    }
                }
                // Region is a SEPARATE setting (2026-09-13): language picks
                // the words, locale picks the dates/numbers/Nepali regional
                // conventions. Was a static caption claiming "Nepal
                // (ne-NP)" with no way to change it — wrong for a Nepali
                // household in India, whose device region used to decide
                // formatting by accident.
                Text("settings.language.region.title")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .padding(.top, 4)
                VStack(spacing: 12) {
                    ForEach(AppLocale.supported(for: coordinator.appLanguage)) { locale in
                        localeRow(locale)
                    }
                }
                Text("settings.language.region.footer")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
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
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accentForeground : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func localeRow(_ locale: AppLocale) -> some View {
        let isSelected = locale == coordinator.appLocale
        return Button {
            coordinator.appLocale = locale
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(locale.regionDisplayNameKey))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    // The identifier itself ("ne-NP") — region codes are
                    // not translated; helpful for caregivers.
                    Text(locale.rawValue)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accentForeground : Color.clear, lineWidth: 2)
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
/// [GEMINI-SOLIDIFY] (2026-09-18) The "Test connection" button's UI
/// state — idle, in-flight, or a completed outcome in the failure
/// taxonomy's vocabulary (`GeminiFailureClass`), so the card reports
/// the same classes the spoken degradation lines use.
private enum ConnectionTestState: Equatable {
    case idle
    case running
    case completed(GeminiClient.ConnectionTestOutcome)
}

struct GeminiAPISettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftKey: String = ""
    @State private var showClearConfirm = false
    @State private var customModel: String = ""
    @State private var connectionTest: ConnectionTestState = .idle
    /// [MASKED-SETTINGS] (2026-10-14, owner: blank boxes give no way to
    /// know whether a value is set) True while a stored key is shown in
    /// its masked form; false once the user taps Change to type.
    @State private var editingKey = false

    /// The masked display for an already-set key — bullets plus the last
    /// four characters, so the holder can recognise their own key
    /// without the full secret ever being on screen.
    private var storedKeyMasked: String? {
        guard let key = coordinator.geminiConfigStore.apiKey, !key.isEmpty else {
            return nil
        }
        let tail = String(key.suffix(4))
        return "••••••••" + tail
    }

    private var isCustomModelSelected: Bool {
        !GeminiModelCatalog.entries.contains { $0.id == coordinator.geminiConfigStore.model }
    }

    var body: some View {
        LeafScreen(titleKey: "settings.gemini.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("settings.gemini.explanation")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)

                statusCard

                costGovernorCard

                modelPicker

                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.gemini.fieldLabel")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textSecondary)
                    if let masked = storedKeyMasked, !editingKey {
                        // [MASKED-SETTINGS] The configured state is
                        // visible: the masked key plus a Change affordance
                        // — never an empty box that pretends nothing is
                        // stored.
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(appearance.colors.accentForeground)
                            Text(masked)
                                .font(.system(size: appearance.typography.bodyPointSize,
                                              design: .monospaced))
                                .foregroundStyle(appearance.colors.textPrimary)
                            Spacer()
                            Button {
                                editingKey = true
                            } label: {
                                Text("settings.gemini.change")
                                    .font(.system(size: appearance.typography.bodyPointSize,
                                                  weight: .semibold))
                                    .foregroundStyle(appearance.colors.accentForeground)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                                .stroke(appearance.colors.textSecondary.opacity(0.25), lineWidth: 1)
                        )
                    } else {
                        SecureField("settings.gemini.fieldPlaceholder", text: $draftKey)
                            .font(.system(size: appearance.typography.bodyPointSize, design: .monospaced))
                            .padding(14)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                                    .stroke(appearance.colors.textSecondary.opacity(0.25), lineWidth: 1)
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

                Button {
                    coordinator.geminiConfigStore.save(draftKey)
                    draftKey = ""
                    editingKey = false
                } label: {
                    Text("settings.gemini.save")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? appearance.colors.textSecondary.opacity(0.4) : appearance.colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.geminiConfigStore.isConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(appearance.colors.accentForeground)
                        Text("settings.gemini.statusConnected")
                            .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                            .foregroundStyle(appearance.colors.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("settings.gemini.remove")
                                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 4)
                }

                testConnectionCard
            }
        }
        .confirmationDialog("settings.gemini.removeConfirm", isPresented: $showClearConfirm) {
            Button("settings.gemini.remove", role: .destructive) {
                coordinator.geminiConfigStore.clear()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    // MARK: - Status card ([GEMINI-SOLIDIFY], 2026-09-18)

    /// One plain-language status card: configured ✓ / the active model /
    /// the cost mode / the fallback chain. All lines are catalog keys —
    /// the leaf is family-facing and bilingual like every other string.
    private var statusCard: some View {
        let locale = coordinator.activeLocale
        let configured = coordinator.geminiConfigStore.isConfigured
        let model = coordinator.geminiConfigStore.model
        return VStack(alignment: .leading, spacing: 8) {
            Label("settings.gemini.status.title", systemImage: "sparkles")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            HStack(spacing: 8) {
                Image(systemName: configured ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(configured ? appearance.colors.accentForeground : appearance.statusForeground(DesignTokens.stateError))
                Text(LocalizedStringKey(configured
                                        ? "settings.gemini.status.configured"
                                        : "settings.gemini.status.notConfigured"))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            Text(L10n.fmt("settings.gemini.status.model", locale: locale, Self.modelDisplayName(model, locale: locale)))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
            Text(L10n.fmt("settings.gemini.status.costMode", locale: locale,
                          Self.number(coordinator.geminiCostGovernor.softDailyCap, locale: locale)))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
            Text(LocalizedStringKey(Self.fallbackChainKey(coordinator)))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The active model's plain-language name: the curated catalog label
    /// when the pick is a catalog entry, the raw id otherwise (a custom
    /// override is its own identifier — shown as typed by the family).
    private static func modelDisplayName(_ model: String, locale: Locale) -> String {
        if let entry = GeminiModelCatalog.entries.first(where: { $0.id == model }) {
            return L10n.str(entry.labelKey, locale: locale)
        }
        return model
    }

    /// The fallback-chain line's key for the CURRENT stack — the same
    /// three states the voice-engine card names, in plain language.
    private static func fallbackChainKey(_ coordinator: AppCoordinator) -> String {
        switch coordinator.voiceEngineStack {
        case .gemini:
            return "settings.gemini.status.chain.hybrid"
        case .onDevice:
            return coordinator.cloudFallbackEnabled
                ? "settings.gemini.status.chain.onDeviceFallback"
                : "settings.gemini.status.chain.onDevice"
        }
    }

    /// Devanagari digits in the Nepali locale (the same elder-facing
    /// convention as `GeminiCostCard`), Arabic elsewhere.
    private static func number(_ value: Int, locale: Locale) -> String {
        if locale.language.languageCode?.identifier == "ne" {
            return BikramSambat.devanagariDigits(value)
        }
        return String(value)
    }

    // MARK: - Test connection ([GEMINI-SOLIDIFY], 2026-09-18)

    /// One REAL minimal round-trip through the shipped client (auth,
    /// timeout, cost governor, retry — the exact chokepoint every call
    /// uses), reporting success or the failure CLASS. The caption states
    /// the attempt is billable and counted toward the daily cap.
    private var testConnectionCard: some View {
        let locale = coordinator.activeLocale
        return VStack(alignment: .leading, spacing: 10) {
            Label("settings.gemini.test.title", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)

            Button {
                connectionTest = .running
                Task { [weak coordinator] in
                    let outcome = await coordinator?.geminiClient.testConnection() ?? .failure(.notConfigured)
                    connectionTest = .completed(outcome)
                }
            } label: {
                HStack(spacing: 8) {
                    if connectionTest == .running {
                        ProgressView()
                    }
                    Text(LocalizedStringKey(connectionTest == .running
                                            ? "settings.gemini.test.running"
                                            : "settings.gemini.test.button"))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize).foregroundStyle(coordinator.geminiConfigStore.isConfigured ? appearance.colors.accentForeground : appearance.colors.textSecondary)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
            .disabled(connectionTest == .running || !coordinator.geminiConfigStore.isConfigured)

            if case .completed(let outcome) = connectionTest {
                switch outcome {
                case .success:
                    Label("settings.gemini.test.success", systemImage: "checkmark.circle.fill")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
                case .failure(let failureClass):
                    Text(L10n.fmt("settings.gemini.test.failed", locale: locale,
                                  failureClass.spokenLine(locale: locale)))
                        .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                }
            }

            Text("settings.gemini.test.costNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textSecondary)
            ForEach(GeminiModelCatalog.entries) { entry in
                modelRow(id: entry.id, labelKey: entry.labelKey, descriptionKey: entry.descriptionKey)
            }
            modelRow(id: nil, labelKey: "settings.gemini.model.custom", descriptionKey: "settings.gemini.model.custom.desc")
            if isCustomModelSelected || !customModel.isEmpty {
                TextField("settings.gemini.model.customPlaceholder", text: $customModel)
                    .font(.system(size: appearance.typography.bodyPointSize, design: .monospaced))
                    .padding(12)
                    .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        coordinator.geminiConfigStore.saveModel(customModel)
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(isSelected ? appearance.colors.accentForeground : appearance.colors.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(labelKey))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(LocalizedStringKey(descriptionKey))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
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
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftAPIKey = ""
    @State private var draftEngineID = ""
    @State private var showClearConfirm = false

    var body: some View {
        LeafScreen(titleKey: "searchSettings.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("searchSettings.explanation")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)

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
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

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
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && draftEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? appearance.colors.textSecondary.opacity(0.4) : appearance.colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && draftEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.searchConfigStore.isConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(appearance.colors.accentForeground)
                        Text("searchSettings.statusConnected")
                            .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                            .foregroundStyle(appearance.colors.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("searchSettings.remove")
                                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 4)
                }

                Text("searchSettings.quotaNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("searchSettings.privacy")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
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
                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textSecondary)
            SecureField(placeholderKey, text: text)
                .font(.system(size: appearance.typography.bodyPointSize, design: .monospaced))
                .padding(14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                        .stroke(appearance.colors.textSecondary.opacity(0.25), lineWidth: 1)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - YouTube (youtube-plugin, 2026-09-08)

/// [YOUTUBE] (2026-09-08) The optional YouTube Data API v3 key behind
/// the voice YouTube feature's "play the top result" path. Family-facing
/// (the elderly primary user is never asked to handle API keys — same
/// framing as the search/Gemini key screens): one SecureField mirroring
/// `SearchSettingsView`'s field style. The key is OPTIONAL — without it
/// "play X on youtube" opens YouTube search directly (the accepted
/// search-only MVP), and the explanation states that plainly.
struct YouTubeSettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draftAPIKey = ""
    @State private var showClearConfirm = false

    var body: some View {
        LeafScreen(titleKey: "youtubeSettings.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("youtubeSettings.explanation")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)

                VStack(alignment: .leading, spacing: 14) {
                    credentialField(labelKey: "youtubeSettings.apiKey",
                                    placeholderKey: "youtubeSettings.apiKey",
                                    text: $draftAPIKey)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

                Button {
                    // An empty draft leaves the stored value untouched —
                    // clearing is the explicit Remove action below.
                    let trimmedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedKey.isEmpty {
                        coordinator.youtubeConfigStore.saveAPIKey(trimmedKey)
                    }
                    draftAPIKey = ""
                } label: {
                    Text("youtubeSettings.save")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? appearance.colors.textSecondary.opacity(0.4) : appearance.colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if coordinator.youtubeConfigStore.isConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(appearance.colors.accentForeground)
                        Text("youtubeSettings.statusConnected")
                            .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                            .foregroundStyle(appearance.colors.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("youtubeSettings.remove")
                                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 4)
                }

                Text("youtubeSettings.quotaNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("youtubeSettings.privacy")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("youtubeSettings.removeConfirm", isPresented: $showClearConfirm) {
            Button("youtubeSettings.remove", role: .destructive) {
                coordinator.youtubeConfigStore.clear()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    /// One labeled SecureField card — same visual recipe as the search
    /// key field (monospaced, min tap height, outlined bubble).
    private func credentialField(labelKey: LocalizedStringKey,
                                 placeholderKey: LocalizedStringKey,
                                 text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(labelKey)
                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textSecondary)
            SecureField(placeholderKey, text: text)
                .font(.system(size: appearance.typography.bodyPointSize, design: .monospaced))
                .padding(14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                        .stroke(appearance.colors.textSecondary.opacity(0.25), lineWidth: 1)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - Spotify (spotify-music-integration, 2026-10-07)

/// [SPOTIFY] T-120 — the caregiver-facing Spotify section (C-SP-10 /
/// design-l2 §17; FR-SP-016, FR-SP-010, NFR-SP-010): the account link's
/// status card with the Link/Unlink action, the M-2 privacy disclosure,
/// the rollout note and the confirm-then-wipe dialog.
///
/// The card renders `SpotifyAccountSession.status` through
/// `SpotifySettingsLeafState` — one total mapping, never optimistic
/// (design §17), so "the surface cannot disagree with the session" is a
/// unit test over the real session and its real store, not a rendering
/// claim.
///
/// No credential UI of any kind (ADR-SP-01): the link happens in the
/// provider's own consent sheet, the tokens live only in the encrypted
/// store, and this surface has no field, no token echo, no debug
/// affordance and no log line (NFR-SP-002).
struct SpotifySettingsView: View {
    @Environment(\.appAppearance) private var appearance
    /// The coordinator's ONE session (T-119): the same instance the plugin
    /// and the router hold, so the card cannot show a second account
    /// (L2-R2). Observed, so a link attempt's outcome repaints the card
    /// the moment `status` publishes.
    @ObservedObject var session: SpotifyAccountSession
    /// The unlink confirmation (design §17: destructive confirmed, cancel
    /// = `common.back`).
    @State private var confirmingUnlink = false

    private var leafState: SpotifySettingsLeafState {
        SpotifySettingsLeafState(state: session.status)
    }

    var body: some View {
        LeafScreen(titleKey: "spotifySettings.title") {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                // FR-SP-016's visible half: the M-2 amended disclosure
                // (the copy T-123's obligation 7 is checked against).
                Text("spotifySettings.privacy")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // OD-S2(c): the Dashboard app is still in development mode
                // (the extended-quota filing is an open owner action), so
                // only approved accounts can connect. The client cannot
                // observe the console-side mode, so the note is shown
                // unconditionally while that remains true — honest, never
                // hidden behind a placebo flag; when OD-S2 completes the
                // note leaves with the copy inventory (§31), not silently
                // gated.
                Text("spotifySettings.rolloutNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("spotifySettings.removeConfirm", isPresented: $confirmingUnlink) {
            Button("spotifySettings.unlink", role: .destructive) {
                // The wipe. A wipe that fails leaves the record — and so
                // the linked status — untouched (the store's own
                // guarantee), which is why the card keeps saying
                // "Connected".
                _ = session.unlink()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    /// The status card: the state as TEXT first (never colour or icon
    /// alone, NFR-SP-010) plus the one primary action.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: leafState.statusIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(leafState.tone == .connected
                                     ? appearance.colors.accentForeground
                                     : appearance.colors.textSecondary)
                    // Decorative: the status line below is the label.
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(leafState.statusKey))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.spotify.status")

            actionButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The single primary action, worded and full-width (never icon-only),
    /// ≥44 pt tall (the house tap-target token). While an attempt is in
    /// flight it stays visible but disabled (design §17's "buttons
    /// disabled"), so the screen can neither open a second consent sheet
    /// nor lose its only affordance.
    private var actionButton: some View {
        Button {
            switch leafState.action {
            case .link:
                // The presenter seam is already wired (T-119); the outcome
                // lands in the published status — the button does not
                // guess at it.
                Task { _ = await session.link() }
            case .unlink:
                confirmingUnlink = true
            }
        } label: {
            Text(LocalizedStringKey(leafState.actionKey))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(leafState.actionEnabled
                            ? appearance.colors.accent
                            : appearance.colors.textSecondary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(!leafState.actionEnabled)
        .accessibilityLabel(Text(LocalizedStringKey(leafState.actionKey)))
        .accessibilityIdentifier("settings.spotify.action")
    }
}

/// The Spotify section's leaf state machine (design-l2 §17), total over
/// `SpotifyAccountSession.Status`. The four caregiver-visible states each
/// render exactly one shipped status line and one action; `.linking` is
/// the in-flight state where the buttons disable.
enum SpotifySettingsLeafState: Equatable {
    /// `status.notLinked` — primary action: Link.
    case notLinked
    /// An attempt is in flight; no outcome is announced until one exists.
    case linking
    /// `linked(.premium)` — primary action: Unlink.
    case linkedPremium
    /// `linked(.free)` and `linked(.unknown)`: L2-D14 makes unknown behave
    /// as free ("playback opens the Spotify app"), so both render the
    /// free-tier line.
    case linkedFree
    /// `linkFailed` — primary action: Link again.
    case linkFailed

    init(state: SpotifyAccountSession.Status) {
        switch state {
        case .notLinked: self = .notLinked
        case .linking: self = .linking
        case .linked(.premium): self = .linkedPremium
        case .linked(.free), .linked(.unknown): self = .linkedFree
        case .linkFailed: self = .linkFailed
        }
    }

    /// The status line's catalog key. `.linking` keeps the not-linked
    /// line: no account exists yet, so "Not connected" is the truth and
    /// no outcome is announced early (design §17 "no status change until
    /// an outcome exists"); the four shipped lines stay the only copy
    /// this surface can show.
    var statusKey: String {
        switch self {
        case .notLinked, .linking: return "spotifySettings.status.notLinked"
        case .linkedPremium: return "spotifySettings.status.linked"
        case .linkedFree: return "spotifySettings.status.freeTier"
        case .linkFailed: return "spotifySettings.status.linkFailed"
        }
    }

    /// The one primary action per state.
    var action: SpotifySettingsAction {
        switch self {
        case .notLinked, .linking, .linkFailed: return .link
        case .linkedPremium, .linkedFree: return .unlink
        }
    }

    /// Disabled exactly while an attempt is in flight (design §17).
    var actionEnabled: Bool { self != .linking }

    /// The action's localised label — the same key the dialog's confirm
    /// button carries, so the button the caregiver tapped and the button
    /// that confirms say the same words.
    var actionKey: String {
        action == .link ? "spotifySettings.link" : "spotifySettings.unlink"
    }

    /// The status glyph (always beside the status TEXT — glyphs and
    /// colour never carry the state alone).
    var statusIcon: String {
        switch self {
        case .notLinked: return "music.note"
        case .linking: return "ellipsis.circle"
        case .linkedPremium, .linkedFree: return "checkmark.circle.fill"
        // The retry glyph — maintenance, not an alarm.
        case .linkFailed: return "arrow.clockwise"
        }
    }

    /// The colour tone the view maps to appearance colours. Deliberately
    /// neutral for `.linkFailed` ([W2-review D3]): the provider expires
    /// refresh tokens after 6 months (verified 2026-10-07, T-110 V-1), so
    /// an unlink → relink cycle is routine maintenance for every linked
    /// household and the surface must not paint it as a fault.
    var tone: Tone {
        switch self {
        case .linkedPremium, .linkedFree: return .connected
        case .notLinked, .linking, .linkFailed: return .neutral
        }
    }

    enum Tone: Equatable { case neutral, connected }
}

/// The surface's single primary action.
enum SpotifySettingsAction: Equatable {
    case link
    case unlink
}

/// Cost-governance card inside the Gemini settings screen (open item #5,
/// 2026-09-06). `@ObservedObject` on the governor so today's count and
/// the cap value update live while the screen is open (the governor
/// publishes from the main queue). Numbers render in Devanagari digits in
/// the Nepali locale — the same convention as the festival reminder card.
private struct GeminiCostCard: View {
    @Environment(\.appAppearance) private var appearance
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
        count >= cap ? appearance.statusForeground(DesignTokens.stateError) : appearance.colors.accentForeground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("settings.gemini.cost.title", systemImage: "number.circle.fill")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            HStack(spacing: 10) {
                Text(L10n.fmt("settings.gemini.cost.usage", locale: locale,
                              Self.number(count, locale: locale),
                              Self.number(cap, locale: locale)))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold)).foregroundStyle(count >= cap ? appearance.statusForeground(DesignTokens.stateError) : appearance.colors.textPrimary)
                Spacer()
            }
            ProgressView(value: progress)
                .tint(progressTint)
            HStack {
                Text("settings.gemini.cost.capLabel")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                Stepper(value: Binding(
                    get: { cap },
                    set: { governor.setSoftDailyCap($0) }
                ), in: GeminiCostGovernor.minimumSoftDailyCap...GeminiCostGovernor.maximumSoftDailyCap,
                step: 10) {
                    Text(Self.number(cap, locale: locale))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold)).foregroundStyle(appearance.colors.accentForeground)
                }
            }
            if count >= cap {
                Text("settings.gemini.cost.reachedToday")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
            } else if count >= warningThreshold {
                Text("settings.gemini.cost.nearLimit")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateListening))
            }
            Text("settings.gemini.cost.explanation")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.voiceEngine.title") {
            VStack(spacing: 16) {
                Text("settings.voiceEngine.explanation")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)

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

                // [LAT-M3] (2026-09-11) Honest interpreter-state caption:
                // one line stating which interpreter answers open-domain
                // questions right now — the same stack-consent +
                // key + budget inputs the per-turn selection uses, so
                // the caption can never disagree with what the chain
                // actually does next.
                Text(LocalizedStringKey(coordinator.isCloudInterpreterActive
                                        ? "voiceSettings.interpreter.cloud"
                                        : "voiceSettings.interpreter.local"))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.leading)

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
            captionColor = appearance.colors.textSecondary
        case (false, _):
            captionKey = "cloudFallback.off"
            captionColor = appearance.colors.textSecondary
        }
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.cloudFallbackEnabled },
                set: { coordinator.cloudFallbackEnabled = $0 }
            )) {
                Text("cloudFallback.title")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text(captionKey)
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.statusForeground(captionColor))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private func stackRow(_ stack: VoiceEngineStack, titleKey: String, subtitleKey: String) -> some View {
        let isSelected = coordinator.voiceEngineStack == stack
        return Button {
            coordinator.voiceEngineStack = stack
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(isSelected ? appearance.colors.accentForeground : appearance.colors.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(titleKey))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(LocalizedStringKey(subtitleKey))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accentForeground : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wake phrase "ये कान्छी" (open item #4) — Voice activation
//
// Family-facing "Voice activation" screen. Its one job is honest status:
// everything that must be true for the wake word to actually listen (the
// Settings toggle ON, the sherpa-onnx runtime linked into the build, the
// KWS model directory bundled) is shown explicitly, and every non-active
// state names the concrete next step — no dead ends (spec §7). Until all
// pieces exist the app keeps `NullWakeWordEngine` (today's exact
// behavior), which this screen says plainly instead of pretending
// otherwise. (2026-09-08: the Porcupine access-key paste-in and its
// `.ppn` checklist rows are gone — the sherpa-onnx KWS engine needs
// neither, and the wake phrase + bundled model are stated in plain copy.)
//
// Presentation mapping shared between the Settings row dot and this
// screen's banner (2026-09-06). `WakeWordStatus` itself is pure logic in
// Services/Voice/WakeWordConfig.swift (unit-tested); only the color/text
// choices live here.
extension WakeWordStatus {
    var presentationColor: Color {
        switch self {
        case .active: return DesignTokens.stateSpeaking
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
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "wakeWord.title") {
            VStack(alignment: .leading, spacing: 12) {
                Text("wakeWord.explanation")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)

                statusBlock(coordinator.wakeWordStatus)

                toggleCard

                phraseCard

                if coordinator.wakeWordStatus != .active {
                    Text("wakeWord.talkStillWorks")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// One colored card per status — title line plus a plain-language
    /// explanation. `.needsSetup` additionally lists the missing pieces
    /// (see `setupChecklist`).
    @ViewBuilder
    private func statusBlock(_ status: WakeWordStatus) -> some View {
        switch status {
        case .active:
            statusCard(color: appearance.colors.accentForeground,
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
                    .fill(appearance.statusForeground(color))
                    .frame(width: 12, height: 12)
                Text(titleKey)
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            Text(detailKey)
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// Renders ONLY the absent pieces, each keyed to the coordinator's own
    /// provisioning truth (`isWakeWordRuntimeLinked` /
    /// `SherpaKWSModelFile.bundledDirectory()` — the same inputs the launch
    /// engine decision used), so the checklist can never contradict the
    /// status banner above it.
    private var setupChecklist: some View {
        VStack(spacing: 10) {
            if !AppCoordinator.isWakeWordRuntimeLinked {
                missingRow("wakeWord.setupNeedsRuntime")
            }
            if SherpaKWSModelFile.bundledDirectory() == nil {
                missingRow("wakeWord.setupNeedsModel")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private func missingRow(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
            Text(LocalizedStringKey(key))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// The on/off master switch. ON is the default and means the wake word
    /// genuinely listens whenever the KWS model is bundled (see
    /// `WakeWordPreferences`); the coordinator's didSet persists it AND
    /// closes/opens the live audio gate, so switching OFF here stops the
    /// mic feed to the wake-word engine immediately. The battery trade-off
    /// is disclosed underneath (honesty requirement).
    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.wakeWordEnabled },
                set: { coordinator.wakeWordEnabled = $0 }
            )) {
                Text("wakeWord.toggleLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            if coordinator.wakeWordEnabled {
                Text("wakeWord.batteryNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// What the wake word listens for — and where the listening model
    /// lives. The model line is shown ONLY when the model is really
    /// bundled (coordinator's own provisioning truth); when it is absent
    /// the needs-setup checklist names it instead, so this card can never
    /// claim a model that isn't there. (2026-09-08: replaces the Porcupine
    /// access-key paste-in card — sherpa-onnx needs no key.)
    private var phraseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 18)).foregroundStyle(appearance.colors.accentForeground)
                Text("wakeWord.phrase")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            if coordinator.isWakeWordProvisioned {
                Text("wakeWord.modelBundled")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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

// MARK: - Family list presentation (T-162; design-l2 §2.7)

/// The pure decisions behind `FamilyContactsSettingsView`'s rows, split
/// out of the view so the harness can pin them without a view instance
/// (the find/photo presentation seams' pattern).
enum FamilyListPresentation {

    /// The `family.link.chip` capsule's visibility (design-l2 §2.7):
    /// exactly the contact whose link the snapshot VERIFIES. A stored
    /// claim the snapshot does not verify (a stale link, FR-FCU-006) is
    /// ABSENT from `links`, so it shows NOTHING here — the editor's
    /// link area owns the honest stale line; the list never claims
    /// "Linked" for an unverified reference.
    static func showsLinkChip(_ contact: FamilyContact,
                              verifiedLinks: VerifiedLinksSnapshot) -> Bool {
        verifiedLinks.links[contact.id] != nil
    }
}

struct FamilyContactsSettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.displayScale) private var displayScale

    /// The open add/edit sheet — nil when closed. Item-driven so a
    /// swipe-dismiss also clears it (same pattern as CallView's
    /// handle-capture sheet).
    @State private var editorTarget: FamilyContactEditorTarget?

    /// Row faces by contact id, resolved OFF the body (design review P2
    /// — "keep image-file reads out of `body`"). The pass below runs
    /// only when a face identity actually changes, hands each face
    /// through the shared downsampling cache (so it is sized for the
    /// 44pt circle it is drawn in), and the body then reads plain
    /// state. T-157: the pass resolves through the coordinator's async
    /// face path, so a linked contact's SYSTEM photo wins where
    /// available (design-l1 §10.1).
    @State private var contactPhotos: [UUID: UIImage] = [:]

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
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
            FamilyContactWizardSheet(target: target) { other in
                // Steering (family-contacts-unify T-159, design-l2 §2.3
                // step 3): the parent swaps the sheet's item to the OTHER
                // contact's editor in place — the item id changes, so
                // SwiftUI replaces the content; no dismiss/re-present
                // race. The first contact's draft was never committed
                // and is discarded by design.
                editorTarget = .edit(other)
            }
        }
        .task(id: faceIdentities) {
            var resolved: [UUID: UIImage] = [:]
            for contact in coordinator.familyContacts {
                let identity = coordinator.faceIdentity(for: contact)
                let face = await coordinator.faceThumbnail(
                    for: contact,
                    diameter: DesignTokens.iconBadgeDiameter,
                    displayScale: displayScale)
                // Post-await identity re-check (design-l2 §4.4):
                // `.task` cancellation is best-effort, so the guard is
                // the guarantee — a face resolved for a superseded
                // identity is dropped, never assigned.
                guard coordinator.faceIdentity(for: contact) == identity else { continue }
                if let face { resolved[contact.id] = face }
            }
            contactPhotos = resolved
        }
    }

    /// Identity of everything the row faces depend on (design-l2 §4.4):
    /// the ARRAY of per-contact face identities — who is on the roster,
    /// which file each face lives in, the resolved system-photo token
    /// and the epoch. `.task(id:)` re-runs exactly when one of those
    /// changes; the id component matters because editing a contact
    /// KEEPS its id.
    private var faceIdentities: [String] {
        coordinator.familyContacts.map { coordinator.faceIdentity(for: $0) }
    }

    /// Opens the add sheet (hidden at the cap — nothing to add).
    private var addButton: some View {
        Button {
            editorTarget = .add
        } label: {
            Text("settings.family.add")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
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
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Role chips (family-emergency task, 2026-09-07):
                    // the emergency number and the doctor/GP stand out
                    // next to the plain relationship caption.
                    if contact.isEmergencyContact {
                        roleChip(L10n.str("family.emergencyBadge",
                                          locale: coordinator.activeLocale),
                                 tint: appearance.badgeTint(.emergency))
                    }
                    if isDoctorRelationship(contact.relationship) {
                        roleChip(L10n.str("family.relationship.doctor",
                                          locale: coordinator.activeLocale),
                                 tint: appearance.colors.accentForeground)
                    }
                    Text(contact.relationship)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                    // The link chip (T-162, design-l2 §2.7) — appended
                    // to the role-chip row, VERIFIED links only.
                    if FamilyListPresentation.showsLinkChip(
                        contact, verifiedLinks: coordinator.verifiedLinks) {
                        linkChip(contact)
                    }
                }
                Text(contact.phone)
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                if let handle = contact.messengerHandle, !handle.isEmpty {
                    Text(L10n.fmt("settings.family.messengerHandle",
                                  locale: coordinator.activeLocale, handle))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
            }
            Spacer()
            Button {
                editorTarget = .edit(contact)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 20))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.family.edit"))
            Button(role: .destructive) {
                coordinator.removeFamilyContact(id: contact.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.family.delete"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// One small role capsule (family-emergency task, 2026-09-07) —
    /// the same accent-tint capsule the call results' `familyChip`
    /// uses, parameterized by text and tint so the emergency flag can
    /// wear the emergency red while the doctor wears the accent.
    /// Decorative for VoiceOver like its call-row sibling: the
    /// relationship caption right beside it already says who the
    /// person is.
    private func roleChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    /// The `family.link.chip` capsule (T-162, design-l2 §2.7) — shown
    /// on the role-chip row for a contact whose link the snapshot
    /// VERIFIES (see `FamilyListPresentation.showsLinkChip`). It is the
    /// row's affordance INTO the link/unlink flow: tapping it opens
    /// this contact's editor, whose link area owns the link's state
    /// and its unlink — committed through the ONE copy-preserving path
    /// (`setFamilyContactLink` with the §1.9 mode rule; T-158). The
    /// visual capsule stays chip-sized; the frame + `contentShape`
    /// carry the ≥44 pt tap floor. Unlike the decorative role chips it
    /// is NOT hidden from VoiceOver — it is interactive, so its label
    /// is the frozen `family.link.chip` copy (no inline strings).
    private func linkChip(_ contact: FamilyContact) -> some View {
        Button {
            editorTarget = .edit(contact)
        } label: {
            Text(L10n.str("family.link.chip", locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.accentForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(appearance.colors.accentForeground.opacity(0.12))
                .clipShape(Capsule())
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.str("family.link.chip", locale: coordinator.activeLocale)))
    }

    /// True when the stored relationship is the wizard's doctor option
    /// (the GP kind chip's condition). Records store the option's
    /// LABEL in the save-time language, and en+ne are the only two
    /// this app writes — so an exact match against the option label in
    /// both shipped locales covers every doctor record, whichever
    /// language the list is being viewed in.
    private func isDoctorRelationship(_ stored: String) -> Bool {
        stored == Self.doctorOptionLabel(for: .english)
            || stored == Self.doctorOptionLabel(for: .nepali)
    }

    private static func doctorOptionLabel(for language: AppLanguage) -> String {
        L10n.str("family.relationship.doctor", locale: language.locale)
    }

    /// The row's 44pt visual: the stored photo when one is on file,
    /// else the initials avatar. Photos are best-effort — a missing or
    /// unreadable file resolves to nil (the `faceIdentities` batch
    /// pass's outcome above, T-157) and falls through to initials.
    @ViewBuilder
    private func contactPhotoThumb(_ contact: FamilyContact) -> some View {
        let diameter = DesignTokens.iconBadgeDiameter
        if let photo = contactPhotos[contact.id] {
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
///      `preselectedOption(for:)`). Below the dropdown sits the
///      optional "Emergency contact" toggle (family-emergency task,
///      2026-09-07) — flagged contacts are whom the Emergency button
///      dials first (see `AppCoordinator.emergencyContact`).
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
///
/// T-159 (family-contacts-unify, 2026-10-12; design-l2 §2.2/§2.3) adds
/// the phone-contact LINK to the find step: the results now come from
/// `UnifiedContactSearch` (the same engine the Phone leaf runs — the
/// family's own lives and the book's names in one ranked list), a
/// tapped book row records an uncommitted `draftLink` (no link is
/// stored until Save), the link area offers linked-to / stale / pick-
/// hint states with an unlink control, and a result whose person
/// another family contact already links to STEERS to that contact
/// (through `onSteerTo`, which the parent turns into an in-place sheet
/// swap) instead of silently re-linking. `.limited` contacts access is
/// READABLE here: the granted set loads and an honest caption sits
/// under the field (the T-148b wizard obligation, design-l2 §3.5).
/// [RESPONSIVENESS] (2026-10-14) One committed nickname DRAFT entry. The
/// wizard's list used to be `[String]` rendered with
/// `ForEach(Array(enumerated()), id: \.offset)` and remove closures that
/// captured the row's index: removing an earlier entry shifted every
/// later row's identity (SwiftUI saw in-place text swaps, not removals)
/// and a stale row's closure could then remove the WRONG spelling. A
/// per-entry UUID fixes both — identity survives removals and removal
/// addresses the entry itself — while duplicate spellings stay fully
/// supported (offset ids never collided, and string ids could not
/// represent the duplicates the editor deliberately preserves).
private struct NicknameDraftEntry: Identifiable, Equatable {
    let id: UUID
    /// The verbatim spelling (validated at entry; never re-trimmed here).
    let text: String

    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

private struct FamilyContactWizardSheet: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// [AX-VIEWPORT] Gates the accessibility-size layout switches in the
    /// search rows, the consent caption and the photo controls.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let target: FamilyContactsSettingsView.FamilyContactEditorTarget

    /// Steering callback (family-contacts-unify T-159, design-l2 §2.1/
    /// §2.3): the wizard never edits ANOTHER contact itself — tapping an
    /// already-linked result hands the other contact here, and the
    /// PARENT swaps the sheet's item to that contact's editor in place.
    let onSteerTo: (FamilyContact) -> Void

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
    ///
    /// `doctor` (family-emergency task, 2026-09-07 — the GP's option,
    /// last in the user-specified list) is the other one the resolver
    /// vocabulary lacks: its `anchorWord` is set ("doctor") but no
    /// resolver word maps onto it, so the anchor never fires and only
    /// the exact-label rule can select it — a doctor saved in the other
    /// locale needs one fresh pick, same as a friend.
    private enum RelationshipOption: String, CaseIterable, Identifiable {
        case daughter, son, mother, father, sister, brother, husband,
             wife, grandmother, grandfather, friend, doctor

        var id: String { rawValue }
        /// The `family.relationship.*` localization key for this option.
        var labelKey: String { "family.relationship.\(rawValue)" }
        /// The anchor word this option's labels normalize onto — nil
        /// for `friend`, which the resolver vocabulary lacks (`doctor`
        /// keeps its word even though the resolver has no entry for it,
        /// so the anchor stays inert rather than pretending to be one).
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
    // The nickname list draft (T-160, design-l2 §2.1/§2.5): committed
    // entries only — `nicknameDraft` is the add field's text. Removes
    // and adds are save-time edits like every other field; the stored
    // list round-trips through `normalizedNicknames` at the coordinator.
    // [RESPONSIVENESS] (2026-10-14) Entries carry their own UUIDs
    // (`NicknameDraftEntry`) so list identity survives removals; the
    // save/load seams map to and from the stored `[String]`.
    @State private var nicknames: [NicknameDraftEntry] = []
    @State private var nicknameDraft = ""
    /// [PER-CONTACT-OVERRIDE] (2026-10-14) The contact's dialer
    /// override draft: nil = follow the global primary/secondary.
    @State private var dialerOverride: CallApp?
    // Home address for voice navigation (directions task, 2026-09-07) —
    // free-form text; blank saves as nil (no address = not a navigation
    // target).
    @State private var address = ""
    // The address the family's calendar invitation goes to (calendar &
    // family sharing task, 2026-09-16) — blank saves as nil, which means
    // "no invite". Optional for an ordinary contact; MANDATORY while the
    // emergency flag is on, because the invite policy makes an emergency
    // contact an attendee of every shared event. `FamilyContactValidation`
    // owns that rule — see `emailIssue`.
    @State private var email = ""
    // Whether the "Emergency contact" toggle is on (family-emergency
    // task, 2026-09-07) — flagged contacts are whom the Emergency
    // button dials first. Optional like the photo: an add starts off,
    // an edit loads the stored flag in `loadDraft`.
    @State private var isEmergencyContact = false

    // Photo draft state: a just-picked image, whether the user asked to
    // remove the stored one, and the stored one itself (resolved once per
    // face identity for an edit).
    @State private var pickedPhoto: UIImage?
    @State private var removingStoredPhoto = false
    @State private var storedPhoto: UIImage?
    @State private var photoPickerItem: PhotosPickerItem?

    /// Whether the resolved `storedPhoto` face came from the linked
    /// SYSTEM record — the `family.photo.sourceSystem` caption's
    /// attribution (T-160, design-l2 §2.4). Assigned by the SAME face
    /// task as `storedPhoto` from one precedence pass, so the caption
    /// and the displayed bytes can never disagree (an app-local fallback
    /// never claims to come from the phone book).
    @State private var storedPhotoIsSystem = false

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

    /// The picked-but-uncommitted link (family-contacts-unify T-159,
    /// design-l2 §2.1): recorded by `prefill` when the tapped row
    /// carries a live record identifier, cleared by the draft's unlink
    /// control, passed through Save. NO link is stored until Save.
    @State private var draftLink: SystemContactLink?
    /// The picked record's display name AT PICK TIME (design-l2 §2.1) —
    /// the `family.link.linkedTo` line's name, kept even if the sweep
    /// later moves under the open sheet.
    @State private var draftLinkBookName: String?
    /// The other contact a tap on an already-linked result points at
    /// (design-l2 §2.1/§2.3): the tap itself is a pure selection —
    /// nothing is picked, no field changes, no store write — and the
    /// intent is dropped by any new search keystroke or a successful
    /// pick.
    @State private var steerTarget: FamilyContact?

    /// The post-save system-photo outcome to render (T-160, design-l2
    /// §2.1/§2.6): nil before a save with a photo change. Non-nil keeps
    /// the sheet open AT the photo step with the honest label under the
    /// preview and the footer offering Close — the owner sees exactly
    /// what happened (L1 §10.2 step 3; F4: `.written` shows
    /// `family.photo.state.updatedInSystem` rather than auto-dismiss).
    @State private var photoSaveState: FamilyPhotoEditorState?

    /// The add-case identity, known BEFORE the store write (T-160,
    /// design-l2 §2.6): the post-save photo step needs the saved
    /// contact's id, and the store write runs first. `@State` keeps one
    /// value for this sheet presentation, so re-saving an add updates
    /// the SAME contact instead of minting a second one.
    @State private var newDraftID = UUID()

    private let directory = AddressBookDirectory()

    init(target: FamilyContactsSettingsView.FamilyContactEditorTarget,
         onSteerTo: @escaping (FamilyContact) -> Void) {
        self.target = target
        self.onSteerTo = onSteerTo
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

    /// The editing contact's CURRENT roster row (family-contacts-unify
    /// T-159). `target` is a snapshot from open time, and the link area
    /// must read live state: the unlink button commits mid-sheet, and
    /// the captured value would keep claiming the cleared link and
    /// render a phantom `family.link.stale` line after a SUCCESSFUL
    /// unlink. nil for a fresh add (and, defensively, for a contact
    /// deleted elsewhere while the sheet is up).
    private var liveEditingContact: FamilyContact? {
        guard let id = editingContact?.id else { return nil }
        return coordinator.familyContacts.first { $0.id == id }
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
    /// enforces: a name, a number, and a relationship, plus the email
    /// rule for an emergency contact (calendar & family sharing task,
    /// 2026-09-16). Save on the last step is dead without all of them.
    private var canSave: Bool {
        hasNameAndPhone && relationshipOption != nil && emailIssue == nil
    }

    /// Why the email draft blocks the save, or nil when it does not.
    /// Read from `FamilyContactValidation` rather than re-checked here,
    /// so the button's state and the caption under the field can never
    /// disagree — the same single-source rule every other gate on this
    /// screen follows. Always nil while the draft is not an emergency
    /// contact: the field is optional then.
    private var emailIssue: FamilyContactValidation.Issue? {
        FamilyContactValidation.issue(email: email,
                                      isEmergencyContact: isEmergencyContact)
    }

    /// The blocking issue's caption key. One arm per `Issue`, so a new
    /// rule cannot be added without a line to show for it.
    private func emailIssueKey(_ issue: FamilyContactValidation.Issue) -> String {
        switch issue {
        case .emailRequired: return "family.contact.emailRequired"
        case .emailInvalid: return "family.contact.emailInvalid"
        }
    }

    var body: some View {
        ZStack {
            VoiceBridgeBackground(theme: coordinator.appTheme)
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Text("settings.family.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        progressRow
                        stepContent
                        footerButtons
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
        // A new keystroke supersedes any steering intent (T-159,
        // design-l2 §2.3 step 5): the row the user pointed at may not
        // even render in the next result list.
        .onChange(of: searchText) { _ in
            steerTarget = nil
        }
        // The stored face, resolved through the coordinator's async
        // precedence resolver (T-157, design-l2 §4.4) — system photo
        // where the contact is verified-linked and one is readable,
        // the app-local file otherwise, nil for the initials avatar.
        // Keyed on the face identity, so a link/photo/epoch change
        // re-resolves. A fresh add has no identity: nothing to resolve.
        // T-159: the LIVE roster row (see `liveEditingContact`) — the
        // unlink's copy-first consequence must reach this preview, and
        // the captured target would key the task to the pre-unlink
        // identity and clear the photo the never-lose rule just saved.
        .task(id: storedFaceIdentity) {
            guard let contact = liveEditingContact else { return }
            let identity = coordinator.faceIdentity(for: contact)
            // T-160: the pair resolves in ONE precedence pass — the image
            // and whether it came from the linked system record (the
            // source caption's attribution, §2.4).
            let face = await coordinator.faceImageWithSource(for: contact)
            // Post-await identity re-check (design-l2 §4.4): abandon the
            // assignment when the identity moved while awaiting — the
            // re-keyed task resolves the fresh face anyway.
            guard coordinator.faceIdentity(for: contact) == identity else { return }
            storedPhoto = face.image
            storedPhotoIsSystem = face.isSystemPhoto
        }
    }

    /// The editing contact's face identity — nil for a fresh add (no
    /// stored face). The sheet's `.task(id:)` key above. Reads the
    /// LIVE roster row (T-159; see `liveEditingContact`).
    private var storedFaceIdentity: String? {
        liveEditingContact.map { coordinator.faceIdentity(for: $0) }
    }

    // MARK: Sheet chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .card, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            Spacer(minLength: 8)
            EmergencyIconButton()
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
                            ? appearance.colors.accentForeground
                            : appearance.colors.textSecondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                }
            }
            .accessibilityHidden(true)
            Text(L10n.fmt("family.step.indicator",
                          locale: coordinator.activeLocale, step.position))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
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
            .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
            .foregroundStyle(appearance.colors.textPrimary)
    }

    // MARK: Step 1 — find the contact

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.find")
            searchSection
            // The link area renders INSIDE the find step, in add AND
            // edit (T-159, design-l1 §11.1, design-l2 §2.2).
            if showsLinkSection {
                linkSection
            }
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
                    // Caption token (DESIGN-REVIEW) — 18pt floor, Dynamic
                    // Type aware; was a fixed 17pt.
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                Text(LocalizedStringKey("family.addManually"))
            }
            .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
            .foregroundStyle(appearance.colors.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
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
            .font(.system(size: appearance.typography.bodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    // MARK: Step 1 — the native-contacts search

    @ViewBuilder
    private var searchSection: some View {
        VStack(spacing: 10) {
            switch access {
            case .allowed, .limited:
                // `.limited` is READABLE (design-l2 §3.5): it shares the
                // search body, and the honest limited caption renders
                // directly under the field (T-159, the T-148b wizard
                // obligation — the decided placement).
                searchField
                if access == .limited {
                    Text(L10n.str("call.search.accessLimited",
                                  locale: coordinator.activeLocale))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        // [AX-VIEWPORT] Essential consent text ("searching
                        // only a part of your contacts") — it wraps at
                        // accessibility sizes instead of truncating.
                        // Standard sizes keep the one-line caption.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
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
                // Caption token (DESIGN-REVIEW) — was a fixed 15pt.
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
            TextField(LocalizedStringKey("family.addSearch.placeholder"), text: $searchText)
                .font(.system(size: appearance.typography.bodyPointSize))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The unified matched rows, most-recently-called first — the SAME
    /// pure search the Phone leaf runs (T-159, design-l2 §2.2): the
    /// family roster (nickname tiers included) and the fetched book in
    /// one engine, with the coordinator's PUBLISHED index and verified
    /// links. Each row renders per its kind: a book row another roster
    /// contact already claims becomes a steering card instead of a
    /// selection, the editing contact's own row is skipped, and every
    /// other selectable row prefills (which also records the draft
    /// link). The rows ARE the engine's list, in the engine's order —
    /// there is no parallel tier table here to drift from it.
    @ViewBuilder
    private var searchResults: some View {
        if let entries {
            let outcome = UnifiedContactSearch.search(
                query: trimmedSearch,
                family: coordinator.familyContacts,
                index: coordinator.familyIndex,
                in: entries,
                verifiedLinks: coordinator.verifiedLinks,
                recency: coordinator.contactCallRecency)
            let rows = FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: coordinator.familyContacts,
                                                         editing: editingContact)
            if rows.isEmpty {
                Text("call.search.noResults")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .selectable(let entry):
                            selectableResultRow(entry)
                        case .steering(let other):
                            steeringResultRow(other)
                        }
                    }
                }
                if outcome.moreAvailable {
                    Text("call.search.moreAvailable")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// A selectable row — today's shape exactly. Tapping it SELECTS the
    /// person (`prefill`).
    private func selectableResultRow(_ entry: AddressBookEntry) -> some View {
        Button {
            prefill(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18)).foregroundStyle(appearance.colors.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: appearance.typography.bodyPointSize,
                                      weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(entry.caption)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        // [AX-VIEWPORT] The caption ("Also in your phone
                        // book as …" / the number line) wraps at
                        // accessibility sizes instead of truncating at
                        // two lines. Standard sizes keep the 2-line cap.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// The steering card for an already-linked person (T-159, design-l2
    /// §2.2/§2.3): the honest sentence says WHO this result is — an
    /// existing family contact — and the ≥44 pt button (a11y
    /// `settings.family.edit`) hands the steer to the parent. A tap
    /// anywhere on the card records the intent (`steerTarget`) WITHOUT
    /// selecting anything — no field changes, no store write; VoiceOver
    /// reads the sentence, then the button.
    private func steeringResultRow(_ other: FamilyContact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.fmt("family.link.alreadyLinked",
                          locale: coordinator.activeLocale, other.name))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onSteerTo(other)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(appearance.colors.accentForeground)
                    Text(other.name)
                        .font(.system(size: appearance.typography.bodyPointSize,
                                      weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                        // [AX-VIEWPORT] The contact name wraps at
                        // accessibility sizes — a truncated name on the
                        // steer button would hide from the elder exactly
                        // WHOSE card they are being offered. Standard
                        // sizes keep the one-line name.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.family.edit"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The WHOLE card is a ≥44 pt target (design-l2 §2.2) — tapping
        // the sentence records the steer intent without committing it.
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .contentShape(Rectangle())
        .onTapGesture { steerTarget = other }
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// A tapped result SELECTS the person: the name + number prefill
    /// the manual fields (which appear for confirmation — the fields
    /// stay editable), the query clears so the results collapse, and —
    /// T-159, design-l2 §2.2 — the row's record is recorded as the
    /// draft link through the pure seam's non-empty-identifier guard
    /// (an empty identifier is "no linkable record", §3.5). Any
    /// steering intent is dropped: the pick superseded it (§2.3
    /// step 5).
    private func prefill(_ entry: AddressBookEntry) {
        name = entry.name
        phone = entry.phone
        showManualEntry = true
        searchText = ""
        steerTarget = nil
        guard let link = FamilyWizardFindPresentation.draftLink(for: entry) else { return }
        draftLink = link
        draftLinkBookName = entry.name
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("call.search.loading")
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadFailedRow: some View {
        HStack(spacing: 10) {
            Text("call.search.loadFailed")
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                loadEntries()
            } label: {
                Text("call.search.retry")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .appSurface(role: .accent, cornerRadius: 999)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The one point-of-use ask — plain-language card first, the system
    /// prompt only after the user taps Allow (constitution; mirror of
    /// CallView's access card).
    private var askAccessCard: some View {
        askCard(titleKey: "family.addSearch.allowTitle",
                bodyKey: "family.addSearch.allowBody")
    }

    /// The shared ask-card shape (T-160, design-l2 §2.4 — "reusing the
    /// wizard's existing ask-card pattern"): title + body + Allow, where
    /// Allow runs the SAME `grantAccess()` — the photo step's card and
    /// the find step's card can never diverge. Only the two keys vary;
    /// every string is a frozen catalog key, never inline copy.
    private func askCard(titleKey: String, bodyKey: String) -> some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(bodyKey))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                grantAccess()
            } label: {
                Text("call.search.allowButton")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The system-Settings link — the only remedy for a denied
    /// authorization (design-l2 §2.4's "existing system-settings link
    /// pattern"). Shared by the find step's blocked card and the photo
    /// step's denied line, so both doors lead to the same screen.
    private var openSettingsButton: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            Text("call.search.openSettings")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// Denied/restricted: the honest blocked line with the search
    /// hidden — only the system Settings screen can lift it, so the
    /// card points there. The "Add manually" path below never depended
    /// on contacts access.
    private var blockedSearchCard: some View {
        VStack(spacing: 12) {
            Text("call.search.deniedTitle")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("family.addSearch.deniedBody")
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .multilineTextAlignment(.center)
            openSettingsButton
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    // MARK: Step 1 — the link area (T-159; design-l2 §2.2, design-l1 §6.4)

    /// The link area's CURRENT state — the pure precedence rule from
    /// `FamilyWizardFindPresentation`, fed with the LIVE roster row
    /// (see `liveEditingContact`: the unlink button commits mid-sheet).
    private var linkState: FamilyWizardFindPresentation.LinkState {
        FamilyWizardFindPresentation.linkState(
            draftLink: draftLink,
            editing: liveEditingContact,
            verifiedLinks: coordinator.verifiedLinks)
    }

    /// Whether the link area renders at all. The readable arm always
    /// shows it (the pick hint IS the affordance's label, and the area
    /// is present in add AND edit — design-l2 §2.2); the unreadable
    /// arms show it ONLY when there is a link to show — a denied /
    /// undetermined search renders the honest access card and never an
    /// empty-but-enabled link section (the unit's failure path), while
    /// a stored link's unlink remedy stays reachable even after access
    /// was revoked (FR-FCU-006; design-l1 §6.4 "works for unverified/
    /// stale links").
    private var showsLinkSection: Bool {
        access?.allowsReading == true || linkState != .noPick
    }

    /// The link area (design-l2 §2.2). The `family.link.sectionTitle`
    /// heading shows in all four states; the states are exclusive and
    /// total:
    ///   1. a DRAFT pick — the name recorded at pick time, and an
    ///      unlink control that clears ONLY the draft (nothing was
    ///      stored);
    ///   2. the editing contact's VERIFIED stored link — the linked-to
    ///      line (the book name resolved from the current sweep, or
    ///      nameless in the narrow window) and an unlink control that
    ///      commits immediately (`setFamilyContactLink`);
    ///   3. the editing contact's STALE stored link — the honest stale
    ///      line and the same committing unlink;
    ///   4. no link — the pick hint only.
    /// No link is ever STORED from this area (the save path writes the
    /// draft); the only write here is the stored link's unlink.
    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle("family.link.sectionTitle")
            switch linkState {
            case .draftLinked:
                linkedToLine(draftLinkBookName)
                unlinkButton { clearDraftLink() }
            case .storedLinked:
                linkedToLine(resolvedBookName)
                unlinkButton { commitUnlink() }
            case .storedStale:
                staleLinkLine
                unlinkButton { commitUnlink() }
            case .noPick:
                Text("family.link.pickHint")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// The `family.link.linkedTo` line — the frozen sentence formatted
    /// with the linked record's name. A nil name (design-l2 §2.2's
    /// narrow window: the record left the sweep while the snapshot
    /// still verifies it) renders the design's "-" placeholder rather
    /// than a fabricated identity.
    private func linkedToLine(_ name: String?) -> some View {
        Text(L10n.fmt("family.link.linkedTo", locale: coordinator.activeLocale, name ?? "-"))
            .font(.system(size: appearance.typography.bodyPointSize))
            .foregroundStyle(appearance.colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The stale-link line: the snapshot no longer verifies the stored
    /// claim (FR-FCU-006) — the link is ignored and the honest sentence
    /// says so; the unlink control below still works.
    private var staleLinkLine: some View {
        Text(L10n.str("family.link.stale", locale: coordinator.activeLocale))
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The name on the linked-to line for the editing contact's
    /// VERIFIED link — resolved from the CURRENT sweep by the record's
    /// identifier (the snapshot's link is authoritative; the sweep only
    /// supplies the display name, design-l2 §2.2).
    private var resolvedBookName: String? {
        guard let identifier = liveEditingContact
            .flatMap({ coordinator.verifiedLinks.links[$0.id]?.identifier }) else {
            return nil
        }
        return FamilyWizardFindPresentation.bookName(for: identifier, in: entries)
    }

    /// The unlink control (design-l2 §2.2, §1.9): ≥44 pt, a11y label
    /// `family.link.unlink` and hint `family.link.unlinkHint`, with the
    /// hint ALSO visible as a caption under the button — the
    /// plain-language reassurance the owner needs before touching a
    /// link. `action` is the state's consequence: the draft clears
    /// locally; a STORED link commits through the coordinator.
    private func unlinkButton(_ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                Text("family.link.unlink")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .control, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("family.link.unlink"))
            .accessibilityHint(Text("family.link.unlinkHint"))
            Text("family.link.unlinkHint")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Clears the uncommitted DRAFT link only (design-l2 §2.2 state 1)
    /// — nothing was stored, so there is nothing to commit.
    private func clearDraftLink() {
        draftLink = nil
        draftLinkBookName = nil
    }

    /// Commits the STORED link's removal through the ONE unlink path
    /// (T-158, design-l2 §2.6/§1.9): the mode comes from the
    /// coordinator's pure rule fed with the CURRENT state — whether an
    /// app-local photo file exists, and whether the editor is showing
    /// the linked record's SYSTEM photo. On `false` nothing changed
    /// (e.g. the never-lose copy was refused): the line stays, never a
    /// false success.
    private func commitUnlink() {
        guard let contact = liveEditingContact else { return }
        let mode = unlinkModeForEditingContact(contact)
        Task {
            _ = await coordinator.setFamilyContactLink(id: contact.id, mode: mode)
        }
    }

    /// The unlink mode for the editing contact's current state (T-159,
    /// design-l2 §2.6/§1.9): `AppCoordinator.unlinkMode` fed with
    /// (a) whether an app-local photo file exists (`photoFilename`), and
    /// (b) whether what the editor DISPLAYS is the linked record's
    /// system photo — a VERIFIED link whose stored photo actually
    /// resolved (`storedPhoto` non-nil with no app-local file is
    /// exactly "system bytes present", the same derivation the photo
    /// step's source caption will use, §2.4). A linked record with no
    /// readable photo is NOT "displaying" one, so its unlink takes the
    /// plain clear instead of a copy that could never be made.
    private func unlinkModeForEditingContact(
        _ contact: FamilyContact) -> AppCoordinator.SystemContactUnlinkMode {
        AppCoordinator.unlinkMode(
            appLocalFileExists: contact.photoFilename != nil,
            displayedPhotoIsSystem: coordinator.verifiedLinks.links[contact.id] != nil
                && storedPhoto != nil)
    }

    private func refreshSearchAccess() {
        let status = AddressBookDirectory.access()
        access = status
        // T-159 (the T-148b wizard obligation; design-l2 §3.5, §8.2):
        // `.limited` is READABLE — the granted set loads; only `.denied`
        // and `.notDetermined` skip the load. Without this, relaunching
        // with an already-granted limited selection renders the search
        // UI over an unloaded book.
        guard status.allowsReading else { return }
        if entries == nil || loadFailed {
            loadEntries()
        }
    }

    private func grantAccess() {
        Task {
            // The binary request result is NEVER the load decision
            // (design-l2 §3.5): re-read the status — the system sheet
            // may yield `.limited`, which is readable.
            _ = await directory.requestAccess()
            access = AddressBookDirectory.access()
            if access?.allowsReading == true {
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

    // MARK: Step 2 — relationship (mandatory dropdown) + emergency flag

    /// The step's content (family-emergency task, 2026-09-07): the
    /// mandatory relationship dropdown, with the optional "Emergency
    /// contact" toggle beneath it — which number the emergency button
    /// dials first is a property of the person being added, so the two
    /// choices share one decision point.
    private var relationshipStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            relationshipMenu
            emergencyToggleCard
        }
    }

    private var relationshipMenu: some View {
        Menu {
            ForEach(RelationshipOption.allCases) { option in
                Button {
                    relationshipOption = option
                } label: {
                    HStack(spacing: 10) {
                        Text(L10n.str(option.labelKey,
                                      locale: coordinator.activeLocale))
                            .foregroundStyle(appearance.colors.textPrimary)
                        Spacer(minLength: 8)
                        if relationshipOption == option {
                            Image(systemName: "checkmark")
                                // Caption token (DESIGN-REVIEW) — was a
                                // fixed 15pt.
                                .font(.system(size: appearance.typography.captionPointSize, weight: .bold)).foregroundStyle(appearance.colors.accentForeground)
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
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            } else {
                Text(LocalizedStringKey("family.step.relationship"))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                // Caption token (DESIGN-REVIEW) — the dropdown indicator
                // was a fixed 13pt, the smallest glyph in the app.
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56)
        .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// The optional "Emergency contact" toggle (family-emergency task,
    /// 2026-09-07) — the same on/off card shape as the wake-word
    /// toggle. The caption states exactly what the flag does ("the
    /// emergency button dials this person first"), so the toggle cannot
    /// be read as "the only person who may be called".
    private var emergencyToggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isEmergencyContact) {
                Text("family.emergencyToggle")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("family.emergencyToggleHint")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    // MARK: Step 3 — photo (optional)

    /// The photo step (T-160, design-l2 §2.4): preview, the system-source
    /// caption, the pick/remove controls, the write-access cards (linked
    /// edits only) and — after a save with a photo change — the honest
    /// outcome line. The order IS the design's subview breakdown.
    private var photoStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("family.step.photo")
            photoPreview
                .frame(maxWidth: .infinity)
            sourceCaption
            photoControls
            writeAccessCards
            photoStateLine
        }
        .frame(maxWidth: .infinity)
    }

    /// `family.photo.sourceSystem` (design-l2 §2.4, FR-FCU-007 honest
    /// display): renders exactly when the preview shows the stored face
    /// AND that face resolved from the linked system record. A fresh
    /// pick or an explicit remove replaces the preview, and the caption
    /// falls away with it — as does an app-local fallback, which must
    /// never claim to come from the phone book.
    @ViewBuilder
    private var sourceCaption: some View {
        if FamilyWizardPhotoPresentation.showsSourceSystemCaption(
            displayingStoredPhoto: pickedPhoto == nil && !removingStoredPhoto,
            storedPhotoIsSystem: storedPhotoIsSystem) {
            Text("family.photo.sourceSystem")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    /// The write-authorization cards (design-l2 §2.4; FR-FCU-009 honest
    /// states): rendered only while EDITING a contact whose link the
    /// snapshot VERIFIES — the only state in which Save can actually
    /// write to the record (`syncSystemPhoto` answers `.skippedNoLink`
    /// otherwise, so an ask would be a dead end). `.notDetermined`
    /// offers the point-of-use ask card (Allow reuses the wizard's
    /// existing `grantAccess`, which re-reads the status — the sheet may
    /// yield `.limited`); `.denied` states the honest consequence with
    /// the system-Settings link (no nag); `.limited` renders NO card
    /// (readable — the write proceeds attempt-and-detect); `.allowed`
    /// likewise; nil (still reading) renders nothing, so no card can
    /// flash before the status resolves.
    @ViewBuilder
    private var writeAccessCards: some View {
        if let contact = liveEditingContact,
           coordinator.verifiedLinks.links[contact.id] != nil {
            switch access {
            case .notDetermined:
                askCard(titleKey: "family.photo.accessTitle",
                        bodyKey: "family.photo.accessBody")
            case .denied:
                photoAccessDeniedLine
            case .allowed, .limited, nil:
                EmptyView()
            }
        }
    }

    /// The `.denied` line (design-l2 §2.4): the frozen honest sentence
    /// plus the Open Settings button — the write cannot happen, the
    /// photo stays in the app only, and nothing here re-prompts.
    private var photoAccessDeniedLine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("family.photo.accessDeniedBody")
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            openSettingsButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The post-save outcome line (design-l2 §2.4/§1.5): the honest
    /// state rendered under the preview once the system-photo step
    /// answered — caption token, secondary color — with the access
    /// explanation alongside `.keptOnPhoneAccessDenied`. Nothing renders
    /// before a save (`photoSaveState` nil).
    @ViewBuilder
    private var photoStateLine: some View {
        if let state = photoSaveState {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(FamilyWizardPhotoPresentation.stateLabelKey(state)))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if FamilyWizardPhotoPresentation.showsAccessDeniedBody(state) {
                    Text("family.photo.accessDeniedBody")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
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
        // [AX-VIEWPORT] Two word-pills cannot share one line at
        // accessibility text sizes (the Remove pill pushed the picker
        // off the card edge). They stack at accessibility sizes.
        // Standard sizes keep today's side-by-side row exactly.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    addPhotoPicker
                    removePhotoButton
                }
            } else {
                HStack(spacing: 12) {
                    addPhotoPicker
                    removePhotoButton
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var addPhotoPicker: some View {
        PhotosPicker(selection: $photoPickerItem, matching: .images) {
            Text(displayedPhoto == nil ? "family.photo.add" : "family.photo.change")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .accent, cornerRadius: 999)
        }
    }

    @ViewBuilder
    private var removePhotoButton: some View {
        if editingContact != nil, displayedPhoto != nil {
            Button {
                pickedPhoto = nil
                removingStoredPhoto = true
            } label: {
                Text("family.photo.remove")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .control, cornerRadius: 999)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            // DESIGN-REVIEW (P2): a picked camera-roll image can be tens
            // of megapixels (~48 MB decoded) and this @State holds it for
            // the wizard's whole lifetime. The store only ever KEEPS
            // `ContactPhotoStore.maxDimension` on the longest edge, and
            // the preview is smaller still — so shrink to that as soon as
            // the bytes arrive: same saved photo, a fraction of the
            // resident memory.
            //
            // [RESPONSIVENESS] (2026-10-14) And pay that cost OFF the
            // main actor: `downsampled(from:)` is ImageIO's thumbnail
            // decode of the bytes (the full-size bitmap — the ~48 MB
            // peak this comment warns about — is never materialized),
            // run on a detached task so the wizard's main thread never
            // carries it; the same detached-load shape as the
            // address-book enumerate below. Undecodable bytes yield nil
            // → no photo, the old `UIImage(data:)` guard's soft failure.
            let thumb = await Task.detached(priority: .userInitiated) {
                DownsampledImageCache.downsampled(
                    from: data, maxPixelEdge: ContactPhotoStore.maxDimension)
            }.value
            guard let thumb else { return }
            pickedPhoto = thumb
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
            // [PER-CONTACT-OVERRIDE] (2026-10-14) The contact's dialer
            // override — Default follows the global primary/secondary;
            // a pick wins the voice call chain for this contact (its
            // fallback is the global primary when the pick is the
            // secondary — never a repeat).
            dialerOverridePicker
        }
    }

    /// The dialer-override row: Default (nil) plus the four call apps,
    /// in the chain's canonical order.
    private var dialerOverridePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.str("family.dialerOverride.title",
                          locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    dialerOverrideChip(nil, labelKey: "family.dialerOverride.default")
                    ForEach([CallApp.phone, .whatsApp, .messenger, .faceTime], id: \.self) { app in
                        dialerOverrideChip(app, labelKey: CallChannelChain.nameKey(for: app))
                    }
                }
            }
        }
    }

    private func dialerOverrideChip(_ app: CallApp?, labelKey: String) -> some View {
        let isSelected = dialerOverride == app
        return Button {
            dialerOverride = app
        } label: {
            Text(L10n.str(labelKey, locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(isSelected ? appearance.colors.accentForeground
                                            : appearance.colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .appSurface(role: isSelected ? .accent : .control,
                            cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("family.dialerOverride.\(app?.rawValue ?? "default")")
    }

    /// The "where to look" lines — the same numbered hints the call
    /// leaf's handle-capture sheet shows (`messenger.handleHints.*`),
    /// so every surface agrees on what a Messenger handle is.
    private var handleHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.str("messenger.handleHints.title",
                          locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
            ForEach(1...3, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index)")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        // DESIGN-REVIEW: the 22pt circle was fixed while
                        // the digit inside it scales — minWidth/minHeight
                        // lets the circle grow with the number instead of
                        // clipping it at Accessibility XXXL.
                        .frame(minWidth: 22, minHeight: 22)
                        .appSurface(role: .accent, cornerRadius: 999)
                    Text(L10n.str("messenger.handleHints.line\(index)",
                                  locale: coordinator.activeLocale))
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textPrimary)
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
            nicknameList
            nicknameAddRow
            nicknameHint
            Text(L10n.str("settings.family.address", locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
            TextField("", text: $address)
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            Text("settings.family.addressHint")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .padding(.horizontal, 4)
            // Email (calendar & family sharing task, 2026-09-16): where
            // the family's calendar invitation goes. Optional for an
            // ordinary contact, required while the emergency flag is on —
            // the hint and the blocking line below both read the one rule
            // in `FamilyContactValidation`, never a second check here.
            Text(L10n.str("family.contact.email", locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
            TextField("", text: $email)
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let issue = emailIssue {
                Text(L10n.str(emailIssueKey(issue), locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isEmergencyContact {
                Text(L10n.str("family.contact.emailHintEmergency",
                              locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The committed nickname entries (T-160, design-l2 §2.5) — one row
    /// per OCCURRENCE, so duplicates are preserved (the editor is a
    /// faithful editor of the stored list; "sanu" and "सानु" are always
    /// distinct entries). The stored spelling renders verbatim — no
    /// transliteration, no case folding.
    @ViewBuilder
    private var nicknameList: some View {
        if !nicknames.isEmpty {
            VStack(spacing: 8) {
                // [RESPONSIVENESS] (2026-10-14) Identity is the entry's
                // own UUID (`NicknameDraftEntry`): removing an earlier
                // entry removes NODE N, it no longer re-labels every
                // later row in place.
                ForEach(nicknames) { entry in
                    nicknameRow(entry)
                }
            }
        }
    }

    /// One entry's row: the verbatim spelling plus a ≥44 pt remove
    /// control whose a11y label names the entry it removes
    /// (`family.nickname.removeLabel`, formatted). Removal is a
    /// save-time edit like every other field — nothing touches the
    /// store until Save.
    private func nicknameRow(_ entry: NicknameDraftEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.text)
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                // [RESPONSIVENESS] (2026-10-14) Identity-addressed
                // removal: the row removes the entry it DRAWS, so a stale
                // row living through a removal animation can never hit a
                // neighbour (the old index capture could). No-op when the
                // entry is already gone.
                nicknames.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.fmt("family.nickname.removeLabel",
                                              locale: coordinator.activeLocale, entry.text)))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// The add control (design-l2 §2.5): hidden at the 8-entry envelope
    /// (`FamilyWizardNicknamePresentation.entryLimit`; nothing already
    /// stored is ever dropped — the control simply stops offering), the
    /// ≥44 pt Add button commits the draft through the F5 seam (trimmed;
    /// whitespace-only rejected AT ENTRY; a whole-grapheme 64-character
    /// cap), stored as entered within that bound.
    @ViewBuilder
    private var nicknameAddRow: some View {
        if FamilyWizardNicknamePresentation.canAdd(entries: nicknames.map(\.text)) {
            HStack(spacing: 8) {
                TextField("", text: $nicknameDraft,
                          prompt: Text(LocalizedStringKey("family.nickname.entryPlaceholder")))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .padding(.horizontal, 14)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                Button {
                    guard let entry = FamilyWizardNicknamePresentation.newEntry(from: nicknameDraft)
                    else { return }
                    nicknames.append(NicknameDraftEntry(entry))
                    nicknameDraft = ""
                } label: {
                    Text("family.nickname.add")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .appSurface(role: .accent, cornerRadius: 999)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("family.nickname.add"))
            }
        }
    }

    /// The store-as-entered reassurance caption (design-l2 §2.5): any of
    /// these names finds the person — typed or spoken — and the entries
    /// are kept exactly as entered.
    private var nicknameHint: some View {
        Text("family.nickname.hint")
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Footer — Back / Next (Save on the last step)

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button {
                step = Step(rawValue: step.rawValue - 1) ?? .find
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        // Caption token (DESIGN-REVIEW) — was a fixed 15pt.
                        .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                    Text(LocalizedStringKey("common.back"))
                }
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
                .padding(.horizontal, 18)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .card, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .disabled(step == .find)
            .opacity(step == .find ? 0.4 : 1)

            Spacer()

            primaryButton(titleKey: primaryTitleKey,
                          isEnabled: primaryEnabled,
                          action: primaryAction)
        }
        .padding(.top, 4)
    }

    /// The footer's primary label (T-160, design-l2 §2.6): while a
    /// post-save photo state is on screen the sheet stays open EXACTLY
    /// so the owner sees what happened — the primary button becomes
    /// `common.close`. Otherwise it is Next, or Save on the last step.
    private var primaryTitleKey: String {
        if photoSaveState != nil { return "common.close" }
        return step == .nickname ? "onboarding.stepFamily.save" : "family.step.next"
    }

    /// Close is always available (the save already happened); the flow's
    /// gates are unchanged otherwise.
    private var primaryEnabled: Bool {
        if photoSaveState != nil { return true }
        return step == .nickname ? canSave : canContinue
    }

    private func primaryAction() {
        if photoSaveState != nil {
            dismiss()
        } else if step == .nickname {
            save()
        } else {
            step = Step(rawValue: step.rawValue + 1) ?? .nickname
        }
    }

    private func primaryButton(titleKey: String, isEnabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(isEnabled ? appearance.colors.accent
                                      : appearance.colors.textSecondary.opacity(0.5))
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
        // The FULL stored list loads into the list editor (T-160,
        // design-l2 §2.5): the interim single-field draft that showed
        // only the first entry — and dropped the rest on save — is gone;
        // the complete draft list round-trips through the coordinator's
        // widened `nicknames:` seam. [RESPONSIVENESS] (2026-10-14) Each
        // loaded spelling gets a fresh draft UUID — the draft identity
        // only needs to be stable across THIS editing session.
        nicknames = contact.nicknames.map { NicknameDraftEntry($0) }
        address = contact.address ?? ""
        // The stored invitation address, so re-opening the editor shows
        // what the family will actually be invited at (calendar & family
        // sharing task, 2026-09-16).
        email = contact.email ?? ""
        // [PER-CONTACT-OVERRIDE] (2026-10-14) The stored override
        // round-trips into the draft; nil shows the Default option.
        dialerOverride = contact.dialerOverride
        // The stored flag shows in the step-2 toggle (family-emergency
        // task, 2026-09-07) — an edit opens with it pre-set.
        isEmergencyContact = contact.isEmergencyContact
        // Pre-select the stored relationship when it is one of the fixed
        // options (see `preselectedOption(for:)`). A legacy free-text
        // value that is none of them stays unselected — the step is
        // mandatory, so the user picks from the fixed list on the way
        // through (and the save then replaces the old text).
        relationshipOption = preselectedOption(for: contact.relationship)
        // Stepping back into the search must show the pre-filled fields.
        showManualEntry = true
        // The stored face is resolved by the sheet's `.task(id:)` above
        // through the coordinator's async precedence resolver (T-157,
        // design-l2 §4.4) — it is the only place a face is ever
        // assigned, so the sync app-local-only lookup cannot drift back
        // in. `storedPhoto` stays nil until that first resolution lands
        // (the initials avatar shows).
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
    ///      friend saved in the other locale needs one fresh pick. The
    ///      same holds for `doctor` (family-emergency task, 2026-09-07):
    ///      its anchor is inert because the resolver vocabulary has no
    ///      doctor word.
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

    /// The Save flow (T-160, design-l2 §2.6; L1 §10.2 sequencing):
    ///
    ///  1. the existing store write runs FIRST — the app-local photo, the
    ///     full nickname list and the draft link commit together, and a
    ///     failed write keeps the draft (today's semantics);
    ///  2. with NO photo change the sheet dismisses (today's UX) — no
    ///     system write is ever attempted;
    ///  3. with a photo change the post-save system-photo step runs in a
    ///     `Task`: every mapped state (`.written` included — F4) KEEPS
    ///     the sheet open at the photo step with the honest label under
    ///     the preview and the footer offering Close; only the nil state
    ///     (unlinked — today's behavior — or the contact having left the
    ///     roster) dismisses.
    private func save() {
        // The saved contact's id, known BEFORE the store write (design-l2
        // §2.6): the edit case's id, or the draft id minted for this
        // sheet presentation — so the post-save photo step can address
        // the contact whatever the store did with the write.
        let savedID = editingContact?.id ?? newDraftID
        let removingPhoto = removingStoredPhoto
        let messenger = trimmedOrNil(messengerHandle)
        // The full nickname list (T-160, design-l2 §2.5) goes to the
        // coordinator's widened `nicknames:` seam, which re-applies
        // `normalizedNicknames` at its own boundary (defense in depth);
        // the entry-level rules (trim, blank rejection, the F5 64-char
        // cap) already ran at the Add control.
        // Blank address saves as nil — no address = not a navigation
        // target (directions task, 2026-09-07).
        let homeAddress = trimmedOrNil(address)
        // Blank email saves as nil too — no address = no calendar
        // invitation, never an empty string the invite policy would then
        // have to special-case (calendar & family sharing task,
        // 2026-09-16). Normalization is the validator's, not a second
        // trim here.
        let contactEmail = FamilyContactValidation.normalizedEmail(email)
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
                photo: pickedPhoto, removingPhoto: removingPhoto,
                nicknames: nicknames.map(\.text),
                address: homeAddress, email: contactEmail,
                isEmergencyContact: isEmergencyContact,
                // T-159 (design-l2 §2.6): the draft link is the ONLY
                // link write this flow makes; nil leaves any stored
                // claim unchanged (clearing is the unlink path only).
                link: draftLink,
                dialerOverride: dialerOverride)
        } else {
            succeeded = coordinator.addFamilyContact(
                id: savedID, name: trimmedName, phone: phone,
                relationship: relationshipText, messengerHandle: messenger,
                photo: pickedPhoto,
                nicknames: nicknames.map(\.text),
                address: homeAddress, email: contactEmail,
                isEmergencyContact: isEmergencyContact,
                link: draftLink,
                dialerOverride: dialerOverride)
        }
        // A failed store write keeps the draft on screen — Save again to
        // retry; nothing was claimed that didn't happen, and no system
        // write is ever attempted for a failed store write (step 1
        // first).
        guard succeeded else { return }
        let photoIntent = pickedPhoto != nil || removingPhoto
        guard photoIntent else {
            // No photo changed → dismiss as today; no write attempted.
            dismiss()
            return
        }
        Task { @MainActor in
            let outcome = await coordinator.syncSystemPhoto(forContactID: savedID,
                                                            clearing: removingPhoto)
            // The remove path's display-precedence recheck (design-l2
            // §2.6/§10.4): a VERIFIED clear that still leaves a
            // resolvable system photo standing maps to
            // `.systemPhotoRemains` instead of the generic label —
            // checked through the SAME resolver the preview uses, after
            // the clear invalidated its cache.
            var systemPhotoStillPresent = false
            if FamilyWizardPhotoPresentation.rechecksRemoval(outcome: outcome,
                                                             removing: removingPhoto),
               let contact = coordinator.familyContacts.first(where: { $0.id == savedID }) {
                systemPhotoStillPresent = await coordinator
                    .faceImageWithSource(for: contact).isSystemPhoto
            }
            if let state = FamilyWizardPhotoPresentation.saveState(
                outcome: outcome,
                removing: removingPhoto,
                systemPhotoStillPresent: systemPhotoStillPresent) {
                photoSaveState = state
                step = .photo   // the honest label lives on the photo step
            } else {
                dismiss()       // unlinked, or the contact left the roster
            }
        }
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Find step presentation (T-159; design-l2 §2.2/§2.3)
//
// The wizard find step's PURE derivations, split out of the sheet so
// the unit harness can pin them without a view instance: which result
// rows render as selectable vs steering (and which are skipped), the
// stored-claimant rule behind steering, the draft-link record, the
// link area's state precedence, and the book-name resolution. The
// sheet is then a thin renderer of these values, and its row list is
// by construction a function of the engine's
// `UnifiedContactSearch.Outcome` — no parallel tier table exists to
// drift from it (the design-l2 §6.4 drift pin tests this seam AND the
// call site).

/// The pure derivations behind `FamilyContactWizardSheet`'s find step.
enum FamilyWizardFindPresentation {

    /// One rendered row of the find step's result list (design-l2 §2.2).
    enum Row: Equatable, Identifiable {
        /// A phone-book row the user can select: tap = `prefill` (name
        /// + number + the draft link record).
        case selectable(AddressBookEntry)

        /// The steering card for `other`, shown in place of the matched
        /// row: the person is already a family contact (their own row,
        /// a synthesized linked row, or the claimant of the matched
        /// book row's record) — the row is never selectable.
        case steering(FamilyContact)

        /// Stable identity within one result list: book rows keep the
        /// engine's number key, steering rows key on the person —
        /// prefixed so the two families can never collide.
        var id: String {
            switch self {
            case .selectable(let entry): return "pick-\(entry.normalized)"
            case .steering(let contact): return "steer-\(contact.id.uuidString)"
            }
        }
    }

    /// The link area's state (design-l2 §2.2), exclusive and total: the
    /// precedence is draft → stored-verified → stored-stale → no pick.
    /// The section heading renders in all four; the DISPLAY names are
    /// the view's business (`draftLinkBookName`, `resolvedBookName`).
    enum LinkState: Equatable {
        /// A picked-but-uncommitted link: the name recorded at pick
        /// time and an unlink control that clears ONLY the draft.
        case draftLinked
        /// The editing contact's stored link, verified by the snapshot.
        case storedLinked
        /// The editing contact's stored link, NOT verified — the
        /// honest `family.link.stale` line; the unlink still works
        /// (FR-FCU-006).
        case storedStale
        /// No link at all — the `family.link.pickHint` caption only.
        case noPick
    }

    /// The result rows to render, in the ENGINE's order (design-l2
    /// §2.2): each `.addressBook` row whose record is already claimed
    /// by another roster contact becomes a steering row instead of a
    /// selectable one; each `.family` row is a steering row — except
    /// the contact being edited, whose own row is skipped entirely
    /// (its link is the link area's subject). One row per person: the
    /// engine's Pass-3 merge already drops a VERIFIED link's book twin,
    /// but a STALE claimant's book row can still ride beside the
    /// claimant's own family row, and SwiftUI's `ForEach` demands
    /// unique ids — the first occurrence (the engine's ranking
    /// position) is kept.
    static func rows(for outcome: UnifiedContactSearch.Outcome,
                     roster: [FamilyContact],
                     editing: FamilyContact?) -> [Row] {
        let mapped: [Row] = outcome.entries.compactMap { result in
            switch result {
            case .addressBook(let entry):
                if let claimant = storedClaimant(entry.identifier, in: roster,
                                                 editing: editing) {
                    return .steering(claimant)
                }
                return .selectable(entry)
            case .family(let contact):
                if let editing, contact.id == editing.id { return nil }
                return .steering(contact)
            }
        }
        var seen: Set<String> = []
        return mapped.filter { seen.insert($0.id).inserted }
    }

    /// The roster contact whose STORED link claims `identifier` — the
    /// steering guard (design-l2 §2.2): verified or stale, the
    /// SUPERSET, so a number already linked to one family contact can
    /// never be silently re-linked to a second. The editing contact is
    /// excluded (re-picking one's own record stays the editor's own
    /// link area's business), roster order decides between several
    /// claimants, and an empty identifier is "no linkable record"
    /// (§3.5) — never a claim.
    static func storedClaimant(_ identifier: String,
                               in roster: [FamilyContact],
                               editing: FamilyContact?) -> FamilyContact? {
        guard !identifier.isEmpty else { return nil }
        return roster.first { contact in
            contact.id != editing?.id && contact.systemContact?.identifier == identifier
        }
    }

    /// The draft-link record a picked row carries (design-l2 §2.2's
    /// `prefill` guard): a live record's identifier plus the row's
    /// normalized number key as the fingerprint; nil for an empty
    /// identifier — "no linkable record", never a link target (§3.5).
    static func draftLink(for entry: AddressBookEntry) -> SystemContactLink? {
        guard !entry.identifier.isEmpty else { return nil }
        return SystemContactLink(identifier: entry.identifier, numberKey: entry.normalized)
    }

    /// The link area's state (design-l2 §2.2). `editing` must be the
    /// LIVE roster row — the unlink button commits mid-sheet, and a
    /// cleared claim must leave the area at `.noPick`, never at a
    /// phantom stale line.
    static func linkState(draftLink: SystemContactLink?,
                          editing: FamilyContact?,
                          verifiedLinks: VerifiedLinksSnapshot) -> LinkState {
        if draftLink != nil { return .draftLinked }
        guard let editing, editing.systemContact != nil else { return .noPick }
        return verifiedLinks.links[editing.id] != nil ? .storedLinked : .storedStale
    }

    /// The name shown on the `family.link.linkedTo` line for the
    /// editing contact's VERIFIED link: the sweep row carrying the
    /// linked record's identifier, when the sweep has one. nil — the
    /// narrow window where the record left the sweep while the
    /// snapshot still verifies it — renders the line without a name;
    /// the stale decision is the snapshot's, never the sweep's
    /// (design-l2 §2.2).
    static func bookName(for identifier: String, in entries: [AddressBookEntry]?) -> String? {
        guard !identifier.isEmpty else { return nil }
        return entries?.first { $0.identifier == identifier }?.name
    }
}

// MARK: - Photo step + save-flow presentation (T-160; design-l2 §2.4, §2.6, §10.4)

/// The pure decisions behind `FamilyContactWizardSheet`'s photo step and
/// save flow, split out of the sheet so the harness can pin them without
/// a view instance: the source caption's attribution rule, the post-save
/// state mapping (the §1.5 table plus the §10.4 remove path), the
/// state→label keys, and the remove-path recheck trigger. The sheet is a
/// thin renderer of these values.
enum FamilyWizardPhotoPresentation {

    /// The `family.photo.sourceSystem` caption shows exactly when the
    /// preview is displaying the STORED face AND that face came from the
    /// linked system record (design-l2 §2.4): a just-picked photo or an
    /// explicit remove replaces the preview, and an app-local fallback —
    /// or an unresolvable system photo — never claims to come from the
    /// phone book (FR-FCU-007 honest display).
    static func showsSourceSystemCaption(displayingStoredPhoto: Bool,
                                         storedPhotoIsSystem: Bool) -> Bool {
        displayingStoredPhoto && storedPhotoIsSystem
    }

    /// The post-save state to render, or nil for "today's UX" (dismiss).
    ///
    /// - nil outcome: the contact left the roster between the store write
    ///   and the photo step — nothing to describe.
    /// - the REMOVE path with a VERIFIED clear (`.written`) that still
    ///   leaves a resolvable system photo (`systemPhotoStillPresent`,
    ///   design-l2 §2.6/§10.4): `.systemPhotoRemains` — the honest,
    ///   actionable-in-Contacts sentence.
    /// - everything else maps through the TOTAL `FamilyPhotoEditorState`
    ///   table (§1.5): `.written` → `.updatedInSystem`, and every other
    ///   attempt outcome is the kept-on-phone family — never a false
    ///   success.
    static func saveState(outcome: SystemContactPhotoWriteOutcome?,
                          removing: Bool,
                          systemPhotoStillPresent: Bool = false) -> FamilyPhotoEditorState? {
        guard let outcome else { return nil }
        if rechecksRemoval(outcome: outcome, removing: removing), systemPhotoStillPresent {
            return .systemPhotoRemains
        }
        return FamilyPhotoEditorState.from(outcome)
    }

    /// Whether the remove path's display-precedence recheck applies —
    /// exactly a VERIFIED clear (design-l2 §2.6): any other outcome
    /// already maps through the §1.5 table, and the write path never
    /// rechecks (a write that read-back-verified its bytes has nothing
    /// left to check).
    static func rechecksRemoval(outcome: SystemContactPhotoWriteOutcome?,
                                removing: Bool) -> Bool {
        removing && outcome == .written
    }

    /// The label KEY for a post-save state — exhaustive, no default: a
    /// new `FamilyPhotoEditorState` case must decide its label at
    /// compile time. `.keptOnPhoneAccessDenied` renders the kept-on-
    /// phone sentence (the denied EXPLANATION is the sibling
    /// `showsAccessDeniedBody`).
    ///
    /// F4 (unit index, T-160): `.updatedInSystem` is the DELIBERATE
    /// label the owner's decision binds for a byte-verified `.written`
    /// write — `family.photo.state.updatedInSystem`, one string only.
    /// The design-document wording alignment (design-l1 §10.2 step 3's
    /// auto-dismiss phrasing) is deferred to T-165; do not invent a
    /// second string for it.
    static func stateLabelKey(_ state: FamilyPhotoEditorState) -> String {
        switch state {
        case .updatedInSystem:
            return "family.photo.state.updatedInSystem"
        case .keptOnPhone, .keptOnPhoneAccessDenied:
            return "family.photo.state.keptOnPhone"
        case .systemPhotoRemains:
            return "family.photo.state.systemPhotoRemains"
        }
    }

    /// The access-denied body renders ONLY beside the denied state
    /// (design-l2 §2.4/§1.5): access is off, the photo stays in the app,
    /// and only iPhone Settings can change that.
    static func showsAccessDeniedBody(_ state: FamilyPhotoEditorState) -> Bool {
        state == .keptOnPhoneAccessDenied
    }
}

// MARK: - Nickname step presentation (T-160; design-l2 §2.5, design-l1 §8.4)

/// The pure decisions behind the nickname step's list editor: the
/// 8-entry envelope (the add control stops offering at the cap — nothing
/// already stored is ever dropped) and the entry rule, routed through
/// the F5 editor/submission seam so the length bound is enforced in
/// exactly ONE place.
enum FamilyWizardNicknamePresentation {

    /// The editor's budget envelope (design-l1 §8.4 — the 12 × 8
    /// measurement envelope): the add row hides at eight entries.
    static let entryLimit = 8

    /// Whether the add row is offered for the current draft list.
    static func canAdd(entries: [String]) -> Bool {
        entries.count < entryLimit
    }

    /// The committed form of the add-field draft — `FamilyContact
    /// .cappedNickname` (F5): trimmed, whitespace-only rejected, an
    /// over-long value capped at 64 CHARACTERS as a whole-grapheme
    /// prefix (a Devanagari cluster is never split). nil = nothing to
    /// add; otherwise the entry is stored as entered within the bound —
    /// no transliteration, no case folding.
    static func newEntry(from draft: String) -> String? {
        FamilyContact.cappedNickname(draft)
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
    @Environment(\.appAppearance) private var appearance
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
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
            ForEach(NavigationMapApp.allCases, id: \.self) { app in
                mapAppRow(app)
            }
            Text("settings.places.mapAppHint")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
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
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accentForeground : Color.clear, lineWidth: 2)
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
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
            if coordinator.savedPlaces.isEmpty {
                Text("settings.places.empty")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
                    .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(place.address)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    editorTarget = .edit(place)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 20))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.places.edit"))
                Button(role: .destructive) {
                    coordinator.removePlace(id: place.id)
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.places.delete"))
            }
            if place.category == .home {
                HStack(spacing: 8) {
                    Image(systemName: place.isDefaultHome
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22)).foregroundStyle(place.isDefaultHome ? appearance.colors.accentForeground : appearance.colors.textSecondary)
                    Text("settings.places.defaultHome")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
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
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var addButton: some View {
        Button {
            editorTarget = .add
        } label: {
            Text("settings.places.add")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
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
    @Environment(\.appAppearance) private var appearance
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
        ZStack {
            VoiceBridgeBackground(theme: coordinator.appTheme)
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Text(editingPlace == nil
                     ? LocalizedStringKey("settings.places.add")
                     : LocalizedStringKey("settings.places.edit"))
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear { loadDraft() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .card, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            Spacer(minLength: 8)
            EmergencyIconButton()
        }
    }

    private func field(placeholderKey: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(placeholderKey), text: text)
            .font(.system(size: appearance.typography.bodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// Home vs important place. Switching a place to `.important` clears
    /// its default-home flag in the store (a non-home place can never be
    /// "home"), and the flag auto-promotes the next `.home` — the toggle
    /// below simply reflects whatever the store ended up with.
    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.places.category")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
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
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(isSelected ? .white : appearance.colors.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(isSelected ? appearance.colors.accent : appearance.colors.background)
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
                    .font(.system(size: 26)).foregroundStyle(isDefaultHome ? appearance.colors.accentForeground : appearance.colors.textSecondary)
                Text("settings.places.defaultHomeToggle")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("onboarding.stepFamily.save")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(canSave ? appearance.colors.accent
                                    : appearance.colors.textSecondary.opacity(0.5))
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
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    /// [AX-VIEWPORT] Gates the dose-time row's stacked layout.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The whole form as a value ([MED-OCR], 2026-09-18): the name, the
    /// printed strength, the dose-time rows and the purpose step. The view
    /// only moves state in and reads stored values out at Save — the
    /// pre-fill rules for a label scan live in `MedicationEditorDraft`,
    /// where they are tested without a view.
    ///
    /// It replaced three `@State` properties (`name`, `time`, `purpose`)
    /// because the label scan fills several of them at once, and "what a
    /// scan may overwrite" is exactly the rule a reader has to be able to
    /// find in one place.
    @State private var draft = MedicationEditorDraft()
    /// The photo the last scan took, held until Save. The entry does not
    /// exist yet — `addMedication` mints its id — so the picture waits here
    /// and is written as the entry's first visual aid at save time.
    @State private var scanPhoto: UIImage?
    /// True while the purpose lookup is in flight: the button becomes the
    /// "searching" line so a slow round-trip is never a dead button.
    @State private var isLookingUpPurpose = false
    @State private var errorKey: String?
    /// The medication whose photos are being managed (medication-visual-
    /// aids task, 2026-09-16) — held as the full entry so the sheet renders
    /// without a store read of its own.
    @State private var photoEditorEntry: MedicationEntry?

    var body: some View {
        LeafScreen(titleKey: "settings.meds.title") {
            VStack(spacing: 12) {
                if coordinator.medicationEntries.isEmpty {
                    Text("settings.meds.empty")
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
                } else {
                    ForEach(coordinator.medicationEntries) { entry in
                        medRow(entry)
                    }
                }
                addForm
                // This leaf edits the household's MEDICINES — nothing else
                // (calendar-split task, 2026-09-17). The native-calendar
                // mirror/two-way/import cards left for the Calendar settings
                // leaf on 2026-09-07, and the two calendar settings that
                // stayed behind — the appointment → iPhone Calendar write
                // gate and the festival advance-reminder days — followed
                // them there. Neither was a medication setting: one is the
                // EventKit write gate the Calendar leaf's mirror cards
                // belong to, the other a Bikram Sambat notification rule
                // that every other BS-calendar control already shares a
                // screen with.
            }
        }
        // A medicine's photos, edited by the family (medication-visual-aids
        // task, 2026-09-16) — the SAME editor the routine reminders use,
        // with the medication photo store instead of the routine one.
        // Edits persist as they happen, so dismissal only has to close the
        // sheet: this leaf reads `coordinator.medicationEntries` in its
        // body, so the row's glyph and the dose screens pick the change up
        // on the next draw (the dose screen snapshots at fire/tap time).
        .sheet(item: $photoEditorEntry) { entry in
            ReminderVisualAidEditorView(
                entryId: entry.id,
                title: entry.medicationName,
                aids: entry.visualAids,
                store: coordinator.medicationVisualAidStore,
                locale: coordinator.activeLocale,
                onSave: { aids in
                    coordinator.setMedicationVisualAids(entry.id, aids: aids)
                },
                onClose: { photoEditorEntry = nil }
            )
        }
    }

    private func medRow(_ entry: MedicationEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.medicationName)
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                // The printed strength ([MED-OCR], 2026-09-18) — read off
                // the label by the scan flow and stored in the dose line.
                // Shown on the row for the same reason the purpose is: a
                // household with two boxes of the same medicine at different
                // strengths must be able to tell them apart HERE, before
                // anyone is asked to take one.
                if !entry.doseDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.doseDescription)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
                Text(timesText(entry.scheduleTimes))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                // What the medicine is FOR ([MED-PURPOSE], 2026-09-17) —
                // the same label the photo caption and the voice rule use
                // (`MedicationPurpose.label(forStored:locale:)`), so the
                // family sees one name for a purpose everywhere. Absent
                // (or blank) draws no line at all: a household that files
                // no purposes sees exactly the row it saw before.
                if let purpose = MedicationPurpose.label(forStored: entry.purpose,
                                                         locale: coordinator.activeLocale) {
                    Text(purpose)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
            }
            Spacer()
            // Photos live behind this row, the same place routines put
            // them (medication-visual-aids task, 2026-09-16): this leaf is
            // where the family configures a medicine, and the photo is
            // part of the medicine, not of today's dose.
            Button {
                photoEditorEntry = entry
            } label: {
                Image(systemName: entry.visualAids.isEmpty ? "photo.badge.plus" : "photo.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.colors.accentForeground)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("visualAid.add"))
            Button(role: .destructive) {
                coordinator.removeMedication(id: entry.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.meds.delete"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var addForm: some View {
        VStack(spacing: 10) {
            scanLabelButton
            if let scanPhoto {
                scannedPhotoRow(scanPhoto)
            }
            TextField(LocalizedStringKey("settings.meds.name"), text: $draft.name)
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            // The printed strength ([MED-OCR], 2026-09-18) — read off the
            // label, editable like every other scan-filled field, and stored
            // in the entry's dose line.
            TextField(LocalizedStringKey("settings.meds.strengthPlaceholder"),
                      text: $draft.strength)
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)

            timeRows

            purposeStep

            if let errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .multilineTextAlignment(.center)
            }

            Button {
                errorKey = coordinator.addMedication(name: draft.storedName,
                                                     times: draft.storedTimes,
                                                     purpose: draft.storedPurpose,
                                                     strength: draft.storedStrength,
                                                     photo: scanPhoto)
                // Cleared only on success, like the name: a rejected save
                // must not throw away what the family chose — nor the photo
                // they took for it.
                if errorKey == nil {
                    draft = MedicationEditorDraft()
                    scanPhoto = nil
                }
            } label: {
                Text("settings.meds.save")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    // MARK: - Scan label ([MED-OCR], 2026-09-18)

    /// "Scan label" — the camera, then on-device OCR, then the form.
    ///
    /// What the scan may and may not do is the whole feature's contract, and
    /// it is enforced in `MedicationEditorDraft.applyScan` rather than here:
    /// blank fields are filled, the label's schedule replaces the form's,
    /// and NOTHING is saved. The family confirms on Save like every other
    /// medication — an OCR misread costs a correction, never a dose.
    private var scanLabelButton: some View {
        Button {
            scanLabel()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                Text("meds.scanLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
            }.foregroundStyle(appearance.colors.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize + 12)
            .background(appearance.colors.setupReminder)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
        .buttonStyle(.plain)
    }

    /// The photo the scan took, shown while the form is still being filled
    /// in: the family can see that the picture they just took is going to be
    /// the medicine's visual aid. It is attached on Save — see `save`.
    private func scannedPhotoRow(_ image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Text("meds.scan.photoAttached")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                scanPhoto = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("meds.scan.removePhoto"))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    private func scanLabel() {
        coordinator.scanMedicationLabel { result in
            switch result {
            case .scanned(let image, let candidate):
                // The shutter fired: the photo is kept for Save either way.
                scanPhoto = image
                // …and the reading is applied, which is a no-op for a
                // candidate that found nothing.
                if let candidate { draft.applyScan(candidate) }
            case .cancelled, .unavailable:
                // The scanner has already spoken the honest line (the
                // cancelled acknowledgement, or the camera guidance); the
                // form is left exactly as it was.
                break
            }
        }
    }

    /// One row per dose time ([MED-OCR], 2026-09-18): the editor used to
    /// hold exactly one time, which could not express a `1-0-1` label — or
    /// any medicine taken twice a day.
    private var timeRows: some View {
        VStack(spacing: 10) {
            ForEach(draft.times.indices, id: \.self) { index in
                // [AX-VIEWPORT] At accessibility text sizes the label,
                // the time picker and the remove button do not fit one
                // line on any phone width — the row overflowed its card.
                // The label takes its own line above the controls there;
                // standard sizes keep today's single-line row exactly.
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            timeLabel
                            HStack(spacing: 12) {
                                timePicker(at: index)
                                Spacer(minLength: 0)
                                removeTimeButton(at: index)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            timeLabel
                            Spacer()
                            timePicker(at: index)
                            removeTimeButton(at: index)
                        }
                    }
                }
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            Button {
                draft.addTime()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("meds.addTime")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                }.foregroundStyle(appearance.colors.accentForeground)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
        }
    }

    /// The "Time" label of a dose-time row — one implementation for both
    /// layout arms of `timeRows`.
    private var timeLabel: some View {
        Text("settings.meds.time")
            .font(.system(size: appearance.typography.bodyPointSize))
            .foregroundStyle(appearance.colors.textPrimary)
    }

    private func timePicker(at index: Int) -> some View {
        DatePicker("", selection: timeBinding(at: index),
                   displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.locale, coordinator.activeLocale)
    }

    /// The row's remove control. The last row cannot be removed: a
    /// medication with no dose time is not a schedule, and `addMedication`
    /// rejects one.
    @ViewBuilder
    private func removeTimeButton(at index: Int) -> some View {
        if draft.times.count > 1 {
            Button {
                draft.removeTime(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("meds.removeTime"))
        }
    }

    private func timeBinding(at index: Int) -> Binding<Date> {
        Binding(
            get: { draft.times.indices.contains(index) ? draft.times[index] : Date() },
            set: { newValue in
                guard draft.times.indices.contains(index) else { return }
                draft.times[index] = newValue
            }
        )
    }

    // The two calendar cards that used to close this leaf — the
    // appointment → iPhone Calendar write gate and the festival
    // advance-reminder days — live on `CalendarSettingsView` now
    // (calendar-split task, 2026-09-17). Their bodies were carried over
    // verbatim; `SettingsTabMappingTests` pins that they are the Calendar
    // leaf's, and that this one renders no calendar key.

    // MARK: - Purpose step ([MED-PURPOSE], 2026-09-17)

    /// "What is it for?": ten one-tap chips over a field that is ALWAYS
    /// editable. A chip fills the field with its own label (in the active
    /// language) and the field stays the family's to change — the typed
    /// words win, which is the whole reason the pair exists rather than a
    /// closed enum (`MedicationPurposeDraft` owns that rule; this view only
    /// wires taps and typing into it).
    ///
    /// Chips are laid out two per row rather than in a flow: the labels are
    /// Devanagari at the elder-facing body size, so a row that reflowed
    /// would shuffle the chips' positions between the two languages and
    /// between a phone's width and a tablet's. Fixed pairs keep the tenth
    /// chip where the family last found it.
    private var purposeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("meds.purpose.label")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                ForEach(Self.purposeChipRows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row) { chip in
                            purposeChip(chip)
                        }
                    }
                }
            }
            TextField(LocalizedStringKey("meds.purpose.freeTextPlaceholder"),
                      text: Binding(
                        get: { draft.purpose.text },
                        set: { draft.purpose.editText($0) }
                      ))
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            purposeLookupButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// "What is this medicine for?" ([MED-PURPOSE-LOOKUP], 2026-09-18) — the
    /// web lookup that fills the field above.
    ///
    /// Disabled until there is a NAME to ask about: a lookup for a blank
    /// medicine is a request with nothing in it, and the field it would fill
    /// is the one the family is still typing in. The result lands in the
    /// free-text field (never silently as a chip) and the family edits or
    /// clears it before Save — this is the same advisory rule the label scan
    /// follows.
    private var purposeLookupButton: some View {
        Button {
            lookupPurpose()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                Text(isLookingUpPurpose ? "meds.lookup.searching" : "meds.purpose.lookup")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
            }.foregroundStyle(canLookUpPurpose ? appearance.colors.accentForeground : appearance.colors.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .disabled(!canLookUpPurpose)
    }

    /// A name to ask about, and no lookup already running.
    private var canLookUpPurpose: Bool {
        !draft.storedName.isEmpty && !isLookingUpPurpose
    }

    private func lookupPurpose() {
        let name = draft.storedName
        guard !name.isEmpty else { return }
        isLookingUpPurpose = true
        coordinator.lookupMedicationPurpose(name: name) { outcome in
            isLookingUpPurpose = false
            // Only the FOUND text touches the form; every other outcome was
            // spoken by the coordinator, and a field the family is reading
            // is never quietly rewritten to say "nothing found".
            if case .found(let text) = outcome {
                draft.applyPurposeLookup(text)
            }
        }
    }

    /// `MedicationPurpose.allCases` in the design's order, two per row.
    private static let purposeChipRows: [[MedicationPurpose]] = {
        var rows: [[MedicationPurpose]] = []
        var current: [MedicationPurpose] = []
        for chip in MedicationPurpose.allCases {
            current.append(chip)
            if current.count == 2 {
                rows.append(current)
                current = []
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }()

    private func purposeChip(_ chip: MedicationPurpose) -> some View {
        let isSelected = draft.purpose.chip == chip
        return Button {
            draft.purpose.select(chip, locale: coordinator.activeLocale)
        } label: {
            Text(chip.label(locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                .foregroundStyle(isSelected ? .white : appearance.colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(isSelected ? appearance.colors.accent : appearance.colors.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed DIRECTLY — the service publishes download state changes;
    // reading through the coordinator never re-renders the rows.
    @EnvironmentObject var downloads: ModelDownloadService

    var body: some View {
        LeafScreen(titleKey: "settings.ai.title") {
            VStack(spacing: 20) {
                // [CATALOG-DECLUTTER 2026-09-12] STT and brain models are
                // two separate surfaces: one picker + one downloads list
                // each. They used to share a single picker card and one
                // mixed downloads card, which read as an undifferentiated
                // blob of "models" to a non-technical user.
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.stt.section")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    // Every curated STT engine is offered — cached AND
                    // not-yet-downloaded alike (a cached-only list hid
                    // everything but the user's 1–2 installed models).
                    // Picking an engine that isn't installed starts its
                    // download (see `sttSelection`); the rows below show
                    // per-row progress.
                    Picker("settings.ai.selection",
                           selection: sttSelection) {
                        Text("settings.ai.automatic").tag(Optional<ModelID>.none)
                        ForEach(ModelCatalog.availableSTTEntries, id: \.id) { entry in
                            // [MODEL-WARDEN] Step 3 — an engine this device
                            // class cannot run is shown and marked, not
                            // hidden (a stored preference must stay visible)
                            // and not selectable (the policy decides what
                            // may be chosen at all). See `unavailableNote`.
                            Text(Self.sttOptionLabel(
                                entry: entry,
                                downloaded: isInstalled(entry.id),
                                unavailable: !availability(of: entry).isAvailable,
                                locale: coordinator.activeLocale))
                                .tag(Optional(entry.id))
                                .disabled(!availability(of: entry).isAvailable)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(appearance.colors.accentForeground)
                    if !hasAnySTTInstalled {
                        Text("model.notDownloaded")
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                    modelRows(managedRows(ModelCatalog.availableSTTEntries,
                                          kind: .whisperBase))
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(appearance.colors.textSecondary)
                        Text(L10n.fmt("model.sttInUse", locale: coordinator.activeLocale,
                                     L10n.str(coordinator.activeSTTNameKey,
                                              locale: coordinator.activeLocale)))
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.brain.section")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    // Every curated brain artifact is offered — cached AND
                    // not-yet-downloaded alike (the STT picker's lesson:
                    // a cached-only list hides everything but 1–2 rows).
                    // Picking one that isn't installed starts its
                    // download (`brainModelPreference`'s didSet does
                    // that, same contract as the STT picker); the rows
                    // below show per-row progress.
                    Picker("settings.brain.selection",
                           selection: brainSelection) {
                        Text("settings.ai.automatic").tag(Optional<ModelID>.none)
                        ForEach(ModelCatalog.availableBrainEntries, id: \.id) { entry in
                            // [MODEL-WARDEN] Step 3 — see the STT picker
                            // above. On the 6 GB class this is the case the
                            // policy exists for: the curated list leads with
                            // the 4B, and only the 1.7B may be chosen.
                            Text(Self.sttOptionLabel(
                                entry: entry,
                                downloaded: isInstalled(entry.id),
                                unavailable: !availability(of: entry).isAvailable,
                                locale: coordinator.activeLocale))
                                .tag(Optional(entry.id))
                                .disabled(!availability(of: entry).isAvailable)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(appearance.colors.accentForeground)
                    // `candidates` is the brains-only pool: the translation
                    // artifacts are `.llamaBase` entries that are NOT in this
                    // picker, and every one of them belongs to the translation
                    // card below (offered there, or appended there as an
                    // installed leftover). Drawn from the whole kind, a device
                    // that installed one would get the installed-hidden
                    // management row here as well — the same artifact, two
                    // rows, two Delete buttons, on one screen.
                    modelRows(managedRows(ModelCatalog.availableBrainEntries,
                                          kind: .llamaBase,
                                          candidates: ModelCatalog.brainEntries))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

                translationCard

                // [ENCODER-RUNTIME-TOGGLE] The internal-testing encoder
                // switch. [ENCODER-ALWAYS-ON] The `if` is the compilation
                // condition, and the condition is part of this target's
                // default build settings (ios/project.yml) — so the card
                // renders in EVERY build, Debug and Release, on the hidden
                // internal screen. Compiling it in does not enable it: both
                // switches on the card default OFF, so a household device
                // still serves the brain picked above.
                if IntentEncoderFeature.isEnabled {
                    encoderCard
                }

                // [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier's
                // card, on the SAME hidden internal screen as the encoder
                // switches — the tier is not encoder-specific (it acts on
                // whatever the local slot answered), so it renders in
                // every build and is not gated on the encoder switch.
                // Nothing to enable for a household: the tier is inert on
                // its own wherever no cloud provider is configured.
                cloudCascadeCard

                // TTS / VAD / KWS management — deliberately left as it
                // was by the STT/brain split (the voice rows this screen
                // has always managed).
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.ai.downloads")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    modelRows(voiceManagedEntries)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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

    /// [TRANSLATION-MODEL-ROW] (2026-09-18) The live-translate tier's own
    /// model — the one row on this screen that exists to make a DOWNLOAD
    /// possible rather than to make a choice possible.
    ///
    /// Why it is here at all: `LocalBrainTranslationTier.installedModel()`
    /// reads what is on disk, and nothing else in the app starts this
    /// artifact's download (the tier only reads installed models, the
    /// assistant-brain picker deliberately excludes it, and `managedRows`
    /// only appends entries that are ALREADY installed). Without this row
    /// the shipped translation fine-tune could be catalogued, published and
    /// sha-pinned and still never reach a device. The row is offered through
    /// `ModelCatalog.availableTranslationEntries` — the catalog's own list
    /// for exactly this surface, not a view-local literal.
    ///
    /// Two deliberate differences from every other row on the screen:
    ///
    ///  · **The Download outlives the refusal.** `downloadsWhileUnavailable`
    ///    keeps the button while the class policy refuses the model, where
    ///    every other row hides it (a household choosing a brain should not
    ///    spend data on one this phone cannot hold — that reasoning stands).
    ///    This row is not a choice: it is how the artifact gets onto a phone
    ///    that CAN run it, and how a phone that cannot becomes able to when
    ///    a later policy moves the line. The verdict is still shown, in the
    ///    same sentence the picker uses (`unavailableNote`), because a row
    ///    that only said "Download" would be claiming the model works here.
    ///
    ///  · **It names the size.** A gigabyte over a household's connection is
    ///    a decision worth pricing before the tap, and the status line only
    ///    shows bytes once a download is already in flight.
    ///
    /// The section header and the note carry the two facts a household
    /// cannot infer from the row: this model answers the camera's
    /// translation, not the assistant, and a phone may hold it without being
    /// able to run it.
    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.translation.section")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            Text("settings.translation.note")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The offered row, plus any translation artifact this device is
            // actually carrying: an alternate quant that was sideloaded, or
            // the superseded round-2b export from before the ship quant. The
            // catalog answers "which artifacts are translation artifacts"
            // (`allTranslationEntries`), so an installed one can never surface
            // on the brain card instead — and the owner can still free its
            // 1.1 GB from the card that owns it.
            modelRows(managedRows(ModelCatalog.availableTranslationEntries,
                                  kind: .llamaBase,
                                  candidates: ModelCatalog.allTranslationEntries),
                      downloadsWhileUnavailable: true,
                      showsArtifactSize: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// Picker selection: sets the persisted preference (existing
    /// `sttModelPreference` flow), records the pick as the household's own
    /// for the current app language (`ModelPreferenceMemory` — the same
    /// seam `ResponseVoiceSelection.remember` provides for the reply
    /// voice), AND — when the chosen engine is not installed yet — starts
    /// its download through the existing `ModelDownloadService` so a fresh
    /// pick works immediately. Rows below surface progress; once the
    /// install completes the picker label sheds its "not downloaded"
    /// suffix and the recognizer resolves the preference (it loads
    /// whatever model is cached).
    ///
    /// This is the ONLY writer of that memory: the automatic app-language
    /// switch reads it (so an en→ne→en round trip returns here) and must
    /// never write it. The "Automatic" row (nil) is not a memory either —
    /// `rememberSTT` takes a real id, and nil leaves whatever was
    /// remembered for the language in place.
    private var sttSelection: Binding<ModelID?> {
        Binding(
            get: { coordinator.sttModelPreference },
            set: { newValue in
                coordinator.sttModelPreference = newValue
                if let newValue {
                    ModelPreferenceMemory.rememberSTT(
                        newValue, for: coordinator.appLanguage.rawValue)
                    startDownloadIfNeeded(newValue)
                }
            }
        )
    }

    /// Brain picker selection: writes `brainModelPreference`. The
    /// coordinator's didSet already starts the chosen model's download
    /// when it isn't cached (the same fresh-pick contract as the STT
    /// picker), so this binding stays a thin passthrough — no second
    /// download kick here. It DOES record the pick per app language
    /// (`ModelPreferenceMemory.rememberBrain`), the STT binding's contract
    /// exactly: the language switch restores the household's own brain
    /// instead of flattening it to the per-language default.
    private var brainSelection: Binding<ModelID?> {
        Binding(
            get: { coordinator.brainModelPreference },
            set: { newValue in
                coordinator.brainModelPreference = newValue
                if let newValue {
                    ModelPreferenceMemory.rememberBrain(
                        newValue, for: coordinator.appLanguage.rawValue)
                }
            }
        )
    }

    /// [ENCODER-RUNTIME-TOGGLE] The internal-testing switch for the
    /// on-device intent encoder (an internal artifact whose published run
    /// does not meet every harness gate — see the catalog entry).
    ///
    /// OFF (the default) is the shipped behaviour: the brain picker above
    /// serves. ON lets the encoder take the local slot the moment its
    /// artifact is installed — and flipping it acts on the NEXT TURN, not
    /// the next launch, so an A/B pass over the same utterances costs one
    /// switch, not two installs. [ENCODER-ALWAYS-ON] The card renders in
    /// every build (the compile condition is in this target's default
    /// build settings) and sits on the hidden internal screen, so a
    /// household user never meets this switch or its vocabulary — and the
    /// switches themselves default OFF, so nothing serves the encoder
    /// until a tester opts in.
    ///
    /// The artifact itself needs no environment variable either: the
    /// tester stages `t033-encoder-int8-mlmodelc.zip` in the app's
    /// `Documents/` directory (`INTENT_ENCODER_SPIKE_ZIP` only overrides
    /// that path), and switching the encoder ON is what starts the
    /// install.
    ///
    /// [ENCODER-RUNTIME-CASCADE] The second switch on the card is the A/B's
    /// third leg: OFF the encoder answers alone; ON the brain picked above
    /// answers the same turn whenever the encoder abstains or is unsure.
    ///
    /// [CORRECTION-TOGGLES] The card then carries the two switches for the
    /// pre-intent layers the local brain's input passes through — the
    /// STT-error corrector and the dialect canonicalizer — so a tester can run
    /// each of them in isolation and in combination without a debugger, a
    /// relaunch or a second install. Both persist through `AppCoordinator`'s
    /// `intentCorrectorEnabled` / `intentCanonicalizerEnabled`.
    ///
    /// [CORRECTION-ANYBRAIN] Unlike the cascade row above, neither is disabled
    /// while the encoder switch is off: the layers act at the LOCAL SLOT's
    /// input (`LocalBrainChain.InputSeam`), so with the encoder out of the slot
    /// they correct and canonicalize what the brain picked above reads — which
    /// is exactly the corrector-only / canonicalizer-only A/B against the
    /// picker brain this card exists to make possible. The card's existing
    /// "Last correction" line is the corrector's readout and renders when the
    /// corrector participated in the last turn the ENCODER ran (the readout is
    /// encoder telemetry; a picker-brain turn reports the layer's effect, not
    /// its readout).
    private var encoderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.encoder.title")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            Toggle(isOn: Binding(
                get: { coordinator.intentEncoderEnabled },
                set: { coordinator.intentEncoderEnabled = $0 }
            )) {
                Text("settings.encoder.toggleLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("settings.encoder.note")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // [ENCODER-RUNTIME-CASCADE] The A/B's third leg: encoder first,
            // the picked brain answering the same turn when the encoder is
            // unsure. Disabled (not hidden) while the encoder is off —
            // the mode collapses to the picker brain there, so the row
            // would do nothing, and the disabled state says so honestly.
            Toggle(isOn: Binding(
                get: { coordinator.intentEncoderCascadeEnabled },
                set: { coordinator.intentEncoderCascadeEnabled = $0 }
            )) {
                Text("settings.encoder.cascadeLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .disabled(!coordinator.intentEncoderEnabled)
            Text("settings.encoder.cascadeNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // [CORRECTION-TOGGLES] The two pre-intent layers, on the SAME
            // card so all four switches are together and the four-way matrix
            // (corrector only / canonicalizer only / both / neither) is a
            // matter of flipping two rows. They answer the two questions the
            // layers themselves are asked, in the order they run:
            // `sanitise → correct → canonicalize → tokenize`.
            //
            // [CORRECTION-ANYBRAIN] Unlike the cascade row above, neither is
            // disabled while the encoder switch is off — and that difference
            // is the point of these two rows, not an oversight. The layers act
            // at the LOCAL SLOT's input (`LocalBrainChain.InputSeam`), which
            // is the boundary in front of whichever local brain answers, so
            // with the encoder out of the slot they correct and canonicalize
            // what the PICKER brain reads. That is what makes the corrector
            // testable alone against the 1.7B, which no encoder-gated row
            // could ever express. The RUNTIME gates are the layers' own
            // (`STTCorrector.Policy.runtime`,
            // `DialectCanonicalizer.Policy.runtime`); neither row can conjure
            // the encoder into the slot, and neither needs to.
            // [CORRECTION-DEFAULT-ON] The get reads the EFFECTIVE state, so
            // the card shows the layer ON on a never-touched device (the
            // shipped apply default); flipping it off writes the pin.
            Toggle(isOn: Binding(
                get: { coordinator.isCorrectionEnabledEffective },
                set: { coordinator.intentCorrectorEnabled = $0 }
            )) {
                Text("settings.encoder.correctorLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            // [CORRECTION-ANYBRAIN] Deliberately NOT
            // `.disabled(!coordinator.intentEncoderEnabled)`: the layer acts
            // at the slot's input, so it works with the picker brain too.
            Text("settings.encoder.correctorNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { coordinator.intentCanonicalizerEnabled },
                set: { coordinator.intentCanonicalizerEnabled = $0 }
            )) {
                Text("settings.encoder.canonicalizerLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            // [CORRECTION-ANYBRAIN] Same as the corrector row above: usable
            // with the encoder off, because it acts at the slot's input.
            Text("settings.encoder.canonicalizerNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: encoderArtifactInstalled
                      ? "checkmark.seal.fill"
                      : "tray.and.arrow.down")
                    .foregroundStyle(appearance.colors.textSecondary)
                Text(L10n.fmt("settings.encoder.artifact",
                              locale: coordinator.appLanguage.locale,
                              L10n.str(encoderArtifactInstalled ? "model.ready"
                                                                : "model.notDownloaded",
                                       locale: coordinator.appLanguage.locale)))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            // [TURN-TIMING-BREAKDOWN] The last completed turn's stage
            // breakdown: one row per stage the turn actually spent time
            // in, name + milliseconds. The breakdown is the coordinator's
            // in-memory last-turn value (never persisted, never logged) —
            // empty until a turn with instrumentation active finalizes.
            //
            // The stage names are DIAGNOSTIC TOKENS (the same vocabulary
            // the observability event carries) and stay unlocalized like
            // the transcript caption's "asr/llm/tts" labels: the card is
            // an internal-testing surface whose vocabulary must match the
            // device logs it is read against.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.encoder.lastTurn")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                if let timing = coordinator.lastTurnTimingBreakdown, !timing.isEmpty {
                    ForEach(timing.readout) { row in
                        HStack(spacing: 8) {
                            Text(row.label)
                            Spacer(minLength: 8)
                            Text(row.value)
                        }
                        .font(.system(size: appearance.typography.captionPointSize,
                                      design: .monospaced))
                        .foregroundStyle(appearance.colors.textSecondary)
                    }
                } else {
                    Text("settings.encoder.lastTurn.empty")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // [TG-12] The last turn's correction decision, mirroring "Last
            // turn" above: the same label/value rows, the same in-memory
            // last-turn value (never persisted, never logged), the same
            // monospaced diagnostic vocabulary — the row labels ("corrected",
            // "conf", "class") are tokens the device log is read against, so
            // they stay unlocalized like the stage names.
            //
            // This line MAY NAME THE WORDS the corrector rewrote: it is the
            // on-device debugger's view, and a debugger that cannot see the
            // pair cannot tell a wrong correction from a missing one. The
            // `turn_correction` EVENT never carries them — it is count-only
            // and binned by construction.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.encoder.lastCorrection")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                if let correction = coordinator.lastCorrectionReadout,
                   !correction.isEmpty {
                    ForEach(correction.rows) { row in
                        HStack(spacing: 8) {
                            Text(row.label)
                            Spacer(minLength: 8)
                            Text(row.value)
                        }
                        .font(.system(size: appearance.typography.captionPointSize,
                                      design: .monospaced))
                        .foregroundStyle(appearance.colors.textSecondary)
                    }
                } else {
                    Text("settings.encoder.lastCorrection.empty")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // [PIPELINE-TRACE] The full pipeline trace, one row per gate in
            // the order the gates run: STT, corrector, canonicalizer, the
            // encoder's three stages, the band policy, the cascade, the
            // picker brain's prompt and its FINAL LLM round-trip, and the
            // TTS start. Each row carries what went in, what came out, the
            // decision taken and the milliseconds — so a wrong correction
            // can be told from a missing one, an abstention from a
            // timeout, and a 7-second reply from a 900 ms one.
            //
            // LIKE "Last correction", THIS SECTION MAY NAME WORDS: it is
            // the on-device debugger's view (internal-testing screen), the
            // value is the coordinator's in-memory LAST-TURN trace (never
            // persisted, never written to the encrypted stores), and the
            // observability events beside it stay count-only — they carry
            // stage tokens and milliseconds, never a summary.
            //
            // The stage labels and decision tokens are the DIAGNOSTIC
            // vocabulary of the device log, so they stay unlocalized like
            // "Last turn"'s stage names and the correction line's labels.
            // The section is scrollable because eleven stages do not fit
            // on one screen at this type size; the rest of Settings keeps
            // its own scroll.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.encoder.pipelineTrace")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                if let trace = coordinator.lastPipelineTrace, !trace.isEmpty {
                    Text(L10n.fmt("settings.encoder.pipelineTrace.count",
                                  locale: coordinator.appLanguage.locale,
                                  trace.ranCount, trace.rows.count))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(trace.rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(row.stage.rawValue)
                                        Spacer(minLength: 8)
                                        Text(row.durationText)
                                        Text(row.decisionText)
                                    }
                                    Text("\(row.inputSummary) → \(row.outputSummary)")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: appearance.typography.captionPointSize,
                                              design: .monospaced))
                                .foregroundStyle(appearance.colors.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("settings.encoder.pipelineTrace.empty")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier's card, on the
    /// hidden internal-testing screen beside the encoder switches.
    ///
    /// Two rows, one writer each:
    ///  · the SWITCH — `AppCoordinator.cloudCascadeEnabled` (**default
    ///    ON**: the tier's rule is the requested behaviour, and it stays
    ///    inert by itself wherever no cloud provider is configured);
    ///  · the THRESHOLD — `AppCoordinator.cloudCascadeThreshold`, **default
    ///    97 %**, stepped in whole percent. Two big tap targets rather
    ///    than a slider, the volume control's pattern: a drag is the wrong
    ///    gesture here, and every step is a discrete, readable number.
    ///
    /// The copy carries the gates so the card can never promise more than
    /// the chain does: the tier is inert while no cloud provider is
    /// configured (a household that never added a key never meets it), the
    /// keyword safety net still runs before any brain, and a spoken hold
    /// cue — not a silent wait — precedes the cloud call.
    private var cloudCascadeCard: some View {
        let percent = CloudCascadeSettings.percent(coordinator.cloudCascadeThreshold)
        let minimumPercent = CloudCascadeSettings.percent(CloudCascadeSettings.minimumThreshold)
        let maximumPercent = CloudCascadeSettings.percent(CloudCascadeSettings.maximumThreshold)
        return VStack(alignment: .leading, spacing: 12) {
            Text("settings.cloudCascade.title")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            Toggle(isOn: Binding(
                get: { coordinator.cloudCascadeEnabled },
                set: { coordinator.cloudCascadeEnabled = $0 }
            )) {
                Text("settings.cloudCascade.toggleLabel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .tint(appearance.colors.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("settings.cloudCascade.toggleNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                cascadeThresholdStepButton(steps: -1, systemImage: "minus",
                                           labelKey: "settings.cloudCascade.decrease",
                                           enabled: percent > minimumPercent)
                Spacer(minLength: 8)
                Text(verbatim: "\(percent)%")
                    .font(.system(size: appearance.typography.titlePointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: 128)
                    .accessibilityLabel(Text("settings.cloudCascade.thresholdLabel"))
                    .accessibilityValue(Text(verbatim: "\(percent)%"))
                Spacer(minLength: 8)
                cascadeThresholdStepButton(steps: +1, systemImage: "plus",
                                           labelKey: "settings.cloudCascade.increase",
                                           enabled: percent < maximumPercent)
            }

            Text("settings.cloudCascade.thresholdNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// One threshold step button; disabled at the ends of the range (no
    /// dead press, and the dimmed state shows where the range ends). The
    /// write goes through the coordinator, whose didSet persists the
    /// clamped value AND re-resolves the router's tier — so a step acts on
    /// the next turn, not the next launch.
    private func cascadeThresholdStepButton(steps: Int, systemImage: String,
                                            labelKey: LocalizedStringKey,
                                            enabled: Bool) -> some View {
        Button {
            let next = CloudCascadeSettings.stepped(coordinator.cloudCascadeThreshold,
                                                    bySteps: steps)
            guard next != coordinator.cloudCascadeThreshold else { return }
            coordinator.cloudCascadeThreshold = next
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(enabled ? appearance.colors.textPrimary
                                         : appearance.colors.textSecondary)
                .frame(minWidth: DesignTokens.minTapTargetSize + 24,
                       minHeight: DesignTokens.minTapTargetSize + 24)
                .appSurface(role: .control, cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(labelKey))
    }

    /// The encoder artifact's install state, resolved through the same
    /// `isInstalled` seam the model rows use (live download state first,
    /// then what is on disk).
    private var encoderArtifactInstalled: Bool {
        isInstalled(ModelCatalog.intentEncoderSpike)
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

    /// Download/management rows for one section: the curated entries the
    /// picker offers, plus any hidden entry of the same kind that is
    /// actually installed on THIS device.
    ///
    /// The declutter rule (2026-09-12) is "not offered, but still
    /// deletable": a superseded / legacy model left the curated lists —
    /// it must never read as a choice — yet a device that already cached
    /// one has to keep a row for it, otherwise the owner can never free
    /// the space. Catalog entries are never removed, so the install check
    /// is the only gate here.
    ///
    /// `candidates` is the pool the append draws from, defaulting to the
    /// whole of `kind`. A section whose card is one *family* of artifacts
    /// passes its own pool so a sibling family cannot land here:
    /// [TRANSLATION-MODEL-ROW] the brain card passes the brains-only pool
    /// (`ModelCatalog.brainEntries`), because the translation artifacts are
    /// `.llamaBase` entries it never offers and the translation card gives
    /// each of them a row — offered, or appended as an installed leftover.
    /// Drawn from the whole kind, an installed translation model would get a
    /// management row on both cards, and one artifact with two rows can be
    /// deleted from one while the other still shows it installed.
    private func managedRows(_ curated: [ModelCatalogEntry],
                             kind: ModelKind,
                             candidates: [ModelCatalogEntry]? = nil) -> [ModelCatalogEntry] {
        let offered = Set(curated.map(\.id))
        let pool = candidates ?? ModelCatalog.entries(kind: kind)
        let installedHidden = pool.filter { !offered.contains($0.id) && isInstalled($0.id) }
        return curated + installedHidden
    }

    /// The non-model assets this screen has always managed (TTS / VAD /
    /// KWS rows) — untouched by the STT/brain split. STT and brain rows
    /// now live in their own sections above, so they are filtered out
    /// here (resolved to entries up front, since a row needs the model).
    private var voiceManagedEntries: [ModelCatalogEntry] {
        coordinator.requiredModelIds.compactMap { id in
            guard let entry = ModelCatalog.entry(for: id) else { return nil }
            guard entry.kind != .whisperBase, entry.kind != .llamaBase else {
                return nil
            }
            return entry
        }
    }

    /// One management row per entry, with the download/delete actions the
    /// screen has always wired (deleting the model the picker currently
    /// points at falls back to the automatic default).
    ///
    /// `downloadsWhileUnavailable` is the [TRANSLATION-MODEL-ROW] exception
    /// (see `translationCard`); `showsArtifactSize` names the artifact's
    /// size under the row title. Both default to the screen's existing
    /// behaviour, so the picker's own lists are unchanged by either.
    @ViewBuilder
    private func modelRows(_ entries: [ModelCatalogEntry],
                           downloadsWhileUnavailable: Bool = false,
                           showsArtifactSize: Bool = false) -> some View {
        ForEach(entries, id: \.id) { entry in
            ModelManagementRow(
                entry: entry,
                state: downloadState(for: entry.id),
                // [MODEL-WARDEN] Step 3 — the class policy's answer for this
                // row. Read from the ledger, which derives the class from the
                // same probe it admits against (`ModelLifecycleManager
                // .availability(of:)`), never from `ProcessInfo` here: a view
                // that guessed the device would disagree with the ledger on
                // exactly the phones where the answer matters.
                unavailableReason: availability(of: entry).reason,
                downloadsWhileUnavailable: downloadsWhileUnavailable,
                showsArtifactSize: showsArtifactSize,
                onStart: { downloads.start(entry.id) },
                onCancel: { downloads.cancel(entry.id) },
                onDelete: {
                    try? coordinator.modelStore.delete(entry.id)
                    downloads.reset(entry.id)
                    if coordinator.sttModelPreference == entry.id {
                        coordinator.sttModelPreference = nil
                    }
                    // Deleting the brain the picker is currently
                    // set to falls back to the default (same
                    // truthfulness rule as the STT handling above).
                    if coordinator.brainModelPreference == entry.id {
                        coordinator.brainModelPreference = nil
                    }
                }
            )
            Divider()
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

    /// Row state for the downloads list. The rule itself is shared with the
    /// translate-test screen (`ModelDownloadState.rowState`); see there for
    /// why it is derived rather than read from one source.
    private func downloadState(for id: ModelID) -> ModelDownloadState {
        .rowState(for: id, states: downloads.states, modelStore: coordinator.modelStore)
    }

    /// Picker row text: the localized model name, plus an honest
    /// "not downloaded yet" note whenever the artifact isn't installed.
    /// Pure (the view computes `downloaded` from store + service state)
    /// so tests can pin both label states.
    ///
    /// [MODEL-WARDEN] Step 3 adds one more honest state: `unavailable`
    /// (the device class cannot run this model — see `unavailableNote`).
    /// It takes precedence over the download note, because downloading a
    /// model this phone cannot hold is not a fix for anything: the row
    /// would gain a progress bar and end up in exactly the state the
    /// picker is telling the household to avoid. One suffix at a time
    /// keeps the menu readable at `minCaptionPointSize`.
    static func sttOptionLabel(entry: ModelCatalogEntry,
                               downloaded: Bool,
                               unavailable: Bool = false,
                               locale: Locale) -> String {
        let name = entry.displayName(locale: locale)
        if unavailable {
            return "\(name) — \(L10n.str("model.unavailable.marker", locale: locale))"
        }
        guard !downloaded else { return name }
        return "\(name) — \(L10n.str("model.notDownloaded", locale: locale))"
    }

    // MARK: - [MODEL-WARDEN] Step 3 — the class policy at the point of choice

    /// Whether this device may be offered `entry` at all.
    ///
    /// Asked of the ledger (`ModelLifecycleManager.shared`) rather than
    /// computed here. The ledger owns the device class because it owns the
    /// probe the admissions are made against; a second derivation in the view
    /// is a second answer, and the two would differ on precisely the phones
    /// the policy is about. The lock is uncontended and the arithmetic is a
    /// handful of comparisons per row.
    private func availability(of entry: ModelCatalogEntry) -> ModelAvailability {
        ModelLifecycleManager.shared.availability(of: entry)
    }

    /// The sentence a row shows when the class refuses the model.
    ///
    /// Pure, so a test can pin both halves of the wiring: that the reason
    /// reaches the row, and that the sentence stays content-free (it names a
    /// memory fact about the phone — never an artifact, a size or an id).
    /// Falls back to the policy's English copy rather than to the key when a
    /// language has no row in the string table: a household must never read
    /// `model.unavailable.overClassBudget` on a Settings screen.
    static func unavailableNote(_ reason: ModelUnavailabilityReason,
                                locale: Locale) -> String {
        let resolved = L10n.str(reason.localizationKey, locale: locale)
        return resolved == reason.localizationKey
            ? ModelBudgetPolicy.displayText(for: reason)
            : resolved
    }

    /// Whether a row's primary action is its Download button — the one place
    /// the [MODEL-WARDEN] refusal and the [TRANSLATION-MODEL-ROW] exception
    /// meet, so the rule and its single carve-out cannot drift apart.
    ///
    /// The rule: a refused model is not downloaded, because an artifact this
    /// phone cannot hold is not something to spend a household's data on.
    /// The exception: a row whose artifact must be on disk for a feature to
    /// work when the phone CAN run it (`downloadsWhileUnavailable`) keeps
    /// the button, and says the refusal in words instead.
    ///
    /// An in-flight download is never re-offered as a fresh one, refused or
    /// not — the row shows Cancel while it runs, and Delete once it lands.
    /// Pure, so a test can drive every combination without a view.
    static func offersDownloadButton(state: ModelDownloadState,
                                     unavailableReason: ModelUnavailabilityReason?,
                                     downloadsWhileUnavailable: Bool) -> Bool {
        guard unavailableReason == nil || downloadsWhileUnavailable else {
            return false
        }
        switch state {
        case .notStarted, .failed, .cancelled: return true
        case .queued, .downloading, .verifying, .completed: return false
        }
    }
}

extension ModelDownloadState {
    /// The row state for one model id, from the two things that know: the
    /// download service's live state wins; otherwise it is derived from what
    /// is on disk, so a model installed before the screen opened reads as
    /// Ready rather than Download.
    ///
    /// Shared by the AI-models screen and the translate-test screen, which
    /// offers the same translation artifact: two copies of this rule would be
    /// two places to disagree about a model that is complete on disk while no
    /// download is running.
    static func rowState(for id: ModelID,
                         states: [ModelID: ModelDownloadState],
                         modelStore: ModelStore) -> ModelDownloadState {
        if let state = states[id] { return state }
        guard let entry = ModelCatalog.entry(for: id) else { return .notStarted }
        return modelStore.isInstalled(entry) ? .completed : .notStarted
    }
}

/// One model's download/delete row.
///
/// `internal` rather than `fileprivate` since the translate-test screen
/// (2026-09-21): that screen offers the SAME translation artifact — and
/// only the artifact, never a picker — so it draws the same row. A second
/// download UI would be a second place for the size, the live state and
/// the device-class verdict to disagree with this one.
struct ModelManagementRow: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.locale) private var locale
    let entry: ModelCatalogEntry
    let state: ModelDownloadState
    /// [MODEL-WARDEN] Step 3 — non-nil when this device class cannot run the
    /// model. Shown, not hidden: the row names the fact, keeps the artifact
    /// deletable (the declutter rule: "not offered, but still deletable") and
    /// stops offering the download, because an artifact this phone cannot
    /// hold is not something to spend a household's data on.
    var unavailableReason: ModelUnavailabilityReason? = nil
    /// [TRANSLATION-MODEL-ROW] The one carve-out from the rule above: keep
    /// the Download while `unavailableReason` is set. For a row whose
    /// artifact a FEATURE reads off disk (the translation tier's model), the
    /// download is not the household choosing a model this phone cannot run
    /// — it is how the artifact is present for the phones that can, and for
    /// this phone once a policy moves the line. The reason line still
    /// renders: the row never claims the model works here.
    var downloadsWhileUnavailable: Bool = false
    /// Show the artifact's size under the row title. Off by default (the
    /// picker rows are choices, and their bytes only matter once a download
    /// starts — the status line carries them then); on for the translation
    /// row, where a 1.83 GB fetch is the decision being made.
    var showsArtifactSize: Bool = false
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.displayName(locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(unavailableReason == nil
                                     ? appearance.colors.textPrimary
                                     : appearance.colors.textSecondary)
                Spacer()
                actionButton
                if case .completed = state {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 20)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("model.delete"))
                }
            }
            if showsArtifactSize {
                Text(L10n.fmt("model.size", locale: locale, bytes(entry.sizeBytes)))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            statusLine
            if let reason = unavailableReason {
                unavailableLine(reason)
            }
        }
        .padding(.vertical, 6)
    }

    /// The reason this class refuses the model — one sentence, resolved
    /// through `AIModelsSettingsView.unavailableNote` (pure + pinned by
    /// tests). Dimmed like every other status line; deliberately NOT
    /// `stateError`, because the model is not broken and the household's
    /// phone is not in a failed state — it is a fact about this device.
    private func unavailableLine(_ reason: ModelUnavailabilityReason) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(appearance.colors.textSecondary)
            Text(AIModelsSettingsView.unavailableNote(reason, locale: locale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notStarted, .failed, .cancelled:
            if AIModelsSettingsView.offersDownloadButton(
                state: state,
                unavailableReason: unavailableReason,
                downloadsWhileUnavailable: downloadsWhileUnavailable) {
                Button(action: onStart) {
                    Text("model.download")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
                }
                .buttonStyle(.plain)
            }
            // else: nothing to offer. `unavailableLine` says why, and the
            // picker option for this model is disabled for the same reason.
            // (The [TRANSLATION-MODEL-ROW] carve-out is inside the helper
            // above, not here: the verdict and its one exception are one
            // rule, and a test drives it without a view.)
        case .queued, .downloading, .verifying:
            Button(action: onCancel) {
                Text("model.cancel")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                            .stroke(appearance.colors.textSecondary, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
        case .completed:
            Label("model.active", systemImage: "bolt.fill")
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .notStarted:
            Text("model.notDownloaded")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        case .queued:
            Text("model.queued")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        case .downloading(let received, let total):
            let ratio = total > 0 ? Double(received) / Double(total) : 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: ratio)
                    .tint(appearance.colors.accentForeground)
                Text("\(bytes(received)) / \(bytes(total))")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        case .verifying:
            Text("model.verifying")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
        case .completed:
            Text("model.ready")
                .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.colors.accentForeground)
        case .failed(let reason):
            Text(L10n.fmt("model.failed", locale: locale, reason))
                .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
        case .cancelled:
            Text("model.cancelled")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
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
    @Environment(\.appAppearance) private var appearance
    @Environment(\.locale) private var locale

    var body: some View {
        LeafScreen(titleKey: "settings.privacy.title") {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44)).foregroundStyle(appearance.colors.accentForeground)
                Text("settings.privacy.body")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(L10n.fmt("settings.about.version", locale: locale, version))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
            }
            .padding(20)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
        }
    }
}

// MARK: - TTS voices (on-device Piper VITS)

/// Per-voice install status for the on-device TTS voices
/// (docs/tts-implementation-plan.md). Exists because the 2026-09-06 field
/// failure was invisible: a build without the bundled voice files fell
/// back to silence for Nepali and nobody could tell why.
struct TTSVoicesSettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// Voice being applied — awaits the confirmation dialog, never the
    /// live voice (research §6: confirm-before-apply, previews must not
    /// switch the live voice).
    @State private var applyCandidate: ResponseVoice?
    /// The voice confirmed on THIS screen visit (so the checkmark moves
    /// immediately); the persisted store is the source of truth.
    @State private var justApplied: ResponseVoice?
    /// A voice whose install-from-bundle failed at apply time.
    @State private var installFailure: ModelID?

    /// [VOLUME-BOOST] The spoken-reply output volume this screen edits:
    /// the persisted percentage, loaded on appear and saved on every step
    /// (`VoiceOutputVolume` owns the key + clamping). The SPEAKER reads
    /// the same key at playback time, so a change applies from the next
    /// reply — no restart, no re-synthesis.
    @State private var volumePercent: Int = VoiceOutputVolume.defaultPercent

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

    /// The sample sentence every Listen/apply-proof speaks. ALWAYS the
    /// Nepali sentence — the voices being auditioned are Nepali voices —
    /// and the same Devanagari sentence is shown on screen next to it
    /// (research §6: never audio-only).
    private var sampleText: String {
        L10n.str("settings.voices.sampleGreeting", locale: Locale(identifier: "ne-NP"))
    }

    /// Current effective voice: the persisted choice, or the locale
    /// default (google-medium speaker 0) before any pick.
    private var currentVoice: ResponseVoice {
        justApplied ?? ResponseVoiceSelection.persisted()
            ?? ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0)
    }

    /// Pickable options in display order: google's default speaker (the
    /// voice the app shipped with), the new chitwan voice, then google's
    /// other verified speakers 1-17 under their own header (same voice
    /// directory, zero download — verified present in the int8 export,
    /// see ResponseVoiceSelection; each is previewable before use).
    private var pickerOptions: [ResponseVoice] {
        [ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0),
         ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)]
    }

    private var alternateGoogleSpeakers: [ResponseVoice] {
        ResponseVoice.speakerIDs(for: ModelCatalog.piperNepali).dropFirst().map {
            ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: $0)
        }
    }

    var body: some View {
        ZStack {
            VoiceBridgeBackground(theme: coordinator.appTheme)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .card, cornerRadius: 999)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.back"))
                    Spacer(minLength: 8)
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Text("settings.voices.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 12) {
                        // Picker intro + the sentence every preview speaks,
                        // shown in the same script (research §6).
                        Text("settings.voices.chooseTitle")
                            .font(.system(size: appearance.typography.bodyPointSize,
                                          weight: .semibold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        VStack(spacing: 6) {
                            Text("settings.voices.sampleNote")
                                .font(.system(size: appearance.typography.captionPointSize,
                                              weight: .semibold))
                                .foregroundStyle(appearance.colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sampleText)
                                .font(.system(size: appearance.typography.bodyPointSize))
                                .foregroundStyle(appearance.colors.textPrimary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(14)
                        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

                        ForEach(pickerOptions) { voice in
                            voiceOptionCard(voice)
                        }

                        // Google-medium's other verified speakers (1-17).
                        if status(of: ModelCatalog.piperNepali) != .missing
                            && !alternateGoogleSpeakers.isEmpty {
                            VStack(spacing: 4) {
                                Text("settings.voices.moreGoogleSpeakers")
                                    .font(.system(size: appearance.typography.bodyPointSize,
                                                  weight: .semibold))
                                    .foregroundStyle(appearance.colors.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("settings.voices.speakerNote")
                                    .font(.system(size: appearance.typography.captionPointSize))
                                    .foregroundStyle(appearance.colors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                            ForEach(alternateGoogleSpeakers) { voice in
                                voiceOptionCard(voice)
                            }
                        }

                        // The English reply voice stays a status-only row —
                        // voice personalisation P0 covers Nepali voices.
                        voiceRow(ModelCatalog.entry(for: ModelCatalog.piperEnglishUS)!)

                        volumeCard

                        Button {
                            coordinator.speak(text: L10n.str("settings.voices.sampleGreeting",
                                                             locale: coordinator.activeLocale))
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                                    .frame(width: 40)
                                Text("settings.voices.testButton")
                                    .font(.system(size: appearance.typography.bodyPointSize,
                                                  weight: .semibold))
                                    .foregroundStyle(appearance.colors.textPrimary)
                                Spacer()
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity).appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
                        }
                        .buttonStyle(.plain)

                        if let voiceID = installFailure,
                           let entry = ModelCatalog.entry(for: voiceID) {
                            Text(L10n.fmt("settings.voices.installFailed", locale: locale,
                                          entry.displayName))
                                .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        if ModelCatalog.entries(kind: .tts).contains(where: {
                            Self.status(for: $0, modelStore: coordinator.modelStore) == .missing
                        }) {
                            Text("settings.voices.missingHint")
                                .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // [VOLUME-BOOST] The persisted value is the source of truth
            // (clamped on read — an out-of-range stored value shows the
            // clamped number, never an impossible one).
            volumePercent = VoiceOutputVolume.percent()
        }
        .confirmationDialog(
            Text("settings.voices.confirmTitle"),
            isPresented: Binding(
                get: { applyCandidate != nil },
                set: { if !$0 { applyCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("settings.voices.confirmApply") {
                if let voice = applyCandidate {
                    apply(voice)
                }
                applyCandidate = nil
            }
            Button("common.cancel", role: .cancel) {
                applyCandidate = nil
            }
        } message: {
            if let voice = applyCandidate {
                Text(L10n.fmt("settings.voices.confirmMessage", locale: locale,
                              optionName(voice)))
            }
        }
    }

    // MARK: - [VOLUME-BOOST] Spoken-reply volume (50–200 %, default 100)

    /// The one loudness control for the assistant's spoken replies. Two
    /// big tap targets in 10 % steps rather than a slider: a drag is the
    /// wrong gesture for shaky hands, and every step is a discrete,
    /// readable number. The copy carries both honest limits — the boost
    /// can only amplify what the voice already contains, and the
    /// soft-knee limiter trades loudness for slight compression at the
    /// top of the range (see Localizable.xcstrings,
    /// `settings.voice.volumeNote`).
    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.voice.volumeLabel")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)

            HStack(spacing: 16) {
                volumeStepButton(steps: -1, systemImage: "minus",
                                 labelKey: "settings.voice.volumeDown",
                                 enabled: volumePercent > VoiceOutputVolume.minimumPercent)
                Spacer(minLength: 8)
                Text(verbatim: "\(volumePercent)%")
                    .font(.system(size: appearance.typography.titlePointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: 128)
                    .accessibilityLabel(Text(verbatim: "\(volumePercent)%"))
                Spacer(minLength: 8)
                volumeStepButton(steps: +1, systemImage: "plus",
                                 labelKey: "settings.voice.volumeUp",
                                 enabled: volumePercent < VoiceOutputVolume.maximumPercent)
            }

            Text("settings.voice.volumeNote")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// One step button; disabled at the ends of the range (no dead press,
    /// and the dimmed state shows the user where the range ends).
    private func volumeStepButton(steps: Int, systemImage: String,
                                  labelKey: LocalizedStringKey,
                                  enabled: Bool) -> some View {
        Button {
            stepVolume(bySteps: steps)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(enabled ? appearance.colors.textPrimary
                                         : appearance.colors.textSecondary)
                .frame(minWidth: DesignTokens.minTapTargetSize + 24,
                       minHeight: DesignTokens.minTapTargetSize + 24)
                .appSurface(role: .control, cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(labelKey))
    }

    /// Persists the next step (saturating at 50 % / 200 %). One writer:
    /// this screen; the speaker only ever reads.
    private func stepVolume(bySteps steps: Int) {
        let next = VoiceOutputVolume.stepped(volumePercent, bySteps: steps)
        guard next != volumePercent else { return }
        volumePercent = next
        VoiceOutputVolume.set(next)
    }

    // MARK: - Option cards

    private func status(of voiceID: ModelID) -> VoiceStatus {
        guard let entry = ModelCatalog.entry(for: voiceID) else { return .missing }
        return Self.status(for: entry, modelStore: coordinator.modelStore)
    }

    private func optionName(_ voice: ResponseVoice) -> String {
        if voice.voiceID == ModelCatalog.piperNepaliChitwan {
            return L10n.str("settings.voices.chitwan", locale: locale)
        }
        if voice.speakerID == 0 {
            return L10n.str("settings.voices.google", locale: locale)
        }
        return L10n.fmt("settings.voices.googleSpeaker", locale: locale, voice.displayNumber)
    }

    /// Auditions a voice WITHOUT switching the live one: registers a
    /// one-shot audition request for the sample sentence, then speaks the
    /// sample through the normal queue. The speaker consumes the request
    /// only for that exact utterance (ResponseVoiceSelection), so nothing
    /// else can pick the voice up.
    private func audition(_ voice: ResponseVoice) {
        installFailure = nil
        ResponseVoiceSelection.requestAudition(of: voice, for: sampleText)
        coordinator.speak(text: sampleText)
    }

    /// Confirm-before-apply: persist the choice, install the voice from
    /// the bundle first if needed (the honest "not downloaded yet" state
    /// — a bundled voice installs here, a truly missing one can't and
    /// shows its red status instead), then speak the sample sentence as
    /// the audible proof, in the newly applied voice.
    private func apply(_ voice: ResponseVoice) {
        installFailure = nil
        if coordinator.modelStore.ttsVoiceDirectory(for: voice.voiceID) == nil,
           coordinator.modelStore.installBundledTTSVoice(for: voice.voiceID) == nil {
            installFailure = voice.voiceID
            return
        }
        guard ResponseVoiceSelection.apply(voice) else { return }
        // Remember the pick per language (2026-09-13, fix 2): an
        // en→ne→en app-language round trip must restore THIS voice, not
        // flatten it to the language default.
        ResponseVoiceSelection.remember(voice, for: coordinator.appLanguage.rawValue)
        justApplied = voice
        ResponseVoiceSelection.requestAudition(of: voice, for: sampleText)
        coordinator.speak(text: sampleText)
    }

    private func voiceOptionCard(_ voice: ResponseVoice) -> some View {
        let voiceStatus = status(of: voice.voiceID)
        let canSpeak = voiceStatus != .missing
        let isCurrent = voice == currentVoice
        let (statusKey, statusColor): (LocalizedStringKey, Color) = {
            switch voiceStatus {
            case .installed: return ("settings.voices.statusInstalled", appearance.colors.accentForeground)
            case .bundled:   return ("settings.voices.statusBundled", appearance.colors.accentForeground)
            case .missing:   return ("settings.voices.statusMissing", DesignTokens.stateError)
            }
        }()
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                    .frame(width: 40)
                Text(optionName(voice))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(appearance.statusForeground(statusColor))
                        .frame(width: 8, height: 8)
                    Text(statusKey)
                        .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    audition(voice)
                } label: {
                    Label(L10n.str("settings.voices.listenButton", locale: locale),
                          systemImage: "play.circle")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                        .background(appearance.colors.textSecondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!canSpeak)
                .accessibilityHint(Text(L10n.str("settings.voices.listenHint", locale: locale)))
        
                if isCurrent {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                        Text("settings.voices.currentVoice")
                            .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    }.foregroundStyle(appearance.colors.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                } else {
                    Button {
                        applyCandidate = voice
                    } label: {
                        Label(L10n.str("settings.voices.useButton", locale: locale),
                              systemImage: "checkmark.circle")
                            .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .accent, cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSpeak)
                    .accessibilityHint(Text(L10n.str("settings.voices.useHint", locale: locale)))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity).appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
        .opacity(canSpeak ? 1 : 0.55)
    }

    /// Status-only row for the English reply voice (not user-selectable
    /// in P0 — the picker covers the Nepali voices above).
    private func voiceRow(_ entry: ModelCatalogEntry) -> some View {
        let status = Self.status(for: entry, modelStore: coordinator.modelStore)
        let nameKey = entry.id == ModelCatalog.piperEnglishUS
            ? "settings.voices.english" : "settings.voices.nepali"
        let (statusKey, statusColor): (LocalizedStringKey, Color) = {
            switch status {
            case .installed: return ("settings.voices.statusInstalled", appearance.colors.accentForeground)
            case .bundled:   return ("settings.voices.statusBundled", appearance.colors.accentForeground)
            case .missing:   return ("settings.voices.statusMissing", DesignTokens.stateError)
            }
        }()
        return HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                .frame(width: 40)
            Text(LocalizedStringKey(nameKey))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(appearance.statusForeground(statusColor))
                    .frame(width: 8, height: 8)
                Text(statusKey)
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity).appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }
}
