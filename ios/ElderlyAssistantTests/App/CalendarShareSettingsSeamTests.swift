import XCTest
@testable import ElderlyAssistant

/// The two seams the Calendar-sharing Settings card was missing on
/// 2026-09-17, both of them consequences of one device run:
///
///  - the SPINNER. `isWorking` was a `@State` bool set inside a detached
///    `Task` and cleared after the await. The elder closed Google's
///    consent sheet, the SDK never called back, the flag stayed true —
///    and because every control on the card is disabled while it is set,
///    the screen was stuck with no way out. The clearing rule now lives
///    in `CalendarShareFlowSpinner`, where "it always clears" is a test
///    rather than a promise.
///  - the ERROR-to-CARD mapping. It was a private switch in the view, so
///    the only way to know a failure class had a sentence in the catalog
///    (in BOTH languages) was to open the screen and look. It lives on
///    `GoogleShareError` now, and this suite resolves every key through
///    the real catalog.
final class CalendarShareSettingsSeamTests: XCTestCase {

    // MARK: - Spinner: the flag always clears

    @MainActor
    func testSpinnerStartsIdleAndRunsWhileTheWorkIsInFlight() async {
        let spinner = CalendarShareFlowSpinner(timeout: .seconds(30))
        XCTAssertFalse(spinner.isWorking, "an idle card shows no spinner")

        let gate = Gate()
        spinner.run { await gate.wait() }
        XCTAssertTrue(spinner.isWorking)

        await gate.open()
        await waitUntil("the flow to finish") { !spinner.isWorking }
    }

    /// The completion path — and the assertion the old bool got wrong
    /// most often, because the two statements were separate.
    @MainActor
    func testSpinnerClearsWhenTheWorkReturns() async {
        let spinner = CalendarShareFlowSpinner(timeout: .seconds(30))

        spinner.run { await Task.yield() }

        await waitUntil("the spinner to clear") { !spinner.isWorking }
    }

    /// The device bug itself: the flow ENDS — the elder closed Google's
    /// sheet and the SDK resumed — and the card must come back to life.
    /// Modelled as a work closure that returns after the cancellation
    /// outcome, which is what a cancelled flow does.
    @MainActor
    func testSpinnerClearsWhenTheFlowEndsInAUserCancel() async {
        let spinner = CalendarShareFlowSpinner(timeout: .seconds(30))
        let session = FakeCancellingSession()

        spinner.run { _ = await session.signIn() }

        await waitUntil("the spinner to clear after a cancelled flow") { !spinner.isWorking }
        XCTAssertEqual(session.signInCalls, 1, "the cancelled flow really did run")
    }

    /// The case the app cannot observe from the inside: Google's sheet is
    /// dismissed and nothing ever calls back. The safety timer is the
    /// only thing that can unlock the card, so it is asserted on its own.
    @MainActor
    func testSafetyTimeoutClearsTheSpinnerWhenTheWorkNeverReturns() async {
        let spinner = CalendarShareFlowSpinner(timeout: .milliseconds(60))

        spinner.run {
            // A flow that never resumes: longer than the timeout, and
            // never fulfilled.
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        XCTAssertTrue(spinner.isWorking)

        await waitUntil("the safety timeout to clear the spinner") { !spinner.isWorking }
    }

    /// A second tap that slipped past the disabled buttons must not start
    /// a second Google sheet on top of the first.
    @MainActor
    func testSecondRunIsIgnoredWhileTheFirstIsInFlight() async {
        let spinner = CalendarShareFlowSpinner(timeout: .seconds(30))
        let gate = Gate()
        let counter = Counter()

        spinner.run {
            await counter.increment()
            await gate.wait()
        }
        await waitUntil("the first run to start") { await counter.value == 1 }
        spinner.run { await counter.increment() }

        let started = await counter.value
        XCTAssertEqual(started, 1, "the second run never starts")
        await gate.open()
        await waitUntil("the spinner to clear") { !spinner.isWorking }
        let finished = await counter.value
        XCTAssertEqual(finished, 1, "and never runs after the first one clears")
    }

    /// After the safety timeout the card is usable again. This is the
    /// deliberate trade — a slow flow may be re-started while the first
    /// is still out there — and it is strictly better than the state it
    /// replaces, which was a dead screen.
    @MainActor
    func testTheCardIsUsableAgainAfterASafetyTimeout() async {
        let spinner = CalendarShareFlowSpinner(timeout: .milliseconds(50))
        let counter = Counter()

        spinner.run { try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
        await waitUntil("the safety timeout") { !spinner.isWorking }

        spinner.run { await counter.increment() }
        await waitUntil("the second run to finish") { !spinner.isWorking }
        let ran = await counter.value
        XCTAssertEqual(ran, 1)
    }

    // MARK: - Failure class → card copy

    /// Every failure class has its OWN sentence: two classes sharing a
    /// line is how a specific problem becomes a generic shrug.
    func testEveryFailureClassHasItsOwnMessageKey() {
        let errors: [GoogleShareError] = [
            .notSignedIn, .notConfigured, .unauthorized, .insufficientScopes, .rateLimited,
            .server(500), .notFound, .malformedResponse, .transport("timedOut"),
        ]
        let keys = errors.map(\.settingsMessageKey)

        XCTAssertEqual(Set(keys).count, errors.count, "one catalog key per failure class")
        for key in keys {
            XCTAssertTrue(key.hasPrefix("calendarShare.error."),
                          "\(key) follows the card's naming")
        }
    }

    /// The keys are resolved through the REAL catalog in BOTH languages.
    /// `L10n.str` answers with the key itself when a lookup fails, so an
    /// unreferenced key and a missing translation are the same string —
    /// this is the assertion that catches a card shipping in English to
    /// a Nepali household.
    func testEveryFailureMessageResolvesInBothLanguages() {
        let errors: [GoogleShareError] = [
            .notSignedIn, .notConfigured, .unauthorized, .insufficientScopes, .rateLimited,
            .server(500), .notFound, .malformedResponse, .transport("timedOut"),
        ]
        for error in errors {
            for identifier in ["en", "ne"] {
                let locale = Locale(identifier: identifier)
                let text = L10n.str(error.settingsMessageKey, locale: locale)
                XCTAssertNotEqual(text, error.settingsMessageKey,
                                  "\(error.settingsMessageKey) is missing from the \(identifier) catalog")
                XCTAssertFalse(text.isEmpty)
            }
        }
    }

    /// The actionability rule, spelled out as a matrix: the tap offered
    /// is a re-connect, so it appears exactly where re-connecting is the
    /// fix and nowhere else.
    func testReconnectIsOfferedOnlyWhereReconnectingHelps() {
        XCTAssertTrue(GoogleShareError.unauthorized.isActionableFromSettings,
                      "a revoked token or a withheld grant — the OAuth flow IS the fix")
        XCTAssertTrue(GoogleShareError.notSignedIn.isActionableFromSettings,
                      "same dead end, different cause: there is no session to write with")
        XCTAssertTrue(GoogleShareError.insufficientScopes.isActionableFromSettings,
                      "a 403 is refused consent, not a dead token — re-connecting is still the fix")
        XCTAssertFalse(GoogleShareError.rateLimited.isActionableFromSettings,
                      "ours to retry — a re-connect would be a tap that changes nothing")
        XCTAssertFalse(GoogleShareError.server(503).isActionableFromSettings)
        XCTAssertFalse(GoogleShareError.transport("notConnectedToInternet").isActionableFromSettings)
        XCTAssertFalse(GoogleShareError.notFound.isActionableFromSettings,
                      "the goal state is reached — a re-create is the caller's job, not the family's")
        XCTAssertFalse(GoogleShareError.notConfigured.isActionableFromSettings,
                      "no client id in the bundle: no amount of tapping builds one in")
        XCTAssertFalse(GoogleShareError.malformedResponse.isActionableFromSettings)
    }

    /// The 403 line is ACTIONABLE prose, not a shrug (2026-09-17). A 403
    /// after a consent sheet means the token in hand was minted for the
    /// wrong scopes, and the fix has one step the 401 line does not name:
    /// signing out first, so the SDK cannot hand the same token back. A
    /// line that only says "connect again" sends the family round the
    /// same loop — which is why the remedy is asserted, in both
    /// languages, rather than just the fact that some string resolves.
    func testTheInsufficientScopesLineNamesItsOwnRecovery() {
        let key = GoogleShareError.insufficientScopes.settingsMessageKey
        let english = L10n.str(key, locale: Locale(identifier: "en")).lowercased()
        let nepali = L10n.str(key, locale: Locale(identifier: "ne"))

        XCTAssertTrue(english.contains("sign out"),
                      "the 403 line has to name the sign-out step, or the re-connect taps straight back into the same refusal")
        XCTAssertTrue(english.contains("console"),
                      "and where to look when it persists — the console is the only place the two refusals can be told apart")
        XCTAssertNotEqual(nepali, L10n.str(GoogleShareError.unauthorized.settingsMessageKey,
                                           locale: Locale(identifier: "ne")),
                          "its own sentence, not the 401's")
    }

    // MARK: - New card copy, both languages

    /// The four lines this change introduces, resolved the way the card
    /// resolves them. Same reason as above: a missing `ne` entry is
    /// invisible at compile time and glaring on an elder's screen.
    func testTheNewCardCopyResolvesInBothLanguages() {
        let keys = [
            "calendarShare.banner.signedIn",
            "calendarShare.step.account",
            "calendarShare.step.consent",
            "calendarShare.scopesMissing",
            "calendarShare.scopesMissing.howTo",
            "calendarShare.scopesMissing.reconnect",
            "calendarShare.error.reconnect",
        ]
        for key in keys {
            for identifier in ["en", "ne"] {
                let locale = Locale(identifier: identifier)
                let text = L10n.str(key, locale: locale)
                XCTAssertNotEqual(text, key, "\(key) is missing from the \(identifier) catalog")
                XCTAssertFalse(text.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor.
    ///
    /// The spinner is driven by tasks that land on the main actor, so a
    /// bare assertion races them; polling is the honest way to observe
    /// where they got to.
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// A one-shot latch, so a test can hold a flow open deliberately.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// Counts work-closure entries, so "the second run never started" is
    /// an assertion about a number rather than about timing.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

// MARK: - Fakes

/// The account seam, reduced to the one flow this file drives: one that
/// ends in the elder closing Google's sheet.
private final class FakeCancellingSession: GoogleAccountSessionProtocol {
    var isConfigured = true
    var isSignedIn = false
    var accountEmail: String?
    var hasRequiredScopes = false
    private(set) var signInCalls = 0

    func signIn() async -> GoogleSessionOutcome {
        signInCalls += 1
        return .cancelled
    }

    func createAccount() async -> GoogleSessionOutcome { .cancelled }
    /// The launch restore is not what this file drives — it is covered
    /// where the outcome matrix lives (`GoogleAccountSessionTests`) and
    /// where the status is republished (`CalendarShareServiceTests`).
    /// Here it answers the honest "nothing restored".
    func restorePreviousSession() async -> GoogleSessionOutcome { .unavailable }
    func signOut() {}
    func accessToken() async -> String? { nil }
}
