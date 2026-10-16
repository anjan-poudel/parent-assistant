# T-173 notes — CloudChatRouting: the single fail-closed routing decision

**Status:** complete, scoped suite green (15/15). Declared files only; nothing committed.
**Branch/worktree:** `feat/conversational-nepali-replies` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`

## Files written (the declared set, exactly)

| File | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift` | new: `CloudChatRouting` — `ChatRoute` (`.cloud` / `.local(reason:)`, with nested `LocalReason`), the injected `Inputs` seam, and the decision (`decide(_ inputs:)` + the pure value core `decide(consent:online:keyConfigured:costAllows:)`). |
| `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatRoutingTests.swift` | new: 15 tests — the 32-cell table, precedence, per-state reasons, per-turn revocation through the real gate, the fail-closed seam table (12 exact cells + all 81 unknown-input combinations), the router-shape fit, determinism, and the source-hygiene scans. |

No other file was modified by this unit. `git status` shows the other dirty paths belong to concurrent units (T-167/T-168/T-175 in flight); `CloudChatConsentGate.swift`, the router and the coordinator were not touched. No commits.

## What was built

### Shape (design §8.1; declared contract)

`enum CloudChatRouting` holds:

- `enum ChatRoute: Equatable { case cloud; case local(reason: LocalReason) }` with
  `enum LocalReason: String, Equatable, CaseIterable { consentNotRecorded, consentDenied, consentRevoked, consentUnreadable, offline, keyMissing, costBlocked }` — the design's closed vocabulary, pinned by test. Raw values are the case names; **the file contains no string literal at all** (pinned by source scan), so even a reason used as a telemetry token carries a member of this vocabulary and nothing else.
- `struct Inputs` — the injected seam: four optional closures
  `consent: (() throws -> CloudChatConsentGate.Decision?)?`,
  `online / keyConfigured / costAllows: (() throws -> Bool?)?`,
  all defaulting to `nil` so `Inputs()` compiles at every pre-feature construction site and selects local, honestly. The router's existing readiness closures (`(() -> Bool)?`, `IntentRouter` :107-108) slot in unchanged — asserted by a compile-level test that builds the seam from `geminiKeyConfigured` / `geminiCostAllows`-shaped closures. `online` follows the LiveTranslate reachability discipline: not known to be reachable reads as not reachable.
- `static func decide(_ inputs: Inputs) -> ChatRoute` — reads every closure **now**, caches nothing, resolves each read to a definite value, and delegates to
- `static func decide(consent:online:keyConfigured:costAllows:) -> ChatRoute` — the pure core and the single body in which the precedence lives (so the seam cannot drift from it): `.cloud` requires all four yeses; otherwise the reason names the **first blocking input** in the fixed order consent → online → key → cost. `nonGrantedReason(for:)` has no `default:` — a fifth gate state would fail to compile rather than silently map.

### Fail-closed resolution (totality is the safety argument)

Every read is total; no input state can reach `.cloud`:

| Input | absent closure | returns nil | throws |
|---|---|---|---|
| consent | `consentNotRecorded` ("nothing recorded" is the truth about a missing input — the gate's own "a store that cannot answer holds nothing" reading) | `consentNotRecorded` | `consentUnreadable` (the read did not complete — a different failure with its own owner action, never collapsed) |
| online | `offline` | `offline` | `offline` |
| keyConfigured | `keyMissing` | `keyMissing` | `keyMissing` |
| costAllows | `costBlocked` | `costBlocked` | `costBlocked` |

### `consentRevoked` — the honest reconciliation with the gate's actual API

**The gate cannot surface revocation as a distinct readable state.** `CloudChatConsentGate.Decision.denied` is documented as "the elder declined, or revoked": a decline and a withdrawal both set `deniesInMemory`, and the revocation tombstone is a `granted: false` record — all of them read back as `.denied` (and a *successful* revocation that deleted the record reads back as `.notRecorded` on a relaunch). There is no API that distinguishes them, and a second source that claimed to would be the parallel consent store the design forbids.

So the mapping encoded is: `.notRecorded → consentNotRecorded`, `.denied → consentDenied`, `.unreadable → consentUnreadable`, `.granted → (continue)`. **`decide` never returns `consentRevoked`** — a routing read that named every `.denied` a revocation would misname every decline. The case stays in the vocabulary (design §8.1 declares it) as the token the **revocation surfaces** use when they performed the withdrawal and know so (the Settings row / voice revoke, T-177; the gate's own write path already distinguishes `consent_revoked` from `consent_denied`). This is documented in the source and pinned by test: the revocation-per-turn test asserts `.local(reason: .consentDenied)` and the 32-cell loop asserts the reason is never fabricated as a revocation.

### Per-turn read, no cache

Both `decide` overloads are pure and hold no state; the gate re-derives from storage on every read. Tested through the real gate (grant → `.cloud`; `revoke()` → same `Inputs` value → `.local(.consentDenied)`), plus the tombstone/relaunch variants (`.denied` / `.notRecorded` — never cloud) and a corrupt-record case (`.consentUnreadable` on the very next turn).

### Deliberately not done (scope fence)

No router/coordinator wiring (T-175/T-177), no guard flag resolution (T-174), no prompt/indicator. The type has no logging, no transport, no model, no UI, and **no import at all** — the decision is the language plus the gate's decision type, so there is no reachable I/O primitive. No content and no identity can travel: the reasons are structural tokens.

## Tests

Command (from the worktree's `ios/`):

```
./build.sh test:unit CloudChatRoutingTests
```

Result (final run): **15 tests executed, 0 failures, 0 skipped — TEST SUCCEEDED.**
xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_20-23-06-+1100.xcresult` (device: iPhone 17 Pro simulator, iOS 26.5; scoped run — the impact baseline is not advanced).

Coverage against the acceptance criteria:

- **The single yes:** `.cloud` iff granted + online + key + cost, incl. the exact `Inputs` seam wired to the real gate.
- **Every other cell:** all 4 × 2 × 2 × 2 = 32 cells (the design's "sixteen" taken at the consent axis's full width of four readable states) compared against an independently written oracle; exactly one cloud cell, and it is `granted/true/true/true`.
- **First blocking input:** consent outranks offline/key/cost; offline outranks key/cost; key outranks cost — each pinned with everything else also blocking.
- **Truthful consent reasons:** notRecorded/denied/unreadable pairwise distinct and never cloud.
- **Per-turn read:** revocation between two decisions flips the route (no cached route in the seam or the gate); tombstone and relaunch variants; corrupt-record variant.
- **Failure paths:** 12 exact cells (4 inputs × absent/nil/throwing) with their expected reasons, plus all 81 = 3⁴ combinations of unknown inputs asserting *never cloud*; the default `Inputs()` and a readiness-only site both select local.
- **Classification only:** no string literal, no print/NSLog/os_log, no transport, no model, no bus, no UI tokens in the routing source; the reason vocabulary pinned as the closed set.

Branch/statement coverage: the scheme's result bundle carries no coverage data; every executable line of the new file is exercised by construction (both `decide` bodies, all four resolution paths, all four switch cases, both overlay paths of `resolvedAllowance`).

## Deviations, assumptions, blockers

1. **`consentRevoked` is declared but never produced by `decide`** — the reconciliation above; the design's reason set is preserved and the gate stays the single consent source.
2. **"Sixteen cells" is tested as 32.** The consent axis has four readable states, not a granted/not-granted dichotomy; the 32-cell table strictly contains the sixteen and still yields exactly one cloud.
3. **Seam shape:** closures are `throws`/optional-returning (the superset of the router's `(() -> Bool)?` shape) so the contract's three failure modes — absent, returns no value, throws — are all expressible and all fail closed. `Inputs` is nested in `CloudChatRouting`; consumers write `CloudChatRouting.Inputs(...)` and switch on `CloudChatRouting.ChatRoute`.
4. **Build contention (not a blocker):** one earlier run failed on a *concurrent* agent's in-flight untracked `CloudChatResponderTests.swift` (`Cannot find 'assertByteIdentical'` ×4) while that file was mid-edit; the retry after it landed compiled and the suite passed. The canonical `./build.sh test:unit` runs XcodeGen, so the generated `ios/seniOS.xcodeproj/project.pbxproj` was regenerated as usual (generated artifact, shared with the concurrent units) — no hand edits to it.
5. For the next units: T-175/T-174 call `CloudChatRouting.decide(inputs)` and switch on the route; T-177 wires `Inputs(consent: { gate.currentDecision() }, online: { reachability }, keyConfigured:, costAllows:)` — the coordinator owns the gate lifecycle; `LocalReason.consentRevoked` is available to the revocation surfaces' classification, not to the routing read.
