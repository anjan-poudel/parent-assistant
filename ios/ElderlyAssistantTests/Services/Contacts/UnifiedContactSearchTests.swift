import XCTest
@testable import ElderlyAssistant

/// Unit tests for the unified contact search (task 2026-09-06: one
/// search over the configured family contacts AND the system address
/// book). Pure logic only — fixture style mirrors
/// SystemContactSearchTests: plain struct literals, no CNContact.
///
/// Fixture cast: Sita (Latin name, Devanagari relationship) and Hari
/// (Latin name, English relationship, Messenger handle) as family
/// contacts; the address book holds the classic unlinked-duplicate
/// twins — "सीता शर्मा" sharing Sita's exact number — plus unrelated
/// people and a clinic.
///
/// family-contacts-unify T-152 (design-l1 §7.1/§8.1, design-l2 §1.6):
/// the search now takes a REQUIRED `FamilyContactIndex` and a
/// `verifiedLinks` snapshot. This suite pins the widened nickname tier
/// (Pass 1), the link-aware merge (Passes 3–5), the `.empty`-snapshot
/// parity anchor for unlinked pairs, the Devanagari grapheme pins
/// (NFR-FCU-007, positive AND negative) and the ≤ 20 ms ceiling at the
/// 12 × 8 production maximum (NFR-FCU-001).
final class UnifiedContactSearchTests: XCTestCase {

    // MARK: - Fixtures

    private let sita = FamilyContact(name: "Sita", phone: "+977 9841 000001",
                                     relationship: "छोरी")
    private let hari = FamilyContact(name: "Hari", phone: "9841 000002",
                                     relationship: "son",
                                     messengerHandle: "@hari.thapa")

    /// Sita's unlinked book twin — same person, same number, Devanagari
    /// name (the app-synced WhatsApp-copy shape).
    private let sitaTwin = AddressBookEntry(name: "सीता शर्मा", label: "mobile",
                                            phone: "+977 9841 000001",
                                            normalized: "9779841000001")
    /// A Latin "Sharma"-named row on its own number.
    private let sitaSharma = AddressBookEntry(name: "Sita Sharma", label: "mobile",
                                              phone: "9841 000003",
                                              normalized: "9841000003")
    private let gopal = AddressBookEntry(name: "Gopal Rai", label: "home",
                                         phone: "9841 000004",
                                         normalized: "9841000004")
    private let ram = AddressBookEntry(name: "Ram Thapa", label: "home",
                                       phone: "01-5552222",
                                       normalized: "015552222")
    private let clinic = AddressBookEntry(name: "पाटन अस्पताल", label: "main",
                                          phone: "01-4445555",
                                          normalized: "014445555")

    private var sitaNumber: String { ContactNumberKey.normalized(sita.phone) }
    private var hariNumber: String { ContactNumberKey.normalized(hari.phone) }

    private func makeFamily(name: String, phone: String, relationship: String,
                            nicknames: [String] = [],
                            messengerHandle: String? = nil,
                            systemContact: SystemContactLink? = nil) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: relationship,
                      messengerHandle: messengerHandle, nicknames: nicknames,
                      systemContact: systemContact)
    }

    private func makeEntry(_ name: String, phone: String,
                           label: String = "mobile",
                           identifier: String = "") -> AddressBookEntry {
        AddressBookEntry(name: name, label: label, phone: phone,
                         normalized: ContactNumberKey.normalized(phone),
                         identifier: identifier)
    }

    /// The index the search now REQUIRES (design-l2 §1.6: "Tests build
    /// `FamilyContactIndex(family:)` inline") — one per roster under
    /// test, never shared across different rosters.
    private func makeIndex(_ family: FamilyContact...) -> FamilyContactIndex {
        FamilyContactIndex(family: family)
    }

    /// A hand-built verified-links snapshot: family contact id → the
    /// record identifier that contact is verified to be. The search
    /// reads ONLY `links`; the number fingerprint and the link-aware
    /// number reach are T-149's surface, not this suite's.
    private func snapshot(_ links: [UUID: String],
                          generation: UInt64 = 1) -> VerifiedLinksSnapshot {
        VerifiedLinksSnapshot(
            links: links.mapValues { SystemContactLink(identifier: $0, numberKey: "") },
            linkedRecordNumbers: [:],
            generation: generation)
    }

    /// The linked-pair fixture FR-FCU-003 is about: the family phone
    /// normalizes to "9779841000001" while the book row's is
    /// "9841000001", so the NUMBER rule alone cannot tell they are one
    /// person — only the verified link can.
    private func linkedPair() -> (family: FamilyContact, bookRow: AddressBookEntry,
                                  links: VerifiedLinksSnapshot) {
        let family = makeFamily(name: "Sita", phone: "+977 9841 000001",
                                relationship: "छोरी",
                                systemContact: SystemContactLink(identifier: "rec-sita",
                                                                 numberKey: "9779841000001"))
        let row = AddressBookEntry(name: "सीता शर्मा", label: "mobile", phone: "9841 000001",
                                   normalized: "9841000001", identifier: "rec-sita")
        return (family, row, snapshot([family.id: "rec-sita"]))
    }

    /// Wall-clock duration of `body` in milliseconds, on the monotonic
    /// uptime clock (same idiom as `FamilyContactIndexTests`).
    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: - Matching tiers

    func testExactNameMatchIsCaseInsensitiveInBothScripts() {
        // "Sita" lowercased by the normalizer on both sides. Tier is
        // .exactName even though the query also containment-matches.
        for query in ["sita", "Sita", "SITA"] {
            let matches = UnifiedContactSearch.familyMatches(query: query, in: [sita, hari],
                                                             index: makeIndex(sita, hari))
            XCTAssertEqual(matches.map { $0.contact }, [sita])
            XCTAssertEqual(matches.first?.tier, .exactName)
        }
        // Devanagari has no case, but an exact Devanagari name still
        // matches exactly (NFC folds alternate byte spellings).
        let devanagari = makeFamily(name: "सीता", phone: "+977 9841 000001",
                                    relationship: "छोरी")
        let matches = UnifiedContactSearch.familyMatches(query: "सीता",
                                                         in: [devanagari, hari],
                                                         index: makeIndex(devanagari, hari))
        XCTAssertEqual(matches.map { $0.contact }, [devanagari])
        XCTAssertEqual(matches.first?.tier, .exactName)
    }

    func testRelationshipTierBridgesScriptsSynonymsAndCompounds() {
        // English query → Nepali-stored relationship ("daughter" ↔
        // "छोरी"), cross-script through the shared anchor table.
        let daughter = UnifiedContactSearch.familyMatches(query: "daughter",
                                                          in: [sita, hari],
                                                          index: makeIndex(sita, hari))
        XCTAssertEqual(daughter.map { $0.contact }, [sita])
        XCTAssertEqual(daughter.first?.tier, .relationship)

        // Reverse direction: Devanagari query → English-stored
        // relationship.
        let englishStored = makeFamily(name: "Sabina", phone: "9841000007",
                                       relationship: "daughter")
        let reverse = UnifiedContactSearch.familyMatches(query: "छोरी",
                                                         in: [englishStored],
                                                         index: makeIndex(englishStored))
        XCTAssertEqual(reverse.map { $0.contact }, [englishStored])
        XCTAssertEqual(reverse.first?.tier, .relationship)

        // Compound with the dative suffix — caught by the anchor's
        // containment pass ("मेरो छोरीलाई" = "my daughter").
        let compound = UnifiedContactSearch.familyMatches(query: "मेरो छोरीलाई",
                                                          in: [sita, hari],
                                                          index: makeIndex(sita, hari))
        XCTAssertEqual(compound.map { $0.contact }, [sita])
        XCTAssertEqual(compound.first?.tier, .relationship)

        // Synonyms that share NO substring: "बहिनी" and "दिदी" are both
        // "sister" — only the anchor table can bridge them.
        let didi = makeFamily(name: "Mina", phone: "9841000008", relationship: "दिदी")
        let sister = UnifiedContactSearch.familyMatches(query: "बहिनी",
                                                        in: [didi, hari],
                                                        index: makeIndex(didi, hari))
        XCTAssertEqual(sister.map { $0.contact }, [didi])
        XCTAssertEqual(sister.first?.tier, .relationship)

        // English → English anchor match.
        let son = UnifiedContactSearch.familyMatches(query: "son", in: [sita, hari],
                                                     index: makeIndex(sita, hari))
        XCTAssertEqual(son.map { $0.contact }, [hari])
        XCTAssertEqual(son.first?.tier, .relationship)
    }

    func testContainmentTierMatchesRawNameRelationshipAndPhone() {
        // Name substring, case-insensitive on the RAW name ("ari"
        // inside "Hari").
        let byName = UnifiedContactSearch.familyMatches(query: "ari", in: [sita, hari],
                                                        index: makeIndex(sita, hari))
        XCTAssertEqual(byName.map { $0.contact }, [hari])
        XCTAssertEqual(byName.first?.tier, .containment)

        // Relationship substring — but NOT a relationship-tier match:
        // "so" anchors to nothing, so only raw containment catches it.
        // (Latin here on purpose: Devanagari substrings stop at Swift
        // Character grapheme-cluster boundaries — "छोर" is [छो][र]
        // while "छोरी" is [छो][री], so the cluster sequence does not
        // occur; same rule as the book search, and the "keep typing"
        // hint covers the mid-word gap.)
        let byRelationship = UnifiedContactSearch.familyMatches(query: "so",
                                                                in: [sita, hari],
                                                                index: makeIndex(sita, hari))
        XCTAssertEqual(byRelationship.map { $0.contact }, [hari])
        XCTAssertEqual(byRelationship.first?.tier, .containment)

        // Pin the grapheme-cluster boundary: a Devanagari query one
        // vowel sign short of the stored relationship does NOT match
        // via containment — Swift Characters, not code points, are the
        // substring unit. Matching this would need scalar-aware search,
        // which the book search deliberately does not do either.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "छोर",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)

        // Digit run of the query inside the contact's dialable number.
        let byDigits = UnifiedContactSearch.familyMatches(query: "9841 000001",
                                                          in: [sita, hari],
                                                          index: makeIndex(sita, hari))
        XCTAssertEqual(byDigits.map { $0.contact }, [sita])
        XCTAssertEqual(byDigits.first?.tier, .containment)

        // A digit run nobody owns matches nobody.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "9841 999999",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)
    }

    func testContactsNotMatchingAreExcluded() {
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "विदेश",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "zzz",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)
    }

    func testEmptyOrWhitespaceQueryYieldsEmptyOutcome() {
        for blank in ["", "   ", "\n\t"] {
            let outcome = UnifiedContactSearch.search(query: blank,
                                                      family: [sita, hari],
                                                      index: makeIndex(sita, hari),
                                                      in: [sitaTwin, sitaSharma])
            XCTAssertTrue(outcome.entries.isEmpty)
            XCTAssertFalse(outcome.moreAvailable)
        }
        // A query nobody matches behaves the same way.
        let outcome = UnifiedContactSearch.search(query: "zzz", family: [sita, hari],
                                                  index: makeIndex(sita, hari),
                                                  in: [sitaTwin, sitaSharma])
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertFalse(outcome.moreAvailable)
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "  ", in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)
    }

    // MARK: - T-152: nickname tier (Pass 1)

    func testTierRawValuesPinTheQualityOrder() {
        // Unit-spec Gherkin "Nickname tier ordering": .exactName (0) <
        // .relationship (1) < .nickname (2) < .containment (3).
        XCTAssertEqual(UnifiedContactSearch.FamilyMatchTier.exactName.rawValue, 0)
        XCTAssertEqual(UnifiedContactSearch.FamilyMatchTier.relationship.rawValue, 1)
        XCTAssertEqual(UnifiedContactSearch.FamilyMatchTier.nickname.rawValue, 2)
        XCTAssertEqual(UnifiedContactSearch.FamilyMatchTier.containment.rawValue, 3)

        XCTAssertTrue(UnifiedContactSearch.FamilyMatchTier.exactName
                        < UnifiedContactSearch.FamilyMatchTier.relationship)
        XCTAssertTrue(UnifiedContactSearch.FamilyMatchTier.relationship
                        < UnifiedContactSearch.FamilyMatchTier.nickname)
        XCTAssertTrue(UnifiedContactSearch.FamilyMatchTier.nickname
                        < UnifiedContactSearch.FamilyMatchTier.containment)
    }

    func testNicknameExactMatchLandsInTheNicknameTier() {
        // FR-FCU-012 scenario 1: the query equals a stored nickname.
        // Both spellings are stored ("store as entered", OD-2) and each
        // answers its own script — the exact hit is the index's O(1) map.
        let kaki = makeFamily(name: "Kaki", phone: "9841 000020", relationship: "भाइ",
                              nicknames: ["सानु", "sanu"])
        let roster = [kaki]
        let index = FamilyContactIndex(family: roster)

        for query in ["सानु", "sanu"] {
            let matches = UnifiedContactSearch.familyMatches(query: query, in: roster, index: index)
            XCTAssertEqual(matches.map { $0.contact }, [kaki], "query \(query)")
            XCTAssertEqual(matches.first?.tier, .nickname, "query \(query)")
        }
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("सानु")),
                       [kaki.id], "the exact tier IS the index map hit")
    }

    func testNicknameSubstringMatchUsesTheSameCharacterSafeSemantics() {
        // FR-FCU-012 scenario 2: a partial query matches "under the same
        // substring semantics as name matching" — the haystack is the
        // PREcomputed normalized nickname, matched with the same
        // `range(of:options:)` call the name tier uses.
        let kaki = makeFamily(name: "Kaki", phone: "9841 000020", relationship: "भाइ",
                              nicknames: ["सानु", "saanu"])
        let roster = [kaki]
        let index = FamilyContactIndex(family: roster)

        let devanagari = UnifiedContactSearch.familyMatches(query: "सान", in: roster, index: index)
        XCTAssertEqual(devanagari.map { $0.contact }, [kaki])
        XCTAssertEqual(devanagari.first?.tier, .nickname)

        let latin = UnifiedContactSearch.familyMatches(query: "SAA", in: roster, index: index)
        XCTAssertEqual(latin.map { $0.contact }, [kaki])
        XCTAssertEqual(latin.first?.tier, .nickname)

        // Exact and substring both land in ONE tier: check order has no
        // ranking consequence by construction.
        let exact = UnifiedContactSearch.familyMatches(query: "सानु", in: roster, index: index)
        XCTAssertEqual(exact.first?.tier, .nickname)
        XCTAssertEqual(exact.first?.tier, devanagari.first?.tier)
    }

    func testNicknameQueriesDoNotCrossScripts() {
        // FR-FCU-012 failure path: no transliteration bridging — a
        // Romanized query does not match a Devanagari-only nickname.
        let devanagariOnly = makeFamily(name: "Kaki", phone: "9841 000020", relationship: "भाइ",
                                        nicknames: ["सानु"])
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "sanu", in: [devanagariOnly],
                                                         index: makeIndex(devanagariOnly)).isEmpty)
        // ... and the reverse: a Devanagari query against a
        // Romanized-only nickname.
        let romanOnly = makeFamily(name: "Kaki", phone: "9841 000021", relationship: "भाइ",
                                   nicknames: ["sanu"])
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "सानु", in: [romanOnly],
                                                         index: makeIndex(romanOnly)).isEmpty)
    }

    func testDevanagariNicknamePinsPositiveAndNegative() {
        // NFR-FCU-007, mirroring the index pins: a whole-word Devanagari
        // nickname matches (positive); a partial word one vowel sign
        // short does NOT — "छोर" is [छो][र] while "छोरी" is [छो][री], so
        // the cluster sequence does not occur. PINNED, not "fixed".
        let daughter = makeFamily(name: "Mina", phone: "9841 000021", relationship: "भाइ",
                                  nicknames: ["छोरी"])
        let roster = [daughter]
        let index = FamilyContactIndex(family: roster)

        let positive = UnifiedContactSearch.familyMatches(query: "छोरी", in: roster, index: index)
        XCTAssertEqual(positive.map { $0.contact }, [daughter])
        XCTAssertEqual(positive.first?.tier, .nickname)

        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "छोर", in: roster,
                                                         index: index).isEmpty,
                      "negative pin: the grapheme-splitting partial does not match")
        XCTAssertTrue(UnifiedContactSearch.search(query: "छोर", family: roster,
                                                  index: index, in: []).entries.isEmpty)
    }

    func testNicknameTierRanksBelowRelationshipAndAboveContainment() {
        // Unit-spec Gherkin "Nickname tier ordering": a nickname match
        // ranks below a relationship match and above containment — one
        // contact per tier, roster deliberately in a different order.
        let exactName = makeFamily(name: "छोरी", phone: "9841 000040", relationship: "भाइ")
        let byRelationship = makeFamily(name: "Maya", phone: "9841 000041", relationship: "छोरी")
        let byNickname = makeFamily(name: "Mina", phone: "9841 000042", relationship: "भाइ",
                                    nicknames: ["छोरी"])
        let byContainment = makeFamily(name: "छोरी कुमारी", phone: "9841 000043",
                                       relationship: "भाइ")
        let roster = [byContainment, byNickname, byRelationship, exactName]
        let index = FamilyContactIndex(family: roster)

        let matches = UnifiedContactSearch.familyMatches(query: "छोरी", in: roster, index: index)
        XCTAssertEqual(matches.map { $0.tier },
                       [.exactName, .relationship, .nickname, .containment])
        XCTAssertEqual(matches.map { $0.contact.name },
                       ["छोरी", "Maya", "Mina", "छोरी कुमारी"])

        // End to end: the ranking preserves the tier order.
        let outcome = UnifiedContactSearch.search(query: "छोरी", family: roster,
                                                  index: index, in: [])
        XCTAssertEqual(outcome.entries.map { $0.name },
                       ["छोरी", "Maya", "Mina", "छोरी कुमारी"])
    }

    // MARK: - Dedupe

    func testDedupeDropsBookTwinWhenTheFamilyContactMatched() {
        // A query matching Sita the FAMILY contact (digit run of her
        // number) and her book twin "सीता शर्मा" — same normalized
        // number, same person twice. Exactly one row survives: the
        // family one.
        let outcome = UnifiedContactSearch.search(query: "9841 000001",
                                                  family: [sita, hari],
                                                  index: makeIndex(sita, hari),
                                                  in: [sitaTwin, sitaSharma, clinic])
        XCTAssertEqual(outcome.entries, [.family(sita)])
        XCTAssertFalse(outcome.moreAvailable)

        // Same person in both scripts: a Devanagari family record and
        // its book twin share the number; the name query matches both,
        // and dedupe collapses to the family row.
        let devanagariTwin = makeFamily(name: "सीता शर्मा", phone: "+977 9841 000001",
                                        relationship: "छोरी")
        let devOutcome = UnifiedContactSearch.search(query: "सीता शर्मा",
                                                     family: [devanagariTwin],
                                                     index: makeIndex(devanagariTwin),
                                                     in: [sitaTwin, sitaSharma])
        XCTAssertEqual(devOutcome.entries, [.family(devanagariTwin)])

        // The pure seam itself: only rows sharing a MATCHED number go
        // away — a matched Hari leaves Sita's twin alone.
        XCTAssertEqual(UnifiedContactSearch.dedupe(matchedFamily: [sita],
                                                   in: [sitaTwin, sitaSharma]),
                       [sitaSharma])
        XCTAssertEqual(UnifiedContactSearch.dedupe(matchedFamily: [hari],
                                                   in: [sitaTwin]),
                       [sitaTwin])
    }

    func testDedupeScopingKeepsBookTwinWhenFamilyTwinDidNotMatch() {
        // "शर्मा" matches the book twin's family name; the family
        // record ("Sita" / "छोरी") does not — and Latin "Sharma" cannot
        // either, since the normalizer deliberately does not
        // transliterate. Dedupe is scoped to MATCHED family contacts,
        // so the twin stays: the person remains findable under the name
        // that matched.
        let devanagari = UnifiedContactSearch.search(query: "शर्मा",
                                                     family: [sita, hari],
                                                     index: makeIndex(sita, hari),
                                                     in: [sitaTwin, sitaSharma])
        XCTAssertEqual(devanagari.entries, [.addressBook(sitaTwin)])
        XCTAssertFalse(devanagari.moreAvailable)

        // Latin mirror: the family matches nothing for "Sharma", and
        // the book's own Sharma-named row answers alone.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "Sharma",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari)).isEmpty)
        let latin = UnifiedContactSearch.search(query: "Sharma",
                                                family: [sita, hari],
                                                index: makeIndex(sita, hari),
                                                in: [sitaTwin, sitaSharma])
        XCTAssertEqual(latin.entries, [.addressBook(sitaSharma)])
    }

    // MARK: - T-152: link merge, Passes 3–5

    func testLinkedPairYieldsOneRowForADigitQueryDespiteNumberSpellings() {
        // FR-FCU-003 scenario 3 + unit-spec "Linked system contact is
        // deduped into one row": an explicit link is identity evidence
        // independent of number spelling.
        let pair = linkedPair()
        let index = FamilyContactIndex(family: [pair.family])

        // Without the link this pair is today's behaviour exactly: the
        // differently spelled numbers defeat the number rule, so the
        // same person appears twice.
        let unlinked = UnifiedContactSearch.search(query: "9841 000001",
                                                   family: [pair.family], index: index,
                                                   in: [pair.bookRow])
        XCTAssertEqual(unlinked.entries,
                       [.family(pair.family), .addressBook(pair.bookRow)])

        // With the verified link (Pass 3) the book twin is dropped: one
        // row, and it is the family row.
        let linked = UnifiedContactSearch.search(query: "9841 000001",
                                                 family: [pair.family], index: index,
                                                 in: [pair.bookRow],
                                                 verifiedLinks: pair.links)
        XCTAssertEqual(linked.entries, [.family(pair.family)])
        XCTAssertFalse(linked.moreAvailable)
        XCTAssertTrue(linked.linkedBookNames.isEmpty,
                      "the family side matched — nothing was synthesized to explain")
    }

    func testBookSideOnlyMatchSynthesizesTheFamilyRowWithItsBookName() {
        // FR-FCU-003 scenario 2 + unit-spec Pass 3: the query matches
        // only the BOOK side ("शर्मा"); the linked family row is
        // synthesized (tier .containment) and the book row dropped —
        // one row, reachable by exactly what matched. The book name is
        // recorded under the row's OWN id so the row can explain the
        // name the user never typed.
        let pair = linkedPair()
        let index = FamilyContactIndex(family: [pair.family])

        let outcome = UnifiedContactSearch.search(query: "शर्मा",
                                                  family: [pair.family], index: index,
                                                  in: [pair.bookRow],
                                                  verifiedLinks: pair.links)
        XCTAssertEqual(outcome.entries, [.family(pair.family)])
        XCTAssertFalse(outcome.moreAvailable)

        let rowID = outcome.entries.first?.id
        XCTAssertEqual(rowID, "family-\(pair.family.id.uuidString)")
        XCTAssertEqual(rowID.flatMap { outcome.linkedBookNames[$0] }, "सीता शर्मा")
        XCTAssertEqual(outcome.linkedBookNames,
                       ["family-\(pair.family.id.uuidString)": "सीता शर्मा"])
    }

    func testSynthesizedCaptionIsSuppressedWhenTheNamesAlreadyAgree() {
        // The alt caption explains a name the user did NOT type into the
        // family record. When the book name already normalizes equal to
        // the family name there is nothing to explain — suppressed.
        let family = makeFamily(name: "Sita", phone: "01-5552222", relationship: "छोरी",
                                systemContact: SystemContactLink(identifier: "rec-sita",
                                                                 numberKey: "9841000001"))
        // The book row's number (9841 000001) is NOT contained in the
        // family's (015552222), so the query matches the book side only.
        let row = AddressBookEntry(name: "SITA", label: "mobile", phone: "9841 000001",
                                   normalized: "9841000001", identifier: "rec-sita")
        let index = FamilyContactIndex(family: [family])

        let outcome = UnifiedContactSearch.search(query: "9841 000001",
                                                  family: [family], index: index, in: [row],
                                                  verifiedLinks: snapshot([family.id: "rec-sita"]))
        XCTAssertEqual(outcome.entries, [.family(family)])
        XCTAssertTrue(outcome.linkedBookNames.isEmpty,
                      "'SITA' normalizes to the family name — no caption to show")
    }

    func testNicknameMatchedLinkedPairStillYieldsOneRow() {
        // FR-FCU-012's last bullet: a linked pair found via a NICKNAME
        // still yields exactly one row — the family row that matched.
        let family = makeFamily(name: "Mina", phone: "9841 000050", relationship: "बहिनी",
                                nicknames: ["sanu"],
                                systemContact: SystemContactLink(identifier: "rec-mina",
                                                                 numberKey: "9841000050"))
        let row = AddressBookEntry(name: "Sanu Thapa", label: "mobile", phone: "9841 000051",
                                   normalized: "9841000051", identifier: "rec-mina")
        let index = FamilyContactIndex(family: [family])

        // The nickname hit is the FAMILY tier (the family row matched) —
        // the linked book row must not double it.
        let matches = UnifiedContactSearch.familyMatches(query: "sanu", in: [family], index: index)
        XCTAssertEqual(matches.first?.tier, .nickname)

        let outcome = UnifiedContactSearch.search(query: "sanu", family: [family], index: index,
                                                  in: [row],
                                                  verifiedLinks: snapshot([family.id: "rec-mina"]))
        XCTAssertEqual(outcome.entries, [.family(family)])
        XCTAssertTrue(outcome.linkedBookNames.isEmpty)
    }

    func testOneRecordTwoNumbersSynthesizesOnce() {
        // One system record, two matched numbers: the family row is
        // synthesized ONCE (no double row for one person) and the first
        // book name in match order is the one recorded.
        let family = makeFamily(name: "Kamala", phone: "9841 000060", relationship: "बहिनी",
                                systemContact: SystemContactLink(identifier: "rec-kamala",
                                                                 numberKey: "9841000060"))
        let first = AddressBookEntry(name: "Maya Sharma", label: "mobile", phone: "9841 000061",
                                     normalized: "9841000061", identifier: "rec-kamala")
        let second = AddressBookEntry(name: "Maya Thapa", label: "home", phone: "9841 000062",
                                      normalized: "9841000062", identifier: "rec-kamala")
        let index = FamilyContactIndex(family: [family])

        let outcome = UnifiedContactSearch.search(query: "Maya", family: [family], index: index,
                                                  in: [first, second],
                                                  verifiedLinks: snapshot([family.id: "rec-kamala"]))
        XCTAssertEqual(outcome.entries, [.family(family)])
        XCTAssertEqual(outcome.linkedBookNames,
                       ["family-\(family.id.uuidString)": "Maya Sharma"])
        XCTAssertFalse(outcome.moreAvailable)
    }

    func testSynthesizedRowRanksAtContainmentBelowARelationshipMatch() {
        // The synthesized tier is `.containment`: it must not outrank a
        // real relationship match on the same query.
        let byRelationship = makeFamily(name: "Maya", phone: "9841 000070",
                                        relationship: "बहिनी")
        let linked = makeFamily(name: "Kamala", phone: "9841 000071", relationship: "दाइ",
                                systemContact: SystemContactLink(identifier: "rec-kamala",
                                                                 numberKey: "9841000071"))
        let row = AddressBookEntry(name: "बहिनी कमला", label: "mobile", phone: "9841 000072",
                                   normalized: "9841000072", identifier: "rec-kamala")
        let roster = [byRelationship, linked]
        let index = FamilyContactIndex(family: roster)

        // The linked contact itself does NOT match "बहिनी" (its
        // relationship is "दाइ" — the brother anchor) — only the book
        // row does, so this exercises the SYNTHESIS path.
        XCTAssertEqual(UnifiedContactSearch.familyMatches(query: "बहिनी", in: roster, index: index)
            .map { $0.contact.name }, ["Maya"])

        let outcome = UnifiedContactSearch.search(query: "बहिनी", family: roster, index: index,
                                                  in: [row],
                                                  verifiedLinks: snapshot([linked.id: "rec-kamala"]))
        XCTAssertEqual(outcome.entries.map { $0.name }, ["Maya", "Kamala"])
        XCTAssertEqual(outcome.linkedBookNames,
                       ["family-\(linked.id.uuidString)": "बहिनी कमला"])
    }

    func testRecountHappensAfterTheLinkMerge() {
        // Pass 5 (FR-FCU-003 scenario 4): dropping a linked twin can
        // turn moreAvailable false — the recount is over the POST-pass
        // rows, before the limit slice.
        let family = makeFamily(name: "Sita", phone: "+977 9841 000001",
                                relationship: "छोरी",
                                systemContact: SystemContactLink(identifier: "rec-sharma",
                                                                 numberKey: "9841000003"))
        let row = AddressBookEntry(name: "Sita Sharma", label: "mobile", phone: "9841 000003",
                                   normalized: "9841000003", identifier: "rec-sharma")
        let index = FamilyContactIndex(family: [family])

        let unlinked = UnifiedContactSearch.search(query: "sita", family: [family],
                                                   index: index, in: [row], limit: 1)
        XCTAssertEqual(unlinked.entries, [.family(family)])
        XCTAssertTrue(unlinked.moreAvailable,
                      "without the link the book row is a second matched person")

        let linked = UnifiedContactSearch.search(query: "sita", family: [family],
                                                 index: index, in: [row],
                                                 verifiedLinks: snapshot([family.id: "rec-sharma"]),
                                                 limit: 1)
        XCTAssertEqual(linked.entries, [.family(family)])
        XCTAssertFalse(linked.moreAvailable,
                       "the twin was dropped BEFORE the recount (Pass 5)")
    }

    func testSynthesizedRowsCountTowardMoreAvailable() {
        // Pass 5 counts synthesized rows too: three matched people —
        // two linked (synthesized) and one plain book row.
        let kamala = makeFamily(name: "Kamala", phone: "9841 000080", relationship: "बहिनी",
                                systemContact: SystemContactLink(identifier: "rec-kamala",
                                                                 numberKey: "9841000080"))
        let sabina = makeFamily(name: "Sabina", phone: "9841 000081", relationship: "दाइ",
                                systemContact: SystemContactLink(identifier: "rec-sabina",
                                                                 numberKey: "9841000081"))
        let roster = [kamala, sabina]
        let index = FamilyContactIndex(family: roster)
        let rows = [makeEntry("Kamala Sharma", phone: "9841 000082", identifier: "rec-kamala"),
                    makeEntry("Sabina Sharma", phone: "9841 000083", identifier: "rec-sabina"),
                    makeEntry("Gopal Sharma", phone: "9841 000084")]
        let links = snapshot([kamala.id: "rec-kamala", sabina.id: "rec-sabina"])

        let capped = UnifiedContactSearch.search(query: "Sharma", family: roster, index: index,
                                                 in: rows, verifiedLinks: links, limit: 2)
        XCTAssertEqual(capped.entries.map { $0.name }, ["Kamala", "Sabina"])
        XCTAssertTrue(capped.moreAvailable, "three people matched, two shown")

        let full = UnifiedContactSearch.search(query: "Sharma", family: roster, index: index,
                                               in: rows, verifiedLinks: links, limit: 3)
        XCTAssertEqual(full.entries.map { $0.name }, ["Kamala", "Sabina", "Gopal Sharma"])
        XCTAssertFalse(full.moreAvailable)
        XCTAssertEqual(full.linkedBookNames,
                       ["family-\(kamala.id.uuidString)": "Kamala Sharma",
                        "family-\(sabina.id.uuidString)": "Sabina Sharma"])
    }

    // MARK: - T-152: failure paths

    func testStaleStoredLinkNeverMergesRecords() {
        // Unit-spec failure path "Stale link during dedupe": a link
        // present in the search input (stored on the contact) but
        // ABSENT from the verified snapshot merges nothing — the two
        // records stay two records — and the count is recounted
        // honestly.
        let claimed = makeFamily(name: "Sabina", phone: "9841 000007",
                                 relationship: "बहिनी",
                                 systemContact: SystemContactLink(identifier: "rec-sabina",
                                                                  numberKey: "9841000007"))
        let row = AddressBookEntry(name: "Sabina Thapa", label: "mobile", phone: "9841 000007",
                                   normalized: "9841000007", identifier: "rec-sabina")
        let index = FamilyContactIndex(family: [claimed])

        // Query "Thapa" matches the book side only.
        let stale = UnifiedContactSearch.search(query: "Thapa", family: [claimed],
                                                index: index, in: [row], limit: 1)
        XCTAssertEqual(stale.entries, [.addressBook(row)])
        XCTAssertTrue(stale.linkedBookNames.isEmpty)
        XCTAssertFalse(stale.moreAvailable, "one row, one slot — nothing hidden")

        // Verified, the same link DOES merge: the pair becomes the
        // family row, with the book name recorded.
        let verified = UnifiedContactSearch.search(query: "Thapa", family: [claimed],
                                                   index: index, in: [row],
                                                   verifiedLinks: snapshot([claimed.id: "rec-sabina"]),
                                                   limit: 1)
        XCTAssertEqual(verified.entries, [.family(claimed)])
        XCTAssertEqual(verified.linkedBookNames,
                       ["family-\(claimed.id.uuidString)": "Sabina Thapa"])
        XCTAssertFalse(verified.moreAvailable)
    }

    func testLinkWhoseFamilyContactIsGoneKeepsTheBookRow() {
        // Defensive half of "Linked record disappears from the book
        // between passes": a verified link whose family contact is NOT
        // in this roster (the roster shrank after the snapshot
        // published) must not drop the row — a row is never dropped
        // without a replacement carrying the person (no phantom drop),
        // and the recount stays honest.
        let goneID = UUID()
        let row = makeEntry("Gone Gurung", phone: "9841 000090", identifier: "rec-gone")

        let outcome = UnifiedContactSearch.search(query: "Gurung", family: [], index: .empty,
                                                  in: [row],
                                                  verifiedLinks: snapshot([goneID: "rec-gone"],
                                                                          generation: 2))
        XCTAssertEqual(outcome.entries, [.addressBook(row)])
        XCTAssertTrue(outcome.linkedBookNames.isEmpty)
        XCTAssertFalse(outcome.moreAvailable)

        // The literal scenario — the record's row is simply gone from
        // the book this pass — is equally safe: nothing to drop, no
        // crash, and the family contact that DOES match answers alone.
        let linked = makeFamily(name: "Sabina", phone: "9841 000091",
                                relationship: "बहिनी",
                                systemContact: SystemContactLink(identifier: "rec-sabina",
                                                                 numberKey: "9841000091"))
        let recordGone = UnifiedContactSearch.search(query: "Sabina", family: [linked],
                                                     index: makeIndex(linked), in: [],
                                                     verifiedLinks: snapshot([linked.id: "rec-sabina"]))
        XCTAssertEqual(recordGone.entries, [.family(linked)])
        XCTAssertTrue(recordGone.linkedBookNames.isEmpty)
    }

    func testRowWithoutALiveRecordIsNeverALinkTarget() {
        // An entry with an EMPTY identifier was not built from a live
        // record (test fixtures, `make`'s default) — it can never be a
        // link target, so a verified link on the family contact cannot
        // drop it.
        let family = makeFamily(name: "Sita", phone: "+977 9841 000001",
                                relationship: "छोरी",
                                systemContact: SystemContactLink(identifier: "rec-sita",
                                                                 numberKey: "9779841000001"))
        let index = FamilyContactIndex(family: [family])

        let outcome = UnifiedContactSearch.search(query: "शर्मा", family: [family],
                                                  index: index, in: [sitaTwin],
                                                  verifiedLinks: snapshot([family.id: "rec-sita"]))
        XCTAssertEqual(outcome.entries, [.addressBook(sitaTwin)],
                       "the twin carries no identifier — it is not the linked record")
        XCTAssertTrue(outcome.linkedBookNames.isEmpty)
    }

    func testAmbiguousNicknameShowsBothClaimsNeverOneCollapsedRow() {
        // Unit-spec failure path "Ambiguous nickname — never the wrong
        // person" (FR-FCU-014): two distinct people both answering to
        // "Buba". The search LIST shows both claimants distinctly; no
        // dedupe pass merges two different people into one row, and no
        // row attributes one person's identity to the other.
        let aama = makeFamily(name: "Aama", phone: "9841 000100", relationship: "बहिनी",
                              nicknames: ["Buba"])
        let kaka = makeFamily(name: "Kaka", phone: "9841 000101", relationship: "दाइ",
                              nicknames: ["buba"])
        let roster = [aama, kaka]
        let index = FamilyContactIndex(family: roster)
        // A third, unrelated book claimant — no links anywhere.
        let bookRow = makeEntry("Buba Bahadur", phone: "9841 000102")

        let matches = UnifiedContactSearch.familyMatches(query: "Buba", in: roster, index: index)
        XCTAssertEqual(matches.map { $0.tier }, [.nickname, .nickname])
        XCTAssertEqual(matches.map { $0.contact }, [aama, kaka])

        let outcome = UnifiedContactSearch.search(query: "Buba", family: roster,
                                                  index: index, in: [bookRow])
        XCTAssertEqual(outcome.entries.map { $0.name }, ["Aama", "Kaka", "Buba Bahadur"])
        XCTAssertEqual(Set(outcome.entries.map { $0.id }).count, 3,
                       "three distinct people, three distinct row ids — nothing collapsed")
        XCTAssertTrue(outcome.linkedBookNames.isEmpty)

        // Deterministic: identical inputs produce an identical outcome.
        XCTAssertEqual(outcome,
                       UnifiedContactSearch.search(query: "Buba", family: roster,
                                                   index: index, in: [bookRow]))
    }

    // MARK: - T-152: unlinked parity (the `.empty` anchor)

    func testEmptySnapshotIsTheUnlinkedParityAnchor() {
        // Unit-spec Gherkin "Unlinked search results are unchanged":
        // with no verified links the same queries return the same rows,
        // order and recency behaviour as before the feature. `.empty`
        // IS that anchor — the defaulted argument and the explicit
        // `.empty` must agree on every query, and `linkedBookNames`
        // must stay empty (no synthesized row exists to explain).
        let roster = [sita, hari]
        let index = FamilyContactIndex(family: roster)
        let book = [sitaTwin, sitaSharma, gopal]
        let now = Date()
        let recency = [sitaNumber: now,
                       gopal.normalized: now.addingTimeInterval(-3600),
                       sitaSharma.normalized: now.addingTimeInterval(-7200)]

        for query in ["sita", "9841 00000", "Sharma", "छोरी", "   ", "zzz"] {
            let explicit = UnifiedContactSearch.search(query: query, family: roster,
                                                       index: index, in: book,
                                                       verifiedLinks: .empty,
                                                       recency: recency)
            let defaulted = UnifiedContactSearch.search(query: query, family: roster,
                                                        index: index, in: book,
                                                        recency: recency)
            XCTAssertEqual(explicit, defaulted, "query \(query): the default IS `.empty`")
            XCTAssertTrue(explicit.linkedBookNames.isEmpty,
                          "query \(query): an unlinked search synthesizes nothing")
        }

        // Hand-computed anchor for the digit query under today's
        // algorithm: both family contacts match by digits, Sita's twin
        // is number-deduped (matched family number), the survivors keep
        // SystemContactSearch's recency order, family first, and the
        // recount sees the whole matched union (4 > limit 4 is false).
        let digitAnchor = UnifiedContactSearch.search(query: "9841 00000", family: roster,
                                                      index: index, in: book,
                                                      recency: recency, limit: 4)
        XCTAssertEqual(digitAnchor.entries,
                       [.family(sita), .family(hari),
                        .addressBook(gopal), .addressBook(sitaSharma)])
        XCTAssertFalse(digitAnchor.moreAvailable)

        // And the name query's anchor (existing behaviour, unchanged).
        let nameAnchor = UnifiedContactSearch.search(query: "sita", family: roster,
                                                     index: index, in: book,
                                                     recency: recency)
        XCTAssertEqual(nameAnchor.entries, [.family(sita), .addressBook(sitaSharma)])
        XCTAssertFalse(nameAnchor.moreAvailable)
    }

    // MARK: - T-152: performance ceiling (NFR-FCU-001)

    func testNicknameSearchStaysUnderTheTwentyMillisecondCeiling() {
        // Unit-spec Gherkin "Search performance and Devanagari pins":
        // 12 contacts × 8 nicknames, nickname query, search returns
        // within the ≤ 20 ms ceiling. Worst measured call asserted, not
        // an average (the F5 discipline); durations only, never fixture
        // text, are printed.
        var family: [FamilyContact] = []
        for i in 0..<12 {
            let nicknames = (0..<8).map { j in
                j.isMultiple(of: 2) ? "nickname-\(i)-\(j)" : "उपनाम-\(i)-\(j)"
            }
            family.append(makeFamily(name: "Contact \(i)",
                                     phone: String(format: "9841%04d", i),
                                     relationship: "छोरा",
                                     nicknames: nicknames))
        }
        let index = FamilyContactIndex(family: family)
        let book = [sitaTwin, sitaSharma, gopal, clinic, ram]

        var worst = 0.0
        for query in ["nickname-3-4", "उपनाम-7-1", "nickname"] {
            for _ in 0..<10 {
                worst = max(worst, milliseconds {
                    _ = UnifiedContactSearch.search(query: query, family: family,
                                                    index: index, in: book)
                })
            }
        }
        print("[T-152] worst unified search over a 12x8 roster: \(worst) ms")
        XCTAssertLessThanOrEqual(worst, 20.0)
    }

    // MARK: - Ranking

    func testRankPutsFamilyFirstEvenWhenTheBookRowWasCalledMoreRecently() {
        // "sita" matches family Sita exactly and book "Sita Sharma" by
        // substring. The BOOK number was dialed most recently, yet the
        // family row leads: family is the configured surface, the book
        // is the long tail.
        let now = Date()
        let recency = [sitaNumber: now.addingTimeInterval(-3600),
                       sitaSharma.normalized: now]
        let outcome = UnifiedContactSearch.search(query: "sita",
                                                  family: [sita, hari],
                                                  index: makeIndex(sita, hari),
                                                  in: [sitaTwin, sitaSharma, clinic],
                                                  recency: recency)
        XCTAssertEqual(outcome.entries, [.family(sita), .addressBook(sitaSharma)])
        XCTAssertFalse(outcome.moreAvailable)
    }

    func testRankOrdersFamilyTiersBestFirstBeforeRecency() {
        // Four contacts all answering query "छोरी", one per meaningful
        // tier split: exact name, relationship word, and two raw
        // containment hits. The exactName contact "छोरी" is the person
        // whose NAME is the word; माया matches through her stored
        // relationship; the two "छोरी …" names contain the word.
        let exact = makeFamily(name: "छोरी", phone: "9841 000006", relationship: "भाइ")
        let byRelationship = makeFamily(name: "माया", phone: "9841 000007",
                                        relationship: "छोरी")
        let kumari = makeFamily(name: "छोरी कुमारी", phone: "9841 000008",
                                relationship: "भाइ")
        let maya = makeFamily(name: "छोरी माया", phone: "9841 000009",
                              relationship: "भाइ")
        let roster = [exact, byRelationship, kumari, maya]
        let index = FamilyContactIndex(family: roster)
        let now = Date()

        // The containment-tier contact was dialed just now — freshest of
        // all four — yet still ranks after the exact-name and
        // relationship contacts: tier first, recency only INSIDE a tier.
        let outcome = UnifiedContactSearch.search(query: "छोरी",
                                                  family: roster,
                                                  index: index,
                                                  in: [],
                                                  recency: ["9841000009": now,
                                                            "9841000008": now.addingTimeInterval(-3600)])
        XCTAssertEqual(outcome.entries.map { $0.name },
                       ["छोरी", "माया", "छोरी माया", "छोरी कुमारी"])

        // Recency flipped within the containment tier reorders only it.
        let flipped = UnifiedContactSearch.search(query: "छोरी",
                                                  family: roster,
                                                  index: index,
                                                  in: [],
                                                  recency: ["9841000008": now,
                                                            "9841000009": now.addingTimeInterval(-3600)])
        XCTAssertEqual(flipped.entries.map { $0.name },
                       ["छोरी", "माया", "छोरी कुमारी", "छोरी माया"])
    }

    func testBookHalfKeepsSystemRankingOrderWithFamilyPresent() {
        // Query "9841 00000" matches both family contacts (digit run of
        // their numbers), the twin (deduped — same number as matched
        // Sita), and two more book rows. The book suffix after the
        // family rows must be exactly what SystemContactSearch.rank
        // produces for the surviving rows.
        let now = Date()
        let recency = [gopal.normalized: now, sitaNumber: now]
        let outcome = UnifiedContactSearch.search(query: "9841 00000",
                                                  family: [sita, hari],
                                                  index: makeIndex(sita, hari),
                                                  in: [sitaTwin, sitaSharma, gopal],
                                                  recency: recency)
        XCTAssertEqual(outcome.entries,
                       [.family(sita), .family(hari),
                        .addressBook(gopal), .addressBook(sitaSharma)])
        let expectedBookSuffix = SystemContactSearch
            .rank([sitaSharma, gopal], by: recency)
            .map { UnifiedContactSearch.Result.addressBook($0) }
        XCTAssertEqual(Array(outcome.entries.dropFirst(2)), expectedBookSuffix)
    }

    func testFamilyRankTiebreakMatchesSystemRecencySemantics() {
        // Both contacts match at the same (.containment) tier via the
        // shared digit run of their numbers. Within a tier the order is
        // most-recently-called first, and never-called falls back to
        // name — the same nil handling SystemContactSearch.rank applies
        // to book rows.
        let matches = UnifiedContactSearch.familyMatches(query: "9841 00000",
                                                         in: [sita, hari],
                                                         index: makeIndex(sita, hari))
        XCTAssertEqual(matches.map { $0.tier }, [.containment, .containment])

        let now = Date()
        let bySita = UnifiedContactSearch.search(query: "9841 00000",
                                                 family: [sita, hari],
                                                 index: makeIndex(sita, hari), in: [],
                                                 recency: [sitaNumber: now])
        XCTAssertEqual(bySita.entries.map { $0.name }, ["Sita", "Hari"])

        let byHari = UnifiedContactSearch.search(query: "9841 00000",
                                                 family: [sita, hari],
                                                 index: makeIndex(sita, hari), in: [],
                                                 recency: [hariNumber: now])
        XCTAssertEqual(byHari.entries.map { $0.name }, ["Hari", "Sita"])

        let neverCalled = UnifiedContactSearch.search(query: "9841 00000",
                                                      family: [sita, hari],
                                                      index: makeIndex(sita, hari), in: [])
        XCTAssertEqual(neverCalled.entries.map { $0.name }, ["Hari", "Sita"])
    }

    // MARK: - Truncation

    func testSearchCapsAcrossTheUnionAndReportsTruncation() {
        // The store caps family contacts at three, but the search is
        // pure over whatever list it is given — a wide list exercises
        // the cap across BOTH sources.
        var family: [FamilyContact] = []
        var book: [AddressBookEntry] = []
        for i in 0..<25 {
            family.append(makeFamily(name: String(format: "आफन्त %02d", i),
                                     phone: String(format: "9841%04d", i),
                                     relationship: "आफन्त"))
            book.append(makeEntry(String(format: "आफन्त बुक %02d", i),
                                  phone: String(format: "9860%04d", i)))
        }
        let index = FamilyContactIndex(family: family)
        let outcome = UnifiedContactSearch.search(query: "आफन्त",
                                                  family: family, index: index, in: book,
                                                  limit: 5)
        XCTAssertEqual(outcome.entries.count, 5)
        // The cap applies to the RANKED UNION — family leads, so the
        // shown rows are all family, and truncation is reported against
        // the whole matched union, not the shown prefix.
        XCTAssertEqual(outcome.entries.first?.name, "आफन्त 00")
        XCTAssertTrue(outcome.moreAvailable)

        // At exactly the limit nothing is hidden: matched 5 = limit 5.
        let exact = UnifiedContactSearch.search(query: "आफन्त",
                                                family: Array(family.prefix(3)),
                                                index: FamilyContactIndex(family: Array(family.prefix(3))),
                                                in: Array(book.prefix(2)),
                                                limit: 5)
        XCTAssertEqual(exact.entries.count, 5)
        XCTAssertFalse(exact.moreAvailable)
    }

    // MARK: - System-contacts parity

    func testEmptyFamilySearchIsIdenticalToSystemContactSearch() {
        // Regression guard: with no family contacts the union must be a
        // byte-identical wrapper over the system search — same rows,
        // same order, same truncation flag.
        let book = [sitaTwin, sitaSharma, gopal, clinic, ram]
        let recency = [sitaSharma.normalized: Date(),
                       sitaTwin.normalized: Date().addingTimeInterval(-60)]
        let digitOutcome = UnifiedContactSearch.search(query: "9841 00000",
                                                       family: [], index: .empty, in: book,
                                                       recency: recency, limit: 2)
        let systemDigit = SystemContactSearch.search(query: "9841 00000", in: book,
                                                     recency: recency, limit: 2)
        XCTAssertEqual(digitOutcome.entries,
                       systemDigit.entries.map { UnifiedContactSearch.Result.addressBook($0) })
        XCTAssertEqual(digitOutcome.moreAvailable, systemDigit.moreAvailable)
        // Three rows matched "9841 00000" (the two Sharmas + Gopal);
        // the cap shows two and the flag says so.
        XCTAssertTrue(digitOutcome.moreAvailable)

        let nameOutcome = UnifiedContactSearch.search(query: "सीता", family: [], index: .empty,
                                                      in: book)
        let systemName = SystemContactSearch.search(query: "सीता", in: book)
        XCTAssertEqual(nameOutcome.entries,
                       systemName.entries.map { UnifiedContactSearch.Result.addressBook($0) })
        XCTAssertEqual(nameOutcome.moreAvailable, systemName.moreAvailable)

        // With verified links but an EMPTY roster there is nothing to
        // link: the book half is untouched (the merge can only act on
        // a family contact the roster actually holds).
        let orphanLinks = snapshot([UUID(): "rec-nobody"], generation: 4)
        let linkedOutcome = UnifiedContactSearch.search(query: "9841 00000",
                                                        family: [], index: .empty, in: book,
                                                        verifiedLinks: orphanLinks,
                                                        recency: recency, limit: 2)
        XCTAssertEqual(linkedOutcome.entries, systemDigit.entries.map {
            UnifiedContactSearch.Result.addressBook($0)
        })
        XCTAssertTrue(linkedOutcome.linkedBookNames.isEmpty)
    }

    // MARK: - Result rows

    func testAvailabilityBadgesReflectLinkBuildabilityNotPlatformPresence() {
        // Book row WITHOUT Facebook linkage (the twin fixture carries
        // none): its dialable phone shapes the WhatsApp link — a phone
        // number IS WhatsApp's official chat identity — but NEVER a
        // Messenger surface (messenger-gate 2026-09-07, user direction:
        // Messenger has no phone-number thread link, so the phone-based
        // chat attempt is gone and a bare number earns no Messenger
        // pill). `messengerHandle` stays nil and the badge stays off.
        let bookOutcome = UnifiedContactSearch.search(query: "शर्मा", family: [],
                                                      index: .empty, in: [sitaTwin, sitaSharma])
        guard let bookRow = bookOutcome.entries.first,
              case .addressBook(let twin) = bookRow else {
            XCTFail("expected the book twin row")
            return
        }
        XCTAssertEqual(twin.name, "सीता शर्मा")
        XCTAssertTrue(bookRow.whatsAppAvailable)
        XCTAssertFalse(bookRow.messengerAvailable)
        XCTAssertNil(bookRow.messengerHandle)

        // Family rows: WhatsApp needs dialable digits; Messenger needs
        // a handle in Messenger's own username alphabet.
        let sitaOutcome = UnifiedContactSearch.search(query: "sita",
                                                      family: [sita, hari],
                                                      index: makeIndex(sita, hari), in: [])
        guard let sitaRow = sitaOutcome.entries.first,
              case .family(let sitaContact) = sitaRow else {
            XCTFail("expected Sita")
            return
        }
        XCTAssertEqual(sitaContact.phone, "+977 9841 000001")
        XCTAssertTrue(sitaRow.whatsAppAvailable)
        XCTAssertFalse(sitaRow.messengerAvailable)   // no handle stored

        let hariOutcome = UnifiedContactSearch.search(query: "hari",
                                                      family: [sita, hari],
                                                      index: makeIndex(sita, hari), in: [])
        guard let hariRow = hariOutcome.entries.first,
              case .family(let hariContact) = hariRow else {
            XCTFail("expected Hari")
            return
        }
        XCTAssertTrue(hariRow.whatsAppAvailable)
        XCTAssertTrue(hariRow.messengerAvailable)   // "@hari.thapa" is real

        // A Devanagari "handle" is outside Messenger's ASCII username
        // alphabet — the link would be unbuildable, so the badge is
        // off.
        let devanagariHandle = makeFamily(name: "सीता कुमारी", phone: "+977 9841 000005",
                                          relationship: "छोरी",
                                          messengerHandle: "सीता")
        let devOutcome = UnifiedContactSearch.search(query: "सीता कुमारी",
                                                     family: [devanagariHandle],
                                                     index: makeIndex(devanagariHandle), in: [])
        guard let devRow = devOutcome.entries.first,
              case .family(let devContact) = devRow else {
            XCTFail("expected the Devanagari-handle contact")
            return
        }
        XCTAssertTrue(devRow.whatsAppAvailable)
        XCTAssertFalse(devRow.messengerAvailable)

        // A phone with no ASCII digits can shape no WhatsApp link at
        // all — but the row itself still exists and dials by name.
        let noDigits = makeFamily(name: "Bua", phone: "मोबाइल", relationship: "आमा")
        let noDigitsOutcome = UnifiedContactSearch.search(query: "bua",
                                                          family: [noDigits],
                                                          index: makeIndex(noDigits), in: [])
        guard let noDigitsRow = noDigitsOutcome.entries.first,
              case .family(let noDigitsContact) = noDigitsRow else {
            XCTFail("expected Bua")
            return
        }
        XCTAssertEqual(noDigitsContact.phone, "मोबाइल")
        XCTAssertFalse(noDigitsRow.whatsAppAvailable)
        XCTAssertFalse(noDigitsRow.messengerAvailable)
    }

    func testMessengerBadgeForLinkedBookRows() {
        // A book row whose record carries derived Facebook linkage —
        // the row shape `AddressBookEntry.make` now produces for a
        // Facebook-synced person (handle pre-normalized at derivation
        // time, exactly what `allEntries` hands the search) — earns
        // the Messenger pill: a link CAN be built from that handle.
        // This is availability from a real stored handle, never a
        // claim that the person is on Messenger.
        let linked = AddressBookEntry(name: "Maya Gurung", label: "mobile",
                                      phone: "9841 000010",
                                      normalized: "9841000010",
                                      messengerHandle: "maya.gurung")
        let outcome = UnifiedContactSearch.search(query: "maya", family: [],
                                                  index: .empty, in: [sitaSharma, linked])
        XCTAssertEqual(outcome.entries, [.addressBook(linked)])
        guard let row = outcome.entries.first else {
            XCTFail("expected Maya's row")
            return
        }
        XCTAssertTrue(row.whatsAppAvailable)
        XCTAssertTrue(row.messengerAvailable)
        XCTAssertEqual(row.messengerHandle, "maya.gurung")

        // The linkage-free neighbor in the same book earns NO Messenger
        // pill (messenger-gate 2026-09-07): a phone alone is not a
        // Messenger identity, and the phone-based chat attempt is gone
        // for book rows. Its handle stays nil.
        let plain = UnifiedContactSearch.Result.addressBook(sitaSharma)
        XCTAssertFalse(plain.messengerAvailable)
        XCTAssertNil(plain.messengerHandle)
    }

    func testResultIdentifiersAndLabelsStaySourceSpecific() {
        let outcome = UnifiedContactSearch.search(query: "sita",
                                                  family: [sita, hari],
                                                  index: makeIndex(sita, hari),
                                                  in: [sitaTwin, sitaSharma, clinic])
        XCTAssertEqual(outcome.entries.count, 2)
        guard outcome.entries.count == 2 else { return }
        let familyRow = outcome.entries[0]
        let bookRow = outcome.entries[1]
        XCTAssertEqual(familyRow, .family(sita))
        XCTAssertEqual(bookRow, .addressBook(sitaSharma))

        // id: family rows key on "family-" + UUID, book rows on the
        // normalized number — disjoint namespaces that can never
        // collide inside a ForEach.
        XCTAssertEqual(familyRow.id, "family-\(sita.id.uuidString)")
        XCTAssertEqual(bookRow.id, sitaSharma.normalized)
        XCTAssertNotEqual(familyRow.id, bookRow.id)

        // name / caption / phone mapping per source.
        XCTAssertEqual(familyRow.name, "Sita")
        XCTAssertEqual(familyRow.caption, "छोरी")
        XCTAssertEqual(familyRow.phone, "+977 9841 000001")
        XCTAssertEqual(bookRow.name, "Sita Sharma")
        XCTAssertEqual(bookRow.caption, "mobile 9841 000003")
        XCTAssertEqual(bookRow.phone, "9841 000003")
        XCTAssertNil(bookRow.messengerHandle)
    }
}
