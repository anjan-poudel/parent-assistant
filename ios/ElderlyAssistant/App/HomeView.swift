import SwiftUI
import UIKit

/// Leaf destinations reachable from the dock (spec §4.3).
enum LeafDestination: Identifiable {
    case meds
    case reminders
    case calendar
    case call
    case history
    case settings

    var id: String {
        switch self {
        case .meds: return "meds"
        case .reminders: return "reminders"
        case .calendar: return "calendar"
        case .call: return "call"
        case .history: return "history"
        case .settings: return "settings"
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
                VStack(spacing: 14) {
                    topBar
                    if let line = coordinator.homeCalendarLine {
                        calendarStrip(line)
                    }
                    if !coordinator.onboardingState.pendingSteps.isEmpty {
                        setupStrip
                    }
                    if !coordinator.favoriteApps.isEmpty {
                        quickAccessRow
                    }
                    Spacer(minLength: 0)
                    talkStage
                    Spacer(minLength: 0)
                    feedbackArea
                    dock
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
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
        }
    }

    // MARK: - Top bar (redesign spec §3.1)

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            // The date/greeting area doubles as the calendar's entry
            // point (2026-09-06: calendar lives ON the home screen via
            // this tap target, NOT as a 5th dock item — the dock stays
            // at three clean entries per the "keep dock items clean"
            // direction; settings moved to the top bar 2026-09-06).
            NavigationLink(value: LeafDestination.calendar) {
                // Live clock (greeting-clock fix, 2026-09-07): the shown
                // time used to freeze at launch because `greetingText`
                // read `Date()` once per body evaluation and nothing ever
                // re-evaluated it. TimelineView re-evaluates its content
                // every minute with `context.date` as the tick's instant —
                // no manual Timer object, no re-render churn on Home.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(greetingText(at: context.date))
                        .font(DesignTokens.greetingFont(size: 22))
                        .foregroundColor(DesignTokens.textPrimary)
                        .multilineTextAlignment(.leading)
                }
            }
            .accessibilityLabel(Text("home.hub.calendar"))
            Spacer()
            // Settings moved to the top bar (2026-09-06): a bottom-dock
            // slot is too valuable for something used occasionally.
            // Still exactly one entry point, by voice or by touch.
            NavigationLink(value: LeafDestination.settings) {
                IconBadge(systemImage: "gearshape.fill", tint: .settings, diameter: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("home.hub.settings")))
            EmergencyIconButton()
        }
        .padding(.top, 8)
    }

    /// Slim strip showing today's Nepali (Bikram Sambat) and Hindu
    /// calendar dates (2026-09-06) — displayed directly on Home per
    /// product direction, tappable into the full calendar leaf.
    /// Deliberately a self-contained little view: when the main-screen
    /// widget system lands, this becomes its first widget.
    private func calendarStrip(_ line: String) -> some View {
        NavigationLink(value: LeafDestination.calendar) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                Text(line)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .task { coordinator.refreshHomeCalendarLineIfNeeded() }
    }

    /// Slim, dismissible-by-navigation strip (redesign spec §3.1) —
    /// replaces the old full-width card so it doesn't compete with the
    /// Talk hero for vertical space.
    private var setupStrip: some View {
        Button { showWizard = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DesignTokens.accent)
                Text(remainingText)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
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
    /// one favourite exists.
    private var quickAccessRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home.quickAccess.caption")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
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

    /// The app's OFFICIAL brand glyph on a white circle when the catalog
    /// carries one (AppIcons.xcassets, CC0 simple-icons vectors), else
    /// the SF Symbol stand-in badge — Apple built-ins and IMO (no
    /// clean-licensed glyph) keep the stand-in.
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

    private var talkStage: some View {
        Group {
            if stageVisuals.isConfirmation {
                ConfirmationChips(titleKey: stageVisuals.captionKey)
            } else {
                VStack(spacing: 18) {
                    TalkButton(session: session,
                               statusOverride: stageVisuals.isError ? errorStatusText : nil) {
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
                    }
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
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
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
            } else if !coordinator.conversationHistory.isEmpty {
                // No outcome yet this session, but there is history —
                // still offer the on-demand sheet rather than nothing.
                historyChip
            }
        }
    }

    private var historyChip: some View {
        Button { showHistory = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .bold))
                Text("home.conversation.title")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
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
    // is the only screen that shows it)

    private var dock: some View {
        HStack(spacing: 2) {
            dockItem(.meds, icon: "pills.fill", tint: .meds, titleKey: "home.hub.meds")
            dockItem(.reminders, icon: "clock.fill", tint: .reminders, titleKey: "home.hub.reminders")
            dockCallItem
            dockApplianceItem
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
                IconBadge(systemImage: icon, tint: tint, diameter: 36)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 15, weight: .semibold))
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
                    FaceAvatar(name: first.name, diameter: 36)
                } else {
                    IconBadge(systemImage: "phone.fill", tint: .call, diameter: 36)
                }
                Text(LocalizedStringKey("home.hub.call"))
                    .font(.system(size: 15, weight: .semibold))
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

    // MARK: - Leaf routing

    @ViewBuilder
    private func leafView(for destination: LeafDestination) -> some View {
        switch destination {
        case .meds:
            MedsView()
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
        }
    }

    // MARK: - Greeting text (spec §4.1.1)

    /// Greeting salutation + clock time, both resolved from ONE instant
    /// (2026-09-07): topBar calls this with the TimelineView context date,
    /// so the salutation and the shown time can never disagree and the
    /// clock ticks every minute with no manual Timer. Single render site
    /// (topBar), so there is no Date()-based convenience overload.
    private func greetingText(at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let hour = Calendar.current.component(.hour, from: date)
        let locale = coordinator.appLanguage.locale
        switch hour {
        case 5..<12:
            return "\(L10n.str("home.greeting.morning", locale: locale)), \(time)"
        case 12..<17:
            return L10n.fmt("home.greeting.time", locale: locale, time)
        default:
            return "\(L10n.str("home.greeting.night", locale: locale)), \(time)"
        }
    }

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
    /// error state's failure-specific caption).
    var statusOverride: String? = nil

    @State private var breathe = false

    /// Single visual mapping for the hero (call-UI fix, 2026-09-07):
    /// icon, fill, halo, labels and motion all come from
    /// `VoiceSessionState.talkVisuals` — one switch over `session.state`
    /// — so the button can never render one state's color with another
    /// state's icon or label, and every element flips in the same
    /// transaction the state publishes.
    private var visuals: TalkStageVisuals { session.state.talkVisuals }

    private var isBreathing: Bool { visuals.pulses && !reduceMotion }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onTap) {
                ZStack {
                    if isBreathing {
                        breathingRings
                    }
                    if visuals.showsHalo {
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
                    Circle()
                        .fill(heroFill)
                        .frame(width: DesignTokens.talkButtonDiameter,
                               height: DesignTokens.talkButtonDiameter)
                        .shadow(color: visuals.tint.opacity(0.35), radius: 10, y: 4)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: visuals.icon)
                                    .font(.system(size: 32))
                                Text(session.state.buttonText(locale: locale))
                                    .font(.system(size: 20, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 12)
                            }
                            .foregroundColor(.white)
                        )
                }
            }
            .buttonStyle(.plain)
            // Enabled in every state except awaitingConfirmation (the
            // yes/no chips own the UI): tapping mid-cycle is the manual
            // recovery escape hatch, and tapping in error/stopped retries
            // the failed boot-time pipeline start.
            .disabled(session.state == .awaitingConfirmation)
            .accessibilityLabel(Text(session.state.buttonText(locale: locale)))

            Text(statusOverride ?? session.state.statusText(locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .medium))
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

    /// Amber gradient only while idle/listening (redesign spec §2 —
    /// "listening/live"); other states keep the existing semantic color so
    /// error/speaking/etc. stay legible against their own state color.
    private var heroFill: AnyShapeStyle {
        guard visuals.usesAmberHero else { return AnyShapeStyle(visuals.tint) }
        return AnyShapeStyle(
            RadialGradient(colors: [DesignTokens.talkGlowStart, DesignTokens.talkGlowEnd],
                           center: UnitPoint(x: 0.35, y: 0.3),
                           startRadius: 4,
                           endRadius: DesignTokens.talkButtonDiameter * 0.7)
        )
    }

    /// Two concentric rings that breathe outward and fade — the
    /// "signature" motion element (redesign spec §2). Respects
    /// `accessibilityReduceMotion` (checked by the caller before this is
    /// even placed in the view tree).
    private var breathingRings: some View {
        ZStack {
            Circle()
                .stroke(DesignTokens.talkGlowEnd.opacity(breathe ? 0.05 : 0.35), lineWidth: 2)
                .frame(width: breathe ? DesignTokens.talkButtonDiameter + 90 : DesignTokens.talkButtonDiameter + 20,
                       height: breathe ? DesignTokens.talkButtonDiameter + 90 : DesignTokens.talkButtonDiameter + 20)
            Circle()
                .stroke(DesignTokens.talkGlowEnd.opacity(breathe ? 0.02 : 0.22), lineWidth: 2)
                .frame(width: breathe ? DesignTokens.talkButtonDiameter + 130 : DesignTokens.talkButtonDiameter + 40,
                       height: breathe ? DesignTokens.talkButtonDiameter + 130 : DesignTokens.talkButtonDiameter + 40)
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
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
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
                .font(.system(size: 24, weight: .bold))
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
/// amber "live" fill, the halo/pulse motion, and the auxiliary stage
/// pieces (hint carousel, confirmation chips, error detail) are all
/// decided here. Previously the views re-derived these with their own
/// ad-hoc conditions (`isGlowing`, the halo's `== .listening ||
/// == .speaking`, `capturePlaceholderKey`) — duplicate mappings that
/// could diverge and did: transcribing/understanding rendered with no
/// glow and no halo while speaking kept its ring, and each view had to
/// be edited in lockstep to keep a state's look consistent. Nothing
/// below branches on state equality; views read this table only.
struct TalkStageVisuals {
    /// SF Symbol inside the hero (state icons — spec §3.3).
    let icon: String
    /// Hero tint: flat fill, shadow and halo color (the DesignTokens
    /// state palette — listening amber, speaking call-blue, etc.).
    let tint: Color
    /// Big caption inside the hero (`state.*.button` keys).
    let captionKey: String
    /// Small status line under the hero (`state.*.status` keys). For
    /// `.awaitingConfirmation` it is the chips card's title instead.
    let statusKey: String
    /// Amber radial-gradient hero ("listening/live", redesign spec §2) —
    /// idle and listening only.
    let usesAmberHero: Bool
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
                                    usesAmberHero: true,
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
                                    usesAmberHero: true,
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
                                    usesAmberHero: false,
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
                                    usesAmberHero: false,
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
                                    usesAmberHero: false,
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
                                    usesAmberHero: false,
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
                                    usesAmberHero: false,
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
                                    usesAmberHero: false,
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
