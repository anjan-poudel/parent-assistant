import Foundation
import XCTest
@testable import ElderlyAssistant

/// Guards the T-119 wiring of the Spotify services into the AppCoordinator
/// (design-l2 §16): the two `lazy var` seams, the plugin registration beside
/// the shipped plugins, and the three router parameters — each pinned as the
/// wiring actually shipped, because every one of these failures is silent at
/// runtime:
///
///   · a second `SpotifyAccountSession` would let Settings and the router
///     disagree about which account is linked (L2-R2);
///   · a Spotify plugin that misses the registration pass would leave
///     `spotify.play` unresolvable with no error anywhere;
///   · a session built with the §26 default bus would DROP every
///     `spotify_link` / `spotify_unlink` event ([W2-review D1] — the
///     omission is invisible: no crash, no log, nothing);
///   · eager construction in `init()` would do keychain work before the
///     first frame ([BOOT-REVIEW P0-1]).
///
/// The four tests are the task's four Gherkin scenarios, one to one. The
/// coordinator's real router is built privately in `composePostFirstFrame()`
/// and is unreachable from a unit test without running `start()` (which would
/// re-register the BGTaskScheduler handlers and trip a platform exception in
/// the test host), so the router clause is pinned in two halves: the SOURCE
/// of the construction call (the only witness to what the launch passes) and
/// the seam BEHAVIOUR of a router armed with the coordinator's own values.
/// That split is the honest maximum a unit test can witness; it is recorded
/// in `specs/T-119-notes.md`.
@MainActor
final class AppCoordinatorSpotifyWiringTests: XCTestCase {

    // MARK: - Scenario 1: services construct lazily and are injected once

    func testScenario1ServicesConstructLazilyAndOneSessionIsInjectedOnce() {
        let coordinator = makeCoordinator()

        // Nothing Spotify-shaped is built yet: both seams are `lazy var`s
        // ([BOOT-REVIEW P0-1] first use, not `init()`), and a fresh
        // coordinator has had no first use.
        XCTAssertNil(lazyStorageValue("spotifyCredentialStore", of: coordinator,
                                      as: SpotifyCredentialStore.self),
                     "the credential store was built before first use — init() must not do keychain work")
        XCTAssertNil(lazyStorageValue("spotifyAccountSession", of: coordinator,
                                      as: SpotifyAccountSession.self),
                     "the session was built before first use — init() must not do keychain work")

        // First use builds one of each; a second read is the same object,
        // never a rebuild.
        let store = coordinator.spotifyCredentialStore
        let session = coordinator.spotifyAccountSession
        XCTAssertTrue(store === coordinator.spotifyCredentialStore,
                      "the credential store must be the one instance every consumer shares")
        XCTAssertTrue(session === coordinator.spotifyAccountSession,
                      "a second read built a second session — every consumer must share one account")
        XCTAssertNotNil(lazyStorageValue("spotifyAccountSession", of: coordinator,
                                         as: SpotifyAccountSession.self),
                        "first use must fill the lazy slot")

        // The registered plugin (same composition pass) holds THOSE two
        // objects, not copies: the interpreter-side `spotify.play` path and
        // the router's deterministic music path read one account state.
        let registry = coordinator.pluginRegistry
        guard let plugin = spotifyPlugin(in: registry) else {
            return XCTFail("the standard registration pass left no SpotifyPlugin in the registry")
        }
        XCTAssertTrue(stored("accountSession", of: plugin, as: SpotifyAccountSession.self) === session,
                      "the plugin was registered with a different session — two accounts can now disagree")
        XCTAssertTrue(stored("credentialStore", of: plugin, as: SpotifyCredentialStore.self) === store,
                      "the plugin was registered with a different credential store")

        // Router clause, runtime half: a router armed with the coordinator's
        // own seams retains exactly those objects (one session, one
        // transport, one opener seam).
        let router = CommandRouter(coordinator: StubCoordinator(),
                                   observabilityBus: RecordingObservabilityBus(),
                                   spotifyAccountSession: session,
                                   spotifyTransport: URLSession.shared,
                                   spotifyLinkOpener: SystemCallLinkOpener())
        XCTAssertTrue(stored("spotifyAccountSession", of: router, as: SpotifyAccountSession.self) === session,
                      "the router's session seam must be the coordinator's session")
        XCTAssertTrue(stored("spotifyTransport", of: router, as: URLSession.self) === URLSession.shared,
                      "the router's transport seam must be the shared session, not a per-call clone")
        XCTAssertNotNil(stored("spotifyLinkOpener", of: router, as: SystemCallLinkOpener.self),
                        "the router's opener seam must be armed with the app's call-link opener")

        // Router clause, source half: the launch passes exactly these three
        // (a runtime read cannot reach the private router — see the type
        // doc). The occurrence counts make "exactly one session
        // constructed" a file-level fact, not an assumption.
        let source = coordinatorSource()
        XCTAssertEqual(occurrences(of: "SpotifyAccountSession(", in: source), 1,
                       "more than one SpotifyAccountSession construction exists in the coordinator")
        XCTAssertEqual(occurrences(of: "SpotifyCredentialStore(", in: source), 1,
                       "more than one SpotifyCredentialStore construction exists in the coordinator")
        XCTAssertEqual(occurrences(of: "lazy var spotifyAccountSession", in: source), 1,
                       "the session declaration must be one lazy var")
        XCTAssertEqual(occurrences(of: "register(SpotifyPlugin(accountSession: spotifyAccountSession", in: source), 1,
                       "exactly one registration hands the session to the plugin")
        XCTAssertEqual(occurrences(of: "spotifyAccountSession: spotifyAccountSession", in: source), 1,
                       "exactly one construction hands the session to the router")
        guard let routerCall = callBlock(in: source, marker: "CommandRouter(") else {
            return XCTFail("no CommandRouter( construction in AppCoordinator.swift")
        }
        XCTAssertTrue(routerCall.contains("spotifyAccountSession: spotifyAccountSession,"),
                      "the router construction does not pass the coordinator's session")
        XCTAssertTrue(routerCall.contains("spotifyTransport: URLSession.shared,"),
                      "the router construction does not pass the shared transport")
        XCTAssertTrue(routerCall.contains("spotifyLinkOpener: SystemCallLinkOpener(),"),
                      "the router construction does not pass the call-link opener")
    }

    // MARK: - Scenario 2: the plugin registers beside the existing plugins

    func testScenario2TheSpotifyPluginRegistersOnceBesideUnchangedPlugins() {
        let coordinator = makeCoordinator()
        let registry = coordinator.pluginRegistry
        XCTAssertTrue(registry === coordinator.pluginRegistry, "the registry is built once")

        // The SHIPPED registration pass, in order. This list is the
        // "pre-existing registrations unchanged" fixture: a changed,
        // dropped, doubled or reordered plugin fails here by name.
        let ids = registry.plugins.map(\.pluginID)
        XCTAssertEqual(ids, ["nepali_calendar", "appliance_helper", "routine", "youtube",
                             "spotify", "live_translate", "app_launcher"],
                       "the standard registration pass changed — Spotify must sit beside YouTube, "
                       + "with every pre-existing plugin untouched")
        XCTAssertEqual(ids.filter { $0 == "spotify" }.count, 1,
                       "the Spotify plugin registered more than once")

        // Same six pre-existing TYPES, not merely the same count of IDs.
        let types = registry.plugins.map { String(describing: Swift.type(of: $0)) }
        XCTAssertEqual(types, ["NepaliCalendarPlugin", "ApplianceHelperPlugin", "RoutinePlugin",
                               "YouTubePlugin", "SpotifyPlugin", "LiveTranslatePlugin",
                               "AppLauncherPlugin"],
                       "a pre-existing registration was replaced by a different plugin type")

        // Source pin: exactly one SpotifyPlugin construction, in a register
        // call that hands over the coordinator's own seam values.
        let source = coordinatorSource()
        XCTAssertEqual(occurrences(of: "SpotifyPlugin(", in: source), 1,
                       "the Spotify plugin is constructed somewhere other than the one registration call")
        guard let call = callBlock(in: source, marker: "registry.register(SpotifyPlugin(") else {
            return XCTFail("no registry.register(SpotifyPlugin( ... ) call in AppCoordinator.swift")
        }
        XCTAssertTrue(call.contains("accountSession: spotifyAccountSession"),
                      "the registration does not hand over the coordinator's session")
        XCTAssertTrue(call.contains("credentialStore: spotifyCredentialStore"),
                      "the registration does not hand over the coordinator's credential store")
    }

    // MARK: - Scenario 3: construction never requires a linked account

    func testScenario3FreshInstallConstructionIsDormantAndMakesNoNetworkCall() {
        // A fresh install in the keychain's own terms: nothing under the one
        // Spotify record key, cleared through the app's own encrypted
        // channel — never around the storage under test.
        _ = MigratingEncryptedStorage().delete(key: SpotifyCredentialStore.storageKey)

        URLProtocol.registerClass(SpotifyWiringURLProbe.self)
        defer { URLProtocol.unregisterClass(SpotifyWiringURLProbe.self) }
        SpotifyWiringURLProbe.reset()

        // The probe's self-check comes FIRST: interception is proven with a
        // control request before the no-request assertion leans on it. A
        // broken probe must fail this test loudly, never pass it vacuously.
        XCTAssertTrue(probeInterceptsTheControlRequest(),
                      "URLProtocol never saw a URLSession.shared request — the "
                      + "no-network assertion below would be vacuous")
        SpotifyWiringURLProbe.reset()

        // Construction, in the wiring's own order: store → session →
        // registration pass (each one a first use — touching them IS the
        // build the launch performs).
        let coordinator = makeCoordinator()
        let store = coordinator.spotifyCredentialStore
        let session = coordinator.spotifyAccountSession
        let registry = coordinator.pluginRegistry

        // The state is dormant — present, not linked, advertising nothing.
        XCTAssertNil(store.record, "a fresh install holds no Spotify record")
        XCTAssertFalse(store.isLinked)
        XCTAssertEqual(session.status, .notLinked, "construction must never require a link")
        XCTAssertFalse(session.isLinked)
        XCTAssertEqual(session.product, .unknown, "an unlinked account advertises no capability")
        XCTAssertNotNil(spotifyPlugin(in: registry),
                        "the seams must be present and dormant, never absent")

        // Dormancy in durable terms too: a fresh reader over the encrypted
        // channel agrees construction wrote nothing.
        XCTAssertNil(SpotifyCredentialStore(storage: MigratingEncryptedStorage()).record,
                     "construction wrote a Spotify record")

        // And nothing left the process through the shared session while the
        // whole build ran.
        XCTAssertEqual(SpotifyWiringURLProbe.requests, [],
                       "construction made a request through URLSession.shared: "
                       + "\(SpotifyWiringURLProbe.requests)")
    }

    // MARK: - Scenario 4: session events reach the app's observability bus

    func testScenario4SessionEventsReachTheAppBusNotTheDroppingDefault() {
        let coordinator = makeCoordinator()
        let session = coordinator.spotifyAccountSession
        let registry = coordinator.pluginRegistry

        // The wiring fact, read where only Mirror can read it ([W2-review
        // D1]): the session's bus, the registry's bus and the coordinator's
        // own bus are ONE object — and it is the app's real console bus,
        // never the session's dropping default.
        guard let sessionBus = stored("observabilityBus", of: session, as: ObservabilityBus.self),
              let registryBus = stored("observabilityBus", of: registry, as: ObservabilityBus.self),
              let coordinatorBus = stored("observabilityBus", of: coordinator, as: ObservabilityBus.self) else {
            return   // `stored` already failed loudly
        }
        XCTAssertTrue(sessionBus is ConsoleObservabilityBus,
                      "the session's bus is not the app's console bus")
        XCTAssertNotEqual(busIdentity(sessionBus), busIdentity(SpotifyAccountSession.unwiredBus),
                          "the session kept the §26 dropping default — every event would vanish silently")
        XCTAssertEqual(busIdentity(sessionBus), busIdentity(registryBus),
                       "the session and the plugin registry do not share the app's bus")
        XCTAssertEqual(busIdentity(sessionBus), busIdentity(coordinatorBus),
                       "the session's bus is not the coordinator's own bus")

        // Behavioural delivery: drive the shipped wipe paths and watch the
        // app bus print. Both are synchronous and local by design (V-1: no
        // remote revocation endpoint exists to call), so this is hermetic —
        // no auth flow, no network, no store precondition: clearing an
        // already-empty record is a success.
        let printed = captureConsole {
            _ = session.unlink()
            _ = session.markRevoked()
        }
        XCTAssertTrue(printed.contains("[spotify] spotify_unlink outcome=success"),
                      "the caregiver's unlink event never reached the app bus; captured: \(printed)")
        XCTAssertTrue(printed.contains("[spotify] spotify_unlink outcome=revoked"),
                      "the revoked event never reached the app bus; captured: \(printed)")

        // And the construction site passes that bus BY NAME — the one
        // argument whose omission is invisible at runtime, so the source
        // itself is the assertion.
        let source = coordinatorSource()
        guard let construction = callBlock(in: source, marker: "SpotifyAccountSession(") else {
            return XCTFail("no SpotifyAccountSession( construction in AppCoordinator.swift")
        }
        XCTAssertTrue(construction.contains("observabilityBus: observabilityBus)"),
                      "the session is constructed without the app's bus — the §26 default drops "
                      + "spotify_link / spotify_unlink silently ([W2-review D1])")
    }

    // MARK: - Fixtures

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    private func spotifyPlugin(in registry: PluginRegistry) -> SpotifyPlugin? {
        registry.plugins.first { $0.pluginID == "spotify" } as? SpotifyPlugin
    }

    /// In-memory stand-in for the encrypted channel (the
    /// `ProfileCoordinatorSeamTests` fake's shape): the coordinator's init
    /// requires one and nothing in this suite touches the profile.
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)   // this fake is raw-read only
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    // MARK: - Mirror reads (the only reader a test has for private seams)

    /// One stored property of `subject`, by label. The `as? T` cast unwraps
    /// one level of `Optional` (verified against this toolchain), which is
    /// what makes the optional seams (`CommandRouter.spotifyAccountSession`,
    /// `PluginRegistry.observabilityBus`) readable at all. A missing label or
    /// a mismatched type is an explicit failure, never a silent nil.
    private func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self,
                           file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject).children.first(where: { $0.label == label }) else {
            XCTFail("no stored property '\(label)' on \(Swift.type(of: subject))",
                    file: file, line: line)
            return nil
        }
        guard let value = child.value as? T else {
            XCTFail("stored property '\(label)' is not a \(T.self) — holds \(Swift.type(of: child.value))",
                    file: file, line: line)
            return nil
        }
        return value
    }

    /// The raw backing slot of a `lazy var` — the compiler labels it
    /// `$__lazy_storage_$_<name>` (verified against this toolchain). nil
    /// until first use, the built value after; a property that stopped being
    /// `lazy` loses this label, which fails the read rather than passing an
    /// eager build.
    private func lazyStorageValue<T>(_ name: String, of subject: Any, as type: T.Type = T.self,
                                     file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject)
            .children.first(where: { $0.label == "$__lazy_storage_$_\(name)" }) else {
            XCTFail("no lazy storage '\(name)' on \(Swift.type(of: subject)) — is it still a `lazy var`?",
                    file: file, line: line)
            return nil
        }
        return child.value as? T
    }

    /// `AnyObject` identity of an existential bus. The app's buses are
    /// classes (`ConsoleObservabilityBus`); a value-type bus would box on
    /// every conversion and its identity comparisons would fail loudly
    /// rather than compare equal by accident.
    private func busIdentity(_ bus: ObservabilityBus,
                             file: StaticString = #filePath, line: UInt = #line) -> ObjectIdentifier {
        ObjectIdentifier(bus as AnyObject)
    }

    // MARK: - Console capture (the LiveTranslateAllowListTests pattern)

    /// Runs `body` with process stdout redirected to a temp file and returns
    /// what the bus printed. Scoped assertions only: another test or the
    /// booting host app may print whatever it likes into the same window.
    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/spotify-wiring-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    // MARK: - Hermetic URLSession.shared probe

    /// One request through `URLSession.shared` with the probe registered:
    /// true exactly when the probe saw it and answered the canned 204. The
    /// control is deliberately to a loopback port that refuses connections:
    /// if interception is broken the request fails fast and the caller's
    /// assertion fails with THIS test, never silently.
    private func probeInterceptsTheControlRequest() -> Bool {
        let done = expectation(description: "probe control request")
        var status = -1
        let url = URL(string: "http://127.0.0.1:1/spotify-wiring-probe-control")!
        URLSession.shared.dataTask(with: url) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return status == 204
    }

    /// Registered with `URLProtocol` so it observes every request the app's
    /// shared session would make, answers a canned 204 to the process, and
    /// records the URLs. Nothing leaves the process while it is registered.
    private final class SpotifyWiringURLProbe: URLProtocol {
        private static let lock = NSLock()
        private static var recorded: [String] = []

        static var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        static func reset() {
            lock.lock()
            defer { lock.unlock() }
            recorded = []
        }

        private static func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request.url?.absoluteString ?? "<no url>")
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Source pins (the file is the only witness for `private` sites)

    /// The coordinator's own source, comments stripped (a documentation
    /// example must not satisfy a pin), via the shipped scan helper.
    private func coordinatorSource(file: StaticString = #filePath) -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The call whose text starts at `marker` (which ends with its opening
    /// parenthesis), up to and including the parenthesis that closes it.
    /// Pins need the call's own text: "the argument exists somewhere in the
    /// file" would pass on a comment or an unrelated call.
    private func callBlock(in text: String, marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return String(text[start.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
