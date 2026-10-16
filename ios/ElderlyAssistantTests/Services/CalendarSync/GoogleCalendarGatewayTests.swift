import XCTest
@testable import ElderlyAssistant

/// The REST gateway's rules, asserted with no network and no session: the
/// request the gateway builds (URL, method, headers, body), the
/// find-or-create behaviour, the inbound filter and the goal-state rules.
///
/// Everything here goes through `FakeShareTransport`, so a test that fails
/// is a rule this layer got wrong rather than a flake in Google's API —
/// the same split `GeminiClientTests` uses for its client.
final class GoogleCalendarGatewayTests: XCTestCase {

    private var session: FakeSession!
    private var transport: FakeShareTransport!
    private var bus: RecordingObservabilityBus!

    /// A fixed clock, so the inbound window is a literal string in the
    /// assertions rather than "whatever `Date()` said".
    private let now = rfc3339Date("2026-09-16T12:00:00Z")
    /// A realistic calendar id — it carries the `@` that makes the path
    /// escaping load-bearing, which a plain "family" id would not.
    private let familyCalendarID = "family@group.calendar.google.com"

    override func setUp() {
        super.setUp()
        session = FakeSession()
        transport = FakeShareTransport()
        bus = RecordingObservabilityBus()
    }

    private func makeGateway() -> GoogleCalendarGateway {
        GoogleCalendarGateway(session: session,
                              transport: transport,
                              observabilityBus: bus,
                              now: { [now] in now })
    }

    // MARK: - Scope ledger (2026-09-17)

    func testFetchTokenScopesParsesTheTokeninfoScopeList() async {
        transport.enqueue(json: [
            "scope": "https://www.googleapis.com/auth/calendar "
                + "https://www.googleapis.com/auth/contacts openid"
        ])
        let gateway = makeGateway()

        let scopes = await gateway.fetchTokenScopes()

        XCTAssertEqual(scopes, [
            "https://www.googleapis.com/auth/calendar",
            "https://www.googleapis.com/auth/contacts",
            "openid",
        ])
    }

    func testInboundWithSyncTokenNeverCombinesSingleEvents() async {
        // [SYNCTOKEN-FIX] Google rejects `syncToken` + `singleEvents`
        // with 400 — the query must be mode-exclusive. The first call
        // (no token) carries singleEvents; a stored-token call must not.
        transport.enqueue(json: ["items": [], "nextSyncToken": "tok-1"])
        let gateway = makeGateway()
        _ = await gateway.listIncoming(syncToken: nil)
        transport.enqueue(json: ["items": [], "nextSyncToken": "tok-2"])
        _ = await gateway.listIncoming(syncToken: "tok-1")

        let firstURL = transport.requests[0].url
        let secondURL = transport.requests[1].url
        XCTAssertTrue(firstURL?.query?.contains("singleEvents=true") == true)
        XCTAssertTrue(firstURL?.query?.contains("timeMin=") == true)
        XCTAssertTrue(secondURL?.query?.contains("syncToken=tok-1") == true)
        XCTAssertFalse(secondURL?.query?.contains("singleEvents") == true,
                       "a sync-token page must never combine with singleEvents")
        XCTAssertFalse(secondURL?.query?.contains("timeMin") == true)
    }

    func testInboundDecodeFailureNamesTheSchemaField() async {
        // A 2xx whose `items` is not an array — the decode must fail
        // AND name the structure of the mismatch so a Release console
        // can show exactly which Google field broke it.
        transport.enqueue(json: ["items": "not-an-array"])
        let gateway = makeGateway()

        _ = await gateway.listIncoming(syncToken: nil)

        XCTAssertTrue(bus.events(named: "calendar_share_inbound_failed").contains {
            $0.metadata["decode_detail"] == "type_mismatch:items"
        })
    }

    func testFetchTokenScopesReportsFailureWithoutABody() async {
        transport.enqueue(json: ["scope": ""])
        let gateway = makeGateway()

        let scopes = await gateway.fetchTokenScopes()

        XCTAssertNil(scopes)
        XCTAssertTrue(bus.events(named: "calendar_share_token_scope_check")
            .contains { $0.outcome == "failure" })
    }

    // MARK: - Family calendar

    func testEnsureFamilyCalendarReturnsTheExistingCalendarAndCachesIt() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        let gateway = makeGateway()

        let found = await gateway.ensureFamilyCalendar()
        let again = await gateway.ensureFamilyCalendar()

        XCTAssertEqual(found, familyCalendarID)
        XCTAssertEqual(again, familyCalendarID)
        // One request for two calls: the id is cached, and a flush that
        // queues ten operations must not re-ask Google ten times.
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
        XCTAssertEqual(transport.requests.first?.url?.path(percentEncoded: false),
                       "/calendar/v3/users/me/calendarList")
        XCTAssertEqual(queryValue(transport.requests.first?.url, "maxResults"), "250")
        XCTAssertNil(gateway.lastErrorClass)
    }

    func testEnsureFamilyCalendarCreatesWhenNoCalendarMatchesTheExactSummary() async {
        // A calendar the family named almost the same thing must NOT be
        // adopted: writing twins into someone else's calendar is worse
        // than making a second one.
        transport.enqueue(json: ["items": [["id": "work-calendar",
                                            "summary": "Sahayak family calendar"]]])
        transport.enqueue(json: ["id": "created-family-calendar"])
        let gateway = makeGateway()

        let found = await gateway.ensureFamilyCalendar()

        XCTAssertEqual(found, "created-family-calendar")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.httpMethod, "POST")
        XCTAssertEqual(transport.requests.last?.url?.path(percentEncoded: false),
                       "/calendar/v3/calendars")
        XCTAssertEqual(bodyJSON(transport.requests.last)["summary"] as? String, "Sahayak Family")
    }

    // MARK: - Create

    func testCreateEventPostsTheDraftWithAttendeesRecurrenceAndADerivedEnd() async throws {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["id": "google-event-1"])
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertEqual(id, "google-event-1")
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://www.googleapis.com/calendar/v3/calendars/family%40group.calendar.google.com/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = bodyJSON(request)
        XCTAssertEqual(body["summary"] as? String, "Metformin")

        // Attendees: the draft's addresses, in order, as Google's
        // `[{"email": …}]` shape.
        let attendees = try XCTUnwrap(body["attendees"] as? [[String: String]])
        XCTAssertEqual(attendees, [["email": "kin@example.com"], ["email": "daughter@example.com"]])

        // Recurrence through `CalendarRecurrenceRule` — the rule that
        // makes the family see a daily series rather than one dose.
        XCTAssertEqual(body["recurrence"] as? [String], ["RRULE:FREQ=DAILY"])

        // The start is the draft's instant, RFC 3339 in UTC, and the
        // duration becomes the END — the app's sources carry minutes, not
        // an end time.
        let start = try XCTUnwrap(body["start"] as? [String: String])
        let end = try XCTUnwrap(body["end"] as? [String: String])
        XCTAssertEqual(start["dateTime"], "2026-09-16T08:00:00Z")
        XCTAssertEqual(end["dateTime"], "2026-09-16T08:30:00Z")
        // The zone travels explicitly: the instant is what rings, the
        // zone is what Google anchors the series to.
        XCTAssertEqual(start["timeZone"], "Asia/Kathmandu")
        XCTAssertEqual(end["timeZone"], "Asia/Kathmandu")
        XCTAssertNil(gateway.lastErrorClass)
    }

    func testCreateEventOmitsRecurrenceForAOneOff() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["id": "google-event-2"])
        let gateway = makeGateway()

        _ = await gateway.createEvent(makeDraft(recurrence: nil))

        let body = bodyJSON(transport.requests.last)
        XCTAssertNil(body["recurrence"])
    }

    func testWeeklyRecurrenceRendersTheDayList() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["id": "google-event-3"])
        let gateway = makeGateway()

        // 1 = Sunday in the app's numbering, so 2 and 5 are Monday and
        // Thursday.
        _ = await gateway.createEvent(makeDraft(recurrence: .weekly(weekdays: [5, 2])))

        let body = bodyJSON(transport.requests.last)
        XCTAssertEqual(body["recurrence"] as? [String],
                       ["RRULE:FREQ=WEEKLY;BYDAY=MO,TH"])
    }

    // MARK: - Update

    func testUpdateEventPutsToTheEventURLWithTheSameBodyConstruction() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["id": "google-event-1"])
        let gateway = makeGateway()

        let updated = await gateway.updateEvent(id: "google-event-1",
                                                with: makeDraft(title: "Metformin 500mg"))

        XCTAssertTrue(updated)
        let request = transport.requests.last
        XCTAssertEqual(request?.httpMethod, "PUT")
        XCTAssertEqual(request?.url?.absoluteString,
                       "https://www.googleapis.com/calendar/v3/calendars/family%40group.calendar.google.com/events/google-event-1")
        let body = bodyJSON(request)
        XCTAssertEqual(body["summary"] as? String, "Metformin 500mg")
        // The recurrence is re-sent: an update that dropped it would
        // silently un-series a shared medication.
        XCTAssertNotNil(body["recurrence"])
    }

    // MARK: - Delete

    func testDeleteEventTreatsA404AsTheGoalStateBeingReached() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["error": ["code": 404]], status: 404)
        let gateway = makeGateway()

        let deleted = await gateway.deleteEvent(id: "google-event-1")

        XCTAssertTrue(deleted)
        // Not a failure: the twin's absence is what the caller wanted, and
        // reporting an error here would make the queue retry it forever.
        XCTAssertNil(gateway.lastErrorClass)
        XCTAssertTrue(bus.contains("calendar_share_delete_already_gone"))
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
    }

    func testDeleteEventReportsANon404FailureClass() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: [:], status: 500)
        let gateway = makeGateway()

        let deleted = await gateway.deleteEvent(id: "google-event-1")

        XCTAssertFalse(deleted)
        XCTAssertEqual(gateway.lastErrorClass, .server(500))
    }

    // MARK: - Failure classes

    func testA401IsRecordedAsUnauthorizedAndIsNotRetryable() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["error": ["code": 401]], status: 401)
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass, .unauthorized)
        // The service pauses on this rather than retrying: a revoked token
        // needs the user, not a backoff.
        XCTAssertEqual(gateway.lastErrorClass?.isRetryable, false)
        XCTAssertTrue(bus.contains("calendar_share_create_failed"))
        XCTAssertEqual(bus.events(named: "calendar_share_create_failed").last?.errorCode,
                       "unauthorized")
    }

    /// 403 is NOT the same fault as 401 (2026-09-17), and the whole point
    /// of splitting them is that the log and the card must never merge
    /// them again: 401 is a token Google will not accept at all, 403 is a
    /// valid token that is not allowed to do this — which, right after a
    /// consent sheet, means the token in hand was minted for the wrong
    /// scopes. Same pause for the queue, different diagnosis for the
    /// family.
    func testA403IsRecordedAsInsufficientScopesNotUnauthorized() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["error": ["code": 403]], status: 403)
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass, .insufficientScopes)
        XCTAssertNotEqual(gateway.lastErrorClass, .unauthorized,
                          "the two refusals are different faults and must not read as one")
        XCTAssertEqual(gateway.lastErrorClass?.isRetryable, false)
        XCTAssertEqual(gateway.lastErrorClass?.isAuthorizationFailure, true,
                       "both refusals stop the pass — the queue does the same thing about either")
        XCTAssertEqual(bus.events(named: "calendar_share_create_failed").last?.errorCode,
                       "insufficient_scopes")
    }

    /// A 401 stops the pass as well, and the classification above is the
    /// only difference between the two — asserted together so a future
    /// edit cannot quietly drop one of them out of the pause.
    func testBothRefusalsStopThePassAndNeitherIsRetryable() {
        XCTAssertTrue(GoogleShareError.unauthorized.isAuthorizationFailure)
        XCTAssertTrue(GoogleShareError.insufficientScopes.isAuthorizationFailure)
        XCTAssertFalse(GoogleShareError.unauthorized.isRetryable)
        XCTAssertFalse(GoogleShareError.insufficientScopes.isRetryable)
    }

    /// The INBOUND refusal (2026-09-17) — the path a device console showed
    /// behaving differently from the family-calendar one, and the reason
    /// the status is classified before the body is read at all.
    ///
    /// Google's error document is a JSON object like any other: decoded as
    /// a page it yields no items and no sync token, so a body-first
    /// implementation would call a REFUSED listing a successful empty one
    /// and silently drop every unanswered invitation the elder has. With
    /// the status gate first, the same response is what it is — a scope
    /// refusal — and both the card and the log say `insufficient_scopes`.
    func testAnInbound403IsClassifiedAsInsufficientScopesNotMalformedResponse() async {
        // A realistic 403 body: the shape Google sends when the token was
        // minted for the wrong scopes, and one that would decode into the
        // listing's own shape as "no items".
        transport.enqueue(json: ["error": ["code": 403,
                                           "status": "PERMISSION_DENIED",
                                           "message": "Request had insufficient authentication scopes."]],
                          status: 403)
        let gateway = makeGateway()

        let page = await gateway.listIncoming(syncToken: nil)

        XCTAssertNil(page,
                     "a refused listing is not an empty one — nothing may be reported as 'no invitations'")
        XCTAssertEqual(gateway.lastErrorClass, .insufficientScopes)
        XCTAssertNotEqual(gateway.lastErrorClass, .malformedResponse,
                          "the status decides the class; the body is never parsed as a page")
        XCTAssertEqual(gateway.lastErrorClass?.isAuthorizationFailure, true,
                       "and the flush stops the pass rather than retrying a refusal")
        XCTAssertEqual(bus.events(named: "calendar_share_inbound_failed").last?.errorCode,
                       "insufficient_scopes")
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// The other refusal, on the same path: a 401 is the token itself, and
    /// it must not be merged with the 403 above any more than it is on the
    /// outbound path.
    func testAnInbound401IsClassifiedAsUnauthorized() async {
        transport.enqueue(json: ["error": ["code": 401]], status: 401)
        let gateway = makeGateway()

        let page = await gateway.listIncoming(syncToken: nil)

        XCTAssertNil(page)
        XCTAssertEqual(gateway.lastErrorClass, .unauthorized)
        XCTAssertEqual(bus.events(named: "calendar_share_inbound_failed").last?.errorCode,
                       "unauthorized")
    }

    /// The call the device console actually refused (2026-09-17): with
    /// `calendar.events` as the only calendar grant, Google answers 403 to
    /// `calendarList.list`. The refusal has to be classified HERE, because
    /// finding the family calendar is the first thing every write does —
    /// and a class that read "malformed response" would send the family
    /// looking at Google's API instead of at the grant.
    func testTheFamilyCalendarLookupClassifiesA403AndStopsTheWrite() async {
        transport.enqueue(json: ["error": ["code": 403,
                                           "status": "PERMISSION_DENIED"]],
                          status: 403)
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass, .insufficientScopes)
        // One request: the write does not go on to address an event to a
        // calendar the account was just refused.
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path(percentEncoded: false),
                       "/calendar/v3/users/me/calendarList")
        XCTAssertEqual(bus.events(named: "calendar_share_family_calendar_failed").last?.errorCode,
                       "insufficient_scopes")
    }

    func testA404OnCreateIsReportedAsNotFound() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: [:], status: 404)
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass, .notFound)
        XCTAssertEqual(gateway.lastErrorClass?.isRetryable, false)
    }

    func testATransportFailureCarriesTheErrorCodeClassOnly() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(error: URLError(.notConnectedToInternet))
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass,
                       .transport(String(describing: URLError.Code.notConnectedToInternet.rawValue)))
    }

    func testAnUndecodableSuccessIsAMalformedResponse() async {
        transport.enqueue(json: ["items": [["id": familyCalendarID,
                                            "summary": "Sahayak Family"]]])
        transport.enqueue(json: ["unexpected": "shape"])
        let gateway = makeGateway()

        let id = await gateway.createEvent(makeDraft())

        XCTAssertNil(id)
        XCTAssertEqual(gateway.lastErrorClass, .malformedResponse)
    }

    // MARK: - Graceful degradation

    func testAnUnconfiguredSessionMakesNoRequestAtAll() async {
        session.isConfigured = false
        let gateway = makeGateway()

        let calendar = await gateway.ensureFamilyCalendar()
        let created = await gateway.createEvent(makeDraft())
        let updated = await gateway.updateEvent(id: "google-event-1", with: makeDraft())
        let deleted = await gateway.deleteEvent(id: "google-event-1")
        let contact = await gateway.ensureContact(email: "kin@example.com", name: nil, phone: nil)
        let page = await gateway.listIncoming(syncToken: nil)
        let accepted = await gateway.acceptInvitation(eventId: "google-event-1")

        XCTAssertNil(calendar)
        XCTAssertNil(created)
        XCTAssertFalse(updated)
        XCTAssertFalse(deleted)
        XCTAssertFalse(contact)
        XCTAssertNil(page)
        XCTAssertFalse(accepted)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(gateway.lastErrorClass, .notConfigured)
    }

    func testAMissingTokenIsReportedAsNotSignedIn() async {
        session.token = nil
        let gateway = makeGateway()

        let page = await gateway.listIncoming(syncToken: nil)

        XCTAssertNil(page)
        XCTAssertEqual(gateway.lastErrorClass, .notSignedIn)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Inbound listing

    func testListIncomingKeepsOnlyTheEldersOwnUnansweredInvitations() async {
        transport.enqueue(json: [
            "items": [
                // Kept: the elder's own entry is at needsAction.
                ["id": "inv-1",
                 "summary": "Tea with Sita",
                 "start": ["dateTime": "2026-09-16T09:00:00Z"],
                 "end": ["dateTime": "2026-09-16T10:00:00Z"],
                 "organizer": ["email": "caregiver@example.com"],
                 "attendees": [["email": "caregiver@example.com", "self": false,
                                "responseStatus": "accepted"],
                               ["email": "elder@example.com", "self": true,
                                "responseStatus": "needsAction"]]],
                // Dropped: the elder already answered.
                ["id": "inv-2",
                 "summary": "Already answered",
                 "start": ["dateTime": "2026-09-16T11:00:00Z"],
                 "attendees": [["email": "elder@example.com", "self": true,
                                "responseStatus": "accepted"]]],
                // Dropped: the elder is not on it at all.
                ["id": "inv-3",
                 "summary": "Someone else's event",
                 "start": ["dateTime": "2026-09-16T11:00:00Z"],
                 "attendees": [["email": "other@example.com", "self": false,
                                "responseStatus": "needsAction"]]],
                // Dropped: all-day, so there is no instant to ring at.
                ["id": "inv-4",
                 "summary": "Holiday",
                 "start": ["date": "2026-09-17"],
                 "attendees": [["email": "elder@example.com", "self": true,
                                "responseStatus": "needsAction"]]],
                // Kept: an untitled invitation is still an invitation.
                ["id": "inv-5",
                 "start": ["dateTime": "2026-09-16T14:00:00Z"],
                 "attendees": [["email": "elder@example.com", "self": true,
                                "responseStatus": "needsAction"]]]
            ],
            "nextSyncToken": "sync-token-2"
        ])
        let gateway = makeGateway()

        let page = await gateway.listIncoming(syncToken: nil)

        XCTAssertEqual(page?.events.map(\.eventId), ["inv-1", "inv-5"])
        XCTAssertEqual(page?.events.first?.title, "Tea with Sita")
        XCTAssertEqual(page?.events.first?.startDate, rfc3339Date("2026-09-16T09:00:00Z"))
        XCTAssertEqual(page?.events.first?.endDate, rfc3339Date("2026-09-16T10:00:00Z"))
        XCTAssertEqual(page?.events.first?.organizerEmail, "caregiver@example.com")
        XCTAssertEqual(page?.events.first?.needsResponse, true)
        XCTAssertEqual(page?.events.last?.title, "")
        XCTAssertEqual(page?.nextSyncToken, "sync-token-2")

        // A full scan is a one-day window on the PRIMARY calendar, with
        // series expanded and deletions suppressed.
        let request = transport.requests.first
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path(percentEncoded: false),
                       "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(queryValue(request?.url, "singleEvents"), "true")
        XCTAssertEqual(queryValue(request?.url, "maxResults"), "250")
        XCTAssertEqual(queryValue(request?.url, "showDeleted"), "false")
        XCTAssertEqual(queryValue(request?.url, "timeMin"), "2026-09-15T12:00:00Z")
        XCTAssertNil(queryValue(request?.url, "syncToken"))
    }

    func testListIncomingUsesTheSyncTokenInsteadOfTheWindow() async {
        transport.enqueue(json: ["items": [], "nextSyncToken": "sync-token-3"])
        let gateway = makeGateway()

        _ = await gateway.listIncoming(syncToken: "sync-token-2")

        let url = transport.requests.first?.url
        XCTAssertEqual(queryValue(url, "syncToken"), "sync-token-2")
        // Google rejects `timeMin` alongside a sync token: the token
        // already means "since last time".
        XCTAssertNil(queryValue(url, "timeMin"))
    }

    // MARK: - Contacts

    func testEnsureContactReturnsTrueWhenTheAddressIsAlreadyKnown() async {
        transport.enqueue(json: ["results": [["person": ["emailAddresses": [
            ["value": "Kin@Example.com"]
        ]]]]])
        let gateway = makeGateway()

        let ensured = await gateway.ensureContact(email: "kin@example.com", name: nil, phone: nil)

        XCTAssertTrue(ensured)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests.first
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path(percentEncoded: false),
                       "/v1/people:searchContacts")
        XCTAssertEqual(queryValue(request?.url, "query"), "kin@example.com")
        XCTAssertEqual(queryValue(request?.url, "readMask"), "emailAddresses")
    }

    func testEnsureContactCreatesWhenTheAddressIsAbsent() async {
        transport.enqueue(json: ["results": []])
        transport.enqueue(json: ["resourceName": "people/1"])
        let gateway = makeGateway()

        let ensured = await gateway.ensureContact(email: "kin@example.com", name: nil, phone: nil)

        XCTAssertTrue(ensured)
        XCTAssertEqual(transport.requests.count, 2)
        let request = transport.requests.last
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path(percentEncoded: false), "/v1/people:createContact")
        let body = bodyJSON(request)
        XCTAssertEqual(body["emailAddresses"] as? [[String: String]],
                       [["value": "kin@example.com"]])
        // No name was supplied, and the address is the honest fallback
        // rather than one invented for the contact.
        XCTAssertEqual(body["names"] as? [[String: String]],
                       [["givenName": "kin@example.com"]])
    }

    func testEnsureContactUsesTheSuppliedNameWhenThereIsOne() async {
        transport.enqueue(json: ["results": []])
        transport.enqueue(json: ["resourceName": "people/2"])
        let gateway = makeGateway()

        _ = await gateway.ensureContact(email: "kin@example.com", name: "Sita", phone: nil)

        XCTAssertEqual(bodyJSON(transport.requests.last)["names"] as? [[String: String]],
                       [["givenName": "Sita"]])
    }

    /// Design §2.2 bullet 4: the contact this creates on the family's side
    /// is someone the caregiver may need to REACH, so the phone number
    /// travels with the address when the elder has one on file. A contact
    /// created as a bare address is a dead end in an emergency.
    func testEnsureContactCarriesThePhoneNumberWhenThereIsOne() async {
        transport.enqueue(json: ["results": []])
        transport.enqueue(json: ["resourceName": "people/3"])
        let gateway = makeGateway()

        _ = await gateway.ensureContact(email: "kin@example.com", name: "Sita",
                                        phone: "9812345678")

        XCTAssertEqual(bodyJSON(transport.requests.last)["phoneNumbers"] as? [[String: String]],
                       [["value": "9812345678"]])
    }

    /// The other half of the same rule: no phone number on file means no
    /// `phoneNumbers` key at all — an empty string would be written to the
    /// family's contact book as a number that cannot be dialled.
    func testEnsureContactOmitsThePhoneFieldWhenThereIsNone() async {
        transport.enqueue(json: ["results": []])
        transport.enqueue(json: ["resourceName": "people/4"])
        let gateway = makeGateway()

        _ = await gateway.ensureContact(email: "kin@example.com", name: "Sita",
                                        phone: "   ")

        XCTAssertNil(bodyJSON(transport.requests.last)["phoneNumbers"])
    }

    func testAFailedContactWriteReturnsFalseWithoutFailingTheCaller() async {
        transport.enqueue(json: ["error": ["code": 403]], status: 403)
        let gateway = makeGateway()

        let ensured = await gateway.ensureContact(email: "kin@example.com", name: nil, phone: nil)

        XCTAssertFalse(ensured)
        // People v1 answering 403 is the account-scope case exactly: the
        // token works, and it was not minted with `contacts`.
        XCTAssertEqual(gateway.lastErrorClass, .insufficientScopes)
        XCTAssertTrue(bus.contains("calendar_share_contact_failed"))
    }

    // MARK: - Accepting an invitation

    func testAcceptInvitationPatchesOnlyTheEldersOwnAttendeeEntry() async {
        transport.enqueue(json: ["attendees": [
            ["email": "caregiver@example.com", "self": false, "responseStatus": "accepted"],
            ["email": "elder@example.com", "displayName": "Elder",
             "self": true, "responseStatus": "needsAction"]
        ]])
        transport.enqueue(json: [:])
        let gateway = makeGateway()

        let accepted = await gateway.acceptInvitation(eventId: "inv-1")

        XCTAssertTrue(accepted)
        XCTAssertEqual(transport.requests.count, 2)
        let read = transport.requests.first
        XCTAssertEqual(read?.httpMethod, "GET")
        XCTAssertEqual(queryValue(read?.url, "fields"), "attendees")

        let write = transport.requests.last
        XCTAssertEqual(write?.httpMethod, "PATCH")
        XCTAssertEqual(write?.url?.path(percentEncoded: false),
                       "/calendar/v3/calendars/primary/events/inv-1")
        // No notification emails: the organizer already invited them.
        XCTAssertEqual(queryValue(write?.url, "sendUpdates"), "none")

        // The whole attendee array is reproduced — Google's PATCH replaces
        // it — and only the elder's own entry is rewritten. The other
        // attendee's status is theirs to set.
        let attendees = bodyJSON(write)["attendees"] as? [[String: String]]
        XCTAssertEqual(attendees?.map { $0["email"] }, ["caregiver@example.com", "elder@example.com"])
        XCTAssertNil(attendees?.first?["responseStatus"])
        XCTAssertEqual(attendees?.last?["responseStatus"], "accepted")
        XCTAssertEqual(attendees?.last?["displayName"], "Elder")
    }

    func testAcceptInvitationReturnsFalseWhenTheElderIsNotAnAttendee() async {
        transport.enqueue(json: ["attendees": [
            ["email": "other@example.com", "self": false, "responseStatus": "needsAction"]
        ]])
        let gateway = makeGateway()

        let accepted = await gateway.acceptInvitation(eventId: "inv-3")

        XCTAssertFalse(accepted)
        // Nothing was written: the caller must not import an event the
        // elder is not on.
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAcceptInvitationIsANoOpWhenTheElderAlreadyAccepted() async {
        transport.enqueue(json: ["attendees": [
            ["email": "elder@example.com", "self": true, "responseStatus": "accepted"]
        ]])
        let gateway = makeGateway()

        let accepted = await gateway.acceptInvitation(eventId: "inv-1")

        // The goal state is reached, so there is nothing to write — the
        // same rule the delete path follows for a 404.
        XCTAssertTrue(accepted)
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Helpers

    private func makeDraft(title: String = "Metformin",
                           start: Date = rfc3339Date("2026-09-16T08:00:00Z"),
                           durationMinutes: Int = 30,
                           recurrence: EventRecurrence? = .daily,
                           attendees: [String] = ["kin@example.com", "daughter@example.com"],
                           timeZone: String = "Asia/Kathmandu") -> CalendarTwinDraft {
        CalendarTwinDraft(title: title,
                          startDate: start,
                          durationMinutes: durationMinutes,
                          timeZoneIdentifier: timeZone,
                          recurrence: recurrence,
                          attendeeEmails: attendees,
                          kind: .medicationReminder)
    }

    private func bodyJSON(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// A query value with the URL's escaping undone — the assertions name
    /// the ADDRESS, not the `%40` an encoder happened to choose.
    private func queryValue(_ url: URL?, _ name: String) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }

}

/// A literal RFC 3339 instant as a `Date`. The fixtures name their
/// instants as strings — a test that fails should print the time Google
/// was asked about, not an epoch offset — and the formatter lives here so
/// no assertion has to parse one.
private func rfc3339Date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else {
        fatalError("test fixture is not RFC 3339: \(string)")
    }
    return date
}

// MARK: - Doubles

/// Records every request and replays a QUEUED response per call — a queue
/// rather than the single canned result `FakeGeminiTransport` keeps,
/// because the gateway's rules are mostly about what it does with the
/// SECOND request (create after the calendar was found, the patch after
/// the read). Running the queue dry is a test bug, and says so.
private final class FakeShareTransport: CalendarShareTransport {
    private(set) var requests: [URLRequest] = []
    private var queued: [Result<(Data, URLResponse), Error>] = []

    private enum FakeTransportError: Error { case noQueuedResponse }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !queued.isEmpty else { throw FakeTransportError.noQueuedResponse }
        return try queued.removeFirst().get()
    }

    func enqueue(json: [String: Any], status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: URL(string: "https://www.googleapis.com/")!,
                                       statusCode: status,
                                       httpVersion: nil,
                                       headerFields: nil)!
        queued.append(.success((data, response)))
    }

    func enqueue(error: Error) {
        queued.append(.failure(error))
    }
}

/// A session with no SDK behind it: the gateway only ever asks whether it
/// is configured and for a token, so that is all this answers.
private final class FakeSession: GoogleAccountSessionProtocol {
    var isConfigured = true
    var isSignedIn = false
    var accountEmail: String?
    /// The gateway's job is the REST call, not the grant: this fake is
    /// always scoped, and the scope STATE is exercised where it is
    /// decided (`GoogleAccountSessionTests`, `CalendarShareServiceTests`).
    var hasRequiredScopes = true
    var token: String? = "fake-access-token"
    /// [SCOPE-LEDGER] The required baseline — the gateway tests never
    /// compare against it, the service tests do.
    var requiredScopes: [String] = []
    var grantScopesResult = true
    func grantScopes(_ scopes: [String]) async -> Bool { grantScopesResult }

    func signIn() async -> GoogleSessionOutcome { isSignedIn ? .connected : .cancelled }
    func createAccount() async -> GoogleSessionOutcome { isSignedIn ? .connected : .cancelled }
    /// The launch restore is not this file's subject — the gateway only
    /// ever asks for a token — so it answers the honest "nothing restored".
    func restorePreviousSession() async -> GoogleSessionOutcome { .unavailable }
    func signOut() { isSignedIn = false }
    func accessToken() async -> String? { token }
}
