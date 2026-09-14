import XCTest
import CryptoKit
import Darwin
@testable import ElderlyAssistant

/// The 2026-09-14 on-device report, reproduced over a REAL socket.
///
/// Device log:
/// ```
/// [20:57:27.316] download_started state=intent-ne-qwen4b-slotcanon-q4km
/// [20:57:27.739] finalize_checksum_mismatch errorCode=checksum
/// [20:57:27.739] download_checksum_failed
/// ```
/// 423 ms between "started" and "checksum" for a 2.5 GB two-part download,
/// with no progress in between: no part was ever fetched, yet the flow ran
/// the reassembly + verifier and reported a checksum verdict.
///
/// WHY: `URLSessionDownloadTask` calls `didFinishDownloadingTo` for ANY
/// completed transfer — an HTTP ERROR PAGE INCLUDED. GitHub answers a
/// mistyped asset name with `404` + a 9-byte `Not Found` body, so both
/// "parts" landed instantly, concatenated into 18 bytes, and `finalize`
/// blamed the checksum.
///
/// These tests run the SHIPPED `ModelDownloadService.start(_ entry:)` path
/// — the runner, the reassembly, the strict verifier, the install — against
/// a loopback HTTP server serving real bytes and real failures, so the
/// transport behaviour a device sees (not a URLProtocol's idea of it) is
/// what the assertions cover. Loopback is exempt from ATS.
final class MultipartDownloadLoopbackTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!
    private var server: LoopbackPartServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-loopback-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        server = try LoopbackPartServer()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeStore(policy: ModelChecksumPolicy,
                           resolving entry: ModelCatalogEntry) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: policy,
                       entryProvider: { id in
                           id == entry.id ? entry : ModelCatalog.entry(for: id)
                       })
    }

    /// The service's own session seam, wired for a loopback server: no disk
    /// cache (a cached error page would poison the next test) and no
    /// connectivity wait (an unreachable part must fail fast, not hang).
    /// Everything the tests then exercise is the shipped download code.
    private func makeService(store: ModelStore) -> ModelDownloadService {
        ModelDownloadService(store: store, observabilityBus: bus, sessionFactory: {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForResource = 60
            return URLSession(configuration: config)
        })
    }

    private func patternedBytes(_ count: Int, seed: Int) -> Data {
        Data((0..<count).map { UInt8(($0 + seed) % 251) })
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeMultipartEntry(id: ModelID, parts: [URL], sha: String,
                                    sizeBytes: Int64) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            kind: .llamaBase,
            displayName: "Loopback \(id.rawValue)",
            filename: "\(id.rawValue).gguf",
            downloadURL: parts[0],
            downloadPartURLs: parts,
            sizeBytes: sizeBytes,
            sha256: sha,
            minDeviceRAMBytes: 1,
            languages: [])
    }

    private func makeSingleFileEntry(id: ModelID, url: URL, sha: String) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            kind: .llamaBase,
            displayName: "Loopback \(id.rawValue)",
            filename: "\(id.rawValue).gguf",
            downloadURL: url,
            sizeBytes: 4096,
            sha256: sha,
            minDeviceRAMBytes: 1,
            languages: [])
    }

    /// Spins the run loop until the condition holds (service state publishes
    /// hop through `DispatchQueue.main.async`).
    @discardableResult
    private func waitUntil(_ description: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let met = condition()
        XCTAssertTrue(met, "timed out waiting for \(description)")
        return met
    }

    private func state(_ service: ModelDownloadService, _ id: ModelID) -> ModelDownloadState {
        service.states[id] ?? .notStarted
    }

    private func failureReason(_ service: ModelDownloadService, _ id: ModelID) -> String? {
        if case let .failed(reason) = state(service, id) { return reason }
        return nil
    }

    private func waitForFailed(_ service: ModelDownloadService, _ id: ModelID,
                               _ description: String) {
        waitUntil(description) {
            if case .failed = state(service, id) { return true }
            return false
        }
    }

    private func events(_ eventType: String) -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.eventType == eventType }
    }

    /// No checksum verdict may be published when nothing was fetched — that
    /// misdiagnosis is the whole regression.
    private func assertNoChecksumVerdict() {
        XCTAssertTrue(events("download_checksum_failed").isEmpty,
                      "a download that transferred no part bytes must not be "
                      + "reported as a checksum failure")
        XCTAssertTrue(bus.emittedEvents.allSatisfy { $0.eventType != "finalize_checksum_mismatch" },
                      "the verifier must never run on an empty reassembly")
    }

    // MARK: - The green half: a two-part download that really transfers

    /// Two 64 KB parts over a live socket, the real `start(_:)` path, the
    /// strict checksum policy: the parts must be fetched, concatenated IN
    /// ORDER, verified against the assembled digest and installed.
    func testLiveTwoPartDownloadAssemblesVerifiesAndInstalls() throws {
        let id = ModelID("loopback-multipart-happy")
        let path0 = "/\(id.rawValue).partaa"
        let path1 = "/\(id.rawValue).partab"
        let part0 = patternedBytes(64 * 1024, seed: 3)
        let part1 = patternedBytes(64 * 1024, seed: 200)
        XCTAssertNotEqual(part0, part1, "the two parts must be distinguishable")
        server.setReply(.ok(part0), for: path0)
        server.setReply(.ok(part1), for: path1)

        let entry = makeMultipartEntry(
            id: id,
            parts: [server.url(for: path0), server.url(for: path1)],
            sha: sha256Hex(part0 + part1),
            sizeBytes: Int64(part0.count + part1.count))
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = makeService(store: store)

        service.start(entry)
        waitUntil("the two-part download to install") {
            if case .completed = state(service, id) { return true }
            return false
        }

        XCTAssertEqual(Set(server.requestedPaths), Set([path0, path1]),
                       "both parts are fetched, each exactly once")
        let installed = try XCTUnwrap(store.path(for: id),
                                     "the verified reassembly must be installed")
        XCTAssertEqual(try Data(contentsOf: installed), part0 + part1,
                       "the parts concatenate in catalog order")
        XCTAssertEqual(events("download_completed").count, 1)
        assertNoChecksumVerdict()
    }

    // MARK: - The reproduction: part URLs that carry no artifact

    /// THE REPRODUCER (this test fails before the fix): both part URLs answer
    /// 404 with a 9-byte body, exactly as the v16 release did for the
    /// mistyped asset name. The old code staged the two error pages,
    /// "reassembled" them and published `download_checksum_failed` — the
    /// device's 423 ms phantom checksum failure. The failure must instead
    /// name the part and the HTTP status.
    func testLivePartHTTP404FailsFastAsPartHTTPErrorNotChecksum() throws {
        let id = ModelID("loopback-multipart-404")
        // Unregistered paths get the server's 404 ("Not Found", 9 bytes) —
        // byte-for-byte what GitHub returns for a mistyped asset name.
        let entry = makeMultipartEntry(
            id: id,
            parts: [server.url(for: "/\(id.rawValue).partaa"),
                    server.url(for: "/\(id.rawValue).partab")],
            sha: String(repeating: "c", count: 64),
            sizeBytes: 4096)
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = makeService(store: store)

        service.start(entry)
        waitForFailed(service, id, "the 404 to fail the download")

        let httpErrors = events("download_part_http_error")
        XCTAssertEqual(httpErrors.count, 1, "exactly one explicit part failure")
        XCTAssertEqual(httpErrors.first?.errorCode, "part_http_error")
        XCTAssertEqual(httpErrors.first?.metadata["http_status"], "404",
                       "the log must carry the status, not just 'checksum'")
        // WHICH part reports first is a race — both URLs 404 and their two
        // tasks run concurrently; only the first terminal event is
        // published. The contract is that the log names a configured part.
        XCTAssertTrue(["0", "1"].contains(httpErrors.first?.metadata["part"] ?? ""),
                      "the log must name the failing part, got "
                      + "\(httpErrors.first?.metadata["part"] ?? "nil")")
        let reason = try XCTUnwrap(failureReason(service, id))
        XCTAssertTrue(reason.contains("404"),
                      "the user-visible reason names the status: \(reason)")
        assertNoChecksumVerdict()
        XCTAssertNil(store.path(for: id), "nothing installs")
    }

    /// A 2xx that carried no bytes is not a part either: fail as an empty
    /// fetch, with the part named, instead of assembling a short file and
    /// letting the verifier answer "checksum".
    func testLiveEmptyPartFailsFastAsPartEmptyNotChecksum() throws {
        let id = ModelID("loopback-multipart-empty")
        let path0 = "/\(id.rawValue).partaa"
        let path1 = "/\(id.rawValue).partab"
        server.setReply(.ok(Data()), for: path0)
        server.setReply(.ok(Data()), for: path1)

        let entry = makeMultipartEntry(
            id: id,
            parts: [server.url(for: path0), server.url(for: path1)],
            sha: String(repeating: "d", count: 64),
            sizeBytes: 4096)
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = makeService(store: store)

        service.start(entry)
        waitForFailed(service, id, "the empty parts to fail the download")

        let emptyEvents = events("download_part_empty")
        XCTAssertEqual(emptyEvents.count, 1, "exactly one explicit empty-part failure")
        XCTAssertEqual(emptyEvents.first?.errorCode, "part_empty")
        // Both parts are empty 200s, so which one reports first is a race;
        // the event and the user-visible reason must name the SAME part.
        let part = try XCTUnwrap(emptyEvents.first?.metadata["part"])
        XCTAssertTrue(["0", "1"].contains(part),
                      "the log must name the failing part, got \(part)")
        let reason = try XCTUnwrap(failureReason(service, id))
        XCTAssertTrue(reason.contains("part \(part) yielded 0 bytes"),
                      "the user-visible reason names the empty part \(part): \(reason)")
        assertNoChecksumVerdict()
        XCTAssertNil(store.path(for: id), "nothing installs")
    }

    /// An unreachable part URL (nothing listening on the port) is a
    /// transport failure and must be reported as one — quickly, and never as
    /// a checksum verdict.
    func testLiveUnreachablePartURLFailsFastAsTransport() throws {
        let id = ModelID("loopback-multipart-unreachable")
        let deadPort = try closedLoopbackPort()
        let entry = makeMultipartEntry(
            id: id,
            parts: [URL(string: "http://127.0.0.1:\(deadPort)/\(id.rawValue).partaa")!,
                    URL(string: "http://127.0.0.1:\(deadPort)/\(id.rawValue).partab")!],
            sha: String(repeating: "e", count: 64),
            sizeBytes: 4096)
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = makeService(store: store)

        service.start(entry)
        waitForFailed(service, id, "the refused connection to fail the download")

        XCTAssertEqual(events("download_failed").first?.errorCode, "transport")
        assertNoChecksumVerdict()
        XCTAssertNil(store.path(for: id), "nothing installs")
    }

    /// The SAME hole in the single-file path: a 404 error page must not be
    /// staged, checksummed and reported as a corrupt download.
    func testLiveSingleFileHTTPErrorPageFailsFast() throws {
        let id = ModelID("loopback-single-404")
        let entry = makeSingleFileEntry(
            id: id,
            url: server.url(for: "/\(id.rawValue).gguf"),
            sha: String(repeating: "f", count: 64))
        let store = try makeStore(policy: .strict, resolving: entry)
        let service = makeService(store: store)

        service.start(entry)
        waitForFailed(service, id, "the single-file 404 to fail the download")

        let httpErrors = events("download_http_error")
        XCTAssertEqual(httpErrors.count, 1)
        XCTAssertEqual(httpErrors.first?.errorCode, "http_error")
        XCTAssertEqual(httpErrors.first?.metadata["http_status"], "404")
        assertNoChecksumVerdict()
        XCTAssertNil(store.path(for: id), "nothing installs")
    }

    // MARK: - Helpers

    /// Binds an ephemeral loopback port and closes it again, so connecting
    /// is REFUSED ("nothing is listening") rather than filtered.
    private func closedLoopbackPort() throws -> UInt16 {
        let probe = try LoopbackPartServer()
        let port = probe.port
        probe.stop()
        return port
    }
}

// MARK: - Loopback HTTP server

/// A minimal HTTP/1.1 server on 127.0.0.1 (ephemeral port), serving canned
/// bytes — or a canned HTTP failure — for every path, so `URLSession`'s real
/// download tasks (and their real delegate semantics) are what the download
/// service talks to. Both C-level and URLProtocol-level stubbing were
/// deliberately avoided: neither can reproduce "the server answered 404 and
/// URLSession called `didFinishDownloadingTo` with the error page".
final class LoopbackPartServer {

    struct Reply {
        let status: Int
        let body: Data

        static func ok(_ body: Data) -> Reply { Reply(status: 200, body: body) }
        /// GitHub's answer to a mistyped release asset name, to the byte.
        static func notFound() -> Reply {
            Reply(status: 404, body: Data("Not Found".utf8))
        }

        var reason: String {
            switch status {
            case 200: return "OK"
            case 404: return "Not Found"
            default: return "Status"
            }
        }
    }

    enum ServerError: Error {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    let port: UInt16
    private let baseURL: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var stopped = false
    private(set) var requestedPaths: [String] = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // Darwin raises SIGPIPE on a write to a peer that went away (a
        // cancelled download task, a client that closed early). A test
        // process must not die for that.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // ephemeral
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let code = errno; close(fd); throw ServerError.bind(code) }
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw ServerError.listen(code) }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &actualLength)
            }
        }
        guard named == 0 else { let code = errno; close(fd); throw ServerError.bind(code) }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        self.baseURL = "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))"
        // Every stored property is set above — safe to hand `self` to a thread.
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "loopback-part-server"
        thread.start()
    }

    deinit { stop() }

    /// Registers the reply for `path`. Unregistered paths answer 404.
    func setReply(_ reply: Reply, for path: String) {
        lock.lock()
        replies[path] = reply
        lock.unlock()
    }

    func url(for path: String) -> URL {
        URL(string: baseURL + path)!
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        shutdown(listenFD, SHUT_RDWR)   // unblocks the accept loop
        close(listenFD)
    }

    private func serve() {
        while true {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listenFD, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break   // the listener was stopped
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))

        // Read the request head; our clients only ever issue bare GETs.
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil, head.count < 16_384 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            head.append(contentsOf: buffer[0..<count])
        }

        let reply = cachedReply(for: Self.path(in: head))
        var payload = Data(("HTTP/1.1 \(reply.status) \(reply.reason)\r\n"
                            + "Content-Length: \(reply.body.count)\r\n"
                            + "Content-Type: application/octet-stream\r\n"
                            + "Connection: close\r\n\r\n").utf8)
        payload.append(reply.body)
        Self.write(payload, to: client)
    }

    private func cachedReply(for path: String) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        requestedPaths.append(path)
        return replies[path] ?? .notFound()
    }

    private static func path(in head: Data) -> String {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else { return "/" }
        let fields = requestLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1]) : "/"
    }

    private static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = send(fd, base, remaining, 0)
                if written <= 0 { return }
                base = base.advanced(by: written)
                remaining -= written
            }
        }
    }
}
