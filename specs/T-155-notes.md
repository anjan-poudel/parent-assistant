# T-155 — FEATURE_ROOTS registration + release-gate coverage — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify`
(branch `feat/family-contacts-unify`). Unit: TG-31 "write seam and coordinator
integration" — release-gate wiring. Agent: dev. Design references: design-l2
§5.2 (logging rules per file), §5.3 (release-gate wiring — the exact
`FEATURE_ROOTS` block), §8.2 (placement table). Requirements: NFR-FCU-002
(PII log safety), NFR-FCU-009 (test and release gates). Speed mode: implement +
whole-module typecheck + commit; no scoped suite run, no push.

## Status

**Done** — the three new seam files are registered in `FEATURE_ROOTS` under
the stricter "feature" role, the gate passes over the current feature tree
(no seam-file fix was needed), the fixture harness passes unchanged in shape
(24 cases / 12 rules) and now pins each new root, whole-module typecheck
**GREEN** (attempt 2; attempt 1 was red on a concurrent dev's mid-wave edit,
see "Gate results"), committed (no push).

## Files changed

- `ios/tools/check-release-log-safety.py` (+7) — the design-l2 §5.3 block
  appended to `FEATURE_ROOTS`: `Services/Contacts/SystemContactLinkService.swift`,
  `Services/Contacts/SystemContactPhotoWriter.swift`,
  `Services/Contacts/FamilyContactIndex.swift`, with the feature's rationale
  comment citing design-l2 §5.2 (the existing per-entry bracket style; the
  comment block is the design's own text). No rule code, no docstring change —
  the established pattern for a root extension is entry + comment only.
- `ios/tools/log-safety-fixtures/feature-console-write/positive/ElderlyAssistant/Services/Contacts/`
  (3 **NEW** fixture files) — one content-free, Release-compiled console write
  planted at each new root's exact path.
- `ios/tools/log-safety-fixtures/feature-console-write/negative/ElderlyAssistant/Services/Contacts/`
  (3 **NEW** fixture files) — the clean twins: identical paths, no console
  write, no event field.
- `ios/tools/log-safety-fixtures/feature-console-write/positive/expect` (+3) —
  each new path pinned as output the gate must name (the drift detector: a
  typo'd/unregistered path would leave its plant scanned as an ordinary file
  and unnamed, and the case would fail with "the planted file was not the one
  caught").
- `specs/T-155-notes.md` (this file).

Nothing under `ios/ElderlyAssistant/` was touched: the gate run over the
current tree passed as-is, so no violating line needed fixing.

## What was built

### 1. Registration (design-l2 §5.3)

The three roots are registered **per file**, not as a `Services/Contacts`
directory root: that group is mixed — it also carries the pre-existing
`AddressBookDirectory`, `MissedCallContactResolver`, `UnifiedContactSearch`
(a touched-in-place file with pre-existing console writes, deliberately
outside the feature role) and the other feature-era files. The three new
files are the feature's own new code, exactly as §8.2's placement table
lists them; every new source file the feature adds is registered, no
exemptions were needed.

The "feature" role engages rules 3-6 over these files: any console write
compiled into Release fails whatever it renders; a content-worded console
write fails in any configuration; an event metadata key must be in
`LogSanitiser.allowedKeys`; an event field must not be content-bearing. The
shipped seam code already complies (bus-only diagnostics: §5.2's closed
vocabularies; keys `entry_count`/`state` are allow-listed). The gate run is
the evidence, not the claim.

### 2. Fixtures (the scan actually covers the registered roots)

Each positive plant is content-free on purpose so the tree trips
`feature-console-write` and nothing else; the negative twin proves the roots
scan clean sources quietly (a new path alone must not fail the gate). This is
the Dialogue/precedent shape for a root extension, one plant per registered
path so a typo in ANY single entry is caught.

## Gate results

- **Gate over the real tree: PASS.** `python3 ios/tools/check-release-log-safety.py`
  → exit 0, no findings, with the three new roots classified as feature
  sources.
- **Full gate, as `build.sh` calls it: PASS.** `bash ios/tools/check-release-log-safety.sh`
  → exit 0: engine verdict + the fixture suite (24 cases over 12 rules, every
  rule's positive and negative behaving).
- **Injected-PII fixture fails and names the file and line** (T-155's
  positive scenario): the engine over the fixture tree reports, e.g.
  `ElderlyAssistant/Services/Contacts/SystemContactLinkService.swift:18: [feature-console-write] …`,
  `…/SystemContactPhotoWriter.swift:15`, `…/FamilyContactIndex.swift:15` — and
  the harness case passes only because each named path is the `expect` token.
- **Falsification:** `check-release-log-safety-fixtures.py --falsify --only feature-console-write`
  → with the rule disabled the positive tree passes ⇒ the three new plants are
  load-bearing on rule 3 alone (no other rule fires on them).
- **Registration drift is caught** (T-155's third scenario): proven in an
  isolated copy of the tools tree — removing
  `Services/Contacts/SystemContactPhotoWriter.swift` from `FEATURE_ROOTS` made
  the gate miss that plant and the harness failed with "the gate fired but did
  not name ['Services/Contacts/SystemContactPhotoWriter.swift'] — the planted
  file was not the one caught". In the repo the same class of drift is caught
  by the `expect` pins; no separate bespoke "registration check" was added —
  the design (§5.3) prescribes exactly this registration + fixture wiring, and
  the harness contract (a rule = a positive + a negative fixture) is the
  mechanism the `expect` file was introduced for ("that a planted violation in
  a newly added scan root is the one reported").
- **Reason-code lines are not flagged** (failure-path scenario): the seam
  files carry no console writes at all; their raw-value reason codes appear
  only as event `errorCode` values (`SystemContactPhotoWriter.swift:467`,
  `SystemContactLinkService.swift:415`), which rule 6 judges for content —
  none is content-worded or error-object-derived, so the clean-tree exit 0
  above is that evidence.
- **`ios/build.sh` wiring unchanged**: `run_tests()` calls
  `tools/check-release-log-safety.sh` at `build.sh:431`, ahead of every
  `xcodebuild test` scope (the ordering is also pinned by
  `SecurityEvidenceIndexTests.testAM5…`). The fixture tree files are not
  compiled: `tools/` is not in the XcodeGen source globs and `project.pbxproj`
  contains zero `log-safety-fixtures` references.
- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project
  seniOS.xcodeproj -scheme ElderlyAssistant -destination
  'platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18'
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`
  → `** TEST BUILD SUCCEEDED **`, exit 0, 0 errors (log
  `ios/build/t155-typecheck2.log`, git-ignored). Attempt 1
  (`t155-typecheck.log`) failed with 64 errors — **all** in
  `ElderlyAssistantTests/Services/Contacts/UnifiedContactSearchTests.swift`,
  none in any file of this unit: the concurrent T-150 wave had just saved its
  production `UnifiedContactSearch.swift` (+220 lines, mtime 08:17:07) while
  the committed test file still matched the old API. Per the contention
  protocol I waited for the peer's test rewrite to settle (mtime 08:20:39) and
  retried; attempt 2 built the current tree clean. This change is
  python/tooling + uncompiled fixtures, so it cannot affect compilation
  (the app target compiled in both attempts).
- **Scoped suite run: deferred** to phase end (T-163) per the speed-mode
  directive.

## Decisions

1. **The design's comment block verbatim** (§5.3) — it cites design-l2 §5.2
   and matches the existing per-entry bracket style.
2. **Three plants + three expect pins, in `feature-console-write` only.** No
   `feature-content-print` plant for these roots: that rule's content
   vocabulary is the recognized/translated-text family, and a contact name is
   not in it — a plant there would be artificial. Rule 4 still covers these
   files (any known content word in any configuration), but the true
   protection for contact PII is rule 3 (no Release console write at all,
   whatever it renders) plus the metadata rules, which is what the design's
   §5.2 rule-3 framing says.
3. **Entry registered per file, not as a directory** — see "What was built"
   §1; a directory root would have pulled pre-existing console-writing files
   into the feature role and failed the gate for code this feature does not
   own.
4. **No engine/docstring/README changes.** The docstring and harness README
   describe the rule family, not the root list; earlier extensions (Point-Ask,
   Profile-Interview, Spotify, Dialogue) likewise landed as entries + comment.

## Deviations

None from the assignment (expected none). One **documented-limitation
observation**, recorded rather than fixed (out of scope, and it is a property
of the shipped rule family, not of this wiring): rule 3 keeps the shipped
Release framing, so a hypothetical `#if DEBUG` console write of a contact
name inside these files would not be flagged — the content vocabulary
(`text`/`transcript`/`translation`/`recognized`/`prompt`) does not contain
name/nickname words, and the design's §5.2 prose ("no console writes at all")
is stronger than a source gate can enforce inside a Debug region. The shipped
seam files contain no console write at all in any region (also pinned at
source level by `SystemContactLinkServiceTests.testServiceFileHasNoConsoleWrites`
and its siblings), so the shipped state is conformant; the gap is only in the
gate's ability to see a future Debug-only name print. This is the same class
of documented limitation the engine docstring already states ("a green gate
means 'no defect of these shapes is present in these files'").

## Risks / open items

- The `expect` pins keep the drift detection honest only as long as future
  roots are added with a plant; that is the harness's documented contract for
  newly added scan roots, not a new obligation invented here.
- Concurrent-dev contention in the shared worktree: the tree was red for ~4
  minutes between T-150's production save (08:17:07) and its test rewrite
  (08:20:39) — the attempt-1 failure is that window, not this unit.
