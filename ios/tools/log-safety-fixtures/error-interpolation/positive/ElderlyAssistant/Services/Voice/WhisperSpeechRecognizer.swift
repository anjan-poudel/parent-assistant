// FIXTURE (positive) — rule error-interpolation.
//
// The error object itself is interpolated, with no content-free member
// applied — a URLError's rendering carries its URL.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print("warm failed: \(error)")
    }
}
