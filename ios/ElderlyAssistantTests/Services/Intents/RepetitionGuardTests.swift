import XCTest
@testable import ElderlyAssistant

final class RepetitionGuardTests: XCTestCase {

    func testRepeatWithinWindowDetected() {
        let guard_ = RepetitionGuard(storage: StubEncryptedStorage(), windowSeconds: 600)
        let now = Date()
        guard_.record(actionKey: "call", targetId: "maiya-id", at: now)
        XCTAssertTrue(guard_.isRepeat(actionKey: "call", targetId: "maiya-id",
                                      at: now.addingTimeInterval(300)))
    }

    func testDifferentTargetNotARepeat() {
        let guard_ = RepetitionGuard(storage: StubEncryptedStorage(), windowSeconds: 600)
        let now = Date()
        guard_.record(actionKey: "call", targetId: "maiya-id", at: now)
        XCTAssertFalse(guard_.isRepeat(actionKey: "call", targetId: "sunita-id",
                                       at: now.addingTimeInterval(60)))
    }

    func testDifferentActionNotARepeat() {
        let guard_ = RepetitionGuard(storage: StubEncryptedStorage(), windowSeconds: 600)
        let now = Date()
        guard_.record(actionKey: "call", targetId: "maiya-id", at: now)
        XCTAssertFalse(guard_.isRepeat(actionKey: "send_message", targetId: "maiya-id",
                                       at: now.addingTimeInterval(60)))
    }

    func testExpiredWindowNotARepeat() {
        let guard_ = RepetitionGuard(storage: StubEncryptedStorage(), windowSeconds: 600)
        let now = Date()
        guard_.record(actionKey: "call", targetId: "maiya-id", at: now)
        XCTAssertFalse(guard_.isRepeat(actionKey: "call", targetId: "maiya-id",
                                       at: now.addingTimeInterval(601)))
    }

    func testFutureClockSkewTolerated() {
        // A record timestamped "after" the query (clock skew) must not
        // count as a repeat — timeIntervalSince would be negative.
        let guard_ = RepetitionGuard(storage: StubEncryptedStorage(), windowSeconds: 600)
        let now = Date()
        guard_.record(actionKey: "call", targetId: "maiya-id", at: now.addingTimeInterval(120))
        XCTAssertFalse(guard_.isRepeat(actionKey: "call", targetId: "maiya-id", at: now))
    }
}
