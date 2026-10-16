# T-148a — `ContactsAccess.limited` + single-gate mapping + identifier plumbing — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`, base 81b24389). Unit: TG-30 split per
plan amendment 1 (T-148a = the AddressBookDirectory half; per-site gate fixes
are T-148b and stay gated). Agent: dev. Design references: design-l2 §3.5
(`:815-895` — enum + mapping + identifier), §5.3 / §8.2 (placement), §6.4
(single-gate pin rationale). Requirement: FR-FCU-009 (honest read states).

## Status

**Done.** `.limited` is a first-class `ContactsAccess` state behind ONE
`#available(iOS 18.0, *)` gate; `AddressBookEntry` carries the system record
identifier; the two compile-forced switch sites are handled (one of them —
SettingsView — as a documented mechanical arm, see "Shared-file compile
fixes"). Gate per the 2026-10-12 speed-mode directive: the scoped suite run is
**deferred to phase end (T-163)**; the whole-module typecheck ran and is green.
No push.

## Files changed

- `ios/ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift` (+52/-10)
  — `ContactsAccess.limited`/`allowsReading`/`from(_:)`; `access()` delegates
  to the single mapping; `AddressBookEntry.identifier` (var, defaulted);
  the custom init gains a defaulted `identifier:` parameter; `make(...)` gains
  `identifier: String = ""`; `fetchKeys` adds `CNContactIdentifierKey`;
  `allEntries()` passes `contact.identifier`.
- `ios/ElderlyAssistant/Services/Contacts/MissedCallContactResolver.swift`
  (+7/-4) — `resolve`'s switch gains `.limited` in the readable arm
  (`case .allowed, .limited:`); doc comment states the limited-is-readable
  rule. Non-shared file (file-disjoint per amendment 1).
- `ios/ElderlyAssistant/App/SettingsView.swift` (+6/-1) — the wizard
  `searchSection` switch (:2117) gains `.limited` in the `.allowed` arm.
  **Mechanical compile fix only — T-148b debt, listed below.**
- `ios/ElderlyAssistantTests/Services/Contacts/ContactsAccessTests.swift`
  (NEW, 181 lines) — 9 tests: the `from(_:)` mapping table, the
  `allowsReading` pins, the single-gate source scan, and the
  `AddressBookEntry.identifier` plumbing pins.
- `ios/seniOS.xcodeproj/project.pbxproj` (+4) — XcodeGen regeneration adds the
  new test file to the test target (surgical: only the 4 lines for
  `ContactsAccessTests.swift`; the concurrent T-151 agent's own pbxproj lines
  were left unstaged for their unit).
- `specs/T-148a-notes.md` (this file).

## What was built

### 1. `ContactsAccess` (design-l2 §3.5, implemented verbatim)

- `case limited` — iOS 18+ "Select Contacts", a granted SUBSET.
- `var allowsReading: Bool { self == .allowed || self == .limited }` — the
  readable-states rule; denial/nagging logic keys on `.denied` only.
- `static func from(_ status: CNAuthorizationStatus) -> ContactsAccess` — the
  pure mapping with the SINGLE `#available(iOS 18.0, *)` gate in the pre-guard
  (`if #available(iOS 18.0, *), status == .limited { return .limited }`),
  then `.authorized → .allowed`, `.denied/.restricted → .denied`,
  `.notDetermined → .notDetermined`, `@unknown default → .denied` (fail
  closed).
- `AddressBookDirectory.access()` (:348) is now the one-liner
  `ContactsAccess.from(CNContactStore.authorizationStatus(for: .contacts))` —
  it no longer re-implements any part of the mapping.

### 2. Identifier plumbing (design-l2 §3.5)

- `AddressBookEntry.identifier: String = ""` — the system record
  (`CNContact.identifier`); empty means "not built from a live record"
  (test fixtures, the `make` default), which the link layer treats as
  unlinkable.
- `make(...)` gains `identifier: String = ""` (last parameter, defaulted) so
  every existing labeled call site compiles unchanged — verified: all 9
  `make(` call sites in tests + the one production call site still compile.
- `fetchKeys` fetches `CNContactIdentifierKey`; `allEntries()` passes
  `contact.identifier` through.

### 3. Consent/scope discipline

The `.limited` scope correction is the design-review-known delta; nothing
incidental was added. `AddressBookDirectory`'s conformance to
`SystemContactReading`/`SystemContactLinkReading` is **not** in this unit —
those protocols land with T-149's new file (they do not exist in this tree
yet), and the assignment narrowed T-148a to the enum + identifier half.

## Shared-file compile fixes (explicit list, as required)

The enum case is compile-forced at exactly two switch sites (equality checks
compile cleanly and are T-148b's by assignment):

1. **`SettingsView.swift:2117` (`FamilyContactWizardSheet.searchSection`,
   a switch over `ContactsAccess?`) — SHARED FILE, mechanical fix only.**
   `case .allowed:` became `case .allowed, .limited:` so `.limited` shares the
   `.allowed` body. This is the MINIMAL compile-complete arm: the design's
   honest `.limited` treatment (the `call.search.accessLimited` caption under
   the search field, limited-affordance copy, design-l2 §2.2) is **T-148b
   debt**, marked in-code with a comment saying so.
2. **`MissedCallContactResolver.resolve` (:107)** — non-shared file (its own
   per amendment 1); `.limited` joins the readable arm
   (`case .allowed, .limited:`) mirroring `.allowed`, per the design's
   "Resolver: `.limited` is readable (§1.8)".

No other shared-file edits. `LeafViews.swift` and `AppCoordinator.swift` were
NOT touched (their equality gates compile cleanly and are T-148b's).

### Pre-existing warning moved, not introduced (recorded deliberately)

The typecheck log shows one warning at the new mapping's switch
(`AddressBookDirectory.swift:282: warning: switch must be exhaustive — note:
add missing case: '.limited'`). This is **pre-existing in kind**: the old
`access()` switch had the identical case list, and a standalone typecheck of
that exact old shape against the same SDK (iphonesimulator SDK, target
iOS 16.0) reproduces the identical warning. The design's specified form
handles `.limited` in the availability pre-guard (keeping ONE gate), so the
switch body deliberately does not repeat the case. Two probes were run to
settle the options: (a) a `case .limited:` arm compiles without a per-case
availability annotation, but it would be dead code behind the pre-guard and
deviates from the design-specified snippet — not taken (noted here so T-148b/
T-163 can silence the warning deliberately if they want); (b) a plain
`default:` would silence it but deviates from the design's `@unknown default`
fail-closed semantics. The warning count is otherwise unchanged.

## Test coverage (written; run deferred)

`ContactsAccessTests` (9 tests):

- Mapping table: `.authorized → .allowed`; `.denied`/`.restricted → .denied`;
  `.notDetermined → .notDetermined`; `.limited → .limited` (guarded by
  `#available(iOS 18.0, *)` + `XCTSkip` on older runtimes — the test target's
  deployment target is 16.0).
- `allowsReading`: true for exactly `.allowed`/`.limited`; false for
  `.denied`/`.notDetermined`; plus the mapping↔readable-states agreement test.
- Single-gate claim (the Gherkin "no other site re-implements the iOS-version
  gate"): `FeatureSourceScan.swiftFiles(in: "ElderlyAssistant")` +
  `codeText(of:)` (comments stripped) scans the whole module for the marker
  `available(iOS 18` (deliberately without the leading `#`, so a
  declaration-level `@available(iOS 18…)` would also be caught) and asserts
  **exactly one** site, that it lives in
  `ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift`, and that
  the line compares against `.limited` (`status == .limited`).
- Identifier plumbing: `make` default is `""`; a passed identifier lands
  verbatim; direct construction defaults to `""` and the identifier
  participates in `Equatable` (two rows differing only by system record are
  NOT equal).

The `@unknown default` fail-closed arm is not directly exercisable (Swift
cannot construct an unknown `CNAuthorizationStatus`) — documented in the
suite as a compile-enforced rule.

## Gate results

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project
  seniOS.xcodeproj -scheme ElderlyAssistant -destination 'platform=iOS
  Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18' -derivedDataPath
  build/DerivedDataTests -skip-testing:ElderlyAssistantUITests` →
  `** TEST BUILD SUCCEEDED **`, exit 0, 0 errors. The log shows
  `SwiftCompile … AddressBookDirectory.swift`, `… MissedCallContactResolver.swift`
  (app target) and `… ContactsAccessTests.swift` (test target). Log kept at
  `ios/build/t148a-typecheck.log` (gitignored). Warnings in the changed files:
  only the pre-existing-in-kind exhaustive-switch warning analysed above; no
  warnings from the resolver, the test file, or the SettingsView arm.
- **Project regeneration:** `xcodegen generate` — pbxproj diff was exactly
  the 4 lines for the new test file at regeneration time; staged surgically
  (the concurrent T-151 agent's later lines left unstaged).
- **Scoped `ContactsAccessTests` run: deferred** to phase end (T-163) per the
  speed-mode directive.
- Static cross-check: marker count across the module = 1 (grep + the scan
  test's logic); `swiftc -parse` clean on all three changed files.

## Decisions

- `AddressBookEntry`'s custom init gained the defaulted `identifier:`
  parameter (not just `make`) so the row is built with its identifier at the
  single construction site — mirrors the `FamilyContact` house pattern of
  defaulted new fields and avoids post-construction mutation. Every existing
  call site compiles unchanged (the design's compile promise), and `make`
  forwards it.
- `allowsReading` is an expression on the enum (`self == .allowed || self ==
  .limited`) exactly as specified — no other formulation.
- The scan marker is `available(iOS 18` (no `#`) — see coverage section.
- The SettingsView arm comment states the T-148b obligation in-code so the
  next unit starts from a marked position.

## Risks / open items

- **T-148b debt (tracked):** SettingsView `searchSection`'s `.limited` arm is
  mechanical — no `call.search.accessLimited` caption, no limited-specific
  affordance yet; plus the untouched equality gates in LeafViews/AppCoordinator
  and the wizard's `refreshSearchAccess`/`grantAccess` load conditions.
- The single-gate pin is intentionally brittle: any later unit adding another
  iOS-18 availability gate in the module fails `ContactsAccessTests` — that is
  the design's §6.4 intent, not a defect.
- `AddressBookEntry`'s synthesized `Equatable` now includes `identifier` —
  behavior-neutral for rows not built from live records (all default `""`),
  and deliberately distinguishing rows that do.
