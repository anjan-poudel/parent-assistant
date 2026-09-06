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
                            messengerHandle: String? = nil) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: relationship,
                      messengerHandle: messengerHandle)
    }

    private func makeEntry(_ name: String, phone: String,
                           label: String = "mobile") -> AddressBookEntry {
        AddressBookEntry(name: name, label: label, phone: phone,
                         normalized: ContactNumberKey.normalized(phone))
    }

    // MARK: - Matching tiers

    func testExactNameMatchIsCaseInsensitiveInBothScripts() {
        // "Sita" lowercased by the normalizer on both sides. Tier is
        // .exactName even though the query also containment-matches.
        for query in ["sita", "Sita", "SITA"] {
            let matches = UnifiedContactSearch.familyMatches(query: query, in: [sita, hari])
            XCTAssertEqual(matches.map { $0.contact }, [sita])
            XCTAssertEqual(matches.first?.tier, .exactName)
        }
        // Devanagari has no case, but an exact Devanagari name still
        // matches exactly (NFC folds alternate byte spellings).
        let devanagari = makeFamily(name: "सीता", phone: "+977 9841 000001",
                                    relationship: "छोरी")
        let matches = UnifiedContactSearch.familyMatches(query: "सीता",
                                                         in: [devanagari, hari])
        XCTAssertEqual(matches.map { $0.contact }, [devanagari])
        XCTAssertEqual(matches.first?.tier, .exactName)
    }

    func testRelationshipTierBridgesScriptsSynonymsAndCompounds() {
        // English query → Nepali-stored relationship ("daughter" ↔
        // "छोरी"), cross-script through the shared anchor table.
        let daughter = UnifiedContactSearch.familyMatches(query: "daughter",
                                                          in: [sita, hari])
        XCTAssertEqual(daughter.map { $0.contact }, [sita])
        XCTAssertEqual(daughter.first?.tier, .relationship)

        // Reverse direction: Devanagari query → English-stored
        // relationship.
        let englishStored = makeFamily(name: "Sabina", phone: "9841000007",
                                       relationship: "daughter")
        let reverse = UnifiedContactSearch.familyMatches(query: "छोरी",
                                                         in: [englishStored])
        XCTAssertEqual(reverse.map { $0.contact }, [englishStored])
        XCTAssertEqual(reverse.first?.tier, .relationship)

        // Compound with the dative suffix — caught by the anchor's
        // containment pass ("मेरो छोरीलाई" = "my daughter").
        let compound = UnifiedContactSearch.familyMatches(query: "मेरो छोरीलाई",
                                                          in: [sita, hari])
        XCTAssertEqual(compound.map { $0.contact }, [sita])
        XCTAssertEqual(compound.first?.tier, .relationship)

        // Synonyms that share NO substring: "बहिनी" and "दिदी" are both
        // "sister" — only the anchor table can bridge them.
        let didi = makeFamily(name: "Mina", phone: "9841000008", relationship: "दिदी")
        let sister = UnifiedContactSearch.familyMatches(query: "बहिनी",
                                                        in: [didi, hari])
        XCTAssertEqual(sister.map { $0.contact }, [didi])
        XCTAssertEqual(sister.first?.tier, .relationship)

        // English → English anchor match.
        let son = UnifiedContactSearch.familyMatches(query: "son", in: [sita, hari])
        XCTAssertEqual(son.map { $0.contact }, [hari])
        XCTAssertEqual(son.first?.tier, .relationship)
    }

    func testContainmentTierMatchesRawNameRelationshipAndPhone() {
        // Name substring, case-insensitive on the RAW name ("ari"
        // inside "Hari").
        let byName = UnifiedContactSearch.familyMatches(query: "ari", in: [sita, hari])
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
                                                                in: [sita, hari])
        XCTAssertEqual(byRelationship.map { $0.contact }, [hari])
        XCTAssertEqual(byRelationship.first?.tier, .containment)

        // Pin the grapheme-cluster boundary: a Devanagari query one
        // vowel sign short of the stored relationship does NOT match
        // via containment — Swift Characters, not code points, are the
        // substring unit. Matching this would need scalar-aware search,
        // which the book search deliberately does not do either.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "छोर",
                                                         in: [sita, hari]).isEmpty)

        // Digit run of the query inside the contact's dialable number.
        let byDigits = UnifiedContactSearch.familyMatches(query: "9841 000001",
                                                          in: [sita, hari])
        XCTAssertEqual(byDigits.map { $0.contact }, [sita])
        XCTAssertEqual(byDigits.first?.tier, .containment)

        // A digit run nobody owns matches nobody.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "9841 999999",
                                                         in: [sita, hari]).isEmpty)
    }

    func testContactsNotMatchingAreExcluded() {
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "विदेश",
                                                         in: [sita, hari]).isEmpty)
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "zzz",
                                                         in: [sita, hari]).isEmpty)
    }

    func testEmptyOrWhitespaceQueryYieldsEmptyOutcome() {
        for blank in ["", "   ", "\n\t"] {
            let outcome = UnifiedContactSearch.search(query: blank,
                                                      family: [sita, hari],
                                                      in: [sitaTwin, sitaSharma])
            XCTAssertTrue(outcome.entries.isEmpty)
            XCTAssertFalse(outcome.moreAvailable)
        }
        // A query nobody matches behaves the same way.
        let outcome = UnifiedContactSearch.search(query: "zzz", family: [sita, hari],
                                                  in: [sitaTwin, sitaSharma])
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertFalse(outcome.moreAvailable)
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "  ", in: [sita, hari]).isEmpty)
    }

    // MARK: - Dedupe

    func testDedupeDropsBookTwinWhenTheFamilyContactMatched() {
        // A query matching Sita the FAMILY contact (digit run of her
        // number) and her book twin "सीता शर्मा" — same normalized
        // number, same person twice. Exactly one row survives: the
        // family one.
        let outcome = UnifiedContactSearch.search(query: "9841 000001",
                                                  family: [sita, hari],
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
                                                     in: [sitaTwin, sitaSharma])
        XCTAssertEqual(devanagari.entries, [.addressBook(sitaTwin)])
        XCTAssertFalse(devanagari.moreAvailable)

        // Latin mirror: the family matches nothing for "Sharma", and
        // the book's own Sharma-named row answers alone.
        XCTAssertTrue(UnifiedContactSearch.familyMatches(query: "Sharma",
                                                         in: [sita, hari]).isEmpty)
        let latin = UnifiedContactSearch.search(query: "Sharma",
                                                family: [sita, hari],
                                                in: [sitaTwin, sitaSharma])
        XCTAssertEqual(latin.entries, [.addressBook(sitaSharma)])
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
        let now = Date()

        // The containment-tier contact was dialed just now — freshest of
        // all four — yet still ranks after the exact-name and
        // relationship contacts: tier first, recency only INSIDE a tier.
        let outcome = UnifiedContactSearch.search(query: "छोरी",
                                                  family: [exact, byRelationship, kumari, maya],
                                                  in: [],
                                                  recency: ["9841000009": now,
                                                            "9841000008": now.addingTimeInterval(-3600)])
        XCTAssertEqual(outcome.entries.map { $0.name },
                       ["छोरी", "माया", "छोरी माया", "छोरी कुमारी"])

        // Recency flipped within the containment tier reorders only it.
        let flipped = UnifiedContactSearch.search(query: "छोरी",
                                                  family: [exact, byRelationship, kumari, maya],
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
                                                         in: [sita, hari])
        XCTAssertEqual(matches.map { $0.tier }, [.containment, .containment])

        let now = Date()
        let bySita = UnifiedContactSearch.search(query: "9841 00000",
                                                 family: [sita, hari], in: [],
                                                 recency: [sitaNumber: now])
        XCTAssertEqual(bySita.entries.map { $0.name }, ["Sita", "Hari"])

        let byHari = UnifiedContactSearch.search(query: "9841 00000",
                                                 family: [sita, hari], in: [],
                                                 recency: [hariNumber: now])
        XCTAssertEqual(byHari.entries.map { $0.name }, ["Hari", "Sita"])

        let neverCalled = UnifiedContactSearch.search(query: "9841 00000",
                                                      family: [sita, hari], in: [])
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
        let outcome = UnifiedContactSearch.search(query: "आफन्त",
                                                  family: family, in: book,
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
                                                       family: [], in: book,
                                                       recency: recency, limit: 2)
        let systemDigit = SystemContactSearch.search(query: "9841 00000", in: book,
                                                     recency: recency, limit: 2)
        XCTAssertEqual(digitOutcome.entries,
                       systemDigit.entries.map { UnifiedContactSearch.Result.addressBook($0) })
        XCTAssertEqual(digitOutcome.moreAvailable, systemDigit.moreAvailable)
        // Three rows matched "9841 00000" (the two Sharmas + Gopal);
        // the cap shows two and the flag says so.
        XCTAssertTrue(digitOutcome.moreAvailable)

        let nameOutcome = UnifiedContactSearch.search(query: "सीता", family: [], in: book)
        let systemName = SystemContactSearch.search(query: "सीता", in: book)
        XCTAssertEqual(nameOutcome.entries,
                       systemName.entries.map { UnifiedContactSearch.Result.addressBook($0) })
        XCTAssertEqual(nameOutcome.moreAvailable, systemName.moreAvailable)
    }

    // MARK: - Result rows

    func testAvailabilityBadgesReflectLinkBuildabilityNotPlatformPresence() {
        // Book row WITHOUT Facebook linkage (the twin fixture carries
        // none — a linked row badges instead, see
        // testMessengerBadgeForLinkedBookRows): the number can shape a
        // WhatsApp link, but Messenger links are handle-addressed — no
        // handle stored, so no badge — even though an app-synced copy
        // of this person may exist on the device.
        let bookOutcome = UnifiedContactSearch.search(query: "शर्मा", family: [],
                                                      in: [sitaTwin, sitaSharma])
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
                                                      family: [sita, hari], in: [])
        guard let sitaRow = sitaOutcome.entries.first,
              case .family(let sitaContact) = sitaRow else {
            XCTFail("expected Sita")
            return
        }
        XCTAssertEqual(sitaContact.phone, "+977 9841 000001")
        XCTAssertTrue(sitaRow.whatsAppAvailable)
        XCTAssertFalse(sitaRow.messengerAvailable)   // no handle stored

        let hariOutcome = UnifiedContactSearch.search(query: "hari",
                                                      family: [sita, hari], in: [])
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
                                                     family: [devanagariHandle], in: [])
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
                                                          family: [noDigits], in: [])
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
                                                  in: [sitaSharma, linked])
        XCTAssertEqual(outcome.entries, [.addressBook(linked)])
        guard let row = outcome.entries.first else {
            XCTFail("expected Maya's row")
            return
        }
        XCTAssertTrue(row.whatsAppAvailable)
        XCTAssertTrue(row.messengerAvailable)
        XCTAssertEqual(row.messengerHandle, "maya.gurung")

        // The linkage-free neighbor in the same book stays badge-off:
        // a bare number cannot form a Messenger handle, even when an
        // app-synced copy of the person exists on the device.
        let plain = UnifiedContactSearch.Result.addressBook(sitaSharma)
        XCTAssertFalse(plain.messengerAvailable)
        XCTAssertNil(plain.messengerHandle)
    }

    func testResultIdentifiersAndLabelsStaySourceSpecific() {
        let outcome = UnifiedContactSearch.search(query: "sita",
                                                  family: [sita, hari],
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
