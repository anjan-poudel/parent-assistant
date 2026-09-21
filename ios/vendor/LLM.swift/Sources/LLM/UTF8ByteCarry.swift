//
//  UTF8ByteCarry.swift
//  LLM
//
//  Carries incomplete UTF-8 tail bytes across token boundaries.
//
//  Why this exists: a single generated token can end in the middle of a
//  multi-byte UTF-8 sequence (byte-fallback tokens do this constantly with
//  Devanagari, where one codepoint is three bytes). Decoding each token's bytes
//  in isolation and dropping the ones that do not form valid UTF-8 severs the
//  cluster, which on device turned "तपाईंको नाम" into "तपंकोीला".
//
//  This is a port of what llama.cpp's server does at the pinned build (b10068):
//
//  - `validate_utf8` (tools/server/server-common.cpp) returns the length of the
//    prefix of `text` that can form a valid string; if the trailing bytes are a
//    cut-in-half multi-byte sequence it returns the index *before* the cut.
//  - `process_token` (tools/server/server-context.cpp) accumulates the raw token
//    bytes and, while that buffer ends in an incomplete sequence, holds emission
//    back so the bytes are never decoded apart from their continuation.
//
//  Difference in *timing*, not in content: upstream holds back the whole
//  accumulated buffer, this emits the bytes that are already complete and holds
//  only the incomplete tail. The concatenation of emitted text is identical,
//  and the tail is carried into the next token either way.
//

/// Per-generation UTF-8 byte carry.
///
/// Usage: create one per generation, feed each token's raw piece bytes to
/// `consume(_:)`, and call `flush()` once when generation stops.
struct UTF8ByteCarry {
    /// Bytes held back because they are an incomplete UTF-8 sequence.
    /// Never longer than 3 bytes: `validPrefixLength` only holds back the bytes
    /// of a cut-off 2-, 3- or 4-byte sequence.
    private var pending: [UInt8] = []

    /// Length of the longest prefix of `bytes` that ends on a UTF-8 character
    /// boundary.
    ///
    /// Direct port of llama.cpp's `validate_utf8` (tools/server/server-common.cpp,
    /// b10068). It scans at most the last four bytes from the end looking for the
    /// lead byte of a multi-byte sequence that is missing continuation bytes; if
    /// it finds one, it returns the index before that lead byte. Note this is not
    /// a full UTF-8 validator (upstream is not either): it only detects a
    /// *truncated* sequence. Genuinely invalid bytes are returned as part of the
    /// valid prefix and repaired when decoded.
    static func validPrefixLength(_ bytes: [UInt8]) -> Int {
        let len = bytes.count
        if len == 0 { return 0 }

        // Check the last few bytes to see if a multi-byte character is cut off
        var i = 1
        while i <= 4 && i <= len {
            let c = bytes[len - i]
            // Check for start of a multi-byte sequence from the end
            if (c & 0xE0) == 0xC0 {
                // 2-byte character start: 110xxxxx
                // Needs at least 2 bytes
                if i < 2 { return len - i }
            } else if (c & 0xF0) == 0xE0 {
                // 3-byte character start: 1110xxxx
                // Needs at least 3 bytes
                if i < 3 { return len - i }
            } else if (c & 0xF8) == 0xF0 {
                // 4-byte character start: 11110xxx
                // Needs at least 4 bytes
                if i < 4 { return len - i }
            }
            i += 1
        }

        // If no cut-off multi-byte character is found, return full length
        return len
    }

    /// Consumes one token's raw piece bytes and returns the text that can be
    /// decoded now. An incomplete tail is held back and prepended to the next
    /// call's bytes.
    mutating func consume(_ bytes: [UInt8]) -> String {
        var combined = pending
        combined.append(contentsOf: bytes)

        let validLength = Self.validPrefixLength(combined)
        pending = Array(combined[validLength...])

        return Self.decode(combined[0..<validLength])
    }

    /// End-of-generation flush of the carried bytes.
    ///
    /// Upstream never discards the accumulated bytes either: they are part of the
    /// final text, and the JSON layer replaces the invalid part with U+FFFD. The
    /// repairing initializer below produces exactly that replacement.
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        defer { pending.removeAll() }
        return Self.decode(pending[...])
    }

    /// Decodes bytes, repairing anything that is not valid UTF-8 with U+FFFD —
    /// the same replacement llama.cpp's JSON layer applies — and dropping NUL
    /// bytes, which is what `LLM.decode(_:special:)` does for single tokens.
    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self).filter { $0 != "\0" }
    }
}
