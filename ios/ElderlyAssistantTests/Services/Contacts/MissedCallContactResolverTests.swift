import XCTest
@testable import ElderlyAssistant

/// The missed-call contact resolver (missed-calls fix, 2026-09-18;
/// link-aware, family-contacts-unify T-150, 2026-10-12): the pure
/// correlation between a missed call's captured NUMBER and the people the
/// app can honestly name — the family contacts FIRST (their phones are
/// stored RAW, so matching is normalized), then the VERIFIED system-contact
/// links (`VerifiedLinksSnapshot`), then the native address book
/// (`AddressBookEntry`s, permission-gated at the point of use). All pure —
/// no CNContact, no coordinator — the house seam pattern.
final class MissedCallContactResolverTests: XCTestCase {

    /// Stable ids for roster-order tests: the ROSTER position must decide,
    /// never the id or the record identifier.
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func familyContact(_ name: String, _ phone: String) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: "daughter")
    }

    /// A family contact carrying a STORED link (the model's claim). Whether
    /// that claim is a VERIFIED one is decided by the snapshot under test,
    /// never by this fixture — the resolver consults only the snapshot.
    private func linkedContact(id: UUID, name: String, phone: String,
                               identifier: String,
                               numberKey: String? = nil) -> FamilyContact {
        FamilyContact(id: id, name: name, phone: phone, relationship: "daughter",
                      systemContact: SystemContactLink(
                          identifier: identifier,
                          numberKey: numberKey ?? ContactNumberKey.normalized(phone)))
    }

    /// A published snapshot in which every given contact's stored link is
    /// VERIFIED and owns exactly the record numbers provided (the
    /// `linkedRecordNumbers` the T-149 pass publishes for the verified
    /// identifiers).
    private func verifiedSnapshot(
        _ entries: [(contact: FamilyContact, recordNumbers: [String])]
    ) -> VerifiedLinksSnapshot {
        var links: [UUID: SystemContactLink] = [:]
        var numbers: [String: [String]] = [:]
        for entry in entries {
            guard let link = entry.contact.systemContact else { continue }
            links[entry.contact.id] = link
            numbers[link.identifier] = entry.recordNumbers
        }
        return VerifiedLinksSnapshot(links: links,
                                     linkedRecordNumbers: numbers,
                                     generation: 1)
    }

    private func bookEntry(_ name: String, _ phone: String,
                           identifier: String = "") -> AddressBookEntry {
        AddressBookEntry(name: name, label: "mobile", phone: phone,
                         normalized: ContactNumberKey.normalized(phone),
                         identifier: identifier)
    }

    // MARK: - Normalization & matching

    /// Format variants are one number: dashes, spaces, parentheses and a
    /// `+` country-code prefix all normalize away.
    func testFormatVariantsAreOneNumber() {
        let variants = [
            "+977-9841 23 45 67",
            "(977) 9841234567",
            "9779841234567",
            "9841234567",
            "+977 9841-234-567",
        ]
        for lhs in variants {
            for rhs in variants {
                XCTAssertTrue(MissedCallContactResolver.matches(lhs, rhs),
                              "\(lhs) and \(rhs) are the same dialable number")
            }
        }
    }

    /// Trailing-digit comparison: the national 10-digit part matches even
    /// when one side carries a country code and the other does not.
    func testTrailingDigitsMatchAcrossCountryCode() {
        XCTAssertTrue(MissedCallContactResolver.matches("9841234567", "+9779841234567"))
        XCTAssertTrue(MissedCallContactResolver.matches("+91 98412 34567", "9841234567"))
    }

    /// Two different numbers never match, even with a shared prefix or
    /// suffix window.
    func testDifferentNumbersDoNotMatch() {
        XCTAssertFalse(MissedCallContactResolver.matches("9841234567", "9841234568"))
        XCTAssertFalse(MissedCallContactResolver.matches("9841234567", "9851234567"))
        XCTAssertFalse(MissedCallContactResolver.matches("9841234567", "9841"))
    }

    /// Empty or non-dialable spellings never match anything — an empty
    /// number must not be "the same number" as another empty one.
    func testEmptyAndNonDialableSpellingsNeverMatch() {
        XCTAssertFalse(MissedCallContactResolver.matches("", ""))
        XCTAssertFalse(MissedCallContactResolver.matches("", "9841234567"))
        XCTAssertFalse(MissedCallContactResolver.matches("abc", "9841234567"))
    }

    /// A short local extension (under 8 digits) compares exactly — it
    /// never suffix-matches a national number it is not.
    func testShortSpellingsCompareExactly() {
        XCTAssertTrue(MissedCallContactResolver.matches("12345", "12345"))
        XCTAssertFalse(MissedCallContactResolver.matches("12345", "98412345"))
    }

    // MARK: - Family correlation (first source)

    /// The family contact whose RAW phone is the same number matches —
    /// raw spellings included, since the editor stores them unnormalized.
    func testFamilyMatchFindsRawStoredSpelling() {
        let family = [
            familyContact("बुबा", "+977-9841 23 45 67"),
            familyContact("सीता", "9800000000"),
        ]
        let match = MissedCallContactResolver.familyMatch(phone: "9841234567", in: family)
        XCTAssertEqual(match?.name, "बुबा")
    }

    /// No family number matches → nil, whatever the native book holds
    /// (the native half is a separate source, consulted only by `resolve`).
    func testFamilyMatchNilWhenNoNumberMatches() {
        let family = [familyContact("सीता", "9800000000")]
        XCTAssertNil(MissedCallContactResolver.familyMatch(phone: "9841234567", in: family))
        XCTAssertNil(MissedCallContactResolver.familyMatch(phone: "", in: family))
    }

    // MARK: - Native correlation (second source)

    func testNativeMatchFindsBookEntryByTrailingDigits() {
        let entries = [bookEntry("Hari Sharma", "+977 9841 23 45 67")]
        let match = MissedCallContactResolver.nativeMatch(phone: "9841234567", in: entries)
        XCTAssertEqual(match?.name, "Hari Sharma")
    }

    func testNativeMatchNilWhenNoNumberMatches() {
        let entries = [bookEntry("Hari Sharma", "9811111111")]
        XCTAssertNil(MissedCallContactResolver.nativeMatch(phone: "9841234567", in: entries))
    }

    // MARK: - Resolution order & access states

    /// FAMILY WINS over the native book — the task's order — even when
    /// both hold the same number under different names.
    func testResolutionPrefersFamilyOverNative() {
        let family = [familyContact("बुबा", "9841234567")]
        let native = [bookEntry("Hari Sharma", "+977 9841234567")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native, access: .allowed)
        XCTAssertEqual(resolution, .name("बुबा"))
    }

    /// Family misses, native book hits — under `.allowed` the second
    /// source answers.
    func testResolutionFallsBackToNativeWhenFamilyMisses() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "+977 9841234567")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native, access: .allowed)
        XCTAssertEqual(resolution, .name("Hari Sharma"))
    }

    /// No match anywhere → `.unresolved`: the raw number stays the
    /// display — the honest answer, never a guessed name.
    func testResolutionUnresolvedWhenNothingMatches() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "9811111111")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native, access: .allowed)
        XCTAssertEqual(resolution, .unresolved)
    }

    /// `.notDetermined` → `.needsPermission`: the native book could
    /// answer but has never been asked — the caller is the point-of-use
    /// permission owner and may request, then re-resolve. The family
    /// half still answers first even with access undecided.
    func testResolutionNeedsPermissionWhenAccessUndetermined() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "9841234567")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native, access: .notDetermined)
        XCTAssertEqual(resolution, .needsPermission)

        let familyHit = MissedCallContactResolver.resolve(
            phone: "9800000000", family: family, native: native, access: .notDetermined)
        XCTAssertEqual(familyHit, .name("सीता"))
    }

    /// `.denied` is the honest denial: no native consultation, no
    /// nagging — the outcome is `.unresolved` (the raw number shows),
    /// never `.needsPermission` (which would re-trigger a prompt).
    func testResolutionUnresolvedWhenAccessDenied() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "9841234567")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native, access: .denied)
        XCTAssertEqual(resolution, .unresolved)
    }

    // MARK: - Verified-link correlation (the link-aware source, T-150)

    /// The acceptance scenario: a verified link between the record's number
    /// and "आमा" resolves a call from THAT number to आमा — even though her
    /// own stored phone in the family editor is a different number.
    func testLinkedFamilyMatchResolvesRecordNumberToFamilyContact() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let family = [aama, familyContact("सीता", "9811111111")]
        let snapshot = verifiedSnapshot([(aama, ["+977 9841 23 45 67"])])

        let match = MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: family, snapshot: snapshot)
        XCTAssertEqual(match?.id, aama.id)
        XCTAssertEqual(match?.name, "आमा")
    }

    /// The record's numbers go through the SAME trailing-digit rule as every
    /// other number path: a stored country-code spelling names the number
    /// the call captured without one.
    func testLinkedFamilyMatchUsesTrailingDigitRule() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["+977-9841 23 45 67"])])

        XCTAssertEqual(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [aama], snapshot: snapshot)?.id, aama.id)
        XCTAssertEqual(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9779841234567", in: [aama], snapshot: snapshot)?.id, aama.id)
        // A number the record does not carry never matches.
        XCTAssertNil(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234568", in: [aama], snapshot: snapshot))
    }

    /// A STORED link is only a claim (T-149 §1.3): with the snapshot empty
    /// (never verified, or a verification pass that dropped it) the
    /// contact's own `systemContact` proves nothing — today's behavior.
    func testLinkedFamilyMatchIgnoresStoredLinksAbsentFromTheSnapshot() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")

        XCTAssertNil(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [aama], snapshot: .empty))

        // Re-published after the record's number changed: the link verifies,
        // but the old number is no longer one the record carries — a stale
        // number must never resolve to आमा (FR-FCU-006).
        let republished = verifiedSnapshot([(aama, ["9811111111"])])
        XCTAssertNil(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [aama], snapshot: republished))
    }

    /// ROSTER ORDER decides when two verified links carry the same number
    /// (two relatives can share one landline): the roster-first contact
    /// wins even though the OTHER contact's record identifier sorts first —
    /// the user's order, not iOS's handle, is the source of truth.
    func testLinkedFamilyMatchFollowsRosterOrderNotIdentifierOrder() {
        let buba = linkedContact(id: idB, name: "बुबा", phone: "9700000000",
                                 identifier: "zzz-record")
        let sita = linkedContact(id: idA, name: "सीता", phone: "9600000000",
                                 identifier: "aaa-record")
        let snapshot = verifiedSnapshot([
            (buba, ["9841234567"]),
            (sita, ["+977 9841234567"]),
        ])

        for _ in 0..<5 {
            let match = MissedCallContactResolver.linkedFamilyMatch(
                phone: "9841234567", in: [buba, sita], snapshot: snapshot)
            XCTAssertEqual(match?.id, buba.id)
        }
        // Flipping the roster flips the claimant — the roster is what decides.
        XCTAssertEqual(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [sita, buba], snapshot: snapshot)?.id, sita.id)
    }

    /// Unlink/re-link churn: a snapshot published before a contact was
    /// removed still carries that contact's link, but resolution runs over
    /// the CURRENT roster — a departed contact is never named.
    func testLinkedFamilyMatchSkipsSnapshotLinksWithoutARosterContact() {
        let departed = linkedContact(id: idA, name: "पुरानो", phone: "9800000000",
                                     identifier: "rec-old")
        let snapshot = verifiedSnapshot([(departed, ["9841234567"])])
        let sita = familyContact("सीता", "9811111111")

        XCTAssertNil(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [sita], snapshot: snapshot))
    }

    // MARK: - resolve: link-aware precedence

    /// The task's main scenario through `resolve`: the linked record's
    /// number comes back as the family person.
    func testResolutionResolvesLinkedRecordNumberToFamilyName() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["+977 9841 23 45 67"])])
        let native = [bookEntry("Hari Sharma", "9841234567", identifier: "rec-hari")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: [aama], native: native,
            access: .allowed, snapshot: snapshot)
        XCTAssertEqual(resolution, .name("आमा"))
    }

    /// Source 1 outranks source 2: when the call is from a contact's OWN
    /// stored phone AND another contact's linked record carries it, the own
    /// phone wins — `familyMatch`'s primacy, independent of roster order.
    func testResolutionFamilyOwnPhoneWinsOverAnotherContactsLinkedRecord() {
        let buba = linkedContact(id: idB, name: "बुबा", phone: "9700000000",
                                 identifier: "rec-buba")
        let sita = familyContact("सीता", "9841234567")
        let snapshot = verifiedSnapshot([(buba, ["9841234567"])])

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: [buba, sita], native: [],
            access: .allowed, snapshot: snapshot)
        XCTAssertEqual(resolution, .name("सीता"))
    }

    /// The linked half outranks the native book: the book's spelling of the
    /// same person must not beat the family identity the user curated.
    func testResolutionPrefersLinkedFamilyOverNativeBookName() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["9841234567"])])
        let native = [bookEntry("Hari Sharma", "+977 9841234567", identifier: "rec-hari")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: [aama], native: native,
            access: .allowed, snapshot: snapshot)
        XCTAssertEqual(resolution, .name("आमा"))
    }

    // MARK: - resolve: native identifier remap

    /// The record gained a number after the last verification pass: the
    /// snapshot still VERIFIES the link, but its recorded numbers predate
    /// the new one — the native match by identifier must remap to the
    /// family person rather than show the book's name for the same human.
    func testResolutionRemapsVerifiedLinkedRecordToFamilyName() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["9800000000"])])
        let native = [bookEntry("Hari Sharma", "9841234567", identifier: "rec-aama")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: [aama], native: native,
            access: .allowed, snapshot: snapshot)
        XCTAssertEqual(resolution, .name("आमा"))
    }

    /// An entry whose identifier is NOT a verified link keeps the book name
    /// — the remap is evidence-based, never a guess by name.
    func testResolutionKeepsBookNameForUnlinkedIdentifier() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["9800000000"])])
        let native = [bookEntry("Hari Sharma", "9841234567", identifier: "rec-hari")]

        let resolution = MissedCallContactResolver.resolve(
            phone: "9841234567", family: [aama], native: native,
            access: .allowed, snapshot: snapshot)
        XCTAssertEqual(resolution, .name("Hari Sharma"))
    }

    /// An EMPTY identifier is "no linkable record", never a link target — on
    /// either side of the remap. Even a corrupt snapshot holding an
    /// empty-identifier link cannot claim a record-less row.
    func testResolutionNeverRemapsOnAnEmptyIdentifier() {
        let corrupt = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                    identifier: "")
        let snapshot = verifiedSnapshot([(corrupt, ["9841234567"])])
        let native = [bookEntry("Hari Sharma", "9841234567")]

        XCTAssertNil(MissedCallContactResolver.linkedFamilyMatch(
            phone: "9841234567", in: [corrupt], snapshot: snapshot))
        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9841234567", family: [corrupt], native: native,
            access: .allowed, snapshot: snapshot), .name("Hari Sharma"))
    }

    // MARK: - resolve: the .limited read arm

    /// `.limited` is a granted SUBSET — readable, so the native half is
    /// consulted exactly as under `.allowed`: a person outside the selection
    /// is an honest "no match", never a denial claim.
    func testResolutionConsultsNativeUnderLimitedAccess() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "9841234567")]

        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native,
            access: .limited), .name("Hari Sharma"))
        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9851234567", family: family, native: native,
            access: .limited), .unresolved)
        // Source 1 answers first under every access state.
        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9800000000", family: family, native: native,
            access: .limited), .name("सीता"))
    }

    /// The identifier remap belongs to the readable native half, so
    /// `.limited` gets it too — one identity under the granted subset.
    func testResolutionRemapsUnderLimitedAccess() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["9800000000"])])
        let native = [bookEntry("Hari Sharma", "9841234567", identifier: "rec-aama")]

        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9841234567", family: [aama], native: native,
            access: .limited, snapshot: snapshot), .name("आमा"))
    }

    // MARK: - resolve: denial and unlinked parity

    /// The failure-path scenario: contacts access denied and no verified
    /// links — the honest empty answer, no crash, no invented family name;
    /// source 1 is untouched by the denial.
    func testResolutionDeniedWithNoVerifiedLinksIsTheHonestEmptyResult() {
        let family = [familyContact("सीता", "9800000000")]
        let native = [bookEntry("Hari Sharma", "9841234567")]

        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: native,
            access: .denied, snapshot: .empty), .unresolved)
        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9800000000", family: family, native: native,
            access: .denied, snapshot: .empty), .name("सीता"))
    }

    /// Access can be revoked AFTER a link was verified. The snapshot is
    /// local, already-proven state and only the NATIVE half is access-gated
    /// (§1.8): T-149 keeps the last snapshot when access turns unreadable
    /// (stale serves), and no address-book read happens on this path — so
    /// the linked number still names the family person.
    func testLinkedResolutionDoesNotDependOnLiveAddressBookAccess() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let snapshot = verifiedSnapshot([(aama, ["9841234567"])])

        for access in [ContactsAccess.denied, .notDetermined, .limited] {
            XCTAssertEqual(MissedCallContactResolver.resolve(
                phone: "9841234567", family: [aama], native: [],
                access: access, snapshot: snapshot), .name("आमा"))
        }
    }

    /// UNLINKED PARITY (the no-regression gate): with the snapshot empty —
    /// the pre-feature world, and the default argument — every case returns
    /// exactly the pre-feature result, whether or not a contact carries an
    /// unverified STORED link.
    func testUnlinkedParityEmptySnapshotMatchesPreFeatureResults() {
        let sita = familyContact("सीता", "9800000000")
        // A stored-but-unverified link: the empty snapshot is the truth.
        let unverified = linkedContact(id: idA, name: "आमा", phone: "9700000000",
                                       identifier: "rec-aama")
        let family = [sita, unverified]
        let native = [bookEntry("Hari Sharma", "+977 9841234567")]

        func bothWays(_ phone: String, _ access: ContactsAccess)
            -> (defaulted: MissedCallContactResolver.NameResolution,
                explicit: MissedCallContactResolver.NameResolution) {
            (MissedCallContactResolver.resolve(phone: phone, family: family,
                                               native: native, access: access),
             MissedCallContactResolver.resolve(phone: phone, family: family,
                                               native: native, access: access,
                                               snapshot: .empty))
        }

        let familyHit = bothWays("9800000000", .allowed)
        XCTAssertEqual(familyHit.defaulted, .name("सीता"))
        XCTAssertEqual(familyHit.explicit, .name("सीता"))

        let nativeHit = bothWays("9841234567", .allowed)
        XCTAssertEqual(nativeHit.defaulted, .name("Hari Sharma"))
        XCTAssertEqual(nativeHit.explicit, .name("Hari Sharma"))

        let limitedHit = bothWays("9841234567", .limited)
        XCTAssertEqual(limitedHit.defaulted, .name("Hari Sharma"))
        XCTAssertEqual(limitedHit.explicit, .name("Hari Sharma"))

        let nothing = bothWays("9811111111", .allowed)
        XCTAssertEqual(nothing.defaulted, .unresolved)
        XCTAssertEqual(nothing.explicit, .unresolved)

        let undetermined = bothWays("9841234567", .notDetermined)
        XCTAssertEqual(undetermined.defaulted, .needsPermission)
        XCTAssertEqual(undetermined.explicit, .needsPermission)

        let denied = bothWays("9841234567", .denied)
        XCTAssertEqual(denied.defaulted, .unresolved)
        XCTAssertEqual(denied.explicit, .unresolved)

        // The "आमा" row's OWN phone is source 1 — answered under any access
        // state, exactly as before the link existed.
        XCTAssertEqual(MissedCallContactResolver.resolve(
            phone: "9700000000", family: family, native: native,
            access: .denied, snapshot: .empty), .name("आमा"))
    }

    // MARK: - resolve: one snapshot per resolution (drain safety)

    /// The drain/swap failure-path scenario: two claimants after unlink/
    /// re-link churn. Resolution answers from the ONE snapshot value it was
    /// handed — roster-first claimant, identical on every repeat — and a
    /// later publish changes the answer only for calls made WITH it. The
    /// resolver is a pure enum holding no state, so a torn read across two
    /// snapshots cannot happen.
    func testResolutionAnswersFromOneSnapshotDuringADrain() {
        let buba = linkedContact(id: idB, name: "बुबा", phone: "9700000000",
                                 identifier: "zzz-record")
        let sita = linkedContact(id: idA, name: "सीता", phone: "9600000000",
                                 identifier: "aaa-record")
        let family = [buba, sita]
        let midDrain = verifiedSnapshot([
            (buba, ["9841234567"]),
            (sita, ["9841234567"]),
        ])
        let afterSwap = verifiedSnapshot([(sita, ["9841234567"])])

        for _ in 0..<5 {
            XCTAssertEqual(MissedCallContactResolver.resolve(
                phone: "9841234567", family: family, native: [],
                access: .allowed, snapshot: midDrain), .name("बुबा"))
            XCTAssertEqual(MissedCallContactResolver.resolve(
                phone: "9841234567", family: family, native: [],
                access: .allowed, snapshot: afterSwap), .name("सीता"))
        }
    }

    /// ONE PERSON ON EVERY SURFACE (FR-FCU-004): the dial-back composition
    /// (`familyMatch` then `linkedFamilyMatch` — what T-158 wires into
    /// `AppCoordinator.familyContact(matchingPhone:)`) answers the same
    /// person the missed-call resolution does.
    func testMissedCallAndDialBackSurfacesAgreeOnTheLinkedPerson() {
        let aama = linkedContact(id: idA, name: "आमा", phone: "9800000000",
                                 identifier: "rec-aama")
        let family = [aama]
        let snapshot = verifiedSnapshot([(aama, ["9841234567"])])

        let missedCall = MissedCallContactResolver.resolve(
            phone: "9841234567", family: family, native: [],
            access: .allowed, snapshot: snapshot)

        let dialBack = MissedCallContactResolver.familyMatch(phone: "9841234567", in: family)
            ?? MissedCallContactResolver.linkedFamilyMatch(
                phone: "9841234567", in: family, snapshot: snapshot)

        XCTAssertEqual(missedCall, .name("आमा"))
        XCTAssertEqual(dialBack?.id, aama.id)
        XCTAssertEqual(dialBack?.name, "आमा")
    }
}
