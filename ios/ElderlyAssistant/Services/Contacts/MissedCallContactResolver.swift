import Foundation

/// Correlates a missed call's NUMBER with the people the app can honestly
/// name (missed-calls fix, 2026-09-18).
///
/// Where the number comes from: the capture seam (`OpenedCallAttributor`,
/// wired in `AppCoordinator.recordUnansweredCall`) — the app itself dialed
/// the number and iOS's anonymous ended-unconnected event is that dial's
/// outcome. The app records the number AT THE SOURCE, and this resolver is
/// the read side: given the raw number, who is it?
///
/// Correlation sources, in order (the task's contract):
///  1. the app's OWN family contacts (`FamilyContactStore`) — note their
///     phones are stored RAW ("+977-9841 23 45 67", "(977) 9841234567"),
///     so matching is normalized, never string equality;
///  2. the NATIVE iOS address book (CNContact via `AddressBookDirectory`) —
///     permission-gated at the point of use: `resolve` takes the CURRENT
///     `ContactsAccess` and reports `.needsPermission` rather than
///     guessing, and a denial resolves to `.unresolved` (the raw number
///     stays the display — the honest denial handling).
///
/// Pure and Foundation-only, like its sibling `SystemContactSearch`: the
/// platform glue (CNContactStore) lives in `AddressBookDirectory` and the
/// coordinator, never here, so the whole matrix is unit-testable.
enum MissedCallContactResolver {

    // MARK: - Number normalization

    /// ASCII digits of a phone number — the only characters a dialable
    /// number is ever built from (the same vocabulary as
    /// `ContactNumberKey`; Devanagari numerals do NOT dial).
    static func digits(_ raw: String) -> String {
        raw.filter { $0.isASCII && $0.isNumber }
    }

    /// Do two spellings name the same dialable number? Strips spaces,
    /// dashes, parentheses and any prefix country code, then compares the
    /// trailing 8–10 digits (the national part): "+977-9841 23 45 67",
    /// "(977) 9841234567" and "9841234567" are ONE number. Two sides that
    /// are both 8+ digits long compare by their shared trailing length
    /// (10 when both are that long, else the shorter side's length down to
    /// 8); shorter spellings compare exactly, digit-for-digit — a 7-digit
    /// local extension never suffix-matches a national number it is not.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = digits(lhs)
        let right = digits(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let floorLength = 8
        guard left.count >= floorLength, right.count >= floorLength else { return false }
        let keep = min(10, min(left.count, right.count))
        return left.suffix(keep) == right.suffix(keep)
    }

    // MARK: - Correlation

    /// The family contact whose RAW stored phone is the same dialable
    /// number, or nil. Family contacts are the FIRST correlation source:
    /// they are the app's own curated people, and their number is what a
    /// dial-back should prefer the family editor's spellings over.
    static func familyMatch(phone: String, in contacts: [FamilyContact]) -> FamilyContact? {
        contacts.first { matches($0.phone, phone) }
    }

    /// The native-address-book entry whose number is the same dialable
    /// number, or nil — the SECOND correlation source (CNContact records,
    /// pre-mapped to plain `AddressBookEntry`s by `AddressBookDirectory`).
    static func nativeMatch(phone: String, in entries: [AddressBookEntry]) -> AddressBookEntry? {
        entries.first { matches($0.phone, phone) }
    }

    // MARK: - Resolution

    /// The outcome of correlating a missed call's number.
    enum NameResolution: Equatable {
        /// The number matched a saved contact — display this name.
        case name(String)
        /// The number is known but matches nobody (or access was denied
        /// honestly) — display the raw number.
        case unresolved
        /// The native book could answer but Contacts access has never been
        /// decided — the caller is the point-of-use permission owner: it
        /// may request access (with the system prompt as the explanation)
        /// and re-resolve, or leave the raw number showing.
        case needsPermission
    }

    /// Resolves the number against the correlation sources IN ORDER —
    /// family first, then the native book — under the CURRENT Contacts
    /// access state.
    ///
    /// - `.allowed`: the native entries may be consulted; a match there
    ///   resolves to its name, and no match anywhere resolves honestly
    ///   (`.unresolved`, raw number shows).
    /// - `.notDetermined`: the native book has not been asked yet, so the
    ///   native half cannot be consulted — `.needsPermission` names that
    ///   gap instead of pretending the number matched nobody.
    /// - `.denied`/`.restricted`: the honest denial — the raw number
    ///   remains the display, no prompt, no nagging.
    static func resolve(phone: String,
                        family: [FamilyContact],
                        native: [AddressBookEntry],
                        access: ContactsAccess) -> NameResolution {
        if let contact = familyMatch(phone: phone, in: family) {
            return .name(contact.name)
        }
        switch access {
        case .allowed:
            if let entry = nativeMatch(phone: phone, in: native) {
                return .name(entry.name)
            }
            return .unresolved
        case .notDetermined:
            return .needsPermission
        case .denied:
            return .unresolved
        }
    }
}
