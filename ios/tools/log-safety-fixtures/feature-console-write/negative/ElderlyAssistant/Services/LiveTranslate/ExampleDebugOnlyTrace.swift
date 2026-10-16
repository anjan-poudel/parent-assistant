// FIXTURE (negative) — rule feature-console-write must stay quiet.
//
// The near-miss that pins the rule's *framing*: a console write inside
// `#if DEBUG`, rendering nothing sensitive. It cannot be compiled into
// Release, so the shipped gate's Release framing exempts it, and this rule
// keeps that framing. (The feature's own `LiveTranslateSourceHygieneTests`
// is stricter and forbids this too — the gate is the backstop, not the only
// arm. And if such a write ever rendered content, `feature-content-print`
// would catch it in any configuration.)
import Foundation

#if DEBUG
func debugTrace(regionCount: Int) {
    print("ocr_pass")
    NSLog("session started")
}
#endif
