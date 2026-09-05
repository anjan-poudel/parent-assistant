import XCTest
@testable import ElderlyAssistant

/// Deterministic `CommandInterpreter` double: fires its completion
/// synchronously and records what it was asked to interpret, so tests can
/// assert exactly which concrete interpreter a `SwitchableCommandInterpreter`
/// forwarded to.
private final class SpyCommandInterpreter: CommandInterpreter {
    var isAvailable: Bool
    var nextCommand: InterpretedCommand?
    private(set) var interpretedTranscripts: [String] = []

    init(isAvailable: Bool, nextCommand: InterpretedCommand? = nil) {
        self.isAvailable = isAvailable
        self.nextCommand = nextCommand
    }

    func interpret(transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretedTranscripts.append(transcript)
        completion(nextCommand)
    }
}

/// Covers the indirection `AppCoordinator` relies on to let the user flip
/// `voiceEngineStack` (on-device vs Gemini) at runtime without
/// `CommandRouter` — which holds its interpreter as an immutable
/// `private let` — ever needing to change.
final class SwitchableCommandInterpreterTests: XCTestCase {

    func testForwardsIsAvailableToCurrentInterpreter() {
        let available = SpyCommandInterpreter(isAvailable: true)
        let switchable = SwitchableCommandInterpreter(current: available)
        XCTAssertTrue(switchable.isAvailable)

        let unavailable = SpyCommandInterpreter(isAvailable: false)
        switchable.current = unavailable
        XCTAssertFalse(switchable.isAvailable)
    }

    func testInterpretForwardsToCurrentInterpreterOnly() {
        let onDevice = SpyCommandInterpreter(isAvailable: true)
        let gemini = SpyCommandInterpreter(isAvailable: true)
        let switchable = SwitchableCommandInterpreter(current: onDevice)
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "ne")

        let exp1 = expectation(description: "first interpret completes")
        switchable.interpret(transcript: "पहिलो", context: ctx) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        XCTAssertEqual(onDevice.interpretedTranscripts, ["पहिलो"])
        XCTAssertEqual(gemini.interpretedTranscripts, [])
    }

    func testSwitchingCurrentRedirectsSubsequentInterpretCalls() {
        let onDevice = SpyCommandInterpreter(isAvailable: true)
        let gemini = SpyCommandInterpreter(isAvailable: true)
        let switchable = SwitchableCommandInterpreter(current: onDevice)
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "en")

        let exp1 = expectation(description: "on-device interpret completes")
        switchable.interpret(transcript: "call son", context: ctx) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        // Flip the stack — same object handed to CommandRouter, new target.
        switchable.current = gemini

        let exp2 = expectation(description: "gemini interpret completes")
        switchable.interpret(transcript: "set reminder", context: ctx) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertEqual(onDevice.interpretedTranscripts, ["call son"])
        XCTAssertEqual(gemini.interpretedTranscripts, ["set reminder"])
    }

    func testCompletionValuePassesThroughUnchanged() {
        let expected = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil,
            medication: nil, message: nil, callType: "voice", requestedApp: nil,
            confidence: 0.9, reply: "ठिक छ"
        )
        let spy = SpyCommandInterpreter(isAvailable: true, nextCommand: expected)
        let switchable = SwitchableCommandInterpreter(current: spy)
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "ne")

        let exp = expectation(description: "interpret completes")
        switchable.interpret(transcript: "छोरालाई फोन गर", context: ctx) { result in
            XCTAssertEqual(result, expected)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}

// MARK: - VoiceEngineStack

/// `VoiceEngineStack` is the persisted UserDefaults-backed preference
/// (`AppCoordinator.voiceEngineStack`) that drives which concrete
/// interpreter/recognizer pair is live. Covers the raw-value round trip
/// `AppCoordinator.init` and its `didSet` rely on.
final class VoiceEngineStackTests: XCTestCase {

    func testRawValueRoundTrip() {
        XCTAssertEqual(VoiceEngineStack(rawValue: "onDevice"), .onDevice)
        XCTAssertEqual(VoiceEngineStack(rawValue: "gemini"), .gemini)
        XCTAssertEqual(VoiceEngineStack.onDevice.rawValue, "onDevice")
        XCTAssertEqual(VoiceEngineStack.gemini.rawValue, "gemini")
    }

    func testUnknownOrMissingStoredValueFallsBackToGemini() {
        // Mirrors AppCoordinator.init's restore expression: an absent key
        // (fresh install) or a stale/garbage stored value must not crash
        // or silently pick on-device — it defaults to the existing
        // always-Gemini behavior.
        func restore(_ stored: String?) -> VoiceEngineStack {
            stored.flatMap(VoiceEngineStack.init(rawValue:)) ?? .gemini
        }
        XCTAssertEqual(restore(nil), .gemini)
        XCTAssertEqual(restore("not-a-real-stack"), .gemini)
        XCTAssertEqual(restore("onDevice"), .onDevice)
    }
}
