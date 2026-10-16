# T-171 — Localisation: consent, disclosure, indicator, revocation and safe-template copy (implement notes)

**Status: implemented, scoped suite green (39/39).** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). No commits, no `ai-sdd` state-mutating commands.
The unit continued an interrupted draft: the draft was audited against the unit spec, two copy
defects were fixed, two stale shared count pins were rebased, the hardcoded-copy sweep gained a
missing surface, and a spec-mirror pin was added; everything below is the state after that pass.

## What was built

### 1. `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (declared)

The 18-key cloud-chat family in `en` + `ne`, every entry `extractionState: manual` with both
`stringUnit` states `translated`, Nepali values Devanagari-only (no ASCII letters), `en != ne`
per key. Inserted at the house alphabetical positions as two contiguous blocks: the 15
`chat.*`/`cloud.chat.*` keys between `caregiverNotify.shareHint` and `cloudCascade.holdCue`,
the 3 `settings.cloudChat.*` keys between `settings.cloudCascade.toggleNote` and
`settings.diagnostics.title`. Catalogue total **1,421 → 1,439** keys (+18, none removed, no
duplicates; verified by parsing the file and by the raw-line key scan).

**The key-name contract** (stable for T-174/T-176/T-177; design-l1 §17 names):

| Surface | Keys (en+ne) |
|---|---|
| Consent question + answers (T-176) | `cloud.chat.consent.title`, `cloud.chat.consent.body` (the plain-language disclosure), `cloud.chat.consent.allow`, `cloud.chat.consent.notNow` |
| Indicator (T-177) | `cloud.chat.indicator`, `cloud.chat.indicatorSpoken` |
| Revocation (T-177) | `cloud.chat.revoke.title`, `cloud.chat.revoke.body`, `cloud.chat.revoke.done` |
| Voice state answers (T-177) | `cloud.chat.state.spoken.on`, `cloud.chat.state.spoken.off` |
| Settings row (T-177) | `settings.cloudChat.title`, `settings.cloudChat.toggleLabel`, `settings.cloudChat.toggleNote` |
| Guard safe templates (T-174) | `chat.safeTemplate.generic`, `chat.safeTemplate.honorificAgreement`, `chat.safeTemplate.devanagariPurity`, `chat.safeTemplate.danglingParticle` |

### 2. `ios/ElderlyAssistant/App/L10n.swift` (declared, +41 — kept as drafted, audited correct)

- `L10n.SafeTemplate: String, CaseIterable` — the bounded, enumerable set; raw values are
  **1:1 with T-169's `GrammarCheckClass` raw values and the style spec's `guard_checks` ids**
  (`honorificAgreement`, `devanagariPurity`, `danglingParticle` + `generic`).
- `L10n.safeTemplate(forCheckClasses: [String])` — deterministic: the FIRST known class wins
  (the guard emits classes in its own fixed order); an unknown name is dropped to `.generic`
  and never echoed into a key.
- `L10n.safeTemplate(_:locale:) -> String` — resolves through `str` (total miss → "", the
  shipped nothing-to-say contract).

T-174's seam: `L10n.safeTemplate(forCheckClasses: verdict.classes.map(\.rawValue))`, then the
`locale:` resolver — no copy in code, no free-form text.

### 3. `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift` (declared, +1,116)

13 T-171 tests (suite total 39, all green):

| Gherkin scenario / DoD item | Test(s) |
|---|---|
| Every new key resolves in both languages | `testEveryCloudChatKeyResolvesInBothLanguages` (through `L10n.str`), `testTheCloudChatFamilyPassesTheCoverageCheck` (source half: count pin + pure check + the four insertion neighbours pinned verbatim), `testTheCloudChatCopyIsPinnedVerbatim` (both values verbatim) |
| Equal format-slot counts | `testTheCloudChatPlaceholderContractIsZeroSlotsInBothLanguages` (zero `%` slots in both languages — parity and the family's no-argument contract are the same assertion) |
| Safe templates bounded + enumerable | `testTheSafeTemplateSetIsBoundedAndEnumerable` (enum ↔ pinned keys ↔ catalog; deterministic selection incl. unknown-name and first-known-wins cases; no fifth `chat.safeTemplate.*` key) |
| Safe templates spec-register authored | `testTheCloudChatCopyMeetsTheRegisterBar` (sentence caps, per-sentence character caps, no emoji/list/markdown, spec `ai_isms` substrings + apology bar, banned familiar forms + non-honorific verbs, `हजुर` in every template; four offence fixtures prove the check bites), `testTheRegisterMirrorCoversTheStyleSpecsBans` (reads the seed's `ai_isms`/`register`/`sentence_shape` machine blocks; the mirror may be a superset, never a subset; the template cap **is** the spec's `max_sentences`) |
| Copy speaks to a person | `testTheCloudChatCopyNamesNoInternals` (both languages; pinned term lists; an enforced fixture) |
| Failure: a missing translation | `testTheCloudChatCoverageCheckFailsNamingTheMissingValue` (10 fixtures: ne removed, en removed, whole entry removed, blank ne, en pasted into ne, one-language slot drift, a stray key in each owned namespace, count-pin arithmetic) — each fails **naming the key**, and the one-language cases name the **language** |
| Failure: a hardcoded user-visible string | `testNoCloudChatCopyIsHardcodedOnTheFeatureSurfaces` (live sweep), `testTheHardcodedCopySweepReportsTheStringAndItsLocation` (fixture sweep reports file:line:text) |
| Alphabetical/contiguous house placement | `testTheCloudChatBlocksSitAlphabeticallyAndContiguouslyInTheFile` (raw-file span pin), `testTheCloudChatSpanCheckFailsOnAMovedOrSmuggledKey` (moved/smuggled/reordered fixtures fail naming the key) |

Also rebased the two shared catalogue-count pins that track the global total:
`callingBaselineKeyCount` 1,416 → **1,434**, `familyContactsBaselineKeyCount` 1,398 → **1,416**
(the dashboard draft had already rebased `dialogueBaselineKeyCount` 1,402 → **1,420**). All four
pins now sum to 1,439 with their family sizes (19/5/23/18).

## Test results (exact commands)

1. `cd /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/ios && ./build.sh test:unit L10nCatalogCoverageTests`
   → **39 tests, 0 failures** (`xcrun xcresulttool` summary: total 39, passed 39, failed 0),
   `** TEST SUCCEEDED **`, wrapper `=== Scoped unit run passed (baseline not advanced) ===`,
   exit 0. xcresult:
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_21-23-50-+1100.xcresult`
2. First run of the audited draft (evidence the shared pins bite): 38 tests, **2 failures** —
   `testTheCallingFamilyPassesTheCoverageCheck` and
   `testTheFamilyContactsFamilyPassesTheCoverageCheck`, both
   `XCTAssertEqual failed: ("1439") is not equal to ("1421")` — fixed by the rebase above, then
   re-run green (xcresult `…_21-20-36-+1100.xcresult`).
3. Gates (run by `build.sh` ahead of every test scope, both exit 0 in the runs above):
   `ios/tools/check-release-log-safety.sh`, `ios/tools/check-prompt-mirror.sh`.

Catalogue counts for the record: total 1,439 (HEAD 1,421); family 18 keys; raw key-line scan
1,437 (the two non-family empty-key entries `%@`/`·` are not key-line shaped — pre-existing).

## Audit of the interrupted draft — what was fixed, what was kept

**Fixed:**

1. **Nepali register slip in the disclosure** (`cloud.chat.consent.body. ne`): the second
   refusal clause used the neutral conjunctive ("होइन भने पनि म …") while the elder is the
   subject of refusing; the register calls for honorific agreement at all times. Now
   "होइन भन्नुभए पनि हुन्छ। **त्यसो भन्नुभए पनि** म यही फोनमै जवाफ दिइरहन्छु।" — honorific
   throughout and the "होइन …/होइन …" repetition is gone. (Test pin updated in the same change.)
2. **Non-idiomatic English Settings note** (`settings.cloudChat.toggleNote. en`): "On, the
   answers to our talks come from the internet. Off, …" → "**When this is on**, the answers to
   our talks come from the internet. **When it is off**, answers come from this phone. Chat
   keeps working just as before." (3 short sentences; max line 64 chars, cap 80.)
3. **Two stale shared count pins** (calling, family-contacts) — see above; the draft had
   landed the 18 keys but not rebased these two, so the suite was red (2 of 38).
4. **Sweep surface list missed T-174's file**: added
   `ElderlyAssistant/Services/Voice/CommandRouter.swift` (the chat-dispatch case that speaks the
   safe template) to the pinned-copy probe set — the "no hardcoded user-visible string" claim now
   covers T-174 + T-176 + T-177 surfaces (5 files + the whole `CloudChat` directory).
5. **Register-mirror provenance was a comment, now a test**:
   `testTheRegisterMirrorCoversTheStyleSpecsBans` reads T-166's seed file (`tools/train-intent/
   seeds/nepali-chat-style-spec`, the same artifact-read pattern as `ChatSamplingTests`), so a
   spec-grown ban or a changed `max_sentences` fails the suite instead of drifting.

**Kept as audited correct:** the L10n.swift API (typing/selection/semantics), the 18 key names
(1:1 with design §17), the four safe-template wordings and the consensus/indicator/revocation
copy (register bar + term bans + sentence caps all pass), the coverage check's rule set and
fixture design, and the omission of `chat.cloudFallback.notice` (see Decisions).

## Decisions and deviations

1. **`chat.cloudFallback.notice` deliberately omitted** (design §17 lists it as *optional*):
   §8.8 chooses "no user-visible error where a reply is expected", so the key would ship as
   dead copy. This is the one inventory deviation from design §17's key list; recorded here
   for the sign-off. The family is exactly 18 keys.
2. **Zero-slot contract.** No key in the family takes a format argument in either language
   (T-176/T-177 compose none), enforced as zero `%` placeholders in both languages — a slot
   added to one language only fails. If a future unit needs a slot, the pin is updated
   deliberately (that is the mechanism, not a gap).
3. **Nepali egress noun is "इन्टरनेट" / "the internet"** — the design's own §8.4 plain-language
   term ("an internet service"), and the only noun that names where content goes. The banned
   technical terms (cloud/server/API/model/provider/gemini) appear in neither language; the
   English and Nepali term lists are pinned by the suite.
4. **Safe templates use the softener "न"** ("फेरि भन्नुहोस् न"), which is not one of the style
   spec's six particle units. Kept deliberately: "न" is the natural respectful-imperative
   softener in spoken Nepali, it is not counted as a reply particle by the guard's lexicon
   (T-169 reads the spec's list), and the spec's alternative ("नि") reads as a question tag and
   would be wrong in a request. Recorded for the owner copy review (T-176) rather than silently
   asserted against the spec.
5. **The register bar's numeric bounds are the authored accessibility bar**: templates ≤ 2
   sentences (the spec's `max_sentences`, asserted equal), every other key ≤ 5; per-sentence
   character caps en 70/ne 65 (templates) and en 80/ne 70 (plain), set above the measured
   maxima (templates en 44/ne 32; family en 64/ne 63). Large-type readability: the copy is
   short-sentence by construction and pinned; the ≥44 pt / ≥18 pt *surfaces* that render it are
   T-176/T-177's UI and their DoD.
6. **Hardcoded-copy sweep — honest bound.** The `CloudChat` directory is scanned for any
   Devanagari in code (only user-visible copy can live there); the five wired files (three
   `App/` files, `CommandRouter`, `KeywordIntentRule`) get the duplicated-catalogue-value probe
   only, because those files legitimately carry other features' Devanagari. An English-only
   sentence newly hardcoded in a swept file is caught when it duplicates a family value; the
   fixture test demonstrates the report format (file, line, text) for both probes.
7. **Two shared count pins rebased within the declared file** — explicitly sanctioned by the
   unit brief ("if a baseline pin tracks total catalogue counts, update that pin"); the
   dialogue pin was already rebased by the draft. No family copy or key was touched in those
   sections.
8. **`SpotifyLocalizationTests` pins the global total at 1,381** (`1,361 + 20`): already stale
   at this tree's HEAD (1,421 keys) **before** this unit, i.e. a pre-existing red suite outside
   the three declared files. This unit's +18 neither causes nor worsens it (recorded, not
   touched).
9. **`ios/seniOS.xcodeproj/project.pbxproj` shows a diff in this shared worktree** — it carries
   the sibling wave units' new files (NepaliGrammarGuard/Routing/tests), generated by
   `build.sh`/XcodeGen from `project.yml`; this unit added no file, so it contributed no
   `pbxproj` entry.
10. **Notes-only record of the copy review hook**: OD-12/13 requires the consent/disclosure copy
    to be reviewed before the first App Store submission; `testTheCloudChatCopyIsPinnedVerbatim`
    is where a deliberate wording change lands (T-176 owns that review).

## Open items

- T-174: consume `L10n.SafeTemplate` / `L10n.safeTemplate(forCheckClasses:)`; the class names
  are pinned 1:1 to `GrammarCheckClass.rawValue`.
- T-176: the disclosure-copy review (OD-12/13) and the prompt's touch/voice answer labels use
  the consent keys; the copy pins are the deliberate-change site.
- T-177: indicator/state/revoke/Settings keys as tabled above.
- T-187 (DV-2/DV-3): the spoken indicator/state lines are heard in the configured language on
  Anzaan — a device item, not assertable in a unit process.
- If the style spec's `ai_isms`/`register`/`sentence_shape` blocks change,
  `testTheRegisterMirrorCoversTheStyleSpecsBans` fails until the mirror is updated (that is the
  intended direction of the dependency).
