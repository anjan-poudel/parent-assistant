# T-128 — Barge-in predicate access widenings (L2-D2) — implementation notes

Status: COMPLETE — implementation + focused tests authored and independently
verified (standalone harness, all fixtures green); the scoped `build.sh`
focused-suite run is BLOCKED at module compile by a cross-unit file (T-125's
`DialogueManager.swift` referencing the W2 type `DialogueMerge`) — three
attempts, all with identical sibling-only diagnostics; see "Gate".
Worktree: `elderly-ai-assistant-multi-turn-conversation`, branch
`feat/multi-turn-conversation`. Date: 2026-10-10. No git/ai-sdd commands run;
no console output added.

## What was built

Exactly design-l2's L2-D2 ("Two barge-in vocabularies are widened `private` →
`internal`") — two surgical visibility changes, both on existing declarations
whose bodies are byte-identical after the change:

1. **`ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`** — `sensitiveCallPhrases`
   (`:1869` baseline): `private static let` → `static let` (internal), per
   design-l2 §12.4 edit 8, with an extraction comment citing the shipped call
   sites (`:1360` topic-pre-answer self-exclusion, `:1973-1980` the
   `router.sensitiveBlocked` block, `containsPhrase` semantics `:1826`) and the
   `isExplicitMedicationAcknowledgement` `:1913` precedent. The list literal is
   untouched.
2. **`ios/ElderlyAssistant/Services/Voice/VoiceContactSearchRoute.swift`** —
   `isDirectCallUtterance` (`:137-140` baseline): `private static func` →
   `static func` (internal), per design C-MTC-08b, doc noting the second call
   site (dialogue barge-in B3) and the **unchanged lowercase-input contract**
   (the caller passes canonical text; `decide(transcript:)` lowercases at `:68`
   before its veto `:74`; the tester folds no case itself). Body untouched.

The medication-acknowledgement check `isExplicitMedicationAcknowledgement`
(`:1913`) is already internal at baseline (verified: security-design-review
ledger row 6), so B1 needed no edit — only the two widenings above.

No renames, no moved files, no signature changes, no body edits, no call-site
moves. No new console writes anywhere in the diff (security-design-review V-2:
the diff adds no console write to the touched legacy files).

## Tests added (Gherkin coverage)

Added to the existing contact-search suite —
`ios/ElderlyAssistantTests/Services/Voice/VoiceContactSearchRouteTests.swift`,
class `VoiceContactSearchRouteTests` (two new tests; no existing test modified):

| Gherkin scenario | Test |
|---|---|
| 1: "The answer path can consume the predicate surfaces — the same boolean results as the shipped call sites are returned" | `testWidenedBargeInPredicatesMatchTheShippedCallSites` — B1 (`isExplicitMedicationAcknowledgement` ack true / denial false), B2 (`CommandRouter.sensitiveCallPhrases.contains { text.contains($0) }` — the exact expression design-l2 pins for B2 — on the router's own doc fixture "मौसम बताउने मान्छेलाई फोन गर" true, plain-topic "आज मौसम कस्तो छ" false), B3 (`isDirectCallUtterance("फोन नम्बर लगाऊ")` true + shipped `decide` equals `.notSearch` + `extractQuery` baseline artifact "लगाऊ" shows the veto, not absence of a search, decided the outcome) |
| 2: "Existing behaviour is unchanged — every test passes unmodified; `isDirectCallUtterance` keeps its documented lowercase-input contract" | the existing router + contact-search suites run unmodified against the widened declarations (no test edited); the contract line is pinned by `testDirectCallTesterKeepsItsLowercaseInputContract` — canonical "call maiya" true, mixed-case "CALL MAIYA'S NUMBER" false (no case folding inside), same utterance still vetoed through `decide` (the shipped call site canonicalises first) |

Compile-level widening proof: the new tests reference the two symbols from
outside the declaring types; `private` is file-scoped, and the test module's
`@testable import` reaches `internal` only — the test target compiles at all
only because the widenings landed. The symbols are consumed exactly as the
design's call sites will (design-l2 §"Barge-in (pinned)": B2
`CommandRouter.sensitiveCallPhrases.contains { text.contains($0) }`; B3
`VoiceContactSearchRoute.isDirectCallUtterance(text)`).

## Independent verification beyond the suite

- `swiftc -frontend -parse` on all three changed files: clean (no syntax
  errors).
- Standalone harness compile + run (in /tmp, not part of the repo): compiled
  the real `VoiceContactSearchRoute.swift` + `KeywordIntentRule.swift` +
  `NepaliTextNormalizer.swift` together (unrelated heavy deps stubbed:
  `AppLauncher`, `NepaliFestivalCatalog`, `ContactResolver.relationshipAnchors`)
  and executed every fixture boolean the new tests assert — **8/8 PASS**,
  including the cross-file consumption of the widened
  `isDirectCallUtterance` (the harness calls it from outside the declaring
  type, which is only possible post-widening), `extractQuery("फोन नम्बर लगाऊ")
  == "लगाऊ"`, and `decide("CALL MAIYA'S NUMBER") == .notSearch`.

## Gate

Focused suites per the DoD: `VoiceContactSearchRouteTests` + `CommandRouterTests`
(router suite that owns the shipped `.blockedSensitiveAction` outcome the B2
comment cross-references), run via the serialized lock protocol:

```
./build.sh test:unit VoiceContactSearchRouteTests CommandRouterTests
```

Result: **BLOCKED at module compile — no tests executed** (rc=65,
"Testing cancelled because the build failed"), across three attempts under the
shared build lock (14:35, 14:42, 15:24). The failures are entirely sibling-unit
errors, not T-128's; details below.

### Cross-unit blocker (not owned by T-128)

All attempts failed with exactly two module-compile errors, both in
`ios/ElderlyAssistant/Services/Voice/DialogueManager.swift` (T-125's file,
unmodified since 14:28 throughout every attempt):

```
Cannot find type 'DialogueMerge' in scope          (DialogueManager.swift:141, case answered(DialogueMerge))
Type 'DialogueFrameResolution' does not conform to protocol 'Equatable'   (cascade of the missing type)
```

`DialogueMerge` is a C-MTC-02 type (design-l2 §7: T-131's
`DialogueAnswerPath.swift`, wave W2); T-125's W1 file references it before it
exists, so the app module cannot compile until that cross-unit reference is
resolved by the owning unit (or the orchestrator). No file of mine is among
the failing diagnostics; my three files parse clean and the standalone harness
(type-checking the real route file) passes. Per instruction: cross-unit
mid-edit failures are retried, not fixed — the suite run must be re-driven
once `DialogueManager.swift` compiles (a 28-minute poll from 14:55–15:23 saw
no change on the sibling file; the worktree was otherwise idle).

## Open items for downstream tasks

- T-131 consumes the widened surfaces (B1/B2/B3) directly — one table, never
  duplicated (NFR-MTC-012 single-source parity). Verified there is no
  pre-existing external user of either symbol (grep over `ios/`: only comment
  mentions), so the widening could not change any current caller.
- Line numbers cited in the new comments are baseline numbers (matching
  design-l2's citations), unchanged semantics.
