import SwiftUI
import UIKit

/// Leaf destinations reachable from the dock (spec §4.3), the top bar
/// and pushed screens.
enum LeafDestination: Identifiable {
    case meds
    case reminders
    case calendar
    case call
    case history
    case settings
    /// "About me" (home-profile-icon, 2026-10-06): the profile editor,
    /// reached from its own icon on the home hub next to Settings — the
    /// SAME `ProfileSettingsView` the Settings family tab pushes, just
    /// one tap from Home.
    case profile
    /// Directions (directions-screen task, 2026-09-07): the saved-targets
    /// map leaf, docked next to Appliance per the task brief.
    case directions
    /// Today's stored morning briefing (briefing persistence task,
    /// 2026-09-08): reached from the Updates leaf's Notifications
    /// section — the briefing is persistent for the day and this leaf is
    /// its viewer.
    case briefing
    /// "Updates" (home-redesign v3, 2026-09-08): the pushed leaf the top
    /// bar's bell opens — Notifications + Today + Activity sections in
    /// one vertical scroll (see `UpdatesScreen`).
    case updates
    /// The mixed content feed (feed-agent task, 2026-09-08) — docked
    /// last so the five pre-existing tiles keep their positions.
    case feed
    /// Alarms & timers management (updates-alarms task, 2026-09-10):
    /// pushed from the Updates leaf's Alarms-section rows — one tap
    /// from the glance to the Settings leaf that manages it.
    case alarms

    var id: String {
        switch self {
        case .meds: return "meds"
        case .reminders: return "reminders"
        case .calendar: return "calendar"
        case .call: return "call"
        case .history: return "history"
        case .settings: return "settings"
        case .profile: return "profile"
        case .directions: return "directions"
        case .briefing: return "briefing"
        case .updates: return "updates"
        case .feed: return "feed"
        case .alarms: return "alarms"
        }
    }
}

/// Home (redesign spec 2026-09-03): the ONLY screen with voice UI — the
/// breathing Talk hero, the hint carousel, the live-caption/outcome
/// feedback loop, and the shortcut dock. Every other screen is a plain
/// full-screen page (see `LeafScreen` in `LeafViews.swift`) — this
/// separation is deliberate (redesign spec §3.2), not an oversight.
struct HomeView: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine
    /// [BOOT-LATENCY] Read so the container can animate the talk hero's
    /// settle when the boot spinner collapses inside the talk stage.
    @EnvironmentObject private var boot: StartupBoot

    @State private var showWizard = false
    @State private var showHistory = false
    /// [PROFILE-INTERVIEW T-102] Where the wizard opens when presented —
    /// captured by BOTH entry points: the reminder card at tap time, the
    /// cold-start one-shot at route time. The cover renders this value,
    /// never a live re-read of the step map.
    @State private var wizardStart: OnboardingState.Step?
    /// The cold-start check runs once per process (first `onAppear`).
    @State private var didCheckStartupRoute = false
    /// Programmatic push target for voice-driven contact search
    /// (voice-contact-search, 2026-09-07): the router's keyword pre-route
    /// publishes `pendingContactSearchRequest`; this onChange appends the
    /// Call leaf so results land on screen with zero touch. Ordinary dock
    /// taps keep using NavigationLink(value:) — both append to this path.
    /// Type-erased navigation path (fix 2026-09-07): the previous
    /// `[LeafDestination]`-typed path silently DROPPED every
    /// `SettingsSection` push from the Settings screen ("nothing in
    /// Settings works") — a value that isn't a LeafDestination cannot
    /// append to a LeafDestination-typed path. `NavigationPath` accepts
    /// any Hashable value, so dock leaves AND Settings sections push
    /// through the same stack.
    @State private var navPath = NavigationPath()
    @State private var conversationViewportHeight: CGFloat = 0

    private var pinsDock: Bool {
        dynamicTypeSize <= .large && verticalSizeClass != .compact
    }

    private var homeDock: some View {
        HomeDock(edgeAttached: pinsDock,
                 onAppliance: { coordinator.presentApplianceHelper(question: nil) },
                 onLiveTranslate: { coordinator.presentLiveTranslate() })
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                VoiceBridgeBackground(theme: coordinator.appTheme)
                VStack(spacing: 0) {
                    HomeTopBar(dateLine: homePresentation.dateLine,
                               calendarLine: coordinator.homeCalendarLine,
                               notificationCount: homePresentation.notificationCount) {
                        navPath.append(LeafDestination.updates)
                    }
                    .equatable()
                    .padding(.horizontal, 20)
                    // [MEDIUM-FIT] (2026-10-15) 4pt top clearance at
                    // ordinary type sizes, 8pt at accessibility sizes.
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 8 : 4)

                    // [VOICE-OOM] F (2026-10-10) — the degraded-mode
                    // status pill: visible while the turn in force runs a
                    // stepped-down brain or the deterministic reply path,
                    // gone (renders nothing) the moment the next turn
                    // resolves back to the remembered pick. Outside the
                    // scroll and above the talk hero, so it never covers
                    // the mic/voice UI.
                    DegradedModeStatusPill(mode: coordinator.degradedVoiceMode)

                    // One vertical scroll owns every movable Home section.
                    // The previous nested feedback scroller had almost no
                    // height above the fixed two-row dock, so activity cards
                    // rendered behind it and were awkward to pan.
                    ScrollView(showsIndicators: false) {
                        // [MEDIUM-FIT] (2026-10-15) 12pt section gap at
                        // ordinary type sizes keeps the whole Home flow
                        // inside the viewport; 16pt at accessibility
                        // sizes where the dock scrolls with the content.
                        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 16 : 12) {
                            if !homePresentation.favoriteApps.isEmpty {
                                QuickAccessStrip(apps: homePresentation.favoriteApps) { app in
                                    // [APP-UI-CONFIRM] (2026-10-14) The
                                    // tile ASKS first — the app's own
                                    // localized confirmation instead of
                                    // iOS's English "Open in <App>?"
                                    // dialog (owner report, verbatim, on
                                    // `requestAppLaunchFromTile`).
                                    // `performAppLaunch` stays the
                                    // executor behind every yes.
                                    coordinator.requestAppLaunchFromTile(app)
                                }
                                .equatable()
                            }

                            HomeTimerChipView(service: coordinator.alarmTimersService) { id in
                                coordinator.cancelTimer(id: id)
                            }
                            .equatable()
                            Spacer(minLength: 0)

                            talkStage
                                .equatable()

                            feedbackRegion
                                .equatable()

                            // Last missed call (call-tracking task,
                            // 2026-09-13): the activity tile sits with the
                            // rest of Home's activity flow, under the
                            // feedback region and above the conversation
                            // chip. It hides itself when there is nothing
                            // to show (`homePresentation.lastMissedCall`
                            // is nil) — no dead card, the redesign's
                            // no-mockups rule. Tap pushes the Phone
                            // screen's call log.
                            if let missedCall = homePresentation.lastMissedCall {
                                HomeMissedCallTile(presentation: missedCall) {
                                    navPath.append(LeafDestination.call)
                                }
                                .equatable()
                            }

                            if showsPinnedHistoryChip,
                               !homePresentation.setup.isVisible {
                                historyChip
                            }
                            Spacer(minLength: 0)
                            if !pinsDock {
                                homeDock
                            }
                        }
                        .padding(.horizontal, 20)
                        // [MEDIUM-FIT] (2026-10-15) Tighter scroll
                        // insets at ordinary type sizes.
                        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 24 : 16)
                        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 16 : 12)
                        .frame(maxWidth: .infinity, minHeight: conversationViewportHeight)
                    }
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        conversationViewportHeight = height
                    }
                    .accessibilityIdentifier("home.content")
                    if pinsDock {
                        homeDock
                            // [MEDIUM-FIT] (2026-10-15) 8pt dock clearance
                            // at ordinary type sizes.
                            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 12 : 8)
                    }
                }
            }
            // Home paints its own top bar (HomeTopBar), so the system
            // navigation bar is hidden entirely. `.toolbar(.hidden,
            // for: .navigationBar)` is the iOS 16 form —
            // `.navigationBarHidden(true)` is deprecated and on iOS 16+
            // can leave the bar's layout space behind on first render.
            .toolbar(.hidden, for: .navigationBar)
            // Value-based navigation (iOS 16 pattern). The previous
            // navigationDestination(isPresented:) with a derived binding
            // is fragile — it silently fails to present on some iOS 16
            // builds, which presented as "hub buttons do nothing".
            .navigationDestination(for: LeafDestination.self) { leafView(for: $0) }
            // Settings leaves pushed straight from Home (menu-audit task,
            // 2026-09-17): the quick-access strip's plus tile pushes
            // `.quickApps` directly. While the Settings hub is itself
            // pushed, ITS registration of this destination type wins (it
            // is the deeper, later-registered one), so hub rows keep
            // routing through SettingsDestinationView exactly as before.
            .navigationDestination(for: SettingsView.SettingsDestination.self) { destination in
                SettingsDestinationView(destination: destination)
            }
            // Voice-driven contact search (2026-09-07): a request means
            // "Phone screen + this search" — push the Call leaf when we
            // aren't already on it. The leaf consumes the request on
            // appear (and observes it while open, so a second utterance
            // re-searches live); consuming clears it, so a stale request
            // can never double-push. iOS 16 onChange (single-parameter).
            .onChange(of: coordinator.pendingContactSearchRequest?.id) { _ in
                guard coordinator.pendingContactSearchRequest != nil else { return }
                // Push the Call leaf from Home (empty path). From other
                // leaves the request stays pending; a type-erased
                // `NavigationPath` cannot read its last element, so the
                // old "already on .call" peek is unavailable — the empty-
                // path guard is the honest equivalent for the primary
                // voice-from-Home flow (fix 2026-09-07).
                if navPath.isEmpty {
                    navPath.append(LeafDestination.call)
                }
            }
            // [PROFILE-INTERVIEW T-102] The cold-start interview route
            // (FR-PI-016, design-l2 §4 C13): ONE evaluation per process,
            // on the first appear only; `scenePhase` is deliberately not
            // observed (no foreground re-check in v1 — it could pop the
            // interview over a live capture). The route is captured into
            // `wizardStart` so the cover renders a stable step. Honours
            // the hosted-test boot guard: unit tests see the behavior
            // they always had; UI tests run the real shell.
            .onAppear {
                guard !didCheckStartupRoute else { return }
                didCheckStartupRoute = true
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
                        == nil else { return }
                if let route = coordinator.coldStartInterviewRoute() {
                    wizardStart = route
                    showWizard = true
                }
            }
            .fullScreenCover(isPresented: $showWizard) {
                OnboardingWizardView(startingAt: wizardStart)
                    .environmentObject(coordinator)
                    .environmentObject(session)
                    .environmentObject(coordinator.modelDownloadService)
                    .environment(\.locale, coordinator.activeLocale)
            }
            .sheet(isPresented: $showHistory) {
                // The coordinator is passed (not looked up in the
                // environment) so the sheet can page older history in
                // and observe the live window (local-cache-chat task,
                // 2026-09-06).
                ConversationHistorySheet(coordinator: coordinator)
            }
            // The top-bar date line refreshes on appear and again just
            // after each midnight while Home stays open (calendar-display
            // task, 2026-09-09): no TimelineView, no timer object — the
            // clock left the top bar entirely (the phone shows the time),
            // so one sleep-until-midnight loop is all the day rollover
            // needs. Foreground refreshes ride
            // AppCoordinator.handleScenePhase, setting changes ride the
            // calendar-display didSets.
            .task {
                coordinator.refreshHomeCalendarLineIfNeeded()
                while !Task.isCancelled {
                    let now = Date()
                    guard let nextMidnight = Calendar.current.nextDate(
                        after: now,
                        matching: DateComponents(hour: 0, minute: 0),
                        matchingPolicy: .nextTime) else { break }
                    let interval = nextMidnight.timeIntervalSince(now)
                    guard interval > 0 else { continue }
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(interval * 1_000_000_000))
                        guard !Task.isCancelled else { break }
                        coordinator.refreshHomeCalendarLineIfNeeded()
                    } catch {
                        break
                    }
                }
            }
        }
    }

    // MARK: - Presentation models ([P1-7] — narrow inputs for the split)


    /// The Home chrome's inputs (top bar, quick-access row, setup strip),
    /// assembled once per render and handed to the extracted views as
    /// VALUES. Assembling them here — where the coordinator is already
    /// observed — is what lets the sections below stop observing it.
    private var homePresentation: HomePresentationState {
        HomePresentationState(
            dateLine: coordinator.homeDateLine,
            notificationCount: activeNotificationCount,
            favoriteApps: coordinator.favoriteApps,
            setup: SetupPresentation(
                pendingCount: coordinator.onboardingState.pendingSteps.count,
                // Warning styling is reserved for a capability that is
                // genuinely unavailable — never for "setup is not done"
                // (design review: ready vs optional setup).
                needsAttention: boot.hasFailures),
            lastMissedCall: missedCallPresentation)
    }

    /// The last missed call, resolved into the tile's two lines — or nil
    /// when the log has no missed call inside the tile window
    /// (call-tracking task, 2026-09-13).
    ///
    /// The lookup is `AppActivityLog`'s OWN missed-call rule, run over the
    /// same published window the Recent activity leaf renders
    /// (`coordinator.recentActivity`), so the tile and the Phone screen's
    /// call log can never disagree about which call was last missed.
    /// Resolution happens here — where the coordinator is already
    /// observed — for the active locale and this render's `now`; the tile
    /// itself stays a value-typed view that reads nothing.
    private var missedCallPresentation: MissedCallPresentation? {
        let now = Date()
        guard let entry = AppActivityLog.lastMissedCall(in: coordinator.recentActivity,
                                                        now: now) else { return nil }
        // The correlated name (missed-calls fix, 2026-09-18) rides the
        // same published map the list rows read, so the tile and the
        // list name one caller identically.
        return MissedCallPresentation.resolve(entry,
                                              now: now,
                                              calendar: .current,
                                              locale: coordinator.activeLocale,
                                              correlatedName: coordinator.missedCallDisplayNames[entry.id])
    }

    /// The talk stage's [P0-2] readiness value plus its two derived labels.
    private var voicePresentation: VoicePresentationState {
        VoicePresentationState(
            readiness: heroReadiness,
            statusOverride: talkStatusLineOverride,
            showsOpenSettings: stageVisuals.isError && coordinator.voiceErrorKind == .permission)
    }

    /// The Home widget registry (rendering v2, home-redesign 2026-09-08):
    /// panels now feed the Updates leaf + bell badge instead of a stacked
    /// card row — evaluated on every render; panels self-hide through
    /// `makeRow`, so no widget bookkeeping lives in this view. The SAME
    /// instance feeds the bell on Home and the Updates leaf's
    /// Notifications section (UpdatesScreen receives it), so badge count
    /// and leaf rows can never disagree.
    private let widgetRegistry = HomeWidgetRegistry()

    /// Bell badge derivation — [P1-7] reads the coordinator's DEDUPED
    /// published count (`AppCoordinator.activeNotificationCount`), which
    /// is recomputed only when reminder/briefing state changes — never on
    /// unrelated Home invalidations.
    private var activeNotificationCount: Int {
        coordinator.activeNotificationCount
    }

    // MARK: - Talk stage (redesign spec §3.1)

    /// The stage's visuals all derive from ONE mapping
    /// (`VoiceSessionState.talkVisuals`, call-UI fix 2026-09-07): which
    /// stage shows (hero vs confirmation chips), the hint carousel and
    /// the error detail branch on the mapping's flags — never on raw
    /// state equality. A session-state flip therefore re-renders every
    /// stage element from the same table in the same transaction,
    /// instead of each view re-deriving its own conditions that could
    /// diverge.
    private var stageVisuals: TalkStageVisuals {
        TalkStageVisuals.resolved(state: session.state,
                                  isSpeaking: coordinator.isSpeaking,
                                  slotAnswerCaptureActive: coordinator.slotAnswerCaptureActive)
    }

    /// Status-line override fed to the hero: the failure-specific error
    /// caption while erroring, else the transient post-reset notice
    /// (TALK-CRASH-FIX, 2026-09-07). The error caption wins over the
    /// notice — a failed restart is the more urgent surface.
    private var talkStatusLineOverride: String? {
        if stageVisuals.isError { return errorStatusText }
        return coordinator.voiceResetNotice
    }

    /// [P0-2] Manual Talk readiness — the shared `VoicePipelineReadiness`
    /// contract the hero gates on, published by the coordinator ONLY from
    /// the real `voicePipeline.start` completion callback.
    private var heroReadiness: VoicePipelineReadiness { coordinator.voicePipelineReadiness }

    /// [P1-7] The extracted stage (`HomeSubviews.swift`). The tap switch
    /// lives inside the stage itself, so the closures Home hands over are
    /// the two coordinator calls the switch selects between — `onStart`
    /// and `onRecover` — plus the hold-to-reset action. `state` travels
    /// both here and inside the stage, where it is part of `==`.
    private var talkStage: TalkStage {
        TalkStage(state: session.state,
                  session: session,
                  // [AUDIO-REACTIVE-HERO] (2026-10-14) The hero's live
                  // audio-level model — the app-constant instance the
                  // pipeline (mic) and the Piper speaker (reply) feed.
                  audioLevels: coordinator.audioVisualization,
                  voice: voicePresentation,
                  isSpeaking: coordinator.isSpeaking,
                  slotAnswerCaptureActive: coordinator.slotAnswerCaptureActive,
                  onStart: coordinator.simulateWakeWordDetection,
                  onRecover: coordinator.recoverVoiceCycle,
                  onReset: coordinator.resetVoiceActivation)
    }

    /// [P1-7] The extracted feedback region (`HomeSubviews.swift`): the
    /// optional-setup strip plus the live-caption/outcome surface.
    private var feedbackRegion: FeedbackRegion {
        FeedbackRegion(state: session.state,
                       caption: coordinator.livePartialTranscript ?? coordinator.lastTranscript,
                       outcome: coordinator.lastOutcome,
                       setup: homePresentation.setup,
                       onResumeSetup: {
                           // Same value the old direct read produced —
                           // now captured at tap so the cover stays
                           // stable while the wizard runs.
                           wizardStart = coordinator.onboardingState.firstPendingStep
                           showWizard = true
                       },
                       onOpenHistory: { showHistory = true },
                       onDismissOutcome: coordinator.dismissOutcome)
    }

    /// The error status line says what actually happened (spec §7) —
    /// permission guidance, audio-unavailable notice, or the generic
    /// re-prompt — instead of always claiming a misheard utterance.
    private var errorStatusText: String {
        let locale = coordinator.activeLocale
        switch coordinator.voiceErrorKind {
        case .permission:
            return L10n.str("state.error.permission", locale: locale)
        case .audioUnavailable:
            return L10n.str("state.error.audio", locale: locale)
        case .other:
            return L10n.str("state.error.status", locale: locale)
        }
    }

    /// Conversation-history affordance in Home's lower scroll flow. It
    /// remains close to the destination rail without overlaying setup or
    /// outcome cards. Shown only when history exists, no fresh outcome is
    /// already offering the sheet, and voice capture is not active.
    private var showsPinnedHistoryChip: Bool {
        guard coordinator.lastOutcome == nil,
              !coordinator.conversationHistory.isEmpty else { return false }
        switch session.state {
        case .idle, .speaking, .error, .stopped:
            return true
        case .listening, .transcribing, .understanding, .awaitingConfirmation,
             .awaitingSlotAnswer:
            // Both answer windows own the stage: no history chip while a
            // question is outstanding (T-135 follows the confirmation row).
            return false
        }
    }

    private var historyChip: some View {
        Button { showHistory = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DesignTokens.warmFont(size: 11, weight: .bold))
                Text("home.conversation.title")
                    .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize, weight: .semibold))
            }
            .foregroundColor(appearance.colors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Leaf routing

    @ViewBuilder
    private func leafView(for destination: LeafDestination) -> some View {
        switch destination {
        case .meds:
            MedicalView()
        case .reminders:
            RemindersView()
        case .calendar:
            CalendarView()
        case .call:
            CallView()
        case .history:
            HistoryView()
        case .settings:
            // [BOOT-REVIEW P0-1] The model-download service is injected
            // HERE (first relevance), not at the app root — Settings is
            // where its UI lives, and the lazy service must not be forced
            // before a download surface exists.
            SettingsView()
                .environmentObject(coordinator.modelDownloadService)
        case .profile:
            // The "About me" editor, pushed from the hub's profile icon
            // (home-profile-icon, 2026-10-06). The coordinator is passed
            // explicitly (its init contract — the view also reads it
            // from the environment for the locale/appearance it needs).
            ProfileSettingsView(coordinator: coordinator)
        case .directions:
            DirectionsView()
        case .briefing:
            BriefingView()
        case .updates:
            // The pushed Updates leaf (home-redesign v3): the bell in the
            // top bar opens it; the SAME registry instance Home's bell
            // badge reads is handed in, so the leaf's Notifications
            // section and the badge can never disagree.
            UpdatesScreen(registry: widgetRegistry)
        case .feed:
            // The Feed leaf (feed-agent task, 2026-09-08).
            FeedsView()
        case .alarms:
            // The Alarms & timers Settings leaf (updates-alarms task,
            // 2026-09-10): the Updates Alarms rows push it. It reads
            // the coordinator from the environment — no init params.
            AlarmsTimersSettingsView()
        }
    }
}

// MARK: - Talk button (spec §3.3, D5; redesign spec §2 — breathing glow)

struct TalkButton: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// [HERO-SIZE] (2026-10-14) The hero disc is ONE constant size in
    /// every state and at every Dynamic Type size: the spec's 132pt token
    /// (`DesignTokens.talkButtonDiameter`). The previous ScaledMetric grew
    /// the disc to 192pt at accessibility sizes — pushing the dock off
    /// the viewport at the medium accessibility size — and the
    /// per-state status line under the hero made the stage height read
    /// as "different button sizes" across states (owner feedback). The
    /// state caption now rides the stage's fixed sub-hero slot at
    /// accessibility sizes (see `TalkStage`), so the disc never needs to
    /// grow and never moves between states.
    private var heroDiameter: CGFloat { DesignTokens.talkButtonDiameter }
    private var usesGloss: Bool {
        appearance.style != .classic && !reduceTransparency && contrast != .increased
    }
    @ObservedObject var session: VoiceSessionStateMachine
    /// [AUDIO-REACTIVE-HERO] (2026-10-14) The live signal model the hero
    /// renders from — the owner's "the main button should bounce like a
    /// speaker … the side bars should move like a CD player's equalizer
    /// - not random but based on music". Observed here (like `session`):
    /// every ~30 Hz publish re-renders ONLY this button, never the stage
    /// above it (see TalkStage's `==` note). When `source` reports no
    /// real signal, every audio-driven branch below stands down and the
    /// existing [HERO-MOTION] idle/fallback motion takes over unchanged.
    @ObservedObject var audioLevels: AudioLevelPublisher
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// [HERO-STATES] True while any reply audio plays.
    let isSpeaking: Bool
    /// [HERO-STATES] True exactly while the auto-listen answer capture
    /// is live.
    let slotAnswerCaptureActive: Bool
    /// [P0-2] Manual Talk readiness — the shared `VoicePipelineReadiness`
    /// contract, and the hero's ONLY gate. `.loading` keeps the disc at
    /// its final dimensions with a spinner inside it and disables
    /// activation AND every recovery gesture (including the hold-to-reset);
    /// `.failed` shows one explanation plus one deterministic recovery;
    /// `.ready` is the normal hero. Wake-word status is deliberately not
    /// consulted — a degraded KWS engine never takes manual Talk down.
    let readiness: VoicePipelineReadiness
    let onTap: () -> Void
    /// Long-press reset (TALK-CRASH-FIX, 2026-09-07): holding the hero
    /// for `DesignTokens.talkResetHoldSeconds` cancels the talk cycle /
    /// re-primes a dead pipeline through the coordinator's reset path.
    /// Provided only for reset-eligible states (see
    /// `VoiceSessionState.supportsTalkReset`) — where it is nil the hero
    /// stays a plain tap target, and a long hold there still fires the
    /// tap on release exactly as it did before this feature.
    var onLongPressReset: (() -> Void)? = nil
    /// [P0-2] The ONE deterministic recovery a `.failed` boot-time start
    /// offers — an explicit control under the hero, so the hero's own tap
    /// can never double as an accidental recovery.
    var onRecover: (() -> Void)? = nil


    @State private var breathe = false
    /// True while a hold that CAN reset is underway (touch down, past the
    /// gesture's tracking start) — drives the hold hint + progress ring.
    @State private var isPressingForReset = false
    /// Ring fill 0...1, animated linearly so it completes exactly when the
    /// reset fires (nil while not pressing).
    @State private var holdProgress: Double?
    /// Backstop against the tap action ALSO firing on release after a
    /// successful hold: SwiftUI's long-press gesture normally wins the
    /// arena and cancels the button's own press, but this guard makes the
    /// "no double action" promise independent of gesture arbitration.
    @State private var suppressTapAfterReset = false
    /// [HERO-MOTION] (2026-10-14) One press-echo flag drives every
    /// "activated" acknowledgement in the owner's request ("add animation
    /// to the talk button when its activated and in active states"): the
    /// tap action AND each flip into an active state family both dip the
    /// disc to `discPulseScale` and spring it back (see
    /// `echoActivationPulse()`). Deliberately ONE flag, not one per
    /// trigger — a tap is followed a beat later by the `.listening` icon
    /// flip, and a shared echo merges those into one continuous
    /// press→release instead of two competing pulses.
    @State private var activationPulse = false
    /// [HERO-MOTION] The state glyph scales a little with Dynamic Type —
    /// at accessibility sizes it is the disc's ONLY content (the caption
    /// hides there), so the old fixed 32pt read small against the 132pt
    /// disc. The scaled size is capped (`heroIconPointSize`) so it can
    /// never crowd the constant disc; `heroDiameter` itself is untouched
    /// ([HERO-SIZE]: the hero never changes size between states).
    @ScaledMetric(relativeTo: .body) private var heroIconBaseSize: CGFloat = 32

    /// Single visual mapping for the hero (call-UI fix, 2026-09-07):
    /// icon, fill, halo, labels and motion all come from
    /// `VoiceSessionState.talkVisuals` — one switch over `session.state`
    /// — so the button can never render one state's color with another
    /// state's icon or label, and every element flips in the same
    /// transaction the state publishes.
    private var visuals: TalkStageVisuals {
        TalkStageVisuals.resolved(state: session.state,
                                  isSpeaking: isSpeaking,
                                  slotAnswerCaptureActive: slotAnswerCaptureActive)
    }

    private var isBreathing: Bool { visuals.pulses && !reduceMotion }

    /// [HERO-MOTION] The press echo's target: 0.94 while
    /// `activationPulse` is down, springing back to 1.0 (see
    /// `echoActivationPulse`). Reduce Motion pins the scale at 1.0 — the
    /// per-state colors and icon still flip, so the static fallback stays
    /// visually correct.
    private var discPulseScale: CGFloat {
        activationPulse && !reduceMotion ? 0.94 : 1.0
    }

    /// [HERO-MOTION] The Dynamic-Type-adaptive glyph size, capped so the
    /// constant 132pt disc can never overflow around it.
    private var heroIconPointSize: CGFloat {
        min(heroIconBaseSize, 48)
    }

    // MARK: Audio-reactive motion ([AUDIO-REACTIVE-HERO], 2026-10-14)

    /// The live envelope the disc bounce and the state-glyph breathing
    /// read — the owner's "the main button should bounce like a speaker
    /// when talking or when mic sound comes in". 0 under Reduce Motion:
    /// the static fallback is the correct state visuals with no
    /// signal-driven displacement.
    private var audioEnvelope: Double {
        reduceMotion ? 0 : audioLevels.envelope
    }

    /// True exactly while the published levels are REAL signal (mic
    /// capture, or a Piper reply with metering + its played-file band
    /// track — see `AudioLevelPublisher.Source`). The ONE gate between
    /// signal-driven motion and the [HERO-MOTION] fallback: the
    /// meterless speaker path (AVSpeechSynthesizer exposes no audio
    /// levels of any kind) and every non-audio state fall back to the
    /// existing motion — never a fabricated meter.
    private var hasLiveAudio: Bool {
        !reduceMotion && audioLevels.hasLiveSignal
    }

    /// The disc's speaker-cone bounce: scale = 1 + envelope x 0.06 (up
    /// to 1.06 — a cone's excursion, not a zoom), composed
    /// multiplicatively with the press echo. Applied via `scaleEffect`,
    /// so the constant 132pt frame, the stage layout and the button's
    /// hit region are untouched ([HERO-SIZE] invariant).
    private var discAudioScale: CGFloat {
        1 + 0.06 * audioEnvelope
    }

    /// The state glyph's envelope-driven breathing (owner follow-up:
    /// "the mic in the centre should also be animated when speaking").
    /// A gentle `scaleEffect` on the Image — never a font-size change,
    /// which would re-lay-out the content VStack inside the fixed disc —
    /// strongest for the mic during capture (0.15), softer for live
    /// reply playback (0.10), exactly 1 when no real signal flows
    /// (fallback / Reduce Motion). Max 48pt glyph x 1.15 = 55pt, well
    /// inside the 132pt disc.
    private var iconAudioScale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch audioLevels.source {
        case .mic: return 1 + 0.15 * audioLevels.envelope
        case .speakerLive: return 1 + 0.10 * audioLevels.envelope
        case .none, .speakerMeterless: return 1
        }
    }

    /// One side bar's live band level, 0…1 (owner: each bar moves "based
    /// on music" — the actual band energies, never a random walk). The
    /// five bars map straight onto `AudioLevelPublisher.bands`
    /// (200/400/800/1600/3200/6400 Hz edges — low→high, left→right on
    /// the left flank). The RIGHT flank is mirrored: its innermost bar
    /// (index 0) shows the HIGHEST band so the equalizer reads as one
    /// symmetric spectrum spreading outward from the disc, matching the
    /// mirrored idle stagger in `waveformSide`. Defensive `first`/`last`
    /// lookups collapse out-of-range reads onto the nearest band instead
    /// of crashing on an index — the publisher's band count is a service
    /// detail this view must not assume.
    private func bandLevel(index: Int, mirrored: Bool) -> Double {
        let bands = audioLevels.bands
        guard !bands.isEmpty else { return 0 }
        let bandIndex = mirrored ? bands.count - 1 - index : index
        guard bands.indices.contains(bandIndex) else {
            // bandIndex < 0 only if the publisher ever grows MORE bands
            // than the five bars; the nearest band is the honest edge.
            return bandIndex < 0 ? bands[bands.startIndex] : bands[bands.index(before: bands.endIndex)]
        }
        return bands[bandIndex]
    }

    /// The [AUDIO-REACTIVE-HERO] equalizer range for one side bar, as a
    /// y-scale of its published capsule height
    /// (`heroDiameter * 0.28 * waveformHeights[index]`). Min 0.30 so a
    /// quiet band still reads as a present bar (never a vanishing
    /// capsule — elderly-legibility over meter realism); max 1.55 so
    /// the tallest bar at full band energy stays inside the overlay's
    /// fixed height. Applied via `scaleEffect(y:)` like the idle
    /// oscillation — no layout ever moves.
    private static let audioBarMinScale: CGFloat = 0.30
    private static let audioBarMaxScale: CGFloat = 1.55

    /// [HERO-MOTION] Fires the shared press echo: a quick easeOut
    /// down-stroke to `discPulseScale`, a ~one-frame beat, then a springy
    /// return. This is the owner's "tap → 0.94 → 1.0". The beat is a
    /// short-lived main-actor task rather than a
    /// `repeatCount(1, autoreverses: true)` toggle so the two edges get
    /// DIFFERENT curves (fast press, softer overshooting release), and so
    /// a re-trigger mid-flight (tap, then the `.listening` flip a beat
    /// later) simply extends the same press — the last restore always
    /// lands, so the disc can never stick at 0.94. No-op under Reduce
    /// Motion.
    private func echoActivationPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.10)) { activationPulse = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 110_000_000)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                activationPulse = false
            }
        }
    }

    /// [HERO-MOTION] The side bars' motion family — the owner's "vary
    /// amplitude/tempo by state family: gentle at idle, livelier while
    /// listening/transcribing/understanding/speaking, static at
    /// error/stopped/loading". Derived from the SAME `TalkStageVisuals`
    /// flags the rest of the stage reads (never a bespoke state switch),
    /// so a family's bars can never disagree with its rings or halo.
    /// `.lively` is exactly the listening→speaking cycle (`showsHalo`);
    /// `.gentle` the idle family (`pulses`); everything else — error,
    /// stopped, the chip-owned confirmation, loading, a failed start, and
    /// the reset hold — stays perfectly still.
    private var waveformRhythm: WaveformRhythm {
        guard !isLoading, failure == nil, !isPressingForReset else {
            return .still
        }
        if visuals.showsHalo { return .lively }
        if visuals.pulses { return .gentle }
        return .still
    }

    /// [P0-2] The pipeline start is still in flight — the hero shows its
    /// loading presentation and every activation/recovery affordance is
    /// off.
    private var isLoading: Bool { readiness.isLoading }

    /// [P0-2] The pipeline's boot-time start failed; the hero shows one
    /// explanation and one recovery.
    private var failure: VoiceStartupFailure? { readiness.failure }

    /// Disabled unless the pipeline's own start callback succeeded AND
    /// the [LAT-M1] boot contract settled (ready OR degraded — a
    /// degraded hero is ENABLED with an honest cold-feature banner, never
    /// silently), plus the confirmation window's own case (the yes/no
    /// chips own that turn): while loading (or failed) the hero is inert
    /// — the reset hold is not even attached, so a hold cannot reach the
    /// reset path while the review's "cannot invoke recovery merely
    /// because startup has not completed" rule applies. The slot answer
    /// window deliberately does NOT disable the hero: it is answered by
    /// voice through the Talk control (device defect fix 2026-10-11 —
    /// the window had no chips, no auto-listen and a dead Talk button).
    private var isDisabled: Bool {
        !readiness.isTalkEnabled
            || !session.state.supportsTalkTap
    }

    /// Idle and startup use the supplied glossy burgundy VoiceBridge face.
    /// Runtime work/speaking/error states retain their semantic colors.
    private var usesBrandFace: Bool {
        isLoading || session.state == .idle
    }

    private var discTint: Color {
        if failure != nil { return DesignTokens.stateError }
        return usesBrandFace ? appearance.colors.talkMid : visuals.tint
    }

    private var discFill: AnyShapeStyle {
        guard usesBrandFace && usesGloss else { return AnyShapeStyle(discTint) }
        return AnyShapeStyle(RadialGradient(
            colors: [appearance.colors.talkHighlight,
                     appearance.colors.talkMid,
                     appearance.colors.talkDeep],
            center: UnitPoint(x: 0.27, y: 0.19),
            startRadius: 0,
            endRadius: heroDiameter * 0.72))
    }

    private var heroGlowTint: Color {
        usesBrandFace ? appearance.colors.brandPink : visuals.tint
    }

    /// The hold-to-reset affordance is live only in a reset-eligible state,
    /// with a reset action provided AND a ready pipeline — a loading or
    /// failed hero never offers it ([P0-2]).
    private var resetHoldable: Bool {
        onLongPressReset != nil
            && session.state.supportsTalkReset
            && readiness == .ready
    }

    var body: some View {
        // The decorative halo gets real layout clearance before any status text.
        VStack(spacing: 12) {
            Button(action: {
                // The reset backstop (see `suppressTapAfterReset`): after
                // a completed hold the release must not ALSO run the tap
                // action. Quick taps and sub-threshold holds never set the
                // flag and are unaffected.
                guard !suppressTapAfterReset else { return }
                onTap()
                // [HERO-MOTION] Press echo (see `echoActivationPulse`):
                // the tap dips the disc to 0.94 and springs it back. Kept
                // inside the backstop guard — a completed reset hold must
                // not echo a tap it never fired.
                echoActivationPulse()
            }) {
                ZStack {
                    // While a reset hold is underway the breathing rings
                    // stand down (the arc below is the motion that
                    // matters); they return on release. [P0-2] they stand
                    // down unless the pipeline is live too — a loading or
                    // failed hero does not breathe. [LAT-M1] A DEGRADED
                    // hero is live (enabled + banner), so it breathes.
                    if isBreathing && !isPressingForReset && readiness.isTalkEnabled {
                        breathingRings
                    }
                    if usesBrandFace && usesGloss && !isPressingForReset {
                        brandGlassRings
                    }
                    if visuals.showsHalo && !isPressingForReset {
                        // Steady state-color halo through every mid-cycle
                        // state (listening → transcribing → understanding
                        // → speaking). The ring used to drop out for
                        // transcribing/understanding and pop back at
                        // speaking — the hero visibly "shrank" mid-turn
                        // (call-UI fix, 2026-09-07).
                        Circle()
                            .stroke(heroGlowTint.opacity(0.30), lineWidth: 10)
                            .frame(width: heroDiameter + 28,
                                   height: heroDiameter + 28)
                            // [HERO-MOTION] The halo glides to the new
                            // family's color instead of snapping when the
                            // state flips; keyed on the color it paints.
                            // Under Reduce Motion the flip stays instant
                            // (nil animation) — still the correct color.
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),
                                       value: heroGlowTint)
                    }
                    // Idle crimson is decorative, not an error. Runtime
                    // states retain their invariant traffic-light fills.
                    Circle()
                        .fill(discFill)
                        .frame(width: heroDiameter,
                               height: heroDiameter)
                        .shadow(color: discTint.opacity(usesGloss ? 0.34 : 0.10), radius: usesGloss ? 16 : 3, y: usesGloss ? 7 : 1)
                        // [HERO-MOTION] The disc's fill + glow crossfade
                        // between state families instead of snapping.
                        // Keyed on `discTint` — the color this element
                        // actually paints (`visuals.tint` folded with the
                        // brand face and the failure override) — so every
                        // tint change that can reach the disc animates.
                        // Placed BEFORE the overlays so it never re-times
                        // the icon transition or the press echo below.
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),
                                   value: discTint)
                        .overlay(heroContent)
                        .overlay {
                            if appearance.skin.isDark {
                                Circle().stroke(appearance.colors.textPrimary.opacity(0.65), lineWidth: 1.5)
                            }
                        }
                        // [HERO-MOTION] The press echo (tap + active-state
                        // flips): the whole disc — glyph included —
                        // briefly dips to 0.94 and springs back. Applied
                        // OUTSIDE the tint animation above so the echo's
                        // own withAnimation curves are never intercepted.
                        // `scaleEffect` is a render transform: the disc's
                        // 132pt frame, the stage layout and the button's
                        // hit region are all untouched.
                        //
                        // [AUDIO-REACTIVE-HERO] (2026-10-14) Composed
                        // multiplicatively with the live speaker-cone
                        // bounce (`discAudioScale` = 1 + envelope x 0.06):
                        // the tap echo and the audio excursion stack, and
                        // the spring below retargets the disc smoothly
                        // through every ~30 Hz publish. Reduce Motion
                        // zeroes the audio factor and the spring is nil —
                        // the echo alone remains, as before.
                        .scaleEffect(discPulseScale * discAudioScale, anchor: .center)
                        .animation(reduceMotion ? nil
                                   : .spring(response: 0.14, dampingFraction: 0.7),
                                   value: audioEnvelope)
                    if isPressingForReset {
                        resetProgressRing
                    }
                }
                // [HERO-MOTION] Every flip INTO an active family (the
                // `.listening` that follows a tap, then
                // transcribing/understanding/speaking) gets the same soft
                // echo a tap gets, so the disc acknowledges the pipeline
                // advancing. Icon-keyed on purpose: each of those flips
                // changes `visuals.icon` in the same transaction the
                // state publishes. Error/stopped and the idle wind-down
                // change the icon too but are NOT active (`showsHalo`
                // false) — deliberately calm.
                .onChange(of: visuals.icon) { _ in
                    guard visuals.showsHalo else { return }
                    echoActivationPulse()
                }
                // [HERO-MOTION] The state halo and breathing rings fade
                // in/out with the family flip (their `if` inserts/removals
                // carry the default opacity transition) instead of
                // popping. Keyed on `showsHalo` so it fires exactly on
                // the family boundary and never on intra-family flips.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),
                           value: visuals.showsHalo)
                // The disc remains the same size; external padding reserves
                // space for the decorative halo and symmetric waveforms.
                .frame(width: heroDiameter,
                       height: heroDiameter)
            }
            .buttonStyle(.plain)
            // Enabled only once the pipeline's start callback succeeded
            // (and not while the yes/no chips own the UI): a ready hero
            // keeps every existing affordance — tapping mid-cycle cancels
            // and recycles, tapping after a runtime error retries. [P0-2]
            // While loading or failed the hero is disabled (plain button
            // style does not dim on its own), and it is deliberately NOT
            // opacity-dimmed either: the disc stays at FULL state color
            // with white glyphs (≥4.5:1, unit tested), and the loading
            // state is carried by the white spinner + localized label
            // inside the disc. Greying the whole hero made the white text
            // unreadable (user feedback, 2026-09-11).
            .disabled(isDisabled)
            .accessibilityIdentifier("home.talk")
            .accessibilityLabel(Text(TalkReadinessCopy.accessibilityLabel(
                readiness,
                stateLabel: session.state.buttonText(locale: locale),
                locale: locale)))
            // The hold-to-reset gesture + VoiceOver hint are ENABLED only
            // in reset-eligible states. An always-LIVE long press would
            // swallow the tap on holds ≥ `talkResetHoldSeconds` in
            // .speaking too — changing the "hold to stop the reply" tap
            // that users rely on today (TALK-CRASH-FIX, 2026-09-07).
            // The modifier itself is attached unconditionally and gates
            // its gestures from the inside (`GestureMask`), so flipping
            // eligibility never changes the hero's view type — the old
            // `.if(resetHoldable, …)` swapped the subtree's type and
            // rebuilt everything under the disc on every state change.
            .modifier(ResetHoldAffordance(
                isEnabled: resetHoldable,
                holdSeconds: DesignTokens.talkResetHoldSeconds,
                // 40pt finger travel before the hold is abandoned — far
                // more forgiving than the 10pt default for unsteady
                // hands, well inside the hero + halo's 160pt footprint.
                maxDistance: 40,
                accessibilityHint: L10n.str("voice.resetA11y", locale: locale),
                onReset: {
                    // Re-check at fire time: the session may have moved
                    // since the hold began (e.g. a router utterance
                    // flipped it to .speaking mid-hold).
                    guard session.state.supportsTalkReset else { return }
                    suppressTapAfterReset = true
                    onLongPressReset?()
                },
                onPressingChanged: handleHoldPressing(_:)
            ))
            .overlay {
                HStack(spacing: 0) {
                    // [HERO-MOTION] Mirrored phase order: the two flanks
                    // share the tempo tables but stagger in opposite
                    // directions, so the waveform reads as travelling
                    // through the disc rather than two copies pumping in
                    // lockstep. Geometry is untouched — still the same
                    // fixed overlay frame, zero layout change.
                    waveformSide(mirrored: false)
                    Spacer().frame(width: heroDiameter + 24)
                    waveformSide(mirrored: true)
                }
                .frame(width: heroDiameter + 78, height: heroDiameter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 39)
            // [HERO-SIZE] Slimmer vertical reserve than the old 32pt: the
            // disc is 132pt constant now, and every saved point goes to
            // fitting the stage + dock in the viewport without scrolling.
            // [MEDIUM-FIT] (2026-10-15) 16pt at ordinary type sizes
            // (still clears the hero's 160pt halo footprint), 20pt at
            // accessibility sizes.
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 20 : 16)
            if !transientStatusLine.isEmpty {
                Text(transientStatusLine)
                    .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                weight: .medium))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // [P0-2] The ONE recovery a failed boot-time start offers —
            // and only then. It replaces the old "tap the dead hero to
            // retry" path, which could not distinguish "not ready yet"
            // from "failed".
            if failure != nil, let onRecover {
                recoveryAction(onRecover)
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else {
                breathe = false
                return
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    /// [HERO-MOTION] The state-icon swap, per the owner's "animate and
    /// move the icons inside the talk button for different states". The
    /// outgoing glyph lifts (+ scale 1.3) while the incoming one rises
    /// into place from below (scale 0.7 → 1) — a fixed "advancing"
    /// direction that matches the idle → listening → … → speaking flow
    /// the pipeline actually runs. Chosen over `matchedGeometryEffect`
    /// deliberately: that would need BOTH glyphs co-resident in a
    /// ZStack plus a `@Namespace`; this asymmetric transition gives the
    /// same movement with one view and no extra state to keep coherent
    /// through rapid listening → transcribing → understanding flips.
    private var heroIconTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.7)
                .combined(with: .opacity)
                .combined(with: .offset(y: 9)),
            removal: .scale(scale: 1.3)
                .combined(with: .opacity)
                .combined(with: .offset(y: -9)))
    }

    /// The disc's content ([P0-2]). While the pipeline start is in flight
    /// the hero shows a `ProgressView` and the localized stage label
    /// INSIDE the disc; otherwise it shows the live state's icon and
    /// caption. Both branches sit inside the same fixed-size circle, so
    /// the hero's final dimensions never move with readiness.
    private var heroContent: some View {
        VStack(spacing: 10) {
            if isLoading {
                // [LOADING-CONTRAST] (2026-09-11) The loading disc is the
                // SOLID rest blue (`discTint` above — the accepted darker-
                // background fix for the "light grey speak button"
                // feedback), so the spinner stays WHITE: white on
                // `stateIdle` #3B6EA5 measures ≈5.3:1, while the dark
                // `textPrimary` #3D2F24 would drop to ≈3.0:1. `.large`
                // control size makes the spinner itself clearly visible
                // instead of the default small wheel.
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                // The stage label is essential localized text: it wraps
                // rather than shrinking (≥18pt caption token, no
                // `minimumScaleFactor`), and bold keeps it clearly legible
                // on the solid disc.
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(loadingStageLabel)
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22)
                }
            } else {
                // [HERO-MOTION] The glyph is Dynamic-Type-adaptive now
                // (`heroIconPointSize`, capped at 48pt) because at
                // accessibility sizes it is the disc's only content.
                // `.id(visuals.icon)` gives each state's icon its own
                // identity — the trigger the asymmetric transition above
                // needs — while states that share a glyph (listening and
                // the slot-answer window) correctly swap with no
                // animation at all.
                Image(systemName: visuals.icon)
                    .font(.system(size: heroIconPointSize))
                    // [AUDIO-REACTIVE-HERO] (2026-10-14) The state glyph
                    // breathes with the live envelope (owner follow-up:
                    // "the mic in the centre should also be animated when
                    // speaking") — a `scaleEffect` render transform, NOT
                    // a font-size change, so the fixed 132pt disc and the
                    // content VStack's layout never shift. Static 1 under
                    // Reduce Motion and whenever no real signal flows.
                    .scaleEffect(iconAudioScale, anchor: .center)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.14, dampingFraction: 0.7),
                               value: audioEnvelope)
                    .id(visuals.icon)
                    .transition(heroIconTransition)
                // The state caption is essential localized text ("I'm
                // ready" / Nepali), so it WRAPS to a second line instead
                // of shrinking: `minimumScaleFactor(0.7)` could render
                // longer Nepali strings at ~14pt, under the 18pt floor
                // this audience needs.
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(session.state.buttonText(locale: locale))
                        .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22)
                }
            }
        }
        .foregroundStyle(.white)
        // [HERO-MOTION] The transition's animation context: placed on the
        // VStack (OUTSIDE the loading if/else, per the transition
        // placement rule) so the swap is driven by the icon change
        // itself. Reduce Motion passes nil — an instant swap, and the
        // per-state glyph/color still render correctly.
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7),
                   value: visuals.icon)
    }

    /// [P0-2] The in-hero loading label for the current stage.
    private var loadingStageLabel: String {
        guard case .loading(let stage) = readiness else { return "" }
        return TalkReadinessCopy.loadingLabel(stage, locale: locale)
    }

    /// [P0-2] The one deterministic recovery for a failed boot-time start:
    /// a labeled control under the hero's status line, at the practical
    /// ≥52pt target size this age group gets everywhere else on Home.
    private func recoveryAction(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                Text(TalkReadinessCopy.failureRecovery(locale: locale))
                    .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                weight: .semibold))
            }
            .foregroundStyle(appearance.colors.accentForeground)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// Only exceptional information lives outside the button: reset-hold
    /// guidance or an actionable startup failure. Steady-state status
    /// (error/stopped captions) renders in the stage's FIXED sub-hero
    /// slot ([HERO-SIZE], 2026-10-14) so a state flip never changes the
    /// layout height around the hero — the owner's "button size must be
    /// consistent across states" rule.
    private var transientStatusLine: String {
        if isPressingForReset {
            return L10n.str("voice.resetHold", locale: locale)
        }
        if isLoading { return "" }
        if let failure {
            return TalkReadinessCopy.failureExplanation(failure, locale: locale)
        }
        return ""
    }

    /// Long-press tracking (called on main): arms the hold hint + ring
    /// while the finger is down, clears everything on release, and
    /// re-arms the tap action for the next touch. Guarded on
    /// `resetHoldable` — the gesture is only attached in eligible states,
    /// but the guard keeps the state coherent if a state change races
    /// the callbacks.
    private func handleHoldPressing(_ pressing: Bool) {
        guard resetHoldable else { return }
        if pressing {
            isPressingForReset = true
            suppressTapAfterReset = false
            holdProgress = 0
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: DesignTokens.talkResetHoldSeconds)) {
                holdProgress = 1
            }
        } else {
            isPressingForReset = false
            holdProgress = nil
            suppressTapAfterReset = false
        }
    }

    /// The hold-to-reset arc (TALK-CRASH-FIX, 2026-09-07): a white
    /// progress ring just outside the hero rim, filling over
    /// `talkResetHoldSeconds` so it completes at the moment the reset
    /// fires. Skipped under `accessibilityReduceMotion` — the hero's
    /// color flip into the stopped pass-through is the feedback there,
    /// and the hold hint still appears on the status line.
    @ViewBuilder
    private var resetProgressRing: some View {
        if !reduceMotion {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(holdProgress ?? 0, 1))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: heroDiameter + 16,
                   height: heroDiameter + 16)
        }
    }

    /// Static frosted annuli around the branded idle/startup face. State
    /// text and color still carry meaning when Reduce Motion is enabled.
    private var brandGlassRings: some View {
        ZStack {
            Color.clear
                .frame(width: heroDiameter + 26, height: heroDiameter + 26)
                .appSurface(role: .control, cornerRadius: (heroDiameter + 26) / 2)
            Circle()
                .stroke(appearance.colors.brandBlush.opacity(0.72), lineWidth: 2)
                .frame(width: heroDiameter + 52, height: heroDiameter + 52)
        }
        .shadow(color: appearance.colors.brandBlush.opacity(0.55), radius: 18)
    }

    private var breathingRings: some View {
        ZStack {
            Circle()
                .stroke(heroGlowTint.opacity(breathe ? 0.05 : 0.35), lineWidth: 2)
                .frame(width: breathe ? heroDiameter + 32 : heroDiameter + 20,
                       height: breathe ? heroDiameter + 32 : heroDiameter + 20)
            Circle()
                .stroke(heroGlowTint.opacity(breathe ? 0.02 : 0.22), lineWidth: 2)
                .frame(width: breathe ? heroDiameter + 56 : heroDiameter + 40,
                       height: breathe ? heroDiameter + 56 : heroDiameter + 40)
        }
    }

    // MARK: Side-bar waveform ([HERO-MOTION], 2026-10-14)

    /// The side bars' motion family (see `waveformRhythm`). Owner: "the
    /// side bars should be animated as well … vary amplitude/tempo by
    /// state family".
    private enum WaveformRhythm: Equatable {
        case still
        case gentle
        case lively
    }

    /// Everything one capsule needs to oscillate: its scale bounds and
    /// the looping animation's tempo + phase.
    private struct WaveformBarSpec {
        let low: CGFloat
        let high: CGFloat
        let duration: Double
        let delay: Double
    }

    /// The single Equatable key every bar's `.animation(_:value:)` watches
    /// — started (`breathe`, the SAME flag the breathing rings ride) PLUS
    /// the rhythm. Bundling both means a state-family flip also animates
    /// through the looping modifier (springboard: the amplitude/tempo
    /// change glides from the current render value) instead of snapping.
    /// [AUDIO-REACTIVE-HERO] (2026-10-14) `audioLevel` was added: the
    /// LIVE band level this particular bar is rendering (0 while not
    /// audio-driven). Watching it makes each ~30 Hz publish retarget the
    /// bar's existing animation toward its new level — continuous
    /// equalizer motion, and because the key is per-bar, adjacent bars
    /// are fully decoupled.
    private struct WaveformMotionKey: Equatable {
        let breathe: Bool
        let rhythm: WaveformRhythm
        let audioLevel: Double
    }

    /// The per-bar key: the family values, plus THIS bar's live band
    /// level while real signal flows. Each bar watches its own level, so
    /// one publish retargets five independent animations — the
    /// adjacent-bars-decoupled equalizer the owner asked for. Without
    /// live audio every bar's key collapses to the same family value, so
    /// state flips retarget exactly as before this feature.
    private func waveformBarKey(index: Int, mirrored: Bool) -> WaveformMotionKey {
        WaveformMotionKey(breathe: breathe,
                          rhythm: waveformRhythm,
                          audioLevel: hasLiveAudio
                              ? bandLevel(index: index, mirrored: mirrored) : 0)
    }

    /// Decorative reference waveforms, not fabricated live audio levels.
    private static let waveformHeights: [CGFloat] = [0.35, 0.65, 1.0, 0.75, 0.45]
    /// Calm idle tempos (seconds per half-cycle), one per capsule —
    /// parallel to `waveformHeights`. Deliberately non-uniform: unequal
    /// durations keep the five bars permanently out of phase without
    /// anyone driving a clock.
    private static let waveformGentleTempo: [Double] = [1.90, 1.60, 1.45, 1.75, 2.05]
    /// Brisk tempos for the listening→speaking families.
    private static let waveformLivelyTempo: [Double] = [1.05, 0.85, 0.70, 0.95, 1.15]

    /// The scale range + tempo one capsule oscillates over. `weight` leans
    /// on the published height array so taller bars swing a little
    /// further — the way a real level meter reads — and `phase` orders
    /// the stagger (reversed on the right flank, see `waveformSide`).
    private func waveformBarSpec(index: Int, mirrored: Bool) -> WaveformBarSpec {
        let weight = 0.5 + 0.5 * Self.waveformHeights[index]
        let phase = Double(mirrored ? Self.waveformHeights.count - 1 - index : index)
        switch waveformRhythm {
        case .still:
            // No oscillation at all — the bars hold their published
            // heights exactly (error / stopped / loading / reset hold).
            return WaveformBarSpec(low: 1, high: 1, duration: 0.35, delay: 0)
        case .gentle:
            return WaveformBarSpec(low: 1 - 0.12 * weight,
                                   high: 1 + 0.16 * weight,
                                   duration: Self.waveformGentleTempo[index],
                                   delay: 0.05 * phase)
        case .lively:
            return WaveformBarSpec(low: 1 - 0.30 * weight,
                                   high: 1 + 0.34 * weight,
                                   duration: Self.waveformLivelyTempo[index],
                                   delay: 0.03 * phase)
        }
    }

    /// The current scale target for one bar. `scaleEffect(y:)` is a render
    /// transform — the capsule's frame (the only layout the fixed overlay
    /// depends on) never changes, so the hero geometry stays constant.
    /// [AUDIO-REACTIVE-HERO] With LIVE signal the target is this bar's
    /// band level mapped across the equalizer range — the "CD player
    /// equalizer, based on music" the owner asked for; adjacent bars
    /// decouple because each reads its own band. The branch deliberately
    /// comes before the breathe/parity oscillation: real meter data, not
    /// a random walk, while sound flows. `.still` rhythm (error/stopped/
    /// loading/reset-hold families) keeps holding the published heights
    /// even if a release tail is still decaying — the settled state
    /// presentation wins.
    ///
    /// Fallback (no live signal): adjacent bars move in OPPOSITE
    /// directions (even indices rise while odd indices fall, then swap)
    /// — a real meter never pumps in unison, and this keeps the
    /// antiphase permanent instead of only during the first cycle. The
    /// spec's `.delay` stays short because SwiftUI applies a repeating
    /// animation's delay on EVERY cycle: it is there to break the
    /// initial lockstep, not to gate the loop.
    private func waveformBarScale(index: Int, mirrored: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        if hasLiveAudio, waveformRhythm != .still {
            let level = CGFloat(bandLevel(index: index, mirrored: mirrored))
            return Self.audioBarMinScale
                + (Self.audioBarMaxScale - Self.audioBarMinScale) * level
        }
        let spec = waveformBarSpec(index: index, mirrored: false)
        let risesFirst = index.isMultiple(of: 2)
        if breathe { return risesFirst ? spec.high : spec.low }
        return risesFirst ? spec.low : spec.high
    }

    /// The looping animation for one bar: easeInOut forever, per-index
    /// tempo + phase. `nil` under Reduce Motion — the static fallback is
    /// every bar at its exact published height — and a plain settle ease
    /// while `.still` (so a flip back to error/stopped settles smoothly
    /// instead of restarting a loop). [AUDIO-REACTIVE-HERO] With LIVE
    /// signal: a short easeOut to each new band level, fired by that
    /// bar's own key change. Held brief on purpose — the analyzer's
    /// attack/release ballistics already do the musical smoothing, so a
    /// longer view curve would double-smooth and visibly lag the audio;
    /// each ~30 Hz publish retargets the in-flight ease from wherever
    /// the bar currently renders.
    private func waveformBarAnimation(index: Int, mirrored: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        guard waveformRhythm != .still else {
            return .easeInOut(duration: 0.35)
        }
        if hasLiveAudio {
            return .easeOut(duration: 0.12)
        }
        let spec = waveformBarSpec(index: index, mirrored: mirrored)
        return .easeInOut(duration: spec.duration)
            .repeatForever(autoreverses: true)
            .delay(spec.delay)
    }

    /// The two static capsule groups flanking the disc, animated per the
    /// owner's "the side bars should be animated as well" — and, with
    /// live signal, per "the side bars should move like a CD player's
    /// equalizer - not random but based on music". Each capsule scales
    /// around its published height
    /// (`heroDiameter * 0.28 * waveformHeights[index]`) via
    /// `scaleEffect(y:)` — a transform, never a relayout. TWO drivers,
    /// picked per frame by `hasLiveAudio`: real band levels via the
    /// per-bar `.animation(value:)` key (each publish retargets), or the
    /// fallback oscillation riding the SAME `breathe` flag the breathing
    /// rings use (one animation driver, per-bar curves via
    /// `waveformBarSpec`). Everything stays inside the existing overlay
    /// frame.
    private func waveformSide(mirrored: Bool) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Self.waveformHeights.indices, id: \.self) { index in
                Capsule()
                    .fill(appearance.colors.accentForeground.opacity(appearance.skin.isDark ? 0.75 : 0.48))
                    .frame(width: 3, height: heroDiameter * 0.28 * Self.waveformHeights[index])
                    .scaleEffect(y: waveformBarScale(index: index, mirrored: mirrored), anchor: .center)
                    .animation(waveformBarAnimation(index: index, mirrored: mirrored),
                               value: waveformBarKey(index: index, mirrored: mirrored))
            }
        }
    }
}

// MARK: - Hold-to-reset affordance (TALK-CRASH-FIX, 2026-09-07)

/// Attaches the Talk hero's hold-to-reset long press AND its VoiceOver
/// hint in one modifier. The modifier is applied UNCONDITIONALLY; its
/// gestures are switched on and off from the inside via `GestureMask`
/// (`isEnabled`), so an eligibility flip never changes the hero's view
/// type. The previous `.if(resetHoldable, ResetHoldAffordance(…))`
/// returned one type when eligible and another when not, so every
/// .idle ⇄ .speaking flip tore down and rebuilt the whole talk-stage
/// subtree instead of just re-rendering it.
///
/// Conditional ENABLEMENT still matters, exactly as before: in
/// non-reset states (.speaking, .awaitingConfirmation) the hero must
/// stay a plain tap target — a live long press would swallow the tap on
/// holds ≥ `talkResetHoldSeconds` there, changing the "hold to stop the
/// reply" behavior users rely on today. With `.none` no recognizer is
/// installed at all, which is the old "modifier not attached" state.
private struct ResetHoldAffordance: ViewModifier {
    /// The call site's `resetHoldable`: when false, neither gesture is
    /// installed and the hint is cleared.
    let isEnabled: Bool
    let holdSeconds: TimeInterval
    let maxDistance: CGFloat
    let accessibilityHint: String
    let onReset: () -> Void
    let onPressingChanged: (Bool) -> Void

    /// True from touch-down until the hold ends (reset fired, finger
    /// released, or the finger travelled past `maxDistance`). The
    /// end-of-hold notification fires exactly once per touch.
    @State private var isPressing = false
    /// Latches when this touch travels past `maxDistance`: the long press
    /// has failed for good (a recognizer does not re-arm mid-touch), so
    /// the ring must not restart if the finger wanders back inside the
    /// radius. Cleared on touch-up, for the next touch.
    @State private var hasMovedTooFar = false

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: holdSeconds, maximumDistance: maxDistance)
                    .onEnded { _ in
                        // Stand the hold tracking down BEFORE the reset,
                        // so the caller's status line has already left
                        // the hold hint when the reset publishes.
                        endPress()
                        onReset()
                    },
                including: gestureMask
            )
            .simultaneousGesture(
                // Touch-down/release tracking for the hold hint + the
                // progress arc (the long press itself only speaks on
                // success). Simultaneous, so the hero's own tap is
                // unaffected; the arc stands down as soon as the finger
                // travels past `maxDistance`, mirroring the long press's
                // own failure rule, so it is never seen filling for a
                // hold that cannot fire.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !hasMovedTooFar else { return }
                        let travelled = hypot(value.translation.width,
                                              value.translation.height)
                        if travelled > maxDistance {
                            hasMovedTooFar = true
                            endPress()
                        } else if !isPressing {
                            beginPress()
                        }
                    }
                    .onEnded { _ in
                        hasMovedTooFar = false
                        endPress()
                    },
                including: gestureMask
            )
            .accessibilityHint(Text(isEnabled ? accessibilityHint : ""))
            // A hold in flight when eligibility flips — a router utterance
            // turned .listening into .speaking mid-hold — has its gestures
            // detached by the mask, so no release callback can arrive:
            // tear the tracking down here instead of leaving the hint and
            // the arc stuck on screen.
            .onChange(of: isEnabled) { enabled in
                guard !enabled else { return }
                endPress()
            }
    }

    /// `.none` installs no recognizer — the pre-`.if` "not attached"
    /// state, which keeps the hero a plain tap target.
    private var gestureMask: GestureMask { isEnabled ? .all : .none }

    private func beginPress() {
        isPressing = true
        onPressingChanged(true)
    }

    private func endPress() {
        guard isPressing else { return }
        isPressing = false
        onPressingChanged(false)
    }
}

// MARK: - Confirmation chips (spec §3.3 — awaitingConfirmation)

/// Big yes/no chips shown instead of the Talk button while a medication
/// confirmation challenge is outstanding. Voice still works too — the
/// router routes the next transcript as a yes/no answer.
///
/// Redesign spec §3.1 "confirm what I heard": the actual challenge prompt
/// (already spoken via `CommandRouter.speak(text:)`, which already stores
/// it in `lastAssistantReply`) is shown here so the user can SEE what
/// they're confirming, not just hear it — no new pipeline data needed.
///
/// `titleKey` heads the card. The head used to be the medication status
/// line ("Did you take your medicine?") for EVERY challenge kind
/// (call-UI fix, 2026-09-07): call and rephrase confirmations rendered
/// that meds question above their own prompt, and the medication flow
/// asked the question twice — once in the title and again in the spoken
/// prompt row below. The title is now the neutral "Please confirm"
/// frame; the kind-specific question always comes from the prompt row.
/// The yes/no chip's half of the confirmation-speech contract.
///
/// [APP-LAUNCHER F2] The generic "Okay, marked as taken" / "Okay, I won't
/// mark it" catalog text is MEDICATION-flavored. It is correct for a dose
/// challenge and wrong for every other flow that shares the confirmation
/// window — a call, a navigation disambiguation, a calendar write, an app
/// launch — because each of those speaks its own honest outcome from
/// `AppCoordinator.handleConfirmationResponse`, and the generic line would
/// both contradict it and claim a dose was recorded.
///
/// The voice path has known this since the call-confirmation fix
/// (`CommandRouter.route`'s `speaksItsOwnYesNo`); the chip knew only about
/// calls. Rather than repeat the list a second time in a second file, the
/// decision is expressed once, here, as a pure value — the same shape the
/// router uses, so the two can be read side by side, and so it is testable
/// without a screen. The chip and the router must be changed together.
struct ConfirmationChipSpeech {
    /// Which confirmation the window currently belongs to. All four are
    /// read from the coordinator BEFORE `handleConfirmationResponse`,
    /// which clears them as it handles the answer.
    struct Flags: Equatable {
        var isCall: Bool = false
        var isNavigationDisambiguation: Bool = false
        var isCalendarEvent: Bool = false
        var isAppLaunch: Bool = false

        init(isCall: Bool = false,
             isNavigationDisambiguation: Bool = false,
             isCalendarEvent: Bool = false,
             isAppLaunch: Bool = false) {
            self.isCall = isCall
            self.isNavigationDisambiguation = isNavigationDisambiguation
            self.isCalendarEvent = isCalendarEvent
            self.isAppLaunch = isAppLaunch
        }

        /// True when the flow owns its own words.
        var speaksForItself: Bool {
            isCall || isNavigationDisambiguation || isCalendarEvent || isAppLaunch
        }
    }

    /// Whether the chip may follow up with the generic catalog line. The
    /// medication challenge is the only flow left that needs it.
    static func speaksGenericYesNo(_ flags: Flags) -> Bool { !flags.speaksForItself }

    /// [APP-UI-CONFIRM] (2026-10-14) The chip LABEL keys for the flow that
    /// currently owns the window. The launch flow renames its chips —
    /// "Open" / "Cancel" (`launcher.chipOpen` / `launcher.chipCancel`,
    /// en+ne) — for the owner's report, verbatim: the curated-bar launch
    /// "shows english dialog confirmation. change that to also use custom
    /// UI instead of native using corresponding components." Under a
    /// localized prompt ("Should I open ह्वाट्सएप?"), a generic Yes/No pair
    /// reproduces the native sheet's language problem in our own surface:
    /// Open/Cancel names the actual actions, and both keys resolve in the
    /// elder's language.
    ///
    /// Every other flow keeps the shared `state.awaitingConfirmation` pair
    /// — a dose challenge says Yes/No because the question is about
    /// taking medicine, not opening anything. The launch rename applies
    /// only when the launch OWNED the window by the same priority the
    /// chip action and `handleConfirmationResponse` apply: a higher-
    /// priority flow that is pended at the same time (call, navigation
    /// walk, calendar write) takes the answer, so the label must promise
    /// what the tap will actually do. Pure, so the mapping is testable
    /// without a screen, and paired with the action's own flags read so
    /// label and behaviour cannot diverge.
    static func chipKeys(_ flags: Flags) -> (yes: String, no: String) {
        let launchOwnsWindow = flags.isAppLaunch
            && !flags.isCall
            && !flags.isNavigationDisambiguation
            && !flags.isCalendarEvent
        return launchOwnsWindow
            ? ("launcher.chipOpen", "launcher.chipCancel")
            : ("state.awaitingConfirmation.chipYes", "state.awaitingConfirmation.chipNo")
    }
}

struct ConfirmationChips: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    let titleKey: String

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(appearance.statusForeground(DesignTokens.stateUnderstanding))
                    Text(LocalizedStringKey(titleKey))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize, weight: .bold))
                        .foregroundColor(appearance.colors.textSecondary)
                }
                if let prompt = coordinator.lastAssistantReply, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundColor(appearance.colors.textPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            // [APP-UI-CONFIRM] The labels follow the OWNING flow: the app
            // launch asks in Open/Cancel (localized), everything else in
            // the shared yes/no pair — see `ConfirmationChipSpeech.chipKeys`
            // for why, and for the priority rule the rename respects.
            HStack(spacing: 16) {
                let keys = ConfirmationChipSpeech.chipKeys(flowFlags)
                chip(key: keys.yes, isYes: true)
                chip(key: keys.no, isYes: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface()
    }

    /// The flow flags, read exactly as the chip ACTION reads them (one
    /// property, so label and action can never read different states).
    /// Read at render time for the labels and again at tap time inside
    /// the action — the second read is the one that decides the answer,
    /// because the pends can have changed since the frame was drawn.
    private var flowFlags: ConfirmationChipSpeech.Flags {
        ConfirmationChipSpeech.Flags(
            isCall: coordinator.isAwaitingCallConfirmation,
            isNavigationDisambiguation: coordinator.isAwaitingNavigationDisambiguation,
            isCalendarEvent: coordinator.isAwaitingCalendarEventConfirmation,
            isAppLaunch: coordinator.isAwaitingAppLaunchConfirmation)
    }

    private func chip(key: String, isYes: Bool) -> some View {
        Button {
            // Same bug class as CommandRouter's voice-path fix: a call
            // confirmation speaks its OWN contextual response inside
            // performCallAction (e.g. "Calling Maiya"). Speaking the
            // generic medication-flavored text here afterward would
            // cancel that correct utterance (SystemSpeechSpeaker.speak()
            // cancels whatever's currently speaking) — checked BEFORE
            // handleConfirmationResponse, which clears pendingCallAction.
            //
            // [APP-LAUNCHER F2] The exemption has to name EVERY flow that
            // speaks for itself, not just the call one, or the chip is a
            // second, drifting copy of the voice path's list — which is
            // how a chip-yes on "क्यामेरा खोल्ने हो?" came to announce
            // "marked as taken" (a medication claim) while the camera was
            // opening. `ConfirmationChipSpeech` mirrors
            // `CommandRouter.route`'s `speaksItsOwnYesNo`; the two must
            // move together.
            let flags = flowFlags
            let response: ConfirmationResponse = isYes ? .yes : .no
            coordinator.handleConfirmationResponse(response)
            if ConfirmationChipSpeech.speaksGenericYesNo(flags) {
                coordinator.speak(key: isYes ? "router.confirmationYes" : "router.confirmationNo")
            }
        } label: {
            Text(LocalizedStringKey(key))
                .font(DesignTokens.warmFont(size: appearance.typography.scaled(24), weight: .bold))
                .foregroundColor(isYes ? appearance.colors.accentForeground : appearance.colors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .padding(.vertical, 8)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                        .stroke(isYes ? appearance.colors.accentForeground : appearance.colors.textSecondary,
                                lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - State bindings — ONE visual table (spec §3.3; call-UI fix
// 2026-09-07)

/// The Home talk stage's per-state look, computed in a single switch over
/// `VoiceSessionState` — the ONE source of truth for every visual on the
/// stage. Hero icon, in-hero caption, under-hero status line, tint, the
/// flat traffic-light fill, the halo/pulse motion, and the auxiliary
/// stage pieces (hint carousel, confirmation chips, error detail) are all
/// decided here. Since visual-polish 2026-09-08 the hero is a SOLID
/// state-tint disc (traffic-light fills — see `DesignTokens`) and every
/// glow element (halo, breathing rings, shadow, carousel dots) derives
/// from the same `tint`, so the light follows the active state family.
/// Previously the views re-derived these with their own ad-hoc conditions
/// (`isGlowing`, the halo's `== .listening || == .speaking`,
/// `capturePlaceholderKey`) — duplicate mappings that could diverge and
/// did: transcribing/understanding rendered with no glow and no halo
/// while speaking kept its ring, and each view had to be edited in
/// lockstep to keep a state's look consistent. Nothing below branches on
/// state equality; views read this table only.
extension TalkStageVisuals {
    /// [HERO-STATES] (2026-10-13) The hero's resolved visual — the one
    /// mapping every stage element derives from. The speaking overlay
    /// comes first: while any reply audio plays the hero shows the
    /// speaking family, whatever the machine state (the slot window
    /// stays in `.awaitingSlotAnswer` through its probe's speech, and
    /// the resolved frame can leave the session `.idle` while the reply
    /// still speaks — both previously showed the wrong icon). The
    /// chip-owned confirmation window is exempt: its chips stay up
    /// while the challenge speaks. Then the slot window's capture
    /// truth: a live auto-listen capture shows the listening family; a
    /// closed-capture window (the remaining 45 s) falls back to the
    /// idle talk affordance instead of a false "listening". Everything
    /// else is the raw state mapping, unchanged.
    static func resolved(state: VoiceSessionState,
                         isSpeaking: Bool,
                         slotAnswerCaptureActive: Bool) -> TalkStageVisuals {
        if isSpeaking, state != .awaitingConfirmation {
            return VoiceSessionState.speaking.talkVisuals
        }
        if state == .awaitingSlotAnswer, !slotAnswerCaptureActive {
            return VoiceSessionState.idle.talkVisuals
        }
        return state.talkVisuals
    }
}

struct TalkStageVisuals {
    /// SF Symbol inside the hero (state icons — spec §3.3).
    let icon: String
    /// Hero tint: flat fill, shadow, halo and glow color (the
    /// DesignTokens traffic-light state palette — rest blue, wait amber,
    /// go green, stop red).
    let tint: Color
    /// Big caption inside the hero (`state.*.button` keys).
    let captionKey: String
    /// Small status line under the hero (`state.*.status` keys). For
    /// `.awaitingConfirmation` it is the chips card's title instead.
    let statusKey: String
    /// Breathing rings animate around the hero — idle + listening. All
    /// other hero states are motionless by design (redesign spec §2:
    /// the rate and presence of motion itself communicates state).
    let pulses: Bool
    /// Steady state-color halo ring around the hero — every mid-cycle
    /// state (listening, transcribing, understanding, speaking) keeps
    /// one, so the ring never visibly drops out mid-turn.
    let showsHalo: Bool
    /// The hint carousel shows under the hero (idle only).
    let showsHintCarousel: Bool
    /// The stage is the yes/no chips card, not the hero.
    let isConfirmation: Bool
    /// The error state's kind-specific status caption applies.
    let isError: Bool
}

extension VoiceSessionState {
    /// State → talk-stage visuals. The single mapping every talk-stage
    /// view reads (call-UI fix, 2026-09-07); updating a state's look
    /// means editing this one switch, never scattered view conditions.
    var talkVisuals: TalkStageVisuals {
        switch self {
        case .idle:
            return TalkStageVisuals(icon: "mic.fill",
                                    tint: DesignTokens.stateIdle,
                                    captionKey: "state.idle.button",
                                    statusKey: "state.idle.status",
                                    pulses: true,
                                    showsHalo: false,
                                    showsHintCarousel: true,
                                    isConfirmation: false,
                                    isError: false)
        case .listening:
            return TalkStageVisuals(icon: "ear.fill",
                                    tint: DesignTokens.stateListening,
                                    captionKey: "state.listening.button",
                                    statusKey: "state.listening.status",
                                    pulses: true,
                                    showsHalo: true,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        case .transcribing:
            return TalkStageVisuals(icon: "pencil",
                                    tint: DesignTokens.stateTranscribing,
                                    captionKey: "state.transcribing.button",
                                    statusKey: "state.transcribing.status",
                                    pulses: false,
                                    showsHalo: true,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        case .understanding:
            return TalkStageVisuals(icon: "brain.head.profile",
                                    tint: DesignTokens.stateUnderstanding,
                                    captionKey: "state.understanding.button",
                                    statusKey: "state.understanding.status",
                                    pulses: false,
                                    showsHalo: true,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        case .speaking:
            return TalkStageVisuals(icon: "speaker.wave.2.fill",
                                    tint: DesignTokens.stateSpeaking,
                                    captionKey: "state.speaking.button",
                                    statusKey: "state.speaking.status",
                                    pulses: false,
                                    showsHalo: true,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        case .awaitingConfirmation:
            return TalkStageVisuals(icon: "questionmark",
                                    tint: DesignTokens.stateUnderstanding,
                                    captionKey: "state.awaitingConfirmation.title",
                                    statusKey: "state.awaitingConfirmation.title",
                                    pulses: false,
                                    showsHalo: false,
                                    showsHintCarousel: false,
                                    isConfirmation: true,
                                    isError: false)
        case .awaitingSlotAnswer:
            // T-135 (FR-MTC-014): the slot answer window. The probe has
            // been (or is being) spoken and the machine waits for the
            // elder's spoken answer, so the hero mirrors the LISTENING
            // family — "go ahead, I'm listening" — with the ear, live
            // motion and halo. Deliberately NOT the yes/no chips: this
            // window has no confirm affordance and is answered by voice
            // (NFR-MTC-009), and deliberately no new copy — the dialogue
            // probe's own strings ride the TTS reply lane.
            return TalkStageVisuals(icon: "ear.fill",
                                    tint: DesignTokens.stateListening,
                                    captionKey: "state.listening.button",
                                    statusKey: "state.listening.status",
                                    pulses: true,
                                    showsHalo: true,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        case .error:
            return TalkStageVisuals(icon: "exclamationmark",
                                    tint: DesignTokens.stateError,
                                    captionKey: "state.error.button",
                                    statusKey: "state.error.status",
                                    pulses: false,
                                    showsHalo: false,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: true)
        case .stopped:
            return TalkStageVisuals(icon: "mic.slash.fill",
                                    tint: DesignTokens.stateStopped,
                                    captionKey: "state.stopped.button",
                                    statusKey: "state.stopped.status",
                                    pulses: false,
                                    showsHalo: false,
                                    showsHintCarousel: false,
                                    isConfirmation: false,
                                    isError: false)
        }
    }

    /// Localized button label, resolved against the injected environment
    /// locale (spec §3.2 — the app language, not the system locale).
    func buttonText(locale: Locale) -> String {
        L10n.str(talkVisuals.captionKey, locale: locale)
    }

    /// Localized status line, same resolution as `buttonText(locale:)`.
    func statusText(locale: Locale) -> String {
        L10n.str(talkVisuals.statusKey, locale: locale)
    }
}
