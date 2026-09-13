import SwiftUI

// MARK: - Recent activity (history) leaf — call-history task, 2026-09-06

/// "Recent activity": everything the assistant itself has called or
/// messaged, newest first, plus an honest live-call banner while a call
/// is connected. Reads `coordinator.recentActivity` — the store logs ONLY
/// the app's own channel opens (plus the one anonymous unanswered-call
/// row, missed-calls task, 2026-09-07), so this leaf needs no contacts
/// permission and nothing on it ever came from the system call log or
/// another app's messages (iOS platform wall).
///
/// Rows re-initiate the recorded channel on tap (the tap IS the
/// confirmation, same trust model as the contact tiles): phone rows dial,
/// FaceTime rows open FaceTime again, WhatsApp rows open the chat,
/// Messenger rows reopen the thread when a handle is on file (otherwise
/// the app says so honestly), SMS rows re-open the compose sheet. An
/// UNANSWERED row (missed-calls task, 2026-09-07) has no number — iOS
/// masks the caller's identity AND number — so its tap opens the Phone
/// app instead (empty `tel://`), where the call genuinely lives in
/// Recents, one tab away.
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
                Text(ActivityRowText.name(for: entry, locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(caption(for: entry))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if entry.channel == .unanswered {
                // The visible dialer affordance (missed-calls task,
                // 2026-09-07): the WHOLE row is the button and opens the
                // Phone app — the accent circle is the visual affordance
                // inside it, hidden from VoiceOver so the row reads once
                // (the same rule CallView's rows already follow; SwiftUI
                // forbids a button nested inside a button).
                dialerCircle
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Accent ≥44pt phone circle — the unanswered row's "this opens the
    /// Phone app" affordance (missed-calls task, 2026-09-07), mirroring
    /// the trailing circle CallView draws on every activity row.
    private var dialerCircle: some View {
        Image(systemName: "phone.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: DesignTokens.minTapTargetSize,
                   minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.accent)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    /// Row channel symbols (call-history task spec): phone.fill for phone,
    /// video.fill for FaceTime video, the WhatsApp chat bubble, the
    /// Messenger paperplane, message.fill for SMS. FaceTime audio reuses
    /// phone.fill — it IS an audio call surface. Unanswered rows
    /// (missed-calls task, 2026-09-07) wear the missed-call glyph —
    /// phone.arrow.down.left, the incoming-call-that-ended symbol — and
    /// never a name or number (the badge plus the "Unanswered call" name
    /// line are the whole identity the row has).
    private func icon(for channel: AppActivityEntry.Channel) -> String {
        switch channel {
        case .phone, .faceTimeAudio: return "phone.fill"
        case .faceTimeVideo: return "video.fill"
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        case .messenger: return "paperplane.fill"
        case .sms: return "message.fill"
        case .unanswered: return "phone.arrow.down.left"
        }
    }

    /// Every row is a re-openable ACTION, so every row wears the
    /// brand/action role (badge-tint consolidation 2026-09-10 — `.call`
    /// and `.reminders` resolve to the same accent now). A call row and
    /// a message row are told apart by their glyph (phone.fill vs the
    /// chat bubbles) and their caption, not by hue; only the urgency of
    /// an unanswered call gets its own visual weight, and that lives in
    /// the row's dialer circle.
    private func tint(for channel: AppActivityEntry.Channel) -> DesignTokens.BadgeTint {
        switch channel {
        case .phone, .faceTimeVideo, .faceTimeAudio: return .call
        case .whatsapp, .messenger, .sms: return .reminders
        case .unanswered: return .call
        }
    }

    private func caption(for entry: AppActivityEntry) -> String {
        ActivityRowText.caption(for: entry,
                                now: Date(),
                                calendar: Calendar.current,
                                locale: coordinator.activeLocale)
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
        case .unanswered:
            // No number exists to dial — the caller is anonymous by
            // platform design — so the row opens the Phone app, where
            // the call genuinely lives in Recents, one tab away
            // (missed-calls task, 2026-09-07). NOT a dead tap: this is
            // the honest resolution of an anonymous row.
            PhoneAppOpener.openDialer()
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
    /// history.messageLabel), so one gesture reads the row's action. An
    /// UNANSWERED row (missed-calls task, 2026-09-07; attribution,
    /// call-tracking task 2026-09-13) announces what the row is AND what
    /// its tap does — "Unanswered call, Open Phone app" when anonymous,
    /// "Missed call: बुबा, Open Phone app" when the app placed the call
    /// itself — because no name exists to fold into a "call back" phrase
    /// for the anonymous case, and the attributed case must not hide that
    /// the call was missed.
    private func rowAccessibilityLabel(_ entry: AppActivityEntry) -> String {
        let locale = coordinator.activeLocale
        if entry.channel == .unanswered {
            let described = entry.contactName.isEmpty
                ? L10n.str("history.unanswered", locale: locale)
                : MissedCallPresentation.title(for: entry, locale: locale)
            return "\(described), " + L10n.str("history.openPhone", locale: locale)
        }
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
                .foregroundStyle(DesignTokens.BadgeTint.call.tint)
            Text("history.liveCall")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.BadgeTint.call.tint)
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
            .foregroundStyle(DesignTokens.textSecondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// Row-name and caption presentation shared by HistoryView and CallView's
/// recentActivitySection (missed-calls task, 2026-09-07; call-tracking
/// task, 2026-09-13) — a sibling of `HistoryTimeFormat`, resolved at
/// RENDER time so the row never stores a locale string. One home for
/// both call surfaces: the Phone screen's list and the Recent activity
/// leaf render the same rows and drifted apart when each composed its
/// own caption.
enum ActivityRowText {
    /// The row's NAME line. An `.unanswered` row with NO stored name
    /// shows the localized "Unanswered call" label (`history.unanswered`)
    /// because the row is anonymous BY PLATFORM DESIGN: iOS masks the
    /// identity AND the number of calls that involve other apps, so
    /// there is no name to store and no number an address book could
    /// match. An unanswered row that DOES store a name is the one case
    /// the app could honestly fill (it placed the call — see
    /// `OpenedCallAttributor`), and it shows that contact exactly like
    /// every other row.
    static func name(for entry: AppActivityEntry, locale: Locale) -> String {
        if entry.channel == .unanswered, entry.contactName.isEmpty {
            return L10n.str("history.unanswered", locale: locale)
        }
        return entry.contactName
    }

    /// The row's secondary line (call-tracking task, 2026-09-13): the
    /// kind label plus the row's time bucket — "Call · Today",
    /// "Message · Yesterday", and for a missed call the explicit
    /// "Missed call · Today" (`history.missedCall`), which is what makes
    /// a missed row tell itself apart in a list at a glance. The missed
    /// label is NOT redundant with an anonymous row's name line
    /// ("Unanswered call"): the name line says what the row IS, the
    /// caption's label says which kind of call event it was, and the two
    /// differ for attributed rows, whose name line is a real contact.
    static func caption(for entry: AppActivityEntry,
                        now: Date,
                        calendar: Calendar = .current,
                        locale: Locale) -> String {
        let time = HistoryTimeFormat.displayString(for: entry.timestamp,
                                                   now: now,
                                                   calendar: calendar,
                                                   locale: locale)
        if entry.channel == .unanswered {
            return "\(L10n.str("history.missedCall", locale: locale)) · \(time)"
        }
        let kind = L10n.str(entry.kind == .call ? "history.channel.call" : "history.channel.message",
                            locale: locale)
        return "\(kind) · \(time)"
    }
}

/// Pure, static relative-time bucketing for list rows — no clock reads
/// and no hidden singletons, so tests can pin `now`, `calendar`, and
/// `locale`. Activity/history rows pass PAST timestamps; the Reminders
/// leaf's upcoming-events section passes FUTURE ones (upcoming-events
/// task, 2026-09-07), which read the same shape mirrored: later today
/// "Today", tomorrow "Tomorrow", anything further ahead its localized
/// short date.
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
        if interval < 0 {
            // Future timestamps (upcoming-events task, 2026-09-07): the
            // `timestamp >= dayStart` check below would otherwise
            // swallow EVERY future date as "Today". Later today keeps
            // the today bucket, tomorrow gets its own, and anything
            // further ahead mirrors the past side's short date.
            if timestamp >= dayStart {
                return L10n.str("history.timeToday", locale: locale)
            }
            if let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: dayStart),
               timestamp < tomorrowStart {
                return L10n.str("history.timeTomorrow", locale: locale)
            }
            return shortDateFormatter(locale: locale).string(from: timestamp)
        }
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

    /// Minutes-aware "how long ago" line for the Home missed-call tile
    /// (call-tracking task, 2026-09-13) — the same pure, `now`-injected
    /// shape as `displayString`, plus the two buckets a missed call
    /// actually needs: "N minutes ago" under an hour, "N hours ago" under
    /// a day. Anything older falls through to `displayString`'s day
    /// buckets (Today / Yesterday / short date), so the line never
    /// pretends to precision it does not have.
    ///
    /// Numerals follow the app's spoken convention (SpokenTime): the
    /// digits are Devanagari in Nepali, ASCII otherwise — the tile shows
    /// a senior the same numerals the assistant speaks.
    static func relativeString(for timestamp: Date,
                               now: Date,
                               calendar: Calendar = .current,
                               locale: Locale = .current) -> String {
        let interval = now.timeIntervalSince(timestamp)
        if interval >= 0 {
            if interval < 60 {
                return L10n.str("history.timeNow", locale: locale)
            }
            if interval < 3600 {
                let minutes = Int(interval / 60)
                // Singular/plural are separate catalog keys: the English
                // copy must read "1 minute ago", and the app resolves
                // strings by key through `L10n`, not through the catalog's
                // plural variations.
                return L10n.fmt(minutes == 1 ? "history.timeMinuteAgo" : "history.timeMinutesAgo",
                                locale: locale,
                                digitString(minutes, locale: locale))
            }
            if interval < 24 * 3600 {
                let hours = Int(interval / 3600)
                return L10n.fmt(hours == 1 ? "history.timeHourAgo" : "history.timeHoursAgo",
                                locale: locale,
                                digitString(hours, locale: locale))
            }
        }
        return displayString(for: timestamp, now: now, calendar: calendar, locale: locale)
    }

    /// A count in the app's numeral convention (SpokenTime/BikramSambat:
    /// Devanagari under `ne`, ASCII otherwise).
    private static func digitString(_ value: Int, locale: Locale) -> String {
        locale.language.languageCode?.identifier == "ne"
            ? BikramSambat.devanagariDigits(value)
            : String(value)
    }

    /// DESIGN-REVIEW (P2): was a fresh `DateFormatter` per row, per body
    /// evaluation — hundreds of identical formatters for one locale's
    /// answer. `LocaleFormatters` builds one per locale and caches it;
    /// `DateFormatter` is safe to format from multiple threads (iOS 7+),
    /// and the cache is lock-guarded besides, so sharing it is safe.
    private static func shortDateFormatter(locale: Locale) -> DateFormatter {
        LocaleFormatters.shortDate(locale: locale)
    }
}
