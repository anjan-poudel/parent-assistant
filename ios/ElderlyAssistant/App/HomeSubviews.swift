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
// This is why the split matters for the review's acceptance: a feed
// translation, a model-download tick, a settings change or an unrelated
// timer invalidates HomeView, but `HomeDock`, `HomeTopBar`,
// `QuickAccessStrip` and `TalkStage` all compare equal and their bodies
// never run. Voice animation/state updates invalidate the talk stage (its
// `==` includes the session state) and leave the dock and top bar alone.
//
// iOS 16 floor: these are value-typed slices fed by HomeView, not
// `@Observable` models — see `HomePresentationState.swift` for the
// migration note.

// MARK: - Top bar (redesign spec §3.1)

/// Settings (leading), the date line doubling as the calendar's entry
/// point (centered), the notifications bell and the emergency button
/// (trailing). Equal-width 44pt containers keep the date line visually
/// centered; the gear can never be confused with emergency.
struct HomeTopBar: View {
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
        HStack(alignment: .center, spacing: 8) {
            // Settings stays LEFT-anchored at the leading edge with the
            // date line centered between it and the emergency button, so
            // the gear can never be confused with emergency (2026-09-07).
            // A balancing invisible 44pt sits beside it (the notifications
            // bell joined the trailing cluster on 2026-09-08).
            NavigationLink(value: LeafDestination.settings) {
                IconBadge(systemImage: "gearshape.fill", tint: .settings, diameter: 32)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("home.hub.settings")))
            .frame(width: 44, alignment: .leading)
            Color.clear.frame(width: 44, height: 44)
            Spacer(minLength: 4)
            // The date area doubles as the calendar's entry point
            // (2026-09-06): the calendar lives ON the home screen via this
            // tap target, NOT as a dock item.
            NavigationLink(value: LeafDestination.calendar) {
                dateLineView
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("home.hub.calendar"))
            .accessibilityValue(Text(calendarLine ?? ""))
            Spacer(minLength: 4)
            // The ONE notifications affordance (home-redesign v3,
            // 2026-09-08): a bell with the active-panel badge — the badge
            // count always matches what the Updates leaf lists (same
            // registry instance). Emergency stays at the far edge.
            NotificationBellButton(count: notificationCount, action: onOpenUpdates)
            EmergencyIconButton()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    /// The primary date (default calendar) on the greeting font, the
    /// enabled overlays joined beneath it in caption size.
    @ViewBuilder
    private var dateLineView: some View {
        if let line = dateLine {
            VStack(alignment: .center, spacing: 2) {
                Text(line.primary)
                    .font(DesignTokens.greetingFont(size: 18))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    // [DESIGN-REVIEW] No minimumScaleFactor on essential
                    // localized text — the date/greeting wraps instead
                    // (Nepali at XXXL stays legible).
                    .lineLimit(2)
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
    let apps: [AppLauncher.App]
    /// Tap on a tile: launch through the coordinator, which probes the
    /// scheme again at tap time and speaks honestly when the app has gone
    /// away.
    let onLaunch: (AppLauncher.App) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(apps) { app in
                    tile(app)
                }
                NavigationLink(value: LeafDestination.settings) {
                    addTile
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    /// 56pt badge + name on a 92pt-wide tile, ≥44pt tall — one combined
    /// accessibility element ("WhatsApp, button").
    private func tile(_ app: AppLauncher.App) -> some View {
        Button {
            onLaunch(app)
        } label: {
            VStack(spacing: 4) {
                AppGlyph(app: app, diameter: 56)
                Text(LocalizedStringKey(app.nameKey))
                    // [DESIGN-REVIEW] 18pt caption floor + wrapping —
                    // no minimumScaleFactor on localized tile labels.
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 92)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    /// The trailing plus tile → Settings (LeafDestination.settings), where
    /// the Quick apps picker lives. Same 92pt width as the app tiles so
    /// the row's rhythm stays even.
    private var addTile: some View {
        VStack(spacing: 4) {
            IconBadge(systemImage: "plus", tint: .apps, diameter: 56)
        }
        .frame(width: 92)
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
                    // [LAT-M1] The boot contract's honest line under the
                    // hero: the per-feature preparing caption while the
                    // contract is open, the cold-feature banner once it
                    // settles degraded. Nothing in any other state.
                    if let extraLine = TalkReadinessCopy.extraLine(voice.readiness,
                                                                   locale: locale) {
                        Text(extraLine)
                            .font(DesignTokens.warmFont(
                                size: DesignTokens.minCaptionPointSize,
                                weight: .medium))
                            .foregroundColor(DesignTokens.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                    }
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
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
                .padding(.horizontal, 16)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
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
            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("homeTimer.remaining"))
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                   weight: .medium))
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text(HomeTimerChipModel.countdownText(
                        remaining: viewModel.snapshot.endsAt?.timeIntervalSince(context.date) ?? 0,
                        isNepali: isNepali))
                        .font(.system(size: DesignTokens.homeTimerDigitPointSize, weight: .bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .monospacedDigit()
                }
                if let label = viewModel.snapshot.label {
                    Text(label)
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                   weight: .regular))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if viewModel.snapshot.activeCount > 1 {
                    multipleBadge
                }
                Button {
                    viewModel.stopNearest()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(DesignTokens.stateError)
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey("homeTimer.stop")))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
    }

    /// "+N" when more than one timer runs — the chip shows the NEAREST,
    /// this badge keeps the count honest ("+2" = two more running).
    private var multipleBadge: some View {
        let more = viewModel.snapshot.activeCount - 1
        let text = HomeTimerChipModel.devanagari("+\(more)")
        return Text(isNepali ? text : "+\(more)")
            .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                        weight: .semibold))
            .foregroundStyle(DesignTokens.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DesignTokens.accent.opacity(0.12))
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
/// live-caption/outcome surface. This region between the hero and the
/// pinned bottom cluster is the only part of Home that ever clips, so on
/// an iPhone SE-sized viewport its content scrolls while the hero and
/// dock never leave the screen.
struct FeedbackRegion: View {
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

    @State private var outcomeExpanded = true

    var body: some View {
        VStack(spacing: 12) {
            // [REBALANCE] At most ONE contextual instruction/outcome line
            // under the hero (design review): while a freshly-landed
            // outcome card is EXPANDED it owns the region, and the
            // optional-setup nudge waits its turn — it returns with the
            // card's collapse (6s later). Dismissing the card (X) clears
            // the coordinator's `lastOutcome`, so the stand-down ends
            // permanently and the strip returns for the session.
            if setup.isVisible, !showsExpandedOutcome {
                SetupStrip(setup: setup, action: onResumeSetup)
            }
            feedback
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// A freshly-landed outcome card is on screen and expanded.
    private var showsExpandedOutcome: Bool {
        outcome != nil && outcomeExpanded
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
                    outcomeExpanded = true
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut) { outcomeExpanded = false }
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

/// The slim setup strip (redesign spec §3.1): Home's only resume
/// affordance for the onboarding wizard, and transient per-user — it must
/// never push the hero off the viewport, so the region below the hero owns
/// it.
///
/// Copy (design review: "clarify ready versus optional setup"): the
/// pending steps are OPTIONAL — the app is usable while they remain, which
/// is exactly what the rendered "3 tasks remaining" treatment failed to
/// say — so the strip now reads "%lld optional setup items" with the
/// reassurance line "Talk now, or finish setup" beneath it. Warning
/// styling (the alert glyph and the warm reminder tint) is reserved for
/// the one case that IS a degradation: `needsAttention`, i.e. a startup
/// capability that actually failed.
private struct SetupStrip: View {
    let setup: SetupPresentation
    let action: () -> Void

    /// The app language, injected at the root (`\.locale` from
    /// `appCoordinator.appLanguage.locale`) — never `Locale.current`,
    /// which would ignore an in-app language change.
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: setup.needsAttention
                      ? "exclamationmark.triangle.fill"
                      : "checklist")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(setup.needsAttention
                                     ? DesignTokens.stateError
                                     : DesignTokens.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.fmt("home.setupOptionalCount",
                                  locale: locale,
                                  setup.pendingCount))
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                    weight: .semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(L10n.str("home.setupTalkNow", locale: locale))
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                                    weight: .regular))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Minimum, never a fixed height: two 18pt lines — and Nepali
            // at Accessibility XXL — must be able to expand instead of
            // clipping.
            .frame(minHeight: 56)
            .background(setup.needsAttention
                        ? DesignTokens.setupReminder
                        : DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock (redesign spec §3.1)

/// The shortcut dock — Home is the only screen that shows it. THREE
/// persistent shortcuts (Medication, Phone, Reminders) plus a labeled
/// "More" tile that opens the secondary surface holding the rest
/// (Appliance, Directions, Feeds): the two-row dock gave six destinations
/// equal priority, and for an elderly audience three daily shortcuts plus
/// one clearly labeled secondary surface ranks them honestly. One row of
/// four same-weight tiles also buys every target a practical 56pt instead
/// of the bare 44pt minimum.
struct HomeDock: View {
    /// The top family contact's name — its face replaces the generic
    /// phone icon on the call tile when one is configured (redesign spec
    /// §3.1/§3.2).
    let contactName: String?
    /// The appliance vision helper presents app-wide (via
    /// `pendingPluginPresentation`), same as the voice path.
    let onAppliance: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Secondary row — Appliance, Directions, Feeds, on TOP. Kept
            // VISIBLE (user feedback, 2026-09-11): the review's "More"
            // sheet hid these behind an extra tap; the two-row layout is
            // restored with the secondary destinations above.
            HStack(spacing: 6) {
                applianceItem
                dockItem(.directions, icon: "map.fill", tint: .directions,
                         titleKey: "home.hub.directions")
                dockItem(.feed, icon: "rectangle.stack.fill", tint: .feeds,
                         titleKey: "home.hub.feeds")
            }
            // Very light grooved divider between the rows (user feedback,
            // 2026-09-11): a hairline dark groove with a hairline light
            // highlight just below — the classic embossed separator, kept
            // subtle so it reads as texture, not a border.
            groovedDivider
            // Primary row — Medication, Phone, Reminders, on the BOTTOM
            // (closest to the thumb; user feedback, 2026-09-11).
            HStack(spacing: 6) {
                dockItem(.meds, icon: "pills.fill", tint: .meds, titleKey: "home.hub.meds")
                callItem
                dockItem(.reminders, icon: "clock.fill", tint: .reminders, titleKey: "home.hub.reminders")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    /// The dock's light grooved row separator.
    private var groovedDivider: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.black.opacity(0.06))
                .frame(height: 1)
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
    }

    private func dockItem(_ destination: LeafDestination, icon: String,
                          tint: DesignTokens.BadgeTint, titleKey: String) -> some View {
        NavigationLink(value: destination) {
            tile(icon: icon, tint: tint, titleKey: titleKey)
        }
        .buttonStyle(.plain)
    }

    /// Appliance is not a leaf push — it presents the vision helper
    /// app-wide through the plugin presentation seam.
    private var applianceItem: some View {
        Button(action: onAppliance) {
            tile(icon: "camera.viewfinder", tint: .appliance,
                 titleKey: "plugin.applianceHelper.name")
        }
        .buttonStyle(.plain)
    }

    /// Uses the top family contact's face instead of a generic phone icon
    /// when one is configured.
    private var callItem: some View {
        NavigationLink(value: LeafDestination.call) {
            VStack(spacing: 4) {
                if let contactName {
                    FaceAvatar(name: contactName, diameter: 44)
                } else {
                    IconBadge(systemImage: "phone.fill", tint: .call, diameter: 44)
                }
                tileLabel("home.hub.call")
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One dock tile: a 44pt badge over an 18pt label (the caption token —
    /// navigation labels sit at or above the 18pt floor), on a 56pt
    /// minimum target that grows when the text does.
    private func tile(icon: String, tint: DesignTokens.BadgeTint,
                      titleKey: String) -> some View {
        VStack(spacing: 4) {
            IconBadge(systemImage: icon, tint: tint, diameter: 44)
            tileLabel(titleKey)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
    }

    private func tileLabel(_ titleKey: String) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize, weight: .semibold))
            .foregroundStyle(DesignTokens.textPrimary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension HomeDock: Equatable {
    /// The contact name is the only datum the dock renders: the tiles are
    /// static links, and the More sheet's choices reach the dock as
    /// parameters of the closures it calls — never as captured state.
    static func == (lhs: HomeDock, rhs: HomeDock) -> Bool {
        lhs.contactName == rhs.contactName
    }
}