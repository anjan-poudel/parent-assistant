import SwiftUI

// MARK: - Tabbed Settings hub (2026-09-16 reorg, spec
// docs/superpowers/specs/2026-09-16-settings-models-reorg-design.md §3)
//
// The hub used to be ONE long scroll of 23 section rows — a caregiver-
// facing list by the end, with the household's everyday rows (medication,
// family, voices) a long scroll away from the technical ones. The spec
// splits it into five tabs (pill bar + swipeable pages) and hands the
// technical six — Gemini/cloud AI, the voice engine stack, web search, the
// two review logs and the model screen — to a sheet reached by
// long-pressing the Settings title (with an ellipsis affordance for
// accessibility once the household has found it once).
//
// Both halves are PURE TABLES (`SettingsSection.rows`,
// `SettingsDestination.hiddenSheetRows`): the view layer only walks them.
// That is what makes "every row lands on exactly one tab, none dropped,
// none duplicated" a unit test (`SettingsTabMappingTests`) instead of a
// screenshot review.
//
// `SettingsSection` used to name all 23 leaf rows; it names the five tabs
// now, and the leaf rows it used to carry live on unchanged as
// `SettingsDestination` — the same cases, the same L10n keys, the same
// leaf screens behind them.

extension SettingsView {

    /// The five visible tabs, in bar order. Raw value drives the L10n key
    /// (`settings.tabs.<rawValue>`), so a new tab cannot ship untranslated
    /// without failing the tab-title localization test.
    enum SettingsSection: String, CaseIterable, Identifiable {
        case voice, family, reminders, tools, system

        var id: String { rawValue }

        var titleKey: String { "settings.tabs.\(rawValue)" }

        /// The rows this tab shows, in display order — the spec's table,
        /// one case per line so it diffs legibly against the design doc.
        var rows: [SettingsDestination] {
            switch self {
            case .voice:
                // "Wake word, Talk & listen, TTS voices" (spec §3).
                return [.wakeWord, .voicePersonalization, .ttsVoices]
            case .family:
                // "Family & friends, caregiver notifications, calling apps".
                return [.family, .caregiverNotifications, .calling]
            case .reminders:
                // "Medications, alarms & timers, events, calendar,
                // calendar sharing" — the household's own time first (the
                // three content rows), then the two mirror settings.
                return [.meds, .alarms, .events, .calendar, .calendarSharing]
            case .tools:
                // "Quick apps, YouTube, news feeds, manuals, saved places".
                return [.quickApps, .youtube, .feeds, .manuals, .places]
            case .system:
                // "Appearance, language, privacy".
                return [.appearance, .language, .privacy]
            }
        }
    }

    /// Every leaf screen the hub can push. The first 19 are the visible
    /// rows across the five tabs; the last five are the technical
    /// settings the hidden sheet carries (spec §2 decision 2).
    enum SettingsDestination: String, CaseIterable, Identifiable {
        // Voice
        case wakeWord, voicePersonalization, ttsVoices
        // Family
        case family, caregiverNotifications, calling
        // Reminders
        case meds, alarms, events, calendar, calendarSharing
        // Tools
        case quickApps, youtube, feeds, manuals, places
        // System
        case appearance, language, privacy
        // Hidden sheet (spec §2 decision 2) — moved, not deleted.
        case geminiAI, voiceEngine, webSearch, intentLog, toolLog

        var id: String { rawValue }

        /// The row's L10n key. Every one of these already existed in the
        /// catalog (en + ne) — the reorg moves rows, it does not rename
        /// them, so no translation can be lost to a typo'd key.
        var titleKey: String {
            switch self {
            case .wakeWord: return "wakeWord.title"
            case .voicePersonalization: return "voiceSettings.title"
            case .ttsVoices: return "settings.voices.title"
            case .family: return "settings.family.title"
            case .caregiverNotifications: return "settings.notifyCaregivers.title"
            case .calling: return "settings.calling.title"
            case .meds: return "settings.meds.title"
            case .alarms: return "settings.alarms.title"
            case .events: return "events.title"
            case .calendar: return "settings.calendar.title"
            case .calendarSharing: return "settings.calendarSharing"
            case .quickApps: return "settings.quickApps.title"
            case .youtube: return "youtubeSettings.title"
            case .feeds: return "settings.feeds.title"
            case .manuals: return "settings.manuals.title"
            case .places: return "settings.places.title"
            case .appearance: return "settings.appearance.title"
            case .language: return "settings.language.title"
            case .privacy: return "settings.privacy.title"
            case .geminiAI: return "settings.gemini.title"
            case .voiceEngine: return "settings.voiceEngine.title"
            case .webSearch: return "searchSettings.title"
            case .intentLog: return "settings.intentLog.title"
            case .toolLog: return "settings.toolLog.title"
            }
        }

        /// Row icon — carried over 1:1 from the pre-reorg rows.
        var icon: String {
            switch self {
            case .wakeWord: return "dot.radiowaves.left.and.right"
            case .voicePersonalization: return "waveform"
            case .ttsVoices: return "speaker.waveform.2.fill"
            case .family: return "person.2.fill"
            case .caregiverNotifications: return "bell.badge.fill"
            case .calling: return "phone.badge.plus"
            case .meds: return "pills.fill"
            case .alarms: return "alarm.fill"
            case .events: return "calendar.circle.fill"
            case .calendar: return "calendar.badge.clock"
            case .calendarSharing: return "calendar.badge.plus"
            case .quickApps: return "square.grid.2x2.fill"
            case .youtube: return "play.rectangle.fill"
            case .feeds: return "rectangle.stack.fill"
            case .manuals: return "book.closed.fill"
            case .places: return "mappin.and.ellipse"
            case .appearance: return "paintpalette.fill"
            case .language: return "globe"
            case .privacy: return "lock.shield.fill"
            case .geminiAI: return "sparkles"
            case .voiceEngine: return "arrow.triangle.2.circlepath"
            case .webSearch: return "magnifyingglass.circle.fill"
            case .intentLog: return "checklist"
            case .toolLog: return "text.magnifyingglass"
            }
        }

        /// The tab this row lives on — `nil` for the hidden sheet's five
        /// (spec §2 decision 2 keeps AI + dev tools off the tabs).
        var tab: SettingsSection? {
            SettingsSection.allCases.first { $0.rows.contains(self) }
        }

        /// The technical settings behind the long-press, in sheet order.
        /// The model screen ("hidden AI models") is the sixth row and is
        /// NOT a destination case — it has its own entry in
        /// `HiddenSettingsSheet` (it never was a `SettingsSection` case).
        static let hiddenSheetRows: [SettingsDestination] = [
            .geminiAI, .voiceEngine, .webSearch, .intentLog, .toolLog,
        ]
    }
}

// MARK: - First-use record of the hidden sheet

/// Remembers that the household has found the hidden technical sheet
/// (spec §3: the ellipsis affordance appears only AFTER a first open, so a
/// first-time user meets the long-press hint rather than an unexplained
/// button). A UI preference, not a secret — house rule, same store as
/// every other preference.
enum HiddenSettingsSheetUsage {
    static let defaultsKey = "settings.hiddenSheet.used"

    static func hasBeenUsed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func markUsed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }

    /// Test seam.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Row chrome

/// The card chrome every settings row shares — one implementation, so the
/// tab rows and the hidden sheet's rows cannot drift apart.
struct SettingsRowChrome: View {
    let icon: String
    let titleKey: LocalizedStringKey
    /// Live status dot + label (e.g. "जेमिनी AI, जोडिएको") for the rows
    /// that carry one; `nil` for plain rows.
    var status: (color: Color, label: LocalizedStringKey)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 40)
            Text(titleKey)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            if let status {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// One navigable settings row. The four rows with live status (Gemini,
/// voice engine, wake word, TTS voices) keep their status derivation
/// verbatim from the pre-reorg hub — the row can never disagree with the
/// screen it opens.
struct SettingsSectionRow: View {
    let destination: SettingsView.SettingsDestination

    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationLink(value: destination) {
            SettingsRowChrome(icon: destination.icon,
                              titleKey: LocalizedStringKey(destination.titleKey),
                              status: statusBadge)
        }
        .buttonStyle(.plain)
    }

    /// (dot color, short label) for the rows that show status.
    private var statusBadge: (color: Color, label: LocalizedStringKey)? {
        switch destination {
        case .geminiAI:
            let configured = coordinator.geminiConfigStore.isConfigured
            return (configured ? DesignTokens.accent : DesignTokens.stateError,
                    configured ? "settings.gemini.statusConnected"
                               : "settings.gemini.statusMissing")
        case .voiceEngine:
            return (DesignTokens.accent,
                    coordinator.voiceEngineStack == .gemini
                    ? "settings.voiceEngine.statusGemini"
                    : "settings.voiceEngine.statusOnDevice")
        case .wakeWord:
            let status = coordinator.wakeWordStatus
            return (status.presentationColor, status.shortTitleKey)
        case .ttsVoices:
            let summary = ttsVoiceSummary
            return (summary.ok ? DesignTokens.accent : DesignTokens.stateError,
                    summary.key)
        default:
            return nil
        }
    }

    /// Green when every catalog voice can speak (installed, or bundled and
    /// installable on first use); red the moment any voice is truly missing
    /// from the build.
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
}

// MARK: - Tab bar

/// Pill tab bar under the Settings title (spec §3 decision 1): ≥44pt
/// targets (the house tap-target token), selected pill in the accent
/// color, horizontally scrollable because five ≥18pt Nepali titles do not
/// fit one screen width. Swiping the pages works too — the pills and the
/// `TabView` share one selection binding.
struct SettingsTabBar: View {
    @Binding var selection: SettingsView.SettingsSection

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SettingsView.SettingsSection.allCases) { tab in
                    let selected = tab == selection
                    let title = L10n.str(tab.titleKey, locale: locale)
                    Button {
                        selection = tab
                    } label: {
                        Text(title)
                            .font(.system(size: DesignTokens.minBodyPointSize,
                                          weight: .semibold))
                            .foregroundStyle(selected ? .white : DesignTokens.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(selected ? DesignTokens.accent : DesignTokens.card)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(title))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Leaf routing

/// Every leaf screen a settings row pushes, in one place — both the hub's
/// `navigationDestination` and the hidden sheet's resolve through this, so
/// the two can never route the same row to different screens.
struct SettingsDestinationView: View {
    let destination: SettingsView.SettingsDestination

    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.locale) private var locale

    var body: some View {
        switch destination {
        case .appearance: AppearanceSettingsView()
        case .language: LanguageSettingsView()
        case .calling: CallingSettingsView()
        case .places: PlacesSettingsView()
        case .family: FamilyContactsSettingsView()
        case .meds: MedicationScheduleSettingsView()
        case .manuals: DefaultManualsBrowseView()
        // Calendar settings (calendar-settings task, 2026-09-07) — the
        // mirror/two-way/import cards that used to crowd the Medication
        // schedule leaf.
        case .calendar: CalendarSettingsView()
        // Family event alerts (caregiver event-notifications task,
        // 2026-09-13) — the settings instance is the coordinator's OWN, so
        // the toggles write the exact object the fire sites read.
        case .caregiverNotifications:
            CaregiverNotifySettingsView(settings: coordinator.caregiverNotifySettings)
        // Calendar sharing (calendar & family sharing task, 2026-09-16) —
        // the service is the coordinator's OWN, so the card renders the
        // exact status the share path writes.
        case .calendarSharing:
            CalendarShareSettingsView(service: coordinator.calendarShareService,
                                      locale: locale)
        case .alarms: AlarmsTimersSettingsView()
        // Free-form events (rich-events task, 2026-09-17) — the
        // household's own appointments, native in the default calendar,
        // with the app-side photo index behind them.
        case .events: EventsView()
        case .geminiAI: GeminiAPISettingsView()
        case .voiceEngine: VoiceEngineSettingsView()
        case .wakeWord: WakeWordSettingsView()
        case .ttsVoices: TTSVoicesSettingsView()
        case .voicePersonalization: VoicePersonalizationSettingsView(coordinator: coordinator)
        case .webSearch: SearchSettingsView()
        case .youtube: YouTubeSettingsView()
        case .feeds: FeedsSettingsView()
        case .quickApps: QuickAccessAppsView()
        case .privacy: PrivacySettingsView()
        case .intentLog: IntentLogReviewView()
        case .toolLog: ToolLogReviewView()
        }
    }
}

// MARK: - Hidden technical sheet

/// What the Settings title's long-press opens (spec §3): the technical
/// settings that moved OFF the tabs — Gemini/cloud AI, the voice engine
/// stack, web search, the intent and tool logs, and the model screen.
///
/// A `NavigationStack` of its own, so each row pushes inside the sheet and
/// the household lands back on the sheet when it pops — not on a Settings
/// tab they did not choose.
struct HiddenSettingsSheet: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            LeafScreen(titleKey: "settings.hidden.title") {
                VStack(spacing: 12) {
                    ForEach(SettingsView.SettingsDestination.hiddenSheetRows) { destination in
                        SettingsSectionRow(destination: destination)
                    }
                    // "Hidden AI models" — the sixth row, and the one the
                    // sheet existed for before this reorg: the STT/brain
                    // pickers, downloads and the encoder A/B card live
                    // behind it (`AIModelsSettingsView`). A closure link,
                    // not a `SettingsDestination`: the model screen was
                    // never a hub section case.
                    NavigationLink {
                        AIModelsSettingsView()
                    } label: {
                        SettingsRowChrome(icon: "brain.head.profile",
                                          titleKey: "settings.ai.title")
                    }
                    .buttonStyle(.plain)

                    Text("settings.hidden.note")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationDestination(for: SettingsView.SettingsDestination.self) { destination in
                SettingsDestinationView(destination: destination)
            }
        }
    }
}
