import Foundation

/// A single upcoming doctor's appointment (medical task, 2026-09-07).
///
/// `doctorOrPlace` is the primary label — the doctor's name when the
/// appointment names one, otherwise the clinic/venue. `place` (added by
/// the SMS-confirmation scope extension, 2026-09-07) carries the
/// clinic/venue separately when the source text names BOTH ("…appointment
/// with Dr Jane … at Xyz medical centre"), so the list row can show
/// "Dr Jane — Xyz medical centre" and the calendar entry can carry both.
/// An appointment typed by hand in the Medical tab puts whatever the
/// senior entered into `doctorOrPlace` and leaves `place` nil.
///
/// Persisted encrypted via `EncryptedLocalStorage` (Keychain, Data
/// Protection Complete — constitution §Security), exactly like
/// `FamilyContactStore`. `place` and `note` are optional and synthesized
/// Codable reads a missing key as nil — the unversioned store's one
/// migration pattern (an optional field IS its migration).
struct MedicalAppointment: Codable, Identifiable, Equatable {
    let id: UUID
    /// Doctor's name, or the clinic/venue when no doctor is named.
    var doctorOrPlace: String
    /// Clinic/venue when the source names it separately from the doctor;
    /// nil when the appointment only has one label.
    var place: String?
    /// When the appointment happens (date + time of day).
    var date: Date
    /// Optional free-form note ("bring the old reports").
    var note: String?

    init(id: UUID = UUID(), doctorOrPlace: String, place: String? = nil,
         date: Date, note: String? = nil) {
        self.id = id
        self.doctorOrPlace = doctorOrPlace
        self.place = place
        self.date = date
        self.note = note
    }
}

/// Seam for writing appointments into the native iPhone Calendar
/// (calendar-2way task, 2026-09-07 — the EventKit backend is built in a
/// parallel worktree against this protocol; this worktree ships the
/// no-op and the integrator swaps the real writer in).
///
/// Returns false when the write did not happen — the caller treats that
/// as "the native calendar was not touched" and does not error the user,
/// because the toggle only promises best effort: EventKit can fail
/// (permission denied, calendar unavailable) and the in-app list is
/// always the source of truth.
protocol MedicalAppointmentCalendarWriting {
    @discardableResult
    func write(appointment: MedicalAppointment) -> Bool

    @discardableResult
    func remove(appointment: MedicalAppointment) -> Bool
}

/// The shipped default writer: calendar sync is not implemented in this
/// worktree, so every write is a no-op — returns false and emits nothing
/// (no logging, no user-visible side effects). The integrator replaces
/// this with the EventKit-backed implementation of the calendar-2way
/// task; `AppointmentStore` calls the protocol, never this type by name.
final class NoopAppointmentCalendarWriter: MedicalAppointmentCalendarWriting {
    @discardableResult
    func write(appointment: MedicalAppointment) -> Bool { false }

    @discardableResult
    func remove(appointment: MedicalAppointment) -> Bool { false }
}

/// Persists the Medical tab's "Doctor's appointments" list
/// (medical task, 2026-09-07). House store pattern, mirroring
/// `FamilyContactStore`: model + store in one file, encrypted storage
/// key `medical.appointments`, newest-first ordering (the add form puts
/// the newest appointment at the top so the next visit is the first row).
final class AppointmentStore {

    /// Upper bound on stored appointments — generous enough for a
    /// busy year of check-ups, small enough that a stuck "paste"
    /// loop can never grow the encrypted payload unbounded.
    static let maxEntries = 50
    private static let storageKey = "medical.appointments"

    private let storage: EncryptedLocalStorage
    private let calendarWriter: MedicalAppointmentCalendarWriting

    /// Whether saved appointments are also handed to the native-calendar
    /// writer. Mirrors the Settings toggle `medical.calendarToggle`
    /// (coordinator key `appointmentsToCalendar`, default ON): the
    /// coordinator syncs this flag on launch AND on every toggle change.
    /// When false the writer is not invoked at all — neither for adds
    /// nor removes — so toggling off never silently deletes an entry the
    /// senior sees in the iPhone Calendar (the calendar-2way integration
    /// may later want removes ungated, with its own orphan-handling; out
    /// of scope here).
    var calendarWritesEnabled: Bool = true

    init(storage: EncryptedLocalStorage,
         calendarWriter: MedicalAppointmentCalendarWriting = NoopAppointmentCalendarWriter()) {
        self.storage = storage
        self.calendarWriter = calendarWriter
    }

    func load() -> [MedicalAppointment] {
        guard case .success(let appointments) = storage.read(
            key: Self.storageKey, type: [MedicalAppointment].self
        ) else { return [] }
        return appointments
    }

    @discardableResult
    func save(_ appointments: [MedicalAppointment]) -> Bool {
        switch storage.write(key: Self.storageKey, value: appointments) {
        case .success: return true
        case .failure: return false
        }
    }

    /// Inserts the appointment at the TOP of the list (newest first) and
    /// persists. When `calendarWritesEnabled` the appointment is ALSO
    /// handed to the native-calendar writer — but only after the
    /// encrypted save succeeded, so a failed save never ghosts a fake
    /// entry into the iPhone Calendar.
    @discardableResult
    func add(_ appointment: MedicalAppointment) -> Bool {
        var appointments = load()
        guard appointments.count < Self.maxEntries else { return false }
        appointments.insert(appointment, at: 0)
        guard save(appointments) else { return false }
        if calendarWritesEnabled {
            calendarWriter.write(appointment: appointment)
        }
        return true
    }

    /// Removes the appointment and persists; when
    /// `calendarWritesEnabled` the removal is also handed to the
    /// native-calendar writer (best effort — see the protocol doc).
    @discardableResult
    func remove(id: UUID) -> Bool {
        var appointments = load()
        guard let removed = appointments.first(where: { $0.id == id }) else { return false }
        appointments.removeAll { $0.id == id }
        guard save(appointments) else { return false }
        if calendarWritesEnabled {
            calendarWriter.remove(appointment: removed)
        }
        return true
    }
}
