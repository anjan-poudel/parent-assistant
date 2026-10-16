// FIXTURE (negative) — rule feature-content-print must stay quiet in the
// new dialogue root.
//
// The answer text is present as *data*: it is read and summarised, and
// nothing at all is rendered to a console. The rule is scoped to console
// writes, so none of this is a violation.
import Foundation

struct DialogueAnswerFixture {
    func answerCaptured(rawText: String) -> Int {
        rawText.count
    }
}
