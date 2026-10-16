// FIXTURE (positive) — rule feature-content-print.
//
// The plural spelling of the content vocabulary: `regionTexts` and a bare
// `texts` are collections of recognized strings, and rendering either to a
// console is the same defect as rendering one. The trailing lookahead used to
// reject `texts` (`s` is a word character), so the plural read as
// content-free — a reviewer reading the rule would not have guessed that the
// singular was covered and the plural was not.
//
// Both writes are inside `#if DEBUG` on purpose: this rule is judged in every
// configuration, so it reaches where the Release-framed
// `feature-console-write` rule cannot look.
import Foundation

func debugTrace(regionTexts: [String], texts: [String]) {
    #if DEBUG
    debugPrint(regionTexts)
    print(texts)
    #endif
}
