# Security Test Review - live-camera-translation (English source to Nepali target, v1)

Task: security-test. Date: 2026-09-17. Branch: worktree-live-camera-translation, reviewed at merge commit b032fb0. Read-only review: no artifact, source file or configuration was modified, and no build or test harness was executed by this review. Every number below was re-derived from the recorded result bundles, and every source claim was re-checked against the post-merge tree; the notes were read as claims, not as evidence.

## Summary

Evidence base, re-derived bundle by bundle:

- ios/build/TG10-gate.xcresult: 14 suites, 205 tests, 0 failed, 0 skipped (suite counts re-read and summed to 205). Includes consent gate 29, cloud tier 25, Gemini client translate 15, activity indicator 15, allow-list 24, cipher storage 16, source hygiene 6, scene text sanitiser 17, security evidence boundary 7, security evidence index 5, pipeline 18, plugin 10, session model 17, OCR fixture 1.
- ios/build/T033-gate.xcresult: 18 suites, 307 tests, 0 failed, 0 skipped (suites sum to 307). Includes snapshot mode 25, camera capture guarantee 6, consent prompt and revocation 22, text detector 17, overlay placement 28, speech 34, app-layer hygiene 11, events 17, copy 10, text stabilizer 18, and others.
- ios/build/TG10-evidence.xcresult: the supporting security-evidence run.
- Post-merge scoped runs. Two bundles live in the default test-log location (ios/build/DerivedDataTests, under the Logs/Test directory) and are cited by no spec note; this review found them by scanning for files modified after the merge and re-derived them:
  - Test-ElderlyAssistant-2026.09.17_09-35-15-+1000.xcresult: 9 suites, 151 tests, 0 failed, 0 skipped, run 09:35:15 to 09:37:00 (+10:00), i.e. after merge commit b032fb0 (09:34:00 +10:00). Suites: ConsentPromptAndRevocationTests 22, LabelTranslationCacheTests 21, LiveTranslateCipherStorageTests 16, LiveTranslateAllowListTests 24, LogSanitiserTests 13, SceneTextSanitiserTests 17, InputSanitiserDetectOnlySeamTests 11, LiveTranslateCopyTests 10, SettingsTabMappingTests 17.
  - Test-ElderlyAssistant-2026.09.17_09-40-56-+1000.xcresult: 2 suites, 23 tests, 0 failed, 0 skipped, run 09:40:56 to 09:41:20. Suites: LiveTranslateEventsTests 17, LiveTranslateSourceHygieneTests 6.
  For both runs, each suite's executed count equals the number of test functions in its source file (checked file by file), so these are whole-suite executions, not filtered subsets. Together they are 174 tests re-run after the merge, covering the merge-touched security surfaces.
- Excluded: ios/build/TG10-ocr.xcresult (aborted, zero tests). It is not cited anywhere in this review.

Post-merge scope: the merge changed no live-translation service source. Its security-relevant deltas were the additive sanitiser allow-list, the allow-list test's declared union, one consent test's source-scan target (the settings reorganisation moved the route into SettingsTabs.swift, verified present there), the coordinator's cipher-storage wiring (checked directly, post-merge), the camera-usage disclosure text in Info.plist (present and correct), and app-layer view files carried from master.

## Decision

decision: SECURITY-GO

AM-1 through AM-10 are discharged with evidence this review re-derived; the three owner amendments have landed and are verified; both release log-safety gates re-run green on the post-merge tree (exit 0, all 12 rules load-bearing under falsification); and the merge-touched security surfaces were re-run after the merge with 174 tests and zero failures. The residuals listed under Not verified are declared, bounded and carried to final sign-off. AM-5 also gates final sign-off and is discharged with the gate and fixture runs recorded here.

## Category verdicts

### Consent gate - PASS
No cloud call without a recorded grant. The proof token's initializer is fileprivate, so only the gate's authorize() can produce it; the decision allows egress only in the granted state and fails closed for not recorded, denied and unreadable. Revocation denies in memory first, cancels in-flight work, deletes the record, reads it back, and leaves a tombstone so a relaunch cannot silently re-grant. Evidence: consent gate 29 and consent prompt and revocation 22 (the latter re-run green post-merge, including the settings-leaf wiring scan against the reorganised file), and the withdrawal-mid-scene boundary test, which revokes while a request is in flight and asserts no retry of the in-flight request, zero requests from later cycles, the indicator off, and exactly one recorded cost call. The consent record is persisted through the same cipher decorator as the translation cache (post-merge coordinator wiring checked directly).

### Text-only egress - PASS
The path cannot structurally carry an image: the translation item type has only an id, a source string and a language; the client entry point has no image, media or data parameter; the request body is one text part with no tool declarations and a JSON response mime type; the prompt embeds the items as a JSON data block. Tests decode the outgoing request and assert one content entry, one text part, no media or structure keys, and the exact top-level key set of contents plus generationConfig; the snapshot-originated request test repeats this for the frozen-frame path and carries a positive control proving the scan sees an image part where one legitimately travels (the shipped vision path). Retry re-enters the same request builder, so no retry can add a part. Suites green pre-merge (security evidence boundary 7, snapshot mode 25); the merge changed none of their sources or tests.

### Log safety - PASS
Emitters are typed: metadata values are integers, closed-vocabulary tokens or the disclosure version stamp; no emitter accepts free text; there is a single emit path. Re-run in this review on the post-merge tree: the release gate exits 0 and the fixture harness with falsification exits 0, reporting 24 fixtures over 12 rules with every rule proven load-bearing (disabling it makes its positive fixture pass). The feature rule family covers console writes, content printing in any configuration over the recognised and translated text vocabulary, unlisted metadata keys, and text interpolated into events; the gate is called from the build's test path before any test invocation, so it is build-blocking. The allow-list extension is additive: 45 keys = 27 shipped + 18 declared; this review statically replicated the suite's own set-equality assertion against the post-merge sources and it holds exactly, with no missing, undeclared or duplicate keys. Post-merge suites green: allow-list 24, LogSanitiser 13, scene text sanitiser 17, detect-only seam 11, source hygiene 6, events 17. AM-5's design correction is present: the invariant row names the cipher layer, and the observability section states the four rules, their configuration semantics and their limits rather than implying coverage the gate does not have.

### Offline degradation honesty - PASS
A result cannot claim a tier without a translation: the outcome is an enum (pending, resolved, degraded) and the source tier is non-nil only for resolved, making false tier attribution unrepresentable. Degradation reasons are closed vocabulary; a provider policy block surfaces a constant code, never upstream text. Degraded paths emit content-free events only. Evidence green pre-merge (pipeline 18, tier 25, session model 17); not re-run post-merge (see Not verified item 3).

### Cost governor - PASS
The shipped governor is consulted before the network call, and the tier checks the latch before each claim and each attempt; at the cap the result is a degraded outcome, not a retried or silently successful call. The cap signal reaches the console with its count and cap: the allow-list suite drives the real governor over its cap and asserts both keys survive the sanitiser and the real console sink, re-run green post-merge (24 of 24). Cancellation-shaped errors are terminal and never retried.

### Cipher at rest (T-032) - PASS
AES-GCM via CryptoKit with a Keychain-held key; the envelope is versioned (magic, version, nonce, ciphertext, tag) and authenticated with the storage key as associated data; an authentication failure discards rather than surfacing plaintext. Key loss regenerates an empty cache and never traps. Tests assert byte-level ciphertext rather than round-trip alone, and a recorded falsification run confirmed the assertion fails loudly when the cipher is bypassed. Post-merge green: cipher storage 16, label translation cache 21.

### Snapshot inclusion (T-033) - PASS
The freeze-frame holds the current camera buffer in memory only, runs the existing detector at full resolution, and renders through the existing overlay with identical tap-to-hear. It uses no tracker or stabilizer, and the frozen frame never travels: the cloud path receives text-only items (the text-only request test and its positive control are green in the snapshot suite, 25 tests, within the 18-suite, 307-test gate).

### Scope and requirements lock - PASS
FR-LCT-003 is re-locked to English source only for v1: every file-hash pair in the lock file recomputes and matches (36 of 36), the snapshot hash matches the requirements document, and the out-of-scope list names Devanagari source text (Nepali source to any target, and Devanagari OCR) as an explicit v1 non-goal, with the runtime probe notes recorded. That matches the observed runtime: the Devanagari Vision capability was absent there, which is why the scope was narrowed rather than left implied.

## Amendment disposition (AM-1 to AM-10)

- AM-1: cancellation-shaped transport errors are terminal and never retried; the gate is re-read immediately before every attempt; the withdrawal-between-attempts case exists and is green. PASS.
- AM-2: the allow-list extension is additive, the cap keys decision is recorded, and per-key tests exist; replicated statically and re-run green post-merge. PASS.
- AM-3: a single-sourced detect-only marker accessor is shared with the transcript sanitiser and pinned by tests (detect-only seam 11, scene text sanitiser 17, both post-merge green). PASS.
- AM-4: a withdrawal write failure denies in memory, verifies the delete by read-back, surfaces failure as failure, and the tombstone blocks a silent re-grant on relaunch (consent prompt and revocation 22, post-merge green). PASS.
- AM-5: the release gate was extended with the recognised and translated text rule family and the invariant table was corrected; gate and fixtures re-run green in this review. PASS (also gates final sign-off; discharged).
- AM-6: the stored ordering field is a monotone counter with no timestamps (design states it; snapshot suite green). PASS.
- AM-7: the request builder requires a consent proof parameter with no default, so the single-caller invariant is enforced at the type level. PASS.
- AM-8: the in-flight key claim and dedupe behaviour is specified and tested (tier suite 25 green pre-merge; sources unchanged by the merge). PASS.
- AM-9: the prompt-boundary wording names the single text channel, the absent tool set, the validated response and the absence of an action surface, and the provider-reason residual is recorded as SR-1. PASS.
- AM-10: all eight assertions verified - zero image or media parts on every path including retry; the body carries only items and language parameters; the consent key is not writable from any configuration path (Keychain attributes pinned; device-level enforcement not verified); cache-at-rest inspection shows ciphertext; the indicator cannot be suppressed while a request is in flight; withdrawal mid-scene yields zero further requests including on retry; zero results claim a tier without a translation; no error code derives from upstream text. PASS.

## Not verified (carried to final sign-off)

1. Device validation was not performed: DV-1 through DV-16 are NOT RUN, OD1, OD2 and OD5 are unmeasured, and owner actions OA-1 through OA-5 are open, as recorded in the device-validation protocol and results files. All evidence in this review is simulator-only; camera permission flows, Keychain and data-protection behaviour on hardware, and provider behaviour on device are not verified.
2. Real provider calls were not exercised: all egress evidence is at the client boundary with stubs and decoders. Live endpoint behaviour, provider-side handling, and real upstream error text are not verified; the no-upstream-derived-error-code invariant is verified structurally, not against live traffic.
3. The post-merge re-runs are scoped, not full-suite: the egress boundary, snapshot, tier, plugin and capture suites were not re-executed after the merge. Their sources and tests are unchanged by the merge and the post-merge tree builds and passes the scoped suites, but 'that suite passes on the post-merge tree' is an inference from unchanged inputs, not a recorded re-run. The two bundles were also cited by no spec note until this review located them.
4. The master unit baseline remains red (about 21 pre-existing failures). The scoped suites are the mitigation; no full-suite green is claimed.
5. One load-sensitive determinism test was observed flaky in the snapshot task; it is attributed in the notes, not eliminated.
6. The release log-safety gate cannot see through indirection; that limit is stated in the design, and the typed emitters plus the hygiene suite are its complement, not a replacement.
7. Two copy keys remain DRAFT, and the consent and disclosure copy review is owed at final sign-off (owner), together with OD3.
8. Residual SR-1 (the provider block reason emitted from one pre-existing site) and residuals T-2 and SD-5 stand as ruled in the security design review.
