import Contacts
import Dispatch
import XCTest
@testable import ElderlyAssistant

/// `SystemContactLinkService` — verified-link snapshots, stale-link
/// degradation, the single-flight drain and the system-photo byte cache
/// (family-contacts-unify T-149; design-l2 §1.3, §4.2, §4.3, §5.2).
///
/// Everything is driven through the `SystemContactReading` seam: `CNContactStore`
/// is not constructible or fakeable in unit tests, so the fake below scripts
/// the address book. Records are built as `CNMutableContact`s — a REAL
/// `CNContact` subclass whose `identifier` the framework assigns per instance
/// (it is get-only; the tests read it back and build the stored link from it,
/// exactly as the wizard does at link time). `identifier(of:)` fails loudly if
/// that ever stops being true rather than letting a link silently verify
/// against nothing.
///
/// The drain tests (§4.2) script arrivals through the fake's `onFetch` hook —
/// the design's own "trigger-during-pass" test point: a roster update arriving
/// while a verification pass is in flight. The assertions are written to hold
/// under EVERY interleaving of that race (captured as the follow-up pass, or
/// served by its own fresh pass — the two orderings §4.2 declares mutually
/// exclusive), so the suite pins the guarantee, not the scheduler.
final class SystemContactLinkServiceTests: XCTestCase {

    // MARK: - Fake platform seam

    /// Scripted `SystemContactReading`.
    ///
    /// Thread-safe by construction: the service is an actor, so every call
    /// arrives serially, but the TEST reads the recorded state while the actor
    /// may still be working — the lock is what makes those reads honest (and
    /// it is what lets the concurrency counters mean anything).
    private final class FakeSystemContactReader: SystemContactReading {

        /// The store-level failure the fake throws when scripted.
        struct ScriptedFailure: Error {}

        struct Request {
            let identifiers: [String]
            let keys: [CNKeyDescriptor]
        }

        private let lock = NSLock()
        private var accessValue: ContactsAccess = .allowed
        private var recordsValue: [CNContact] = []
        private var failureValue: Error?
        private var requestsValue: [Request] = []
        private var fetchCountValue = 0
        private var concurrentFetches = 0
        private var peakConcurrentFetchesValue = 0

        /// The arrival script: called with the 1-based fetch number, OUTSIDE
        /// the lock, so the closure may spawn a competing `refresh` from
        /// inside a pass (§4.2's trigger-during-pass case).
        var onFetch: ((Int) -> Void)?

        var access: ContactsAccess {
            get { lock.lock(); defer { lock.unlock() }; return accessValue }
            set { lock.lock(); defer { lock.unlock() }; accessValue = newValue }
        }

        /// The records the book currently holds. A record that is NOT here is
        /// absent from the fetch — deleted, or withheld under limited access
        /// (the same shape, and the same honest degradation).
        var records: [CNContact] {
            get { lock.lock(); defer { lock.unlock() }; return recordsValue }
            set { lock.lock(); defer { lock.unlock() }; recordsValue = newValue }
        }

        var failure: Error? {
            get { lock.lock(); defer { lock.unlock() }; return failureValue }
            set { lock.lock(); defer { lock.unlock() }; failureValue = newValue }
        }

        var requests: [Request] {
            lock.lock(); defer { lock.unlock() }; return requestsValue
        }

        var fetchCount: Int {
            lock.lock(); defer { lock.unlock() }; return fetchCountValue
        }

        var peakConcurrentFetches: Int {
            lock.lock(); defer { lock.unlock() }; return peakConcurrentFetchesValue
        }

        func currentAccess() -> ContactsAccess { access }

        func contacts(identifiers: [String], keysToFetch: [CNKeyDescriptor]) throws -> [CNContact] {
            lock.lock()
            fetchCountValue += 1
            let number = fetchCountValue
            requestsValue.append(Request(identifiers: identifiers, keys: keysToFetch))
            concurrentFetches += 1
            peakConcurrentFetchesValue = max(peakConcurrentFetchesValue, concurrentFetches)
            let currentRecords = recordsValue
            let currentFailure = failureValue
            lock.unlock()

            defer {
                lock.lock()
                concurrentFetches -= 1
                lock.unlock()
            }

            onFetch?(number)
            if let currentFailure { throw currentFailure }
            return currentRecords.filter { identifiers.contains($0.identifier) }
        }
    }

    /// A lock-protected value written by a spawned task and read by the test
    /// after that task's completion has been awaited. A captured `var` would
    /// not compile (concurrent mutation) and a bare class without the lock
    /// would be a data race the moment two spawns write it.
    private final class Box<Value> {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        var current: Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Value) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    // MARK: - Fixtures

    /// One address-book record. The number list is the record's stored order;
    /// `photo` is the full-size image data the photo path reads.
    private func makeRecord(number: String,
                            extraNumbers: [String] = [],
                            photo: Data? = nil) -> CNMutableContact {
        let contact = CNMutableContact()
        // A name, on purpose: the service must never fetch it (data
        // minimisation) nor log it, and `verificationKeys`/`photoKeys` are
        // pinned against exactly that.
        contact.givenName = "System Only Name"
        contact.familyName = "NotForTheApp"
        contact.phoneNumbers = ([number] + extraNumbers).map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile,
                           value: CNPhoneNumber(stringValue: $0))
        }
        if let photo { contact.imageData = photo }
        return contact
    }

    /// A family contact whose STORED link claims `record`. `numberKey`
    /// defaults to the record's first number as link time would have stored
    /// it (`ContactNumberKey.normalized`); a test passes a different key to
    /// script a stale fingerprint.
    private func linkedContact(for record: CNContact,
                               name: String = "Sita Sharma",
                               numberKey: String? = nil) -> FamilyContact {
        let firstNumber = record.phoneNumbers.first?.value.stringValue ?? ""
        return FamilyContact(name: name,
                             phone: "+977 9841 234 567",
                             relationship: "daughter",
                             systemContact: SystemContactLink(
                                identifier: record.identifier,
                                numberKey: numberKey ?? ContactNumberKey.normalized(firstNumber)))
    }

    /// The record's framework-assigned identifier. The wizard stores what the
    /// frame work hands it; a test that silently used an empty identifier
    /// would assert against a link the model refuses — so this fails here,
    /// loudly, instead.
    private func identifier(of record: CNContact,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> String {
        let identifier = record.identifier
        XCTAssertFalse(identifier.isEmpty,
                       "CNMutableContact must carry a system identifier in the simulator",
                       file: file, line: line)
        return try XCTUnwrap(identifier.isEmpty ? nil : identifier,
                             "the fetched record must carry an identifier",
                             file: file, line: line)
    }

    /// Does a fetch ask for this key? The `CNContact*Key` constants are
    /// `String` on this SDK and the fetched descriptors bridge to `NSString`,
    /// so membership is their own string equality.
    private func containsKey(_ key: String, _ keys: [CNKeyDescriptor]) -> Bool {
        keys.contains { ($0 as AnyObject).isEqual(key) }
    }

    private func requests(in reader: FakeSystemContactReader,
                          withKey key: String) -> [FakeSystemContactReader.Request] {
        reader.requests.filter { containsKey(key, $0.keys) }
    }

    /// The verification fetches (they ask for phone numbers).
    private func verificationRequests(in reader: FakeSystemContactReader) -> [FakeSystemContactReader.Request] {
        requests(in: reader, withKey: CNContactPhoneNumbersKey)
    }

    /// The photo fetches (they ask for image data).
    private func photoRequests(in reader: FakeSystemContactReader) -> [FakeSystemContactReader.Request] {
        requests(in: reader, withKey: CNContactImageDataKey)
    }

    /// Polls until the fake has served `expected` fetches — the test-side
    /// "the pass is in flight" signal the concurrent tests synchronise on.
    private func waitForFetchCount(_ expected: Int,
                                   on reader: FakeSystemContactReader,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if reader.fetchCount >= expected { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for fetch #\(expected); saw \(reader.fetchCount)",
                file: file, line: line)
    }

    private func serviceFileText(file: StaticString = #filePath) -> String {
        let files = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/Contacts", file: file)
        guard let url = files.first(where: {
            FeatureSourceScan.relativePath(of: $0).hasSuffix("SystemContactLinkService.swift")
        }) else {
            XCTFail("SystemContactLinkService.swift not found under Services/Contacts")
            return ""
        }
        return FeatureSourceScan.codeText(of: url)
    }

    // MARK: - Verification (§1.3)

    /// Gherkin: "Stored link verifies against the live address book" — the
    /// snapshot carries the link and the record's numbers, and the generation
    /// bumps EXACTLY once for the drain (a second drain bumps it once more).
    func testStoredLinkVerifiesWithRecordNumbersAndOneGenerationBump() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let roster = [linkedContact(for: record)]
        let identifier = try identifier(of: record)

        let first = await service.refresh(contacts: roster)

        XCTAssertEqual(first.links[roster[0].id],
                       SystemContactLink(identifier: identifier, numberKey: "9841234567"))
        XCTAssertEqual(first.linkedRecordNumbers[identifier], ["9841234567"])
        XCTAssertEqual(first.generation, 1, "exactly one bump for that drain")
        XCTAssertEqual(first.familyID(forIdentifier: identifier), roster[0].id)

        let second = await service.refresh(contacts: roster)

        XCTAssertEqual(second.generation, 2, "one bump per completed drain, monotonic")
        XCTAssertEqual(second.links, first.links, "the same roster verifies to the same set")
    }

    /// The verification is ONE batched fetch over every claimed identifier,
    /// asking for the identifier and the numbers ONLY — a verification has no
    /// business pulling the person's name.
    func testVerificationIsOneBatchedFetchOfIdentifierAndNumberKeysOnly() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001")
        let recordB = makeRecord(number: "9841000002")
        let recordC = makeRecord(number: "9841000003")
        reader.records = [recordA, recordB, recordC]
        let roster = [linkedContact(for: recordA, name: "A"),
                      linkedContact(for: recordB, name: "B"),
                      linkedContact(for: recordC, name: "C")]

        _ = await service.refresh(contacts: roster)

        XCTAssertEqual(reader.fetchCount, 1, "ONE batched fetch — never a loop per link")
        let request = try XCTUnwrap(verificationRequests(in: reader).first)
        XCTAssertEqual(Set(request.identifiers),
                       Set([recordA.identifier, recordB.identifier, recordC.identifier]))
        XCTAssertEqual(request.keys.count, 2)
        XCTAssertTrue(containsKey(CNContactIdentifierKey, request.keys))
        XCTAssertTrue(containsKey(CNContactPhoneNumbersKey, request.keys))
        XCTAssertFalse(containsKey(CNContactGivenNameKey, request.keys),
                       "data minimisation: a verification must not fetch names")
        XCTAssertFalse(containsKey(CNContactImageDataKey, request.keys),
                       "data minimisation: a verification must not fetch photos")
    }

    /// A number ADDED to the record keeps the link: the fingerprint is the
    /// "is one of the current numbers still this number" test, not equality of
    /// the number lists (design-l1 §6.2).
    func testNumberOfTheRecordAddedOrKeptStillVerifies() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567", extraNumbers: ["01-4455667"])
        reader.records = [record]
        let roster = [linkedContact(for: record)]

        let snapshot = await service.refresh(contacts: roster)

        XCTAssertNotNil(snapshot.links[roster[0].id], "the stored number is still one of the record's")
        XCTAssertEqual(snapshot.linkedRecordNumbers[try identifier(of: record)],
                       ["9841234567", "014455667"], "all current normalized numbers, in stored order")
    }

    /// Duplicate identifier claims (only reachable from a corrupt payload —
    /// the coordinator refuses to persist one, L1 §6.1): the FIRST claim in
    /// roster order wins; every later duplicate stays unverified.
    func testDuplicateClaimFirstInRosterOrderWins() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let first = linkedContact(for: record, name: "First")
        let second = linkedContact(for: record, name: "Second")

        let snapshot = await service.refresh(contacts: [first, second])

        XCTAssertEqual(snapshot.links.count, 1, "one identifier, one verified link — never two")
        XCTAssertNotNil(snapshot.links[first.id])
        XCTAssertNil(snapshot.links[second.id], "the later duplicate claim stays unverified")
        XCTAssertEqual(snapshot.familyID(forIdentifier: try identifier(of: record)), first.id)
    }

    /// The first claim owns the identifier even when IT is stale: a later
    /// duplicate can never take over the claim (the roster order decides, not
    /// the verification outcome) — so a corrupt payload cannot flip which
    /// family contact a record maps to.
    func testDuplicateClaimWithAStaleFirstClaimLeavesTheIdentifierUnverified() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let stale = linkedContact(for: record, name: "Stale", numberKey: "9999999999")
        let valid = linkedContact(for: record, name: "Valid")

        let snapshot = await service.refresh(contacts: [stale, valid])

        XCTAssertTrue(snapshot.links.isEmpty, "the first claim owns the identifier even when stale")
        XCTAssertNil(snapshot.links[valid.id])
    }

    // MARK: - Degradation (FR-FCU-006, §1.3 failure paths)

    /// Gherkin: "Stale link (contact deleted)" — excluded from the snapshot,
    /// degraded not presented, and the family contact itself is untouched.
    func testStaleLinkRecordGoneIsExcludedAndTheFamilyContactSurvives() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let roster = [linkedContact(for: record)]
        let identifier = try identifier(of: record)

        // The record vanishes between link time and verification.
        reader.records = []
        let snapshot = await service.refresh(contacts: roster)

        XCTAssertTrue(snapshot.links.isEmpty, "a link whose record is gone is never presented")
        XCTAssertTrue(snapshot.linkedRecordNumbers.isEmpty)
        XCTAssertEqual(snapshot.generation, 1, "the pass completed — it published an empty set")
        XCTAssertNil(snapshot.familyID(forIdentifier: identifier))
        XCTAssertNil(snapshot.familyID(matchingRecordNumber: "9841234567"))
        XCTAssertEqual(roster[0].systemContact?.identifier, identifier,
                       "the stored claim is left alone — degradation, never deletion")
        XCTAssertEqual(MissedCallContactResolver.familyMatch(phone: "9841234567", in: roster)?.id,
                       roster[0].id,
                       "the family contact still resolves by number")
    }

    /// Gherkin: "Stale link (number changed)" — the fingerprint no longer
    /// matches, so the link degrades to unlinked.
    func testStaleLinkNumberChangedIsExcluded() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841000009")
        reader.records = [record]
        let roster = [linkedContact(for: record, numberKey: "9841000001")]

        let snapshot = await service.refresh(contacts: roster)

        XCTAssertTrue(snapshot.links.isEmpty, "the number the link fingerprinted is gone")
        XCTAssertTrue(snapshot.linkedRecordNumbers.isEmpty,
                      "unverified links carry no reachable numbers")
    }

    /// Gherkin: "Address-book read failure mid-drain" — the previously
    /// published snapshot is retained unchanged (stale serves; no
    /// empty-snapshot flap) and the generation is NOT incremented.
    func testFetchThrowRetainsThePreviousSnapshotAndDoesNotBumpTheGeneration() async throws {
        let reader = FakeSystemContactReader()
        let bus = RecordingObservabilityBus()
        let service = SystemContactLinkService(reader: reader, observabilityBus: bus)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let roster = [linkedContact(for: record)]
        let published = await service.refresh(contacts: roster)
        XCTAssertEqual(published.generation, 1, "precondition — a good pass published")

        reader.failure = FakeSystemContactReader.ScriptedFailure()
        let degraded = await service.refresh(contacts: roster)

        XCTAssertEqual(degraded, published, "the previous snapshot survives a read failure")
        XCTAssertEqual(degraded.generation, 1, "a failed pass publishes nothing and does not bump")
        XCTAssertEqual(bus.events.last?.outcome, "degraded")
        XCTAssertEqual(bus.events.last?.errorCode, "fetch_failed",
                       "the reason code is the closed vocabulary's fetch_failed")
    }

    /// Gherkin: "Contacts access revoked to denied" — no store call at all,
    /// the snapshot is untouched, and the degraded state is reported rather
    /// than retried (no retry storm).
    func testUnreadableAccessMakesNoStoreCallAndKeepsTheSnapshot() async throws {
        let reader = FakeSystemContactReader()
        let bus = RecordingObservabilityBus()
        let service = SystemContactLinkService(reader: reader, observabilityBus: bus)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let roster = [linkedContact(for: record)]
        let published = await service.refresh(contacts: roster)
        XCTAssertEqual(reader.fetchCount, 1, "precondition — one pass ran")

        for access in [ContactsAccess.denied, .notDetermined] {
            reader.access = access
            let snapshot = await service.refresh(contacts: roster)

            XCTAssertEqual(snapshot, published, "unreadable access publishes no new verified links")
            XCTAssertEqual(reader.fetchCount, 1, "no store call under unreadable access")
            XCTAssertEqual(bus.events.last?.outcome, "degraded")
            XCTAssertNil(bus.events.last?.errorCode, "no error code: nothing failed, access is off")
            XCTAssertEqual(bus.events.last?.metadata, ["entry_count": "1"],
                           "the count that still STANDS, not a claim about this pass")
        }
    }

    /// `.limited` (iOS 18 "Select Contacts") is a granted SUBSET: readable, so
    /// the granted record verifies and a record outside the selection is
    /// simply absent (an honest "no match", never a denial claim) — and never
    /// a re-prompt (FR-FCU-009, design-l2 R2).
    func testLimitedAccessIsReadableAndVerifiesTheGrantedRecord() async throws {
        let reader = FakeSystemContactReader()
        let bus = RecordingObservabilityBus()
        let service = SystemContactLinkService(reader: reader, observabilityBus: bus)
        let granted = makeRecord(number: "9841234567")
        let withheld = makeRecord(number: "9841999999")
        reader.access = .limited
        reader.records = [granted]          // the selection excludes `withheld`
        let grantedContact = linkedContact(for: granted, name: "Granted")
        let withheldContact = linkedContact(for: withheld, name: "Withheld")

        let snapshot = await service.refresh(contacts: [grantedContact, withheldContact])

        XCTAssertNotNil(snapshot.links[grantedContact.id], "a granted record verifies under .limited")
        XCTAssertNil(snapshot.links[withheldContact.id], "a withheld record is absent, not denied")
        XCTAssertEqual(reader.fetchCount, 1)
        XCTAssertEqual(bus.events.last?.outcome, "ok", "limited access is not a degraded state")
    }

    /// A roster that claims no links publishes the empty snapshot WITHOUT a
    /// store call — and that empty snapshot REPLACES an older one: links must
    /// not outlive the roster that claimed them (the "empty snapshot ⇒ today's
    /// behavior" anchor of design-l1 §6.2).
    func testLinklessRosterPublishesTheEmptySnapshotWithoutAFetch() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        let linked = linkedContact(for: record)

        let withLink = await service.refresh(contacts: [linked])
        XCTAssertEqual(withLink.links.count, 1, "precondition — a link verified")

        let unlinked = FamilyContact(name: "Sita Sharma",
                                     phone: "+977 9841 234 567",
                                     relationship: "daughter")
        let snapshot = await service.refresh(contacts: [unlinked])

        XCTAssertEqual(snapshot.links, [:])
        XCTAssertEqual(snapshot.linkedRecordNumbers, [:])
        XCTAssertEqual(snapshot.generation, 2, "the pass completed and published the empty set")
        XCTAssertEqual(reader.fetchCount, 1, "nothing to verify ⇒ no store call at all")
        XCTAssertEqual(VerifiedLinksSnapshot.empty,
                       VerifiedLinksSnapshot(links: [:], linkedRecordNumbers: [:], generation: 0),
                       "`.empty` is the unlinked anchor: no links, generation 0")
    }

    // MARK: - Snapshot lookups (§1.3)

    /// The two lookups every consumer uses: by record identifier, and by the
    /// linked record's number under `MissedCallContactResolver.matches` (the
    /// trailing-digit rule, floor 8) — reused unchanged, never re-implemented.
    func testSnapshotLookupsByIdentifierAndByRecordNumber() {
        let familyID = UUID()
        let snapshot = VerifiedLinksSnapshot(
            links: [familyID: SystemContactLink(identifier: "ABRecord-1",
                                                numberKey: "9841234567")],
            linkedRecordNumbers: ["ABRecord-1": ["9779841234567", "014455667"]],
            generation: 3)

        XCTAssertEqual(snapshot.familyID(forIdentifier: "ABRecord-1"), familyID)
        XCTAssertNil(snapshot.familyID(forIdentifier: "ABRecord-2"))
        XCTAssertEqual(snapshot.familyID(matchingRecordNumber: "9841234567"), familyID)
        XCTAssertEqual(snapshot.familyID(matchingRecordNumber: "+977 9841 234 567"), familyID,
                       "country-code and formatting tolerance, the same rule the dial path uses")
        XCTAssertEqual(snapshot.familyID(matchingRecordNumber: "14455667"), familyID,
                       "an 8-digit comparison is inside the rule's floor")
        XCTAssertNil(snapshot.familyID(matchingRecordNumber: "5551234"),
                     "a 7-digit local number never suffix-matches a national one")
        XCTAssertNil(snapshot.familyID(matchingRecordNumber: "9841000000"))
    }

    /// Only VERIFIED links are reachable by number: an unverified (stale)
    /// link carries no numbers, so a changed number can never resolve a call
    /// to the wrong family contact.
    func testSnapshotNumberLookupIgnoresUnverifiedLinks() {
        let snapshot = VerifiedLinksSnapshot(
            links: [UUID(): SystemContactLink(identifier: "ABRecord-1", numberKey: "9841234567")],
            linkedRecordNumbers: [:],       // nothing verified ⇒ nothing reachable
            generation: 1)

        XCTAssertNil(snapshot.familyID(matchingRecordNumber: "9841234567"))
    }

    // MARK: - Drain (§4.2)

    /// Gherkin: "Single-flight drain captures the latest roster". A roster
    /// update arriving while a verification pass is in flight runs a
    /// follow-up pass with THAT roster — it is not deferred to the next
    /// external trigger, and it never costs a pass per trigger.
    ///
    /// Determinism: under BOTH orderings of the race the second roster is
    /// fetched exactly once after the first, so two passes stand and the
    /// generation-2 snapshot is the one built from the LATEST roster. Which
    /// call carries it back differs by design — the coalesced caller returns
    /// the earlier snapshot and drops it via the generation guard — so that
    /// is asserted as the (either) 1-or-2 shape.
    func testTriggerArrivingDuringAnInFlightPassIsVerifiedByThatDrain() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001")
        let recordB = makeRecord(number: "9841000002")
        reader.records = [recordA, recordB]
        let rosterA = [linkedContact(for: recordA, name: "A")]
        let rosterB = [linkedContact(for: recordB, name: "B")]
        let identifierA = try identifier(of: recordA)
        let identifierB = try identifier(of: recordB)

        let first = Task { await service.refresh(contacts: rosterA) }
        await waitForFetchCount(1, on: reader)
        let second = await service.refresh(contacts: rosterB)   // arrives mid-pass
        let firstResult = await first.value

        XCTAssertEqual(reader.fetchCount, 2, "two rosters, two passes — no pass per trigger, none dropped")
        XCTAssertEqual(reader.requests.map { $0.identifiers },
                       [[identifierA], [identifierB]],
                       "the follow-up pass runs with the retained LATEST roster")
        let snapshots = [firstResult, second]
        let final = try XCTUnwrap(snapshots.max { $0.generation < $1.generation })
        XCTAssertEqual(final.generation, 2)
        XCTAssertNotNil(final.links[rosterB[0].id],
                        "the snapshot that stands is the one built from the latest roster")
        XCTAssertNil(final.links[rosterA[0].id],
                     "…and only from it: a pass publishes its own batch's verified set")
        // The snapshot a call returns always matches the pass it stands for.
        switch firstResult.generation {
        case 1:
            XCTAssertNotNil(firstResult.links[rosterA[0].id])
        case 2:
            XCTAssertNotNil(firstResult.links[rosterB[0].id])
        default:
            XCTFail("unexpected generation \(firstResult.generation)")
        }
    }

    /// §4.2's coalescing bound, FORCED rather than raced: pass 1 is held open
    /// (its fetch blocks on a gate) while two roster triggers arrive. Both
    /// refresh calls are parked on the actor before the drain's capture point,
    /// so both take the coalesced path and the drain costs exactly ONE
    /// follow-up pass — with the LATEST roster (they overwrite one
    /// `pendingContacts`, never queue N passes); the superseded roster is
    /// never fetched at all.
    ///
    /// The two 100 ms margins are scheduling room for each task BODY to ISSUE
    /// its call while the actor is provably held — the arrival ORDER is then
    /// fixed, so "latest roster" is well defined. Everything asserted happens
    /// after the gate: no assertion depends on those margins.
    func testTriggersArrivingDuringAnInFlightPassCoalesceIntoOneFollowUpPass() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001")
        let recordB = makeRecord(number: "9841000002")
        let recordC = makeRecord(number: "9841000003")
        reader.records = [recordA, recordB, recordC]
        let rosterA = [linkedContact(for: recordA, name: "A")]
        let rosterB = [linkedContact(for: recordB, name: "B")]
        let rosterC = [linkedContact(for: recordC, name: "C")]

        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "pass 1 entered the store")
        reader.onFetch = { number in
            guard number == 1 else { return }
            entered.fulfill()
            gate.wait()          // hold the pass — and therefore the actor — open
        }
        let drain = Task { await service.refresh(contacts: rosterA) }
        await fulfillment(of: [entered], timeout: 5)

        let arrived = expectation(description: "both mid-pass triggers returned")
        arrived.expectedFulfillmentCount = 2
        let returnedGenerations = Box<[UInt64]>([])
        let collect = { (generation: UInt64) in
            returnedGenerations.set(returnedGenerations.current + [generation])
        }
        Task {
            let snapshot = await service.refresh(contacts: rosterB)
            collect(snapshot.generation)
            arrived.fulfill()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        Task {
            let snapshot = await service.refresh(contacts: rosterC)
            collect(snapshot.generation)
            arrived.fulfill()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.signal()

        let final = await drain.value
        await fulfillment(of: [arrived], timeout: 5)

        XCTAssertEqual(reader.fetchCount, 2,
                       "N triggers during one pass cost ONE follow-up pass — never a pass per trigger")
        XCTAssertEqual(reader.requests.map { $0.identifiers },
                       [[recordA.identifier], [recordC.identifier]],
                       "the follow-up pass verifies the LATEST roster only; the superseded one is never fetched")
        XCTAssertEqual(final.generation, 2)
        XCTAssertEqual(final.links.count, 1, "the newest snapshot holds exactly the newest roster's link")
        XCTAssertNotNil(final.links[rosterC[0].id], "the latest roster's link is published")
        XCTAssertNil(final.links[rosterB[0].id], "the superseded roster's claim is not in the newest snapshot")
        XCTAssertEqual(returnedGenerations.current.sorted(), [1, 1],
                       "both coalesced callers got the earlier snapshot back — droppable by the generation guard")
    }

    /// Two overlapping drains: a pass per roster — never a second concurrent
    /// pass over the same book, never a lost trigger. Exactly one call carries
    /// the final generation back (the other returns an earlier snapshot that
    /// the consumer's generation guard drops).
    func testTwoOverlappingDrainsRunOnePassPerRosterAndNeverOverlap() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001")
        let recordB = makeRecord(number: "9841000002")
        reader.records = [recordA, recordB]
        let rosterA = [linkedContact(for: recordA, name: "A")]
        let rosterB = [linkedContact(for: recordB, name: "B")]

        async let first = service.refresh(contacts: rosterA)
        async let second = service.refresh(contacts: rosterB)
        let (snapshotA, snapshotB) = await (first, second)

        XCTAssertEqual(reader.fetchCount, 2, "two rosters ⇒ two passes, whatever the interleaving")
        XCTAssertEqual(Set(reader.requests.map { $0.identifiers.first ?? "" }),
                       Set([recordA.identifier, recordB.identifier]))
        XCTAssertEqual(reader.peakConcurrentFetches, 1,
                       "single-flight: two passes over the book never overlap")
        let snapshots = [snapshotA, snapshotB]
        XCTAssertEqual(snapshots.filter { $0.generation == 2 }.count, 1,
                       "exactly one call carries the final snapshot; the other is droppable")
        XCTAssertTrue(snapshots.map { $0.generation }.max() == 2)
    }

    /// A trigger arriving AFTER the drain completed takes the fast path: it
    /// runs its own pass and publishes the next generation (no stale carry-
    /// over from the previous drain's coalesced state).
    func testTriggerAfterQuiescenceRunsAFreshPass() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001")
        let recordB = makeRecord(number: "9841000002")
        reader.records = [recordA, recordB]
        let rosterA = [linkedContact(for: recordA, name: "A")]
        let rosterB = [linkedContact(for: recordB, name: "B")]

        let first = await service.refresh(contacts: rosterA)
        let second = await service.refresh(contacts: rosterB)

        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(reader.requests.map { $0.identifiers },
                       [[recordA.identifier], [recordB.identifier]])
        XCTAssertNil(second.links[rosterA[0].id], "each pass publishes its own batch's set")
        XCTAssertNotNil(second.links[rosterB[0].id])
    }

    // MARK: - Photo cache (§4.3)

    /// Gherkin: "Photo cache serves verified system photos" — the first ask
    /// costs one fetch, the second is served from the NSCache.
    func testVerifiedLinkPhotoIsFetchedOnceThenServedFromTheCache() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let photo = Data([0x01, 0x02, 0x03, 0x04])
        let record = makeRecord(number: "9841234567", photo: photo)
        reader.records = [record]
        let roster = [linkedContact(for: record)]
        let snapshot = await service.refresh(contacts: roster)
        XCTAssertNotNil(snapshot.links[roster[0].id], "precondition — the link verifies")

        let first = await service.photoImageData(forIdentifier: try identifier(of: record))
        let second = await service.photoImageData(forIdentifier: try identifier(of: record))

        XCTAssertEqual(first, photo)
        XCTAssertEqual(second, photo)
        XCTAssertEqual(photoRequests(in: reader).count, 1,
                       "the second ask is served from the cache — one fetch, not two")
    }

    /// A photo read asks for the identifier and the image bytes only — never
    /// the person's name or numbers.
    func testPhotoReadFetchesIdentifierAndImageKeysOnly() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567", photo: Data([0x0A]))
        reader.records = [record]

        _ = await service.photoImageData(forIdentifier: try identifier(of: record))

        let request = try XCTUnwrap(photoRequests(in: reader).first)
        XCTAssertEqual(request.keys.count, 2)
        XCTAssertTrue(containsKey(CNContactIdentifierKey, request.keys))
        XCTAssertTrue(containsKey(CNContactImageDataKey, request.keys))
        XCTAssertFalse(containsKey(CNContactGivenNameKey, request.keys))
        XCTAssertFalse(containsKey(CNContactPhoneNumbersKey, request.keys))
    }

    /// The cache key is a HASH: 16 hex characters of sha256(identifier) — no
    /// identifier, no slice of one, deterministic per record.
    func testPhotoCacheKeyIsTheSixteenHexCharHashOfTheIdentifier() {
        let identifier = "6146EC92-EEF9-4F4A-819C-28F2F9F579FB:ABPerson"

        let key = SystemContactLinkService.photoCacheKey(for: identifier)

        XCTAssertEqual(key.count, SystemContactLinkService.photoKeyHashPrefixLength)
        XCTAssertEqual(key.count, 16)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit }, "hex only: \(key)")
        XCTAssertNotEqual(key, identifier)
        XCTAssertFalse(identifier.contains(key), "the key is not a slice of the identifier")
        XCTAssertEqual(key, SystemContactLinkService.photoCacheKey(for: identifier),
                       "deterministic for one record")
        XCTAssertNotEqual(key, SystemContactLinkService.photoCacheKey(for: identifier + "2"),
                          "distinct records get distinct keys")
    }

    /// The §4.3 budgets are the named constants, not literals sprinkled at the
    /// construction site: 24 entries, 16 MiB of raw bytes, a 16-hex prefix.
    func testPhotoCacheBudgetsAreTheDesignConstants() {
        XCTAssertEqual(SystemContactLinkService.photoCacheCountLimit, 24)
        XCTAssertEqual(SystemContactLinkService.photoCacheTotalCostLimit, 16 * 1024 * 1024)
        XCTAssertEqual(SystemContactLinkService.photoKeyHashPrefixLength, 16)
    }

    /// Wholesale invalidation (the foreground hook, §4.5): every record's
    /// cached bytes are gone, so the next ask re-reads the book.
    func testInvalidateAllClearsTheWholeCache() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let record = makeRecord(number: "9841234567", photo: Data([0x01]))
        reader.records = [record]
        let identifier = try identifier(of: record)
        _ = await service.photoImageData(forIdentifier: identifier)
        _ = await service.photoImageData(forIdentifier: identifier)
        XCTAssertEqual(photoRequests(in: reader).count, 1, "precondition — cached")

        await service.invalidate(identifier: nil)
        let afterInvalidation = await service.photoImageData(forIdentifier: identifier)

        XCTAssertEqual(afterInvalidation, Data([0x01]))
        XCTAssertEqual(photoRequests(in: reader).count, 2, "the whole cache was dropped")
    }

    /// Per-identifier invalidation (after our own write, §4.4) touches ONE
    /// record: the other record's bytes stay cached.
    func testInvalidateOneIdentifierLeavesOtherRecordsCached() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let recordA = makeRecord(number: "9841000001", photo: Data([0x0A]))
        let recordB = makeRecord(number: "9841000002", photo: Data([0x0B]))
        reader.records = [recordA, recordB]
        let identifierA = try identifier(of: recordA)
        let identifierB = try identifier(of: recordB)
        _ = await service.photoImageData(forIdentifier: identifierA)
        _ = await service.photoImageData(forIdentifier: identifierB)
        XCTAssertEqual(photoRequests(in: reader).count, 2, "precondition — both cached")

        await service.invalidate(identifier: identifierA)
        _ = await service.photoImageData(forIdentifier: identifierA)
        _ = await service.photoImageData(forIdentifier: identifierB)

        let requests = photoRequests(in: reader)
        XCTAssertEqual(requests.count, 3, "only the invalidated record was re-fetched")
        XCTAssertEqual(requests.last?.identifiers, [identifierB],
                       "…and the surviving record was served from its cache")
    }

    /// nil is the honest answer for all three shapes — absent, unreadable,
    /// not readable — and an absent photo is NOT remembered as absent.
    func testPhotoAbsentOrUnreadableOrNotReadableReturnsNil() async throws {
        let reader = FakeSystemContactReader()
        let service = SystemContactLinkService(reader: reader)
        let noPhoto = makeRecord(number: "9841234567")
        let withPhoto = makeRecord(number: "9841999999", photo: Data([0x0C]))
        reader.records = [noPhoto, withPhoto]

        // Absent: the record has no full-size image.
        let absentIdentifier = try identifier(of: noPhoto)
        let absentFirst = await service.photoImageData(forIdentifier: absentIdentifier)
        let absentSecond = await service.photoImageData(forIdentifier: absentIdentifier)
        XCTAssertNil(absentFirst)
        XCTAssertNil(absentSecond)
        XCTAssertEqual(photoRequests(in: reader).count, 2,
                       "a nil result is not cached — absent is re-checked, never remembered")

        // Unreadable: the store failed.
        reader.failure = FakeSystemContactReader.ScriptedFailure()
        let unreadable = await service.photoImageData(forIdentifier: try identifier(of: withPhoto))
        XCTAssertNil(unreadable)

        // Not readable: denied, and no store call at all.
        reader.failure = nil
        reader.access = .denied
        let before = reader.fetchCount
        let denied = await service.photoImageData(forIdentifier: try identifier(of: withPhoto))
        XCTAssertNil(denied)
        XCTAssertEqual(reader.fetchCount, before, "no store call under unreadable access")
    }

    // MARK: - Observability (§5.2)

    /// A published pass emits exactly one event, in the closed vocabulary,
    /// with allow-listed metadata keys and a count-shaped value — never a
    /// name, number or identifier.
    func testPublishedPassEmitsTheClosedVocabularyWithAllowListedMetadata() async throws {
        let reader = FakeSystemContactReader()
        let bus = RecordingObservabilityBus()
        let service = SystemContactLinkService(reader: reader, observabilityBus: bus)
        let record = makeRecord(number: "9841234567")
        reader.records = [record]
        _ = await service.refresh(contacts: [linkedContact(for: record)])

        XCTAssertEqual(bus.events.count, 1, "one completed pass, one event")
        let event = try XCTUnwrap(bus.events.first)
        XCTAssertEqual(event.component, "contacts_link")
        XCTAssertEqual(event.eventType, "refresh_completed")
        XCTAssertEqual(event.outcome, "ok")
        XCTAssertNil(event.errorCode)
        XCTAssertEqual(event.metadata, ["entry_count": "1"])
        XCTAssertNotNil(event.durationMs, "duration_ms is set on refresh_completed")
        XCTAssertTrue(Set(event.metadata.keys).isSubset(of: LogSanitiser.allowedKeys),
                      "every metadata key is allow-listed: \(event.metadata.keys.sorted())")
    }

    /// The service writes NOTHING to the console in any build (§5.2 rule 3 of
    /// the release log-safety gate): diagnostics are bus events only.
    func testServiceFileHasNoConsoleWrites() {
        let code = serviceFileText()
        XCTAssertFalse(code.isEmpty, "precondition — the service source was read")
        for token in ["print(", "debugPrint(", "NSLog(", "os_log(", "fputs("] {
            let pattern = NSRegularExpression.escapedPattern(for: token)
            let hit = FeatureSourceScan.firstMatch(of: pattern, in: code)
            XCTAssertNil(hit, "console write `\(token)` at line \(hit?.line ?? 0): \(hit?.text ?? "")")
        }
    }

    /// NFR-FCU-003: no network. All of the service's data is local
    /// address-book state, so no transport API may appear in its source.
    func testServiceFileHasNoNetworkEgress() {
        let code = serviceFileText()
        XCTAssertFalse(code.isEmpty, "precondition — the service source was read")
        for token in ["URLSession", "URLRequest", "NWConnection", "NWPathMonitor",
                      "import Network", "CFNetwork"] {
            let pattern = NSRegularExpression.escapedPattern(for: token)
            let hit = FeatureSourceScan.firstMatch(of: pattern, in: code)
            XCTAssertNil(hit, "network API `\(token)` at line \(hit?.line ?? 0): \(hit?.text ?? "")")
        }
    }
}
