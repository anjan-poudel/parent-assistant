import SwiftUI
import UIKit

// MARK: - Home's extracted subviews (startup review P1-7, 2026-09-10)
//
// Each type here is a REAL view with a narrow, value-typed interface, so
// HomeView's re-render does not have to become this section's re-render:
// the call sites apply `.equatable()`, and the `==` conformances below
// decide — field by field — which changes actually matter to that section.
// Nothing in this file observes `AppCoordinator`; the coordinator reaches
// these views only through the values passed in and the closures they
// call (see `HomePresentationState.swift` for the models and the equality
// rule).
//
// Unrelated coordinator updates still compare equal. Skin/style and Dynamic
// Type are environment dependencies, so their changes invalidate the relevant
// subviews even across the equatable performance boundaries. Voice animation
// and state updates remain isolated to the talk stage.
//
// iOS 16 floor: these are value-typed slices fed by HomeView, not
// `@Observable` models — see `HomePresentationState.swift` for the
// migration note.

// MARK: - Top bar (redesign spec §3.1)

/// Settings and "About me" (leading, home-profile-icon 2026-10-06), the
/// date line doubling as the calendar's entry point (centered), the
/// notifications bell and the emergency button (trailing). At larger type
/// the full date moves below the controls; every entrypoint retains a
/// minimum 44pt target.
struct HomeTopBar: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Today's composed date line — nil until the first offline
    /// composition lands (one launch frame), which renders as an empty
    /// date area, exactly as before the split.
    let dateLine: HomeDateLineComposer.Line?
    /// The line's VoiceOver value (`homeCalendarLine`), separate from the
    /// displayed composition: the a11y value is the plain calendar date
    /// even while the visual line shows the BS/tithi overlays.
    let calendarLine: String?
    /// Active notification panels — the bell badge.
    let notificationCount: Int
    /// Tap on the bell: push the Updates leaf.
    let onOpenUpdates: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                NavigationLink(value: LeafDestination.settings) {
                    ReferenceIconArtwork(name: "settings", diameter: 32)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("home.hub.settings"))
                .accessibilityIdentifier("home.settings")
                NavigationLink(value: LeafDestination.profile) {
                    IconBadge(systemImage: "person.crop.circle.fill", tint: .profile, diameter: 32)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("home.hub.profile"))
                .accessibilityIdentifier("home.profile")
                if dynamicTypeSize <= .large {
                    calendarButton
                        .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 8)
                }
                NotificationBellButton(count: notificationCount, action: onOpenUpdates)
                EmergencyIconButton()
            }
            if dynamicTypeSize > .large {
                calendarButton
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
    }

    private var calendarButton: some View {
        NavigationLink(value: LeafDestination.calendar) {
            dateLineView
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("home.hub.calendar"))
        .accessibilityValue(Text(calendarLine ?? ""))
    }

    /// Compact date content; the whole center target opens Calendar.
    @ViewBuilder
    private var dateLineView: some View {
        VStack(alignment: .center, spacing: 3) {
            if let line = dateLine {
                Text(line.primary)
                    .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !line.overlays.isEmpty {
                    Text(line.overlays.joined(separator: " • "))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                   weight: .medium))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension HomeTopBar: Equatable {
    /// The date line, its a11y value and the badge count — the three
    /// values this bar renders. The closures are deliberately out: see
    /// the equality rule in `HomePresentationState.swift`.
    static func == (lhs: HomeTopBar, rhs: HomeTopBar) -> Bool {
        lhs.dateLine == rhs.dateLine
            && lhs.calendarLine == rhs.calendarLine
            && lhs.notificationCount == rhs.notificationCount
    }
}

// MARK: - Quick access row (quick-access-apps task, 2026-09-06)

/// The user's favourite apps as one-tap launch tiles, above the Talk
/// hero. Deliberately an inline row, NOT a HomeWidget — the row has no
/// widget lifecycle needs and the home-screen widget system is a separate
/// concern (documented in the task design). The trailing plus tile opens
/// Settings → Quick apps; the row renders only while at least one
/// favourite exists (the caller's `if`).
struct QuickAccessStrip: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var largeTypeTileWidth: CGFloat = 92
    @State private var availableWidth: CGFloat = 0
    let apps: [AppLauncher.App]
    /// Launch through the coordinator, including its installed-app check.
    let onLaunch: (AppLauncher.App) -> Void

    private var tileWidth: CGFloat {
        let fourAcrossWidth = max(DesignTokens.minTapTargetSize, (availableWidth - 24) / 4)
        return dynamicTypeSize > .large ? max(largeTypeTileWidth, fourAcrossWidth) : fourAcrossWidth
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(apps) { app in
                    tile(app)
                }
                NavigationLink(value: SettingsView.SettingsDestination.quickApps) {
                    addTile
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.quickAccess.add")
            }
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            availableWidth = width
        }
        .accessibilityIdentifier("home.quickAccess")
    }

    /// Four equal slots fit the viewport at ordinary type sizes. More
    /// favourites and the picker stay accessible by horizontal scrolling.
    private func tile(_ app: AppLauncher.App) -> some View {
        Button {
            onLaunch(app)
        } label: {
            VStack(spacing: 4) {
                AppGlyph(app: app, diameter: 48)
                Text(LocalizedStringKey(app.nameKey))
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: tileWidth, alignment: .top)
            .frame(minHeight: DesignTokens.minTapTargetSize, alignment: .top)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.quickAccess.\(app.id)")
    }

    /// The trailing plus tile opens the Quick apps picker directly.
    private var addTile: some View {
        IconBadge(systemImage: "plus", tint: .apps, diameter: 48)
            .frame(width: tileWidth)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("home.quickAccess.add"))
    }
}


extension QuickAccessStrip: Equatable {
    /// The favourites themselves — the only data the row renders (the
    /// launch closure acts on the `App` its tile was built from).
    static func == (lhs: QuickAccessStrip, rhs: QuickAccessStrip) -> Bool {
        lhs.apps == rhs.apps
    }
}

// MARK: - Talk stage (redesign spec §3.1)

/// The fixed chrome between the top bar and the feedback region: the Talk
/// hero with its status line, the hint carousel, or the yes/no
/// confirmation chips — the branch comes from `state.talkVisuals`, the ONE
/// visual table (call-UI fix, 2026-09-07).
///
/// The session arrives as a plain reference (the hero observes it itself)
/// while `state` travels as a VALUE: the stage's own branch, its hint
/// carousel and its tap behavior all key on it, so it belongs in `==` —
/// that is what makes a voice state flip re-render the stage even though
/// the stage does not observe the session.
struct TalkStage: View {
    @Environment(\.appAppearance) private var appearance
    /// The state the stage renders (branch, hint carousel, tap behavior).
    let state: VoiceSessionState
    /// Handed to the hero, which observes it for its own live updates
    /// (icon, caption, hold eligibility).
    let session: VoiceSessionStateMachine
    /// [P0-2] Manual Talk readiness + the labels the stage shows.
    let voice: VoicePresentationState
    /// Idle hero tap — the manual wake-word simulation that starts a
    /// cycle.
    let onStart: () -> Void
    /// Hero tap mid-cycle / after an error, and the failed-start
    /// recovery: recycle the pipeline.
    let onRecover: () -> Void
    /// Hold-to-reset on the hero.
    let onReset: () -> Void

    @Environment(\.locale) private var locale

    private var visuals: TalkStageVisuals { state.talkVisuals }

    var body: some View {
        Group {
            if visuals.isConfirmation {
                // The boot capsule is gone (user feedback, 2026-09-11):
                // the hero's own spinner + label is the loading UI, and
                // capability diagnostics live in Settings.
                ConfirmationChips(titleKey: visuals.captionKey)
            } else {
                // The stage reads as ONE unit: hero, its status line and
                // the hint carousel each sit ≤4pt apart (visual-polish
                // 2026-09-08). The boot capsule is an overlay on the disc
                // inside `TalkButton`, NOT a flow element here, so nothing
                // below shifts when it collapses.
                VStack(spacing: 4) {
                    TalkButton(session: session,
                               // [P0-2] Manual Talk readiness — the shared
                               // `VoicePipelineReadiness` contract, driven
                               // by the pipeline's own start callback and
                               // the [LAT-M1] boot contract.
                               readiness: voice.readiness,
                               onTap: {
                                   switch state {
                                   case .idle:
                                       onStart()
                                   case .listening, .transcribing, .understanding, .speaking:
                                       // Manual escape hatch: tapping mid-cycle
                                       // cancels and recycles the pipeline (the
                                       // watchdog does the same after 15s).
                                       onRecover()
                                   case .error, .stopped:
                                       // Boot-time start failed (mic denied,
                                       // speech denied, no audio input) —
                                       // tapping retries the pipeline start
                                       // instead of staying dead.
                                       onRecover()
                                   case .awaitingConfirmation:
                                       break
                                   }
                               },
                               statusOverride: voice.statusOverride,
                               onLongPressReset: onReset,
                               // [P0-2] The ONE deterministic recovery for a
                               // failed boot-time start: an explicit button
                               // under the hero. Tapping the hero itself can
                               // therefore never "recover" merely because
                               // startup has not completed.
                               onRecover: onRecover)
                    if visuals.showsHintCarousel {
                        HintCarousel()
                    }
                    if visuals.isError, voice.showsOpenSettings {
                        openSettingsButton
                    }
                }
            }
        }
    }

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("state.error.openSettings", systemImage: "gear")
                .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundColor(appearance.colors.accentForeground)
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .padding(.vertical, 8)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }
}

extension TalkStage: Equatable {
    /// Session identity (never a fold of it), the state that decides the
    /// branch and the tap behavior, and the two [P0-2] value models. The
    /// hero's own live updates ride its `@ObservedObject` subscription;
    /// this comparison exists so HOME's re-render (a feed translation, a
    /// model-download tick, a settings change) cannot re-run the stage.
    static func == (lhs: TalkStage, rhs: TalkStage) -> Bool {
        ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
            && lhs.state == rhs.state
            && lhs.voice == rhs.voice
    }
}

// MARK: - Home timer chip ([HOME-TIMER-CHIP] 2026-09-11)

/// The active-timer chip in the hero's empty area: the NEAREST running
/// timer's remaining time, ticking every second through the house
/// `TimelineView` countdown pattern, plus a one-tap STOP. Renders nothing
/// (no space taken) while no timer runs.
///
/// Honest limits (see `HomeTimerChipModel` for the full doctrine): the
/// chip DERIVES remaining from the app-side record (`endsAt − now`) —
/// the system countdown (Dynamic Island / Lock Screen widget for
/// AlarmKit timers, the delivered one-shot for the UN path) is an
/// independent rendering of the same timer, and pause is not modeled.
///
/// Stop is one tap with the same friction as every other timer surface
/// (the Settings timer row's cancel, the alarm screen's STOP): cancelling
/// a running timer is instantly redoable ("set a timer for 5 minutes"),
/// not the irreversible class of destructive action the app's
/// confirmation dialogs guard.
struct HomeTimerChipView: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var chipLayout: AnyLayout {
        dynamicTypeSize > .large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
    }
    let service: AlarmTimersService
    @Environment(\.locale) private var locale

    @StateObject private var viewModel: HomeTimerChipViewModel

    init(service: AlarmTimersService, onStop: @escaping (UUID) -> Void) {
        self.service = service
        _viewModel = StateObject(wrappedValue: HomeTimerChipViewModel(
            rows: { service.timers },
            stopTimer: onStop))
    }

    var body: some View {
        Group {
            if viewModel.isVisible {
                chip
            }
        }
        // The service publishes on create/cancel/expire; every publish
        // recomputes the snapshot (visibility, nearest, count). The
        // per-second ticking below is the display's own business.
        //
        // `receive(on:)` is load-bearing: `objectWillChange` fires during
        // the service's `willSet` — BEFORE the mutation commits — so a
        // synchronous refresh would read the STALE rows (a cancelled
        // timer would linger until the next publish). The main-queue hop
        // delivers the refresh in a later runloop turn, after the rows
        // are already the new value.
        .onReceive(service.objectWillChange.receive(on: DispatchQueue.main)) {
            viewModel.refresh()
        }
    }

    private var chip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            chipLayout {
                Image(systemName: "timer")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("homeTimer.remaining"))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                   weight: .medium))
                        .foregroundStyle(appearance.colors.textSecondary)
                    Text(HomeTimerChipModel.countdownText(
                        remaining: viewModel.snapshot.endsAt?.timeIntervalSince(context.date) ?? 0,
                        isNepali: isNepali))
                        .font(.system(size: appearance.typography.homeTimerDigitPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                        .monospacedDigit()
                }
                if let label = viewModel.snapshot.label {
                    Text(label)
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                   weight: .regular))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if dynamicTypeSize <= .large { Spacer(minLength: 8) }
                if viewModel.snapshot.activeCount > 1 {
                    multipleBadge
                }
                Button {
                    viewModel.stopNearest()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey("homeTimer.stop")))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .appSurface(cornerRadius: DesignTokens.bubbleCornerRadius)
        }
    }

    /// "+N" when more than one timer runs — the chip shows the NEAREST,
    /// this badge keeps the count honest ("+2" = two more running).
    private var multipleBadge: some View {
        let more = viewModel.snapshot.activeCount - 1
        let text = HomeTimerChipModel.devanagari("+\(more)")
        return Text(isNepali ? text : "+\(more)")
            .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                        weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(appearance.colors.accent.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel(Text(L10n.fmt("homeTimer.multiple", locale: locale, more)))
    }

    private var isNepali: Bool {
        locale.language.languageCode?.identifier == "ne"
    }
}

extension HomeTimerChipView: Equatable {
    /// The service identity is the only datum — the rows reach the chip
    /// through the view model's own subscription, and the stop closure is
    /// deliberately out (the house equality rule).
    static func == (lhs: HomeTimerChipView, rhs: HomeTimerChipView) -> Bool {
        ObjectIdentifier(lhs.service) == ObjectIdentifier(rhs.service)
    }
}

// MARK: - Feedback region: setup strip + live caption / outcome
// (redesign spec §3.1, §6)

/// Everything BELOW the hero inside Home's single scroll region: the
/// transient setup nudge (only while onboarding steps remain) and the
/// live-caption/outcome surface. The whole Home content column can scroll
/// on shorter phones; at larger type the dock joins that same scroll flow.
struct FeedbackRegion: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which feedback branch shows (the capture states own the pill, the
    /// confirmation state owns nothing here — its chips are the stage).
    let state: VoiceSessionState
    /// The transcript the pill renders.
    let caption: String?
    /// The last outcome — identity-compared (its fields are immutable, so
    /// a different instance is a different card).
    let outcome: AppCoordinator.OutcomeSummary?
    /// The optional-setup strip's inputs (design review: ready vs
    /// optional).
    let setup: SetupPresentation
    /// Resume the onboarding wizard.
    let onResumeSetup: () -> Void
    /// Open the conversation-history sheet.
    let onOpenHistory: () -> Void
    /// Dismiss the outcome card for good (coordinator's `dismissOutcome`).
    let onDismissOutcome: () -> Void
    @State private var outcomeExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            // One contextual card at a time. An activity/outcome is more
            // relevant than optional setup and must never be pushed behind
            // the fixed dock; setup returns after the outcome is dismissed.
            if setup.isVisible, outcome == nil {
                SetupStrip(setup: setup, action: onResumeSetup)
            }
            feedback
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }


    @ViewBuilder
    private var feedback: some View {
        switch state {
        case .listening, .transcribing, .understanding:
            // The pill is a transcript surface — its header ("You're
            // saying") plus the real words once STT lands. The capture
            // stage's own phrase lives on the hero's status line; the pill
            // used to repeat that same sentence inside the transcript
            // slot, framed as if it were the user's words (call-UI fix,
            // 2026-09-07).
            LiveCaptionPill(transcript: caption)
        case .awaitingConfirmation:
            // The confirmation chips in `TalkStage` ARE the feedback — an
            // earlier turn's outcome card underneath the yes/no question
            // read as a stray second card (call-UI fix, 2026-09-07).
            EmptyView()
        default:
            if let outcome {
                OutcomeCardView(outcome: outcome,
                                expanded: outcomeExpanded,
                                onTapChip: onOpenHistory,
                                onDismiss: onDismissOutcome)
                .task(id: outcome.id) {
                    // Informational outcomes are compact immediately. Only
                    // a genuinely undoable action earns the expanded card,
                    // and only during its short undo window.
                    outcomeExpanded = outcome.undo != nil
                    guard outcome.undo != nil else { return }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut) { outcomeExpanded = false }
                }
            }
        }
    }
}

extension FeedbackRegion: Equatable {
    /// The state's branch, the transcript, the outcome's identity and the
    /// setup inputs. `OutcomeSummary` is immutable (every field is `let`),
    /// so its `id` fully identifies the card.
    static func == (lhs: FeedbackRegion, rhs: FeedbackRegion) -> Bool {
        lhs.state == rhs.state
            && lhs.caption == rhs.caption
            && lhs.outcome?.id == rhs.outcome?.id
            && lhs.setup == rhs.setup
    }
}

/// The Home missed-call activity tile (call-tracking task, 2026-09-13):
/// one card in Home's activity flow showing the last missed call —
/// "छुटेको कल: बुबा · १० मिनेट अघि" — and pushing the Phone screen, where
/// the full call log lives.
///
/// Where the row comes from: `AppActivityLog`'s missed-call lookup over
/// the assistant's own activity log (a call the app placed and nobody
/// picked up, or an unanswered call the live-call observer reported with
/// no identity — see the tile's two-line presentation). A missed call
/// the app cannot attribute is shown honestly, without a name.
///
/// Why the tile is a NAVIGATION row, not a dial action: the app never
/// dials from a glance (every call goes through the Talk confirmation or
/// a tapped contact), and an anonymous missed call has no number to dial
/// at all. The chevron is the app's standard "this opens a screen"
/// disclosure (UpdatesRowButton draws the same one).
///
/// EQUATABLE by presentation only — the tap closure is re-created every
/// render and always pushes the same destination, the rule every extracted
/// Home view follows (see HomePresentationState).
struct HomeMissedCallTile: View {
    @Environment(\.appAppearance) private var appearance
    let presentation: MissedCallPresentation
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                IconBadge(systemImage: "phone.arrow.down.left",
                          tint: .call,
                          diameter: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(presentation.time)
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
            .appSurface()
        }
        .buttonStyle(.plain)
        // One gesture reads the whole tile: "Missed call: बुबा · १० मिनेट
        // अघि" — then the hint says what the tap does, the same split
        // every row in the app uses.
        .accessibilityLabel(Text(presentation.line))
        .accessibilityHint(Text(LocalizedStringKey("history.openPhone")))
    }
}

extension HomeMissedCallTile: Equatable {
    /// The resolved lines decide the render; the closure never does (it
    /// always pushes the same destination).
    static func == (lhs: HomeMissedCallTile, rhs: HomeMissedCallTile) -> Bool {
        lhs.presentation == rhs.presentation
    }
}

/// The slim setup strip (redesign spec §3.1): Home's only resume
/// affordance for the onboarding wizard, and transient per-user — it must
/// never push the hero off the viewport, so the region below the hero owns
/// it.
///
/// Copy (design review: "clarify ready versus optional setup"): the
/// pending steps are OPTIONAL — the app is usable while they remain, which
/// is exactly what the rendered "3 tasks remaining" treatment failed to
/// say — so the strip now reads "%lld optional setup items" with the
/// reassurance line "Talk now, or finish setup" beneath it. The alert
/// glyph is reserved for the one case that IS a degradation:
/// `needsAttention`, i.e. a startup
/// capability that actually failed.
private struct SetupStrip: View {
    @Environment(\.appAppearance) private var appearance
    let setup: SetupPresentation
    let action: () -> Void

    /// The app language, injected at the root (`\.locale` from
    /// `appCoordinator.activeLocale`) — never `Locale.current`,
    /// which would ignore an in-app language change.
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: setup.needsAttention
                      ? "exclamationmark.triangle.fill"
                      : "checklist")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(setup.needsAttention ? appearance.statusForeground(DesignTokens.stateError) : appearance.colors.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.fmt("home.setupOptionalCount",
                                  locale: locale,
                                  setup.pendingCount))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                    weight: .semibold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(L10n.str("home.setupTalkNow", locale: locale))
                        .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize,
                                                    weight: .regular))
                        .foregroundStyle(appearance.colors.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Minimum, never a fixed height: two 18pt lines — and Nepali
            // at Accessibility XXL — must be able to expand instead of
            // clipping.
            .frame(minHeight: 56)
            .appSurface(cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock (redesign spec §3.1)

/// Reference action dock: help/translation/news/maps above phone/medicine/reminders.
/// Larger accessibility text reflows inside Home's scroll area.
struct HomeDock: View {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onAppliance: () -> Void
    let onLiveTranslate: () -> Void

    private var topColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .top)]
            : Array(repeating: GridItem(.flexible(minimum: 44), spacing: 8, alignment: .top), count: 4)
    }

    private var bottomColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .top)]
            : Array(repeating: GridItem(.flexible(minimum: 44), spacing: 8, alignment: .top), count: 3)
    }

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: topColumns, alignment: .center, spacing: 8) {
                Button(action: onAppliance) {
                    tile(artwork: "settings", titleKey: "plugin.applianceHelper.name", onRail: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.action.appliance")
                Button(action: onLiveTranslate) {
                    tile(artwork: "translate", titleKey: LiveTranslateEntry.labelKey, onRail: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.action.liveTranslate")
                dockItem(.feed, artwork: "news", titleKey: "home.hub.feeds",
                         onRail: false, identifier: "home.action.feed")
                dockItem(.directions, artwork: "location", titleKey: "home.hub.directions",
                         onRail: false, identifier: "home.action.maps")
            }
            .accessibilityIdentifier("home.actionRow")

            LazyVGrid(columns: bottomColumns, alignment: .center, spacing: 8) {
                dockItem(.call, artwork: "phone", titleKey: "home.hub.call",
                         onRail: true, identifier: "home.action.phone")
                dockItem(.meds, artwork: "medicine", titleKey: "home.hub.meds",
                         onRail: true, identifier: "home.action.medication")
                dockItem(.reminders, artwork: "clock", titleKey: "home.hub.reminders",
                         onRail: true, identifier: "home.action.reminders")
            }
            .padding(8)
            .appSurface(role: .dock, cornerRadius: 20)
            .accessibilityIdentifier("home.dock")
        }
        .accessibilityIdentifier("home.actions")
    }

    private func dockItem(_ destination: LeafDestination, artwork: String,
                          titleKey: String, onRail: Bool, identifier: String) -> some View {
        NavigationLink(value: destination) {
            tile(artwork: artwork, titleKey: titleKey, onRail: onRail)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func tile(artwork: String, titleKey: String, onRail: Bool) -> some View {
        if onRail {
            tileContent(artwork: artwork, titleKey: titleKey, onRail: true)
        } else {
            tileContent(artwork: artwork, titleKey: titleKey, onRail: false)
                .appSurface(role: .control, cornerRadius: 12)
        }
    }

    private func tileContent(artwork: String, titleKey: String, onRail: Bool) -> some View {
        VStack(spacing: 4) {
            ReferenceIconArtwork(name: artwork, diameter: onRail ? 44 : 48)
            Text(LocalizedStringKey(titleKey))
                .font(DesignTokens.warmFont(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(onRail ? appearance.colors.onAccent : appearance.colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
