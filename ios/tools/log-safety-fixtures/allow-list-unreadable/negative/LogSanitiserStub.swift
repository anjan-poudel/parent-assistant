// FIXTURE (negative, support file) — the smallest allow-list the gate can
// read. The real one lives in the project; this stub exists so the fixture
// does not depend on the project's file content.
import Foundation

struct LogSanitiserStub {
    static let allowedKeys: Set<String> = [
        "regionCount",
        "count"
    ]
}
