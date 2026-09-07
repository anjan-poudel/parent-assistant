import SwiftUI

// MARK: - Recent activity (history) leaf — call-history task, 2026-09-06

/// "Recent activity": everything the assistant itself has called or
/// messaged, newest first, plus an honest live-call banner while a call
/// is connected. Reads `coordinator.recentActivity` — the store logs ONLY
/// the app's own channel opens, so this leaf needs no contacts permission
/// and nothing on it ever came from the system call log or another app's
/// messages (iOS platform wall).
///
/// Rows re-initiate the recorded channel on tap (the tap IS the
/// confirmation, same trust model as the contact tiles): phone rows dial,
/// FaceTime rows open FaceTime again, WhatsApp rows open the chat,
/// Messenger rows reopen the thread when a handle is on file (otherwise
/// the app says so honestly), SMS rows re-open the compose sheet.
struct HistoryView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "history.title") {
            VStack(spacing: 12) {
                if coordinator.liveCallActive {
                    liveCallBanner
                }
                if coordinator.recentActivity.isEmpty {
                    emptyStateCard
                } else {
                    activityRows
                }
            }
        }
    }

    // MARK: Rows

    private var activityRows: some View {
        VStack(spacing: 12) {
            ForEach(coordinator.recentActivity) { entry in
                Button {
                    initiate(entry)
                } label: {
                    rowContent(entry)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(rowAccessibilityLabel(entry)))
            }
        }
    }

    private func rowContent(_ entry: AppActivityEntry) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: icon(for: entry.channel),
                      tint: tint(for: entry.channel),
                      diameter: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.contactName)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(caption(for: entry))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Row channel symbols (call-history task spec): phone.fill for phone,
    /// video.fill for FaceTime video, the WhatsApp chat bubble, the
    /// Messenger paperplane, message.fill for SMS. FaceTime audio reuses
    /// phone.fill — it IS an audio call surface.
    private func icon(for channel: AppActivityEntry.Channel) -> String {
        switch channel {
        case .phone, .faceTimeAudio: return "phone.fill"
        case .faceTimeVideo: return "video.fill"
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        case .messenger: return "paperplane.fill"
        case .sms: return "message.fill"
        }
    }

    private func tint(for channel: AppActivityEntry.Channel) -> DesignTokens.BadgeTint {
        switch channel {
        case .phone, .faceTimeVideo, .faceTimeAudio: return .call
        case .whatsapp, .messenger, .sms: return .reminders
        }
    }

    private func caption(for entry: AppActivityEntry) -> String {
        let locale = coordinator.activeLocale
        let kind = L10n.str(entry.kind == .call ? "history.channel.call" : "history.channel.message",
                            locale: locale)
        let time = HistoryTimeFormat.displayString(for: entry.timestamp,
                                                   now: Date(),
                                                   calendar: Calendar.current,
                                                   locale: locale)
        return "\(kind) · \(time)"
    }

    /// Tap re-initiation, per the recorded channel (a row re-opens the
    /// SAME surface the assistant opened before — nothing beyond it).
    private func initiate(_ entry: AppActivityEntry) {
        let name = entry.contactName
        let phone = entry.phone
        switch entry.channel {
        case .phone:
            guard !phone.isEmpty else {
                honestDeadRow(entry)
                return
            }
            coordinator.performSystemContactCall(name: name, phone: phone)
        case .faceTimeVideo:
            coordinator.performFaceTimeCall(name: name, phone: phone, video: true)
        case .faceTimeAudio:
            coordinator.performFaceTimeCall(name: name, phone: phone, video: false)
        case .whatsapp:
            guard !phone.isEmpty else {
                honestDeadRow(entry)
                return
            }
            coordinator.performSystemContactWhatsApp(name: name, phone: phone)
        case .messenger:
            guard let handle = entry.messengerHandle, !handle.isEmpty else {
                // The handle left the row (or was never there — an old
                // voice-path attempt) — say so instead of a silent dead
                // tap; Messenger rows can only be re-opened by handle.
                let locale = coordinator.activeLocale
                coordinator.speak(text: L10n.fmt("router.call.messengerNoHandle",
                                                 locale: locale, name))
                return
            }
            coordinator.performSystemContactMessenger(name: name, handle: handle)
        case .sms:
            coordinator.presentMessageDraft(phone: phone, name: name, body: "")
        }
    }

    /// Honest dead-row line: the number the row stored normalized to
    /// nothing dialable (defensive — records never store one, but a
    /// corrupt/hand-edited payload must not produce a silent dead tap).
    private func honestDeadRow(_ entry: AppActivityEntry) {
        let locale = coordinator.activeLocale
        coordinator.speak(text: L10n.fmt("call.announce.noPhoneNumber",
                                         locale: locale, entry.contactName))
    }

    /// Screen-reader label: "Call <name> back" for call rows,
    /// "Message <name>" for message rows (history.callbackLabel /
    /// history.messageLabel), so one gesture reads the row's action.
    private func rowAccessibilityLabel(_ entry: AppActivityEntry) -> String {
        let locale = coordinator.activeLocale
        if entry.kind == .call {
            return L10n.fmt("history.callbackLabel", locale: locale, entry.contactName)
        }
        return L10n.fmt("history.messageLabel", locale: locale, entry.contactName)
    }

    // MARK: Live-call banner & empty state

    /// Honest, identity-free banner while `liveCallActive` — the detector
    /// knows presence only (CXCallObserver masks whose call it is), and
    /// this banner claims exactly that and no more.
    private var liveCallBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.BadgeTint.call.tint)
            Text("history.liveCall")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.BadgeTint.call.tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.BadgeTint.call.background)
        .clipShape(Capsule())
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var emptyStateCard: some View {
        Text(LocalizedStringKey("history.empty"))
            .font(.system(size: DesignTokens.minBodyPointSize))
            .foregroundColor(DesignTokens.textSecondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// Pure, static time bucketing for activity rows — no clock reads and no
/// hidden singletons, so tests can pin `now`, `calendar`, and `locale`.
enum HistoryTimeFormat {
    static func displayString(for timestamp: Date,
                              now: Date,
                              calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        let interval = now.timeIntervalSince(timestamp)
        if interval >= 0, interval < 60 {
            return L10n.str("history.timeNow", locale: locale)
        }
        // Day buckets are NOW-relative (fix 2026-09-07): the previous
        // `calendar.isDateInToday/isDateInYesterday` read the WALL
        // CLOCK, so the buckets silently depended on the run date — the
        // unit tests (which pin `now`) passed only while the fixture
        // date happened to be the real today. Bucketing off `now`'s own
        // day makes the function a pure function of its inputs.
        let dayStart = calendar.startOfDay(for: now)
        if timestamp >= dayStart {
            return L10n.str("history.timeToday", locale: locale)
        }
        if let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: dayStart),
           timestamp >= yesterdayStart {
            return L10n.str("history.timeYesterday", locale: locale)
        }
        // Older rows get a localized short date in the app's language.
        return shortDateFormatter(locale: locale).string(from: timestamp)
    }

    private static func shortDateFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }
}
