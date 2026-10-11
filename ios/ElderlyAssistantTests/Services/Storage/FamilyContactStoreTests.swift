import XCTest
@testable import ElderlyAssistant

final class FamilyContactStoreTests: XCTestCase {

    func testAddLoadRoundTrip() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "राम")
        XCTAssertEqual(loaded.first?.phone, "9812345678")
    }

    func testMaxContactsEnforcedAtTwelve() {
        // (family-and-friends task, 2026-09-07) The cap was raised from
        // 3 to 12 — "Family and friends" is now the primary curated list,
        // not just the emergency trio. The onboarding flow keeps its own
        // 1–3 collection regardless; this cap bounds the Settings editor.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        for i in 0..<13 {
            let added = store.add(FamilyContact(name: "सम्पर्क \(i)",
                                                phone: "98\(i)",
                                                relationship: "परिवार"))
            if i < 12 {
                XCTAssertTrue(added, "contact \(i) should have been accepted")
            } else {
                XCTAssertFalse(added, "13th contact must be rejected")
            }
        }
        XCTAssertEqual(store.load().count, 12)
    }

    func testRemoveDeletesOnlyTarget() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let a = FamilyContact(name: "अ", phone: "1", relationship: "छोरा")
        let b = FamilyContact(name: "ब", phone: "2", relationship: "छोरी")
        store.add(a)
        store.add(b)

        XCTAssertTrue(store.remove(id: a.id))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, b.id)
    }

    func testEmptyWhenNothingStored() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.load().isEmpty)
    }

    func testMessengerHandleRoundTrips() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "सीता", phone: "9812345678",
                                    relationship: "छोरी",
                                    messengerHandle: "sita.sharma77")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.messengerHandle, "sita.sharma77")
    }

    func testPhotoFilenameRoundTrips() {
        // (family-and-friends task, 2026-09-07) The contact stores only
        // the ContactPhotoStore file NAME — never a path — and a contact
        // without a photo simply has nil.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "गीता", phone: "9812345678",
                                    relationship: "छोरी",
                                    photoFilename: "1E9A8B7C-2D3E-4F5A-6B7C-8D9E0F1A2B3C.jpg")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.photoFilename,
                       "1E9A8B7C-2D3E-4F5A-6B7C-8D9E0F1A2B3C.jpg")
    }

    func testNicknamesRoundTrip() {
        // (family-contacts-unify T-145, 2026-10-12 — evolved from the
        // family-wizard task's single nickname, 2026-09-07) The stored
        // nicknames are the source of truth, in order, exactly as
        // entered — a contact saved without any reads back as an empty
        // list.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा",
                                    nicknames: ["बुवा"])
        XCTAssertTrue(store.add(contact))

        XCTAssertEqual(store.load().first?.nicknames, ["बुवा"])

        let plain = FamilyContact(name: "सीता", phone: "9812345678", relationship: "छोरी")
        XCTAssertTrue(store.add(plain))
        XCTAssertEqual(store.load().last?.nicknames, [],
                       "a contact created without a nickname stores none")
    }

    func testAddressRoundTrips() {
        // (directions task, 2026-09-07) The free-form home address makes
        // a relative a voice-navigation target ("मैयाको घर लैजाऊ"); nil
        // when the user never set one.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "मैया", phone: "9812345678",
                                    relationship: "दिदी",
                                    address: "बूढानीलकण्ठ, काठमाडौं ९")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.address, "बूढानीलकण्ठ, काठमाडौं ९")
    }

    func testContactWithoutAddressLoadsNil() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा")
        XCTAssertTrue(store.add(contact))

        XCTAssertNil(store.load().first?.address,
                     "no address typed means nil — the navigation candidate list excludes the contact")
    }

    // MARK: - Email (calendar & family sharing task, 2026-09-16)

    func testEmailRoundTrips() {
        // The address a Google Calendar invitation is sent to. Like the
        // handle, the photo, the nickname and the address before it, the
        // field is stored verbatim and read back — the share mapper is
        // what decides whether a contact with no address gets an invite.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "आमा", phone: "9812345678",
                                    relationship: "आमा",
                                    email: "maa@example.com",
                                    isEmergencyContact: true)
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.email, "maa@example.com")
    }

    func testBlankEmailNormalizesToNilAndStoresNoAddress() {
        // The editor funnels the typed field through
        // `FamilyContactValidation.normalizedEmail` before saving, so a
        // field the user tabbed through and left empty is stored as nil
        // — never an empty string that every invite check would then have
        // to special-case as "present but useless".
        XCTAssertNil(FamilyContactValidation.normalizedEmail("   "))
        XCTAssertNil(FamilyContactValidation.normalizedEmail("\n\t "))

        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा",
                                    email: FamilyContactValidation.normalizedEmail("  "))
        XCTAssertTrue(store.add(contact))

        XCTAssertNil(store.load().first?.email,
                     "whitespace normalizes to no address at all")
    }

    func testLegacyPayloadWithoutEmailDecodesAsNil() {
        // Same four-field legacy shape as the other backward-decode
        // tests: a payload written before the email field existed loads
        // email-less rather than failing the whole store read — the
        // synthetic fallback contact `AppCoordinator` builds when the
        // list is empty depends on it.
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyFamilyContact(id: UUID(), name: "राम",
                                         phone: "9812345678", relationship: "छोरा")
        guard case .success = storage.write(key: "family.contacts", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.email,
                     "a pre-email-field payload decodes email-less — such a contact simply receives no invitation")
    }

    func testLegacyPayloadWithoutOptionalFieldsDecodesAsNil() {
        // Payloads written before the optional fields existed (the
        // unversioned store's only "migration" is each field being
        // optional) must still load — written here through a legacy-shaped
        // struct that provably lacks every optional field:
        // `messengerHandle` (added 2026-09-06), `photoFilename` (added
        // 2026-09-07 by the family-and-friends task), the single
        // `nickname` (added 2026-09-07 by the family-wizard task;
        // T-145 replaced it with the `nicknames` array, whose
        // pre-field default is the empty list) and `address` (added
        // 2026-09-07 by the directions task).
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyFamilyContact(id: UUID(), name: "राम",
                                         phone: "9812345678", relationship: "छोरा")
        guard case .success = storage.write(key: "family.contacts", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "राम")
        XCTAssertNil(loaded.first?.messengerHandle,
                     "a pre-field payload decodes with a nil handle, not a failure")
        XCTAssertNil(loaded.first?.photoFilename,
                     "a pre-photo-field payload decodes photo-less, not a failure")
        XCTAssertEqual(loaded.first?.nicknames, [],
                       "a pre-nickname-field payload decodes with no nicknames, not a failure")
        XCTAssertNil(loaded.first?.address,
                     "a pre-address payload decodes address-less, not a failure")
        XCTAssertNil(loaded.first?.systemContact,
                     "a pre-link payload decodes unlinked, not a failure")
    }

    // MARK: - Multi-nickname storage and migration (family-contacts-unify T-145, 2026-10-12)

    /// Writes a RAW payload for `key` — the only way to say "a payload
    /// exactly as an older build wrote it", because the current model
    /// cannot encode the legacy `nickname` key at all (the synthesized
    /// encoder is authoritative and emits only stored properties). The
    /// store always reads an ARRAY of records, so the fixture is an
    /// array of one (or more) dictionaries.
    @discardableResult
    private func writeRaw(_ records: [[String: Any]], storage: InMemoryEncryptedStorage,
                          key: String = "family.contacts") -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: records) else { return false }
        return storage.writeRaw(key: key, data: data)
    }

    /// A complete, current-shape record's JSON dictionary with the caller's
    /// overrides applied — the base for every historical-shape fixture.
    private func recordJSON(id: UUID = UUID(), name: String = "राम",
                            phone: String = "9812345678",
                            relationship: String = "छोरा",
                            overrides: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "phone": phone,
            "relationship": relationship,
        ]
        for (key, value) in overrides { object[key] = value }
        return object
    }

    func testMultipleNicknamesStoredAsEnteredSurviveRoundTrip() {
        // FR-FCU-011 scenario 1 (family-contacts-unify T-145): the two
        // spellings are DISTINCT entries — no transliteration, no
        // romanization, no fuzzy bridging. Order is preserved.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "सीता शर्मा", phone: "9812345678",
                                    relationship: "छोरी",
                                    nicknames: ["sanu", "सानु"])
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.nicknames, ["sanu", "सानु"],
                       "both entries survive the round-trip exactly as entered")
    }

    func testLegacySingleNicknameMigratesLosslessly() {
        // T-145 acceptance scenario 1 (FR-FCU-011 scenario 2): the
        // pre-change payload carries the OLD single key; the store hands
        // it back as one multi-nickname entry, untouched, and re-encoding
        // writes the NEW shape (the legacy key is never emitted again).
        let storage = InMemoryEncryptedStorage()
        let id = UUID()
        writeRaw([recordJSON(id: id, overrides: ["nickname": "बुवा"])], storage: storage)

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.nicknames, ["बुवा"],
                       "the legacy single nickname migrates into the list without loss")
        XCTAssertEqual(loaded.first?.id, id, "no other field is altered")
        XCTAssertEqual(loaded.first?.name, "राम")
        XCTAssertEqual(loaded.first?.phone, "9812345678")
        XCTAssertEqual(loaded.first?.relationship, "छोरा")
        XCTAssertNil(loaded.first?.systemContact)

        // A READ never rewrites the store — the migration lands when the
        // migrated record is saved again (an edit, a flag write), and
        // THAT write emits the new shape only.
        XCTAssertTrue(store.save(loaded), "re-saving the migrated contact succeeds")
        guard case .success(let object) = storage.rawObject(key: "family.contacts") else {
            return XCTFail("raw payload missing after re-save")
        }
        let records = object as? [[String: Any]]
        XCTAssertEqual(records?.count, 1, "re-encoding keeps the contact")
        XCTAssertEqual(records?.first?["nicknames"] as? [String], ["बुवा"],
                       "the migrated payload carries the new array shape")
        XCTAssertNil(records?.first?["nickname"],
                     "the legacy key is never written by the synthesized encoder")

        // And the round-trip through the new shape is lossless.
        let reloaded = store.load()
        XCTAssertEqual(reloaded.first?.nicknames, ["बुवा"])
        guard case .success(let decodedAgain) = storage.readRaw(
            key: "family.contacts", as: [FamilyContact].self) else {
            return XCTFail("re-encoded payload no longer decodes")
        }
        XCTAssertEqual(decodedAgain.first?.nicknames, ["बुवा"],
                       "the re-encoded shape decodes back to the same entry")
        XCTAssertEqual(decodedAgain.first?.id, id,
                       "re-encoding keeps the record's identity")
    }

    func testLegacyEmptyOrWhitespaceOnlyNicknameMigratesToNoNicknames() {
        // A legacy value that is empty or whitespace-only means "unset"
        // — it must never become an entry that could match everything
        // (FR-FCU-011 edge scenario).
        for legacyValue in ["", "   ", "\n\t "] {
            let storage = InMemoryEncryptedStorage()
            writeRaw([recordJSON(overrides: ["nickname": legacyValue])], storage: storage)

            let store = FamilyContactStore(storage: storage)
            let loaded = store.load()
            XCTAssertEqual(loaded.count, 1,
                           "a blank legacy nickname must not drop the contact")
            XCTAssertEqual(loaded.first?.nicknames, [],
                           "legacy value '\(legacyValue)' normalizes to no nicknames")
        }
    }

    func testNormalizedNicknamesTrimsAndDropsWhitespaceOnlyEntries() {
        // Design-l2 §3.2: trim with `.whitespacesAndNewlines`, drop the
        // entries that become empty, and preserve order AND duplicates
        // (the editor is a faithful editor of the stored list).
        XCTAssertEqual(FamilyContact.normalizedNicknames(["  sanu ", "सानु", "   "]),
                       ["sanu", "सानु"])
        XCTAssertEqual(FamilyContact.normalizedNicknames(["\n बुवा \t", "", "\n"]),
                       ["बुवा"])
        XCTAssertEqual(FamilyContact.normalizedNicknames(["sanu", "sanu"]),
                       ["sanu", "sanu"], "duplicates are preserved, not deduped")
        XCTAssertEqual(FamilyContact.normalizedNicknames([]), [])
    }

    func testWhitespaceOnlyEntriesAreNotStoredAndDoNotMatchAnything() {
        // FR-FCU-011 edge scenario: entries that are only spaces are
        // dropped at the store boundary — nothing empty ever persists.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा",
                                    nicknames: ["  ", "\n\t ", ""])
        XCTAssertTrue(store.add(contact))

        XCTAssertEqual(store.load().first?.nicknames, [],
                       "no empty entry is ever stored (a query can never match one)")
    }

    func testNicknameCappedAtSixtyFourCharactersAtTheEditorSeam() {
        // T-145 acceptance scenario 3 (security advisory F5). The BOUND
        // lives at the editor/submission seam — `normalizedNicknames`
        // stays faithful so the migration is lossless — and the cap is a
        // whole-grapheme prefix: no Character cluster is split.
        let long = String(repeating: "a", count: 100)
        let capped = FamilyContact.cappedNickname(long)
        XCTAssertEqual(capped?.count, 64)
        XCTAssertEqual(capped, String(repeating: "a", count: 64))
        XCTAssertEqual(FamilyContact.cappedNickname("  बुवा  "), "बुवा",
                       "trimming still happens at the seam")
        XCTAssertNil(FamilyContact.cappedNickname("   "),
                     "blank input is not a nickname")
        XCTAssertNil(FamilyContact.cappedNickname("\n\t "))

        // A Devanagari cluster straddling the boundary is kept whole.
        let clusters = String(repeating: "क", count: 63) + "क्ष"
        let cappedClusters = FamilyContact.cappedNickname(clusters)
        XCTAssertEqual(cappedClusters?.count, 64,
                       "the cap counts Characters, so a cluster is never split")
        XCTAssertTrue(cappedClusters?.hasSuffix("क्ष") ?? false)

        // And the projection stays FAITHFUL — it does not cap (the F5
        // decision above): what the seam stored is exactly what the
        // projection hands back, trimmed and nothing else.
        XCTAssertEqual(FamilyContact.normalizedNicknames([capped ?? ""]),
                       [String(repeating: "a", count: 64)],
                       "normalizedNicknames reflects exactly the stored entries")
        XCTAssertEqual(FamilyContact.normalizedNicknames([long]), [long],
                       "the projection itself never truncates — the bound lives at the editor seam (design-l2 §3.2/F5)")
    }

    func testNicknamesPresenceWinsOverLegacyKeyWithoutDuplicating() {
        // T-145 failure-path scenario 2: a payload carrying BOTH keys is
        // decoded from the new one — even an empty array wins (removing
        // every nickname is real data) — and no entry is duplicated.
        let storage = InMemoryEncryptedStorage()
        writeRaw([recordJSON(overrides: [
            "nicknames": ["sanu", "सानु"],
            "nickname": "sanu",
        ])], storage: storage)

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.first?.nicknames, ["sanu", "सानु"],
                       "the multi-nickname array wins and the legacy key is ignored")

        // The empty-new-shape-wins case: the user removed every entry.
        let second = InMemoryEncryptedStorage()
        writeRaw([recordJSON(overrides: [
            "nicknames": [String](),
            "nickname": "बुवा",
        ])], storage: second)

        let secondStore = FamilyContactStore(storage: second)
        XCTAssertEqual(secondStore.load().first?.nicknames, [],
                       "an explicit empty array is the user's real state; the legacy key does not resurrect it")
    }

    // MARK: - System-contact link (FR-FCU-002, family-contacts-unify T-145)

    func testSystemContactLinkRoundTripsWithBothFields() {
        // T-145 acceptance scenario 4: the pointer to the system record is
        // stored with BOTH the identifier and the number fingerprint, and
        // both come back byte-for-byte.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let link = SystemContactLink(identifier: "X",
                                     numberKey: ContactNumberKey.normalized("9841234567"))
        let contact = FamilyContact(name: "सीता", phone: "9841234567",
                                    relationship: "छोरी",
                                    nicknames: ["sanu"],
                                    systemContact: link)
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.systemContact?.identifier, "X")
        XCTAssertEqual(loaded.first?.systemContact?.numberKey,
                       ContactNumberKey.normalized("9841234567"))
        XCTAssertEqual(loaded.first?.systemContact, link,
                       "the whole link is preserved exactly")
    }

    func testContactWithoutLinkDecodesUnlinked() {
        // The pre-link payload shape: a contact saved before the field
        // existed (or never linked) loads with NO link — nothing about
        // the record changes.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा")
        XCTAssertTrue(store.add(contact))

        XCTAssertNil(store.load().first?.systemContact,
                     "an unlinked contact stores and reads back no link")
    }

    func testCorruptLinkPayloadDecodesToNoLinkAndKeepsTheContact() {
        // T-145 failure-path scenario 1 (FR-FCU-002 scenario 3,
        // NFR-FCU-006): a malformed link payload must NEVER drop the
        // record. Three corruption shapes, one rule.
        let corruptions: [(label: String, value: Any)] = [
            ("empty identifier", ["identifier": "", "numberKey": "9841234567"]),
            ("empty numberKey", ["identifier": "X", "numberKey": ""]),
            ("unknown field type", ["identifier": 42, "numberKey": ["nested"]]),
        ]

        for corruption in corruptions {
            let storage = InMemoryEncryptedStorage()
            writeRaw([recordJSON(overrides: ["systemContact": corruption.value])],
                     storage: storage)

            let store = FamilyContactStore(storage: storage)
            let loaded = store.load()
            XCTAssertEqual(loaded.count, 1,
                           "[\(corruption.label)] the contact is retained, never dropped")
            XCTAssertEqual(loaded.first?.name, "राम",
                           "[\(corruption.label)] all non-link fields are intact")
            XCTAssertEqual(loaded.first?.phone, "9812345678",
                           "[\(corruption.label)] the number survives")
            XCTAssertNil(loaded.first?.systemContact,
                         "[\(corruption.label)] a corrupt link degrades to NO link")
        }
    }

    func testEveryHistoricalShapeLoadsWithoutLoss() {
        // NFR-FCU-006 / T-145 acceptance scenario 2: EVERY shape this
        // store has ever written, plus the corrupt shapes, decodes in one
        // read — no decode failure drops a contact.
        let storage = InMemoryEncryptedStorage()
        let idPreField = UUID()
        let idLegacyNick = UUID()
        let idMulti = UUID()
        let idLinked = UUID()
        let idCorruptLink = UUID()
        let idBlankLegacy = UUID()
        let payload: [[String: Any]] = [
            // 1. The original four-field shape (pre-2026-09-06).
            recordJSON(id: idPreField, name: "पहिलो"),
            // 2. Pre-multi: the legacy single `nickname` key.
            recordJSON(id: idLegacyNick, name: "दोस्रो",
                       overrides: ["nickname": "बुवा"]),
            // 3. The multi-nickname array.
            recordJSON(id: idMulti, name: "तेस्रो",
                       overrides: ["nicknames": ["sanu", "सानु"]]),
            // 4. A valid link.
            recordJSON(id: idLinked, name: "चौथो",
                       overrides: ["systemContact": [
                           "identifier": "56E3-AB", "numberKey": "9841234567",
                       ]]),
            // 5. A corrupt link payload (malformed JSON *object* shape).
            recordJSON(id: idCorruptLink, name: "पाँचौं",
                       overrides: ["systemContact": "not-an-object"]),
            // 6. A whitespace-only legacy nickname.
            recordJSON(id: idBlankLegacy, name: "छैठौं",
                       overrides: ["nickname": "   ", "address": "काठमाडौं"]),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              storage.writeRaw(key: "family.contacts", data: data) else {
            return XCTFail("historical payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 6,
                       "no decode failure may drop a contact — all six shapes load")
        XCTAssertEqual(loaded.map(\.id),
                       [idPreField, idLegacyNick, idMulti, idLinked,
                        idCorruptLink, idBlankLegacy],
                       "order is preserved and every record is present")

        XCTAssertEqual(loaded[0].nicknames, [], "pre-field shape: no nicknames")
        XCTAssertNil(loaded[0].systemContact)
        XCTAssertEqual(loaded[1].nicknames, ["बुवा"], "legacy single nickname migrates")
        XCTAssertEqual(loaded[2].nicknames, ["sanu", "सानु"], "multi shape is verbatim")
        XCTAssertEqual(loaded[3].systemContact,
                       SystemContactLink(identifier: "56E3-AB", numberKey: "9841234567"),
                       "the valid link survives")
        XCTAssertNil(loaded[4].systemContact, "the corrupt link decodes to no link")
        XCTAssertEqual(loaded[5].nicknames, [], "the blank legacy nickname is dropped")
        XCTAssertEqual(loaded[5].address, "काठमाडौं",
                       "non-link fields of the blank-legacy record are intact")
        // Every record's identity survives — the no-drop guarantee.
        XCTAssertTrue(loaded.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: - Emergency flag (family-emergency task, 2026-09-07)

    func testIsEmergencyContactRoundTrips() {
        // The wizard's "Emergency contact" toggle writes the flag on the
        // record; the store must hand it back so an edit shows the
        // toggle pre-set and `AppCoordinator.emergencyContact` can
        // prefer the flagged person.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "बहिनी", phone: "9812345678",
                                    relationship: "बहिनी",
                                    isEmergencyContact: true)
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded.first?.isEmergencyContact ?? false,
                      "the flagged contact must read back flagged")
    }

    func testEmergencyFlagDefaultsToFalse() {
        // A contact created without the flag — every pre-toggle call
        // site, onboarding included — stores false, never a surprise.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        XCTAssertFalse(contact.isEmergencyContact)
        XCTAssertTrue(store.add(contact))
        XCTAssertFalse(store.load().first?.isEmergencyContact ?? true)
    }

    func testLegacyPayloadWithoutEmergencyFlagDecodesFalse() {
        // The flag is the one NON-optional field added since the
        // optional era — its migration is a decoder default, not nil:
        // a payload written before the flag existed (same four-field
        // shape as `LegacyFamilyContact`) must load as false, not fail
        // the whole store read — the pre-flag behavior (first contact
        // wins) is exactly what `AppCoordinator.emergencyContact`
        // keeps as its fallback.
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyFamilyContact(id: UUID(), name: "राम",
                                         phone: "9812345678", relationship: "छोरा")
        guard case .success = storage.write(key: "family.contacts", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded.first?.isEmergencyContact ?? true,
                       "a pre-flag payload decodes as not-emergency, not a failure")
    }

    // MARK: - Emergency-preference rule — AppCoordinator.preferredEmergencyContact

    func testPreferredEmergencyPrefersFlaggedContact() {
        // The wizard's flagged person is whom the Emergency button
        // dials first, even when an unflagged relative sits earlier in
        // the list.
        let son = FamilyContact(name: "छोरा", phone: "9812345678", relationship: "छोरा")
        let daughter = FamilyContact(name: "छोरी", phone: "9812000000",
                                     relationship: "छोरी", isEmergencyContact: true)
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([son, daughter])?.id,
                       daughter.id)
    }

    func testPreferredEmergencyFirstFlagWinsAmongSeveral() {
        // The toggle caption promises "dials this person first" — with
        // several flagged contacts the FIRST flag is the number, list
        // order is the tiebreak.
        let first = FamilyContact(name: "आमा", phone: "1", relationship: "आमा",
                                  isEmergencyContact: true)
        let middle = FamilyContact(name: "छोरा", phone: "2", relationship: "छोरा")
        let last = FamilyContact(name: "छोरी", phone: "3", relationship: "छोरी",
                                 isEmergencyContact: true)
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([first, middle, last])?.id,
                       first.id)
    }

    func testPreferredEmergencyFallsBackToFirstWhenNoneFlagged() {
        // No flagged contact (every record written before the flag
        // existed, or none toggled) keeps the pre-flag behavior: the
        // first configured contact is the emergency number.
        let ram = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        let sita = FamilyContact(name: "सीता", phone: "9812345678", relationship: "छोरी")
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([ram, sita])?.id, ram.id)
    }

    func testPreferredEmergencyEmptyListIsNil() {
        // No configured contacts — the view surfaces that honestly
        // (the emergency button's no-contact alert) instead of
        // resolving to somebody who is not there.
        XCTAssertNil(AppCoordinator.preferredEmergencyContact([]))
    }
}

/// The pre-optional-fields contact shape — no `messengerHandle` (added
/// 2026-09-06), no `photoFilename` (added 2026-09-07), no `nickname`
/// (added 2026-09-07 by the family-wizard task; replaced by the
/// `nicknames` array in T-145, 2026-10-12, whose pre-field default is
/// the empty list), no `address` (added 2026-09-07 by the directions
/// task) and no `email` (added 2026-09-16 by the calendar & family
/// sharing task). It also lacks the `isEmergencyContact` flag (added
/// 2026-09-07 by the family-emergency task), which — unlike the
/// optionals — decodes as false rather than nil. Exists to write
/// old-shape payloads into storage for the backward-decode tests; its
/// JSON is byte-compatible with what the old app version stored.
private struct LegacyFamilyContact: Codable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
}

/// In-memory `EncryptedLocalStorage` for tests — the real implementation
/// is Keychain-backed and untestable without a device context.
///
/// `writeRaw`/`rawObject` (family-contacts-unify T-145) let a test place
/// bytes the CURRENT model cannot produce (the legacy `nickname` key, a
/// corrupt link object) and then inspect what the store actually wrote.
private final class InMemoryEncryptedStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }

    // MARK: Raw-payload access (test-only)

    @discardableResult
    func writeRaw(key: String, data: Data) -> Bool {
        values[key] = data
        return true
    }

    /// Reads the stored bytes back through the CURRENT model — the
    /// "re-encoding writes the new shape" half of the migration test.
    func readRaw<T: Decodable>(key: String, as type: T.Type) -> Result<T, StorageError> {
        read(key: key, type: type)
    }

    /// The stored bytes as a JSON object tree, for asserting which KEYS
    /// the synthesized encoder actually emitted.
    /// the synthesized encoder actually emitted.
    func rawObject(key: String) -> Result<Any, StorageError> {
        guard let data = values[key],
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(object)
    }
}
