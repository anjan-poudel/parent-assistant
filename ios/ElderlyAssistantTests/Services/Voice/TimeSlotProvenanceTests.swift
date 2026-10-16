import XCTest
@testable import ElderlyAssistant

/// [SLOT-PROVENANCE] (2026-09-17) The guard that keeps a hallucinated
/// time out of a reminder/calendar event: a model time slot is only
/// defensible when the transcript contained SOME time material.
final class TimeSlotProvenanceTests: XCTestCase {

    func testFabricatedTimeOverDateQuestionIsRejected() {
        // The 2026-09-17 device failure: "दशैँ कहिले हो" was classified
        // set_reminder and the model invented "बिहान १०:३०".
        XCTAssertFalse(TimeSlotProvenance.timeSlotIsDefensible(
            raw: "दशैँ कहिले हो", time: "बिहान १०:३०"))
    }

    func testEmptyTimeIsAlwaysDefensible() {
        XCTAssertTrue(TimeSlotProvenance.timeSlotIsDefensible(
            raw: "दशैँ कहिले हो", time: nil))
        XCTAssertTrue(TimeSlotProvenance.timeSlotIsDefensible(
            raw: "anything", time: ""))
    }

    func testSpokenTimeInTranscriptIsDefensible() {
        XCTAssertTrue(TimeSlotProvenance.timeSlotIsDefensible(
            raw: "बिहान आठ बजे औषधि सम्झाऊ", time: "बिहान ८ बजे"))
    }

    func testRelativeTimeWordsAreTimeMaterial() {
        // "आधा घण्टा" carries no digits — the guard must not reject
        // real relative-time utterances (permissive by design).
        XCTAssertTrue(TimeSlotProvenance.timeSlotIsDefensible(
            raw: "आधा घण्टामा सम्झाऊ", time: "३० मिनेटपछि"))
    }

    func testQuestionWordAloneIsNotTimeMaterial() {
        // "कहिले" asks when — it does not say a time. The fabricated
        // slot must stay rejected even though the transcript mentions
        // time-adjacent vocabulary.
        XCTAssertFalse(TimeSlotProvenance.containsTimeMaterial("कहिले हो"))
    }

    func testDigitsAnywhereAreTimeMaterial() {
        XCTAssertTrue(TimeSlotProvenance.containsTimeMaterial("१० बजे"))
        XCTAssertTrue(TimeSlotProvenance.containsTimeMaterial("3pm call"))
    }

    func testEnglishAndNepaliTimeWords() {
        XCTAssertTrue(TimeSlotProvenance.containsTimeMaterial("tomorrow morning"))
        XCTAssertTrue(TimeSlotProvenance.containsTimeMaterial("भोलि बिहान"))
        XCTAssertFalse(TimeSlotProvenance.containsTimeMaterial("when is dashain"))
    }
}
