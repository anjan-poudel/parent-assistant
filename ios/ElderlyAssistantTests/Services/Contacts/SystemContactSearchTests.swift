import XCTest
@testable import ElderlyAssistant

/// Unit tests for the Phone leaf's system-contacts search (task
/// 2026-09-06: "sweep all sweepable contacts when searching, maybe sort
/// by the most recently used"). The pure logic — number keys, CNContact
/// → row mapping, matching, recency ranking, and the recency store — is
/// tested here; the `CNContactStore` glue in `AddressBookDirectory` is
/// deliberately untestable (CNContact is not constructible) and stays
/// one-liners over these seams.

final class ContactNumberKeyTests: XCTestCase {

    func testNormalizedKeepsOnlyASCIIDigits() {
        XCTAssertEqual(ContactNumberKey.normalized("+977-9841 23 45 67 (mobile)"),
                       "9779841234567")
        XCTAssertEqual(ContactNumberKey.normalized("(977) 9841234567"),
                       "9779841234567")
    }

    func testNormalizedRejectsDevanagariNumerals() {
        // Devanagari digits can never be dialed in a tel: URL, so a
        // number written with them must not key-match an ASCII one.
        XCTAssertEqual(ContactNumberKey.normalized("९८४१"), "")
        XCTAssertEqual(ContactNumberKey.normalized(""), "")
    }
}

final class AddressBookEntryTests: XCTestCase {

    func testNameJoinsGivenAndFamily() {
        let entry = AddressBookEntry.make(givenName: "सीता",
                                          familyName: "शर्मा",
                                          organizationName: "",
                                          numbers: [("mobile", "+977 9841 23 45 67")])
        XCTAssertEqual(entry?.name, "सीता शर्मा")
        XCTAssertEqual(entry?.phone, "+977 9841 23 45 67")
        XCTAssertEqual(entry?.normalized, "9779841234567")
        XCTAssertEqual(entry?.caption, "mobile +977 9841 23 45 67")
    }

    func testCompanyContactUsesOrganizationName() {
        let entry = AddressBookEntry.make(givenName: "",
                                          familyName: "",
                                          organizationName: "पाटन अस्पताल",
                                          numbers: [("", "014523456")])
        XCTAssertEqual(entry?.name, "पाटन अस्पताल")
    }

    func testUnnamedContactFallsBackToPhoneAsName() {
        // Contacts.app itself shows the number when a record has no name.
        let entry = AddressBookEntry.make(givenName: "",
                                          familyName: "",
                                          organizationName: "",
                                          numbers: [("", "9841000000")])
        XCTAssertEqual(entry?.name, "9841000000")
    }

    func testFirstDialableNumberWins() {
        let entry = AddressBookEntry.make(givenName: "Ram",
                                          familyName: "Thapa",
                                          organizationName: "",
                                          numbers: [("home", "01-4 4 4 5 5 5 5"),
                                                    ("mobile", "+977 9841 0000 000")])
        XCTAssertEqual(entry?.phone, "01-4 4 4 5 5 5 5")
        XCTAssertEqual(entry?.normalized, "014445555")
    }

    func testNonDialableFirstNumberIsSkippedForDialableSecond() {
        // A "number" that normalizes to no ASCII digits can't be dialed —
        // the mapping must skip it and take the next, not show a row
        // whose button could only fail.
        let entry = AddressBookEntry.make(givenName: "Hari",
                                          familyName: "",
                                          organizationName: "",
                                          numbers: [("", "९८४१"),
                                                    ("mobile", "9841000000")])
        XCTAssertEqual(entry?.phone, "9841000000")
    }

    func testNoDialableNumberYieldsNil() {
        let entry = AddressBookEntry.make(givenName: "Nobody",
                                          familyName: "",
                                          organizationName: "",
                                          numbers: [("", ""), ("", "९८४१")])
        XCTAssertNil(entry)
        XCTAssertNil(AddressBookEntry.make(givenName: "Empty",
                                           familyName: "",
                                           organizationName: "",
                                           numbers: []))
    }
}

final class SystemContactSearchTests: XCTestCase {

    private let sita = AddressBookEntry(name: "सीता शर्मा", label: "mobile",
                                        phone: "+977 9841 000001",
                                        normalized: "9779841000001")
    private let ram = AddressBookEntry(name: "Ram Thapa", label: "mobile",
                                       phone: "+977 9841 000002",
                                       normalized: "9779841000002")
    private let clinic = AddressBookEntry(name: "पाटन अस्पताल", label: "main",
                                          phone: "01-4445555",
                                          normalized: "014445555")
    private let sunita = AddressBookEntry(name: "Sunita Aacharya", label: "home",
                                          phone: "015552222",
                                          normalized: "015552222")

    private func make(_ name: String, phone: String = "9841000000") -> AddressBookEntry {
        AddressBookEntry(name: name, label: "mobile", phone: phone,
                         normalized: ContactNumberKey.normalized(phone))
    }

    func testEmptyOrWhitespaceQueryMatchesNothing() {
        XCTAssertTrue(SystemContactSearch.matches(query: "", in: [sita, ram]).isEmpty)
        XCTAssertTrue(SystemContactSearch.matches(query: "   ", in: [sita, ram]).isEmpty)
    }

    func testNameSubstringMatchIsCaseInsensitive() {
        XCTAssertEqual(SystemContactSearch.matches(query: "ram", in: [sita, ram]), [ram])
        XCTAssertEqual(SystemContactSearch.matches(query: "RAM", in: [sita, ram]), [ram])
    }

    func testDevanagariNameMatch() {
        XCTAssertEqual(SystemContactSearch.matches(query: "सीता", in: [sita, ram]), [sita])
        XCTAssertEqual(SystemContactSearch.matches(query: "शर्मा", in: [sita, ram]), [sita])
    }

    func testQueryMatchingNoOneYieldsNothing() {
        XCTAssertTrue(SystemContactSearch.matches(query: "विदेश", in: [sita, ram]).isEmpty)
    }

    func testDigitQueryMatchesTheRowsOwnDialableNumber() {
        // Query digits match only the number the row would actually
        // dial — never a second number that isn't surfaced.
        XCTAssertEqual(SystemContactSearch.matches(query: "9841 000001",
                                                   in: [sita, ram, clinic]), [sita])
        XCTAssertEqual(SystemContactSearch.matches(query: "01-4445555",
                                                   in: [sita, ram, clinic]), [clinic])
    }

    func testQueryLeadingPlusNormalizesWithNumber() {
        XCTAssertEqual(SystemContactSearch.matches(query: "+977 9841 000002",
                                                   in: [sita, ram]), [ram])
    }

    func testRankPutsRecentlyCalledNumbersFirst() {
        let now = Date()
        let recency = [ram.normalized: now, sita.normalized: now.addingTimeInterval(-3600)]
        // sita called an hour ago, ram just now — but sita < ram
        // alphabetically (Devanagari sorts before Latin), so a pure
        // alphabetical order is inverted; recency must win.
        XCTAssertEqual(SystemContactSearch.rank([sita, ram], by: recency), [ram, sita])
    }

    func testRankFallsBackToAlphabeticalForNeverCalledOrTies() {
        // Never called → plain alphabetical order (single script, so
        // localizedStandardCompare is deterministic here).
        XCTAssertEqual(SystemContactSearch.rank([sunita, ram], by: [:]), [ram, sunita])
        XCTAssertEqual(SystemContactSearch.rank([clinic, sita], by: [:]), [clinic, sita])
        // Equal recency dates → alphabetical tiebreak.
        let now = Date()
        let tied = [ram.normalized: now, sunita.normalized: now]
        XCTAssertEqual(SystemContactSearch.rank([sunita, ram], by: tied), [ram, sunita])
    }

    func testSearchRanksThenCapsAndReportsTruncation() {
        var book: [AddressBookEntry] = []
        for i in 0..<25 {
            // Each person gets a distinct number — recency is keyed by
            // number, so a shared fixture number would make the rank
            // treat everyone as equally recent.
            book.append(make(String(format: "Person %02d", i),
                             phone: String(format: "9841%05d", i)))
        }
        let recency = [book[24].normalized: Date()]
        let outcome = SystemContactSearch.search(query: "Person",
                                                 in: book,
                                                 recency: recency,
                                                 limit: 5)
        XCTAssertEqual(outcome.entries.count, 5)
        // The most recently called person surfaces despite sitting at
        // the alphabetical end — ranking happens BEFORE the cap.
        XCTAssertEqual(outcome.entries.first, book[24])
        XCTAssertTrue(outcome.moreAvailable)
    }

    func testSearchWithoutTruncation() {
        let outcome = SystemContactSearch.search(query: "Sunita", in: [sita, sunita])
        XCTAssertEqual(outcome.entries, [sunita])
        XCTAssertFalse(outcome.moreAvailable)
    }
}

final class CallRecencyStoreTests: XCTestCase {

    func testRecordAndLookupNormalizeTheNumber() {
        let store = CallRecencyStore(storage: StubEncryptedStorage())
        let now = Date()
        store.record(phone: "+977-9841 23 45 67", at: now)
        XCTAssertEqual(store.lastCalled(phone: "(977) 9841234567"), now)
    }

    func testLastCallWinsOnRepeatedRecord() {
        let store = CallRecencyStore(storage: StubEncryptedStorage())
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        store.record(phone: "9841000000", at: earlier)
        store.record(phone: "9841 000 000", at: later)
        XCTAssertEqual(store.lastCalled(phone: "9841000000"), later)
    }

    func testUnDialableNumberIsNotRecorded() {
        let store = CallRecencyStore(storage: StubEncryptedStorage())
        store.record(phone: "९८४१")
        store.record(phone: "")
        XCTAssertNil(store.lastCalled(phone: "९८४१"))
        XCTAssertTrue(store.recentCalls().isEmpty)
    }

    func testRecentCallsCapsAndPrunesOldest() {
        let store = CallRecencyStore(storage: StubEncryptedStorage())
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(CallRecencyStore.maxNumbers + 5) {
            store.record(phone: String(format: "9841%04d", i), at: base.addingTimeInterval(Double(i)))
        }
        let all = store.recentCalls()
        XCTAssertEqual(all.count, CallRecencyStore.maxNumbers)
        // Numbers 0-4 are the oldest — pruned.
        XCTAssertNil(all["98410000"])
        XCTAssertNil(all["98410004"])
        // The newest survive.
        XCTAssertNotNil(all["98410104"])
        XCTAssertNotNil(store.lastCalled(phone: "9841 0104"))
    }

    func testEmptyStoreReportsNoRecency() {
        let store = CallRecencyStore(storage: StubEncryptedStorage())
        XCTAssertTrue(store.recentCalls().isEmpty)
        XCTAssertNil(store.lastCalled(phone: "9841000000"))
    }
}
