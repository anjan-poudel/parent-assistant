import SwiftUI
import UIKit

extension Color {
    /// The `Color` for an `AppTheme`'s background (skinnable home,
    /// 2026-09-07) — the single view-layer bridge from the palette's
    /// Foundation-only RGB tuple. Screen backgrounds read
    /// `Color(theme: coordinator.appTheme)` so the whole app re-skins on
    /// one change; swatches (Appearance settings) use it too.
    init(theme: AppTheme) {
        self.init(red: theme.background.red,
                  green: theme.background.green,
                  blue: theme.background.blue)
    }
}

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

/// The OFFICIAL multicolor logo of a quick-access catalog app on a white
/// circle (AppIcons.xcassets — Wikimedia Commons PNGs, 2026-09-07, see
/// the catalog's README for sources), drawn as-is with its own colors, or
/// the SF Symbol stand-in badge when the catalog carries no official logo
/// (Apple built-ins use SF Symbols as their official glyphs; IMO's was
/// removed from simple-icons over trademark concerns and Commons hosts
/// none). Every tile is the same white circle with the logo at the same
/// 0.6-of-diameter inset, whatever the logo's natural aspect, so the row
/// reads uniform like iPhone drawer tiles. Hidden from VoiceOver — the
/// surrounding tile/row reads the app name.
struct AppGlyph: View {
    let app: AppLauncher.App
    let diameter: CGFloat

    var body: some View {
        Group {
            if let imageName = app.imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter * 0.6, height: diameter * 0.6)
                    .frame(width: diameter, height: diameter)
                    .background(Color.white)
                    .clipShape(Circle())
            } else {
                IconBadge(systemImage: app.systemImage, tint: .apps, diameter: diameter)
            }
        }
        .accessibilityHidden(true)
    }
}

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
    /// Deliberately `tel://` WITH slashes (tel-scheme fix, 2026-09-07):
    /// the slashed form only misbehaves for an EMPTY number — iOS shows
    /// a dead Open/Cancel sheet instead of the dialer. This URL always
    /// carries real digits (the guard below returns nil when the phone
    /// normalizes to none), and WITH a number the slashed form dials
    /// correctly. The numberless case lives in
    /// `AppLauncher.App.rootURL`, which special-cases `tel:`/`sms:`
    /// without slashes for the quick-access tiles.
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
                .font(.system(size: 17, weight: .bold))
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

/// The capture-stage transcript surface: the "You're saying" label while
/// the user talks, then the REAL transcript once STT completes. This is a
/// v1-honest implementation: today's STT is batch-only (no
/// partial-result stream), so this cannot be true word-by-word live
/// captioning — see spec §6. It never fabricates interim text.
///
/// There is deliberately NO placeholder body under the label (call-UI
/// fix, 2026-09-07): the pill used to repeat the session state's own
/// phrase (`state.*.status` — e.g. "Go ahead, I'm listening") in the
/// transcript slot, which duplicated the identical sentence already
/// shown on the hero's status line and — sitting under the "You're
/// saying" header — read as a fake transcript ("You're saying: Go ahead,
/// I'm listening") until the real words replaced it. The state phrase
/// lives on the hero's status line; this card holds only the label and
/// the user's actual words.
struct LiveCaptionPill: View {
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
///
/// Text area composition is uniform for every outcome
/// (conversation-panel fix, 2026-09-06): the user's transcript is always
/// rendered as a "you said" row — small caption above the transcript,
/// mirroring the history sheet's user row — ABOVE the assistant's
/// response, so the card reads user-then-assistant like the sheet and a
/// response is never shown without its command. Rows come from
/// `AppCoordinator.OutcomeSummary.rows`, the same pure composition every
/// outcome path funnels through.
struct OutcomeCardView: View {
    let outcome: AppCoordinator.OutcomeSummary
    let expanded: Bool
    let onTapChip: () -> Void

    /// The card's text rows in display order (user transcript — when one
    /// was recorded — above the response).
    private var bodyRows: [AppCoordinator.OutcomeSummary.Row] {
        AppCoordinator.OutcomeSummary.rows(transcript: outcome.transcript,
                                           response: outcome.text)
    }

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
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bodyRows, id: \.self) { row in
                        switch row {
                        case .user(let heard):
                            Text("home.outcome.youSaid")
                                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                                .foregroundColor(DesignTokens.textSecondary)
                            Text(heard)
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                                .foregroundColor(DesignTokens.textPrimary)
                        case .assistant(let response):
                            Text(response)
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                                .foregroundColor(DesignTokens.textPrimary)
                        }
                    }
                }
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
                    .font(.system(size: 15, weight: .bold))
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

/// Pure display-ordering for the conversation history sheet
/// (conversation-panel fix, 2026-09-06). The sheet reads newest-first,
/// but each exchange pair must read user-then-assistant — a plain
/// reversal of the chronological list would show every assistant reply
/// ABOVE the user transcript it answers. So user turns are paired with
/// the assistant turn that directly follows them on the CHRONOLOGICAL
/// list, and the pairs (plus any singletons: an unanswered user turn, an
/// assistant row whose user was trimmed past the cap or never spoke) are
/// emitted newest group first, each pair internally user-then-assistant.
///
/// Callers pass the concatenated chronological history (the coordinator's
/// live window + every older page fetched so far, oldest → newest), so
/// pairing is correct across the window/page seam too — a pair split by
/// pagination is still re-joined. Unit-tested without SwiftUI.
enum HistoryRowOrderer {
    static func newestFirstPaired(from chronological: [AppCoordinator.Exchange])
        -> [AppCoordinator.Exchange] {
        var result: [AppCoordinator.Exchange] = []
        result.reserveCapacity(chronological.count)
        var index = chronological.count
        while index > 0 {
            index -= 1
            let newest = chronological[index]
            // Walk newest → oldest. When the newest row is an assistant
            // reply and the row directly below it in time is its user
            // transcript, emit the PAIR user-first so the reply never
            // renders above its own transcript. Anything else (an
            // unanswered user turn, an orphan assistant row) emits as a
            // singleton in place.
            if index > 0,
               newest.role == .assistant,
               chronological[index - 1].role == .user {
                result.append(chronological[index - 1])
                result.append(newest)
                index -= 1
            } else {
                result.append(newest)
            }
        }
        return result
    }
}

/// Replaces the old always-visible conversation card: opened only by
/// tapping the collapsed outcome chip, so it never competes with the Talk
/// hero for permanent screen space.
///
/// Pagination (local-cache-chat task, 2026-09-06): the sheet opens on the
/// newest `AppCoordinator.conversationHistory` window (up to 20 rows,
/// newest at the top) and offers a "Show more" button that loads the NEXT
/// 20 OLDER exchanges from the persisted history and appends them below —
/// repeating until the 200-entry store is exhausted, then the button
/// disappears. The visible list is the coordinator's live window plus the
/// older pages fetched so far (`@State`): a new exchange landing while
/// the sheet is open appears on top without disturbing pages below. Rows
/// read top-to-bottom as newest → oldest, exactly as the pre-pagination
/// sheet rendered.
///
/// Row pairing (conversation-panel fix, 2026-09-06): within each
/// exchange pair the user's transcript is drawn ABOVE its own assistant
/// reply — `HistoryRowOrderer` pairs the full chronological history
/// (window + older pages so far, re-joined across the pagination seam)
/// before the newest-first flip, so no pair ever reads response-above-
/// transcript the way a bare `.reversed()` did.
struct ConversationHistorySheet: View {
    @ObservedObject var coordinator: AppCoordinator

    /// Older-than-the-window pages already fetched via "Show more",
    /// display order (each page newest-first). Drawn below the live
    /// `coordinator.conversationHistory` window.
    @State private var olderRows: [AppCoordinator.Exchange] = []

    /// The oldest visible row — the boundary the next "Show more" page
    /// must be strictly older than. Falls back to the window's oldest row
    /// until an older page has been fetched.
    private var boundaryID: UUID? {
        olderRows.last?.id ?? coordinator.conversationHistory.last?.id
    }

    /// Display rows, newest group first with each pair user-then-
    /// assistant: the FULL chronological history — every fetched older
    /// page first (oldest → newest), then the live window — fed through
    /// `HistoryRowOrderer`. Concatenation order matters: the orderer
    /// walks its input newest → oldest, so the input must be pure
    /// chronological (older rows before newer) for pairs to be re-joined
    /// across the window/page seam.
    private var visibleRows: [AppCoordinator.Exchange] {
        let window = coordinator.conversationHistory
        let olderChronological = Array(olderRows.reversed())
        return HistoryRowOrderer.newestFirstPaired(from: olderChronological + window)
    }

    private var canShowMore: Bool {
        guard let boundaryID else { return false }
        return coordinator.hasOlderHistory(than: boundaryID)
    }

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
                if visibleRows.isEmpty {
                    Text("home.conversation.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)
                } else {
                    ForEach(visibleRows) { exchange in
                        row(exchange)
                    }
                    if canShowMore {
                        showMoreButton
                    }
                }
            }
            .padding(20)
        }
        .background(Color(theme: coordinator.appTheme).ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    /// Fetches the next 20 older exchanges (oldest → newest from the
    /// coordinator) and flips them below the current rows, so the newest
    /// of the page sits directly under the oldest row already shown.
    /// Exhaustion is handled by `canShowMore` re-evaluating against the
    /// new boundary — an empty page is never appended and the button
    /// disappears the moment nothing older remains.
    private func loadOlderPage() {
        guard let boundaryID else { return }
        let page = coordinator.olderHistory(than: boundaryID)
        guard !page.isEmpty else { return }
        olderRows += page.reversed()
    }

    private var showMoreButton: some View {
        Button(action: loadOlderPage) {
            Text("history.showMore")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.accent)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(DesignTokens.accent.opacity(0.35), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
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
