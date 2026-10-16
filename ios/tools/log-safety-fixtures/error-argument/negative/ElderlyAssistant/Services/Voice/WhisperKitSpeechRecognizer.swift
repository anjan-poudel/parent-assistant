// FIXTURE (negative) — rule error-argument must stay quiet.
//
// The catch block reports the domain only, which is identity rather than
// content.
import Foundation

func warmUp() {
    do {
        try warm()
    } catch {
        print(error.domain)
    }
}
