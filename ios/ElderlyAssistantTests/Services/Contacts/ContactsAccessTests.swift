import Contacts
import XCTest
@testable import ElderlyAssistant

/// `ContactsAccess` — the app-facing contacts authorization state and the
/// `.limited` mapping (family-contacts-unify T-148a; design-l2 §3.5).
///
/// Pins the two claims the T-148 split assigns to this unit:
///
///  1. the pure mapping is total and honest — `from(_:)` maps every known
///     `CNAuthorizationStatus` (iOS 18's `.limited` included) and
///     `allowsReading` is true for exactly the readable states. The
///     `@unknown default` arm fails closed to `.denied`; it is not
///     exercisable from a test (Swift cannot construct an unknown
///     `CNAuthorizationStatus`), so it stays a compile-enforced rule;
///  2. the SINGLE-GATE claim — the `#available(iOS 18.0, *)` check that
///     lets `.limited` be named exists EXACTLY ONCE in the module. A
///     second copy anywhere under `ElderlyAssistant/` fails the scan,
///     which is the pin that keeps the version gate from drifting into
///     other files (the design's "no other site re-implements the
///     iOS-version gate" scenario).
///
/// The `.limited` identifier-plumbing pins (`AddressBookEntry.identifier`
/// / `make(..., identifier:)`, §3.5) live here too: this unit adds the
/// plumbing, and this is the unit's suite.
final class ContactsAccessTests: XCTestCase {

    // MARK: - Pure mapping (`from(_:)`)

    /// `.authorized` is full access.
    func testAuthorizedMapsToAllowed() {
        XCTAssertEqual(ContactsAccess.from(.authorized), .allowed)
    }

    /// Denial and restriction share the one blocked state: for both, the
    /// only forward path is the system Settings screen, so the UI copy is
    /// the same (the enum's documented rule).
    func testDeniedAndRestrictedMapToDenied() {
        XCTAssertEqual(ContactsAccess.from(.denied), .denied)
        XCTAssertEqual(ContactsAccess.from(.restricted), .denied)
    }

    /// `.notDetermined` stays distinct: the point-of-use owner may still
    /// ask, so it must never collapse into denial.
    func testNotDeterminedMapsToNotDetermined() {
        XCTAssertEqual(ContactsAccess.from(.notDetermined), .notDetermined)
    }

    /// iOS 18's "Select Contacts" maps to its OWN state — not collapsed
    /// into `.allowed` (which would claim the whole book is visible) and
    /// not into `.denied` (which would tell a granted user they granted
    /// nothing).
    func testLimitedMapsToLimited() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("CNAuthorizationStatus.limited is iOS 18+")
        }
        XCTAssertEqual(ContactsAccess.from(.limited), .limited)
    }

    // MARK: - `allowsReading` (the readable states)

    /// Exactly `.allowed` and `.limited` allow reading: a limited
    /// selection is a granted SUBSET — its records enumerate — while
    /// `.denied` and `.notDetermined` never read.
    func testAllowsReadingIsTrueForAllowedAndLimitedOnly() {
        XCTAssertTrue(ContactsAccess.allowed.allowsReading)
        XCTAssertTrue(ContactsAccess.limited.allowsReading)
        XCTAssertFalse(ContactsAccess.denied.allowsReading)
        XCTAssertFalse(ContactsAccess.notDetermined.allowsReading)
    }

    /// The mapping and the readable-states rule agree end to end: every
    /// status `from(_:)` maps to a readable state is exactly an
    /// authorized-or-limited one, and everything else does not read.
    func testMappingAndAllowsReadingAgree() throws {
        XCTAssertTrue(ContactsAccess.from(.authorized).allowsReading)
        XCTAssertFalse(ContactsAccess.from(.denied).allowsReading)
        XCTAssertFalse(ContactsAccess.from(.restricted).allowsReading)
        XCTAssertFalse(ContactsAccess.from(.notDetermined).allowsReading)
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("CNAuthorizationStatus.limited is iOS 18+")
        }
        XCTAssertTrue(ContactsAccess.from(.limited).allowsReading)
    }

    // MARK: - The single iOS-18 gate

    /// The token a real availability gate carries. Deliberately WITHOUT
    /// the leading `#`: a declaration-level `@available(iOS 18…)` is the
    /// same version re-check, so the scan must catch both spellings.
    private static let availabilityGateMarker = "available(iOS 18"

    /// Every line in the module carrying an iOS-18 availability gate, as
    /// `(file, 1-based line, line text)`. `FeatureSourceScan.codeText`
    /// strips comments (and keeps string literals), so only real gates
    /// count, and the line text preserved for the identifying assertion.
    private func ios18AvailabilitySites() -> [(file: String, line: Int, text: String)] {
        var sites: [(file: String, line: Int, text: String)] = []
        for url in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant") {
            let text = FeatureSourceScan.codeText(of: url)
            let file = FeatureSourceScan.relativePath(of: url)
            for (offset, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            where line.contains(Self.availabilityGateMarker) {
                sites.append((file, offset + 1, String(line)))
            }
        }
        return sites
    }

    /// The single-gate claim: `.limited` sits behind ONE version check.
    /// This test fails the moment a second gate appears anywhere in the
    /// module — the drift the design's "no other site re-implements the
    /// iOS-version gate" scenario forbids.
    func testTheIOS18AvailabilityGateAppearsExactlyOnceInTheModule() {
        let sites = ios18AvailabilitySites()
        let reported = sites.map { "\($0.file):\($0.line)" }.joined(separator: ", ")
        XCTAssertEqual(sites.count, 1,
                       "expected exactly one iOS-18 availability gate in the module; "
                       + "found \(sites.count): \(reported)")
    }

    /// …and that one gate IS the `.limited` mapping: it lives in
    /// `AddressBookDirectory.swift` and compares the status against
    /// `.limited`. A single gate somewhere else — or one that maps
    /// something else — means the mapping was re-implemented outside the
    /// single seam.
    func testTheSingleGateIsTheLimitedMappingInAddressBookDirectory() {
        let sites = ios18AvailabilitySites()
        XCTAssertEqual(sites.count, 1,
                       "precondition — see testTheIOS18AvailabilityGateAppearsExactlyOnceInTheModule")
        guard let site = sites.first else { return }
        XCTAssertEqual(site.file,
                       "ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift",
                       "the single gate must live with the ContactsAccess mapping")
        XCTAssertTrue(site.text.contains("status == .limited"),
                      "the single gate must compare the status against .limited "
                      + "(line \(site.line): \(site.text))")
    }

    // MARK: - `AddressBookEntry.identifier` plumbing (T-148a §3.5)

    /// `make` defaults the identifier to empty: every existing labeled
    /// call site (test fixtures included) constructs an unlinkable row
    /// unchanged.
    func testMakeDefaultsIdentifierToEmpty() {
        let entry = AddressBookEntry.make(givenName: "Sita",
                                          familyName: "Sharma",
                                          organizationName: "",
                                          numbers: [("mobile", "9841234567")])
        XCTAssertEqual(entry?.identifier, "")
    }

    /// A passed identifier lands on the entry verbatim — the system
    /// record handle a stored contact link anchors on.
    func testMakePassesIdentifierThrough() {
        let entry = AddressBookEntry.make(givenName: "Sita",
                                          familyName: "Sharma",
                                          organizationName: "",
                                          numbers: [("mobile", "9841234567")],
                                          identifier: "ABRecord-42")
        XCTAssertEqual(entry?.identifier, "ABRecord-42")
    }

    /// Direct (test) construction defaults to empty, and the identifier
    /// participates in the synthesized `Equatable`: two rows differing
    /// only by their system record are different rows — a link must never
    /// be proven by "everything else matches".
    func testDirectConstructionDefaultsToEmptyAndIdentifierIsEquatable() {
        let plain = AddressBookEntry(name: "Sita", label: "mobile",
                                     phone: "9841234567", normalized: "9841234567")
        XCTAssertEqual(plain.identifier, "")
        XCTAssertEqual(plain,
                       AddressBookEntry(name: "Sita", label: "mobile",
                                        phone: "9841234567", normalized: "9841234567"))
        var linked = plain
        linked.identifier = "ABRecord-42"
        XCTAssertNotEqual(plain, linked)
    }
}
