# T-032 — at-rest encryption (cipher) for the live-camera-translation feature: implementation notes

Task: **T-032** — the cache is "encrypted" only by Data Protection; the payloads the feature persists
(recognized scene text and its translation, and the consent record) are written in the clear inside the
store's envelope. This task puts a real cipher between the feature's two consumers and the storage seam.
Worktree: `.claude/worktrees/live-camera-translation`. Uncommitted, per the workflow (no commits were made).
Driving requirement: **AM-10** ("cache-at-rest inspection of the app container", `specs/security-design-review.md`).
Owner decisions honoured: **OD7** (`GeminiCostGovernor` untouched), **OD8** (`LabelTranslationCache` not renamed).

## What was built

### 1. `LiveTranslateCipherStorage` — the cipher, as a decorator (NEW)

`ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateCipherStorage.swift` (384 lines).

Conforms to both seam protocols (`EncryptedLocalStorage`, `RawEncryptedStorage`) and wraps an injected
`EncryptedLocalStorage`. It seals every value with **AES-GCM (CryptoKit, 256-bit)** and opens nothing it
cannot authenticate. The wrapped store is untouched, so **no other feature's on-disk format changes and no
migration exists to run** — containment is the design, not an accident (see Decisions).

- `read<T>(key:type:)` → absent/undecodable/unopenable all return `.failure(.encryptedReadFailed)`, which is
  what the consumers already treat as "nothing stored" (the shipped semantics asserted by TG-04's suite).
  A payload that fails to open **or to decode is deleted** before the failure is returned.
- `write<T>(key:value:)` → JSON-encodes, seals, wraps in the versioned envelope, writes.
- `readRawData(key:)` returns the **sealed** bytes verbatim (never plaintext); this preserves the consumers'
  `payloadExistsOnDisk` probe semantics without adding an unauthenticated way to reach scene text.
- `writeRawData(_:key:)` stores verbatim; the type's own typed `write` is the only production writer.
- `discard(key:)` = `wrapped.delete(key:)`, best-effort: a store that will not delete is still never served from.

### 2. The envelope format

```
offset 0   magic     4 bytes   0x4C 0x54 0x43 0x45  ("LTCE")
offset 4   version   1 byte    0x01  (Envelope.currentVersion)
offset 5   sealed box: AES-GCM combined = nonce (12) | ciphertext (n) | tag (16)
```

Total minimum 33 bytes. Written as `Data` through the wrapped store, so the container file additionally
carries whatever envelope *that* store uses (in production: `EncryptedFileStorage`'s JSON envelope, which
base64-encodes the `Data` payload) — the ciphertext, never the plaintext.

- **Versioned and fail-closed.** `open` requires exact magic and an exact known version before it will even
  construct a `SealedBox`. A payload from a future version is not "best-effort decoded": it is treated as
  absent and removed (`testAPayloadFromAFutureVersionOrAnotherFormatIsNeverInterpretedAndIsRemoved`).
- **AAD = the storage key** (`Data(key.utf8)`). A payload copied from one key's slot to another's fails
  authentication (`testAPayloadMovedToAnotherStorageKeyFailsAuthentication`).
- **Fresh nonce every write**, taken from `AES.GCM.seal` — never reused, never supplied by the caller
  (`testTheEnvelopeIsMagicVersionNonceCiphertextAndTagWithAFreshNonceEveryWrite`).

### 3. Where the key lives

`KeychainLiveTranslateCipherKeyStore` (same file), a generic-password item:

- service `com.elderlyassistant.livetranslate.cipher`, account `plugin.live_translate.at_rest_key.v1`
- **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**, `kSecAttrSynchronizable: false`
- 32 random bytes from `SymmetricKey(size: .bits256)`

The accessibility attribute is asserted **by reading it back out of the Keychain**
(`testTheKeychainKeyStoreStoresOneDeviceBoundKey`), not by inspecting the source. AES keys cannot live in
the Secure Enclave (a P-256-only primitive), so `WhenUnlockedThisDeviceOnly` is the strongest accessibility
the platform offers for this key class; it is device-bound and unreadable while the device is locked.

The key store is behind the `LiveTranslateCipherKeyStoring` protocol (3 methods), so tests inject an
in-memory double and no suite depends on simulator Keychain state — except the one integration test above,
which is the point of that test.

### 4. Key loss

`resolveKey()` never throws, never returns nil and never traps:

| state on disk | what happens |
| --- | --- |
| usable 32-byte key | used |
| a stored value that is **not** a usable key (truncated, or written by something else) | replaced (`replaceKeyBytes`), replaced value used |
| nothing stored | generated; `addKeyBytesIfAbsent` — **first key wins**, so concurrent/racing writers converge on the key the payloads were sealed with |
| Keychain refuses to store | in-memory session key; encrypts for this session; a later launch resolves a different key and the old payload fails authentication and is discarded |

The last row is the worst case and it is deliberate: **losing the key costs translations, never data
integrity and never a launch failure.** `testKeyLossRegeneratesAKeyAndCostsOnlyTheCachedTranslations`
proves the cost is exactly a cache miss and that the store still works afterwards. The resolved key is
memoised for the life of the process (the test's "second process" is a fresh decorator over the same disk
state — noted in a comment in that test, because a memoised key inside one process is not key loss).

### 5. Wiring (the only change outside the feature's own file)

`ios/ElderlyAssistant/App/AppCoordinator.swift`, three lines in `init` (the file also carries the concurrent
agent's unrelated edits; these three are mine):

```swift
let liveTranslateStorage = LiveTranslateCipherStorage(wrapping: storage)
self.labelTranslationCache   = LabelTranslationCache(storage: liveTranslateStorage, observabilityBus: bus)
self.liveTranslateConsentGate = LiveTranslateConsentGate(storage: liveTranslateStorage, observabilityBus: bus)
```

Exactly the feature's two consumers are handed the decorator; every other consumer of the shared `storage`
is untouched (`testOnlyTheFeaturesTwoConsumersAreHandedTheCipher`).

### 6. Tests

- `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateCipherStorageTests.swift` (NEW, 657 lines, **16 tests**)
- `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateTestCipherKeyStore.swift` (NEW, 60 lines) — in-memory key-store double
- `ios/ElderlyAssistantTests/Services/LiveTranslate/LabelTranslationCacheTests.swift` (EDITED, TG-04's suite): its
  "bytes on disk" test now drives the cipher-wrapped store and asserts the payload on disk is the cipher
  envelope, decoded by opening it, with the plaintext checks moved onto the decrypted plaintext. The rest of
  the suite still drives the raw double, proving the decorator did not change seam semantics.
- `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateConsentGateTests.swift` (EDITED, TG-05's suite):
  the "real encrypted channel" test now shares one injected key store across three decorator instances.

## Directive → test mapping

| Directive (binding) | Test |
| --- | --- |
| AES-GCM via CryptoKit, Keychain-stored symmetric key | `testAValueRoundTripsThroughTheCipherAndTheStoredBytesAreNotThePlaintext`, `testTheKeychainKeyStoreStoresOneDeviceBoundKey` |
| Versioned envelope: magic + version + nonce + ciphertext + tag | `testTheEnvelopeIsMagicVersionNonceCiphertextAndTagWithAFreshNonceEveryWrite` |
| A future/foreign format is detectable and must fail closed, never mis-decode | `testAPayloadFromAFutureVersionOrAnotherFormatIsNeverInterpretedAndIsRemoved` |
| Truncated/garbage/empty shapes never trap, always fail closed | `testMalformedPayloadShapesNeverTrapAndAlwaysFailClosed` |
| Missing key → regenerate; payload reads as empty cache, no crash | `testKeyLossRegeneratesAKeyAndCostsOnlyTheCachedTranslations` |
| Unusable stored key → replaced, never reused as-is, never a raw crypto error | `testAStoredValueThatIsNotAUsableKeyIsReplacedRatherThanReused` |
| Keychain unavailable → still encrypts, never crashes | `testAKeyStoreThatWillNotStoreTheKeyStillEncryptsAndNeverCrashes` |
| Scope: the translation cache **and** the consent record | `testAM10TheConsentRecordAtRestCarriesNoPlaintextFieldAndNeverTheKey`, `testTheCacheThroughTheCipherServesAHitInALaterSessionWithUnchangedSemantics` |
| Shared `RawEncryptedStorage` seam (works over both shapes of wrapped store) | `testTheRawChannelHandsBackCiphertextForBothShapesOfWrappedStore` |
| **Byte-level ciphertext, named AM-10 evidence** | `testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext`, `testAM10TheConsentRecordAtRestCarriesNoPlaintextFieldAndNeverTheKey` |
| An unauthenticated payload is absent **and removed**, never served, never crashed on | `testAM10APayloadThatFailsAuthenticationIsTreatedAsAbsentRemovedAndNeverServed` |
| Not changeable by moving it to another storage key | `testAPayloadMovedToAnotherStorageKeyFailsAuthentication` |
| No on-disk format change for other features | `testOtherFeaturesPayloadsOnTheSharedStoreKeepTheirUnchangedFormat` |
| Contained: only this feature's consumers get the cipher | `testOnlyTheFeaturesTwoConsumersAreHandedTheCipher` |

## The AM-10 evidence, and how it was falsified

`testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext` stores a real recognition/translation pair
through the production-shaped stack (`MigratingEncryptedStorage` over `EncryptedFileStorage` on disk),
then reads the actual bytes the store holds and asserts the recognized text, the translated text
(Devanagari), the payload's schema field name and the key itself appear in **none** of the file's encoding
layers. The consent test does the same for `granted` / `recordedAt` / `disclosureVersion` / the disclosure
version string.

**The first version of this test was not falsifiable, and the falsification run found that out.** Bypassing
the cipher (driving the store directly) did *not* trip the plaintext assertions: `EncryptedFileStorage`
JSON-encodes its `Data` payload, so the plaintext sits base64-encoded inside the store envelope and a
raw-file scan misses it. The scan was therefore extended to walk the file's encoding layers without ever
decrypting (`inspectedLayers(ofFileAt:)`: file bytes, then the store envelope's `payload`, then a
base64-decoded JSON string, bounded at 3), and both AM-10 tests now assert over every layer.

Re-run with the cipher bypassed, the test now fails loudly and names the layer:

```
error: XCTAssertFalse failed - AM-10 cache-at-rest inspection: the recognized text 'fluffernutter mode'
  is present in the container bytes of 06f42ac0….json (encoding layer 1 (137 bytes))
error: XCTAssertFalse failed - AM-10 cache-at-rest inspection: the translated text is present in the
  container bytes of 06f42ac0….json (encoding layer 1 (137 bytes))
error: XCTAssertNil failed - AM-10 cache-at-rest inspection: the payload's schema field name is present
  in the container bytes of 06f42ac0….json (encoding layer 1 (137 bytes))
```

(7 failures, exit 65 — `** TEST FAILED **`.) The bypass was then reverted and the file re-run green. The
"encoding layer 1" in the message is the store envelope's payload, i.e. exactly the layer a base64-unaware
scan would have missed.

## Decisions

1. **Contained option chosen (as preferred).** The cipher is a decorator at the feature's layer, not a
   change inside `EncryptedFileStorage`. No legacy read path is needed, no byte-verbatim contract of
   `MigratingEncryptedStorage` is disturbed, and no other feature's data migrates. Cost: a payload written
   before this change (plaintext inside the store envelope) fails to open — but a plaintext `Data` payload
   is not a valid `LTCE` envelope, so it is discarded as absent, which is precisely the required
   fail-closed behaviour.
2. **Discard-on-authentication-failure lives in the decorator**, since it is the only layer that can detect
   it. Consequence recorded honestly: the cache's `cache_payload_reset` observability event and the consent
   gate's `.unreadable` state do **not** fire for cipher-level failures — the decrypted-away payload simply
   reads as absent. For consent that is still fail-closed (`.notRecorded` denies, per SD-1/AM-4). Nothing in
   the consumers' semantics was weakened; a signal for cipher-level discards is an open item below.
3. **Raw channel returns ciphertext.** `readRawData` is used only by this feature's two consumers as a
   presence probe (grepped). Returning ciphertext keeps that probe honest without adding a second,
   unauthenticated path to scene text.
4. **The store envelope's base64 layer is a real threat surface**, not a technicality — it is why the AM-10
   test scans layers (above). With Data Protection alone the scene text was one base64 decode away from any
   process that could read the container.

## Verification

Simulator: private `LCT-T032` (`iPhone 17`, iOS 26.5), `xcrun simctl create "LCT-T032" "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
`./build.sh generate` was run immediately before every gate. Per-suite counts are read from the result
bundle, not inferred from the exit code.

Scoped gate (exact command):

```
cd ios && xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=037212B1-EDAC-4F6A-A98D-42475B58353E" \
  -derivedDataPath build/T032DerivedData -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCipherStorageTests \
  -only-testing:ElderlyAssistantTests/LabelTranslationCacheTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateConsentGateTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/ApplianceHelperLabelSeamTests \
  -only-testing:ElderlyAssistantTests/ConsentPromptAndRevocationTests \
  -only-testing:ElderlyAssistantTests/MigratingEncryptedStorageTests \
  -only-testing:ElderlyAssistantTests/EncryptedFileStorageTests \
  -only-testing:ElderlyAssistantTests/StoragePlacementTests \
  -resultBundlePath build/T032-gate.xcresult
```

`** TEST SUCCEEDED **` (exit 0). `xcrun xcresulttool get test-results summary`: passed 136, failed 0,
skipped 0. Per-suite, from `xcrun xcresulttool get test-results tests`:

| suite | tests |
| --- | --- |
| LiveTranslateCipherStorageTests | 16 |
| LabelTranslationCacheTests (TG-04) | 21 |
| LiveTranslateConsentGateTests (TG-05) | 29 |
| LiveTranslateSourceHygieneTests | 6 |
| ApplianceHelperLabelSeamTests | 9 |
| ConsentPromptAndRevocationTests | 22 |
| MigratingEncryptedStorageTests | 15 |
| EncryptedFileStorageTests | 12 |
| StoragePlacementTests | 6 |
| **total** | **136** |

Adjacent feature suites (`AlwaysShowOriginalToggleTests` 11, `CameraPermissionSurfaceTests` 14,
`CloudActivityIndicatorTests` 15, `CloudTranslationTierTests` 25, `GeminiClientTranslateTests` 15,
`LiveOverlayPlacementTests` 28) → **108 tests, 0 failures**.

Release build: `cd ios && IOS_DERIVED_DATA="$PWD/build/T032DerivedData" ./build.sh build` → `** BUILD SUCCEEDED **`
(exit 0). Release log safety: `cd ios && ./tools/check-release-log-safety.sh` → exit 0
("no transcript content or raw error object can be printed in a non-Debug configuration").

## Environment findings

- `ElderlyAssistantTests` compiles as one unit: a transient compile error in the **concurrent agent's**
  `LiveTranslateSpeechTests.swift` ("method must be declared private because its result uses a private
  type") blocked a test build. Per the environment rules I did not touch that file; I waited and re-ran, and
  the build succeeded. Expect further churn in that file from that agent.
- The simulator's Keychain works under the test host, so the real `KeychainLiveTranslateCipherKeyStore` is
  integration-tested against `SecItemAdd`/`SecItemCopyMatching`, including reading back
  `kSecAttrAccessible`. The test uses a UUID-suffixed throwaway service and deletes its item in a `defer`.
- The unit baseline is genuinely RED outside this scope (~21 pre-existing failures in unrelated
  intent-engine/voice suites), so every gate here is scoped with `-only-testing:` and per-suite counts are
  read from the result bundle — a suite whose class is missing from the generated project runs nothing and
  still reports success.

## Open items (reported, not silently closed)

1. **No observability event for cipher-level discards.** A payload discarded because it failed
   authentication is invisible to the feature's event bus (decision 2). If the team wants that signal,
   it belongs in the consumers, which own their event vocabulary — deliberately not invented here.
2. **Key rotation does not re-seal existing payloads.** Replacing the key (unusable-value path) makes old
   payloads unreadable and they are discarded as absent; acceptable for a cache and for a consent record
   that fails closed, but a future requirement to preserve either across rotation would need a re-seal step.
3. **The pre-change plaintext payloads are discarded, not migrated.** That is the fail-closed behaviour and
   the intended cost of containment; a user upgrading mid-cache loses the cached translations (never data
   integrity, never a launch failure).
4. **AM-10 remains a claim about the app container only.** This change covers the feature's two persisted
   payloads. It says nothing about other features' payloads, which are explicitly out of scope (no format
   change was made for them).
