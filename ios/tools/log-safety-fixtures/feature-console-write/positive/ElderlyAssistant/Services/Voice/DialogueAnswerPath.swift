// FIXTURE (positive) — rule feature-console-write, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The answer path is one of the four dialogue files the gate must classify
// as a *feature* source; this fixture pins its half of the root extension
// for the Release-framed rule — a console write in this file, however
// harmless it renders, is a violation.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func answerCaptured(attempt: Int) {
    print("dialogue_answer_captured")
}
