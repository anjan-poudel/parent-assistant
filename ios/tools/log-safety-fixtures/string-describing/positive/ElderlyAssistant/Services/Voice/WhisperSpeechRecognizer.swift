// FIXTURE (positive) — rule string-describing.
//
// The exact T-050 defect shape, in one of the two guarded engine files:
// `String(describing:)` renders arbitrary state (here the whole error, which
// can embed a key-bearing URL). The file path is what makes the engine rules
// apply, so it is named after the shipped engine.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print("warm failed: \(String(describing: error))")
    }
}
