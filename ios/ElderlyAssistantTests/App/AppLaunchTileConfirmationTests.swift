import XCTest
@testable import ElderlyAssistant

/// [APP-UI-CONFIRM] (2026-10-14) — the curated-bar launch asks in the
/// app's OWN UI before anything external opens.
///
/// The owner's report, verbatim: "the same thing happens when i try to
/// open apps from the curated apps scrollable bar at the top - shows
/// english dialog confirmation. change that to also use custom UI
/// instead of native using corresponding components."
///
/// The "english dialog" was iOS's own "Open in <App>?" sheet, presented
/// in the SYSTEM language for programmatic custom-scheme opens — not
/// suppressible from this app. What this unit pins is the half that IS
/// ours, driven against a REAL `AppCoordinator`:
///
/// 1. A tile tap PENDS the launch and opens the existing confirmation
///    window (`requestAppLaunchFromTile`) — the same window, question
///    vocabulary and executor the voice path uses, so the elder sees
///    one confirmation language, never two.
/// 2. The resolution rules: same-tile re-tap is the yes; a different
///    tile supersedes the live question first; an unavailable app is
///    refused honestly with nothing pended; a window another flow owns
///    (call, walk, calendar, dose challenge) is never asked into.
/// 3. The chip labels: the launch flow renames its chips Open/Cancel
///    (`ConfirmationChipSpeech.chipKeys`), both keys resolving en+ne.
/// 4. The flywheel gate: a tile-asked question never records
///    (`appendLaunchCapture`), pinned at the source.
///
/// The launch-URL half (universal link vs scheme, the probe, the
/// may-still-prompt matrix) lives in `AppLauncherTests`. What a unit
/// test cannot witness — the sheet's actual absence on a device, the
/// spoken audio, the rendered chips — stays DV's job and is not
/// simulated here; the tests assert presentation state (the pends, the
/// session state, the copy keys), exactly the discipline the sibling
/// confirmation suites established.
final class AppLaunchTileConfirmationTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// The coordinator's own language key (`AppLanguage` keeps its
    /// defaults key private; this string is the seam the app really
    /// writes). Snapshot/restore like the sibling suites.
    private static let languageKey = "appLanguage"

    private var languageBackup: Any?

    override func setUp() {
        super.setUp()
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
    }

    override func tearDown() {
        if let languageBackup {
            UserDefaults.standard.set(languageBackup, forKey: Self.languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.languageKey)
        }
        super.tearDown()
    }

    // MARK: - The tap asks first

    /// The report's entire fix, at the presentation layer: the tap no
    /// longer launches — it pends and opens OUR window (the awaiting
    /// state is what renders `ConfirmationChips`, whose launch labels are
    /// pinned below). The question line itself comes from the same
    /// `launcher.confirmOpen*` keys the voice path speaks.
    @MainActor
    func testTileTapPendsTheLaunchAndOpensTheConfirmationWindow() throws {
        let coordinator = makeCoordinator()
        let whatsapp = try XCTUnwrap(AppLauncher.app(for: "whatsapp"))

        coordinator.requestAppLaunchFromTile(whatsapp)

        XCTAssertEqual(coordinator.pendingAppLaunch?.appID, "whatsapp")
        XCTAssertEqual(coordinator.pendingAppLaunch?.origin, .tile,
                       "the pend must carry the tile origin — the flywheel gate reads it")
        XCTAssertTrue(coordinator.isAwaitingAppLaunchConfirmation,
                      "the launch owns the window: the chips will render its question")
        XCTAssertEqual(coordinator.voiceSession.state, .awaitingConfirmation,
                       "the tap opens the SAME 45 s confirmation window the voice path uses")
    }

    /// The camera is the probe-free entry (its plan is always `.camera`,
    /// no installed-probe involved), so its ask is deterministic in every
    /// environment — a tap must ask here too, never fall back to the
    /// pre-fix immediate launch.
    @MainActor
    func testCameraTileAsksToo() throws {
        let coordinator = makeCoordinator()
        let camera = try XCTUnwrap(AppLauncher.app(for: "camera"))

        coordinator.requestAppLaunchFromTile(camera)

        XCTAssertEqual(coordinator.pendingAppLaunch?.appID, "camera")
        XCTAssertEqual(coordinator.pendingAppLaunch?.origin, .tile)
        XCTAssertEqual(coordinator.voiceSession.state, .awaitingConfirmation)
    }

    /// A launch that can only fail is never turned into a question
    /// (the voice path's refusal-to-ASK rule, applied to the tile): imo
    /// is not installed in the test environment and has no web fallback,
    /// so the tap pends nothing and the session never enters the window —
    /// the tile announces the honest not-installed line instead.
    @MainActor
    func testUnavailableAppIsRefusedHonestlyAndNothingIsPended() throws {
        let coordinator = makeCoordinator()
        let imo = try XCTUnwrap(AppLauncher.app(for: "imo"))

        coordinator.requestAppLaunchFromTile(imo)

        XCTAssertNil(coordinator.pendingAppLaunch,
                     "nothing is pended for a launch that can only fail")
        XCTAssertFalse(coordinator.isAwaitingAppLaunchConfirmation)
        XCTAssertNotEqual(coordinator.voiceSession.state, .awaitingConfirmation,
                          "no window may open over a refusal")
    }

    // MARK: - Resolution: re-tap, supersede, contention

    /// F6's "a tap IS an answer", now applied to OUR question: re-tapping
    /// the same tile proceeds exactly as a spoken yes would — the pend is
    /// resolved `.confirmedByTile`, the window closes, and the shared
    /// executor runs (which is what speaks the launch line, once).
    @MainActor
    func testSameTileRetapIsTheYesAndClosesTheQuestion() throws {
        let coordinator = makeCoordinator()
        let whatsapp = try XCTUnwrap(AppLauncher.app(for: "whatsapp"))

        coordinator.requestAppLaunchFromTile(whatsapp)
        XCTAssertNotNil(coordinator.pendingAppLaunch)

        coordinator.requestAppLaunchFromTile(whatsapp)

        XCTAssertNil(coordinator.pendingAppLaunch,
                     "the re-tap IS the yes — the question must not outlive it")
        XCTAssertFalse(coordinator.isAwaitingAppLaunchConfirmation)
        XCTAssertEqual(coordinator.voiceSession.state, .idle,
                       "the window closes with the answer — no 45 s timer may later " +
                       "speak 'time is up' over the app that just opened")
    }

    /// A tap on a DIFFERENT tile supersedes the live question first (the
    /// unanswered verdict is recorded by `resolveLaunchQuestion`) and then
    /// asks its own — so the screen never shows one app's question while
    /// the next tap opens another.
    @MainActor
    func testTapOnADifferentTileSupersedesTheLiveQuestion() throws {
        let coordinator = makeCoordinator()
        let whatsapp = try XCTUnwrap(AppLauncher.app(for: "whatsapp"))
        let facebook = try XCTUnwrap(AppLauncher.app(for: "facebook"))

        coordinator.requestAppLaunchFromTile(whatsapp)
        XCTAssertEqual(coordinator.pendingAppLaunch?.appID, "whatsapp")

        coordinator.requestAppLaunchFromTile(facebook)

        XCTAssertEqual(coordinator.pendingAppLaunch?.appID, "facebook",
                       "the superseded question is gone; the new one is pended")
        XCTAssertEqual(coordinator.pendingAppLaunch?.origin, .tile)
        XCTAssertEqual(coordinator.voiceSession.state, .awaitingConfirmation,
                       "the new question re-arms the window (a fresh 45 s budget)")
    }

    /// The contention rule: while another confirm-tier flow owns the
    /// window (here, a dose challenge — `pendingConfirmationEntryId`),
    /// the launch question could never be the one answered — the chips
    /// would say "Open" while the tap answered a call. In that corner the
    /// tile keeps the pre-fix behavior: launch directly, ask nothing.
    @MainActor
    func testTileNeverAsksIntoAWindowAnotherFlowOwns() throws {
        let coordinator = makeCoordinator()
        coordinator.pendingConfirmationEntryId = UUID()   // a live dose challenge
        let whatsapp = try XCTUnwrap(AppLauncher.app(for: "whatsapp"))

        coordinator.requestAppLaunchFromTile(whatsapp)

        XCTAssertNil(coordinator.pendingAppLaunch,
                     "a launch question must not be pended while the dose challenge " +
                     "owns the answer (ConfirmationArbitration)")
        XCTAssertFalse(coordinator.isAwaitingAppLaunchConfirmation,
                       "the medication challenge still owns the window")
    }

    // MARK: - Chip labels (Open / Cancel, en + ne)

    /// The label half of the fix: under the launch flow the chips read
    /// Open/Cancel, and the keys resolve to real localized words in both
    /// languages — an unlocalized "Open" in a Nepali session would repeat
    /// the exact language failure the owner reported about the native
    /// sheet.
    func testLaunchChipKeysResolveInBothLanguagesAndNameTheActions() {
        let launch = ConfirmationChipSpeech.chipKeys(.init(isAppLaunch: true))
        XCTAssertEqual(launch.yes, "launcher.chipOpen")
        XCTAssertEqual(launch.no, "launcher.chipCancel")

        for (key, expectedEN) in [(launch.yes, "Open"), (launch.no, "Cancel")] {
            let english = L10n.str(key, locale: en)
            let nepali = L10n.str(key, locale: ne)
            XCTAssertEqual(english, expectedEN, "\(key) must read as the action itself")
            XCTAssertNotEqual(nepali, key, "\(key) must resolve in the Nepali catalog")
            XCTAssertFalse(nepali.isEmpty)
            XCTAssertNotEqual(nepali, english,
                              "\(key) must be a Devanagari word, not a Latin copy")
            XCTAssertTrue(nepali.contains { !$0.isASCII },
                          "\(key)'s Nepali value must be Devanagari")
        }

        // The rename is launch-only: the shared yes/no pair every other
        // flow uses is untouched, and its words differ from Open/Cancel —
        // otherwise the rename silently rewrote the medication challenge.
        let generic = ConfirmationChipSpeech.chipKeys(.init())
        XCTAssertEqual(generic.yes, "state.awaitingConfirmation.chipYes")
        XCTAssertEqual(generic.no, "state.awaitingConfirmation.chipNo")
        XCTAssertNotEqual(L10n.str(generic.yes, locale: en), L10n.str(launch.yes, locale: en))
        XCTAssertNotEqual(L10n.str(generic.no, locale: en), L10n.str(launch.no, locale: en))
    }

    /// The label must promise what the tap will DO: when a higher-priority
    /// flow is pended alongside the launch, `handleConfirmationResponse`
    /// routes the answer to that flow first — so the chips keep Yes/No.
    func testChipRenameYieldsToHigherPriorityFlows() {
        XCTAssertEqual(ConfirmationChipSpeech.chipKeys(
            .init(isCall: true, isAppLaunch: true)).yes,
            "state.awaitingConfirmation.chipYes",
            "a call answer routed first must not be labelled 'Open'")
        XCTAssertEqual(ConfirmationChipSpeech.chipKeys(
            .init(isNavigationDisambiguation: true, isAppLaunch: true)).yes,
            "state.awaitingConfirmation.chipYes")
        XCTAssertEqual(ConfirmationChipSpeech.chipKeys(
            .init(isCalendarEvent: true, isAppLaunch: true)).yes,
            "state.awaitingConfirmation.chipYes")
    }

    /// The question and outcome lines a tile launch rides resolve in both
    /// languages — the tile path reuses the voice path's whole key set
    /// (`requestAppLaunchCore`), so nothing new may be minted here, and
    /// nothing existing may go missing.
    func testLaunchQuestionCopyResolvesInBothLanguages() {
        let keys = ["launcher.confirmOpen", "launcher.confirmOpenWeb",
                    "launcher.confirmOpenSettings", "launcher.cancelled",
                    "launcher.noApp", "launcher.unknownApp",
                    "apps.announce.opened", "apps.announce.notInstalled",
                    "apps.announce.openingWeb"]
        for key in keys {
            for locale in [en, ne] {
                let text = L10n.str(key, locale: locale)
                XCTAssertFalse(text.isEmpty, "\(key) is missing from \(locale.identifier)")
                XCTAssertNotEqual(text, key,
                                  "\(key) must resolve from the \(locale.identifier) catalog")
            }
        }
    }

    // MARK: - The flywheel gate, pinned at the source

    /// The tile-asked question records NOTHING (a finger is not an
    /// utterance), and the enforcement is structural: every launch
    /// capture site runs through `appendLaunchCapture`, which gates on
    /// `recordsFlywheelCapture` — no site may call `appendCapture` with a
    /// launch capture directly. Pinned by counting, so a seventh capture
    /// site that bypasses the gate fails HERE rather than fabricating
    /// accept-band signal on a device.
    func testTileCaptureGatingIsPinnedAtTheSource() throws {
        let text = coordinatorSource()

        XCTAssertEqual(occurrences(of: "appendLaunchCapture(launch,", in: text), 6,
                       "the six launch capture sites: the F6 tile-resolution pair, the " +
                       "confirmed executor, the medication-challenge drop, the 45 s " +
                       "timeout and the spoken no")

        // The ONLY direct launch write compiles inside the gated helper —
        // a capture site that bypassed the gate would be a second
        // occurrence, outside the helper's region.
        let helper = try region(between: "private func appendLaunchCapture(",
                                and: "recordConfirmationTimeout", in: text)
        XCTAssertEqual(occurrences(of: "appendCapture(launch.capture", in: text), 1,
                       "a launch verdict must never reach appendCapture outside the " +
                       "gated helper")
        XCTAssertEqual(occurrences(of: "appendCapture(launch.capture", in: helper), 1,
                       "the one direct write is the helper's own, and it sits inside " +
                       "the helper's region")
        XCTAssertTrue(collapsed(helper).contains(
            "guard launch.recordsFlywheelCapture else { return }"),
            "the one gate every site funnels through must stay in the helper")
        XCTAssertTrue(collapsed(helper).contains(
            "appendCapture(launch.capture, verdict, path: launch.capturePath)"),
            "the gated write must keep the launch's own path (F10: never the " +
            "'model' default for a keyword-asked launch)")

        // The tile wiring itself: Home's strip calls the asking entry
        // point, not the executor — a revert here would silently bring
        // the native dialog's flow back.
        let home = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/HomeView.swift"))
        XCTAssertEqual(occurrences(of: "coordinator.requestAppLaunchFromTile(app)", in: home), 1,
                       "the QuickAccessStrip tap must ask through requestAppLaunchFromTile")
        XCTAssertEqual(occurrences(of: "coordinator.performAppLaunch(app)", in: home), 0,
                       "the strip must not call the bare executor — that was the " +
                       "pre-fix behavior (launch first, system sheet second)")
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The text between two code markers — comment-stripped, so the pins
    /// are code, never prose (the `CallConfirmationWordingTests`
    /// convention).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "AppCoordinator.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship — `ColdStartRoutingTests`,
    // `CallingSettingsSurfaceTests`, `CallConfirmationWordingTests`: the
    // coordinator's payload store only; the seams under test are the real
    // catalog, the real session machine and the real language store.)

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
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }
}
