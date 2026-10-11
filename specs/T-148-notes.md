# T-148 — Voice confirmation: chain-before-prompt and the disclosure clause — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base a5f9f543 = wave 4). Unit: TG-30, wave 5,
risk HIGH, effort M. Depends on T-146; blocks T-149. Requirements: FR-CDP-013, FR-CDP-014,
FR-CDP-016, NFR-CDP-009. Design references: design-l2 §8 (`:474-564`), §13 edit rows 9-11
(`:1013-1015`), §14 (`:1053`), §15 steps 3-8 (`:1061-1071`), §28 (`:1179`), §29 FR-CDP-013/014
(`:1204-1205`). Task spec: `specs/plan-tasks/tasks/TG-30-voice-confirmation-and-launch-fail-hop.md`
T-148 section (`:25-84`).

## Status

**Done — scoped gate green, nothing committed (coordinator records after paired review).**
One production region-set in `AppCoordinator.swift`, one new suite, one mechanical xcodegen
registration (see "Files changed"). No new dependency, no new catalogue key, no new console
write, no network symbol, no ai-sdd command, no commit, no push.

## Files changed

| File | numstat (+/-) |
|------|---------------|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 68 / 20 |
| `ios/ElderlyAssistantTests/App/CallConfirmationWordingTests.swift` (NEW) | 402 lines |
| `ios/seniOS.xcodeproj/project.pbxproj` (mechanical, xcodegen) | 4 / 0 |

The pbxproj delta is `./build.sh generate`'s registration of the new test file only (the
`ElderlyAssistantTests` target globs its directory; three addition lines for the build-file /
file-reference / group entry and one for the Sources phase — the same shape as T-154's
registration). It is not hand-edited and touches no other target. Without it the scoped
`-only-testing` identifier does not exist and the gate cannot run; recorded here because the
file is outside the unit's owned list.

## What was built

### 1. `PendingCallAction` additions (design-l2 §8 `:474-515`, verbatim shapes)

```swift
        /// [INTENTLOG-CAPTURE] When the confirmation question was asked —
        /// the flywheel's latency start. `var` (L2-D3) so the hop's copy
        /// can preserve the ORIGINAL question's clock.
        ///
        /// Still reset when a correction re-pends an amended action: a
        /// construction that omits the field takes the default — the new
        /// question's clock is the one the answer belongs to.
        var requestedAt: Date = Date()
        /// Channels the chain attempted and skipped, in attempt order —
        /// empty when nothing fell back (FR-CDP-008). Drives the prompt
        /// disclosure (FR-CDP-013); never mutated after construction.
        var fellBackFrom: [CallApp] = []
        /// The launch-fail candidates: the attempt order's
        /// vocabulary-filtered suffix after the routed channel
        /// (FR-CDP-015, L2-D1). Empty for touch-shaped constructions and
        /// after an override (the amended action deliberately drops
        /// provenance so a stale disclosure is never re-spoken).
        var hopCandidates: [CallApp] = []
```

`requestedAt` moves from `let` to `var` with its initial value kept: the synthesized memberwise
initializer now exposes it as a defaulted parameter, which is exactly what `replacing` needs and
what keeps every unnamed construction resolving to "now". `capture` is byte-unchanged.

```swift
        /// The hop's re-entry copy (FR-CDP-015; L2-D3/D7): routed method
        /// and remaining candidates replaced; the flywheel pair carries
        /// over; `fellBackFrom` deliberately resets to `[]` (not passed
        /// below) so the hop never re-speaks the disclosure while the
        /// training context survives.
        func replacing(method: CallMethod, hopCandidates: [CallApp]) -> PendingCallAction {
            PendingCallAction(contact: contact,
                              method: method,
                              unsupportedRequestedApp: nil,
                              sourceTranscript: sourceTranscript,
                              sourceCommand: sourceCommand,
                              requestedAt: requestedAt,
                              hopCandidates: hopCandidates)
        }
```

Doc comment and body are the V-3 corrected form from T-144 verbatim (checked against the
T-144 diff to design-l2, `fe0a7576`). The function is unused in this unit by design — T-149's
hop is its only caller.

### 2. `requestCallConfirmation` — chain resolves before the action is pended

The shipped Messenger-no-handle early return (`:7713-7716` pre-edit, spoken
`router.call.messengerNoHandle`) is **removed at that site only**; the block in its place is
design-l2 §8 `:519-547` verbatim:

```swift
        // ADR-CDP-05 step 3: the chain runs BEFORE the action is pended —
        // the feasibility fallback replaces the shipped Messenger-no-
        // handle refusal, so the elder is never asked to yes/no an action
        // that can only fail.
        let intentIsVideo = resolved.method == .facetimeVideo
            || resolved.method == .messengerVideo
        let preferred = CallChannelChain.channel(for: resolved.method)
        let route = Self.resolvedCallChannel(
            explicit: preferred,
            defaultApp: defaultCallApp,
            secondaryApp: secondaryCallApp,
            messengerHandleAvailable: hasUsableMessengerHandle(contact.messengerHandle),
            whatsAppInstalled: whatsAppInstalledNow)
        let action = PendingCallAction(contact: contact,
                                       method: CallChannelChain.method(for: route.channel,
                                                                       isVideo: intentIsVideo),
                                       unsupportedRequestedApp: resolved.unsupportedRequestedApp,
                                       sourceTranscript: sourceTranscript,
                                       sourceCommand: sourceCommand,
                                       fellBackFrom: route.fellBackFrom,
                                       hopCandidates: CallChannelChain.hopCandidates(
                                           preferred: preferred,
                                           secondary: secondaryCallApp,
                                           routed: route.channel))
```

Steps 1-2 (contact resolution incl. the near-miss retry, `methodResolver.resolve`) are
untouched; `repetitionGuard`, `openConfirmationWindow()` and the near-miss prefix are
untouched. The shipped refusal line survives at its other sites, all untouched: the override
gate (`:7794`), the system-contact Messenger flow (`:7940-7941`), the row stale-state guard
(`LeafViews.swift:1578`), `LeafViews.swift:1996` and `HistoryView.swift:211`.

### 3. `confirmationPrompt` — disclosure clause, after the notices and before the method sentence

```swift
        if let skipped = action.fellBackFrom.first {
            parts.append(L10n.fmt("router.call.fallbackDisclosure", locale: locale,
                                  CallChannelChain.label(skipped, locale: locale),
                                  action.contact.name,
                                  CallChannelChain.label(
                                      CallChannelChain.channel(for: action.method),
                                      locale: locale)))
        }
```

Design-l2 §8 `:551-559` verbatim; it sits between the unsupported-app notice and the
method-key switch, so the utterance order is `[near-miss prefix][repeat notice][unsupported-app
notice][fallback disclosure][method sentence][confirm question]` (design §15 step 5). The
routed label derives from the routed `action.method`, never the skip. The key is T-155's
existing `router.call.fallbackDisclosure` (`%1$@` skipped label, `%2$@` contact name, `%3$@`
routed label — the listing's argument order matches the catalog contract exactly).

### 4. New suite — `ios/ElderlyAssistantTests/App/CallConfirmationWordingTests.swift`

MainActor-scoped like its neighbours; coordinator constructed with the house in-memory
payload store; the real `appLanguage` seam is seeded before construction and snapshotted /
restored around every test (no didSet side-effect). The prompt is driven with a CONSTRUCTED
`PendingCallAction` through the real catalog — the design §28 seam. Four tests, all four
scenarios' wordings in **both** locales:

| Test | What it pins |
|------|--------------|
| `testDisclosureNamesSkippedAndRouted` | The clause carries the skipped label (`fellBackFrom.first`, not a later candidate), the contact name and the routed label in the catalog's slots; the question still names the routed channel; the disclosure is spoken before the question. Two routed cases (phone floor and whatsAppChat) so the routed label cannot pass by accident. |
| `testNoFallbackKeepsPromptByteIdentical` | Empty provenance composes exactly `[repeat][unsupported][question]` with single-space joins — equality against the shipped composition (baseline `eafa4bcc`, unchanged through the W4 point), for the bare, repeat, unsupported and combined cases. |
| `testOverrideGateUntouchedPin` | Comment-stripped source pin over the override function: the no-handle gate with its `return true`, the amended construction (exact token sequence, count 1), the `.corrected` capture with `path: "override"`, exactly one re-confirmation, and NO `fellBackFrom`/`hopCandidates`/`requestedAt` anywhere in the region. |
| `testNewRegionsAddNoKeysOrConsoleWrites` | No console write pattern (`print|debugPrint|NSLog|os_log|fputs(`) and no `observabilityBus.emit` in either new region (speech only); the prompt's key surface is exactly the shipped nine keys plus the existing disclosure key; the disclosure key resolves in both locales; `requestCallConfirmation` no longer contains `router.call.messengerNoHandle`; step 3 resolves through the shared chain seam. |

## Gate

Command (from the worktree root): `ios/build.sh test:unit CallConfirmationWordingTests CallChannelResolutionTests`

- Exit code: 0 — `=== Scoped unit run passed (baseline not advanced) ===`, `** TEST SUCCEEDED **`
- `Selected tests` / xctest bundle: **Executed 30 tests, with 0 failures (0 unexpected)** —
  `CallConfirmationWordingTests` 4/4 passed, `CallChannelResolutionTests` 26/26 passed
  (regression check only; T-149/T-150 own that file and it was not modified).
- xcresult (authoritative pass list): `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_05-58-37-+1100.xcresult`
  (`passedTests: 30, failedTests: 0, result: "Passed"` via `xcresulttool`).
- Retained log: `ios/build/t148-gate.log` (same command, `tee`d).
- In-build guards, both green **before** the tests: privacy guard
  (`Services/Calls` root included; 24 fixtures over 12 rules, every case behaved) and the
  intent-prompt mirror guard (seed mirrors `IntentPrompt.build` byte-for-byte, 2717 bytes,
  4 placeholders; all 7 drift self-tests rejected).
- No build-database lock contention occurred; no retry needed.
- Override diff-cleanliness independently re-checked against HEAD:
  `git show HEAD:… | awk`-extracted body vs worktree — **byte-identical, 31 lines**.

## Deviations from the design listings (with reason)

1. **`confirmationPrompt` access: `private` → internal.** The design's §28 test home is this
   separate suite, and the seam §28 names IS `confirmationPrompt` driven "via the real
   catalog". A `private` member is unreachable from another file, so the function is now
   internal with a doc comment recording why ("Internal (not private) so the wording pins can
   drive it with a constructed action against the real catalog (design-l2 §28)") — the house
   convention used by `ChatHistoryStore`, `LogSanitiser` and `GeminiCostGovernor`. No
   behaviour, signature or body change; the design listing itself does not pin the modifier.
   The alternative (driving the full `requestCallConfirmation` end-to-end) is not available in
   the unit bundle: `familyContacts` is `private(set)` and only the real encrypted contact
   store populates it — no test in the repo seeds contacts, and doing so would write through
   the real store and depend on a main-queue hop.
2. **`requestedAt` doc comment is a superset of the design's.** The design listing's three
   lines are kept verbatim; one paragraph is appended because `var` + default *preserves* the
   shipped reset-on-correction clock semantics (the override construction omits the field, so
   its default is evaluated at that construction) and dropping the shipped comment would have
   deleted the only documentation of that fact.
3. **Anchors had shifted.** The design's and brief's line numbers (:7518-7550, :7620-7623,
   :7688-7709, :7656-7686) predate W3/W4. Actual pre-edit anchors: struct `:7611`,
   early return `:7713-7716`, override `:7749-7781`, `confirmationPrompt` `:7781`. Everything
   was located by content, not line number. Post-edit anchors: fields `:7631/:7635/:7641`,
   `replacing` `:7661`, step 3 `:7732`, override `:7783`, `confirmationPrompt` `:7821`,
   disclosure `:7830`.
4. Nothing else deviates: the three listing bodies (fields, `replacing`, step 3, disclosure)
   are verbatim, including comments.

## Notes for the paired challenger

1. **The access relaxation (deviation 1) is the one judgement call** — probe whether any other
   in-repo seam would have served; the driver for it is design §28's own test row.
2. **Scenario 3 of the Gherkin ("a messenger preference without a handle no longer
   early-returns") has no behavioural in-suite execution.** Contacts are not injectable into
   the unit bundle (see deviation 1). Evidence here: the source pin (the refusal key is absent
   from the whole `requestCallConfirmation` region; step 3 calls `resolvedCallChannel` with
   `hasUsableMessengerHandle`) plus the resolution suite's messenger-without-handle matrix
   cells (26/26 green). The end-to-end "slot holds the resolved action" observation is
   T-149/DV territory and is not claimed here.
3. **Near-miss prefix + disclosure composition** (FR-CDP-014 scenario 3) is not asserted as a
   combined string: the prefix concatenation (`prefix + " " + prompt`) is untouched and the
   clause is compositional; a challenger may want a combined-utterance pin in T-149.
4. **The four shipped labelled constructions**: the override construction and both
   `IntentLogStoreTests` constructions compile without naming the new fields (the gate's test
   bundle build is the proof); the `requestCallConfirmation` construction now names
   `fellBackFrom`/`hopCandidates` — that is this unit's design edit (#10). T-149's
   additive-fields pin should reference this state, not the pre-T-148 one.
5. **`hopCandidates` is written but not consumed here** (T-149's hop reads it) — the value is
   pinned only by construction in this unit; the resolution suite pins the static list.

## Definition of done

- [x] Chain resolves before the pending action; the early return is removed only at the named
      site (source-pinned; the refusal lines at the override gate, system-contact flow and
      leaf guards are untouched and the override body is byte-identical to HEAD)
- [x] Prompt disclosure names the skipped and routed channels; empty provenance is
      byte-identical (pinned, both locales)
- [x] Override block, gate and amended-action construction diff-clean; pinned test green
- [x] Scoped run green: `ios/build.sh test:unit CallConfirmationWordingTests CallChannelResolutionTests`
- [x] No PII in logs; no new console writes (source-pinned; both in-build guards green)
- [ ] Code reviewed and merged — coordinator's paired review + integration commit
