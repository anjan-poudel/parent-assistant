// FIXTURE (positive) — rule feature-console-write.
//
// The `#elseif` branch of a `#if DEBUG` chain. The branch that follows an
// `#elseif` is *not* the Debug branch — the condition above it was not taken
// — so this write compiles into Release. `ELSE_RE` (`^#else\b`) never matched
// `#elseif`, so the walker used to leave the whole chain classified Debug and
// excuse the write. The near-miss guard: a rule that only reads the first
// branch of a conditional is a rule with a documented way around it.
//
// Content-free on purpose — this tree must trip `feature-console-write` and
// nothing else. It is the branch that is on trial here, not the write.
import Foundation

func sessionStarted(regionCount: Int) {
    #if DEBUG
    let traceDetail = regionCount
    _ = traceDetail
    #elseif canImport(UIKit)
    print("ocr_pass")
    #endif
}
