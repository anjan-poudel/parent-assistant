import XCTest
@testable import ElderlyAssistant

/// T-173 — the fail-closed chat-routing decision (design-l1 §8.1; FR-CNR-008,
/// FR-CNR-009, FR-CNR-010, NFR-CNR-002).
///
/// The unit's safety argument is exhaustiveness, so the suite is a
/// grid-and-boundary suite rather than a happy-path one:
///
///  - **The single yes, exhaustively.** All 4 x 2 x 2 x 2 = 32 cells of
///    consent (the gate's four readable states) x online x key x cost are
///    driven, and exactly ONE returns cloud. The design calls this the
///    "sixteen-cell" decision; taken at the consent axis's full width it is
///    32, which contains the sixteen.
///  - **The reason names the first blocking input,** in the fixed order
///    consent -> online -> key -> cost, and the three non-granted consent
///    states keep the gate's own names — a human reads these to know why the
///    cloud was not used.
///  - **Revocation is read per turn.** The seam caches no route and the gate
///    caches no grant: two decisions around a real `revoke()` disagree, and
///    the second names the state the gate actually reports. The gate's
///    readable state cannot distinguish a withdrawal from a decline
///    (`Decision.denied` is "the elder declined, or revoked"), so the
///    decision reports `consentDenied` and never fabricates `consentRevoked`
///    — the token belongs to the surfaces that performed the withdrawal and
///    know it, not to a single-consent-source read.
///  - **Unknown inputs fail closed.** Absent, nil-returning and throwing
///    readers — every one of them, in every combination — resolve to local,
///    never cloud: no code path turns an unknown input into egress.
///  - **Classification only, structurally.** The routing source contains no
///    string literal at all, no logging call, no transport, no model and no
///    UI — there is nothing in the file for content to travel through.
final class CloudChatRoutingTests: XCTestCase {

    private let consentKey = CloudChatConsentGate.storageKey
    private let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    private func makeGate() -> CloudChatConsentGate {
        CloudChatConsentGate(storage: storage,
                             observabilityBus: bus,
                             now: { self.recordedAt })
    }

    // MARK: - Scenario: the single yes

    func testTheSingleYesIsGrantedOnlineKeyedAndUnderBudget() {
        XCTAssertEqual(CloudChatRouting.decide(consent: .granted, online: true,
                                               keyConfigured: true, costAllows: true),
                       .cloud)
    }

    func testExactlyOneOfTheThirtyTwoCellsIsCloud() {
        var checked = 0
        var cloudCells: [String] = []

        for consent in CloudChatConsentGate.Decision.allCases {
            for online in [true, false] {
                for key in [true, false] {
                    for cost in [true, false] {
                        checked += 1
                        let cell = "\(consent)/online=\(online)/key=\(key)/cost=\(cost)"
                        let route = CloudChatRouting.decide(consent: consent, online: online,
                                                            keyConfigured: key, costAllows: cost)
                        XCTAssertEqual(route, expectedRoute(consent: consent, online: online,
                                                            key: key, cost: cost),
                                       "cell \(cell)")
                        if route == .cloud { cloudCells.append(cell) }
                    }
                }
            }
        }

        XCTAssertEqual(checked, 32, "four readable consent states x online x key x cost")
        XCTAssertEqual(cloudCells, ["granted/online=true/key=true/cost=true"],
                       "exactly one cell egresses, and it is the cell where every input says yes")
    }

    // MARK: - Scenario: every other combination names its first blocking input

    func testTheReasonNamesTheFirstBlockingInputEvenWhenEverythingElseBlocksToo() {
        XCTAssertEqual(CloudChatRouting.decide(consent: .notRecorded, online: false,
                                               keyConfigured: false, costAllows: false),
                       .local(reason: .consentNotRecorded),
                       "consent is read first: it outranks offline, key and cost")
        XCTAssertEqual(CloudChatRouting.decide(consent: .denied, online: false,
                                               keyConfigured: false, costAllows: false),
                       .local(reason: .consentDenied))
        XCTAssertEqual(CloudChatRouting.decide(consent: .unreadable, online: false,
                                               keyConfigured: false, costAllows: false),
                       .local(reason: .consentUnreadable))
        XCTAssertEqual(CloudChatRouting.decide(consent: .granted, online: false,
                                               keyConfigured: false, costAllows: false),
                       .local(reason: .offline),
                       "a granted consent with no path is offline — not 'key missing'")
        XCTAssertEqual(CloudChatRouting.decide(consent: .granted, online: true,
                                               keyConfigured: false, costAllows: false),
                       .local(reason: .keyMissing),
                       "key outranks cost")
        XCTAssertEqual(CloudChatRouting.decide(consent: .granted, online: true,
                                               keyConfigured: true, costAllows: false),
                       .local(reason: .costBlocked))
    }

    // MARK: - Scenario: the reason names the consent state truthfully

    func testTheThreeNonGrantedConsentStatesKeepTheirOwnNames() {
        let notRecorded = CloudChatRouting.decide(consent: .notRecorded, online: true,
                                                  keyConfigured: true, costAllows: true)
        let denied = CloudChatRouting.decide(consent: .denied, online: true,
                                             keyConfigured: true, costAllows: true)
        let unreadable = CloudChatRouting.decide(consent: .unreadable, online: true,
                                                 keyConfigured: true, costAllows: true)

        XCTAssertEqual(notRecorded, .local(reason: .consentNotRecorded))
        XCTAssertEqual(denied, .local(reason: .consentDenied))
        XCTAssertEqual(unreadable, .local(reason: .consentUnreadable))
        // The three names are pairwise distinct — a human reads them later to
        // know why the cloud was not used, so collapsing any two would lose
        // the answer (the gate's own `.unreadable`-never-collapses rule).
        XCTAssertNotEqual(notRecorded, denied)
        XCTAssertNotEqual(notRecorded, unreadable)
        XCTAssertNotEqual(denied, unreadable)
        for route in [notRecorded, denied, unreadable] {
            XCTAssertNotEqual(route, .cloud, "a consent reason is never egress")
        }
    }

    // MARK: - Scenario: the decision reads state per turn (no cached route)

    func testARevocationBetweenTwoTurnsChangesTheSecondTurnAndNothingIsCached() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let inputs = CloudChatRouting.Inputs(consent: { gate.currentDecision() },
                                             online: { true },
                                             keyConfigured: { true },
                                             costAllows: { true })

        XCTAssertEqual(CloudChatRouting.decide(inputs), .cloud,
                       "consented, online, keyed and under budget: the single yes")

        XCTAssertTrue(gate.revoke().isSuccess)

        // The SAME Inputs value, a new call: the seam holds nothing and the
        // gate re-derives from storage, so the next turn sees the withdrawal
        // (design §8.6 — revocation takes effect at the next turn's routing
        // decision, never earlier, never later).
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the gate's readable state after a withdrawal is its one 'no'")
        XCTAssertEqual(CloudChatRouting.decide(inputs), .local(reason: .consentDenied),
                       "the reason is the state the gate actually reports: a withdrawal and a "
                       + "decline share `.denied`, and this decision does not invent a distinction "
                       + "the single consent source does not make")
        XCTAssertNotEqual(CloudChatRouting.decide(inputs), .cloud)
    }

    func testAWithdrawalLeavesNothingARelaunchCouldRouteCloudFrom() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        XCTAssertTrue(gate.revoke().isSuccess)

        // A relaunch over the same store: the verified delete removed the
        // grant, so the next decision reads notRecorded.
        let relaunched = makeGate()
        XCTAssertEqual(CloudChatRouting.decide(CloudChatRouting.Inputs(
            consent: { relaunched.currentDecision() }, online: { true },
            keyConfigured: { true }, costAllows: { true })),
            .local(reason: .consentNotRecorded))

        // The store whose delete lies: the gate tombstones the surviving
        // grant, and a relaunch reads the one 'no' — never a grant.
        storage.keepsBytesAfterDelete = true
        let tombstoning = makeGate()
        XCTAssertTrue(tombstoning.record(granted: true).isSuccess)
        XCTAssertTrue(tombstoning.revoke().isSuccess)

        let afterTombstone = makeGate()
        XCTAssertEqual(afterTombstone.currentDecision(), .denied)
        XCTAssertEqual(CloudChatRouting.decide(CloudChatRouting.Inputs(
            consent: { afterTombstone.currentDecision() }, online: { true },
            keyConfigured: { true }, costAllows: { true })),
            .local(reason: .consentDenied))
    }

    func testACorruptRecordBetweenTwoTurnsChangesTheSecondTurnToUnreadable() {
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let inputs = CloudChatRouting.Inputs(consent: { gate.currentDecision() },
                                             online: { true },
                                             keyConfigured: { true },
                                             costAllows: { true })
        XCTAssertEqual(CloudChatRouting.decide(inputs), .cloud)

        storage.setRaw(Data("torn".utf8), forKey: consentKey)

        XCTAssertEqual(CloudChatRouting.decide(inputs), .local(reason: .consentUnreadable),
                       "a record that stops being readable refuses on the very next turn")
        XCTAssertNotEqual(CloudChatRouting.decide(inputs), .cloud)
    }

    // MARK: - Failure path: a non-granted state can never yield cloud

    func testANonGrantedConsentCanNeverYieldCloudForAnyOtherInputs() {
        for consent in CloudChatConsentGate.Decision.allCases where consent != .granted {
            for online in [true, false] {
                for key in [true, false] {
                    for cost in [true, false] {
                        XCTAssertNotEqual(
                            CloudChatRouting.decide(consent: consent, online: online,
                                                    keyConfigured: key, costAllows: cost),
                            .cloud,
                            "\(consent)/online=\(online)/key=\(key)/cost=\(cost) egressed")
                    }
                }
            }
        }

        // The same statement through the seam, with every reader answering
        // except consent's.
        XCTAssertNotEqual(CloudChatRouting.decide(inputs(consent: { .notRecorded })), .cloud)
        XCTAssertNotEqual(CloudChatRouting.decide(inputs(consent: { .denied })), .cloud)
        XCTAssertNotEqual(CloudChatRouting.decide(inputs(consent: { .unreadable })), .cloud)
    }

    // MARK: - Failure path: absent, nil and throwing inputs fail closed

    /// The construction site that wires nothing — `Inputs()` itself. Every
    /// pre-feature site and every test that never opts in gets this reading,
    /// and it is local, honestly: no consent reader exists, so nothing has
    /// been recorded.
    func testTheDefaultInputsSelectLocalAndNeverCloud() {
        let route = CloudChatRouting.decide(CloudChatRouting.Inputs())
        XCTAssertEqual(route, .local(reason: .consentNotRecorded))
        XCTAssertNotEqual(route, .cloud)
    }

    func testEachInputInEachFailureModeSelectsItsOwnReasonAndNeverCloud() {
        for mode in ReaderMode.allCases {
            let expectedConsent: CloudChatRouting.ChatRoute =
                .local(reason: mode == .throwing ? .consentUnreadable : .consentNotRecorded)

            XCTAssertEqual(CloudChatRouting.decide(inputs(consent: mode.consentReader)),
                           expectedConsent,
                           "consent reader \(mode): no reader and no decision read as "
                           + "notRecorded; a read that threw keeps the unreadable name")
            XCTAssertEqual(CloudChatRouting.decide(inputs(online: mode.boolReader)),
                           .local(reason: .offline),
                           "online reader \(mode): not known to be online is offline")
            XCTAssertEqual(CloudChatRouting.decide(inputs(keyConfigured: mode.boolReader)),
                           .local(reason: .keyMissing),
                           "key reader \(mode)")
            XCTAssertEqual(CloudChatRouting.decide(inputs(costAllows: mode.boolReader)),
                           .local(reason: .costBlocked),
                           "cost reader \(mode)")

            XCTAssertNotEqual(CloudChatRouting.decide(inputs(consent: mode.consentReader)), .cloud)
            XCTAssertNotEqual(CloudChatRouting.decide(inputs(online: mode.boolReader)), .cloud)
            XCTAssertNotEqual(CloudChatRouting.decide(inputs(keyConfigured: mode.boolReader)), .cloud)
            XCTAssertNotEqual(CloudChatRouting.decide(inputs(costAllows: mode.boolReader)), .cloud)
        }
    }

    func testNoCombinationOfUnknownInputsEverProducesCloud() {
        var checked = 0
        for consent in ReaderMode.allCases {
            for online in ReaderMode.allCases {
                for key in ReaderMode.allCases {
                    for cost in ReaderMode.allCases {
                        checked += 1
                        let route = CloudChatRouting.decide(CloudChatRouting.Inputs(
                            consent: consent.consentReader,
                            online: online.boolReader,
                            keyConfigured: key.boolReader,
                            costAllows: cost.boolReader))
                        XCTAssertNotEqual(route, .cloud,
                                          "unknown inputs (consent=\(consent), online=\(online), "
                                          + "key=\(key), cost=\(cost)) must never turn into egress")
                    }
                }
            }
        }
        XCTAssertEqual(checked, 81, "3^4 ways for the four readers to fail to answer")
    }

    func testTheRouterReadinessClosuresSlotIntoTheSeamUnchanged() {
        // The router already holds these two (`IntentRouter` :107-108) as
        // `(() -> Bool)?`; the feature's wiring joins them rather than
        // replacing them, so their shape must fit the seam.
        let geminiKeyConfigured: (() -> Bool)? = { true }
        let geminiCostAllows: (() -> Bool)? = { true }
        let gate = makeGate()
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let wired = CloudChatRouting.Inputs(consent: { gate.currentDecision() },
                                            online: { true },
                                            keyConfigured: geminiKeyConfigured,
                                            costAllows: geminiCostAllows)
        XCTAssertEqual(CloudChatRouting.decide(wired), .cloud)

        // A site that wires the readiness inputs but never opts in to chat
        // egress (no consent reader) selects local — honestly, and with no
        // behavioural surprise at a call site that never opted in.
        let readinessOnly = CloudChatRouting.Inputs(keyConfigured: geminiKeyConfigured,
                                                    costAllows: geminiCostAllows)
        XCTAssertEqual(CloudChatRouting.decide(readinessOnly), .local(reason: .consentNotRecorded))
        XCTAssertNotEqual(CloudChatRouting.decide(readinessOnly), .cloud)
    }

    func testTheDecisionKeepsNoStateAndRepeatsIdentically() {
        let allow = inputs()
        XCTAssertEqual(CloudChatRouting.decide(allow), .cloud)
        XCTAssertEqual(CloudChatRouting.decide(CloudChatRouting.Inputs()),
                       .local(reason: .consentNotRecorded))
        XCTAssertEqual(CloudChatRouting.decide(allow), .cloud,
                       "a refusal in between leaves no residue — nothing is memoised")

        let blocked = inputs(costAllows: { false })
        for _ in 0..<50 {
            XCTAssertEqual(CloudChatRouting.decide(blocked), .local(reason: .costBlocked),
                           "same inputs, same route, every time")
        }
    }

    // MARK: - Classification only: no content, no identity, no logging, no I/O

    func testTheReasonVocabularyIsTheClosedDesignSet() {
        XCTAssertEqual(Set(CloudChatRouting.ChatRoute.LocalReason.allCases.map(\.rawValue)),
                       ["consentNotRecorded", "consentDenied", "consentRevoked",
                        "consentUnreadable", "offline", "keyMissing", "costBlocked"],
                       "design §8.1's closed reason vocabulary, pinned as a set")
    }

    func testTheRoutingSourceCarriesNoStringLiteralLoggingOrEgressPrimitive() {
        let code = routingSource
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "enum ChatRoute", in: code),
                        "the scan must have located the routing source, not an empty string")

        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\"", in: code),
                     "no string literal of any kind: a reason is a token, and this file holds no "
                     + "text a reason could carry")

        let forbidden = ["print(", "NSLog", "os_log", "URLSession", "Gemini", "FileManager",
                         "ObservabilityBus", "Logger", "SwiftUI", "UIKit", "Task", "async",
                         "transcript", "utterance", "replyText", "payload", "identity"]
        for token in forbidden {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: NSRegularExpression.escapedPattern(for: token),
                                                      in: code),
                         "the routing decision's source mentions '\(token)': it must hold no "
                         + "content, no identity, no logging, no transport and no UI")
        }
    }

    // MARK: - Helpers

    /// The expected route, written from the requirement's words rather than
    /// from the implementation: cloud iff all four inputs say yes; otherwise
    /// the first blocking input, in the order consent -> online -> key ->
    /// cost.
    private func expectedRoute(consent: CloudChatConsentGate.Decision,
                               online: Bool, key: Bool, cost: Bool)
        -> CloudChatRouting.ChatRoute {
        switch consent {
        case .notRecorded: return .local(reason: .consentNotRecorded)
        case .denied: return .local(reason: .consentDenied)
        case .unreadable: return .local(reason: .consentUnreadable)
        case .granted:
            if !online { return .local(reason: .offline) }
            if !key { return .local(reason: .keyMissing) }
            if !cost { return .local(reason: .costBlocked) }
            return .cloud
        }
    }

    /// The seam with every reader answering yes, minus whatever the caller
    /// overrides — the "everything else is fine" control for each single
    /// failure under test.
    private func inputs(consent: (() throws -> CloudChatConsentGate.Decision?)? = { .granted },
                        online: (() throws -> Bool?)? = { true },
                        keyConfigured: (() throws -> Bool?)? = { true },
                        costAllows: (() throws -> Bool?)? = { true }) -> CloudChatRouting.Inputs {
        CloudChatRouting.Inputs(consent: consent,
                                online: online,
                                keyConfigured: keyConfigured,
                                costAllows: costAllows)
    }

    /// The three ways an injected reader can fail to answer.
    private enum ReaderMode: CaseIterable {
        case absent
        case nilReturning
        case throwing

        var consentReader: (() throws -> CloudChatConsentGate.Decision?)? {
            switch self {
            case .absent: return nil
            case .nilReturning: return { nil }
            case .throwing: return { throw SeamFailure.readThrew }
            }
        }

        var boolReader: (() throws -> Bool?)? {
            switch self {
            case .absent: return nil
            case .nilReturning: return { nil }
            case .throwing: return { throw SeamFailure.readThrew }
            }
        }
    }

    private enum SeamFailure: Error {
        case readThrew
    }

    private var routingPath: String {
        "ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift"
    }

    private var routingSource: String {
        FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(routingPath))
    }
}
