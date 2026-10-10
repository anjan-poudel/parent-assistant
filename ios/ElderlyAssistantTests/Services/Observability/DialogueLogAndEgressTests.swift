import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10) T-140 — the E4/E5/E6 runtime evidence suite
/// (TG-27's security evidence, W5). T-137 proved the allow-list STATIC
/// side (the six dialogue keys, the closed vocabularies, the 78→84 diff)
/// and T-138 proved the Release log gate; this suite drives the
/// PRODUCTION pipeline (the real `ConsoleObservabilityBus` with the real
/// `LogSanitiser`) over the full dialogue scenario set and captures its
/// stdout sink, so every claim below is a scan of what the shipped code
/// actually emitted:
///
///   · E4 — over probe, answer, merge, cancel, timeout, escape,
///     exhaustion and did-you-mean: every sink payload carries only
///     allow-listed keys, every dialogue event carries only §26's
///     closed key set, and DISTINCTIVE MARKER TOKENS planted in the
///     fixtures (and proven to have flowed, in-process, into the frame
///     and the speech/execution seams) never appear in any sink payload;
///   · E5 — the closed-vocabulary machinery at runtime: an
///     out-of-vocabulary token under a dialogue key is redacted by the
///     production sanitiser, an unlisted key is dropped whole, in-
///     vocabulary tokens pass verbatim, and `reason` (a SHIPPED key —
///     reuse verified, not assumed) passes verbatim while the shipped
///     84-key allow-list holds;
///   · E6 — the source audit (no new host/endpoint/transport construct
///     in the four dialogue files, CommandRouter's six dialogue regions,
///     or the coordinator's dialogue extension) combined with a runtime
///     egress spy over the executed paths (probe, answer, merge, cancel,
///     exhaustion, default execution): zero transport requests, and the
///     merged music execution reaches the pre-existing offline playback
///     helper (`youtubeLinkOpener` + `YouTubeTool.appSearchURL`) ONLY.
///
/// Sink discipline (R1, documented): "sink payload" is a BUS line —
/// `[HH:mm:ss.SSS][component] …` — the only line the observability
/// pipeline writes. The pre-existing `#if DEBUG` prints in
/// `CommandRouter.speak()` are outside the pipeline (an accepted
/// residual, security-design-review R1) and are therefore not scanned;
/// the marker proofs below compensate: every marker is proven to have
/// really flowed (frame/speech/URL witnesses), so its absence from the
/// sink is causal, not vacuous.
///
/// Doubles are file-private mirrors of the `CommandRouterDialogueTests`
/// harness. No sleeps — async legs wait on `waitForDelivery`.
@MainActor
final class DialogueLogAndEgressTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    /// The six documented dialogue keys (T-137).
    private let dialogueKeys: Set<String> = [
        "intake", "probe_kind", "attempt", "option_count", "capture_form", "merge_source"
    ]

    /// §26's closed key set for `dialogue_*` events: the six new keys
    /// plus the two shipped keys the dialogue events reuse (`reason`,
    /// `outcome`).
    private let dialogueEventKeys: Set<String> = [
        "intake", "probe_kind", "attempt", "option_count", "capture_form", "merge_source",
        "reason", "outcome"
    ]

    /// The closed invalid-answer vocabulary (`InvalidAnswerReason`).
    private let invalidAnswerReasons: Set<String> = [
        "overLength", "emptyAfterStrip", "degenerateAnswer", "noCandidateClaimed"
    ]

    // MARK: - Console capture (the LiveTranslate/DialogueCoordinatorWiring idiom)

    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/dialogue-log-egress-sink-\(UUID().uuidString).log"
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

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "log-suite async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    private func drainMainQueue() {
        let done = expectation(description: "main drain")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Sink parsing

    /// The only lines the observability pipeline writes: `[HH:mm:ss.SSS][component] …`.
    private func sinkLines(in console: String) -> [String] {
        console.components(separatedBy: "\n").filter {
            $0.range(of: #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\]\["#, options: .regularExpression) != nil
        }
    }

    private static let eventTypeRegex = try! NSRegularExpression(pattern: #"\] (\w+) outcome="#)
    private static let metadataKeyRegex = try! NSRegularExpression(pattern: #""([^"]+)":\s""#)
    private static let reasonValueRegex = try! NSRegularExpression(pattern: #""reason": "([^"]+)""#)

    private func eventType(of line: String) -> String? {
        let ns = line as NSString
        guard let match = Self.eventTypeRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)),
            match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// The metadata dict's keys as rendered by the bus (`metadata=["k": "v", …]`).
    /// Dictionary order is unstable, so callers assert per-key substrings,
    /// never whole-rendered strings.
    private func metadataKeys(in line: String) -> Set<String> {
        guard let range = line.range(of: "metadata=") else { return [] }
        let metadata = String(line[range.upperBound...])
        let ns = metadata as NSString
        var keys: Set<String> = []
        Self.metadataKeyRegex.enumerateMatches(
            in: metadata, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            if let match, match.numberOfRanges > 1 {
                keys.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        return keys
    }

    private func reasonValue(in line: String) -> String? {
        let ns = line as NSString
        guard let match = Self.reasonValueRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)),
            match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// The E4 scan for one captured scenario: every sink line's metadata
    /// keys are allow-listed, every `dialogue_*` line's keys are inside
    /// §26's closed set, no marker appears in any sink payload, and the
    /// expected witness substrings are present (non-vacuity). Returns
    /// the dialogue keys observed, for the suite-level §26 union pin.
    @discardableResult
    private func assertSinkHygiene(_ console: String, scenario: String,
                                   markers: [String],
                                   expectedSubstrings: [String],
                                   file: StaticString = #filePath,
                                   line: UInt = #line) -> Set<String> {
        let lines = sinkLines(in: console)
        XCTAssertFalse(lines.isEmpty,
                       "\(scenario): no bus lines were captured — the scenario is vacuous",
                       file: file, line: line)
        var dialogueKeysSeen: Set<String> = []
        for sinkLine in lines {
            let keys = metadataKeys(in: sinkLine)
            let unknown = keys.subtracting(LogSanitiser.allowedKeys)
            XCTAssertTrue(unknown.isEmpty,
                          "\(scenario): sink line carried unlisted metadata keys \(unknown): \(sinkLine)",
                          file: file, line: line)
            if let type = eventType(of: sinkLine), type.hasPrefix("dialogue_") {
                let foreign = keys.subtracting(dialogueEventKeys)
                XCTAssertTrue(foreign.isEmpty,
                              "\(scenario): dialogue event \(type) carried keys outside §26's closed set \(foreign): \(sinkLine)",
                              file: file, line: line)
                dialogueKeysSeen.formUnion(keys)
            }
            let lowered = sinkLine.lowercased()
            for marker in markers {
                XCTAssertFalse(lowered.contains(marker),
                               "\(scenario): marker '\(marker)' leaked into a sink payload: \(sinkLine)",
                               file: file, line: line)
            }
        }
        for needle in expectedSubstrings {
            XCTAssertTrue(console.contains(needle),
                          "\(scenario): expected sink content missing: \(needle)",
                          file: file, line: line)
        }
        return dialogueKeysSeen
    }

    // MARK: - E4: the full dialogue scenario set, captured through the production pipeline

    @MainActor
    func testTheFullDialogueScenarioSetEmitsOnlyAllowListedKeysAndNoContent() throws {
        var observedDialogueKeys: Set<String> = []

        // (1) probe — the degenerate ladder intake. No marker rides this
        // fixture: the intake decision IS the extraction's provenance
        // ("भजन बजाऊ" → markerFallback), so any free-form token would
        // flip it to a real content query — the degenerate query is
        // vocabulary-bound by construction. The absent-content claim is
        // instead pinned by exact closed VALUES (intake/probe_kind/
        // attempt/option_count) — nothing else could fit the payload.
        do {
            let world = makeWorld()
            let console = captureConsole {
                _ = world.router.route(transcript: "भजन बजाऊ")
                waitForDelivery()
            }
            let frame = try XCTUnwrap(world.coordinator.manager.frame,
                                      "the degenerate intake must arm the slot-fill frame")
            XCTAssertEqual(frame.sourceTranscript, "भजन बजाऊ")
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "probe", markers: [],
                expectedSubstrings: [
                    "dialogue_degenerate_query", "\"intake\": \"ladder\"",
                    "dialogue_probe_spoken", "\"probe_kind\": \"slotFill\"",
                    "\"attempt\": \"1\"", "\"option_count\": \"4\""
                ]))
        }

        // (2) answer — a free-text slot-fill answer carrying a marker
        // utterance. The marker is proven to flow: the recorded merge
        // value contains it and the unlinked music arm opens its URL.
        do {
            let marker = "zmtcanswerx"
            let world = makeWorld()
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: musicCommand(), sourceTranscript: "भजन बजाऊ")))
            let console = captureConsole {
                _ = world.router.route(transcript: "दशैं दुर्गा भजन \(marker)")
                waitForDelivery()
            }
            let resolution = try XCTUnwrap(world.coordinator.resolutions.last)
            guard case .answered(let merge) = resolution else {
                return XCTFail("answer leg: expected .answered, got \(resolution)")
            }
            XCTAssertTrue(merge.value.contains(marker),
                          "answer leg: the marker must ride the merged value (content really flowed)")
            XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: merge.value)],
                           "answer leg: the merged value reached the pre-existing music helper")
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "answer", markers: [marker],
                expectedSubstrings: [
                    "\"capture_form\": \"freeText\"", "\"merge_source\": \"freeText\"",
                    "outcome=answered"
                ]))
        }

        // (3) merge — a candidate-choice free-form claim carrying a
        // marker utterance; the claim's extracted value reaches the
        // helper and the recorded merge names `.candidate`.
        do {
            let marker = "zmtcmerge"
            let world = makeWorld()
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                candidateChoiceDraft([musicCandidate(query: "रामायण", matchKeys: [])],
                                     sourceTranscript: "पुरानो गीत")))
            let console = captureConsole {
                _ = world.router.route(transcript: "रामायण \(marker)")
                waitForDelivery()
            }
            let resolution = try XCTUnwrap(world.coordinator.resolutions.last)
            guard case .answered(let merge) = resolution else {
                return XCTFail("merge leg: expected .answered, got \(resolution)")
            }
            XCTAssertEqual(merge.source, .candidate)
            XCTAssertTrue(merge.value.contains(marker),
                          "merge leg: the marker must ride the claimed value")
            let played = try XCTUnwrap(world.opener.opened.last)
            XCTAssertEqual(played, YouTubeTool.appSearchURL(query: merge.value),
                           "merge leg: the claimed value reached the pre-existing music helper")
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "merge", markers: [marker],
                expectedSubstrings: [
                    "\"capture_form\": \"freeText\"", "\"merge_source\": \"candidate\"",
                    "outcome=answered"
                ]))
        }

        // (4) cancel — the marker sits on the frame's sourceTranscript
        // fixture (the utterance is the bare "रद्द").
        do {
            let marker = "zmtccancelx"
            let world = makeWorld()
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: musicCommand(),
                                  sourceTranscript: "भजन बजाऊ \(marker)")))
            let console = captureConsole {
                _ = world.router.route(transcript: "रद्द")
            }
            XCTAssertEqual(world.coordinator.resolutions, [.cancelled])
            XCTAssertNil(world.coordinator.manager.frame)
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "cancel", markers: [marker],
                expectedSubstrings: ["outcome=cancelled", "\"outcome\": \"cancelled\""]))
        }

        // (5) timeout — the REAL coordinator's funnel (the only dialogue
        // event with component app_coordinator). The marker sits on the
        // frame's sourceTranscript fixture.
        do {
            let marker = "zmtctimeoutx"
            let coordinator = AppCoordinator(profileStorage: LogInMemoryProfilePayloadStorage())
            let draft = DialogueFrame.slotFill(
                candidates: [musicCandidate(query: "दुर्गा भजन", matchKeys: ["दुर्गा"])],
                defaultQuery: "भजन", domain: .music, activeCommand: musicCommand(),
                sourceTranscript: "भजन बजाऊ \(marker)")
            XCTAssertTrue(coordinator.startDialogueFrame(draft))
            drainMainQueue()
            let console = captureConsole {
                coordinator.voiceSession.onSlotAnswerTimeout?()
            }
            XCTAssertNil(coordinator.activeDialogueFrame, "the timeout resolves the frame")
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "timeout", markers: [marker],
                expectedSubstrings: [
                    "[app_coordinator] dialogue_frame_resolved outcome=timedOut",
                    "\"outcome\": \"timedOut\""
                ]))
        }

        // (6) escape — the marker rides the utterance itself.
        do {
            let marker = "zmtcescapex"
            let world = makeWorld()
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: musicCommand(), sourceTranscript: "भजन बजाऊ")))
            let console = captureConsole {
                _ = world.router.route(transcript: "फेरि भन्छु \(marker)")
            }
            XCTAssertEqual(world.coordinator.resolutions, [.escaped])
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "escape", markers: [marker],
                expectedSubstrings: ["outcome=escaped", "\"outcome\": \"escaped\""]))
        }

        // (7) exhaustion — the slot-fill attempt cap executes the
        // pending default ("भजन"); the marker sits on the frame's
        // sourceTranscript fixture (the degenerate default is vocabulary-bound).
        do {
            let marker = "zmtcexhx"
            let world = makeWorld()
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: nil,
                                  sourceTranscript: "भजन बजाऊ \(marker)")))
            let console = captureConsole {
                _ = world.router.route(transcript: "भजन बजाऊ")
                _ = world.router.route(transcript: "भजन बजाऊ")
                waitForDelivery()
            }
            XCTAssertEqual(world.coordinator.resolutions, [.defaultExecuted])
            XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "भजन")])
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "exhaustion", markers: [marker],
                expectedSubstrings: [
                    "\"attempt\": \"2\"", "\"option_count\": \"4\"",
                    "\"reason\": \"degenerateAnswer\"",
                    "outcome=defaultExecuted", "\"merge_source\": \"defaultQuery\""
                ]))
        }

        // (8) did-you-mean — the rephrase-discard candidate-choice
        // frame. The marker rides the denied hypothesis' own words. The
        // pending source is "समाचार": the R2 never-alone rule re-offers
        // the hypothesis ONLY alongside a near-match, so the fixture
        // pairs it with the proven news reading (2 candidates → the
        // frame and the probe body both carry the marker — it provably
        // reached the spoken surface and the re-offered candidate, never
        // the sink).
        do {
            let marker = "zmtcdym"
            let world = makeWorld()
            world.coordinator.isAwaitingConfirmation = true
            world.coordinator.pendRephrase(musicCommand(message: "दुर्गा भजन \(marker)"),
                                           sourceTranscript: "समाचार")
            let console = captureConsole {
                _ = world.router.route(transcript: "होइन")
                waitForDelivery()
            }
            let frame = try XCTUnwrap(world.coordinator.manager.frame,
                                      "the did-you-mean frame is armed")
            XCTAssertEqual(frame.probeKind, .candidateChoice)
            XCTAssertEqual(frame.candidates.count, 2)
            XCTAssertTrue(frame.candidates.contains { $0.query?.contains(marker) == true },
                          "did-you-mean leg: the hypothesis words are the re-offered candidate (content really flowed)")
            XCTAssertTrue(world.coordinator.assistantSpoken.contains { $0.contains(marker) },
                          "did-you-mean leg: the hypothesis words reached the spoken probe")
            observedDialogueKeys.formUnion(assertSinkHygiene(
                console, scenario: "did-you-mean", markers: [marker],
                expectedSubstrings: [
                    "dialogue_probe_spoken", "\"probe_kind\": \"candidateChoice\"",
                    "\"option_count\": \"2\""
                ]))
        }

        // The suite-level §26 pin: across the whole scenario set the
        // runtime-observed dialogue metadata vocabulary is EXACTLY the
        // closed set — no seventh key, no stray field.
        XCTAssertEqual(observedDialogueKeys, dialogueEventKeys,
                       "the observed dialogue metadata vocabulary must be exactly §26's closed set")
    }

    // MARK: - E5: the closed-vocabulary machinery at runtime

    /// The production bus + sanitiser, driven directly: an
    /// out-of-vocabulary token under a dialogue key is redacted (the
    /// pair survives, the content does not); an unlisted key is dropped
    /// whole; in-vocabulary tokens pass verbatim; `reason` — a SHIPPED
    /// key, reused not added — passes verbatim. The static frame around
    /// it: the shipped allow-list still carries the six documented keys,
    /// and `reason` is provably NOT one of them.
    func testTheClosedVocabularyRedactsOutOfVocabularyTokensAndDropsUnlistedKeys() {
        XCTAssertTrue(dialogueKeys.isSubset(of: LogSanitiser.allowedKeys),
                      "the six documented dialogue keys must be in the shipped allow-list")
        XCTAssertEqual(LogSanitiser.allowedKeys.count, 84,
                       "T-137's documented 78→84 diff: six keys added, none removed")
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("reason"),
                      "reason is a shipped key")
        XCTAssertFalse(dialogueKeys.contains("reason"),
                       "reason was REUSED, not added by this feature (verified, not assumed)")

        let bus = ConsoleObservabilityBus(sanitiser: LogSanitiser())
        let console = captureConsole {
            bus.emit(ObservabilityEvent(
                component: "command_router", eventType: "dialogue_probe_spoken",
                durationMs: nil, outcome: "success", errorCode: nil,
                metadata: ["probe_kind": "zmtchostiletoken", "attempt": "1",
                           "option_count": "2"]))
            bus.emit(ObservabilityEvent(
                component: "command_router", eventType: "dialogue_answer",
                durationMs: nil, outcome: "success", errorCode: nil,
                metadata: ["free_text_answer": "zmtcunlistedvalue", "reason": "overLength"]))
            bus.emit(ObservabilityEvent(
                component: "command_router", eventType: "dialogue_degenerate_query",
                durationMs: nil, outcome: "info", errorCode: nil,
                metadata: ["intake": "ladder"]))
        }

        let lines = sinkLines(in: console)
        XCTAssertEqual(lines.count, 3, "three emissions, three sink lines: \(console)")

        // Out-of-vocabulary token: redacted, key kept.
        XCTAssertTrue(lines[0].contains("\"probe_kind\": \"[redacted]\""),
                      "an out-of-vocabulary probe_kind must be redacted: \(lines[0])")
        XCTAssertFalse(lines[0].contains("zmtchostiletoken"))
        XCTAssertTrue(lines[0].contains("\"attempt\": \"1\""),
                      "in-vocabulary tokens pass verbatim")
        XCTAssertTrue(lines[0].contains("\"option_count\": \"2\""))

        // Unlisted key: dropped whole, value never rendered.
        XCTAssertFalse(lines[1].contains("free_text_answer"),
                       "an unlisted key must be dropped from the payload")
        XCTAssertFalse(lines[1].contains("zmtcunlistedvalue"))
        XCTAssertTrue(lines[1].contains("\"reason\": \"overLength\""),
                      "reason renders verbatim (its closure lives at the producer, not the bus — M-4)")

        // In-vocabulary token under a second key family: verbatim.
        XCTAssertTrue(lines[2].contains("\"intake\": \"ladder\""))
    }

    // MARK: - E5 (producer half): the invalid-answer reason vocabulary

    /// The runtime half of `reason`'s closed vocabulary: the shipped
    /// invalid path can only ever emit one of the four
    /// `InvalidAnswerReason` values, rendered verbatim. (The three
    /// INVALID reasons in `invalidAnswerReasons` that this leg does not
    /// produce are pinned by `CommandRouterDialogueTests`, whose
    /// scenario set covers all four; this leg pins the rendering path.)
    @MainActor
    func testTheInvalidAnswerReasonStaysClosedAtTheProducer() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(
            try slotFillDraft(activeCommand: musicCommand())))
        // The T-133 overLength fixture: clears the gibberish guard, then
        // trips the classifier's C1 raw-length gate.
        let raw = ["आज बिहान मैले मेरो औषधि खाएँ र त्यसपछि केही समय आराम गरेँ अनि अलिकति पानी पिएँ।",
                   "भोलि दिउँसो म हजुरबुबासँग बजार जान्छु किनभने नयाँ कपडा र जुत्ता किन्नु छ।",
                   "हिजो साँझ पाहुना आएकोले हामीले मिठाई र चिया खाएर कुरा गर्‍यौं, धेरै रमाइलो भयो।",
                   "अनि हामीले बेलुका छिमेकीलाई भेट्न गयौँ र उनीहरूसँग धेरै बेर गफ गर्‍यौं।",
                   "आज बेलुका हामी सबै सँगै बसेर मिठो खाना खान्छौं।"]
            .joined(separator: " ")
        XCTAssertEqual(TranscriptSanityGuard.check(raw), .pass)
        XCTAssertGreaterThan(raw.count, InputSanitiser.maxLength)

        let console = captureConsole {
            _ = world.router.route(transcript: raw)
        }

        let invalidLines = sinkLines(in: console).filter {
            $0.contains("dialogue_answer") && $0.contains("outcome=invalid")
        }
        XCTAssertEqual(invalidLines.count, 1, "one invalid answer, one sink line: \(console)")
        let line = try XCTUnwrap(invalidLines.first)
        let reason = try XCTUnwrap(reasonValue(in: line),
                                   "the invalid line must carry its reason verbatim: \(line)")
        XCTAssertTrue(invalidAnswerReasons.contains(reason),
                      "reason '\(reason)' is outside the closed InvalidAnswerReason vocabulary")
        XCTAssertEqual(reason, "overLength", "the over-length fixture must trip C1")
    }

    // MARK: - E6 (source half): no new network construction

    /// The feature's files and regions construct no host, endpoint or
    /// transport: the four dialogue files (comment-stripped whole-file
    /// scans) and the dialogue regions of `CommandRouter.swift` and
    /// `AppCoordinator.swift` contain none of the network symbols this
    /// repo's clients use. The catalog's one URL-shaped construct is its
    /// LOCAL bundle lookup — pinned here so the permitted set is
    /// explicit, not absence-by-oversight.
    func testNoDialoguePathConstructsNetworkEgress() throws {
        let forbidden = ["URLSession", "URLRequest", "URLComponents", "URL(string:",
                         "http://", "https://", "NWConnection", "NWPathMonitor",
                         "CFNetwork", "dataTask", "fetchData(for:", "LocalToolTransport"]
        let root = FeatureSourceScan.iosDirectory(file: #filePath)

        // (a) the four dialogue files — whole-file, comment-stripped.
        for relative in ["ElderlyAssistant/Services/Voice/DialogueManager.swift",
                         "ElderlyAssistant/Services/Voice/DialogueAnswerPath.swift",
                         "ElderlyAssistant/Services/Voice/DialogueCandidateBuilder.swift",
                         "ElderlyAssistant/Services/Voice/DialogueOptionCatalog.swift"] {
            let text = FeatureSourceScan.codeText(of: root.appendingPathComponent(relative))
            XCTAssertFalse(text.isEmpty, "could not read \(relative)")
            for symbol in forbidden {
                XCTAssertFalse(text.contains(symbol),
                               "\(relative) must not contain \(symbol) (NFR-MTC-003)")
            }
        }

        // The catalog's one permitted URL construct: its local bundle
        // resource lookup (no network).
        let catalog = FeatureSourceScan.codeText(
            of: root.appendingPathComponent("ElderlyAssistant/Services/Voice/DialogueOptionCatalog.swift"))
        XCTAssertTrue(catalog.contains("url(forResource:"),
                      "the catalog must read its shipped resource from the bundle")

        // (b) CommandRouter's six dialogue regions (the T-133/T-134 anchors).
        let routerURL = root.appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift")
        let routerSource = try String(contentsOf: routerURL, encoding: .utf8)
        let routerRegions: [(String, String, String)] = [
            ("interception", "// [MULTI-TURN] (2026-10-10, C-MTC-05 §12.2)",
             "// Deterministic safety net FIRST"),
            ("helpers", "// MARK: - [MTC] Dialogue frame",
             "/// One music turn, state machine B"),
            ("rephrase-discard", "// [MTC-T134] rephrase-discard",
             "// Call-confirmation correction protocol"),
            ("ladder-degenerate", "// [MTC-T134] ladder-degenerate",
             "// [APP-LAUNCHER] (2026-09-16) The launcher's voice fast"),
            ("keyword-remainder", "// [MTC-T134] keyword-remainder",
             "case .downloadingBrain:"),
            ("interpreted-degenerate", "// [MTC-T134] interpreted-degenerate",
             "case .sendMessage:")
        ]
        for (label, start, end) in routerRegions {
            let region = try XCTUnwrap(Self.region(in: routerSource, from: start, to: end),
                                       "router region anchor missing: \(label)")
            for symbol in forbidden {
                XCTAssertFalse(region.contains(symbol),
                               "CommandRouter's \(label) region must not contain \(symbol)")
            }
        }

        // (c) the coordinator's dialogue extension (the six members, the
        // funnel and the internals extension, up to the next MARK).
        let coordinatorURL = root.appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        let coordinatorSource = try String(contentsOf: coordinatorURL, encoding: .utf8)
        let coordinatorRegion = try XCTUnwrap(
            Self.region(in: coordinatorSource,
                        from: "extension AppCoordinator: VoiceCommandCoordinating {",
                        to: "// MARK: - Voice-OS shell v1: push-speech card presentation"),
            "the coordinator dialogue region is missing")
        for symbol in forbidden {
            XCTAssertFalse(coordinatorRegion.contains(symbol),
                           "the coordinator's dialogue region must not contain \(symbol)")
        }
    }

    // MARK: - E6 (runtime half): the executed paths reach no transport

    /// A runtime spy over the executed dialogue paths. The world is the
    /// unlinked/keyless world (no YouTube/Spotify/Search config, no
    /// Spotify session) with counting transports injected at every seam:
    /// probe (arms, executes nothing), answer (merged value), merge
    /// (candidate claim), cancel (executes nothing), exhaustion + default
    /// execution (the pending default). Every execution must land on the
    /// pre-existing offline playback helper — `youtubeLinkOpener` with
    /// `YouTubeTool.appSearchURL(query: <the recorded value>)` — and
    /// ZERO transport requests may occur on any path.
    @MainActor
    func testTheExecutedDialoguePathsReachNoTransportAndOnlyTheOfflinePlaybackHelper() throws {
        var allSpies: [EgressSpyTransport] = []
        var allOpened: [URL] = []
        var expected: [URL] = []

        // (1) probe — the degenerate intake consumes the turn; nothing executes.
        do {
            let world = makeWorld()
            allSpies.append(contentsOf: world.spies)
            _ = world.router.route(transcript: "भजन बजाऊ")
            waitForDelivery()
            XCTAssertNotNil(world.coordinator.manager.frame, "the probe armed (non-vacuous)")
            XCTAssertTrue(world.opener.opened.isEmpty, "the probe executes nothing")
            allOpened.append(contentsOf: world.opener.opened)
        }

        // (2) answer — the merged value executes through the music arm.
        do {
            let world = makeWorld()
            allSpies.append(contentsOf: world.spies)
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: musicCommand(), sourceTranscript: "भजन बजाऊ")))
            _ = world.router.route(transcript: "दशैं दुर्गा भजन zmtcanswerx")
            waitForDelivery()
            let resolution = try XCTUnwrap(world.coordinator.resolutions.last)
            guard case .answered(let merge) = resolution else {
                return XCTFail("answer leg: expected .answered, got \(resolution)")
            }
            expected.append(YouTubeTool.appSearchURL(query: merge.value))
            allOpened.append(contentsOf: world.opener.opened)
        }

        // (3) merge — the candidate claim's extracted value executes.
        do {
            let world = makeWorld()
            allSpies.append(contentsOf: world.spies)
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                candidateChoiceDraft([musicCandidate(query: "रामायण", matchKeys: [])],
                                     sourceTranscript: "पुरानो गीत")))
            _ = world.router.route(transcript: "रामायण zmtcmerge")
            waitForDelivery()
            let resolution = try XCTUnwrap(world.coordinator.resolutions.last)
            guard case .answered(let merge) = resolution else {
                return XCTFail("merge leg: expected .answered, got \(resolution)")
            }
            expected.append(YouTubeTool.appSearchURL(query: merge.value))
            allOpened.append(contentsOf: world.opener.opened)
        }

        // (4) cancel — nothing executes.
        do {
            let world = makeWorld()
            allSpies.append(contentsOf: world.spies)
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: musicCommand())))
            _ = world.router.route(transcript: "रद्द")
            waitForDelivery()
            XCTAssertEqual(world.coordinator.resolutions, [.cancelled])
            allOpened.append(contentsOf: world.opener.opened)
        }

        // (5) exhaustion + default execution — the pending default executes.
        do {
            let world = makeWorld()
            allSpies.append(contentsOf: world.spies)
            XCTAssertTrue(world.coordinator.startDialogueFrame(
                try slotFillDraft(activeCommand: nil)))
            _ = world.router.route(transcript: "भजन बजाऊ")
            _ = world.router.route(transcript: "भजन बजाऊ")
            waitForDelivery()
            XCTAssertEqual(world.coordinator.resolutions, [.defaultExecuted])
            expected.append(YouTubeTool.appSearchURL(query: "भजन"))
            allOpened.append(contentsOf: world.opener.opened)
        }

        XCTAssertEqual(allOpened, expected,
                       "every execution reached exactly the pre-existing offline playback helper")
        for spy in allSpies {
            XCTAssertTrue(spy.requests.isEmpty,
                          "a dialogue path reached a transport — the offline helper ONLY rule broke")
        }
    }

    // MARK: - Source-slice helper

    private static func region(in text: String, from start: String, to end: String) -> String? {
        guard let lower = text.range(of: start),
              let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[lower.lowerBound..<upper.lowerBound])
    }

    // MARK: - World builder

    @MainActor
    private final class World {
        let coordinator: LogMockCoordinator
        let speaker: LogMockSpeaker
        let opener: LogLinkOpener
        let interpreter: StubCommandInterpreter
        let router: CommandRouter
        /// The four egress spies, one per injected transport seam.
        let spies: [EgressSpyTransport]

        init(coordinator: LogMockCoordinator, speaker: LogMockSpeaker,
             opener: LogLinkOpener, interpreter: StubCommandInterpreter,
             router: CommandRouter, spies: [EgressSpyTransport]) {
            self.coordinator = coordinator
            self.speaker = speaker
            self.opener = opener
            self.interpreter = interpreter
            self.router = router
            self.spies = spies
        }
    }

    /// One router over one fake world, with the PRODUCTION
    /// `ConsoleObservabilityBus` (the real `LogSanitiser`) as the sink —
    /// captured stdout is the evidence — and counting transports injected
    /// at every seam (the runtime half of E6 is armed here, honest even
    /// in legs that never execute music).
    @MainActor
    private func makeWorld(interpreter: StubCommandInterpreter = StubCommandInterpreter(result: nil)) -> World {
        let coordinator = LogMockCoordinator()
        let speaker = LogMockSpeaker()
        let opener = LogLinkOpener()
        let logStore = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let spies = [EgressSpyTransport(), EgressSpyTransport(),
                     EgressSpyTransport(), EgressSpyTransport()]
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: ConsoleObservabilityBus(sanitiser: LogSanitiser()),
            speaker: speaker,
            interpreter: interpreter,
            weatherTransport: spies[3],
            searchTransport: spies[2],
            localToolLogStore: logStore,
            youtubeTransport: spies[0],
            youtubeLinkOpener: opener,
            spotifyTransport: spies[1])
        return World(coordinator: coordinator, speaker: speaker, opener: opener,
                     interpreter: interpreter, router: router, spies: spies)
    }

    // MARK: - Fixtures

    private func musicCommand(message: String? = nil) -> InterpretedCommand {
        InterpretedCommand(action: .music, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    private func musicCandidate(query: String? = nil,
                                matchKeys: [String] = []) -> DialogueCandidate {
        DialogueCandidate(id: UUID().uuidString, labelKey: "dialogue.candidate.music",
                          domain: .music, query: query, appID: nil, matchKeys: matchKeys)
    }

    private func slotFillDraft(activeCommand: InterpretedCommand? = nil,
                               defaultQuery: String = "भजन",
                               sourceTranscript: String = "भजन बजाऊ") throws -> DialogueFrame {
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.groupForMusicQuery(defaultQuery),
                                  "the shipped catalog must claim the pending query")
        return DialogueFrame.slotFill(
            candidates: DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog),
            defaultQuery: defaultQuery,
            domain: .music,
            activeCommand: activeCommand,
            sourceTranscript: sourceTranscript)
    }

    private func candidateChoiceDraft(_ candidates: [DialogueCandidate],
                                      sourceTranscript: String) -> DialogueFrame {
        DialogueFrame.candidateChoice(candidates: candidates, sourceTranscript: sourceTranscript)
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterDialogueTests harness)

/// The coordinator double: the six dialogue members are thin adapters
/// over a REAL `DialogueManager`; every resolution, spoken line and
/// rephrase take is recorded for assertions. (The leg that exercises the
/// coordinator's own funnel — the timeout — uses the real
/// `AppCoordinator` instead.)
private final class LogMockCoordinator: VoiceCommandCoordinating {
    let manager = DialogueManager(answerWindowSeconds: 45)

    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    private(set) var resolutions: [DialogueFrameResolution] = []
    private(set) var clears: [DialogueFrameResolution] = []
    private(set) var assistantSpoken: [String] = []
    private(set) var recordedTranscripts: [String] = []
    private(set) var rephraseTakes = 0
    private var rephrasePended: (command: InterpretedCommand, sourceTranscript: String?)?

    func pendRephrase(_ command: InterpretedCommand, sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }

    // MARK: The six dialogue members

    var activeDialogueFrame: DialogueFrame? { manager.liveFrame }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
        do {
            try manager.arm(frame)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func noteDialogueAttempt() -> Int { manager.noteAttempt() }

    func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {
        manager.resolve(resolution)
        resolutions.append(resolution)
    }

    func clearDialogueFrame(reason: DialogueFrameResolution) {
        manager.resolve(reason)
        clears.append(reason)
    }

    func prepareDialogueAnswerText(_ raw: String) -> String {
        InputSanitiser.sanitise(raw, level: .quarantine)
    }

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { [] }

    var pendingRephraseCommand: InterpretedCommand? { rephrasePended?.command }

    func recordTranscript(_ text: String) {
        recordedTranscripts.append(text)
    }

    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {}

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}

    func noteAssistantSpoke(_ text: String) {
        assistantSpoken.append(text)
    }

    func noteGenericReply(_ text: String) {}

    func fireNewsReader() {}

    func requestAppLaunch(appID: String, confidence: Double?) -> String {
        "launch line"
    }

    func addVoiceReminder(title: String, time: DateComponents) {}

    func requestCallConfirmation(contactQuery: String?, callType: String?,
                                 requestedApp: String?, sourceTranscript: String?,
                                 sourceCommand: InterpretedCommand?) -> String? {
        "हो भन्नुहोस्"
    }

    func startRephraseConfirmation(_ command: InterpretedCommand,
                                   sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }

    func takePendingRephraseCommand()
        -> (command: InterpretedCommand, sourceTranscript: String?)? {
        rephraseTakes += 1
        let taken = rephrasePended
        rephrasePended = nil
        return taken
    }

    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }

    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }

    func presentPluginView(_ view: AnyView) {}

    func requestContactSearch(query: String?) {}
}

private final class LogMockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

private final class LogLinkOpener: CallLinkOpening {
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

/// Counts every transport request — the E6 runtime witness. A request
/// must never occur on any dialogue path; if one does, it is the
/// failure's evidence.
private final class EgressSpyTransport: LocalToolTransport {
    private(set) var requests: [URLRequest] = []

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        throw URLError(.unsupportedURL)
    }
}

/// In-memory stand-in for the encrypted channel (the established
/// repo-wide fake's shape): the coordinator's init requires one and
/// nothing in the timeout leg reads the profile back.
private final class LogInMemoryProfilePayloadStorage: ProfilePayloadStorage {
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
