import Testing
import Foundation
@testable import LLM

/// Regression test for the Devanagari corruption where a codepoint split across a
/// token boundary lost its partial bytes: the model generated "तपाईंको नाम" and the
/// UI showed "तपंकोीला".
///
/// The chunks below are raw token pieces (what `llama_token_to_piece` returns), so
/// this test needs no model.
struct UTF8ByteCarryTests {
    /// "तपाईं" split mid-codepoint: "तपा" + the lead byte of "ई", then the rest.
    /// Byte-fallback tokens hand over Devanagari exactly like this.
    @Test func splitMidCodepointReassemblesDevanagari() throws {
        let clean = "तपाईं"
        let bytes = Array(clean.utf8)
        // "तपा" is the first three codepoints (9 bytes); the ई starting at byte 9 is
        // handed over one byte at a time, so its codepoint is carried across tokens.
        let firstChunk = Array(bytes[0..<9]) + [bytes[9]]
        let secondChunk = Array(bytes[10...])

        var carry = UTF8ByteCarry()
        var decoded = carry.consume(firstChunk)
        // The lone lead byte is not decodable yet: it must be carried, not dropped.
        #expect(decoded == "तपा")

        decoded += carry.consume(secondChunk)
        decoded += carry.flush()

        #expect(decoded == clean)
    }
}
