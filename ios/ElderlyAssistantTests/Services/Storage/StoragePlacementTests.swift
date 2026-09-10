import XCTest
@testable import ElderlyAssistant

/// Guards the storage split ([BOOT-REVIEW P1-6], 2026-09-10): the
/// Keychain keeps SMALL SECRETS AND KEYS ONLY; every structured payload
/// lives in an encrypted file under Application Support.
///
/// Both directions are pinned by name, because the failure modes are
/// asymmetric and both are bad: a secret that slips into a file loses the
/// Keychain item's per-item protection, and a large payload that stays in
/// the Keychain is the migration this item exists to perform.
final class StoragePlacementTests: XCTestCase {

    // MARK: - What stays in the Keychain

    func testProviderSecretsStayInTheKeychain() {
        for key in ["gemini.apiKey", "search.apiKey", "search.engineId",
                    "youtube.apiKey", "gemini.model"] {
            XCTAssertEqual(StoragePlacementPolicy.placement(for: key),
                           .keychain,
                           "\(key) must keep the Keychain's protection")
            XCTAssertFalse(StoragePlacementPolicy.migratesToFile(key))
        }
    }

    func testTheKeychainSetIsExactlyTheReviewedSecrets() {
        // Set equality, not a containment check: every Keychain-resident
        // key is a deliberate decision about a small secret, and a new one
        // appearing (or an existing one moving to the file store) must be a
        // conscious edit to this list.
        XCTAssertEqual(StoragePlacementPolicy.keychainResidentKeys,
                       ["gemini.apiKey", "search.apiKey", "search.engineId",
                        "youtube.apiKey", "gemini.model"])
    }

    // MARK: - What moves to encrypted files

    func testStructuredDataMigratesToEncryptedFiles() {
        // The keys the boot restore and the stores actually use. Named
        // here so a store that changes its key cannot silently drift onto
        // the wrong side of the split.
        let structuredKeys = [
            // Identity + care (the safety-critical set the boot restores).
            "family.contacts",
            "places.saved",
            "medical.appointments",
            "morningBriefing.current",
            "chat.history",
            "app.activity.log",
            // Reminder state.
            "routine.entries",
            "routine.occurrences",
            "routine.seeded_v1",
            "medication.entries",
            "medication.pending_reminders",
            "medication.adherence_log",
            "alarms.list",
            "timers.list",
            // Configuration + cached presentation data.
            "feeds.config.v1",
            "news.sources",
            "local.tool.log",
            "gemini.costGovernor.v1",
            "plugin.appliance_helper.cache.v1",
            "contact.channel.preferences",
            "messenger.handles.byNormalizedPhone",
            "call.recency.byNormalizedNumber",
            "call.methodPreferences",
            "call.confirmedMethodHistory",
            "intents.commandCache",
            "intents.recentConfirmedActions",
        ]
        for key in structuredKeys {
            XCTAssertEqual(StoragePlacementPolicy.placement(for: key),
                           .encryptedFile,
                           "\(key) is structured data — it belongs in an "
                           + "encrypted file, not a Keychain item")
        }
    }

    func testPreviouslyUnseenStructuredKeyDefaultsToTheFileStore() {
        // The default is the file store, so a NEW structured payload does
        // not silently join the Keychain — that is the direction the
        // review's rule points.
        XCTAssertEqual(StoragePlacementPolicy
                        .placement(for: "something.new.v1"),
                       .encryptedFile)
    }

    func testPluginCacheKeysFromUserTextAreFileResident() {
        // The Nepali calendar plugin builds a key from the user's own
        // question — unbounded, arbitrary text, including "/" — which is
        // exactly what must not become a Keychain item name.
        let key = "plugin.nepali_calendar.answer.आजको मिति कति? / today"
        XCTAssertEqual(StoragePlacementPolicy.placement(for: key),
                       .encryptedFile)
    }

    func testThePolicyIsPure() {
        // Same input → same answer, no state, no ordering effects: the
        // placement of a key must not depend on what was asked before it.
        let key = "family.contacts"
        let first = StoragePlacementPolicy.placement(for: key)
        _ = StoragePlacementPolicy.placement(for: "gemini.apiKey")
        XCTAssertEqual(StoragePlacementPolicy.placement(for: key), first)
    }
}
