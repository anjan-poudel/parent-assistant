import Foundation
import Combine
import EventKit

// MARK: - Consent (calendar & family sharing, 2026-09-16)

/// The plain-language disclosure gate (design §5, gate 2 of 2).
///
/// Persisted in `UserDefaults`, NOT the encrypted store — it is an
/// opt-in flag with no personal content, the same placement
/// `ExternalCalendarService.isEnabled` and `CaregiverNotifySettings`
/// use. Absent reads as NOT accepted: sharing never starts by default.
///
/// The disclosure TEXT is not stored here. A re-readable copy lives in
/// the string catalog (`calendarShare.consent.*`) so it follows the app
/// language, and the acceptance is a bare bool — the same split every
/// other opt-in in this app uses.
final class CalendarShareConsent {

    static let defaultsKey = "calendarShare.consentAccepted"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAccepted: Bool {
        get { defaults.bool(forKey: Self.defaultsKey) }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }
}

// MARK: - Status

/// Everything the Settings card needs to tell the truth, as one value
/// (constitution: no silent stubs — an unconnected bridge has to say
/// exactly what is not happening and why).
struct CalendarShareStatus: Equatable {

    /// Where the Google connection stands.
    enum Connection: Equatable {
        /// No OAuth client id in the bundle — the app cannot even offer
        /// a sign-in. The card explains this rather than showing a
        /// button that would fail.
        case notConfigured
        /// Configured, but nobody has connected an account yet.
        case signedOut
        /// Connected, and holding every scope the share path needs.
        case connected(email: String?)
        /// SIGNED IN but without the Calendar/contacts grant — the elder
        /// declined the consent sheet, revoked the grant at Google, or
        /// the account was connected by a build that asked for identity
        /// alone (2026-09-17).
        ///
        /// Its own case rather than a flag on `connected`, because the
        /// two need different SCREENS, not a different sentence: this
        /// one can only offer the re-connect, while `connected` offers
        /// the disclosure. And folding it into `signedOut` would be a
        /// lie of a different kind — the app would be telling the elder
        /// they had no account when they can see it in Settings.
        case connectedWithoutScopes(email: String?)
    }

    var connection: Connection = .signedOut
    /// Whether the disclosure was accepted.
    var isConsented: Bool = false
    /// How many mutations are waiting on Google right now.
    var pendingCount: Int = 0
    /// When the queue last drained, nil before the first clean pass.
    var lastSyncAt: Date?
    /// The most recent failure class, for the honest status line.
    var lastError: GoogleShareError?

    /// Whether sharing is actually acting: connected, SCOPED and
    /// consented. Pending work with this false is exactly the state the
    /// card has to surface ("3 events waiting to share" + why they are
    /// waiting).
    ///
    /// `connectedWithoutScopes` is not active however loudly consent was
    /// given: the token cannot write to Calendar, so calling that state
    /// "sharing" would be exactly the silent stub the constitution
    /// forbids.
    var isActive: Bool {
        if case .connected = connection, isConsented, lastError == nil { return true }
        return false
    }
}

// MARK: - Service

/// The bridge between the app's local-first world and Google Calendar
/// (design §4.1). Local behavior is COMPLETELY untouched by this class:
/// events still land in EventKit first, alarms still fire from there,
/// and every failure here degrades to "not shared" rather than to "not
/// reminded".
///
/// Responsibilities, and deliberately nothing else:
///  - reconcile the shared twins of medication/routine/calendar items
///    into a persisted queue (`reconcileMedication`, `reconcileRoutines`,
///    `eventCreated`, `eventDeleted`);
///  - drain that queue against Google with bounded retries
///    (`flushPending`);
///  - pull invitations the family sent the elder INTO the local calendar
///    (`syncInbound`), where the existing import arms them.
///
/// The Google IO lives entirely behind `GoogleCalendarGatewayProtocol`
/// and `GoogleAccountSessionProtocol`, so every rule above is
/// unit-tested with no network, no SDK and no OAuth client.
final class CalendarShareService: ObservableObject {

    @Published private(set) var status: CalendarShareStatus

    private let session: GoogleAccountSessionProtocol
    private let gateway: GoogleCalendarGatewayProtocol
    private let store: LocalGoogleEventMappingStore
    private let consent: CalendarShareConsent
    private let notifySettings: CaregiverNotifySettings
    private let observabilityBus: ObservabilityBus
    private let eventKit: EventKitCalendarGateway
    private let now: () -> Date
    /// Contacts are read at reconcile time, never captured — the family
    /// edits them in Settings and the next pass must see the edit.
    private let contactsProvider: () -> [FamilyContact]
    /// Google's continuation token for the inbound listing, persisted in
    /// UserDefaults (opaque, non-personal).
    private let defaults: UserDefaults
    /// Locale for the routine twins' titles — matches the native mirror's
    /// label so both calendars read the same.
    var locale: Locale = Locale(identifier: "en")

    /// Fired after an inbound event is written to the local calendar, so
    /// the coordinator can run the existing import immediately — the
    /// imported event then arms a notification and fires the caregiver
    /// alert through the paths that already exist.
    var onLocalEventImported: (() -> Void)?

    private static let syncTokenDefaultsKey = "calendarShare.inboundSyncToken"

    init(
        session: GoogleAccountSessionProtocol,
        gateway: GoogleCalendarGatewayProtocol,
        store: LocalGoogleEventMappingStore,
        consent: CalendarShareConsent,
        notifySettings: CaregiverNotifySettings,
        observabilityBus: ObservabilityBus,
        eventKit: EventKitCalendarGateway = EKCalendarGateway(),
        contactsProvider: @escaping () -> [FamilyContact],
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.gateway = gateway
        self.store = store
        self.consent = consent
        self.notifySettings = notifySettings
        self.observabilityBus = observabilityBus
        self.eventKit = eventKit
        self.contactsProvider = contactsProvider
        self.defaults = defaults
        self.now = now
        self.status = CalendarShareStatus()
        refreshStatus()
    }

    // MARK: - Main-thread discipline

    /// Runs `block` on the main queue (immediately when already there).
    ///
    /// The service is a plain `ObservableObject` rather than
    /// `@MainActor`, because its callers are deliberately a mix:
    /// `MedicationScheduler`'s change callback and view actions arrive on
    /// main, while the network passes resume on whatever thread the
    /// session chose. Publishing `status` has to happen on main either
    /// way, so the hop lives here instead of in every caller.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// One pass at a time, per pass kind.
    ///
    /// A reconcile auto-flushes and the launch/foreground hooks flush
    /// too, so two passes can overlap; without this gate they would each
    /// create the same event — double invitations for the family, and a
    /// twin neither pass can find afterwards. A lock rather than an
    /// actor because the guarded work is an async call-and-return, not
    /// state anything else reads.
    private final class PassGate {
        private let lock = NSLock()
        private var isRunning = false

        /// True when the caller now owns the pass and must call `end()`.
        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isRunning else { return false }
            isRunning = true
            return true
        }

        func end() {
            lock.lock()
            defer { lock.unlock() }
            isRunning = false
        }
    }

    private let flushGate = PassGate()
    private let inboundGate = PassGate()

    // MARK: - Status

    /// Recomputes the published status from the session, the consent flag
    /// and the persisted queue. Cheap (two small storage reads) and
    /// idempotent, so every entry point can call it before it acts.
    func refreshStatus() {
        guard Thread.isMainThread else {
            onMain { [weak self] in self?.refreshStatus() }
            return
        }
        var next = CalendarShareStatus()
        next.isConsented = consent.isAccepted
        next.pendingCount = store.pendingCount
        next.lastSyncAt = store.lastSyncAt
        next.lastError = gateway.lastErrorClass

        if !session.isConfigured {
            next.connection = .notConfigured
        } else if session.isSignedIn {
            // Signed in is not the same as able to share: the account
            // can lack the Calendar/contacts grant, and the card has to
            // say which of the two it is holding (2026-09-17).
            next.connection = session.hasRequiredScopes
                ? .connected(email: session.accountEmail)
                : .connectedWithoutScopes(email: session.accountEmail)
        } else {
            next.connection = .signedOut
        }
        // A refusal is reported by the gateway as `.unauthorized` (401:
        // the session is gone) or `.insufficientScopes` (403: the token
        // in hand was minted for the wrong scopes); the connection is
        // still nominally signed in, so the card says "connected" and the
        // error line says what is wrong with it.
        if status != next {
            status = next
        }
    }

    // MARK: - Consent

    /// Records acceptance of the disclosure. Accepting is what UNLOCKS
    /// sharing — the reconcile entry points below enqueue nothing until
    /// both gates pass, so nothing was ever queued behind the user's back.
    func acceptConsent() {
        consent.isAccepted = true
        emit("calendar_share_consent_accepted", outcome: "success")
        refreshStatus()
    }

    /// Withdraws consent and stops sharing (design §5: "revoked consent
    /// pauses sharing; local behavior never affected"). The queue is
    /// KEPT — re-accepting resumes exactly where it left off, and losing
    /// the family's pending work to a mis-tap would be its own bug.
    func revokeConsent() {
        consent.isAccepted = false
        emit("calendar_share_consent_revoked", outcome: "success")
        refreshStatus()
    }

    // MARK: - Account

    /// Presents Google sign-in. Returns whether a fully-connected session
    /// exists afterwards; on success the pending queue is flushed
    /// immediately (anything the family queued while signed out lands
    /// now).
    ///
    /// A sign-in that ends WITHOUT the Calendar/contacts grant returns
    /// false and flushes nothing: the queue would fail item by item with
    /// a 401, and the next pass (this card's "try again", or the
    /// foreground flush) would repeat it. The status tells the card
    /// which of the two "false" states the household is in.
    @discardableResult
    func signIn() async -> Bool {
        let outcome = await session.signIn()
        refreshStatus()
        if outcome.isConnected { await flushPending() }
        return outcome.isConnected
    }

    /// Presents Google's account-creation flow, then signs in — for the
    /// household that has no Google account at all (design §2 decision 3).
    @discardableResult
    func createAccount() async -> Bool {
        let outcome = await session.createAccount()
        refreshStatus()
        if outcome.isConnected { await flushPending() }
        return outcome.isConnected
    }

    /// Brings back the Google account a previous launch connected, then
    /// republishes the status so the Settings card shows the restored
    /// "signed in as" state (2026-09-17).
    ///
    /// The republish is the point of doing this HERE rather than at the
    /// call site: `status` is published state the card observes, and the
    /// restore completes asynchronously — after launch has already
    /// rendered. A card that read the session directly would be right by
    /// accident; a card driven by `status` is only right if something
    /// recomputes it when the restore lands, which is this line.
    ///
    /// A restore that brings nothing back changes nothing here: the
    /// status recomputes to the same `signedOut` (or `notConfigured`)
    /// it already showed, and the queue stays exactly as it was. That is
    /// the honest degradation — a failed restore must not look like a
    /// connection, and it must not look like a fresh problem either.
    ///
    /// Flushing on success is what makes the restore worth doing at
    /// launch rather than only on the next foreground: anything the
    /// family queued before the process restarted drains now, instead of
    /// waiting behind a sign-in the elder has no reason to perform again.
    @discardableResult
    func restoreSession() async -> Bool {
        let outcome = await session.restorePreviousSession()
        refreshStatus()
        if outcome.isConnected { await flushPending() }
        return outcome.isConnected
    }

    /// Drops the session and PAUSES sharing. The local calendar, the
    /// local reminders and every local alarm are untouched — signing out
    /// of Google must never make the elder's own reminders stop firing.
    ///
    /// The queue is cleared with the map: both are the working state of a
    /// share that can no longer happen, and the local items remain the
    /// source of truth, so a later sign-in re-creates what it still
    /// needs. Leaving a stale map behind would make the next sign-in
    /// "update" twins that belong to a different account.
    func signOut() {
        session.signOut()
        store.clear()
        defaults.removeObject(forKey: Self.syncTokenDefaultsKey)
        emit("calendar_share_signed_out", outcome: "success")
        refreshStatus()
    }

    // MARK: - Reconcile: medication

    /// Reconciles a medication schedule into shared twins.
    ///
    /// Called from the scheduler's `onScheduleChanged` seam, so it sees
    /// every add/remove/voice-create through one path. It diffs against
    /// the map's known keys: entries/slots that are new become creates,
    /// ones that are gone become tombstones, and everything still
    /// present is re-queued as an update so an edit (a retimed dose)
    /// reaches the twin.
    func reconcileMedication(_ entries: [MedicationEntry]) {
        onMain { [weak self] in
            guard let self else { return }
            let contacts = self.contactsProvider()
            var desired: [String: CalendarTwinDraft] = [:]
            for entry in entries {
                let drafts = CalendarShareMapper.medicationDrafts(
                    entry: entry, contacts: contacts,
                    notifySettings: self.notifySettings, now: self.now())
                for (slot, draft) in drafts.enumerated() {
                    desired[CalendarShareKey.slot(kind: .medicationReminder,
                                                  entryId: entry.id, slot: slot)] = draft
                }
            }
            self.reconcile(kind: .medicationReminder, desired: desired,
                           ownedKeyPrefix: nil)
        }
    }

    // MARK: - Reconcile: routines

    /// Reconciles the routine schedule into shared twins — same diff
    /// shape as medication, with the routine's own recurrence and the
    /// "<name> (<category>)" title the native mirror uses.
    func reconcileRoutines(_ entries: [RoutineEntry]) {
        onMain { [weak self] in
            guard let self else { return }
            let contacts = self.contactsProvider()
            var desired: [String: CalendarTwinDraft] = [:]
            for entry in entries {
                let drafts = CalendarShareMapper.routineDrafts(
                    entry: entry, contacts: contacts,
                    notifySettings: self.notifySettings, now: self.now(),
                    locale: self.locale)
                for (slot, draft) in drafts.enumerated() {
                    desired[CalendarShareKey.slot(kind: .routineReminder,
                                                  entryId: entry.id, slot: slot)] = draft
                }
            }
            self.reconcile(kind: .routineReminder, desired: desired,
                           ownedKeyPrefix: nil)
        }
    }

    // MARK: - Reconcile: calendar events

    /// A one-off event was created locally (voice, import, or the Events
    /// form). Shares it, when the policy says anyone wants it.
    ///
    /// `location` is the address the elder typed (rich-events task,
    /// 2026-09-17): it rides into the twin's Google `location` row, which
    /// is what makes the family's invitation open in their own maps.
    /// Defaulted to nil so the voice-created path, which has no address
    /// field, is unchanged.
    func eventCreated(localEventId: String, title: String, startDate: Date,
                      durationMinutes: Int, location: String? = nil) {
        onMain { [weak self] in
            guard let self, self.canShare else { return }
            let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                             eventIdentifier: localEventId)
            guard let draft = CalendarShareMapper.calendarEventDraft(
                title: title, startDate: startDate, durationMinutes: durationMinutes,
                contacts: self.contactsProvider(), notifySettings: self.notifySettings,
                location: location
            ) else {
                // Nobody is eligible — including the case where the only
                // candidate has no email. Nothing is queued, and no twin is
                // left behind, so a LATER edit that makes someone eligible
                // starts from a clean slate.
                return
            }
            // Marked as OURS before the request goes out, and marked as
            // ours even if it never lands: the stale-twin sweep must only
            // ever consider deleting events this device put on the
            // family's calendar (see the store's note).
            _ = self.store.markOutbound(key)
            self.enqueue(key: key, draft: draft)
        }
    }

    /// Stale-twin sweep (design §2.5): a local one-off the family shared,
    /// and the elder later deleted in the Calendar app, leaves a twin on
    /// the shared calendar that nobody can see locally — and the family
    /// keeps a doctor's appointment that no longer exists.
    ///
    /// Only events this device CREATED are considered (`isOutbound`), for
    /// the reason the marker's own doc gives: for an imported invitation
    /// the twin is the ORGANIZER's event, and deleting it on the elder's
    /// behalf would take it off the family's calendar too.
    ///
    /// Full calendar access is required, not merely write access: the
    /// store answers nil for every lookup without read permission, which
    /// this sweep would read as "everything is gone" and answer with a
    /// mass delete. A permission we do not have means an answer we do not
    /// have, and the safe move is to sweep nothing.
    func cleanupVanishedEvents() {
        onMain { [weak self] in
            guard let self, self.canShare else { return }
            guard self.eventKit.eventsAccess == .fullAccess else {
                self.emit("calendar_share_sweep_skipped", outcome: "failure",
                          metadata: ["reason": "no_calendar_access"])
                return
            }
            var swept = 0
            for key in self.store.outboundKeys {
                // Two conditions, and both are about not deleting blind: a
                // key with no twin id has nothing out there to delete, and
                // a key whose local event still exists is not stale at all.
                guard self.store.googleEventID(for: key) != nil else { continue }
                guard let localId = CalendarShareKey.oneOffIdentifier(key) else { continue }
                guard !self.eventKit.eventExists(identifier: localId) else { continue }
                // The twin is orphaned. The tombstone is queued and the
                // ownership mark dropped in the same turn, so the next
                // sweep does not queue the same deletion again while the
                // flush is still in flight.
                self.enqueueTombstone(key: key, kind: .calendarEvent)
                _ = self.store.unmarkOutbound(key)
                swept += 1
            }
            if swept > 0 {
                self.emit("calendar_share_swept", outcome: "success",
                          metadata: ["vanished": "\(swept)"])
                self.refreshStatus()
                Task { await self.flushPending() }
            }
        }
    }

    /// Carries the free-form events' CURRENT native state over to their
    /// twins (rich-events task, 2026-09-17; design §3: "edits/deletes via
    /// a foreground reconcile of side-index-tracked events").
    ///
    /// A free-form event is native by construction, so the Calendar app's
    /// copy — which the elder, the family and the Events form all edit —
    /// is the source of truth, and this pass is the bridge to Google. It
    /// reads each tracked event, builds the draft its current title /
    /// start / duration / address imply, and lets the ordinary reconcile
    /// diff decide: a changed fingerprint re-queues the twin, and an
    /// event that no longer exists queues its tombstone. Nothing here
    /// decides WHAT changed — the fingerprint (`CalendarShareMapper`)
    /// already does, over exactly the fields the gateway sends.
    ///
    /// `trackedEventIds` is the side index's key set, and it is the
    /// SNAPSHOT of the diff rather than every `calendarEvent:` key in the
    /// ledger. That distinction is load-bearing: the ledger also holds
    /// invitations this device IMPORTED (`importLocally`), where "the
    /// twin" is the organizer's own event — treating those as gone would
    /// delete the family's event from their own calendar. Only the ids the
    /// caller says are the app's own are ever considered.
    ///
    /// Full calendar access is required, and for the same reason the
    /// sweep requires it: without read permission every lookup answers
    /// nil, which this pass would read as "every event is gone" and answer
    /// with a mass delete.
    func reconcileFreeFormEvents(trackedEventIds: Set<String>) {
        onMain { [weak self] in
            guard let self, self.canShare else { return }
            guard self.eventKit.eventsAccess == .fullAccess else {
                self.emit("calendar_share_events_skipped", outcome: "failure",
                          metadata: ["reason": "no_calendar_access"])
                return
            }
            let contacts = self.contactsProvider()
            var desired: [String: CalendarTwinDraft] = [:]
            var snapshot: Set<String> = []
            for eventId in trackedEventIds {
                let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                                  eventIdentifier: eventId)
                snapshot.insert(key)
                guard let record = self.eventKit.fetchEvent(identifier: eventId),
                      !record.isCanceled,
                      let draft = CalendarShareMapper.calendarEventDraft(
                        title: record.title,
                        startDate: record.startDate,
                        durationMinutes: record.durationMinutes,
                        contacts: contacts,
                        notifySettings: self.notifySettings,
                        location: record.location
                      )
                else {
                    // Either gone (the tombstone below is the honest
                    // answer) or momentarily unshareable because nobody
                    // is eligible right now — in which case the diff
                    // withdraws the twin, which is the same thing the
                    // policy says for the other kinds.
                    continue
                }
                desired[key] = draft
            }
            self.reconcile(kind: .calendarEvent, desired: desired,
                           ownedKeyPrefix: nil, knownKeySnapshot: snapshot)
        }
    }

    /// A one-off event was deleted locally — queue its tombstone.
    ///
    /// Now has a caller (rich-events task, 2026-09-17): the Events form's
    /// delete, the first in-app calendar-event deletion the app has ever
    /// had. The pair with `eventCreated` is what keeps the family's copy
    /// honest — an appointment the elder removed locally must not stay on
    /// the shared calendar.
    ///
    /// Gated on `canShare` exactly like `eventCreated`, and for the same
    /// reason: with sharing off, a queued tombstone would be a row waiting
    /// on a decision the family has not made, and the Settings card's
    /// pending count must never mean that. Nothing is lost by it — an
    /// event deleted while signed out leaves its key in the ledger, and
    /// `cleanupVanishedEvents()` queues this same tombstone on the first
    /// pass after sharing is switched on.
    func eventDeleted(localEventId: String) {
        onMain { [weak self] in
            guard let self, self.canShare else { return }
            let key = CalendarShareKey.oneOff(kind: .calendarEvent,
                                             eventIdentifier: localEventId)
            self.enqueueTombstone(key: key, kind: .calendarEvent)
        }
    }

    // MARK: - Reconcile core

    /// Whether both gates are open. Enqueueing is gated on this so a
    /// signed-out or un-consented app accumulates NO queue: the Settings
    /// card's pending count then means "waiting on Google", never
    /// "waiting on a decision the family has not made yet".
    private var canShare: Bool {
        CalendarShareMapper.canShare(isSignedIn: session.isSignedIn,
                                     hasConsented: consent.isAccepted)
    }

    /// The shared diff for a kind: create what has no twin yet, update
    /// the twins whose CONTENT changed, queue tombstones for what
    /// vanished — and nothing at all for the twins that are already
    /// right, which is the common case on every launch.
    ///
    /// `knownKeySnapshot` overrides "last-known" for the callers whose
    /// knowledge is NARROWER than the ledger. Medication and routine
    /// passes leave it nil (every key of their kind is theirs to judge);
    /// the free-form reconcile passes the tracked key set, because the
    /// ledger also holds imported invitations that it must not delete —
    /// see `reconcileFreeFormEvents`.
    private func reconcile(kind: EventNotifyKind, desired: [String: CalendarTwinDraft],
                           ownedKeyPrefix: String?,
                           knownKeySnapshot: Set<String>? = nil) {
        guard canShare else { refreshStatus(); return }
        let prefix = ownedKeyPrefix ?? "\(kind.rawValue):"
        let known = knownKeySnapshot ?? Set(store.knownKeys.filter { $0.hasPrefix(prefix) })
        let plan = CalendarShareMapper.plan(currentKeys: Array(desired.keys),
                                            snapshotKeys: known)

        var created = 0
        var updated = 0
        for key in plan.created {
            guard let draft = desired[key] else { continue }
            enqueue(key: key, draft: draft)
            created += 1
        }
        for (key, draft) in desired where store.googleEventID(for: key) != nil {
            // The twin exists; only a CONTENT change is worth a request.
            guard store.fingerprint(for: key) != CalendarShareMapper.fingerprint(of: draft)
            else { continue }
            enqueue(key: key, draft: draft)
            updated += 1
        }
        for key in plan.removed {
            enqueueTombstone(key: key, kind: kind)
        }
        let removed = plan.removed.count
        emit("calendar_share_reconciled", outcome: "success", metadata: [
            "kind": kind.rawValue,
            "created": "\(created)",
            "updated": "\(updated)",
            "removed": "\(removed)"
        ])
        refreshStatus()
        if created + updated + removed > 0 {
            Task { await flushPending() }
        }
    }

    private func enqueue(key: String, draft: CalendarTwinDraft) {
        _ = store.enqueue(.upsert(key: key, draft: draft,
                                  googleEventID: store.googleEventID(for: key)))
    }

    private func enqueueTombstone(key: String, kind: EventNotifyKind) {
        _ = store.enqueue(.tombstone(key: key, kind: kind,
                                     googleEventID: store.googleEventID(for: key)))
    }

    // MARK: - Flush

    /// Drains the queue against Google.
    ///
    /// Ordering is oldest-first and a pass STOPS at the first failure —
    /// whatever caused it (rate limit, dead network, a revoked token)
    /// applies to every operation behind it, and the next foreground or
    /// interval pass is the backoff. "The twin is already gone" is NOT a
    /// failure: `apply` classifies a 404 as done (an update re-creates,
    /// a delete is already satisfied), so a pass only stops on an error
    /// it genuinely cannot act on.
    ///
    /// A 403 is called out separately (`calendar_share_flush_paused`): the
    /// account is connected but no longer usable, which is the signal for
    /// Settings to ask the family to reconnect rather than to keep
    /// retrying. The operation that hit it is left exactly as it was —
    /// a paused pass is not a failed attempt, so nothing is backed off.
    /// The class is read from the FAILURE, never remembered from an
    /// earlier pass, so reconnecting resumes immediately.
    func flushPending() async {
        guard flushGate.begin() else { return }
        defer { flushGate.end() }
        guard canShare else { refreshStatus(); return }
        let queue = store.pending
        // What the queue held when the pass started. The commit compares
        // against this to tell "the operation I just applied" from "a
        // NEWER operation the family enqueued while the pass was in
        // flight" — the two are not distinguishable by key alone, and
        // conflating them either loses an edit or re-queues work forever.
        let snapshot = Dictionary(queue.map { ($0.key, $0) },
                                  uniquingKeysWith: { _, latest in latest })
        guard !queue.isEmpty else {
            store.lastSyncAt = now()
            refreshStatus()
            return
        }
        // Backoff (design §2.5): the queue is retried, not hammered. An
        // operation that has already failed carries the instant it was
        // last tried and waits out an exponential delay before the next
        // attempt, so a Google that is refusing everything costs ONE
        // request per delay window instead of one per foreground and one
        // per schedule edit. An operation that has never failed is always
        // due, so the common case (a fresh change) is never delayed.
        let passInstant = now()
        let due = queue.filter { $0.isDue(at: passInstant) }
        guard !due.isEmpty else {
            emit("calendar_share_flush_deferred", outcome: "success",
                 metadata: ["waiting": "\(queue.count)"])
            refreshStatus()
            return
        }
        guard let calendarID = await gateway.ensureFamilyCalendar() else {
            emit("calendar_share_flush_failed", outcome: "failure",
                 metadata: ["reason": errorClassLabel(gateway.lastErrorClass)])
            refreshStatus()
            return
        }
        // The invitees' own details, for the People contact the invite
        // rides on — read once per pass, on main (see `contactsByEmail`).
        let contacts = await contactsByEmail()

        // The network half touches NOTHING persisted: `apply` reports
        // what should happen and the commit below, on main, does it.
        var appliedKeys: Set<String> = []
        var mapUpdates: [String: String] = [:]
        var mapRemovals: Set<String> = []
        var appliedFingerprints: [String: String] = [:]
        var failedKeys: Set<String> = []
        /// Keys refused for authorization (an expired/revoked token, or a
        /// scope the family never granted). Kept APART from `failedKeys`
        /// because a paused pass is not a failed attempt: there is nothing
        /// to back off from, the family has to reconnect. The Settings
        /// card turns this into "reconnect your account", while a rate
        /// limit or a dead network stays an ordinary retry.
        var pausedKeys: Set<String> = []
        var pausedForAuth = false
        /// WHICH refusal stopped the pass, for the event below. Kept as
        /// the class rather than a Bool because 401 and 403 are no longer
        /// one thing (2026-09-17) and a log line that called a 403
        /// "unauthorized" is exactly the merge this split removes.
        var pausedClass: GoogleShareError = .unauthorized

        for operation in due {
            // Stop at the first failure: whatever caused it (rate limit,
            // dead network, revoked token) applies to every operation
            // behind it, and the next foreground/interval pass is the
            // backoff.
            if !failedKeys.isEmpty || pausedForAuth { break }
            switch await apply(operation, calendarID: calendarID, contacts: contacts) {
            case .applied(let newGoogleEventID):
                appliedKeys.insert(operation.key)
                if let newGoogleEventID { mapUpdates[operation.key] = newGoogleEventID }
                // Record what WAS written, so the next reconcile can tell
                // "already current" from "the family changed this" — see
                // `fingerprint(of:)`. A payload too incomplete to rebuild
                // records nothing, which reads as unknown and costs one
                // extra write rather than a lost edit.
                if let draft = draft(from: operation) {
                    appliedFingerprints[operation.key] =
                        CalendarShareMapper.fingerprint(of: draft)
                }
            case .appliedRemovingMapping:
                appliedKeys.insert(operation.key)
                mapRemovals.insert(operation.key)
            case .retry:
                // Read the class HERE, right after the operation that
                // failed, rather than before the pass: the class is not
                // sticky (any later success clears it), so a pre-pass read
                // can only ever be another operation's leftovers — and
                // since nothing would clear it, a stale refusal would
                // skip every later pass including the one right after the
                // family reconnects.
                //
                // BOTH refusal classes pause (401 and 403): they are two
                // causes of one state — nothing queued can land until the
                // family reconnects — and the class itself is kept so the
                // event below names the one that actually happened
                // instead of labelling every pause "unauthorized".
                if let refusal = gateway.lastErrorClass, refusal.isAuthorizationFailure {
                    pausedForAuth = true
                    pausedClass = refusal
                    pausedKeys.insert(operation.key)
                } else {
                    failedKeys.insert(operation.key)
                }
            }
        }

        let appliedCount = appliedKeys.count
        let didFail = !failedKeys.isEmpty
        // Commit on main, and READ THE QUEUE AT COMMIT rather than
        // restoring the snapshot taken before it: a reconcile can enqueue
        // while the pass is in flight, and writing the old snapshot back
        // would silently drop whatever the family changed in the
        // meantime. The mapping is written first so the reconcile below
        // sees the ids this pass learned.
        onMain { [weak self] in
            guard let self else { return }
            for (key, id) in mapUpdates { _ = self.store.setGoogleEventID(id, for: key) }
            for (key, fingerprint) in appliedFingerprints {
                _ = self.store.setFingerprint(fingerprint, for: key)
            }
            for key in mapRemovals {
                _ = self.store.removeGoogleEventID(for: key)
                _ = self.store.removeFingerprint(for: key)
            }

            let next = self.store.pending.compactMap { op -> PendingShareOperation? in
                // Refused for authorization: left EXACTLY as it was, so
                // the queue reads as untouched (no attempt, no backoff)
                // and resumes the moment the family reconnects.
                if pausedKeys.contains(op.key) { return op }
                if failedKeys.contains(op.key) { return op.retried(at: passInstant) }
                guard appliedKeys.contains(op.key) else { return op }
                // This pass satisfied a key. Two very different things can
                // sit in the queue under that key now, and the ONLY way to
                // tell them apart is the pass's opening snapshot:
                //
                //   * the op the pass just applied, still unchanged —
                //     done, DROP it. Keeping it would re-PUT the twin on
                //     every later pass (defeating `fingerprint(of:)`) and
                //     would leave `pendingCount` stuck above zero forever.
                //   * a DIFFERENT op the family enqueued while the pass
                //     was in flight — keep it (dropping it would lose the
                //     edit), retargeted at the id the pass just learned so
                //     it updates the twin instead of creating a duplicate
                //     or dying on the nil id it was enqueued with.
                if snapshot[op.key] == op { return nil }
                guard let id = self.store.googleEventID(for: op.key) else { return nil }
                var carried = op
                carried.googleEventID = id
                carried.action = op.action == .create ? .update : op.action
                carried.attempts = 0
                return carried
            }
            _ = self.store.replacePending(next)
            if !didFail { self.store.lastSyncAt = self.now() }
            self.emit("calendar_share_flushed",
                      outcome: didFail ? "failure" : "success",
                      metadata: ["applied": "\(appliedCount)",
                                 "remaining": "\(next.count)"])
            if pausedForAuth {
                self.emit("calendar_share_flush_paused", outcome: "failure",
                          metadata: ["reason": self.errorClassLabel(pausedClass)])
            }
            self.refreshStatus()
        }
    }

    /// Outcome of one queued operation — what the caller must COMMIT, not
    /// what it already did. Every store mutation happens in
    /// `flushPending`'s main-thread commit, so this half stays purely
    /// network + values.
    private enum ApplyOutcome: Equatable {
        /// Done. Carries the twin id to record when the step learned one
        /// (a create, or a re-create after the twin turned out to be
        /// gone); nil means the mapping is already correct.
        case applied(newGoogleEventID: String?)
        /// Done, and the key's mapping should be dropped (a delete, or a
        /// tombstone for a twin that never existed).
        case appliedRemovingMapping
        case retry
    }

    private func apply(_ operation: PendingShareOperation,
                       calendarID: String,
                       contacts: [String: FamilyContact]) async -> ApplyOutcome {
        switch operation.action {
        case .create:
            // Contacts first, best-effort: a failure here must not stop
            // the invite (`ensureContact` is documented best-effort). The
            // family's own name and phone for the address ride along when
            // they exist, so the elder's address book gains a person they
            // can recognise and call rather than a bare address.
            for email in operation.attendeeEmails ?? [] {
                let contact = contacts[email.lowercased()]
                _ = await gateway.ensureContact(email: email,
                                                name: contact?.name,
                                                phone: contact?.phone)
            }
            guard let draft = draft(from: operation) else {
                return .appliedRemovingMapping
            }
            guard let id = await gateway.createEvent(draft) else { return .retry }
            return .applied(newGoogleEventID: id)

        case .update:
            guard let draft = draft(from: operation) else {
                return .appliedRemovingMapping
            }
            guard let id = operation.googleEventID else {
                // No twin id: the original create never confirmed. Create
                // now rather than retrying an update that cannot address
                // anything.
                guard let newID = await gateway.createEvent(draft) else { return .retry }
                return .applied(newGoogleEventID: newID)
            }
            if await gateway.updateEvent(id: id, with: draft) {
                return .applied(newGoogleEventID: nil)
            }
            // Gone on Google's side (someone deleted the twin there). The
            // local item is the source of truth, so re-create it under
            // the same key. Any OTHER failure just retries — re-creating
            // after a transient error would leave the family with two
            // copies of the same dose.
            guard gateway.lastErrorClass == .notFound else { return .retry }
            guard let newID = await gateway.createEvent(draft) else { return .retry }
            return .applied(newGoogleEventID: newID)

        case .delete:
            guard let id = operation.googleEventID else {
                // Tombstone for a twin that was never confirmed to exist
                // — nothing to do, and keeping it would pin the pending
                // count up forever.
                return .appliedRemovingMapping
            }
            if await gateway.deleteEvent(id: id) { return .appliedRemovingMapping }
            // Already gone is the goal state, not a failure: someone
            // deleted the twin on Google's side. Retrying would leave a
            // tombstone that can never drain, so the pending count would
            // never come back to zero.
            guard gateway.lastErrorClass == .notFound else { return .retry }
            return .appliedRemovingMapping
        }
    }

    /// The family's contacts, keyed by their normalized (lowercased)
    /// address — the flush pass's lookup for an invitee's own details.
    ///
    /// Read on MAIN via a hop, not directly: `contactsProvider` returns
    /// the coordinator's published `familyContacts`, which are only ever
    /// mutated on the main queue, and the flush pass runs off it. The
    /// result is a value, so nothing off-main holds a reference.
    private func contactsByEmail() async -> [String: FamilyContact] {
        await withCheckedContinuation { continuation in
            onMain { [weak self] in
                guard let self else { return continuation.resume(returning: [:]) }
                var byEmail: [String: FamilyContact] = [:]
                for contact in self.contactsProvider() {
                    guard let email = FamilyContactValidation.normalizedEmail(contact.email)
                    else { continue }
                    // First one wins: the editor makes a duplicate address
                    // hard to create, and flip-flopping between two
                    // matches across passes would be worse than picking.
                    if byEmail[email.lowercased()] == nil {
                        byEmail[email.lowercased()] = contact
                    }
                }
                continuation.resume(returning: byEmail)
            }
        }
    }

    private func draft(from operation: PendingShareOperation) -> CalendarTwinDraft? {
        guard let title = operation.title,
              let start = operation.startDate,
              let duration = operation.durationMinutes,
              let zone = operation.timeZoneIdentifier else { return nil }
        return CalendarTwinDraft(
            title: title, startDate: start, durationMinutes: duration,
            timeZoneIdentifier: zone, recurrence: operation.recurrence,
            attendeeEmails: operation.attendeeEmails ?? [],
            kind: operation.kind,
            // Carried through, not dropped: the flush pass records the
            // fingerprint of what it just WROTE, and the reconcile
            // compares that against the fingerprint of the current
            // draft. A field that survives one reconstruction but not
            // the other makes every item look permanently changed — one
            // PUT per pass, forever (rich-events task, 2026-09-17).
            location: operation.location)
    }

    // MARK: - Inbound

    /// Pulls invitations the family sent the elder into the local
    /// calendar (design §4.5).
    ///
    /// An event the caregiver created in their own Google Calendar and
    /// invited the elder to appears on the elder's primary calendar with
    /// the elder's attendee entry at `needsAction`. This accepts it,
    /// mirrors it into the DEFAULT EventKit calendar, and lets the
    /// existing import arm it — so it rings and fires the caregiver
    /// alert through paths that already work, with no new machinery.
    ///
    /// Honest limitation (design §4.5): inbound arrives at the next
    /// foreground or interval tick. There is no push channel until the
    /// TG-07 relay exists.
    func syncInbound() async {
        guard inboundGate.begin() else { return }
        defer { inboundGate.end() }
        guard canShare else { refreshStatus(); return }
        // Inbound needs to WRITE to the local calendar; without access
        // there is nowhere to put an accepted invitation, and asking for
        // it here (mid-poll, with no user action) would be a prompt out
        // of nowhere.
        let access = eventKit.eventsAccess
        guard access == .fullAccess || access == .writeOnly else {
            emit("calendar_share_inbound_skipped", outcome: "failure",
                 metadata: ["reason": "no_calendar_access"])
            return
        }
        guard let page = await gateway.listIncoming(
            syncToken: defaults.string(forKey: Self.syncTokenDefaultsKey)
        ) else {
            emit("calendar_share_inbound_failed", outcome: "failure",
                 metadata: ["reason": errorClassLabel(gateway.lastErrorClass)])
            refreshStatus()
            return
        }

        var imported = 0
        for event in page.events where event.needsResponse {
            guard !isAlreadyImported(googleEventID: event.eventId) else { continue }
            guard await gateway.acceptInvitation(eventId: event.eventId) else {
                // Not accepted, so do not import it — an event the elder
                // never accepted should not ring as a reminder.
                continue
            }
            if importLocally(event) { imported += 1 }
        }

        // Persist the continuation token even when nothing was imported —
        // otherwise every poll rescans the same window, and the "nothing
        // new" case would cost a full listing forever.
        let token = page.nextSyncToken
        let seen = page.events.count
        onMain { [weak self] in
            guard let self else { return }
            if let token {
                self.defaults.set(token, forKey: Self.syncTokenDefaultsKey)
            }
            self.emit("calendar_share_inbound", outcome: "success",
                      metadata: ["seen": "\(seen)", "imported": "\(imported)"])
            if imported > 0 {
                self.store.lastSyncAt = self.now()
                // The coordinator's cue to run the existing import now
                // rather than at the next scan — the accepted invitation
                // is in the native calendar, and the import is what turns
                // it into an armed reminder.
                self.onLocalEventImported?()
            }
            self.refreshStatus()
        }
    }

    /// Whether this Google event is already mirrored locally. A linear
    /// scan is right at this size (the whole map is one family's shared
    /// items) and avoids a second persisted index that could disagree
    /// with the first.
    private func isAlreadyImported(googleEventID: String) -> Bool {
        store.map.values.contains(googleEventID)
    }

    /// Writes the accepted invitation into the DEFAULT calendar.
    ///
    /// The default calendar, not the "Sahayak" mirror: `AppCoordinator`
    /// excludes Sahayak from the external import, so an event created
    /// there would never be imported, armed or fired — the same
    /// load-bearing choice `EventKitCalendarEventWriter` documents.
    private func importLocally(_ event: GoogleIncomingEvent) -> Bool {
        let duration = max(1, Int((event.endDate ?? event.startDate)
            .timeIntervalSince(event.startDate) / 60))
        let draft = CalendarEventDraft(
            title: event.title,
            notes: nil,
            startDate: event.startDate,
            durationMinutes: duration,
            recurrence: nil)
        guard let localId = eventKit.createEvent(draft, in: nil) else { return false }
        // Remember the pairing so the next poll does not import it twice
        // and so a later deletion of the local event can tombstone it.
        _ = store.setGoogleEventID(event.eventId,
                                   for: CalendarShareKey.oneOff(
                                       kind: .calendarEvent, eventIdentifier: localId))
        return true
    }

    // MARK: - Observability

    /// Coarse label for an error, safe to emit — an enum name, never a
    /// message. The whole share layer follows the `FamilyAlertContext`
    /// rule: counts and classes only, never titles or addresses.
    private func errorClassLabel(_ error: GoogleShareError?) -> String {
        guard let error else { return "none" }
        switch error {
        case .notSignedIn: return "not_signed_in"
        case .notConfigured: return "not_configured"
        case .unauthorized: return "unauthorized"
        case .insufficientScopes: return "insufficient_scopes"
        case .rateLimited: return "rate_limited"
        case .notFound: return "not_found"
        case .server: return "server"
        case .malformedResponse: return "malformed_response"
        case .transport: return "transport"
        }
    }

    private func emit(_ type: String, outcome: String,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "calendar_share", eventType: type, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}
