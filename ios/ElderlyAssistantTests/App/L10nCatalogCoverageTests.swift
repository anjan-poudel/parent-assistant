import XCTest
@testable import ElderlyAssistant

/// Catalog coverage for the profile-interview's new user-visible keys
/// (profile-interview, T-093 / C09, NFR-PI-006).
///
/// Every interview/Settings string is keyed; this suite is what makes
/// "the key resolves" a claim with evidence: each key must resolve in
/// BOTH shipped languages (en + ne) to something that is not the key
/// itself, and the two resolutions must differ — a key whose ne copy was
/// forgotten by copy-pasting the en value fails here rather than shipping
/// a screen that reads English to a Nepali household.
///
/// Resolution goes through `L10n.str`, the same path non-View code uses,
/// so this pins the shipped lproj bundles, not the source JSON.
final class L10nCatalogCoverageTests: XCTestCase {

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    /// The feature's new keys (plus `profile.field.addressAs`, which the
    /// shared `AddressAsField` has rendered since T-098 — the coverage
    /// check is how its absence would have been caught).
    private static let interviewKeys: [String] = [
        // C05 — the wake acknowledgment template (design-given copy).
        "wakeAck.personalized",
        // C06 — About-you step: title/body + field labels.
        "onboarding.aboutYou.title",
        "onboarding.aboutYou.body",
        "onboarding.aboutYou.name",
        "onboarding.aboutYou.addressAs",
        "onboarding.aboutYou.dateOfBirthToggle",
        // C11 — emergency contacts step: title/body + kin/GP/hospital.
        "onboarding.emergency.title",
        "onboarding.emergency.body",
        "onboarding.emergency.kinTitle",
        "onboarding.emergency.doctor",
        "onboarding.emergency.hospital",
        // C12 — voice fingerprint step + its controls.
        "onboarding.stepVoiceFingerprint.title",
        "onboarding.stepVoiceFingerprint.body",
        "onboarding.voiceFingerprint.progress",
        "onboarding.voiceFingerprint.record",
        "onboarding.voiceFingerprint.stop",
        "onboarding.voiceFingerprint.done",
        // C08 — the Settings editor.
        "settings.profile.title",
        "settings.profile.explanation",
        "profile.field.name",
        "profile.field.addressAs",
        "profile.field.dateOfBirth",
        "profile.field.doctor",
        "profile.field.hospital",
        "profile.kin.note",
        "profile.save",
        "profile.saved",
        "profile.error.saveFailed",
    ]

    func testEveryInterviewKeyResolvesInBothLanguages() {
        for key in Self.interviewKeys {
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
        }
    }

    func testNoInterviewKeyShipsTheEnglishCopyUntranslated() {
        for key in Self.interviewKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, ne,
                              "\(key) resolves to the SAME string in en and ne "
                              + "— the Nepali copy is missing (or the key was "
                              + "forgotten in one language)")
        }
    }

    /// The number of `%d`/`%@` placeholders must match between the two
    /// languages: a translator who drops or duplicates a placeholder
    /// would make `L10n.fmt` crash or mis-place an argument. Only the
    /// format-string keys carry them; this pins those two.
    func testTheFormattedKeysKeepTheirPlaceholderCounts() {
        for key in ["wakeAck.personalized", "onboarding.voiceFingerprint.progress"] {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertEqual(Self.placeholderCount(in: en),
                           Self.placeholderCount(in: ne),
                           "\(key): the en and ne copies disagree on how many "
                           + "arguments the format string takes")
        }
    }

    private static func placeholderCount(in value: String) -> Int {
        var count = 0
        var index = value.startIndex
        while let found = value[index...].range(of: "%") {
            count += 1
            index = value.index(after: found.lowerBound)
            if index >= value.endIndex { break }
        }
        return count
    }
}
