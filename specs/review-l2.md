# review-l2 — reminders-instructions-enhancements — iteration 4

| Field | Value |
|---|---|
| Task | `review-l2` |
| Workflow | `reminders-instructions-enhancements` |
| Iteration | 4 (final review after three bounded reworks; `max_rework_iterations: 3`) |
| Artifact under review | `specs/design-l2.md` (2,278 lines) |
| Artifact SHA-256 | `0bd1ee1a825d529b4313a9685060d1a542ed38a5c42e5c1d899cf1d085177eeb` |
| Worktree | `elderly-ai-assistant-reminders-instructions-enhancements` (branch `feat/reminders-instructions-enhancements`) |
| Requirements lock | `specs/define-requirements.lock.yaml`: 25 FR-RIE and 10 NFR-RIE requirements, 107 scenarios; snapshot `a02b9d4ee24a305ae396cf762304f1a13816f7bc1e81242e9f2adbaf0111bfb9` matches `specs/define-requirements.md`; 35 of 35 per-file SHA-256 entries match; zero drift |
| Prior reviews | `review-l2` iterations 1, 2 and 3 (all NO_GO); preserved copies in `.ai-sdd/runs/reminders-instructions-enhancements/reviews/` |
| Review mode | Read-only. The design, L1, both constitutions, the requirements and lock, the workflow, the prior reviews and the named source anchors were read. No build, test run, commit or workflow execution was performed. |
| Decision | GO |

## Summary

The three iteration-3 findings are resolved in the body of the artifact, not merely asserted in a revision table.

**B-3 is resolved.** `specs/design-l2.md` §5.2 steps 5 to 7 (`:1499–1501`) now create the staging destination with no bytes and `[.protectionKey: .complete]` through the staging seam, fill it with a bounded chunked stream (1 MiB default, cumulative 200 MiB cap, step-2 byte count checked), and re-read the protection attribute after the stream. A reported weaker class deletes the file and the draft directory and fails the write; an unreported attribute proceeds only as the recorded refinement R-5 platform limitation. `copyItem` is never used in the staging path. P-10 (`:31`), the step-order paragraph (`:1506`), §5.3 (`:1510–1515`), R-4 (`:2242`) and OI-5 (`:2269`) all state the same guarantee, and the kill-window claim is true. `InstructionStagingFileOps` and `SystemInstructionStagingFileOps` live inside `InstructionVideoStore.swift` and are tabled in C02; the seam adds no new file and no unstated error path. §11.4 names the `InstructionStagingFileOpsSpy`, and §11.3 E.1–E.9 can fail the claims with an ordered call log, a no-`copyItem` source scan, weaker-class reports at creation and after the stream, mid-stream read and write failures, truncation, the cumulative cap and the kill-window invariant.

**M-3 is resolved.** §11.3 N (`:2155–2157`) and §10.6 (`:2048`) now read the built app bundle. The unit tests are app-hosted through `TEST_HOST` (`ios/project.yml:371–372`); the suite resolves the host app from `Bundle.main.bundleURL`, asserts that `en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings` exist inside the built bundle, parses each as a property list and asserts both keys and their exact values. The source-plist and source-strings pins remain complementary, and `object(forInfoDictionaryKey:)` is explicitly no longer claimed as registration evidence. A missing `project.yml` registration fails because the resource is absent from the built bundle.

**M-4 is resolved.** `RoutineStore.loadEntriesIfReadable() -> [RoutineEntry]?` is tabled in C11 and IF-33, returns nil on any `storage.read` failure including a first-run absent key, and is implementable in an extension in the same file as the class. `RoutineScheduler.entriesIfReadable()` delegates to it, the legacy `loadEntries()` keeps returning `[]` for every existing caller and is never used to build a live set, and §11.2/§11.3 K name the unreadable-store survival, readable-but-empty collection and legacy-`[]` tests. The nil-means-unknown sweep safety is now implementable and testable.

Every earlier finding remains resolved or accepted: B-1, B-2, M-1, M-2, m-1, m-2, m-3, m-4 and N-1 through N-10 were re-checked against the current body. N-1's residual evidence gap is closed by the M-3 correction. L1 fidelity is intact: C01–C17 are unchanged, D1–D18 are preserved, P-1 through P-14 and refinements R-1 through R-13 are recorded, and no unrecorded deviation was found. All 35 locked requirements are designed and traceable to named suites. No new blocker or major finding was found, and no scope creep or unsafe storage or privacy step was found. The decision is GO.

## Findings

### Iteration-3 findings — resolution status

| Finding | Status | Evidence and anchors |
|---|---|---|
| B-3 staged video copied before protection | Resolved | §5.2 steps 5 to 7 (`:1499–1501`) create the destination with no bytes and the complete-protection attribute, fill it with a bounded chunked stream whose handles close on every path, enforce the cap cumulatively, check the step-2 count, and re-read protection after the stream. Cleanup on creation, read, write and verification failure removes the partial file and the draft directory. §5.3 (`:1510–1515`), the step-order paragraph (`:1506`), P-10 (`:31`) and R-4 (`:2242`) agree. `copyItem` appears only in statements that it is absent or source-scanned (`:31`, `:121`, `:1506`, `:1512`, `:1514`, `:1828`, `:2084`, `:2130`, `:2242`). The seam is in C02 (`:144`), the spy is in §11.4 (`:2180–2182`), and E.1–E.9 (`:2127–2137`) exercise the ordering, the weaker-class branches, mid-stream failure, truncation, the cumulative cap, the kill window and cleanup. OI-5 is now only the chunk-size measurement (`:2269`), and the chunked path is mandated. |
| M-3 built-bundle registration evidence | Resolved | §1.9 M-3 (`:122`), §10.6 Text pin (`:2048`), §11.3 N (`:2155–2157`) and the `L10nCatalogCoverageTests` row (`:2104`). The tests are app-hosted (`TEST_HOST`, `ios/project.yml:371–372`), resolve `Bundle.main.bundleURL`, assert both `InfoPlist.strings` resources exist in the built bundle, parse them and assert both keys and exact values, including the Nepali strings and Devanagari. The source-plist and source-strings pins remain. `object(forInfoDictionaryKey:)` is explicitly rejected as registration evidence. A missing `project.yml` entry fails because the built bundle lacks the resource. |
| M-4 strict-read seam for the orphan sweep | Resolved | C11 (`:145`), §2.11.6 (`:294`), IF-23 (`:419`), IF-33 (`:429`), the declarations (`:1075–1097`), §4.9 (`:1404–1420`), §5.9 (`:1590–1602`), §7.1 (`:1741`), §7.6 (`:1793–1802`), §11.2 (`:2094`, `:2098`) and §11.3 K (`:2149`). `RoutineStore.storage` is private but the strict read is an extension in the same file; `RoutineStore.init(storage:)` and `RoutineScheduler.init(store:)` are internal; both shipping storage implementations return a failure for a missing key. The legacy `loadEntries()` `[]` contract is untouched. K injects failing and readable-but-empty doubles and asserts the sweep distinction. |

### Earlier findings — resolution status

| Finding | Status | Evidence and anchors |
|---|---|---|
| B-1 optional-entry tap and deleted-owner notice | Resolved | P-12/P-13 (`:33–34`), §1.7 B-1 (`:87`), §2.14.3 (`:328`), §2.15.3–4 (`:341–342`), §4.11 (`:1436`), §10.5 row 35, §11.3 B, §11.5 step 7. `onInstructionTap(entryId:entry:firedAt:)` carries the optional entry; a nil entry maps to `.unavailable` with `instruction.reminderUnavailable` and Close; no title or time is claimed; photo-only and pre-upgrade taps remain no-ops. |
| B-2 persisted `text` kind and labels | Resolved | §1.7 B-2 (`:88`), §3.4 (`:545`), §4.1, §10.1 (`:1921`) and §10.5 rows 5–7 (`:1976–1978`). The raw value is `"text"` throughout; the visible label is Text; no `case note`, `kind.note` or raw `"note"` remains. |
| M-1 camera-before-microphone order | Resolved | §1.8 M-1 (`:89`), §2.4.3 (`:208`), §2.5.3 (`:221`), §11.3 R (`:2168`). Camera is read and requested first, a denial short-circuits before the microphone request, and the recorder is presented only after both grants. The permission tests record the order and both denial short-circuits. |
| M-2 FR-RIE-024, 021 and 022 evidence | Resolved | §1.8 M-2 (`:90`), §11.2 rows for `InstructionDisplayStateTests`, `NotificationCategoriesTests`, `RoutineSchedulerTests` and `RoutineNotificationSchedulerTests`, and §11.3 Q/S/T (`:2163–2176`). Each named suite can fail the claim it evidences. |
| m-1 single service read | Resolved | §1.8 m-1 (`:91`), §2.13, §3.6, §4.8 and §5.9. `FreeFormEventService.event(withId:)` (`FreeFormEventService.swift:318`) is the only service read; the coordinator wrapper delegates. |
| m-2 labelled store `Bool` exception | Resolved | §1.8 m-2 (`:92`), §3.1 (`:384`), IF-26 (`:422`) and OI-1 (`:2265`). The store exception is labelled and translated to `.persistenceFailed` at the service seam; no view sees the `Bool`. |
| m-3 copy-family renames | Accepted | §1.7 note (`:94`). The renames are not behaviour-bearing; the two behaviour-bearing keys `instruction.reminderUnavailable` and `instruction.foregroundNote` are present in §10.5. |
| m-4 load-bearing source anchors | Verified | §1.7 note (`:94`) and P-8 (`:29`). The corrected anchors were re-read in the source: `EventExtrasStore.setPhotoFilename` `:110–113`; `RoutineScheduler(` `AppCoordinator.swift:3571`; overlay `ContentView.swift:65–72` against the design's harmless `65–73`; userInfo `RoutineAlarmScheduler.swift:75–79`; formatter `ViewCaches.swift:51`; service read `FreeFormEventService.swift:318`; filename guard `VisualAidStore.swift:243–249`. |
| N-1 plist amendment and disclosure | Resolved | §1.8 N-1 (`:102`), §10.6 (`:2016–2050`), §11.3 N (`:2155–2157`), §11.5 step 13. The exact English camera and microphone text is amended, both `InfoPlist.strings` resources and both `project.yml` entries are tabled, and the built-bundle evidence now makes the registration claim real. The original N-1 blocker and the M-3 residual are both closed. |
| N-2 "Note" residue | Resolved | §1.8 N-2 (`:103`), §10.1 (`:1921`) and §10.5 rows 5–7. The kind picker reads Text / Photo / Video; no "Note" label survives. |
| N-3 invalid `InstructionPayload` enum | Resolved | §1.8 N-3 (`:104`), §3.4 (`:545`) and §4.2. The payload is a `struct InstructionPayload: Equatable` with stored fields and an explicit memberwise init; no enum remains. |
| N-4 incomplete filename guard | Resolved | §1.8 N-4 (`:105`), §3.5 (`:800–802`) and F-11. `isPlain` requires non-empty, excludes `.` and `..`, and excludes both separators before any name-derived URL or store access; the video and image loaders and the store paths apply it. |
| N-5 dropped fire-time line | Resolved | §1.8 N-5 (`:106`), §4.10 (`:1421–1435`), §2.15.3–4 and §11.3 B/M. `timeText` is non-nil only when the instruction is present or `expectsInstruction` holds; `.unavailable` carries no time; a photo-only firing has no time line. |
| N-6 phantom suite citation | Resolved | §1.8 N-6 (`:107`), §8.3 and the §2.0 naming note (`:156–157`). The real suite is `RoutineNotificationSchedulerTests`; the phantom `RoutineNotificationContentTests` is gone; `RoutineAlarmSchedulerTests` is documented as a phantom. |
| N-7 missing files in C01, C05, C08 and P-14 | Resolved | §1.8 N-7 (`:108`), §2.0 C01/C05/C08 (`:142–152`) and P-14 (`:35`). The image-loading file, both strings files, the plist, the `project.yml` entries and the loader read are tabled; P-14 says no new file beyond §2.0. |
| N-8 unrecorded L1 shape changes | Resolved | §1.8 N-8 (`:109`) and §1.3 R-8 through R-13 (`:50–55`). The six L1 shape differences are recorded and argued mechanically equivalent; none is a new decision. |
| N-9 FR-RIE-015 and NFR-RIE-009 evidence | Resolved | §1.8 N-9 (`:110`), §11.2 and §11.3 I (`:2145`). The fire handler and notification scheduler suites name FR-RIE-015; the playback controller adds the `finished` outcome and the close path. |
| N-10 duplicate fake and `tooLong` copy | Resolved | §1.8 N-10 (`:111`), §11.4 (`:2180–2196`), §6.7 and §10.5 row 19 (`:1990`). One recorder fake remains; the copy says "3 minutes or shorter" and "३ मिनेटसम्मको", matching the inclusive 180-second cap. |

### New findings

None. No new blocker or major issue was found in the rework-3 sections or in the full L1, safety, storage, privacy, error-handling, concurrency, accessibility, localisation, performance, traceability and scope re-check.

### Review notes (not findings)

1. `InstructionStagingFileOps.createProtectedFile(at:) -> Bool` is a construction flag, not a public error surface. §5.2 step 5 maps `false` immediately to `.writeFailed(.stagingFailed)`, and §3.5 (`:719–741`) documents the seam and the production implementation. It adds no unstated error path. If a future reviewer applies the "no `Bool` where why matters" rule to this internal seam as well, the design should record it beside OI-1, but nothing in the current contract is lost: the only caller translates it into a typed error.
2. §11.3 E.1's parenthetical that the ordered log shows `createProtectedFile` "carrying `.completeFileProtection`" is describing the production creation call; the seam method itself takes no attribute parameter, so the ordered log proves the create-before-first-chunk-write order and the source pin proves the creation option. The implementation should site that source pin over the `SystemInstructionStagingFileOps.createProtectedFile` creation region as well as the owner-directory creation region. This is a test-siting clarification, not a behavioural gap; the design's §3.5 and §5.3 name the exact production call.
3. §1.9 says the revision "changes nothing else," while its M-3 row lists §1.8 N-1 among the changed sections. This is the intended evidence correction, not a behavioural change: the plist amendment and the strings files are unchanged, and only the registration evidence moved to the built bundle. No contradiction affects the decision.

## Ratification

| Item | Disposition | Basis and conditions |
|---|---|---|
| OI-1 | Ratified | The principal seams declare explicit error types. `EventExtrasStore.setInstruction -> Bool` is a narrow, labelled exception in IF-26, follows the store's existing convention and is translated to `.persistenceFailed` at the service boundary. Condition: keep the IF-26 label and the translation test. |
| OI-3 | Ratified | `InstructionCommit` and `InstructionPendingMedia` are necessary because an event has no id before it is created, so a picked photo or recorded video cannot have a store filename at handoff. The kind-match rule prevents a text write from smuggling media. |
| OI-7 | Ratified | NFR-RIE-008's 1 s bound is a failure-detection budget; the preflight and `AVPlayerItem.status` resolve the named failures within it. The 10 s ready watchdog is a platform-stall ceiling with Close available, not the failure budget. Condition: keep that distinction explicit and keep 10 s as a backstop. |
| OI-8 | Ratified | Event notifications carry no `had_instruction`; the event tap already opens the detail, where absence renders `.none`, so there is no dead end. Revisit only if a future flow presents instruction content from the background. |
| OI-2 | Correctly classified, non-blocking | The synchronous AVFoundation accessors are deprecated but not removed; warnings-as-errors is off. The async replacement cannot run inside the system callback; the fallback is stated and triggered by SDK removal. |
| OI-4 | Correctly classified, non-blocking | The shared image store is pinned by L1 D3; one instruction image per owner is unambiguous. A per-instruction layout is a future product and engineering decision. |
| OI-5 | Correctly classified, non-blocking | It is now only the `stagingChunkBytes` measurement: the chunked stream is the mandated D18 path and 1 MiB is the shipped default. Tune only if the 200 MiB smoke misses the budget; the write stays inside the same callback. |
| OI-6 | Correctly classified, non-blocking | L1 specifies plain text only; a Settings deep-link is a new interaction and a product decision. The plain text is the shipped default. |

### Risk register R-1 through R-14

| Risk | Disposition | Basis |
|---|---|---|
| R-1 orphan sweep deletes live videos | Accepted | The nil-means-unknown chain is now implementable through `RoutineStore.loadEntriesIfReadable()` and `RoutineScheduler.entriesIfReadable()`; §11.3 K carries the survival, readable-but-empty and legacy-`[]` tests; the 60 s grace and in-flight set remain. |
| R-2 synchronous 200 MiB staging write | Accepted | The size cap precedes staging; the 1 MiB chunked stream keeps peak memory flat; the smoke measures the worst case; `stagingChunkBytes` is the tuning knob (OI-5). |
| R-3 deprecated synchronous AVFoundation probe | Accepted | No warnings-as-errors today; the async replacement cannot run in the callback; OI-2 records the fallback. |
| R-4 platform ignores or fails to report protection | Accepted | The destination is created with `.completeFileProtection` before any byte, filled by the chunked stream, and re-verified after the stream and after the commit rename. A weaker reported class fails closed and deletes the bytes. An unreported class is tolerated only by the refinement R-5 conditional assertion; the source pins cover the creation call and the absence of `copyItem`; a crash after creation leaves at most an empty or partial `.complete` file that the sweep removes. |
| R-5 event owner directory collision | Accepted | 128 bits are kept, one implementation (`eventDirectoryName`) is used, and a shape and uniqueness test pins it. |
| R-6 malicious video parse | Accepted | The caps bound the input; the file is never transformed, uploaded or shared; the OS parses the same bytes in any player; no custom demuxer. Platform risk accepted. |
| R-7 PII through an ungraded log path | Accepted | No console writes in the three feature roots; typed emitters with closed vocabularies; the release-log gate and its self-test; shared hunks are reviewed file by file (the gate's documented limitation). |
| R-8 partial event save confusion | Accepted | One plain detail line, the Edit retry path and the outcome type name the partial state; the form does not claim success for the missing part. |
| R-9 system-language permission dialog | Accepted | The amended English plist is pinned; `InfoPlist.strings` in en and ne covers Nepali-system phones; the in-app denial note is app-language localised. |
| R-10 cancel during the staging copy | Accepted | The copy completes and is discarded; bounded by 200 MiB and 180 s; a short delay before the sheet returns to idle. |
| R-11 future wholesale `EventExtras` rebuild | Accepted | The mutation rule, the two-order preservation test and the struct comment pin it. |
| R-12 1 s fallback versus the 10 s watchdog | Accepted | §8.1 distinguishes failure detection from a platform stall; OI-7 keeps 10 s as a backstop. |
| R-13 duplicate fired-screen presentation | Accepted | The tap path does not replace a presentation already showing the same entry; a different entry replaces rather than stacks; the overlay is a single `fullScreenCover(item:)`. |
| R-14 event instruction-image files on a failed delete | Accepted | A pre-existing flat-store condition stated in §5.8; no new mechanism is invented. |
| Refinements R-1 through R-13 | Accepted | The §1.3 rows are recorded mechanical or evidence changes: R-1 to OI-1, R-2's typed context, R-3's explicit parameter, R-4's anchor corrections, R-5's conditional protection assertion, R-6's defaulted property, R-7 to OI-3, and R-8 through R-13's mechanical equivalences. None changes user-visible behaviour or the scope boundary. |

## Requirement traceability

The lock contains 25 functional and 10 non-functional RIE requirements. The table below re-derives the evidence independently of the design's summary; every requirement has a named suite that can fail its claim.

| Requirement | Design sections | Named evidence | Status |
|---|---|---|---|
| FR-RIE-001 instruction model | §2.1, §3.4, §4.1–4.3 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests` | Covered |
| FR-RIE-002 text instruction | §2.1, §2.8, §4.1 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `EventExtrasStoreTests`; `RoutineStoreTests` | Covered |
| FR-RIE-003 image instruction | §2.1, §2.8, §5.8 | `InstructionModelTests`; `InstructionImageLoadingTests`; `RoutineSettingsInstructionTests`; `VisualAidStoreTests` | Covered |
| FR-RIE-004 library pick | §2.4, §3.5, §7.4 | `InstructionCaptureTests`; `InstructionVideoImportTests` | Covered |
| FR-RIE-005 recording | §2.4, §3.5, §7.4 | `InstructionCaptureTests`; `InstructionVideoImportTests`; `InstructionPermissionTests` | Covered |
| FR-RIE-006 limits | §3.4, §5.2, §9.1 | `InstructionModelTests` (duration); `InstructionVideoImportTests` (limits) | Covered |
| FR-RIE-007 caption | §2.1, §3.4, §4.10 | `InstructionModelTests`; `InstructionVideoImportTests`; `InstructionCaptureTests` | Covered |
| FR-RIE-008 lifetime and edits | §4.2, §5.6 | `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-009 existing surfaces | §2.8–2.10 | `RoutineSettingsInstructionTests`; `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-010 plain feedback | §3.3, §6.2, §6.7, §10.7 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-011 storage layout and protection | §4.3, §5.1–5.4 | `InstructionVideoStoreTests` (creation before bytes, chunked cleanup, no `copyItem`, kill window); `NoIOInInitTests` | Covered |
| FR-RIE-012 filename hygiene | §3.4, §4.3, §4.7 F-11, §8.3 | `InstructionVideoStoreTests`; `InstructionImageLoadingTests`; `EventExtrasStoreTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-013 transactional replace | §5.6 | `InstructionVideoStoreTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-014 delete with owner | §2.11, §2.13.4, §5.5–5.6 | `InstructionVideoStoreTests`; `FreeFormEventServiceTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-015 always fires | §2.14, §2.17, §6.2 | `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; unchanged facade and medication suites | Covered |
| FR-RIE-016 handlers return false | §2.14 | `RoutineVisualAidFireHandlerTests`; `FreeFormEventFireHandlerTests` | Covered |
| FR-RIE-017 composition | §2.15 | `InstructionDisplayStateTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests`; `FreeFormEventFireHandlerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-018 playback UX | §2.6–2.7, §10.1–10.3 | `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests`; `InstructionSurfaceTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-019 tap and Open | §2.14.2–3, §2.15.3–4, §4.11 | `RoutineVisualAidFireHandlerTests` (three taps); `AppCoordinatorInstructionTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-020 failure fallback | §4.10, §6.2 | `InstructionDisplayStateTests`; `InstructionPlaybackControllerTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-021 notification taxonomy | §2.14, §2.17, §6.4 | `NotificationCategoriesTests`; `RoutineSchedulerTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-022 no notification attachment | §2.17, §5.6, §11.3 T | `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-023 no new machinery | §1.4, §2.15, §6.4 | `RoutineSchedulerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-024 honest capability surface | §2.8.6, §4.10, §10.5 row 36 | `InstructionDisplayStateTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-025 permissions and disclosure | §2.4.3, §2.5.3, §3.5, §10.6 | `InstructionCaptureTests`; `InstructionPermissionTests`; `L10nCatalogCoverageTests` (source plist, source strings, built-bundle resources) | Covered |
| NFR-RIE-001 accessibility | §10.1–10.4 | `InstructionSurfaceTests`; `DesignTokensTests` | Covered |
| NFR-RIE-002 localisation | §10.5–10.7 | `L10nCatalogCoverageTests`; `InstructionSurfaceTests` | Covered |
| NFR-RIE-003 privacy and no egress | §8.3–8.4 | `InstructionSourceHygieneTests` | Covered |
| NFR-RIE-004 PII-free logs | §6.4–6.6 | `InstructionObservabilityTests`; `RoutineNotificationSchedulerTests` | Covered |
| NFR-RIE-005 at-rest protection | §5.3 | `InstructionVideoStoreTests` (creation and post-stream verification, no `copyItem`); `InstructionSourceHygieneTests` | Covered |
| NFR-RIE-006 migration and tolerance | §4.4–4.7 | `InstructionModelTests`; `InstructionDisplayStateTests`; `RoutineEntryTests`; `RoutineStoreTests`; `EventExtrasStoreTests` | Covered |
| NFR-RIE-007 footprint and orphans | §5.5–5.6 | `InstructionVideoStoreTests`; `RoutineStoreTests` (strict read); `RoutineSchedulerTests` (nil and empty sweep cases) | Covered |
| NFR-RIE-008 responsiveness | §8.1–8.2, §9.1 | `InstructionPlaybackControllerTests`; `AppCoordinatorInstructionTests`; recorded smoke | Covered; OI-7 ratified |
| NFR-RIE-009 testability and gate | §3.5, §11.2 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests`; recorded smoke | Covered |
| NFR-RIE-010 preserved baseline | §4.10, §11.3 M, §11.2 unchanged suites | `InstructionSurfaceTests`; `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; `NotificationCategoriesTests`; medication suites | Covered |

## Cross-cutting verification

| Check | Result | Evidence |
|---|---|---|
| Explicit error types on every interface method | Pass | §3.1 (`:384`) states the rule; IF-1 through IF-35 declare `Result<T, ConcreteError>`, a sum type whose cases are the failures, or a published state whose `.failed` case carries the failure. No new API returns `any Error`, `NSError` or a `Bool` where "why" matters. `EventExtrasStore.setInstruction -> Bool` is the one deliberate, labelled exception (IF-26, OI-1) and is translated at the service seam. The new staging seam's `createProtectedFile -> Bool` is a construction flag mapped immediately to a typed error (§5.2 step 5). |
| Async and external failure modes and recovery | Pass | §3.3 error taxonomy, §6.2 failure matrix per surface, §6.3 retry and recovery register, §9.2 async and external call register. The callback-scoped source URL is staged before the callback returns; a failure leaves the previous instruction intact; staging has no timeout because the URL cannot be deferred, and the cap bounds the work; playback has an explicit preflight and watchdog; sweep and delete failures retry at the next launch. |
| Timeouts and retry limits configurable | Pass | §9.1: `maxBytes` 209,715,200, `maxDurationSeconds` 180, `preflightTimeoutSeconds` 0.6, `readyWatchdogSeconds` 10, `orphanGraceSeconds` 60, `stagingChunkBytes` 1,048,576, all in the configuration types and injected. The staging write has no timeout by design and states why; OI-5 is the chunk-size measurement. No hardcoded retry count exists; retries are next-launch passes. |
| Operator-visible success and failure | Pass | §6.2 maps every surface and failure to what the person sees; §6.7 gives the plain copy; §10.7 states the copy voice. The instruction card has explicit `.none`, `.text`, `.image`, `.video`, `.unsupported` and `.removed` states; media failures fall back to the plain card; playback failures show a plain line with Close; no silent stub is designed. |
| Storage correctness and protection | Pass | §5.1 roots and no-IO init; §5.2 creation-before-bytes, bounded stream, cumulative cap, step-2 count, typed failures and cleanup; §5.3 protection at creation and verification; §5.4 same-volume rename; §5.5 pending purge and orphan sweep with nil-means-unknown; §5.6 transactional replace; §5.8 image store boundary; §5.9 read paths; §5.10 disk-full. The traversal guard is exact and runs before any name-derived URL. |
| Notification userInfo, taps and taxonomy | Pass | §2.14 handlers and tap branching; §2.17 content builder; §11.3 H payload; §11.3 B three taps; §11.3 S scoped cancels; §11.3 T no video attachment. The handlers always return `false`; `had_instruction` is a `Bool`; no instruction text, filename or URL is in `userInfo`; no instruction category, action or video attachment is added. |
| `EventExtrasStore.setPhotoFilename` mutation fix | Pass | §4.5 (`:1319–1335`), P-4 (`:25`), §11.3 F (`:2139`) and `EventExtrasStoreTests`. The rebuild is removed; only `photoFilename` changes; the two-order preservation test keeps `instruction` and the row count. |
| PII-free observability | Pass | §6.4 event catalogue, §6.5 release-log gate, §6.6 sanitisation and `LogSanitiser.allowedKeys`, §11.3 P and Q source hygiene, and `InstructionObservabilityTests`. Events carry closed-vocabulary fields and no content. |
| Concurrency and isolation | Pass | §7.1 isolation map, §7.2 shared resources, §7.3 single-flight, §7.4 callback-scoped URL, §7.5 cancellation and teardown, §7.6 unreadable-read safety. The store is `@unchecked Sendable` with its file work confined as stated; the sweep runs on the existing housekeeping queue; the presentation is main-actor. |
| Accessibility | Pass | §10.1 44 pt controls and 18 pt body floors; §10.2 Dynamic Type and the accessibility viewport; §10.3 VoiceOver labels and non-gesture-only controls; §10.4 motion, contrast and reach; `InstructionSurfaceTests` and `DesignTokensTests`. |
| Localisation | Pass | §10.5 36 keys in en and ne; §10.6 usage descriptions and built-bundle strings evidence; §10.7 copy voice; `L10n` lookups and `LocaleFormatters.shortTime(locale:)`; `L10nCatalogCoverageTests` covers source and built-bundle resources. |
| Performance budgets and test coverage | Pass | §8.1 500 ms interaction, 2 s playback start and 1 s failure detection; §8.2 IO discipline; §9.1 numbers; §11.2 suite map; §11.3 required cases; §11.5 the recorded device smoke. Every FR-RIE and NFR-RIE has named evidence in the traceability table above. |

## Scope statement

No scope creep was found. The design keeps the decoded `url` inert and ships no link, YouTube or URL control; no transcode, compression, trimming, cloud upload or thumbnails; no instruction notification category, action or attachment (`had_instruction` is a Boolean in `userInfo`); no medication-path change; no multi-instruction; no photo-library read (the picker is out of process and the recorder uses camera and microphone only); no Settings deep-link (OI-6 default); no audio transcription or captioning; and no `SpokenTime`. §1.4 (`:59–72`), §8.3–8.4 and §11.3 P and Q enforce the boundary.

The component set is L1's C01–C17. The only new files are the ones tabled in §2.0. The new `InstructionStagingFileOps` and `SystemInstructionStagingFileOps` types live inside `InstructionVideoStore.swift`, tabled in C02, so the seam adds no file. The shared files are all tabled: `RoutineScheduler.swift` and `RoutineStore.swift` in C11, `EventExtrasStore.swift` in C12, `FreeFormEventService.swift` in C13, the two notification handlers in C14, `AppCoordinator.swift` and `ContentView.swift` in C15, the plist and `project.yml` in C05, the two `InfoPlist.strings` resources in C05, and the feature views and editor files in C08–C10. The two `InfoPlist.strings` resources are localisation files required by L1 D10, not new scope. The permission copy's existing cloud disclosures describe current app behaviour; no new egress is introduced. The design adds no new permission key.

## Decision

Decision: GO

**Justification.** B-3, M-3 and M-4 are resolved in the artifact body. B-3 now creates the protected destination before any byte, fills it with a bounded chunked stream, verifies protection at creation and after the stream, fails closed on a weaker reported class, tolerates an unreported class only as the recorded R-5 limitation, and proves the kill window. M-3 now reads the built app bundle's en and ne `InfoPlist.strings` resources, so a missing `project.yml` registration actually fails. M-4 now has an implementable strict read in `RoutineStore`, a delegating scheduler accessor, and the unreadable, readable-but-empty and legacy-`[]` tests, so the nil-means-unknown sweep safety is real. Every earlier finding is intact, all 35 locked requirements are designed and traceable to named falsifiable evidence, every interface declares its errors, async and external failures have recovery paths, limits and timeouts are configurable, and the operator sees the success and failure states. No new blocker or major, no scope creep and no unsafe storage or privacy step was found.

**Conditions.** None block the decision. The following are implementation-time pins of the design's own claims, not further rework:

1. Implement the creation-before-bytes order exactly as §5.2 steps 5 to 7 and keep §11.3 E.1 through E.9 and the no-`copyItem` source scan.
2. Keep the built-bundle assertions in `L10nCatalogCoverageTests`; do not replace them with `Bundle.main.object(forInfoDictionaryKey:)`.
3. Keep `loadEntriesIfReadable()` returning nil on every read failure and keep the §11.3 K tests; do not use the legacy `loadEntries()` to build a live set.
4. Keep the refinement R-5 conditional attribute tolerance and do not weaken it; the unreported class is tolerated only because creation is the guarantee.
5. Keep the IF-26 label and the `setInstruction` translation for OI-1.

The rework budget is exhausted (`max_rework_iterations: 3`; this is review iteration 4). A GO here closes L2 and advances the workflow to `plan-tasks`.

This report is the only file written by this review. No reviewed artifact, requirement, constitution, workflow or code was modified. The preserved iteration-3 review copy in the run reviews directory was not edited. No build, test run, commit or workflow execution was performed.
