// FIXTURE (positive) — rule engine-file-missing.
//
// This tree deliberately omits the two guarded engine files. Run with
// `--require-engine-files` (see this fixture's `arguments` file), the gate
// must fail rather than report success over an empty scope — the
// anti-green-by-emptiness control.
import Foundation
