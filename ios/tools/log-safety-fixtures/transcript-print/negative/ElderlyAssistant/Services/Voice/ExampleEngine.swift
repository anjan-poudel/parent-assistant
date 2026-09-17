// FIXTURE (negative) — rule transcript-print must stay quiet.
//
// `empty_transcript` is an event name, not content: the word is preceded by
// an underscore, so the rule's boundary holds and this file must pass. The
// same file also carries the camelCase near-miss `transcriptCount` used as a
// count (not rendered), which the rule must not read as content either.
import Foundation

func warmUp(emptyTranscript: Bool, transcriptCount: Int) {
    print("empty_transcript")
    _ = emptyTranscript
    _ = transcriptCount
}
