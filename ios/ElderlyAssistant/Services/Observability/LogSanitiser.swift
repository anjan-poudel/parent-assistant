import Foundation

/// Removes PII from observability event metadata before it reaches any log
/// sink (Console / OSLog / disk / remote crash reporter).
///
/// Constitution §Privacy requires: "Logs must not contain PII (names, health
/// values, contacts). Log sanitiser required." This is the single choke point
/// for that guarantee — every `ObservabilityBus` implementation must route
/// through `sanitise(_:)` before emitting.
///
/// Approach:
///  - allow-listed metadata keys pass through verbatim (id hashes, counts,
///    enum tags, boolean flags),
///  - unknown keys are dropped rather than logged, so a caller adding a new
///    field cannot leak PII by accident,
///  - values on allowed keys are still scrubbed for obvious PII patterns
///    (phone numbers, e-mails, blood-pressure readings) as defence in depth,
///  - the top-level `error_code` is bounded to a code shape and a maximum
///    unbroken-run length (see `boundErrorCode`) — [T-050/B2] it was the one
///    content-bearing field copied through unscrubbed, which is how a
///    key-bearing URL reached the console.
struct LogSanitiser {

    /// Longest `error_code` preserved verbatim at the bus boundary.
    static let maxErrorCodeLength = 64

    /// Codes are identifier-shaped: letters, digits and `._:-,;`.
    /// Anything else — spaces, `=`, quotes, `/`, `@`, braces, i.e. the
    /// shape an `Error` or `URL` description arrives in — is not a code
    /// and is replaced with `[redacted]` rather than logged.
    ///
    /// [T-050 / finding B2] `error_code` is a top-level event field copied
    /// through with no scrub, which is how `String(describing: URLError)`
    /// carried a key-bearing URL to the console. Emitters are fixed to
    /// pass content-free codes (`ErrorCodeMapper`); this bound catches the
    /// shapes a future emitter is most likely to hand over by accident (a
    /// rendered error or URL, a bare key-shaped token). It is a *shape*
    /// bound, not an entropy proof: a secret that is shorter than the run
    /// limit, or that the code charset splits into sub-limit runs, still
    /// passes verbatim — so nothing secret may be passed as `error_code`
    /// in the first place.
    private static let safeErrorCodePattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._:,;\-]*$"#)

    /// Longest unbroken alphanumeric run tolerated in an `error_code`.
    /// Codes are short words joined by `_` / `-` / `,` (the longest run in
    /// the live vocabulary is `delivery`); a Google API key is one unbroken
    /// 39-character run (`AIza…`). 32 sits between the two.
    static let maxUnbrokenRunLength = 32

    /// Built from `maxUnbrokenRunLength` so the two cannot drift apart.
    private static let longRunPattern = try! NSRegularExpression(
        pattern: "[A-Za-z0-9]{\(maxUnbrokenRunLength),}")

    /// Keys known to carry non-PII values. Anything else is dropped.
    static let allowedKeys: Set<String> = [
        "entry_id_hash",
        "contact_id_hash",
        "refire_count",
        "entry_count",
        "alert_type",
        "outcome",
        "state",
        "duration_ms",
        "error_code",
        // [TURN-TIMING] The serialized per-turn stage list
        // (`[{stage, ms}, …]`) — stage names and integer durations only,
        // never transcript or reply text (see VoiceTurnLatencyTracer).
        "stages"
    ]

    private static let piiPatterns: [NSRegularExpression] = {
        let patterns = [
            // phone numbers (7+ digits, common separators)
            #"\+?\d[\d\s\-().]{6,}\d"#,
            // e-mail addresses
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            // blood-pressure-like readings (systolic/diastolic)
            #"\b\d{2,3}\s*/\s*\d{2,3}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func sanitise(_ event: ObservabilityEvent) -> ObservabilityEvent {
        var cleanMetadata: [String: String] = [:]
        for (key, value) in event.metadata where Self.allowedKeys.contains(key) {
            cleanMetadata[key] = scrubValue(value)
        }
        return ObservabilityEvent(
            component: event.component,
            eventType: event.eventType,
            durationMs: event.durationMs,
            outcome: event.outcome,
            errorCode: boundErrorCode(event.errorCode),
            metadata: cleanMetadata
        )
    }

    /// Bounds a top-level `error_code` (T-050). Order matters: scrub first
    /// (phone / e-mail / BP shapes), then require the code charset — a
    /// value that fails it is not a code at all, so it is replaced rather
    /// than logged, then reject a key-shaped unbroken run (a pasted API
    /// key is charset-valid), and finally cap the length. A charset-valid,
    /// run-legal but over-long value is truncated — still content-free by
    /// shape, and codes are short by design.
    private func boundErrorCode(_ errorCode: String?) -> String? {
        guard let errorCode, !errorCode.isEmpty else { return nil }
        let scrubbed = scrubValue(errorCode)
        let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
        guard Self.safeErrorCodePattern.firstMatch(in: scrubbed, options: [],
                                                   range: range) != nil else {
            return "[redacted]"
        }
        guard Self.longRunPattern.firstMatch(in: scrubbed, options: [],
                                             range: range) == nil else {
            // One unbroken 32+-character alphanumeric token: a key or a
            // hash, never a code — truncating it would still log most of
            // the secret.
            return "[redacted]"
        }
        return String(scrubbed.prefix(Self.maxErrorCodeLength))
    }

    private func scrubValue(_ value: String) -> String {
        var result = value
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        for pattern in Self.piiPatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: "[redacted]"
            )
            _ = range
        }
        return result
    }
}
