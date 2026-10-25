# review-l1 — Independent review of the L1 architecture (Reminders Instructions Enhancements)

| | |
|---|---|
| Task | `review-l1` (reviewer agent), contract `review_report` |
| Artifact under review | `specs/design-l1.md` (contract `architecture_l1`; worktree working tree, 1,199 lines, uncommitted modification at the scaffold base `821f19c5`) |
| Feature | `reminders-instructions-enhancements`, worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements`, branch `feat/reminders-instructions-enhancements` |
| Judged against | feature constitution (`specs/reminders-instructions-enhancements/constitution.md`, OD-1…OD-8 resolved 2026-10-25), `specs/define-requirements.md` plus `define-requirements/FR` and `define-requirements/NFR` (25 FR-RIE + 10 NFR-RIE), root `constitution.md` |
| Lock integrity | verified: the `define-requirements.md` snapshot sha256 matches the lock (`a02b9d4ee24a305ae396cf762304f1a13816f7bc1e81242e9f2adbaf0111bfb9`); all 35 requirement-file sha256 values match; 25 FR + 10 NFR; no drift |
| Method | full read of the design; every requirement file read (description and acceptance criteria); symbol-level verification of every load-bearing seam claim against the worktree code at HEAD (line numbers treated as orientation, symbols as contracts); the shipped implementation and the test tree checked directly |
| Decision | **NO_GO** — 2 blockers, 2 major, 8 minor. The architecture is fundamentally sound and reuses the right seams, but two locked MUST clauses are contradicted by the design as written (FR-RIE-006's pre-copy duration limit and FR-RIE-019's unresolved-owner/content tap branch), and the event-form save contract carries a silent instruction-loss ambiguity of the same class as the design's own `setPhotoFilename` hazard. Each has a bounded resolution; none requires abandoning the architecture. |

## Summary

The L1 architecture is directionally right and unusually well grounded: local-only media, the instruction embedded as an optional value in the two existing encrypted payloads, video bytes in dedicated Application Support roots, a single generic footer seam on the fired routine screen, unchanged notification handlers/facade/taxonomy, and a thin injectable playback seam with configurable timeouts. The design correctly identifies the `EventExtrasStore.setPhotoFilename` erasure hazard (verified real at `EventExtrasStore.swift:112–114`, and localized: no other `EventExtras(` construction site exists), verifies the routine footer seam (`VisualAidViews.swift:128`, rendered at `:232`), and keeps both fire handlers returning `false` with no category, action, or attachment change. Storage ordering matches the shipped `setPhoto` transaction (write → index → delete old), and the requirement lock is intact.

The decision is NO_GO for two locked-MUST conflicts that require design rework, not implementation interpretation. (1) FR-RIE-006 says "the limits must be enforced before the file is copied into the instruction store"; the design copies into `<root>/_pending/…` first and validates duration and playability afterwards. The size pre-check is correct; the 3-minute limit is not. (2) FR-RIE-019 says that if the owner or content cannot be resolved on the tap/Open path, the reminder content plus a plain fallback must show rather than a blank screen or a false success; the design's routine `didReceive` calls `onFire` only when `entry.instruction?.isPresent == true`, so a delivered notification whose instruction was removed, or whose entry was deleted, is silently inert on tap. Both fixes are bounded and keep the architecture.

Two majors must also be pinned before implementation: the event form's `InstructionDraft`/`hasChanges` is described but not wired into `saveFreeFormEvent(form, instruction: draft, …)`, while `InstructionWrite.kind == nil` means "remove" — an unrelated edit on an event whose draft failed to load can silently erase the instruction; and `InstructionVideoStore.existingFileURL` returns a bare `URL?`, which cannot produce the design's own `rejected_name` / `missing` / `unreadable` resolution outcomes required by FR-RIE-012's logging clause. The eight minors are interface/test/bookkeeping gaps listed below. The five flagged risks (D9 backup inclusion, D6 time-only-with-instruction, event-image 512 px, nested presentation, callback-scoped picker URLs) are all accepted as designed; D6 is the only reading that satisfies both FR-RIE-017/020 and NFR-RIE-010, and the staging copy inside the system callback is the correct and only safe answer to the ephemeral URLs.

No scope creep was found: no YouTube/link UI, no transcoding, no cloud, no medication-path change, no new notification category/action/attachment, and exactly one instruction per owner.

## Findings

### Blockers

**B-1 — The 3-minute duration limit is enforced after the file is copied into the instruction store (FR-RIE-006).**

Evidence:

- `specs/define-requirements/FR/FR-RIE-006-video-acceptance-limits.md:10`: "A video exceeding either limit **must** be rejected the same way. The limits **must** be enforced before the file is copied into the instruction store."
- Design `:304–319`: step 2a stats the source and rejects `> maxBytes` "before any copy"; step 2b copies into `<root>/_pending/<draftUUID>/…`; step 3 then "runs `InstructionVideoImporter.validate` off-main: duration, playability and a video track". The duration check is therefore after the copy.
- Design `:717–720`: `stageSynchronously(from:in:maxBytes:)` takes only the byte cap; its invariant at `:729–734` claims only the size pre-check.
- Design `:775–779`: the importer does a "defensive re-check of the byte cap, then the inspector", again after staging.

Effect: an over-long clip of up to ~200 MiB is copied into the instruction root before rejection. The user-facing rejection is still inside the pick flow and the previous instruction survives, but the locked requirement's ordering is violated. The design's implicit defense — that `_pending` is staging rather than the store — does not hold: `_pending` sits under the `InstructionVideos`/`EventInstructionVideos` root and `stageSynchronously` is an `InstructionVideoStore` method, so the copy is a copy into the instruction store.

Required resolution (design-l1 rework, bounded): inspect duration (and, for defense-in-depth, playability/video track) synchronously inside the picker/recorder callback before the stage copy, since the source URL is valid there, or extend `stageSynchronously` to take the duration limit and reject before copying; keep the off-main importer as the second check. If a synchronous metadata read is judged unacceptable, the deviation requires an owner-approved amendment to FR-RIE-006; this review cannot waive a locked MUST.

**B-2 — The routine tap/Open path is a silent no-op when the owner or content cannot be resolved (FR-RIE-019).**

Evidence:

- `specs/define-requirements/FR/FR-RIE-019-tap-open-path-foreground-honest.md:10`: "If the owner or content cannot be resolved on that path, the reminder/event content and a plain fallback (FR-RIE-020) **must** show rather than a blank screen or a false success."
- Design `:360–377`: the routine `didReceive` resolves the entry and calls `onFire(entry, notification.date)` **only** if `entry.instruction?.isPresent == true`; "Photo-only entries remain a no-op (today's behaviour)".
- Design `:1008–1010` (C14): "implement `didReceive` for `.default` with the instruction-presence guard".
- Shipped `RoutineVisualAidFireHandler.swift:72`: `didReceive` is an empty function today; the design preserves a no-op branch for the unresolved cases.

Effect: if the instruction object was removed after the notification was delivered (`instruction == nil`), or the entry was deleted (`entry == nil`), tapping the delivered banner or Open action does nothing — the "false success" the requirement forbids. If the instruction object exists but its file is missing, the handler does open and the card shows the fallback, so that sub-case is covered.

Required resolution: design an honest unresolved branch. If the entry resolves, open the fired screen with the reminder title/time and the plain fallback (the card already renders it); if the entry is gone, show a plain localized "no longer available" surface or route to the Reminders list. To keep photo-only taps byte-for-byte today's behaviour, add a `had_instruction` flag to the routine notification `userInfo` at arm time (a small, bounded `RoutineAlarmScheduler` change, with the text/banner and scoped-cancel contracts untouched) or explicitly justify an always-open-on-tap rule against NFR-RIE-010. A silent no-op is not an option under FR-RIE-019.

### Major

**M-1 — The event-form save conflates "leave unchanged" with "remove", risking silent instruction loss on an unrelated edit.**

Evidence:

- Design `:216–226`: `InstructionWrite.kind: InstructionKind? // nil = remove the instruction`.
- Design `:911–919`: the `EventInstructionSection` binds an `InstructionDraft` (an `InstructionWrite` plus a `hasChanges` flag) in `@State`, loads the existing instruction on `.onAppear`, and "The form's Save calls `coordinator.saveFreeFormEvent(form, instruction: draft, editing: event?.id)`." The `hasChanges` flag is never included in the call.
- Design `:922–932`: `save(_:instruction: InstructionWrite?, …)` and `setInstruction(_ instruction: InstructionWrite?, …)` take an optional write without defining what `nil` means; `setInstruction` mutates `extras(forEventId:) ?? EventExtras()`.
- The design's own risk 1 (`:1124–1127`) names `setPhotoFilename`'s fresh-`EventExtras` rebuild as the feature's most likely silent-data-loss bug; this is the same class one layer up.

Effect: on an existing event with an instruction, if the draft is empty because the `.onAppear` load has not completed or failed, pressing Save for an unrelated change (title, time, photo) can pass a non-nil write whose `kind` is nil and erase the instruction. The `hasChanges` flag shows the intent to avoid this, but the specified call does not wire it.

Required resolution (design-l2 at the latest): define `nil` = "leave the instruction untouched"; explicit removal is a non-nil write with `kind == nil` (or a distinct `.remove` case); the form passes the draft only when `hasChanges`, and Save is disabled until the initial load completes. Add regression tests: edit title/photo with an existing instruction untouched → the instruction survives; explicit Remove → removed; a failed load cannot erase.

**M-2 — `existingFileURL -> URL?` cannot produce the design's own resolution classification (`rejected_name` / `missing` / `unreadable`).**

Evidence:

- Design `:443–445`: `InstructionPlaybackAvailability` has `available, rejectedFilename, missingFile, unreadableFile`.
- Design `:722`: `func existingFileURL(filename: String, for owner: InstructionOwner) -> URL?`.
- Design `:738–739`: it "returns nil for a non-plain name, an absent file, or an unreadable file".
- Design `:594`: the `instruction_resolution` event's `outcome` is `rejected_name` / `missing` / `unreadable`.
- `specs/define-requirements/FR/FR-RIE-012-filename-hygiene-traversal-guard.md:10`: "The rejected lookup **must** be logged PII-free (event type and outcome only; no file name or path — NFR-RIE-004)."

Effect: the card cannot distinguish the three outcomes and cannot emit the specified event; the design's observability table and FR-RIE-012's logging clause are unimplementable through this interface. The elder-facing fallback text is the same in all three cases, so the defect is classification/logging plus the reviewer's explicit-error-type rule, not the fallback itself.

Required resolution: return `InstructionPlaybackAvailability` (or `Result<URL, InstructionPlaybackAvailability>`) from the store/card resolution seam and emit `instruction_resolution` from the same classification. Add store/card tests for traversal, absent, and unreadable inputs asserting distinct outcomes and no filename in the event.

### Minor

**m-1 — The free-form event handler's instruction-lookup dependency is unspecified.** Design `:363` gates `willPresent` on `instruction(forEventId:)?.isPresent`, but C14 `:1011` says only "`photoFilename != nil || instructionPresent`", and C15 `:1028` names only the routine handler's new sink. The shipped `FreeFormEventFireHandler` has `eventLookup` only (`FreeFormEventFireHandler.swift:69`). Specify a second dependency (service or `(String) -> Bool` lookup) in C14/C15 and its fake; keep always-`false`.

**m-2 — `InstructionStorageError.deleteFailed` is unreachable through the specified store interface.** Design `:723–724` declares `delete(...)` and `deleteAll(...)` as Void; `:546` says `deleteFailed` is "Raised by store"; `:280` says "a filesystem refusal is logged"; `:592` requires an `instruction_media_delete` outcome. A Void method cannot report the failure the taxonomy and the event require. Return Bool/Result, or have the store emit the typed delete outcome itself and remove `deleteFailed` from the raised-by list.

**m-3 — `RoutineAlarmSchedulerTests` does not exist, yet the design cites it as an extended suite and as the primary evidence for FR-RIE-021/022.** Design `:964`, `:1059`, `:1096–1097`; a repository-wide search finds no such suite (only the design's text mentions it). Label it a new suite, or fold the no-video-attachment/copy regression into `RoutineSchedulerTests` / `NotificationCategoriesTests` and name the real gate. FR-RIE-022 is a MUST; its evidence cannot be a nonexistent suite.

**m-4 — "Byte-identical" overclaims while the shared screen gains a defaulted `timeText` parameter.** Design `:400–406` says the shared `ReminderVisualAidScreen` "is untouched" and its source is "byte-identical"; `:1175–1177` says "the only shared-view addition is the optional `timeText` parameter with a default". NFR-RIE-010's "byte-for-byte today's behaviour" is a behaviour claim; the source changes by one defaulted parameter. Reword to "behaviourally identical for no-instruction and medication call sites" and make the source-scan baseline allow and pin the parameter; no-instruction entries must pass `timeText == nil` and render the same view tree.

**m-5 — Protection is applied after the staging copy, not at write time.** Design `:257–261`: "each staged and committed file gets `FileProtectionType.complete` set after the copy"; FR-RIE-011 and NFR-RIE-005 require every video file be "written with `.completeFileProtection`", and the shipped `VisualAidStore.save` writes with `[.atomic, .completeFileProtection]` (`VisualAidStore.swift:113–128`, attribute at `:123`). The staged file exists briefly with the default class; a crash leaves it until the launch purge. Apply protection at the write/copy (fail-closed delete on any set/verify error) and state the staging-window guarantee; add a store test asserting the staged file's attribute as well as the committed file's.

**m-6 — `preflightTimeoutSeconds = 1.0` equals NFR-RIE-008's 1 s failure bound, leaving no margin.** Design `:566–570` labels it "NFR-RIE-008 failure bound"; `:82–84` acknowledges the 1 s bound and the 10 s watchdog. NFR-RIE-008's target is that the plain fallback appears within 1 s; a 1.0 s preflight timeout plus cover/render overhead lands at or after the bound, not within it. Use a sub-second default (for example 0.5–0.8 s) with 1 s as the outer acceptance bound, or define the measurement point (from tap, with the cover already presented) explicitly. The 500 ms presentation target is credible because the cover appears before preflight; the 2 s first frame is device evidence.

**m-7 — The recorded device smoke does not specify a Release build.** NFR-RIE-009's acceptance says "Given a Release build installed on the reference device"; design `:1063–1066` says only "One recorded real-device smoke check". Name the Release build and record it in the evidence.

**m-8 — `InstructionImageLoading` is named but its signature and failure classification are unspecified.** Design `:661` lists it among the in-process protocols and `:870–872` says two adapters implement it, but no interface is given. Image loading is fallible and the card shows a plain fallback (`:425`). Specify an explicit success/failure result (for example `Result<UIImage, InstructionImageFailure>` or an optional plus a resolution classification) and a test double.

### Notes (non-blocking)

- **Citation drift is orientation-level, as declared.** Spot-checked: `modelHousekeepingQueue` cited `:567`, actual `:571`; `EventExtrasStore.setPhotoFilename` cited `:111–113`, actual `:112–114`; `EventDetailView` cited `:550`, actual `:549`. Every named symbol exists and behaves as claimed; no seam claim failed on content.
- **Release-gate naming is accurate.** The design's `FEATURE_ROOTS` change targets `ios/tools/check-release-log-safety.py:184`; `ios/build.sh:431` invokes the `.sh` wrapper, and the requirement names the `.sh` entry point. No inconsistency.
- **The observability vocabulary needs no new sanitiser keys.** Verified `LogSanitiser.allowedKeys` (`:56`) contains `outcome` (`:62`), `error_code` (`:65`), `durationMs` (`:180`), `count` (`:182`) and `kind` (`:402`); the fail-closed filter is at `:633–638`.
- **Heuristic source scans are honestly labelled.** `InstructionSurfaceTests` / `InstructionReleaseSafetyTests` pin tokens rather than semantics; the design states that limit, and the release gate backs it. Accepted.
- **The `_pending` purge belongs on the existing housekeeping queue.** The queue exists (`AppCoordinator.swift:571`) and the design keeps the store's init IO-free (the `VisualAidStore` doctrine). Accepted.

## Requirement traceability

All 35 locked requirements are listed. Status: **covered** = substantive design treatment that satisfies the requirement as written; **partial** = treatment exists but a locked clause is contradicted or cannot be implemented through the specified interface (the finding is named).

| Requirement | Status | Design treatment and review note |
|---|---|---|
| FR-RIE-001 model, one kind | covered | Data model; C01/C11/C12. One optional instruction; bare filename/identifier; unknown kind decodes; no bytes in the payload. |
| FR-RIE-002 text instruction | covered | Capture · Text; C01/C08. Trim/normalize; blank is not an instruction; removal is explicit. |
| FR-RIE-003 image via existing stores | covered | D3; C09/C10/C13. Reuses `VisualAidStore` / `ContactPhotoStore("EventPhotos")`; event images inherit the 512 px pipeline (accepted risk 3). |
| FR-RIE-004 library pick | covered | C04. `PHPickerViewController` `.videos`, `selectionLimit = 1`, `.current`; permission-free. |
| FR-RIE-005 in-app recording | covered | C04/C05. `UIImagePickerController` video with configured maximum duration/quality; cancel is not an error. |
| FR-RIE-006 limits, as provided, codec reject | **partial** | Configuration; C02/C03. Size rejected pre-copy, no transcode, codec rejected in the pick flow — but the 3-minute limit is checked after the staging copy (**B-1**). |
| FR-RIE-007 optional caption | covered | C01/C08. Trimmed; blank reserves no space; text instructions have no separate caption. |
| FR-RIE-008 lifetime and edits | covered | C11/C13. Instruction belongs to the owner; `setInstruction` follows `persistAndReschedule`; no per-occurrence copy. The event-form unrelated-edit path needs **M-1** to fully preserve the stored instruction. |
| FR-RIE-009 existing edit surfaces | covered | C09/C10. Routine manage sheet and event form/detail; no standalone media screen. |
| FR-RIE-010 plain feedback, safe failure | covered | Error taxonomy; C04/C09/C10. Every action has a visible state; failures keep the draft/previous instruction; cancellation is an outcome. |
| FR-RIE-011 roots, bare names, protection | covered | Storage; C02/C11/C13. Dedicated routine/event roots; bare names; per-owner layout. Protection-at-write needs **m-5**. |
| FR-RIE-012 filename hygiene | **partial** | Storage; C01/C02/C08. Traversal/absolute names are rejected and treated as missing with the plain fallback, but the required PII-free rejected-lookup classification is not expressible through `existingFileURL -> URL?` (**M-2**). |
| FR-RIE-013 transactional replace | covered | Storage lifecycle; C11/C13. Write pending media → index → delete old; failures delete the new file and keep the previous instruction. |
| FR-RIE-014 delete with owner | covered | C11/C13. Routine delete removes the video directory; event delete/reconcile removes the video and image; removing only the instruction keeps the owner and other media. Delete-failure reporting needs **m-2**. |
| FR-RIE-015 always fires | covered | Fire-time; C14. Delivery is untouched; handlers always return `false`; media failure never blocks or mutes. |
| FR-RIE-016 handlers always false | covered | C14. Verified shipped handlers return `false`; the facade is unchanged. |
| FR-RIE-017 composition per kind | covered | D5/D6; C08/C09/C10. Text/image/video render per kind; instruction-only entries present; title and time for instruction-bearing firings. |
| FR-RIE-018 explicit Play, no autoplay | covered | C06/C07/C08. The cover appears on the tap, no player is built on appearance, and the feed precedent verifies the "play only after the explicit tap" pattern. |
| FR-RIE-019 tap/Open path | **partial** | C14/C15. The instruction-present path is designed and the event path opens the detail, but the unresolved owner/content branch is a silent no-op for routines (**B-2**). |
| FR-RIE-020 plain fallback, PII-free | covered | Error taxonomy; C06/C08. Missing/corrupt/unsupported/traversal all map to one plain localized line while the reminder stays; the failure log uses type + outcome only. The tap-path unresolved case is **B-2**. |
| FR-RIE-021 taxonomy preserved | covered | Notification integration. No new category/action; `NotificationCategories` untouched; scoped cancels only. Test evidence naming needs **m-3**. |
| FR-RIE-022 no video attachments/copies | covered | Notification integration; C11. `RoutineAlarmScheduler` untouched; no video path into `UNNotificationAttachment`; re-arming copies nothing. Test evidence naming needs **m-3**. |
| FR-RIE-023 no new machinery | covered | Notification integration; C14. No acknowledgement/escalation/re-fire/missed-event surface; medication machinery untouched. |
| FR-RIE-024 honest capability surface | covered | Data model (`url` inert); D8; C08. No link/YouTube control; unknown kinds show a plain "newer version" note with no control; no background claim. |
| FR-RIE-025 permissions, denial non-blocking | covered | C05. Point-of-use camera then microphone; plain pre-permission explanation; denial leaves library pick and the reminder working; `Info.plist` amended with en/ne `InfoPlist.strings`. |
| NFR-RIE-001 accessibility | covered | Accessibility section; C08/C09/C10. 44 pt floor (`DesignTokens.minTapTargetSize` :127) and 60 pt chips (:156); 18 pt text floor (`AppTypography` :28–37); VoiceOver labels; no instruction-specific motion; largest-text-size smoke. |
| NFR-RIE-002 en/ne localisation | covered | Localisation section; C16. Every new string in `Localizable.xcstrings` with en+ne; new `InfoPlist.strings` in both locales; parity tests. |
| NFR-RIE-003 no new egress | covered | Layering; C03/C06/C07. Local-only APIs; no network client; static scan plus release gate. |
| NFR-RIE-004 PII-free logs, release gate | covered | Observability section; C04. Closed vocabulary on existing allowed keys; the new roots are added to `FEATURE_ROOTS`; the gate runs from `build.sh`. |
| NFR-RIE-005 at-rest protection | covered | Storage; C02. `.completeFileProtection`, Application Support only, no Photos/share exposure. Protection-at-write needs **m-5**. |
| NFR-RIE-006 migration | covered | Data model; C01/C11/C12. Optional fields, tolerant `decodeIfPresent`, pre-feature fixtures; never lose the owner payload to a bad instruction object. |
| NFR-RIE-007 footprint, zero orphans | covered | Storage lifecycle; C02/C11/C13. One file per owner, ≤200 MiB, replace/delete cleanup, no per-re-arm copies. Delete-failure reporting needs **m-2**. |
| NFR-RIE-008 playback responsiveness | covered | Playback; Configuration; C06. 500 ms cover, configurable preflight, 10 s watchdog; targets are device acceptance evidence. The 1.0 s preflight equals the failure bound (**m-6**). |
| NFR-RIE-009 playback seam and gates | covered | Playback seam; C06/C16. Injectable protocol, four scripted outcomes, simulator failure paths, one device smoke. Name the Release build (**m-7**). |
| NFR-RIE-010 preserved baseline | covered | Notification integration; D5/D6; C14. Medication paths, banner/list/sound, read-aloud and no-instruction firings are behaviourally unchanged. The "byte-identical" wording needs **m-4**. |

## Risks accepted

The five risks the task asked the review to judge are accepted as designed, with the reasons recorded here. None is a blocker.

1. **D9 — instruction video is included in the normal iOS device backup (no `isExcludedFromBackup`). Accepted.** This is parity with the shipped photo aids and the encrypted payloads, adds no app network path, and backup is OS-mediated. It should be stated in the owner-facing report; if the owner wants backup-excluded media, that is a scope change, not a design defect.
2. **D6 — the fired time is shown only when an instruction is present. Accepted.** FR-RIE-017/020 require title and time on instruction-bearing firings, while NFR-RIE-010 requires no-instruction firings to stay byte-for-byte today's behaviour. Showing the time only on the instruction-bearing fired screen is the only reading that satisfies both. The delivery-time source (`UNNotification.date`) is the honest "when this fired"; the scheduled-time alternative would require a bound scheduler change and is not required.
3. **Event image instructions inherit `ContactPhotoStore`'s 512 px thumbnail pipeline. Accepted.** FR-RIE-003 binds image instructions to the existing event photo path and forbids a parallel image store; the resolution consequence is a requirements consequence, not a design choice. Flag it to the owner for diagram legibility; a sharper event image would be a new requirement.
4. **Nested presentation — the player cover lives inside the fired `fullScreenCover` or the event `sheet`. Accepted, conditional on the stated evidence.** The design checks the nested path first in the device smoke and names a bounded fallback (hoist the cover to `ContentView` through coordinator state) that does not change the injectable seam. The risk is real but adequately contained.
5. **Callback-scoped picker/recorder URLs. Accepted.** The PHPicker `loadFileRepresentation` URL and the `UIImagePickerController` `mediaURL` are valid only inside their callbacks; the design's synchronous `stageSynchronously` is the correct and only safe answer, and it keeps the rule in one place. The system UI cannot run in unit tests; the device smoke is the honest evidence.

Additional accepted risks: the unknown-kind "newer version" note with no control (honest, forward-compatible, FR-RIE-024); the deliberate absence of a UI test (OD-7); the delivery-time semantics (above); and the source-scan heuristics (backed by the release gate, labelled as heuristic in the design).

## Follow-ups for design-l2 and implementation

1. **B-1:** move the duration (and, as defense-in-depth, playability/video-track) check before the stage copy; update the C02/C04 interfaces and add a test that an over-long source never reaches the staged copy (a byte-counter/file-manager spy or a `stageSynchronously` duration parameter). If a synchronous metadata read is rejected, raise an owner amendment to FR-RIE-006 instead of implementing the deviation silently.
2. **B-2:** design the unresolved routine tap surface (entry resolves → fired screen with title/time plus the plain fallback; entry gone → plain unavailable surface or Reminders route). If a `had_instruction` userInfo flag is added, keep the notification text/banner and scoped-cancel contracts untouched. Test three tap cases: instruction present, instruction removed, entry deleted.
3. **M-1:** pin `InstructionWrite?` semantics (`nil` = leave unchanged; explicit removal is a non-nil write with `kind == nil` or a distinct `.remove`), wire `hasChanges` into the save call, disable Save until the initial load completes, and add the regression tests named in the finding.
4. **M-2:** return the availability classification from the store/card resolution seam and emit `instruction_resolution` from it; test traversal, absent and unreadable cases and assert no filename in the event.
5. **m-1 through m-8:** specify the event handler's instruction lookup; return a delete outcome or emit the typed delete event; label `RoutineAlarmSchedulerTests` as new or retarget the FR-RIE-021/022 evidence; reword the "byte-identical" claim; apply protection at write; lower the preflight default below the 1 s bound (or define the measurement point); name the Release build in the smoke; and specify `InstructionImageLoading` with an explicit failure type.
6. **Implementation order:** fix `EventExtrasStore.setPhotoFilename` first (the verified erasure hazard; the fix is localized because no other `EventExtras(` construction site exists), then the model/decode, then the video store, then the services, then the fire handlers, then the UI, then the gates. The `RoutineEntry(` construction sites are new-entry/seed only, so there is no wholesale rebuild that would drop the new field.
7. **Evidence to carry:** scoped `xcodebuild test` suites green with the full-suite baseline unchanged; typecheck/build clean; the Release log gate green after adding `Services/Instructions`, `App/InstructionViews.swift` and `App/InstructionCapture.swift` to `FEATURE_ROOTS`; the recorded Release-build device smoke covering library pick, recording with permissions, fired routine Play with audio, event detail Play, close-stops-audio, largest accessibility text, VoiceOver labels, camera denial, microphone denial, and the foreground-only copy; the simulator failure matrix for missing, corrupt, unsupported, traversal, replace failure, playback failure and timeout.
8. **Owner-facing report:** state D9 (backup inclusion), the event-image 512 px consequence, D6 (time shown only on instruction-bearing firings), and the foreground-only/no-background-video limitation. None is a blocking decision for this review.

## Verification record

- **Requirement lock:** snapshot sha256 matches; all 35 requirement-file hashes match the lock; 25 FR + 10 NFR; no drift. The design was read in full (1,199 lines).
- **`EventExtrasStore` hazard:** `setPhotoFilename` rebuilds `EventExtras(photoFilename:)` at `EventExtrasStore.swift:112–114`; `EventExtras` is at `:25`, `photoFilename` at `:30`, tolerant decode at `:41–45`, `track` at `:104–107`, `remove` at `:131–137`. No other `EventExtras(` construction site exists outside the store file. The design's fix is correctly localized.
- **Routine fired-screen seam:** `ReminderVisualAidScreen` has the generic `footer` at `VisualAidViews.swift:128`, rendered at `:232`, with the `EmptyView` convenience at `:137`/`:289`; `FiredRoutineVisualAids` at `:295`; `RoutineVisualAidOverlay` at `:306`. The footer seam is real and supports the zero-behavioural-change claim for medication and photo-only call sites (source changes only by the defaulted `timeText` parameter, **m-4**).
- **Notification layer:** `RoutineVisualAidFireHandler` returns `false` at `:48`/`:58`/`:65`, gate at `:55`, `didReceive` no-op at `:72`; `FreeFormEventFireHandler` returns `false` at `:62`/`:70`/`:77`, gate at `:69`, `didReceive` at `:87`; `NotificationFacade` is unchanged. No category, action, or attachment change is designed.
- **Storage and lifecycle:** `VisualAidStore` no-IO init `:74–104`, `save` `:113–128`, `.completeFileProtection` `:123`, `existingFileURL` `:142`, `deleteAll` `:158`, `safeDirectoryURL`/`fileURL` `:227–241`, `isPlainFilename` `:243–249`; `FreeFormEventService.setPhoto` `:396–414` (write → index → delete old), `upcoming` prune `:293–315`, `delete` `:424–431`; `RoutineScheduler.removeEntry` → `deleteAll` `:111–117`, `setVisualAids` `:131–137`, `persistAndReschedule` `:202–213`. The design's transactional ordering matches the shipped precedent.
- **`RoutineAlarmScheduler`:** userInfo `:75–79`, first-photo attachment `:82–87`, throwaway copy `:108–143`, scoped cancels `:145–153`. No video path is added; the FR-RIE-022 claim holds.
- **`RoutineEntry`:** `visualAids` `:100`, CodingKeys `:126–129`, tolerant decode `:135–145`; `RoutineEntry(` construction sites are `RoutinePlugin.swift:125` and `RoutineStore.defaultEntries()` seeds only, so no persisted-entry rebuild drops the new field.
- **Composition anchors:** `AppCoordinator.modelHousekeepingQueue` actual `:571` (design `:567`); `firedRoutineVisualAids` `:13395`; `presentRoutineVisualAids` `:13441`; handler wiring `:4591–4598` and `:4626–4633`; `freeFormEventService` `:12862`; `saveFreeFormEvent` `:12898`.
- **Playback precedent:** `FeedMediaPlayerSheet` at `FeedsView.swift:649` starts playback on appear only because an explicit Play tap opened the sheet; `VideoPlayer` at `:686`/`:695`. Verified; the no-autoplay claim is credible.
- **Observability:** `LogSanitiser.allowedKeys` at `:56` includes `outcome` `:62`, `error_code` `:65`, `durationMs` `:180`, `count` `:182`, `kind` `:402`; the fail-closed filter is at `:633–638`. No new key is needed.
- **Release gate:** `check-release-log-safety.py` `FEATURE_ROOTS` at `:184`; `build.sh` invokes the `.sh` wrapper at `:431`; scoped `-only-testing` at `:458`.
- **Accessibility and localisation:** `DesignTokens.minTapTargetSize` `:127`, `chipHeight` `:156`; `AppTypography` body/caption `:28–29`, floor `:35–37`; `Localizable.xcstrings` en+ne (1,498 keys); no `InfoPlist.strings` exists today, so the design's new-file plan is correct.
- **Test tree:** the design's named existing suites are present (`RoutineEntryTests`, `RoutineSchedulerTests`, `RoutineStoreTests`, `VisualAidStoreTests`, `VisualAidDisplayStateTests`, `RoutineVisualAidFireHandlerTests`, `EventExtrasStoreTests`, `FreeFormEventServiceTests`, `FreeFormEventFormTests`, `FreeFormEventFireHandlerTests`, `NotificationFacadeTests`, `NotificationCategoriesTests`, `NoIOInInitTests`, `L10nCatalogCoverageTests`, `MedicationEditorSurfaceTests`, `FeatureSourceScan`) with the single exception of `RoutineAlarmSchedulerTests` (**m-3**).
- **Scope:** no YouTube/link UI, no transcoding, no cloud, no medication source change, no new notification category/action/attachment, and one instruction per owner. No scope creep found.

## Decision

Decision: NO_GO

Rework is required before this design is ratified. The architecture is retained; the rework is bounded:

- **B-1 (blocker):** enforce the 3-minute duration limit before the file is copied into the instruction store, per FR-RIE-006, or raise an owner-approved amendment.
- **B-2 (blocker):** the routine tap/Open path must show the reminder content plus the plain fallback when the owner or content cannot be resolved, per FR-RIE-019, instead of a silent no-op.
- **M-1 (major):** pin the event-form `InstructionWrite?` / `hasChanges` semantics so an unrelated edit cannot silently erase the instruction.
- **M-2 (major):** make the resolution seam return the availability classification so the FR-RIE-012 logging and the design's own `instruction_resolution` event are implementable.
- **Minors m-1…m-8** may be resolved in design-l2, provided each named resolution lands and the named tests exist.

Resubmit the revised design-l1 for re-review. The five flagged risks (D9, D6, 512 px, nested presentation, callback-scoped URLs) are accepted as designed and do not need rework.
