# T-036-repin — re-pin the internal-testing CoreML intent-encoder catalog entry to the T-036 v0 artifact

- **Task:** re-pin `ModelCatalog.intentEncoderSpike` (`intent-encoder-t033-c3-minilm-int8`) to the freshly exported T-036 v0 CoreML zip, so `ModelStore.installCoreMLEncoder(fromZip:for:)` accepts it (strict checksum policy, `kind == .intentEncoder`).
- **Branch:** `worktree-agent-a921c906416bd7d0e`, base `e28165c19411` — not merged, not pushed.
- **Scope:** exactly the re-pin + test-assertion update + the entry's doc comment. No refactor, no other catalog fields touched.

## Why this change was needed

`ModelStore.installCoreMLEncoder(fromZip:for:)` verifies the catalog sha256 of the ZIP before unpacking for `kind == .intentEncoder` (`ios/ElderlyAssistant/Services/ModelStore/ModelStore.swift`, checksum block). The entry still pinned the T-033 zip's hash, so installing the new T-036 v0 export failed with `ModelStoreError.checksumMismatch` — the artifact was not installable until the pin moved.

## Changes

1. `sizeBytes`: `109_075_268` → `109_086_647`
2. `sha256`: `6056ba41ba37…` → `e0ff09231843…` (full new digest below)
3. The entry's doc comment now names the producing run (checkpoint `6d2989e95785`, run `clean-9af1d59-20260913-120652`), states plainly that it is an INTERNAL-TESTING BASELINE for mechanics and baseline behaviour and **not** a quality claim (E4 harness gates failed on this artifact: closed-intent accuracy ~0.53, emergency recall ~0.9375, publication withheld), and records that the entry pins the ZIP's own sha256 under the strict checksum policy, superseding the earlier T-033 hash.
4. Test assertions in `IntentEncoderArtifactTests.testCatalogEntryIsPinnedAndMarkedInternalTesting` updated to the new size/hash; the stale "T-033 C3 export's measured zip hash" comment now names the T-036 v0 export. All other guarantees of that test are unchanged (64-hex length, placeholder URL never device-reachable, no `/Users/` path, not offered in brain/STT pickers, present in `internalTestingEncoderEntries`).

Deliberately unchanged: `filename: "t033-encoder-int8.mlmodelc"` (the zip's single top-level directory is exactly this name), `downloadURL`, `kind`, `dependsOn`, `minDeviceRAMBytes`, the placeholder-URL logic, `intentEncoderSpikeZipURL(environment:)`, and the ID itself.

## Artifact verification (read-only)

Path: `/Users/anjan/t036-encoder-v0/coreml-v0/t033-encoder-int8-mlmodelc.zip` (the file was not modified).

| Item | Value |
|---|---|
| byte size | `109086647` (`ls -l`, exact) |
| sha256 | `e0ff09231843c5a6e667db9f6a33d5994df9a2f37c9601f82e1a125073d7aaa5` (`shasum -a 256`) |
| zip top-level | one entry: `t033-encoder-int8.mlmodelc/` (5 files, `unzip -l`) |

Provenance cross-check: `coreml-v0/v0-coreml-report.json` (`packaging_int8`: 109.1 MB, single top-level `t033-encoder-int8.mlmodelc`); the model dir's `meta.json` carries `artifact_digest` prefix `6d2989e95785…` (the checkpoint named in the doc comment) and the run path `…/code-waiver-9af1d59/…` matching the run id `clean-9af1d59-20260913-120652`.

## Tests — exact commands and results

### 1. iOS gate (focused XCTest via xcodebuild) — PASSED

Command (repo convention: `xcodebuild test`, warm `-derivedDataPath`, ModelStore-area suites + the `test:impact` safety net):

```
cd ios && xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=14AE2228-…" \
  -derivedDataPath <warm DerivedDataTests> \
  -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/IntentEncoderArtifactTests \
  -only-testing:ElderlyAssistantTests/ModelStoreTests \
  -only-testing:ElderlyAssistantTests/ModelCatalogSTTNamingTests \
  -only-testing:ElderlyAssistantTests/ModelCatalogLanguageTests \
  -only-testing:ElderlyAssistantTests/LanguageModelResolverTests \
  -only-testing:ElderlyAssistantTests/TTSVoiceCatalogTests \
  -only-testing:ElderlyAssistantTests/TTSVoiceInstallTests \
  -only-testing:ElderlyAssistantTests/MedicationSchedulerTests \
  -only-testing:ElderlyAssistantTests/VoiceSessionStateMachineTests \
  -only-testing:ElderlyAssistantTests/DesignTokensTests
```

Result: `** TEST SUCCEEDED **`, exit 0. **120 tests executed, 0 failures** across all ten suites (IntentEncoderArtifactTests 8/8, ModelStoreTests 28, ModelCatalogLanguageTests 16, ModelCatalogSTTNamingTests 14, LanguageModelResolverTests 8, TTSVoiceCatalogTests 12, TTSVoiceInstallTests 13, MedicationSchedulerTests 3, VoiceSessionStateMachineTests 9, DesignTokensTests 9). `testCatalogEntryIsPinnedAndMarkedInternalTesting` passed (0.012 s), as did the class's checksum-mismatch, install/unzip, delete, and destination-scoping tests.

Run history (recorded for honesty about the evidence chain):
1. First attempt was **stopped deliberately before tests ran** (SIGTERM, exit 144): the data volume was at 100% capacity (235–560 MiB free) with a concurrent agent build writing, and this worktree cannot reuse the warm cache for the **vendored** packages (source paths differ per worktree, so swift-syntax and the other local packages recompile from scratch — >1000 compile tasks). Continuing would have driven the shared disk to zero. Partial output landed only in the disposable DerivedData of a completed worktree (`t046-chat-framing`, chosen over a cold worktree-local cache purely to avoid duplicating ~4.5 GB on a full disk).
2. Second attempt failed during the **resource-copy phase only** (no test code ran): the gitignored per-worktree resources `Resources/Models/whisper-medium-ne-q5_1.bin` and `Resources/Models/kws` were absent. They were provisioned as symlinks to the immutable copies in the main checkout (read-only; zero disk duplication; both are gitignored, and `git status` stayed clean).
3. Third attempt (the command above) succeeded.

### 2. Standalone catalog-pin harness — executed, all checks pass (extra evidence)

Before the XCTest run was possible, the catalog assertions of `testCatalogEntryIsPinnedAndMarkedInternalTesting` were also executed against the real, unmodified `ModelCatalog.swift` source compiled for macOS (`swiftc`), plus a byte-level comparison against the actual artifact zip:

```
cd /tmp/t036-repin-harness && xcrun swiftc \
  <worktree>/ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift main.swift -o harness && ./harness
```

Result: 18/18 PASS, exit 0 — including `shipped artifact byte size (109086647) == entry.sizeBytes` and `shipped artifact sha256 == entry.sha256`, plus kind/filename/pickers/placeholder-URL/override assertions. This is supplementary to (not a replacement of) the XCTest class, which now also passes.

### 3. Source privacy guard (runs before every build.sh test gate)

```
cd ios && ./tools/check-release-log-safety.sh
```

Result: `no transcript content or raw error object can be printed in a non-Debug configuration` — pass. Xcode project regenerated with `xcodegen generate --spec project.yml --project .` (warns only about the gitignored, per-worktree-fetch model resources).

## Decisions / notes

- **Task id.** The prompt named no explicit task id; this record uses `T-036-repin` (`specs/T-036-repin-notes.md`). If the workflow expects a different id, rename the notes file.
- **Superseded-history references left alone** on purpose (minimal diff): `tools/train-intent/docs/T-033-encoder-bakeoff.md`, `specs/T-037-a-notes.md`, `specs/T-037-a-review.md` still cite the T-033 zip hash — they are historical records of that artifact, which is unchanged.
- **Stale ID-doc observation (not changed, out of scope):** the `intentEncoderSpike` ID doc still describes the artifact as a "LEGACY LLM-format dataset snapshot … slot coverage is contact/time only … calibration unmeasured". That described the T-033 spike; the T-036 v0 export is trained on the T-034 schema-v2 BIO data. Flagged for a follow-up doc touch rather than widened this diff.
- No PII, secrets, or tokens added (NFR-016). No server/GPU contact. The artifact zip was read only. Nothing was deleted outside this worktree. No merge, no push.
