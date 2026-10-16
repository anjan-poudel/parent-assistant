// FIXTURE (positive) — rule feature-content-print, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The raw answer is a transcript fragment; rendering it to a console is a
// violation in every configuration. Deliberately inside `#if DEBUG` so the
// Release-framed `feature-console-write` rule stays quiet and this tree
// isolates the content rule, as its sibling fixtures do.
import Foundation

func answerCaptured(rawText: String) {
    #if DEBUG
    print(rawText)
    #endif
}
