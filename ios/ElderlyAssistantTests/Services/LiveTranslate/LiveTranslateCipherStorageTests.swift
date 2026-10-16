import XCTest
import CryptoKit
import Security
@testable import ElderlyAssistant

/// T-032 — the at-rest cipher for the feature's two persisted payloads.
///
/// The suite's centre of gravity is the one assertion Data Protection cannot
/// make: the bytes the app container holds must not contain the recognized or
/// the translated string. Everything else here exists so that the cipher which
/// makes that true cannot quietly stop being a cipher — the envelope layout,
/// the failure paths (tamper, foreign format, lost key), and the containment
/// claim that no other feature's on-disk format changed.
///
/// The three tests named `…AM10…` are the evidence for AM-10's
/// "cache-at-rest inspection of the app container" item. They are named so a
/// reviewer can find them from that sentence alone, and they fail loudly if a
/// payload ever goes out in the clear again.
final class LiveTranslateCipherStorageTests: XCTestCase {

    private var keyStore: LiveTranslateTestCipherKeyStore!
    private var storage: LabelTranslationCacheTestStorage!
    private var cipher: LiveTranslateCipherStorage!
    private var bus: LiveTranslateSanitisingBus!

    private var storageKey: String { LabelTranslationCache.storageKey }
    private var consentKey: String { LiveTranslateConsentGate.storageKey }

    /// Nonsense on purpose: a word that cannot appear in a payload by
    /// accident, so "not found in the container" is evidence rather than luck.
    private let recognizedText = "fluffernutter mode"
    private let translationText = "फ्लफरनटर मोड"

    /// The declared payload shape, used where the test needs a value rather
    /// than the feature's own type.
    private struct Payload: Codable, Equatable {
        let key: String
        let translation: String
    }

    private var payload: Payload {
        Payload(key: "\(recognizedText)|ne", translation: translationText)
    }

    override func setUp() {
        super.setUp()
        keyStore = LiveTranslateTestCipherKeyStore()
        storage = LabelTranslationCacheTestStorage()
        cipher = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)
        bus = LiveTranslateSanitisingBus()
    }

    // MARK: - Helpers

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The storage shape production hands the feature: the shared migrating
    /// store (Keychain for small secrets, encrypted files for everything
    /// structured) over a real directory. The Keychain half is a test double
    /// so no suite depends on the simulator's Keychain state.
    private func productionShapedStorage(root: URL) -> MigratingEncryptedStorage {
        MigratingEncryptedStorage(keychain: LabelTranslationCacheTestStorage(),
                                 files: EncryptedFileStorage(rootDirectory: root))
    }

    /// The byte strings an inspection of the container actually looks at.
    ///
    /// The first falsification of these AM-10 checks is why this exists: the
    /// store's envelope carries a `Data` payload base64-encoded inside its
    /// own JSON, so a scan of the FILE alone misses the payload the file
    /// holds — the pre-cipher format's plaintext was one base64 decode away
    /// from an inspector's eyes. So each file contributes the file bytes, the
    /// payload its envelope carries, and one encoded layer beneath that.
    /// Bounded at three: this scan never decrypts, which is what makes it
    /// evidence rather than a restatement of the cipher's own tests.
    private func inspectedLayers(ofFileAt url: URL) throws -> [(name: String, bytes: Data)] {
        var layers: [(name: String, bytes: Data)] = [("the file bytes", try Data(contentsOf: url))]
        var current = layers[0].bytes
        for depth in 1...3 {
            guard let unwrapped = Self.unwrapOneEncodingLayer(current),
                  unwrapped != current else { break }
            layers.append(("encoding layer \(depth) (\(unwrapped.count) bytes)", unwrapped))
            current = unwrapped
        }
        return layers
    }

    /// One layer off a stored blob: the store envelope's payload, or a base64
    /// string's decoded bytes. nil when the bytes are neither.
    private static func unwrapOneEncodingLayer(_ bytes: Data) -> Data? {
        if let envelope = try? JSONDecoder().decode(EncryptedFileStorage.Envelope.self, from: bytes) {
            return envelope.payload
        }
        if let text = try? JSONDecoder().decode(String.self, from: bytes),
           let decoded = Data(base64Encoded: text) {
            return decoded
        }
        return nil
    }

    /// Asserts `needles` appear in none of a file's inspectable layers.
    private func assertNoPlaintext(_ needles: [(String, Data)],
                                   inLayersOfFileAt url: URL,
                                   _ context: String) throws {
        for layer in try inspectedLayers(ofFileAt: url) {
            let text = String(decoding: layer.bytes, as: UTF8.self)
            for (description, needle) in needles {
                XCTAssertNil(layer.bytes.range(of: needle),
                             "AM-10 cache-at-rest inspection: \(description) is present in "
                             + "\(context) (\(layer.name))")
                XCTAssertFalse(text.lowercased().contains(String(decoding: needle, as: UTF8.self).lowercased()),
                               "AM-10 cache-at-rest inspection: \(description) is present in "
                               + "\(context) (\(layer.name))")
            }
        }
    }

    /// Every byte on the channel for `key`, or a test failure.
    private func storedBytes(forKey key: String) throws -> Data {
        try XCTUnwrap(storage.bytes(forKey: key), "nothing stored for \(key)")
    }

    private func isSealedEnvelope(_ data: Data) -> Bool {
        guard data.count >= LiveTranslateCipherStorage.Envelope.minimumByteCount else { return false }
        return Array(data.prefix(LiveTranslateCipherStorage.Envelope.magic.count))
                == LiveTranslateCipherStorage.Envelope.magic
            && data[data.startIndex + LiveTranslateCipherStorage.Envelope.magic.count]
                == LiveTranslateCipherStorage.Envelope.currentVersion
    }

    /// Every file under `root`, recursively — the "inspection of the app
    /// container" the AM-10 items perform. Recursive on purpose: a second
    /// copy, a temporary sibling or a nested directory is exactly what this
    /// inspection exists to find.
    private func containerFiles(under root: URL) throws -> [(name: String, bytes: Data)] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).map {
            (name: $0, bytes: try Data(contentsOf: root.appendingPathComponent($0)))
        }
    }

    // MARK: - The envelope on the channel

    func testAValueRoundTripsThroughTheCipherAndTheStoredBytesAreNotThePlaintext() throws {
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        guard case .success(let read) = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("the value that was just written must read back")
        }
        XCTAssertEqual(read, payload)

        let bytes = try storedBytes(forKey: storageKey)
        XCTAssertTrue(isSealedEnvelope(bytes), "the channel holds a sealed envelope, not the value")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(recognizedText), "the recognized text is on the channel in the clear")
        XCTAssertNil(bytes.range(of: Data(translationText.utf8)),
                     "the translated text is on the channel in the clear")
    }

    func testTheEnvelopeIsMagicVersionNonceCiphertextAndTagWithAFreshNonceEveryWrite() throws {
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        let first = try storedBytes(forKey: storageKey)

        // magic | version | nonce | ciphertext | tag — parsed here with the
        // crypto primitive itself, so the layout cannot silently drift from
        // what it claims to be.
        let header = LiveTranslateCipherStorage.Envelope.headerByteCount
        XCTAssertTrue(isSealedEnvelope(first))
        XCTAssertEqual(first.count - header - LiveTranslateCipherStorage.Envelope.nonceByteCount
                        - LiveTranslateCipherStorage.Envelope.tagByteCount,
                       try JSONEncoder().encode(payload).count,
                       "ciphertext is exactly the encoded payload; nothing else rides along")
        let box = try AES.GCM.SealedBox(combined: first.dropFirst(header))
        XCTAssertEqual(box.nonce.withUnsafeBytes { $0.count },
                       LiveTranslateCipherStorage.Envelope.nonceByteCount)
        XCTAssertEqual(box.tag.count, LiveTranslateCipherStorage.Envelope.tagByteCount)
        // Compared as the **decoded value**, not as bytes: two independent
        // `JSONEncoder().encode` calls on the same value are free to order the
        // fields differently — Foundation serialises through an unordered
        // dictionary — and this assertion used to compare them byte-for-byte.
        // It was therefore a coin flip: a green run had the two encoders
        // agreeing on order, a red one had them disagreeing over an 82-byte
        // plaintext that was in fact equal in every field (evidence kept in
        // the PR). The claim here is "the plaintext is the payload", and the
        // decoder is what makes that claim, one way or the other.
        XCTAssertEqual(try JSONDecoder().decode(Payload.self,
                                                from: try AES.GCM.open(box,
                                                                       using: SymmetricKey(data: try XCTUnwrap(keyStore.bytes)),
                                                                       authenticating: Data(storageKey.utf8))),
                       payload)

        // The same value written twice is two different byte strings: a
        // repeated nonce would be a real GCM weakness, and this is what would
        // catch one.
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        let second = try storedBytes(forKey: storageKey)
        XCTAssertNotEqual(first, second, "every write must use a fresh nonce")
        XCTAssertNotEqual(first.dropFirst(header), second.dropFirst(header))
    }

    func testTheRawChannelHandsBackCiphertextForBothShapesOfWrappedStore() throws {
        // 1. A wrapped store with a verbatim byte channel — the shipped
        //    `EncryptedFileStorage`, and the test double.
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        let raw = try XCTUnwrap(cipher.readRawData(key: storageKey))
        XCTAssertTrue(isSealedEnvelope(raw),
                      "the raw channel is the ciphertext: it must never decrypt")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(recognizedText))

        // 2. A wrapped store WITHOUT one — `MigratingEncryptedStorage`, which
        //    is what production actually hands the feature. The sealed bytes
        //    travel through its `Data` channel and are handed back the same,
        //    so the consumers' "is something stored here?" probe answers the
        //    same way whichever store is underneath.
        let root = temporaryRoot("CipherRawChannel")
        defer { try? FileManager.default.removeItem(at: root) }
        let productionCipher = LiveTranslateCipherStorage(
            wrapping: productionShapedStorage(root: root), keyStore: keyStore)
        XCTAssertTrue(productionCipher.write(key: storageKey, value: payload).isSuccess)
        let productionRaw = try XCTUnwrap(productionCipher.readRawData(key: storageKey))
        XCTAssertTrue(isSealedEnvelope(productionRaw))
        XCTAssertNil(productionRaw.range(of: Data(translationText.utf8)))
    }

    // MARK: - AM-10: at-rest inspection of the container

    func testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext() throws {
        let root = temporaryRoot("AM10CacheAtRest")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LabelTranslationCache(storage: LiveTranslateCipherStorage(
                                            wrapping: productionShapedStorage(root: root),
                                            keyStore: keyStore),
                                          observabilityBus: bus)
        XCTAssertTrue(cache.store(text: recognizedText, translation: translationText).isSuccess)

        let files = try containerFiles(under: root)
        XCTAssertEqual(files.count, 1, "one payload, one file: \(files.map(\.name))")
        let keyBytes = try XCTUnwrap(keyStore.bytes)
        for file in files {
            XCTAssertFalse(file.name.lowercased().contains(recognizedText),
                           "the recognized text reached a file name: \(file.name)")
            try assertNoPlaintext([("the recognized text '\(recognizedText)'",
                                    Data(recognizedText.utf8)),
                                   ("the translated text", Data(translationText.utf8)),
                                   ("the payload's schema field name",
                                    Data("lastAccessSequence".utf8)),
                                   ("the key that protects it", keyBytes)],
                                  inLayersOfFileAt: root.appendingPathComponent(file.name),
                                  "the container bytes of \(file.name)")
        }

        // The scan is not vacuous: the payload really is there, and it really
        // does carry this text — read back through the cipher, by a second
        // cache over the same directory.
        let reopened = LabelTranslationCache(storage: LiveTranslateCipherStorage(
                                                wrapping: productionShapedStorage(root: root),
                                                keyStore: keyStore),
                                             observabilityBus: bus)
        guard case .success(.some(let hit)) = reopened.lookup(text: "  \(recognizedText.uppercased())  ") else {
            return XCTFail("the stored translation must be served through the cipher")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertEqual(hit.origin, .persistedLayer)
    }

    func testAM10TheConsentRecordAtRestCarriesNoPlaintextFieldAndNeverTheKey() throws {
        let root = temporaryRoot("AM10ConsentAtRest")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LiveTranslateConsentGate(storage: LiveTranslateCipherStorage(
                                                wrapping: productionShapedStorage(root: root),
                                                keyStore: keyStore),
                                            observabilityBus: bus)
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        let files = try containerFiles(under: root)
        XCTAssertEqual(files.count, 1, "one record, one file: \(files.map(\.name))")
        let keyBytes = try XCTUnwrap(keyStore.bytes)
        for file in files {
            try assertNoPlaintext([("'granted'", Data("granted".utf8)),
                                   ("'recordedAt'", Data("recordedAt".utf8)),
                                   ("'disclosureVersion'", Data("disclosureVersion".utf8)),
                                   ("the disclosure version",
                                    Data(LiveTranslateConfig.default.disclosureVersion.utf8)),
                                   ("the key that protects it", keyBytes)],
                                  inLayersOfFileAt: root.appendingPathComponent(file.name),
                                  "the container bytes of \(file.name)")
        }

        // Not vacuous: the record is there, and it really is a grant.
        let reopened = LiveTranslateConsentGate(storage: LiveTranslateCipherStorage(
                                                    wrapping: productionShapedStorage(root: root),
                                                    keyStore: keyStore),
                                                observabilityBus: bus)
        XCTAssertEqual(reopened.currentDecision(), .granted)
    }

    // MARK: - Fail closed

    func testAM10APayloadThatFailsAuthenticationIsTreatedAsAbsentRemovedAndNeverServed() throws {
        // The cache's payload, edited by one byte — the shape a tampered or
        // partially overwritten container produces.
        let cache = LabelTranslationCache(storage: cipher, observabilityBus: bus)
        XCTAssertTrue(cache.store(text: recognizedText, translation: translationText).isSuccess)
        var edited = try storedBytes(forKey: storageKey)
        edited[edited.count - 1] ^= 0x01
        storage.setRaw(edited, forKey: storageKey)

        let reopened = LabelTranslationCache(storage: cipher, observabilityBus: bus)
        guard case .success(let miss) = reopened.lookup(text: recognizedText) else {
            return XCTFail("an unauthenticated payload must read as an empty cache, "
                           + "never as a failure the elder could see")
        }
        XCTAssertNil(miss, "nothing that fails authentication is ever served")
        XCTAssertNil(storage.bytes(forKey: storageKey),
                     "the unauthenticated payload is discarded, not left to fail again")

        // The feature still works afterwards: the next resolution stores and
        // reads a fresh payload.
        XCTAssertTrue(reopened.store(text: recognizedText, translation: translationText).isSuccess)
        guard case .success(.some(let hit)) = reopened.lookup(text: recognizedText) else {
            return XCTFail("the store must keep working after a discard")
        }
        XCTAssertEqual(hit.translation, translationText)

        // The same rule at the consent seam: a record that fails
        // authentication is absent — which denies — and is removed.
        let gateCipher = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)
        let gate = LiveTranslateConsentGate(storage: gateCipher, observabilityBus: bus)
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        var editedRecord = try storedBytes(forKey: consentKey)
        editedRecord[editedRecord.count - 1] ^= 0x01
        storage.setRaw(editedRecord, forKey: consentKey)

        let reopenedGate = LiveTranslateConsentGate(storage: gateCipher, observabilityBus: bus)
        XCTAssertEqual(reopenedGate.currentDecision(), .notRecorded,
                       "an unauthenticated record is absent, and absent denies (AM-4 fail-closed)")
        XCTAssertFalse(reopenedGate.currentDecision().allowsEgress)
        XCTAssertNil(storage.bytes(forKey: consentKey), "the unauthenticated record is removed")
    }

    func testAPayloadFromAFutureVersionOrAnotherFormatIsNeverInterpretedAndIsRemoved() throws {
        // A future layout is detectable and fails closed rather than being
        // guessed at: the version byte is read, not assumed.
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        var future = try storedBytes(forKey: storageKey)
        future[future.startIndex + LiveTranslateCipherStorage.Envelope.magic.count] =
            LiveTranslateCipherStorage.Envelope.currentVersion &+ 1
        storage.setRaw(future, forKey: storageKey)

        guard case .failure = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("a future version must not be decoded as if it were this one")
        }
        XCTAssertNil(storage.bytes(forKey: storageKey), "an unreadable payload is discarded")

        // A foreign format — bytes that are not this cipher's envelope at all.
        storage.setRaw(Data("not a payload".utf8), forKey: storageKey)
        guard case .failure = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("a foreign payload must fail closed")
        }
        XCTAssertNil(storage.bytes(forKey: storageKey))

        // And the data that was never ours in the first place: a wrong magic
        // bytes string that is still shaped like an envelope.
        var foreign = Data([0x00, 0x01, 0x02, 0x03])
        foreign.append(LiveTranslateCipherStorage.Envelope.currentVersion)
        foreign.append(Data(repeating: 0xAB,
                            count: LiveTranslateCipherStorage.Envelope.minimumByteCount))
        storage.setRaw(foreign, forKey: storageKey)
        guard case .failure = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("a foreign magic must fail closed")
        }
    }

    func testMalformedPayloadShapesNeverTrapAndAlwaysFailClosed() throws {
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        let sealed = try storedBytes(forKey: storageKey)
        let header = LiveTranslateCipherStorage.Envelope.headerByteCount
        let minimum = LiveTranslateCipherStorage.Envelope.minimumByteCount

        var nonceEdited = sealed
        nonceEdited[nonceEdited.startIndex + header] ^= 0xFF
        var tagEdited = sealed
        tagEdited[tagEdited.count - 1] ^= 0xFF
        var magicEdited = sealed
        magicEdited[magicEdited.startIndex] ^= 0xFF

        let shapes: [(name: String, bytes: Data)] = [
            ("empty", Data()),
            ("one byte", Data([0x00])),
            ("magic only", Data(LiveTranslateCipherStorage.Envelope.magic)),
            ("header only", Data(sealed.prefix(header))),
            ("one byte short of a sealed box", Data(sealed.prefix(minimum - 1))),
            ("nonce edited", nonceEdited),
            ("tag edited", tagEdited),
            ("magic edited", magicEdited)
        ]

        for shape in shapes {
            storage.setRaw(shape.bytes, forKey: storageKey)
            // Reaching the assertion at all is half the evidence — no shape
            // traps — and the shape is named so a failure says which one.
            switch cipher.read(key: storageKey, type: Payload.self) {
            case .success:
                XCTFail("\(shape.name) must never be served")
            case .failure(.encryptedReadFailed):
                break   // the store's one failure: no crypto detail travels
            case .failure:
                XCTFail("\(shape.name) reported a failure other than the store's own")
            }
        }
    }

    func testAPayloadMovedToAnotherStorageKeyFailsAuthentication() throws {
        // Both payloads share the key, so the placement of the bytes must be
        // authenticated too: a consent record copied into the cache's slot (or
        // the reverse) is not a value this store will serve.
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        let sealed = try storedBytes(forKey: storageKey)
        storage.setRaw(sealed, forKey: consentKey)

        guard case .failure = cipher.read(key: consentKey, type: Payload.self) else {
            return XCTFail("the storage key is authenticated data: a moved payload must fail")
        }
        XCTAssertNil(storage.bytes(forKey: consentKey), "the moved payload is discarded")

        // The original is untouched and still readable.
        guard case .success(let read) = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("discarding the copy must not touch the original")
        }
        XCTAssertEqual(read, payload)
    }

    // MARK: - Key lifecycle

    func testKeyLossRegeneratesAKeyAndCostsOnlyTheCachedTranslations() throws {
        let first = LabelTranslationCache(storage: cipher, observabilityBus: bus)
        XCTAssertTrue(first.store(text: recognizedText, translation: translationText).isSuccess)
        let originalKey = try XCTUnwrap(keyStore.bytes)

        // The key is gone (a restore, a deleted item, or a key something else
        // replaced) — the scenario the directive says must never crash and
        // must never fail the launch. A new cipher instance is the new
        // process: this one resolves the key from the key store, as launch
        // does (a resolved key is memoised for the life of the process, which
        // is the only reason a running process cannot lose it).
        keyStore.loseKey()
        let second = LabelTranslationCache(
            storage: LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore),
            observabilityBus: bus)

        guard case .success(let miss) = second.lookup(text: recognizedText) else {
            return XCTFail("key loss must read as an empty cache, not as an error")
        }
        XCTAssertNil(miss, "losing the key costs the translations it protected")

        // A usable key was regenerated and stored, the payload that could not
        // be read was discarded, and the feature carries on.
        let regeneratedKey = try XCTUnwrap(keyStore.bytes)
        XCTAssertEqual(regeneratedKey.count, LiveTranslateCipherStorage.keyByteCount)
        XCTAssertNotEqual(regeneratedKey, originalKey)
        XCTAssertNil(storage.bytes(forKey: storageKey),
                     "the payload no key can open is discarded, not left behind")
        XCTAssertTrue(second.store(text: recognizedText, translation: "पुनः").isSuccess)
        guard case .success(.some(let hit)) = second.lookup(text: recognizedText) else {
            return XCTFail("the feature must keep working after a key loss")
        }
        XCTAssertEqual(hit.translation, "पुनः")
    }

    func testAStoredValueThatIsNotAUsableKeyIsReplacedRatherThanReused() throws {
        // A truncated key — the shape a damaged or foreign Keychain item has.
        keyStore = LiveTranslateTestCipherKeyStore(bytes: Data(repeating: 0x11, count: 16))
        let cipher = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)

        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)
        XCTAssertEqual(keyStore.bytes?.count, LiveTranslateCipherStorage.keyByteCount,
                       "an unusable stored key must be replaced, or every launch would "
                       + "generate a different unusable one")
        XCTAssertGreaterThan(keyStore.replaceCount, 0)

        // The replacement is stable: a second process instance reads the same
        // key and serves the payload.
        let reopened = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)
        guard case .success(let read) = reopened.read(key: storageKey, type: Payload.self) else {
            return XCTFail("the payload must be readable with the replacement key")
        }
        XCTAssertEqual(read, payload)
    }

    func testAKeyStoreThatWillNotStoreTheKeyStillEncryptsAndNeverCrashes() throws {
        keyStore.failsWrites = true
        let cipher = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)

        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess,
                      "an unavailable Keychain must not turn writes into failures")
        XCTAssertNil(keyStore.bytes, "nothing was stored")
        let bytes = try storedBytes(forKey: storageKey)
        XCTAssertTrue(isSealedEnvelope(bytes), "the session key still seals the payload")

        // Same process: the memoised key decrypts it.
        guard case .success(let read) = cipher.read(key: storageKey, type: Payload.self) else {
            return XCTFail("the session key must serve this session")
        }
        XCTAssertEqual(read, payload)

        // Next launch: a different key, so the payload reads as absent — a
        // cost in translations, which is what losing a key is allowed to cost.
        let nextLaunch = LiveTranslateCipherStorage(wrapping: storage, keyStore: keyStore)
        guard case .failure = nextLaunch.read(key: storageKey, type: Payload.self) else {
            return XCTFail("a payload sealed with a key that was never stored must not be served")
        }
    }

    func testTheKeychainKeyStoreStoresOneDeviceBoundKey() throws {
        // A throwaway service, so this integration check never collides with
        // the app's real item or with another run.
        let service = "com.elderlyassistant.livetranslate.cipher.tests.\(UUID().uuidString)"
        let account = KeychainLiveTranslateCipherKeyStore.defaultAccount
        let store = KeychainLiveTranslateCipherKeyStore(service: service, account: account)
        defer { _ = SecItemDelete(cleanupQuery(service: service, account: account) as CFDictionary) }

        XCTAssertNil(store.readKeyBytes(), "a fresh service holds no key")

        let first = Data(repeating: 0x11, count: LiveTranslateCipherStorage.keyByteCount)
        XCTAssertEqual(store.addKeyBytesIfAbsent(first), first)
        XCTAssertEqual(store.readKeyBytes(), first)

        // Never clobbers: the first key written is the key the payloads were
        // sealed with, so a second writer converges on it rather than
        // orphaning them.
        let second = Data(repeating: 0x22, count: LiveTranslateCipherStorage.keyByteCount)
        XCTAssertEqual(store.addKeyBytesIfAbsent(second), first,
                       "an existing key must never be overwritten")

        // Replacing is the one way a stored value changes, and it is reached
        // only for a value the cipher has read and found unusable.
        let third = Data(repeating: 0x33, count: LiveTranslateCipherStorage.keyByteCount)
        XCTAssertTrue(store.replaceKeyBytes(third))
        XCTAssertEqual(store.readKeyBytes(), third)

        // The attribute that makes the protection claim true, read back from
        // the Keychain rather than taken from the source.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess,
                       "the key item must be there")
        let attributes = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "the key is device-bound and unreadable while the device is locked")
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false,
                       "the key must never travel to another device via iCloud Keychain")

        // And the store is a working key store end to end: a payload sealed by
        // one instance is opened by the next, which is what "the key outlives
        // the process" means.
        let root = temporaryRoot("KeychainEndToEnd")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProcess = LiveTranslateCipherStorage(
            wrapping: productionShapedStorage(root: root),
            keyStore: KeychainLiveTranslateCipherKeyStore(service: service, account: account))
        XCTAssertTrue(firstProcess.write(key: storageKey, value: payload).isSuccess)
        let nextProcess = LiveTranslateCipherStorage(
            wrapping: productionShapedStorage(root: root),
            keyStore: KeychainLiveTranslateCipherKeyStore(service: service, account: account))
        guard case .success(let read) = nextProcess.read(key: storageKey, type: Payload.self) else {
            return XCTFail("the Keychain key must outlive the process that created it")
        }
        XCTAssertEqual(read, payload)
    }

    private func cleanupQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    // MARK: - Containment

    func testOtherFeaturesPayloadsOnTheSharedStoreKeepTheirUnchangedFormat() throws {
        // The cipher is a decorator over the seam, and this is the claim it
        // has to earn: another feature writing through the SAME store keeps
        // the format it always had, so nothing else needs a migration.
        let root = temporaryRoot("CipherContainment")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = productionShapedStorage(root: root)
        let cipher = LiveTranslateCipherStorage(wrapping: shared, keyStore: keyStore)

        XCTAssertTrue(shared.write(key: "app.activity.log", value: ["opened"]).isSuccess)
        XCTAssertTrue(cipher.write(key: storageKey, value: payload).isSuccess)

        let otherEnvelope = try JSONDecoder().decode(
            EncryptedFileStorage.Envelope.self,
            from: try Data(contentsOf: root.appendingPathComponent(
                EncryptedFileStorage.fileName(for: "app.activity.log"))))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: otherEnvelope.payload),
                       ["opened"],
                       "another feature's payload is still the store's plain envelope")

        let featureBytes = try Data(contentsOf: root.appendingPathComponent(
            EncryptedFileStorage.fileName(for: storageKey)))
        let featureEnvelope = try JSONDecoder().decode(EncryptedFileStorage.Envelope.self,
                                                       from: featureBytes)
        XCTAssertNil(try? JSONDecoder().decode(LabelTranslationCache.Persisted.self,
                                               from: featureEnvelope.payload),
                     "the feature's payload is no longer the plain shape")
        XCTAssertFalse(String(decoding: featureBytes, as: UTF8.self).lowercased().contains(recognizedText))
    }

    func testOnlyTheFeaturesTwoConsumersAreHandedTheCipher() {
        let ios = FeatureSourceScan.iosDirectory()
        let constructedIn = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant")
            .filter { FeatureSourceScan.codeText(of: $0).contains("LiveTranslateCipherStorage(") }
            .map { FeatureSourceScan.relativePath(of: $0) }
        XCTAssertEqual(constructedIn, ["ElderlyAssistant/App/AppCoordinator.swift"],
                       "one construction site, so the blast radius is one line of wiring")

        let coordinator = FeatureSourceScan.codeText(
            of: ios.appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        for consumer in ["labelTranslationCache = LabelTranslationCache\\(storage: liveTranslateStorage",
                         "liveTranslateConsentGate = LiveTranslateConsentGate\\(storage: liveTranslateStorage"] {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: consumer, in: coordinator),
                            "the cipher must wrap exactly the feature's two consumers")
        }
    }

    // MARK: - The feature's own semantics through the cipher

    func testTheCacheThroughTheCipherServesAHitInALaterSessionWithUnchangedSemantics() throws {
        let root = temporaryRoot("CipherCacheSession")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LabelTranslationCache(storage: LiveTranslateCipherStorage(
                                            wrapping: productionShapedStorage(root: root),
                                            keyStore: keyStore),
                                          observabilityBus: bus)
        XCTAssertTrue(first.store(text: recognizedText, translation: translationText).isSuccess)

        let second = LabelTranslationCache(storage: LiveTranslateCipherStorage(
                                            wrapping: productionShapedStorage(root: root),
                                            keyStore: keyStore),
                                           observabilityBus: bus)
        guard case .success(.some(let hit)) = second.lookup(text: recognizedText) else {
            return XCTFail("the persisted layer must survive a new session through the cipher")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertEqual(hit.origin, .persistedLayer)
        XCTAssertEqual(hit.tier, .cloud)

        // The dictionary layer is untouched by any of this: a curated label is
        // still answered without touching the payload.
        guard case .success(.some(let curated)) = second.lookup(text: "Start") else {
            return XCTFail("the curated layer must be unaffected")
        }
        XCTAssertEqual(curated.origin, .curatedDictionary)
    }
}
