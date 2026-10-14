import SwiftUI

// MARK: - Tabbed Settings hub (2026-09-16 reorg, spec
// docs/superpowers/specs/2026-09-16-settings-models-reorg-design.md §3)
//
// The hub used to be ONE long scroll of 23 section rows — a caregiver-
// facing list by the end, with the household's everyday rows (medication,
// family, voices) a long scroll away from the technical ones. The spec
// splits it into five tabs (pill bar + swipeable pages) and hands the
// technical rows — Gemini/cloud AI, the voice engine stack, web search, the
// YouTube key, the Spotify account link, the two review logs and the model
// screen — to a sheet reached by long-pressing the Settings title (with an
// ellipsis affordance for accessibility once the household has found it
// once).
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
                // "Family & friends, About me, caregiver notifications,
                // calling apps" — [PROFILE-INTERVIEW T-103] the profile
                // editor sits with the family rows (design-l2 §5.7:
                // tab .family — rows become [.family, .profile,
                // .caregiverNotifications, .calling]).
                return [.family, .profile, .caregiverNotifications, .calling]
            case .reminders:
                // "Medications, daily routines, alarms & timers, events,
                // calendar, calendar sharing" — the household's own time
                // first (the four content rows), then the two mirror
                // settings.
                return [.meds, .routines, .alarms, .events, .calendar,
                        .calendarSharing]
            case .tools:
                // "Quick apps, news feeds, manuals, saved places" — the
                // household's shelf of apps and reference screens.
                // YouTube used to sit second here; it is a cloud-provider
                // KEY screen (the same screen class as the hidden Web
                // search and Gemini rows: a SecureField, a quota note and
                // a privacy note), so it moved in with them (menu-
                // deepening pass, 2026-09-17). A household tab stays free
                // of plumbing a family member must not be asked to handle.
                return [.quickApps, .feeds, .manuals, .places]
            case .system:
                // "Appearance, language, privacy" + the live-translation
                // consent row ([LIVE-TRANSLATE T-015], 2026-09-17): the
                // reorg's System group is where the privacy-shaped
                // household controls live, and the branch's row sat
                // immediately above `.privacy` — the elder changing their
                // mind about translation is the common case, so it is a
                // plain row here, not a sub-page of Privacy.
                return [.appearance, .language, .liveTranslate, .privacy]
            }
        }
    }

    /// Every leaf screen the hub can push. The first 21 are the visible
    /// rows across the five tabs; the last seven are the technical settings
    /// the hidden sheet carries (spec §2 decision 2; YouTube joined them
    /// in the menu-deepening pass, 2026-09-17; Spotify joined them with the
    /// spotify-music-integration pass, 2026-10-07 — design-l2 §17; About me
    /// joined the visible rows in the profile-interview pass, 2026-10-05).
    enum SettingsDestination: String, CaseIterable, Identifiable {
        // Voice
        case wakeWord, voicePersonalization, ttsVoices
        // Family
        case family, profile, caregiverNotifications, calling
        // Reminders
        case meds, routines, alarms, events, calendar, calendarSharing
        // Tools
        case quickApps, feeds, manuals, places
        // System
        case appearance, language, liveTranslate, privacy
        // Hidden sheet (spec §2 decision 2) — moved, not deleted. YouTube
        // rides with them: a provider-key screen, not a household control.
        // [SPOTIFY T-120] Spotify rides there too: the caregiver's account
        // link is plumbing of the same class (design-l2 §17), never a
        // household tab row.
        case geminiAI, voiceEngine, webSearch, intentLog, toolLog, youtube, spotify

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
            case .profile: return "settings.profile.title"
            case .caregiverNotifications: return "settings.notifyCaregivers.title"
            case .calling: return "settings.calling.title"
            case .meds: return "settings.meds.title"
            case .routines: return "settings.routines.title"
            case .alarms: return "settings.alarms.title"
            case .events: return "events.title"
            case .calendar: return "settings.calendar.title"
            case .calendarSharing: return "settings.calendarSharing"
            case .quickApps: return "settings.quickApps.title"
            case .youtube: return "youtubeSettings.title"
            // [SPOTIFY T-120] The T-117 catalog key (design-l2 §31), en+ne
            // already shipped — the row renders the same title as its leaf.
            case .spotify: return "spotifySettings.title"
            case .feeds: return "settings.feeds.title"
            case .manuals: return "settings.manuals.title"
            case .places: return "settings.places.title"
            case .appearance: return "settings.appearance.title"
            case .language: return "settings.language.title"
            // [LIVE-TRANSLATE T-015] The consent leaf's own title key, in
            // en + ne already (the reorg moves rows, it does not rename
            // them).
            case .liveTranslate: return "settings.livetranslate.title"
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
            case .profile: return "person.text.rectangle"
            case .caregiverNotifications: return "bell.badge.fill"
            case .calling: return "phone.badge.plus"
            case .meds: return "pills.fill"
            case .routines: return "repeat.circle.fill"
            case .alarms: return "alarm.fill"
            case .events: return "calendar.circle.fill"
            case .calendar: return "calendar.badge.clock"
            case .calendarSharing: return "calendar.badge.plus"
            case .quickApps: return "square.grid.2x2.fill"
            case .youtube: return "play.rectangle.fill"
            // [SPOTIFY T-120] design-l2 §17's pinned row icon.
            case .spotify: return "music.note"
            case .feeds: return "rectangle.stack.fill"
            case .manuals: return "book.closed.fill"
            case .places: return "mappin.and.ellipse"
            case .appearance: return "paintpalette.fill"
            case .language: return "globe"
            case .liveTranslate: return "text.viewfinder"
            case .privacy: return "lock.shield.fill"
            case .geminiAI: return "sparkles"
            case .voiceEngine: return "arrow.triangle.2.circlepath"
            case .webSearch: return "magnifyingglass.circle.fill"
            case .intentLog: return "checklist"
            case .toolLog: return "text.magnifyingglass"
            }
        }

        /// The tab this row lives on — `nil` for the hidden sheet's seven
        /// (spec §2 decision 2 keeps AI + dev tools off the tabs).
        var tab: SettingsSection? {
            SettingsSection.allCases.first { $0.rows.contains(self) }
        }

        /// The technical settings behind the long-press, in sheet order:
        /// the cloud/AI plumbing (Gemini, the voice-engine stack, web
        /// search), the two provider screens the caregiver configures (the
        /// YouTube Data API key, the Spotify account link — [SPOTIFY T-120],
        /// design-l2 §17: after `.youtube`), then the two review logs. The
        /// model screen ("hidden AI models") is the row AFTER these and is
        /// NOT a destination case — it has its own entry in
        /// `HiddenSettingsSheet` (it never was a `SettingsSection` case).
        static let hiddenSheetRows: [SettingsDestination] = [
            .geminiAI, .voiceEngine, .webSearch, .youtube, .spotify,
            .intentLog, .toolLog,
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
    @Environment(\.appAppearance) private var appearance
    /// [AX-VIEWPORT] Gates the status-under-title stacking below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let titleKey: LocalizedStringKey
    /// Live status dot + label (e.g. "जेमिनी AI, जोडिएको") for the rows
    /// that carry one; `nil` for plain rows.
    var status: (color: Color, label: LocalizedStringKey)? = nil

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon, tint: .settings, diameter: 40)
            // [AX-VIEWPORT] At accessibility text sizes the title and the
            // status label cannot share one line without wrapping every
            // word (the row triples in height with both squeezed into
            // slivers). The status moves to its own line under the title:
            // the row still reads "title, then status", just stacked.
            // Standard sizes keep today's single-line row exactly.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    statusText
                }
                Spacer(minLength: 8)
            } else {
                titleText
                Spacer()
                statusText
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(appearance.colors.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity).appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var titleText: some View {
        Text(titleKey)
            .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
            .foregroundStyle(appearance.colors.textPrimary)
    }

    /// The live status dot + label; renders nothing for a plain row.
    @ViewBuilder
    private var statusText: some View {
        if let status {
            HStack(spacing: 6) {
                Circle()
                    .fill(appearance.statusForeground(status.color))
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
    }
}

/// One navigable settings row. The four rows with live status (Gemini,
/// voice engine, wake word, TTS voices) keep their status derivation
/// verbatim from the pre-reorg hub — the row can never disagree with the
/// screen it opens.
struct SettingsSectionRow: View {
    @Environment(\.appAppearance) private var appearance
    let destination: SettingsView.SettingsDestination

    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationLink(value: destination) {
            SettingsRowChrome(icon: destination.icon,
                              titleKey: LocalizedStringKey(destination.titleKey),
                              status: statusBadge)
        }
        .buttonStyle(.plain)
        // [RESPONSIVENESS] Press confirmation for every settings row —
        // the hub's and the hidden sheet's alike, since both render
        // through this one row (SettingsRowChrome's own doc: "one
        // implementation, so the tab rows and the hidden sheet's rows
        // cannot drift apart"). The push animation is the visual half;
        // the light tap is the half an elder feels while still looking
        // at the row they pressed. See `Haptics` for the accessibility
        // gates (reduceMotion/VoiceOver suppress it wholesale).
        .hapticOnTap()
        .accessibilityIdentifier("settings.\(destination.rawValue)")
    }

    /// (dot color, short label) for the rows that show status.
    private var statusBadge: (color: Color, label: LocalizedStringKey)? {
        switch destination {
        case .geminiAI:
            let configured = coordinator.geminiConfigStore.isConfigured
            return (configured ? appearance.colors.accentForeground : DesignTokens.stateError,
                    configured ? "settings.gemini.statusConnected"
                               : "settings.gemini.statusMissing")
        case .voiceEngine:
            return (appearance.colors.accentForeground,
                    coordinator.voiceEngineStack == .gemini
                    ? "settings.voiceEngine.statusGemini"
                    : "settings.voiceEngine.statusOnDevice")
        case .wakeWord:
            let status = coordinator.wakeWordStatus
            return (status.presentationColor, status.shortTitleKey)
        case .ttsVoices:
            let summary = ttsVoiceSummary
            return (summary.ok ? appearance.colors.accentForeground : DesignTokens.stateError,
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
    @Environment(\.appAppearance) private var appearance
    @Binding var selection: SettingsView.SettingsSection

    @Environment(\.locale) private var locale
    /// [AX-VIEWPORT] Gates the pill's wrapping room.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SettingsView.SettingsSection.allCases) { tab in
                    let selected = tab == selection
                    let title = L10n.str(tab.titleKey, locale: locale)
                    Button {
                        // [RESPONSIVENESS] The selection tick fires only
                        // on a REAL change — re-tapping the pill already
                        // selected must stay silent, or the tick stops
                        // meaning "the tab changed" and starts meaning
                        // "something was touched" (see `Haptics` for the
                        // reduceMotion/VoiceOver gates).
                        guard tab != selection else { return }
                        Haptics.play(.selection)
                        selection = tab
                    } label: {
                        Text(title)
                            .font(.system(size: appearance.typography.bodyPointSize,
                                          weight: .semibold))
                            .foregroundStyle(selected ? appearance.colors.onAccent : appearance.colors.textPrimary)
                            .multilineTextAlignment(.center)
                            // [AX-VIEWPORT] At accessibility text sizes a
                            // single line of body text is taller than the
                            // 44pt minimum, so with `.lineLimit(1)` and no
                            // vertical padding the words touched the
                            // capsule's edges — unreadable pills. The
                            // title may now wrap (a width cap gives the
                            // horizontal scroll a line to wrap AT — an
                            // unbounded line still never wraps), and the
                            // capsule gets vertical room that scales with
                            // the type, like the text does. Standard sizes
                            // keep the one-line pill byte-for-byte.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 220 : nil)
                            .padding(.horizontal, 20)
                            .padding(.vertical, dynamicTypeSize.isAccessibilitySize
                                     ? appearance.typography.captionPointSize * 0.4 : 0)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: selected ? .accent : .control, cornerRadius: 999)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(title))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
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
    @Environment(\.appAppearance) private var appearance
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
        // [PROFILE-INTERVIEW T-103] The About-me editor (design-l2 §5.7):
        // same leaf pattern as VoicePersonalizationSettingsView — the
        // coordinator is passed in rather than looked up, so the model's
        // save path is the same single writer the wizard uses.
        case .profile: ProfileSettingsView(coordinator: coordinator)
        case .meds: MedicationScheduleSettingsView()
        // Daily routines (routine-settings move, 2026-09-17) — the
        // enable/disable toggles and photo management that used to live
        // at the bottom of the Reminders leaf.
        case .routines: RoutineSettingsView()
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
        // [SPOTIFY T-120] The caregiver's account link and disclosure
        // (design-l2 §17): the leaf takes the coordinator's ONE session
        // (T-119) — the same instance the plugin and the router hold — and
        // constructs no second account (L2-R2).
        case .spotify: SpotifySettingsView(session: coordinator.spotifyAccountSession)
        case .feeds: FeedsSettingsView()
        case .quickApps: QuickAccessAppsView()
        // [LIVE-TRANSLATE T-015] The leaf drives the coordinator's one
        // consent controller, so its decision is the session view's
        // decision with no restart and no second record.
        case .liveTranslate:
            LiveTranslateConsentSettingsView(controller: coordinator.liveTranslateConsentController())
        case .privacy: PrivacySettingsView()
        case .intentLog: IntentLogReviewView()
        case .toolLog: ToolLogReviewView()
        }
    }
}

// MARK: - Hidden technical sheet

/// What the Settings title's long-press opens (spec §3): the technical
/// settings that moved OFF the tabs — Gemini/cloud AI, the voice engine
/// stack, web search, the YouTube key, the Spotify account link
/// ([SPOTIFY T-120]), the intent and tool logs, and the model screen.
///
/// A `NavigationStack` of its own, so each row pushes inside the sheet and
/// the household lands back on the sheet when it pops — not on a Settings
/// tab they did not choose.
struct HiddenSettingsSheet: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject private var coordinator: AppCoordinator
    /// [DEVSCREEN-DOWNLOAD] The persisted bypass switch
    /// (`ModelDownloadDebugSettings`). `@AppStorage` writes the same
    /// `UserDefaults` key `ModelDownloadService` reads per download, so the
    /// toggle IS the behaviour — there is no second copy to fall out of
    /// step. Default OFF: an untouched install never bypasses the policy.
    @AppStorage(ModelDownloadDebugSettings.ignoreFitPolicyKey)
    private var ignoreFitPolicyForDownloads = false
    /// [OWNER-OVERRIDE 2026-10-11] The RAM-tier bypass switch — same
    /// single-source-of-truth pattern as the row above.
    @AppStorage(ModelDownloadDebugSettings.ignoreRamTierKey)
    private var ignoreRamTierForDownloads = false

    var body: some View {
        NavigationStack {
            LeafScreen(titleKey: "settings.hidden.title") {
                VStack(spacing: 12) {
                    ForEach(SettingsView.SettingsDestination.hiddenSheetRows) { destination in
                        SettingsSectionRow(destination: destination)
                    }
                    // "Hidden AI models" — the row after the destination
                    // list, and the one the sheet existed for before this
                    // reorg: the STT/brain
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
                    // [RESPONSIVENESS] Same press confirmation as the
                    // destination rows above — these three closure links
                    // are settings rows in everything but their type, so
                    // they cannot feel different (see `Haptics`).
                    .hapticOnTap()

                    // [SCHEME-PROBE] (2026-09-19) The URL scheme tester —
                    // a diagnostic tool, so it lives here with the other
                    // developer surfaces, never in the family tabs.
                    NavigationLink {
                        SchemeProbeView()
                    } label: {
                        SettingsRowChrome(icon: "link",
                                          titleKey: "settings.schemeProbe.title")
                    }
                    .buttonStyle(.plain)
                    .hapticOnTap()  // [RESPONSIVENESS] see the row above

                    // [TRANSLATE-TEST] (2026-09-21) The translation
                    // comparison screen — runs the two shipped translation
                    // tiers against text you type or dictate and shows which
                    // one answered and how long it took. Same reasoning as
                    // the scheme tester above: a diagnostic, so it lives
                    // here and never in a family tab. A closure link rather
                    // than a `SettingsDestination`, following the row above.
                    NavigationLink {
                        TranslateTestView()
                    } label: {
                        SettingsRowChrome(icon: "character.bubble",
                                          titleKey: "settings.translateTest.title")
                    }
                    .buttonStyle(.plain)
                    .hapticOnTap()  // [RESPONSIVENESS] see above

                    // [DEVSCREEN-DOWNLOAD] (2026-09-21) The switch the
                    // translation comparison screen's Download button needs
                    // when the warden's device-class policy refuses the very
                    // model that screen is there to A/B: a policy that cannot
                    // be stepped around makes it useless for exactly the
                    // models it exists to measure.
                    //
                    // It sits here, in the sheet a household never opens, and
                    // it is OFF until someone persists it — the bypass is a
                    // developer's deliberate choice for as long as an A/B
                    // runs, never a shipped behaviour. It bypasses POLICY
                    // only: the size cap, disk, RAM and iOS gates still
                    // refuse a download with it on.
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $ignoreFitPolicyForDownloads) {
                            Text("settings.hidden.ignoreFitPolicy.label")
                                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                                .foregroundStyle(appearance.colors.textPrimary)
                        }
                        .tint(appearance.colors.accent)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        Text("settings.hidden.ignoreFitPolicy.hint")
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // [OWNER-OVERRIDE 2026-10-11] The RAM-tier bypass —
                    // allows downloads this phone's own RAM floor refuses,
                    // WITH the warning below. Temporary testing only.
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $ignoreRamTierForDownloads) {
                            Text("settings.hidden.ignoreRamTier.label")
                                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                                .foregroundStyle(appearance.colors.textPrimary)
                        }
                        .tint(appearance.colors.accent)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        Text("settings.hidden.ignoreRamTier.hint")
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("settings.hidden.note")
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary.opacity(0.8))
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
