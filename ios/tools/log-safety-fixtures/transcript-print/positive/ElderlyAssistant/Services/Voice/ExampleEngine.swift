// FIXTURE (positive) — rule transcript-print.
//
// The B1 defect shape: a print that compiles into Release and renders the
// recognised utterance. The gate must fail on this file and name
// `transcript-print`.
import Foundation

func warmUp(rawTranscript: String) {
    print("heard \(rawTranscript)")
}
