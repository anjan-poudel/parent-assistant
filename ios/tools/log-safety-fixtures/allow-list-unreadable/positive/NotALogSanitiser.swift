// FIXTURE (positive, support file) — a log sanitiser shape with no
// `static let allowedKeys: Set<String> = [ … ]` declaration for the gate to
// read. The gate must refuse to run its key rules rather than assume.
import Foundation

struct NotALogSanitiser {
    static let redacted = "[redacted]"
}
