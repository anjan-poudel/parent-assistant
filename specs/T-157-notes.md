# T-157 — Final integration and release-evidence sweep (unit report)

Feature: call-dialer-primary-secondary · Group TG-32 · Final barrier (plan `final: true`)
Unit owner: dev agent · Base for this unit: `4f17049a` (W9 T-153 commit) on `feat/call-dialer-primary-secondary`
Merge-base with master: `8089c735c679ecb70bd5ca0f04989271a082a2f0`

**Verdict.** Every scoped suite of the feature family passes on the final authoritative
sweep (Passed 136/136/0/0), the privacy guard exits zero both in-build and in a direct
formal re-run, the preservation audit shows zero drift on SA-4/SA-7 anchors, the five
catalogue keys prove parity and exclusivity, and the four planned negative controls
(one W8, three W9) each failed exactly the pins they were designed to fail, with every
control restored byte-identically (md5-verified). The feature is ready for the
end-stage review/security-test pass and the owner's DV-1..7 device run (§7). Nothing
was committed in this unit (per the brief); no ai-sdd CLI command was run; the main
checkout was never touched.

---

## 1. Sweep of record

### 1.1 Final authoritative family sweep (the sweep of record)

Command (exactly the task-file scope, run from the worktree root):

```
ios/build.sh test:unit CallChannelResolutionTests MethodResolverTests MissedCallDialBackTests \
  ContactCallButtonsTests CallingSettingsSurfaceTests CallConfirmationWordingTests L10nCatalogCoverageTests
```

- Log: `ios/build/t157-final-sweep.log` — exit 0
- Bundle: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_08-10-43-+1100.xcresult`
- Result: Passed, 136/136/0/0
- Per suite: CallChannelResolutionTests 45 · MethodResolverTests 17 · MissedCallDialBackTests 22 ·
  ContactCallButtonsTests 25 · CallingSettingsSurfaceTests 7 · CallConfirmationWordingTests 4 ·
  L10nCatalogCoverageTests 16
- In-build guards (run by `build.sh` before every test scope, this run included):
  - `ios/tools/check-release-log-safety.sh` — green.
  - `ios/tools/check-prompt-mirror.sh` — green: "the seed mirrors IntentPrompt.build
    byte-for-byte (2717 bytes, 4 placeholders)" and all 7 self-test drifts rejected
    ("every drift class is rejected; the gate is load-bearing").

### 1.2 First green sweep (pre-pin baseline)

- Command: same seven-suite scope.
- Log: `ios/build/t157-sweep.log` — exit 0.
- Bundle: `Test-ElderlyAssistant-2026.10.12_07-46-17-+1100.xcresult` — Passed, 134/134/0/0.
- Suites: CallChannelResolutionTests 43 · MethodResolverTests 17 · MissedCallDialBackTests 22 ·
  ContactCallButtonsTests 25 · CallingSettingsSurfaceTests 7 · CallConfirmationWordingTests 4 ·
  L10nCatalogCoverageTests 16.
- This run is the first execution of every W8/W9-authored test (§11).

### 1.3 Pins rerun (after the Part B pins landed)

- Log: `ios/build/t157-pins-rerun.log` (first pins run) and `ios/build/t157-pins-rerun2.log` (repaired).
- Bundles: `Test-ElderlyAssistant-2026.10.12_07-50-01-+1100.xcresult` (Failed 67 tests,
  65 passed / 2 failed — the two new pins, on my own expectation error; see §11.3) and
  `Test-ElderlyAssistant-2026.10.12_07-54-40-+1100.xcresult` (Passed 67/67/0/0:
  CallChannelResolutionTests 45 = 43 + 2 new pins · MissedCallDialBackTests 22 with the
  new §10.4 audio-vocabulary leg inside the existing hop-candidate test).

### 1.4 Direct privacy-guard run (formal gate re-run)

- Invocation (as `ios/build.sh` runs it): the guard script `ios/tools/check-release-log-safety.sh`
  / `ios/tools/check-release-log-safety.py` from the worktree root.
- Log: `ios/build/t157-privacy-guard.log`; exit 0 (recorded as GUARD_EXIT=0 at run time).
- Summary line (verbatim): "no transcript content or raw error object can be printed in
  a non-Debug configuration, and the live-camera-translation sources carry no console
  write or content-bearing event field". Fixtures: "log-safety fixtures: 24 case(s) over
  12 rule(s)" — all positive/negative fixtures behaved ("every rule has a positive and a
  negative fixture, and every fixture behaves").
- Feature-root registration (T-156, re-verified here): `Services/Calls` is present in
  `FEATURE_ROOTS` at `ios/tools/check-release-log-safety.py:197`, so `CallChannelChain.swift`
  is graded feature-role and the new write-rules apply to it.

### 1.5 Worktree context

The sweep ran in this feature worktree with the warm `DerivedDataTests` cache
(`ios/build/DerivedDataTests`, simulator `0D2CED77-002C-4081-A4C7-6A0A97E60F18`,
Xcode 26.6). Model symlinks (whisper/KWS artifacts) were already in place from worktree
setup — a fresh worktree must recreate them or the build's link step fails (see §8).

---

## 2. Announcement end-to-end checks (task-file items a–d)

All four checks are exercised by named tests inside the sweep-of-record run (§1.1):

- **(a) The confirmation prompt names the routed channel.** `CallConfirmationWordingTests.testDisclosureNamesSkippedAndRouted`
  composes the prompt through the shipped `confirmationPrompt(for:)` for a fell-back
  action and asserts the skipped channel and the routed channel are both named, in
  attempt order, through `call.announce.fallbackRouted` labels. Green.
- **(b) One hop line per hop.** T-149's pins: `CallChannelResolutionTests.testLaunchFailedFallbackSpokenOnce`
  (exact single event payload; closed tokens; no name/digits), `testHopStepConsumesCandidatesNeverRepeats`,
  `testHopOpenerWiringEndToEnd` (hop line spoken once per hop step, before the opener's
  outcome line), plus `testFaceTimeLegThreadsTheRemainingCandidates` (the T-157 sweep's
  W8 control target C — the faceTime leg threads the remaining candidates). All green.
- **(c) M-1 variant exercised.** `CallChannelResolutionTests.testWhatsAppChatFalseSpeaksTheLine`
  plus `testPhoneFalseSpeaksTheLineNoHop`: the voice `.whatsappChat`/`.phone` false paths
  speak the shipped honest line (`call.announce.noPhoneNumber` via `announceNoUsableNumber`),
  record nothing, never hop. Green (and the W9-B control proves the recordlessness
  helper-body pin §9).
- **(d) The floor speaks the shipped line.** `testNumberlessDeadRowKeepsTheShippedFloorLine`,
  `testHoppedFloorLegWithoutAPhoneKeepsTheShippedLine` (Voice suite) and
  `MissedCallDialBackTests.testUndialableNumberIsHonestDeadRow`, `testDirectTelFloorCarriesEmptyProvenance`,
  `testFloorReachableWithEveryOtherChannelInfeasible`. All green.

---

## 3. SA-1..SA-9 landing map

Source of the SA items: `specs/security-design-review.md` ("Evidence obligations for
security-test", :177-195). Gate evidence for every row is the sweep of record (§1.1)
unless stated otherwise.

| SA | Landing unit(s) | Test evidence (suite · tests) | Gate evidence |
|----|-----------------|-------------------------------|---------------|
| SA-1 Chain matrix (64 cells, floor reachability per vocabulary) | T-145 (chain), T-146 (seam), T-151 (row), T-152 (tiles), T-153 (dial-back) | Voice: `testEveryConfigurationResolvesToAnAttemptableChannel` (64 cells, injected probe closure), `testPreferredWinsAndEqualPicksDedupe`, `testOrderContainsPhonePreferredFirst`, `testStubbedAbsentWhatsAppStillRoutes`, `testSeamNeverReturnsAChannelOutsideTheAttemptOrder`, `testSecondaryEqualsPrimaryDedupes`, `testMissedCallSeamUsesAudioVocabularyWithProvenance`, `testRowFloorReachableFromEveryRowState`; Intents: `testVideoTileVocabularyExcludesThePhoneCandidateUntilTheFloor`, `testAudioTileVocabularyExcludesFaceTimeAndKeepsSilentSubstitution`; DialBack: `testFloorReachableWithEveryOtherChannelInfeasible` | Sweep of record green |
| SA-2 At-most-once and termination | T-149 (hop), T-148 (prompt), T-153 | Voice: `testHopStepConsumesCandidatesNeverRepeats`, `testHopConsumesCandidatesNeverLoops`, `testLaunchFailedFallbackSpokenOnce`, `testHopNeverReEntersConfirmationOrAwaits`, `testHopOpenerWiringEndToEnd`; Wording: `testNoFallbackKeepsPromptByteIdentical`; DialBack: `testDialBackAnnouncesBeforeDispatchSourcePins` (no re-entry symbols) | Sweep of record green |
| SA-3 GSM floor per surface | T-145/T-146 (voice anyChannel + video), T-151 (rows), T-152 (tiles), T-153 (dial-back) | Voice: `testSeamVocabularySubstitutionRoutesToTerminal`, `testVocabularySubstitutionCannotDeadEndTheRoute`, `testSubstitutedTerminalHasNoCandidates`, `testRowFloorReachableFromEveryRowState`; Intents: `testVideoTileVocabularyExcludesThePhoneCandidateUntilTheFloor`, `testAudioTileFallbackReachesTheFloorWithProvenance`; DialBack: `testFaceTimePreferenceStaysTheAudioFloorRoute`, `testUnmatchedNumberAlwaysDialsTel`, `testFloorReachableWithEveryOtherChannelInfeasible`; announcement names the floor: Wording `testDisclosureNamesSkippedAndRouted` | Sweep of record green |
| SA-4 (a) no emergency file in change set; trigger byte-unchanged | T-157 audit (§6.1) | — (audit evidence) | §6.1 + sweep green |
| SA-4 (b) override block diff-clean; gate; amended action | T-148 + T-157 audit (§6.2) | Wording: `testOverrideGateUntouchedPin` | §6.2 + sweep green |
| SA-4 (c) zero emergency-identifier additions | T-157 audit (§6.3) | — (grep evidence) | §6.3 |
| SA-4 (d) no escalation-delaying await | T-149/T-153 + T-157 re-verification (§6.4) | DialBack: `testDialBackAnnouncesBeforeDispatchSourcePins` (per-token zero scan over the dial-back region + hop path); Voice: `testHopNeverReEntersConfirmationOrAwaits` | Sweep of record green |
| SA-4 (e) confirmation timeout untouched | T-157 audit (§6.5) | — (diff evidence) | §6.5 |
| SA-5 Announcement honesty (incl. M-1) | T-148 (prompt), T-149 (hop line), T-150 (false-case floors), T-151/T-152 (tap announces), T-153 (dial-back announce) | Wording: `testDisclosureNamesSkippedAndRouted`, `testNoFallbackKeepsPromptByteIdentical`; Voice: `testLaunchFailedFallbackSpokenOnce`, `testPhoneFalseSpeaksTheLineNoHop`, `testWhatsAppChatFalseSpeaksTheLine`, `testRowAnnouncesBeforeTheOpenAndThreadsTheHop`, `testNumberlessDeadRowKeepsTheShippedFloorLine`; DialBack: `testDialBackAnnouncesBeforeDispatchSourcePins` (one site, before the switch), `testDirectRouteCarriesNoProvenanceToAnnounce` | Sweep of record green |
| SA-6 Log safety | T-156 (gate registration) + T-149/T-150/T-153 (source discipline) | DialBack: zero `observabilityBus`/`emit(` in the region (inside `testDialBackAnnouncesBeforeDispatchSourcePins`); Wording: `testNewRegionsAddNoKeysOrConsoleWrites` | §1.4 direct guard exit 0 + in-build guards green; `LogSanitiser` not in the change set |
| SA-7 No new surface | T-157 audit (§6.6-6.9) | — (diff/grep evidence) | §6.6-6.9 |
| SA-8 Localisation (five keys, parity, no literals) | T-155 + T-157 parity proof (§4) | L10nCatalogCoverageTests (16 tests incl. `testEveryCallingKeyResolvesInBothLanguages`, `testTheCallingPlaceholdersMatchBetweenLanguages`, `testTheCallingCoverageCheckFailsNamingTheMissingValue`, `testTheCallingFamilyPassesTheCoverageCheck`, `testTheCallingCopyIsPinnedVerbatim`, `testTheCallingKeysSitAlphabeticallyInTheFile`); Wording `testNewRegionsAddNoKeysOrConsoleWrites`; Settings `testTheScreenAddsNoSixthUserVisibleString` | Sweep of record green + §4 |
| SA-9 Settings persistence | T-154 (+ T-146 key) | CallingSettingsSurfaceTests: `testSecondaryAbsentRestoresPhone`, `testSecondaryRoundTrip`, `testPickerTwoSectionsPersist`, `testPickerRowExposesSelectedState`, `testPickerTitlesExposeHeadingTrait`, `testChannelLabelsDelegateToTheChainHelper` | Sweep of record green |

---

## 4. Five-key parity proof (SA-8)

Catalogue: `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (sourceLanguage `en`,
version 1.0). Total keys in the file: **1394**. The five feature keys, en and ne, with
placeholder counts extracted from the JSON:

| Key | en | ne | Placeholders (en/ne) |
|-----|----|----|----------------------|
| `settings.calling.primaryTitle` | Primary dialer | मुख्य डायलर | 0 / 0 |
| `settings.calling.secondaryTitle` | Fallback dialer | वैकल्पिक डायलर | 0 / 0 |
| `router.call.fallbackDisclosure` | %1$@ isn't available, so I'll call %2$@ via %3$@. | %1$@ उपलब्ध छैन, त्यसैले %2$@ लाई %3$@ बाट कल गर्नेछु। | %1$@ %2$@ %3$@ / %1$@ %2$@ %3$@ |
| `call.announce.fallbackRouted` | %1$@ isn't available — calling %2$@ via %3$@. | %1$@ उपलब्ध छैन — %2$@ लाई %3$@ बाट कल गर्दैछु। | %1$@ %2$@ %3$@ / %1$@ %2$@ %3$@ |
| `call.announce.launchFailedFallback` | %1$@ didn't open for %2$@ — trying %3$@. | %2$@ को %1$@ खुलेन — %3$@ मार्फत प्रयास गर्दैछु। | %1$@ %2$@ %3$@ / %1$@ %2$@ %3$@ |

Exclusivity proof (catalogue diff `8089c735..HEAD`): **85 insertions, 0 deletions**;
exactly five added top-level keys, matching the list above character for character
(`call.announce.fallbackRouted`, `call.announce.launchFailedFallback`,
`router.call.fallbackDisclosure`, `settings.calling.primaryTitle`,
`settings.calling.secondaryTitle`). No other key was added, renamed or removed.

---

## 5. No-egress statement

Every probe the feature consumes is local:

- The single WhatsApp probe is `CallChannelChain.whatsAppInstalled(canOpen:)`, resolving
  the compile-time literal `static let whatsAppProbeURL = URL(string: "whatsapp://")!`
  (`Services/Calls/CallChannelChain.swift:910`) through an injected `canOpenURL` —
  an installed-app probe on the platform, no network.
- Opener URLs are platform-scheme handoffs only (`tel:`, `facetime:`, `fb-messenger:`,
  `whatsapp:`); the one web URL (`https://m.me/`) lives in the pre-existing
  `CallLinks.swift` recovery chain and is not part of this change set.

Audit evidence (added lines of the whole iOS diff `8089c735..HEAD`): zero matches for
`URLSession`, `URLRequest`, `http://`, `Network`, `URLConnection`, `socket(`; zero
`https://` additions. The only scheme literal added anywhere is the `whatsapp://` probe
above (cross-referenced from SA-7 §6.6).

---

## 6. Preservation audits (SA-4, SA-7, FR-CDP-018)

Method: change set enumerated by `git diff 8089c735..HEAD` (merge-base above). The plan
cites planned line anchors; lines below were located **by content** and the actual
current lines are recorded (the brief's "record actual lines if shifted" rule).

### 6.1 SA-4(a) — emergency components

- Change set contains **no emergency component file**: the 15 iOS files are
  AppCoordinator, CallingSettingsView, LeafViews, Localizable.xcstrings,
  CallChannelChain (new), MethodResolver, project.pbxproj, check-release-log-safety.py
  plus seven test files (full list §13.2). `RedesignComponents.swift` is NOT in the
  change set (0 diff entries; file-level byte-identical).
- The emergency trigger at `App/RedesignComponents.swift:229-237`
  (`emergencyNotify` + `PhoneDialer.url` + `UIApplication.shared.open`) is byte-unchanged
  (region diffed against base, empty).

### 6.2 SA-4(b) — override block, gate, amended action

Overrides live in `App/AppCoordinator.swift` `handleCallConfirmationOverride(_:)` —
planned anchors :7656-7686/:7665-7669/:7670-7674; **actual content located at
:7783-7813** (line shift from the feature's own additive edits):

- Gate — actual `:7792-7796`: `if override == .messengerAudio || override == .messengerVideo,
  CallLinks.messengerHandle(action.contact.messengerHandle ?? "").isEmpty { speak(... router.call.messengerNoHandle ...); return true }`
  — the original action stays pending; the shipped line is spoken; returns true.
- Amended action — actual `:7797-7801`: `PendingCallAction(contact:method:unsupportedRequestedApp: nil,
  sourceTranscript:sourceCommand:)` — still constructs with provenance dropped
  (`unsupportedRequestedApp: nil`); assigned at :7802.
- Diff-clean: the block sits entirely inside a diff-clean gap of the AppCoordinator diff
  (surrounding base hunks end at old line 7628 and resume at old 7688 — no hunk touches
  the block). Additional pin: `CallConfirmationWordingTests.testOverrideGateUntouchedPin` (green).

### 6.3 SA-4(c) — zero emergency-identifier additions

Grep over the added lines of the full iOS diff for `emergencyNotify|NotifyChannel|preferredEmergencyContact|EmergencyChannel`:
**0 matches**. No emergency notification identifier, notify-channel type, or
preferred-emergency-contact storage was added anywhere.

### 6.4 SA-4(d) — no escalation-delaying await (re-verification)

Re-verified at this sweep by two green tests in the sweep of record:
`MissedCallDialBackTests.testDialBackAnnouncesBeforeDispatchSourcePins` scans the
dial-back region and the hop path (`launchFailHopStep` + `performLaunchFailHop`) token
by token for `await`, `sleep`, `Timer`, `retry`, `asyncAfter` — zero occurrences each
(plus zero `DispatchQueue`/`Task` in the T-153 recorded raw+stripped inspection over
`:8812-8949` and `:8005-8057`); and `CallChannelResolutionTests.testHopNeverReEntersConfirmationOrAwaits`.
The only concurrency shape in the region is the pre-existing one-way GSM handoff
(`DispatchQueue.main.async`, predating the feature).

### 6.5 SA-4(e) — confirmation timeout untouched

`App/VoiceSessionStateMachine.swift` is not in the change set (0 diff entries);
`var confirmationTimeoutSeconds: UInt64 = 45` intact at anchor `:135`.

### 6.6 SA-7 — plist and pbxproj

- `Info.plist`: not in the change set (0 files; byte-diff empty). No new scheme or
  permission.
- `seniOS.xcodeproj/project.pbxproj`: +20/-0, purely mechanical registration of the
  three new source files (CallChannelChain.swift, CallConfirmationWordingTests.swift,
  CallingSettingsSurfaceTests.swift — PBXBuildFile/PBXFileReference/group/Sources
  entries; no build-setting lines).

### 6.7 SA-7 — no new network symbol

See §5: 0 matches for network symbols in the added lines.

### 6.8 SA-7 — store keys (secondaryCallApp is the ONLY new store key)

- Production `forKey:` additions in the diff: exactly two lines, both
  `Self.secondaryCallAppKey` (the setter `AppCoordinator.swift:346-349` and the init
  read `:2923-2924`); key constant `private static let secondaryCallAppKey = "secondaryCallApp"`
  at `:352`.
- Base already contains `defaultCallAppKey` (3 occurrences at base — the pre-existing
  primary) and **zero** occurrences of `secondaryCallApp` — the secondary key is the
  single new store key.
- All other `UserDefaults` lines in the diff are test-side snapshot/restore helpers, not
  store keys.
- The stored value is a `CallApp` raw value (enum string, non-PII).

### 6.9 SA-7 / FR-CDP-018 — no per-contact storage; no router service

- No `FamilyContact*` file appears in the change set (0 files); zero added production
  lines reference `FamilyContact`. No per-contact primary/secondary storage exists or
  was added; contact preferences remain the pre-existing model fields.
- `RouterService`/`routerService`: 0 occurrences anywhere in the shipping sources
  (`ios/ElderlyAssistant`). **Traceability statement of record: no router service
  exists; no per-contact storage was added (FR-CDP-018 preserved).**

---

## 7. Device-validation checklist — DV-1..7 (prepared for the owner's run; NOT executed here)

Source: `specs/define-requirements/FR/FR-CDP-019-device-validation-completion-gate.md`
and the feature constitution's "Success Criteria & Completion Gate". Reference device:
Anzaan. The device pass itself is the downstream sign-off gate and is deliberately not
simulated in this unit.

| # | Scenario | Pass criteria |
|---|----------|---------------|
| DV-1 | Settings: Primary + Fallback pickers persist across relaunch (`secondaryCallApp` next to `defaultCallApp`) | Pick Primary = A, Fallback = B; force-quit; relaunch; both pickers show A/B; VoiceOver names the headings |
| DV-2 | Primary infeasible (Messenger preferred, no handle on file) → call completes via fallback with the spoken announcement naming the routed channel | The call opens on the fallback channel; the announcement names skipped and routed channels in attempt order |
| DV-3 | WhatsApp not installed (`canOpenURL` false) → chain lands on fallback/GSM with the announcement; a launch failure is announced via the spoken-outcome lane (no silent failure) | No silent failure anywhere: each failed open produces its shipped spoken line / hop line |
| DV-4 | `secondary == primary` dedupes; both infeasible → `phone` attempted; zero dead ends | Every tried configuration opens something; the floor is always reached |
| DV-5 | Override preserved: "होइन, फोन नै गर" still switches to a phone call | The confirmation is amended and a phone call is placed |
| DV-6 | All call paths route the chain: address-book row, family-contact, missed-call dial-back, voice-initiated call (MethodResolver global default) | Each path visibly/audibly routes per settings and announces fallbacks |
| DV-7 | ne/en copy: pickers, confirmation and announcement strings localised; spoken language matches the session | Switching language switches all copy and speech |

---

## 8. Baseline honesty

- **The scoped suites are the gate.** Per the owner's consolidated-gate directive, this
  feature's gates are `-only-testing` scoped runs; the full-bundle test baseline on
  master is pre-existing red and is unrelated to this feature's files. Every run in this
  unit (and every wave gate) used the scoped form; no run here executed the full bundle.
- **Fresh-worktree note.** A brand-new worktree does not inherit the whisper/KWS model
  artifacts; they must be symlinked from the main checkout (`whisper-medium-ne-q5_1.bin`
  and the KWS asset) or the xcodebuild link step fails. This worktree was already warm;
  no link failure occurred in any run recorded here.
- Disk was watched between runs (ENOSPC can kill xcodebuild silently); no run died on
  disk pressure.
- One in-flight build failure predating this unit (W8's first `t151-gate` run, fixed at
  the source by the wave dev) is recorded in `specs/implement-notes.md` and is not part
  of this unit's evidence.

---

## 9. Negative-control records

All controls edit only `App/AppCoordinator.swift`, applied with a fragment-uniqueness-
checked editor; restore is by byte-exact pre-control backup; md5 is captured before the
edit, after the edit, and after the restore. Clean file md5 throughout:
**7f50894d800b276dbf470c176a444d13** (this is also the T-153 wave-closure hash — no
drift preceded the sweep).

### 9.1 W8 control (the two carried-fix lines reverted)

Edits: the `performLaunchFailHop` `.faceTime` leg back to the pre-N-1 form
(`performFaceTimeCall(name: name, phone: phone, video: isVideo)`), and the messenger
opener's hopped consume back to `phone: ""`.
Control md5: `bfe71e16398bc42429dc41c7699b6e57`.

- Run: `ios/build.sh test:unit CallChannelResolutionTests ContactCallButtonsTests` —
  log `ios/build/t157-w8-control.log`, exit 65; bundle
  `Test-ElderlyAssistant-2026.10.12_07-56-15-+1100.xcresult`: Failed, 70 tests,
  68 passed / 2 failed / 0 skipped.
- **Expected** reds: exactly `testFaceTimeLegThreadsTheRemainingCandidates` and
  `testLaunchHopCarriesThePhoneAdditively`; ContactCallButtonsTests stays green (its
  fixtures use empty phones) and must not be mistaken for coverage.
- **Observed**: exactly those two reds (the faceTime-leg pin: the case arm loses the
  hop thread, verbatim diff in the failure text; the LaunchHop-phone pin: "the messenger
  opener consumes the hop's own number (N-4)"); ContactCallButtonsTests 25/25 green.
  **Expected == observed.**
- Restore: md5 `7f50894d800b276dbf470c176a444d13` (byte-identical). Confirm run
  (`test:unit CallChannelResolutionTests ContactCallButtonsTests`, log
  `ios/build/t157-w8-restore-confirm.log`, exit 0; bundle
  `Test-ElderlyAssistant-2026.10.12_07-58-40-+1100.xcresult`): Passed 70/70/0/0.

### 9.2 W9 control A (combined: announce deleted + hop two-labeled + one arm's hop dropped)

Edits (scoped to `dialBackMissedCall`): delete the announce block; revert the hop to the
two-label `LaunchHop(candidates:handle:)`; drop `hop: hop` from the WhatsApp arm.
Control md5: `21fbd6a4049c4149a4335cfc0f08f4a7`.

- Run: `test:unit MissedCallDialBackTests` — log `ios/build/t157-w9a-control.log`,
  exit 65; bundle `Test-ElderlyAssistant-2026.10.12_08-00-48-+1100.xcresult`: Failed,
  22 tests, 21 passed / 1 failed, 2 assertion failures.
- **Expected**: the announce-before-dispatch source pin red, on its counts/needles.
- **Observed**: exactly that — `testDialBackAnnouncesBeforeDispatchSourcePins` red:
  first the "one announcement site" count (0 vs 1), then the test aborts at the missing
  announce block (the unwrap); the hop-form and `hop: hop` count needles sit later in the
  same test body and were not reached. **Expected == observed** (the observed record is
  exactly what ran; the combined edit's later needles are unreached by assertion order,
  disclosed rather than implied).
- Restore: md5 `7f50894d800b276dbf470c176a444d13` (byte-identical).

### 9.3 W9 control B (raw-to-normalised derivation swap)

Edit: `messengerHandleAvailable: messengerHandle?.isEmpty == false` →
`!CallLinks.messengerHandle(messengerHandle ?? "").isEmpty` in `missedCallDialAction`.
Control md5: `c72a3821986af53bff04aee88a0a3241`.

- Run: `test:unit MissedCallDialBackTests` — log `ios/build/t157-w9b-control.log`,
  exit 65; bundle `Test-ElderlyAssistant-2026.10.12_08-04-37-+1100.xcresult`: Failed,
  22 tests, 20 passed / 2 failed.
- **Expected** reds: `testMissedCallDialActionSourcePins` AND
  `testWhitespaceOnlyHandleKeepsTheRawDialBackDerivation`.
- **Observed**: exactly those two — the source pin ("the RAW shipped handle derivation,
  verbatim (L2-D9 / W3 N-2)") and the behavioural pin (the plan flips from `.messenger`
  to `.call` for the whitespace-only handle). **Expected == observed.**
- Restore: md5 `7f50894d800b276dbf470c176a444d13` (byte-identical).

### 9.4 W9 control C (vocabulary swap `.audio` → `.anyChannel`)

Edit: the single final-return `vocabulary: .audio` → `.anyChannel` in `missedCallDialAction`.
Control md5: `eb08ebf62216ea9ceadcc595bebaa769`.

- Run: `test:unit MissedCallDialBackTests` — log `ios/build/t157-w9c-control.log`,
  exit 65; bundle `Test-ElderlyAssistant-2026.10.12_08-07-14-+1100.xcresult`: Failed,
  22 tests, 20 passed / 2 failed.
- **Expected** reds: `testMissedCallDialActionSourcePins` and the new §10.4
  audio-vocabulary behavioural leg (added in this unit, §11.2).
- **Observed**: exactly those two — the source pin ("the audio hop candidates" needle)
  and `testRouteHopCandidatesAreTheChainsDerivedSuffix`'s new leg
  (observed `[.faceTime, .phone]` vs expected `[.phone]`). **Expected == observed.**
- Restore: md5 `7f50894d800b276dbf470c176a444d13` (byte-identical).

All five of T-153's five-candidate control plan items were exercised (candidates 1-3
combined as control A; 4 as B; 5 as C). After every restore the final sweep (§1.1)
re-confirmed the family green.

---

## 10. Errata roll-up (carried records — NOT design edits)

1. **W2 N-3**: L2-D1's "Case table 11.4" pointer is dangling; the vocabulary case table
   is design section **10.4**. The hop semantics agree on all eight rows. A one-line
   erratum is owed the next time design-l2 is touched.
2. **W4 N-6**: the stale `CallingSettingsView.swift:70-77` pointer inside
   `CallChannelChain.swift:157-158` is design-inherited (the design's own listing carries
   the same comment). The chain file stays byte-frozen; a wording-only erratum on both
   the design listing and the chain comment is owed at the next legitimate touch,
   alongside the W2 N-3 erratum.
3. **W6 N-1**: the design's `performLaunchFailHop` listing omitted the hop thread on the
   `.faceTime` leg — adjudicated and **landed in code at W8** (reviewer-prescribed one-line
   thread + pin); now proven load-bearing by control 9.1.
4. **W6 N-4**: the design listing showed the two-label `LaunchHop(candidates:handle:)`;
   the additive defaulted `phone` field **landed in code at W8** and is threaded from the
   dial-back at W9; proven load-bearing by control 9.1.

Housekeeping warning for the end-stage reviewer: `specs/implement-review-w8.md` in this
worktree is a **Spotify-feature artifact** (2026-10-07, T-124 device-validation protocol,
commit `31dd53ea`) — it is NOT this feature's W8 review (this feature's W8 review does not
exist by design; per-unit reviews were consolidated to the end stage). It must not be
edited or cited as this feature's W8 review.

---

## 11. First-execution declaration

### 11.1 Tests first executed by this sweep (previously unaudited-against-run)

Compile-verified only in waves 8-9; **first run was the first green sweep (§1.2)**:

- `CallChannelResolutionTests` W8-new (9): `testRowProbeStubbedFalseRoutesToSecondaryOrFloor`,
  `testRowFloorReachableFromEveryRowState`, `testRowAnnouncesBeforeTheOpenAndThreadsTheHop`,
  `testRowProbeIsTheSingleChainProbe`, `testRowStateIsTheFiveArgumentCallAndTheDeadRowStaysShipped`,
  `testNumberlessDeadRowKeepsTheShippedFloorLine`, `testFaceTimeLegThreadsTheRemainingCandidates`,
  `testLaunchHopCarriesThePhoneAdditively`, `testHoppedFloorLegWithoutAPhoneKeepsTheShippedLine` — all green first run.
- `ContactCallButtonsTests` W8-new (9): `testVideoTileVocabularyExcludesThePhoneCandidateUntilTheFloor`,
  `testAudioTileVocabularyExcludesFaceTimeAndKeepsSilentSubstitution`,
  `testVideoTileDirectEmitsTheShippedDirectOutcome`, `testAudioTileDirectKeepsTheShippedDirectOutcome`,
  `testAudioTileFallbackReachesTheFloorWithProvenance`, `testVideoTileSubstitutionNeverHopsAndStaysOnFaceTime`,
  `testMessengerTileInvalidHandleHopsThroughTheChain`, `testWhatsAppLaneNeverHopsEvenHandedCandidates`,
  `testTileChainHeadSourcePins` — all green first run.
- `MissedCallDialBackTests` W9-new (10): `testBothNumberlessGuardsCarryAnEmptyRoute`,
  `testDirectTelFloorCarriesEmptyProvenance`, `testFloorReachableWithEveryOtherChannelInfeasible`,
  `testFaceTimePreferenceStaysTheAudioFloorRoute`, `testDirectRouteCarriesNoProvenanceToAnnounce`,
  `testWhitespaceOnlyHandleKeepsTheRawDialBackDerivation`, `testRouteHopCandidatesAreTheChainsDerivedSuffix`,
  `testDialBackAnnouncesBeforeDispatchSourcePins`, `testMissedCallDialRouteShapeSourcePins`,
  `testMissedCallDialActionSourcePins` — all green first run (plus the W9-upgraded
  `testMatchedFamilyContactDrivesTheAction` call site, green).
- The W9 first-execution closes the W9 record's "22 tests unaudited-against-run" item.

No production defect surfaced at first execution of any of these tests. **No repair was
needed by the first sweep.**

### 11.2 Pins authored in this unit

- `CallChannelResolutionTests.testEmptyInputGuardsPrecedeEveryProbe` — W6 N-8(b) owed
  pin: comment-stripped exact-body pins for the hermeticity floor (`CallLinks.openPhone`,
  `openFaceTime`, `openMessengerThread`, `openMessengerChat`, `openWhatsAppCallChat` —
  empty input refused before any probe; the four `guard !handle.isEmpty` nil builders and
  the two digit-based ones counted; `PhoneDialer.url` nil-on-no-digits in
  `RedesignComponents.swift`).
- `CallChannelResolutionTests.testAnnounceNoUsableNumberBodyStaysRecordless` — W7-log
  point 4 owed pin: `announceNoUsableNumber`'s body pinned whole (exact collapsed
  equality: `setOutcome` + `speak` of the shipped line, nothing else).
- `MissedCallDialBackTests.testRouteHopCandidatesAreTheChainsDerivedSuffix` — extended
  (T-153 coverage note): the §10.4-case-table discriminator leg — messenger preferred
  (handle present) + FaceTime secondary → dial-back hop candidates `[.phone]` under the
  audio vocabulary, with the `.anyChannel` control leg showing `[.faceTime, .phone]`
  (proven load-bearing by control 9.4).

### 11.3 Honest first-run record of the new pins

The first run of the two new pins (`Test-ElderlyAssistant-2026.10.12_07-50-01-+1100.xcresult`)
was **red on my own expectation error**: 2 failed test cases / 7 assertion failures. Root
cause: the suite's `region(between:and:)` helper is start-marker-inclusive
(`CallChannelResolutionTests.swift:2256-2262` returns `text[start.lowerBound..<end.lowerBound]`),
and my expected strings omitted the marker text. The extracted regions themselves showed
the shipped floors exactly as intended — no production concern; the fix was **test-side
only**: the marker text was prepended to each of the seven expectations, pre-validated by
an exact Python emulation of `FeatureSourceScan.codeText` + region + whitespace collapse
(all seven byte-verified against the sources, plus the 4/2 guard counts) before the rerun.
Rerun: 67/67 green (§1.3). Classified and recorded here as a test-authoring repair, not a
production repair. The B.3 leg appended in this unit was green in every run of this suite.

---

## 12. Owed-item disposition (from specs/implement-notes.md)

Wave-8 owed list: (1) T-152 emit-suffix arbitration → **escalated** to the end-stage
reviewer (below); (2) T-151 real-probe supersession acknowledgment → **escalated** (below);
(3) W6 N-8(b) pin → **discharged** (§11.2); (4) W7-log point 4 pin → **discharged** (§11.2);
(5) deferred scoped runs + W8 control → **discharged** (§1.2, §9.1).
Wave-9 owed list: (1) T-153 coverage note (behavioural audio-vocabulary discriminator) →
**discharged** (§11.2, proven by §9.4); (2) five-candidate control plan → **discharged**
(all five exercised, §9); (3) "this suite's 22 tests are unaudited-against-run" →
**closed** (§11.1).

### Escalations for the end-stage reviewer (no dev-side action available in this unit)

1. **T-152 emit-suffix reading** (`performContactCall`): the shipped audio-/video-prefixed
   outcome strings stay byte-identical with a `:direct`/`:fellBack` provenance suffix
   appended per design §9.2; a strict reading of the DoD's shipped-direct-outcome-strings
   clause is unsatisfiable alongside the normative §9.2 listing. Flagged at W8 for
   end-stage arbitration; still open.
2. **T-151 real-probe supersession**: `rowChannelState` uses the real
   `whatsAppInstalledNow` probe, superseding the T-146 bridge's hardcoded `true`
   (disclosed routing change: a WhatsApp-preferring row on a phone without WhatsApp now
   falls back instead of opening a dead link). Acknowledgment against the T-146 bridge's
   contract requested.
3. **Disclosed residual (W8, not faked)**: no behavioural WhatsApp tile arm (the real
   probe is not stubbable in the simulator) and no behavioural tile hop onto FaceTime (no
   tile hop can currently land there) — pinned through the shipped opener plus source pins.

---

## 13. Evidence index

### 13.1 Logs and bundles (all under `ios/build/`)

| Artifact | log | bundle |
|----------|-----|--------|
| First green sweep (A) | `t157-sweep.log` | `…07-46-17-+1100.xcresult` |
| Pins first run (red, mine) | `t157-pins-rerun.log` | `…07-50-01-+1100.xcresult` |
| Pins rerun (green) | `t157-pins-rerun2.log` | `…07-54-40-+1100.xcresult` |
| W8 control | `t157-w8-control.log` | `…07-56-15-+1100.xcresult` |
| W8 restore confirm | `t157-w8-restore-confirm.log` | `…07-58-40-+1100.xcresult` |
| W9-A control | `t157-w9a-control.log` | `…08-00-48-+1100.xcresult` |
| W9-B control | `t157-w9b-control.log` | `…08-04-37-+1100.xcresult` |
| W9-C control | `t157-w9c-control.log` | `…08-07-14-+1100.xcresult` |
| **Final sweep of record** | `t157-final-sweep.log` | `…08-10-43-+1100.xcresult` |
| Direct privacy guard | `t157-privacy-guard.log` | — (exit 0) |

### 13.2 Change set (base `8089c735` … `4f17049a` + this unit's tree)

Production (8): `App/AppCoordinator.swift` (+567/-104) · `App/CallingSettingsView.swift`
(+55/-17) · `App/LeafViews.swift` (+82/-20) · `Resources/Localizable.xcstrings` (+85/-0) ·
`Services/Calls/CallChannelChain.swift` (new, +212) · `Services/Intents/MethodResolver.swift`
(+22/-5) · `seniOS.xcodeproj/project.pbxproj` (+20/-0) · `tools/check-release-log-safety.py` (+10/-0).
Tests (7): `Services/Voice/CallChannelResolutionTests.swift` (+2179/-10) ·
`Services/Intents/ContactCallButtonsTests.swift` (+569/-0) ·
`App/MissedCallDialBackTests.swift` (+508/-38) · `App/CallConfirmationWordingTests.swift`
(new, +402) · `App/CallingSettingsSurfaceTests.swift` (new, +330) ·
`App/L10nCatalogCoverageTests.swift` (+317/-7) · `Services/Intents/MethodResolverTests.swift`
(+70/-2). (Specs/docs additionally change; see `git diff --stat` for the full list.)
This unit's tree change (`git diff HEAD --numstat`): `CallChannelResolutionTests.swift`
+115/-0 (the two pins) and `MissedCallDialBackTests.swift` +29/-0 (the extended leg) —
tests only, pure additions; **no production file was modified by T-157** (production
diff vs HEAD empty; AppCoordinator md5 restored exactly).

### 13.3 Payload

Completion payload JSON: `ios/build/t157-completion-payload.json` (task_id `T-157`,
output_path `specs/T-157-notes.md`, content byte-matching this file).

---

## 14. Honest not-done list

- **DV-1..7 device validation is NOT executed here** (by design and by the brief): §7 is
  the prepared checklist; the owner's run on Anzaan is the downstream completion gate.
- The two escalations in §12 remain reviewer decisions, not dev actions.
- The W4 N-6 and W2 N-3 errata are recorded (not edited) — design documents are outside
  this unit's ownership.
- Nothing in this unit was committed (per the brief); no ai-sdd CLI command was run; the
  main checkout was not touched; the untracked engine-state `.ai-sdd/workflows/workflow.yaml`
  was left untouched.
