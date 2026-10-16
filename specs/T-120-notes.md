# T-120 — Settings: Spotify section (link / unlink / privacy disclosure)

- Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
- Branch: `feat/spotify-music-integration`, HEAD `f55e74f` ("W5: T-119, T-121")
- Date: 2026-10-07
- Task: `specs/plan-tasks/tasks/TG-22-plugin-wiring-settings-and-localisation/T-120-settings-surface.md` (binding, 4 Gherkin scenarios)
- Design anchors, verified BY CONTENT before implementing: design-l2 §17 (leaf spec: destination, view order, leaf state machine, accessibility, test seams) and §31 (copy inventory, T-117-shipped, M-2-amended privacy row). Both read from the file, not assumed from the table of contents.
- No commit was made (instructed). `ios/seniOS.xcodeproj/project.pbxproj` shows as modified because xcodegen regenerated it during the gate build — it was not hand-edited.

## What was built

1. **`ios/ElderlyAssistant/App/SettingsTabs.swift`** — the destination and its routing.
2. **`ios/ElderlyAssistant/App/SettingsView.swift`** — `SpotifySettingsView`, its leaf state machine (`SpotifySettingsLeafState`) and action enum (`SpotifySettingsAction`).
3. **`ios/ElderlyAssistantTests/App/SpotifySettingsSurfaceTests.swift`** (NEW, 14 tests) — state mapping, end-to-end unlink wipe, both-locale copy, accessibility/substance scans, wiring scans.
4. **`ios/ElderlyAssistantTests/App/SettingsTabMappingTests.swift`** — hidden-sheet pin updated (6 → 7) and the manual-names-the-sheet pin generalised from YouTube-alone to every hidden row.
5. **`ios/ElderlyAssistant/Resources/ManualText/userManual.json`** — the technical-settings paragraph now also names Spotify, in both languages (the generalised pin above is what requires this; the household reads the manual, not the enum).
6. **F-7 record** — kept-copy adjudication recorded below and in `specs/T-117-notes.md` (see "F-7" and "Deviations" — that file had to be created; provenance note there).

No new localisation keys were added or changed: T-117 shipped the 20 `spotifySettings.*` keys; T-120 only consumes them. No credential field of any kind (ADR-SP-01). No new log lines (NFR-SP-002).

## Edit sites (file:line, final)

### SettingsTabs.swift
| line | change |
|---|---|
| :11 | file-header enumeration of hidden-sheet rows — Spotify added |
| :84 | `SettingsDestination` doc comment: visible rows "the last seven…" (count fix: 6 → 7) |
| :105 | `case geminiAI, voiceEngine, webSearch, intentLog, toolLog, youtube, spotify` (rawValue `"spotify"`) |
| :131 | `case .spotify: return "spotifySettings.title"` |
| :169 | `case .spotify: return "music.note"` |
| :185 | `tab` doc comment: the hidden sheet's seven |
| :194 | `hiddenSheetRows` doc comment — Spotify named with [SPOTIFY T-120] marker |
| :199–202 | `hiddenSheetRows` = `[.geminiAI, .voiceEngine, .webSearch, .youtube, .spotify, .intentLog, .toolLog]` |
| :435 | `SettingsDestinationView`: `case .spotify: SpotifySettingsView(session: coordinator.spotifyAccountSession)` |
| :454 | technical-stack doc comment — Spotify account link added |
| :478 | `HiddenSettingsSheet` comment: "the row after the destination" |

### SettingsView.swift
| line | change |
|---|---|
| :870 | `// MARK: - Spotify (spotify-music-integration, 2026-10-07)` — block inserted before `GeminiCostCard` |
| :887 | `struct SpotifySettingsView: View` (`LeafScreen(titleKey: "spotifySettings.title")`) |
| :909 | `Text("spotifySettings.privacy")` — privacy disclosure card |
| :923 | `Text("spotifySettings.rolloutNote")` — rollout note (unconditional; see D3) |
| :930 | `.confirmationDialog("spotifySettings.removeConfirm", isPresented: $confirmingUnlink)` with destructive `Button("spotifySettings.unlink")` → `session.unlink()` and cancel `Button("common.back", role: .cancel)` |
| :960 | status text `.accessibilityIdentifier("settings.spotify.status")`, `.accessibilityElement(children: .combine)` |
| :999 | action button `.accessibilityIdentifier("settings.spotify.action")`, `.accessibilityLabel(Text(LocalizedStringKey(leafState.actionKey)))`, `.frame(minHeight: DesignTokens.minTapTargetSize)` |
| :1007 | `enum SpotifySettingsLeafState: Equatable` — the total mapping + `statusKey`/`action`/`actionEnabled`/`actionKey`/`statusIcon`/`tone` |
| :1091 | `enum SpotifySettingsAction: Equatable { case link, unlink }` |

### Tests
| file:line | change |
|---|---|
| `SettingsTabMappingTests.swift` :93–101 | hidden-sheet pin now `[… .youtube, .spotify, .intentLog, .toolLog]` (visible count pin 21 unchanged, partition test unchanged and still passing) |
| `SettingsTabMappingTests.swift` :342 | `testTheManualNamesYouTubeWhereItNowLives` replaced by `testTheManualNamesEveryHiddenSheetRowWhereItLives` — loops `Destination.hiddenSheetRows`, both locales |
| `SpotifySettingsSurfaceTests.swift` :62…:382 | 14 new tests (list below) |

### Manual
| file:line | change |
|---|---|
| `userManual.json` :447 (en) | technical-settings paragraph now contains "…Spotify (connect a family Spotify account — the service is still being tested, so only approved accounts can connect)…" |
| `userManual.json` :478 (ne) | "…स्पोटिफाइ (घरका लागि स्पोटिफाइ खाता जोड्ने — सेवा अझै परीक्षणमा छ, अहिले स्वीकृत खाताले मात्र जोड्न सकिन्छ)…" |

JSON re-validated by parser after the edit; both clauses present.

## Decisions

### D1 — State mapping (session status → leaf state) is total and non-optimistic

| `SpotifyAccountSession.Status` | leaf state | status line key | action | enabled | icon | tone |
|---|---|---|---|---|---|---|
| `.notLinked` | `.notLinked` | `spotifySettings.status.notLinked` ("Not connected") | `spotifySettings.link` | yes | `music.note` | neutral |
| `.linking` | `.linking` | `spotifySettings.status.notLinked` (unchanged line) | `spotifySettings.link` | **no** | `ellipsis.circle` | neutral |
| `.linked(.premium)` | `.linkedPremium` | `spotifySettings.status.linked` ("Connected (Premium)") | `spotifySettings.unlink` | yes | `checkmark.circle.fill` | connected |
| `.linked(.free)` / `.linked(.unknown)` | `.linkedFree` | `spotifySettings.status.freeTier` | `spotifySettings.unlink` | yes | `checkmark.circle.fill` | connected |
| `.linkFailed(_)` | `.linkFailed` | `spotifySettings.status.linkFailed` | `spotifySettings.link` | yes | `arrow.clockwise` | **neutral** |

*(W6-review N-1 correction, 2026-10-07: the icon column above is the shipped `SpotifySettingsLeafState.statusIcon` — `SettingsView.swift:1065-1072`; the first draft of this table mis-stated three rows. Notes-accuracy fix only.)*

- `.linked(.unknown)` maps to **freeTier**, not premium — design-l2 §17 / L2-D14: never optimistically claim Premium when the product tier is unknown.
- `.linking` deliberately keeps the notLinked status LINE while the action is visible-but-disabled: an outcome is only announced when the session actually has one (no early "connecting…" copy exists in the shipped catalog, and inventing one is not permitted). Recorded because scenario 3's "no unshipped copy" rule and this choice interact.
- `.linkFailed(_)` maps to one leaf state for every `SpotifyAuthError` — the shipped copy is error-agnostic by design (see W2-D3 record).

### D2 — View takes the session only (deviation from the brief's phrasing)

The brief said the view "reads `coordinator.spotifyAccountSession` / `coordinator.spotifyCredentialStore`". `SpotifySettingsView` takes **`@ObservedObject var session: SpotifyAccountSession`** only, wired at SettingsTabs.swift :435. Rationale: design-l2 §17 defines the leaf state machine on the session; the store's `record` carries nothing the session does not already surface as `status`; per L2-R2 there is exactly one lazy session over one store, so a second injected source could only disagree, never add. `testTheSectionUsesTheCoordinatorsOneSessionAndBuildsNoSecondAccount` pins that the surface is built from the coordinator's session and that `SettingsTabs.swift` constructs no `SpotifyAccountSession` of its own.

### D3 — Rollout note: rendered unconditionally, documented

`spotifySettings.rolloutNote` ("Spotify's service is still being tested; for now only approved accounts can connect." / "स्पोटिफाइ सेवा अझै परीक्षणमा छ; अहिले स्वीकृत खाताले मात्र जोड्न सकिन्छ।") is rendered **unconditionally**, with a code comment citing OD-S2(c). Rationale: "development mode / approved accounts only" is a fact about the Spotify console, not a client-observable condition — there is no client-side flag that distinguishes approved from unapproved accounts, so a gated render would be a placebo toggle and a dishonest gate. The note is honest in all four states; when OD-S2 closes, the copy is a §31 catalog change, not a render change.

### D4 — W2-D3 verification: link-failed/retry reads as routine maintenance

Checked against the **shipped** copy rather than rewriting it (task: "verify, record; do not rewrite"):

- `spotifySettings.status.linkFailed` en "Couldn't connect. Please try again." / ne "जोड्न सकिएन। फेरि प्रयास गर्नुहोस्।"
- Findings: no fault vocabulary (no "error", "failed to authenticate", "token", no blame framing); the second sentence is a plain retry instruction; the retry affordance is the same Connect action (`spotifySettings.link`), same tone (`.neutral`), and a refresh glyph (`arrow.clockwise`) rather than an alarm glyph or red. A six-month refresh-token expiry — the documented routine maintenance case — lands in exactly this state and reads as "try again", not as a fault.
- Verdict: **shipped copy supports the routine-maintenance framing; kept as shipped.** No change requested; any wording change would be owner-sign-off §31 catalog territory.

### D5 — Privacy disclosure consumes the shipped (M-2-amended) catalog key

`spotifySettings.privacy` renders the M-2-amended sentence now in `Localizable.xcstrings` ("What you ask for — including play commands — is sent to Spotify to find music and control playback; no other app data is sent."). Note for the record: the §31 copy table as it sits on disk still shows the pre-amendment wording; the shipped catalog (pinned by T-117 in `SpotifyLocalizationTests`) is the source of truth the surface consumes. Recorded, not rewritten — the §31 table is design-doc territory outside this task.

### D6 — Gherkin "account identity"

Scenario 1's phrase "account identity" is satisfied by the product-tier status line (per §17): the ADR-SP-08 session record carries no account identifier (no e-mail/name field exists), and the catalog ships no copy for one. Rendering the tier line is the design's intent; adding an identity string would mean a new record field + new copy, both out of scope. Recorded.

### D7 — Unlink failure behaviour

If the store wipe fails, `SpotifyCredentialStore.unlink()` keeps the record (its own guarantee, pinned in `AppCoordinatorSpotifyWiringTests`), so the session stays `linked` and the surface shows the linked state again — no bespoke "unlink failed" copy is invented. Covered by the store/session tests, not re-tested at the surface level.

### D8 — Manual paragraph generalisation

The manual's technical-settings paragraph enumerates the hidden sheet's rows, so adding `.spotify` to `hiddenSheetRows` without a manual edit would have left the household hunting for a screen the manual still doesn't mention. Both languages updated; the YouTube-only pin was generalised (`testTheManualNamesEveryHiddenSheetRowWhereItLives`) so the next move cannot drift either. Content wording stays in the shipped manual's voice ("the service is still being tested…").

### D9 — Accessibility (NFR-SP-010) record

Implemented: every string is a shipped, localised key (no string literals); the status is text-first with the glyph `.accessibilityHidden(true)` and the status row `.accessibilityElement(children: .combine)` + identifier `settings.spotify.status`; the action button carries a worded localised `.accessibilityLabel` (`leafState.actionKey` — "Connect Spotify"/"Remove Spotify", never icon-only) and identifier `settings.spotify.action`; the button honours `DesignTokens.minTapTargetSize` (44 pt) via `.frame(minHeight:)`; state is conveyed by words, not colour (tone only tints the card).

Unit-testable and tested: label keys resolve in both locales; the tap-target constant is the project one; the glyph is hidden and the text is not; identifiers present. **Not** unit-testable in this suite (honest limitation): rendered VoiceOver traversal order, dynamic-type layout, and truncation — those remain on the device checklist (DV-5).

### D10 — F-7 adjudication: keep `removeConfirm` copy

Default action per the brief: **keep the copy**, record the deviation both here and in `specs/T-117-notes.md`. Rendered: `spotifySettings.removeConfirm` ("Remove the Spotify connection? Music will use YouTube only." / "स्पोटिफाइ जडान हटाउने हो? संगीत युट्युबबाट मात्र बज्नेछ।"), destructive confirm `spotifySettings.unlink` ("Remove Spotify"), cancel = `common.back`. Operator review-l2's F-7 ruling is "No — copy option" (i.e. the sentence stays as the §31 choice); matrix row 8 can still open the `spotify:search:` hand-off when YouTube cannot serve, so "YouTube only" is a shortcut summary, not a promise the pipeline cannot keep. No catalog copy was changed. See `specs/T-117-notes.md` for the F-7 entry on the catalog side.

## Tests

New: `ios/ElderlyAssistantTests/App/SpotifySettingsSurfaceTests.swift` — 14 tests, all green:

1. :62 `testScenario1ACompletedLinkMovesTheSurfaceToTheLinkedState` — drives the REAL `SpotifyAccountSession` through the scripted consent seam (asserts the authorize seam ran), premium → `linkedPremium` + remove action.
2. :89 `testScenario1AnAbandonedFlowShowsTheLinkFailedStateWithTheRetryAffordance` — cancelled flow → `linkFailed`, retry glyph, Connect action enabled.
3. :107 `testScenario1AFailedFlowShowsTheSameLinkFailedState` — hard error → same leaf (error-agnostic copy).
4. :120 `testTheFourCaregiverVisibleStatesMapToTheShippedCopyAndActions` — all four caregiver-visible states × copy key + action + enabled + identifier.
5. :157 `testLinkingInFlightDisablesTheOnlyActionWithoutAnnouncingAnOutcome` — `.linking` keeps the notLinked line, action disabled.
6. :185 `testScenario2UnlinkConfirmsThenWipesTheStoreAndReturnsToNotLinked` — END TO END against the real store (`SpotifyInMemoryStorage`): wipe observed on storage (`record == nil`, storage cleared), events emitted with empty metadata (no PII), state back to notLinked. (Bypasses the dialog's tap, which is view-level; the dialog's existence/copy is pinned in #7.)
7. :223 `testScenario2TheConfirmationDialogIsTheShippedCopyAndCallsTheWipe` — source scan: dialog key, destructive button renders `spotifySettings.unlink` and calls `session.unlink()`, cancel is `common.back`.
8. :242 `testScenario3EverySectionStringResolvesInBothLanguages` — all four status keys + link/unlink/privacy/rolloutNote/removeConfirm/title resolve non-identically in en-US AND ne-NP (catalog, not source).
9. :273 `testScenario3TheDisclosureAndRolloutNoteAreRenderedAndHonest` — privacy + rolloutNote are (a) rendered by the view and (b) resolve in both locales; no credential vocabulary anywhere.
10. :302 `testScenario4EveryActionCarriesAWordedLocalisedLabel` — action labels are keys, not symbols; resolve in both locales.
11. :324 `testScenario4TheActionIsWordedAndMeetsTheProjectTapTarget` — `DesignTokens.minTapTargetSize` frame + worded label on the button.
12. :344 `testScenario4TheStatusIsTextFirstAndTheGlyphIsDecorative` — glyph `.accessibilityHidden(true)`, status text visible and labelled.
13. :363 `testTheSectionHoldsNoCredentialFieldAndNoLogSurface` — ADR-SP-01 + NFR-SP-002 scan: no `SecureField`/token/credential field, no `print`/`os_log`/`Logger` in the section.
14. :382 `testTheSectionUsesTheCoordinatorsOneSessionAndBuildsNoSecondAccount` — routing scan: `case .spotify: SpotifySettingsView(session: coordinator.spotifyAccountSession)`; zero `SpotifyAccountSession(` constructions in SettingsTabs.swift (L2-R2).

Updated pins: `SettingsTabMappingTests` :93–101 (hidden sheet 7, `.spotify` after `.youtube`; visible count 21 unchanged; visible/hidden partition still exact) and :342 (manual names every hidden row, en + ne).

## Gate

Command (serialized via `/tmp/spotify-lockrun.sh`):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifySettingsSurfaceTests SettingsTabMappingTests CalendarShareSettingsSeamTests \
  AppCoordinatorSpotifyWiringTests L10nCatalogCoverageTests SpotifyLocalizationTests
```

Result: **GREEN** — "Executed 66 tests, with 0 failures"; `SpotifySettingsSurfaceTests` 14/14; all six classes green in the one run; "=== Scoped unit run passed (baseline not advanced) ==="; exit 0.
Log: `/tmp/w6-gate.log`. xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.07_02-31-51-+1100.xcresult`.

## Deviations and limitations

1. **Session-only injection** (D2) — deviation from the brief's literal "reads both" phrasing; rationale above.
2. **`specs/T-117-notes.md` did not exist** anywhere in the repo or git history (T-117 shipped in W1, commit `a198830`, with its evidence in `SpotifyLocalizationTests.swift` and `specs/implement-review-w1.md`). The brief said "append"; with no file to append to, it was **created** as a clearly-marked F-7 record for T-117, with its provenance stated in the file. Recorded here so the deviation is visible.
3. **Manual edit not literally enumerated in the brief** but required by the shipped `SettingsTabMappingTests` manual pins; both languages updated, pin generalised.
4. **§31 privacy table on disk is stale** vs the shipped amended catalog (D5) — recorded, not rewritten (design doc out of scope).
5. **`.linking` renders the notLinked line** (D1) — a genuine choice under the "no unshipped copy" constraint.
6. **Rendered-output testing limitation** (D9): VoiceOver traversal/dynamic type/truncation at render time are not covered by the unit suite; source scans + model/exercise tests are the unit-level evidence, DV-5 is the device gate.
7. **`project.pbxproj` modified in the working tree** — xcodegen regeneration during the gate build (new test-file reference); never hand-edited.
8. No commit/push, per instruction.
