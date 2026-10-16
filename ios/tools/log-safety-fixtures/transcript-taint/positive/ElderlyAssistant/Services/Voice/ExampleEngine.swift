// FIXTURE (positive) — rule transcript-taint.
//
// The value is not spelled `transcript` at the print; it was assigned from a
// transcript-bearing expression one hop earlier. The gate is expected to
// follow that hop and fail, naming `transcript-taint`.
import Foundation

func warmUp(rawTranscript: String) {
    let message = "warm failed: " + rawTranscript
    print(message)
}
