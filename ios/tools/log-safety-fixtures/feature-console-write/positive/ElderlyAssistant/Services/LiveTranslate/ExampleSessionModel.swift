// FIXTURE (positive) — rule feature-console-write.
//
// A console write in the feature's own sources, rendering nothing sensitive
// at all. It is still a violation: the feature's events go through the
// sanitising observability bus or not at all, so any console write is a
// bypass of the sanitiser (NFR-LCT-006).
//
// Deliberately content-free, and deliberately outside `#if DEBUG`: this tree
// must trip `feature-console-write` and nothing else, or the rule could not
// be shown to be load-bearing on its own.
import Foundation

func sessionStarted(regionCount: Int) {
    print("ocr_pass")
    NSLog("session started")
}
