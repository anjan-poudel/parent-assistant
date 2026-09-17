# Implement phase — live-camera-translation (English → Nepali, v1)

description: Implementation record for the live-camera-translation feature. Thirty planned tasks
(T-001 … T-030) across ten task groups, plus two owner-directed additions — T-032 (authenticated,
encrypted at-rest storage for the translation cache and the consent record) and T-033 (snapshot /
freeze-frame mode). Task T-031 was dropped by owner directive. All work was carried out in the git
worktree `worktree-live-camera-translation`; every gate was scoped with `-only-testing:` and every
per-suite count was read from the result bundle rather than from the exit code.

## 1. Scope and task inventory

The plan (`specs/plan-tasks/plan.md`) groups the thirty tasks into ten groups:

| Group | Theme | Tasks |
| --- | --- | --- |
| TG-01 | Foundations — config, errors, observability keys, sanitiser seam, catalog | T-001 … T-005 |
| TG-02 | Camera and text detection | T-006 … T-008 |
| TG-03 | Region stabilisation | T-009, T-010 |
| TG-04 | Dictionary and translation cache | T-011 … T-013 |
| TG-05 | Consent and disclosure | T-014 … T-016 |
| TG-06 | Cloud translation tier | T-017 … T-019 |
| TG-07 | Overlay | T-020 … T-022 |
| TG-08 | Voice and session commands | T-023 … T-025 |
| TG-09 | Plugin session pipeline | T-026, T-027 |
| TG-10 | Release gates and evidence | T-028 … T-030 |

Two tasks sit outside the original plan, both owner-directed:

- **T-032** — cipher-backed storage. Before this task, `EncryptedFileStorage` wrote its
  `Envelope { key, payload }` as JSON with the payload in the clear, relying on Data Protection
  (`.completeFileProtection`) alone. T-032 introduces AES-GCM (CryptoKit) with a Keychain-stored
  symmetric key and a versioned envelope (magic / nonce / ciphertext / tag). Key loss is a
  recoverable condition: the key is regenerated and the cache starts empty; the path never traps.
  The translation cache **and** the consent record both sit on the same `RawEncryptedStorage` seam
  and are both covered.
- **T-033** — snapshot (freeze-frame) mode. A single capture control in the reserved top strip
  holds the current camera buffer in memory only, runs the existing `LiveTextDetector` over that
  frame at full resolution, and renders the existing smart-mix overlay on the frozen frame with
  identical tap-to-hear behaviour. It reuses the detector, tier ladder, cache and overlay renderer;
  it does **not** construct or consult the region stabiliser. The frozen frame is never sent to the
  cloud — only OCR'd text enters the text-only tier (OD-13, "never images").

**T-031 was dropped.** v1 is English source → Nepali target. Nepali/Devanagari OCR is not v1 scope,
so no custom Devanagari recogniser task was implemented. FR-LCT-003 is to be amended to
English-source-only at the security-test re-lock.

## 2. Group results

Each row is the gate that group ran, with the counts taken from the result bundle.

| Group | Gate result | Notes |
| --- | --- | --- |
| TG-01 | 106 tests, 0 failures, exit 0 | Scoped to the group's suites. Baseline-wide run recorded 3340 tests / 21 pre-existing failures, none in this group. |
| TG-02 | 68 tests, 0 failures | 3408 / 3380 passed / 21 failed / 7 skipped baseline-wide; no TG-02 suite among the 21. |
| TG-03-04 | Gate 1: 107 tests, 0 failures. Gate 2: 137 tests (shipped appliance area, unedited) | Gate 2 is the NFR-LCT-012 evidence that shipped behaviour is unchanged. |
| TG-05 | 144/144, exit 0 | `./build.sh build` → BUILD SUCCEEDED. |
| TG-06 | 57 tests, 0 failures | CloudTranslationTier 25, GeminiClientTranslate 15, SceneTextSanitiser 17. |
| TG-07 | 99/99, 74 new | LiveOverlayPlacement 28, Geometry 10, OverlayView 14, Toggle 11, AppLayerHygiene 11. |
| TG-08 | Parser 49/49; voice 59/59 | Parser suite 24/24 new; speech 33/33 and command capture 26/26. Wide run 205/205. |
| TG-09 | 92/92 across seven suites | Build SUCCEEDED; log-safety exit 0; coverage 98.6 / 91.4 / 100 / 74.4 percent across the touched files. |
| TG-10 | 205/205 across 14 suites | Log-safety gate 24 fixtures over 12 rules; falsification run 36 cases with 12/12 rules load-bearing; `./build.sh build` exit 0. |
| T-032 | 136/136 across nine suites | Adjacent shipped suites 108 tests, 0 failures. |
| T-033 | 307/307 across 18 suites | SnapshotModeTests 25/25. Build SUCCEEDED; log-safety exit 0. |

The T-033 figure was re-verified independently from `ios/build/T033-gate.xcresult` after the run
(`result: Passed`, 307 total, 0 failed, 0 skipped, 18 suites, no suite with failures).

## 3. Verification practice held across the phase

Three controls were applied to every gate, because the obvious signal is not trustworthy here:

1. **XcodeGen before every gate.** `./build.sh generate` runs before each gate, and
   `project.pbxproj` is never hand-edited. The reason is a false-green hazard: a test suite whose
   class is absent from the generated project runs nothing at all and still reports success.
2. **Per-suite counts from the bundle, never the log or the exit code.**
   `xcrun xcresulttool get test-results summary --path <bundle>` is the authority; every suite in a
   selection is confirmed to have run a non-zero number of tests. `-resultBundlePath` refuses to
   overwrite an existing bundle, so bundles are removed before each run.
3. **Scoped gates against an honest baseline.** The unit-test baseline on `master` is red: roughly
   21 pre-existing failures across about eleven suites, unrelated to this feature. Those were
   neither chased nor "fixed". Every gate in this phase was scoped with `-only-testing:` to the
   suites the group owns or can affect.

One concrete instance of the value of (3): an early run of TG-05's task reported TEST SUCCEEDED with
78 tests while all 66 newly written tests had never executed. The bundle showed it; the log did not.

## 4. Owner directives honoured

- **OD7** — the shipped per-day `GeminiCostGovernor` remains the spending bound for the cloud tier.
  No new budget mechanism was introduced.
- **OD8** — the name `LabelTranslationCache` is kept. The type was generalised to the persistent,
  encrypted, dictionary-seeded cache described in the design, without a rename.
- **OD-13** — never images. The cloud tier's request type carries text only; see section 5.

## 5. Never-images enforcement (OD-13, AM-10)

The claim that no image can leave the device is enforced structurally rather than by convention,
along four independent lines, each of which can fail on its own:

1. The cloud request item type has no image field at all, so there is nothing to serialise one into.
2. A test walks both the built request JSON and the serialised `URLRequest` body for image, media
   and attachment parts, and a positive control confirms the same check *does* find the real
   `inlineData` part in the shipped vision client — so the check cannot pass by being blind.
3. A source scan over the feature for forbidden shapes (Photos APIs, capture outputs, pickers,
   share sheet, encoders, disk writes), with controls that fire on shipped code which legitimately
   carries those shapes.
4. A file-system listing delta across a real freeze, proving nothing was written.

## 6. Binding amendments

The security design review returned SECURITY-GO with mandatory amendments AM-1 … AM-10. Their
implementation status and the test that discharges each is tabulated in
`specs/LCT-security-evidence-index.md`. Three amendment owners called out in the review:

- **SD-1** (consent revoke fail-closed floor) — owned by the consent tasks, implemented and tested.
- **SD-2** (log-gate extension) — owned by the release-gate work; the gate gained four feature rule
  families and now covers console writes, content-bearing prints, unlisted metadata keys and
  text interpolated into events. See section 7.
- **CL-2** (cancellation-shaped errors are terminal and never retryable) — owned by the cloud-tier
  task and pinned by test.

`specs/design-component.md` was corrected under AM-5 / SD-2 so the log-safety invariant names the
four rules, their roots, and the instruction to treat gate-invisible indirection as a gap.

## 7. Release log-safety gate

`ios/tools/check-release-log-safety.sh` (implemented by `check-release-log-safety.py`, 818 lines)
gained four rule families for this feature and a companion fixture harness:

- `feature-console-write` (Release only), `feature-content-print` (every configuration),
  `feature-unlisted-metadata-key`, `feature-text-interpolated-into-event`.
- `ios/tools/check-release-log-safety-fixtures.py` runs the real engine as a subprocess once per
  fixture. A rule with no fixture is itself a failure, and `--falsify` disables each rule in turn
  and requires its positive fixture to go red — so every rule is demonstrated to be load-bearing
  rather than merely present. 24 fixtures over 12 rules; the falsification run exercises 36 cases
  and reports 12/12 rules load-bearing.
- The disabling switches are CLI-only by design, so no build setting can weaken the gate.

The gate reports two honest limits, recorded in the script itself: it cannot see through
indirection (a helper that returns a value, a metadata dictionary built in a variable, a wrapper,
an unknown sink), and falsification is a recorded manual run rather than a per-build step. The
runtime allow-list remains the primary safeguard; the gate is a second line.

## 8. What the implement phase could not establish

These are carried forward as open items, not as silent gaps.

1. **No device validation was performed.** Every check in `specs/LCT-device-validation-protocol.md`
   (DV-1 … DV-16) is recorded as NOT RUN in `specs/LCT-device-validation-results.md`, each with its
   reason: no physical device was available and no genuine airplane-mode run was possible. Camera,
   paper, real light, battery, thermal envelope, real radio, real container protection class, device
   audio path and Instruments-on-release all require hardware. Consequently the owner decisions that
   depend on measurement (OD1, OD2, OD5) have no measurement behind them; the results file says
   "unmeasured" rather than "probably fine" and lists them as owner actions OA-1 … OA-5.
   Nothing in that file is presented as a device run; the simulator is named as a simulator.
2. **Devanagari OCR is not available in v1.** A recorded capability probe found the Vision text
   recogniser reporting revision 3 with 30 supported languages, none of them Devanagari-capable,
   and accepting an unsupported language code silently rather than erroring. An English control
   recognised at 1.0 confidence. This is why FR-LCT-003 is to be re-locked as English-source-only.
3. **One load-sensitive test, attributed and not fixed.** A pipeline determinism test in T-026's
   area failed once under heavy machine load and passed on every other run including in isolation.
   The diff was exactly *when* a cloud answer was published relative to a fixed sleep, i.e. a
   wall-clock race under load, in synchronisation this feature added but not in the snapshot work.
   It is reported rather than papered over; the honest fix is a synchronisation redesign owned by
   the task that owns the file.
4. **A defect was found and fixed in eight existing checks.** Seven sites plus one outside the
   feature used `range(of:options:.regularExpression)` with a Devanagari range. That API declines
   any match whose range would split a grapheme cluster, and the `\u{0900}` escape form used in the
   pattern is rejected by `NSRegularExpression` and was being swallowed. A leaked sentence in the
   elder's own language could therefore have satisfied a check written to forbid exactly that. All
   eight sites now use the scalar idiom, and a guard test scans the suite directory for a return of
   the regex form and carries two falsifiability controls.
5. **Two new catalogue keys are drafts** and owe the owner's copy review at final sign-off, along
   with the rest of the elder-facing copy. They are pinned in the copy suite so a third key cannot
   be added unreviewed.
6. **An aborted run left an empty result bundle** (`build/TG10-ocr.xcresult`, zero tests,
   `result: unknown`). It is flagged so that no one cites it as evidence; the real OCR evidence is
   the attachment inside `build/TG10-gate.xcresult`.
7. **A stale invariant row remains in `specs/design-component.md`.** The row stating that the cache
   is encrypted at rest with no plaintext file still attributes encryption to Data Protection and
   does not name the T-032 cipher. It should be corrected at or before the security-test re-lock so
   the design document matches the shipped mechanism.

## 9. State of the tree

- All work is in the worktree `worktree-live-camera-translation`. Nothing was committed.
- `project.pbxproj` was never hand-edited; it is regenerated by XcodeGen.
- `ios/tools/**` and the fixtures tree are new or extended as described in section 7.
- Production code lives in the app target's `Services/LiveTranslate/` directory, with the app-layer
  view under `App/LiveTranslate/` and the plugin registration under `Services/Plugins/`.
- Test code lives under `ios/ElderlyAssistantTests/Services/LiveTranslate/`.

## 10. Evidence index

`specs/LCT-security-evidence-index.md` maps AM-1 … AM-10 to the tests that discharge them and lists
evidence items E1 … E8, the residual security risk SR-1 (pinned, not retired) and the known
limitations. It is the document the security-test gate should read first.
