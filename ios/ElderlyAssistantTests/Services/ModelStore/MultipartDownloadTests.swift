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

    private func makeStore(policy: ModelChecksumPolicy = .skip) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: policy)
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

    private func makeEntry(id: String, sizeBytes: Int64,
                           parts: [URL]? = nil) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: ModelID(id),
            kind: .llamaBase,
            displayName: "Synthetic \(id)",
            filename: "\(id).gguf",
            downloadURL: parts?.first ?? URL(string: "https://example.com/\(id).gguf")!,
            downloadPartURLs: parts,
            sizeBytes: sizeBytes,
            sha256: String(repeating: "a", count: 64),
            minDeviceRAMBytes: 1,
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
        XCTAssertEqual(entry.sizeBytes, 2_497_278_752)
        XCTAssertEqual(entry.minDeviceRAMBytes, 4_000_000_000)
        XCTAssertEqual(entry.languages, ["ne"])
        XCTAssertEqual(entry.sha256, ModelCatalogEntry.pendingSHA256,
                       "the digest lands with the v16 upload — the entry must "
                       + "carry the clearly-marked placeholder, never a "
                       + "fabricated 64-hex pin")
        XCTAssertLessThanOrEqual(entry.sizeBytes, ModelDownloadService.maxMultipartTotalBytes,
                                 "the default brain must fit the size guardrail")

        let parts = try XCTUnwrap(entry.downloadPartURLs)
        XCTAssertEqual(parts.map(\.lastPathComponent), [
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partaa",
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partab"
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
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partaa": partAA,
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partab": partAB
        ]
        let entry = try XCTUnwrap(ModelCatalog.entry(for: id))
        // `.skip`: the v16 digest is the pre-upload placeholder, so the
        // strict path would (correctly) refuse to install. The checksum
        // behaviour itself is covered by the test above and ModelStoreTests.
        let store = try makeStore(policy: .skip)
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
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
        XCTAssertTrue(partTempDirectories(for: id).isEmpty,
                      "a completed reassembly must leave no part temp files behind")
    }

    /// A part that fails kills the whole attempt: the remaining parts are
    /// cancelled, `.failed` is published, and neither the part temp files
    /// nor a staged file survive.
    func testFailedPartCancelsTheRestAndLeavesNothingBehind() throws {
        let id = ModelCatalog.intentQwen4BSlotCanon
        MultipartStubURLProtocol.payloads = [
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partaa": Data("PART-AA ".utf8)
        ]
        MultipartStubURLProtocol.failures = [
            "intent-ne-qwen4b-slotcanon-q4_k_m.gguf.partab": URLError(.networkConnectionLost)
        ]
        let store = try makeStore()
        let service = ModelDownloadService(store: store,
                                           observabilityBus: bus,
                                           sessionFactory: stubSessionFactory())
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
        })
        XCTAssertNil(store.path(for: id),
                     "a failed reassembly must install nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURL(for: id).path),
                       "a failed reassembly must not leave a staged file")
        XCTAssertTrue(partTempDirectories(for: id).isEmpty,
                      "every part temp file must be deleted on failure")
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
                                           sessionFactory: stubSessionFactory())
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
