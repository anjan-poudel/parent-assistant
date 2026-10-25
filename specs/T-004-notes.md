# T-004: Playback seam and AVKit adapter — implementation notes

## What was built

Three files, exactly the declared ownership set:

- `ios/ElderlyAssistant/Services/Instructions/InstructionPlayback.swift` (new)
- `ios/ElderlyAssistant/Services/Instructions/AVKitInstructionVideoPlayer.swift` (new)
- `ios/ElderlyAssistantTests/Services/Instructions/InstructionPlaybackAdapterTests.swift` (new)

### Key API

`InstructionPlayback.swift` (C06, seam only — the controller arrives in T-017):

- `enum InstructionPlaybackFailure: Error, Equatable` — exactly `.unsupported`, `.playerFailed`, `.interrupted`, `.timedOut` (design §3.3).
- `enum InstructionPlaybackEvent: Equatable` — exactly `.preflightPassed`, `.ready`, `.failed(InstructionPlaybackFailure)`, `.finished`, `.closed` (design §3.5; `.closed` is controller-only, the adapter never emits it).
- `struct InstructionPlaybackConfiguration: Equatable` — `preflightTimeoutSeconds` (0.6), `readyWatchdogSeconds` (10), `.standard` (design §9.1).
- `@MainActor protocol InstructionVideoPlaying: AnyObject` (IF-19) — `renderablePlayer: AVPlayer? { get }`, `present(url:onEvent:)`, `dismiss()`.

`AVKitInstructionVideoPlayer.swift` (C07):

- `@MainActor final class AVKitInstructionVideoPlayer: NSObject, InstructionVideoPlaying`, `override init()` constructing nothing.
- `present` runs the synchronous `AVURLAsset.isPlayable` preflight (non-file URLs refused before AVFoundation sees them — the no-network guard), constructs `AVPlayerItem`/`AVPlayer`, sets `renderablePlayer`, registers observations, and emits `.preflightPassed` — all before returning; a false preflight emits one `.failed(.unsupported)` and constructs nothing. The URL is callback-scoped and never stored.
- Observations (design §2.7.2): `AVPlayerItem.status` KVO (`[.initial, .new]`, `.readyToPlay` → `.ready` once, `.failed` → `.failed(.playerFailed)`), `AVPlayerItemDidPlayToEndTime` → `.finished` (gated on ready — `testFinishedOnlyAfterStart`), `AVPlayerItemFailedToPlayToEndTime` → `.failed(.playerFailed)` (error payload deliberately not read), `AVAudioSession.interruptionNotification` `.began` → `.failed(.interrupted)` (`.ended` is no event).
- `dismiss` closes the emission gate first, then pauses, clears the item (`replaceCurrentItem(with: nil)`), removes every observer, releases the player and drops the callback; idempotent, no event after it returns. A `deinit` safety net removes any leaked notification registrations.
- A single `emit` gate enforces: nothing after dismiss, and one terminal event per session (a `.failed` or `.finished` closes the door).
- No timers, no polling (`timeControlStatus` never read), no network, no transcode, no copy, no logging, no `play()` call — whoever holds `renderablePlayer` drives playback.

## Tests

`InstructionPlaybackAdapterTests` — all ten planned cases, verbatim names, each appearing exactly once:

`testPresentationDoesNotAutoplay`, `testPreflightMissingURLFailsUnsupported`, `testPreflightUnplayableItemFails`, `testReadyEmitsReadyOnce`, `testItemFailureEmitsPlayerFailed`, `testFinishedOnlyAfterStart`, `testDismissPausesThenReleases`, `testLateObservationAfterDismissIgnored`, `testAdapterHasNoTimers`, `testAdapterPerformsNoNetworkOrTranscode`.

Plus one extra documented case: `testInterruptionWhilePresentingMapsToInterrupted` — added because none of the ten covers the positive leg of the interruption mapping, which design §2.7.2 pins as adapter behaviour. (Deviation, see below.)

Strategy: the mapping handlers are internal and driven directly for determinism; the real KVO path is exercised once in `testReadyEmitsReadyOnce` (per design §8.1, simulator tests resolve through `AVPlayerItem.status`); observer registrations and the dismiss pause→clear→release order are source-pinned via `FeatureSourceScan` (the §11.3 E idiom). Fixtures: a deterministic silent PCM WAV (playable; same fixture T-001 pins) and a non-media file, written only into a per-test temp directory. No test touches an NSError, a logged path or a raw platform value.

## Verification (no build, per unit instructions)

- Read-back review of all three files; delimiter balance checked with a string/comment-aware counter: braces, parens, brackets all balanced in all three files (the raw grep imbalance was parens inside string literals).
- `git status --short` scoped to the owned paths: exactly the three new files; no other unit's file modified (T-001/T-002/T-005 files in the same directory are untouched).
- Grep: each of the ten planned test names exists exactly once.
- Grep: zero logging statements (`print`/`NSLog`/`os_log`/`Logger`) in all three files; zero forbidden tokens in the adapter (`timeControlStatus`, `Timer`, `.play(`, `setActive`, `setCategory`, `URLSession`, `AVAssetExportSession`, `AVAssetWriter`, `dataTask`, `http`).
- The `dismiss` body's textual order is pause → `replaceCurrentItem(with: nil)` → `renderablePlayer = nil`, matching the source pin the test asserts.

## Decisions and deviations

1. **Extra test** `testInterruptionWhilePresentingMapsToInterrupted` beyond the planned ten (documented in the file header). The interruption mapping is a pinned design contract (§2.7.2) and no planned case covers its positive leg.
2. **`override init()`** — the design's pseudo-declaration shows plain `init()`, but the repo's only NSObject subclasses with a zero-arg init use `override init()` (LocationFetcher, LiveCallDetector); plain `init()` would not compile against `NSObject.init`.
3. **`AVPlayerItemFailedToPlayToEndTime` observed** — permitted by the task's implementation notes; maps to `.failed(.playerFailed)`, gated on ready, error payload not read.
4. **Preflight rejects non-file URLs** before `isPlayable` — required by the no-network rule (design §8.3), not availability policy.
5. **No `import AVKit`** — the adapter constructs no view controller (C06 owns no AVKit view); `AVFoundation` covers `AVPlayer`/`AVAudioSession`.

## Risks

- `testReadyEmitsReadyOnce` depends on real `AVPlayerItem.status` KVO reaching `.readyToPlay` for the local WAV on the simulator (10 s expectation). This is the design's own prescribed simulator path (§8.1); the same fixture is already exercised by T-001's suite.
- `testPreflightMissingURLFailsUnsupported` relies on `AVURLAsset.isPlayable` being false for a nonexistent file — documented AVFoundation behaviour, but not separately pinned by T-001 (its prober checks existence first).
- The two real-KVO-dependent tests could flake if the simulator audio environment stalls item loading; timeouts are generous (10 s) and event assertions elsewhere are ordering-robust.
