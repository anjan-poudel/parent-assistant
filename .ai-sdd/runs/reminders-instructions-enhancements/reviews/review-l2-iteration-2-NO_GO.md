# Review L2 — iteration 2 (re-review)

| Field | Value |
|---|---|
| Task | `review-l2` |
| Feature | `reminders-instructions-enhancements` |
| Iteration | 2 of 3 |
| Reviewer | Independent reviewer (ai-sdd workflow) |
| Date | 2026-10-25 |
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements` |
| Artifact under review | `specs/design-l2.md` (2,149 lines; rework for review-l2 iteration 1) |
| Prior decision | NO_GO, preserved at `.ai-sdd/runs/reminders-instructions-enhancements/reviews/review-l2-iteration-1-NO_GO.md` |
| Decision | **NO_GO** |

## Summary

The rework is real: the architecture and the engineering core are unchanged, and most iteration-1 findings are fixed with the right anchors rather than merely reworded. B-1 is fully resolved (optional-entry tap sink, `.unavailable` notice, copy key, VoiceOver row, failure-matrix row, test case B.3 and the device-smoke step). M-1 and M-2 are resolved with specific, falsifiable test evidence. m-1 and m-2 are resolved; m-3 is accepted; m-4's anchors were independently re-checked against the sources. B-2's persisted kind is corrected to `text` everywhere the model, fixtures, observability and tests are described.

The revision is nevertheless not ready. One locked MUST is still not designed: FR-RIE-025's acceptance reads the **shipped `Info.plist`** usage descriptions, and the feature constitution lists `ios/ElderlyAssistant/Info.plist` as an integration surface; L1 D10 says the plist is amended in English with the strings files carrying the localised copy. L2 §10.6 adds only the two `InfoPlist.strings` files. The base plist keeps its old text and remains the fallback on system languages other than en/ne; an implementer following L2 fails the locked scenario, and no suite pins the usage descriptions. That is a blocker on its own.

Four further correctness defects must ride the same rework: a stale visible "Note" label (the last residue of B-2), an invalid Swift declaration (`InstructionPayload` as an `enum` with stored properties), an incomplete filename guard (the non-empty condition is omitted, and an empty component can resolve to the owner directory), and a dropped time-line condition that puts NFR-RIE-010's photo-only baseline at risk. Minor evidence and file-map inconsistencies are listed below. The architecture does not need to change; the rework is bounded and local.

**Verification performed.** I read the revised `design-l2.md` in full, the preserved iteration-1 report, `design-l1.md`, `review-l1.md`, `define-requirements.md`, the lock, all 25 FR and 10 NFR files, both constitutions, the workflow, and the load-bearing sources named in the findings. The lock is intact: snapshot `a02b9d4ee24a305ae396cf762304f1a13816f7bc1e81242e9f2adbaf0111bfb9` matches, 35 files, 25 FR + 10 NFR, 107 acceptance scenarios, and all per-file sha256 values match with zero drift. Source anchors were checked independently: `EventExtrasStore.swift:110–113`, `AppCoordinator.swift:3571`, `ContentView.swift:65–72`, `RoutineAlarmScheduler.swift:75–79` (the existing print is at `:103`), `ViewCaches.swift:51`, `FreeFormEventService.swift:318`, `VisualAidViews.swift:283–289`, `VisualAidStore.swift:243–249`, and `Info.plist:113–114`/`:121–122`. No build or test was run, by task instruction. This review wrote only this report; no design, requirement, constitution, workflow or code file was changed.

## Findings

### Iteration-1 findings: resolution status

| ID | Status | Evidence and residual |
|---|---|---|
| B-1 | Resolved | Optional entry sink `onInstructionTap(entryId:entry:firedAt:)` (§2.14.3, §3.6 IF-31/IF-32); the coordinator maps nil to `.unavailable` (§2.15.3–4); `.unavailable` renders the shared screen with `aids: []`, `instruction.reminderUnavailable`, an `EmptyView` footer and Close, claiming no title or time (§2.15.4, §4.11, §10.3); copy row 35, the failure-matrix row, test B.3 and smoke step 7 are present. Photo-only and pre-upgrade no-ops are retained (P-13, case B negatives). No dead tap remains. |
| B-2 | Partially resolved | The persisted kind is fixed: `InstructionKind.text`, raw `"text"`, payloads, fixture F-3, `reportable`, observability and copy key `instruction.kind.text` (§3.4, §4.1, §4.7, §6.4, §10.5 row 5). No `kind.note`, `case note` or raw `"note"` remains. **Residual:** §10.1 line 1827 still says `Kind picker (Note / Photo / Video)` and `Labels are the kind names`, contradicting the catalogue and §1.7's claim that §10.1 changed. See N-2. |
| M-1 | Resolved | §2.4.3 and §2.5.3 specify camera first, microphone second when both are undetermined, short-circuit on denial, and the recorder only after both are granted; §11.3 R records the call order, both denial short-circuits, the already-denied/restricted no-re-prompt rule and camera-unavailable without a microphone request; §11.2 maps it to `InstructionPermissionTests`. |
| M-2 | Resolved | FR-RIE-024 is credited to `InstructionDisplayStateTests` (unknown kind, no fake control) plus an `InstructionSurfaceTests` source scan and the restored `instruction.foregroundNote`; FR-RIE-021 to `NotificationCategoriesTests` plus a `RoutineSchedulerTests` scoped-cancel case and source pin; FR-RIE-022 to `RoutineNotificationSchedulerTests` with schedule, re-arm and event attachment assertions (§11.2, §11.3 Q/S/T). Each claim is now falsifiable by a named suite. |
| m-1 | Resolved | Every service read is named `FreeFormEventService.event(withId:)` (`FreeFormEventService.swift:318`); the existing coordinator wrapper `AppCoordinator.freeFormEvent(id:)` at `:12876` merely delegates, so there is no second read path (§2.13, §3.6, §4.8, §5.9). |
| m-2 | Resolved | `EventExtrasStore.setInstruction -> Bool` is labelled in IF-26 as the deliberate store exception, translated to `InstructionWriteError.persistenceFailed` at the service seam, and recorded in OI-1 (§3.1, §3.5, §13). |
| m-3 | Accepted | The copy-family renames are not behaviour-bearing; the two behaviour-bearing keys `instruction.reminderUnavailable` and `instruction.foregroundNote` are restored as rows 35–36 with en and ne values. |
| m-4 | Verified | `EventExtrasStore.setPhotoFilename` is at `:110–113`; `RoutineScheduler(` at `AppCoordinator.swift:3571`; the routine overlay is `ContentView.swift:65–72` (the design cites 65–73, a harmless range); userInfo is `RoutineAlarmScheduler.swift:75–79` and the existing print is `:103` inside `:101–105`; `LocaleFormatters.shortTime(locale:)` is `ViewCaches.swift:51`; the service read is `FreeFormEventService.swift:318`. P-8 is accurate. |

### N-1 — Blocker: FR-RIE-025's `Info.plist` disclosure is neither designed nor tested

**Anchor.** `design-l2.md` §10.6 lines 1922–1933; §2.0 C05 line 102; §11.2 rows for `InstructionCaptureTests` and `InstructionPermissionTests`; `design-l1.md` D10 lines 840–845 and line 1106; FR-RIE-025 lines 40–45; feature constitution line 53 and Integration Surfaces line 129.

**Problem.** L2 creates only `ios/ElderlyAssistant/Resources/en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings`. It never instructs editing `ios/ElderlyAssistant/Info.plist` `NSCameraUsageDescription` (`:113–114`) or `NSMicrophoneUsageDescription` (`:121–122`), and no suite pins the usage-description text. The component map lists neither the plist edit nor the two strings files.

**Why this is blocking.** FR-RIE-025's acceptance is: "Given the shipped Info.plist When the camera and microphone usage descriptions are read Then both disclose video recording And both state that the recording stays on the device And the existing disclosures are retained." The feature constitution lists `ios/ElderlyAssistant/Info.plist` as an integration surface with the exact keys. L1 D10 says the plist is amended in English and the strings files carry the localised copy; the plist English text remains the fallback. L2's strings-only approach leaves the fallback stale on system languages other than en or ne and does not satisfy the locked scenario as written. L2's own standard is that every requirement names the suite that would fail if the claim became false; FR-RIE-025 is mapped only to permission-order and denial suites, not to a usage-description pin.

**Required fix.** Amend the two plist usage descriptions (retain the medication/appliance, live-translation and voice-command disclosures; add video recording and stays-on-device clauses); list `Info.plist` as a shared C05 file and the two `InfoPlist.strings` resources in §2.0 and §10.6; restore `InstructionLocalisationTests` or map equivalent text pins to an existing extended suite in §11.2 and §11.3; keep §10.6's honest system-language limit.

### N-2 — Major: B-2's visible "Note" label survives at §10.1

**Anchor.** `design-l2.md` line 1827 versus §10.5 row 5 line 1882 (`instruction.kind.text` = "Text") and §1.7 line 80 (which claims §10.1 changed).

**Problem.** The accessibility table names the picker "Note / Photo / Video" and says "Labels are the kind names"; the copy catalogue says Text / Photo / Video. An implementer reading §10.1 can ship the wrong visible label even though the model and catalogue are correct.

**Why this is not stylistic.** It is the last visible residue of the iteration-1 B-2 correction. The locked vocabulary is `text`, and §10.5 is the design's single copy source. A document that says both "Note" and "Text" is internally contradictory on a user-visible string.

**Required fix.** Replace "Note" with "Text" so the picker labels match §10.5 rows 5–7.

### N-3 — Major (mechanical): `InstructionPayload` is declared as an enum with stored properties

**Anchor.** `design-l2.md` lines 507–515 versus `design-l1.md` line 269 (`struct InstructionPayload`).

**Problem.** The declaration is `enum InstructionPayload: Equatable` with stored `let kind`, `text`, `caption`, `filename` and a memberwise `init`. Swift enums cannot have stored instance properties, so the contract register cannot compile as written. The change from L1's struct is not recorded in §1.3.

**Why this matters.** §3.4 is the contract an implementer writes from; the declaration must be valid and the type shape must not require guessing. The intended semantics (named fields, memberwise init, computed `instruction`) are otherwise clear.

**Required fix.** Declare `struct InstructionPayload: Equatable` (matching L1) or restate an equivalent valid shape, and re-check `InstructionWrite`, `InstructionDraft.payload` and the §4.2 truth table for consistency.

### N-4 — Major (safety): `InstructionFilename.isPlain` omits the non-empty condition

**Anchor.** `design-l2.md` line 572; §4.3/§4.7 F-11; §8.3 line 1744; §11.3 D line 2007; shipping guard `VisualAidStore.swift:243–249`.

**Problem.** The contract comment is "bare, no slash, no backslash, dot, dot-dot". The shipping guard it replaces also requires a non-empty name. An empty component passed to `fileURL` resolves to the owner directory; `delete(_:for:)` (IF-8) or `availability(filename:owner:)` could then act on the directory rather than a file. Case D tests traversal shapes but not the empty string.

**Why this is not a wording nit.** The design deliberately makes the store the security boundary (the model does not sanitise). A crafted or corrupt payload with an image/video kind and an empty filename must be refused before URL construction; a delete through an empty component would remove the owner directory and the live bytes in it.

**Required fix.** Define `isPlain` as non-empty AND no slash/backslash AND not the single-dot or double-dot component; apply it before every URL construction in read, write and delete, and in both image loaders; add empty-name, single-dot and double-dot refusal cases to F-11 and the store/loader suites.

### N-5 — Major: the fired-screen time-line condition is dropped

**Anchor.** `design-l2.md` §2.15.4 line 305 ("footer (time + card)"), §4.10 line 1345 ("when the firing has one"), §11.3 B.2 line 2000 and M line 2026; `design-l1.md` D6 line 72; NFR-RIE-010; `VisualAidViews.swift:283–289` (the routine footer is `EmptyView`).

**Problem.** L1 D6 is explicit: the fired time is shown only when an instruction is present or expected. L2's composition bullet says `.reminder` renders a footer with time plus card unconditionally, and §4.10 says the time line is passed "when the firing has one" although every `.reminder` carries `firedAt`. The intended gate is recoverable only from test B.2 (a removed instruction keeps title and time) and M ("timeText default nil") — and the latter is a card default, not a stated overlay rule.

**Why this is not cosmetic.** A photo-only foreground firing presents `.reminder` with `instruction == nil` and `expectsInstruction == false`. If the overlay always passes `shortTime(firedAt)`, the fired screen gains a time line that the shipping screen does not have, violating NFR-RIE-010's preserved baseline. The design contains an internal contradiction, not merely an omission.

**Required fix.** State the gate once in §2.15.4 and §4.10: `timeText` is non-nil only when `instruction?.isPresent == true || expectsInstruction`; `.unavailable` carries no time; and pin the photo-only foreground firing in §11.3 M as showing no time line (the `.none` card and the footer are both `EmptyView`, matching `VisualAidViews.swift:283–289`).

### Minor findings

| ID | Severity | Anchor | Problem | Required fix |
|---|---|---|---|---|
| N-6 | Minor | §8.3 line 1752 | The threat model cites `RoutineNotificationContentTests`, which does not exist in §11.2 or on disk. §2.0 line 118 and §11.2 name the real suite, `RoutineNotificationSchedulerTests`. | Correct the evidence citation. |
| N-7 | Minor | §2.0 lines 98–114; §3.5 line 929; P-14 line 35 | `Services/Instructions/InstructionImageLoading.swift` is declared as C01/used by C08 but is absent from the C01 and C08 file lists; the two `InfoPlist.strings` resources are in no file list. P-14 says "No new top-level file outside C01/C03/C06's described areas", contradicted by new files in C04 (`App/InstructionCapture.swift`), C08 (`App/InstructionViews.swift`), C17 (`Services/Notifications/RoutineNotificationContent.swift`) and the C02/C05/C07 files under `Services/Instructions`. | Add the missing files to the component map and reword P-14 to the real rule ("no new file beyond those tabled in §2"). |
| N-8 | Minor | §1.3 lines 37–49 | §1.3 claims to record every shape change that cannot follow L1 literally, but these are unrecorded: the display state changed from L1's struct with `.missingInstruction`/`.media`/`.unsupportedKind` to an enum with `.none`/`.text`/`.image`/`.video`/`.unsupported`/`.removed`; the permission protocol changed from `@MainActor` synchronous to `async Sendable`; the importer's `discard` is folded into `validate`; the event handler's `instructionPresent` lookup is replaced by a composite `FreeFormEvent.instruction` read; the playback seam's pause/close pair is collapsed to `closed`; and C17 is extracted to a new file. | Add refinement rows or state the mechanical equivalence; no behaviour change is apparent, so this is documentation fidelity, not a redesign. |
| N-9 | Minor | §11.2 lines 1962–1990; §11.3 I line 2018 | FR-RIE-015 ("always fires") is not named in any suite row, although §2.14 and §6.2 design it. The NFR-RIE-009 row lists ready, failed, interrupted, timeout and close but not `finished`; missing-file evidence sits in the availability row. | Name FR-RIE-015 in the handler and scheduler rows; add a `finished` assertion and state that close exercises pause in §11.3 I. |
| N-10 | Minor (editorial) | §11.4 lines 2057 and 2061; §10.5 row 19 | `FakeInstructionVideoRecorder` is listed twice. The `instruction.video.tooLong` copy says "under 3 minutes" while the cap allows exactly 180 s (`exceedsLimit` is strictly greater). | Remove the duplicate row; make the copy and the boundary agree (state the boundary or adjust the copy). |

## Ratification

| Item | Disposition | Basis and conditions |
|---|---|---|
| OI-1 | **Ratified** | The principal seams (`saveRoutineInstruction`, `saveFreeFormEvent`, the `InstructionVideoStore` methods) declare explicit error types. `EventExtrasStore.setInstruction -> Bool` is a narrow, labelled exception (IF-26) that follows the shipping store's existing Bool convention and is translated to `.persistenceFailed` at the service boundary; it never reaches a view. Condition: keep the IF-26 label and the translation test so the exception cannot drift into a second failure channel. |
| OI-3 | **Ratified** | `InstructionCommit` and `InstructionPendingMedia` are necessary because an event has no id before it is created, so a picked photo or recorded video cannot have a store filename at handoff. The shape matches the shipping `pickedPhoto` pattern, and the rule that pending media is dropped unless the write kind matches prevents a text write from smuggling media (§4.2). |
| OI-7 | **Ratified** | NFR-RIE-008's 1 s bound is a failure-detection budget: the preflight is 0.6 s and `AVPlayerItem.status` resolves the named failure cases within it. The 10 s ready watchdog is a platform-stall ceiling with Close still available, not the failure budget. Condition: §8.1 must keep that distinction explicit, and the 10 s must remain a backstop rather than a normal-path wait. |
| OI-8 | **Ratified** | Event notifications carry no `had_instruction`. The event tap already opens the detail, where an absent instruction renders `.none` (EmptyView); there is no dead end to defend. Condition: revisit only if a future flow presents instruction content from the background. |
| OI-2 | Correctly classified, non-blocking | The synchronous AVFoundation accessors are deprecated but not removed; no warnings-as-errors today. The async replacement cannot run inside the system callback, so the trigger is SDK removal and the fallback (copy inside the callback, probe off-main) is stated. |
| OI-4 | Correctly classified, non-blocking | The shared image store is pinned by L1 D3; one instruction image per owner is unambiguous within the owner's directory. A per-instruction layout is a future product+engineering decision. |
| OI-5 | Correctly classified, non-blocking | Chunking is a measurement-driven fix that stays inside the same callback. It should be decided after the 200 MiB device smoke, not now. |
| OI-6 | Correctly classified, non-blocking | L1 specifies plain text only; a Settings deep-link is a new interaction and a product decision. OI-6 is not a silent addition. |
| R-1 through R-7 | **Accepted** | R-1/R-3/R-7 are the typed-seam refinements tied to OI-1/OI-3; R-2 is the optional-entry sink that resolves B-1; R-4 is the anchor correction verified under m-4; R-5 is an honest, non-flaky protection test; R-6 preserves existing `EventExtras` construction. None changes user-visible behaviour or the component set. |

## Requirement traceability

All 25 functional requirements and 10 non-functional requirements were re-derived against the locked files, not against the design's own shorthand.

| Requirement | Design sections | Named evidence | Status |
|---|---|---|---|
| FR-RIE-001 instruction model | §2.1, §3.4, §4.1–4.3 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests` | Covered |
| FR-RIE-002 text instruction | §2.1, §2.8, §4.1 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `EventExtrasStoreTests`; `RoutineStoreTests` | Covered |
| FR-RIE-003 image instruction | §2.1, §2.8, §5.8 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `VisualAidStoreTests` | Covered |
| FR-RIE-004 library pick | §2.4, §3.5, §7.4 | `InstructionCaptureTests` | Covered |
| FR-RIE-005 recording | §2.4, §3.5, §7.4 | `InstructionVideoImportTests`; `InstructionCaptureTests` | Covered |
| FR-RIE-006 limits | §3.4, §5.2, §9.1 | `InstructionModelTests` (duration); `InstructionVideoImportTests` (limits) | Covered |
| FR-RIE-007 caption | §2.1, §3.4, §4.10 | `InstructionModelTests`; `InstructionVideoImportTests`; `InstructionCaptureTests` | Covered |
| FR-RIE-008 lifetime and edits | §4.2, §5.6 | `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-009 existing surfaces | §2.8–2.10 | `RoutineSettingsInstructionTests`; `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-010 plain feedback | §3.3, §6.2, §6.7, §10.7 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-011 storage layout and protection | §4.3, §5.1–5.4 | `InstructionVideoStoreTests`; `NoIOInInitTests` | Covered |
| FR-RIE-012 filename hygiene | §3.4, §4.3, §4.7 F-11, §8.3 | `InstructionVideoStoreTests`; `EventExtrasStoreTests`; `RoutineSchedulerTests` | Covered, guard incomplete (N-4) |
| FR-RIE-013 transactional replace | §5.6 | `InstructionVideoStoreTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-014 delete with owner | §2.11, §2.13.4, §5.5–5.6 | `InstructionVideoStoreTests`; `FreeFormEventServiceTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-015 always fires | §2.14, §2.17, §6.2 | `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; unchanged facade and medication suites | Covered in design; evidence naming nit (N-9) |
| FR-RIE-016 handlers return false | §2.14 | `RoutineVisualAidFireHandlerTests`; `FreeFormEventFireHandlerTests` | Covered |
| FR-RIE-017 composition | §2.15 | `InstructionDisplayStateTests`; `InstructionSurfaceTests`; `FreeFormEventFireHandlerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-018 playback UX | §2.6–2.7, §10.1–10.3 | `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests`; `InstructionSurfaceTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-019 tap and Open | §2.14.2–3, §2.15.3–4, §4.11 | `RoutineVisualAidFireHandlerTests` (three taps); `AppCoordinatorInstructionTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-020 failure fallback | §4.10, §6.2 | `InstructionDisplayStateTests`; `InstructionPlaybackControllerTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-021 notification taxonomy | §2.14, §2.17, §6.4 | `NotificationCategoriesTests`; `RoutineSchedulerTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-022 no notification attachment | §2.17, §5.6, §11.3 T | `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-023 no new machinery | §1.4, §2.15, §6.4 | `RoutineSchedulerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-024 honest capability surface | §2.8.6, §4.10, §10.5 row 36 | `InstructionDisplayStateTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-025 permissions and disclosure | §2.4.3, §2.5.3, §3.5, §10.6 | `InstructionCaptureTests`; `InstructionPermissionTests` | **Gap:** request order covered; the shipped plist amendment and its text pin are missing (N-1) |
| NFR-RIE-001 accessibility | §10.1–10.4 | `InstructionSurfaceTests`; `DesignTokensTests` | Covered |
| NFR-RIE-002 localisation | §10.5–10.7 | `L10nCatalogCoverageTests`; `InstructionSurfaceTests` | Covered |
| NFR-RIE-003 privacy and no egress | §8.3–8.4 | `InstructionSourceHygieneTests` | Covered |
| NFR-RIE-004 PII-free logs | §6.4–6.6 | `InstructionObservabilityTests`; `RoutineNotificationSchedulerTests` | Covered |
| NFR-RIE-005 at-rest protection | §5.3 | `InstructionVideoStoreTests`; `InstructionSourceHygieneTests` | Covered |
| NFR-RIE-006 migration and tolerance | §4.4–4.7 | `InstructionModelTests`; `RoutineEntryTests`; `RoutineStoreTests`; `EventExtrasStoreTests` | Covered |
| NFR-RIE-007 footprint and orphans | §5.5–5.6 | `InstructionVideoStoreTests`; `RoutineSchedulerTests` | Covered |
| NFR-RIE-008 responsiveness | §8.1–8.2, §9.1 | `InstructionPlaybackControllerTests`; `AppCoordinatorInstructionTests` | Covered; OI-7 ratified |
| NFR-RIE-009 testability and gate | §3.5, §11.2 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests` | Covered; outcome naming nit (N-9) |
| NFR-RIE-010 preserved baseline | §4.10, §11.3 M, §11.2 unchanged suites | `InstructionSurfaceTests`; `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; `NotificationCategoriesTests`; medication suites | Covered subject to N-5 |

## Scope statement

No scope creep was found. The design deliberately keeps `url` decode-only and inert and ships no link, YouTube or URL control; no transcode, compression, trimming, cloud upload or thumbnails; no instruction notification category, action or attachment (`had_instruction` is a Boolean in `userInfo`); no medication-path change; no multi-instruction; no photo-library access (the picker is out of process and the recorder uses camera and microphone only); no Settings deep-link (OI-6); no audio transcription or captioning; and no `SpokenTime`. §1.4 and the source-hygiene tests (`InstructionSourceHygieneTests`, §11.3 P and Q) enforce that boundary. The two new `InfoPlist.strings` resources are localisation files required by L1 D10, not new scope; the missing base-plist amendment is a compliance gap (N-1), not scope creep.

## Decision

Decision: NO_GO

**Justification.** The revision resolves B-1, M-1, M-2, m-1 and m-2, accepts m-3, and verifies m-4. B-2 is only partially closed, and N-1 leaves a locked MUST undesigned and untested: FR-RIE-025's shipped `Info.plist` disclosure, which the feature constitution lists as an integration surface and L1 D10 makes the English fallback, is replaced by strings files alone. N-3 (invalid Swift declaration), N-4 (filename boundary and empty-component safety) and N-5 (the NFR-RIE-010 time-line gate) are correctness and safety defects, not stylistic preferences. The architecture, component set and scope boundary are sound, so the rework is bounded and local; no redesign is required.

**Blocking IDs:** N-1 (locked requirement), N-2 (residual B-2), N-3 (declaration), N-4 (storage safety), N-5 (baseline and L1 D6).

**Bounded rework scope.**

1. Add the FR-RIE-025 base-plist amendment and its test evidence, and list the plist and the two `InfoPlist.strings` resources in the component map (N-1).
2. Replace the stale "Note" picker label with "Text" (N-2).
3. Correct `InstructionPayload` to a valid declaration, matching L1's struct or an equivalent (N-3).
4. Add the non-empty condition to `InstructionFilename.isPlain` and the empty-name, single-dot and double-dot refusal cases (N-4).
5. State the fired-screen time-line gate and pin the photo-only foreground firing (N-5).
6. Fix N-6 through N-10 in the same pass: suite citation, component-map and P-14 wording, recorded L1 refinements, FR-RIE-015/NFR-RIE-009 evidence naming, duplicate fake row and the 3-minute copy boundary.

**Conditions for a GO at iteration 3.** Every blocking finding is closed with an anchor and a named test; the traceability table reflects the corrected mapping; no new contradiction is introduced; the scope boundary is unchanged; and no new open item lacks a shipped default. Iteration 2 of 3 is complete; one rework iteration remains. This report is the only file written by this review; the preserved iteration-1 report was not edited.
