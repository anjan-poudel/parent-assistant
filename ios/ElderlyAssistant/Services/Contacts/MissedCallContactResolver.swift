import Foundation

/// Correlates a missed call's NUMBER with the people the app can honestly
/// name (missed-calls fix, 2026-09-18; link-aware, family-contacts-unify
/// T-150, 2026-10-12).
///
/// Where the number comes from: the capture seam (`OpenedCallAttributor`,
/// wired in `AppCoordinator.recordUnansweredCall`) — the app itself dialed
/// the number and iOS's anonymous ended-unconnected event is that dial's
/// outcome. The app records the number AT THE SOURCE, and this resolver is
/// the read side: given the raw number, who is it?
///
/// Correlation sources, in order (the task's contract; source 2 added by
/// T-150, design-l2 §1.8):
///  1. the app's OWN family contacts (`FamilyContactStore`) — note their
///     phones are stored RAW ("+977-9841 23 45 67", "(977) 9841234567"),
///     so matching is normalized, never string equality;
///  2. the VERIFIED system-contact links (`VerifiedLinksSnapshot`, T-149) —
///     a call from a linked record's number IS the linked family person
///     (FR-FCU-004: one person on the missed-call row and the dial-back
///     surface). Only the snapshot is consulted; an unverified or stale
///     stored link is ABSENT from it and so degrades to the unlinked path
///     exactly (FR-FCU-006);
///  3. the NATIVE iOS address book (CNContact via `AddressBookDirectory`) —
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

    /// The family contact whose VERIFIED linked record carries this number,
    /// or nil — the link-aware half of number reach (T-150, design-l2 §1.8,
    /// FR-FCU-004). Callers run it AFTER `familyMatch`: a contact whose own
    /// phone matches has already won.
    ///
    /// ROSTER ORDER decides: the first contact in the editor's order whose
    /// verified link's record numbers match wins, so the answer is
    /// deterministic even when two linked relatives share one landline. (The
    /// snapshot's own `familyID(matchingRecordNumber:)` orders by record
    /// identifier, an artifact of iOS's handles — deliberately not used
    /// here, because the user-visible order is the roster's.)
    ///
    /// Only the snapshot is consulted — never `contact.systemContact`, never
    /// the address book. The snapshot holds PROVEN links only (T-149 §1.3),
    /// so a stale claim (record deleted, number changed, unreadable access
    /// at verification) is simply absent and the number falls through to the
    /// unlinked path — today's behavior exactly (FR-FCU-006). A snapshot
    /// link whose contact has left the roster is never returned either: the
    /// roster is what is iterated.
    static func linkedFamilyMatch(phone: String,
                                  in contacts: [FamilyContact],
                                  snapshot: VerifiedLinksSnapshot) -> FamilyContact? {
        for contact in contacts {
            guard let link = snapshot.links[contact.id],
                  // The model-level contract, re-checked where it is USED —
                  // the same rule the T-149 pass applies: an empty identifier
                  // is "no linkable record", never a link target, so even a
                  // corrupt hand-built snapshot cannot invent one.
                  !link.identifier.isEmpty,
                  let numbers = snapshot.linkedRecordNumbers[link.identifier]
            else { continue }
            if numbers.contains(where: { matches(phone, $0) }) { return contact }
        }
        return nil
    }

    /// The native-address-book entry whose number is the same dialable
    /// number, or nil — the THIRD correlation source, after the family's own
    /// phones and the verified links (CNContact records, pre-mapped to plain
    /// `AddressBookEntry`s by `AddressBookDirectory`).
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
    /// family first, then the verified links, then the native book — under
    /// the CURRENT Contacts access state.
    ///
    /// Precedence (T-150, design-l2 §1.8, FR-FCU-004):
    ///  1. `familyMatch`: the family editor's own phones. The app's curated
    ///     people win over every other source.
    ///  2. `linkedFamilyMatch`: a number carried by a VERIFIED linked record
    ///     resolves to the linked FAMILY person, so the missed-call row and
    ///     the dial-back surface show one identity for one human. This half
    ///     reads LOCAL verified state only — no address-book read happens
    ///     here, so a denial cannot erase a link that was verified while
    ///     access was readable (T-149 keeps the last snapshot on unreadable
    ///     access: stale serves). Losing that name would be the regression.
    ///  3. the native address book, consulted only when
    ///     `access.allowsReading`: a matched entry whose `identifier` is a
    ///     verified link remaps to that family contact's name (the record IS
    ///     that person; the snapshot's recorded numbers can lag a number the
    ///     record gained after the last verification pass), and any other
    ///     match resolves to the book name.
    ///
    /// `snapshot` defaults to `.empty`, i.e. today's unlinked behavior
    /// exactly: an unverified or stale stored link never appears in a
    /// snapshot, so it cannot change a resolution (FR-FCU-006). One call
    /// reads ONE snapshot value — the whole resolution is consistent even
    /// while a verification drain publishes a newer one.
    ///
    /// - `.allowed`/`.limited`: the native entries may be consulted; a
    ///   match there resolves to its name, and no match anywhere resolves
    ///   honestly (`.unresolved`, raw number shows). `.limited` (iOS 18
    ///   "Select Contacts") is a granted SUBSET — readable, so consulted
    ///   the same way; a person outside the selection simply never
    ///   matches (an honest "no match", never a denial claim).
    /// - `.notDetermined`: the native book has not been asked yet, so the
    ///   native half cannot be consulted — `.needsPermission` names that
    ///   gap instead of pretending the number matched nobody.
    /// - `.denied`/`.restricted`: the honest denial — the raw number
    ///   remains the display, no prompt, no nagging.
    static func resolve(phone: String,
                        family: [FamilyContact],
                        native: [AddressBookEntry],
                        access: ContactsAccess,
                        snapshot: VerifiedLinksSnapshot = .empty) -> NameResolution {
        if let contact = familyMatch(phone: phone, in: family) {
            return .name(contact.name)
        }
        if let contact = linkedFamilyMatch(phone: phone, in: family, snapshot: snapshot) {
            return .name(contact.name)
        }
        guard access.allowsReading else {
            // `.notDetermined` names the gap (the caller may prompt and
            // re-resolve); every other non-readable state is the honest
            // denial — the raw number stays the display.
            return access == .notDetermined ? .needsPermission : .unresolved
        }
        if let entry = nativeMatch(phone: phone, in: native) {
            // A match whose record is a VERIFIED link is that family person:
            // the two surfaces must show one identity, so the family name
            // wins over the book's (roster order decides a tie).
            if !entry.identifier.isEmpty,
               let linked = family.first(where: {
                   snapshot.links[$0.id]?.identifier == entry.identifier
               }) {
                return .name(linked.name)
            }
            return .name(entry.name)
        }
        return .unresolved
    }
}
