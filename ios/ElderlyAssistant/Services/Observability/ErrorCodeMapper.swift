import Foundation

/// A type that can name itself with a short, content-free diagnostic code
/// for the observability bus's `error_code` field.
///
/// Adopt this when the `NSError` bridge (`domain` + numeric `code`) would
/// lose the diagnostic distinction — a Swift error enum's associated values
/// are not part of its bridged domain/code, so every case collapses to the
/// same pair. Implementations MUST derive the code from the type's own case
/// structure only: never a description, a URL, an upstream body or user
/// info (T-050 / NFR-016).
protocol LogSafeErrorCode {
    var logSafeErrorCode: String { get }
}

/// The single error → `error_code` mapping used by every emitter that
/// previously passed `String(describing: error)` (T-050, finding B2).
///
/// Why this exists: a transport error's *description* embeds the failing
/// URL — and while the Gemini key rode in that URL's query string
/// (`...&key=<API_KEY>`), the description carried the key itself into
/// `error_code`, which `LogSanitiser` copied through unscrubbed. This
/// mapper never reads `localizedDescription`, `String(describing:)` or any
/// user-info value; it emits only type-level identity (error domain,
/// numeric code, or an explicit `LogSafeErrorCode`), which is content-free
/// by construction and stays diagnosable — `url_error_-1004` is an
/// unreachable host, `url_error_-1001` a timeout, `http_429` a quota.
///
/// Call sites stay one line — `ErrorCodeMapper.code(for: error)` — so the
/// next emitter inherits the safe behaviour by construction.
enum ErrorCodeMapper {

    /// Hard cap on a mapped code. `LogSanitiser` applies its own bound at
    /// the bus boundary as defence in depth; this one keeps a
    /// wildly-shaped `NSError` domain from producing an oversized code.
    static let maxCodeLength = 64

    static func code(for error: Error) -> String {
        if let coded = error as? LogSafeErrorCode {
            return bounded(coded.logSafeErrorCode)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // Transport failure: the domain is implied and the numeric
            // NSURLError code is the diagnostic value. The failing URL —
            // the piece that used to carry the key — is never consulted.
            return "url_error_\(nsError.code)"
        }
        let domain = token(from: nsError.domain)
        return bounded("\(domain.isEmpty ? "error" : domain)_\(nsError.code)")
    }

    /// A conservative charset for an error domain: type identities are
    /// identifier-shaped. Anything else (a sentence, a URL, a body) is
    /// dropped rather than logged.
    private static func token(from raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(raw.filter { allowed.contains($0) }.prefix(48))
    }

    private static func bounded(_ code: String) -> String {
        String(code.prefix(maxCodeLength))
    }
}
