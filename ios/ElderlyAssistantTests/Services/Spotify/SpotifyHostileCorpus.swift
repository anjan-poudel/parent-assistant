import Foundation

/// T-107 hostile deep-link corpus (NFR-SP-008; design-l2 §24 "URI validation
/// boundary"; security evidence obligation 5).
///
/// Fixtures, not assertions: every hostile payload the §24 corpus list names
/// lives here once, with a stable fixture name so `SpotifyDeepLinkTests` can
/// emit one named rejection assertion per entry. Provider results are
/// remote-controlled input; this file is the frozen sample of everything
/// that must never construct a URI, never reach the opener and never be
/// echoed.
///
/// Corpora are data, so this file has no test class and no logic beyond the
/// grouping helper — a fixture that became clever would stop being
/// auditable.
enum SpotifyHostileCorpus {

    /// One hostile identifier offered to `SpotifyTool.trackURI(id:)`.
    struct Entry: Equatable {
        /// Stable, unique fixture name — it appears in the assertion
        /// message, so a failure names the exact payload class.
        let name: String
        /// The hostile payload itself, offered to the builder verbatim.
        let value: String
        /// Which clause of the §24 corpus list this fixture proves.
        let category: Category
    }

    /// The §24 rejection classes, one fixture group each; the test suite has
    /// one NAMED test per case, so deleting a group is a visible edit.
    enum Category: String, CaseIterable {
        case wrongScheme
        case scriptStyleScheme
        case controlCharacters
        case offLengthIdentifier
        case delimiter
        case schemeText
        case doubleSlash
        case quote
        case pathTraversal
        case nonBase62Unicode
        case caseVariant
        case whitespaceVariant
        case percentEncodingTrick
    }

    /// A hostile QUERY offered to the search hand-off builder
    /// (`SpotifyTool.searchURI(query:)`). Queries are text, not identifiers:
    /// these are refused only on the §24 bounds — everything else must be
    /// percent-encoded inside the same `spotify:` grammar.
    struct QueryFixture: Equatable {
        let name: String
        let value: String
    }

    static func entries(in category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }

    // MARK: - Identifier fixtures

    /// Every entry here must be rejected by `trackURI(id:)` with nil — no
    /// URI, no partial, no repair.
    static let entries: [Entry] = [

        // Wrong scheme: scheme-shaped text where a 22-character base62 id
        // belongs.
        Entry(name: "wrong-scheme-https-url", value: "https://evil.example/track/01AbCdEfGhIjKlMnOpQrSt", category: .wrongScheme),
        Entry(name: "wrong-scheme-http-url", value: "http://evil.example/01AbCdEfGhIjKlMnOpQrSt", category: .wrongScheme),
        Entry(name: "wrong-scheme-file-url", value: "file:///etc/passwd", category: .wrongScheme),
        Entry(name: "wrong-scheme-tel-link", value: "tel:+15550100", category: .wrongScheme),
        Entry(name: "wrong-scheme-data-url", value: "data:text/plain;base64,QUJD", category: .wrongScheme),
        Entry(name: "wrong-scheme-mailto", value: "mailto:caregiver@example.com", category: .wrongScheme),

        // Script-style scheme: the classic injection surfaces.
        Entry(name: "script-scheme-javascript-alert", value: "javascript:alert(1)", category: .scriptStyleScheme),
        Entry(name: "script-scheme-javascript-cookie", value: "javascript:alert(document.cookie)", category: .scriptStyleScheme),
        Entry(name: "script-scheme-vbscript", value: "vbscript:msgbox(1)", category: .scriptStyleScheme),
        Entry(name: "script-scheme-javascript-percent-encoded", value: "javascript%3Aalert(1)", category: .scriptStyleScheme),
        Entry(name: "script-scheme-xss-tag", value: "</script><script>alert(1)</script>", category: .scriptStyleScheme),
        Entry(name: "script-scheme-data-html-base64", value: "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==", category: .scriptStyleScheme),

        // Control characters, several at exactly the valid 22-Character
        // length so rejection is proven on the scalar class, not the length.
        Entry(name: "control-char-nul-trailing", value: "01AbCdEfGhIjKlMnOpQrS" + "\u{0000}", category: .controlCharacters),
        Entry(name: "control-char-soh-leading", value: "\u{0001}" + "1AbCdEfGhIjKlMnOpQrSt", category: .controlCharacters),
        Entry(name: "control-char-cr-embedded", value: "01AbCdEfGhIjKlMnOpQ" + "\r" + "St", category: .controlCharacters),
        Entry(name: "control-char-unit-separator", value: "01AbCdEfGhIjKlMnOpQrS" + "\u{001F}", category: .controlCharacters),
        Entry(name: "control-char-delete", value: "01AbCdEfGhIjKlMnOpQrS" + "\u{007F}", category: .controlCharacters),

        // Off-length identifiers: 0, 21, 23 and a gross oversize — the 21
        // and 23 entries are valid base62 apart from their length, so they
        // prove the exact-length rule rather than the alphabet rule.
        Entry(name: "length-zero-empty", value: "", category: .offLengthIdentifier),
        Entry(name: "length-21-prefix", value: "01AbCdEfGhIjKlMnOpQrS", category: .offLengthIdentifier),
        Entry(name: "length-23-suffix", value: "01AbCdEfGhIjKlMnOpQrStX", category: .offLengthIdentifier),
        Entry(name: "length-100-oversize", value: String(repeating: "a", count: 100), category: .offLengthIdentifier),

        // Delimiters and the whitespace character, several pinned at exactly
        // 22 Characters.
        Entry(name: "delimiter-slash", value: "01AbCdEfGhIjKlMnOpQrS/", category: .delimiter),
        Entry(name: "delimiter-colon", value: "01AbCdEfGhIjKlMnOpQrS:", category: .delimiter),
        Entry(name: "delimiter-question", value: "01AbCdEfGhIjKlMnOpQrS?", category: .delimiter),
        Entry(name: "delimiter-hash", value: "01AbCdEfGhIjKlMnOpQrS#", category: .delimiter),
        Entry(name: "delimiter-percent", value: "01AbCdEfGhIjKlMnOpQrS%", category: .delimiter),
        Entry(name: "delimiter-dot", value: "01AbCdEfGhIjKlMnOpQrS.", category: .delimiter),
        Entry(name: "delimiter-hyphen", value: "01AbCdEfGhIjKlMnOpQrS-", category: .delimiter),
        Entry(name: "delimiter-underscore", value: "01AbCdEfGhIjKlMnOpQrS_", category: .delimiter),
        Entry(name: "delimiter-space-trailing", value: "01AbCdEfGhIjKlMnOpQrS ", category: .delimiter),
        Entry(name: "delimiter-space-leading", value: " 01AbCdEfGhIjKlMnOpQrS", category: .delimiter),
        Entry(name: "delimiter-space-internal", value: "01AbCdEfGhIjKlMnOpQr S", category: .delimiter),
        Entry(name: "delimiter-plus", value: "01AbCdEfGhIjKlMnOpQrS+", category: .delimiter),
        Entry(name: "delimiter-ampersand", value: "01AbCdEfGhIjKlMnOpQrS&", category: .delimiter),
        Entry(name: "delimiter-equals", value: "01AbCdEfGhIjKlMnOpQrS=", category: .delimiter),
        Entry(name: "delimiter-at", value: "01AbCdEfGhIjKlMnOpQrS@", category: .delimiter),
        Entry(name: "delimiter-semicolon", value: "01AbCdEfGhIjKlMnOpQrS;", category: .delimiter),
        Entry(name: "delimiter-comma", value: "01AbCdEfGhIjKlMnOpQrS,", category: .delimiter),

        // Scheme text: the correct scheme and the provider's, embedded in an
        // id-shaped string.
        Entry(name: "scheme-text-spotify-prefix", value: "spotify:track:01AbCdEfGhIjKlMnOpQrSt", category: .schemeText),
        Entry(name: "scheme-text-spotify-uppercase", value: "SPOTIFY:TRACK:01ABCDEFGHIJKLMNOPQRST", category: .schemeText),
        Entry(name: "scheme-text-open-spotify-https", value: "https://open.spotify.com/track/01AbCdEfGhIjKlMnOpQrSt", category: .schemeText),
        Entry(name: "scheme-text-auth-callback", value: "sahayak-spotify://callback?code=AQD-test", category: .schemeText),
        Entry(name: "scheme-text-embedded-colon", value: "01AbCdEfGhIjKlMnOpQrS:track", category: .schemeText),

        // Double slash: authority-shaped text.
        Entry(name: "double-slash-authority-lead", value: "//evil.example/track", category: .doubleSlash),
        Entry(name: "double-slash-tail", value: "01AbCdEfGhIjKlMnOpQrS//", category: .doubleSlash),
        Entry(name: "double-slash-embedded", value: "01AbCdEfGh//IjKlMnOpQrSt", category: .doubleSlash),
        Entry(name: "double-slash-only", value: "//", category: .doubleSlash),
        Entry(name: "double-slash-triple", value: "///01AbCdEfGhIjKlMnOpQrSt", category: .doubleSlash),

        // Quotes: double, single and backtick, wrapping and embedded.
        Entry(name: "quote-double-wrapped", value: "\"01AbCdEfGhIjKlMnOpQrSt\"", category: .quote),
        Entry(name: "quote-single-wrapped", value: "'01AbCdEfGhIjKlMnOpQrSt'", category: .quote),
        Entry(name: "quote-double-embedded", value: "01AbCdEfGhIjKlMnOpQrS\"", category: .quote),
        Entry(name: "quote-single-embedded", value: "01AbCdEfGhIjKlMnOpQrS'", category: .quote),
        Entry(name: "quote-backtick-wrapped", value: "`01AbCdEfGhIjKlMnOpQrSt`", category: .quote),
        Entry(name: "quote-backtick-embedded", value: "01AbCdEfGhIjKlMnOpQrS`", category: .quote),

        // Path traversal, raw and percent-encoded forms.
        Entry(name: "traversal-dot-dot-slash", value: "../track", category: .pathTraversal),
        Entry(name: "traversal-encoded-etc-passwd", value: "..%2F..%2Fetc%2Fpasswd", category: .pathTraversal),
        Entry(name: "traversal-double-dot-double-slash", value: "....//....//", category: .pathTraversal),
        Entry(name: "traversal-trailing-escape", value: "01AbCdEfGhIjKlMnOpQrSt/../../", category: .pathTraversal),
        Entry(name: "traversal-backslash-windows", value: "..\\..\\windows\\system32", category: .pathTraversal),
        Entry(name: "traversal-single-dot-prefix", value: "./01AbCdEfGhIjKlMnOpQrSt", category: .pathTraversal),

        // Non-base62 Unicode: accents, Devanagari, emoji (a 22-Character
        // string at 23 scalars), invisible formats, combining marks and a
        // provider-title-shaped id.
        Entry(name: "unicode-latin-accent", value: "01AbCdEfGhIjKlMnOpQrSé", category: .nonBase62Unicode),
        Entry(name: "unicode-devanagari-letter", value: "01AbCdEfGhIjKlMnOpQrSठ", category: .nonBase62Unicode),
        Entry(name: "unicode-emoji-at-valid-length", value: "01AbCdEfGhIjKlMnOpQrS🎵", category: .nonBase62Unicode),
        Entry(name: "unicode-bullet-prefix", value: "•01AbCdEfGhIjKlMnOpQrS", category: .nonBase62Unicode),
        Entry(name: "unicode-word-joiner-prefix", value: "\u{2060}01AbCdEfGhIjKlMnOpQrS", category: .nonBase62Unicode),
        Entry(name: "unicode-combining-acute", value: "01AbCdEfGhIjKlMnOpQrS\u{0301}", category: .nonBase62Unicode),
        Entry(name: "unicode-title-shaped-id", value: "भजन गीत", category: .nonBase62Unicode),
        Entry(name: "unicode-arabic-letter", value: "01AbCdEfGhIjKlMnOpQrSق", category: .nonBase62Unicode),

        // Case variants that are NOT base62: fullwidth forms and Cyrillic
        // homoglyphs. (A plain case flip of A-Z/a-z IS base62 and therefore
        // valid — these are the lookalikes that are not.)
        Entry(name: "case-variant-fullwidth-a", value: "01AbCdEfGhIjKlMnOpQrS\u{FF21}", category: .caseVariant),
        Entry(name: "case-variant-fullwidth-zero", value: "\u{FF10}1AbCdEfGhIjKlMnOpQrSt", category: .caseVariant),
        Entry(name: "case-variant-cyrillic-te", value: "01AbCdEfGhIjKlMnOpQrS\u{0442}", category: .caseVariant),
        Entry(name: "case-variant-cyrillic-dze", value: "01AbCdEfGhIjKlMnOpQr\u{0405}t", category: .caseVariant),
        Entry(name: "case-variant-dotless-i", value: "01AbCdEfGhIjKlMnOpQrS\u{0131}", category: .caseVariant),

        // Whitespace variants: ASCII tab/newline/CR and the Unicode spaces
        // trimmers do not strip from an id.
        Entry(name: "whitespace-tab-trailing", value: "01AbCdEfGhIjKlMnOpQrS\t", category: .whitespaceVariant),
        Entry(name: "whitespace-newline-trailing", value: "01AbCdEfGhIjKlMnOpQrS\n", category: .whitespaceVariant),
        Entry(name: "whitespace-cr-trailing", value: "01AbCdEfGhIjKlMnOpQrS\r", category: .whitespaceVariant),
        Entry(name: "whitespace-nbsp-trailing", value: "01AbCdEfGhIjKlMnOpQrS\u{00A0}", category: .whitespaceVariant),
        Entry(name: "whitespace-ideographic-space", value: "01AbCdEfGhIjKlMnOpQrS\u{3000}", category: .whitespaceVariant),
        Entry(name: "whitespace-padded-valid-core", value: "  01AbCdEfGhIjKlMnOpQrSt  ", category: .whitespaceVariant),

        // Percent-encoding tricks: encoded delimiters, double encoding,
        // malformed escapes and an encoded full scheme — decoded nowhere,
        // rejected as text.
        Entry(name: "percent-encoded-slash", value: "01AbCdEfGhIjKlMnOpQrS%2F", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-colon", value: "01AbCdEfGhIjKlMnOpQrS%3A", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-nul", value: "01AbCdEfGhIjKlMnOpQrS%00", category: .percentEncodingTrick),
        Entry(name: "percent-double-encoded-newline", value: "01AbCdEfGhIjKlMnOpQrS%250A", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-traversal", value: "%2E%2E%2F%2E%2E%2F", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-scheme", value: "spotify%3Atrack%3A01AbCdEfGhIjKlMnOpQrSt", category: .percentEncodingTrick),
        Entry(name: "percent-malformed-escape", value: "01AbCdEfGhIjKlMnOpQrSt%2", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-quote", value: "01AbCdEfGhIjKlMnOpQrS%22", category: .percentEncodingTrick),
        Entry(name: "percent-encoded-dot-boundary", value: "01AbCdEfGhIjKlMn%2E%2E%2F", category: .percentEncodingTrick),
    ]

    // MARK: - Search hand-off query fixtures

    /// Queries the search hand-off must refuse (design §24: accepted iff the
    /// trimmed query is non-empty and within `maxSearchQueryLength`).
    static let rejectedQueries: [QueryFixture] = [
        QueryFixture(name: "query-empty", value: ""),
        QueryFixture(name: "query-whitespace-only", value: " \n\t "),
        QueryFixture(name: "query-over-cap-ascii-101", value: String(repeating: "a", count: 101)),
        QueryFixture(name: "query-over-cap-multibyte-101", value: String(repeating: "ग", count: 101)),
        QueryFixture(name: "query-over-cap-thousand", value: String(repeating: "x", count: 1000)),
    ]

    /// Queries that must be accepted AND percent-encoded inside
    /// `spotify:search:` — hostile text is text here, never grammar.
    static let encodedQueries: [QueryFixture] = [
        QueryFixture(name: "query-delimiters", value: "a & b = c + d ? e / f % g # h"),
        QueryFixture(name: "query-scheme-text", value: "https://evil.example/x"),
        QueryFixture(name: "query-script-text", value: "javascript:alert(1)"),
        QueryFixture(name: "query-percent-trick", value: "%2E%2E%2F"),
        QueryFixture(name: "query-interior-nul", value: "a\u{0000}b"),
        QueryFixture(name: "query-format-strings", value: "%@ %n %s"),
        QueryFixture(name: "query-interior-newline", value: "line1\nline2"),
        QueryFixture(name: "query-double-encoded-traversal", value: "%252e%252e%252f"),
        QueryFixture(name: "query-title-shaped", value: "भजन गीत"),
    ]
}
