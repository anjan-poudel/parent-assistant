// FIXTURE (positive) — rule error-description.
//
// `.localizedDescription` on an error embeds the URL, the upstream body and
// the failure path, which is how a key-bearing URL reached the console
// before T-050. The gate must fail on this file.
import Foundation

func extractDialectEmbedding() {
    do {
        try load()
    } catch {
        print("extractDialectEmbedding failed: \(error.localizedDescription)")
    }
}
