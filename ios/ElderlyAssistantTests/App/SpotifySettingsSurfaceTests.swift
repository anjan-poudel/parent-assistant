import XCTest
import UIKit
@testable import ElderlyAssistant

/// T-120 — the Settings Spotify section (C-SP-10 / design-l2 §17;
/// FR-SP-016, FR-SP-010, NFR-SP-010). One test per Gherkin scenario,
/// plus the surface-contract sweeps the design's test seam names.
///
/// The view-state half runs the REAL `SpotifyAccountSession` over the
/// shared scripted seams (`SpotifyInMemoryStorage`, a state-echoing auth
/// flow, a scripted transport), so "the surface never disagrees with the
/// session" is observed on the shipped state machine — not on a mock of it.
///
/// What a unit test honestly CANNOT witness (recorded, not faked): the
/// rendered SwiftUI tree — VoiceOver traversal order, the traits SwiftUI
/// assigns to rendered Buttons, and the on-screen frame of a control.
/// Those are asserted where they exist as values (the leaf-state model and
/// the tap-target token) and pinned in the source where they are modifiers
/// (`FeatureSourceScan`, the suite's established pattern); the rendered
/// traversal itself is DV-5's job on the device.
@MainActor
final class SpotifySettingsSurfaceTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    // MARK: - Pinned fixture values

    private static let accessToken = "settings-surface-access-token-1"
    private static let refreshToken = "settings-surface-refresh-token-1"

    /// A deterministic linked record (fixed instants, so equality
    /// assertions are stable — the `SpotifyAccountSessionTests` convention).
    private static func record(product: String?) -> SpotifySessionRecord {
        SpotifySessionRecord(accessToken: accessToken,
                             refreshToken: refreshToken,
                             expiry: Date(timeIntervalSince1970: 1_800_003_600),
                             product: product,
                             scope: "user-read-private user-modify-playback-state",
                             linkedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func tokenBody() -> Data {
        let payload: [String: Any] = [
            "access_token": "fresh-access-token-1",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "fresh-refresh-token-1",
            "scope": "user-read-private user-modify-playback-state",
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private static func profileBody(product: String) -> Data {
        Data(#"{"product":"\#(product)","country":"NP"}"#.utf8)
    }

    // MARK: - Scenario 1: Linking from Settings updates the stated status

    /// The happy path, driven through the real session: the surface's state
    /// follows `link()` to the linked state with exactly one stored record.
    func testScenario1ACompletedLinkMovesTheSurfaceToTheLinkedState() async {
        let world = makeWorld()
        XCTAssertEqual(world.leafState, .notLinked)

        scriptSuccessfulLink(in: world, product: "premium")
        let outcome = await world.session.link()

        XCTAssertEqual(outcome, .linked(.premium))
        XCTAssertEqual(world.flow.authorizeCalls, 1, "the consent seam really ran")
        XCTAssertEqual(world.session.status, .linked(.premium))
        XCTAssertEqual(world.leafState, .linkedPremium)
        XCTAssertEqual(world.leafState.statusKey, "spotifySettings.status.linked",
                       "the linked state renders the shipped Premium line")
        XCTAssertEqual(world.leafState.action, .unlink,
                       "the linked state's primary action is Unlink")
        XCTAssertTrue(world.leafState.actionEnabled)
        XCTAssertEqual(world.leafState.actionKey, "spotifySettings.unlink")

        // Backed by exactly the one record — the surface cannot say
        // "Connected" over an empty store.
        XCTAssertNotNil(world.store.record)
        XCTAssertEqual(world.storage.rawPayloads.keys.sorted(),
                       [SpotifyCredentialStore.storageKey])
    }

    /// The abandoned and the failed flow — one link-failed state with the
    /// same connect action as the retry affordance.
    func testScenario1AnAbandonedFlowShowsTheLinkFailedStateWithTheRetryAffordance() async {
        let world = makeWorld()
        world.flow.script = { _ in throw SpotifyAuthError.userCancelled }

        let outcome = await world.session.link()

        XCTAssertEqual(outcome, .cancelled,
                       "a declined consent sheet is a decision, not a failure")
        XCTAssertEqual(world.session.status, .linkFailed(.userCancelled))
        XCTAssertEqual(world.leafState, .linkFailed)
        XCTAssertEqual(world.leafState.statusKey, "spotifySettings.status.linkFailed")
        XCTAssertEqual(world.leafState.action, .link,
                       "the retry affordance IS the normal connect action")
        XCTAssertTrue(world.leafState.actionEnabled)
        XCTAssertEqual(world.leafState.actionKey, "spotifySettings.link")
        XCTAssertButNoRecordWasStored(world)
    }

    func testScenario1AFailedFlowShowsTheSameLinkFailedState() async {
        let world = makeWorld()
        world.flow.script = { _ in throw SpotifyAuthError.presentationFailed(code: 7) }

        let outcome = await world.session.link()

        XCTAssertEqual(outcome, .failed(.presentationFailed(code: 7)))
        XCTAssertEqual(world.leafState, .linkFailed)
        XCTAssertButNoRecordWasStored(world)
    }

    /// The four caregiver-visible states, each driven on a real session:
    /// one status line and one action apiece (design §17's leaf table).
    func testTheFourCaregiverVisibleStatesMapToTheShippedCopyAndActions() async {
        // Not linked (fresh store).
        let fresh = makeWorld()
        XCTAssertEqual(fresh.leafState, .notLinked)
        XCTAssertEqual(fresh.leafState.statusKey, "spotifySettings.status.notLinked")
        XCTAssertEqual(fresh.leafState.action, .link)
        XCTAssertTrue(fresh.leafState.actionEnabled)

        // Linked, premium.
        let premium = makeWorld(preLinkedRecord: Self.record(product: "premium"))
        XCTAssertEqual(premium.leafState, .linkedPremium)
        XCTAssertEqual(premium.leafState.statusKey, "spotifySettings.status.linked")
        XCTAssertEqual(premium.leafState.action, .unlink)

        // Linked, free.
        let free = makeWorld(preLinkedRecord: Self.record(product: "free"))
        XCTAssertEqual(free.leafState, .linkedFree)
        XCTAssertEqual(free.leafState.statusKey, "spotifySettings.status.freeTier")
        XCTAssertEqual(free.leafState.action, .unlink)

        // Linked, unknown product — L2-D14: rendered and routed as free.
        let unknown = makeWorld(preLinkedRecord: Self.record(product: nil))
        XCTAssertEqual(unknown.leafState, .linkedFree,
                       "an unknown product must render the free-tier line (L2-D14)")

        // Link failed (driven).
        let failed = makeWorld()
        failed.flow.script = { _ in throw SpotifyAuthError.networkUnavailable }
        _ = await failed.session.link()
        XCTAssertEqual(failed.leafState, .linkFailed)
        XCTAssertEqual(failed.leafState.statusKey, "spotifySettings.status.linkFailed")
        XCTAssertEqual(failed.leafState.action, .link)
    }

    /// While the consent sheet owns the flow the only action stays ON the
    /// screen, disabled (design §17) — and the status line does not
    /// announce an outcome that has not happened.
    func testLinkingInFlightDisablesTheOnlyActionWithoutAnnouncingAnOutcome() async {
        let world = makeWorld()
        let gate = Gate()
        world.flow.gate = gate
        world.flow.script = { _ in throw SpotifyAuthError.userCancelled }

        let attempt = Task { await world.session.link() }
        await waitUntil("the session to enter the linking state") {
            world.session.status == .linking
        }

        XCTAssertEqual(world.leafState, .linking)
        XCTAssertFalse(world.leafState.actionEnabled,
                       "the button must be disabled while its sheet is open")
        XCTAssertEqual(world.leafState.statusKey, "spotifySettings.status.notLinked",
                       "no outcome is announced before one exists")

        await gate.open()
        let outcome = await attempt.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(world.leafState, .linkFailed)
    }

    // MARK: - Scenario 2: Unlink confirms, then wipes

    /// The end-to-end wipe the confirm button performs: linked record →
    /// `session.unlink()` → the wipe OBSERVED on the store and on the
    /// encrypted storage's own bytes → back to not linked.
    func testScenario2UnlinkConfirmsThenWipesTheStoreAndReturnsToNotLinked() {
        let world = makeWorld(preLinkedRecord: Self.record(product: "premium"))
        XCTAssertEqual(world.leafState, .linkedPremium)
        XCTAssertNotNil(world.storage.rawPayloads[SpotifyCredentialStore.storageKey],
                        "the fixture must actually hold the record on disk")

        // Exactly what the dialog's destructive button runs.
        let result = world.session.unlink()

        guard case .success = result else {
            return XCTFail("the wipe must succeed against the working store")
        }

        // Observed on the store AND on the raw storage bytes — not by
        // reading the session's own account of itself.
        XCTAssertNil(world.store.record, "the record survives the confirmed wipe")
        XCTAssertNil(world.storage.rawPayloads[SpotifyCredentialStore.storageKey],
                     "the encrypted bytes survive the confirmed wipe")
        XCTAssertTrue(world.storage.keysCarryingMaterial(Self.accessToken).isEmpty,
                      "token material is still on disk after the wipe")
        XCTAssertTrue(world.storage.keysCarryingMaterial(Self.refreshToken).isEmpty)

        // And the surface: back to not linked, offering Link again.
        XCTAssertEqual(world.session.status, .notLinked)
        XCTAssertEqual(world.leafState, .notLinked)
        XCTAssertEqual(world.leafState.actionKey, "spotifySettings.link")

        // The wipe is the one event this path emits, and it carries no
        // metadata (NFR-SP-002).
        XCTAssertEqual(world.bus.events.map { "\($0.eventType)|\($0.outcome)" },
                       ["spotify_unlink|success"])
        XCTAssertTrue(world.bus.events.allSatisfy { $0.metadata.isEmpty })
    }

    /// The confirm half a unit test can witness: the dialog is the shared
    /// confirmation recipe — the shipped `removeConfirm` title, the
    /// destructive confirm that calls the session's wipe, and
    /// `common.back` as cancel.
    func testScenario2TheConfirmationDialogIsTheShippedCopyAndCallsTheWipe() throws {
        let section = try spotifySectionSource()

        XCTAssertTrue(section.contains(#".confirmationDialog("spotifySettings.removeConfirm""#),
                      "the unlink confirmation must be titled by the localised removeConfirm string")
        XCTAssertTrue(section.contains(#"Button("spotifySettings.unlink", role: .destructive)"#),
                      "the confirm button is the caregiver's Remove action, destructive")
        XCTAssertTrue(section.contains(#"Button("common.back", role: .cancel)"#),
                      "cancel is the shipped common.back copy")
        XCTAssertTrue(section.contains("session.unlink()"),
                      "the confirm must run the session's wipe — not a copy of it")
    }

    // MARK: - Scenario 3: The privacy disclosure is present and accurate (M-2)

    /// Every string this surface can show resolves through the REAL
    /// catalog in both languages (the `CalendarShareSettingsSeamTests`
    /// pattern: `L10n.str` answers with the key itself on a miss, so a key
    /// with no translation is caught here).
    func testScenario3EverySectionStringResolvesInBothLanguages() {
        let keys = [
            "spotifySettings.title",
            "spotifySettings.status.notLinked",
            "spotifySettings.status.linkFailed",
            "spotifySettings.status.linked",
            "spotifySettings.status.freeTier",
            "spotifySettings.link",
            "spotifySettings.unlink",
            "spotifySettings.removeConfirm",
            "spotifySettings.privacy",
            "spotifySettings.rolloutNote",
            "common.back",
        ]
        for key in keys {
            for locale in [english, nepali] {
                let text = L10n.str(key, locale: locale)
                XCTAssertNotEqual(text, key,
                                  "\(key) is missing from the \(locale.identifier) catalog")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            XCTAssertNotEqual(L10n.str(key, locale: english),
                              L10n.str(key, locale: nepali),
                              "\(key) is not translated — en and ne resolve identically")
        }
    }

    /// The disclosure and the rollout note are RENDERED (a key that
    /// resolves but no view draws would still be absent from the screen),
    /// and the rollout note says what OD-S2(c) needs it to say: testing,
    /// approved accounts only.
    func testScenario3TheDisclosureAndRolloutNoteAreRenderedAndHonest() throws {
        let section = try spotifySectionSource()
        XCTAssertTrue(section.contains(#""spotifySettings.privacy""#),
                      "the disclosure row must be on the surface (FR-SP-016)")
        XCTAssertTrue(section.contains(#""spotifySettings.rolloutNote""#),
                      "the rollout note must be on the surface (OD-S2(c): honest, never hidden)")

        // The disclosure names the playback activity (M-2) — the surface
        // half of the T-117 pin.
        let privacy = L10n.str("spotifySettings.privacy", locale: english).lowercased()
        XCTAssertTrue(privacy.contains("play commands") && privacy.contains("control playback"),
                      "the M-2 disclosure names the play commands and the playback control: \(privacy)")

        // Development mode is a console-side fact the client cannot
        // observe; while it holds, the shipped note says so plainly.
        let noteEn = L10n.str("spotifySettings.rolloutNote", locale: english).lowercased()
        let noteNe = L10n.str("spotifySettings.rolloutNote", locale: nepali)
        XCTAssertTrue(noteEn.contains("still being tested") && noteEn.contains("approved accounts"),
                      "the rollout note must state the development-mode limit honestly: \(noteEn)")
        XCTAssertTrue(noteNe.contains("परीक्षणमा") && noteNe.contains("स्वीकृत"),
                      "the Nepali rollout note must state the same limit: \(noteNe)")
    }

    // MARK: - Scenario 4: New controls are reachable with assistive technology

    /// Every actionable element's label, as the value the view binds:
    /// each leaf state's action label key, the dialog's confirm label and
    /// its cancel label all resolve in both languages — the machine-
    /// readable half of "every actionable element has a label".
    func testScenario4EveryActionCarriesAWordedLocalisedLabel() {
        let states: [SpotifySettingsLeafState] = [.notLinked, .linking, .linkedPremium,
                                                  .linkedFree, .linkFailed]
        for state in states {
            for locale in [english, nepali] {
                let label = L10n.str(state.actionKey, locale: locale)
                XCTAssertNotEqual(label, state.actionKey,
                                  "\(state.actionKey) does not resolve in \(locale.identifier)")
                XCTAssertFalse(label.isEmpty)
            }
        }
        for key in ["spotifySettings.unlink", "common.back"] {
            for locale in [english, nepali] {
                XCTAssertNotEqual(L10n.str(key, locale: locale), key)
            }
        }
    }

    /// The primary action is a WORDED control (never icon-only), labelled
    /// for VoiceOver, and at least the project's tap target tall — the
    /// source picks `DesignTokens.minTapTargetSize` up by name, so it can
    /// never silently drift below the project minimum.
    func testScenario4TheActionIsWordedAndMeetsTheProjectTapTarget() throws {
        let section = try spotifySectionSource()

        XCTAssertTrue(section.contains("Text(LocalizedStringKey(leafState.actionKey))"),
                      "the action control must render a localised worded label")
        XCTAssertTrue(section.contains(".accessibilityLabel(Text(LocalizedStringKey(leafState.actionKey)))"),
                      "the action control must carry its localised label explicitly")
        XCTAssertTrue(section.contains(".frame(minHeight: DesignTokens.minTapTargetSize)"),
                      "the action control must take the house tap-target token")
        XCTAssertFalse(section.contains("minHeight: 44"),
                       "a hard-coded 44 would stop tracking the project minimum")

        // The token itself is the project's 44 pt floor (DesignTokensTests
        // pins the constant; this pins the surface's dependence on it).
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
    }

    /// The status is carried by TEXT; the glyph beside it is decorative
    /// (colour and icon never carry the state alone, NFR-SP-010), and the
    /// surface's status copy is the pinned per-state key.
    func testScenario4TheStatusIsTextFirstAndTheGlyphIsDecorative() throws {
        let section = try spotifySectionSource()
        XCTAssertTrue(section.contains("Text(LocalizedStringKey(leafState.statusKey))"),
                      "the status line must render the mapped localised text")
        XCTAssertTrue(section.contains(".accessibilityHidden(true)"),
                      "the status glyph must be hidden from assistive tech — the text is the label")
        XCTAssertTrue(section.contains(#".accessibilityIdentifier("settings.spotify.status")"#),
                      "the status element keeps a stable identifier for DV-5")

        // One text key per state, no sharing between distinct meanings.
        let states: [SpotifySettingsLeafState] = [.notLinked, .linkedPremium,
                                                  .linkedFree, .linkFailed]
        XCTAssertEqual(Set(states.map(\.statusKey)).count, states.count)
    }

    // MARK: - Surface contract: no credential UI, no logging, one session

    /// ADR-SP-01 / NFR-SP-002: the section has no credential field, no
    /// token material and no log surface of its own.
    func testTheSectionHoldsNoCredentialFieldAndNoLogSurface() throws {
        let section = try spotifySectionSource()
        for forbidden in ["SecureField", "TextField", "credentialField",
                          "accessToken", "refreshToken", "print(", "os_log", "Logger"] {
            XCTAssertFalse(section.contains(forbidden),
                           "the Spotify section must not carry \(forbidden) (ADR-SP-01 / NFR-SP-002)")
        }
        // The one interactable media control is the action Button — the
        // precondition that makes the absence scan above meaningful.
        XCTAssertTrue(section.contains("Button {"),
                      "the scan did not reach the section's action button")
        XCTAssertTrue(section.contains("session.link()"),
                      "the link action must run the session's own flow")
    }

    /// The section is wired to the coordinator's ONE session (T-119) and
    /// constructs no second account (L2-R2): the destination case hands
    /// over `coordinator.spotifyAccountSession` by name and SettingsTabs
    /// contains no `SpotifyAccountSession(` construction at all.
    func testTheSectionUsesTheCoordinatorsOneSessionAndBuildsNoSecondAccount() {
        let tabs = settingsTabsSource()
        XCTAssertTrue(tabs.contains("case .spotify: SpotifySettingsView(session: coordinator.spotifyAccountSession)"),
                      "the .spotify destination must hand over the coordinator's session")
        XCTAssertEqual(occurrences(of: "SpotifyAccountSession(", in: tabs), 0,
                       "SettingsTabs must never construct a second account session")
        XCTAssertTrue(tabs.contains(#"case .spotify: return "music.note""#),
                      "the row icon is design-l2 §17's pinned music.note")
        XCTAssertTrue(tabs.contains(#"case .spotify: return "spotifySettings.title""#),
                      "the row title is the shipped catalog key")
    }

    // MARK: - World builder

    @MainActor
    private final class SurfaceWorld {
        let storage: SpotifyInMemoryStorage
        let store: SpotifyCredentialStore
        let flow: SurfaceFakeAuthSession
        let transport: SurfaceStubTransport
        let bus: RecordingObservabilityBus
        let session: SpotifyAccountSession

        init(preLinkedRecord: SpotifySessionRecord? = nil) {
            let storage = SpotifyInMemoryStorage()
            let store = SpotifyCredentialStore(storage: storage)
            if let preLinkedRecord {
                store.save(preLinkedRecord)
            }
            let flow = SurfaceFakeAuthSession()
            let transport = SurfaceStubTransport()
            let bus = RecordingObservabilityBus()
            let session = SpotifyAccountSession(store: store,
                                                flow: flow,
                                                transport: transport,
                                                clientID: "client-settings-surface",
                                                refreshAttemptLimit: 1,
                                                capabilityStalenessSeconds: 3600,
                                                linkFlowTimeoutSeconds: 300,
                                                expirySkewSeconds: 60,
                                                observabilityBus: bus)
            session.presenter = { UIViewController() }
            self.storage = storage
            self.store = store
            self.flow = flow
            self.transport = transport
            self.bus = bus
            self.session = session
        }

        /// The surface's state, exactly as the view derives it.
        var leafState: SpotifySettingsLeafState {
            SpotifySettingsLeafState(state: session.status)
        }
    }

    private func makeWorld(preLinkedRecord: SpotifySessionRecord? = nil) -> SurfaceWorld {
        SurfaceWorld(preLinkedRecord: preLinkedRecord)
    }

    private func scriptSuccessfulLink(in world: SurfaceWorld, product: String) {
        world.transport.exchangeReply = .body(Self.tokenBody(), 200)
        world.transport.profileReply = .body(Self.profileBody(product: product), 200)
    }

    private func XCTAssertButNoRecordWasStored(_ world: SurfaceWorld,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        XCTAssertNil(world.store.record,
                     "a failed link must store nothing", file: file, line: line)
        XCTAssertTrue(world.storage.rawPayloads.isEmpty,
                      "a failed link must leave no bytes behind", file: file, line: line)
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor (the
    /// `CalendarShareSettingsSeamTests` pattern — the session's state
    /// changes land on the main actor, so a bare assertion races them).
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    // MARK: - Source scans (the file is the witness for view modifiers)

    /// The `SpotifySettingsView` struct's own source — comments stripped,
    /// string literals kept (a doc example must not satisfy a pin; a
    /// modifier must).
    private func spotifySectionSource() throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift")
        let text = FeatureSourceScan.codeText(of: url)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("struct SpotifySettingsView") },
                                  "SettingsView.swift has no top-level struct SpotifySettingsView")
        // Top-level declarations start in column 0; nested types and
        // members do not, so the next one is the end of this type (the
        // `SettingsTabMappingTests.structSource` convention).
        let end = lines[(start + 1)...].firstIndex { line in
            ["struct ", "enum ", "extension ", "final class ", "class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    private func settingsTabsSource() -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsTabs.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Doubles

/// A one-shot latch, so a test can hold the consent flow open (and the
/// fake below can wait on it). File-scope because the seam and the test
/// case both use it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// The scripted presentation seam: can hold the flow open (the in-flight
/// fixture) and can take a script; the default echoes the authorize URL's
/// state into a valid callback — the one way a test can satisfy a nonce
/// the session minted internally.
@MainActor
private final class SurfaceFakeAuthSession: SpotifyAuthSession {
    private(set) var authorizeCalls = 0
    var gate: Gate?
    var script: ((URL) throws -> URL)?

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        authorizeCalls += 1
        if let gate { await gate.wait() }
        if let script { return try script(url) }
        return Self.callbackURL(echoing: url)
    }

    private static func callbackURL(echoing authorizeURL: URL) -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        var components = URLComponents()
        components.scheme = SpotifyAuthFlow.callbackScheme
        components.host = SpotifyAuthFlow.callbackHost
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-settings-fixture"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }
}

/// Scripted `LocalToolTransport` for the session's two link-path requests
/// (the code exchange and the `/v1/me` verification).
private final class SurfaceStubTransport: LocalToolTransport {
    enum Reply {
        case body(Data, Int)
    }

    var exchangeReply: Reply = .body(Data(), 500)
    var profileReply: Reply = .body(Data(), 500)
    private(set) var requests: [URLRequest] = []

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = request.url?.host == "api.spotify.com" ? profileReply : exchangeReply
        switch reply {
        case .body(let data, let statusCode):
            let url = request.url ?? URL(string: "https://accounts.spotify.com")!
            return (data, HTTPURLResponse(url: url, statusCode: statusCode,
                                          httpVersion: nil, headerFields: nil)!)
        }
    }
}
