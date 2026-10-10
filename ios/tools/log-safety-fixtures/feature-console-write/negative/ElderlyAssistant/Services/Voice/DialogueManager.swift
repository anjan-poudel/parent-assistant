// FIXTURE (negative) — the same new feature root, clean.
//
// The pair to the positive fixture one directory over: the identical path
// under the extended FEATURE_ROOTS, with no console write and no event
// field, must keep the gate at exit 0 — the roots scan clean sources
// quietly, they do not fail simply because the path is new.
import Foundation

struct DialogueFrameFixture {
    let attempt: Int
}
