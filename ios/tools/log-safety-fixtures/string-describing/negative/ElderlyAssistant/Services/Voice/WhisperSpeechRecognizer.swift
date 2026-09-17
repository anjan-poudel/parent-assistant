// FIXTURE (negative) — rule string-describing must stay quiet.
//
// A content-free member off the error (`.domain`) is the sanctioned way to
// say something failed; the gate must accept it.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print("warm failed: \(error.domain)")
    }
}
