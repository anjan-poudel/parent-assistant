// FIXTURE (positive) — rule feature-content-print, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The candidate texts come from the near-match arm — the household's own
// words echoed back — and rendering them to a console is the same defect
// as rendering the transcript. Inside `#if DEBUG` on purpose: the content
// rule is judged in every configuration, the Release-framed write rule is
// not, and this tree isolates the former.
import Foundation

func candidatesBuilt(candidateTexts: [String]) {
    #if DEBUG
    debugPrint(candidateTexts)
    #endif
}
