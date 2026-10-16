import XCTest
@testable import ElderlyAssistant

/// T-158 — the coordinator's link/unlink seam, the post-save system-photo
/// step and the link-aware missed-call names (family-contacts-unify;
/// design-l2 §1.9, §1.8, §3.5, §4.4, §4.5, §8.2; FR-FCU-001/004/005/006;
/// security advisories F3 + the review-iteration-2 R4 gate fix).
///
/// Everything drives the REAL coordinator — the
/// `CoordinatorIdentityRefreshTests` pattern — over an in-memory profile
/// channel, with the verified-link service and the T-154 photo writer
/// replaced by scripted doubles through the init seams, so no
/// `CNContactStore` ever enters a test. The family roster itself is
/// written through the coordinator's own store (the host's encrypted file
/// channel): every test starts from `clearRoster`, and every test that
/// stages a LINK clears the roster again at the end, so the shared
/// container never hands a stored link to whatever runs next (a leftover
/// link would make another suite's coordinator build the REAL service).
@MainActor
final class CoordinatorLinkUnlinkTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory stand-in for the encrypted PROFILE channel (the
    /// `CoordinatorIdentityRefreshTests` shape: raw read/write, no keychain).
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

    /// One-shot async latch (the `CoordinatorIdentityRefreshTests` Gate):
    /// parks a photo read until the test releases it.
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

    /// Scripted `SystemContactLinkReading` (the T-156/T-157 shape, plus
    /// scripted photo bytes and a parking gate): every stored claim on the
    /// captured roster "verifies" by default, the generation is the 1-based
    /// call ordinal, and each verified link's record carries exactly its
    /// `numberKey` as the reachable number — so a linked record's number
    /// can be made DIFFERENT from the contact's own phone.
    private final class FakeLinkReading: SystemContactLinkReading {
        private let lock = NSLock()
        private let gate = Gate()
        private var calls = 0
        private var invalidationsRun: [String?] = []
        private var photoReads: [String] = []
        private var scriptedPhotoBytes: [String: Data] = [:]

        /// When false, a pass returns NO links (the degraded shape).
        var verifiesLinks = true
        /// Parks every photo read until `releasePhotoCalls()` — the
        /// copy-before-clear order proof (a parked copy must not have
        /// cleared anything yet).
        var holdsPhotoCalls = false

        var refreshCalls: Int { lock.withLock { calls } }
        var invalidatedIdentifiers: [String?] { lock.withLock { invalidationsRun } }
        var photoReadIdentifiers: [String] { lock.withLock { photoReads } }

        func setPhotoBytes(_ data: Data?, for identifier: String) {
            lock.withLock { scriptedPhotoBytes[identifier] = data }
        }

        func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot {
            let (index, verifies) = lock.withLock { () -> (Int, Bool) in
                let index = calls
                calls += 1
                return (index, verifiesLinks)
            }
            var links: [UUID: SystemContactLink] = [:]
            var numbers: [String: [String]] = [:]
            if verifies {
                for contact in contacts {
                    guard let link = contact.systemContact, !link.identifier.isEmpty else { continue }
                    links[contact.id] = link
                    numbers[link.identifier] = [link.numberKey]
                }
            }
            return VerifiedLinksSnapshot(links: links,
                                         linkedRecordNumbers: numbers,
                                         generation: UInt64(index + 1))
        }

        func photoImageData(forIdentifier identifier: String) async -> Data? {
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

    private func makeCoordinator(linkService: SystemContactLinkReading? = nil,
                                 writer: SystemContactPhotoWriting? = nil) -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage(),
                       wireProfilePersonalization: false,
                       systemContactLinkService: linkService,
                       systemContactPhotoWriter: writer)
    }

    /// Empties the persisted roster through the coordinator's own remove
    /// path (each removal rides the didSet republish — and deletes the
    /// contact's app-local photo file with it). The simulator test host's
    /// family store is shared across tests in a run, so every test starts
    /// from this reset instead of assuming an empty store.
    private func clearRoster(_ coordinator: AppCoordinator,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for contact in coordinator.familyContactStore.load() {
            coordinator.removeFamilyContact(id: contact.id)
        }
        await waitUntil("the roster reset republishes", file: file, line: line) {
            coordinator.familyContacts.isEmpty
        }
    }

    /// Polls `condition` on the main actor (the house pattern — publishes
    /// land through Tasks/hops, so a bare assertion races them).
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

    private func settleMain() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
        await MainActor.run {}
    }

    private func claim(_ identifier: String, _ numberKey: String) -> SystemContactLink {
        SystemContactLink(identifier: identifier, numberKey: numberKey)
    }

    private func storedContact(_ coordinator: AppCoordinator, id: UUID) -> FamilyContact? {
        coordinator.familyContactStore.load().first { $0.id == id }
    }

    /// A record identifier unlikely to collide with the shared container's
    /// leftovers (the sysphoto cache is process-wide).
    private func recordIdentifier() -> String { "record-\(UUID().uuidString)" }

    /// The `systemContactPhotoWriter` lazy slot via Mirror — which sees the
    /// stored Optional WITHOUT triggering the lazy initializer.
    ///
    /// [T-163 first-run correction] a `lazy var`'s Mirror child is
    /// labelled `$__lazy_storage_$_<name>`, never the plain name: matching
    /// only `systemContactPhotoWriter` read every state as "empty" — the
    /// must-NOT-build pins below were vacuous. Both labels are matched.
    private func writerSlotIsEmpty(_ coordinator: AppCoordinator) -> Bool {
        let slot = Mirror(reflecting: coordinator).children
            .first { $0.label == "systemContactPhotoWriter"
                || $0.label == "$__lazy_storage_$_systemContactPhotoWriter" }?
            .value as? SystemContactPhotoWriting
        return slot == nil
    }

    // MARK: Solid-colour fixture + pixel probe (the copy is visible)

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

    private func jpegBytes(_ image: UIImage) -> Data {
        image.jpegData(compressionQuality: 0.9)!
    }

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

    /// Stages a contact, links it, and waits for the claim to verify into
    /// the published snapshot — the `link → verified reference` half of the
    /// unit's first scenario (the WRITE side is the T-156 add/update seam:
    /// design-l2 §1.9 stores a link on add/update and clears it ONLY here).
    @discardableResult
    private func linkContact(_ coordinator: AppCoordinator, id: UUID,
                             name: String = "Sita", phone: String = "9841000000",
                             photo: UIImage? = nil,
                             link: SystemContactLink,
                             file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let added = coordinator.addFamilyContact(id: id, name: name, phone: phone,
                                                 relationship: "daughter", photo: photo)
        XCTAssertTrue(added, "the add must persist", file: file, line: line)
        await waitUntil("the add republishes", file: file, line: line) {
            coordinator.familyContacts.contains { $0.id == id }
        }
        let updated = coordinator.updateFamilyContact(id: id, name: name, phone: phone,
                                                      relationship: "daughter",
                                                      messengerHandle: nil, link: link)
        XCTAssertTrue(updated, "the link write must persist", file: file, line: line)
        await waitUntil("the claim verifies into the snapshot", file: file, line: line) {
            coordinator.verifiedLinks.links[id] == link
        }
        return true
    }

    // MARK: - Scenario: link stores the verified reference; unlink clears it

    func testLinkVerifiesIntoTheSnapshotAndUnlinkClearsItNeverTouchingTheSystemRecord() async {
        let keptLink = claim(recordIdentifier(), "9841000000")
        let goneLink = claim(recordIdentifier(), "9842000000")
        let service = FakeLinkReading()
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        // Two linked contacts, so the refresh after the unlink actually
        // runs (the unlinked-roster early return is T-156's pinned shape:
        // the LAST unlink keeps the previous snapshot, recorded in notes).
        let keptID = UUID(), goneID = UUID()
        await linkContact(coordinator, id: keptID, name: "Sita", link: keptLink)
        await linkContact(coordinator, id: goneID, name: "Ram", phone: "9842000000",
                          link: goneLink)

        let generationBefore = coordinator.verifiedLinks.generation
        XCTAssertGreaterThan(generationBefore, 0,
                             "a refresh verified the claims (generation bump, scenario 1)")
        XCTAssertEqual(coordinator.verifiedLinks.links[goneID], goneLink)
        let epochBefore = coordinator.faceEpoch

        // The unlink: the stored claim is cleared, the roster republishes,
        // the refresh drops the claim from the snapshot.
        let cleared = await coordinator.setFamilyContactLink(
            id: goneID, mode: .unlinkKeepingLocalAsIs)
        XCTAssertTrue(cleared, "the unlink must report success")
        XCTAssertNil(storedContact(coordinator, id: goneID)?.systemContact,
                     "the stored claim is cleared")
        XCTAssertNil(coordinator.familyContacts.first { $0.id == goneID }?.systemContact,
                     "the published roster carries no claim")
        XCTAssertEqual(storedContact(coordinator, id: keptID)?.systemContact, keptLink,
                       "the OTHER contact's claim is untouched")
        await waitUntil("the snapshot drops the cleared claim") {
            coordinator.verifiedLinks.links[goneID] == nil
            && coordinator.verifiedLinks.links[keptID] == keptLink
            && coordinator.verifiedLinks.generation > generationBefore
        }
        XCTAssertGreaterThanOrEqual(coordinator.faceEpoch, epochBefore + 1,
                                    "an unlink is an identity change — the epoch bumps")

        // FR-FCU-005 / the only-unlink-path rule: the system record was
        // NEVER written — the write seam was not even asked for access.
        XCTAssertEqual(writer.accessRequests, 0)
        XCTAssertTrue(writer.writes.isEmpty && writer.clearedLinks.isEmpty && writer.intents.isEmpty,
                      "unlink never writes to the system record")

        await clearRoster(coordinator)
    }

    // MARK: - Scenario: the pure mode rule (design-l2 §1.9)

    func testUnlinkModeRuleIsPureAndTotal() {
        XCTAssertEqual(AppCoordinator.unlinkMode(appLocalFileExists: true,
                                                 displayedPhotoIsSystem: true),
                       .unlinkKeepingLocalAsIs)
        XCTAssertEqual(AppCoordinator.unlinkMode(appLocalFileExists: true,
                                                 displayedPhotoIsSystem: false),
                       .unlinkKeepingLocalAsIs)
        XCTAssertEqual(AppCoordinator.unlinkMode(appLocalFileExists: false,
                                                 displayedPhotoIsSystem: true),
                       .unlinkKeepingDisplayedPhotoLocally)
        XCTAssertEqual(AppCoordinator.unlinkMode(appLocalFileExists: false,
                                                 displayedPhotoIsSystem: false),
                       .unlinkKeepingLocalAsIs)
    }

    // MARK: - Scenario: copy-preserving unlink (F3)

    func testCopyModeUnlinkCopiesTheDisplayedSystemPhotoThenAssignsAndClears() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        let systemBytes = jpegBytes(solidImage(.systemRed))
        service.setPhotoBytes(systemBytes, for: record)
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        // A second linked contact keeps the post-unlink refresh running.
        await linkContact(coordinator, id: UUID(), name: "Ram", phone: "9842000000",
                          link: claim(recordIdentifier(), "9842000000"))
        let id = UUID()
        await linkContact(coordinator, id: id, name: "Sita", link: link)
        XCTAssertNil(storedContact(coordinator, id: id)?.photoFilename,
                     "no app-local file yet — the displayed photo IS the system one")
        let epochBefore = coordinator.faceEpoch

        let cleared = await coordinator.setFamilyContactLink(
            id: id, mode: .unlinkKeepingDisplayedPhotoLocally)
        XCTAssertTrue(cleared)

        // F3: the copy landed in the app-local store and was ASSIGNED to
        // photoFilename in the same record write that cleared the link.
        let stored = storedContact(coordinator, id: id)
        XCTAssertNil(stored?.systemContact, "the link is cleared after the copy")
        let copiedFilename = try? XCTUnwrap(stored?.photoFilename)
        let copiedData = coordinator.contactPhotoStore.loadData(named: copiedFilename)
        XCTAssertNotNil(copiedData, "the copied file exists in the family photo store")

        // FR-FCU-005: after the unlink the family contact still shows the
        // same photo — now served from the app-local copy (the snapshot
        // dropped the link, so the system branch is gone).
        await waitUntil("the snapshot drops the copied claim") {
            coordinator.verifiedLinks.links[id] == nil
        }
        let face = await coordinator.faceImage(for: stored!)
        XCTAssertTrue(isReddish(face), "the contact still shows the displayed (red) photo")

        XCTAssertGreaterThanOrEqual(coordinator.faceEpoch, epochBefore + 1)
        XCTAssertEqual(writer.accessRequests, 0)
        XCTAssertTrue(writer.writes.isEmpty && writer.clearedLinks.isEmpty,
                      "the copy path never writes to the system record")
        XCTAssertEqual(service.invalidatedIdentifiers, [],
                       "no system write happened — nothing to invalidate")

        await clearRoster(coordinator)
    }

    /// The F3 order pin, observed behaviourally: while the copy is parked,
    /// NOTHING has been assigned or cleared — the clear cannot precede the
    /// copy. (The source-order pin lives in the source-pin test below.)
    func testCopyModeUnlinkCannotClearBeforeTheCopyCompletes() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        service.setPhotoBytes(jpegBytes(solidImage(.systemRed)), for: record)
        service.holdsPhotoCalls = true
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        await linkContact(coordinator, id: UUID(), name: "Ram", phone: "9842000000",
                          link: claim(recordIdentifier(), "9842000000"))
        let id = UUID()
        await linkContact(coordinator, id: id, name: "Sita", link: link)

        let unlink = Task { await coordinator.setFamilyContactLink(
            id: id, mode: .unlinkKeepingDisplayedPhotoLocally) }
        await waitUntil("the copy read is in flight") {
            service.photoReadIdentifiers == [record]
        }
        await settleMain()

        // Parked: the copy has not produced a file — so neither the
        // assignment nor the clear may have happened yet.
        let parked = storedContact(coordinator, id: id)
        XCTAssertEqual(parked?.systemContact, link,
                       "the link must still be stored while the copy is in flight")
        XCTAssertNil(parked?.photoFilename,
                     "photoFilename must not be assigned before the copy landed")

        await service.releasePhotoCalls()
        let cleared = await unlink.value
        XCTAssertTrue(cleared)
        let final = storedContact(coordinator, id: id)
        XCTAssertNil(final?.systemContact)
        XCTAssertNotNil(final?.photoFilename,
                        "the copied file is assigned by the time the link clears")

        await clearRoster(coordinator)
    }

    // MARK: - Failure scenarios

    /// Copy fails (the system photo is gone): the link is NOT cleared, the
    /// state stays coherent and no phantom file appears (failure criteria
    /// 1 and 2; FR-FCU-005's never-lose rule wins over the unlink).
    func testCopyFailureRefusesToClearAndLeavesNoPhantomFile() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        service.setPhotoBytes(nil, for: record)   // the record's photo is gone
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        let id = UUID()
        await linkContact(coordinator, id: id, name: "Sita", link: link)

        let cleared = await coordinator.setFamilyContactLink(
            id: id, mode: .unlinkKeepingDisplayedPhotoLocally)
        XCTAssertFalse(cleared, "a copy that produced no file must refuse to clear")
        let after = storedContact(coordinator, id: id)
        XCTAssertEqual(after?.systemContact, link,
                       "the link is NOT cleared — still linked with the system photo")
        XCTAssertNil(after?.photoFilename,
                     "no dangling photoFilename: nothing was assigned")
        await settleMain()
        XCTAssertEqual(writer.accessRequests, 0)
        XCTAssertTrue(writer.writes.isEmpty, "no system write on the refusal path")

        await clearRoster(coordinator)
    }

    /// The stale-link scenario: the system photo is gone and the mode is
    /// the plain one — the unlink completes without crash, creates no
    /// phantom file, and leaves nothing dangling.
    func testAsIsUnlinkWithAGoneSystemPhotoCompletesWithoutAPhantomFile() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        service.setPhotoBytes(nil, for: record)
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        await linkContact(coordinator, id: UUID(), name: "Ram", phone: "9842000000",
                          link: claim(recordIdentifier(), "9842000000"))
        let id = UUID()
        await linkContact(coordinator, id: id, name: "Sita", link: link)

        let cleared = await coordinator.setFamilyContactLink(
            id: id, mode: .unlinkKeepingLocalAsIs)
        XCTAssertTrue(cleared)
        let after = storedContact(coordinator, id: id)
        XCTAssertNil(after?.systemContact)
        XCTAssertNil(after?.photoFilename,
                     "no photoFilename is invented for a gone system photo")

        await clearRoster(coordinator)
    }

    /// The explicit "remove everything" mode: the app-local file and the
    /// link are both cleared — the file only AFTER the record write (the
    /// update path's save-first sequencing).
    func testClearModeUnlinkRemovesTheAppLocalFileAndTheLink() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        service.setPhotoBytes(jpegBytes(solidImage(.systemRed)), for: record)
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        let id = UUID()
        XCTAssertTrue(coordinator.addFamilyContact(id: id, name: "Sita", phone: "9841000000",
                                                   relationship: "daughter",
                                                   photo: solidImage(.systemBlue)))
        await waitUntil("the photo add republishes") {
            coordinator.familyContacts.contains { $0.id == id }
        }
        XCTAssertTrue(coordinator.updateFamilyContact(id: id, name: "Sita", phone: "9841000000",
                                                      relationship: "daughter",
                                                      messengerHandle: nil, link: link))
        await waitUntil("the claim verifies") {
            coordinator.verifiedLinks.links[id] == link
        }
        let oldFilename = try? XCTUnwrap(storedContact(coordinator, id: id)?.photoFilename)
        XCTAssertNotNil(coordinator.contactPhotoStore.loadData(named: oldFilename))

        let cleared = await coordinator.setFamilyContactLink(
            id: id, mode: .unlinkAndClearAppLocalPhoto)
        XCTAssertTrue(cleared)
        let after = storedContact(coordinator, id: id)
        XCTAssertNil(after?.systemContact)
        XCTAssertNil(after?.photoFilename, "the record no longer points at a file")
        XCTAssertNil(coordinator.contactPhotoStore.loadData(named: oldFilename),
                     "the app-local file is deleted after the record write")

        await clearRoster(coordinator)
    }

    func testUnlinkOfAnUnknownContactReturnsFalseAndTouchesNothing() async {
        let service = FakeLinkReading()
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        let cleared = await coordinator.setFamilyContactLink(
            id: UUID(), mode: .unlinkKeepingDisplayedPhotoLocally)
        XCTAssertFalse(cleared, "no such contact")
        XCTAssertEqual(writer.accessRequests, 0)
        XCTAssertTrue(service.photoReadIdentifiers.isEmpty,
                      "an unknown contact must not even read the system bytes")
    }

    // MARK: - Scenario: the post-save system-photo step (syncSystemPhoto)

    func testSyncSystemPhotoReturnsNilForUnknownContactsAndSkipsUnlinkedOnes() async {
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: FakeLinkReading(), writer: writer)
        await clearRoster(coordinator)
        XCTAssertTrue(writerSlotIsEmpty(coordinator), "init must not build the writer")

        // No such contact → nil, nothing touched.
        let missing = await coordinator.syncSystemPhoto(forContactID: UUID(), clearing: false)
        XCTAssertNil(missing)
        XCTAssertEqual(writer.accessRequests, 0)

        // A contact with a stored but UNVERIFIED claim → .skippedNoLink;
        // the writer seam is never resolved (no CNContactStore on a
        // contact with no verified link).
        let service = FakeLinkReading()
        service.verifiesLinks = false
        let coordinator2 = makeCoordinator(linkService: service, writer: writer)
        let id = UUID()
        let added = coordinator2.addFamilyContact(id: id, name: "Sita", phone: "9841000000",
                                                  relationship: "daughter",
                                                  link: claim(recordIdentifier(), "9841000000"))
        XCTAssertTrue(added)
        await waitUntil("the unverified add republishes") {
            coordinator2.familyContacts.contains { $0.id == id }
        }
        await settleMain()
        XCTAssertTrue(coordinator2.verifiedLinks.links.isEmpty,
                      "a stored claim that fails verification is absent from the snapshot")
        let skipped = await coordinator2.syncSystemPhoto(forContactID: id, clearing: false)
        XCTAssertEqual(skipped, .skippedNoLink)
        XCTAssertEqual(writer.accessRequests, 0,
                       "no verified link → no attempt, not even an access question")
        XCTAssertTrue(writerSlotIsEmpty(coordinator2),
                      "an unlinked contact must never construct the write seam")

        await clearRoster(coordinator2)
    }

    func testSyncSystemPhotoSkipsWithoutWriteAuthorizationAndAttemptsUnderLimited() async {
        let service = FakeLinkReading()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        // Denied: no attempt at all — the honest fallback state. Each
        // coordinator learns the roster through its OWN add/link seam:
        // init deliberately starts with an empty published roster (the
        // boot phase owns the store load), so a fresh coordinator in a
        // unit test never "sees the shared store" on its own. [T-163
        // first-run correction: the original test waited on exactly that
        // impossible pickup.]
        let deniedWriter = FakeSystemContactPhotoWriter()
        deniedWriter.access = .denied
        let deniedCoordinator = makeCoordinator(linkService: service, writer: deniedWriter)
        let deniedID = UUID()
        await linkContact(deniedCoordinator, id: deniedID,
                          link: claim(recordIdentifier(), "9841000000"))
        let denied = await deniedCoordinator.syncSystemPhoto(forContactID: deniedID, clearing: false)
        XCTAssertEqual(denied, .skippedNoAuthorization(.denied))
        XCTAssertEqual(deniedWriter.accessRequests, 1)
        XCTAssertTrue(deniedWriter.writes.isEmpty)
        XCTAssertTrue(deniedWriter.intents.isEmpty, "no request is built without authorization")

        // Limited: a granted SUBSET may attempt — and the attempt goes
        // through with the real payload (the app-local photo; without one
        // the coordinator honestly reports .failed(.fetchFailed) instead
        // of ever reaching the writer).
        let limitedWriter = FakeSystemContactPhotoWriter()
        limitedWriter.access = .limited
        limitedWriter.outcome = .written
        let limitedCoordinator = makeCoordinator(linkService: service, writer: limitedWriter)
        let limitedID = UUID()
        await linkContact(limitedCoordinator, id: limitedID, photo: solidImage(.systemBlue),
                          link: claim(recordIdentifier(), "9841000000"))
        let limited = await limitedCoordinator.syncSystemPhoto(forContactID: limitedID,
                                                               clearing: false)
        XCTAssertEqual(limited, .written)
        XCTAssertEqual(limitedWriter.writes.count, 1,
                       ".limited is a readable/writable-attempt state — the attempt runs")
        await clearRoster(coordinator)
    }

    func testSyncSystemPhotoWrittenInvalidatesTheIdentifierAndBumpsTheEpoch() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        let id = UUID()
        XCTAssertTrue(coordinator.addFamilyContact(id: id, name: "Sita", phone: "9841000000",
                                                   relationship: "daughter",
                                                   photo: solidImage(.systemBlue)))
        await waitUntil("the photo add republishes") {
            coordinator.familyContacts.contains { $0.id == id }
        }
        XCTAssertTrue(coordinator.updateFamilyContact(id: id, name: "Sita", phone: "9841000000",
                                                      relationship: "daughter",
                                                      messengerHandle: nil, link: link))
        await waitUntil("the claim verifies") {
            coordinator.verifiedLinks.links[id] == link
        }
        let epochBefore = coordinator.faceEpoch

        let outcome = await coordinator.syncSystemPhoto(forContactID: id, clearing: false)
        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(writer.writes.count, 1)
        XCTAssertEqual(writer.writes.first?.link, link)
        let storedJpeg = coordinator.contactPhotoStore.loadData(
            named: storedContact(coordinator, id: id)?.photoFilename)
        XCTAssertNotNil(storedJpeg)
        XCTAssertEqual(writer.writes.first?.jpeg, storedJpeg,
                       "the payload is the app-local processed JPEG — byte-identical")
        XCTAssertEqual(service.invalidatedIdentifiers, [record],
                       ".written invalidates the identifier's photo cache")
        XCTAssertEqual(coordinator.faceEpoch, epochBefore + 1,
                       ".written bumps the epoch exactly once")
        XCTAssertTrue(writer.clearedLinks.isEmpty, "a write is not a clear")

        // The clear leg: same seam, nil payload.
        let cleared = await coordinator.syncSystemPhoto(forContactID: id, clearing: true)
        XCTAssertEqual(cleared, .written)
        XCTAssertEqual(writer.clearedLinks, [link])
        XCTAssertEqual(service.invalidatedIdentifiers, [record, record])
        XCTAssertEqual(coordinator.faceEpoch, epochBefore + 2)

        await clearRoster(coordinator)
    }

    func testSyncSystemPhotoRecordGoneAndIdentityMismatchRefreshTheLinks() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        let id = UUID()
        // The write needs an app-local payload to reach the writer seam:
        // without one the coordinator honestly reports
        // .failed(.fetchFailed) before any attempt. [T-163 first-run
        // correction: the original fixture linked a photo-less contact
        // and expected the scripted writer outcomes.]
        await linkContact(coordinator, id: id, name: "Sita", photo: solidImage(.systemBlue),
                          link: link)

        for outcome in [SystemContactPhotoWriteOutcome.recordGone,
                        .identityMismatch] {
            writer.outcome = outcome
            let callsBefore = service.refreshCalls
            let epochBefore = coordinator.faceEpoch
            let result = await coordinator.syncSystemPhoto(forContactID: id, clearing: false)
            XCTAssertEqual(result, outcome)
            await waitUntil("a degraded write outcome refreshes the links") {
                service.refreshCalls == callsBefore + 1
            }
            XCTAssertEqual(coordinator.faceEpoch, epochBefore,
                           "a failed attempt is not an identity change")
            XCTAssertTrue(service.invalidatedIdentifiers.isEmpty)
        }

        // A plain failure triggers nothing beyond its own writer event.
        writer.outcome = .failed(.saveRejected)
        let callsBefore = service.refreshCalls
        let failed = await coordinator.syncSystemPhoto(forContactID: id, clearing: false)
        XCTAssertEqual(failed, .failed(.saveRejected))
        await settleMain()
        XCTAssertEqual(service.refreshCalls, callsBefore,
                       "a save rejection is not a link-degradation trigger")

        await clearRoster(coordinator)
    }

    /// No app-local payload (the record save kept an older/no file): no
    /// attempt, and never a false success — the honest kept-on-phone state.
    func testSyncSystemPhotoWithoutAnAppLocalPayloadMakesNoAttempt() async {
        let record = recordIdentifier()
        let link = claim(record, "9841000000")
        let service = FakeLinkReading()
        let writer = FakeSystemContactPhotoWriter()
        let coordinator = makeCoordinator(linkService: service, writer: writer)
        await clearRoster(coordinator)

        let id = UUID()
        await linkContact(coordinator, id: id, name: "Sita", link: link)
        XCTAssertNil(storedContact(coordinator, id: id)?.photoFilename)

        let outcome = await coordinator.syncSystemPhoto(forContactID: id, clearing: false)
        XCTAssertEqual(outcome, .failed(.fetchFailed),
                       "no payload → the honest failure the mapping renders as kept-on-phone")
        XCTAssertTrue(writer.writes.isEmpty, "nothing was written to the system record")
        XCTAssertEqual(writer.accessRequests, 1, "the access gate legitimately ran first")

        await clearRoster(coordinator)
    }

    // MARK: - Scenario: link-aware missed-call names

    func testFamilyContactMatchingPhoneIsLinkAwareAndNeverWrongPerson() async {
        let record = recordIdentifier()
        let ownPhoneContact = UUID()
        let linkedContact = UUID()
        let ownNumber = "9841000000"
        let linkedRecordNumber = "9841222333"
        let service = FakeLinkReading()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        await linkContact(coordinator, id: linkedContact, name: "Bimala",
                          phone: "9841666777",
                          link: claim(record, linkedRecordNumber))
        XCTAssertTrue(coordinator.addFamilyContact(id: ownPhoneContact, name: "Sita",
                                                   phone: ownNumber,
                                                   relationship: "daughter"))
        await waitUntil("the second add republishes") {
            coordinator.familyContacts.contains { $0.id == ownPhoneContact }
        }

        // The contact's OWN phone wins.
        XCTAssertEqual(coordinator.familyContact(matchingPhone: ownNumber)?.id,
                       ownPhoneContact)
        // The linked record's number resolves to the FAMILY contact
        // (FR-FCU-004) — even though the contact's own phone differs.
        XCTAssertEqual(coordinator.familyContact(matchingPhone: linkedRecordNumber)?.id,
                       linkedContact)
        // An unrelated number resolves to nobody.
        XCTAssertNil(coordinator.familyContact(matchingPhone: "9800000001"))

        // Degradation: an unverified claim is absent from the snapshot, so
        // the linked number stops resolving — never the wrong person
        // (FR-FCU-006). The stored claim itself is untouched.
        service.verifiesLinks = false
        coordinator.refreshVerifiedLinks()
        let generationBefore = coordinator.verifiedLinks.generation
        await waitUntil("the degraded pass publishes") {
            coordinator.verifiedLinks.generation > generationBefore
            && coordinator.verifiedLinks.links.isEmpty
        }
        XCTAssertNil(coordinator.familyContact(matchingPhone: linkedRecordNumber),
                     "a stale claim never resolves a number")
        XCTAssertEqual(storedContact(coordinator, id: linkedContact)?.systemContact,
                       claim(record, linkedRecordNumber),
                       "degradation never rewrites the stored claim")

        await clearRoster(coordinator)
    }

    // MARK: - Source pins (the wiring a unit test cannot reach)

    /// The unlink seam's shape, its vocabulary and the F3 order are pinned
    /// against the source (comments stripped), so a reordered or rewired
    /// unlink fails this suite even where behaviour is unchanged.
    func testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource() throws {
        let source = try coordinatorSource()

        // The mode enum and the pure rule.
        XCTAssertTrue(source.contains("enum SystemContactUnlinkMode: Equatable"),
                      "the mode enum is nested in the coordinator (design-l2 §1.9)")
        for modeCase in ["case unlinkKeepingLocalAsIs",
                         "case unlinkKeepingDisplayedPhotoLocally",
                         "case unlinkAndClearAppLocalPhoto"] {
            XCTAssertTrue(source.contains(modeCase), "missing mode case: \(modeCase)")
        }
        XCTAssertTrue(source.contains(
            "static func unlinkMode(appLocalFileExists: Bool,"))

        // The unlink body, brace-balanced.
        let body = try XCTUnwrap(functionBody(containing: "func setFamilyContactLink(id:",
                                              in: source),
                                 "the unlink seam must exist")

        // F3 order: the copy precedes the assignment, the assignment
        // precedes the clear, and both precede the record write.
        let copyIndex = try XCTUnwrap(body.range(of: "copyDisplayedSystemPhotoLocally(forIdentifier:")).lowerBound
        let assignIndex = try XCTUnwrap(body.range(of: "photoFilename = newFilename")).lowerBound
        let clearIndex = try XCTUnwrap(body.range(of: "systemContact = nil")).lowerBound
        let saveIndex = try XCTUnwrap(body.range(of: "familyContactStore.save(all)")).lowerBound
        XCTAssertTrue(copyIndex < assignIndex, "the copy must precede the photoFilename assignment")
        XCTAssertTrue(assignIndex < clearIndex, "photoFilename is assigned before the link clears")
        XCTAssertTrue(clearIndex < saveIndex,
                      "assignment + clear reach the store in ONE write (the clear follows the assignment)")

        // The unlink path has no access to the write seam at all.
        for forbidden in ["writePhoto", "clearPhoto", "CNSaveRequest", "systemContactPhotoWriter"] {
            XCTAssertFalse(body.contains(forbidden),
                           "the unlink path must never touch the write seam: \(forbidden)")
        }

        // §5.2 vocabulary: the success row is the three mode tokens under
        // `contacts_link`/`unlink`; a refusal is reason-coded (the
        // claim_refused shape) with fixed codes.
        XCTAssertTrue(source.contains("eventType: \"unlink\""))
        XCTAssertTrue(source.contains("\"keeping_local_as_is\""))
        XCTAssertTrue(source.contains("\"keeping_displayed_photo_locally\""))
        XCTAssertTrue(source.contains("\"clear_app_local_photo\""))
        XCTAssertTrue(source.contains("component: \"contacts_link\""))
        XCTAssertTrue(source.contains("eventType: \"unlink_refused\""))
        XCTAssertTrue(source.contains("outcome: \"refused\""))
        XCTAssertTrue(source.contains("errorCode: reasonCode"))
        XCTAssertTrue(source.contains("emitUnlinkRefusal(reasonCode: \"copy_failed\")"))
        XCTAssertTrue(source.contains("emitUnlinkRefusal(reasonCode: \"save_failed\")"))

        // The writer seam is lazy (first use) and injected through init.
        XCTAssertTrue(source.contains(
            "private lazy var systemContactPhotoWriter: SystemContactPhotoWriting ="))
        XCTAssertTrue(source.contains("self.injectedSystemContactPhotoWriter = systemContactPhotoWriter"))

        // syncSystemPhoto's consequences (design-l2 §4.4/§4.5).
        let syncBody = try XCTUnwrap(functionBody(containing: "func syncSystemPhoto(forContactID id: UUID,",
                                                  in: source),
                                      "syncSystemPhoto must exist")
        XCTAssertTrue(syncBody.contains("SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink: true"))
        XCTAssertTrue(syncBody.contains("await service.invalidate(identifier: link.identifier)"))
        XCTAssertTrue(syncBody.contains("refreshVerifiedLinks()"))
        XCTAssertTrue(syncBody.contains("contactPhotoStore.loadData(named: contact.photoFilename)"),
                      "the payload reader is the app-local processed JPEG (design-l2 §1.9)")
    }

    /// The link-aware missed-call passes and the review-iteration-2 R4 fix
    /// in `refreshNativeMissedCallNames` (design-l2 §3.5/§6.4, §8.2) — the
    /// private wiring the unit tests cannot reach: the family pass and the
    /// dial-back share ONE lookup, the post-prompt status is RE-READ (no
    /// granted-ternary), the guard reads `allowsReading`, and the REAL
    /// access + the verified snapshot reach the resolver.
    func testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource() throws {
        let source = try coordinatorSource()

        // One lookup for both surfaces: the family pass delegates.
        let correlations = try XCTUnwrap(functionBody(containing: "func refreshMissedCallCorrelations(",
                                                      in: source))
        XCTAssertTrue(correlations.contains("familyContact(matchingPhone: row.phone)"),
                      "the family pass uses the link-aware lookup (design-l2 §8.2)")
        XCTAssertFalse(correlations.contains("MissedCallContactResolver.familyMatch(phone: row.phone"),
                       "the bare familyMatch loop must not survive in the list pass")

        let lookup = try XCTUnwrap(functionBody(containing: "func familyContact(matchingPhone phone: String)",
                                                in: source))
        let familyIndex = try XCTUnwrap(lookup.range(of: "familyMatch(phone: phone, in: familyContacts)")).lowerBound
        let linkedIndex = try XCTUnwrap(lookup.range(of: "linkedFamilyMatch(phone: phone,")).lowerBound
        XCTAssertTrue(familyIndex < linkedIndex, "familyMatch runs first, linkedFamilyMatch second")
        XCTAssertTrue(lookup.contains("snapshot: verifiedLinks"),
                      "the PUBLISHED snapshot is the only link source")

        // The R4 gate shape (:8336/:8338/:8346 in the plan's anchors).
        let native = try XCTUnwrap(functionBody(containing: "func refreshNativeMissedCallNames(",
                                                in: source))
        XCTAssertTrue(native.contains("_ = await directory.requestAccess()"))
        let requestIndex = try XCTUnwrap(native.range(of: "requestAccess()")).lowerBound
        // BOUNDED search: the pre-prompt `var access = AddressBookDirectory.access()`
        // also contains the `access = AddressBookDirectory.access()` substring, so
        // an unbounded first-match anchors on the INITIAL read and inverts the pin.
        // [T-163 first-run correction — the production shape is correct]
        let reReadIndex = try XCTUnwrap(native.range(of: "access = AddressBookDirectory.access()",
                                                     range: requestIndex..<native.endIndex),
                                        "the status must be RE-READ after the prompt").lowerBound
        XCTAssertTrue(requestIndex < reReadIndex,
                      "the status is RE-READ after the prompt (a limited sheet must not collapse to .allowed)")
        XCTAssertFalse(native.contains("granted"),
                       "the granted-ternary is gone")
        XCTAssertTrue(native.contains("guard access.allowsReading,"),
                      "the guard reads allowsReading (the granted set enumerates under .limited)")
        XCTAssertTrue(native.contains("access: access"),
                      "the resolver receives the REAL access")
        XCTAssertTrue(native.contains("snapshot: snapshot"),
                      "the verified snapshot reaches the native resolution")
        XCTAssertFalse(native.contains("access: .allowed"),
                       "no hardcoded .allowed may survive in the native pass")
    }

    // MARK: - Source access helpers

    private func coordinatorSource() throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        let source = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(source.isEmpty, "the coordinator source must be readable")
        return source
    }

    /// The brace-balanced body of the first declaration containing
    /// `signature` — comment-free source from `codeText`, so a doc comment
    /// can never satisfy a marker.
    private func functionBody(containing signature: String,
                              in source: String) -> String? {
        guard let declaration = source.range(of: signature),
              let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex)
        else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
