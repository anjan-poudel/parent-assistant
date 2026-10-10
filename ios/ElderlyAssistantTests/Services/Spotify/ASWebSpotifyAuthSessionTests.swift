import XCTest
import AuthenticationServices
import UIKit
@testable import ElderlyAssistant

/// T-111 — the C-SP-04 presenter half (`ASWebSpotifyAuthSession`) and the
/// `sahayak-spotify` URL-scheme declaration (C-SP-12, design-l2 §11/§19/§26).
///
/// The Gherkin's three scenarios map onto this suite as follows:
///
/// * "The presenter runs the flow and returns the callback" —
///   `testAuthorizePresentsTheGivenURLAndSchemeFromTheResolvedPresenter`,
///   `testTheSheetAnchorsToThePresenterControllersWindow`,
///   `testDeliveredCallbackIsHandedBackUnchangedAndValidatesThroughTheFlow`
///   (`Then the callback URL is handed to SpotifyAuthFlow for exact-match
///   validation`: the returned URL is fed to `SpotifyAuthFlow.parseCallback`),
///   `testUserDismissalSurfacesAsUserCancelled` (`canceledLogin` — the
///   flow's existing dismissal mapping, L2-D7) and
///   `testADismissalReportedWithoutAnErrorAlsoSurfacesAsUserCancelled`.
/// * "Presentation failures are typed and never crash" —
///   `testNoPresentableViewControllerFailsWithNoPresenterAndPresentsNothing`,
///   `testSystemStartFailureCarriesTheNumericReasonCodeOnly` (the system's
///   codes 2/3), `testAStartRefusalWithNoReportedReasonCodeCarriesTheUnreportedCode`,
///   plus the never-crash pins: `testASecondSystemReportIsIgnoredAndCannotResumeTwice`,
///   `testCancelFromTheWaitingTaskDismissesTheSheetAndEndsAsUserCancelled`,
///   `testATaskCancelledBeforeTheSheetExistsNeverPresentsOne`.
/// * "The URL scheme is declared exactly once" —
///   `testSourceInfoPlistDeclaresTheCallbackSchemeExactlyOnce`,
///   `testSourceInfoPlistKeepsTheCalendarShareEntryUnchanged` and
///   `testRunningAppBundleDeclaresTheCallbackScheme` (the plist SOURCE file
///   via `FeatureSourceScan`, plus the built bundle `Bundle.main` — the same
///   source-versus-bundle pairing the app-launcher suite established).
///
/// The system session is stubbed through the `SystemWebAuthSession` seam:
/// the stub records what it was asked to present and completes on command,
/// so every branch is a unit test instead of a device session. No test ever
/// starts a real `ASWebAuthenticationSession` (one is constructed as the
/// `presentationAnchor(for:)` argument, which presents nothing).
final class ASWebSpotifyAuthSessionTests: XCTestCase {

    /// The nonce "minted for this attempt" in the tests.
    private let attemptState = "test-state-4f2c9a"

    // MARK: - Scenario: the presenter runs the flow and returns the callback

    @MainActor
    func testAuthorizePresentsTheGivenURLAndSchemeFromTheResolvedPresenter() async throws {
        let authorizeURL = try configuredAuthorizeURL()
        let stub = StubSystemWebAuthSession()
        let anchor = UIViewController()
        let subject = makeSubject(anchor: anchor, stub: stub)

        let task = Task { @MainActor in
            try await subject.authorize(url: authorizeURL,
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }

        // The seam hands the URL and scheme through unchanged — it is a
        // presenter, not a URL builder (that is `SpotifyAuthFlow`'s half).
        XCTAssertEqual(stub.presentedURL, authorizeURL)
        XCTAssertEqual(stub.presentedScheme, SpotifyAuthFlow.callbackScheme)
        XCTAssertEqual(SpotifyAuthFlow.callbackScheme, "sahayak-spotify",
                       "the one shared constant the plist entry is checked against")
        XCTAssertNotNil(stub.providerAtStart,
                        "the presentation context must be set BEFORE start(), "
                        + "or the system reports its absence as code 2")

        stub.complete(with: try callbackURL(), error: nil)
        _ = try await task.value
    }

    @MainActor
    func testTheSheetAnchorsToThePresenterControllersWindow() async throws {
        // "Given a presentable view controller ... the auth session starts"
        // — the sheet must anchor where the presenter pointed, or the
        // system refuses the context (codes 2/3) instead of showing the
        // consent page.
        let anchor = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = anchor
        window.addSubview(anchor.view)
        XCTAssertTrue(anchor.view.window === window,
                      "test scaffolding: the anchor controller is in its window")

        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: anchor, stub: stub)
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }

        let provider = try XCTUnwrap(stub.providerAtStart)
        // The provider's own requirement takes the session as an argument;
        // constructing one presents nothing.
        let systemSession = ASWebAuthenticationSession(
            url: try configuredAuthorizeURL(),
            callbackURLScheme: SpotifyAuthFlow.callbackScheme,
            completionHandler: { _, _ in })
        XCTAssertTrue(provider.presentationAnchor(for: systemSession) === window,
                      "the system sheet must anchor at the presenter's own window")

        stub.complete(with: try callbackURL(), error: nil)
        _ = try await task.value
    }

    @MainActor
    func testDeliveredCallbackIsHandedBackUnchangedAndValidatesThroughTheFlow() async throws {
        // "Then the callback URL is handed to SpotifyAuthFlow for
        // exact-match validation": the seam returns the delivery byte for
        // byte and the flow's validator is the only door a code comes
        // through — the seam itself never inspects it.
        let callback = try callbackURL()
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)

        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        stub.complete(with: callback, error: nil)

        let returned = try await task.value
        XCTAssertEqual(returned, callback,
                       "the delivered URL is handed back unchanged — nothing is "
                       + "normalised, rewritten or inspected on the way")

        guard case .success(let code) = SpotifyAuthFlow.parseCallback(returned, expectedState: attemptState) else {
            return XCTFail("the delivered callback must validate through SpotifyAuthFlow's "
                           + "exact-match validator")
        }
        XCTAssertEqual(code, "AQD-test-code-1")
    }

    @MainActor
    func testUserDismissalSurfacesAsUserCancelled() async throws {
        // "And a user dismissal surfaces as userCancelled": the system's
        // dismissal signal is `canceledLogin`, and the seam throws the
        // flow's own cancellation case (L2-D7) — never a presentation
        // failure, because nothing failed.
        XCTAssertEqual(ASWebAuthenticationSessionError.canceledLogin.rawValue, 1,
                       "the system constant the dismissal mapping reads")
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)

        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        stub.complete(with: nil,
                      error: NSError(domain: ASWebAuthenticationSessionError.errorDomain,
                                     code: ASWebAuthenticationSessionError.canceledLogin.rawValue))

        let error = await waitForAuthorizeError(task)
        XCTAssertEqual(error, .userCancelled)
    }

    @MainActor
    func testADismissalReportedWithoutAnErrorAlsoSurfacesAsUserCancelled() async throws {
        // Some system versions report an interactive dismissal as a
        // completion with neither a URL nor an error. That is the same
        // claim — the household closed the sheet — so it must surface as
        // the same outcome, not as a fabricated presentation failure.
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)

        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        stub.complete(with: nil, error: nil)

        let error = await waitForAuthorizeError(task)
        XCTAssertEqual(error, .userCancelled)
    }

    @MainActor
    func testThePresenterIsResolvedAtPresentTimeNotConstruction() async throws {
        // The coordinator builds this object before any window exists
        // (AppCoordinator 9314–9322), so a controller captured at
        // construction would be a detached one: resolution happens when
        // authorize runs.
        var anchor: UIViewController?
        let stub = StubSystemWebAuthSession()
        let subject = ASWebSpotifyAuthSession(
            presenter: { anchor },
            systemSessionFactory: { url, scheme, completion in
                stub.record(url: url, scheme: scheme, completion: completion)
                return stub
            })

        anchor = UIViewController()
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        let callback = try callbackURL()
        stub.complete(with: callback, error: nil)
        let returned = try await task.value
        XCTAssertEqual(returned, callback)
    }

    // MARK: - Scenario: presentation failures are typed and never crash

    @MainActor
    func testNoPresentableViewControllerFailsWithNoPresenterAndPresentsNothing() async throws {
        // "Given no presentable view controller exists / When linking is
        // attempted / Then it fails with SpotifyAuthError.noPresenter" —
        // and never a crash, never a silent success, and never a sheet.
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: nil, stub: stub)

        let error = await authorizeError(subject)
        XCTAssertEqual(error, .noPresenter)
        XCTAssertEqual(stub.startCalls, 0, "no sheet is started when there is nowhere to present it")
        XCTAssertNil(stub.presentedURL, "the system session is never even built")
    }

    @MainActor
    func testSystemStartFailureCarriesTheNumericReasonCodeOnly() async throws {
        // "When the session fails to start for any other system reason /
        // Then it fails with presentationFailed(code:) carrying that reason
        // code" — the system's own start failures travel by number.
        let systemCodes = [
            ASWebAuthenticationSessionError.presentationContextNotProvided.rawValue,
            ASWebAuthenticationSessionError.presentationContextInvalid.rawValue,
        ]
        for code in systemCodes {
            let stub = StubSystemWebAuthSession()
            let subject = makeSubject(anchor: UIViewController(), stub: stub)
            let task = Task { @MainActor in
                try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                            callbackURLScheme: SpotifyAuthFlow.callbackScheme)
            }
            await settle { stub.startCalls == 1 }
            stub.complete(with: nil,
                          error: NSError(domain: ASWebAuthenticationSessionError.errorDomain,
                                         code: code))

            let error = await waitForAuthorizeError(task)
            XCTAssertEqual(error, .presentationFailed(code: code),
                           "code \(code) must travel as a number and nothing else")
        }

        // A failure from outside the system domain still keeps its numeric
        // code — the vocabulary is "the system's number", never text.
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        stub.complete(with: nil, error: NSError(domain: "SpotifyWebAuthSystemTests", code: 42))
        let error = await waitForAuthorizeError(task)
        XCTAssertEqual(error, .presentationFailed(code: 42))
    }

    @MainActor
    func testAStartRefusalWithNoReportedReasonCodeCarriesTheUnreportedCode() async throws {
        // `start()` returning false is a refusal the system reports with no
        // error object — no code exists to carry, so the honest stand-in is
        // the documented "no numeric reason" sentinel (still a number,
        // never a string).
        let stub = StubSystemWebAuthSession()
        stub.startResult = false
        let subject = makeSubject(anchor: UIViewController(), stub: stub)

        let error = await authorizeError(subject)
        XCTAssertEqual(ASWebSpotifyAuthSession.unreportedStartFailureCode, 0)
        XCTAssertEqual(error, .presentationFailed(code: ASWebSpotifyAuthSession.unreportedStartFailureCode))
        XCTAssertEqual(stub.startCalls, 1)
    }

    @MainActor
    func testASecondSystemReportIsIgnoredAndCannotResumeTwice() async throws {
        // A late second report — the sheet dismissing AFTER the callback
        // was delivered — must not resume the continuation again: a double
        // resume is a crash, not a bug report. Surviving this test IS the
        // assertion.
        let callback = try callbackURL()
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }
        stub.complete(with: callback, error: nil)

        let returned = try await task.value
        XCTAssertEqual(returned, callback)

        // Delivered after the attempt ended (the await above proves that):
        // it must be dropped, not resume a second time.
        stub.complete(with: nil,
                      error: NSError(domain: ASWebAuthenticationSessionError.errorDomain,
                                     code: ASWebAuthenticationSessionError.canceledLogin.rawValue))
        await Task.yield()
    }

    @MainActor
    func testCancelFromTheWaitingTaskDismissesTheSheetAndEndsAsUserCancelled() async throws {
        // The link flow's timeout cancels the waiting task (L2-D7): the
        // sheet is dismissed and the attempt ends as `.userCancelled` — the
        // flow's own timeout vocabulary — even if the system never calls
        // back (the abandoned-session case the calendar flow taught us).
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        await settle { stub.startCalls == 1 }

        task.cancel()

        let error = await waitForAuthorizeError(task)
        XCTAssertEqual(error, .userCancelled)
        XCTAssertEqual(stub.cancelCalls, 1, "the system sheet is dismissed, not left hanging")
    }

    @MainActor
    func testATaskCancelledBeforeTheSheetExistsNeverPresentsOne() async throws {
        // A caller that was already cancelled when `authorize` runs (a
        // timeout that fired first) must not flash a sheet nobody waits
        // for; the outcome is the same cancellation case.
        let stub = StubSystemWebAuthSession()
        let subject = makeSubject(anchor: UIViewController(), stub: stub)
        let task = Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }
        task.cancel()

        let error = await waitForAuthorizeError(task)
        XCTAssertEqual(error, .userCancelled)
        XCTAssertEqual(stub.startCalls, 0, "a cancelled attempt presents nothing")
    }

    // MARK: - Scenario: the URL scheme is declared exactly once (C-SP-12)

    /// "Given the built app's Info.plist / When CFBundleURLTypes is
    /// inspected / Then the sahayak-spotify scheme is declared with its
    /// callback handler" — the SOURCE file under review, read from the tree
    /// (the app-launcher suite's source-plist convention).
    func testSourceInfoPlistDeclaresTheCallbackSchemeExactlyOnce() throws {
        let urlTypes = try sourceInfoPlistURLTypes()
        let scheme = SpotifyAuthFlow.callbackScheme

        let declaring = urlTypes.filter { entry in
            (entry["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true
        }
        XCTAssertEqual(declaring.count, 1,
                       "CFBundleURLTypes must declare \(scheme) exactly once")

        let entry = try XCTUnwrap(declaring.first)
        XCTAssertEqual(entry["CFBundleURLName"] as? String, "com.elderlyassistant.spotify")
        XCTAssertEqual(entry["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(entry["CFBundleURLSchemes"] as? [String], [scheme],
                       "the entry carries the scheme and only the scheme")

        // The declared scheme is the scheme half of the ONE shared redirect
        // constant that the plist, the Dashboard registration and the
        // exact-match validator all move with (design-l2 §11, risk 1).
        let redirect = try XCTUnwrap(URLComponents(string: SpotifyAuthFlow.redirectURI))
        XCTAssertEqual(redirect.scheme, scheme)
        XCTAssertEqual("\(scheme)://\(SpotifyAuthFlow.callbackHost)", SpotifyAuthFlow.redirectURI)

        // Exactly one entry was added, none removed.
        XCTAssertEqual(urlTypes.count, 2, "the pre-existing entry plus the Spotify one")
    }

    /// "... And the pre-existing URL type entry is unchanged" — the
    /// calendar-share entry keeps every value, so the added dict is the
    /// only difference in the file.
    func testSourceInfoPlistKeepsTheCalendarShareEntryUnchanged() throws {
        let urlTypes = try sourceInfoPlistURLTypes()
        let googleScheme = "com.googleusercontent.apps.906771099595-cdqhrgvdqqm1um8ml76sqm92llriqhfv"

        let declaring = urlTypes.filter { entry in
            (entry["CFBundleURLSchemes"] as? [String]) == [googleScheme]
        }
        XCTAssertEqual(declaring.count, 1,
                       "the calendar-share entry must still be declared exactly once")

        let entry = try XCTUnwrap(declaring.first)
        XCTAssertEqual(entry["CFBundleURLName"] as? String, "com.elderlyassistant.calendarshare")
        XCTAssertEqual(entry["CFBundleTypeRole"] as? String, "Editor")
    }

    /// The plist the DEVICE reads: a declaration that exists only in the
    /// source file (lost on the way into the bundle) would still fail the
    /// hand-off, so the built bundle is checked too.
    func testRunningAppBundleDeclaresTheCallbackScheme() throws {
        let declared = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
            "the test host must expose the app's Info.plist")
        let scheme = SpotifyAuthFlow.callbackScheme
        let declaring = declared.filter { entry in
            (entry["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true
        }
        XCTAssertEqual(declaring.count, 1,
                       "the built app's Info.plist must declare \(scheme) exactly once")
        XCTAssertEqual(declared.count, 2)
    }

    /// "... And the query scheme the deep-link pre-check probes is
    /// declared" — design-l2 §19 edit (1), applied by the wave driver when
    /// the W2 dispatch surfaced that the §19 edit set had no task owner:
    /// `SpotifyTool.open`'s `canOpenURL` pre-check is only honest when the
    /// probed scheme is declared here (constraint 8).
    func testSourceInfoPlistDeclaresTheSpotifyQueryScheme() throws {
        let plist = try sourceInfoPlist()
        let queries = try XCTUnwrap(
            plist["LSApplicationQueriesSchemes"] as? [String],
            "LSApplicationQueriesSchemes is missing from the source Info.plist")
        XCTAssertEqual(queries.filter { $0 == "spotify" }.count, 1,
                       "the probed deep-link scheme must be declared exactly once")
        XCTAssertTrue(queries.contains("youtube"),
                      "the pre-existing query schemes must be untouched")
    }

    /// "... And the client-ID seam exists for the Dashboard paste" —
    /// design-l2 §19 edit (3): the key ships in `Info.plist` so
    /// `bundledClientID` reads it and the session stays dormant until the
    /// OD-S2 owner action pastes the Dashboard value into this exact key.
    /// As of 2026-10-07 the owner's Dashboard client ID is pasted (OD-S2
    /// step 4). This test keeps the seam honest: the key must exist and
    /// carry no stray whitespace; the value itself is public by definition
    /// (ADR-SP-01) and deliberately not pinned here.
    func testSourceInfoPlistCarriesTheSpotifyClientIDKey() throws {
        let plist = try sourceInfoPlist()
        let value = try XCTUnwrap(
            plist["SpotifyClientID"] as? String,
            "SpotifyClientID (blank until the OD-S2 Dashboard paste) is missing")
        XCTAssertEqual(value, value.trimmingCharacters(in: .whitespacesAndNewlines),
                       "a pasted client id must not carry stray whitespace")
    }

    // MARK: - Harness

    /// The session under test with the stub system session wired in: the
    /// factory records what it was asked to present and hands back a stub
    /// the test completes on command.
    @MainActor
    private func makeSubject(anchor: UIViewController?,
                             stub: StubSystemWebAuthSession) -> ASWebSpotifyAuthSession {
        ASWebSpotifyAuthSession(presenter: { anchor },
                                systemSessionFactory: { url, scheme, completion in
            stub.record(url: url, scheme: scheme, completion: completion)
            return stub
        })
    }

    /// A configured authorize URL (built by the flow itself, so this suite
    /// never invents one) whose callback will carry `state`.
    private func configuredAuthorizeURL(state: String? = nil) throws -> URL {
        let pair = SpotifyAuthFlow.makePKCE()
        return try XCTUnwrap(SpotifyAuthFlow.authorizeURL(clientID: "test-client-123",
                                                          state: state ?? attemptState,
                                                          challenge: pair.challenge))
    }

    /// The callback the system would deliver for the configured attempt.
    private func callbackURL() throws -> URL {
        try XCTUnwrap(URL(string: "sahayak-spotify://callback"
                          + "?code=AQD-test-code-1&state=\(attemptState)"))
    }

    /// The typed error `authorize` threw — and a loud failure if it
    /// returned a callback or leaked a foreign error type.
    @MainActor
    private func authorizeError(_ subject: ASWebSpotifyAuthSession,
                                file: StaticString = #filePath,
                                line: UInt = #line) async -> SpotifyAuthError? {
        await waitForAuthorizeError(Task { @MainActor in
            try await subject.authorize(url: try self.configuredAuthorizeURL(),
                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
        }, file: file, line: line)
    }

    /// Waits for an in-flight `authorize` and returns the typed error it
    /// ended with.
    @MainActor
    private func waitForAuthorizeError(_ task: Task<URL, Error>,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async -> SpotifyAuthError? {
        do {
            _ = try await task.value
            XCTFail("expected a SpotifyAuthError", file: file, line: line)
            return nil
        } catch let error as SpotifyAuthError {
            return error
        } catch {
            // The type only — a foreign error's description can carry
            // content this suite must not print.
            XCTFail("a foreign error escaped the seam: \(type(of: error))",
                    file: file, line: line)
            return nil
        }
    }

    /// Yields until `condition` holds, so the unstructured task driving
    /// `authorize` gets its turn without a fixed sleep.
    @MainActor
    private func settle(until condition: @MainActor () -> Bool,
                        file: StaticString = #filePath,
                        line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("the system session never reached the expected state", file: file, line: line)
    }

    /// `ios/ElderlyAssistant/Info.plist` — the source file under review,
    /// located from this test's own path (`FeatureSourceScan`, the
    /// app-launcher suite's source-plist convention).
    private func sourceInfoPlistURLTypes(file: StaticString = #filePath) throws -> [[String: Any]] {
        let plist = try sourceInfoPlist(file: file)
        return try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]],
                             "CFBundleURLTypes is missing from the source Info.plist")
    }

    /// The source plist as a whole, for the entries outside
    /// CFBundleURLTypes (the query-scheme allowlist, the client-ID seam).
    private func sourceInfoPlist(file: StaticString = #filePath) throws -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Info.plist")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any],
                             "the source Info.plist at \(url.path) did not parse")
    }

    /// A stub `SystemWebAuthSession`: records how it was asked to start,
    /// whether a presentation context was in place by then, and completes
    /// only when the test says so.
    @MainActor
    private final class StubSystemWebAuthSession: SystemWebAuthSession {

        var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
        var startResult = true
        private(set) var startCalls = 0
        private(set) var cancelCalls = 0
        private(set) var providerAtStart: ASWebAuthenticationPresentationContextProviding?
        private(set) var presentedURL: URL?
        private(set) var presentedScheme: String?

        private var completion: ((URL?, Error?) -> Void)?

        func record(url: URL, scheme: String, completion: @escaping (URL?, Error?) -> Void) {
            presentedURL = url
            presentedScheme = scheme
            self.completion = completion
        }

        /// Delivers a system completion report, as the system would.
        func complete(with callback: URL?, error: Error?) {
            completion?(callback, error)
        }

        func start() -> Bool {
            startCalls += 1
            providerAtStart = presentationContextProvider
            return startResult
        }

        func cancel() { cancelCalls += 1 }
    }
}
