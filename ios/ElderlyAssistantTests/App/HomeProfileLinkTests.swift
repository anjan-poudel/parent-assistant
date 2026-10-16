import XCTest
@testable import ElderlyAssistant

/// The home hub's "About me" icon (home-profile-icon, 2026-10-06): the
/// profile editor's own leaf, sitting immediately after Settings on the
/// top bar and pushing the SAME `ProfileSettingsView` the Settings
/// family tab pushes.
///
/// The hub link itself (`NavigationLink(value: .profile)`, label key
/// `home.hub.profile`, identifier `home.profile` beside `home.settings`)
/// is a view-layer fact pinned at the UI-test layer — this suite pins
/// what a unit test honestly can: the leaf's navigation-path id and the
/// label resolving in both shipped languages.
final class HomeProfileLinkTests: XCTestCase {

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    /// The pushed destination is keyed by `id` — the path entry must be
    /// exactly "profile", and it must not collide with any other leaf.
    func testTheProfileLeafIdIsStableAndUnique() {
        XCTAssertEqual(LeafDestination.profile.id, "profile",
                       "the navigation path's value is the leaf's id")

        let allLeaves: [LeafDestination] = [
            .meds, .reminders, .calendar, .call, .history, .settings,
            .profile, .directions, .briefing, .updates, .feed, .alarms,
        ]
        let ids = allLeaves.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "every leaf id must be unique — a duplicate would "
                       + "make navigationDestination resolve the wrong leaf")
    }

    /// The icon's VoiceOver label is keyed and ships in both languages —
    /// the same coverage contract the interview keys carry
    /// (NFR-PI-006). This is the key the hub link's accessibility label
    /// resolves through, so "the icon is announced" is checkable here
    /// even though the link wiring is not.
    func testTheHubProfileLabelResolvesInBothLanguages() {
        let key = "home.hub.profile"
        let en = L10n.str(key, locale: english)
        let ne = L10n.str(key, locale: nepali)
        XCTAssertNotEqual(en, key,
                          "\(key) does not resolve in en — the catalog "
                          + "entry is missing")
        XCTAssertNotEqual(ne, key,
                          "\(key) does not resolve in ne — the catalog "
                          + "entry is missing")
        XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(key) resolves to empty en copy")
        XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(key) resolves to empty ne copy")
        XCTAssertNotEqual(en, ne,
                          "\(key) resolves to the SAME string in en and ne "
                          + "— the Nepali copy is missing")
    }
}
