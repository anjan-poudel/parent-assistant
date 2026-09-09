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
    /// [SPINNER-PLACEMENT] Read so the container can animate the talk
    /// hero's settle when the boot spinner's flow slot collapses.
    @EnvironmentObject private var boot: StartupBoot

    @State private var showWizard = false
    @State private var showHistory = false
    @State private var outcomeExpanded = true
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
                    topBar
                    // Quick access ABOVE the Talk hero (home-redesign v3,
                    // 2026-09-08): the favourites are one-tap launch
                    // tiles, not reading matter — the user asked for them
                    // above the hero, and they render only while at least
                    // one favourite exists.
                    if !coordinator.favoriteApps.isEmpty {
                        quickAccessRow
                    }
                    // [SPINNER-PLACEMENT] The startup spinner lives ABOVE
                    // the speak button: a flow slot between quick access
                    // and the talk stage. It used to be a ContentView top
                    // overlay, where the capsule covered the top bar's
                    // calendar date line — the complaint — so it now sits
                    // here, never covering the calendar. The slot
                    // collapses when the boot reaches `.ready` (and the
                    // overlay renders zero-height while nothing shows).
                    StartupProgressOverlay()
                    // The talk stage is FIXED chrome (home-redesign v3):
                    // hero + the small status/rotating texts under it sit
                    // between the top bar and the outcome region, so the
                    // speak button is always in the viewport on every
                    // phone size.
                    talkStage
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
                        VStack(spacing: 12) {
                            if !coordinator.onboardingState.pendingSteps.isEmpty {
                                setupStrip
                            }
                            feedbackArea
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                // [SPINNER-PLACEMENT] When the boot finishes the spinner
                // slot collapses and everything below it rises — ease the
                // whole settle (hero included) instead of a snap, matching
                // the overlay's own 0.2s ease.
                .animation(.easeInOut(duration: 0.2), value: boot.spinnerVisible)
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
                    dock
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationBarHidden(true)
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

    // MARK: - Top bar (redesign spec §3.1)

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Settings stays in the top bar, LEFT-anchored at the leading
            // edge with the date line centered between it and the
            // emergency button, so the gear can never be confused with
            // emergency (2026-09-07). Still exactly one entry point, by
            // voice or by touch. Equal-width 44pt containers on both
            // sides keep the date line visually centered — the
            // notifications bell joined the trailing cluster
            // (home-redesign 2026-09-08), so a balancing invisible 44pt
            // sits beside settings.
            NavigationLink(value: LeafDestination.settings) {
                IconBadge(systemImage: "gearshape.fill", tint: .settings, diameter: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("home.hub.settings")))
            .frame(width: 44, alignment: .leading)
            Color.clear.frame(width: 44, height: 44)
            Spacer(minLength: 4)
            // The date area doubles as the calendar's entry point
            // (2026-09-06: calendar lives ON the home screen via this
            // tap target, NOT as a dock item; settings moved to the top
            // bar the same day). The greeting + live clock are GONE
            // (calendar-display task, 2026-09-09): the phone already
            // shows the time, and the local date + holiday overlay is
            // the thing that is genuinely useful here — composed from
            // the Calendar display settings (default calendar + the BS
            // and tithi overlays) by `HomeDateLineComposer` and
            // refreshed on appear, at midnight and on foreground.
            NavigationLink(value: LeafDestination.calendar) {
                homeDateLineView
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("home.hub.calendar"))
            .accessibilityValue(Text(coordinator.homeCalendarLine ?? ""))
            Spacer(minLength: 4)
            // The ONE notifications affordance (home-redesign v3,
            // 2026-09-08): a bell with the active-panel badge in the top
            // bar — the "notifications live here" spot every phone has
            // taught, and the badge count always matches what the Updates
            // leaf lists (same registry instance). Bell sits between the
            // date line and emergency, keeping emergency at the far edge
            // exactly where it always was. Tap PUSHES the Updates leaf
            // (home-redesign v3): the pushed leaf replaced the drawer
            // sheet, so no sheet machinery lives on Home anymore.
            NotificationBellButton(count: activeNotificationCount) {
                navPath.append(LeafDestination.updates)
            }
            EmergencyIconButton()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    /// Today's date, composed from the calendar display settings: the
    /// primary date (default calendar) on the greeting font, the enabled
    /// overlays joined beneath it in caption size. Empty until the
    /// coordinator's first offline composition lands (one launch frame).
    @ViewBuilder
    private var homeDateLineView: some View {
        if let line = coordinator.homeDateLine {
            VStack(alignment: .center, spacing: 2) {
                Text(line.primary)
                    .font(DesignTokens.greetingFont(size: 18))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !line.overlays.isEmpty {
                    Text(line.overlays.joined(separator: " • "))
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                   weight: .medium))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
        }
    }

    /// The Home widget registry (rendering v2, home-redesign 2026-09-08):
    /// panels now feed the Updates leaf + bell badge instead of a stacked
    /// card row — evaluated on every render; panels self-hide through
    /// `makeRow`, so no widget bookkeeping lives in this view. The SAME
    /// instance feeds the bell on Home and the Updates leaf's
    /// Notifications section (UpdatesScreen receives it), so badge count
    /// and leaf rows can never disagree.
    private let widgetRegistry = HomeWidgetRegistry()

    /// Bell badge derivation — the count of active notification panels,
    /// straight from the registry rows the Updates leaf lists.
    private var activeNotificationCount: Int {
        widgetRegistry.activeNotificationCount(coordinator: coordinator)
    }

    /// Slim, dismissible-by-navigation strip (redesign spec §3.1) —
    /// replaces the old full-width card so it doesn't compete with the
    /// Talk hero for vertical space. Sits BELOW the hero inside the
    /// outcome scroll region (home-redesign v3): the wizard only shows
    /// while onboarding steps remain, and this strip is Home's only
    /// resume affordance for it — but it is transient per-user and must
    /// never push the hero off the viewport, so the region below the
    /// hero owns it.
    private var setupStrip: some View {
        Button { showWizard = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DesignTokens.accent)
                // Short static catalog microcopy (visual-polish 2026-09-08):
                // warm rounded, matching the sibling historyChip capsule.
                Text(remainingText)
                    .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: DesignTokens.minTapTargetSize)
            .background(DesignTokens.setupReminder)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick access row (quick-access-apps task, 2026-09-06)

    /// The user's favourite apps as one-tap launch tiles, right under the
    /// setup strip. Deliberately an inline row, NOT a HomeWidget — the
    /// row has no widget lifecycle needs and the home-screen widget
    /// system is a separate concern (documented in the task design). The
    /// trailing plus tile opens Settings → Quick apps, where the
    /// favourites are managed; the whole row renders only while at least
    /// one favourite exists. No "Quick access" caption (calendar-display
    /// task, 2026-09-09): the row of app tiles is self-evident — the
    /// caption read as clutter, so the tiles + plus stand alone.
    private var quickAccessRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(coordinator.favoriteApps) { app in
                    quickAccessTile(app)
                }
                NavigationLink(value: LeafDestination.settings) {
                    quickAccessAddTile
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    /// 48pt badge + 12pt name on a 76pt-wide tile, ≥44pt tall — one
    /// combined accessibility element ("WhatsApp, button"); tapping
    /// launches through the coordinator, which probes the scheme again at
    /// tap time and speaks honestly when the app has gone away.
    private func quickAccessTile(_ app: AppLauncher.App) -> some View {
        Button {
            coordinator.performAppLaunch(app)
        } label: {
            VStack(spacing: 4) {
                appGlyph(app, diameter: 56)
                Text(LocalizedStringKey(app.nameKey))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 92)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    /// The app's OFFICIAL multicolor logo on a white circle when the
    /// catalog carries one (AppIcons.xcassets — Wikimedia Commons PNGs),
    /// else the SF Symbol stand-in badge — Apple built-ins and IMO (no
    /// official logo) keep the stand-in.
    private func appGlyph(_ app: AppLauncher.App, diameter: CGFloat) -> some View {
        AppGlyph(app: app, diameter: diameter)
    }

    /// The trailing plus tile → Settings (LeafDestination.settings), where
    /// the Quick apps picker lives. 76pt-wide like the app tiles so the
    /// row's rhythm stays even.
    private var quickAccessAddTile: some View {
        VStack(spacing: 4) {
            IconBadge(systemImage: "plus", tint: .apps, diameter: 56)
        }
        .frame(width: 92)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("home.quickAccess.add"))
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

    private var talkStage: some View {
        Group {
            if stageVisuals.isConfirmation {
                ConfirmationChips(titleKey: stageVisuals.captionKey)
            } else {
                // The stage reads as ONE unit: hero, its status line and
                // the hint carousel each sit ≤4pt apart (visual-polish
                // 2026-09-08 — at the old gaps the texts floated loose
                // below the button; the hints describe the button right
                // below them, so they must hug it).
                VStack(spacing: 4) {
                    TalkButton(session: session,
                               onTap: {
                                   switch session.state {
                                   case .idle:
                                       coordinator.simulateWakeWordDetection()
                                   case .listening, .transcribing, .understanding, .speaking:
                                       // Manual escape hatch: tapping mid-cycle cancels
                                       // and recycles the pipeline (the watchdog does
                                       // the same automatically after 15s).
                                       coordinator.recoverVoiceCycle()
                                   case .error, .stopped:
                                       // Boot-time start failed (mic denied, speech
                                       // denied, no audio input) — tapping retries
                                       // the pipeline start instead of staying dead.
                                       coordinator.recoverVoiceCycle()
                                   case .awaitingConfirmation:
                                       break
                                   }
                               },
                               statusOverride: talkStatusLineOverride,
                               onLongPressReset: coordinator.resetVoiceActivation)
                    if stageVisuals.showsHintCarousel {
                        HintCarousel()
                    }
                    if stageVisuals.isError,
                       coordinator.voiceErrorKind == .permission {
                        openSettingsButton
                    }
                }
            }
        }
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

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("state.error.openSettings", systemImage: "gear")
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
                .padding(.horizontal, 16)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feedback area: live caption while capturing, outcome after
    // (redesign spec §3.1, §6 — replaces the old always-visible
    // conversation card entirely)

    @ViewBuilder
    private var feedbackArea: some View {
        switch session.state {
        case .listening, .transcribing, .understanding:
            // The pill is a transcript surface — its header ("You're
            // saying") plus the real words once STT lands. The capture
            // stage's own phrase lives on the hero's status line; the
            // pill used to repeat that same sentence inside the
            // transcript slot, framed by the header as if it were the
            // user's words ("You're saying: Go ahead, I'm listening")
            // until the real transcript replaced it (call-UI fix,
            // 2026-09-07).
            LiveCaptionPill(transcript: coordinator.livePartialTranscript ?? coordinator.lastTranscript)
        case .awaitingConfirmation:
            // The confirmation chips in `talkStage` ARE the feedback — an
            // earlier turn's outcome card underneath the yes/no question
            // read as a stray second card (call-UI fix, 2026-09-07).
            EmptyView()
        default:
            if let outcome = coordinator.lastOutcome {
                OutcomeCardView(outcome: outcome, expanded: outcomeExpanded) {
                    showHistory = true
                }
                .task(id: outcome.id) {
                    outcomeExpanded = true
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut) { outcomeExpanded = false }
                }
            }
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

    // MARK: - Dock (redesign spec §3.1 — replaces the 2×2 hub grid; Home
    // is the only screen that shows it). Six tiles in TWO rows of three
    // (calendar-display task, 2026-09-09): one row of six read as a
    // cluttered shelf, so the user asked for two rows — top: appliance
    // helper, directions, feeds; bottom: the rest (meds, reminders,
    // call). Same `dockItem` components, same ≥44pt targets, same
    // material card, same accessibility labels — only the layout
    // changed. Items share width equally (`frame(maxWidth: .infinity)`
    // per tile) and labels wrap when they must.

    private var dock: some View {
        VStack(spacing: 10) {
            // Top row (the user's ordering, calendar-display task):
            // appliance helper, directions, feeds.
            HStack(spacing: 2) {
                dockApplianceItem
                dockDirectionsItem
                dockItem(.feed, icon: "rectangle.stack.fill", tint: .feeds, titleKey: "home.hub.feeds")
            }
            // Bottom row: the rest — meds, reminders, call.
            HStack(spacing: 2) {
                dockItem(.meds, icon: "pills.fill", tint: .meds, titleKey: "home.hub.meds")
                dockItem(.reminders, icon: "clock.fill", tint: .reminders, titleKey: "home.hub.reminders")
                dockCallItem
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func dockItem(_ destination: LeafDestination, icon: String,
                          tint: DesignTokens.BadgeTint, titleKey: String) -> some View {
        NavigationLink(value: destination) {
            VStack(spacing: 4) {
                IconBadge(systemImage: icon, tint: tint, diameter: 42)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    /// Uses the top family contact's face instead of a generic phone icon
    /// when one is configured (redesign spec §3.1/§3.2).
    private var dockCallItem: some View {
        NavigationLink(value: LeafDestination.call) {
            VStack(spacing: 4) {
                if let first = coordinator.familyContacts.first {
                    FaceAvatar(name: first.name, diameter: 42)
                } else {
                    IconBadge(systemImage: "phone.fill", tint: .call, diameter: 42)
                }
                Text(LocalizedStringKey("home.hub.call"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    /// Appliance vision helper — the design §4 "Show Me" dock tile. A
    /// Button, not a NavigationLink: it presents the camera surface
    /// app-wide (via `pendingPluginPresentation`), same as the voice path.
    private var dockApplianceItem: some View {
        Button { coordinator.presentApplianceHelper(question: nil) } label: {
            VStack(spacing: 4) {
                IconBadge(systemImage: "camera.viewfinder", tint: .appliance, diameter: 36)
                Text(LocalizedStringKey("plugin.applianceHelper.name"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    /// Directions (directions-screen task, 2026-09-07) — the map tile
    /// docked right next to Appliance per the task brief. The map icon
    /// reads "navigation" against the house/appliance row; it pushes the
    /// Directions leaf like every other dock tile.
    private var dockDirectionsItem: some View {
        dockItem(.directions, icon: "map.fill", tint: .directions, titleKey: "home.hub.directions")
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
            SettingsView()
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
        }
    }

    // MARK: - Setup strip text

    private var remainingText: String {
        L10n.fmt("home.setupRemaining", locale: coordinator.appLanguage.locale,
                 coordinator.onboardingState.pendingSteps.count)
    }
}

// MARK: - Talk button (spec §3.3, D5; redesign spec §2 — breathing glow)

struct TalkButton: View {
    @ObservedObject var session: VoiceSessionStateMachine
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// The hold-to-reset affordance is live (reset-eligible state AND a
    /// reset action was provided). The Home stage always supplies the
    /// action, so this effectively means `supportsTalkReset` — kept
    /// separate so a future reuse of TalkButton without a reset stays a
    /// plain tap target.
    private var resetHoldable: Bool {
        onLongPressReset != nil && session.state.supportsTalkReset
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
                    // matters); they return on release.
                    if isBreathing && !isPressingForReset {
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
                    Circle()
                        .fill(visuals.tint)
                        .frame(width: DesignTokens.talkButtonDiameter,
                               height: DesignTokens.talkButtonDiameter)
                        .shadow(color: visuals.tint.opacity(0.4), radius: 10, y: 4)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: visuals.icon)
                                    .font(.system(size: 32))
                                Text(session.state.buttonText(locale: locale))
                                    .font(DesignTokens.warmFont(size: 20, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 12)
                            }
                            .foregroundColor(.white)
                        )
                    if isPressingForReset {
                        resetProgressRing
                    }
                }
            }
            .buttonStyle(.plain)
            // Enabled in every state except awaitingConfirmation (the
            // yes/no chips own the UI): tapping mid-cycle is the manual
            // recovery escape hatch, and tapping in error/stopped retries
            // the failed boot-time pipeline start.
            .disabled(session.state == .awaitingConfirmation)
            .accessibilityLabel(Text(session.state.buttonText(locale: locale)))
            // The hold-to-reset gesture + VoiceOver hint exist ONLY in
            // reset-eligible states. An always-attached long press would
            // swallow the tap on holds ≥ `talkResetHoldSeconds` in
            // .speaking too — changing the "hold to stop the reply" tap
            // that users rely on today (TALK-CRASH-FIX, 2026-09-07).
            .if(resetHoldable, ResetHoldAffordance(
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
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    /// Status line under the hero: the live hold hint while a reset
    /// press is underway, else the caller's override (error caption /
    /// post-reset notice), else the state's own status text. The hold
    /// hint wins over everything — while the finger is down the line
    /// must say what the press will DO (TALK-CRASH-FIX, 2026-09-07).
    private var statusTextLine: String {
        if isPressingForReset {
            return L10n.str("voice.resetHold", locale: locale)
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
/// hint in one modifier so the two can be applied conditionally (see the
/// `.if` at the call site). Conditional attachment matters: in
/// non-reset states (.speaking, .awaitingConfirmation) the hero must
/// stay a plain tap target — an always-attached long press would swallow
/// the tap on holds ≥ `talkResetHoldSeconds` there, changing the
/// "hold to stop the reply" behavior users rely on today.
private struct ResetHoldAffordance: ViewModifier {
    let holdSeconds: TimeInterval
    let maxDistance: CGFloat
    let accessibilityHint: String
    let onReset: () -> Void
    let onPressingChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityHint(Text(accessibilityHint))
            .onLongPressGesture(minimumDuration: holdSeconds,
                                maximumDistance: maxDistance,
                                perform: onReset,
                                onPressingChanged: onPressingChanged)
    }
}

/// Conditional-modifier helper: applies `modifier` only while `condition`
/// holds. Used by the hero's reset affordance, which exists only in
/// reset-eligible states. File-private — no other file sees it.
private extension View {
    @ViewBuilder
    func `if`<M: ViewModifier>(_ condition: Bool, _ modifier: M) -> some View {
        if condition {
            self.modifier(modifier)
        } else {
            self
        }
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
