import Foundation

// MARK: - Shared-event identity (calendar & family sharing, 2026-09-16)

/// The stable local identity of one shared item — the key the
/// `LocalGoogleEventMappingStore` maps to a Google event id.
///
/// Grammar: `kind:uuid` for one-off items, `kind:uuid:slot` for the
/// per-slot series of a recurring entry.
///
/// The plan sketched the bare `kind:uuid` form ("entry ids for
/// med/routine, EventKit event id for calendar events"). The slot suffix
/// is the one addition, and it is load-bearing rather than decorative: a
/// medication entry with two daily times is TWO recurring series — one
/// at 08:00 and one at 20:00 — and an RFC 5545 recurrence rule cannot
/// carry two times of day. Keying only by entry id would silently share
/// the morning dose and drop the evening one, which is exactly the kind
/// of quiet hole the invite policy exists to prevent. Voice-created and
/// imported events are one-offs and keep the bare two-part form.
///
/// The calendar-event form uses the EventKit `eventIdentifier` as the
/// uuid position — it is opaque, stable for the event's lifetime, and
/// already the join key `ExternalEventLinkStore` uses for native events.
enum CalendarShareKey {

    /// A recurring entry's slot series.
    static func slot(kind: EventNotifyKind, entryId: UUID, slot: Int) -> String {
        "\(kind.rawValue):\(entryId.uuidString):\(slot)"
    }

    /// A one-off item (a voice-created or imported calendar event).
    static func oneOff(kind: EventNotifyKind, eventIdentifier: String) -> String {
        "\(kind.rawValue):\(eventIdentifier)"
    }

    /// Splits a key back into its parts; nil for anything not written by
    /// this grammar. `entryId` is nil for the one-off form, where the
    /// trailing component is an opaque native event identifier.
    static func parts(_ key: String) -> (kind: EventNotifyKind, entryId: UUID?, slot: Int?)? {
        let components = key.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3,
              let kind = EventNotifyKind(rawValue: String(components[0])) else { return nil }
        if components.count == 2 {
            guard !components[1].isEmpty else { return nil }
            return (kind, nil, nil)
        }
        guard let entryId = UUID(uuidString: String(components[1])),
              let slot = Int(components[2]), slot >= 0 else { return nil }
        return (kind, entryId, slot)
    }

    /// Every slot key belonging to `entryId` — the reconcile diff's way
    /// of finding the series an entry owns without scanning the kind.
    static func slotKeys(kind: EventNotifyKind, entryId: UUID) -> String {
        "\(kind.rawValue):\(entryId.uuidString):"
    }

    /// The native event identifier inside a ONE-OFF key, nil for a slot
    /// key or anything else. `parts` drops the identifier on purpose (it
    /// is opaque, not a uuid), but the stale-twin sweep needs it back:
    /// the key is the only place the local event id is written down.
    static func oneOffIdentifier(_ key: String) -> String? {
        let components = key.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2, !components[1].isEmpty,
              EventNotifyKind(rawValue: String(components[0])) != nil else { return nil }
        return String(components[1])
    }
}

// MARK: - Twin draft

/// A local item expressed as a Google Calendar event — the mapper's
/// output, the gateway's input, and the only shape the REST layer ever
/// sees. A plain value, so the whole invite policy is unit-tested with
/// no session, no network and no settings store.
struct CalendarTwinDraft: Equatable {
    /// The event title as the family will read it. Plain language,
    /// verbatim from the local item: the medication NAME, the routine's
    /// title, the event's title. Post-consent full titles are the user's
    /// decision 5 — before consent NOTHING is mapped at all (the gate is
    /// the mapper's, not a redaction here), so there is no "masked"
    /// variant of this type to get wrong.
    let title: String
    /// First occurrence. Recurring sources anchor here; Google projects
    /// the rule forward from this instant.
    let startDate: Date
    /// Bounded block length — the house 30-minute default unless the
    /// source says otherwise.
    let durationMinutes: Int
    /// IANA identifier (e.g. "Asia/Kathmandu"). Carried explicitly
    /// because the elder's device timezone is the correct anchor even if
    /// the Google account's default is elsewhere.
    let timeZoneIdentifier: String
    /// Recurrence in app terms; nil for a one-off. The gateway renders
    /// this to an RFC 5545 RRULE.
    let recurrence: EventRecurrence?
    /// Addresses to invite, already policy-filtered and de-duplicated.
    /// NEVER empty for a draft that exists — a draft with no invitees is
    /// the no-op case and the mapper returns nil instead.
    let attendeeEmails: [String]
    /// Which firing system this twin mirrors. Kept on the draft so the
    /// gateway can tag the Google event (and so logs can name the kind
    /// without naming the event).
    let kind: EventNotifyKind
    /// The event's address, verbatim (rich-events task, 2026-09-17).
    /// This is what makes an address the family typed on the elder's
    /// phone reach the Google invitation's location row (design §3
    /// "CalendarShareMapper gains the location field"). nil for every
    /// draft whose source has no address — medication and routine
    /// drafts always, and free-form events without one.
    ///
    /// Trailing and defaulted rather than required: the three existing
    /// draft builders and their tests construct this positionally, and
    /// a defaulted member keeps every one of them compiling with the
    /// same meaning.
    var location: String? = nil
}

// MARK: - Mapper

/// Pure mapping from local items to shareable twins, plus the invite
/// policy that decides WHO sees them (design §4.3).
///
/// Three rules, in order, and all three are cheap:
///
///  1. **No invitees → no draft.** The mapper returns nil rather than an
///     attendee-less event, so the no-sign-in / no-consent / no-eligible-
///     contact cases all collapse to the same zero-API-call outcome
///     without the service branching on each.
///  2. **Emergency contacts are always invited**, for every kind.
///  3. **Every other contact follows its kind's toggle** in
///     `CaregiverNotifySettings` (default OFF).
///
/// A contact with no email is skipped by rule 3's lookup itself — the
/// emergency-mandatory editor rule means this is a configuration error
/// rather than a normal state, and it is surfaced there (design §4.3).
/// Emergency contacts are ordered first so the "always invited" set is
/// visible at the head of the list in any log or debug dump.
enum CalendarShareMapper {

    /// Bounded block length for a shared event. Matches the voice
    /// writer's default (`EventKitCalendarEventWriter`) — a shared twin
    /// and its local event should describe the same half hour.
    static let defaultDurationMinutes = 30

    // MARK: Invite policy

    /// The addresses invited to an event of `kind`.
    ///
    /// De-duplicated case-insensitively (``Ma@x.com`` and `ma@x.com` are
    /// one person, and Google would send one invite anyway — de-duping
    /// here keeps request bodies honest) and ordered emergency-first.
    /// Blank addresses are treated as absent, so a whitespace-only field
    /// cannot produce a draft full of empty strings.
    static func inviteeEmails(
        contacts: [FamilyContact],
        kind: EventNotifyKind,
        notifySettings: CaregiverNotifySettings
    ) -> [String] {
        let othersEnabled = notifySettings.isEnabled(for: kind)
        var seen = Set<String>()
        var result: [String] = []

        appendEmails(from: contacts.filter { $0.isEmergencyContact },
                     to: &result, seen: &seen)
        // [CALENDAR-POLICY] (2026-09-17) Calendar events are shared with
        // EVERY contact that has an email, toggle-independent — the
        // elder's original requirement ("make all calendar events
        // sharable with caregivers and emergency contacts"). The toggle
        // keeps its fire-time meaning (SMS/WhatsApp at fire); medication
        // and routine kinds keep toggle gating because their daily
        // recurrence would invite every contact to every dose forever.
        if othersEnabled || kind == .calendarEvent {
            appendEmails(from: contacts.filter { !$0.isEmergencyContact },
                         to: &result, seen: &seen)
        }
        return result
    }

    /// The family-notification audience (M-1 resolved, T-012): EVERY
    /// family contact with an email — de-duplicated case-insensitively,
    /// emergency-first — with the notify toggles never consulted.
    ///
    /// The significant-event calendar channel (IF-17/IF-18) invites this
    /// set rather than the per-kind `inviteeEmails` rule: the three
    /// at-risk events (a missed dose, a possible double dose, a dose
    /// that needs attention) are unconditional, and the amended
    /// disclosure the household accepted says exactly this — "Safety
    /// alerts … are always shared with every family contact who has an
    /// email". The toggles keep governing the daily reminder twins'
    /// noise.
    static func familyAudienceEmails(contacts: [FamilyContact]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        appendEmails(from: contacts.filter { $0.isEmergencyContact },
                     to: &result, seen: &seen)
        appendEmails(from: contacts.filter { !$0.isEmergencyContact },
                     to: &result, seen: &seen)
        return result
    }

    /// The shared de-dup/ordering append, so `inviteeEmails` and
    /// `familyAudienceEmails` cannot drift on the rule they both state:
    /// trimmed, blank-skipped (a whitespace-only field is absent, never
    /// an empty invitee), de-duplicated case-insensitively with the
    /// first spelling kept.
    private static func appendEmails(from contacts: [FamilyContact],
                                     to result: inout [String],
                                     seen: inout Set<String>) {
        for contact in contacts {
            guard let email = contact.email else { continue }
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
    }

    // MARK: Gate

    /// Whether sharing may act at all right now. Two gates in order
    /// (design §5): a signed-in Google account, then the plain-language
    /// disclosure. `pendingCount` is deliberately NOT an input — a
    /// non-zero queue with sharing paused is exactly what the Settings
    /// status card must be able to show honestly.
    static func canShare(isSignedIn: Bool, hasConsented: Bool) -> Bool {
        isSignedIn && hasConsented
    }

    // MARK: Medication

    /// Twins for a medication entry — one per schedule time.
    ///
    /// Recurrence is always `.daily`: the whole `MedicationScheduler`
    /// (and the EventKit mirror before it) treats `scheduleTimes` as
    /// wall-clock times that repeat every day, and the model's
    /// weekly/custom frequencies are not consulted anywhere in the
    /// scheduler. Mirroring what actually fires beats mirroring a field
    /// nothing reads.
    ///
    /// `startDate` anchoring uses the same next-occurrence rule as the
    /// native mirror (`CalendarSyncService.nextStart`), so the twin and
    /// the local event describe the same next dose.
    static func medicationDrafts(
        entry: MedicationEntry,
        contacts: [FamilyContact],
        notifySettings: CaregiverNotifySettings,
        now: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> [CalendarTwinDraft] {
        let attendees = inviteeEmails(contacts: contacts, kind: .medicationReminder,
                                      notifySettings: notifySettings)
        guard !attendees.isEmpty else { return [] }
        return entry.scheduleTimes.enumerated().compactMap { _, time in
            guard let hour = time.hour, let minute = time.minute,
                  let start = CalendarSyncService.nextStart(
                    after: now, hour: hour, minute: minute,
                    weekdays: nil, calendar: calendar)
            else { return nil }
            return CalendarTwinDraft(
                title: entry.medicationName,
                startDate: start,
                durationMinutes: defaultDurationMinutes,
                timeZoneIdentifier: timeZone.identifier,
                recurrence: .daily,
                attendeeEmails: attendees,
                kind: .medicationReminder
            )
        }
    }

    // MARK: Routine

    /// Twins for a routine entry — one per schedule time, exactly
    /// mirroring `CalendarSyncService.recurrence(for:)`: daily unless the
    /// entry actually restricts weekdays (an empty weekday list under
    /// `.weekly` means every day, i.e. daily). Disabled entries have
    /// nothing to share.
    static func routineDrafts(
        entry: RoutineEntry,
        contacts: [FamilyContact],
        notifySettings: CaregiverNotifySettings,
        now: Date,
        locale: Locale = Locale(identifier: "en"),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> [CalendarTwinDraft] {
        guard entry.isEnabled else { return [] }
        let attendees = inviteeEmails(contacts: contacts, kind: .routineReminder,
                                      notifySettings: notifySettings)
        guard !attendees.isEmpty else { return [] }
        let recurrence = CalendarSyncService.recurrence(for: entry)
        let weekdays: [Int]? = {
            switch recurrence {
            case .daily: return nil
            case .weekly(let days): return days
            }
        }()
        // The same "<name> (<category>)" title the native mirror writes,
        // so the family sees one consistent label across both calendars.
        let label = L10n.str(entry.category.displayNameKey, locale: locale)
        let title = "\(entry.displayTitle(locale: locale)) (\(label))"
        return entry.scheduleTimes.compactMap { time in
            guard let hour = time.hour, let minute = time.minute,
                  let start = CalendarSyncService.nextStart(
                    after: now, hour: hour, minute: minute,
                    weekdays: weekdays, calendar: calendar)
            else { return nil }
            return CalendarTwinDraft(
                title: title,
                startDate: start,
                durationMinutes: defaultDurationMinutes,
                timeZoneIdentifier: timeZone.identifier,
                recurrence: recurrence,
                attendeeEmails: attendees,
                kind: .routineReminder
            )
        }
    }

    // MARK: Calendar event

    /// The twin for a one-off calendar event (voice-created, imported, or
    /// created from the Events form). One draft or none — a one-off has
    /// nothing to iterate.
    ///
    /// `location` is the event's plain address string, passed through
    /// verbatim (rich-events task, 2026-09-17: design §3, "the Google
    /// twin inherits it"). Blank normalizes to nil like every other
    /// optional text field in the app, so an emptied address field
    /// clears the twin's location rather than writing "   ".
    static func calendarEventDraft(
        title: String,
        startDate: Date,
        durationMinutes: Int,
        contacts: [FamilyContact],
        notifySettings: CaregiverNotifySettings,
        timeZone: TimeZone = .current,
        location: String? = nil
    ) -> CalendarTwinDraft? {
        let attendees = inviteeEmails(contacts: contacts, kind: .calendarEvent,
                                      notifySettings: notifySettings)
        guard !attendees.isEmpty else { return nil }
        return CalendarTwinDraft(
            title: title,
            startDate: startDate,
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZone.identifier,
            recurrence: nil,
            attendeeEmails: attendees,
            kind: .calendarEvent,
            location: normalizedLocation(location)
        )
    }

    /// A free-text address field, normalized: blank/whitespace-only
    /// reads as absent (the house rule for every optional text field),
    /// so "has an address?" answers `false` for a field the family
    /// cleared and no empty `location` ever reaches Google.
    static func normalizedLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Significant event (IF-18, C11)

    /// The title a significant-event twin opens with: the catalog phrase
    /// for the event kind (C13 keys, present in both locales), then the
    /// medication name — `"<phrase> — <name>"`, the same two-part shape
    /// the medicine screen's photo caption uses so the family reads one
    /// vocabulary wherever the alert reaches them.
    ///
    /// The name is the elder's own medication name, verbatim: after
    /// consent the shipped full-title rule applies (user decision 5),
    /// and a redacted title here would be a second, silently different
    /// policy.
    static func significantEventTitle(
        kind: SignificantMedicationEvent.Kind,
        medicationName: String,
        locale: Locale
    ) -> String {
        "\(L10n.str(kind.alertKey, locale: locale)) — \(medicationName)"
    }

    /// The twin for a significant medication event (IF-18): a ONE-OFF
    /// (no recurrence) anchored at the trigger instant, titled with the
    /// significant-event copy, and invited to the FAMILY-NOTIFICATION
    /// audience — every family contact with an email, toggle-independent
    /// (see `familyAudienceEmails`).
    ///
    /// `nil` when nobody has an email: the same "no invitees → no
    /// draft" collapse the other builders use, which the service reports
    /// as a skip rather than writing an attendee-less entry.
    ///
    /// `kind` on the draft is `.medicationReminder` — the family-facing
    /// reminder taxonomy, so existing surfaces (the Google event tag, the
    /// flush logs) classify it without a new case. It is NOT the key's
    /// identity component spelling anything significant: the caller
    /// composes the key from the event's deterministic id (D7).
    static func significantEventDraft(
        event: SignificantMedicationEvent,
        medicationName: String,
        contacts: [FamilyContact],
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en")
    ) -> CalendarTwinDraft? {
        let attendees = familyAudienceEmails(contacts: contacts)
        guard !attendees.isEmpty else { return nil }
        return CalendarTwinDraft(
            title: significantEventTitle(kind: event.kind,
                                         medicationName: medicationName,
                                         locale: locale),
            startDate: event.occurredAt,
            durationMinutes: defaultDurationMinutes,
            timeZoneIdentifier: timeZone.identifier,
            recurrence: nil,
            attendeeEmails: attendees,
            kind: .medicationReminder
        )
    }

    // MARK: Fingerprint

    /// A stable content hash of a draft — what the reconcile compares to
    /// decide whether an existing twin needs an update.
    ///
    /// Without it the only options are "re-write every twin on every
    /// pass" (a PUT per event per launch, forever, for schedules that
    /// only change once a month) or "never re-write", which silently
    /// drops the edit that matters. The fingerprint is the third option,
    /// and it is computed from the payload the gateway would send, not
    /// from the local model, so nothing can differ in the request while
    /// hashing equal.
    ///
    /// Two deliberate exclusions:
    ///  - The DATE half of `startDate` for a RECURRING draft. Its anchor
    ///    is "the next occurrence" by construction
    ///    (`CalendarSyncService.nextStart`), so it moves forward every
    ///    day; hashing it would re-write every series daily for no
    ///    change in what the family sees. The wall-clock time is the
    ///    part that identifies the series, so only that is hashed. A
    ///    one-off has no rule to carry its date, so it hashes the full
    ///    instant.
    ///  - Attendee ORDER (sorted here, and lowercased) — the mapper's
    ///    output order depends on contact ordering in Settings, which is
    ///    not a change to the event.
    static func fingerprint(of draft: CalendarTwinDraft) -> String {
        var parts: [String] = [
            draft.title,
            draft.timeZoneIdentifier,
            "\(draft.durationMinutes)",
            draft.kind.rawValue,
            draft.recurrence.map { CalendarRecurrenceRule.rrule($0) } ?? ""
        ]
        // The address IS content the family sees on the invitation, so an
        // address edit has to reach the twin (rich-events task,
        // 2026-09-17). Appended rather than folded into an existing part
        // so a payload written before this field existed hashes to a
        // DIFFERENT value and is re-written ONCE — which is what carries
        // the new field out to twins created before it existed. The
        // `loc:` prefix keeps it distinguishable from a title that
        // happens to read like an address.
        parts.append("loc:" + (draft.location ?? ""))
        if draft.recurrence == nil {
            parts.append("at:\(Int(draft.startDate.timeIntervalSince1970))")
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
            let c = calendar.dateComponents([.hour, .minute], from: draft.startDate)
            parts.append("at:\(c.hour ?? 0):\(c.minute ?? 0)")
        }
        parts.append("to:" + draft.attendeeEmails
            .map { $0.lowercased() }.sorted().joined(separator: ","))
        return parts.joined(separator: "|")
    }

    // MARK: Diffing

    /// What changed between the local items and the last-known snapshot,
    /// expressed as work for the service. Pure: no store, no network.
    ///
    /// `snapshot` is the previous pass's key set (the mapping store's
    /// view). A key present now but not before is a create; present in
    /// both is a possible update (the service compares drafts — a
    /// changed dose time must retime the series); present before but not
    /// now is a delete, and is emitted as a tombstone so a twin whose
    /// create once failed still gets cleaned up.
    static func plan(
        currentKeys: [String],
        snapshotKeys: Set<String>
    ) -> (created: Set<String>, removed: Set<String>) {
        let current = Set(currentKeys)
        return (current.subtracting(snapshotKeys), snapshotKeys.subtracting(current))
    }

    /// The slice of the ledger a reconcile pass may reason about: the
    /// keys that belong to `prefix` AND are SLOT-shaped (the
    /// three-component `kind:uuid:slot` form the schedule mirror writes).
    ///
    /// The narrowing is load-bearing, not housekeeping (D7): the ledger
    /// also holds significant-event one-off keys (`kind:<opaque id>`,
    /// written by the alert channel), and a prefix-only slice would let
    /// the reconciler read a written one-off as "removed by this schedule
    /// edit" and queue a tombstone that DELETES a live alert from the
    /// family's calendar. The 2-vs-3-component distinction is the one
    /// the parser already draws (`CalendarShareKey.parts`), so the
    /// snapshot reads that parse rather than a second spelling of the
    /// same rule — one grammar, one interpretation.
    static func reconcileSnapshotKeys(from knownKeys: Set<String>,
                                      prefix: String) -> Set<String> {
        knownKeys.filter { key in
            guard key.hasPrefix(prefix) else { return false }
            return CalendarShareKey.parts(key)?.slot != nil
        }
    }
}
