import SwiftUI
import UIKit

/// Shared visual components introduced by the 2026-09-03 UI redesign
/// (docs/superpowers/specs/2026-09-03-ui-visual-redesign-design.md).
/// Every piece here is wired to real `AppCoordinator` state — none of it
/// is placeholder/mock data.

// MARK: - Icon badge (replaces bare gray SF Symbols — spec §2)

struct IconBadge: View {
    let systemImage: String
    let tint: DesignTokens.BadgeTint
    var diameter: CGFloat = DesignTokens.iconBadgeDiameter

    var body: some View {
        Circle()
            .fill(tint.background)
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundColor(tint.tint)
            )
    }
}

// MARK: - Face avatar (initials — spec §3.1/§3.2, replaces generic phone icons)

struct FaceAvatar: View {
    let name: String
    var diameter: CGFloat = DesignTokens.iconBadgeDiameter

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [DesignTokens.talkGlowStart, DesignTokens.talkGlowEnd],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: diameter, height: diameter)
            .overlay(
                Text(initial)
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundColor(.white)
            )
    }
}

// MARK: - Phone dialing (shared by the emergency icon, contact tiles, and
// voice-triggered calling — redesign spec §3.2, trial voice wiring)

enum PhoneDialer {
    static func url(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }
}

// MARK: - Emergency icon (persistent everywhere — spec §3.1/§3.2)

/// The one voice/safety affordance allowed outside Home. Real behavior:
/// posts the same local notification `CommandRouter` posts for a
/// voice-triggered emergency, speaks the ack, and — when a family contact
/// is configured — places a real phone call via `tel:`. Honest about the
/// unconfigured case instead of pretending the action succeeded.
struct EmergencyIconButton: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var showNoContactAlert = false

    var body: some View {
        Button(action: trigger) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DesignTokens.BadgeTint.emergency.tint)
                .frame(width: 32, height: 32)
                .background(DesignTokens.BadgeTint.emergency.background)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(DesignTokens.BadgeTint.emergency.tint.opacity(0.4), lineWidth: 1.2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("common.emergency"))
        .alert("emergency.noContact", isPresented: $showNoContactAlert) {
            Button("common.back", role: .cancel) {}
        }
    }

    private func trigger() {
        coordinator.emergencyNotify()
        guard let contact = coordinator.emergencyContact,
              let url = PhoneDialer.url(for: contact.phone) else {
            showNoContactAlert = true
            return
        }
        UIApplication.shared.open(url)
    }
}

// MARK: - Hint carousel (Home idle — spec §3.1)

/// Rotates through example phrases the user can literally imitate, so the
/// Talk button isn't a blank affordance for someone who's never used a
/// voice assistant. Static, localized catalog — no ML involved.
struct HintCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let phraseKeys = [
        "home.hint.medAck", "home.hint.reminder", "home.hint.call", "home.hint.query"
    ]
    @State private var index = 0

    var body: some View {
        VStack(spacing: 6) {
            Text("home.hint.label")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            Text(LocalizedStringKey(Self.phraseKeys[index]))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(DesignTokens.card)
                .clipShape(Capsule())
                .id(index)
                .transition(.opacity)
            HStack(spacing: 4) {
                ForEach(Self.phraseKeys.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? DesignTokens.talkGlowEnd : DesignTokens.textSecondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    index = (index + 1) % Self.phraseKeys.count
                }
            }
        }
    }
}

// MARK: - Live caption pill (Home, capturing — spec §3.1, §6)

/// Shows a placeholder while capture/transcription is in progress, then
/// reveals the REAL transcript with a brief typewriter effect once it
/// arrives. This is a v1-honest implementation: today's STT is batch-only
/// (no partial-result stream), so this cannot be true word-by-word live
/// captioning — see spec §6. It never fabricates interim text.
struct LiveCaptionPill: View {
    let placeholderKey: String
    let transcript: String?

    private var readyText: String? {
        guard let transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("home.liveCaption.label")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            if let text = readyText {
                // Full text, immediately — NOT a per-character typewriter.
                // A prior version revealed this a character at a time, but
                // `feedbackArea` switches away from this view the instant
                // routing finishes (which can land mid-reveal, especially
                // once the second Gemini call completes) — the animation
                // got cut off mid-sentence, which read as garbled/
                // "disappearing" text (2026-09-04 field report). The real
                // transcript is still fully preserved either way in
                // `AppCoordinator.conversationHistory`; this just stops
                // showing a deliberately-incomplete slice of it.
                Text(text)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .transition(.opacity)
            } else {
                Text(LocalizedStringKey(placeholderKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.15), value: readyText)
    }
}

// MARK: - Outcome card (Home, after routing — spec §3.1, §6)

/// Dual-channel confirmation: the assistant already spoke the reply
/// (`CommandRouter`/`AppCoordinator.speak`), this is the redundant VISUAL
/// channel for users who may not have heard it clearly. `undo` is only
/// present on the summary when a real reversible action backs it
/// (`AppCoordinator` never fabricates one).
struct OutcomeCardView: View {
    let outcome: AppCoordinator.OutcomeSummary
    let expanded: Bool
    let onTapChip: () -> Void

    var body: some View {
        Group {
            if expanded {
                expandedCard
            } else {
                collapsedChip
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var expandedCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(DesignTokens.userBubble)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: outcome.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.text)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                HStack(spacing: 10) {
                    Text(outcome.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                    if let undo = outcome.undo {
                        Button(action: undo) {
                            Text("home.outcome.undo")
                                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                                .foregroundColor(DesignTokens.BadgeTint.emergency.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private var collapsedChip: some View {
        Button(action: onTapChip) {
            HStack(spacing: 6) {
                Circle().fill(DesignTokens.accent).frame(width: 6, height: 6)
                Text(outcome.text)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DesignTokens.card)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Conversation history sheet (Home, on-demand — spec §3.1)

/// Replaces the old always-visible conversation card: opened only by
/// tapping the collapsed outcome chip, so it never competes with the Talk
/// hero for permanent screen space.
struct ConversationHistorySheet: View {
    let exchanges: [AppCoordinator.Exchange]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Capsule()
                    .fill(DesignTokens.textSecondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                Text("home.conversation.title")
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                if exchanges.isEmpty {
                    Text("home.conversation.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)
                } else {
                    ForEach(exchanges.reversed()) { exchange in
                        row(exchange)
                    }
                }
            }
            .padding(20)
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ exchange: AppCoordinator.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(exchange.role == .user ? "home.conversation.user" : "home.conversation.assistant"))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(exchange.role == .user ? DesignTokens.textSecondary : DesignTokens.accent)
            Text(exchange.text)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
            Text(exchange.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }
}
