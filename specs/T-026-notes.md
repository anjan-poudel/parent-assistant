# T-026 — Release-log gate registration and source-hygiene suite

Status: implementation complete in the feature worktree
(`elderly-ai-assistant-reminders-instructions-enhancements`). The scoped
XCTest filter has not been run by this agent (see Limitations); the gate,
its self-test, the fixture suite and the temporary-copy proof were run
directly and are recorded below.

## What was built

1. **Gate registration.** `ios/tools/check-release-log-safety.py` now scans
   the instruction feature's own sources under the existing relative-path
   convention:
   - `Services/Instructions`
   - `App/InstructionViews.swift`
   - `App/InstructionCapture.swift`

   It also recognises exactly the seven catalogue event names:
   `instruction_media_import`, `instruction_media_delete`,
   `instruction_media_availability`, `instruction_playback`,
   `instruction_image_load`, `instruction_capture_permission`,
   `instruction_orphan_purge`.

   No existing root or allow-list entry was removed or weakened. The gate's
   failure convention is unchanged: a violation is reported with its file,
   line and rule id, `main()` returns 1, and `sys.exit(main())` propagates it
   to `ios/tools/check-release-log-safety.sh`, which `ios/build.sh` runs as a
   build-blocking step.

2. **Self-test extension.** The gate's `--self-test` gained three
   temporary-copy legs over the real shipped feature file
   (`Services/Instructions/InstructionObservability.swift`):
   - `clean-copy-of-instruction-feature-file` — the unmodified copy exits 0;
   - `seeded-instruction-text-in-feature-copy` — an appended
     `print("seeded instruction text: \(instructionText)")` exits 1 and is
     named with `feature-console-write`, `feature-content-print` and the
     seeded statement;
   - `seeded-unknown-event-in-feature-copy` — an appended emission of
     `instruction_future_unknown` carrying `metadata: ["transcript": token]`
     exits 1 and is named with `feature-unlisted-metadata-key`, `'transcript'`
     and the unknown event name.

   The copy is read read-only from the shipping tree, the seed is appended in
   memory, and the write happens only inside `tempfile.TemporaryDirectory`.
   Each copy leg declares the shipping file as guarded: `run_self_test` reads
   its bytes before and after the subprocess and fails the leg with
   "the shipping tree changed during a temporary-copy leg" if they differ.
   A missing copy source is reported as a failed `instruction-copy-source`
   case instead of a traceback.

3. **Source-hygiene suite.**
   `ios/ElderlyAssistantTests/Services/Instructions/InstructionSourceHygieneTests.swift`
   (new, 811 lines) contains exactly the eleven named cases. It scans the
   three roots with `FeatureSourceScan.codeText` (comments stripped, string
   literals preserved), pins the gate registration and self-test design as
   source evidence, and enforces the scope boundary from design §8.3 /
   §11.3 P. Every forbidden-pattern family also has a planted-token
   falsifiability control, so a detector that silently stopped matching fails
   the suite instead of passing forever.

## Files changed

- `ios/tools/check-release-log-safety.py` — modified (+186/−13): three roots,
  seven event types, docstring/self-test documentation, three copy legs,
  guarded-byte comparison, missing-copy-source handling.
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionSourceHygieneTests.swift`
  — new (811 lines, 11 test methods).
- `specs/T-026-notes.md` — this file.

`git status --porcelain` for the owned set shows only the two implementation
files from this task (the worktree carries other tasks' pre-existing
modifications, which this task did not touch).

## Validation performed

All commands were run from the feature worktree root.

### Gate on the shipping tree

```
python3 ios/tools/check-release-log-safety.py
```

Result: exit 0. Output reports **54 feature roots** and **21 feature event
types** payload-graded (pre-task baseline was 51 roots / 14 event types).

### Gate coverage self-test

```
python3 ios/tools/check-release-log-safety.py --self-test
```

Result: exit 0, **10 legs**:
`coverage-registry`, `pristine-feature-paths`,
`seeded-raw-print-in-feature-path`,
`seeded-content-write-in-feature-path`,
`seeded-event-type-unlisted-key`, `seeded-event-type-content-field`,
`off-root-control`, `clean-copy-of-instruction-feature-file`,
`seeded-instruction-text-in-feature-copy`,
`seeded-unknown-event-in-feature-copy`.

The two seeded instruction copies report the copied path with line numbers
and the rule ids, and the final summary states that the temporary-copy legs
left the shipping tree byte-identical.

### Full wrapper (fixtures + self-test)

```
bash ios/tools/check-release-log-safety.sh
```

Result: exit 0. Fixture harness: **24 cases over 12 rules**, every rule with a
positive and a negative fixture; then the same 10-leg self-test.

### Manual temporary-copy proof (requirement 4)

```
SHIP=ios/ElderlyAssistant/Services/Instructions/InstructionObservability.swift
BEFORE=$(shasum -a 256 "$SHIP")
TMP=$(mktemp -d /tmp/log-safety-t026.XXXXXX)
mkdir -p "$TMP/ElderlyAssistant/Services/Instructions"
cp "$SHIP" "$TMP/ElderlyAssistant/Services/Instructions/InstructionObservability.swift"
# append a synthetic interpolated instruction-text log to the COPY only
python3 ios/tools/check-release-log-safety.py \
  --source-root "$TMP/ElderlyAssistant" \
  --allow-list ios/ElderlyAssistant/Services/Observability/LogSanitiser.swift
```

Result: **exit 1**, naming the copied file and both rules:

```
ElderlyAssistant/Services/Instructions/InstructionObservability.swift:357:
  [feature-console-write] console write in the feature's sources ...
ElderlyAssistant/Services/Instructions/InstructionObservability.swift:357:
  [feature-content-print] recognized or translated text in a console write
```

The temp directory was removed; the shipping file's SHA-256 was
`0fa0dd7be11bca69e4361ba6908d988530aeb1f3791231d762b2b3d51ac96dc7` before
and after. Shipping gate exit 0 was also re-confirmed in the same run.

### Swift syntax check

```
xcrun swiftc -parse ios/ElderlyAssistantTests/Services/Instructions/InstructionSourceHygieneTests.swift
```

Result: exit 0. This is a parse, not a type-check against the test target and
not an `xcodebuild` run (both out of scope for this task; see Limitations).

### Assertion simulation

Because the simulator test bundle cannot spawn Python, every gate source pin
and every hygiene regex in the Swift suite was replayed with a Python
equivalent of `FeatureSourceScan.codeText` over the real files:

- 15 feature files scanned (13 under `Services/Instructions` + the two App
  files);
- 0 matches for all network/upload/share, Photos, `copyItem`, and
  transcode/trim/compression patterns;
- 0 merged-Info.plist usage-string lookups;
- all planted-token falsifiability controls and both negative controls
  (`PHPickerViewController`, `trimmingCharacters`) behaved as the suite
  asserts;
- all gate source pins (roots, event register, rules, exit-1 path,
  temp-directory/read-only/guarded-digest design) hold against the current
  script.

This simulation caught one real defect before submission: the bare
`UIActivity` pattern (which ends in a negative lookahead) cannot fire on
`UIActivityViewController`. The planted string now carries both
`UIActivityViewController(...)` and a bare `UIActivity()`, and each pattern is
asserted separately.

## Test cases and the scenarios they cover

- `testFeatureRootsAreRegistered` — all three roots are quoted entries; the
  directory root keeps its directory spelling; no quoted entry mentions
  `RoutineNotificationContent`; representative roots from earlier features
  are retained; the allow-list authority is still the shipped
  `LogSanitiser.swift`.
- `testEveryFeatureFileIsCoveredByARoot` — the scan finds at least the 15
  expected files, no duplicates, every file is covered by the gate's exact
  file-or-directory-prefix rule, and the store/emitter files are present. The
  predicate is falsified against a lookalike sibling
  (`Services/InstructionsExtra/...`) and an extended filename.
- `testSevenEventTypesRegistered` — exactly the seven `instruction_*` keys
  (an eighth would fail), representative event types from other features
  remain, and all seven payload keys still exist in
  `LogSanitiser.allowedKeys`.
- `testUnknownEventTypeFailsGate` — the seeded name is not registered; the
  feature-root branch, `judge_feature`/`judge_feature_payload`, the unlisted
  metadata-key rule, the `return 1` violation path and `sys.exit(main())`
  are pinned; the temporary-copy leg demands exit 1 with the rule and key
  named.
- `testPlantedFreeTextLogFailsGate` — the copy-source constant, the read-only
  helper, the interpolated seed and the leg's two rule expectations are
  pinned; Swift-side mirrors of the console-write and content-word detectors
  fire on the seed. The comment records the manual live-run evidence without
  claiming XCTest executed Python.
- `testNoNetworkOrUploadInFeatureSources` — precise tokens for `URLSession`,
  `URLRequest`, `NWConnection`, `import Network`, `WebSocket`, `CFSocket`,
  upload, and the share/export surfaces; no bare `share` token, so
  `AVAudioSession.sharedInstance()` is not a false positive.
- `testNoPhotoLibraryAccess` — forbids the in-process Photos surface
  (`PHPhotoLibrary`, `PHAsset`, `PHFetchResult`, `PHImageManager`,
  `PHCachingImageManager`, `PHAuthorizationStatus`,
  `requestAuthorization`, the two photo usage-description keys, and
  `import Photos` with a token that does not swallow `PhotosUI`).
  `PHPickerViewController` is explicitly present and must not be flagged: it
  runs out of process and needs no photo-library permission.
- `testNoCopyItemInVideoStore` — no `copyItem` anywhere in the three roots,
  while `InstructionStagingFileOps` / `SystemInstructionStagingFileOps`
  remain present so the create-before-write `.completeFileProtection`
  design is still the one in force.
- `testNoTranscodeOrTrimAPI` — forbids export/writer/reader/composition,
  VideoToolbox/compression and transcode spellings, and `trim(` /
  `trimming(`; ordinary text `trimmingCharacters(in:)` is proven not to
  match.
- `testNoMergedInfoDictionaryUsageForUsageStrings` — no usage string is read
  from the merged Info.plist dictionary (direct key literal,
  `infoDictionary[...]`, or a key within two lines of an
  `object(forInfoDictionaryKey:)` read); a planted camera-usage lookup is
  detected and a `CFBundleShortVersionString` lookup is not.
- `testGateSelfTestDoesNotModifyShippingTree` — the self-test writes only
  under its temporary root, the shipped-file helper is an explicit
  read-only open, the before/after byte comparison exists and a change fails
  the leg, and the copy legs declare the shipping file as guarded.

## Decisions

1. **Seven event names only.** The task names exactly seven `instruction_*`
   types; design §6.5 also sketches shared-file emitters
   (`entry_instruction_updated`, `event_instruction_updated`). I followed the
   explicit task list. Those shared emitters are therefore not registered by
   this task; the seven entries are the durable anchor for the emitter that
   exists today. If a later task moves or adds an emitter, the registry and
   the coverage self-test make the omission visible rather than silent.
2. **`RoutineNotificationContent.swift` is not a root.** It lives in a shared
   directory, writes no log, and carries two producer keys plus a Bool
   (design §6.5). The test asserts this over the registry's quoted entries,
   not over the explanatory comment that names the file.
3. **Unknown event names fail by the root's rules, not by an event-name
   allow-list.** The gate deliberately has no event-name allow-list: every
   emission statement in a feature-root file is judged by rules 5–6 whatever
   the event is called. A bare unknown event with empty metadata is not
   content and correctly passes; an unlisted key or content-bearing field
   fails. The seeded leg uses an unlisted key so the test pins the real
   mechanism rather than a fictional name check.
4. **The copy legs use the real shipped file**, not a synthetic stand-in, so
   the coverage claim is demonstrated on the tree's own shape and cannot
   drift from it. The clean copy is the differential control for the two
   seeded copies.
5. **Shipping bytes are compared, not assumed.** The self-test proves the
   temporary-copy exercise leaves the shipping tree identical instead of
   trusting the temp-directory convention.
6. **No allow-list changes.** The seven payloads use only existing keys:
   `outcome`, `state`, `duration_ms`, `error_code`, `count`, `kind` and the
   already-hashed `entry_id_hash`.
7. **Hygiene scans are comment-free but string-preserving**, matching the
   existing `FeatureSourceScan.codeText` convention, so documentation
   examples do not fail the suite and a code literal inside a string is still
   visible.

## Limitations (not provable from XCTest or from a static scan)

- The iOS Simulator test bundle has no `Process`; the suite **does not spawn
  Python and does not claim to**. Its gate cases are honest source pins over
  the engine plus the design of the self-test. The live gate run is performed
  by `ios/tools/check-release-log-safety.sh` from `ios/build.sh`; the manual
  temporary-copy run above is the execution evidence for T-026.
- The gate and the suite are static and textual. They cannot prove the
  absence of egress hidden behind a helper, a key built at run time in a
  variable, or a framework sink they do not name. The gate's own
  documentation states that dynamic or indirect logging is not proven; the
  suite states the same and does not claim more.
- This agent did not run `xcodebuild` or `./build.sh` (per the task's
  constraints), so the scoped XCTest filter
  `-only-testing:ElderlyAssistantTests/InstructionSourceHygieneTests` remains
  the coordinator's step. `swiftc -parse` proves syntax only, not
  type-checking against the test target; the assertion simulation above is
  the compensating check for the source-pin logic.
- The seven event registry entries are currently redundant with the directory
  root because the emitter lives inside it; they become load-bearing only if
  an emitter moves to a shared file (see Decision 1).
- No security settings, CI permissions, entitlements, Info.plist, app sources
  or allow-list entries were changed. All seeded text is synthetic; no PII
  appears in any test fixture or log.
