import XCTest
@testable import ElderlyAssistant

final class DoubleDoseDetectorTests: XCTestCase {

    func testNoDuplicateWhenLogIsEmpty() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [],
            now: now
        )

        XCTAssertFalse(result.isDuplicate)
        XCTAssertNil(result.previousDoseAt)
    }

    func testNoDuplicateWhenLogHasOnlyOtherMedications() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()
        let otherEntryId = UUID()

        let otherLog = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: otherEntryId,
            scheduledAt: now.addingTimeInterval(-3600),
            acknowledgedAt: now.addingTimeInterval(-1800),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [otherLog],
            now: now
        )

        XCTAssertFalse(result.isDuplicate)
    }

    func testNoDuplicateWhenPreviousDoseIsOutsideWindow() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        // Acknowledged 5 hours ago, window is 4 hours
        let oldLog = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-6 * 3600),
            acknowledgedAt: now.addingTimeInterval(-5 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [oldLog],
            now: now
        )

        XCTAssertFalse(result.isDuplicate)
    }

    func testDuplicateDetectedWhenWithinWindow() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        // Acknowledged 2 hours ago, window is 4 hours
        let recentLog = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-3 * 3600),
            acknowledgedAt: now.addingTimeInterval(-2 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [recentLog],
            now: now
        )

        XCTAssertTrue(result.isDuplicate)
        XCTAssertNotNil(result.previousDoseAt)
        XCTAssertNotNil(result.windowEndsAt)
    }

    func testDuplicateDetectedAtExactWindowBoundary() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        // Acknowledged exactly 4 hours ago
        let boundaryLog = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-5 * 3600),
            acknowledgedAt: now.addingTimeInterval(-4 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [boundaryLog],
            now: now
        )

        // Exactly at boundary -- should be within window
        XCTAssertTrue(result.isDuplicate)
    }

    func testMissedDosesAreNotCountedAsDuplicates() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        let missedLog = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-2 * 3600),
            acknowledgedAt: nil,
            refireCount: 5,
            status: .missed,
            familyAlerted: true,
            photoVerification: .notRequired,
            confirmationPassed: false,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [missedLog],
            now: now
        )

        XCTAssertFalse(result.isDuplicate)
    }

    func testMostRecentDoseUsedWhenMultipleInLog() throws {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        let olderDose = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-10 * 3600),
            acknowledgedAt: now.addingTimeInterval(-8 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let recentDose = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-3 * 3600),
            acknowledgedAt: now.addingTimeInterval(-2 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 4,
            adherenceLog: [olderDose, recentDose],
            now: now
        )

        XCTAssertTrue(result.isDuplicate)
        let previousDoseAt = try XCTUnwrap(result.previousDoseAt)
        let recentAcknowledgedAt = try XCTUnwrap(recentDose.acknowledgedAt)
        XCTAssertEqual(
            previousDoseAt.timeIntervalSince1970,
            recentAcknowledgedAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testCustomWindowHours() {
        let detector = DoubleDoseDetector()
        let now = Date()
        let entryId = UUID()

        // 3 hours ago, window is 2 hours (twice-daily)
        let log = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: now.addingTimeInterval(-4 * 3600),
            acknowledgedAt: now.addingTimeInterval(-3 * 3600),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        let result = detector.check(
            medicationEntryId: entryId,
            windowHours: 2,   // twice-daily medication
            adherenceLog: [log],
            now: now
        )

        XCTAssertFalse(result.isDuplicate)
    }
}
