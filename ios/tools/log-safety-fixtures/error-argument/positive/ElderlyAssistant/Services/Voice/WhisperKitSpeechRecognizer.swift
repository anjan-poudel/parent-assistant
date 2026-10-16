// FIXTURE (positive) — rule error-argument.
//
// The error object is handed to the print as a bare argument: no member is
// applied, so the sink renders the whole object.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print(error)
    }
}
