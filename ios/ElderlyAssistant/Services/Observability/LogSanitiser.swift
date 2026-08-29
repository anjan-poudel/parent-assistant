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
///    (phone numbers, e-mails, blood-pressure readings) as defence in depth.
struct LogSanitiser {

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
        "error_code"
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
            errorCode: event.errorCode,
            metadata: cleanMetadata
        )
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
