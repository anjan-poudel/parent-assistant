# T-145 — FamilyContact identity model and nicknames: implementation notes

Unit: `TG-29/T-145-family-contact-identity-model-and-nicknames`
Feature: `family-contacts-unify` · Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`)
Commit: the T-145 unit commit on `feat/family-contacts-unify` carrying this notes file plus the six source/test files listed at the end (not pushed).
Date: 2026-10-12

## What was built

### 1. Model (`ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift`)

- `var nickname: String?` **replaced** by `var nicknames: [String]` (no shim, design-l2 §3.1). Member-wise `init` signature follows the design exactly (`photoFilename:`, `nicknames: [String] = []`, …, `systemContact: SystemContactLink? = nil` last).
- New `struct SystemContactLink: Codable, Equatable { var identifier: String; var numberKey: String }` defined in the same file (design-l2 §1.1, §8.2), next to the payload shape it belongs to.
- `static func normalizedNicknames(_ raw: [String]) -> [String]`: trim with `.whitespacesAndNewlines`, drop entries that become empty, preserve order and duplicates (design-l2 §3.2). Applied in the decoder.
- `static let maxNicknameLength = 64` + `static func cappedNickname(_ raw: String) -> String?`: the F5 editor/submission bound — trim, blank → nil, over-long → whole-**Character** prefix (a Devanagari cluster is never split).
- **Decoder** (design-l2 §3.4, verbatim order): `nicknames` presence wins (`decodeIfPresent([String])` → `normalizedNicknames`), else the legacy single `nickname` read through a separate `private enum LegacyNicknameKeys` container but only when non-blank, else `[]`. `systemContact` decodes to nil when the payload is missing, malformed, or has an empty `identifier`/`numberKey`. `CodingKeys` holds only stored properties; the synthesized `Encodable` is untouched and never emits a legacy key. No logging anywhere on the decode/migration path (no PII surface at all).

### 2. Compile-forced call sites

| File | Change | Ownership |
|---|---|---|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | **minimal mechanical**: `addFamilyContact`/`updateFamilyContact` keep `nickname: String?` and write `nickname.map { [$0] } ?? []`; the two call sites and a KNOWN INTERIM LOSS note are commented | T-156 widens to `nicknames: [String]` |
| `ios/ElderlyAssistant/App/ProfileInterviewSteps.swift` | pass-through → `nickname: entry.contact.nicknames.first` (comment names T-156) | T-156/T-158 |
| `ios/ElderlyAssistant/App/SettingsView.swift` | `loadDraft` → `contact.nicknames.first ?? ""`; `save()` → `FamilyContact.cappedNickname(nickname)` (single free-text draft kept; F5 cap now enforced on save) | T-160 builds the §2.5 list editor |
| `ios/ElderlyAssistantTests/App/KinDesignationTests.swift` | fixtures moved from `nickname:` to `nicknames:` | test-side only |

No other file in the repo references the old field (verified by repo-wide grep for `\.nickname\b` / `nickname:`).

### 3. Tests (`ios/ElderlyAssistantTests/Services/Storage/FamilyContactStoreTests.swift`, 31 tests, 16 new/rewritten)

| Scenario (task spec) | Test |
|---|---|
| Legacy single nickname migrates losslessly; re-encoding writes the new shape; no other field altered | `testLegacySingleNicknameMigratesLosslessly` (raw legacy-JSON payload → decode → **re-save** → raw bytes carry `nicknames`, never `nickname`; re-decodes with the same id) |
| Every historical shape decodes; no decode failure drops a contact (NFR-FCU-006) | `testEveryHistoricalShapeLoadsWithoutLoss` (6 records in ONE read: pre-field, legacy single, multi, valid link, corrupt link, blank legacy nickname) |
| Whitespace-only entries dropped | `testNormalizedNicknamesTrimsAndDropsWhitespaceOnlyEntries`, `testWhitespaceOnlyEntriesAreNotStoredAndDoNotMatchAnything`, `testLegacyEmptyOrWhitespaceOnlyNicknameMigratesToNoNicknames` |
| Corrupt link → nil, record retained (FR-FCU-002 sc. 3) | `testCorruptLinkPayloadDecodesToNoLinkAndKeepsTheContact` (empty identifier / empty numberKey / wrong-typed field) |
| Link round-trips both fields exactly | `testSystemContactLinkRoundTripsWithBothFields` |
| Legacy key alongside new keys: presence wins, no duplication | `testNicknamesPresenceWinsOverLegacyKeyWithoutDuplicating` (incl. explicit empty array wins over the legacy value) |
| 64-char editor cap + faithful projection (F5) | `testNicknameCappedAtSixtyFourCharactersAtTheEditorSeam` (100-char input → 64; cluster-boundary case; projection does NOT truncate) |
| FR-FCU-011 scenario 1 (as-entered round-trip) | `testMultipleNicknamesStoredAsEnteredSurviveRoundTrip` |

Fixtures the current model cannot produce (the legacy `nickname` key, corrupt link objects) are written as raw `JSONSerialization` bytes through a new test-only `InMemoryEncryptedStorage.writeRaw/rawObject`; the pre-existing legacy coverage (`LegacyFamilyContact`) now also asserts empty nicknames + nil link.

## Gate results

- **Scoped unit suite**: `./build.sh test:unit FamilyContactStoreTests` → **31/31 pass** (exit 0). Also ran `./build.sh test:unit KinDesignationTests` → 4/4 pass.
- **Whole-module typecheck**: `xcodebuild build -scheme ElderlyAssistant` (simulator destination) → **BUILD SUCCEEDED, 0 errors**; the test target also compiles (both scoped suites ran), which covers the wizard/onboarding compile requirement.
- Coverage percentage was not measured: `build.sh test:unit` does not emit an `.xcresult` coverage report in this configuration (the run's result bundle carries no coverage payload). The new model code is exercised directly by the 16 tests above (every decoder branch, both normalizer branches, both cap branches, both decoder-presence branches).
- House rule followed: no `ai-sdd run` / `ai-sdd complete-task` was invoked. The parent's speed-mode directive (skip the scoped suite, typecheck only) arrived mid-unit; the suites above were run before/around it and are reported as an extra confidence signal, not as the phase gate.

## Decisions made during implementation

1. **F5 cap placement** — the 64-char bound lives at the editor/submission seam (`cappedNickname`, used by the wizard's save path) while `normalizedNicknames` stays faithful (trim + drop only), exactly as the task's F5 decision records. Documented in both code comments; the task's "stored/edited value capped at 64" acceptance line is pinned via `cappedNickname` + the faithful-projection assertion.
2. **Legacy key + presence rule** — implemented exactly as design §3.4, including "an explicit empty array wins" (removing every nickname is real data, not a fallback to the legacy value).
3. **Coordinator seam not widened** — T-156 owns the signature change; the interim write is a one-entry list so single-nickname contacts round-trip unchanged.
4. **Encoder kept synthesized** — no hand-written `encode(to:)`; the "presence wins" behaviour is proven by inspecting the raw stored JSON, not by the encoder.
5. **No decode-path logging** — the PII-discipline requirement is satisfied vacuously (there is no log call on the migration/decode path).

## Handoff / open items (for T-156, T-160, T-163)

1. **T-156 (blocking for the pair)**: widen `addFamilyContact`/`updateFamilyContact` to `nicknames: [String]`, apply `FamilyContact.normalizedNicknames` at that save path (design §3.2's third application point), and delete the two `nickname.map { [$0] } ?? []` shims. **Until it lands, a contact holding several nicknames loses the entries after the first when saved through the wizard or replayed through the T-100 kin-designation pass-through** — flagged in-code at both coordinator sites.
2. **T-160**: the wizard's nickname step is still the legacy single free-text field (showing/saving the first entry). The §2.5 list editor (`nicknameList`/`nicknameAddRow`/`nicknameHint`, 8-entry cap at the Add control, `family.nickname.*` keys) replaces the draft state; `loadDraft` becomes `nicknames = contact.nicknames`. The current save route through `cappedNickname` should be kept as the entry-point cap there.
3. **T-151**: the worst-case long-string performance assertion (256-char entry) is T-151's by the recorded decision — `normalizedNicknames` intentionally does not truncate.
4. Pre-existing test bug found and fixed while extending `FamilyContactStoreTests`: `testNicknameRoundTrip` asserted on a second contact it never added (it passed before only by asserting `nil` on the first contact).

## Files changed

```
ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift   (+125/-…)
ios/ElderlyAssistant/App/AppCoordinator.swift                    (+20)
ios/ElderlyAssistant/App/ProfileInterviewSteps.swift             (+7)
ios/ElderlyAssistant/App/SettingsView.swift                      (+17)
ios/ElderlyAssistantTests/App/KinDesignationTests.swift          (+16)
ios/ElderlyAssistantTests/Services/Storage/FamilyContactStoreTests.swift (+398)
```
