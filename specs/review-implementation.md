# Review — implementation, live-camera-translation (EN→NE, v1)

Artifact under review: `specs/implement-notes.md`, for task `review-implementation`.
Read with: `specs/LCT-security-evidence-index.md`, `specs/security-design-review.md`, `specs/design-component.md`, `specs/plan-tasks/plan.md` and the task files, the group notes, and `specs/LCT-device-validation-results.md`.
Method: the notes were treated as claims. Every cheap check was re-derived rather than trusted — result bundles via xcresulttool, the two log-safety script gates re-run in this worktree, and source and diff spot checks against the branch merge base. No build was run.

## Summary

The phase satisfies the feature constitution's Standards. The required pure-logic and integration coverage exists and is green in retained result bundles; the security-relevant behaviour matches the binding amendments at the source level; the release log-safety gate passes and is demonstrably load-bearing. The verdict is GO, with four corrections carried forward that do not block this gate (section 6).

### 1. Gates re-verified from the result bundles (observed, not asserted)

| Bundle | Observed | Notes' claim |
| --- | --- | --- |
| T033-gate | 307 passed, 0 failed, 0 skipped, 18 suites, every suite non-zero | 307 / 18 suites |
| TG10-gate | 205 passed, 0 failed, 14 suites (boundary 7, index 5, OCR fixture 1) | 205 / 14 suites |
| TG10-evidence | 13 passed (7 + 5 + 1) | 13 |
| TG09-gate | 92 passed across the seven named suites | 92 / 7 suites |
| TG05-gate / TG07-gate / TG02-gate | 144 / 99 / 68, 0 failed | 144 / 99 / 68 |
| TG06-pinned | 57 passed (tier 25, client translate 15, sanitiser 17) | 57 |
| TG08-parser-gate / TG08b-gate-final | 49 / 59, 0 failed | 49 / 59 |
| T032-gate / T032-adjacent | 136 across 9 suites / 108 | 136 / 108 |
| TG10-ocr | 0 tests, result unknown | declared unusable |

Three points that matter more than the totals:

- Every suite inside every bundle I read reports a non-zero count, so the false-green hazard (a suite absent from the generated project runs nothing and still reports success) is not present in the cited evidence.
- `TG10-ocr.xcresult` holds zero tests and is declared unusable; it is not cited as evidence anywhere. The OCR fixture test did run inside `TG10-gate.xcresult` (1 test, passed) and its activity tree carries the `ocr-fixture-measurement` attachment.
- `TG10-evidence.xcresult` carries the boundary and index evidence suites plus the OCR fixture, 13 tests, all green.

### 2. Script gates re-run from this worktree (all green)

- The release log-safety gate (`ios/tools/check-release-log-safety.sh`) — exit 0, 24 fixtures over 12 rules.
- Its fixture harness (`ios/tools/check-release-log-safety-fixtures.py`) — exit 0.
- The same with `--falsify` — exit 0, 36 cases, 12 of 12 rules proven load-bearing. This independently confirms the AM-5 claim rather than reading it from the notes.
- The gate is genuinely wired ahead of every test scope inside `run_tests` in `ios/build.sh`, as AM-5 requires.

### 3. Source spot checks against the binding rules

- Consent cannot be skipped: `translateStrings` requires a `Grant` whose initialiser is fileprivate, so the gate's `authorize()` is its only producer, and the tier mints a fresh proof before every attempt including the retry (AM-1, AM-7).
- Text only, never media: one text part, `tools` explicitly nil, no image, media or attachment parameter on any signature, and no field on the request item an image could travel in. Tests decode every recorded request including the retry; no live network is used (the transport seam is a test double). OD-13 and AM-9/AM-10 hold by construction.
- Withdrawal: deny-in-memory precedes storage, the delete is verified by read-back, a surviving grant is tombstoned, an unverifiable one is reported as a failure; a revocation cancels registered in-flight work and a cancellation-shaped error is terminal and never retried (AM-1, AM-4).
- Cache at rest: AES-GCM via CryptoKit, Keychain key with WhenUnlockedThisDeviceOnly and not synchronised, versioned envelope, storage key as authenticated data, key loss recovers as an empty cache without trapping (T-032). The type name `LabelTranslationCache` is kept and generalised (OD8); the stored ordering field is a monotone counter (AM-6).
- Camera: one `AVCaptureVideoDataOutput`; the capture protocol has no entry point that could construct a photo output. The snapshot path holds one CGImage in memory, writes nothing, and reuses the one detector, tier and renderer.
- OD7: the shipped governor and the overlay mapper are untouched against the merge base; the config explicitly refuses to own a cap; the tier consumes the governor as shipped and latches for the session when the cap is reached.
- Additive-only shared edits: the sanitiser allow-list differs from the base by a comma and one conditional; the localizer adds entries; the transcript sanitiser gains a detect-only accessor with the anti-copy prohibition; the speech queue gains a source-scoped drain.
- No print, NSLog or os_log in the feature sources; no hardcoded timeout — the deadline is derived from the shipped client timeout plus a configured grace.
- The camera purpose string now discloses live translation and the conditional text-only send.

### 4. Role checklist

| Item | Verdict | Basis |
| --- | --- | --- |
| Every interface method has an explicit error return type | Pass | Typed Swift enums and Result throughout; no untyped escape hatch; no failure case collapsed into another |
| Every async or external call documents a failure mode and recovery path | Pass | A retryability policy exhaustive with no default, per-region degradation, and failure isolation asserted in the pipeline tests |
| Timeouts and retry limits are configurable | Pass | Retry budget, deadline grace, cadence and thresholds live in one config type; the deadline is derived so no second value can diverge; the consent prompt has no timeout by design (it is a prompt, not a call) |
| Every element traces to an FR or NFR | Pass | The plan maps all 23 FR and 13 NFR; the evidence index maps amendments to tests; non-goals are absent by construction with tests that would fail if introduced |
| The design describes what the operator sees on success and failure | Pass | Pending, resolved and degraded rendering with the original text always shown; unavailable and quarantined copy with Nepali first; the consent prompt and its failure note; the cloud indicator |

### 5. Owner directives and amendments

- OD7 — the shipped per-day governor remains the spending bound. Verified: no new budget mechanism, the governor file is unmodified against the merge base.
- OD8 — `LabelTranslationCache` kept as the name, generalised in place. Verified.
- OD-13 — never images, including on the retry. Verified by type (nothing to serialise an image into) and by test (every recorded request decoded, one text part, no media).
- AM-1 … AM-10 — each has an implementing site and at least one named test that ran green in a retained bundle. AM-5's enforcement point is the build gate, which I re-ran including falsification. T-031's drop is correct: no Devanagari recogniser shipped, and the English-source re-lock is explicitly deferred to the security-test gate.

### 6. Declared gaps, accepted at this gate, with reasons

- No device validation; every DV-1 … DV-16 check is NOT RUN, carried as owner actions OA-1 … OA-5. Accepted: the constitution's Open Decisions 1, 2 and 5 resolve on a device and at the first device demo, i.e. after this gate. T-030's deliverable was the protocol and the results record; both exist, the reasons are stated per row, and nothing is presented as a device run.
- Device-only behaviour unverified. Accepted on the same basis; the record names the simulator as a simulator.
- Red unit baseline on master (about 21 pre-existing failures). Accepted: gates were scoped with explicit selections and the unrelated red was documented, not hidden, and no claimed suite rides on it.
- One load-sensitive determinism test. Accepted: the failing diff is characterised as a wall-clock race against a fixed sleep in the pipeline's synchronisation, the test passed in both retained final gates, and the fix is assigned to the file's owning task. Reported, not papered over.
- Two DRAFT copy keys for the snapshot control. Accepted: they are pinned by the copy suite and listed for the owner's review, which the workflow already makes a final-sign-off condition.
- The stale cache-encryption invariant row in the design document. Accepted as a documentation defect with a scheduled correction; the shipped mechanism is stronger than the row describes.
- The log-safety gate cannot see through indirection. Accepted: stated in the script itself and in the evidence index, with the runtime allow-list as the primary safeguard.
- The snapshot view coverage figure. Accepted as a selection artefact, declared rather than dressed up.

### 7. Corrections carried forward (recorded, non-blocking)

1. `specs/implement-notes.md` section 1 maps groups to the wrong task IDs from TG-02 onward (for example it gives TG-03 as T-011 … T-013 where the plan and the task tree assign T-009 and T-010, and TG-09 as T-028 … T-030 where it is T-026 and T-027). The plan and the task files are correct; the notes' summary table is stale. No evidence depends on it; fix it alongside item 2.
2. Correct the declared stale invariant row in the design document before the security-test re-lock, naming the T-032 cipher rather than Data Protection alone.
3. Evidence retention: the TG-06 gate bundle cannot be read by xcresulttool (item missing) and no TG-01 or TG-03-04 bundles are retained, so those three group counts rest on the notes. The suites themselves are covered by retained bundles; keep the next gate's bundles intact.
4. Integration note: the branch is well behind the local master, and master has since touched the shared observability allow-list. Merge master before the security-test gate and re-run the allow-list, sanitiser and cache suites, because the additive-extension tests pin the exact set they know.

## Decision

decision: GO

All criteria in the feature constitution's Standards are met and were re-verified where verification was cheap. The four corrections in section 7 are record-keeping and integration hygiene: none weakens the evidence for OD7, OD8, OD-13 or AM-1 … AM-10, and none is a scope violation. The declared gaps are accepted for the reasons given, with the device run remaining an owner action that neither security-test nor final-sign-off may treat as done.
