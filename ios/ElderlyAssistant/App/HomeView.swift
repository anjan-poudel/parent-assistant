import SwiftUI
import UIKit

/// Leaf destinations reachable from the dock (spec §4.3).
enum LeafDestination: Identifiable {
    case meds
    case reminders
    case call
    case settings

    var id: String {
        switch self {
        case .meds: return "meds"
        case .reminders: return "reminders"
        case .call: return "call"
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

    var body: some View {
        NavigationStack {
            ZStack {
                DesignTokens.background.ignoresSafeArea()
                VStack(spacing: 14) {
                    topBar
                    if !coordinator.onboardingState.pendingSteps.isEmpty {
                        setupStrip
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
            .fullScreenCover(isPresented: $showWizard) {
                OnboardingWizardView(startingAt: coordinator.onboardingState.firstPendingStep)
                    .environmentObject(coordinator)
                    .environmentObject(session)
                    .environmentObject(coordinator.modelDownloadService)
                    .environment(\.locale, coordinator.appLanguage.locale)
            }
            .sheet(isPresented: $showHistory) {
                ConversationHistorySheet(exchanges: coordinator.conversationHistory)
            }
        }
    }

    // MARK: - Top bar (redesign spec §3.1)

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(greetingText)
                .font(DesignTokens.greetingFont(size: 22))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer()
            // Settings has exactly one entry point (the dock below) —
            // deliberately not duplicated up here, so there's only ever
            // one "सेटिङ" to find, by voice or by touch.
            EmergencyIconButton()
        }
        .padding(.top, 8)
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: DesignTokens.minTapTargetSize)
            .background(DesignTokens.setupReminder)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Talk stage (redesign spec §3.1)

    private var talkStage: some View {
        Group {
            if session.state == .awaitingConfirmation {
                ConfirmationChips(statusKey: "state.awaitingConfirmation.status")
            } else {
                VStack(spacing: 18) {
                    TalkButton(session: session,
                               statusOverride: session.state == .error ? errorStatusText : nil) {
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
                    if session.state == .idle {
                        HintCarousel()
                    }
                    if session.state == .error,
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
            LiveCaptionPill(placeholderKey: capturePlaceholderKey, transcript: coordinator.lastTranscript)
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

    private var capturePlaceholderKey: String {
        switch session.state {
        case .transcribing: return "state.transcribing.status"
        case .understanding: return "state.understanding.status"
        default: return "state.listening.status"
        }
    }

    // MARK: - Dock (redesign spec §3.1 — replaces the 2×2 hub grid; Home
    // is the only screen that shows it)

    private var dock: some View {
        HStack(spacing: 2) {
            dockItem(.meds, icon: "pills.fill", tint: .meds, titleKey: "home.hub.meds")
            dockItem(.reminders, icon: "clock.fill", tint: .reminders, titleKey: "home.hub.reminders")
            dockCallItem
            dockItem(.settings, icon: "gearshape.fill", tint: .settings, titleKey: "home.hub.settings")
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
                    .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 10, weight: .semibold))
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
        case .call:
            CallView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Greeting text (spec §4.1.1)

    private var greetingText: String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        let hour = Calendar.current.component(.hour, from: Date())
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

    private var isGlowing: Bool { session.state == .idle || session.state == .listening }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onTap) {
                ZStack {
                    if isGlowing && !reduceMotion {
                        breathingRings
                    }
                    if session.state == .listening || session.state == .speaking {
                        Circle()
                            .stroke(session.state.color.opacity(0.28), lineWidth: 10)
                            .frame(width: DesignTokens.talkButtonDiameter + 28,
                                   height: DesignTokens.talkButtonDiameter + 28)
                    }
                    Circle()
                        .fill(heroFill)
                        .frame(width: DesignTokens.talkButtonDiameter,
                               height: DesignTokens.talkButtonDiameter)
                        .shadow(color: session.state.color.opacity(0.35), radius: 10, y: 4)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: session.state.icon)
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
        guard isGlowing else { return AnyShapeStyle(session.state.color) }
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
struct ConfirmationChips: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let statusKey: String

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(DesignTokens.stateUnderstanding)
                    Text(LocalizedStringKey(statusKey))
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
            let response: ConfirmationResponse = isYes ? .yes : .no
            coordinator.handleConfirmationResponse(response)
            coordinator.speak(key: isYes ? "router.confirmationYes" : "router.confirmationNo")
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

// MARK: - State bindings (spec §3.3 table)

extension VoiceSessionState {
    /// Localized button label, resolved against the injected environment
    /// locale (spec §3.2 — the app language, not the system locale).
    func buttonText(locale: Locale) -> String {
        L10n.str(buttonKey, locale: locale)
    }

    /// Localized status line, same resolution as `buttonText(locale:)`.
    func statusText(locale: Locale) -> String {
        L10n.str(statusKey, locale: locale)
    }

    private var buttonKey: String {
        switch self {
        case .idle: return "state.idle.button"
        case .listening: return "state.listening.button"
        case .transcribing: return "state.transcribing.button"
        case .understanding: return "state.understanding.button"
        case .speaking: return "state.speaking.button"
        case .awaitingConfirmation: return "state.awaitingConfirmation.status"
        case .error: return "state.error.button"
        case .stopped: return "state.stopped.button"
        }
    }

    private var statusKey: String {
        switch self {
        case .idle: return "state.idle.status"
        case .listening: return "state.listening.status"
        case .transcribing: return "state.transcribing.status"
        case .understanding: return "state.understanding.status"
        case .speaking: return "state.speaking.status"
        case .awaitingConfirmation: return "state.awaitingConfirmation.status"
        case .error: return "state.error.status"
        case .stopped: return "state.stopped.status"
        }
    }

    var color: Color {
        switch self {
        case .idle, .speaking: return DesignTokens.stateIdle
        case .listening: return DesignTokens.stateListening
        case .transcribing: return DesignTokens.stateTranscribing
        case .understanding: return DesignTokens.stateUnderstanding
        case .awaitingConfirmation: return DesignTokens.stateUnderstanding
        case .error: return DesignTokens.stateError
        case .stopped: return DesignTokens.stateStopped
        }
    }

    var icon: String {
        switch self {
        case .idle: return "mic.fill"
        case .listening: return "ear.fill"
        case .transcribing: return "pencil"
        case .understanding: return "brain.head.profile"
        case .speaking: return "speaker.wave.2.fill"
        case .awaitingConfirmation: return "questionmark"
        case .error: return "exclamationmark"
        case .stopped: return "mic.slash.fill"
        }
    }
}
