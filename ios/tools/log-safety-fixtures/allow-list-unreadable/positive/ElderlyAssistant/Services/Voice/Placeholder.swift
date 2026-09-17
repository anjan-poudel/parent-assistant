// FIXTURE (positive) — rule allow-list-unreadable.
//
// The `--allow-list` pointed at NotALogSanitiser.swift (see `arguments`),
// which declares no `allowedKeys` array. With no allow-list there is nothing
// to judge a metadata key against, so the gate must fail rather than report
// a scope it cannot read.
import Foundation
