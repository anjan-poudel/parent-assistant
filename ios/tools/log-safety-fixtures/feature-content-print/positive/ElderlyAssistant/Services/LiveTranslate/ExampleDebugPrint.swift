// FIXTURE (positive) — rule feature-content-print.
//
// The SD-2 defect the design review found: recognized text (`region.text`)
// and translated text (`translation`) rendered to a console in the feature's
// sources, which the shipped gate did not recognise as content.
//
// Both writes are inside `#if DEBUG` **on purpose**, and that is the point of
// this fixture: the feature's content rules are configuration-independent
// (NFR-LCT-006 forbids content on a log surface in any build), so this rule
// must reach where the Release-framed `feature-console-write` rule cannot
// look. Keeping the two rules orthogonal is what makes each of them
// load-bearing, and it is why this tree holds no Release-compiled write: the
// union shape (a Release-compiled content print) fires *both* rules, which is
// a monotone consequence of the two individually proven triggers.
import Foundation

func debugTrace(region: TextRegion, translation: String) {
    #if DEBUG
    debugPrint(translation)
    #endif
    #if DEBUG
    print(region.text)
    #endif
}
