import XCTest
@testable import ElderlyAssistant

/// T-156 — the coordinator's identity state (family-contacts-unify;
/// design-l2 §1.9, §3.6, §4.4, §4.5): the wholesale index rebuild at the
/// roster choke point, the generation-guarded verified-link refresh, the
/// foreground identity hook (wholesale invalidation + one epoch bump +
/// refresh), the duplicate-claim refusal on both write paths, and the
/// unlinked-parity anchor (an unlinked roster never fetches — it never
/// even builds the service).
///
/// Everything drives the REAL coordinator — the `ProfileCoordinatorSeamTests`
/// pattern — over an in-memory profile channel, with the verified-link
/// service replaced by a scripted fake through the T-156 init seam
/// (`systemContactLinkService:`), so no `CNContactStore` ever enters a
/// test. The family roster itself is written through the coordinator's own
/// store (the host's encrypted file channel): every test starts from
/// `clearRoster`, and the tests that stage linked contacts clear them
/// again, so the shared container is left with no links for whatever runs
/// next.
@MainActor
final class CoordinatorIdentityRefreshTests: XCTestCase {

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
    /// parks a refresh call until the test releases it — a blocking
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

    /// Scripted `SystemContactLinkReading` — the T-156 init seam.
    ///
    /// Default behaviour is the honest superset of a real pass: every
    /// stored claim on the captured roster "verifies", and the generation
    /// is the 1-based call ordinal — so a call parked on the gate always
    /// holds an OLDER generation than any call that followed it (exactly
    /// the §3.6 publication race). `verifiesLinks = false` flips a pass
    /// to the degraded shape (generation advances, no links — the record
    /// is gone or its number changed). Lock-protected: the coordinator's
    /// refresh Tasks outlive the synchronous test steps that spawn them.
    private final class FakeLinkService: SystemContactLinkReading {
        private let lock = NSLock()
        private let gate = Gate()
        private var calls = 0
        private var completions = 0
        private var invalidationsRun: [String?] = []
        private var rostersSeen: [[FamilyContact]] = []

        /// Parks call 0 until `releaseFirstCall()` — the slow-refresh half
        /// of the generation-guard race. Later calls never park.
        var holdsFirstCall = false
        /// When false, a pass returns NO links (the degraded shape).
        var verifiesLinks = true

        var refreshCalls: Int { lock.withLock { calls } }
        var completedCalls: Int { lock.withLock { completions } }
        var invalidatedIdentifiers: [String?] { lock.withLock { invalidationsRun } }
        var invalidateAllCount: Int { invalidatedIdentifiers.filter { $0 == nil }.count }
        var capturedRosters: [[FamilyContact]] { lock.withLock { rostersSeen } }

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

            if holdsFirstCall, index == 0 { await gate.wait() }

            var links: [UUID: SystemContactLink] = [:]
            var numbers: [String: [String]] = [:]
            if verifies {
                for contact in contacts {
                    guard let link = contact.systemContact else { continue }
                    links[contact.id] = link
                    numbers[link.identifier] = [link.numberKey]
                }
            }

            lock.withLock { completions += 1 }
            return VerifiedLinksSnapshot(links: links,
                                         linkedRecordNumbers: numbers,
                                         generation: UInt64(index + 1))
        }

        func photoImageData(forIdentifier identifier: String) async -> Data? { nil }

        func invalidate(identifier: String?) async {
            lock.withLock { invalidationsRun.append(identifier) }
        }

        func releaseFirstCall() async { await gate.open() }
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
    /// `CalendarShareSettingsSeamTests`/`SpotifySettingsSurfaceTests`
    /// pattern — the publishes land on the main actor through Tasks, so a
    /// bare assertion races them).
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

    /// Lets every main-queue hop already enqueued land before a
    /// must-NOT-have-happened assertion is made (the sentinel hop is
    /// queued after everything enqueued before it).
    private func settleMain() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
        await MainActor.run {}
    }

    /// Whether the `linkService` lazy slot is still UNFILLED, read through
    /// Mirror — which sees the stored Optional WITHOUT triggering the lazy
    /// initializer. A missing child or a nil Optional both read as
    /// "not built yet"; a filled Optional lifts through the dynamic cast
    /// and reads as "built".
    private func linkServiceSlotIsEmpty(_ coordinator: AppCoordinator) -> Bool {
        guard let child = Mirror(reflecting: coordinator).children
            .first(where: { $0.label == "linkService" })?.value else { return true }
        return (child as? SystemContactLinkReading) == nil
    }

    /// The resolved lazy seam, once something has read it (the cast lifts
    /// through the stored Optional — see `linkServiceSlotIsEmpty`).
    private func resolvedLinkService(_ coordinator: AppCoordinator) -> SystemContactLinkReading? {
        Mirror(reflecting: coordinator).children
            .first(where: { $0.label == "linkService" })?.value as? SystemContactLinkReading
    }

    private func storedContact(_ coordinator: AppCoordinator, id: UUID) -> FamilyContact? {
        coordinator.familyContactStore.load().first { $0.id == id }
    }

    private func claim(_ identifier: String, _ numberKey: String) -> SystemContactLink {
        SystemContactLink(identifier: identifier, numberKey: numberKey)
    }

    // MARK: - Scenario: the index is rebuilt wholesale at the roster choke point

    func testRosterMutationRebuildsThePublishedIndexWholesale() async {
        let coordinator = makeCoordinator()
        await clearRoster(coordinator)

        let id = UUID()
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita Acharya", phone: "9841000000",
            relationship: "daughter",
            nicknames: ["  Sit  ", "", "छोरी"]),
            "the add must persist")
        await waitUntil("the add republishes the roster") {
            coordinator.familyContacts.contains { $0.id == id }
        }

        // The save-path projection landed (trim, drop blanks, order kept)…
        XCTAssertEqual(coordinator.familyContacts.first { $0.id == id }?.nicknames,
                       ["Sit", "छोरी"],
                       "the widened seam must normalize the list before persisting")
        // …and the index was rebuilt from the very same assignment.
        XCTAssertEqual(coordinator.familyIndex.entry(for: id)?.normalizedNicknames,
                       [NepaliTextNormalizer.normalize("Sit"),
                        NepaliTextNormalizer.normalize("छोरी")])
        XCTAssertEqual(coordinator.familyIndex
                        .exactNicknameHolders(NepaliTextNormalizer.normalize("Sit")), [id])

        // An update re-keys the index: the replaced key must not survive.
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita Acharya", phone: "9841000000",
            relationship: "daughter", messengerHandle: nil,
            nicknames: ["Sannu"]))
        await waitUntil("the update republishes") {
            coordinator.familyIndex
                .exactNicknameHolders(NepaliTextNormalizer.normalize("Sannu")) == [id]
        }
        XCTAssertTrue(coordinator.familyIndex
                        .exactNicknameHolders(NepaliTextNormalizer.normalize("Sit")).isEmpty,
                      "the rebuilt index must not keep the replaced nickname key")

        // A removal rides the same choke point.
        coordinator.removeFamilyContact(id: id)
        await waitUntil("the removal republishes") {
            !coordinator.familyContacts.contains { $0.id == id }
        }
        XCTAssertNil(coordinator.familyIndex.entry(for: id),
                     "the removed contact must leave the index with the roster")
    }

    // MARK: - Scenario: an older generation never overwrites a newer snapshot

    func testGenerationGuardDiscardsAStalePublication() async {
        let id = UUID()
        let stale = claim("record-a", "9841000000")
        let fresh = claim("record-b", "9841000001")

        let service = FakeLinkService()
        service.holdsFirstCall = true
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        // The linked add spawns refresh A and it parks inside the fake.
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: stale))
        await waitUntil("refresh A is in flight") { service.refreshCalls == 1 }
        XCTAssertTrue(coordinator.verifiedLinks.links.isEmpty,
                      "nothing may publish while the only pass is still in flight")

        // A roster mutation spawns refresh B, which completes first.
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", messengerHandle: nil, link: fresh))
        await waitUntil("the newer generation publishes") {
            coordinator.verifiedLinks.links[id] == fresh
        }
        let generationAfterFresh = coordinator.verifiedLinks.generation
        XCTAssertGreaterThan(generationAfterFresh, 0)

        // Release A: it completes with the OLDER generation — discarded.
        await service.releaseFirstCall()
        await waitUntil("refresh A completes") { service.completedCalls == 2 }
        await settleMain()

        XCTAssertEqual(coordinator.verifiedLinks.generation, generationAfterFresh,
                       "an older generation must never overwrite a newer snapshot")
        XCTAssertEqual(coordinator.verifiedLinks.links[id], fresh,
                       "the stale pass's links must not replace the newer ones")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: no-op refresh does not bump the epoch

    func testNoOpRefreshDoesNotBumpTheEpoch() async {
        let id = UUID()
        let claim = claim("record-a", "9841000000")
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: claim))
        await waitUntil("the first snapshot publishes") {
            coordinator.verifiedLinks.links[id] == claim
        }
        let epochAfterPublish = coordinator.faceEpoch
        XCTAssertEqual(epochAfterPublish, 1,
                       "empty → one link is exactly one identity change")
        let generationBefore = coordinator.verifiedLinks.generation

        // Same links, newer generation — a no-op identity-wise.
        coordinator.refreshVerifiedLinks()
        await waitUntil("the second pass publishes") {
            coordinator.verifiedLinks.generation > generationBefore
        }
        XCTAssertEqual(coordinator.faceEpoch, epochAfterPublish,
                       "a no-op refresh must not bump the epoch")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: the duplicate-claim guard refuses both write paths

    func testDuplicateLinkClaimIsRefusedOnAddAndUpdate() async {
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        let first = UUID(), second = UUID()
        let taken = claim("record-a", "9841000000")
        XCTAssertTrue(coordinator.addFamilyContact(
            id: first, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: taken))
        await waitUntil("the first claim lands in the roster") {
            coordinator.familyContacts.contains { $0.id == first }
        }

        // ADD onto a taken identifier: refused — and NOTHING is written.
        XCTAssertFalse(coordinator.addFamilyContact(
            id: second, name: "Ram", phone: "9842000000",
            relationship: "son", link: taken),
            "a second contact claiming an owned identifier must be refused")
        XCTAssertFalse(coordinator.familyContactStore.load().contains { $0.id == second },
                       "the refused add must persist nothing")
        XCTAssertFalse(coordinator.familyContacts.contains { $0.id == second },
                       "the refused add must not republish a contact")

        // A free identifier on the same contact is ordinary data.
        XCTAssertTrue(coordinator.addFamilyContact(
            id: second, name: "Ram", phone: "9842000000",
            relationship: "son", link: claim("record-b", "9842000000")))
        await waitUntil("the second contact lands") {
            coordinator.familyContacts.contains { $0.id == second }
        }

        // UPDATE onto the taken identifier: refused, the stored claim untouched.
        XCTAssertFalse(coordinator.updateFamilyContact(
            id: second, name: "Ram", phone: "9842000000",
            relationship: "son", messengerHandle: nil, link: taken),
            "an update claiming another contact's identifier must be refused")
        XCTAssertEqual(storedContact(coordinator, id: second)?.systemContact?.identifier,
                       "record-b",
                       "a refused update must leave the stored claim unchanged")

        // The owner may re-save its OWN claim (the guard excludes itself).
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: first, name: "Sita", phone: "9841000000",
            relationship: "daughter", messengerHandle: nil, link: taken),
            "a contact re-saving its own claim is not a duplicate")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: an unlinked roster never fetches (parity anchor)

    func testAnUnlinkedRosterNeverFetchesAndNeverBuildsTheService() async {
        // NO fake: the real seam must stay UNBUILT — an unlinked roster
        // must never construct the address-book service either.
        let coordinator = makeCoordinator()
        await clearRoster(coordinator)
        XCTAssertTrue(linkServiceSlotIsEmpty(coordinator),
                      "init must not build the link service (first use, not init)")

        coordinator.refreshVerifiedLinks()   // explicit trigger on the empty roster
        let id = UUID()
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "daughter"))
        await waitUntil("the unlinked add republishes") {
            coordinator.familyContacts.contains { $0.id == id }
        }
        coordinator.refreshVerifiedLinks()   // and again with an unlinked roster
        await settleMain()

        XCTAssertTrue(linkServiceSlotIsEmpty(coordinator),
                      "an unlinked roster must never build the link service (no CNContactStore, no fetch)")
        XCTAssertEqual(coordinator.verifiedLinks, .empty,
                       "the snapshot stays the empty anchor — today's unlinked behaviour exactly")
        XCTAssertEqual(coordinator.faceEpoch, 0,
                       "no identity change, no epoch bump")
    }

    // MARK: - Scenario: the foreground hook (invalidate, bump once, refresh)

    func testForegroundIdentityRefreshInvalidatesBumpsOnceThenRefreshes() async {
        let id = UUID()
        let claim = claim("record-a", "9841000000")
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: claim))
        await waitUntil("the linked add publishes") {
            coordinator.verifiedLinks.links[id] == claim
        }
        let epochBefore = coordinator.faceEpoch
        let callsBefore = service.refreshCalls
        let generationBefore = coordinator.verifiedLinks.generation

        coordinator.refreshContactsIdentity()   // the handleScenePhase(.active) hook

        await waitUntil("the whole photo cache is invalidated") {
            service.invalidateAllCount == 1
        }
        await waitUntil("the epoch bumps") { coordinator.faceEpoch == epochBefore + 1 }
        await waitUntil("the refresh re-runs") { service.refreshCalls == callsBefore + 1 }
        await waitUntil("the foreground refresh publishes") {
            coordinator.verifiedLinks.generation > generationBefore
        }
        await settleMain()

        XCTAssertEqual(service.invalidatedIdentifiers, [nil],
                       "the foreground hook invalidates the WHOLE cache (nil), never one record")
        XCTAssertEqual(coordinator.faceEpoch, epochBefore + 1,
                       "the re-verification changed nothing — exactly one bump, never two")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: degradation never rewrites the stored claim

    func testDegradedSnapshotPublishesAndNeverRewritesTheStoredClaim() async {
        let id = UUID()
        let claim = claim("record-a", "9841000000")
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: claim))
        await waitUntil("the verified pass publishes") {
            coordinator.verifiedLinks.links[id] == claim
        }
        let epochAfterVerify = coordinator.faceEpoch
        let generationBefore = coordinator.verifiedLinks.generation

        // The record's number changed (or the record is gone): the next
        // pass publishes NO links while the generation still advances.
        service.verifiesLinks = false
        coordinator.refreshVerifiedLinks()
        await waitUntil("the degraded pass publishes") {
            coordinator.verifiedLinks.links.isEmpty
            && coordinator.verifiedLinks.generation > generationBefore
        }

        XCTAssertNil(coordinator.verifiedLinks.familyID(forIdentifier: "record-a"),
                     "a stale link is absent from the snapshot — the unlinked path serves it")
        XCTAssertEqual(storedContact(coordinator, id: id)?.systemContact, claim,
                       "degradation never rewrites the stored claim (FR-FCU-006)")
        XCTAssertEqual(coordinator.faceEpoch, epochAfterVerify + 1,
                       "the verification set changed — exactly one bump")
        await clearRoster(coordinator)
    }

    // MARK: - Scenario: the seam is built at first use, and it is ONE instance

    func testTheLinkServiceIsResolvedAtFirstUseToTheInjectedInstance() async {
        let id = UUID()
        let service = FakeLinkService()
        let coordinator = makeCoordinator(linkService: service)
        XCTAssertTrue(linkServiceSlotIsEmpty(coordinator),
                      "init must not resolve the seam")

        await clearRoster(coordinator)
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000",
            relationship: "daughter", link: claim("record-a", "9841000000")))
        await waitUntil("the first use resolves the seam") {
            !self.linkServiceSlotIsEmpty(coordinator)
        }
        XCTAssertTrue(resolvedLinkService(coordinator) === service,
                      "the resolved seam must be the one injected instance, never a clone")
        await clearRoster(coordinator)
    }

    // MARK: - Source pins (the wiring the runtime cannot reach in a unit test)

    /// `handleScenePhase` is unreachable in a unit test (`start()` trips
    /// the BGTaskScheduler platform exception — the Spotify suite's
    /// finding), so the foreground wiring and the refusal vocabulary are
    /// pinned against the source, the established split for unreachable
    /// private wiring.
    func testWiringAndVocabularyArePinnedAtTheSource() throws {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        let source = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(source.isEmpty, "the coordinator source must be readable")

        // The didSet choke point: index rebuild + refresh, one place.
        XCTAssertTrue(source.contains("familyIndex = FamilyContactIndex(family: familyContacts)"),
                      "the roster didSet must rebuild the index wholesale")
        XCTAssertTrue(source.contains("refreshVerifiedLinks()"),
                      "the roster didSet must trigger the link refresh")

        // The boot restore assignment is the launch path (the didSet covers it).
        XCTAssertTrue(source.contains("self.familyContacts = batch.contacts"),
                      "boot restore must assign through the roster choke point")

        // The foreground hook is the LAST statement of `.active` —
        // nothing inserted around it may reorder the call-dialer hooks.
        XCTAssertTrue(source.contains("refreshContactsIdentity()\n        case .background:"),
                      "handleScenePhase(.active) must end with refreshContactsIdentity()")

        // The refusal is reason-coded on the bus, PII-free by shape.
        XCTAssertTrue(source.contains("eventType: \"family_contact_write_refused\""))
        XCTAssertTrue(source.contains("errorCode: \"duplicate_claim\""))
        XCTAssertTrue(source.contains("outcome: \"rejected\""))

        // The seam is lazy (first use, not init) and the resolver reads
        // the published index.
        XCTAssertTrue(source.contains("private lazy var linkService: SystemContactLinkReading ="),
                      "the link service must be lazy — no CNContactStore at init")
        XCTAssertTrue(source.contains("indexProvider: { [weak self] in self?.familyIndex ?? .empty }"),
                      "the resolver must read the coordinator's published index")

        // The interim single-nickname shim is gone from both write paths.
        XCTAssertFalse(source.contains("nickname: String? = nil"),
                       "the single-value nickname shim must not survive T-156")
    }
}
