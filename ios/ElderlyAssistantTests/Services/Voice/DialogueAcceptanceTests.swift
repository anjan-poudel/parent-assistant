import CryptoKit
import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10) T-141 — the feature's closing acceptance
/// (TG-28). One named test per in-test Gherkin scenario of the task file
/// (the fifth scenario — "the full-suite run records no new failures" — is
/// the wave's executed full-unit run and its sweep record, by the task
/// file's own division of labour: the run is the witness, not a test):
///
///   · Scenario 1 — the anchor dialogue end to end at the ROUTER seam
///     with production-shaped wiring (a real `CommandRouter`, a non-nil
///     coordinator whose six dialogue members are thin adapters over the
///     REAL `DialogueManager`, the REAL shipped catalog, the same
///     playback/opener helper double the dialogue suites use): the
///     degenerate "भजन बजाऊ" opens the probe, the primary alias answer
///     "दुर्गा" merges deterministically to the catalog's canonical query
///     (verified from the shipped resource, not assumed) and executes
///     through the pre-existing offline playback helper — with ZERO
///     interpreter consultations and ZERO transport requests;
///   · Scenario 2 — the FR-MTC-019 Phase-1 guard: reminder, calendar and
///     medication turns route IDENTICALLY with the dialogue machinery
///     armed and with the shipped (pre-feature, inert) coordinator shape
///     — measured as an A/B on the same doubles, with the live arm
///     additionally pinned to nil frame + zero `dialogue_*` telemetry;
///   · Scenario 3 — the FR-MTC-018 Phase-1 prompt guard (the E7 second
///     half): the shipped prompt composition still hashes to the pinned
///     `18003ddd…`/`bd47910d…` digests at the pinned 2_506-Character
///     baseline inside the 3_000-Character ceiling, and the prompt FILE
///     bytes still equal their diff-base (`0cbe4e6`) bytes — the
///     zero-prompt-edits claim as a digest pin, not a promise;
///   · Scenario 4 — the pinned regression surfaces: the golden music
///     block digest (`fb14012e…`, 15 entries) re-derived from the source,
///     plus the carrier suites' presence/floor pins (their full-run
///     results are cited in the sweep record).
///
/// Honesty discipline: every pinned value is either re-derived in-test
/// from the shipped artifact or asserted against a value this file
/// computed off the diff base (the base digests below were taken with
/// `git show 0cbe4e6:<path> | shasum -a 256`, and base == HEAD ==
/// worktree at T-141 time); nothing is hard-coded unverified. Doubles are
/// file-private mirrors of the `CommandRouterDialogueTests` /
/// `CommandRouterDegenerateTriggerTests` harness; no sleeps — async legs
/// wait on `waitForDelivery`.
@MainActor
final class DialogueAcceptanceTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Pinned evidence

    /// The constitution :9 anchor's canonical query: the `दुर्गा`
    /// option's `query` in the shipped resource. Read from the catalog at
    /// test time (the `XCTUnwrap` + equality below); the literal is the
    /// second half of the pin — a catalog edit that moved the anchor's
    /// query would fail BOTH assertions by name.
    private static let anchorDurationQuery = "durga bhajan"

    /// The prompt digests (homes: `IntentPromptTests` and
    /// `PinnedSurfaceGuardTests`, whose literals are ALSO pinned below so
    /// a weakened or deleted home fails this suite too).
    private static let defaultNoTermDigest =
        "18003dddc2a0c16d6fab3be7ffb0f2d93802e1a161f54e05e98a7f33f24b8b78"
    private static let weatherNoTermDigest =
        "bd47910d74d5c10d2ad889e1bb9a6f1e6093b59bb8fb7f03bb765f8f016e00ff"
    private static let defaultTranscript = "test transcript"
    private static let weatherTranscript = "भोलिको मौसम कस्तो छ?"
    private static let promptBaselineCharacters = 2_506
    private static let promptCeilingCharacters = 3_000

    /// The golden music block pin (home: `PinnedSurfaceGuardTests`).
    private static let goldenMusicBlockDigest =
        "fb14012e836a33a3d889ae0610db44ebd3ea1f9b747aa0e368cc38a7221296e2"
    private static let goldenMusicEntryCount = 15

    /// The prompt files' BASE bytes (`0cbe4e6`, this feature's diff base)
    /// — the FR-MTC-018 Phase-1 guard's "zero prompt-file edits" witness.
    /// Taken at T-141 time with `git show 0cbe4e6:<path> | shasum -a 256`
    /// (base == HEAD == working tree when pinned); the test asserts the
    /// WORKING TREE's bytes still hash to the same values. Any prompt edit
    /// in the feature diff — including a comment-only one — fails here.
    private static let promptFileBaseDigests: [(path: String, sha256: String)] = [
        ("ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift",
         "820372d9f8117eca653e5db752b38ead9d87af064f3000ef69cf39812fab94af"),
        ("tools/train-intent/seeds/prompt_template.txt",
         "425241446eefe8caddc1b9a557a03755b52fd2043127f738ad15ecfe9c2d38dd"),
        ("tools/train-intent/src/intent_prompt.py",
         "2952dece2dab74ea42a568880cf4424ff68d33c7381e20e41e646b46e2a662bc")
    ]

    /// The feature's own vocabulary — no prompt file may carry any of it
    /// (the textual half of the same guard; the digest pin above is the
    /// byte-exact half).
    private static let featureVocabulary = [
        "[MULTI-TURN]", "[MTC", "DialogueManager", "DialogueFrame", "probeKind"
    ]

    // MARK: - Scenario 1: the anchor dialogue, end to end at the router seam

    @MainActor
    func testScenario1TheAnchorDialogueCompletesEndToEndWithNoModelAndNoEgress() throws {
        // The canonical query comes from the SHIPPED catalog (never
        // assumed): the group the degenerate request's pending query
        // claims, and within it the option the alias "दुर्गा" names.
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.groupForMusicQuery("भजन"),
                                  "the shipped catalog must claim the degenerate query भजन")
        let durga = try XCTUnwrap(
            group.options.first { $0.aliases.contains("दुर्गा") },
            "the shipped catalog must offer the दुर्गा option the anchor answers with")
        XCTAssertEqual(durga.query, Self.anchorDurationQuery,
                       "the catalog's canonical दुर्गा query moved — the constitution :9 anchor moved")

        let world = makeWorld()

        // (1) The degenerate request: the intake opens the probe and
        // executes NOTHING. Production behaviour, router seam, real manager.
        let first = world.router.route(transcript: "भजन बजाऊ")
        XCTAssertEqual(first, .unrecognised(transcript: "भजन बजाऊ"))

        let frame = try XCTUnwrap(world.coordinator.manager.frame,
                                  "the degenerate request must arm the slot-fill probe")
        XCTAssertEqual(frame.probeKind, .slotFill)
        XCTAssertEqual(frame.domain, .music)
        XCTAssertEqual(frame.sourceTranscript, "भजन बजाऊ")
        XCTAssertEqual(frame.defaultQuery, "भजन")
        XCTAssertEqual(frame.candidates.count, 4, "the shipped bhajan group, capped")
        XCTAssertNil(frame.activeCommand, "the ladder intake carries no pending command")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                            retry: false, locale: ne)),
            "the composed first probe was spoken through the production seam")
        waitForDelivery()
        XCTAssertTrue(world.opener.opened.isEmpty, "the probe executes nothing")

        // (2) The answer: the primary alias merges DETERMINISTICALLY into
        // the pending command and executes through the music arm.
        let answer = world.router.route(transcript: "दुर्गा")
        XCTAssertEqual(answer, .unrecognised(transcript: "दुर्गा"))
        XCTAssertEqual(world.coordinator.resolutions,
                       [.answered(DialogueMerge(value: durga.query,
                                                capture: .optionName,
                                                source: .catalog))],
                       "the merge is the catalog canonicalisation, captured by option name")
        XCTAssertNil(world.coordinator.manager.frame, "the frame was consumed by its answer")
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "answered")
        let answerEvent = world.events("dialogue_answer").last
        XCTAssertEqual(answerEvent?.outcome, "success")
        XCTAssertEqual(answerEvent?.metadata,
                       ["capture_form": "optionName", "merge_source": "catalog"],
                       "the deterministic merge's closed-vocabulary telemetry")

        waitForDelivery()

        // (3) The constitution :9 anchor's landing: the catalog's canonical
        // query reached the PRE-EXISTING offline playback helper.
        XCTAssertEqual(world.opener.opened,
                       [YouTubeTool.appSearchURL(query: Self.anchorDurationQuery)],
                       "the executed music query must be the catalog's canonical query")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.fmt("youtube.openingSearch", locale: ne, Self.anchorDurationQuery)),
            "the turn ended in the shipped outcome line for the canonical query")

        // (4) No model, no egress: zero interpreter consultations across the
        // whole dialogue, and every injected transport seam silent.
        XCTAssertEqual(world.interpreter.interpretCount, 0,
                       "the anchor dialogue is deterministic end to end")
        for spy in world.spies {
            XCTAssertTrue(spy.requests.isEmpty,
                          "a dialogue path reached a transport — NFR-MTC-003 broke")
        }

        // Control (non-vacuity): the SAME alias utterance with no live frame
        // DOES reach the interpreter — the zero above is causal, not vacuous.
        let control = makeWorld()
        _ = control.router.route(transcript: "दुर्गा")
        XCTAssertEqual(control.interpreter.interpretCount, 1,
                       "the interpreter spy would have fired — the anchor's zero is causal")
    }

    // MARK: - Scenario 2: reminder/calendar/medication turns never open a frame

    /// One guard fixture: an utterance from the EXISTING reminder/calendar/
    /// medication fixtures (the golden corpus's `set_reminder` utterance,
    /// the `CommandRouterTests` calendar fixture, the shipped medication-ack
    /// fixture) and the command the shipped suite scripts for it.
    private struct GuardFixture {
        let name: String
        let utterance: String
        let scripted: InterpretedCommand?
        let pendingReminderId: UUID?
    }

    private func guardFixtures() -> [GuardFixture] {
        [
            GuardFixture(
                name: "reminder",
                // The golden corpus's set_reminder utterance
                // (`CommandRouterTests.testBareWakeInfinitiveIsNotAnAlarmCommand`).
                utterance: "बिहान ६ बजे उठाउनु",
                scripted: InterpretedCommand(
                    action: .setReminder, entryId: nil, contact: nil, time: "बिहान ६ बजे",
                    medication: nil, message: nil, callType: nil, requestedApp: nil,
                    confidence: 0.92, reply: "सम्झना राख्छु"),
                pendingReminderId: nil),
            GuardFixture(
                name: "calendar",
                // The `CommandRouterTests` calendar fixture.
                utterance: "बिहान ८ बजे डाक्टर भेट्ने पात्रोमा राख",
                scripted: InterpretedCommand(
                    action: .createCalendarEvent, entryId: nil, contact: nil,
                    time: "बिहान ८ बजे", medication: nil, message: nil, callType: nil,
                    requestedApp: nil, topic: "डाक्टर भेट्ने",
                    confidence: 0.9, reply: "पात्रोमा राख्छु"),
                pendingReminderId: nil),
            GuardFixture(
                name: "medication (no frame)",
                // The shipped medication-ack fixture
                // (`CommandRouterTests.testNepaliMedicationAcknowledgementRoutesToOldestPendingReminder`).
                utterance: "मैले औषधि खाएँ",
                scripted: nil,
                pendingReminderId: UUID())
        ]
    }

    @MainActor
    func testScenario2ReminderCalendarAndMedicationTurnsNeverOpenAFrame() throws {
        for fixture in guardFixtures() {
            // Arm A — the dialogue machinery is armed (the live coordinator:
            // real `DialogueManager`, every member implemented).
            let live = makeWorld(dialogueEnabled: true,
                                 interpreter: AcceptanceInterpreter(scripted: fixture.scripted),
                                 pendingReminderId: fixture.pendingReminderId)
            let liveResult = live.router.route(transcript: fixture.utterance)
            waitForDelivery()

            // Arm B — the SHIPPED baseline shape: the same doubles, the
            // coordinator's dialogue members inert (nil frame, refused arm,
            // no-op resolve/clear) — i.e. the pre-feature coordinator, which
            // had no dialogue members at all.
            let baseline = makeWorld(dialogueEnabled: false,
                                     interpreter: AcceptanceInterpreter(scripted: fixture.scripted),
                                     pendingReminderId: fixture.pendingReminderId)
            let baselineResult = baseline.router.route(transcript: fixture.utterance)
            waitForDelivery()

            // (1) Behavioural identity, measured — same routing outcome,
            // same spoken lines, same executed side effects, on both arms.
            XCTAssertEqual(liveResult, baselineResult,
                           "\(fixture.name): the routing outcome changed against the shipped arm")
            XCTAssertEqual(live.coordinator.assistantSpoken,
                           baseline.coordinator.assistantSpoken,
                           "\(fixture.name): the spoken lines changed against the shipped arm")
            XCTAssertEqual(live.coordinator.addedReminders.map { $0.title },
                           baseline.coordinator.addedReminders.map { $0.title },
                           "\(fixture.name): the executed reminder changed")
            XCTAssertEqual(live.coordinator.addedReminders.map { $0.time.hour },
                           baseline.coordinator.addedReminders.map { $0.time.hour },
                           "\(fixture.name): the resolved reminder hour changed")
            XCTAssertEqual(live.coordinator.addedReminders.map { $0.time.minute },
                           baseline.coordinator.addedReminders.map { $0.time.minute },
                           "\(fixture.name): the resolved reminder minute changed")
            XCTAssertEqual(live.coordinator.calendarEventRequests.map { $0.title },
                           baseline.coordinator.calendarEventRequests.map { $0.title },
                           "\(fixture.name): the executed calendar request changed")
            XCTAssertEqual(live.coordinator.acknowledgedEntryIds,
                           baseline.coordinator.acknowledgedEntryIds,
                           "\(fixture.name): the medication acknowledgement changed")
            XCTAssertEqual(live.coordinator.challengeEntryIds,
                           baseline.coordinator.challengeEntryIds,
                           "\(fixture.name): the acknowledgement challenge changed")

            // (2) Non-vacuity: the fixture really executed the shipped arm.
            switch fixture.name {
            case "reminder":
                XCTAssertEqual(live.coordinator.addedReminders.count, 1,
                               "the reminder fixture must really execute")
            case "calendar":
                XCTAssertEqual(live.coordinator.calendarEventRequests.count, 1,
                               "the calendar fixture must really execute")
            default:
                XCTAssertEqual(liveResult, .acknowledgedMedication,
                               "the medication fixture must really acknowledge")
                let pending = try XCTUnwrap(fixture.pendingReminderId)
                XCTAssertEqual(live.coordinator.challengeEntryIds, [pending],
                               "the acknowledgement must challenge the oldest pending reminder")
            }

            // (3) The FR-MTC-019 Phase-1 guard proper: with the dialogue
            // machinery armed, no frame opened, nothing was resolved, and
            // not one dialogue_* event was emitted.
            XCTAssertNil(live.coordinator.activeDialogueFrame,
                         "\(fixture.name): a dialogue frame opened on a Phase-1-unchanged turn")
            XCTAssertTrue(live.coordinator.resolutions.isEmpty,
                          "\(fixture.name): the dialogue machinery resolved something")
            XCTAssertTrue(live.dialogueEvents.isEmpty,
                          "\(fixture.name): dialogue telemetry was emitted on an unchanged turn")
            XCTAssertEqual(live.interpreter.interpretCount,
                           fixture.scripted == nil ? 0 : 1,
                           "\(fixture.name): the shipped interpreter consultation count changed")
        }
    }

    // MARK: - Scenario 3: the Phase-1 prompts are byte-unchanged and pinned

    func testScenario3ThePhaseOnePromptPinsAndFileBytesHold() throws {
        // (1) The digests, RE-DERIVED from the shipped builder — the same
        // fixtures the home suites pin (verified, never assumed).
        let defaultPrompt = IntentPrompt.build(
            transcript: Self.defaultTranscript,
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"))
        XCTAssertFalse(defaultPrompt.contains("Address them as"),
                       "the no-term fixture must carry no address-as clause")
        XCTAssertEqual(sha256Hex(defaultPrompt), Self.defaultNoTermDigest,
                       "the default no-term composition drifted from its pinned digest")

        let weatherPrompt = IntentPrompt.build(
            transcript: Self.weatherTranscript,
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"))
        XCTAssertEqual(sha256Hex(weatherPrompt), Self.weatherNoTermDigest,
                       "the weather no-term composition drifted from its pinned digest")

        // (2) NFR-MTC-002's measured baseline (exactly 2_506 Characters) and
        // the 3_000-Character on-device ceiling.
        XCTAssertEqual(weatherPrompt.count, Self.promptBaselineCharacters,
                       "the weather fixture baseline is no longer 2_506 Characters")
        XCTAssertLessThanOrEqual(weatherPrompt.count, Self.promptCeilingCharacters,
                                 "the 3_000-Character on-device ceiling is exceeded")

        // (3) Zero prompt-file edits in the feature diff, as a byte pin:
        // the working tree's prompt files must still hash to their diff-base
        // (`0cbe4e6`) bytes, and none may carry the feature's vocabulary.
        let root = try repoRoot()
        for pin in Self.promptFileBaseDigests {
            let url = root.appendingPathComponent(pin.path)
            guard let data = try? Data(contentsOf: url) else {
                return XCTFail("could not read the prompt file \(pin.path) at \(url.path)")
            }
            XCTAssertEqual(sha256Hex(data), pin.sha256,
                           "\(pin.path) differs from its diff base (0cbe4e6) — the feature "
                           + "touched a prompt file (FR-MTC-018 Phase-1 guard)")
            let text = String(decoding: data, as: UTF8.self)
            for token in Self.featureVocabulary {
                XCTAssertFalse(text.contains(token),
                               "\(pin.path) carries the feature's vocabulary ('\(token)')")
            }
        }

        // (4) The pins' HOMES are intact: both carrier suites still carry
        // the digest literals they own (a weakened or deleted home fails the
        // acceptance suite too).
        for home in ["ios/ElderlyAssistantTests/Services/Voice/IntentPromptTests.swift",
                     "ios/ElderlyAssistantTests/Services/Voice/PinnedSurfaceGuardTests.swift"] {
            let url = root.appendingPathComponent(home)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return XCTFail("the digest pin's home suite is missing: \(home)")
            }
            XCTAssertTrue(text.contains(Self.defaultNoTermDigest),
                          "\(home) no longer carries the default no-term digest pin")
            XCTAssertTrue(text.contains(Self.weatherNoTermDigest),
                          "\(home) no longer carries the weather no-term digest pin")
        }
    }

    // MARK: - Scenario 4: the pinned regression surfaces stay green

    func testScenario4ThePinnedRegressionSurfacesStayGreen() throws {
        let root = try repoRoot()

        // (1) The golden music block: re-derived from the SOURCE bytes (the
        // `PinnedSurfaceGuardTests` technique, re-expressed file-privately so
        // this suite depends on no sibling) — the digest, the 15-entry
        // count, and every entry's intent.
        let corpusURL = root.appendingPathComponent(
            "ios/ElderlyAssistantTests/Services/Voice/GoldenCorpus.swift")
        guard let corpus = try? String(contentsOf: corpusURL, encoding: .utf8) else {
            return XCTFail("the golden corpus source is missing at \(corpusURL.path)")
        }
        let slice = try XCTUnwrap(Self.musicBlockSlice(in: corpus),
                                  "the `// MARK: - music` anchor or its closing bracket is missing")
        XCTAssertEqual(slice.entryLines.count, Self.goldenMusicEntryCount,
                       "the golden music block must hold exactly 15 entries")
        XCTAssertEqual(sha256Hex(slice.blockText), Self.goldenMusicBlockDigest,
                       "the golden music block must stay byte-identical to its pin")
        for line in slice.entryLines {
            XCTAssertTrue(line.contains("intent: \"music\""),
                          "a golden music entry lost its intent: \(line)")
        }

        // (2) The carrier suites the sweep record cites are present, and
        // `GoldenCorpusTests`' own >= 15 floor test is still in place — a
        // green corpus run can never be a vacuous one.
        for carrier in [
            "ios/ElderlyAssistantTests/Services/Voice/PinnedSurfaceGuardTests.swift",
            "ios/ElderlyAssistantTests/Services/Voice/GoldenCorpusTests.swift",
            "ios/ElderlyAssistantTests/Services/Voice/CommandRouterMusicTests.swift",
            "ios/ElderlyAssistantTests/Services/Spotify/SpotifyLocalizationTests.swift",
            "ios/ElderlyAssistantTests/Services/Voice/CommandRouterTests.swift"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(carrier).path),
                "a pinned-regression carrier suite is missing: \(carrier)")
        }
        let floorURL = root.appendingPathComponent(
            "ios/ElderlyAssistantTests/Services/Voice/GoldenCorpusTests.swift")
        guard let floorSuite = try? String(contentsOf: floorURL, encoding: .utf8) else {
            return XCTFail("GoldenCorpusTests.swift is unreadable at \(floorURL.path)")
        }
        XCTAssertTrue(floorSuite.contains("func testCorpusHasAtLeast15EntriesPerIntent()"),
                      "the golden corpus's >= 15 floor test was removed or renamed")
        XCTAssertTrue(floorSuite.contains("XCTAssertGreaterThanOrEqual(count, 15"),
                      "the golden corpus's >= 15 floor assertion was weakened")
    }

    // MARK: - Hashing / source helpers

    private func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The repository root, found by walking up from this test file's own
    /// path until a directory contains BOTH the iOS sources and the
    /// training prompt seed. A failure to locate it is an explicit test
    /// failure — a scan that cannot read its inputs proves nothing.
    private func repoRoot(file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        var hops = 0
        while hops < 32 {
            let ios = url.appendingPathComponent("ios")
            let seed = url.appendingPathComponent(
                "tools/train-intent/seeds/prompt_template.txt")
            if FileManager.default.fileExists(atPath: ios.path),
               FileManager.default.fileExists(atPath: seed.path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
            hops += 1
        }
        XCTFail("could not locate the repository root from \(file)")
        throw CocoaError(.fileNoSuchFile)
    }

    /// The `// MARK: - music` slice of the golden corpus: the marker line
    /// through the first following closing-`]` line, verbatim, plus its
    /// `.init` rows (the `PinnedSurfaceGuardTests` extraction, copied
    /// exactly — the digest is over the block text these lines join to).
    private struct MusicBlockSlice {
        let blockText: String
        let entryLines: [String]
    }

    private static func musicBlockSlice(in source: String) -> MusicBlockSlice? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let marker = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "// MARK: - music"
        }) else { return nil }
        guard let closing = lines[(marker + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "]"
        }) else { return nil }
        let entryLines = lines[(marker + 1)..<closing].filter { $0.contains(".init(") }
        return MusicBlockSlice(blockText: lines[marker...closing].joined(separator: "\n"),
                               entryLines: entryLines)
    }

    // MARK: - World builder

    @MainActor
    private final class AcceptanceWorld {
        let coordinator: AcceptanceCoordinator
        let bus: MockObservabilityBus
        let speaker: AcceptanceSpeaker
        let opener: AcceptanceLinkOpener
        let interpreter: AcceptanceInterpreter
        let router: CommandRouter
        /// The four transport spies, one per injected egress seam.
        let spies: [AcceptanceEgressSpy]

        init(coordinator: AcceptanceCoordinator, bus: MockObservabilityBus,
             speaker: AcceptanceSpeaker, opener: AcceptanceLinkOpener,
             interpreter: AcceptanceInterpreter, router: CommandRouter,
             spies: [AcceptanceEgressSpy]) {
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.opener = opener
            self.interpreter = interpreter
            self.router = router
            self.spies = spies
        }

        func events(_ eventType: String) -> [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType == eventType }
        }

        /// Every `dialogue_*` event the turn emitted (the FR-MTC-019 guard's
        /// telemetry half).
        var dialogueEvents: [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType.hasPrefix("dialogue_") }
        }
    }

    @MainActor
    private func makeWorld(dialogueEnabled: Bool = true,
                           interpreter: AcceptanceInterpreter = AcceptanceInterpreter(),
                           pendingReminderId: UUID? = nil,
                           bus: MockObservabilityBus = MockObservabilityBus()) -> AcceptanceWorld {
        let coordinator = AcceptanceCoordinator(dialogueEnabled: dialogueEnabled)
        coordinator.pendingReminderId = pendingReminderId
        let speaker = AcceptanceSpeaker()
        let opener = AcceptanceLinkOpener()
        let logStore = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let spies = [AcceptanceEgressSpy(), AcceptanceEgressSpy(),
                     AcceptanceEgressSpy(), AcceptanceEgressSpy()]
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: bus,
            speaker: speaker,
            interpreter: interpreter,
            weatherTransport: spies[3],
            searchTransport: spies[2],
            localToolLogStore: logStore,
            youtubeTransport: spies[0],
            youtubeLinkOpener: opener,
            spotifyTransport: spies[1])
        return AcceptanceWorld(coordinator: coordinator, bus: bus, speaker: speaker,
                               opener: opener, interpreter: interpreter, router: router,
                               spies: spies)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "acceptance async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterDialogueTests harness)

/// Counts every `interpret` consultation and scripts the resolved command
/// (nil = the shipped abstain). The completion is SYNCHRONOUS — the
/// `FakeCommandInterpreter` idiom the interpreter-scripted routing suites
/// use (e.g. the calendar fixture's shipped test), so a routed fixture
/// settles deterministically and the counter is readable the moment
/// `route` returns.
private final class AcceptanceInterpreter: CommandInterpreter {
    private let scripted: InterpretedCommand?
    private(set) var interpretCount = 0

    init(scripted: InterpretedCommand? = nil) {
        self.scripted = scripted
    }

    var isAvailable: Bool { true }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCount += 1
        completion(scripted)
    }

    func unload() {}
}

/// The coordinator double: the six dialogue members are thin adapters over
/// a REAL `DialogueManager` when `dialogueEnabled`, and the shipped
/// pre-feature coordinator shape (nil frame, refused arm, no-op
/// resolve/clear) when not — the FR-MTC-019 A/B's two arms on otherwise
/// identical doubles. The recorders mirror `CommandRouterTests`'
/// `MockVoiceCommandCoordinator` so the guard fixtures' side effects are
/// comparable field by field.
private final class AcceptanceCoordinator: VoiceCommandCoordinating {
    let manager = DialogueManager(answerWindowSeconds: 45)
    private let dialogueEnabled: Bool

    var pendingReminderId: UUID?
    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }
    var isAwaitingCalendarEventConfirmation = false
    var calendarEventPrompt: String? = "«%1$@» पात्रोमा राखूँ?"
    var confirmationPrompt: String? = "के तपाईंले औषधि अहिले लिनुभएको हो?"

    // Records
    private(set) var resolutions: [DialogueFrameResolution] = []
    private(set) var clears: [DialogueFrameResolution] = []
    private(set) var assistantSpoken: [String] = []
    private(set) var addedReminders: [(title: String, time: DateComponents)] = []
    private(set) var calendarEventRequests: [(title: String, startDate: Date)] = []
    private(set) var acknowledgedEntryIds: [UUID] = []
    private(set) var challengeEntryIds: [UUID] = []

    init(dialogueEnabled: Bool = true) {
        self.dialogueEnabled = dialogueEnabled
    }

    // MARK: The six dialogue members

    var activeDialogueFrame: DialogueFrame? {
        dialogueEnabled ? manager.liveFrame : nil
    }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
        guard dialogueEnabled else { return false }
        do {
            try manager.arm(frame)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func noteDialogueAttempt() -> Int {
        dialogueEnabled ? manager.noteAttempt() : 1
    }

    func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {
        guard dialogueEnabled else { return }
        manager.resolve(resolution)
        resolutions.append(resolution)
    }

    func clearDialogueFrame(reason: DialogueFrameResolution) {
        guard dialogueEnabled else { return }
        manager.resolve(reason)
        clears.append(reason)
    }

    func prepareDialogueAnswerText(_ raw: String) -> String {
        guard dialogueEnabled else { return raw }
        return InputSanitiser.sanitise(raw, level: .quarantine)
    }

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { [] }

    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) {}

    func oldestPendingReminderEntryId() -> UUID? { pendingReminderId }

    func handleMedicationAcknowledgement(entryId: UUID) {
        acknowledgedEntryIds.append(entryId)
    }

    func startVoiceAckConfirmation(for entryId: UUID) -> String? {
        challengeEntryIds.append(entryId)
        isAwaitingConfirmation = confirmationPrompt != nil
        return confirmationPrompt
    }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        isAwaitingConfirmation = false
    }

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}

    func noteAssistantSpoke(_ text: String) {
        assistantSpoken.append(text)
    }

    func noteGenericReply(_ text: String) {}

    func fireNewsReader() {}

    func requestAppLaunch(appID: String, confidence: Double?) -> String { "launch line" }

    func addVoiceReminder(title: String, time: DateComponents) {
        addedReminders.append((title, time))
    }

    func requestCallConfirmation(contactQuery: String?, callType: String?,
                                 requestedApp: String?, sourceTranscript: String?,
                                 sourceCommand: InterpretedCommand?) -> String? { nil }

    func startRephraseConfirmation(_ command: InterpretedCommand,
                                   sourceTranscript: String?) {}

    func takePendingRephraseCommand()
        -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }

    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }

    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }

    func presentPluginView(_ view: AnyView) {}

    func requestContactSearch(query: String?) {}

    func requestCalendarEventConfirmation(title: String, startDate: Date) -> String? {
        calendarEventRequests.append((title, startDate))
        return calendarEventPrompt
    }
}

private final class AcceptanceSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

/// A `canOpenURL`-true opener — the anchor's executed-exactly-once witness
/// (the `CallLinkOpening` double the dialogue suites use).
private final class AcceptanceLinkOpener: CallLinkOpening {
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return true
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}

/// Counts every transport request — the NFR-MTC-003 runtime witness. A
/// request on any dialogue path is the failure's evidence.
private final class AcceptanceEgressSpy: LocalToolTransport {
    private(set) var requests: [URLRequest] = []

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        throw URLError(.unsupportedURL)
    }
}
