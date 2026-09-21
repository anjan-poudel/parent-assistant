import XCTest
import CryptoKit
import Combine
@testable import ElderlyAssistant

/// Multipart model delivery (2026-09-14): the ordered-part download path
/// for artifacts GitHub's 2 GiB per-asset cap cannot carry in one piece,
/// its cumulative progress, its all-or-nothing cleanup — and the hard size
/// guardrail that keeps "parts" from becoming the hole through which
/// arbitrary model sizes ship.
final class MultipartDownloadTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!

    /// Room for the tests that drive the REAL catalog entry (2.5 GB): the
    /// download service's disk pre-flight measures the HOST volume, so
    /// without this those tests fail on any machine with less than
    /// `entry.sizeBytes + 300 MB` free — a property of the machine, not of
    /// the flow under test (three of them did exactly that, with
    /// "not enough disk space", on a shared nearly-full host). The guard's
    /// own refusal path is pinned deterministically instead, by
    /// `testDiskGuardRefusesBeforeTheTransportIsTouched`.
    private let roomyFreeSpace: () -> Int64? = { 100_000_000_000 }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        MultipartStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MultipartStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// `resolving:` injects a SYNTHETIC entry — one no release ships — so
    /// the strict download → concat → verify → install path can run for it
    /// without a multi-GB asset. Production resolves the shipped catalog;
    /// the service side already takes a synthetic entry
    /// (`ModelDownloadService.start(_ entry:)`), and this is the store half
    /// of that same seam (without it the store answers `unknownModel` for
    /// an id the service is already downloading).
    private func makeStore(policy: ModelChecksumPolicy = .skip,
                           resolving entry: ModelCatalogEntry? = nil) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: policy,
                       entryProvider: { id in
                           if let entry, entry.id == id { return entry }
                           return ModelCatalog.entry(for: id)
                       })
    }

    /// Streaming sha256 the strict verifier would compute, for building a
    /// REAL pin for a synthetic artifact.
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic filler bytes for a part of `count` bytes.
    private func patternedBytes(_ count: Int) -> Data {
        let pattern = Array("0123456789abcdef".utf8)
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count { data.append(contentsOf: pattern) }
        return Data(data.prefix(count))
    }

    /// A session factory whose sessions answer through the stub protocol
    /// instead of the network — the service's own `sessionFactory` seam, so
    /// the REAL download code path runs unchanged.
    private func stubSessionFactory() -> () -> URLSession {
        {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MultipartStubURLProtocol.self]
            config.waitsForConnectivity = false
            return URLSession(configuration: config)
        }
    }

    /// `minRAM` defaults to a floor every phone clears; the RAM-guard test
    /// raises it to `UInt64.max` so `MemoryProbe.canFit` answers false on any
    /// device the suite could run on (the probe compares against
    /// `ProcessInfo.physicalMemory`, so no real machine can pass it).
    private func makeEntry(id: String, sizeBytes: Int64,
                           minRAM: UInt64 = 1,
                           parts: [URL]? = nil,
                           sha: String = String(repeating: "a", count: 64)) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: ModelID(id),
            kind: .llamaBase,
            displayName: "Synthetic \(id)",
            filename: "\(id).gguf",
            downloadURL: parts?.first ?? URL(string: "https://example.com/\(id).gguf")!,
            downloadPartURLs: parts,
            sizeBytes: sizeBytes,
            sha256: sha,
            minDeviceRAMBytes: minRAM,
            languages: [])
    }

    /// The part temp directories the runner left behind for `id` (it names
    /// them `model-parts-<id>-<uuid>` under the process temp directory).
    private func partTempDirectories(for id: ModelID) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("model-parts-\(id.rawValue)-") }
    }

    /// Spins the run loop until the service's main-queue state publishes
    /// have landed (every `update` hops through `DispatchQueue.main.async`,
    /// while downloads complete on a background delegate queue).
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 15,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    /// Wait for the stub's process-wide request record to stop growing, and
    /// call it from any test that interrupts work still in flight.
    ///
    /// The stub records into a `static` (`requestedPaths`), and the cancel
    /// tests stop tasks that are deliberately hanging. A task whose resume
    /// raced the cancel can still deliver its `startLoading` a few
    /// milliseconds later — after `tearDown` has reset the record — and the
    /// straggler then lands in whichever test is running by then, which is
    /// how the disk-guard test (that same entry, `hangs`) could see a part
    /// request it never made. Draining here keeps the request inside the
    /// test that caused it, so "nothing was requested" stays a statement
    /// about the flow under test rather than about scheduling luck.
    private func drainStubRequests(quietFor: TimeInterval = 0.15,
                                   timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var quietSince = Date()
        while Date() < deadline {
            let count = MultipartStubURLProtocol.requestedPaths.count
            if count != lastCount {
                lastCount = count
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietFor {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Collects the progress the service publishes for one model so a test
    /// can assert on the whole sequence, not just the final value.
    private final class ProgressRecorder {
        private(set) var received: [Int64] = []
        private(set) var totals: [Int64] = []
        var maxReceived: Int64 { received.max() ?? 0 }
        var lastTotal: Int64 { totals.last ?? 0 }
        func record(received: Int64, total: Int64) {
            self.received.append(received)
            self.totals.append(total)
        }
    }

    // MARK: - Catalog shape: the parts of the slot-canonical 4B brain

    /// The default brain's artifact is 2.5 GB — over GitHub's 2 GiB asset
    /// cap — so it ships as two ORDERED parts of one file. The order is
    /// load-bearing (it is the reassembly order), and `sizeBytes` is the
    /// ASSEMBLED file's size, which is what the guardrail measures.
    func testSlotCanonBrainDeclaresItsTwoOrderedParts() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        guard let entry = ModelCatalog.entry(for: id) else {
            XCTFail("the slot-canonical 4B brain is missing from the catalog")
            return
        }
        XCTAssertEqual(entry.displayName, "Brain — Qwen 4B · Nepali (gate-passing)")
        XCTAssertEqual(entry.kind, .llamaBase)
        XCTAssertEqual(entry.filename, "intent-ne-qwen4b-slotcanon-q4_k_m.gguf")
        XCTAssertEqual(entry.sizeBytes, 2_497_278_784,
                       "the ASSEMBLED size — what the v16 parts sum to "
                       + "(1_500_000_000 + 997_278_784) and what the server "
                       + "reports. The entry understated it by 32 bytes while "
                       + "the download progress and disk pre-flight measure "
                       + "against it")
        XCTAssertEqual(entry.minDeviceRAMBytes, 4_000_000_000)
        XCTAssertEqual(entry.languages, ["ne"])
        // THE REGRESSION (2026-09-14 on-device report): the entry must pin
        // the digest the two parts CONCATENATE to. Verified against the v16
        // release assets and the uploaded whole file, which agree byte for
        // byte. A placeholder is not a digest, so the strict verifier could
        // only ever answer "checksum failed" — after the user had already
        // paid for the full 2.5 GB download.
        XCTAssertEqual(entry.sha256,
                       "1662e2178c37ad7ab4f4eff9188adee90fd404fe649e23cbe421084d78f7a45f",
                       "the v16 pin is the ASSEMBLED file's digest")
        XCTAssertNotEqual(entry.sha256, ModelCatalogEntry.pendingSHA256,
                          "the v16 brain is uploaded — the entry must carry "
                          + "its real digest, not the pre-upload placeholder")
        XCTAssertLessThanOrEqual(entry.sizeBytes, ModelDownloadService.maxMultipartTotalBytes,
                                 "the default brain must fit the size guardrail")

        let parts = try XCTUnwrap(entry.downloadPartURLs)
        // THE ASSET NAMES THE RELEASE ACTUALLY PUBLISHES (2026-09-14). The
        // v16 assets carry the `-s42-` seed segment. This expectation used
        // to pin the name WITHOUT it — and GitHub answers a nonexistent
        // asset with `404` + a 9-byte `Not Found` body, which the download
        // path staged as a "part", reassembled to 18 bytes and reported as
        // a checksum failure on device 423 ms after the download started.
        // The pin must mirror the RELEASE LISTING; the entry's local
        // `filename` is an on-disk name and does not have to match.
        XCTAssertEqual(parts.map(\.lastPathComponent), [
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partaa",
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partab"
        ], "part order IS the reassembly order")
        for part in parts {
            XCTAssertTrue(part.absoluteString.hasPrefix(
                "https://github.com/anjan-poudel/elderly-ai-assistant-models/"
                + "releases/download/v16/"),
                          "parts come from the hosted v16 release: \(part)")
        }
        XCTAssertEqual(parts.first, entry.downloadURL,
                       "downloadURL mirrors part 0 for readers that predate parts")
        // Curated list leader + the auto-download default.
        XCTAssertEqual(ModelCatalog.availableBrainEntries.first?.id, id)
        XCTAssertEqual(AppCoordinator.defaultBrainModelID, id)
    }

    /// Single-file entries keep `nil` parts, and the initializer preserves
    /// whatever order the caller declared (it is not sorted or normalized).
    func testSingleFileEntriesHaveNoPartsAndPartOrderIsPreserved() {
        XCTAssertNil(ModelCatalog.entry(for: ModelCatalog.whisperBaseEn)?.downloadPartURLs)
        XCTAssertNil(ModelCatalog.entry(for: ModelCatalog.qwen3_4BInstruct)?.downloadPartURLs)
        XCTAssertNil(ModelCatalog.entry(for: ModelCatalog.whisperKitMediumV6)?.downloadPartURLs)

        let p0 = URL(string: "https://example.com/model.gguf.partaa")!
        let p1 = URL(string: "https://example.com/model.gguf.partab")!
        let p2 = URL(string: "https://example.com/model.gguf.partac")!
        let declared = ModelCatalogEntry(
            id: ModelID("synthetic-multipart"),
            kind: .llamaBase,
            displayName: "Synthetic multipart",
            filename: "model.gguf",
            downloadURL: p0,
            downloadPartURLs: [p2, p0, p1],
            sizeBytes: 3,
            sha256: String(repeating: "b", count: 64),
            minDeviceRAMBytes: 1,
            languages: [])
        XCTAssertEqual(declared.downloadPartURLs, [p2, p0, p1])
        // The parameter's default is nil: the single-file shape is what an
        // entry gets unless it says otherwise.
        XCTAssertNil(makeEntry(id: "synthetic-single", sizeBytes: 3).downloadPartURLs)
    }

    // MARK: - The size guardrail

    /// An entry declaring more than the cap is refused before a byte moves:
    /// `.failed(reason: "model too large")` plus the observability event,
    /// and the network is never touched. Parts are a delivery mechanism,
    /// not a licence to ship arbitrary sizes.
    func testMultipartEntryOverTheSizeCapIsRefusedBeforeAnyByteMoves() throws {
        let parts = [URL(string: "https://example.com/big.gguf.partaa")!,
                     URL(string: "https://example.com/big.gguf.partab")!]
        MultipartStubURLProtocol.payloads = [
            "big.gguf.partaa": Data("A".utf8),
            "big.gguf.partab": Data("B".utf8)
        ]
        let entry = makeEntry(id: "synthetic-over-cap",
                              sizeBytes: ModelDownloadService.maxMultipartTotalBytes + 1,
                              parts: parts)
        let service = ModelDownloadService(store: try makeStore(),
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
        service.start(entry)
        waitUntil("the size-cap refusal") {
            service.states[entry.id] == .failed(reason: "model too large")
        }
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_size_cap_rejected" && $0.errorCode == "too_large"
        }, "the refusal must be observable")
        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty,
                      "a refused entry must not touch the network")
        XCTAssertTrue(partTempDirectories(for: entry.id).isEmpty)
    }

    /// The cap covers the single-file shape too — a multipart-only cap
    /// would be a one-line bypass.
    func testSingleFileEntryOverTheSizeCapIsRefused() throws {
        let entry = makeEntry(id: "synthetic-over-cap-single",
                              sizeBytes: ModelDownloadService.maxMultipartTotalBytes + 1)
        let service = ModelDownloadService(store: try makeStore(),
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
        service.start(entry)
        waitUntil("the size-cap refusal") {
            service.states[entry.id] == .failed(reason: "model too large")
        }
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_size_cap_rejected" && $0.errorCode == "too_large"
        })
        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty)
    }

    /// Exactly at the cap is allowed: the guardrail is a ceiling, not a
    /// strict inequality, so the largest sanctioned artifact still ships.
    func testEntryExactlyAtTheCapIsNotRefusedByTheGuardrail() throws {
        let entry = makeEntry(id: "synthetic-at-cap",
                              sizeBytes: ModelDownloadService.maxMultipartTotalBytes)
        let service = ModelDownloadService(store: try makeStore(),
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
        service.start(entry)
        waitUntil("the flow to leave the guardrail") {
            if case .failed = service.states[entry.id] ?? .notStarted { return true }
            return service.states[entry.id] == .queued
        }
        XCTAssertNotEqual(service.states[entry.id], .failed(reason: "model too large"),
                          "the cap is inclusive")
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "download_size_cap_rejected" })
    }

    // MARK: - The warden's class budget

    /// [MODEL-WARDEN 2026-09-20] A floor value is not the last word. An entry
    /// the device-class warden refuses (here `.requiresEvictingWarmSTT` — the
    /// model fits the class alone and not beside the warm STT) must not start:
    /// the household would spend the download on an artifact the app refuses
    /// at use time, and the floor that admitted it is one number a later
    /// catalog edit can move.
    func testAnEntryTheWardenRefusesIsNotDownloaded() throws {
        let entry = makeEntry(id: "synthetic-warden-refused", sizeBytes: 1_000)
        let service = ModelDownloadService(
            store: try makeStore(),
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availabilityProvider: { _ in .unavailable(reason: .requiresEvictingWarmSTT) },
            // The [DEVSCREEN-DOWNLOAD] bypass is a SECOND axis, off by
            // default and pinned on its own below; named here so this test's
            // verdict cannot depend on a switch a developer once persisted
            // into this machine's defaults.
            ignoresFitPolicy: { false })
        service.start(entry)
        waitUntil("the warden refusal") {
            if case .failed = service.states[entry.id] ?? .notStarted { return true }
            return false
        }
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_policy_rejected"
                && $0.errorCode == ModelUnavailabilityReason.requiresEvictingWarmSTT.rawValue
        }, "the refusal must name the class reason on the bus, not fail silently")
        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty,
                      "a warden-refused entry must not touch the network")
    }

    /// The `soloOverBudget` escape hatch: a preference the household stored
    /// itself is delivered even when the class refuses it
    /// (`AppCoordinator.resolveBrainModelID` rule 1). Refusing here would
    /// leave the pick stored, the row's Download hidden and the artifact
    /// never arriving.
    func testAStoredPreferenceIsDeliveredEvenWhenTheWardenRefuses() throws {
        let entry = makeEntry(id: "synthetic-stored-pick", sizeBytes: 1_000)
        let service = ModelDownloadService(
            store: try makeStore(),
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availabilityProvider: { _ in .unavailable(reason: .overClassBudget) })
        service.start(entry, deliveringStoredPreference: true)
        waitUntil("the delivery to leave the gate") {
            service.states[entry.id] != .notStarted
        }
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "download_policy_rejected" },
                       "a stored pick is not refused by the warden gate")
        XCTAssertNotEqual(service.states[entry.id], .failed(reason:
            "the model is larger than this device class can hold"))
    }

    /// [DEVSCREEN-DOWNLOAD] THE ON DIRECTION, and the whole reason the
    /// switch exists: the hidden translation test screen's install card is a
    /// developer tool — the A/B exists to run models the policy refuses — so
    /// with `ignoreModelFitPolicyForDownloads` turned on, the class verdict
    /// must not stop the download. Same warden verdict as the refusal test
    /// above (`.requiresEvictingWarmSTT`), same flow, one switch different:
    /// the download must run all the way to a verified install.
    func testTheDebugSwitchLetsADownloadProceedThroughTheWardenRefusal() throws {
        let payload = Data("developer-tool-bytes".utf8)
        let entry = makeEntry(id: "synthetic-devscreen-bypass",
                              sizeBytes: Int64(payload.count),
                              sha: sha256Hex(payload))
        MultipartStubURLProtocol.payloads[entry.downloadURL.lastPathComponent] = payload
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = ModelDownloadService(
            store: store,
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availableBytesProvider: roomyFreeSpace,
            availabilityProvider: { _ in .unavailable(reason: .requiresEvictingWarmSTT) },
            ignoresFitPolicy: { true })

        service.start(entry)
        waitUntil("the developer download to install") {
            service.states[entry.id] == .completed
        }

        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "download_policy_rejected" },
                       "the dev-screen carve-out must not be refused by the warden gate")
        XCTAssertEqual(MultipartStubURLProtocol.requestedPaths,
                       [entry.downloadURL.lastPathComponent],
                       "the bypassed download must actually be fetched")
        let installed = try XCTUnwrap(store.path(for: entry.id),
                                      "the bypassed download must install the artifact")
        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_completed" && $0.outcome == "success"
        })
    }

    /// The carve-out is the CLASS VERDICT and nothing else. A developer
    /// download that cannot fit on the volume, or that the phone has too
    /// little RAM for, is refused for the honest reason exactly as before:
    /// the dev screen is a way around the policy that stops a household
    /// spending data on a model its device class refuses, not a way around
    /// the resource facts of the phone in the hand.
    func testTheDeveloperBypassSkipsTheClassVerdictAndNothingElse() throws {
        let refusedByPolicy: (ModelCatalogEntry) -> ModelAvailability = { _ in
            .unavailable(reason: .overClassBudget)
        }

        let diskCramped = ModelDownloadService(
            store: try makeStore(),
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availableBytesProvider: { 1 },
            availabilityProvider: refusedByPolicy,
            ignoresFitPolicy: { true })
        let onDisk = makeEntry(id: "synthetic-devscreen-disk", sizeBytes: 1_000)
        diskCramped.start(onDisk)
        waitUntil("the disk refusal") {
            if case .failed = diskCramped.states[onDisk.id] ?? .notStarted { return true }
            return false
        }
        XCTAssertEqual(diskCramped.states[onDisk.id],
                       .failed(reason: "not enough disk space"),
                       "the disk guard outranks the dev-screen carve-out")

        let onRAM = makeEntry(id: "synthetic-devscreen-ram", sizeBytes: 1_000,
                              minRAM: UInt64.max)
        let ramTight = ModelDownloadService(
            store: try makeStore(),
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availableBytesProvider: roomyFreeSpace,
            availabilityProvider: refusedByPolicy,
            ignoresFitPolicy: { true })
        ramTight.start(onRAM)
        waitUntil("the RAM refusal") {
            if case .failed = ramTight.states[onRAM.id] ?? .notStarted { return true }
            return false
        }
        XCTAssertEqual(ramTight.states[onRAM.id],
                       .failed(reason: "device does not have enough memory for this model"),
                       "the RAM floor outranks the dev-screen carve-out")

        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty,
                      "neither resource guard may reach the transport")
    }

    /// [DEVSCREEN-DOWNLOAD] THE OFF DIRECTION, and the half that keeps this a
    /// developer switch rather than a shipping behaviour: the production
    /// reader (`ModelDownloadDebugSettings.ignoresFitPolicy`) answers FALSE
    /// until a developer persists the key, and a service wired to it the way
    /// `AppCoordinator` wires the real one refuses exactly as before.
    ///
    /// The store is a fresh suite, not `UserDefaults.standard`: what is under
    /// test is the default of an UNSET key, and the process's own defaults
    /// may carry whatever a previous run on this machine persisted.
    func testTheDebugSwitchIsOffUntilPersistedSoThePolicyStillRefuses() throws {
        XCTAssertEqual(ModelDownloadDebugSettings.ignoreFitPolicyKey,
                       "modelDownload.ignoreModelFitPolicyForDownloads",
                       "the key is a persisted contract — the switch row, the "
                       + "service and the card's caption must share it")

        let suiteName = "devscreen-bypass-\(UUID().uuidString)"
        let freshStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { freshStore.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(ModelDownloadDebugSettings.ignoresFitPolicy(in: freshStore),
                       "an unset key is OFF — nobody bypasses the fit policy by default")

        let entry = makeEntry(id: "synthetic-devscreen-off", sizeBytes: 1_000)
        let service = ModelDownloadService(
            store: try makeStore(),
            observabilityBus: bus,
            sessionFactory: stubSessionFactory(),
            availabilityProvider: { _ in .unavailable(reason: .requiresEvictingWarmSTT) },
            ignoresFitPolicy: { ModelDownloadDebugSettings.ignoresFitPolicy(in: freshStore) })
        service.start(entry)
        waitUntil("the warden refusal with the switch off") {
            if case .failed = service.states[entry.id] ?? .notStarted { return true }
            return false
        }

        XCTAssertEqual(service.states[entry.id],
                       .failed(reason: "the model needs the memory the speech model is holding"))
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_policy_rejected"
                && $0.errorCode == ModelUnavailabilityReason.requiresEvictingWarmSTT.rawValue
        }, "with the switch unset the class verdict must still refuse the download")
        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty,
                      "a refused download must not touch the network")

        // Persisting the switch is what turns the bypass on — the same read
        // the service makes per call and the card's caption makes per render.
        freshStore.set(true, forKey: ModelDownloadDebugSettings.ignoreFitPolicyKey)
        XCTAssertTrue(ModelDownloadDebugSettings.ignoresFitPolicy(in: freshStore))
    }

    // MARK: - Reassembly: order and the full-file checksum

    /// Stubbed small parts: the reassembly is the parts' bytes IN ORDER,
    /// and the strict verifier the install path runs
    /// (`ModelStore.finalize` → `verifyChecksum`, streaming sha256 over
    /// the whole file) accepts that reassembly's own digest and rejects
    /// anything else — including a swapped reassembly of the same parts.
    func testStubbedPartsConcatenateInOrderAndVerifyAgainstTheFullFileSHA() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let part0 = dir.appendingPathComponent("partaa")
        let part1 = dir.appendingPathComponent("partab")
        try Data("hello ".utf8).write(to: part0)
        try Data("world".utf8).write(to: part1)
        let staged = dir.appendingPathComponent("model.gguf")

        try ModelDownloadService.concatenateParts([part0, part1], into: staged)
        let assembled = try Data(contentsOf: staged)
        XCTAssertEqual(assembled, Data("hello world".utf8),
                       "parts must land in declaration order")

        let store = try makeStore(policy: .strict)
        let digest = SHA256.hash(data: assembled)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(try store.verifyChecksum(at: staged, expected: digest),
                      "the reassembled file's own digest must verify")
        XCTAssertTrue(try store.verifyChecksum(at: staged, expected: digest.uppercased()),
                      "the comparison is case-insensitive like every other pin")
        XCTAssertFalse(try store.verifyChecksum(at: staged,
                                                expected: String(repeating: "ab", count: 32)))

        // Order is not cosmetic: a swapped reassembly is a different file
        // and must never pass the full-file checksum.
        let swapped = dir.appendingPathComponent("swapped.gguf")
        try ModelDownloadService.concatenateParts([part1, part0], into: swapped)
        XCTAssertEqual(try Data(contentsOf: swapped), Data("worldhello ".utf8),
                       "the first part carries the trailing space: swapped order "
                       + "is \"world\" + \"hello \"")
        XCTAssertFalse(try store.verifyChecksum(at: swapped, expected: digest),
                       "a swapped reassembly must fail the full-file checksum")

        // Reassembly REPLACES its destination — a leftover partial file
        // must never prefix the new download.
        try Data("garbage".utf8).write(to: staged)
        try ModelDownloadService.concatenateParts([part0], into: staged)
        XCTAssertEqual(try Data(contentsOf: staged), Data("hello ".utf8))

        // A missing part is a hard error, not a short file.
        XCTAssertThrowsError(try ModelDownloadService.concatenateParts(
            [part0, dir.appendingPathComponent("missing")], into: staged))
    }

    // MARK: - End to end through the real flow

    /// The default brain's two declared parts, fetched through the real
    /// download flow (stubbed transport), reassembled in order and
    /// installed — with CUMULATIVE progress: one running total for the
    /// whole model, never a per-part bar that resets.
    func testMultipartDownloadInstallsTheOrderedReassemblyAndReportsCumulativeProgress() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        let partAA = Data("PART-AA ".utf8)
        let partAB = Data("PART-AB".utf8)
        MultipartStubURLProtocol.payloads = [
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partaa": partAA,
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partab": partAB
        ]
        let entry = try XCTUnwrap(ModelCatalog.entry(for: id))
        // `.skip`: the v16 digest is the pre-upload placeholder, so the
        // strict path would (correctly) refuse to install. The checksum
        // behaviour itself is covered by the test above and ModelStoreTests.
        let store = try makeStore(policy: .skip)
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory(),
                                           availableBytesProvider: roomyFreeSpace)
        let progress = ProgressRecorder()
        let subscription = service.$states.sink { states in
            if case .downloading(let received, let total) = states[id] {
                progress.record(received: received, total: total)
            }
        }
        defer { subscription.cancel() }

        service.start(id)
        waitUntil("the multipart download to install") { service.states[id] == .completed }

        let installed = try XCTUnwrap(store.path(for: id),
                                      "the reassembled model must be installed")
        XCTAssertEqual(try Data(contentsOf: installed), Data("PART-AA PART-AB".utf8),
                       "the installed file is the parts' bytes in declaration order")

        let assembledBytes = Int64(partAA.count + partAB.count)
        XCTAssertEqual(progress.maxReceived, assembledBytes,
                       "progress must be cumulative across the parts")
        for total in progress.totals {
            XCTAssertTrue(total == assembledBytes || total == entry.sizeBytes,
                          "the denominator is the ASSEMBLED file's expected size "
                          + "(server-reported, else catalog-declared) — never a "
                          + "single part's (\(total))")
        }
        XCTAssertEqual(progress.lastTotal, assembledBytes,
                       "with Content-Length on every part the file's own size is known")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_completed" && $0.outcome == "success"
        })
        // The runner deletes its temp directory on its own (delegate) queue
        // right AFTER the service has the parts — i.e. after `.completed`
        // is published — so this must be a wait, not an instantaneous read,
        // or the assertion races the deletion. A real leak still fails.
        waitUntil("the part temp files to be removed") {
            self.partTempDirectories(for: id).isEmpty
        }
    }

    /// A part that fails kills the whole attempt: the remaining parts are
    /// cancelled, `.failed` is published, and neither the part temp files
    /// nor a staged file survive.
    func testFailedPartCancelsTheRestAndLeavesNothingBehind() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        MultipartStubURLProtocol.payloads = [
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partaa": Data("PART-AA ".utf8)
        ]
        MultipartStubURLProtocol.failures = [
            "intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partab": URLError(.networkConnectionLost)
        ]
        let store = try makeStore()
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory(),
                                           availableBytesProvider: roomyFreeSpace)
        service.start(id)
        waitUntil("the failed state") {
            if case .failed = service.states[id] ?? .notStarted { return true }
            return false
        }
        guard case .failed(let reason)? = service.states[id] else {
            XCTFail("a failed part must fail the download")
            return
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_failed" && $0.errorCode == "transport"
        }, "the failing part must be reported as a transport failure — "
           + "reason=\(reason), events="
           + bus.emittedEvents.map { "\($0.eventType)/\($0.errorCode ?? "-")" }
               .joined(separator: ","))
        XCTAssertNil(store.path(for: id),
                     "a failed reassembly must install nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(for: id).path),
                       "a failed reassembly must not leave a staged file")
        XCTAssertTrue(partTempDirectories(for: id).isEmpty,
                      "every part temp file must be deleted on failure")
        drainStubRequests()
    }

    /// Cancel mid-flight: the in-flight part tasks are cancelled, the temp
    /// files are deleted, and the published state is `.cancelled` — the
    /// cancellation errors are NOT reported as a download failure.
    func testCancelCancelsEveryPartAndDeletesTheTempFiles() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        MultipartStubURLProtocol.hangs = true   // parts stay in flight until cancelled
        let store = try makeStore()
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory(),
                                           availableBytesProvider: roomyFreeSpace)
        service.start(id)
        // Let the runner create its temp directory and start its tasks.
        waitUntil("the multipart attempt to start") {
            service.states[id] == .queued || !self.partTempDirectories(for: id).isEmpty
        }
        service.cancel(id)
        waitUntil("the cancelled state") { service.states[id] == .cancelled }
        XCTAssertTrue(partTempDirectories(for: id).isEmpty,
                      "cancelling must delete the part temp files")
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "download_failed" },
                       "a cancellation is not a failure")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "download_cancelled" })
        XCTAssertNil(store.path(for: id))
        drainStubRequests()
    }

    // MARK: - STRICT end to end: the path the on-device report exercised
    //
    // The tests above only reach `finalize` with `.skip` (their bytes are
    // fixtures, so a REAL digest would have to be fabricated). That left the
    // strict half of the path — the one every production download takes —
    // with no end-to-end coverage at all, which is how a 2.5 GB reassembly
    // could be verified against a string that is not a digest. These three
    // tests drive the SAME real flow with `.strict` and a genuine pin.

    /// The reported bug, reproduced and closed: two small parts (3 bytes +
    /// 2 bytes) whose ENTRY carries the assembled file's real sha256, run
    /// through the real download → concat → verify → install flow on the
    /// STRICT policy. It must install, and what lands must hash to the pin.
    func testStrictMultipartDownloadInstallsEndToEndWithTheAssembledDigest() throws {
        let partAA = Data("abc".utf8)                 // 3 bytes
        let partAB = Data("de".utf8)                  // 2 bytes
        let assembled = partAA + partAB
        let digest = sha256Hex(assembled)             // a REAL full-file sha
        let parts = [URL(string: "https://example.com/strict.gguf.partaa")!,
                     URL(string: "https://example.com/strict.gguf.partab")!]
        MultipartStubURLProtocol.payloads = [
            "strict.gguf.partaa": partAA,
            "strict.gguf.partab": partAB
        ]
        let entry = makeEntry(id: "synthetic-strict-multipart",
                              sizeBytes: Int64(assembled.count),
                              parts: parts,
                              sha: digest)
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())

        service.start(entry)
        waitUntil("the strict multipart download to install") {
            service.states[entry.id] == .completed
        }

        let installed = try XCTUnwrap(store.path(for: entry.id),
                                      "an entry whose pin matches the reassembly "
                                      + "must install — this is the flow the "
                                      + "on-device report failed")
        XCTAssertEqual(try Data(contentsOf: installed), assembled,
                       "the installed file is part 0 then part 1")
        XCTAssertEqual(sha256Hex(try Data(contentsOf: installed)), digest,
                       "the file the strict verifier promoted IS the artifact "
                       + "the entry pins")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_completed" && $0.outcome == "success"
        })
        XCTAssertFalse(bus.emittedEvents.contains {
            $0.eventType == "download_checksum_failed"
        }, "a correct reassembly must not be reported as a checksum failure")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try store.stagingURL(for: entry.id).path),
            "a successful install promotes the staged file — nothing is left behind")
        waitUntil("the part temp files to be removed") {
            self.partTempDirectories(for: entry.id).isEmpty
        }
    }

    /// The other half of the contract: the strict policy is genuinely ON for
    /// this path. One hex character of the pin changed is enough to refuse
    /// the install, publish `download_checksum_failed`, and leave neither an
    /// installed file nor a staged one — the same assertions a placeholder
    /// digest would have produced on device.
    func testStrictMultipartDownloadRefusesAWrongDigestAndInstallsNothing() throws {
        let partAA = Data("abc".utf8)
        let partAB = Data("de".utf8)
        let assembled = partAA + partAB
        let good = sha256Hex(assembled)
        var wrong = good
        let firstCharacter = wrong.removeFirst()
        wrong = (firstCharacter == "0" ? "1" : "0") + wrong
        XCTAssertEqual(wrong.count, 64)
        XCTAssertNotEqual(wrong, good)
        let parts = [URL(string: "https://example.com/wrong.gguf.partaa")!,
                     URL(string: "https://example.com/wrong.gguf.partab")!]
        MultipartStubURLProtocol.payloads = [
            "wrong.gguf.partaa": partAA,
            "wrong.gguf.partab": partAB
        ]
        let entry = makeEntry(id: "synthetic-strict-wrong-digest",
                              sizeBytes: Int64(assembled.count),
                              parts: parts,
                              sha: wrong)
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())

        service.start(entry)
        waitUntil("the strict verifier to refuse the reassembly") {
            service.states[entry.id] == .failed(reason: "checksum failed")
        }

        XCTAssertNil(store.path(for: entry.id),
                     "a reassembly that does not match the pin must install nothing")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try store.stagingURL(for: entry.id).path),
            "the rejected staging file must be cleaned up")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_checksum_failed" && $0.errorCode == "checksum"
        })
        waitUntil("the refused attempt's part temp files to be removed") {
            self.partTempDirectories(for: entry.id).isEmpty
        }
    }

    /// The reassembly streams through a 1 MB buffer, so the digest the strict
    /// verifier checks has to survive parts that straddle it (and three
    /// parts, which is the full concurrent window). A 3+2-byte fixture
    /// cannot catch a truncated or duplicated chunk; this can.
    func testStrictMultipartDownloadVerifiesARedassemblyThatStraddlesTheChunkBuffer() throws {
        let payloads = [patternedBytes(1_500_000),      // > one 1 MB read
                        patternedBytes(2),              // a mid-stream speck
                        patternedBytes(900_000)]        // tail
        let names = ["chunked.gguf.partaa", "chunked.gguf.partab", "chunked.gguf.partac"]
        let parts = names.map { URL(string: "https://example.com/\($0)")! }
        MultipartStubURLProtocol.payloads = Dictionary(
            uniqueKeysWithValues: zip(names, payloads))
        let assembled = payloads.reduce(Data(), +)
        let entry = makeEntry(id: "synthetic-strict-chunked",
                              sizeBytes: Int64(assembled.count),
                              parts: parts,
                              sha: sha256Hex(assembled))
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())

        service.start(entry)
        waitUntil("the chunked strict multipart download to install") {
            service.states[entry.id] == .completed
        }

        let installed = try XCTUnwrap(store.path(for: entry.id))
        let bytes = try Data(contentsOf: installed)
        XCTAssertEqual(bytes.count, assembled.count,
                       "every byte of every part must survive the reassembly")
        XCTAssertEqual(bytes, assembled)
        XCTAssertEqual(sha256Hex(bytes), entry.sha256,
                       "the installed file hashes to the pin")
        XCTAssertEqual(MultipartStubURLProtocol.requestedPaths.sorted(), names.sorted(),
                       "all three parts are fetched exactly once")
    }

    // MARK: - The single-file path is unchanged

    /// Regression guard for the untouched single-file flow: an entry with
    /// no parts still downloads through the proxy delegate and installs.
    func testSingleFileEntryStillDownloadsThroughTheProxyDelegate() throws {
        let id = ModelCatalog.sileroVAD
        MultipartStubURLProtocol.payloads = ["ggml-silero-v5.1.2.bin": Data("VAD".utf8)]
        let store = try makeStore()
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
        service.start(id)
        waitUntil("the single-file download to install") { service.states[id] == .completed }
        let installed = try XCTUnwrap(store.path(for: id))
        XCTAssertEqual(try Data(contentsOf: installed), Data("VAD".utf8))
        XCTAssertEqual(MultipartStubURLProtocol.requestedPaths,
                       ["ggml-silero-v5.1.2.bin"],
                       "the single-file path must fetch exactly the one URL")
    }

    // MARK: - Disk pre-flight (deterministic)

    /// The disk guard, without depending on the host's free space: a
    /// free-space reading of 1 byte refuses the entry BEFORE any transport
    /// work, with its own reason and event, and nothing is requested or
    /// left behind. (Until now the guard could only be reached by actually
    /// filling a disk, so its refusal path had no test at all — and the
    /// tests that DID depend on the host having room failed on a shared
    /// nearly-full machine: "not enough disk space" for a 2.5 GB entry.)
    func testDiskGuardRefusesBeforeTheTransportIsTouched() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        let entry = try XCTUnwrap(ModelCatalog.entry(for: id))
        let store = try makeStore()
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory(),
                                           availableBytesProvider: { 1 })

        service.start(entry)
        waitUntil("the disk refusal") {
            if case .failed = service.states[id] ?? .notStarted { return true }
            return false
        }

        XCTAssertEqual(service.states[id], .failed(reason: "not enough disk space"))
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "download_disk_full" && $0.errorCode == "disk_full"
        }, "the refusal must be reported as a disk refusal")
        XCTAssertTrue(MultipartStubURLProtocol.requestedPaths.isEmpty,
                      "the guard must refuse before a single part is requested")
        XCTAssertTrue(partTempDirectories(for: id).isEmpty,
                      "a refused download leaves no temp files")
    }

    // MARK: - Live release guard (opt-in)

    /// The check that would have caught the 2026-09-14 regression before a
    /// user paid 2.5 GB for it: every URL the catalog hands the download
    /// service must actually exist in the hosted release. GitHub answers a
    /// mistyped asset name with `404` + a 9-byte `Not Found` body, which
    /// `URLSession` delivers through `didFinishDownloadingTo` like any
    /// other transfer. The download path now refuses that explicitly, but
    /// the cheapest place to catch a renamed asset is here, against the
    /// real host, BEFORE the pin ships.
    ///
    /// Skipped by default: CI has no business reaching GitHub and a
    /// network flake must never redden the suite. Two ways to opt in,
    /// because a simulator test process does NOT inherit the environment
    /// of the shell that launched `xcodebuild` (an exported
    /// `CATALOG_LIVE_URL_CHECK=1` never reaches this code — verified):
    ///
    ///  - Xcode: set `CATALOG_LIVE_URL_CHECK=1` on the scheme's Test action
    ///    (Edit Scheme → Test → Arguments → Environment Variables).
    ///  - CLI: drop the marker in the app's data container —
    ///
    ///        P=$(xcrun simctl get_app_container booted \
    ///              com.elderlyassistant.app data)
    ///        touch "$P/Documents/catalog-live-url-check"
    ///
    ///    then run the single test as usual.
    func testLiveCatalogAssetURLsResolveAgainstTheRealRelease() async throws {
        try XCTSkipUnless(
            liveCheckIsOptedIn,
            "opt-in network check: set CATALOG_LIVE_URL_CHECK=1 on the "
            + "scheme (or drop Documents/catalog-live-url-check in the app "
            + "container) to verify every catalog asset name against the "
            + "hosted release")

        var missing: [String] = []
        for entry in ModelCatalog.all {
            let urls = [entry.downloadURL] + (entry.downloadPartURLs ?? [])
                + [entry.whisperKitZipURL, entry.coreMLEncoderDownloadURL].compactMap { $0 }
            for url in urls where Self.isPublicReleaseURL(url) {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 15
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    if !(200..<300).contains(status) {
                        missing.append("\(status) \(url.lastPathComponent) <- \(url)")
                    }
                } catch {
                    missing.append("unreachable (\(error.localizedDescription)) "
                                   + "\(url.lastPathComponent) <- \(url)")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "catalog assets missing from the release:\n"
                      + missing.joined(separator: "\n"))
    }

    /// Public-host filter for the live check: only URLs that are supposed to
    /// come off the internet are checked. Two catalog URLs are deliberately
    /// NOT public — the RFC 2606 `.invalid` documentation placeholder and
    /// the LAN dev server (`http://192.168.1.117:8765`) that serves the
    /// internal 4B Nepali build — and HEADing either can only hang until
    /// the request times out (which is exactly what the first run of this
    /// check did).
    private static func isPublicReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        if host == "localhost" || host.hasSuffix(".invalid") { return false }
        let parts = host.split(separator: ".")
        if let first = parts.first, ["127", "10", "192", "169"].contains(first) {
            return false
        }
        if parts.first == "172", parts.count > 1,
           let second = Int(parts[1]), (16...31).contains(second) {
            return false   // RFC 1918: 172.16.0.0 – 172.31.255.255
        }
        return true
    }

    /// The live check's opt-in: the scheme environment variable (the Xcode
    /// path) or a marker file in the app's own container (the CLI path —
    /// the two commands are in the test's doc comment).
    private var liveCheckIsOptedIn: Bool {
        if ProcessInfo.processInfo.environment["CATALOG_LIVE_URL_CHECK"] == "1" {
            return true
        }
        let marker = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/catalog-live-url-check")
        return FileManager.default.fileExists(atPath: marker.path)
    }
}

// MARK: - Stubbed transport

/// Serves canned bytes — or a canned failure — for every request the
/// multipart tests make, so the real download code runs with no network.
/// A request the test did not declare fails loudly rather than hanging.
final class MultipartStubURLProtocol: URLProtocol {

    static var payloads: [String: Data] = [:]
    static var failures: [String: Error] = [:]
    /// When true, requests neither respond nor fail — used to observe a
    /// download that is still in flight (the cancel test).
    static var hangs = false
    private(set) static var requestedPaths: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        payloads = [:]
        failures = [:]
        hangs = false
        requestedPaths = []
    }

    private static func record(_ path: String) -> (Data?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        requestedPaths.append(path)
        return (payloads[path], failures[path])
    }

    private static var isHanging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hangs
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        let (payload, failure) = Self.record(name)
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if Self.isHanging { return }
        guard let payload, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(payload.count)",
                           "Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
