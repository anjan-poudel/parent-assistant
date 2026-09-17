import SwiftUI
import Foundation

/// "Calendar sharing" settings leaf (calendar & family sharing task,
/// 2026-09-16; scope honesty 2026-09-17) — the family-facing half of the
/// Google Calendar bridge: the account, the plain-language disclosure,
/// and the honest status of what is (and is not) leaving the phone.
///
/// The card is driven entirely by `service.status`, and each of the FIVE
/// states says exactly what is happening rather than what could happen:
///  - `notConfigured` — no OAuth client in this build, which is the state
///    the app ships in today — explains that the bridge was never set up
///    and offers NOTHING to tap: a sign-in button here would fail on
///    touch, and a button that cannot work is the silent stub the
///    constitution forbids (design §0);
///  - `signedOut` offers the two ways to get an account;
///  - `connectedWithoutScopes` says the account is connected and CANNOT
///    share, and offers the one tap that fixes it (2026-09-17 — before
///    this state existed, a declined consent sheet rendered as "connected
///    and agreed", which is the silent stub again with a friendlier
///    face);
///  - connected but not yet consented shows the full disclosure and the
///    one action that unlocks sharing — nothing is queued before it;
///  - connected + consented shows the account, the queue, and the two
///    things the family can do about it (share now / stop sharing).
///
/// Connecting is TWO steps and the card shows them as two steps: the
/// Google account, then the disclosure that is this app's own gate. The
/// indicator is not decoration — "which of these am I being asked for
/// now" is the question an elder reads a sharing screen to answer, and
/// the disclosure card is otherwise indistinguishable from a repeat of
/// the sign-in they just completed.
///
/// Every connected state carries the same sign-out control, because they
/// are all the same ACCOUNT on screen and the one moment sign-out matters
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

    /// While a Google round-trip is in flight. ONE flag for every action
    /// here — they are all the same "talk to Google and wait" state, and
    /// two flags would only let the card show two spinners. The flag
    /// lives in its own object so the guarantee that it ALWAYS clears is
    /// a unit test rather than a device observation (2026-09-17: a
    /// declined consent sheet left the old `@State` bool set, and with
    /// every control disabled there was no way out of the screen).
    @StateObject private var spinner = CalendarShareFlowSpinner()
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
        // foreground flush) may have moved it since the hub was drawn —
        // including the SCOPE state, which a re-connect elsewhere in the
        // app (or a revocation at Google) can change while this card is
        // off screen. The scope ledger re-checks the LIVE token each
        // time the card appears.
        .onAppear {
            service.refreshStatus()
            run { await service.refreshScopeStatus() }
        }
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

    /// Exactly one of the five states is on screen at a time, so the card
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
                consentCard(accountEmail: accountEmail)
            }
        case .connectedWithoutScopes(let accountEmail):
            missingScopesCard(accountEmail: accountEmail)
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
            stepIndicator(current: 1)
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

    // MARK: - Connected, scope grant missing

    /// Signed in, and unable to share (2026-09-17).
    ///
    /// The state exists because Google's consent sheet can close with the
    /// account connected and the Calendar grant withheld. It is its own
    /// card rather than a warning on the consent card: there is nothing
    /// to agree to here yet — the app has no permission to ask about —
    /// and offering the disclosure first would be asking the family to
    /// consent to a share that cannot happen.
    private func missingScopesCard(accountEmail: String?) -> some View {
        card {
            accountBanner(email: accountEmail)
            stepIndicator(current: 1)
            Text(L10n.str("calendarShare.scopesMissing", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            // The actionable half: what the tap will show, and what to
            // allow when it does. "Reconnect" alone would not tell an
            // elder which of Google's screens they are being sent back
            // to, or what to tap once they are there.
            Text(L10n.str("calendarShare.scopesMissing.howTo", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            primaryAction("calendarShare.scopesMissing.reconnect") {
                // The full flow, not a scope-only retry: it re-runs the
                // grant on the account that is already there, and it is
                // also the path that recovers from a token Google has
                // revoked since.
                run { _ = await service.signIn() }
            }
            signOutAction
            workingRow
        }
    }

    // MARK: - Connected, consent not yet given

    /// The disclosure (design §5, gate 2 of 2). It is re-readable rather
    /// than a one-shot dialog, and it names the two things an elder
    /// actually needs to know: that full titles — medicine names included
    /// — become visible to invited family, and that accepting can be
    /// undone at any time.
    private func consentCard(accountEmail: String?) -> some View {
        card {
            accountBanner(email: accountEmail)
            stepIndicator(current: 2)
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
            accountBanner(email: accountEmail)
            stepIndicator(current: 3)
            Text(statusLine)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            scopeLedgerRows
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

    /// [SCOPE-LEDGER] (2026-09-17) The per-scope truth, asked of Google's
    /// tokeninfo — the rows that end the console guessing. Each required
    /// scope shows granted or missing; one missing scope gets one Grant
    /// button that presents the consent sheet for exactly that scope and
    /// re-checks afterwards. Before the first check has run, the rows
    /// read "checking" — the card refreshes the check on appear.
    @ViewBuilder
    private var scopeLedgerRows: some View {
        let ledger = service.status.scopeStatus
        let displayScopes: [(String, String)] = [
            ("https://www.googleapis.com/auth/calendar", "calendarShare.scope.calendar"),
            ("https://www.googleapis.com/auth/contacts", "calendarShare.scope.contacts"),
        ]
        ForEach(displayScopes, id: \.0) { scope, labelKey in
            HStack(spacing: 10) {
                Image(systemName: ledger.map { $0[scope] == true } == true
                      ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ledger.map { $0[scope] == true } == true
                                     ? DesignTokens.stateSpeaking : DesignTokens.textSecondary)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                Text(L10n.str(labelKey, locale: locale))
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer()
                if ledger?[scope] == false {
                    Button {
                        run { _ = await service.grantMissingScopes() }
                    } label: {
                        Text(L10n.str("calendarShare.scope.grant", locale: locale))
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                            .foregroundStyle(DesignTokens.accent)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Account banner

    /// WHO is connected, at the top of every connected card.
    ///
    /// The address was a thin line of body text before (2026-09-17) and
    /// it is the single most important fact on this screen after the
    /// state itself: a household with more than one Google account has no
    /// other way to tell whether the elder's reminders are going to the
    /// right place, and "which account is this?" is the question every
    /// other control here is answering around. It is never logged
    /// (constitution C9).
    ///
    /// An absent address is not papered over: the banner still says
    /// "signed in to Google", because that much is certainly true, and
    /// invents nothing to fill the second line.
    private func accountBanner(email: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: DesignTokens.minBodyPointSize + 6))
                .foregroundStyle(DesignTokens.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.str("calendarShare.banner.signedIn", locale: locale))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                if let email {
                    Text(email)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.stateVoiceRestWash)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius + 2))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Two-step indicator

    /// The two gates, as two numbered rows: 1 the Google account, 2 this
    /// app's disclosure (design §5 gate 2 of 2).
    ///
    /// `current` is 1, 2 or 3 — 3 meaning both are done. A row that is
    /// neither current nor done stays visible and quiet rather than
    /// disappearing: the shape of the whole job is what makes "you are
    /// not finished yet" legible, and a card that only ever shows the
    /// current step reads as a fresh demand every time.
    private func stepIndicator(current: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(number: 1, titleKey: "calendarShare.step.account",
                    isCurrent: current == 1, isDone: current > 1)
            stepRow(number: 2, titleKey: "calendarShare.step.consent",
                    isCurrent: current == 2, isDone: current > 2)
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(number: Int, titleKey: String,
                         isCurrent: Bool, isDone: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isDone ? DesignTokens.accent
                                 : (isCurrent ? DesignTokens.accent
                                              : DesignTokens.textSecondary.opacity(0.25)))
                    .frame(width: 26, height: 26)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Text(L10n.str(titleKey, locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize,
                              weight: isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? DesignTokens.textPrimary
                                           : DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
    ///
    /// ACTIONABLE, not just honest (2026-09-17). A 401 — the revoked
    /// token, the grant that was never given — used to be a sentence the
    /// family could only read; the fix was the same every time (connect
    /// the account again) and the screen never offered it, so the only
    /// way out was a Settings trip they had no reason to think would
    /// help. The class of failure decides whether that button appears
    /// (`isActionableFromSettings`) — a re-connect offered for a
    /// rate-limit would be a tap that changes nothing.
    ///
    /// A 403 has its own line (`insufficientScopes`, split from the 401
    /// later the same day): the token in hand is the wrong one rather
    /// than a dead one, so its sentence names the extra step that fixes
    /// it — sign out first, so the SDK cannot hand back the token it
    /// minted without the grant — and only then the re-connect button.
    ///
    /// It is PERSISTENT for as long as the failure is: the gateway holds
    /// `lastError` until a call succeeds, so the card stays until the
    /// problem is actually fixed rather than fading on a timer.
    private func errorCard(_ error: GoogleShareError) -> some View {
        card {
            Text(L10n.str(error.settingsMessageKey, locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.stateError)
                .fixedSize(horizontal: false, vertical: true)
            if error.isActionableFromSettings {
                primaryAction("calendarShare.error.reconnect") {
                    run { _ = await service.signIn() }
                }
            }
            Text(L10n.str("calendarShare.error.generic", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
                .background(spinner.isWorking ? DesignTokens.textSecondary.opacity(0.5)
                                              : DesignTokens.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(spinner.isWorking)
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
        .disabled(spinner.isWorking)
    }

    /// The shared "waiting on Google" indicator. Hidden rather than
    /// reserved when idle: an elder should never see a spinner that is
    /// not spinning.
    @ViewBuilder
    private var workingRow: some View {
        if spinner.isWorking {
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
        spinner.run(work)
    }
}

// MARK: - The card's spinner

/// The card's one "a Google round-trip is in flight" flag — and the
/// reason it is an object instead of a `@State` bool.
///
/// The first cut set the bool inside a detached `Task` and cleared it on
/// the next line after the await. On 2026-09-17 a device run found the
/// hole: the elder closed Google's consent sheet, the SDK's async call
/// never resumed, and the card was left DISABLED behind a spinner that
/// was never going to stop — with no control on the screen able to break
/// out of it. Every button on this card is gated on the flag, so a flag
/// that sticks is a screen that is gone.
///
/// Clearing is structural here rather than a second statement someone
/// has to remember to write:
///  - `finish()` is the ONE place the flag goes false, so the completion
///    path, the cancel path and the timeout cannot disagree;
///  - it runs after the work returns whatever the work did — the flag is
///    cleared even when the flow ended in `cancelled`, which is exactly
///    the case that used to hang;
///  - and a safety timer calls it even if the work never returns at all,
///    because "Google's sheet was dismissed without a callback" is a
///    state this app cannot observe from the inside.
@MainActor
final class CalendarShareFlowSpinner: ObservableObject {

    /// How long a flow may hold the card before the spinner gives up on
    /// it.
    ///
    /// Generous on purpose: a real sign-in is a human reading Google's
    /// screens and typing a password, and cutting that short would
    /// re-enable the buttons under their hands. Three minutes is longer
    /// than any plausible flow and far shorter than "until the app is
    /// killed", which was the old behaviour.
    static let defaultTimeout: Duration = .seconds(180)

    @Published private(set) var isWorking = false

    private let timeout: Duration
    private var work: Task<Void, Never>?
    private var safety: Task<Void, Never>?

    init(timeout: Duration = CalendarShareFlowSpinner.defaultTimeout) {
        self.timeout = timeout
    }

    /// Runs one round-trip behind the flag.
    ///
    /// Re-entrant calls are IGNORED rather than queued or run
    /// concurrently: the buttons are disabled while a flow is up, so a
    /// second call means a tap that slipped through, and starting a
    /// second Google sheet on top of the first is the one thing that
    /// must not happen.
    func run(_ work: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        let timeout = self.timeout
        safety = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish()
        }
        self.work = Task { [weak self] in
            await work()
            self?.finish()
        }
    }

    /// Clears the flag and drops both handles. Idempotent: the timeout
    /// and the work both call it, and the late one is a no-op.
    ///
    /// The in-flight work is deliberately NOT cancelled. If the timer is
    /// what got here first, the flow is still Google's to finish — and
    /// the result of it still has to land: the caller's continuation
    /// refreshes the service status when it resumes, which is how a
    /// sheet that was merely slow ends up rendering the truth instead of
    /// being thrown away.
    private func finish() {
        guard isWorking else { return }
        isWorking = false
        safety?.cancel()
        safety = nil
        work = nil
    }
}
