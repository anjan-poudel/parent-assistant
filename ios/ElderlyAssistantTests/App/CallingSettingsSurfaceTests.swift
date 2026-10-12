import XCTest
@testable import ElderlyAssistant

/// T-154 — the calling settings screen's second picker and its
/// accessibility (C6 view half, design-l2 §11; FR-CDP-001/002/003,
/// NFR-CDP-005/006). One test per T-154 Gherkin scenario — scenario 1
/// carries both restore halves (absent AND unknown raw value), the same
/// pair T-146's scenario 5 "starts at the phone floor" states — plus the
/// source pins the design's §28 seam row names for the view structure.
///
/// The persistence half runs the REAL `AppCoordinator` over the real
/// UserDefaults seam (`UserDefaults.standard`, keys "defaultCallApp" /
/// "secondaryCallApp" — the same seam the app writes): every test
/// snapshots and restores those two keys around itself (the
/// `ColdStartRoutingTests` discipline), and the payload channel is the
/// house in-memory profile storage helper (the pattern its sibling
/// suites ship — `ColdStartRoutingTests`, `ProfileCoordinatorSeamTests`).
///
/// What a unit test honestly CANNOT witness (recorded as DV-1 items in
/// the unit report, not simulated here): the RENDERED SwiftUI
/// accessibility tree — VoiceOver's traversal order, the announcement it
/// derives from a trait on a rendered Button, the on-screen frames of
/// the rows, and the ne-locale reading of the selected trait. The traits
/// and semantics are pinned in the SOURCE with the house scan helper
/// (`FeatureSourceScan`, the `SpotifySettingsSurfaceTests` pattern);
/// the rendered tree is DV-1's job on the device.
final class CallingSettingsSurfaceTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    /// The coordinator's own preference keys (`AppCoordinator` keeps them
    /// private; these strings are the seam the app really writes).
    private static let primaryKey = "defaultCallApp"
    private static let secondaryKey = "secondaryCallApp"

    private var primaryBackup: Any?
    private var secondaryBackup: Any?

    override func setUp() {
        super.setUp()
        primaryBackup = UserDefaults.standard.object(forKey: Self.primaryKey)
        secondaryBackup = UserDefaults.standard.object(forKey: Self.secondaryKey)
    }

    override func tearDown() {
        restore(Self.primaryKey, backup: primaryBackup)
        restore(Self.secondaryKey, backup: secondaryBackup)
        super.tearDown()
    }

    // MARK: - Scenario 1: An absent or garbage stored value restores the phone floor

    /// The two restore halves the scenario states ("no secondary key" OR
    /// "an unknown raw value"): both read `phone` through the real
    /// coordinator, and the stored value stays WRITABLE by the settings
    /// screen afterwards (T-146 scenario 5's second clause).
    @MainActor
    func testSecondaryAbsentRestoresPhone() {
        let storage = InMemoryProfilePayloadStorage()

        // Half one: fresh storage with no secondary key at all.
        UserDefaults.standard.removeObject(forKey: Self.secondaryKey)
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.secondaryKey),
                     "the fixture must genuinely have no secondary key")
        let fresh = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(fresh.secondaryCallApp, .phone,
                       "a store without the secondary key must show phone (the GSM floor)")

        // Half two: an unknown raw value restores the same floor.
        UserDefaults.standard.set("carrierPigeon", forKey: Self.secondaryKey)
        let garbage = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(garbage.secondaryCallApp, .phone,
                       "an unknown stored raw value must restore phone, never crash")

        // The picker row's write path reaches the store from either state
        // (the value is writable after a fallback restore).
        garbage.secondaryCallApp = .messenger
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.secondaryKey), "messenger",
                       "the settings screen must be able to write the secondary pick after a fallback restore")
    }

    // MARK: - Scenario 2: The pick round-trips across coordinator instances

    /// Pick messenger through the property (exactly what the secondary
    /// section's row tap writes), then re-instantiate the coordinator
    /// over the SAME storage: the restored pick is messenger — the
    /// storage half landed in T-146, exercised end to end here.
    @MainActor
    func testSecondaryRoundTrip() {
        UserDefaults.standard.removeObject(forKey: Self.secondaryKey)
        let storage = InMemoryProfilePayloadStorage()

        let first = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(first.secondaryCallApp, .phone, "the fixture starts on the floor")
        first.secondaryCallApp = .messenger

        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.secondaryKey), "messenger",
                       "the pick must reach the store at the moment it is made (didSet)")

        let restarted = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(restarted.secondaryCallApp, .messenger,
                       "a new coordinator over the same storage must show messenger as selected")
    }

    // MARK: - Scenario 3: Both sections persist independently

    /// Distinct primary and secondary picks, each written the way its
    /// row's tap writes it: neither pick moves the other section's
    /// property, the two keys hold their own values, both survive a
    /// re-instantiation, and an EQUAL pair stays legal at the storage
    /// layer (SA-9 — dedupe is the chain's job, never storage's).
    @MainActor
    func testPickerTwoSectionsPersist() {
        UserDefaults.standard.removeObject(forKey: Self.primaryKey)
        UserDefaults.standard.removeObject(forKey: Self.secondaryKey)
        let storage = InMemoryProfilePayloadStorage()

        let coordinator = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(coordinator.defaultCallApp, .phone)
        XCTAssertEqual(coordinator.secondaryCallApp, .phone)

        // The primary section's row tap, then the secondary section's —
        // each section's selection is its own property, so neither write
        // may move the other.
        coordinator.defaultCallApp = .whatsApp
        XCTAssertEqual(coordinator.secondaryCallApp, .phone,
                       "the primary pick must not move the secondary section")
        coordinator.secondaryCallApp = .messenger
        XCTAssertEqual(coordinator.defaultCallApp, .whatsApp,
                       "the secondary pick must not move the primary section")

        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.primaryKey), "whatsApp",
                       "the primary pick persists under its own key")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.secondaryKey), "messenger",
                       "the secondary pick persists under its own key")

        let restarted = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(restarted.defaultCallApp, .whatsApp, "the primary section shows only its own pick")
        XCTAssertEqual(restarted.secondaryCallApp, .messenger, "the secondary section shows only its own pick")

        // SA-9: secondary == primary is legal — both keys simply keep the
        // same raw value; the chain dedupes at routing time.
        restarted.secondaryCallApp = .whatsApp
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.primaryKey), "whatsApp")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.secondaryKey), "whatsApp",
                       "an equal pair must persist on both keys — storage never dedupes")
    }

    // MARK: - Scenario 4: Selection is announced non-visually (the failure of the visual-only check)

    /// The shipped failure mode the scenario names — "selection conveyed
    /// by checkmark and stroke only" — is pinned shut at the source: the
    /// row carries the selected trait gated on its own section's
    /// selection, the checkmark glyph is decorative, and ONE row builder
    /// serves both sections, each selecting against its OWN stored pick.
    func testPickerRowExposesSelectedState() throws {
        let section = try callingSettingsSource()

        XCTAssertTrue(section.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
                      "the selected row must carry the selected trait (V-4) — the checkmark cannot be the only signal")
        XCTAssertTrue(section.contains(".accessibilityHidden(true)"),
                      "the checkmark glyph must be decorative — the trait is the non-visual signal")

        // One row pattern for both sections (the design's "identical row
        // serves both sections"), and the selection it reads is the
        // section's own `selected` argument — never another section's.
        XCTAssertEqual(occurrences(of: "private func channelRow(", in: section), 1,
                       "there must be exactly ONE row builder serving both sections")
        XCTAssertTrue(section.contains("channelRow(app, isSelected: app == selected, pick: pick)"),
                      "the row's selection must be computed against its section's own pick")

        // Two sections, each bound to its own stored pick and pick-write.
        XCTAssertEqual(occurrences(of: "section(titleKey: \"", in: section), 2,
                       "the screen must render exactly the two labelled sections")
        XCTAssertTrue(section.contains("selected: coordinator.defaultCallApp"),
                      "the primary section selects against defaultCallApp only")
        XCTAssertTrue(section.contains("selected: coordinator.secondaryCallApp"),
                      "the secondary section selects against secondaryCallApp only")
    }

    /// The section titles carry heading semantics — a plain `Text` header
    /// is not a VoiceOver heading (V-4) — and the two sections render
    /// DISTINCT titles from the two new keys, both resolving in both
    /// scripts (no sixth user-visible string).
    func testPickerTitlesExposeHeadingTrait() throws {
        let section = try callingSettingsSource()

        XCTAssertTrue(section.contains(".accessibilityAddTraits(.isHeader)"),
                      "the section titles must carry the heading trait (V-4)")
        XCTAssertEqual(occurrences(of: ".accessibilityAddTraits(.isHeader)", in: section), 1,
                       "heading semantics belong to the one section-title element")

        XCTAssertTrue(section.contains(#"section(titleKey: "settings.calling.primaryTitle""#),
                      "the primary section title must be the new primaryTitle key")
        XCTAssertTrue(section.contains(#"section(titleKey: "settings.calling.secondaryTitle""#),
                      "the secondary section title must be the new secondaryTitle key")

        for locale in [english, nepali] {
            let primary = L10n.str("settings.calling.primaryTitle", locale: locale)
            let secondary = L10n.str("settings.calling.secondaryTitle", locale: locale)
            XCTAssertNotEqual(primary, "settings.calling.primaryTitle",
                              "primaryTitle is missing from the \(locale.identifier) catalog")
            XCTAssertNotEqual(secondary, "settings.calling.secondaryTitle",
                              "secondaryTitle is missing from the \(locale.identifier) catalog")
            XCTAssertNotEqual(primary, secondary,
                              "the two sections must render distinct titles in \(locale.identifier)")
        }
    }

    // MARK: - L2-D8 and the frozen string surface (definition-of-done pins)

    /// The channel labels stay single-sourced (L2-D8): the view holds NO
    /// `app.name.*` literal of its own — the mapping is the shared chain
    /// helper's, whose four keys are the shipped vocabulary.
    func testChannelLabelsDelegateToTheChainHelper() throws {
        let section = try callingSettingsSource()

        XCTAssertFalse(section.contains("app.name."),
                       "the view must not re-derive the channel name keys — it delegates (L2-D8)")
        XCTAssertTrue(section.contains("CallChannelChain.nameKey(for: app)"),
                      "nameKey must delegate to the chain helper (L2-D8)")
        XCTAssertTrue(section.contains("LocalizedStringKey(Self.nameKey(for: app))"),
                      "the row label must flow through the delegating mapping")

        for app in [CallApp.faceTime, .phone, .messenger, .whatsApp] {
            XCTAssertEqual(CallChannelChain.nameKey(for: app),
                           "app.name.\(app.rawValue.lowercased())",
                           "the helper's key for \(app.rawValue) drifted from the shipped catalog key")
        }
    }

    /// "No sixth user-visible string" (T-154 DoD): every catalog key this
    /// screen renders is read off the source — the literal passed as
    /// `titleKey:` or to `Text("...")` — and the set is EXACTLY the four
    /// shipped keys. A new literal fails here, named; a deliberate new
    /// surface updates this list in the same commit.
    func testTheScreenAddsNoSixthUserVisibleString() throws {
        let section = try callingSettingsSource()
        let rendered = Self.renderedCatalogKeys(in: section)

        XCTAssertEqual(rendered, ["settings.calling.title",
                                  "settings.calling.primaryTitle",
                                  "settings.calling.secondaryTitle",
                                  "calling.defaultCaption"],
                       "the screen's string surface is frozen at the shipped keys plus the two new titles")
    }

    // MARK: - Helpers

    private func restore(_ key: String, backup: Any?) {
        if let backup {
            UserDefaults.standard.set(backup, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Source scans (the file is the witness for view modifiers)

    /// The `CallingSettingsView` struct's own source — comments stripped,
    /// string literals kept (a doc example must not satisfy a pin; a
    /// modifier must). The unit of a scan is the TYPE (the
    /// `SettingsTabMappingTests.structSource` convention).
    private func callingSettingsSource() throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/CallingSettingsView.swift")
        let text = FeatureSourceScan.codeText(of: url)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("struct CallingSettingsView") },
                                  "CallingSettingsView.swift has no top-level struct CallingSettingsView")
        let end = lines[(start + 1)...].firstIndex { line in
            ["struct ", "enum ", "extension ", "final class ", "class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// The catalog keys the screen renders, read off its (comment-
    /// stripped) source: every literal passed as `titleKey:` or to
    /// `Text("...")`. Parameterised titles
    /// (`Text(LocalizedStringKey(titleKey))`) are covered by their call
    /// sites, which this pattern picks up.
    private static func renderedCatalogKeys(in text: String) -> Set<String> {
        let pattern = "(?:titleKey:|Text\\()\\s*\"([A-Za-z0-9._-]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        var keys: Set<String> = []
        for match in regex.matches(in: text,
                                   range: NSRange(location: 0, length: source.length)) {
            keys.insert(source.substring(with: match.range(at: 1)))
        }
        return keys
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship — `ColdStartRoutingTests`,
    // `ProfileCoordinatorSeamTests`: the coordinator's payload store only;
    // the preference seam under test is the real UserDefaults one.)

    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }
}
