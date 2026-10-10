// FIXTURE (negative) — rule feature-content-print must stay quiet in the
// new dialogue root.
//
// The content word the rule knows is present here as *data*: the probe
// text is read and summarised, and nothing at all is rendered to a
// console. The rule is scoped to console writes, so none of this is a
// violation.
import Foundation

struct DialogueManagerFixture {
    func probeSpoken(probeText: String) -> Int {
        probeText.count
    }
}
