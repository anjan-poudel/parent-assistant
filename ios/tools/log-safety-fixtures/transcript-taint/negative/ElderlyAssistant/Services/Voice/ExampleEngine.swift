// FIXTURE (negative) — rule transcript-taint must stay quiet.
//
// The same one-hop shape as the positive fixture, but the assigned value is
// an event name rather than content: the taint must not spread from a
// snake_case token.
import Foundation

func warmUp() {
    let message = "empty_transcript"
    print(message)
}
