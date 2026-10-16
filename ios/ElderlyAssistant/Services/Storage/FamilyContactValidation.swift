import Foundation

// MARK: - Family contact draft validation (calendar & family sharing, 2026-09-16)

/// The save-gate rules for a family contact, as a PURE function — the
/// editor's `canSave` reads it, so "Save is dead until the emergency
/// contact has an email" is unit-tested without instantiating a View
/// (same split as `CalendarSyncService`'s planners: the decision lives
/// outside the SwiftUI shell).
///
/// Exactly one rule exists today, and it is asymmetric on purpose:
///
///  - `email` is OPTIONAL for an ordinary contact (the family may not
///    know the address yet, and an address-less contact simply receives
///    no calendar invitation — see `CalendarShareMapper`);
///  - `email` is MANDATORY for an emergency contact, because the invite
///    policy makes emergency contacts attendees of EVERY shared event
///    (user decision 2). An emergency contact with no address is a
///    silent hole in the family's safety net, so the editor refuses to
///    save one rather than discovering it at invite time.
///
/// The well-formedness check is deliberately simple (one `@`, a dot in
/// the domain, no whitespace) — the design's open risks record that
/// undeliverable-but-well-formed addresses surface as a failed operation
/// in Settings rather than being pre-validated (design §10). Do NOT
/// grow this into an RFC 5322 validator: it gates a Save button, it is
/// not an email server.
enum FamilyContactValidation {

    /// Why a contact draft cannot be saved. One case per user-facing
    /// hint, so the editor maps straight to a localized caption.
    enum Issue: Equatable {
        /// Emergency contact with a blank address field.
        case emailRequired
        /// Emergency contact with something typed that is not an
        /// address — distinct from blank so the hint can be specific
        /// (asking for "an email" when they typed one is the kind of
        /// lie that makes an elder distrust the whole screen).
        case emailInvalid
    }

    /// The blocking issue for a draft, or nil when it may be saved.
    ///
    /// Only the emergency rule can block today: the name/phone/
    /// relationship trio is enforced by the wizard's own step gates
    /// (`hasNameAndPhone` + `relationshipOption`), which stay where they
    /// are because they gate NAVIGATION between steps, not the save.
    static func issue(email: String, isEmergencyContact: Bool) -> Issue? {
        guard isEmergencyContact else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emailRequired }
        return isWellFormedAddress(trimmed) ? nil : .emailInvalid
    }

    /// Simplified address shape: a non-empty local part, exactly one
    /// `@`, and a domain carrying at least one dot with non-empty labels
    /// on both sides. Whitespace anywhere fails. Case is irrelevant
    /// (addresses are matched case-insensitively) and is not checked.
    static func isWellFormedAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              !address.contains(where: { $0.isWhitespace }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { !$0.isEmpty }
    }

    /// The stored form of a typed address: trimmed, and nil when blank or
    /// ABSENT — the same "blank means unset" rule the nickname and
    /// address fields use, so an empty field never persists an empty
    /// string that invite logic would then have to special-case.
    ///
    /// The parameter is optional because that is how the address arrives
    /// from both sides: a `@State` editor field is a non-optional
    /// `String`, while `addFamilyContact`/`updateFamilyContact` take
    /// `String?` (their callers predate the field and omit it). Nil in
    /// means nil out — there is nothing to normalize and nothing to
    /// store, so the two spellings of "no address" agree by construction
    /// rather than at each call site.
    static func normalizedEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
