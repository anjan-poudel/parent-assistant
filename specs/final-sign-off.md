# Final sign-off — live camera translation (English → Nepali, v1)

**Task:** final-sign-off (T2 human gate) — decision pack
**Date:** 2026-09-17
**Branch under review:** worktree-live-camera-translation (pushed to origin; master merged in at b032fb0; tip at the owner's sign-off was 8aae456). Not yet integrated into master.
**What this document is:** the pack the owner read in order to decide, and now the record of the decision. The reviewer's recommendation is unchanged; the sign-off itself was the owner's, given through the separate human approval step.

**Amended at sign-off (2026-09-17).** The owner gave the T2 sign-off on 2026-09-17 and accepted the consent/disclosure copy as it stands (Open Decision 3 / OA-3). Two consequences are recorded in place below: the copy review is complete (Gate 2), and the disclosure version stamp has been bumped to drop the word "draft" — it now reads livetranslate.disclosure.16sep2026.r1, wording unchanged. No consent grant could exist under the old stamp: the feature is not on master and no build of it has ever been distributed, so the bump retires nothing in the field. The release log-safety gate was re-run after the stamp edit and passed (Gate 3). Everything else in this pack stands as it was when the recommendation was made.

**How this review was done:** the design, security and evidence documents were read; the recorded test result bundles were re-read with the standard bundle tool (no suite is cited here without a non-zero test count — a suite that runs zero tests still reports success); the two cheap log-safety script gates were re-run in the worktree, both exit 0; no build or test target was run; no artifact was modified.

## Summary

**What was built, in outcome terms.** The user points the phone's camera at printed English text — an appliance panel, a remote, packaging, a sign, a menu — and sees it translated into the app's language (Nepali at launch), live, as an overlay on the camera view, without a photo ever being taken. A voice command and a Home-screen tile both open it. Translation is attempted first from an on-device dictionary. Only when the dictionary cannot resolve a phrase may the text — and only the text, never the picture — be sent to the assistant's cloud service, and only after the user has agreed. If the user withdraws agreement, or there is no network, the feature keeps working offline with the dictionary and cached translations. When nothing can translate a phrase, the original stays visible with an offline badge: the feature never invents a translation and never reports success when it did not translate.

**The change is additive.** No existing behaviour was replaced. It adds a new feature area (Services/LiveTranslate/), an app-layer view, one plugin registration, and small additive extensions to shared pieces: the log-sanitiser allow-list, the localisation string catalogue, and the camera purpose string. The shipped appliance helper's dictionary and cache were extended, not modified.

**What is verified.** All three release gates this final gate exists to check, reported in full in Release gates verified below: the recorded constitution exception (Open Decision 13) is present and text-only; the camera purpose string is updated and discloses both required facts; the release log-safety gate and its fixture harness both pass and cover the new OCR/translation paths, with every rule proven load-bearing. On top of that: the recorded test gates are green (205 tests in the TG10 gate bundle across 14 suites; 307 in the T033 gate bundle across 18 suites; 13 security-evidence tests; 174 tests across 11 suites in two scoped runs made after the master merge), and every cited suite was confirmed to have run a non-zero count. The STRIDE security design review and the security test both returned SECURITY-GO; all ten mandatory amendments are discharged with named tests.

**What is NOT verified — the things to weigh before deciding.**
1. **No device validation was performed.** All sixteen device checks (DV-1 to DV-16) are NOT RUN and every measurement in the record is a simulator measurement. The feature has not been run on a phone. Camera behaviour in real light, battery use and heat over sustained use, real airplane mode, the device speaker, and the real encrypted container are unmeasured. The three value decisions that depend on those measurements (OD1, OD2, OD5) are unmeasured — not "probably fine". Nothing in this pack is device evidence.
2. **No real cloud call was ever made in testing.** Every network assertion was made against a recorded request with a stub; live provider behaviour is unverified.

The third item this section carried when the recommendation was made — the consent/disclosure copy review owed by the owner under Open Decision 3 — was discharged at sign-off on 2026-09-17: see Gate 2 below.

Recommendation: see the Decision section.

## Release gates verified

### Gate 1 — the recorded constitution exception (Open Decision 13): PRESENT

Recorded in the project constitution on this branch as Open Decision 13, "Cloud text-translation exception (live camera translation)", RECORDED AS AN EXCEPTION WITH CONSENT AMENDMENT (2026-09-16), owner Anjan Poudel. The operative wording:

- Scope: "OCR'd text strings ONLY (never images, never photos) may be sent to Gemini for translation into the user's active language, when the on-device dictionary cannot resolve them AND the user has consented. … No health data, contacts, profile content, or camera imagery."
- Consent and disclosure: "explicit user consent at first cloud use with plain-language disclosure; a visible indicator while the cloud tier is active; revocable at any time — revoking degrades the feature to offline mode (dictionary + cached translations), never blocks it. Info.plist NSCameraUsageDescription must disclose the live-translation use and the text-to-cloud fallback."

The amendment is also cross-referenced from the constitution's Architecture Constraint 1 — "the live camera translation tier (Open Decision 13) is a consent-gated exception covering OCR'd text translation only" — and from the Privacy standard: "No personal data … transmitted to cloud for AI processing, except under the recorded exceptions (Open Decision 12, voice transcription; Open Decision 13, OCR'd text translation), each of which requires explicit user consent and plain-language disclosure. The shipped default engine stack is the cloud engine, so the consent/disclosure obligation attaches to the default path, not only to an opt-in."

The two confirmations requested of this review:

- **Does it cover text only?** Yes. The scope clause says "OCR'd text strings ONLY (never images, never photos)", and the same bullet excludes health data, contacts, profile content and camera imagery.
- **Do the consent/disclosure obligations attach to the default path rather than an opt-in?** Yes. The Privacy standard records that the obligation "attaches to the default path, not only to an opt-in"; and the feature constitution (rule 3) records that "the default configuration must not reach tier 2 without recorded consent". The cloud text tier is part of the feature's default ladder (not behind an experimental setting), which is exactly why the consent gate and the disclosure obligations are what make the shipped behaviour conformant.

Where it lives and when it lands: the amendment is committed on this branch in its own commits (separate from the feature code) and is part of the same change that would ship the feature; the branch is pushed to origin. It is not yet on master, because the branch has not been integrated. The cloud tier must not ship without the amendment, and it cannot: the amendment and the code travel in the same merge.

### Gate 2 — consent/disclosure copy and camera purpose string

Camera purpose string, current, from ios/ElderlyAssistant/Info.plist:

"The camera is used to verify medication intake, to photograph appliances, remotes, or screens when you ask for help using them, and to take an ordinary photo when you ask for one — that photo is then saved to your photo library. The camera is also used to read printed text aloud in your language with live translation. Appliance photos are sent to the assistant's cloud service so it can guide you. For live translation, only the text seen by the camera is sent — and only when the phone's own dictionary cannot translate it. Photos of that text are never sent."

- **(a) Does it disclose that the camera reads printed text for live translation?** Yes: "The camera is also used to read printed text aloud in your language with live translation."
- **(b) Does it disclose that only text — never the photo — is sent, and only when the on-device dictionary cannot translate?** Yes: "For live translation, only the text seen by the camera is sent — and only when the phone's own dictionary cannot translate it. Photos of that text are never sent."
- Wording nuance the owner considered at the copy review and accepted: the translation sentence says the text "is sent" without repeating "to the assistant's cloud service"; the cloud destination is named in the preceding sentence (about appliance photos). That is a wording judgement, not a missing fact.

Two planning comments in the repository still describe this string as not yet updated (a comment in the workflow definition and a parenthetical in the feature constitution's Standards section). Both predate the update; the shipped string is the one quoted above, and the copy test asserts the disclosure is present in the real file.

The consent prompt shown at first cloud need exists in the string catalogue, Nepali first. Its central disclosure line, English: "When a word isn't in the phone's own dictionary, the text on this screen — only the text, never the picture — is sent to the assistant's cloud service to be translated. Nothing is sent until you agree, and you can stop it any time." Prompt title: "Use the internet to translate?"; accept: "Yes, use the internet"; decline: "No, keep it on this phone"; stop control: "Stop using the internet for translation".

The disclosure version stamp recorded on a consent grant read livetranslate.disclosure.draft.16sep2026.r1 — with "draft" in it — while the review was open. At the owner's review on 2026-09-17 it became livetranslate.disclosure.16sep2026.r1. The recorded rule (owner action OA-3): if the copy changes when it is reviewed, this stamp must be bumped so previously granted consents do not carry over to the new wording. The wording did not change, so no wording-driven carry-over arises; the bump was applied so that the stamp no longer reads "draft", and it is the mechanism that would have retired a stale grant had one existed. None did: the feature is absent from master (verified — master holds no file under Services/LiveTranslate/) and no build of it has been distributed, so there was no field consent to invalidate.

**Consent/disclosure copy review (Open Decision 3): COMPLETE — owner review, 2026-09-17; copy accepted as written.** The two catalogue keys that were held DRAFT, exactly as they stand and as accepted:

| Catalogue key | English | Nepali | Status |
|---|---|---|---|
| livetranslate.snapshot.capture | "Hold this picture" | "यो दृश्य रोक्नुहोस्" | ACCEPTED at sign-off 2026-09-17. Catalogue comment still reads "DRAFT: awaiting the owner's OD3 copy review at final sign-off" — see the staleness note below. |
| livetranslate.snapshot.live | "Go live again" | "फेरि चलाउनुहोस्" | ACCEPTED at sign-off 2026-09-17. Catalogue comment still reads "DRAFT: awaiting the owner's OD3 copy review at final sign-off" — see the staleness note below. |

**One residual left by that acceptance, recorded rather than tidied.** The DRAFT wording lives in the two catalogue comments in ios/ElderlyAssistant/Resources/Localizable.xcstrings (and in a comment in the copy test that pins those keys). Those comments now describe a review that is complete. They are developer-facing comments, not user-visible strings — the shipped English and Nepali values are the ones in the table above and are unchanged. They were left untouched deliberately: the comments are the pin that made the copy debt visible, and editing a pinned artifact in the same change that records the sign-off would blur the two. Clearing them is a follow-up, not a condition of this sign-off.

These are the freeze-frame control's two labels (one control, two states). They are pinned by the copy test so that a third unreviewed string cannot be added silently. All 26 feature strings have both English and Nepali values and pass the copy tests, which assert properties (present, localised, truthful) rather than final wording.

### Gate 3 — release log-safety gate: PASSES, and covers the new OCR/translation paths

Re-run in this worktree for this review; both commands exited 0. The release gate was run once more after the sign-off stamp edit (the only source change made at sign-off) and passed again, exit 0, with the same 24 fixtures over 12 rules.

- The release gate script (ios/tools/check-release-log-safety.sh): passes. It runs the rule engine over the whole source tree — including the feature's new roots — and then runs the gate's own fixture suite. Reported output: no transcript content or raw error object can be printed in a non-Debug configuration, and the live-camera-translation sources carry no console write or content-bearing event field.
- The fixture harness (ios/tools/check-release-log-safety-fixtures.py) with its falsification flag: passes. 36 cases over 12 rules; every rule proven load-bearing (disabling a rule makes its positive fixture pass — i.e. the rule was catching something real). The build-path run is 24 fixtures over 12 rules; every rule has a positive and a negative fixture, and a missing fixture fails the gate rather than skipping it.

Coverage of the new paths: four feature rule families were added — any console write in the feature's sources (Release builds only), any print that renders recognised or translated text (every build configuration), any event metadata key outside the sanitiser's allow-list, and any text value interpolated into an event field. The gate is wired into the build script's test path ahead of every test scope (unit, UI and full), so no test gate can run with a re-introduced raw content print; it is build-blocking, not a report.

Stated limits, recorded by the gate itself and repeated in the evidence index: it is a source-level check that cannot follow every indirection (a helper's return value, a wrapper function, a metadata variable), and the falsification run is a recorded manual run rather than a per-build step. The runtime allow-list tests are the primary safeguard; the gate is the second line.

## Change summary (what changed)

- New feature sources: the Services/LiveTranslate/ service area — camera session with no photo output, text detector, region stabiliser, curated-dictionary extension, encrypted translation cache, consent gate and prompt, text-only cloud tier, overlay placement and views, in-session commands, config.
- App layer: the feature's screen and the Home tile entry.
- Plugin registration: one registration in the plugin registry (AppCoordinator.swift), built lazily — registering costs nothing until the feature is opened.
- Shared seams extended additively: the log-sanitiser metadata allow-list (45 keys = 27 shipped + 18 new, with the set-equality verified); the localisation catalogue (26 new strings, Nepali first); the camera purpose string; a detect-only accessor on the transcript sanitiser so the marker list has one source; the curated dictionary (~120 entries).
- Owner-directed additions beyond the 30 planned tasks: T-032 (the translation cache and consent record now sit under a real cipher — AES-GCM, Keychain-held key, versioned envelope; key loss recovers as an empty cache) and T-033 (snapshot / freeze-frame mode, in-memory only). T-031 (a Devanagari recogniser) was dropped when the platform probe found the on-device OCR has no Devanagari capability on the target runtime; v1 is English source only, re-locked with owner sign-off.

## Requirements traceability

23 functional requirements (FR-LCT-001…023) and 13 non-functional (NFR-LCT-001…013), in a hash-locked snapshot (36/36 hashes recomputed at the security-test gate; the lock records the one owner-signed amendment — FR-LCT-003 narrowed to English source only). Two supporting documents carry the detail: specs/LCT-security-evidence-index.md maps every binding security amendment (AM-1…AM-10) to the named tests that discharge it, and specs/implement-notes.md records the per-group gate counts.

| Area | Requirements | Implementation | Test evidence (all suites non-zero, all passed) |
|---|---|---|---|
| Camera capture and disclosure | FR-LCT-001, FR-LCT-002 | No photo output; permission surfaces; purpose string | camera-capture 6; copy 10; snapshot 25 |
| Detection and stabilisation | FR-LCT-003 (English source, as amended), FR-LCT-004…006 | Text detector; stabiliser (hysteresis, declutter, region cap) | text detector 17; stabiliser 18; OCR fixture page 1 (8 regions from an 8-line page, 6/6 words read) |
| Dictionary and cache | FR-LCT-007, FR-LCT-019, FR-LCT-020; NFR-LCT-008 | Curated dictionary; persistent encrypted shared cache (T-032) | cache 21; cipher storage 16 (plus a recorded falsification run of the byte-level ciphertext assertion) |
| Cloud tier and consent | FR-LCT-009…014, FR-LCT-023; NFR-LCT-005/006/007/009 | Fail-closed consent gate; text-only request; activity indicator; sanitiser | consent gate 29; consent prompt and revocation 22; tier 25; client translate 15; allow-list 24; scene sanitiser 17; detect-only seam 11; events 17; source hygiene 6; boundary 7; evidence index 5; pipeline 18 |
| Overlay and accessibility | FR-LCT-015…018; NFR-LCT-003 | Smart-mix overlay; callouts; always-show-original toggle; honest states | overlay placement 28; overlay view 14; toggle 11; app-layer hygiene 11 |
| Voice and session | FR-LCT-021, FR-LCT-022 | Command parser; spoken output; plugin entry and lifecycle | parser 49; command capture 26; speech 33–34; plugin 10; session model 17 |
| Cost governance | FR-LCT-013; NFR-LCT-013 | Shipped per-day governor shared with voice (OD7 directive); fails closed, latches for the session | tier suite 25 |
| Release and compliance | NFR-LCT-013 | Log-safety gate and fixtures; requirements lock | both gates re-run green today; 36/36 lock hashes |
| Shared-behaviour integrity | NFR-LCT-012 | Additive edits only to shared seams | appliance-helper area 137 tests, unedited sources |

Recorded runs, all re-read from the result bundles for this review: TG10 gate 205/205 across 14 suites; T033 gate 307/307 across 18 suites; security-evidence 13/13 across 3 suites; post-merge scoped 151 + 23 = 174 across 11 suites.

## Security posture

The security design review (STRIDE, all six categories, checked against the actual code) returned SECURITY-GO with ten mandatory amendments (AM-1…AM-10). Its strongest properties are structural rather than procedural:

- Image egress is impossible rather than forbidden: the camera session configures no photo output, nothing writes a frame anywhere, and the one translation request builder has no parameter an image could travel in. Tests decode every outgoing request — including the retry — with a positive control proving the check does find a real image part where one legitimately travels (the shipped appliance-photo path).
- The translation request has no action surface: one text part, no tools, only the requested ids with string values accepted; nothing in the feature acts on model output.
- The consent gate fails closed on every non-granted state; a withdrawal denies in memory first, cancels work in flight, and cannot be defeated by the retry (the one genuine evasion window found in design — a cancelled request looking transient — was closed and is pinned by test).
- The cloud-activity indicator has one input, is released when the last request ends, and cannot be suppressed while a request is in flight.
- The cache and the consent record are encrypted at rest under a real cipher (T-032), asserted at the byte level rather than by round-trip alone.

The security test review re-derived the evidence and returned SECURITY-GO: all ten amendments discharged with named tests; per-category passes for the consent gate, text-only egress, log safety, offline-degradation honesty, cost governor, cipher at rest, snapshot inclusion, and the requirements lock; the merge-touched security surfaces re-run after the merge with 174 tests and zero failures.

### Not verified — the eight residuals carried forward from the security test report

1. Device validation was not performed: DV-1 through DV-16 are NOT RUN, OD1, OD2 and OD5 are unmeasured, and owner actions OA-1 through OA-5 are open, as recorded in the device-validation protocol and results files. All evidence in this review is simulator-only; camera permission flows, Keychain and data-protection behaviour on hardware, and provider behaviour on device are not verified.
2. Real provider calls were not exercised: all egress evidence is at the client boundary with stubs and decoders. Live endpoint behaviour, provider-side handling, and real upstream error text are not verified; the no-upstream-derived-error-code invariant is verified structurally, not against live traffic.
3. The post-merge re-runs are scoped, not full-suite: the egress boundary, snapshot, tier, plugin and capture suites were not re-executed after the merge; "that suite passes on the post-merge tree" is an inference from unchanged inputs, not a recorded re-run. (The two bundles were also cited by no spec note until the security-test review located them.)
4. The master unit baseline remains red (about 21 pre-existing failures, unrelated to this feature). The scoped suites are the mitigation; no full-suite green is claimed.
5. One load-sensitive determinism test was observed flaky during the snapshot task; it is attributed in the notes, not eliminated.
6. The release log-safety gate cannot see through indirection; that limit is stated in the design, and the typed emitters plus the source-hygiene suite are its complement, not a replacement.
7. Two copy keys were held DRAFT pending the consent and disclosure copy review at final sign-off (owner), together with Open Decision 3. That review was completed at sign-off on 2026-09-17 with the copy accepted as written; the stamp was bumped and the catalogue comments that still say DRAFT are noted as stale in Gate 2.
8. Residual SR-1 (the provider's block reason emitted from one pre-existing shared site — pinned to that site, never on a feature event) and residuals T-2 (the consent record's on-device integrity rests on platform file protection, not an authentication tag) and SD-5 (with the cloud voice engine active, one screen can have two cloud paths but only the translation indicator; input to the joint Open Decision 12 / 13 review) stand as ruled in the security design review.

## Open items

Owner actions (OA-3 closed at sign-off; the rest open; owner: Anjan Poudel):

| # | Action | Why it is the owner's | State |
|---|---|---|---|
| OA-1 | OD1 — fix or confirm the OCR cadence and thermal values | needs device checks DV-2 / DV-10 / DV-15 | Open — unmeasured |
| OA-2 | OD2 — confirm the always-show-original default and the in-place rule | needs the DV-3 device demo | Open — unmeasured |
| OA-3 | OD3 — review the consent/disclosure copy and the purpose-string wording; if the copy changes, bump the disclosure version stamp | a copy and disclosure judgement, with a reader in front of the prompt (DV-6) | CLOSED 2026-09-17 — owner accepted the copy as written; stamp bumped to livetranslate.disclosure.16sep2026.r1 |
| OA-4 | OD5 — confirm the declutter thresholds | needs DV-13 / DV-16 on real dense pages | Open — unmeasured |
| OA-5 | Run the device validation itself (DV-1…DV-16), then the constitution's pre-release device console check on a Release build before submission | only the owner has the hardware | Open |

Draft and known-limitation items carried forward:

- The two catalogue comments that still say DRAFT (Gate 2) — the copy debt they pinned is discharged, but the comments are the stale half of the pin and were left for a follow-up rather than edited in the change that records the sign-off.
- The log-safety gate's two stated limits: indirection, and falsification being a manual recorded run (a rule could regress to firing only in company between runs; the build path still catches a rule that stops firing entirely).
- The aborted result bundle TG10-ocr.xcresult holds zero tests and must never be cited as evidence; the real OCR evidence is inside TG10-gate.xcresult.
- Evidence retention: one earlier gate bundle can no longer be read by the result-bundle tool, and two groups retained no bundle, so three group counts rest on the notes rather than on recorded bundles.
- Closed since the review-implementation report was written: specs/implement-notes.md section 1 previously mapped the task groups to the wrong task IDs from TG-02 onward (for example it gave TG-03 as T-011…T-013 rather than T-009/T-010). The table was corrected against the task tree, the corrected version is what is committed at HEAD, and the plan and task files were always correct. No evidence ever depended on it. (The review-implementation report flagged this correctly; the copy of the finding carried into an earlier draft of this section was stale.)
- The snapshot-view coverage figure is a test-selection artefact, declared rather than dressed up.
- Closed since the notes were written: the design document's cache-encryption invariant row now names the cipher layer (corrected at 7f8d248).

Load-sensitive determinism test: one pipeline determinism test added by this feature failed once under heavy machine load and passed on every other run, including the retained final gates. The difference was exactly when a cloud answer was published relative to a fixed sleep — a wall-clock race under load, in synchronisation this feature added. It is reported rather than hidden; the fix belongs to the task that owns that file.

Residual security risks: SR-1, T-2 and SD-5 (detail in Security posture). SR-1's recommended hardening (validating the provider's block reason against a closed token set) is explicitly out of this feature's scope.

## Rollback plan

In plain terms there are four real levers, and no others. There is no CI pipeline and no deployment machinery in this repository — integration and rollback are manual; and there is no remote kill switch, because the encrypted remote-configuration channel is not implemented (a recorded descope).

1. Before integration — do nothing. The feature exists only on the branch worktree-live-camera-translation (pushed to origin); master does not contain it (verified: no file under Services/LiveTranslate/ on master). Not merging it is a complete rollback.
2. After integration — revert the change. Integration is expected via a pull request; after a merge, roll back by reverting that merge commit (the git revert command with -m 1 against the merge commit). The change is additive — new directories plus small additive edits — so the revert restores the previous behaviour cleanly. Then verify the way every change is verified here: build the app, run the scoped tests, re-run the two log-safety script gates. The constitution amendment (Open Decision 13) sits in its own commits, so it can be retained deliberately for a future re-landing while the code is reverted.
3. After shipping — in-product levers, best first:
   - The user (or family) revokes translation consent: the cloud text send stops immediately and the feature continues in offline mode. This is the product-level off switch this feature has; it is reachable from the translation screen and from Settings.
   - Unregister the plugin: remove the single registration in the app's plugin registry (AppCoordinator.swift). The voice command and the Home tile then report "unavailable" explicitly through a recorded, tested error path (an event plus a spoken line) instead of failing silently; the feature becomes unreachable.
   - Lower the family-set cloud budget (Settings → Gemini AI) to its floor of 10 calls per day: bounds spend, but it is shared with the voice pipeline and cannot go to zero.
   - Remove the Gemini API key: stops all Gemini use, including the cloud voice engine. Blunt and not translation-specific; last resort.
4. Not available: a remote flag to disable only this feature in the field. Any field change requires a new app build. Also note there is no App Store build of this feature yet — no archive or TestFlight build exists (recorded in the device-validation results) — so today a rollback is purely a repository action.

## Compliance checklist

| Item | Verdict |
|---|---|
| Constitution exception (Open Decision 13) recorded, text-only scope, consent-gated | PASS — recorded 2026-09-16; quoted in Gate 1; committed on the branch |
| Consent/disclosure obligations attach to the default path, not an opt-in | PASS — recorded in the Privacy standard and feature constitution rule 3 |
| Consent gate enforced before any egress | PASS — fail-closed gate; withdrawal mid-scene leaves zero further requests, including on the retry (boundary evidence suite) |
| No image egress on any path, including the retry | PASS — structurally impossible; every recorded request decoded: one text part, no media; positive control proves the check works |
| Log safety gated at build time and covering the new OCR/translation paths | PASS — wired ahead of every test scope; both gates re-run green today; 12/12 rules proven load-bearing |
| Camera purpose string updated and disclosing both required facts | PASS — quoted in Gate 2 |
| Consent/disclosure copy reviewed | PASS — owner review completed 2026-09-17 (Open Decision 3 / OA-3); copy accepted as written; stamp bumped to livetranslate.disclosure.16sep2026.r1; stale catalogue DRAFT comments noted in Gate 2 |
| Device validation | NOT PERFORMED — DV-1…DV-16 NOT RUN; simulator-only evidence; OD1 / OD2 / OD5 unmeasured |
| Requirements lock intact | PASS — 23 FR / 13 NFR; 36/36 hashes recompute; the FR-LCT-003 narrowing is owner-signed and recorded |
| No regression to shared behaviour (NFR-LCT-012) | PASS within the evidence — appliance-helper suites green; shared governor and overlay mapper untouched against the merge base |

## Decision

decision: GO

**GO — recommended by this review and signed by the owner.** Every gate criterion this review can verify is met, and each was re-checked rather than taken on trust: the exception amendment is recorded (Gate 1); the purpose string is updated and discloses both required facts (Gate 2); the log-safety gate passes and covers the new paths, with every rule proven load-bearing (Gate 3); all ten security amendments are discharged with named, passing tests; and the recorded test gates are green with every cited suite confirmed non-zero.

This recommendation was not itself the sign-off. **The owner gave the T2 sign-off on 2026-09-17** through the human approval step (HIL item b6d85d84-1847-4849-9688-39d89091686f, resolved 2026-09-17T02:37:01Z), accepting the consent/disclosure copy as written.

Two things remain, and they are the owner's. Neither was a condition of the sign-off; both are conditions of shipping:

1. The device validation run (DV-1…DV-16), then the constitution's pre-release device console check, before any store submission. The feature has not been tested on a phone, and nothing in this pack is device evidence. DV-1…DV-16 stand recorded as the pre-submission owner action.
2. The OD1 / OD2 / OD5 value decisions, once item 1 produces measurements.

The third item this section carried when the recommendation was made — the consent/disclosure copy review — closed at sign-off: see Gate 2. If the owner prefers to hold the change until the device run is complete, nothing here resists that: the engineering work is complete and additive, and the Open items section is the list of what remains.
