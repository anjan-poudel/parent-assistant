import XCTest
@testable import ElderlyAssistant

/// The missed-call contact resolver (missed-calls fix, 2026-09-18): the
/// pure correlation between a missed call's captured NUMBER and the people
/// the app can honestly name — the family contacts FIRST (their phones are
/// stored RAW, so matching is normalized), then the native address book
/// (`AddressBookEntry`s, permission-gated at the point of use). All pure —
/// no CNContact, no coordinator — the house seam pattern.
final class MissedCallContactResolverTests: XCTestCase {

    private func familyContact(_ name: String, _ phone: String) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: "daughter")
    }

    private func bookEntry(_ name: String, _ phone: String) -> AddressBookEntry {
        AddressBookEntry(name: name, label: "mobile", phone: phone,
                         normalized: ContactNumberKey.normalized(phone))
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
}
