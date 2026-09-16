import Foundation

// MARK: - Google Calendar / People REST gateway (calendar & family sharing, 2026-09-16)

/// The production `GoogleCalendarGatewayProtocol`: Google Calendar v3 and
/// People v1 over hand-rolled REST.
///
/// Hand-rolled rather than through `GoogleAPIClientForREST` (design §2
/// decision 4): the share path makes seven calls, all of them one request
/// deep, and the app's only other network client (`GeminiClient`) is also
/// hand-rolled over a transport protocol. Adding the generated client
/// libraries would buy a second dependency tree and a second token-refresh
/// path for no call this file does not already make.
///
/// The seam is `CalendarShareTransport`, so every rule the design cares
/// about — attendee JSON, RRULE rendering, find-or-create, the inbound
/// self/needsAction filter, the accept patch — is asserted in tests with
/// no network, no OAuth client and no Google account.
///
/// Every method returns value-or-nil instead of throwing: the service's
/// queue asks "did it happen", and the two places that must distinguish
/// "unauthorized" (pause) from "rate limited" (retry) read
/// `lastErrorClass`. Nothing about a failure is thrown away — it is
/// recorded in that one property and emitted as an event.
///
/// Privacy (constitution C9 / the release-log privacy gate): this type
/// never writes to a console. Its observability events carry counts, the
/// error CLASS and the event KIND — never a title, an address, an event id
/// or a response body. That is why the failure events are built by one
/// private `emit` rather than by the call sites: a call site holding a
/// `CalendarTwinDraft` cannot accidentally pass a title through it.
final class GoogleCalendarGateway: GoogleCalendarGatewayProtocol {

    // MARK: Constants

    /// The dedicated shared calendar's exact summary. Matched EXACTLY, not
    /// case-insensitively: a calendar the family happens to have called
    /// "sahayak family" is not this app's to write twins into, and the
    /// cost of a false negative is one extra calendar rather than a
    /// medication twin landing somewhere nobody is looking.
    static let familyCalendarSummary = "Sahayak Family"

    /// Google's maximum page size for `calendarList.list` — comfortably
    /// more than "at least 100", and the fewest round trips for an account
    /// with a long list.
    private static let calendarPageSize = 250
    /// Page cap for the find-or-create scan. A real account's list is one
    /// page; the cap exists only so a repeated `nextPageToken` (a Google
    /// bug, or a test double returning the same page forever) cannot spin.
    private static let calendarPageLimit = 10
    /// Google's maximum for `events.list`. 250 covers a day's arrivals
    /// with room to spare; the inbound window is a day wide on a full scan
    /// and a delta on an incremental one.
    private static let eventsPageSize = 250
    /// The full-scan window: back one day. Wide enough that an invitation
    /// sent while the app was closed for the evening is still caught, and
    /// narrow enough that the first sync does not import the account's
    /// entire history into the elder's calendar.
    private static let inboundWindowSeconds: TimeInterval = -86_400

    // MARK: Dependencies

    private let session: GoogleAccountSessionProtocol
    private let transport: CalendarShareTransport
    private let observabilityBus: ObservabilityBus
    private let now: () -> Date

    /// The family calendar's id, remembered after the first find-or-create.
    /// In memory only: it is re-derivable from the account, and persisting
    /// it would add a second source of truth that goes stale the moment
    /// the family signs in with a different Google account.
    private var cachedFamilyCalendarID: String?

    /// The class of the most recent failure; nil after a success. See the
    /// type comment for who reads it and why.
    private(set) var lastErrorClass: GoogleShareError?

    init(session: GoogleAccountSessionProtocol,
         transport: CalendarShareTransport = URLSessionCalendarShareTransport(),
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.transport = transport
        self.observabilityBus = observabilityBus
        self.now = now
    }

    // MARK: - Family calendar

    /// Find-or-create the shared calendar.
    ///
    /// The cached id short-circuits both the scan and the token fetch: a
    /// flush that queues ten operations must not ask Google ten times
    /// which calendar this family uses.
    func ensureFamilyCalendar() async -> String? {
        if let cachedFamilyCalendarID { return cachedFamilyCalendarID }
        let event = "calendar_share_family_calendar"
        guard let token = await authorizedToken(event: event, kind: nil) else { return nil }

        var pageToken: String?
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: String(Self.calendarPageSize))]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            guard let url = Self.url(host: Self.calendarHost,
                                     path: "/calendar/v3/users/me/calendarList",
                                     query: query) else {
                recordMalformed(event, kind: nil)
                return nil
            }
            guard let (data, _) = await roundTrip(request(url, method: "GET", token: token),
                                                  event: event, kind: nil) else { return nil }
            guard let list = try? JSONDecoder().decode(CalendarListResponse.self, from: data) else {
                recordMalformed(event, kind: nil)
                return nil
            }
            if let existing = (list.items ?? [])
                .first(where: { $0.summary == Self.familyCalendarSummary }),
               let id = existing.id, !id.isEmpty {
                cachedFamilyCalendarID = id
                lastErrorClass = nil
                return id
            }
            pageToken = list.nextPageToken
            pages += 1
        } while pageToken != nil && pages < Self.calendarPageLimit

        // Absent — create it. A bare calendar (no timezone field) inherits
        // the account's own, which is the right default here: the twins
        // carry their own `timeZone` per event, so the calendar's zone is
        // never consulted for the times the family reads.
        guard let body = try? JSONSerialization.data(
                withJSONObject: ["summary": Self.familyCalendarSummary]),
              let createURL = Self.url(host: Self.calendarHost, path: "/calendar/v3/calendars") else {
            recordMalformed(event, kind: nil)
            return nil
        }
        guard let (data, _) = await roundTrip(request(createURL, method: "POST", token: token, body: body),
                                              event: event, kind: nil) else { return nil }
        guard let created = try? JSONDecoder().decode(CreatedCalendarResponse.self, from: data),
              let id = created.id, !id.isEmpty else {
            recordMalformed(event, kind: nil)
            return nil
        }
        cachedFamilyCalendarID = id
        lastErrorClass = nil
        return id
    }

    // MARK: - Outbound

    func createEvent(_ draft: CalendarTwinDraft) async -> String? {
        let event = "calendar_share_create"
        // The calendar first: it is the one call whose failure the
        // service's status card reports differently (no shared calendar at
        // all vs. one twin that did not land), and it carries its own auth.
        guard let calendarID = await ensureFamilyCalendar() else { return nil }
        guard let token = await authorizedToken(event: event, kind: draft.kind) else { return nil }
        guard let body = body(for: draft),
              let url = Self.eventsURL(calendarID: calendarID) else {
            recordMalformed(event, kind: draft.kind)
            return nil
        }
        guard let (data, _) = await roundTrip(request(url, method: "POST", token: token, body: body),
                                              event: event, kind: draft.kind) else { return nil }
        guard let created = try? JSONDecoder().decode(EventResponse.self, from: data),
              let id = created.id, !id.isEmpty else {
            recordMalformed(event, kind: draft.kind)
            return nil
        }
        return id
    }

    func updateEvent(id: String, with draft: CalendarTwinDraft) async -> Bool {
        let event = "calendar_share_update"
        guard let calendarID = await ensureFamilyCalendar() else { return false }
        guard let token = await authorizedToken(event: event, kind: draft.kind) else { return false }
        guard let body = body(for: draft),
              let url = Self.eventsURL(calendarID: calendarID, eventID: id) else {
            recordMalformed(event, kind: draft.kind)
            return false
        }
        return await roundTrip(request(url, method: "PUT", token: token, body: body),
                               event: event, kind: draft.kind) != nil
    }

    /// Removes the twin. TRUE on 404 as well, and that is load-bearing: the
    /// caller's goal is the twin's ABSENCE, which a 404 already proves —
    /// so "already deleted on the family's phone" must not be retried
    /// forever as a failure. This is the same goal-state rule
    /// `CalendarShareService` applies to its queue, expressed once here
    /// where the status code is actually visible.
    func deleteEvent(id: String) async -> Bool {
        let event = "calendar_share_delete"
        guard let calendarID = await ensureFamilyCalendar() else { return false }
        guard let token = await authorizedToken(event: event, kind: nil) else { return false }
        guard let url = Self.eventsURL(calendarID: calendarID, eventID: id) else {
            recordMalformed(event, kind: nil)
            return false
        }
        let start = Date()
        guard let (_, http) = await roundTrip(request(url, method: "DELETE", token: token),
                                              event: event, kind: nil,
                                              goalStatuses: [404]) else { return false }
        if http.statusCode == 404 {
            emit("calendar_share_delete_already_gone", outcome: "success",
                 durationMs: Self.milliseconds(since: start))
        }
        return true
    }

    // MARK: - Contacts

    /// People v1: make sure `email` exists among the elder's contacts.
    ///
    /// Best-effort by contract (design §4.2 — the invite must never be
    /// blocked by its anti-spam measure): a search that fails, or a create
    /// that fails, returns false and the caller proceeds with the invite.
    ///
    /// Creation always happens when the address is absent — including when
    /// `name` and `phone` are nil, which is still a legitimate call (the
    /// family may not have filled the contact in). The contact is the
    /// point; the name is decoration, and Google shows an address-labelled
    /// contact as its address anyway, so the address is the honest
    /// fallback rather than one invented for it.
    ///
    /// The phone rides along when the family stored one (design §2.2
    /// bullet 4): the elder's address book then holds someone they can
    /// CALL from the same entry the invite came from, which is the whole
    /// reason the emergency contact is in the sharing flow.
    func ensureContact(email: String, name: String?, phone: String?) async -> Bool {
        let event = "calendar_share_contact"
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        guard let token = await authorizedToken(event: event, kind: nil) else { return false }

        guard let searchURL = Self.url(host: Self.peopleHost,
                                       path: "/v1/people:searchContacts",
                                       query: [URLQueryItem(name: "query", value: address),
                                               URLQueryItem(name: "readMask", value: "emailAddresses")]) else {
            recordMalformed(event, kind: nil)
            return false
        }
        guard let (data, _) = await roundTrip(request(searchURL, method: "GET", token: token),
                                              event: event, kind: nil) else { return false }
        guard let found = try? JSONDecoder().decode(PeopleSearchResponse.self, from: data) else {
            recordMalformed(event, kind: nil)
            return false
        }
        let alreadyThere = (found.results ?? []).contains { result in
            (result.person?.emailAddresses ?? []).contains { value in
                value.value?.caseInsensitiveCompare(address) == .orderedSame
            }
        }
        if alreadyThere { return true }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let givenName: String = {
            guard let trimmedName, !trimmedName.isEmpty else { return address }
            return trimmedName
        }()
        let trimmedPhone = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        var person: [String: Any] = [
            "emailAddresses": [["value": address]],
            "names": [["givenName": givenName]]
        ]
        // Phone FIRST in the field list's own order of preference, and
        // only when the family actually stored one: People v1 rejects an
        // empty value, and a contact with a blank phone is worse than one
        // with none (it reads as "we have their number" and is not).
        if let trimmedPhone, !trimmedPhone.isEmpty {
            person["phoneNumbers"] = [["value": trimmedPhone]]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: person),
              let createURL = Self.url(host: Self.peopleHost, path: "/v1/people:createContact") else {
            recordMalformed(event, kind: nil)
            return false
        }
        return await roundTrip(request(createURL, method: "POST", token: token, body: body),
                               event: event, kind: nil) != nil
    }

    // MARK: - Inbound

    /// The elder's own pending invitations.
    ///
    /// Incremental when the caller has a `syncToken` (Google then returns
    /// only what changed, and `timeMin` must NOT be combined with it — the
    /// server rejects the pair); a one-day window when it does not.
    /// `singleEvents=true` expands series into occurrences, which is what
    /// the local calendar wants to hold.
    ///
    /// The filter is the design's (§4.5): an item counts only when the
    /// elder's OWN attendee entry (`self`) is still at `needsAction` —
    /// that is exactly "someone invited the elder and nobody has answered
    /// yet". Everything else on the primary calendar is either the
    /// elder's own event or an invitation they already dealt with.
    func listIncoming(syncToken: String?) async -> GoogleIncomingPage? {
        let event = "calendar_share_inbound"
        guard let token = await authorizedToken(event: event, kind: nil) else { return nil }
        var query = [URLQueryItem(name: "singleEvents", value: "true"),
                     URLQueryItem(name: "maxResults", value: String(Self.eventsPageSize)),
                     // Deleted occurrences must not arrive as imports. The
                     // cost is that a cancellation reaches the elder only
                     // as "the event is gone from the listing", which is
                     // the truth the local mirror can act on anyway.
                     URLQueryItem(name: "showDeleted", value: "false")]
        if let syncToken, !syncToken.isEmpty {
            query.append(URLQueryItem(name: "syncToken", value: syncToken))
        } else {
            query.append(URLQueryItem(name: "timeMin", value: Self.rfc3339String(
                from: now().addingTimeInterval(Self.inboundWindowSeconds))))
        }
        guard let url = Self.eventsURL(calendarID: "primary", query: query) else {
            recordMalformed(event, kind: nil)
            return nil
        }
        guard let (data, _) = await roundTrip(request(url, method: "GET", token: token),
                                              event: event, kind: nil) else { return nil }
        guard let page = try? JSONDecoder().decode(EventListResponse.self, from: data) else {
            recordMalformed(event, kind: nil)
            return nil
        }
        let events: [GoogleIncomingEvent] = (page.items ?? []).compactMap { item in
            // An item without an id could be neither imported nor accepted
            // (both are keyed by it), so it is not an event this path can
            // use — skipping is the only outcome that leaves no half-state.
            guard let id = item.id, !id.isEmpty else { return nil }
            guard let selfEntry = item.attendees?.first(where: { $0.isSelf == true }),
                  selfEntry.responseStatus == Self.needsAction else { return nil }
            // All-day events carry `start.date` and no `dateTime`: they
            // have no instant to ring at, so the inbound path leaves them
            // to the Calendar app rather than inventing a midnight.
            guard let startValue = item.start?.dateTime,
                  let start = Self.date(fromRFC3339: startValue) else { return nil }
            let end = item.end?.dateTime.flatMap { Self.date(fromRFC3339: $0) }
            return GoogleIncomingEvent(
                eventId: id,
                // A missing summary is a real state (an untitled event the
                // organizer never named); the local import gets an empty
                // title rather than this layer inventing a placeholder.
                title: item.summary ?? "",
                startDate: start,
                endDate: end,
                organizerEmail: item.organizer?.email,
                // Guaranteed by the filter above — kept as a field because
                // it is what the service's `where` clause reads, so the
                // listing's contract stays visible at the call site.
                needsResponse: true)
        }
        return GoogleIncomingPage(events: events, nextSyncToken: page.nextSyncToken)
    }

    /// Answers an invitation: the elder's attendee entry becomes
    /// `accepted`, and nobody is emailed about it (`sendUpdates=none` —
    /// the organizer already invited them; an RSVP notification is noise).
    ///
    /// This is a read-modify-write because Google's PATCH replaces the
    /// whole attendee array: sending only the elder's entry would delete
    /// everyone else from the event. The GET is narrowed with
    /// `fields=attendees` so the read cannot carry a title or a location
    /// back into this process at all.
    func acceptInvitation(eventId: String) async -> Bool {
        let event = "calendar_share_accept"
        guard let token = await authorizedToken(event: event, kind: nil) else { return false }
        guard let readURL = Self.eventsURL(calendarID: "primary", eventID: eventId,
                                           query: [URLQueryItem(name: "fields", value: "attendees")]) else {
            recordMalformed(event, kind: nil)
            return false
        }
        guard let (data, _) = await roundTrip(request(readURL, method: "GET", token: token),
                                              event: event, kind: nil) else { return false }
        guard let list = try? JSONDecoder().decode(AttendeeListResponse.self, from: data),
              let attendees = list.attendees else {
            recordMalformed(event, kind: nil)
            return false
        }
        guard let selfEntry = attendees.first(where: { $0.isSelf == true }) else {
            // The elder is not on this event any more (the invitation was
            // withdrawn, or the listing is stale). Nothing to accept, and
            // the caller must NOT import it — an event the elder is not
            // attending must not ring as their reminder.
            return false
        }
        if selfEntry.responseStatus == Self.accepted {
            // Already answered — on another device, between the listing
            // and this read. The goal state is reached, so there is
            // nothing to write; the same "goal state" rule `deleteEvent`
            // follows for a 404.
            lastErrorClass = nil
            return true
        }
        let patched: [[String: Any]] = attendees.compactMap { attendee in
            // An entry Google reports with no address (a comment-only
            // attendee) cannot be reproduced as an invitee, and sending it
            // back addressless would be rejected outright.
            guard let address = attendee.email, !address.isEmpty else { return nil }
            var entry: [String: Any] = ["email": address]
            if let displayName = attendee.displayName, !displayName.isEmpty {
                entry["displayName"] = displayName
            }
            // Every OTHER attendee's response status is theirs to set;
            // restating it here would be this app answering on their
            // behalf. Only the elder's own entry is rewritten.
            if attendee.isSelf == true { entry["responseStatus"] = Self.accepted }
            return entry
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["attendees": patched]),
              let writeURL = Self.eventsURL(calendarID: "primary", eventID: eventId,
                                            query: [URLQueryItem(name: "sendUpdates", value: "none")]) else {
            recordMalformed(event, kind: nil)
            return false
        }
        return await roundTrip(request(writeURL, method: "PATCH", token: token, body: body),
                               event: event, kind: nil) != nil
    }

    // MARK: - Request body

    /// The body for a create and for an update — ONE construction, so the
    /// two can never drift into describing the same twin differently. An
    /// update that quietly dropped the recurrence would un-series a shared
    /// medication for the family's calendar while the elder's own phone
    /// kept firing it.
    ///
    /// `end` is derived here rather than carried on the draft: duration is
    /// what the app's sources know (`CalendarShareMapper`), and one place
    /// converts it.
    private func body(for draft: CalendarTwinDraft) -> Data? {
        // A negative duration is an upstream bug; a zero-length block is
        // the honest rendering of a nonsensical one, and Google rejects an
        // `end` before its `start` outright (400), which would turn a
        // mapping bug into a silently dropped reminder.
        let minutes = max(0, draft.durationMinutes)
        let start = draft.startDate
        let end = start.addingTimeInterval(TimeInterval(minutes) * 60)
        let zone = draft.timeZoneIdentifier
        var payload: [String: Any] = [
            "summary": draft.title,
            // The instant is sent in UTC and the IANA zone alongside it.
            // The instant is what the family's phones ring at; the zone is
            // what Google anchors the recurrence rule to, so a series
            // created in Kathmandu keeps its 08:00 wall clock if the
            // account's own zone is elsewhere.
            "start": ["dateTime": Self.rfc3339String(from: start), "timeZone": zone],
            "end": ["dateTime": Self.rfc3339String(from: end), "timeZone": zone],
            "attendees": draft.attendeeEmails.map { ["email": $0] }
        ]
        // The address, verbatim, in Google's own `location` field
        // (rich-events task, 2026-09-17: design §3 — the family's
        // invitation shows where the event is).
        //
        // Omitted entirely when the draft carries none, rather than sent
        // as an empty string. Both spellings clear the field (this is a
        // PUT, and `updateEvent` is a full replace), which is the
        // correct outcome for "the family removed the address"; omitting
        // it just avoids asserting an empty value we do not mean.
        if let location = draft.location, !location.isEmpty {
            payload["location"] = location
        }
        if let recurrence = draft.recurrence {
            payload["recurrence"] = CalendarRecurrenceRule.googleRecurrence(recurrence)
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Transport

    /// One transport round trip, with the error-class bookkeeping and the
    /// failure event in ONE place so no call site can forget either.
    ///
    /// `event` is the snake_case base name of the observability event
    /// (`calendar_share_create` → `calendar_share_create_failed`); it
    /// names the OPERATION, never the item.
    ///
    /// `goalStatuses` is the escape hatch for a status code that is a
    /// failure to the transport and success to the operation — DELETE's
    /// 404 is the only one today. Such a status clears `lastErrorClass`
    /// like any other success and emits nothing here; the caller reports
    /// its own event, because only the caller knows the goal was reached.
    private func roundTrip(_ request: URLRequest,
                           event: String,
                           kind: EventNotifyKind?,
                           goalStatuses: Set<Int> = []) async -> (Data, HTTPURLResponse)? {
        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            // The CLASS only. A `URLError`'s description carries the
            // failing URL, and `localizedDescription` can carry more —
            // neither is allowed anywhere near a log line (the same rule
            // `GeminiClient` follows for its HTTP failures).
            let failure = GoogleShareError.transport(
                String(describing: (error as? URLError)?.code.rawValue ?? -1))
            lastErrorClass = failure
            emit("\(event)_failed", outcome: "failure",
                 durationMs: Self.milliseconds(since: start), error: failure, kind: kind)
            return nil
        }
        guard let http = response as? HTTPURLResponse else {
            recordMalformed(event, kind: kind)
            return nil
        }
        if goalStatuses.contains(http.statusCode) {
            lastErrorClass = nil
            return (data, http)
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = Self.errorClass(forStatus: http.statusCode)
            lastErrorClass = failure
            emit("\(event)_failed", outcome: "failure",
                 durationMs: Self.milliseconds(since: start), error: failure, kind: kind)
            return nil
        }
        lastErrorClass = nil
        return (data, http)
    }

    /// The access token for one call, or nil having recorded WHY there is
    /// none. Graceful degradation (design §0) lives here rather than in
    /// each method so no call can reach the network without a token, and
    /// so the two "no Google possible right now" states are reported
    /// honestly rather than as a silent no-op.
    private func authorizedToken(event: String, kind: EventNotifyKind?) async -> String? {
        guard session.isConfigured else {
            lastErrorClass = .notConfigured
            emit("\(event)_failed", outcome: "failure", error: .notConfigured, kind: kind)
            return nil
        }
        guard let token = await session.accessToken(), !token.isEmpty else {
            lastErrorClass = .notSignedIn
            emit("\(event)_failed", outcome: "failure", error: .notSignedIn, kind: kind)
            return nil
        }
        return token
    }

    private func request(_ url: URL, method: String, token: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Both headers on every call, including the reads: one shape for
        // every request means a new call cannot be added without auth.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // MARK: - Error classification

    /// Status code → failure class, for the statuses that are not 2xx. The
    /// mapping is total and coarse on purpose: the values reach a log line
    /// and the Settings status card, so they must not be able to carry a
    /// body, a title or an address, and the service only needs to know
    /// "pause" (unauthorized) from "retry" (everything else transient).
    ///
    /// 404 gets its own case because it is the one failure with a defined
    /// recovery rather than a retry: what was addressed is GONE. The
    /// caller's update path re-creates the twin on it, and `deleteEvent`
    /// reads the raw status itself and calls the absence a success. Any
    /// other 4xx lands in `malformedResponse` — non-retryable, so a
    /// request that cannot succeed is never a busy-loop, without claiming
    /// a recovery this layer does not know.
    static func errorClass(forStatus status: Int) -> GoogleShareError {
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .malformedResponse
        }
    }

    /// A 2xx whose body did not contain what was asked of it — the one
    /// failure the round-trip chokepoint cannot see, because the status
    /// was fine and the body was not.
    private func recordMalformed(_ event: String, kind: EventNotifyKind?) {
        lastErrorClass = .malformedResponse
        emit("\(event)_failed", outcome: "failure", error: .malformedResponse, kind: kind)
    }

    // MARK: - Observability

    /// The single emitter. Component and event-name grammar are fixed
    /// here; the only things that vary are the OUTCOME, the error CLASS,
    /// the event KIND and counts.
    ///
    /// Metadata is a `[String: String]` by interface, which means the
    /// no-PII rule has to be kept by the call sites — so call sites pass
    /// primitives through the typed parameters below (`kind`, `count`)
    /// instead of formatting their own, and never build a metadata value
    /// out of a draft, an address, an id or a response body.
    private func emit(_ eventType: String,
                      outcome: String,
                      durationMs: Int = 0,
                      error: GoogleShareError? = nil,
                      kind: EventNotifyKind? = nil,
                      metadata: [String: String] = [:]) {
        var fields = metadata
        if let kind { fields["kind"] = kind.rawValue }
        observabilityBus.emit(ObservabilityEvent(
            component: "calendar_share_gateway",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: error.map(Self.errorLabel),
            metadata: fields
        ))
    }

    /// An error's log-safe code — an enum name, never a message. The
    /// `server` and `transport` cases carry their integer CODE only, which
    /// is what makes this type safe to put in a log line at all.
    private static func errorLabel(for error: GoogleShareError) -> String {
        switch error {
        case .notSignedIn: return "not_signed_in"
        case .notConfigured: return "not_configured"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate_limited"
        case .server(let status): return "server_\(status)"
        case .notFound: return "not_found"
        case .malformedResponse: return "malformed_response"
        case .transport(let code): return "transport_\(code)"
        }
    }

    // MARK: - URLs

    private static let calendarHost = "www.googleapis.com"
    private static let peopleHost = "people.googleapis.com"
    /// Google's name for the response, and the only value the accept path
    /// writes into an attendee entry.
    private static let accepted = "accepted"
    private static let needsAction = "needsAction"

    /// `https://<host><path>[?query]`.
    ///
    /// The path is set through `percentEncodedPath` because the plain
    /// `path` setter would re-escape the escaping done by `escaped(_:)` —
    /// the classic `%40` → `%2540` trap, which turns a family calendar id
    /// into a 404.
    private static func url(host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// `/calendar/v3/calendars/<id>/events[/<eventId>]`.
    ///
    /// `calendarID` is either an opaque Google id or the literal
    /// `"primary"`; both are path segments and both are escaped the same
    /// way, which is what makes the inbound path (`primary`) and the
    /// outbound one (the family calendar) share this builder.
    private static func eventsURL(calendarID: String,
                                  eventID: String? = nil,
                                  query: [URLQueryItem] = []) -> URL? {
        var path = "/calendar/v3/calendars/\(escaped(calendarID))/events"
        if let eventID { path += "/\(escaped(eventID))" }
        return url(host: calendarHost, path: path, query: query)
    }

    /// RFC 3986 unreserved characters only. Every real Google id is made
    /// of these and comes through unchanged; anything else (a slash, a
    /// question mark, a space) is escaped rather than allowed to split or
    /// terminate the path it is embedded in.
    private static func escaped(_ segment: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? segment
    }

    // MARK: - RFC 3339

    /// Google's date format, and the app's only writer of it.
    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Reads Google's instants. Two formatters because the API is not
    /// consistent about fractional seconds — `events.list` returns
    /// `2026-09-16T09:00:00Z` for some events and
    /// `2026-09-16T09:00:00.000Z` for others, and a tolerant read beats
    /// dropping a real invitation over a decimal point.
    private static let rfc3339Parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func rfc3339String(from date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }

    static func date(fromRFC3339 string: String) -> Date? {
        rfc3339Parser.date(from: string) ?? rfc3339Formatter.date(from: string)
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Wire types

/// The Google responses this layer reads, as plain `Decodable` shapes —
/// no JSON crosses the gateway seam (the same rule
/// `CalendarEventRecord` follows for EventKit). Every field is optional:
/// a response that is missing one is a `malformedResponse` at the call
/// site rather than a decode failure with a message that could name a
/// field of someone's calendar.
private struct CalendarListResponse: Decodable {
    struct Entry: Decodable {
        let id: String?
        let summary: String?
    }
    let items: [Entry]?
    let nextPageToken: String?
}

private struct CreatedCalendarResponse: Decodable {
    let id: String?
}

private struct EventResponse: Decodable {
    let id: String?
}

/// One event as `events.list` reports it — the inbound path's read.
private struct EventListResponse: Decodable {
    struct DateValue: Decodable {
        /// Present for timed events; the all-day form carries `date`
        /// instead, which this layer deliberately does not read.
        let dateTime: String?
    }
    struct Organizer: Decodable {
        let email: String?
    }
    struct Item: Decodable {
        let id: String?
        let summary: String?
        let start: DateValue?
        let end: DateValue?
        let organizer: Organizer?
        let attendees: [Attendee]?
    }
    let items: [Item]?
    let nextSyncToken: String?
}

/// The `?fields=attendees` read the accept path makes before its patch.
private struct AttendeeListResponse: Decodable {
    let attendees: [Attendee]?
}

/// One attendee entry. `self` is a JSON key AND a Swift keyword, hence the
/// explicit coding key — and `isSelf` is what makes the whole inbound path
/// work: it is how the elder's own entry is told apart from the family's.
private struct Attendee: Decodable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let isSelf: Bool?

    private enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus
        case isSelf = "self"
    }
}

private struct PeopleSearchResponse: Decodable {
    struct Result: Decodable {
        struct Person: Decodable {
            struct EmailAddress: Decodable {
                let value: String?
            }
            let emailAddresses: [EmailAddress]?
        }
        let person: Person?
    }
    let results: [Result]?
}
