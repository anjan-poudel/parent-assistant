# review-l2 — Independent review of the L2 component design (Reminders Instructions Enhancements)

| | |
|---|---|
| Task | `review-l2`, contract `review_report` |
| Artifact under review | `specs/design-l2.md` (2,078 lines; `design-l2` COMPLETED 2026-10-25T09:14:21Z) |
| Feature | `reminders-instructions-enhancements` |
| Worktree / branch | `/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements` / `feat/reminders-instructions-enhancements` |
| Judged against | root `constitution.md`; feature constitution `specs/reminders-instructions-enhancements/constitution.md` (OD-1…OD-8 resolved); `specs/define-requirements.md` + the 35 locked requirement files; `specs/design-l1.md` (approved); `specs/review-l1.md` (GO; N-1…N-5); the shipped code in this worktree |
| Requirement lock | verified first-hand: snapshot sha256 `a02b9d4ee24a305ae396cf762304f1a13816f7bc1e81242e9f2adbaf0111bfb9` matches; 35/35 per-file sha256 match; 25 FR + 10 NFR; 107 acceptance scenarios; no drift |
| Method | full read of design-l2 (2,078 lines); design-l1 and review-l1 re-read; all 35 requirement files re-read; traceability re-derived requirement-by-requirement; every load-bearing citation spot-checked against source; no artifact modified |
| Decision | **NO_GO** — two blocking contradictions with locked requirements and the approved L1, two required traceability corrections, four non-blocking minors |

## Summary

The engineering core of this design is review-grade. It gives a complete interface register (IF-1…IF-32), five typed error enums (`InstructionImportError`, `InstructionStorageError`, `InstructionWriteError`, `InstructionPlaybackFailure`, `InstructionImageFailure`), fail-closed at-rest protection (`.completeFileProtection` created and verified), a transactional replace (bytes before index, index before old-byte delete), an orphan sweep with nil-means-unknown safety and a 60 s grace window, a fully injectable playback seam with both timers owned by one type, a typed PII-free emitter whose fields are already in `LogSanitiser.allowedKeys`, configurable limits and timeouts in value types, a 34-key en+ne copy catalogue, and a requirement-to-suite map that names a test for every acceptance area. The load-bearing citations were spot-checked and are accurate, and the design records its genuine L1 refinements (R-1…R-7, OI-1…OI-8).

It cannot be approved as written, for four reasons:

1. **B-1 (blocking):** the routine tap path on an entry deleted after arming is specified as a **no-op**, and the L1/review-l1 mandated `instruction.reminderUnavailable` surface is removed from the model, copy, accessibility map and tests. FR-RIE-019 requires a plain fallback when the owner cannot be resolved; review-l1 closed B-2 on exactly that surface.
2. **B-2 (blocking):** the persisted instruction kind is renamed to `"note"` (case `.note`, copy key `instruction.kind.note`, label "Note"). FR-RIE-001's locked acceptance pins kind `"text"`, and L1's model is `case text, image, video` with a `{"kind":"text",…}` payload. The change is not recorded in §1.3 or §13.
3. **M-1 (major):** FR-RIE-025's explicit request order — "camera is requested first and microphone next" — is not specified or tested anywhere.
4. **M-2 (major):** FR-RIE-024 (honest capability surface) is unaddressed in the test plan and mis-mapped to `InstructionPermissionTests`; the `instruction.foregroundNote` copy L1 proposed is dropped; FR-RIE-021 and FR-RIE-022 are also mis-mapped or lack the taxonomy/attachment evidence their acceptance scenarios require.

Fixing B-1 and B-2 is mechanical and preserves the architecture; they are not invitations to redesign. M-1 and M-2 are small additions to C04/C05, the copy table, §10.3, §11.2 and §11.3.

## Findings

### B-1 — Routine tap with the entry deleted after arming is a no-op (FR-RIE-019; review-l1 B-2; L1 D14)

**The locked and approved contract.**

- FR-RIE-019, Description: "If the owner or content cannot be resolved on that path, the reminder/event content and a plain fallback (FR-RIE-020) **must** show rather than a blank screen or a false success."
- L1 tap resolution (`design-l1.md:473–476`): `had_instruction == true`, entry gone (deleted after arming) → plain localized "This reminder is no longer available." surface (`instruction.reminderUnavailable`) with a Close control; no title/time is claimed because none can be resolved.
- L1 fired-screen model (`design-l1.md:493–520`): `FiredRoutineVisualAids.Content` has `.reminder(…)` and `.unavailable`; `RoutineVisualAidOverlay` maps `.unavailable` to the shared screen with `aids: []`, `title: instruction.reminderUnavailable` and an `EmptyView` footer.
- review-l1 B-2 resolution (`review-l1.md:42–43`): case (3) is the `instruction.reminderUnavailable` notice with Close; the tap sink resolves the entry as **optional** (`onInstructionTap(entryId, entry?, notification.date)`), C15 maps `entry == nil` to `.unavailable`, and "`InstructionSurfaceTests` covers the `.unavailable` surface".

**What L2 specifies instead.**

- `design-l2.md:34` (P-13): "Three tap cases are specified: present, instruction-removed fallback, **entry-deleted no-op**", attributed to "L1 tap branching" — L1 says the opposite.
- `design-l2.md:274` (§2.14 item 3): "Entry exists and instruction gone ⇒ present with `.removed`; **entry gone ⇒ no-op**."
- `design-l2.md:1084–1112` (§4.10): the handler sink is `onFire(RoutineEntry, RoutineInstructionFireContext)` — there is no optional-entry tap sink; the coordinator entry point is `presentRoutineVisualAids(for entry: RoutineEntry, …)`, so a deleted entry cannot reach presentation at all.
- `design-l2.md:1318–1329` (§4.11): `FiredRoutineVisualAids` has `instruction`, `instructionExpected`, `firedAt`; there is no `.unavailable` content state.
- `design-l2.md:1490–1501` (§6.2): the failure matrix has a row for "Instruction removed since arming" and none for an owner deleted after arming.
- `design-l2.md:1797–1812` (§10.3): no VoiceOver row for the owner-deleted notice.
- `design-l2.md:1831–1864` (§10.5): all 34 keys; `instruction.reminderUnavailable` is absent (L1 listed it at `design-l1.md:835`).
- `design-l2.md:1950` (§11.3 B.3): the test asserts "no `onFire`, `willPresent`/`didReceive` both return `false`" — codifying the no-op.
- This also contradicts L2's own copy principle at `design-l2.md:1585`: "A removed instruction is stated, not hidden … the tap did something, and the person is told what."

**Why blocking.** A locked MUST clause and a prior review's explicit resolution are reversed silently. The entry-deleted case is precisely "the owner cannot be resolved"; a no-op is the dead tap FR-RIE-019 forbids. The three-case matrix in review-l1 was the evidence that closed B-2; changing case (3) reopens it.

**Required rework.**

1. Restore an owner-unresolved presentation path with L1's shape: the routine tap sink carries the optional entry (`onInstructionTap(entryId: UUID, entry: RoutineEntry?, firedAt: Date)` or an equivalent typed result), and the coordinator maps `entry == nil` to a `.unavailable` presentation (a `FiredRoutineVisualAids.Content` case or an equally explicit value) rendered by `ReminderVisualAidScreen` with `aids: []`, title `instruction.reminderUnavailable`, `EmptyView` footer and a Close control. No title/time is claimed.
2. Add `instruction.reminderUnavailable` (en + ne) to the copy catalogue and a §10.3 VoiceOver row (static text plus Close button).
3. Add the §6.2 matrix row and a §11.3 case: `had_instruction == true`, entry deleted ⇒ the unavailable surface is presented and Close works; both notification callbacks still return `false`.
4. Correct P-13's attribution: L1 says the entry-deleted case is a notice, not a no-op. The photo-only and pre-upgrade no-op cases are unchanged.

### B-2 — Persisted kind `"note"` contradicts the locked `"text"` kind (FR-RIE-001; L1 model)

**The locked and approved contract.**

- FR-RIE-001 acceptance ("A free-form event carries a text instruction"): "the event extras are persisted with instruction kind **"text"** and the written steps".
- L1 (`design-l1.md:195–196`): `enum InstructionKind: String, CaseIterable, Codable { case text, image, video }`; payload (`design-l1.md:252`): `{"kind":"text","text":"Lift your toes up and down ten times."}`; copy family (`design-l1.md:829`): `.kind.text/.image/.video`.
- FR-RIE-024's future-kind scenario uses kind `"link"` — independent confirmation that the known-kind vocabulary is `text`/`image`/`video`.

**What L2 specifies instead.**

- `design-l2.md:466`: `case note, image, video`.
- `design-l2.md:113`: "Known kinds are `note`, `image`, `video`"; `:569`: `kind == "note"`; `:1126`: raw values `"note"`, `"image"`, `"video"`; `:1242`: fixture F-3 `{"kind":"note","text":"Take the blue pill"}`.
- `design-l2.md:1835`: copy key `instruction.kind.note`, English "Note".
- The overview (`design-l2.md:14`) restates "three media kinds (note, photo, video)" as if L1 fixed that vocabulary; L1 fixed text/image/video.
- Neither §1.3 (R-1…R-7) nor §13 (OI-1…OI-8) records this change.

**Why blocking.** The raw kind is the persisted representation the requirement's acceptance scenario names. An implementation that follows L2 fails FR-RIE-001 as locked and diverges from the approved L1 data model. Design cannot amend a locked requirement; a silent rename is exactly the kind of absorption §1.3 exists to prevent. There is no migration justification: the feature has no shipped payloads.

**Required rework.**

1. Use `text` as the case and raw value; update all payloads, fixtures, `InstructionKind.reportable(_:)` mappings, observability `kind` values and tests (fixture F-3).
2. Rename the copy key to `instruction.kind.text`; the English label may remain "Text" (or a justified display synonym, but the raw value must be `text`).
3. Correct the overview's attribution to L1. If a display label different from the raw value is desired, state it explicitly; do not let the raw value drift from the locked term.
4. Keep an independently unknown value (e.g. `"link"`) in the unknown-kind tests so tolerance is still proven with a genuinely unknown kind.

### M-1 — FR-RIE-025's camera-then-microphone request order is unspecified and untested

- FR-RIE-025 acceptance: "Given the caregiver taps record for the first time / When the system permission prompts appear / Then **camera is requested first and microphone next**".
- L2 C05 (`design-l2.md:757–778`) defines the permission enum and seam but no order. C04 (`design-l2.md:156`) says only "Permissions are checked before the recorder is presented".
- §11.2 (`design-l2.md:1919`) maps `InstructionPermissionTests` to FR-RIE-024/025, but the listed cases are "status mapping; no re-prompt when denied; no `unavailable` trap" — no ordering case.

**Required rework.** Specify in C04/C05 that the coordinator checks/requests camera first and microphone second when both are undetermined, then presents the recorder; add an `InstructionPermissionTests` case that records the request sequence and asserts camera-before-microphone (with denial short-circuiting). Correct the FR-RIE-024 mapping per M-2 at the same time.

### M-2 — FR-RIE-024 honesty surface unaddressed; FR-RIE-021/022 evidence mis-mapped or missing

- FR-RIE-024 requires no YouTube/link control, honest degradation of a future kind, and an honest foreground-only statement; its acceptance inspects "the video instruction UI and the feature report".
- L2 mentions FR-RIE-024 once, in the wrong suite (`design-l2.md:1919`, `InstructionPermissionTests`). §1.4 (`design-l2.md:55`) removes link UI from scope (correct), but no test or source scan pins "no link/URL control"; §11.3 C proves unknown-kind tolerance (good) but is not credited to FR-RIE-024.
- L1 proposed `instruction.foregroundNote` (`design-l1.md:834`); L2's 34-key catalogue drops it, and no L2 section states the foreground-only limitation in UI copy or in its report obligations.
- FR-RIE-021 (taxonomy and scoped cancels) is mapped to `InstructionSurfaceTests` ("FR-RIE-017 … 021", `design-l2.md:1922`) and `AppCoordinatorInstructionTests` (`design-l2.md:1933`) — UI/coordinator suites cannot evidence the full-REPLACE category set or scoped cancels; case M only says `NotificationCategoriesTests` is green.
- FR-RIE-022 (no video in notification attachments) is mapped to store/service/scheduler suites; case H (`design-l2.md:1962`) covers `userInfo` only. Nothing asserts the `attachments` array: no video attachment, the first-photo attachment unchanged, no per-occurrence copy on re-arm.

**Required rework.**

1. Map FR-RIE-024 to real evidence: credit the unknown-kind/no-fake-control cases (case C, `InstructionDisplayStateTests`) and add a source scan that the instruction UI contains no link/URL/YouTube control and no background-playback claim.
2. Restore `instruction.foregroundNote` (en + ne) and render it where L1 intended (editor/cover/report path), or record an explicit decision that the feature report, not the UI, carries the statement — and pin that in a test or a review checklist.
3. Move FR-RIE-021's evidence to `NotificationCategoriesTests` plus a scoped-cancel case (existing alarm/scheduler suite), and FR-RIE-022's to `RoutineNotificationSchedulerTests` with attachment assertions for schedule and re-arm (and the event path).
4. Keep §11.2 truthful: every suite listed must be able to fail the requirement it claims; otherwise the map is not evidence.

### Minor findings (non-blocking; fix while revising)

- **m-1 — `freeFormEvent(id:)` is not a shipping method.** `FreeFormEventService` has `event(withId:)` at `FreeFormEventService.swift:318`; L2 names `freeFormEvent(id:)` (`design-l2.md:260`, `:1032`, `:1259`, `:1462`) and says "there is no second read path". Name the existing method, or state that the design adds a thin wrapper and why that is not a second read path.
- **m-2 — the store's `setInstruction` has a `Bool` error channel.** `EventExtrasStore.setInstruction(…) -> Bool` (`design-l2.md:1002`) is a new interface method; P-11 translates at the service seam to `Result<Void, InstructionWriteError>`, and the store's `Bool` convention is shipping (`saveEntries`/`add`/`remove`). Accept the exception as recorded (OI-1), but label it in the register as deliberate so the explicit-error-type rule is visibly satisfied at the seam, not silently waived.
- **m-3 — the copy catalogue renames L1's proposed key family wholesale** (`.kind.text` → `.kind.note`, `.permission.*` → `.camera.*`/`.microphone.*`, etc.). This is acceptable as L2's concreteness mandate; only the two behaviour-bearing keys in B-1 and M-2 must be restored.
- **m-4 — P-8's citation corrections are accurate.** `RoutineScheduler(` at `AppCoordinator.swift:3571`, `setPhotoFilename` at `EventExtrasStore.swift:110–113`, the routine overlay at `ContentView.swift:65–72`, the payload at `RoutineAlarmScheduler.swift:75–79`, and `LocaleFormatters.shortTime(locale:)` at `ViewCaches.swift:51` were all verified. The pre-existing print is at `RoutineAlarmScheduler.swift:103` (design cites `:101–105`); the window is acceptable.

## Ratification of design-l2's open items

| Item | Disposition |
|---|---|
| OI-1 — `setInstruction` returns `Result<Void, InstructionWriteError>` instead of L1's `Bool` | **Ratified.** Declared error types at the principal seams; the store's `Bool` is translated and recorded. |
| OI-3 — `InstructionCommit` (write + pending media) beside `InstructionWrite` | **Ratified.** The event id does not exist at pick time; the pending-media carrier matches the shipping `pickedPhoto` shape. |
| OI-7 — 10 s ready watchdog vs NFR-RIE-008's 1 s fallback | **Ratified.** The 1 s bound is the failure-detection budget (§8.1); the 10 s watchdog is a platform-stall ceiling, not a fallback delay. Keep both numbers and the distinction in the report. |
| OI-8 — event notifications carry no `had_instruction` | **Ratified.** The event tap opens the detail, where a removed/absent instruction renders `.none`; there is no dead end. |
| OI-2, OI-4, OI-5, OI-6 | Informational; no objection. OI-5's smoke measurement and OI-6's product follow-up are correctly deferred. |
| R-1…R-6 | Mechanical, no user-visible change; accepted as recorded. |
| R-7 | Accepted via OI-3. |

## Requirement traceability

Legend: **covered** = design section plus named test evidence; **fix** = covered, but a finding changes the behaviour or the evidence.

| Requirement | Design evidence | Test evidence | Status |
|---|---|---|---|
| FR-RIE-001 model, one kind | §2.1, §3.2, §4.2 | `InstructionModelTests`, `RoutineSettingsInstructionTests`, `FreeFormEventServiceTests` | **fix B-2** (raw kind) |
| FR-RIE-002 text instruction | §2.1, §4.2 | Model, RoutineSettings, FreeFormEventService | covered (after B-2) |
| FR-RIE-003 image instruction | §2.1, §5.8 | Model, `VisualAidStoreTests` | covered |
| FR-RIE-004 library pick | §2.4, §7.4 | `InstructionCaptureTests`, `InstructionVideoImportTests` | covered |
| FR-RIE-005 record | §2.4, §7.4 | Capture, Permission | covered |
| FR-RIE-006 limits | §8.1 limits/config | Import case A; device smoke | covered |
| FR-RIE-007 caption | §2.1, editor | Model, `InstructionSurfaceTests` | covered |
| FR-RIE-008 one per entry | §4.2, services | RoutineSettings, FreeFormEventService/Form | covered |
| FR-RIE-009 existing surfaces | §2.9, §2.10 | RoutineSettings, FreeFormEventForm | covered |
| FR-RIE-010 plain feedback | §6.2, §10.5 | Surface, Capture, Import | covered |
| FR-RIE-011 store and protection | §5 | VideoStore E, `NoIOInInitTests` | covered |
| FR-RIE-012 filename hygiene | §5.4 | VideoStore D | covered |
| FR-RIE-013 transactional replace | §5.6, §5.7 | VideoStore L | covered |
| FR-RIE-014 delete with owner | §5.8 | VideoStore, FreeFormEventService, RoutineScheduler | covered |
| FR-RIE-015 always fires | §2.14 | FireHandler, NotificationScheduler | covered |
| FR-RIE-016 handlers return false | §2.14 | FireHandler both | covered |
| FR-RIE-017 fired composition | §2.8, §10 | Surface, DisplayState, Playback | covered |
| FR-RIE-018 playback UX | §2.6, §2.7, §10 | Playback controller/adapter, Surface, smoke | covered |
| FR-RIE-019 tap/Open; no background claim | §2.14, §4.11 | FireHandler, Surface | **fix B-1** (owner-deleted notice), **M-2** (foreground statement) |
| FR-RIE-020 playback failure fallback | §6.2, §2.6 | Playback, DisplayState, Surface | covered |
| FR-RIE-021 notification taxonomy | §2.14 baseline; no change | `NotificationCategoriesTests`, scoped-cancel case | **fix M-2** (mapping/case) |
| FR-RIE-022 no video attachment | §2.14, §2.17 | NotificationScheduler | **fix M-2** (attachment assertions) |
| FR-RIE-023 no new machinery | §2.14, §8 | RoutineScheduler, AppCoordinator, medication baseline | covered |
| FR-RIE-024 honest capability surface | §1.4 | none credited | **fix M-2** |
| FR-RIE-025 permissions | §2.5, §10.6 | Permission | **fix M-1** (order), **M-2** (mapping) |
| NFR-RIE-001 accessibility | §10 | Surface O, DesignTokens | covered |
| NFR-RIE-002 localisation | §10.5, §10.6 | `L10nCatalogCoverageTests`, Surface | covered (after B-2 key rename) |
| NFR-RIE-003 no egress | §1.4, §8 | SourceHygiene P | covered |
| NFR-RIE-004 PII-free logs | §3.6, §6.6 | Observability, release gate | covered |
| NFR-RIE-005 at-rest protection | §5.3 | VideoStore E, SourceHygiene | covered |
| NFR-RIE-006 migration, unknown kinds | §4.6 | Model/Entry/Store case C | covered |
| NFR-RIE-007 footprint, zero orphans | §5.7, §8 | VideoStore K, L | covered |
| NFR-RIE-008 responsiveness | §8.1 | Playback I; device smoke §11.5 | covered (OI-7 ratified) |
| NFR-RIE-009 testability and gates | §8, §11 | Playback seam, smoke, build gates | covered |
| NFR-RIE-010 preserved baseline | §11.2, §12 | case M, unchanged suites | covered (after B-1 notice is restored as new behaviour, not a baseline change) |

## Verification record

- **Artifact and run state.** `design-l2` is COMPLETED (2026-10-25T09:14:21Z) with output `specs/design-l2.md`; `review-l2` was PENDING with no outputs before this review. The file was read in full (2,078 lines). No artifact was modified; this report is the only file written.
- **Requirement lock.** Snapshot sha256 matches; 35/35 per-file sha256 match; 25 FR + 10 NFR; 107 acceptance scenarios; no drift.
- **Approved inputs.** design-l1 (1,611 lines) and review-l1 (182 lines) were read in full; the B-2 resolution and L1 tap matrix are quoted above.
- **Source spot-checks (all read in this worktree).**
  - `Services/Storage/EventExtrasStore.swift` — `setPhotoFilename` wholesale rebuild at `:110–113` (P-4 hazard confirmed); `remove` returns the dropped extras; tolerant decode at `:41–45`.
  - `Services/Reminders/RoutineEntry.swift` — `VisualAid`, coding keys, tolerant init; the proposed field is additive.
  - `Services/Reminders/RoutineScheduler.swift` — `removeEntry` `:111–119`, `setVisualAids` `:131–137`, `persistAndReschedule` `:202–213`.
  - `Services/Storage/VisualAidStore.swift` — no-IO init `:82–104`, save/protection `:113–128`, `Void` delete/deleteAll `:150–161`.
  - `Services/Notifications/RoutineVisualAidFireHandler.swift` / `FreeFormEventFireHandler.swift` — always `false` (`:48/:58/:65`, `:62/:70/:77`), photo gates, event detail path `:87–96`.
  - `Services/Notifications/NotificationFacade.swift` — `[.banner, .list, .sound]` at `:90`, handler loop and dispatch.
  - `Services/Reminders/RoutineAlarmScheduler.swift` — protocol `:17–36`, identifier `:58–60`, userInfo `:75–79`, first-photo attachment `:82–87`, scoped cancels `:145–153`, print `:103`.
  - `Services/Events/FreeFormEventService.swift` — `event(withId:)` at `:318`, `save` `:360`, `setPhoto` `:396`, `delete` `:424` (m-1 naming).
  - `App/AppCoordinator.swift` — `modelHousekeepingQueue` `:571`, `RoutineScheduler(` `:3571`, handler wiring `:4591`/`:4626`/`:4638`, service `:12862`, save/delete `:12898`/`:12927`, fired state `:13395`/`:13427`/`:13441`; P-8's anchors are accurate.
  - `App/ContentView.swift` — routine overlay `:65–72`, event detail sheet `:107–110`.
  - `App/VisualAidViews.swift` — `ReminderVisualAidScreen` `:108–291`, `[AX-VIEWPORT]` `:170–174`, `FiredRoutineVisualAids` `:295–300`, overlay `:306–329`.
  - `App/FeedsView.swift` — `FeedMediaPlayerSheet` `:649–715`, the explicit-Play AVKit precedent.
  - `Services/Observability/LogSanitiser.swift` — `allowedKeys` `:56` (`outcome` `:62`, `state` `:63`, `duration_ms` `:64`, `error_code` `:65`, `count` `:182`, `kind` `:402`); `maxErrorCodeLength` 64 and `maxUnbrokenRunLength` 32 with the code-shape regex — the design's ≤19/≤32 claim sits inside the shipped bound; no new key needed.
  - `ios/tools/check-release-log-safety.py` — `FEATURE_ROOTS` `:184`, `FEATURE_EVENT_TYPES` `:339`, rules 3–6 (`feature-console-write`, `feature-content-print`, `feature-unlisted-metadata-key`, `feature-text-interpolated-into-event`), `--self-test` at `:1331`; `ios/build.sh` invokes the gate at `:431`; the design's additions are consistent.
  - Localisation and tokens — `Resources/Localizable.xcstrings` present; `L10n.fmt(_:locale:_:)` at `App/L10n.swift:62`; `DesignTokens.minTapTargetSize` 44 at `App/DesignTokens.swift:127`, `chipHeight` 60 at `:156`; `Info.plist` camera/microphone disclosures at `:113–114`/`:121–122`; `InfoPlist.strings` is new-file work as designed.
  - Test tree — named suites/fakes exist (`NoIOInInitTests`, `MockEncryptedLocalStorage`, `MockObservabilityBus`, `FeatureSourceScan`, the `MedicationEditorSurfaceTests` source-pin idiom); `RoutineAlarmSchedulerTests` does not exist, and L2 correctly creates `RoutineNotificationSchedulerTests`.

## Decision

Decision: NO_GO

Rework required: restore the entry-deleted routine tap notice (B-1); use the locked `"text"` kind and align every payload, fixture and copy key (B-2); specify and test the camera-before-microphone order (M-1); make the FR-RIE-024/021/022 traceability real (M-2); apply the four minors. The architecture, interface register, storage algorithm, observability design and test plan are approved in substance and need no redesign. Once the four items above are corrected, the design is ready to return for review.
