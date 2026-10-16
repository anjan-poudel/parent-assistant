// FIXTURE (negative) — rule error-interpolation must stay quiet.
//
// The same interpolation, reaching only content-free members of the error.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print("warm failed: \(nsError.domain) status \(nsError.code)")
    }
}
