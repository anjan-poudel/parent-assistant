// FIXTURE (positive) — rule feature-content-print, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The probe text is the household's words: rendering it to a console is
// the NFR-LCT-006 defect, in any build. Deliberately inside `#if DEBUG` —
// this rule is judged in every configuration, so it reaches where the
// Release-framed `feature-console-write` rule cannot look; keeping the two
// rules orthogonal is what makes each of them load-bearing.
import Foundation

func probeSpoken(probeText: String) {
    #if DEBUG
    debugPrint(probeText)
    #endif
}
