// FIXTURE (negative) — rule error-description must stay quiet.
//
// The same catch block, reporting shape identity (domain + code) instead of
// a description.
import Foundation

func extractDialectEmbedding() {
    do {
        try load()
    } catch {
        print("extractDialectEmbedding failed: \(error.domain) \(error.code)")
    }
}
