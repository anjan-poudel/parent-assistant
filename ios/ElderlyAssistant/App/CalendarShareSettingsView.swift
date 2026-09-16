import SwiftUI
import Foundation

/// "Calendar sharing" settings leaf (calendar & family sharing task,
/// 2026-09-16) — the family-facing half of the Google Calendar bridge:
/// the account, the plain-language disclosure, and the honest status of
/// what is (and is not) leaving the phone.
///
/// The card is driven entirely by `service.status`, and each of the four
/// states says exactly what is happening rather than what could happen:
///  - `notConfigured` — no OAuth client in this build, which is the state
///    the app ships in today — explains that the bridge was never set up
///    and offers NOTHING to tap: a sign-in button here would fail on
///    touch, and a button that cannot work is the silent stub the
///    constitution forbids (design §0);
///  - `signedOut` offers the two ways to get an account;
///  - connected but not yet consented shows the full disclosure and the
///    one action that unlocks sharing — nothing is queued before it;
///  - connected + consented shows the account, the queue, and the two
///    things the family can do about it (share now / stop sharing).
///
/// Both connected states also carry the same sign-out control, because
/// both are the same ACCOUNT on screen and the one moment sign-out matters
/// most is right after signing into the wrong account — before consent.
/// Without it there, an elder who tapped their way into a sibling's
/// Google account could only get out by first agreeing to share their
/// medication names with it. Signing out is local (no round-trip), so it
/// runs without the spinner; it pauses sharing, and the next sign-in
/// re-creates whatever the family still needs (`signOut()`'s own note).
///
/// The service is INJECTED rather than read off the coordinator, the same
/// way `CaregiverNotifySettingsView` takes its settings object: the card
/// then renders the identical instance the share path writes.
///
/// Every error line names a failure CLASS. No associated value is ever
/// rendered — `transport` carries a `URLError` code and `server` a status
/// code, and neither belongs on an elder's screen (constitution C9, and
/// the release log-surface gate's no-raw-upstream rule).
struct CalendarShareSettingsView: View {

    @ObservedObject var service: CalendarShareService
    let locale: Locale

    /// True while a Google round-trip is in flight. ONE flag: every action
    /// here is the same "talk to Google and wait" state, and two flags
    /// would only let the card show two spinners.
    @State private var isWorking = false
    /// The stop-sharing confirmation. Revoking is one reversible tap, but
    /// it is still the only control here that stops something — so it asks
    /// first (design §5).
    @State private var confirmingStop = false

    var body: some View {
        LeafScreen(titleKey: "settings.calendarSharing") {
            VStack(alignment: .leading, spacing: 12) {
                stateCard
                if let error = service.status.lastError {
                    errorCard(error)
                }
            }
        }
        // The status is recomputed on entry: another surface (or the
        // foreground flush) may have moved it since the hub was drawn.
        .onAppear { service.refreshStatus() }
        .alert(L10n.str("calendarShare.stopSharing.confirm", locale: locale),
               isPresented: $confirmingStop) {
            Button(L10n.str("common.cancel", locale: locale), role: .cancel) { }
            Button(L10n.str("calendarShare.stopSharing", locale: locale),
                   role: .destructive) {
                service.revokeConsent()
            }
        }
    }

    // MARK: - State dispatch

    /// Exactly one of the four states is on screen at a time, so the card
    /// can never contradict itself about what is happening.
    @ViewBuilder
    private var stateCard: some View {
        switch service.status.connection {
        case .notConfigured:
            notConfiguredCard
        case .signedOut:
            signedOutCard
        case .connected(let accountEmail):
            if service.status.isConsented {
                connectedCard(accountEmail: accountEmail)
            } else {
                consentCard
            }
        }
    }

    // MARK: - Not configured

    /// Design §0: with no OAuth client id in the bundle GoogleSignIn
    /// cannot even be initialised, so there is no action to offer. The
    /// card carries the whole explanation and nothing else.
    private var notConfiguredCard: some View {
        card {
            Text(L10n.str("calendarShare.notConfigured", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Signed out

    private var signedOutCard: some View {
        card {
            Text(L10n.str("calendarShare.signedOut", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            primaryAction("calendarShare.connect") {
                run { _ = await service.signIn() }
            }
            // The household may have no Google account at all (design §2
            // decision 3) — account creation is the escape hatch, so it is
            // a visible action, not a footnote.
            outlinedAction("calendarShare.createAccount", tint: DesignTokens.accent) {
                run { _ = await service.createAccount() }
            }
            workingRow
        }
    }

    // MARK: - Connected, consent not yet given

    /// The disclosure (design §5, gate 2 of 2). It is re-readable rather
    /// than a one-shot dialog, and it names the two things an elder
    /// actually needs to know: that full titles — medicine names included
    /// — become visible to invited family, and that accepting can be
    /// undone at any time.
    private var consentCard: some View {
        card {
            Text(L10n.str("calendarShare.consent.title", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.str("calendarShare.consent.body", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.str("calendarShare.consent.whoCanSee", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.str("calendarShare.consent.revoke", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            primaryAction("calendarShare.consent.accept") {
                service.acceptConsent()
            }
            signOutAction
        }
    }

    // MARK: - Connected and consented

    private func connectedCard(accountEmail: String?) -> some View {
        card {
            // The address is shown so the family can confirm WHICH account
            // the elder's reminders are going out under; it is never
            // logged (constitution C9).
            if let accountEmail {
                Text(L10n.fmt("calendarShare.connectedAs", locale: locale,
                              accountEmail))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            primaryAction("calendarShare.syncNow") {
                run {
                    await service.flushPending()
                    await service.syncInbound()
                    service.refreshStatus()
                }
            }
            outlinedAction("calendarShare.stopSharing", tint: DesignTokens.stateError) {
                confirmingStop = true
            }
            signOutAction
            workingRow
        }
    }

    /// The account control both connected states share. Quieter than
    /// "stop sharing" above it, and deliberately un-confirmed: it stops
    /// nothing local, it cannot be reached by accident without the
    /// disclosure screen's own tap, and signing back in rebuilds the
    /// twins from the local items.
    private var signOutAction: some View {
        outlinedAction("calendarShare.signOut", tint: DesignTokens.textSecondary) {
            service.signOut()
        }
    }

    /// The queue's honest one-liner: how much is waiting, when it last
    /// went through, or that nothing has gone through yet. Reads counts
    /// and timestamps only — never a title, never an address.
    private var statusLine: String {
        let status = service.status
        if status.pendingCount > 0 {
            return L10n.fmt("calendarShare.status.pending", locale: locale,
                            status.pendingCount)
        }
        if let lastSyncAt = status.lastSyncAt {
            return L10n.fmt("calendarShare.status.synced", locale: locale,
                            syncTime(lastSyncAt))
        }
        return L10n.str("calendarShare.status.waiting", locale: locale)
    }

    /// The last-sync stamp, in the APP's language: `DateFormatter` with an
    /// explicit locale rather than a bare `Date.FormatStyle`, because the
    /// app language is a setting here — the system locale would print a
    /// foreign date beside Nepali copy.
    private func syncTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Errors

    /// The failure line (design §6: a failed share is surfaced, never
    /// swallowed) plus the standing reassurance that local behaviour is
    /// untouched — the invariant this whole feature is built around.
    private func errorCard(_ error: GoogleShareError) -> some View {
        card {
            Text(L10n.str(errorKey(error), locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.stateError)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.str("calendarShare.error.generic", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One catalog key per failure class. The associated values of
    /// `server` and `transport` are deliberately dropped — a status code
    /// and a `URLError` class label are diagnostics, not sentences for an
    /// elder, and the release log-surface rule treats them as the same
    /// kind of raw upstream value that must not reach a surface.
    private func errorKey(_ error: GoogleShareError) -> String {
        switch error {
        case .notSignedIn: return "calendarShare.error.notSignedIn"
        case .notConfigured: return "calendarShare.error.notConfigured"
        case .unauthorized: return "calendarShare.error.unauthorized"
        case .rateLimited: return "calendarShare.error.rateLimited"
        case .server: return "calendarShare.error.server"
        case .notFound: return "calendarShare.error.notFound"
        case .malformedResponse: return "calendarShare.error.malformedResponse"
        case .transport: return "calendarShare.error.transport"
        }
    }

    // MARK: - Shared chrome

    /// The house card: the same paddings, background and corner radius as
    /// `CaregiverNotifySettingsView`'s card (the settings-group pattern).
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The filled action — the one thing this card wants done reads like
    /// the wizard's Save button, at the same tap-target floor.
    private func primaryAction(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.str(key, locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .background(isWorking ? DesignTokens.textSecondary.opacity(0.5)
                                      : DesignTokens.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    /// The quieter action — account creation, and the one destructive
    /// control. Same tap target as the primary; only the fill differs.
    private func outlinedAction(_ key: String, tint: Color,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.str(key, locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    /// The shared "waiting on Google" indicator. Hidden rather than
    /// reserved when idle: an elder should never see a spinner that is
    /// not spinning.
    @ViewBuilder
    private var workingRow: some View {
        if isWorking {
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.str("calendarShare.working", locale: locale))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Runs one Google round-trip behind the shared spinner, so no button
    /// on this card stays tappable while a flow is already on screen.
    private func run(_ work: @escaping () async -> Void) {
        Task {
            isWorking = true
            await work()
            isWorking = false
        }
    }
}
