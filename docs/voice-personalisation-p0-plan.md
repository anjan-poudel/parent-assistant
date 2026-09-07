# Voice Personalisation P0 — Implementation Plan

Date: 2026-09-08 · Research basis: `docs/voice-personalisation-research.md` + `docs/research-sections/*`
Branch: `worktree-voice-personalisation-p0`

## Scope

The four P0 slices from the research roadmap — no constitution change, no owner
decisions required:

| Slice | Content | Wave |
|---|---|---|
| A — Wake-word migration | Porcupine → sherpa-onnx KWS behind existing `WakeWordEngine` protocol; model fetch + ModelCatalog entry | 1 |
| C — Voice Processing I/O | Switchable audio-session preset (A/B gate), metrics events | 1 |
| B — Voice picker | chitwan-medium + google-medium 18-speaker selection in Settings; SherpaTTSEngine speaker/voice param | 2 |
| D — Dialect ID + biasing | WhisperKit encoder embedding → kNN dialect classifier; `DecodingOptions` prompt-token biasing | 2 |

Out of scope (P1/P2, gated on owner decisions): enrollment/verification/liveness,
consent-gated training pipeline, DeepFilterNet3 NS, cloning.

## Execution model

Parallel subagents, disjoint file ownership, all inside this worktree. Agents code
against the pinned seams below; no builds, no commits; write new files only unless the
table assigns an existing file. Integration + verification in the worktree
(`xcodegen generate` + `xcodebuild test` with model binaries copied in), then merge.

## Pinned seams

- `WakeWordEngine` (Services/Voice/WakeWordEngine.swift) — protocol unchanged:
  `start() throws`, `stop()`, feed API per current protocol. Slice A adds a
  `SherpaKWSWakeWordEngine` + selection in `WakeWordEngineSelection.make` +
  `WakeWordConfig` entry + ModelCatalog model entry + `tools/fetch-*` script for the
  sherpa KWS model. Porcupine path stays until the sherpa engine proves out (selection
  order: sherpa if model present, else existing behavior).
- `AudioSessionManager.activate` — Slice C adds a switchable preset
  (`voiceProcessingEnabled: Bool`, default OFF, persisted like other toggles) that
  applies `setVoiceProcessingEnabled(true)` + the appropriate mode when ON; emits
  sanitised observability events (session_preset_changed) and exposes the state for an
  A/B metric event; `.measurement` behavior untouched when OFF.
- `SherpaTTSEngine`/`PiperVoiceSpeaker` — Slice B adds voice/speaker selection
  parameters (model path + speaker id) plumbed from a persisted picker setting;
  SettingsView gains a small voices section (44pt targets, previews, confirm-before-
  apply); ModelCatalog gains chitwan-medium entry (verified live at
  sherpa tts-models release); fetch script extended.
- Dialect ID — Slice D adds `DialectIdentifier` (new file) consuming WhisperKit encoder
  embedding → kNN/centroids over a tiny bundled centroid table (start with 2-3
  clusters + default); wires `DecodingOptions` prompt tokens in
  `WhisperKitSpeechRecognizer` config path; honest <60%-confidence → default pack
  behavior (no pack switching yet — packs are server work; the seam + label are the
  deliverable).

## File ownership

| Agent | Owns |
|---|---|
| A | NEW `Services/Voice/SherpaKWSWakeWordEngine.swift`; EDITS `WakeWordConfig.swift`, `WakeWordEngineSelection` region of `WakeWordEngine.swift`, `Services/ModelStore/ModelCatalog.swift`, NEW `tools/fetch-kws-model.sh`; NEW tests `SherpaKWSWakeWordEngineTests.swift` |
| C | EDITS `Services/Voice/AudioSessionManager.swift` (preset + toggle), `App/AppCoordinator.swift` (composition + toggle plumbing only, minimal); NEW `AudioSessionPresetTests.swift` |
| B | EDITS `Services/Voice/Speaker.swift` (SherpaTTSEngine/PiperVoiceSpeaker selection), `App/SettingsView.swift` (voices section), `Services/ModelStore/ModelCatalog.swift` (chitwan entry — WAIT for A's merge or coordinate region), `tools/fetch-tts-voices.sh`; NEW tests |
| D | NEW `Services/Voice/DialectIdentifier.swift`; EDITS `Services/Voice/WhisperKitSpeechRecognizer.swift` (DecodingOptions biasing path); NEW `DialectIdentifierTests.swift` |

Waves: A + C parallel (disjoint). Then B + D parallel (B touches ModelCatalog — take A's
landed version; B and D disjoint).

## Verification

Copy model binaries from main checkout (whisper bin + CoreML + tts) into the worktree,
`xcodegen generate`, run targeted suites then full `xcodebuild test` on a dedicated
simulator with isolated DerivedData. Known environment failures to expect (documented):
UI tests on fresh sims (onboarding Skip-button clipping) and the flaky Piper
cancel-timing test.

## Merge

Commit on the branch, exit worktree, `--no-ff` merge to master after master-in-first
update (parallel sessions land commits continuously).
