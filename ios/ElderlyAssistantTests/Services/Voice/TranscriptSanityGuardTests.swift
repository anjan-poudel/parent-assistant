import XCTest
@testable import ElderlyAssistant

final class TranscriptSanityGuardTests: XCTestCase {

    // MARK: - Passes

    func testEmptyTranscriptPasses() {
        XCTAssertEqual(TranscriptSanityGuard.check(""), .pass)
        XCTAssertEqual(TranscriptSanityGuard.check("   \n"), .pass)
    }

    func testShortNepaliAcknowledgementPasses() {
        // Realistic ack utterance: "मैले औषधि खाएँ।" ("I took the medicine.")
        XCTAssertEqual(
            TranscriptSanityGuard.check("मैले औषधि खाएँ।"),
            .pass
        )
    }

    func testShortEnglishAcknowledgementPasses() {
        XCTAssertEqual(TranscriptSanityGuard.check("i took my medicine"), .pass)
    }

    func testOneWordNepaliPassesEvenWithLowDiversity() {
        // "हो" — two chars, low diversity, but under `entropyMinLength`
        // so the entropy floor doesn't apply.
        XCTAssertEqual(TranscriptSanityGuard.check("हो"), .pass)
        XCTAssertEqual(TranscriptSanityGuard.check("no"), .pass)
    }

    func testCodeSwitchedNepanglishPasses() {
        // Real elderly speech mixes English words in Nepali sentences.
        XCTAssertEqual(
            TranscriptSanityGuard.check("मैले medicine खाएँ आज बिहान"),
            .pass
        )
    }

    // MARK: - Repetition loop

    func testWordLevelRepetitionLoopRejected() {
        // Whisper's classic noise failure — the same short phrase looped.
        // "औषधि खाएँ" has high character diversity, so it passes the
        // entropy floor and the repetition detector is the one that fires.
        let looped = Array(repeating: "औषधि खाएँ", count: 6).joined(separator: " ")
        XCTAssertEqual(
            TranscriptSanityGuard.check(looped),
            .reject(.repetitionLoop)
        )
    }

    func testCharacterLevelRepetitionLoopRejected() {
        // Three-glyph pattern loop with no whitespace — 3/18 ≈ 0.17
        // diversity clears the entropy floor (0.15), so the repetition
        // detector is the one that must fire.
        XCTAssertEqual(
            TranscriptSanityGuard.check("षकमषकमषकमषकमषकमषकम"),
            .reject(.repetitionLoop)
        )
    }

    func testSingleGlyphSpamRejectedAsLowEntropy() {
        // Same char × many — the single-glyph hallucination. Entropy
        // runs before repetition so it wins the labeling race.
        XCTAssertEqual(
            TranscriptSanityGuard.check("षषषषषषषषषषषष"),
            .reject(.lowEntropy)
        )
    }

    func testFourGramRepetitionRejected() {
        let phrase = "बिरामी छ आज मैले "
        let looped = String(repeating: phrase, count: 5)
        XCTAssertEqual(
            TranscriptSanityGuard.check(looped),
            .reject(.repetitionLoop)
        )
    }

    func testTwoIdenticalPhrasesArentAloop() {
        // A user repeating themselves twice for emphasis must not trip
        // the guard.
        XCTAssertEqual(
            TranscriptSanityGuard.check("औषधि खाएँ औषधि खाएँ"),
            .pass
        )
    }

    // MARK: - Entropy

    func testLowEntropyLongTranscriptRejected() {
        // Same char × many, long enough to cross entropy floor length
        // but escaping the repetition detector by mixing two chars.
        let low = String(repeating: "अआ", count: 40)
        // Diversity = 2 / 80 = 0.025 << 0.15 → reject.
        XCTAssertEqual(
            TranscriptSanityGuard.check(low),
            .reject(.lowEntropy)
        )
    }

    func testHighEntropyLongTranscriptPasses() {
        // 60+ Devanagari chars with reasonable diversity — a full sentence.
        let text = "आज बिहान मैले मेरो औषधि खाएँ र त्यसपछि केही समय आराम गरेँ अनि अलिकति पानी पिएँ।"
        XCTAssertEqual(TranscriptSanityGuard.check(text), .pass)
    }

    // MARK: - Length cap

    func testAbsurdlyLongTranscriptRejected() {
        // > 300 chars means the STT ran way past a 10 s utterance.
        let long = String(repeating: "क ", count: 200)
        XCTAssertEqual(
            TranscriptSanityGuard.check(long),
            .reject(.tooLong)
        )
    }

    // MARK: - Config overrides

    func testCustomConfigChangesBehaviour() {
        let strict = TranscriptSanityGuard.Config(
            repetitionThreshold: 2,
            repetitionNGramSizes: [1, 2],
            minCharacterDiversity: 0.5,
            entropyMinLength: 4,
            maxCharacters: 50
        )
        XCTAssertEqual(
            TranscriptSanityGuard.check("hi hi", config: strict),
            .reject(.repetitionLoop)
        )
    }
}
