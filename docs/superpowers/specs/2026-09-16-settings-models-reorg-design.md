# Design: Per-language model persistence, best/ANE defaults, and Settings reorganization

**Date:** 2026-09-16
**Status:** Approved (brainstorming session; user decisions recorded below)
**Scope:** Three ordered PRs from one worktree (`worktree-settings-models`):
1. Per-language STT/brain model persistence + defaults → best/latest ANE.
2. Settings reorganization: top tabs, hidden advanced menu under long-press of the Settings title.
3. STT fallback auto-restore (fresh install must not run bundled medium on CPU).

## 1. User decisions

1. **Layout:** top tabs — pill-style, ≥44pt targets, swipeable — replacing the single long scroll.
2. **Hidden set:** long-press the Settings title reveals Gemini/cloud AI, voice engine stack, web search, intent log, tool log, hidden AI models. (AI + dev tools scope; content config stays visible.) Amended 2026-09-17: the YouTube key row joined the set — see §3 amendment.
3. **Tab title:** the content tab is named **Tools** (not "Apps").
4. **Defaults rule:** the default model is always the best (latest) and, where the catalog has one, the ANE-accelerated build.
5. **Brain default:** gate-passing Qwen 4B = `intentQwen4BSlotCanon`.

## 2. PR 1 — Per-language persistence + defaults

### Problem (verified)
`syncModelPreferencesToLanguage` (`AppCoordinator.swift:140`) overwrites the single stored STT/brain preference with the new language's default. A ne→en→ne round trip therefore flattens the household's explicit pick to the default. TTS already fixed this shape with `ResponseVoiceSelection.rememberedVoices()`; STT and brain have no memory.

### Changes
1. New `ModelPreferenceMemory` (UserDefaults — prefs, not secrets, house rule): `rememberedSTT: [lang: ModelID]`, `rememberedBrain: [lang: ModelID]`. Written ONLY by the Settings pickers (a `remember` call next to the preference write); never written by the automatic language switch.
2. `LanguageModelResolver.resolvedPreference` gains `remembered: [String: ModelID] = [:]`: current incompatible → remembered pick for the new language (when it still resolves in the catalog and is language-compatible) → per-kind default → current unchanged. Mirror of the voice resolver's remembered step.
3. `syncModelPreferencesToLanguage` passes the maps. `nil` ("Automatic") untouched, as before.
4. Defaults:
   - `ModelCatalog.languageDefaultPicks[.whisperBase]["ne"]` → `whisperKitMediumV6` (latest v6 ANE). `"en"` stays `whisperBaseEn` — verified: every WhisperKit catalog entry is `["ne"]`-tagged; no English ANE model exists.
   - `availableSTTEntries` reordered: `whisperKitMediumV6` first (picker order + curated fallback).
   - `AppCoordinator.defaultBrainModelID` → `ModelCatalog.intentQwen4BSlotCanon` (currently stale `intentQwen4BS43`). The per-language map already names slot-canon.
5. Tests: `LanguageModelResolverTests` (remembered round-trip matrix, invalid remembered ignored, defaults pins), `ModelCatalogLanguageTests` (new default pins + curated order), picker remember-seam tests.

## 3. PR 2 — Settings reorganization

### Tabs (final, decision 3 applied)

| Tab | Contains (existing sections, moved not deleted) |
|---|---|
| **Voice** | Wake word, Talk & listen, TTS voices |
| **Family** | Family & friends, caregiver notifications, calling apps |
| **Reminders** | Medications, daily routines, alarms & timers, events, calendar, calendar sharing |
| **Tools** | Quick apps, news feeds, manuals, saved places (YouTube moved out 2026-09-17 — see amendment) |
| **System** | Appearance, language, privacy |

- Pill tab bar under the Settings title; `DesignTokens.minTapTargetSize` (≥44pt), swipe + tap, selected-tab accent per house tokens. All rows keep their existing leaf screens and `navigationDestination`s.
- **Long-press the Settings title** (e.g., 0.8s, with an a11y alternative — a small ellipsis affordance that appears after first use) → modal sheet: Gemini/cloud AI, voice engine stack, web search, intent log, tool log, hidden AI models. The existing `showHiddenAIModels` toggle state moves into this sheet.
- Existing 22-case `SettingsSection` enum collapses to the 5 tabs (the hidden sheet reuses the removed cases). Voice-first: every tab and row remains reachable by accessibility labels; no row loses its L10n key (en+ne for new tab titles + sheet title + long-press hint).
- Tests: tab mapping table test (every section exactly once), hidden-sheet contents test, long-press gesture present test (view-level where feasible; mapping logic pinned as a pure table).

### Amendment (2026-09-17, menu-deepening pass)

The first pass left one classification inconsistent: three rows are the *same screen* — an
optional cloud-provider credential (a `SecureField` for an API key, a quota note, a privacy
note) that the household is never asked to handle — and two of them (`Web search`, `Gemini
AI`) were in the hidden sheet while `YouTube` sat on the Tools tab. YouTube moved into the
hidden sheet, next to its peers. Nothing else in the tab table changed; the visible-row
count is 19 and the hidden sheet carries six rows plus the model screen. The manual's
Settings tour (`docs/user-manual.md` §4k, and the bundled `ManualText/userManual.json`) was
brought level with the table in the same pass — it was still missing the Daily routine and
Events rows — and both are now pinned by `SettingsTabMappingTests`.

## 4. PR 3 — STT fallback auto-restore (root cause of 2026-09-16 device bug)

Console-confirmed on Anzaan: app update → fresh container → WhisperKit ANE artifact gone → `OnDeviceSTTSelection` falls to whisper.cpp with the bundled medium (`whisper-medium-ne-q5_1`) → ~1.2 GB cold-load spike → SIGKILL (first attempt) / ~2-min CPU transcription hang (subsequent). VAD/audio verified healthy.

### Changes
1. **Auto-restore:** when the user's engine stack is on-device and the WhisperKit artifact is missing (`isAvailable == false`), kick the standard `ModelDownloadService` download of `whisperKitNepaliMedium` (the `whisperKitMediumV6` pick follows PR 1's default) on first voice readiness — no Settings trip required. Honest status while downloading (reuse the existing download-progress row pattern).
2. **CPU fallback safety net:** whisper.cpp must never run medium on a fresh install — when only whisper.cpp is available, resolve to the smallest available local model (add a bundled small `whisper-small` fine-tune `whisperFinetunedNepaliQ8` as bundled resource, or prefer an already-downloaded small over the bundled medium); medium stays reachable only as an explicit pick.
3. Tests: `OnDeviceSTTSelection` + auto-restore decision-table tests (artifact missing → download triggered; download in flight → no re-kick; explicit user pick → never overridden), model-resolution tests for the CPU fallback order.

## 5. Execution

- One worktree (`worktree-settings-models`), three PRs in order (1 → merge → 2 → merge → 3), each with targeted `-only-testing` verification on the dedicated simulator before merge (per memory: scoped runs are the honest gate; the full bundle has a known pre-existing failure baseline).
- `./build.sh generate` after file changes; release log-safety guard runs with every gate.
- Main checkout integrates via PR merges and fast-forwards only.
