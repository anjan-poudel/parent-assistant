// FIXTURE (negative) — rule feature-content-print must stay quiet in the
// new dialogue root.
//
// The candidate texts are present as *data*: they are read and counted,
// and nothing at all is rendered to a console. The rule is scoped to
// console writes, so none of this is a violation.
import Foundation

struct DialogueCandidateFixture {
    func candidatesBuilt(candidateTexts: [String]) -> Int {
        candidateTexts.count
    }
}
