import SwiftUI

/// Leaf destinations reachable from the hub cards (spec §4.3).
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

/// Home (spec §4.1): greeting, setup-reminder card, hero Talk button with
/// state bindings, latest conversation card, 2×2 hub cards.
struct HomeView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine

    @State private var showWizard = false

    var body: some View {
        NavigationStack {
            ZStack {
                DesignTokens.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        greeting
                        if !coordinator.onboardingState.pendingSteps.isEmpty {
                            setupReminderCard
                        }
                        talkSection
                        conversationCard
                        hubGrid
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
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
                    .environment(\.locale, coordinator.appLanguage.locale)
            }
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        Text(greetingText)
            .font(DesignTokens.greetingFont())
            .foregroundColor(DesignTokens.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }

    private var setupReminderCard: some View {
        Button {
            showWizard = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remainingText)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Text("home.setupCardHint")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.setupReminder)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var talkSection: some View {
        Group {
            if session.state == .awaitingConfirmation {
                ConfirmationChips(statusKey: "state.awaitingConfirmation.status")
            } else {
                VStack(spacing: 14) {
                    TalkButton(session: session) {
                        if session.state == .idle {
                            coordinator.simulateWakeWordDetection()
                        }
                    }
                }
            }
        }
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("home.conversation.title")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            if coordinator.lastTranscript == nil && coordinator.lastAssistantReply == nil {
                Text("home.conversation.empty")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                if let user = coordinator.lastTranscript {
                    bubble(text: user, labelKey: "home.conversation.user",
                           background: DesignTokens.userBubble,
                           alignment: .leading)
                }
                if let reply = coordinator.lastAssistantReply {
                    bubble(text: reply, labelKey: "home.conversation.assistant",
                           background: DesignTokens.accent,
                           alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    private func bubble(text: String, labelKey: String,
                        background: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(labelKey))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(alignment == .leading
                                 ? DesignTokens.textSecondary
                                 : Color.white.opacity(0.85))
            Text(text)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(alignment == .leading ? DesignTokens.textPrimary : .white)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    private var hubGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                hubCard(.meds, icon: "pills.fill", titleKey: "home.hub.meds")
                hubCard(.reminders, icon: "clock.fill", titleKey: "home.hub.reminders")
            }
            HStack(spacing: 12) {
                hubCard(.call, icon: "phone.fill", titleKey: "home.hub.call")
                hubCard(.settings, icon: "gearshape.fill", titleKey: "home.hub.settings")
            }
        }
    }

    private func hubCard(_ destination: LeafDestination,
                         icon: String, titleKey: String) -> some View {
        NavigationLink(value: destination) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundColor(DesignTokens.accent)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.hubCardMinHeight)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
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

// MARK: - Talk button (spec §3.3, D5)

struct TalkButton: View {
    @ObservedObject var session: VoiceSessionStateMachine
    @Environment(\.locale) private var locale
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onTap) {
                ZStack {
                    if session.state == .listening || session.state == .speaking {
                        Circle()
                            .stroke(session.state.color.opacity(0.28), lineWidth: 10)
                            .frame(width: DesignTokens.talkButtonDiameter + 28,
                                   height: DesignTokens.talkButtonDiameter + 28)
                    }
                    Circle()
                        .fill(session.state.color)
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
            .disabled(session.state != .idle)
            .accessibilityLabel(Text(session.state.buttonText(locale: locale)))

            Text(session.state.statusText(locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .medium))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Confirmation chips (spec §3.3 — awaitingConfirmation)

/// Big yes/no chips shown instead of the Talk button while a medication
/// confirmation challenge is outstanding. Voice still works too — the
/// router routes the next transcript as a yes/no answer.
struct ConfirmationChips: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let statusKey: String

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(DesignTokens.stateUnderstanding)
                Text(LocalizedStringKey(statusKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
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
