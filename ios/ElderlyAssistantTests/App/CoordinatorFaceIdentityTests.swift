import XCTest
import UIKit
import CryptoKit
@testable import ElderlyAssistant

/// T-157 — the coordinator's face surface (family-contacts-unify;
/// design-l1 §10.1, design-l2 §1.9, §4.4, §8.1, §8.2): the face
/// identity composition and its stability/epoch versioning, the photo
/// display precedence (system-linked photo wins, app-local next, nil
/// last), the token map and its `sysphoto:` cache keying, the identity
/// guard that drops completions resolved under a superseded identity,
/// and the source pins for the migrated call sites and the deleted sync
/// `contactPhoto(for:)`.
///
/// Everything drives the REAL coordinator — the
/// `CoordinatorIdentityRefreshTests` pattern — over an in-memory profile
/// channel, with the verified-link service replaced by a scripted fake
/// through the T-156 init seam (`systemContactLinkService:`), so no
/// `CNContactStore` ever enters a test. The family roster itself is
/// written through the coordinator's own store (the host's encrypted
/// file channel) and every test starts from `clearRoster` and clears the
/// roster again at the end, so the shared container is left empty for
/// whatever runs next (removal also deletes the photo files it wrote).
@MainActor
final class CoordinatorFaceIdentityTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory stand-in for the encrypted PROFILE channel (the
    /// `ProfileCoordinatorSeamTests` shape: raw read/write, no keychain).
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        private var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)   // this fake is raw-read only
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    /// One-shot async latch (the `CalendarShareSettingsSeamTests` Gate):
    /// parks a photo read until the test releases it — a blocking
    /// semaphore would burn a concurrency thread instead.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    /// Scripted `SystemContactLinkReading` — the T-156 init seam, widened
    /// for T-157 with scripted system-photo BYTES per record identifier
    /// and the ability to park a photo read (the slow-completion half of
    /// the identity race).
    ///
    /// Default `refresh` behaviour is the honest superset of a real pass:
    /// every stored claim on the captured roster "verifies", and the
    /// generation is the 1-based call ordinal. `verifiesLinks = false`
    /// flips a pass to the degraded shape (generation advances, no links
    /// — the record is gone or its number changed). Lock-protected: the
    /// coordinator's refresh Tasks outlive the synchronous test steps
    /// that spawn them.
    private final class FakeLinkService: SystemContactLinkReading {
        private let lock = NSLock()
        private let gate = Gate()
        private var calls = 0
        private var invalidationsRun: [String?] = []
        private var rostersSeen: [[FamilyContact]] = []
        private var scriptedPhotoBytes: [String: Data] = [:]
        private var photoReads: [String] = []

        /// When false, a pass returns NO links (the degraded shape).
        var verifiesLinks = true
        /// Parks photo reads until `releasePhotoCalls()` — a read that
        /// entered before an identity change completes after it (the
        /// stale completion the identity guard exists for).
        var holdsPhotoCalls = false

        var refreshCalls: Int { lock.withLock { calls } }
        var invalidatedIdentifiers: [String?] { lock.withLock { invalidationsRun } }
        var capturedRosters: [[FamilyContact]] { lock.withLock { rostersSeen } }
        var photoReadIdentifiers: [String] { lock.withLock { photoReads } }

        func setPhotoBytes(_ data: Data?, for identifier: String) {
            lock.withLock { scriptedPhotoBytes[identifier] = data }
        }

        func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot {
            // Scoped locking (`withLock`), never the bare lock/unlock
            // pair: both call sites below run in an async context, where
            // the unscoped calls are an error in the Swift 6 language mode.
            let (index, verifies) = lock.withLock { () -> (Int, Bool) in
                let index = calls
                calls += 1
                rostersSeen.append(contacts)
                return (index, verifiesLinks)
            }

            var links: [UUID: SystemContactLink] = [:]
            var numbers: [String: [String]] = [:]
            if verifies {
                for contact in contacts {
                    guard let link = contact.systemContact else { continue }
                    links[contact.id] = link
                    numbers[link.identifier] = [link.numberKey]
                }
            }

            return VerifiedLinksSnapshot(links: links,
                                         linkedRecordNumbers: numbers,
                                         generation: UInt64(index + 1))
        }

        func photoImageData(forIdentifier identifier: String) async -> Data? {
            // The bytes are captured at CALL time, before any parking:
            // a parked read completes with the bytes as of its entry —
            // exactly what a real fetch would have returned.
            let (bytes, holds) = lock.withLock { () -> (Data?, Bool) in
                photoReads.append(identifier)
                return (scriptedPhotoBytes[identifier], holdsPhotoCalls)
            }
            if holds { await gate.wait() }
            return bytes
        }

        func invalidate(identifier: String?) async {
            lock.withLock { invalidationsRun.append(identifier) }
        }

        func releasePhotoCalls() async { await gate.open() }
    }

    // MARK: - Helpers

    private func makeCoordinator(linkService: SystemContactLinkReading? = nil) -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage(),
                       wireProfilePersonalization: false,
                       systemContactLinkService: linkService)
    }

    /// Empties the persisted roster through the coordinator's own remove
    /// path (each removal rides the didSet republish), then waits for the
    /// published roster to reflect the empty store. The simulator test
    /// host's family store is shared across tests in a run, so every test
    /// starts from this reset instead of assuming an empty store.
    private func clearRoster(_ coordinator: AppCoordinator,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for contact in coordinator.familyContactStore.load() {
            coordinator.removeFamilyContact(id: contact.id)
        }
        await waitUntil("the roster reset republishes", file: file, line: line) {
            coordinator.familyContacts.isEmpty
        }
    }

    /// Polls `condition` on the main actor (the
    /// `CalendarShareSettingsSeamTests` pattern — the publishes land on
    /// the main actor through Tasks/DispatchQueue hops, so a bare
    /// assertion races them).
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func claim(_ identifier: String, _ numberKey: String) -> SystemContactLink {
        SystemContactLink(identifier: identifier, numberKey: numberKey)
    }

    private func contact(_ coordinator: AppCoordinator, id: UUID) -> FamilyContact? {
        coordinator.familyContacts.first { $0.id == id }
    }

    /// A record identifier unlikely to collide with anything else in the
    /// shared simulator container (the sysphoto cache is process-wide).
    private func recordIdentifier() -> String { "record-\(UUID().uuidString)" }

    // MARK: Solid-colour fixtures + pixel probes (precedence made visible)

    private func solidImage(_ color: UIColor, side: CGFloat = 96) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                               format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The shape stored system photos arrive in: encoded bytes, not a
    /// decoded image.
    private func jpegBytes(_ image: UIImage) -> Data {
        image.jpegData(compressionQuality: 0.9)!
    }

    /// The centre pixel of a rendered face, drawn into a 1×1 RGBA context.
    private func centerPixel(of image: UIImage?) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image?.cgImage else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func isReddish(_ image: UIImage?, file: StaticString = #filePath,
                           line: UInt = #line) -> Bool {
        guard let (r, g, b) = centerPixel(of: image) else {
            XCTFail("no decoded face to probe", file: file, line: line)
            return false
        }
        return r > 150 && r > g + 60 && r > b + 60
    }

    private func isGreenish(_ image: UIImage?, file: StaticString = #filePath,
                            line: UInt = #line) -> Bool {
        guard let (r, g, b) = centerPixel(of: image) else {
            XCTFail("no decoded face to probe", file: file, line: line)
            return false
        }
        return g > 120 && g > r + 50 && g > b + 50
    }

    private func isBlueish(_ image: UIImage?, file: StaticString = #filePath,
                           line: UInt = #line) -> Bool {
        guard let (r, g, b) = centerPixel(of: image) else {
            XCTFail("no decoded face to probe", file: file, line: line)
            return false
        }
        return b > 150 && b > r + 60 && b > g + 40
    }

    /// The token component of a face identity — `"<id>:<token>:<file>:<epoch>"`.
    private func tokenComponent(of identity: String) -> String {
        let parts = identity.split(separator: ":").map(String.init)
        return parts.count > 1 ? parts[1] : ""
    }

    /// The test's own sha256 computation — the token must be a hash of
    /// the resolved bytes, so the expected value is recomputed here
    /// rather than read back from the code under test.
    private func sha256HexPrefix16(of data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Scenario: face identity is stable and epoch-versioned

    func testFaceIdentityComposesIdTokenFilenameAndEpoch() async {
        let id = UUID()
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        // 1. Unlinked, no photo: "<id>:link-nil:-:<faceEpoch>".
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter"))
        await waitUntil("the unlinked add republishes") { self.contact(coordinator, id: id) != nil }
        var current = contact(coordinator, id: id)!
        let unlinkedEpoch = coordinator.faceEpoch
        let unlinkedIdentity = coordinator.faceIdentity(for: current)
        XCTAssertEqual(unlinkedIdentity, "\(id.uuidString):link-nil:-:\(unlinkedEpoch)",
                       "an unlinked photo-less face is <id>:link-nil:-:<epoch>")
        // Stable: repeated derivation returns the identical string.
        XCTAssertEqual(coordinator.faceIdentity(for: current), unlinkedIdentity,
                       "the identity must be stable without an identity change")

        // Epoch participation: the foreground hook bumps it, the identity
        // follows — and a no-op re-verification does NOT bump it.
        coordinator.refreshContactsIdentity()
        await waitUntil("the foreground hook bumps the epoch") {
            coordinator.faceEpoch == unlinkedEpoch + 1
        }
        let epochAfterForeground = coordinator.faceEpoch
        XCTAssertEqual(coordinator.faceIdentity(for: current),
                       "\(id.uuidString):link-nil:-:\(epochAfterForeground)")
        XCTAssertNotEqual(coordinator.faceIdentity(for: current), unlinkedIdentity,
                          "an epoch change must change the identity (the cache key rotates)")
        coordinator.refreshContactsIdentity()
        await waitUntil("the second foreground bump lands") {
            coordinator.faceEpoch == epochAfterForeground + 1
        }
        let epochAfterSecond = coordinator.faceEpoch
        // An UNLINKED resolve must not touch the token map: the face is
        // the initials state and the identity stays link-nil.
        let unlinkedFace = await coordinator.faceImage(for: current)
        XCTAssertNil(unlinkedFace, "no link and no file: nil, the initials avatar's cue")
        XCTAssertEqual(coordinator.faceIdentity(for: current),
                       "\(id.uuidString):link-nil:-:\(epochAfterSecond)",
                       "an unlinked resolve must never mint a token")

        // 2. Linked but not yet resolved: the token is "-" (not link-nil).
        let recordID = recordIdentifier()
        let claim = claim(recordID, "9841000000")
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            messengerHandle: nil, link: claim))
        await waitUntil("the claim verifies") { coordinator.verifiedLinks.links[id] == claim }
        current = contact(coordinator, id: id)!
        let linkedEpoch = coordinator.faceEpoch
        XCTAssertEqual(coordinator.faceIdentity(for: current),
                       "\(id.uuidString):-:-:\(linkedEpoch)",
                       "a verified link without a resolved photo is <id>:-:-:<epoch>")

        // 3. Resolved system bytes: the token becomes the 16-hex sha256
        //    prefix of those bytes — recomputed independently here.
        let bytes = jpegBytes(solidImage(.systemRed))
        service.setPhotoBytes(bytes, for: recordID)
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            messengerHandle: nil, photo: solidImage(.systemBlue)))
        await waitUntil("the photo edit republishes") {
            self.contact(coordinator, id: id)?.photoFilename != nil
        }
        current = contact(coordinator, id: id)!
        let face = await coordinator.faceImage(for: current)
        XCTAssertTrue(isReddish(face), "the resolved face must be the SYSTEM photo")
        let expectedToken = sha256HexPrefix16(of: bytes)
        let identityAfterResolve = coordinator.faceIdentity(for: current)
        XCTAssertEqual(identityAfterResolve,
                       "\(id.uuidString):\(expectedToken):\(current.photoFilename!):\(coordinator.faceEpoch)",
                       "a resolved face is <id>:<sha256-prefix>:<filename>:<epoch>")
        XCTAssertEqual(expectedToken.count, 16, "the token is a 16-hex-char prefix")
        XCTAssertEqual(tokenComponent(of: identityAfterResolve), expectedToken)
        XCTAssertEqual(expectedToken, expectedToken.lowercased(),
                       "the sha256 prefix renders lowercase, like the service's keys")
        // A removal clears the filename component back to "-".
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            messengerHandle: nil, removingPhoto: true))
        await waitUntil("the removal republishes") {
            self.contact(coordinator, id: id)?.photoFilename == nil
        }
        current = contact(coordinator, id: id)!
        XCTAssertEqual(coordinator.faceIdentity(for: current),
                       "\(id.uuidString):\(expectedToken):-:\(coordinator.faceEpoch)")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: photo display precedence

    func testSystemPhotoWinsThenDegradesToTheAppLocalPhoto() async {
        let id = UUID()
        let recordID = recordIdentifier()
        let claim = claim(recordID, "9841000000")
        let service = FakeLinkService()
        service.setPhotoBytes(jpegBytes(solidImage(.systemRed)), for: recordID)
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        // BOTH a system photo and an app-local photo exist.
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            photo: solidImage(.systemBlue), link: claim))
        await waitUntil("the linked add publishes") { coordinator.verifiedLinks.links[id] == claim }
        var current = contact(coordinator, id: id)!
        XCTAssertNotNil(current.photoFilename, "the app-local photo must be on file too")

        // (1) System-linked photo wins on BOTH accessors.
        let systemFace = await coordinator.faceImage(for: current)
        XCTAssertTrue(isReddish(systemFace),
                      "the verified link's readable system photo wins over the app-local file")
        let systemThumb = await coordinator.faceThumbnail(for: current,
                                                          diameter: 44, displayScale: 2)
        XCTAssertTrue(isReddish(systemThumb),
                      "faceThumbnail must apply the same precedence")

        // (2) The verification degrades (record gone / number changed):
        // the app-local photo serves — including the thumbnail, whose
        // sysphoto key is no longer reachable.
        service.verifiesLinks = false
        coordinator.refreshVerifiedLinks()
        await waitUntil("the degraded snapshot publishes") {
            coordinator.verifiedLinks.links.isEmpty
        }
        current = contact(coordinator, id: id)!
        let localFace = await coordinator.faceImage(for: current)
        XCTAssertTrue(isBlueish(localFace), "the app-local photo is the degrade target")
        let localThumb = await coordinator.faceThumbnail(for: current,
                                                         diameter: 44, displayScale: 2)
        XCTAssertTrue(isBlueish(localThumb))
        XCTAssertTrue(coordinator.faceIdentity(for: current).contains(":link-nil:"),
                      "an unverified link reads link-nil, never a stale token")

        // (3) Re-verified with NO system bytes scripted: the app-local
        // photo still serves (a linked record without a photo is not a
        // system face).
        service.setPhotoBytes(nil, for: recordID)
        service.verifiesLinks = true
        coordinator.refreshVerifiedLinks()
        await waitUntil("the link re-verifies") { coordinator.verifiedLinks.links[id] == claim }
        current = contact(coordinator, id: id)!
        let stillLocal = await coordinator.faceImage(for: current)
        XCTAssertTrue(isBlueish(stillLocal),
                      "a linked record with no photo degrades to the app-local file")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: no photo available

    func testNoPhotoAnywhereReturnsNilAndNeverAnotherContactsFace() async {
        let withPhoto = UUID(), withoutPhoto = UUID()
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: withPhoto, name: "Sita", phone: "9841000000", relationship: "daughter",
            photo: solidImage(.systemBlue)))
        XCTAssertTrue(coordinator.addFamilyContact(
            id: withoutPhoto, name: "Ram", phone: "9842000000", relationship: "son"))
        await waitUntil("both contacts republish") {
            coordinator.familyContacts.count == 2
        }
        let sita = contact(coordinator, id: withPhoto)!
        let ram = contact(coordinator, id: withoutPhoto)!

        // Resolve Sita's face first (fills every cache the app holds).
        let sitaThumb = await coordinator.faceThumbnail(for: sita, diameter: 44, displayScale: 2)
        XCTAssertTrue(isBlueish(sitaThumb))
        // Ram has neither a system link nor a file: nil, both accessors —
        // never Sita's face from a shared key.
        let ramFace = await coordinator.faceImage(for: ram)
        let ramThumb = await coordinator.faceThumbnail(for: ram, diameter: 44, displayScale: 2)
        XCTAssertNil(ramFace)
        XCTAssertNil(ramThumb)
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: cache invalidation on identity change

    func testNewSystemBytesChangeTheTokenAndNoStaleThumbIsServed() async {
        let id = UUID()
        let recordID = recordIdentifier()
        let claim = claim(recordID, "9841000000")
        let redBytes = jpegBytes(solidImage(.systemRed))
        let greenBytes = jpegBytes(solidImage(.systemGreen))
        let service = FakeLinkService()
        service.setPhotoBytes(redBytes, for: recordID)
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter", link: claim))
        await waitUntil("the linked add publishes") { coordinator.verifiedLinks.links[id] == claim }
        var current = contact(coordinator, id: id)!

        // First resolve fills the sysphoto cache under token(red).
        let redThumb = await coordinator.faceThumbnail(for: current, diameter: 44, displayScale: 2)
        XCTAssertTrue(isReddish(redThumb))
        let redToken = tokenComponent(of: coordinator.faceIdentity(for: current))
        XCTAssertEqual(redToken, sha256HexPrefix16(of: redBytes))

        // An EXTERNAL photo edit in Contacts.app, surfaced by the
        // foreground hook (wholesale invalidation + epoch bump).
        let epochBefore = coordinator.faceEpoch
        service.setPhotoBytes(greenBytes, for: recordID)
        coordinator.refreshContactsIdentity()
        await waitUntil("the foreground hook bumps the epoch") {
            coordinator.faceEpoch == epochBefore + 1
        }
        current = contact(coordinator, id: id)!

        // The new bytes hash differently ⇒ a NEW key ⇒ a fresh decode;
        // the red thumbnail is never served again.
        let greenThumb = await coordinator.faceThumbnail(for: current, diameter: 44, displayScale: 2)
        XCTAssertTrue(isGreenish(greenThumb),
                      "changed system bytes must produce a new token and a fresh thumbnail")
        let greenToken = tokenComponent(of: coordinator.faceIdentity(for: current))
        XCTAssertNotEqual(greenToken, redToken,
                          "the token rotates with the bytes (the cache key rotates with it)")
        XCTAssertEqual(greenToken, sha256HexPrefix16(of: greenBytes))
        await clearRoster(coordinator)
    }

    func testReplacingTheAppLocalFileChangesTheKeyAndTheFace() async {
        let id = UUID()
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            photo: solidImage(.systemBlue)))
        await waitUntil("the add republishes") { self.contact(coordinator, id: id) != nil }
        var current = contact(coordinator, id: id)!
        let blueFilename = current.photoFilename!
        let blueThumb = await coordinator.faceThumbnail(for: current, diameter: 44, displayScale: 2)
        XCTAssertTrue(isBlueish(blueThumb))

        // Replacing the stored photo KEEPS the contact id; the filename
        // component of the identity is what must carry the change, and
        // the `contact:<filename>` cache key follows it.
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            messengerHandle: nil, photo: solidImage(.systemGreen)))
        await waitUntil("the photo replacement republishes") {
            let filename = self.contact(coordinator, id: id)?.photoFilename
            return filename != nil && filename != blueFilename
        }
        current = contact(coordinator, id: id)!
        XCTAssertTrue(coordinator.faceIdentity(for: current).contains(current.photoFilename!),
                      "the new file name must appear in the identity")
        let greenThumb = await coordinator.faceThumbnail(for: current, diameter: 44, displayScale: 2)
        XCTAssertTrue(isGreenish(greenThumb),
                      "the replaced file must be decoded fresh, never served stale")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: stale-completion drop

    func testACrossAwaitIdentityChangeMakesTheCompletionStale() async {
        let id = UUID()
        let recordID = recordIdentifier()
        let claim = claim(recordID, "9841000000")
        let service = FakeLinkService()
        service.setPhotoBytes(jpegBytes(solidImage(.systemRed)), for: recordID)
        service.holdsPhotoCalls = true
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter",
            photo: solidImage(.systemBlue), link: claim))
        await waitUntil("the linked add publishes") { coordinator.verifiedLinks.links[id] == claim }
        let current = contact(coordinator, id: id)!
        let epochBefore = coordinator.faceEpoch

        // The view's pattern: capture the identity, await the face.
        let identityBefore = coordinator.faceIdentity(for: current)
        let faceTask = Task { await coordinator.faceImage(for: current) }
        await waitUntil("the system photo read is parked") {
            service.photoReadIdentifiers == [recordID]
        }

        // While the read is in flight the identity moves: the link
        // degrades (the record's number changed / the record vanished).
        service.verifiesLinks = false
        coordinator.refreshVerifiedLinks()
        await waitUntil("the degraded publication lands") {
            coordinator.verifiedLinks.links.isEmpty
        }
        await waitUntil("the publication bumped the epoch") {
            coordinator.faceEpoch == epochBefore + 1
        }
        let identityAfter = coordinator.faceIdentity(for: current)
        XCTAssertNotEqual(identityAfter, identityBefore,
                          "the identity must change across the await — otherwise the guard could not reject")

        // The parked completion returns the PRE-change system face; the
        // guard (pinned at every call site below) compares the identity
        // and abandons exactly this value.
        await service.releasePhotoCalls()
        let staleCompletion = await faceTask.value
        XCTAssertTrue(isReddish(staleCompletion),
                      "the parked read completes with the pre-change bytes — the value the guard drops")

        // A fresh resolve under the new identity serves the app-local
        // photo, which is what the user actually sees.
        let freshFace = await coordinator.faceImage(for: current)
        XCTAssertTrue(isBlueish(freshFace),
                      "after the guard drops the stale completion, the fresh resolve serves the local face")
        await clearRoster(coordinator)
    }

    // MARK: - Token/cache-key shape

    func testTokenAndCacheKeyAreHashShapedAndCollisionFree() {
        let bytesA = jpegBytes(solidImage(.systemRed))
        let bytesB = jpegBytes(solidImage(.systemGreen))

        let tokenA = AppCoordinator.systemPhotoToken(of: bytesA)
        XCTAssertEqual(tokenA, sha256HexPrefix16(of: bytesA),
                       "the token must be the 16-hex sha256 prefix of the bytes")
        XCTAssertEqual(tokenA.count, 16)
        XCTAssertEqual(tokenA, tokenA.lowercased())
        XCTAssertEqual(AppCoordinator.systemPhotoToken(of: bytesA), tokenA,
                       "the token is deterministic for the same bytes")
        XCTAssertNotEqual(AppCoordinator.systemPhotoToken(of: bytesB), tokenA,
                          "different bytes must hash differently")

        let sysKey = AppCoordinator.systemPhotoCacheKey(identifier: "record-a", token: tokenA)
        XCTAssertEqual(sysKey, "sysphoto:record-a:\(tokenA)")
        XCTAssertNotEqual(sysKey, "contact:\(UUID().uuidString).jpg",
                          "the two cache-key families can never collide")
    }

    // MARK: - Source pins (the wiring and deletion the runtime cannot reach)

    /// The view call sites and the sync-accessor deletion are pinned
    /// against the source (the Spotify/House split for platform-
    /// unreachable wiring): the four migrated sites key their `.task` on
    /// the face identity and re-check it after the await, the face
    /// methods are the only writers of the token map, and the deleted
    /// sync `contactPhoto(for:)` has no code references left anywhere.
    func testFacePathWiringAndDeletionArePinnedAtTheSource() throws {
        let iosRoot = FeatureSourceScan.iosDirectory(file: #filePath)
        let coordinatorSource = FeatureSourceScan.codeText(
            of: iosRoot.appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        let settingsSource = FeatureSourceScan.codeText(
            of: iosRoot.appendingPathComponent("ElderlyAssistant/App/SettingsView.swift"))
        let leafSource = FeatureSourceScan.codeText(
            of: iosRoot.appendingPathComponent("ElderlyAssistant/App/LeafViews.swift"))
        for source in [coordinatorSource, settingsSource, leafSource] {
            XCTAssertFalse(source.isEmpty, "every scanned source must be readable")
        }

        // The three face methods are @MainActor (the token map and the
        // identity reads are main-confined; atomic per contact by
        // construction) and the identity format is the pinned shape.
        XCTAssertTrue(coordinatorSource.contains(
            "@MainActor\n    func faceIdentity(for contact: FamilyContact) -> String"))
        XCTAssertTrue(coordinatorSource.contains("func faceIdentity(for contact: FamilyContact) -> String {"))
        XCTAssertTrue(coordinatorSource.contains(
            "\"\\(contact.id.uuidString):\\(token):\\(contact.photoFilename ?? \"-\"):\\(faceEpoch)\""),
            "the identity format is pinned: <id>:<token>:<filename|->:<faceEpoch>")
        XCTAssertTrue(coordinatorSource.contains(
            "@MainActor\n    func faceImage(for contact: FamilyContact) async -> UIImage? {"))
        XCTAssertTrue(coordinatorSource.contains(
            "@MainActor\n    func faceThumbnail(for contact: FamilyContact, diameter: CGFloat,"))
        XCTAssertTrue(coordinatorSource.contains(
            "@MainActor\n    private func resolvedSystemPhoto(for contact: FamilyContact) async -> UIImage?"))

        // The token map has exactly ONE writer, inside the @MainActor
        // face path — and it is a hash prefix, never an identifier.
        let tokenWrites = coordinatorSource.components(separatedBy: "systemPhotoTokens[contact.id] = ").count - 1
        XCTAssertEqual(tokenWrites, 1,
                       "systemPhotoTokens is written only inside the @MainActor face methods")
        XCTAssertTrue(coordinatorSource.contains("systemPhotoTokens[contact.id] = Self.systemPhotoToken(of: data)"))

        // The sysphoto cache key family, composed in one place.
        XCTAssertTrue(coordinatorSource.contains("\"sysphoto:\\(identifier):\\(token)\""))

        // The four migrated call sites: identity-keyed tasks + the
        // post-await identity re-check (the guard is the guarantee —
        // cancellation is best-effort).
        XCTAssertTrue(settingsSource.contains(".task(id: faceIdentities)"))
        XCTAssertTrue(settingsSource.contains(".task(id: storedFaceIdentity)"))
        XCTAssertTrue(leafSource.contains(".task(id: coordinator.faceIdentity(for: contact))"))
        XCTAssertTrue(leafSource.contains(".task(id: resultFaceKey)"))
        let guardCount = (settingsSource.components(
            separatedBy: "coordinator.faceIdentity(for: contact) == identity").count - 1)
            + (leafSource.components(
                separatedBy: "coordinator.faceIdentity(for: contact) == identity").count - 1)
        XCTAssertEqual(guardCount, 4,
                       "every migrated call site (2 in SettingsView, 2 in LeafViews) re-checks the identity after its await")

        // The §8.1 deletion is compile-and-scan verified: no CODE
        // reference to the sync accessor survives anywhere in the app
        // (comments are already stripped by `codeText`).
        for file in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant") {
            let text = FeatureSourceScan.codeText(of: file)
            XCTAssertFalse(text.contains("contactPhoto(for"),
                           "the deleted sync accessor must have no code references: "
                           + FeatureSourceScan.relativePath(of: file))
            XCTAssertFalse(text.contains("func contactPhoto(for"),
                           "the sync contactPhoto(for:) resolver must stay deleted: "
                           + FeatureSourceScan.relativePath(of: file))
        }

        // ViewCaches carries the key-family invalidation contract as a
        // DOC note (§8.2) — prose, so it is read from the raw file.
        let viewCachesRaw = try String(contentsOf: iosRoot.appendingPathComponent(
            "ElderlyAssistant/App/ViewCaches.swift"), encoding: .utf8)
        XCTAssertTrue(viewCachesRaw.contains("sysphoto:"),
                      "ViewCaches documents the sysphoto: key family (design-l2 §8.2)")
        XCTAssertTrue(viewCachesRaw.contains("contact:<filename>"),
                      "ViewCaches documents the app-local key family beside it")
    }
}
