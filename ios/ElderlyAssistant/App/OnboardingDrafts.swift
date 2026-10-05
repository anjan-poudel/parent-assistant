import Foundation

// MARK: - Wizard drafts (profile-interview, T-097)
//
// Pure, unit-testable merge helpers for the interview steps and the
// Settings editor. Both callers merge a draft into the CURRENT record and
// save the complete new record through the single coordinator writer, so
// the merge semantics live here once — the wizard's Next gate is the only
// difference between the two callers, never the merge itself.

struct ProfileEntryBounds: Equatable {
    var addressAsMaxGraphemes: Int = 24
    var nameMaxGraphemes: Int = 60
    static let `default` = ProfileEntryBounds()
}

/// The merge base for a wizard/editor draft. `.absent` and `.unreadable`
/// both merge into an EMPTY record (OB-2): nothing stored could be
/// preserved, and a save built on an empty base *repairs* the record
/// rather than failing — the ordinary Next-and-save is the repair path.
extension ProfileLoadResult {
    var mergeBase: UserProfile {
        if case .loaded(let profile) = self { return profile }
        return UserProfile(name: "", addressAs: "",
                           dateOfBirth: nil,
                           emergencyDoctor: nil, localHospital: nil)
    }
}

struct AboutYouDraft: Equatable {
    var name: String = ""
    var addressAs: String = ""
    var dateOfBirth: Date? = nil
    var hasDateOfBirth: Bool = false

    /// Trimmed non-empty name AND address-as (the Next gate, FR-PI-002) —
    /// single-sourced with `mandatoryFieldsRecorded(in:)` so the wizard
    /// button and the cold-start routing predicate can never disagree.
    var isComplete: Bool {
        AboutYouDraft.mandatoryFieldsRecorded(name: name, addressAs: addressAs)
    }

    /// The trimmed-non-empty predicate over a stored record (FR-PI-016's
    /// "mandatory fields recorded").
    static func mandatoryFieldsRecorded(in profile: UserProfile) -> Bool {
        mandatoryFieldsRecorded(name: profile.name, addressAs: profile.addressAs)
    }

    static func mandatoryFieldsRecorded(name: String, addressAs: String) -> Bool {
        !trimmed(name).isEmpty && !trimmed(addressAs).isEmpty
    }

    /// The single permitted normalisation (trim) applied to name and
    /// address-as; GP/hospital and any other record fields are preserved
    /// from `base` (FR-PI-010).
    ///
    /// DOB follows the draft in three cases: a held date with the toggle
    /// on records year/month/day components only (no calendar, no
    /// timezone); a held date with the toggle off clears the record (the
    /// user turned it off in front of a prefilled field); no held date at
    /// all (the field was never touched) preserves whatever `base` has —
    /// this is what keeps an About-you visit that skips the date from
    /// erasing a previously recorded birthday.
    func merged(into base: UserProfile) -> UserProfile {
        var merged = base
        merged.name = Self.trimmed(name)
        merged.addressAs = Self.trimmed(addressAs)
        if hasDateOfBirth, let dateOfBirth {
            let parts = Calendar.current.dateComponents([.year, .month, .day],
                                                        from: dateOfBirth)
            merged.dateOfBirth = DateComponents(year: parts.year,
                                                month: parts.month,
                                                day: parts.day)
        } else if dateOfBirth != nil {
            merged.dateOfBirth = nil
        }
        return merged
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EmergencyContactsDraft: Equatable {
    var emergencyDoctor: String = ""
    var localHospital: String = ""
    /// The kin selection is a family-contact flag write, not a profile
    /// field — it is carried here only as the step's selection state.
    var nextOfKinID: UUID? = nil

    /// Trims the two text fields; empty → nil; name/address-as/DOB
    /// preserved from `base`.
    func merged(into base: UserProfile) -> UserProfile {
        var merged = base
        merged.emergencyDoctor = Self.normalised(emergencyDoctor)
        merged.localHospital = Self.normalised(localHospital)
        return merged
    }

    private static func normalised(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
