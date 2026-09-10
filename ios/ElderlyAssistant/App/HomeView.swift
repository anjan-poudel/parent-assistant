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
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine
    /// [BOOT-LATENCY] Read so the container can animate the talk hero's
    /// settle when the boot spinner collapses inside the talk stage.
    @EnvironmentObject private var boot: StartupBoot

    @State private var showWizard = false
    @State private var showHistory = false
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

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                // Skinnable background (2026-09-07) — the theme's cream is
                // today's DesignTokens.background; see `AppTheme`.
                Color(theme: coordinator.appTheme).ignoresSafeArea()
                VStack(spacing: 12) {
                    // [P1-7] Every section below is a real view with a
                    // narrow, value-typed interface (`HomeSubviews.swift`)
                    // applied with `.equatable()`. HomeView still observes
                    // the coordinator — it is what BUILDS the models — but
                    // an unrelated publish now stops at the section's own
                    // `==`: the section compares equal and its body never
                    // runs (see `HomePresentationState.swift`).
                    HomeTopBar(dateLine: homePresentation.dateLine,
                               calendarLine: coordinator.homeCalendarLine,
                               notificationCount: homePresentation.notificationCount) {
                        navPath.append(LeafDestination.updates)
                    }
                    .equatable()
                    // Quick access ABOVE the Talk hero (home-redesign v3,
                    // 2026-09-08): the favourites are one-tap launch
                    // tiles, not reading matter — the user asked for them
                    // above the hero, and they render only while at least
                    // one favourite exists.
                    if !homePresentation.favoriteApps.isEmpty {
                        QuickAccessStrip(apps: homePresentation.favoriteApps) { app in
                            coordinator.performAppLaunch(app)
                        }
                        .equatable()
                    }
                    // [REBALANCE] One flexible spacer above the stage —
                    // Home's only empty space. A VStack splits its
                    // leftover height between flexible children, so this
                    // spacer and the scroll region below share it and the
                    // talk stage settles near the vertical centre of the
                    // free area: the hero no longer clings to the top bar
                    // (design review: "vertically center the Talk stage …
                    // keep empty space for focus"). It is one flexible
                    // Spacer, never a dashboard row, and it collapses to
                    // its 8pt minimum on SE-sized screens, where the
                    // scroll region then absorbs the overflow exactly as
                    // before.
                    Spacer(minLength: 8)
                    // [HOME-TIMER-CHIP] (2026-09-11) The active-timer
                    // chip in the hero's empty area: the nearest running
                    // timer's remaining time + one-tap STOP. Renders
                    // nothing (no space) while no timer runs — the free
                    // area above the hero stays free.
                    HomeTimerChipView(service: coordinator.alarmTimersService) { id in
                        coordinator.cancelTimer(id: id)
                    }
                    .equatable()
                    // The talk stage is FIXED chrome (home-redesign v3):
                    // hero + the small status/rotating texts under it sit
                    // between the top bar and the outcome region, so the
                    // speak button is always in the viewport on every
                    // phone size.
                    talkStage
                        .equatable()
                    // Everything BELOW the hero — the transient setup
                    // nudge (only while onboarding steps remain) and the
                    // live-caption/outcome text — is ONE scroll region.
                    // This region between the hero and the pinned bottom
                    // cluster (history chip + dock, see the safeAreaInset
                    // below) is the only part of Home that ever clips: on
                    // an iPhone SE-sized viewport the lower content
                    // scrolls while the hero, chip and dock never leave
                    // the screen.
                    ScrollView(showsIndicators: false) {
                        feedbackRegion
                            .equatable()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            // Dock pinned to the bottom edge (home-redesign 2026-09-08):
            // previously the dock was the last child of the fixed VStack,
            // so any overflow above it (the old widget stack) pushed it
            // off the viewport on small screens. As a `safeAreaInset` it
            // always owns the bottom of the screen and the scroll region
            // above it absorbs overflow instead.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Fixed bottom cluster (visual-polish 2026-09-08): the
                // history chip rides ABOVE the dock, 6pt off its top edge,
                // both pinned — the scroll region between the hero and
                // this cluster is the only part of Home that clips.
                VStack(spacing: 6) {
                    if showsPinnedHistoryChip {
                        historyChip
                    }
                    HomeDock(contactName: homePresentation.primaryContactName,
                             onAppliance: {
                                 coordinator.presentApplianceHelper(question: nil)
                             })
                    .equatable()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
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
            .fullScreenCover(isPresented: $showWizard) {
                OnboardingWizardView(startingAt: coordinator.onboardingState.firstPendingStep)
                    .environmentObject(coordinator)
                    .environmentObject(session)
                    .environmentObject(coordinator.modelDownloadService)
                    .environment(\.locale, coordinator.appLanguage.locale)
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
            primaryContactName: coordinator.familyContacts.first?.name,
            setup: SetupPresentation(
                pendingCount: coordinator.onboardingState.pendingSteps.count,
                // Warning styling is reserved for a capability that is
                // genuinely unavailable — never for "setup is not done"
                // (design review: ready vs optional setup).
                needsAttention: boot.hasFailures))
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
    private var stageVisuals: TalkStageVisuals { session.state.talkVisuals }

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
                  voice: voicePresentation,
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
                       onResumeSetup: { showWizard = true },
                       onOpenHistory: { showHistory = true },
                       onDismissOutcome: coordinator.dismissOutcome)
    }

    /// The error status line says what actually happened (spec §7) —
    /// permission guidance, audio-unavailable notice, or the generic
    /// re-prompt — instead of always claiming a misheard utterance.
    private var errorStatusText: String {
        let locale = coordinator.appLanguage.locale
        switch coordinator.voiceErrorKind {
        case .permission:
            return L10n.str("state.error.permission", locale: locale)
        case .audioUnavailable:
            return L10n.str("state.error.audio", locale: locale)
        case .other:
            return L10n.str("state.error.status", locale: locale)
        }
    }

    /// Pinned history affordance (visual-polish 2026-09-08): the chip
    /// moved OUT of the scroll region to sit between it and the dock —
    /// "closer to the dock menus" — so older conversations stay one
    /// fixed tap away regardless of scroll position. Visibility mirrors
    /// the chip's old in-scroll rule exactly: shown while there is
    /// history to open, no fresh outcome card is already offering the
    /// sheet, and the stage is not mid-capture (the live pill owns the
    /// moment). Tapping opens the same history sheet as before.
    private var showsPinnedHistoryChip: Bool {
        guard coordinator.lastOutcome == nil,
              !coordinator.conversationHistory.isEmpty else { return false }
        switch session.state {
        case .idle, .speaking, .error, .stopped:
            return true
        case .listening, .transcribing, .understanding, .awaitingConfirmation:
            return false
        }
    }

    private var historyChip: some View {
        Button { showHistory = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DesignTokens.warmFont(size: 11, weight: .bold))
                Text("home.conversation.title")
                    .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .semibold))
            }
            .foregroundColor(DesignTokens.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DesignTokens.card)
            .clipShape(Capsule())
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
    @ObservedObject var session: VoiceSessionStateMachine
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// [P0-2] Manual Talk readiness — the shared `VoicePipelineReadiness`
    /// contract, and the hero's ONLY gate. `.loading` keeps the disc at
    /// its final dimensions with a spinner inside it and disables
    /// activation AND every recovery gesture (including the hold-to-reset);
    /// `.failed` shows one explanation plus one deterministic recovery;
    /// `.ready` is the normal hero. Wake-word status is deliberately not
    /// consulted — a degraded KWS engine never takes manual Talk down.
    let readiness: VoicePipelineReadiness
    let onTap: () -> Void
    /// Replaces the state-bound status line when set (used for the
    /// error state's failure-specific caption and the post-reset notice).
    var statusOverride: String? = nil
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

    /// Single visual mapping for the hero (call-UI fix, 2026-09-07):
    /// icon, fill, halo, labels and motion all come from
    /// `VoiceSessionState.talkVisuals` — one switch over `session.state`
    /// — so the button can never render one state's color with another
    /// state's icon or label, and every element flips in the same
    /// transaction the state publishes.
    private var visuals: TalkStageVisuals { session.state.talkVisuals }

    private var isBreathing: Bool { visuals.pulses && !reduceMotion }

    /// [P0-2] The pipeline start is still in flight — the hero shows its
    /// loading presentation and every activation/recovery affordance is
    /// off.
    private var isLoading: Bool { readiness.isLoading }

    /// [P0-2] The pipeline's boot-time start failed; the hero shows one
    /// explanation and one recovery.
    private var failure: VoiceStartupFailure? { readiness.failure }

    /// Disabled unless the pipeline's own start callback succeeded, plus
    /// the chips' own case: while loading (or failed) the hero is inert —
    /// the reset hold is not even attached, so a hold cannot reach the
    /// reset path while the review's "cannot invoke recovery merely
    /// because startup has not completed" rule applies.
    private var isDisabled: Bool {
        readiness != .ready || session.state == .awaitingConfirmation
    }

    /// [P0-2 UX fix] The disc's fill. While the pipeline start is in
    /// flight (or it failed), the session state is `.stopped`, whose
    /// dimmed grey-blue tint reads as a light grey disc under white text
    /// — unreadable (user feedback, 2026-09-11). Loading and failed
    /// render the SOLID rest blue instead, so the white glyphs keep their
    /// contrast and the disc never flashes grey → blue at readiness.
    private var discTint: Color {
        (isLoading || failure != nil) ? DesignTokens.stateIdle : visuals.tint
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
        // 4pt — the status line HUGS the hero circle so button + caption
        // read as one unit (visual-polish 2026-09-08; the stage VStack
        // keeps its own ≤4pt below this line to the hint carousel).
        VStack(spacing: 4) {
            Button(action: {
                // The reset backstop (see `suppressTapAfterReset`): after
                // a completed hold the release must not ALSO run the tap
                // action. Quick taps and sub-threshold holds never set the
                // flag and are unaffected.
                guard !suppressTapAfterReset else { return }
                onTap()
            }) {
                ZStack {
                    // While a reset hold is underway the breathing rings
                    // stand down (the arc below is the motion that
                    // matters); they return on release. [P0-2] they stand
                    // down unless the pipeline is ready too — a loading or
                    // failed hero does not breathe.
                    if isBreathing && !isPressingForReset && readiness == .ready {
                        breathingRings
                    }
                    if visuals.showsHalo && !isPressingForReset {
                        // Steady state-color halo through every mid-cycle
                        // state (listening → transcribing → understanding
                        // → speaking). The ring used to drop out for
                        // transcribing/understanding and pop back at
                        // speaking — the hero visibly "shrank" mid-turn
                        // (call-UI fix, 2026-09-07).
                        Circle()
                            .stroke(visuals.tint.opacity(0.28), lineWidth: 10)
                            .frame(width: DesignTokens.talkButtonDiameter + 28,
                                   height: DesignTokens.talkButtonDiameter + 28)
                    }
                    // Traffic-light hero (visual-polish 2026-09-08): a
                    // SOLID state-color disc — flat fills read calmer and
                    // clearer than the old radial amber "diya" glow, and
                    // white glyphs hold ≥4.5:1 on every state color (unit
                    // tested). The breathing rings + halo + shadow carry
                    // the "alive" light in the state's own color family.
                    // [P0-2] The disc's DIMENSIONS are readiness-independent
                    // by construction (the frame below), so the hero keeps
                    // its final size through loading and failure. The fill
                    // is `discTint` — solid rest blue while loading or
                    // failed, the state color otherwise. The floating boot
                    // capsule is GONE (user feedback, 2026-09-11): the
                    // hero's own spinner + label is the loading UI, and
                    // capability diagnostics live in Settings.
                    Circle()
                        .fill(discTint)
                        .frame(width: DesignTokens.talkButtonDiameter,
                               height: DesignTokens.talkButtonDiameter)
                        .shadow(color: discTint.opacity(0.4), radius: 10, y: 4)
                        .overlay(heroContent)
                    if isPressingForReset {
                        resetProgressRing
                    }
                }
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

            // Warm rounded status line ("I'm ready", hold hint, error
            // captions) — short human-facing microcopy (visual-polish
            // 2026-09-08).
            Text(statusTextLine)
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .medium))
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)

            // [P0-2] The ONE recovery a failed boot-time start offers —
            // and only then. It replaces the old "tap the dead hero to
            // retry" path, which could not distinguish "not ready yet"
            // from "failed".
            if failure != nil, let onRecover {
                recoveryAction(onRecover)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    /// The disc's content ([P0-2]). While the pipeline start is in flight
    /// the hero shows a `ProgressView` and the localized stage label
    /// INSIDE the disc; otherwise it shows the live state's icon and
    /// caption. Both branches sit inside the same fixed-size circle, so
    /// the hero's final dimensions never move with readiness.
    private var heroContent: some View {
        VStack(spacing: 6) {
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
                Text(loadingStageLabel)
                    .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            } else {
                Image(systemName: visuals.icon)
                    .font(.system(size: 32))
                // The state caption is essential localized text ("I'm
                // ready" / Nepali), so it WRAPS to a second line instead
                // of shrinking: `minimumScaleFactor(0.7)` could render
                // longer Nepali strings at ~14pt, under the 18pt floor
                // this audience needs.
                Text(session.state.buttonText(locale: locale))
                    .font(DesignTokens.warmFont(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
        }
        .foregroundStyle(.white)
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
                    .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                weight: .semibold))
            }
            .foregroundStyle(DesignTokens.accent)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .background(DesignTokens.card)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Status line under the hero: the live hold hint while a reset
    /// press is underway, else the ONE failure explanation while the
    /// pipeline start failed, else EMPTY while it is still loading (the
    /// stage label lives inside the disc — and the state's own text would
    /// claim "I'm ready" before the callback says so), else the caller's
    /// override (error caption / post-reset notice), else the state's own
    /// status text. The hold hint wins over everything — while the finger
    /// is down the line must say what the press will DO
    /// (TALK-CRASH-FIX, 2026-09-07); a disabled hero can never hold, so
    /// the two never collide.
    private var statusTextLine: String {
        if isPressingForReset {
            return L10n.str("voice.resetHold", locale: locale)
        }
        if isLoading { return "" }
        if let failure {
            return TalkReadinessCopy.failureExplanation(failure, locale: locale)
        }
        return statusOverride ?? session.state.statusText(locale: locale)
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
            .frame(width: DesignTokens.talkButtonDiameter + 16,
                   height: DesignTokens.talkButtonDiameter + 16)
        }
    }

    /// Two concentric rings that breathe outward and fade — the
    /// "signature" motion element (redesign spec §2). The rings breathe
    /// in the ACTIVE state's color (visual-polish 2026-09-08): blue
    /// rings at rest, amber while listening — the light follows the
    /// traffic-light family, never a fixed amber. Respects
    /// `accessibilityReduceMotion` (checked by the caller before this is
    /// even placed in the view tree).
    private var breathingRings: some View {
        ZStack {
            Circle()
                .stroke(visuals.tint.opacity(breathe ? 0.05 : 0.35), lineWidth: 2)
                .frame(width: breathe ? DesignTokens.talkButtonDiameter + 90 : DesignTokens.talkButtonDiameter + 20,
                       height: breathe ? DesignTokens.talkButtonDiameter + 90 : DesignTokens.talkButtonDiameter + 20)
            Circle()
                .stroke(visuals.tint.opacity(breathe ? 0.02 : 0.22), lineWidth: 2)
                .frame(width: breathe ? DesignTokens.talkButtonDiameter + 130 : DesignTokens.talkButtonDiameter + 40,
                       height: breathe ? DesignTokens.talkButtonDiameter + 130 : DesignTokens.talkButtonDiameter + 40)
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
struct ConfirmationChips: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let titleKey: String

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(DesignTokens.stateUnderstanding)
                    Text(LocalizedStringKey(titleKey))
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                if let prompt = coordinator.lastAssistantReply, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 16) {
                chip(key: "state.awaitingConfirmation.chipYes", isYes: true)
                chip(key: "state.awaitingConfirmation.chipNo", isYes: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
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
            let isCall = coordinator.isAwaitingCallConfirmation
            let response: ConfirmationResponse = isYes ? .yes : .no
            coordinator.handleConfirmationResponse(response)
            if !isCall {
                coordinator.speak(key: isYes ? "router.confirmationYes" : "router.confirmationNo")
            }
        } label: {
            Text(LocalizedStringKey(key))
                .font(DesignTokens.warmFont(size: 24, weight: .bold))
                .foregroundColor(isYes ? DesignTokens.accent : DesignTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.chipHeight)
                .background(DesignTokens.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                        .stroke(isYes ? DesignTokens.accent : DesignTokens.textSecondary,
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
