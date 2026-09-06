import XCTest
@testable import ElderlyAssistant

/// Outcome-card composition (conversation-panel fix, 2026-09-06).
///
/// The user reported that the Home outcome panel showed the assistant's
/// response WITHOUT the user's command above it for every non-generic
/// path (medication ack, reminder set, call placed, message sent).
/// Every `setOutcome(icon:text:undo:)` call site funnels into ONE private
/// funnel in `AppCoordinator` that attaches the just-heard transcript
/// (`lastTranscript`, recorded by `recordTranscript` at the top of every
/// `route()`), and the card text is composed by the shared pure helper
/// under test here — `OutcomeSummary.rows` — so a response can never be
/// shown without its transcript above it. `AppCoordinator` itself is the
/// app's composition root and is not unit-instantiated (repo pattern), so
/// these tests lock the pure composition every outcome-producing path
/// goes through, exercised with the real localized response strings the
/// paths store.
final class OutcomePanelCompositionTests: XCTestCase {

    private typealias Row = AppCoordinator.OutcomeSummary.Row

    /// English locale for the real outcome strings (tests must not depend
    /// on the device locale).
    private let en = Locale(identifier: "en")

    // MARK: - Sanitization (nil/blank transcripts must not draw an empty
    // "you said" row)

    func testNilTranscriptSanitizesToNil() {
        XCTAssertNil(AppCoordinator.OutcomeSummary.sanitizedTranscript(nil))
    }

    func testBlankTranscriptSanitizesToNil() {
        XCTAssertNil(AppCoordinator.OutcomeSummary.sanitizedTranscript(""))
        XCTAssertNil(AppCoordinator.OutcomeSummary.sanitizedTranscript("   "))
        XCTAssertNil(AppCoordinator.OutcomeSummary.sanitizedTranscript("\n\t "))
    }

    func testTranscriptIsTrimmedForDisplay() {
        XCTAssertEqual(AppCoordinator.OutcomeSummary.sanitizedTranscript("  ममीलाई फोन गर  "),
                       "ममीलाई फोन गर")
    }

    // MARK: - Universal shape: transcript row above response row

    func testTranscriptRowAlwaysComposesAboveResponseRow() {
        let rows = AppCoordinator.OutcomeSummary.rows(
            transcript: "ममीलाई फोन गर",
            response: "आमा लाई फोन गर्दै")
        XCTAssertEqual(rows, [.user("ममीलाई फोन गर"), .assistant("आमा लाई फोन गर्दै")])
    }

    func testResponseRowIsAlwaysLastEvenWithoutTranscript() {
        let rows = AppCoordinator.OutcomeSummary.rows(transcript: nil,
                                                      response: "Calling Mom")
        XCTAssertEqual(rows, [.assistant("Calling Mom")])
    }

    func testBlankTranscriptComposesResponseOnly() {
        let rows = AppCoordinator.OutcomeSummary.rows(transcript: "   ",
                                                      response: "Calling Mom")
        XCTAssertEqual(rows, [.assistant("Calling Mom")])
    }

    // MARK: - Every outcome-producing path yields transcript-above-response
    //
    // Each test mirrors a real path's stored response string (built with
    // the same L10n calls the coordinator uses) and asserts the shape the
    // card renders: [user transcript, assistant response] when the
    // transcript was recorded, [assistant response] alone when nothing
    // was heard. The paths themselves are unchanged — the composition is
    // applied once, in `setOutcome`.

    func testMedicationAcknowledgementPath() {
        let response = L10n.fmt("home.outcome.medAck", locale: en, "Aspirin")
        let withTranscript = AppCoordinator.OutcomeSummary.rows(
            transcript: "मैले औषधि खाएँ",
            response: response)
        XCTAssertEqual(withTranscript.first, .user("मैले औषधि खाएँ"))
        XCTAssertEqual(withTranscript.last, .assistant(response))

        let silent = AppCoordinator.OutcomeSummary.rows(transcript: nil, response: response)
        XCTAssertEqual(silent, [.assistant(response)])
    }

    func testVoiceReminderPath() {
        let response = L10n.fmt("home.outcome.reminderSet", locale: en, "Vitamin")
        let rows = AppCoordinator.OutcomeSummary.rows(
            transcript: "भिटामिन खान सम्झाउनुहोस्",
            response: response)
        XCTAssertEqual(rows.first, .user("भिटामिन खान सम्झाउनुहोस्"))
        XCTAssertEqual(rows.last, .assistant(response))
        // The undo affordance rides on OutcomeSummary.undo, untouched by
        // the composition — the reminder path still creates its summary
        // carrying the real undo closure.
        let summary = AppCoordinator.OutcomeSummary(
            icon: "clock.badge.checkmark.fill",
            text: response,
            transcript: "भिटामिन खान सम्झाउनुहोस्",
            timestamp: Date(),
            undo: {})
        XCTAssertNotNil(summary.undo)
        XCTAssertEqual(summary.transcript, "भिटामिन खान सम्झाउनुहोस्")
        XCTAssertEqual(AppCoordinator.OutcomeSummary.rows(transcript: summary.transcript,
                                                          response: summary.text),
                       [.user("भिटामिन खान सम्झाउनुहोस्"), .assistant(response)])
    }

    func testCallPlacedPath() {
        let response = L10n.fmt("home.outcome.callPlaced", locale: en, "Mom")
        let rows = AppCoordinator.OutcomeSummary.rows(transcript: "call mom",
                                                      response: response)
        XCTAssertEqual(rows.first, .user("call mom"))
        XCTAssertEqual(rows.last, .assistant(response))
    }

    func testMessageSentPath() {
        let response = L10n.fmt("home.outcome.messageReady", locale: en, "Dad")
        let rows = AppCoordinator.OutcomeSummary.rows(
            transcript: "बुबालाई सन्देश पठाउनुहोस्",
            response: response)
        XCTAssertEqual(rows.first, .user("बुबालाई सन्देश पठाउनुहोस्"))
        XCTAssertEqual(rows.last, .assistant(response))
    }

    func testGenericReplyPath() {
        // noteGenericReply's transcript handling moved into the shared
        // composition — the card no longer relies on the old inline
        // "\u{201C}…\u{201D}\n…" embedding to show what the user said.
        let response = "माफ गर्नुहोस्, मैले बुझिनँ।"
        let rows = AppCoordinator.OutcomeSummary.rows(
            transcript: "आजको मौसम कस्तो छ?",
            response: response)
        XCTAssertEqual(rows, [.user("आजको मौसम कस्तो छ?"), .assistant(response)])
    }
}

/// Newest-first row ordering for the "Last conversation" sheet
/// (conversation-panel fix, 2026-09-06). A bare `.reversed()` of the
/// chronological history renders every assistant reply ABOVE the user
/// transcript it answers; `HistoryRowOrderer.newestFirstPaired` must emit
/// each pair user-then-assistant while keeping the newest group on top —
/// across the window/page pagination seam too, and without reordering
/// singletons (unanswered user turns, orphan assistant rows).
final class HistoryRowOrderingTests: XCTestCase {

    private typealias Exchange = ChatHistoryStore.Exchange
    private typealias Role = ChatHistoryStore.ExchangeRole

    /// Fixture: "e0" user, "e1" assistant, "e2" user, … — strictly
    /// increasing timestamps, mirroring `ChatHistoryStoreTests`.
    private func exchange(_ i: Int) -> Exchange {
        Exchange(role: i % 2 == 0 ? .user : .assistant,
                 text: "e\(i)",
                 timestamp: Date(timeIntervalSince1970: TimeInterval(i)))
    }

    private func row(_ text: String, _ role: Role) -> Exchange {
        Exchange(role: role, text: text, timestamp: Date())
    }

    /// Structural check that the display rows satisfy the sheet contract:
    /// every user/assistant pair of the chronological history renders
    /// with the USER DIRECTLY ABOVE ITS OWN reply (never the reply above
    /// its transcript), and pairs are emitted newest-first — older pairs
    /// only ever sit below newer ones. Pairs are located on the
    /// chronological list, so orphans (unanswered users, trimmed/never-
    /// spoken assistant rows) are exempt, and a flat role scan would
    /// false-positive on legitimate pair boundaries.
    ///
    /// `display` must be derived from THIS `chronological` array (same
    /// exchange instances), not a separately-built twin — the ids are the
    /// only identity.
    private func assertPairedRows(_ chronological: [Exchange], _ display: [Exchange],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(display.count, chronological.count, file: file, line: line)
        XCTAssertEqual(Set(display.map(\.id)), Set(chronological.map(\.id)),
                       "display rows are not the same exchanges", file: file, line: line)
        let displayIndex = Dictionary(uniqueKeysWithValues:
            display.enumerated().map { ($0.element.id, $0.offset) })
        // Pairs are walked oldest → newest; the display is newest-first,
        // so each successive pair must sit strictly BELOW the previous
        // one (its display index grows). A reply index is always its
        // user's + 1 (asserted above), so tracking user indices suffices.
        var previousUserIndex = Int.max
        var k = 0
        while k < chronological.count {
            if k + 1 < chronological.count,
               chronological[k].role == .user,
               chronological[k + 1].role == .assistant {
                guard let userIndex = displayIndex[chronological[k].id],
                      let replyIndex = displayIndex[chronological[k + 1].id] else {
                    XCTFail("pair \(chronological[k].text)/\(chronological[k + 1].text) "
                            + "missing from display",
                            file: file, line: line)
                    k += 2
                    continue
                }
                XCTAssertEqual(userIndex + 1, replyIndex,
                               "\(chronological[k].text)/\(chronological[k + 1].text) "
                               + "renders without the user directly above its own reply",
                               file: file, line: line)
                XCTAssertLessThan(userIndex, previousUserIndex,
                                  "older pair rendered above a newer one",
                                  file: file, line: line)
                previousUserIndex = userIndex
                k += 2
            } else {
                k += 1
            }
        }
    }

    func testAlternatingPairsRenderUserAboveOwnReply() {
        // [u0 a0 u1 a1 u2 a2] → newest pair first, each pair u→a.
        let chronological = (0..<6).map(exchange)
        let rows = HistoryRowOrderer.newestFirstPaired(from: chronological)
        XCTAssertEqual(rows.map(\.text), ["e4", "e5", "e2", "e3", "e0", "e1"])
        assertPairedRows(chronological, rows)
    }

    func testSinglePair() {
        let chronological = (0..<2).map(exchange)
        let rows = HistoryRowOrderer.newestFirstPaired(from: chronological)
        XCTAssertEqual(rows.map(\.text), ["e0", "e1"])
        assertPairedRows(chronological, rows)
    }

    func testNewestUnansweredUserStaysOnTop() {
        // [u0 a0 u1] — the newest user turn has no reply yet.
        let chronological = (0..<3).map(exchange)
        let rows = HistoryRowOrderer.newestFirstPaired(from: chronological)
        XCTAssertEqual(rows.map(\.text), ["e2", "e0", "e1"])
        assertPairedRows(chronological, rows)
    }

    func testOrphanAssistantWhoseUserWasTrimmedSinksToItsChronologicalSpot() {
        // Store trimmed the user half of the oldest pair: an assistant
        // row whose transcript is gone must render as a singleton at the
        // bottom, not steal a neighbor's transcript.
        let chronological = [row("a-old", .assistant), row("u1", .user), row("a1", .assistant)]
        let rows = HistoryRowOrderer.newestFirstPaired(from: chronological)
        XCTAssertEqual(rows.map(\.text), ["u1", "a1", "a-old"])
        assertPairedRows(chronological, rows)
    }

    func testMidListOrphanAssistantStaysInPlace() {
        // Proactive assistant speech with no user turn: [u0 a0 aX u1 a1].
        let chronological = [row("u0", .user), row("a0", .assistant),
                             row("aX", .assistant),
                             row("u1", .user), row("a1", .assistant)]
        let rows = HistoryRowOrderer.newestFirstPaired(from: chronological)
        XCTAssertEqual(rows.map(\.text), ["u1", "a1", "aX", "u0", "a0"])
        assertPairedRows(chronological, rows)
    }

    func testPairSplitAcrossWindowPageSeamIsRejoined() {
        // 22 exchanges e0…e21 (u,a,u,a,…; e21 = the newest reply). The
        // sheet slices this into a 5-row live window = suffix [e17…e21]
        // and a 17-row page = prefix [e0…e16] — the window's oldest row
        // e17 is an ASSISTANT whose user e16 lives on the page, so the
        // (e16, e17) pair straddles the seam. The helper must re-join it:
        // the sheet concatenates OLDER rows first, then the window
        // (olderChronological + window = pure chronological order), and
        // pairs across the seam are then found as if no seam existed.
        let chronological = (0..<22).map(exchange)
        let window = Array(chronological.suffix(5))             // e17…e21
        let pageChronological = Array(chronological.prefix(17)) // e0…e16
        XCTAssertEqual(window.first?.role, .assistant)  // the seam case
        let sheetInput = pageChronological + window     // exactly what visibleRows feeds
        let rows = HistoryRowOrderer.newestFirstPaired(from: sheetInput)
        XCTAssertEqual(rows.map(\.text),
                       ["e20", "e21", "e18", "e19", "e16", "e17",   // seam pair joined here
                        "e14", "e15", "e12", "e13", "e10", "e11",
                        "e8", "e9", "e6", "e7", "e4", "e5",
                        "e2", "e3", "e0", "e1"])
        assertPairedRows(sheetInput, rows)
    }

    func testNewAssistantReplyInsertsAfterItsUserWithoutDisturbingLowerRows() {
        // Sheet open while the reply to the newest turn lands: the rows
        // below the pair must be untouched by the insertion.
        let beforeInput = [row("u0", .user), row("a0", .assistant), row("u1", .user)]
        let before = HistoryRowOrderer.newestFirstPaired(from: beforeInput)
        XCTAssertEqual(before.map(\.text), ["u1", "u0", "a0"])
        assertPairedRows(beforeInput, before)

        let afterInput = [row("u0", .user), row("a0", .assistant),
                          row("u1", .user), row("a1", .assistant)]
        let after = HistoryRowOrderer.newestFirstPaired(from: afterInput)
        XCTAssertEqual(after.map(\.text), ["u1", "a1", "u0", "a0"])
        XCTAssertEqual(Array(after.suffix(2)).map(\.text), ["u0", "a0"])
        assertPairedRows(afterInput, after)
    }

    func testEmptyHistoryYieldsEmptyRows() {
        XCTAssertTrue(HistoryRowOrderer.newestFirstPaired(from: []).isEmpty)
    }
}
