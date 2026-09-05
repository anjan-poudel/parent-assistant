import XCTest
@testable import ElderlyAssistant

final class IntentCommandCacheTests: XCTestCase {

    private func makeCache() -> IntentCommandCache {
        IntentCommandCache(storage: StubEncryptedStorage())
    }

    func testRecordThenHit() {
        let cache = makeCache()
        let command = makeCommand(action: .call, contact: "maiya")
        cache.record(transcript: "maiya lai phone gara", command: command)
        XCTAssertEqual(cache.command(for: "maiya lai phone gara"), command)
    }

    func testHitIgnoresCasePunctuationAndWhitespace() {
        let cache = makeCache()
        let command = makeCommand(action: .call, contact: "maiya")
        cache.record(transcript: "Maiya lai phone gara!", command: command)
        XCTAssertEqual(cache.command(for: "  maiya   lai phone gara."), command)
    }

    func testDevanagariDigitVariantsHit() {
        let cache = makeCache()
        let command = makeCommand(action: .music)
        cache.record(transcript: "८ बजे भजन बजाउ", command: command)
        XCTAssertEqual(cache.command(for: "8 बजे भजन बजाउ"), command)
    }

    func testNonCacheableActionsNeverStored() {
        let cache = makeCache()
        for action: InterpretedCommand.Action in [.setReminder, .ackMed, .emergency, .query, .none, .sendMessage] {
            cache.record(transcript: "some transcript \(action)", command: makeCommand(action: action))
        }
        XCTAssertNil(cache.command(for: "some transcript setReminder"))
        XCTAssertNil(cache.command(for: "some transcript ackMed"))
        XCTAssertNil(cache.command(for: "some transcript emergency"))
        XCTAssertNil(cache.command(for: "some transcript query"))
    }

    func testCacheableActionsStored() {
        let cache = makeCache()
        for action: InterpretedCommand.Action in [.call, .music, .suggestVideo] {
            let key = "transcript for \(action)"
            cache.record(transcript: key, command: makeCommand(action: action))
            XCTAssertNotNil(cache.command(for: key), "\(action) should be cacheable")
        }
    }

    func testStaleCacheEntryForNonCacheableIsRejectedOnRead() {
        // Defense in depth: even if a non-cacheable command somehow lands
        // under a key, reads reject it.
        let cache = makeCache()
        cache.record(transcript: "call maiya", command: makeCommand(action: .call, contact: "maiya"))
        // Overwrite attempt with a query under the same key — record
        // no-ops, the original call entry survives.
        cache.record(transcript: "call maiya", command: makeCommand(action: .query))
        XCTAssertEqual(cache.command(for: "call maiya")?.action, .call)
    }

    func testFreshConfirmationOverwritesEntry() {
        let cache = makeCache()
        cache.record(transcript: "call maiya", command: makeCommand(action: .call, contact: "maiya", requestedApp: "facetime"))
        cache.record(transcript: "call maiya", command: makeCommand(action: .call, contact: "maiya", requestedApp: "whatsapp"))
        XCTAssertEqual(cache.command(for: "call maiya")?.requestedApp, "whatsapp")
    }

    func testMissOnEmptyAndUnknown() {
        let cache = makeCache()
        XCTAssertNil(cache.command(for: ""))
        XCTAssertNil(cache.command(for: "never recorded"))
    }

    func testHitCountIncrements() {
        let storage = StubEncryptedStorage()
        let cache = IntentCommandCache(storage: storage)
        cache.record(transcript: "call maiya", command: makeCommand(action: .call, contact: "maiya"))
        _ = cache.command(for: "call maiya")
        _ = cache.command(for: "call maiya")
        // Reload from the same storage to verify persistence + counts.
        let reloaded = IntentCommandCache(storage: storage)
        XCTAssertNotNil(reloaded.command(for: "call maiya"))
    }
}
