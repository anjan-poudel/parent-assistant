// FIXTURE (positive) — rule feature-content-print, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The option texts are the catalog's labels — the household's music words
// — and rendering them to a console is a violation in any build. Inside
// `#if DEBUG` on purpose: this tree isolates the content rule from the
// Release-framed write rule, as its sibling fixtures do.
import Foundation

func catalogLoaded(optionTexts: [String]) {
    #if DEBUG
    print(optionTexts)
    #endif
}
