import XCTest
@testable import ElderlyAssistant

/// `CalendarShareService`: the two gates, the reconcile diff, the flush
/// queue and the inbound pull — every rule driven through the protocol
/// seams with no network, no OAuth client and no EventKit permission.
///
/// Two things shape the suite:
///  - the service publishes status and commits its ledger from
///    `DispatchQueue.main.async` hops, so assertions after an action go
///    through `drainMain()` (see the helper at the bottom);
///  - a reconcile auto-flushes on a detached `Task` with no completion
///    handle, so tests that must observe the END of that pass poll with
///    `waitUntil`. Where a rule does not need the auto-flush, the queue
///    is seeded directly and `flushPending()` is awaited — which is
///    deterministic.
final class CalendarShareServiceTests: XCTestCase {

    // MARK: - Pinned clock

    /// A fixed instant, so the drafts the mapper builds are the same on
    /// every run. The service's own date math is calendar-injected one
    /// level down (`CalendarShareMapper`), which is where it is tested
    /// against a pinned UTC calendar.
    private let pinnedNow = Date(timeIntervalSince1970: 1_789_000_000)

    private var fakeNow: Date = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - Harness

    private var suiteName = ""
    /// `CalendarShareConsent`, `LocalGoogleEventMappingStore.lastSyncAt`
    /// and the inbound sync token all persist in `UserDefaults`; an
    /// isolated throwaway suite keeps a flipped gate from leaking into
    /// the next test (or into the process-wide standard defaults).
    private var defaults: UserDefaults = .standard
    private var notifySettings: CaregiverNotifySettings!
    /// Read at reconcile time, never captured — the family edits contacts
    /// in Settings and the next pass must see the edit.
    private var testContacts: [FamilyContact] = []

    override func setUp() {
        super.setUp()
        suiteName = "calendarShare.service.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        notifySettings = CaregiverNotifySettings.isolated()
        fakeNow = pinnedNow
        testContacts = [FamilyContact(name: "आमा", phone: "9812345678",
                                      relationship: "आमा",
                                      email: "maa@example.com",
                                      isEmergencyContact: true)]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct Rig {
        let service: CalendarShareService
        let session: FakeShareSession
        let gateway: FakeShareGateway
        let eventKit: FakeShareEventKit
        let store: LocalGoogleEventMappingStore
        let bus: MockObservabilityBus
    }

    private func makeService(signedIn: Bool = true, consented: Bool = true,
                             configured: Bool = true,
                             hasScopes: Bool = true) -> Rig {
        let session = FakeShareSession()
        session.isConfigured = configured
        session.isSignedIn = signedIn
        session.hasRequiredScopes = hasScopes
        let gateway = FakeShareGateway()
        let eventKit = FakeShareEventKit()
        // A fresh ledger per rig: two services in one test must not share
        // a mapping store, or the "signed out" half would see the
        // "consented" half's work.
        let store = LocalGoogleEventMappingStore(storage: MockEncryptedLocalStorage(),
                                                 defaults: defaults)
        let consent = CalendarShareConsent(defaults: defaults)
        consent.isAccepted = consented
        let bus = MockObservabilityBus()
        let service = CalendarShareService(
            session: session, gateway: gateway, store: store, consent: consent,
            notifySettings: notifySettings, observabilityBus: bus, eventKit: eventKit,
            contactsProvider: { [weak self] in self?.testContacts ?? [] },
            defaults: defaults,
            now: { [weak self] in self?.fakeNow ?? Date() })
        return Rig(service: service, session: session, gateway: gateway,
                   eventKit: eventKit, store: store, bus: bus)
    }

    // MARK: - Builders

    private func medicationEntry(name: String = "Amlodipine",
                                 hour: Int = 10, minute: Int = 0) -> MedicationEntry {
        MedicationEntry(
            id: UUID(), userProfileId: UUID(), medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: hour, minute: minute)],
            frequency: .daily, ackWindowMinutes: 5, maxRefireCount: 5,
            escalationWindowMinutes: 60, doubleDoseWindowHours: 4,
            photoVerificationEnabled: false, confirmationDescription: nil)
    }

    private func slotKey(_ entryId: UUID, slot: Int = 0) -> String {
        CalendarShareKey.slot(kind: .medicationReminder, entryId: entryId, slot: slot)
    }

    /// One queued mutation, in the shape `reconcile` would have written
    /// it. Seeding the queue directly keeps the flush rules below free of
    /// the reconcile's detached auto-flush.
    private func queuedCreate(key: String, title: String = "Amlodipine",
                              googleEventID: String? = nil,
                              attendees: [String] = ["maa@example.com"])
        -> PendingShareOperation {
        PendingShareOperation.upsert(
            key: key,
            draft: CalendarTwinDraft(
                title: title,
                startDate: fakeNow.addingTimeInterval(3600),
                durationMinutes: 30,
                timeZoneIdentifier: "Asia/Kathmandu",
                recurrence: .daily,
                attendeeEmails: attendees,
                kind: .medicationReminder),
            googleEventID: googleEventID)
    }

    private func incomingEvent(id: String, needsResponse: Bool = true,
                               title: String = "Doctor") -> GoogleIncomingEvent {
        GoogleIncomingEvent(eventId: id, title: title,
                            startDate: fakeNow.addingTimeInterval(86_400),
                            endDate: fakeNow.addingTimeInterval(86_400 + 3600),
                            organizerEmail: "son@example.com",
                            needsResponse: needsResponse)
    }

    // MARK: - Gate: signed in AND consented, or nothing happens

    func testReconcileWhileSignedOutQueuesNothingAndCallsNothing() async {
        let rig = makeService(signedIn: false, consented: true)

        rig.service.reconcileMedication([medicationEntry()])
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0,
                       "a signed-out app accumulates NO queue — the pending count must mean \"waiting on Google\", never \"waiting on a decision\"")
        XCTAssertTrue(rig.store.knownKeys.isEmpty)
        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "not even the family calendar is opened")

        await rig.service.flushPending()
        await drainMain()
        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "and flushing that empty queue calls nothing either")
    }

    func testReconcileWithConsentWithdrawnQueuesNothingAndCallsNothing() async {
        let rig = makeService(signedIn: true, consented: false)

        rig.service.reconcileMedication([medicationEntry()])
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0,
                       "revoked consent pauses sharing — the local schedule is untouched")
        XCTAssertTrue(rig.gateway.callLog.isEmpty)
    }

    func testReconcileWithBothGatesOpenQueuesAndFlushes() async {
        let rig = makeService()
        rig.gateway.createResults = ["g-1"]
        let entry = medicationEntry()

        rig.service.reconcileMedication([entry])
        await waitUntil("the reconcile's auto-flush to create the twin") {
            rig.gateway.createdDrafts.count == 1
        }
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.map(\.title), ["Amlodipine"])
        XCTAssertEqual(rig.store.googleEventID(for: slotKey(entry.id)), "g-1",
                       "the twin's Google id is recorded against the slot's share key")
    }

    // MARK: - Consent and connection status

    func testAcceptAndRevokeConsentFlipTheStatusFlag() async {
        let rig = makeService(signedIn: false, consented: false)
        await drainMain()
        XCTAssertFalse(rig.service.status.isConsented)

        rig.service.acceptConsent()
        await drainMain()
        XCTAssertTrue(rig.service.status.isConsented)
        XCTAssertEqual(rig.service.status.connection, .signedOut,
                       "accepting the disclosure signs nobody in — the two gates stay independent")

        rig.service.revokeConsent()
        await drainMain()
        XCTAssertFalse(rig.service.status.isConsented)
    }

    func testConnectionMirrorsTheSessionHonestly() async {
        let unconfigured = makeService(signedIn: false, configured: false)
        await drainMain()
        XCTAssertEqual(unconfigured.service.status.connection, .notConfigured,
                       "no OAuth client id in the bundle — the card explains instead of offering a button that cannot work")

        let signedOut = makeService(signedIn: false, configured: true)
        await drainMain()
        XCTAssertEqual(signedOut.service.status.connection, .signedOut)

        let connected = makeService(signedIn: true, configured: true)
        await drainMain()
        XCTAssertEqual(connected.service.status.connection,
                       .connected(email: "maa@example.com"))
    }

    /// The status matrix, over the three session facts the card renders
    /// (2026-09-17).
    ///
    /// `signedIn` and `canShare` were the same question until this
    /// change, and they are not: Google's consent sheet can close with
    /// the account connected and the Calendar grant withheld, and the
    /// card has to say THAT rather than "connected", which would tell
    /// the family their reminders are going out.
    func testConnectionSeparatesSignedInFromAbleToShare() async {
        // Signed in, no Calendar/contacts grant: its own state, with the
        // account still named so the household can see WHICH one it is.
        let unscoped = makeService(signedIn: true, hasScopes: false)
        await drainMain()
        XCTAssertEqual(unscoped.service.status.connection,
                       .connectedWithoutScopes(email: "maa@example.com"))
        XCTAssertFalse(unscoped.service.status.isActive,
                       "consent or not, a token without the calendar grant cannot share")

        // The full matrix in one place, so a future flag cannot silently
        // collapse two of these into one.
        let consentOff = makeService(signedIn: true, consented: false, hasScopes: false)
        await drainMain()
        XCTAssertEqual(consentOff.service.status.connection,
                       .connectedWithoutScopes(email: "maa@example.com"),
                       "the missing grant is reported even before the disclosure")

        let scopedAndConsented = makeService(signedIn: true, consented: true, hasScopes: true)
        await drainMain()
        XCTAssertTrue(scopedAndConsented.service.status.isActive,
                      "connected + scoped + consented is the only active state")

        let scopedButNotConsented = makeService(signedIn: true, consented: false, hasScopes: true)
        await drainMain()
        XCTAssertEqual(scopedButNotConsented.service.status.connection,
                       .connected(email: "maa@example.com"))
        XCTAssertFalse(scopedButNotConsented.service.status.isActive,
                       "the app's own gate is still a gate")
    }

    /// A flow that ends with the scope grant declined: the session is
    /// REAL (the account is not signed out) and nothing is flushed — the
    /// queue would fail item by item against a token that cannot write.
    func testSignInWithoutTheScopeGrantLeavesAnHonestInactiveStatus() async {
        let rig = makeService(signedIn: false, consented: true)
        rig.session.signInOutcome = .connectedWithoutScopes
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))
        await drainMain()

        let connected = await rig.service.signIn()
        await drainMain()

        XCTAssertFalse(connected,
                       "the return value means 'usable session', and this one cannot share")
        XCTAssertEqual(rig.service.status.connection,
                       .connectedWithoutScopes(email: "maa@example.com"),
                       "signed IN and unable to share — not signed out, which would be a different lie")
        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "nothing is drained into a token with no calendar grant")
    }

    /// The re-connect from that state works: the SAME entry point, run
    /// again, ends with the grant and the queue drains.
    func testReconnectingFromTheUnscopedStateRestoresSharing() async {
        let rig = makeService(signedIn: true, hasScopes: false)
        rig.gateway.createResults = ["g-1"]
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))
        await drainMain()
        XCTAssertEqual(rig.service.status.connection,
                       .connectedWithoutScopes(email: "maa@example.com"))

        rig.session.signInOutcome = .connected
        let connected = await rig.service.signIn()
        await drainMain()

        XCTAssertTrue(connected)
        XCTAssertEqual(rig.service.status.connection,
                       .connected(email: "maa@example.com"))
        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "the queue that waited through the missing grant lands once it is given")
    }

    /// Cancelling the sign-in sheet creates nothing at all — the state
    /// that was there before the tap is the state after it.
    func testCancellingSignInLeavesTheSignedOutStateAlone() async {
        let rig = makeService(signedIn: false, consented: true)
        rig.session.signInOutcome = .cancelled
        await drainMain()

        let connected = await rig.service.signIn()
        await drainMain()

        XCTAssertFalse(connected)
        XCTAssertEqual(rig.service.status.connection, .signedOut)
        XCTAssertTrue(rig.gateway.callLog.isEmpty)
    }

    // MARK: - Launch restore (2026-09-17)

    /// The bug the whole restore path exists for, end to end through the
    /// service: at cold launch the session reads SIGNED OUT (the SDK's
    /// user lives in memory, not in the Keychain), the card shows the
    /// pre-connect state, and anything queued before the elder last quit
    /// is gated behind a sign-in they have no reason to perform again.
    ///
    /// Both halves are asserted together because they are one story: the
    /// STATUS has to come back (the card), and the QUEUE has to drain
    /// (the family's events).
    func testRestoreRepublishesTheStatusAndDrainsTheQueueThatWaitedForIt() async {
        let rig = makeService(signedIn: false, consented: true)
        rig.gateway.createResults = ["g-1"]
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))
        await drainMain()
        XCTAssertEqual(rig.service.status.connection, .signedOut,
                       "the cold-launch state: stored account, unread session")

        rig.session.restoreOutcome = .connected
        let restored = await rig.service.restoreSession()
        await drainMain()

        XCTAssertTrue(restored)
        XCTAssertEqual(rig.session.restoreCalls, 1)
        XCTAssertEqual(rig.service.status.connection,
                       .connected(email: "maa@example.com"),
                       "the card shows the restored 'signed in as' account without the elder signing in again")
        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "and the work that waited for the session lands at launch")
        XCTAssertEqual(rig.store.pendingCount, 0)
    }

    /// Restored WITHOUT the Calendar/contacts grant: a real session that
    /// cannot share. Same honest state the interactive path produces, and
    /// nothing is drained into a token that would 401 item by item.
    func testRestoreWithoutTheGrantLeavesTheUnscopedStateAndDrainsNothing() async {
        let rig = makeService(signedIn: false, consented: true)
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))
        await drainMain()

        rig.session.restoreOutcome = .connectedWithoutScopes
        let restored = await rig.service.restoreSession()
        await drainMain()

        XCTAssertFalse(restored,
                       "the return value means 'can share', and this account cannot")
        XCTAssertEqual(rig.service.status.connection,
                       .connectedWithoutScopes(email: "maa@example.com"))
        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "nothing is drained into a token with no calendar grant")
        XCTAssertEqual(rig.store.pendingCount, 1,
                       "and nothing is lost by waiting — the queue is exactly as it was")
    }

    /// A restore that brings nothing back — no stored account, a revoked
    /// grant, a Keychain the SDK cannot read. It degrades to the state a
    /// device that never connected sits in, which is what the card says:
    /// no session, no error line, and the family's queued work intact
    /// for the next attempt.
    func testAFailedRestoreLeavesTheSignedOutStateExactlyAsItWas() async {
        let rig = makeService(signedIn: false, consented: true, configured: true)
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))
        rig.session.restoreOutcome = .unavailable
        await drainMain()

        let restored = await rig.service.restoreSession()
        await drainMain()

        XCTAssertFalse(restored)
        XCTAssertEqual(rig.session.restoreCalls, 1, "the restore was attempted, not skipped")
        XCTAssertEqual(rig.service.status.connection, .signedOut,
                       "a restore that did not arrive is the signed-out state, not a new error state")
        XCTAssertNil(rig.service.status.lastError,
                     "nothing was attempted against Google, so there is no share failure to report")
        XCTAssertTrue(rig.gateway.callLog.isEmpty)
        XCTAssertEqual(rig.store.pendingCount, 1,
                       "a failed restore must not eat the family's pending work")
    }

    /// No OAuth client in the bundle: the restore has nothing to work
    /// with, and the card keeps saying so rather than flickering to a
    /// state it cannot be in.
    func testRestoreIsInertWithoutAnOAuthClient() async {
        let rig = makeService(signedIn: false, consented: true, configured: false)
        await drainMain()

        let restored = await rig.service.restoreSession()
        await drainMain()

        XCTAssertFalse(restored)
        XCTAssertEqual(rig.service.status.connection, .notConfigured)
    }

    // MARK: - Flush: create

    func testSuccessfulCreateRecordsTheGoogleIDAndTheDraftFingerprint() async {
        let rig = makeService()
        rig.gateway.createResults = ["g-1"]
        let key = slotKey(UUID())
        rig.store.enqueue(queuedCreate(key: key))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.ensuredContactEmails, ["maa@example.com"],
                       "the People entry is ensured before the invite so it does not land in spam")
        XCTAssertEqual(rig.gateway.createdDrafts.count, 1)
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-1")
        guard let sent = rig.gateway.createdDrafts.first else {
            return XCTFail("no draft reached the gateway to fingerprint")
        }
        XCTAssertEqual(rig.store.fingerprint(for: key),
                       CalendarShareMapper.fingerprint(of: sent),
                       "the fingerprint describes the payload that was actually sent")
        XCTAssertNotNil(rig.store.lastSyncAt,
                        "a clean pass timestamps the ledger for the status card")
    }

    /// Design §2.2 bullet 4: the People contact the invite rides on is
    /// created from the FAMILY CONTACT's own details, not from the address
    /// alone — the name so the caregiver's contact list reads like a
    /// person, the phone so the entry is usable in an emergency.
    func testTheContactWriteCarriesTheNameAndPhoneBehindTheAddress() async {
        let rig = makeService()
        rig.gateway.createResults = ["g-1"]
        rig.store.enqueue(queuedCreate(key: slotKey(UUID())))

        await rig.service.flushPending()
        await drainMain()

        guard let contact = rig.gateway.ensuredContacts.first else {
            return XCTFail("no contact write reached the gateway")
        }
        XCTAssertEqual(contact.email, "maa@example.com")
        XCTAssertEqual(contact.name, "आमा", "the family's own spelling travels with the invite")
        XCTAssertEqual(contact.phone, "9812345678",
                       "a contact created as a bare address is a dead end in an emergency")
    }

    /// The service passes the family's stored details through UNTOUCHED —
    /// including an empty phone. Deciding that an empty string is not a
    /// phone number is the gateway's job, and it is asserted there
    /// (`testEnsureContactOmitsThePhoneFieldWhenThereIsNone`); what this
    /// test pins is that the service does not invent, trim or filter a
    /// field on the way, so the two layers cannot disagree about what the
    /// family typed.
    func testTheContactWritePassesTheStoredDetailsThroughUntouched() async {
        let rig = makeService()
        testContacts = [FamilyContact(name: "छोरा", phone: "",
                                      relationship: "छोरा",
                                      email: "chhora@example.com",
                                      isEmergencyContact: true)]
        rig.gateway.createResults = ["g-1"]
        rig.store.enqueue(queuedCreate(key: slotKey(UUID()),
                                       attendees: ["chhora@example.com"]))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.ensuredContacts.first?.email, "chhora@example.com")
        XCTAssertEqual(rig.gateway.ensuredContacts.first?.name, "छोरा")
        XCTAssertEqual(rig.gateway.ensuredContacts.first?.phone, "")
    }

    // MARK: - Flush: failure handling and ordering

    func testFailedCreateKeepsTheOperationQueuedAndStopsThePass() async {
        let rig = makeService()
        rig.gateway.createResults = []          // every create answers nil
        rig.store.enqueue(queuedCreate(key: slotKey(UUID(), slot: 0)))
        rig.store.enqueue(queuedCreate(key: slotKey(UUID(), slot: 1)))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "the pass STOPS at the first failure — whatever caused it applies to every operation behind it")
        XCTAssertEqual(rig.store.pendingCount, 2, "nothing is dropped on a failure")
        XCTAssertEqual(rig.store.pending.map(\.attempts).sorted(), [0, 1],
                       "exactly the failed operation records an attempt, persisted so a crash loop cannot reset the backoff")
        XCTAssertNil(rig.store.lastSyncAt, "a failed pass does not claim a clean sync")
    }

    func testUnauthorizedGatewayPausesThePassWithoutRetrying() async {
        let rig = makeService()
        rig.gateway.errorClassAfterFailure = .unauthorized
        let firstKey = slotKey(UUID(), slot: 0)
        let secondKey = slotKey(UUID(), slot: 1)
        rig.store.enqueue(queuedCreate(key: firstKey))
        rig.store.enqueue(queuedCreate(key: secondKey))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "a revoked token must not be hammered — the pass stops at the first refusal instead of working through the queue")
        XCTAssertEqual(rig.store.pendingCount, 2, "the family's pending work is kept")
        XCTAssertEqual(rig.store.pending.map(\.attempts), [0, 0],
                       "a paused pass is not a failed attempt — there is nothing for a backoff to do")
        XCTAssertEqual(rig.service.status.lastError, .unauthorized,
                       "the card says what is wrong with the connection")

        let paused = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_flush_paused" }
        XCTAssertEqual(paused.count, 1)
        XCTAssertEqual(paused.first?.outcome, "failure")
        XCTAssertEqual(paused.first?.metadata["reason"], "unauthorized")

        // And the pause must not be STICKY: reconnecting has to resume.
        // The class comes from the failure that just happened, never from
        // a remembered error, so a fresh token cannot sit behind a stale
        // `.unauthorized` that nothing clears.
        rig.gateway.errorClassAfterFailure = nil
        // A fresh family-calendar lookup too: the canned answers are
        // consumed in call order, so a second pass without one would fail
        // at the CALENDAR (and look like the pause was sticky).
        rig.gateway.ensureFamilyCalendarResults = ["family-cal"]
        rig.gateway.createResults = ["g-1", "g-2"]
        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0,
                       "the reconnected account drains exactly the work the pause held back")
        XCTAssertEqual(rig.store.googleEventID(for: firstKey), "g-1")
        XCTAssertEqual(rig.store.googleEventID(for: secondKey), "g-2")
    }

    /// The same pause for the OTHER refusal class (2026-09-17): a 403 is
    /// refused consent rather than a dead session, so the queue must stop
    /// exactly as it does for a 401 — and the event must say WHICH one it
    /// was, because labelling every pause "unauthorized" is the merge
    /// that hid the wrong-scoped-token bug in the device log.
    func testInsufficientScopesPausesThePassAndNamesItsOwnReason() async {
        let rig = makeService()
        rig.gateway.errorClassAfterFailure = .insufficientScopes
        let firstKey = slotKey(UUID(), slot: 0)
        let secondKey = slotKey(UUID(), slot: 1)
        rig.store.enqueue(queuedCreate(key: firstKey))
        rig.store.enqueue(queuedCreate(key: secondKey))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "a refused grant is not hammered — the pass stops at the first refusal")
        XCTAssertEqual(rig.store.pendingCount, 2, "the family's pending work is kept")
        XCTAssertEqual(rig.store.pending.map(\.attempts), [0, 0],
                       "a paused pass is not a failed attempt — there is nothing for a backoff to do")
        XCTAssertEqual(rig.service.status.lastError, .insufficientScopes,
                       "the card shows this class's own sentence, not the 401's")

        let paused = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_flush_paused" }
        XCTAssertEqual(paused.count, 1)
        XCTAssertEqual(paused.first?.outcome, "failure")
        XCTAssertEqual(paused.first?.metadata["reason"], "insufficient_scopes",
                       "the log names the refusal that actually happened")
    }

    // MARK: - Flush: delete and update

    func testDeleteWithNoKnownTwinIsDroppedWithoutADeleteCall() async {
        let rig = makeService()
        let key = CalendarShareKey.oneOff(kind: .calendarEvent, eventIdentifier: "evt-1")
        rig.store.enqueue(.tombstone(key: key, kind: .calendarEvent,
                                     googleEventID: nil, title: "Doctor"))

        await rig.service.flushPending()
        await drainMain()

        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty,
                      "there is no twin id to address — nothing to delete")
        XCTAssertEqual(rig.gateway.callLog, ["ensureFamilyCalendar"],
                       "the pass opens the family calendar and then makes no mutation call at all")
        XCTAssertEqual(rig.store.pendingCount, 0,
                       "the tombstone is dropped — keeping it would pin the pending count up forever")
    }

    /// A twin someone deleted on Google's side, whose tombstone we now
    /// owe: the goal state is ALREADY reached, so the tombstone has to
    /// drain. Retrying it would leave a queue entry that can never
    /// succeed, and `pendingCount` would never come back to zero.
    func testDeleteThatFindsTheTwinAlreadyGoneDrainsTheTombstone() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.setGoogleEventID("g-old", for: key)
        rig.store.enqueue(.tombstone(key: key, kind: .medicationReminder,
                                     googleEventID: "g-old", title: "Amlodipine"))
        rig.gateway.errorClassAfterFailure = .notFound
        rig.gateway.deleteResults = [false]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.deletedIDs, ["g-old"])
        XCTAssertEqual(rig.store.pendingCount, 0, "already gone is the goal state, not a failure")
        XCTAssertNil(rig.store.googleEventID(for: key),
                     "the mapping goes with it — nothing is out there to update")
        XCTAssertNotNil(rig.store.lastSyncAt, "the pass did reach the goal state, so it is a clean pass")
    }

    /// The other half of the same rule: a delete that failed for a reason
    /// that is NOT "it is gone" must be retried, not dropped — the twin
    /// is still out there and the family would keep seeing an event the
    /// elder removed.
    func testDeleteThatFailsTransientlyStaysQueued() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.setGoogleEventID("g-old", for: key)
        rig.store.enqueue(.tombstone(key: key, kind: .medicationReminder,
                                     googleEventID: "g-old", title: "Amlodipine"))
        rig.gateway.errorClassAfterFailure = .server(503)
        rig.gateway.deleteResults = [false]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 1, "the twin is still out there — the tombstone is kept")
        XCTAssertEqual(rig.store.pending.map(\.attempts), [1])
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-old",
                       "the mapping is kept too, so the retry has an id to address")
    }

    func testUpdateWhoseTwinIsGoneIsRecreatedUnderTheSameKey() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.setGoogleEventID("g-old", for: key)
        rig.store.enqueue(queuedCreate(key: key, googleEventID: "g-old"))
        rig.gateway.errorClassAfterFailure = .notFound
        rig.gateway.updateResults = [false]
        rig.gateway.createResults = ["g-new"]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.updatedCalls.map { $0.id }, ["g-old"])
        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "the local item is the source of truth — a twin someone deleted on Google's side is re-created")
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-new",
                       "the same key now points at the new twin, so the family sees one event, not two")
    }

    func testUpdateThatFailsTransientlyRetriesRatherThanDuplicatingTheTwin() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.setGoogleEventID("g-old", for: key)
        rig.store.enqueue(queuedCreate(key: key, googleEventID: "g-old"))
        rig.gateway.errorClassAfterFailure = .server(503)
        rig.gateway.updateResults = [false]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertTrue(rig.gateway.createdDrafts.isEmpty,
                      "re-creating after a transient error would leave the family with two copies of the same dose")
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-old")
        XCTAssertEqual(rig.store.pending.map(\.attempts), [1])
    }

    // MARK: - Backoff

    /// Design §2.5: the queue is retried, not hammered. A foreground
    /// return (or an interval wake) while an operation is still backing
    /// off makes NO request at all — not even the family-calendar lookup.
    func testAnOperationStillBackingOffDefersTheWholePass() async {
        let rig = makeService()
        let key = slotKey(UUID())
        // One recorded failure, just now: due in 30 seconds.
        rig.store.enqueue(queuedCreate(key: key).retried(at: fakeNow))
        rig.gateway.createResults = ["g-1"]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "the delay IS the retry — a pass that fires while it runs is the flood the backoff exists to prevent")
        XCTAssertEqual(rig.store.pending.map(\.attempts), [1],
                       "a deferred pass is not a failed attempt: it records nothing")
        XCTAssertEqual(rig.store.pendingCount, 1, "nothing is dropped")
        XCTAssertNil(rig.store.lastSyncAt, "nothing was synced")
        let deferred = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_flush_deferred" }
        XCTAssertEqual(deferred.count, 1)
        XCTAssertEqual(deferred.first?.metadata["waiting"], "1",
                       "the count of what is waiting is the only thing the line carries")
        XCTAssertNil(rig.service.status.lastError,
                     "waiting out a backoff is not an error for the family to see")
    }

    func testTheDeferredOperationIsAttemptedOnceTheBackoffHasElapsed() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.enqueue(queuedCreate(key: key).retried(at: fakeNow))
        rig.gateway.createResults = ["g-1"]
        await rig.service.flushPending()
        await drainMain()
        XCTAssertEqual(rig.store.pendingCount, 1, "still backing off")

        fakeNow = fakeNow.addingTimeInterval(31)
        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.count, 1,
                       "the operation is retried on the next pass after the delay")
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-1")
        XCTAssertNil(rig.store.pending.first, "and drains cleanly")
        XCTAssertNotNil(rig.store.lastSyncAt)
    }

    /// A never-tried operation is never delayed: the common case is a
    /// fresh change from the schedulers, and holding THAT back would make
    /// the family wait 30 seconds for every edit.
    func testAFreshOperationIsNotDelayedByAnotherKeySBackoff() async {
        let rig = makeService()
        let stale = slotKey(UUID())
        let fresh = slotKey(UUID())
        rig.store.enqueue(queuedCreate(key: stale).retried(at: fakeNow))
        rig.store.enqueue(queuedCreate(key: fresh))
        rig.gateway.createResults = ["g-1"]

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.createdDrafts.count, 1)
        XCTAssertEqual(rig.store.googleEventID(for: fresh), "g-1")
        XCTAssertEqual(rig.store.pendingCount, 1, "only the backing-off operation is left")
        XCTAssertEqual(rig.store.pending.first?.key, stale)
    }

    // MARK: - Stale-twin sweep

    /// Design §2.5. The elder deletes a shared appointment in the Calendar
    /// app; the twin on the family's calendar is now invisible locally and
    /// permanent remotely — the family keeps a doctor's visit that is not
    /// happening. The sweep is what turns that into a tombstone.
    func testSweepDeletesTheTwinOfAnOutboundEventThatVanishedLocally() async {
        let rig = makeService()
        let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                         eventIdentifier: "evt-1")
        rig.store.markOutbound(key)
        rig.store.setGoogleEventID("g-twin", for: key)
        rig.eventKit.vanishedIdentifiers = ["evt-1"]
        rig.gateway.deleteResults = [true]

        rig.service.cleanupVanishedEvents()
        await drainMain()
        // The sweep's own flush is detached (like the reconcile's), so the
        // end of the pass is observed rather than awaited.
        await waitUntil("the swept twin is deleted") { rig.store.pendingCount == 0 }

        XCTAssertEqual(rig.eventKit.existenceChecks, ["evt-1"])
        XCTAssertEqual(rig.gateway.deletedIDs, ["g-twin"],
                      "the family stops seeing an appointment the elder already removed")
        XCTAssertNil(rig.store.googleEventID(for: key))
        XCTAssertFalse(rig.store.isOutbound(key),
                       "the mark goes with the twin, so the next sweep does not queue the same deletion again")
        let swept = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_swept" }
        XCTAssertEqual(swept.count, 1)
        XCTAssertEqual(swept.first?.metadata["vanished"], "1")
    }

    /// The rule that makes the sweep safe. An IMPORTED invitation's twin
    /// is the organizer's own event — deleting it on the elder's behalf
    /// would take it off the family's calendar too, and the sweep would
    /// have no way of knowing whose appointment it just removed.
    func testSweepLeavesAnImportedInvitationAlone() async {
        let rig = makeService()
        let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                         eventIdentifier: "evt-invited")
        rig.store.setGoogleEventID("g-organizer", for: key)
        rig.eventKit.vanishedIdentifiers = ["evt-invited"]
        rig.gateway.deleteResults = [true]

        rig.service.cleanupVanishedEvents()
        await drainMain()

        XCTAssertTrue(rig.eventKit.existenceChecks.isEmpty,
                      "not ours to delete — not even asked about")
        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty)
        XCTAssertEqual(rig.store.googleEventID(for: key), "g-organizer")
        XCTAssertTrue(rig.store.pending.isEmpty, "no tombstone is queued")
    }

    func testSweepLeavesAnEventThatIsStillOnThePhoneAlone() async {
        let rig = makeService()
        let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                         eventIdentifier: "evt-2")
        rig.store.markOutbound(key)
        rig.store.setGoogleEventID("g-twin", for: key)
        // `vanishedIdentifiers` stays empty: the local event is still there.

        rig.service.cleanupVanishedEvents()
        await drainMain()

        XCTAssertEqual(rig.eventKit.existenceChecks, ["evt-2"])
        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty)
        XCTAssertTrue(rig.store.isOutbound(key), "the mark stays while the event does")
        XCTAssertTrue(rig.store.pending.isEmpty)
    }

    /// A key with no twin id has nothing out there to delete, and a key
    /// the one-off grammar cannot read (a slot key, however it got marked)
    /// names no local event to check.
    func testSweepIgnoresKeysWithNoTwinAndKeysThatAreNotOneOffs() async {
        let rig = makeService()
        let noTwin = CalendarShareKey.oneOff(kind: .calendarEvent,
                                            eventIdentifier: "evt-3")
        let slot = slotKey(UUID())
        rig.store.markOutbound(noTwin)
        rig.store.markOutbound(slot)
        rig.store.setGoogleEventID("g-slot", for: slot)
        rig.eventKit.vanishedIdentifiers = ["evt-3"]

        rig.service.cleanupVanishedEvents()
        await drainMain()

        XCTAssertTrue(rig.eventKit.existenceChecks.isEmpty)
        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty)
        XCTAssertTrue(rig.store.outboundKeys.contains(noTwin),
                      "nothing was swept, so nothing is unmarked")
    }

    /// Write-only access cannot READ events at all — every lookup would
    /// answer "gone" and the sweep would delete everything it knows
    /// about. A permission the app does not have is not an answer.
    func testSweepDoesNothingWithoutFullCalendarAccess() async {
        let rig = makeService()
        rig.eventKit.access = .writeOnly
        let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                         eventIdentifier: "evt-4")
        rig.store.markOutbound(key)
        rig.store.setGoogleEventID("g-twin", for: key)
        rig.eventKit.vanishedIdentifiers = ["evt-4"]

        rig.service.cleanupVanishedEvents()
        await drainMain()

        XCTAssertTrue(rig.eventKit.existenceChecks.isEmpty)
        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty)
        XCTAssertTrue(rig.store.isOutbound(key),
                      "nothing was swept, so the mark is kept for the pass that CAN see")
        let skipped = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_sweep_skipped" }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.metadata["reason"], "no_calendar_access")
    }

    /// Sharing paused (signed out or consent withdrawn) means no Google
    /// traffic at all — the sweep is not an exception.
    func testSweepDoesNothingWhileSharingIsPaused() async {
        let rig = makeService(signedIn: false)
        let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                         eventIdentifier: "evt-5")
        rig.store.markOutbound(key)
        rig.store.setGoogleEventID("g-twin", for: key)
        rig.eventKit.vanishedIdentifiers = ["evt-5"]

        rig.service.cleanupVanishedEvents()
        await drainMain()

        XCTAssertTrue(rig.eventKit.existenceChecks.isEmpty)
        XCTAssertTrue(rig.gateway.deletedIDs.isEmpty)
        XCTAssertTrue(rig.store.pending.isEmpty)
        XCTAssertTrue(rig.store.isOutbound(key))
    }

    // MARK: - The no-change rule

    /// **The fingerprint's whole purpose.** Without it the only options
    /// are "re-write every twin on every pass" (a PUT per event per
    /// launch, forever) or "never re-write", which silently drops the
    /// edit that matters.
    func testReconcilingTheSameEntriesTwiceEnqueuesWorkOnlyTheFirstTime() async {
        let rig = makeService()
        rig.gateway.createResults = ["g-1"]
        let entry = medicationEntry()
        let key = slotKey(entry.id)

        rig.service.reconcileMedication([entry])
        await waitUntil("the first pass to create the twin and record its fingerprint") {
            rig.store.fingerprint(for: key) != nil
        }
        await drainMain()

        let callsAfterFirstPass = rig.gateway.callLog
        XCTAssertEqual(callsAfterFirstPass.filter { $0.hasPrefix("createEvent") }.count, 1)

        // The same entries again — nothing about them changed.
        rig.service.reconcileMedication([entry])
        await drainMain()

        XCTAssertEqual(rig.gateway.callLog, callsAfterFirstPass,
                       "a second pass over unchanged content must send nothing")
    }

    // MARK: - eventCreated

    func testEventCreatedQueuesAOneOffTwinKeyedByTheNativeEventID() async {
        let rig = makeService()

        rig.service.eventCreated(localEventId: "evt-1", title: "Doctor",
                                 startDate: fakeNow, durationMinutes: 45)
        await drainMain()

        let key = CalendarShareKey.oneOff(kind: .calendarEvent, eventIdentifier: "evt-1")
        XCTAssertEqual(rig.store.pending.map(\.key), [key],
                       "the EventKit identifier is the join key — re-finding the event by title and time would be a guess two same-named events break")
        XCTAssertEqual(rig.store.pending.first?.action, .create)
        XCTAssertEqual(rig.store.pending.first?.durationMinutes, 45)
        XCTAssertEqual(rig.store.pending.first?.attendeeEmails, ["maa@example.com"])
    }

    func testEventCreatedWithNobodyEligibleEnqueuesNothing() async {
        let rig = makeService()
        testContacts = []

        rig.service.eventCreated(localEventId: "evt-1", title: "Doctor",
                                 startDate: fakeNow, durationMinutes: 45)
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0)
        XCTAssertTrue(rig.store.knownKeys.isEmpty)
        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "no draft means no queue and no call — the no-op lives in the mapper")

        // A contact with no address is equally ineligible, even the
        // emergency one the editor refuses to save without an address.
        let second = makeService()
        testContacts = [FamilyContact(name: "राम", phone: "9812345678",
                                             relationship: "छोरा",
                                             isEmergencyContact: true)]
        second.service.eventCreated(localEventId: "evt-2", title: "Doctor",
                                    startDate: fakeNow, durationMinutes: 45)
        await drainMain()
        XCTAssertEqual(second.store.pendingCount, 0)
        XCTAssertTrue(second.gateway.callLog.isEmpty)

        // [CALENDAR-POLICY] (2026-09-17) The skip is recorded, never
        // silent: the 2026-09-17 device runs created events with zero
        // share observability, which is what made "no invitation" so
        // hard to diagnose.
        let skipped = rig.bus.emittedEvents.filter {
            $0.eventType == "calendar_share_skipped_no_invitees"
        }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.metadata["kind"],
                       EventNotifyKind.calendarEvent.rawValue)
    }

    func testEventCreatedWhenSharingIsNotActiveEmitsSkippedNotActive() async {
        let rig = makeService(signedIn: false)

        rig.service.eventCreated(localEventId: "evt-1", title: "Doctor",
                                 startDate: fakeNow, durationMinutes: 45)
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0)
        let skipped = rig.bus.emittedEvents.filter {
            $0.eventType == "calendar_share_skipped_not_active"
        }
        XCTAssertEqual(skipped.count, 1,
                       "a signed-out / unconsented device still says WHY it shared nothing")
    }

    // MARK: - Scope ledger (2026-09-17)

    func testRefreshScopeStatusPublishesTheTokeninfoTruth() async {
        let rig = makeService()
        // The live token carries calendar but NOT contacts — the exact
        // 2026-09-17 device state that 403'd the People call while the
        // SDK's list still claimed the grant.
        rig.gateway.tokenScopesResult = ["https://www.googleapis.com/auth/calendar"]

        await rig.service.refreshScopeStatus()
        await drainMain()

        XCTAssertEqual(rig.service.status.scopeStatus, [
            "https://www.googleapis.com/auth/calendar": true,
            "https://www.googleapis.com/auth/contacts": false,
        ])
        let check = rig.bus.emittedEvents.filter {
            $0.eventType == "calendar_share_scope_check"
        }
        XCTAssertEqual(check.count, 1)
        XCTAssertEqual(check.first?.metadata["calendar"], "granted")
        XCTAssertEqual(check.first?.metadata["contacts"], "missing")
    }

    func testGrantMissingScopesRequestsExactlyTheGapAndRechecks() async {
        let rig = makeService()
        rig.gateway.tokenScopesResult = ["https://www.googleapis.com/auth/calendar"]
        await rig.service.refreshScopeStatus()
        await drainMain()
        // The grant lands: the next tokeninfo read answers with both.
        rig.gateway.tokenScopesResult = [
            "https://www.googleapis.com/auth/calendar",
            "https://www.googleapis.com/auth/contacts",
        ]

        let granted = await rig.service.grantMissingScopes()
        await drainMain()

        XCTAssertTrue(granted)
        XCTAssertEqual(rig.session.grantScopesRequests.count, 1)
        XCTAssertEqual(rig.session.grantScopesRequests.first,
                       ["https://www.googleapis.com/auth/contacts"],
                       "only the missing scope is asked for — never a full re-consent")
        // Three tokeninfo reads: the initial check, the direct post-grant
        // re-check, and the republish re-check the service runs last.
        // The published ledger truth itself is pinned in
        // testRefreshScopeStatusPublishesTheTokeninfoTruth.
        XCTAssertEqual(rig.gateway.tokenScopeCheckCalls, 3)
    }

    func testGrantMissingScopesWithNoGapAsksGoogleNothing() async {
        let rig = makeService()
        rig.gateway.tokenScopesResult = [
            "https://www.googleapis.com/auth/calendar",
            "https://www.googleapis.com/auth/contacts",
        ]
        await rig.service.refreshScopeStatus()
        await drainMain()

        let granted = await rig.service.grantMissingScopes()

        XCTAssertTrue(granted)
        XCTAssertTrue(rig.session.grantScopesRequests.isEmpty)
    }

    // MARK: - Sign out

    func testSignOutClearsTheLedgerAndSaysSo() async {
        let rig = makeService()
        let key = slotKey(UUID())
        rig.store.setGoogleEventID("g-1", for: key)
        rig.store.setFingerprint("fp-1", for: key)
        rig.store.enqueue(queuedCreate(key: key))
        rig.store.lastSyncAt = fakeNow

        rig.service.signOut()
        await drainMain()

        XCTAssertEqual(rig.session.signOutCalls, 1)
        XCTAssertTrue(rig.store.isEmpty,
                      "the map and queue are the WORKING state of a share that can no longer happen")
        XCTAssertTrue(rig.store.fingerprints.isEmpty,
                      "the fingerprints describe content as the PREVIOUS account saw it")
        XCTAssertNil(rig.store.lastSyncAt)
        XCTAssertEqual(rig.service.status.connection, .signedOut)

        let emitted = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_signed_out" }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.outcome, "success")
    }

    // MARK: - Inbound

    func testAlreadyImportedGoogleEventIsNotImportedTwice() async {
        let rig = makeService()
        let twinKey = CalendarShareKey.oneOff(kind: .calendarEvent,
                                              eventIdentifier: "evt-7")
        rig.store.setGoogleEventID("g-1", for: twinKey)
        rig.gateway.incomingPages = [GoogleIncomingPage(events: [incomingEvent(id: "g-1")],
                                                       nextSyncToken: "tok-1")]

        await rig.service.syncInbound()
        await drainMain()

        XCTAssertTrue(rig.gateway.acceptedEventIDs.isEmpty,
                      "an event already mirrored locally must not be accepted and imported a second time")
        XCTAssertTrue(rig.eventKit.created.isEmpty)
    }

    func testIncomingEventThatNeedsNoResponseIsIgnored() async {
        let rig = makeService()
        rig.gateway.incomingPages = [GoogleIncomingPage(
            events: [incomingEvent(id: "g-2", needsResponse: false)],
            nextSyncToken: "tok-1")]

        await rig.service.syncInbound()
        await drainMain()

        XCTAssertEqual(rig.gateway.listedSyncTokens.count, 1)
        XCTAssertTrue(rig.gateway.acceptedEventIDs.isEmpty,
                      "only an event whose elder attendee says needsAction is acted on")
        XCTAssertTrue(rig.eventKit.created.isEmpty)

        // The continuation token is persisted even when nothing was
        // imported — otherwise every poll rescans the same window.
        rig.gateway.incomingPages = [GoogleIncomingPage(events: [], nextSyncToken: "tok-2")]
        await rig.service.syncInbound()
        await drainMain()
        XCTAssertEqual(rig.gateway.listedSyncTokens.count, 2)
        guard rig.gateway.listedSyncTokens.count == 2 else { return }
        XCTAssertNil(rig.gateway.listedSyncTokens[0])
        XCTAssertEqual(rig.gateway.listedSyncTokens[1], "tok-1",
                       "the next poll asks for the incremental page")
    }

    func testDeniedCalendarAccessMakesNoInboundCallAtAll() async {
        for blocked in [CalendarAccess.denied, .restricted, .notDetermined] {
            let rig = makeService()
            rig.eventKit.access = blocked
            rig.gateway.incomingPages = [GoogleIncomingPage(events: [incomingEvent(id: "g-2")],
                                                            nextSyncToken: "tok-1")]

            await rig.service.syncInbound()
            await drainMain()

            XCTAssertTrue(rig.gateway.listedSyncTokens.isEmpty,
                          "without calendar access there is nowhere to put an accepted invitation — the pass does not even list")
            XCTAssertTrue(rig.eventKit.created.isEmpty)

            let skipped = rig.bus.emittedEvents.filter {
                $0.eventType == "calendar_share_inbound_skipped"
            }
            XCTAssertEqual(skipped.first?.outcome, "failure")
            XCTAssertEqual(skipped.first?.metadata["reason"], "no_calendar_access")
        }
    }

    func testOnLocalEventImportedFiresWhenSomethingWasImported() async {
        let rig = makeService()
        var importCallbacks = 0
        rig.service.onLocalEventImported = { importCallbacks += 1 }
        rig.gateway.incomingPages = [GoogleIncomingPage(events: [incomingEvent(id: "g-2")],
                                                       nextSyncToken: "tok-1")]

        await rig.service.syncInbound()
        await drainMain()

        XCTAssertEqual(rig.gateway.acceptedEventIDs, ["g-2"])
        XCTAssertEqual(rig.eventKit.created.count, 1)
        guard let written = rig.eventKit.created.first else {
            return XCTFail("the accepted invitation must be written into the local calendar")
        }
        XCTAssertNil(written.calendarIdentifier,
                     "the accepted invitation goes into the DEFAULT calendar so the existing import arms and fires it")
        XCTAssertEqual(importCallbacks, 1,
                       "the coordinator's cue to run the existing import now rather than at the next scan")
        XCTAssertNotNil(rig.store.lastSyncAt)
        XCTAssertEqual(
            rig.store.googleEventID(for: CalendarShareKey.oneOff(
                kind: .calendarEvent, eventIdentifier: "evt-1")),
            "g-2",
            "the pairing is remembered so a later deletion of the local event can still tombstone the twin")
    }

    func testOnLocalEventImportedDoesNotFireWhenNothingWasImported() async {
        let rig = makeService()
        var fired = false
        rig.service.onLocalEventImported = { fired = true }
        rig.gateway.incomingPages = [GoogleIncomingPage(
            events: [incomingEvent(id: "g-3", needsResponse: false)],
            nextSyncToken: nil)]

        await rig.service.syncInbound()
        await drainMain()

        XCTAssertFalse(fired)
    }

    // MARK: - Observability

    func testFlushedEventCarriesTheOutcomeAndCountsOnly() async {
        let rig = makeService()
        rig.gateway.createResults = ["g-1"]
        let key = slotKey(UUID())
        rig.store.enqueue(queuedCreate(key: key))

        await rig.service.flushPending()
        await drainMain()

        let success = rig.bus.emittedEvents.filter { $0.eventType == "calendar_share_flushed" }
        XCTAssertEqual(success.count, 1)
        XCTAssertEqual(success.first?.component, "calendar_share")
        XCTAssertEqual(success.first?.outcome, "success")
        XCTAssertEqual(success.first?.metadata["applied"], "1")

        let failing = makeService()
        failing.gateway.createResults = []
        failing.store.enqueue(queuedCreate(key: slotKey(UUID())))
        await failing.service.flushPending()
        await drainMain()

        let failure = failing.bus.emittedEvents.filter {
            $0.eventType == "calendar_share_flushed"
        }
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(failure.first?.outcome, "failure")
        XCTAssertEqual(failure.first?.metadata["applied"], "0")
    }

    /// The privacy rule, asserted generically over EVERY event the
    /// service emits: counts and classes only, never a title, never an
    /// address (constitution Privacy / the release-log gate).
    func testNoEmittedFieldEverCarriesATitleOrAnAddress() async {
        let rig = makeService()
        let title = "Amlodipine"
        let address = "maa@example.com"
        rig.gateway.createResults = ["g-1"]
        let entry = medicationEntry(name: title)
        let key = slotKey(entry.id)

        rig.service.acceptConsent()
        rig.service.reconcileMedication([entry])
        await waitUntil("the reconcile's flush to commit") {
            rig.store.fingerprint(for: key) != nil
        }
        rig.gateway.incomingPages = [GoogleIncomingPage(
            events: [incomingEvent(id: "g-2", title: title)], nextSyncToken: "tok-1")]
        await rig.service.syncInbound()
        await drainMain()

        // Force the refusal on the CALL itself (the family calendar is
        // opened again first, so the pass really reaches the mutation),
        // which is the honest way into the pause path — see the pause
        // test above.
        rig.gateway.ensureFamilyCalendarResults = ["family-cal"]
        rig.gateway.createResults = []
        rig.gateway.errorClassAfterFailure = .unauthorized
        rig.store.enqueue(queuedCreate(key: key, title: title))
        await rig.service.flushPending()
        await drainMain()

        rig.service.revokeConsent()
        rig.service.signOut()
        await drainMain()

        XCTAssertFalse(rig.bus.emittedEvents.isEmpty,
                       "the sequence must actually emit for the scan to be worth anything")
        let types = Set(rig.bus.emittedEvents.map(\.eventType))
        for expected in ["calendar_share_consent_accepted",
                         "calendar_share_consent_revoked",
                         "calendar_share_signed_out",
                         "calendar_share_reconciled",
                         "calendar_share_flushed",
                         "calendar_share_flush_paused",
                         "calendar_share_inbound"] {
            XCTAssertTrue(types.contains(expected), "expected \(expected) to be emitted")
        }

        for event in rig.bus.emittedEvents {
            var fields = [event.eventType, event.outcome, event.errorCode ?? ""]
            fields += event.metadata.map { "\($0.key)=\($0.value)" }
            for field in fields {
                let haystack = field.lowercased()
                XCTAssertFalse(haystack.contains(title.lowercased()),
                               "\(event.eventType) leaked the event title in \"\(field)\"")
                XCTAssertFalse(haystack.contains(address.lowercased()),
                               "\(event.eventType) leaked a family address in \"\(field)\"")
            }
        }
    }

    // MARK: - Free-form events (rich-events task, 2026-09-17)

    /// A tracked native event — `recordsByIdentifier` is what
    /// `fetchEvent(identifier:)` answers with, so a test states exactly
    /// what the event looks like NOW.
    private func nativeEvent(id: String = "evt-1",
                             title: String = "Doctor",
                             start: Date? = nil,
                             durationMinutes: Int = 30,
                             location: String? = nil,
                             isCanceled: Bool = false) -> CalendarEventRecord {
        CalendarEventRecord(
            eventIdentifier: id, calendarIdentifier: "home-calendar",
            title: title, notes: nil, startDate: start ?? fakeNow,
            isAllDay: false, isCanceled: isCanceled, recurrence: nil,
            location: location, durationMinutes: durationMinutes)
    }

    private func freeFormKey(_ eventId: String) -> String {
        CalendarShareKey.oneOff(kind: .calendarEvent, eventIdentifier: eventId)
    }

    /// A twin this device already shared: an id AND the fingerprint of
    /// the content it was shared with. Both are needed before a pass can
    /// tell "nothing changed" from "the family retimed it".
    private func seedSharedTwin(_ rig: Rig, eventId: String,
                                googleEventID: String = "g-1",
                                sharedEvent: CalendarEventRecord) {
        let key = freeFormKey(eventId)
        _ = rig.store.setGoogleEventID(googleEventID, for: key)
        guard let draft = CalendarShareMapper.calendarEventDraft(
            title: sharedEvent.title, startDate: sharedEvent.startDate,
            durationMinutes: sharedEvent.durationMinutes,
            contacts: testContacts, notifySettings: notifySettings,
            location: sharedEvent.location) else {
            return XCTFail("the test's contact must be eligible for a twin to exist")
        }
        _ = rig.store.setFingerprint(CalendarShareMapper.fingerprint(of: draft),
                                     for: key)
    }

    /// The whole point of the pass (design §3): the elder or the family
    /// retimes the appointment in the Calendar app, and the family's
    /// Google copy follows.
    func testFreeFormReconcileCarriesARetimeToTheTwin() async {
        let rig = makeService()
        rig.gateway.updateResults = [true]
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent(start: fakeNow))
        let moved = nativeEvent(title: "Dr Sharma",
                                start: fakeNow.addingTimeInterval(3600),
                                durationMinutes: 45)
        rig.eventKit.recordsByIdentifier["evt-1"] = moved

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await waitUntil("the retimed twin to reach Google") {
            rig.gateway.updatedCalls.count == 1
        }

        XCTAssertEqual(rig.gateway.updatedCalls.first?.id, "g-1",
                       "the twin is found by the ledger's own id, never by title/time")
        let draft = rig.gateway.updatedCalls.first?.draft
        XCTAssertEqual(draft?.title, "Dr Sharma")
        XCTAssertEqual(draft?.startDate, moved.startDate)
        XCTAssertEqual(draft?.durationMinutes, 45,
                       "an edit that shortened the event must reach the family's copy")
        XCTAssertEqual(rig.store.pendingCount, 0,
                       "a 404-free update leaves nothing behind in the queue")
    }

    /// An address added (or corrected) in the Calendar app is content the
    /// family sees on the invitation, so it has to reach the twin — which
    /// it only does because the fingerprint covers `location`.
    func testFreeFormReconcileCarriesAnAddressEditToTheTwin() async {
        let rig = makeService()
        rig.gateway.updateResults = [true]
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent())
        let addressed = nativeEvent(location: "  Tilganga, Kathmandu  ")
        rig.eventKit.recordsByIdentifier["evt-1"] = addressed

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await waitUntil("the re-addressed twin to reach Google") {
            rig.gateway.updatedCalls.count == 1
        }

        XCTAssertEqual(rig.gateway.updatedCalls.first?.draft.location,
                       "Tilganga, Kathmandu",
                       "normalized at the mapper, so no blank ever reaches Google")
    }

    func testFreeFormReconcileIsSilentWhenNothingChanged() async {
        let rig = makeService()
        let unchanged = nativeEvent()
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: unchanged)
        rig.eventKit.recordsByIdentifier["evt-1"] = unchanged

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await drainMain()

        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "a launch over unchanged events must send nothing at all — "
                      + "the fingerprint is what makes that possible")
    }

    /// The event is gone (deleted in the Calendar app, or by the Events
    /// form): the twin must go with it, or the family keeps a doctor's
    /// appointment that no longer exists.
    func testFreeFormReconcileTombstonesAVanishedEvent() async {
        let rig = makeService()
        rig.gateway.deleteResults = [true]
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent())
        // No record in recordsByIdentifier — it is gone.

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await waitUntil("the tombstone to reach Google") {
            rig.gateway.deletedIDs == ["g-1"]
        }
        await drainMain()

        XCTAssertNil(rig.store.googleEventID(for: freeFormKey("evt-1")),
                     "the ledger forgets a twin Google has confirmed gone")
    }

    func testFreeFormReconcileTombstonesACanceledEvent() async {
        let rig = makeService()
        rig.gateway.deleteResults = [true]
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent())
        rig.eventKit.recordsByIdentifier["evt-1"] = nativeEvent(isCanceled: true)

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await waitUntil("the canceled event's twin to be removed") {
            rig.gateway.deletedIDs == ["g-1"]
        }
    }

    /// The snapshot is the SIDE INDEX, not the ledger: an invitation this
    /// device imported has a twin too (`importLocally`), but that twin is
    /// the organizer's own event. Treating every `calendarEvent:` key as
    /// ours would delete the family's event from their own calendar.
    func testFreeFormReconcileLeavesImportedTwinsAlone() async {
        let rig = makeService()
        rig.gateway.deleteResults = [true, true]
        let importedKey = freeFormKey("invitation-1")
        _ = rig.store.setGoogleEventID("g-imported", for: importedKey)
        // The imported event is not in the side index, so the pass is
        // never told about it — and there is no record for it either
        // (an imported invitation the family has already answered).
        seedSharedTwin(rig, eventId: "evt-ours", googleEventID: "g-ours",
                       sharedEvent: nativeEvent(id: "evt-ours"))

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-ours"])
        await waitUntil("our vanished twin to be removed") {
            rig.gateway.deletedIDs == ["g-ours"]
        }
        await drainMain()

        XCTAssertEqual(rig.store.googleEventID(for: importedKey), "g-imported",
                       "an imported invitation's twin is the organizer's event — "
                       + "it must survive a pass that is not about it")
    }

    /// Without read access every lookup answers nil, which this pass
    /// would read as "every event is gone" and answer with a mass delete.
    func testFreeFormReconcileRefusesToRunWithoutFullCalendarAccess() async {
        let rig = makeService()
        rig.eventKit.access = .writeOnly
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent())

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await drainMain()

        XCTAssertTrue(rig.gateway.callLog.isEmpty, "nothing deleted, nothing written")
        XCTAssertEqual(rig.store.pendingCount, 0)
        XCTAssertTrue(rig.bus.emittedEvents.contains {
            $0.eventType == "calendar_share_events_skipped"
                && $0.metadata["reason"] == "no_calendar_access"
        }, "the skip is observable — a silently missing reconcile reads as 'nothing to do'")
        XCTAssertEqual(rig.store.googleEventID(for: freeFormKey("evt-1")), "g-1",
                       "the ledger survives untouched for the next pass with access")
    }

    /// Nobody eligible any more (the family removed the contact, or the
    /// notify policy changed) means no draft — and the pass then reads
    /// that exactly as the other kinds do: the twin is WITHDRAWN, not
    /// left on a calendar whose invitees the policy no longer covers.
    func testFreeFormReconcileWithdrawsATwinWhenNobodyIsEligible() async {
        let rig = makeService()
        rig.gateway.deleteResults = [true]
        seedSharedTwin(rig, eventId: "evt-1", sharedEvent: nativeEvent())
        rig.eventKit.recordsByIdentifier["evt-1"] = nativeEvent()
        testContacts = []

        rig.service.reconcileFreeFormEvents(trackedEventIds: ["evt-1"])
        await waitUntil("the now-unshareable twin to be withdrawn") {
            rig.gateway.deletedIDs == ["g-1"]
        }

        XCTAssertTrue(rig.gateway.updatedCalls.isEmpty,
                      "nothing is written over it either — the twin goes, it is not "
                      + "silently re-authored")
    }

    /// `eventCreated` now carries the address (rich-events task): the
    /// twin the family receives on the FIRST share must already have it,
    /// not just after the next reconcile.
    func testEventCreatedCarriesTheAddressIntoTheQueuedTwin() async {
        let rig = makeService()

        rig.service.eventCreated(localEventId: "evt-1", title: "Doctor",
                                 startDate: fakeNow, durationMinutes: 45,
                                 location: "  Patan Durbar Square  ")
        await drainMain()

        XCTAssertEqual(rig.store.pending.map(\.key), [freeFormKey("evt-1")])
        XCTAssertEqual(rig.store.pending.first?.location, "Patan Durbar Square",
                       "normalized and carried inline so the queued operation is "
                       + "replayable on its own")
    }

    func testEventCreatedWithoutAnAddressQueuesNoLocation() async {
        let rig = makeService()

        rig.service.eventCreated(localEventId: "evt-1", title: "Doctor",
                                 startDate: fakeNow, durationMinutes: 45,
                                 location: "   ")
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 1)
        XCTAssertNil(rig.store.pending.first?.location,
                     "a blank address is no address — no empty location reaches Google")
    }

    /// The Events form's delete: the app's first in-app calendar-event
    /// deletion, and the reason `eventDeleted` finally has a caller.
    ///
    /// Unlike the reconcile passes — which flush what they just queued —
    /// the notification-driven actions only ENQUEUE, exactly as
    /// `eventCreated` does: the removal waits for the next foreground or
    /// interval pass, so a delete that happens with no network is
    /// recorded rather than lost.
    func testEventDeletedQueuesATombstoneForTheTwin() async {
        let rig = makeService()
        rig.gateway.deleteResults = [true]
        _ = rig.store.setGoogleEventID("g-1", for: freeFormKey("evt-1"))

        rig.service.eventDeleted(localEventId: "evt-1")
        await drainMain()

        XCTAssertTrue(rig.gateway.callLog.isEmpty,
                      "nothing reaches Google at delete time — the pass does that")
        XCTAssertEqual(rig.store.pending.map(\.key), [freeFormKey("evt-1")])
        XCTAssertEqual(rig.store.pending.first?.action, .delete,
                       "a tombstone, not an upsert: the local event is gone")
        XCTAssertEqual(rig.store.pending.first?.googleEventID, "g-1",
                       "the ledger's id rides along inline, so the pass can delete "
                       + "the right twin without the event it came from")

        await rig.service.flushPending()
        await drainMain()

        XCTAssertEqual(rig.gateway.deletedIDs, ["g-1"])
        XCTAssertNil(rig.store.googleEventID(for: freeFormKey("evt-1")))
        XCTAssertEqual(rig.store.pendingCount, 0)
    }

    /// Both gates closed: NOTHING is queued — a tombstone waiting on a
    /// connection the family never made would make the Settings card's
    /// pending count mean "waiting on a decision", not "waiting on
    /// Google". Nothing is lost by it: the ledger keeps the key, and
    /// `cleanupVanishedEvents()` queues the same tombstone on the first
    /// pass after sharing is switched on.
    func testEventDeletedWhileSignedOutQueuesNothing() async {
        let rig = makeService(signedIn: false)
        _ = rig.store.setGoogleEventID("g-1", for: freeFormKey("evt-1"))

        rig.service.eventDeleted(localEventId: "evt-1")
        await drainMain()

        XCTAssertEqual(rig.store.pendingCount, 0)
        XCTAssertEqual(rig.store.googleEventID(for: freeFormKey("evt-1")), "g-1",
                       "the ledger remembers the twin, so switching sharing on "
                       + "still cleans it up")
        XCTAssertTrue(rig.gateway.callLog.isEmpty)
    }

    // MARK: - Main-queue helpers

    /// Runs the service's pending main-queue hops to completion.
    ///
    /// The service publishes status and commits its ledger from
    /// `DispatchQueue.main.async` hops. This block is enqueued AFTER the
    /// action returned and the main queue is serial, so by the time it
    /// runs every hop the action scheduled has run too. Awaiting the
    /// continuation (rather than blocking) also works when the test body
    /// itself is on the main thread — the suspension frees the queue.
    private func drainMain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Polls `condition` while draining the main queue.
    ///
    /// A reconcile auto-flushes on a detached `Task` with no completion
    /// handle, so there is nothing to await; polling is the honest way to
    /// observe the end of that pass.
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await drainMain()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

// MARK: - Fakes

/// The Google account seam. `isConfigured` is the graceful-degradation
/// hinge: with no client id the SDK cannot even be initialised, and every
/// surface has to say so instead of offering a button that cannot work.
private final class FakeShareSession: GoogleAccountSessionProtocol {
    var isConfigured = true
    var isSignedIn = false
    var accountEmail: String? = "maa@example.com"
    /// The Calendar/contacts grant (2026-09-17). Default TRUE so every
    /// existing rig stays a fully-connected household, and set false by
    /// the tests that drive the "signed in, cannot share" state.
    var hasRequiredScopes = true
    /// What the interactive flow reports.
    var signInOutcome: GoogleSessionOutcome = .connected
    /// What the launch restore reports. Default `.unavailable`: the
    /// ordinary state of a fake with no stored session, so a rig that
    /// never mentions restore keeps behaving exactly as before.
    var restoreOutcome: GoogleSessionOutcome = .unavailable
    private(set) var signInCalls = 0
    private(set) var createAccountCalls = 0
    private(set) var signOutCalls = 0
    private(set) var restoreCalls = 0
    private(set) var accessTokenCalls = 0

    /// [SCOPE-LEDGER] The baseline the ledger compares against; tests can
    /// narrow it to drive a partial-grant household.
    var requiredScopes: [String] = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/contacts",
    ]
    /// What `grantScopes` reports and records.
    var grantScopesResult = true
    private(set) var grantScopesRequests: [[String]] = []

    func grantScopes(_ scopes: [String]) async -> Bool {
        grantScopesRequests.append(scopes)
        return grantScopesResult
    }

    /// Signs the fake in (or not) exactly the way the real session does:
    /// `.connected` leaves a scoped session, `.connectedWithoutScopes`
    /// leaves a signed-in one WITHOUT the grant, and the other two leave
    /// no session at all.
    func signIn() async -> GoogleSessionOutcome {
        signInCalls += 1
        apply(signInOutcome)
        return signInOutcome
    }

    func createAccount() async -> GoogleSessionOutcome {
        createAccountCalls += 1
        apply(signInOutcome)
        return signInOutcome
    }

    /// The launch path, with the same outcome semantics as the
    /// interactive ones: a restore that comes back `.unavailable` leaves
    /// the fake signed out, which is the state the service has to render
    /// honestly.
    func restorePreviousSession() async -> GoogleSessionOutcome {
        restoreCalls += 1
        apply(restoreOutcome)
        return restoreOutcome
    }

    private func apply(_ outcome: GoogleSessionOutcome) {
        switch outcome {
        case .connected:
            isSignedIn = true
            hasRequiredScopes = true
        case .connectedWithoutScopes:
            isSignedIn = true
            hasRequiredScopes = false
        case .cancelled, .unavailable:
            break   // no session was created; whatever was there stays
        }
    }

    func signOut() {
        signOutCalls += 1
        isSignedIn = false
        hasRequiredScopes = false
        accountEmail = nil
    }

    func accessToken() async -> String? {
        accessTokenCalls += 1
        return isSignedIn ? "fake-token" : nil
    }
}

/// The Google Calendar + People seam. Every method records what it was
/// asked for, so the "the gateway receives NO calls" rules are asserted
/// on the RECORDED CALLS rather than on a count.
private final class FakeShareGateway: GoogleCalendarGatewayProtocol {

    /// Canned answers, consumed in call order. An exhausted list means
    /// the call FAILS (nil / false) — the retry path.
    var ensureFamilyCalendarResults: [String?] = ["family-cal"]
    var createResults: [String] = []
    var updateResults: [Bool] = []
    var deleteResults: [Bool] = []
    var incomingPages: [GoogleIncomingPage] = []
    var ensureContactResult = true
    var acceptInvitationResult = true

    /// What `lastErrorClass` reads as after a failed call — the
    /// service's pause-vs-retry input. Settable so a test can start the
    /// service in an already-paused state.
    var lastErrorClass: GoogleShareError?
    var errorClassAfterFailure: GoogleShareError? = .transport("test")

    /// [SCOPE-LEDGER] The tokeninfo answer — URL-form scopes the live
    /// token carries. nil = the check could not run.
    var tokenScopesResult: [String]? = nil
    private(set) var tokenScopeCheckCalls = 0

    func fetchTokenScopes() async -> [String]? {
        tokenScopeCheckCalls += 1
        return tokenScopesResult
    }

    private(set) var ensureFamilyCalendarCalls = 0
    private(set) var createdDrafts: [CalendarTwinDraft] = []
    private(set) var updatedCalls: [(id: String, draft: CalendarTwinDraft)] = []
    private(set) var deletedIDs: [String] = []
    private(set) var ensuredContactEmails: [String] = []
    /// The full `ensureContact` argument list — the name and phone matter
    /// as much as the address (design §2.2 bullet 4: a contact created on
    /// the family's side must arrive with the number the elder can be
    /// reached on, not as a bare address).
    private(set) var ensuredContacts: [(email: String, name: String?, phone: String?)] = []
    private(set) var listedSyncTokens: [String?] = []
    private(set) var acceptedEventIDs: [String] = []

    /// Every call the service actually made, as readable labels. Grouped
    /// by call kind (not ordered across kinds) — the point is that a
    /// stray call of a DIFFERENT kind cannot hide behind a matching
    /// total.
    var callLog: [String] {
        var log = Array(repeating: "ensureFamilyCalendar",
                        count: ensureFamilyCalendarCalls)
        log += createdDrafts.map { "createEvent:\($0.title)" }
        log += updatedCalls.map { "updateEvent:\($0.id)" }
        log += deletedIDs.map { "deleteEvent:\($0)" }
        log += ensuredContactEmails.map { "ensureContact:\($0)" }
        log += listedSyncTokens.map { _ in "listIncoming" }
        log += acceptedEventIDs.map { "acceptInvitation:\($0)" }
        return log
    }

    func ensureFamilyCalendar() async -> String? {
        ensureFamilyCalendarCalls += 1
        guard !ensureFamilyCalendarResults.isEmpty else {
            lastErrorClass = errorClassAfterFailure
            return nil
        }
        let result = ensureFamilyCalendarResults.removeFirst()
        lastErrorClass = result == nil ? errorClassAfterFailure : nil
        return result
    }

    func createEvent(_ draft: CalendarTwinDraft) async -> String? {
        createdDrafts.append(draft)
        guard !createResults.isEmpty else {
            lastErrorClass = errorClassAfterFailure
            return nil
        }
        lastErrorClass = nil
        return createResults.removeFirst()
    }

    func updateEvent(id: String, with draft: CalendarTwinDraft) async -> Bool {
        updatedCalls.append((id, draft))
        guard !updateResults.isEmpty else {
            lastErrorClass = errorClassAfterFailure
            return false
        }
        let ok = updateResults.removeFirst()
        lastErrorClass = ok ? nil : errorClassAfterFailure
        return ok
    }

    func deleteEvent(id: String) async -> Bool {
        deletedIDs.append(id)
        guard !deleteResults.isEmpty else {
            lastErrorClass = errorClassAfterFailure
            return false
        }
        let ok = deleteResults.removeFirst()
        lastErrorClass = ok ? nil : errorClassAfterFailure
        return ok
    }

    func ensureContact(email: String, name: String?, phone: String?) async -> Bool {
        ensuredContactEmails.append(email)
        ensuredContacts.append((email, name, phone))
        return ensureContactResult
    }

    func listIncoming(syncToken: String?) async -> GoogleIncomingPage? {
        listedSyncTokens.append(syncToken)
        guard !incomingPages.isEmpty else {
            lastErrorClass = errorClassAfterFailure
            return nil
        }
        lastErrorClass = nil
        return incomingPages.removeFirst()
    }

    func acceptInvitation(eventId: String) async -> Bool {
        acceptedEventIDs.append(eventId)
        return acceptInvitationResult
    }
}

/// The EventKit seam, used only by the inbound path. Records the drafts
/// it was asked to write so a test can prove WHERE an accepted
/// invitation lands.
private final class FakeShareEventKit: EventKitCalendarGateway {
    var access: CalendarAccess = .fullAccess
    private(set) var created: [(draft: CalendarEventDraft,
                                calendarIdentifier: String?)] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var fragmentRemovalRequests: [String] = []
    /// The native events a test has deleted "in the Calendar app" — the
    /// stale-twin sweep's only input. A set rather than an "exists"
    /// closure so the default (empty) reads as the honest common case:
    /// nothing has vanished unless a test says so.
    var vanishedIdentifiers: Set<String> = []
    private(set) var existenceChecks: [String] = []

    var eventsAccess: CalendarAccess { access }

    func requestFullAccess() async -> Bool { true }

    func ensureSahayakCalendar(knownIdentifier: String?) -> String? { "sahayak-1" }

    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] { [] }

    /// The free-form share reconcile's by-identifier read (rich-events
    /// task, 2026-09-17). A dictionary rather than a window fetch, so a
    /// test can state exactly what one tracked event looks like NOW — the
    /// retimed / re-addressed / deleted cases — without inventing dates
    /// that fall inside a scan window.
    var recordsByIdentifier: [String: CalendarEventRecord] = [:]

    func fetchEvent(identifier: String) -> CalendarEventRecord? {
        recordsByIdentifier[identifier]
    }

    func eventExists(identifier: String) -> Bool {
        existenceChecks.append(identifier)
        return !vanishedIdentifiers.contains(identifier)
    }

    func createEvent(_ draft: CalendarEventDraft,
                     in calendarIdentifier: String?) -> String? {
        created.append((draft, calendarIdentifier))
        return "evt-\(created.count)"
    }

    func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool { false }

    func removeEvent(identifier: String) -> Bool {
        removedIdentifiers.append(identifier)
        return false
    }

    func removeEvents(matchingNotesFragment fragment: String) -> Int {
        fragmentRemovalRequests.append(fragment)
        return 0
    }
}
