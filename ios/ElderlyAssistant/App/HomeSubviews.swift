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
    /// [P0-2] Boot state the capsule above the disc renders.
    let startup: StartupState
    /// Idle hero tap — the manual wake-word simulation that starts a
    /// cycle.
    let onStart: () -> Void
    /// Hero tap mid-cycle / after an error, and the failed-start
    /// recovery: recycle the pipeline.
    let onRecover: () -> Void
    /// Hold-to-reset on the hero.
    let onReset: () -> Void

    private var visuals: TalkStageVisuals { state.talkVisuals }

    var body: some View {
        Group {
            if visuals.isConfirmation {
                // [BOOT-LATENCY] The spinner is an element of the stage
                // itself — above whatever the stage currently shows — so
                // it stays anchored to the speak area even in the chips
                // branch.
                VStack(spacing: 4) {
                    StartupProgressOverlay()
                    ConfirmationChips(titleKey: visuals.captionKey)
                }
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
                               // by the pipeline's own start callback. The
                               // hero no longer reads the fold status
                               // (`voiceReadinessStatus`) or
                               // `TalkHeroGating`.
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
                               onRecover: onRecover,
                               // [P0-2] The hero's own loading presentation
                               // says "Starting voice…" inside the disc, so
                               // the boot capsule stands down for the boot
                               // stage whose label it would repeat; every
                               // other boot stage keeps it.
                               showsBootCapsule: startup.showsCapsule)
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
            && lhs.startup == rhs.startup
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

    @State private var outcomeExpanded = true

    var body: some View {
        VStack(spacing: 12) {
            if setup.isVisible {
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
                OutcomeCardView(outcome: outcome, expanded: outcomeExpanded) {
                    onOpenHistory()
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

/// The slim, dismissible-by-navigation setup strip (redesign spec §3.1):
/// Home's only resume affordance for the onboarding wizard, and transient
/// per-user — it must never push the hero off the viewport, so the region
/// below the hero owns it.
private struct SetupStrip: View {
    let setup: SetupPresentation
    let action: () -> Void

    /// The app language, injected at the root (`\.locale` from
    /// `appCoordinator.appLanguage.locale`) — never `Locale.current`,
    /// which would ignore an in-app language change.
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DesignTokens.accent)
                Text(L10n.fmt("home.setupRemaining",
                              locale: locale,
                              setup.pendingCount))
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
}

// MARK: - Dock (redesign spec §3.1)

/// The shortcut dock — Home is the only screen that shows it. Two rows of
/// three tiles (calendar-display task, 2026-09-09): one row of six read as
/// a cluttered shelf, so the user asked for two rows — top: appliance
/// helper, directions, feeds; bottom: meds, reminders, call. Same
/// `dockItem` components, same ≥44pt targets, same material card, same
/// accessibility labels.
struct HomeDock: View {
    /// The top family contact's name — its face replaces the generic
    /// phone icon on the call tile when one is configured (redesign spec
    /// §3.1/§3.2).
    let contactName: String?
    /// The appliance vision helper presents app-wide (via
    /// `pendingPluginPresentation`), same as the voice path — a Button,
    /// not a NavigationLink.
    let onAppliance: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                applianceItem
                dockItem(.directions, icon: "map.fill", tint: .directions, titleKey: "home.hub.directions")
                dockItem(.feed, icon: "rectangle.stack.fill", tint: .feeds, titleKey: "home.hub.feeds")
            }
            HStack(spacing: 2) {
                dockItem(.meds, icon: "pills.fill", tint: .meds, titleKey: "home.hub.meds")
                dockItem(.reminders, icon: "clock.fill", tint: .reminders, titleKey: "home.hub.reminders")
                callItem
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
    /// when one is configured.
    private var callItem: some View {
        NavigationLink(value: LeafDestination.call) {
            VStack(spacing: 4) {
                if let contactName {
                    FaceAvatar(name: contactName, diameter: 42)
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

    /// The design §4 "Show Me" dock tile.
    private var applianceItem: some View {
        Button(action: onAppliance) {
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
}

extension HomeDock: Equatable {
    /// The contact name is the only datum the dock renders (the tiles are
    /// static links).
    static func == (lhs: HomeDock, rhs: HomeDock) -> Bool {
        lhs.contactName == rhs.contactName
    }
}
