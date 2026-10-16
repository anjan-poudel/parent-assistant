import XCTest
@testable import ElderlyAssistant

final class ContactResolverTests: XCTestCase {

    private let maiya = FamilyContact(name: "माइया", phone: "1", relationship: "आमा")
    private let sunita = FamilyContact(name: "सुनिता आचार्य", phone: "2", relationship: "छोरी")
    private let ram = FamilyContact(name: "Ram", phone: "3", relationship: "son")

    private func resolver(_ contacts: [FamilyContact]) -> ContactResolver {
        ContactResolver(contactsProvider: { contacts })
    }

    /// The production shape (T-151/T-156): a published `FamilyContactIndex`
    /// is handed in, nothing is rebuilt per call.
    private func indexedResolver(_ contacts: [FamilyContact]) -> ContactResolver {
        let index = FamilyContactIndex(family: contacts)
        return ContactResolver(contactsProvider: { contacts }, indexProvider: { index })
    }

    /// The `.ambiguous` payload's ids, or nil for any other outcome — lets
    /// the consequence-table rows assert SETS (order-free) rather than pin
    /// a roster order the ambiguity rule deliberately ignores.
    private func ambiguousIDs(_ match: ContactMatch) -> Set<UUID>? {
        guard case .ambiguous(let contacts) = match else { return nil }
        return Set(contacts.map(\.id))
    }

    func testExactNameMatch() {
        XCTAssertEqual(resolver([maiya, sunita]).resolve("माइया"), .one(maiya))
    }

    func testNameMatchWithHonorific() {
        XCTAssertEqual(resolver([maiya]).resolve("माइया ज्यू"), .one(maiya))
    }

    func testPartialNameContainment() {
        // "सुनिता" should match "सुनिता आचार्य" (0.8 containment).
        XCTAssertEqual(resolver([maiya, sunita]).resolve("सुनिता"), .one(sunita))
    }

    func testRelationshipMatchNepali() {
        XCTAssertEqual(resolver([maiya, sunita]).resolve("छोरी"), .one(sunita))
    }

    func testRelationshipMatchEnglishAgainstNepaliField() {
        // "son" anchors onto the same word as Nepali "छोरा" — matching
        // runs on anchors, so an English query hits a Nepali relationship.
        XCTAssertEqual(resolver([maiya, ram]).resolve("son"), .one(ram))
    }

    func testRelationshipMatchNepaliAgainstEnglishField() {
        let nepaliSon = FamilyContact(name: "Hari", phone: "4", relationship: "छोरा")
        XCTAssertEqual(resolver([nepaliSon]).resolve("छोरालाई"), .one(nepaliSon))
    }

    func testNoMatch() {
        XCTAssertEqual(resolver([maiya]).resolve("nonexistent person"), .none)
        XCTAssertEqual(resolver([maiya]).resolve(nil), .none)
        XCTAssertEqual(resolver([maiya]).resolve(""), .none)
    }

    func testAmbiguityReturnsAllRivals() {
        let maiya1 = FamilyContact(name: "माइया श्रेष्ठ", phone: "5", relationship: "आमा")
        let maiya2 = FamilyContact(name: "माइया थापा", phone: "6", relationship: "दिदी")
        let result = resolver([maiya1, maiya2]).resolve("माइया")
        guard case .ambiguous(let matches) = result else {
            XCTFail("expected ambiguous, got \(result)")
            return
        }
        XCTAssertEqual(matches.count, 2)
    }

    func testExactMatchBeatsContainmentRival() {
        // Exact (1.0) vs containment (0.8): margin 0.2 > 0.15 → not ambiguous.
        let exact = FamilyContact(name: "माइया", phone: "1", relationship: "आमा")
        let longer = FamilyContact(name: "माइया श्रेष्ठ", phone: "5", relationship: "दिदी")
        XCTAssertEqual(resolver([exact, longer]).resolve("माइया"), .one(exact))
    }

    /// Roster-order-free parity anchor: a roster with no nicknames answers
    /// exactly as the pre-nickname resolver did — the index is additive.
    func testRosterWithoutNicknamesReproducesTodaysAnswers() {
        let contacts = [maiya, sunita, ram]
        for both in [resolver(contacts), indexedResolver(contacts)] {
            XCTAssertEqual(both.resolve("माइया"), .one(maiya))
            XCTAssertEqual(both.resolve("सुनिता"), .one(sunita))
            XCTAssertEqual(both.resolve("son"), .one(ram))
            XCTAssertEqual(both.resolve("बाटो"), .none)
        }
    }
}

// MARK: - Nickname bands (FR-FCU-013), T-153

extension ContactResolverTests {

    func testUnambiguousNicknameResolvesInOneStep() {
        // Gherkin: one family contact carries nickname "आमा" — the spoken
        // request resolves straight to that contact (0.85 band).
        let contact = FamilyContact(name: "सुनिता", phone: "1", relationship: "छोरी",
                                    nicknames: ["आमा"])
        XCTAssertEqual(resolver([contact]).resolve("आमा"), .one(contact))
        XCTAssertEqual(indexedResolver([contact]).resolve("आमा"), .one(contact))
    }

    func testEveryStoredNicknameSpellingResolves() {
        let contact = FamilyContact(name: "सुनिता", phone: "1", relationship: "छोरी",
                                    nicknames: ["आमा", "सानु", "ममी"])
        for nickname in contact.nicknames {
            XCTAssertEqual(resolver([contact]).resolve(nickname), .one(contact))
        }
    }

    func testNicknameContainmentMatchesEitherDirection() {
        // The 0.75 band has the name band's both-direction shape: the
        // nickname may contain the query, or the query may contain the
        // whole nickname (a fuller utterance around it).
        let contact = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                    nicknames: ["सुनिता आचार्य"])
        XCTAssertEqual(resolver([contact]).resolve("सुनिता"), .one(contact))
        XCTAssertEqual(resolver([contact]).resolve("हाम्री सुनिता आचार्य"), .one(contact))
    }

    func testNicknameBandNeverFabricatesAMatch() {
        // A nickname present on someone else's record does not make an
        // unrelated request match this contact.
        let contact = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                    nicknames: ["सानु"])
        XCTAssertEqual(resolver([contact]).resolve("बाटो"), .none)
    }

    func testBlankNicknameSpellingCannotMatchEveryQuery() {
        // A punctuation-only spelling normalizes to "" and is dropped at
        // the index; it must not "contain" every request.
        let contact = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                    nicknames: ["।।"])
        XCTAssertEqual(resolver([contact]).resolve("बाटो"), .none)
        XCTAssertEqual(indexedResolver([contact]).resolve("बाटो"), .none)
    }
}

// MARK: - F2 consequence table (T-153; security advisory F2)

extension ContactResolverTests {

    /// The banding pins. The table below is a consequence of running the
    /// REAL resolver over real contacts; these two numbers are what make
    /// it falsifiable — an accept/margin edit flips a documented row.
    func testConsequenceTablePinsTheBandingConstants() {
        let pins = ContactResolver.bandingPins
        XCTAssertEqual(pins.accept, 0.6)
        XCTAssertEqual(pins.margin, 0.15)
        // The IEEE-754 gap the table documents: 0.15 has no exact double
        // representation, so every at-margin pair lands at
        // 0.15000000000000002 — strictly GREATER than the margin, so the
        // strict `<` rival rule makes those pairs DECISIVE (top wins).
        XCTAssertEqual(1.00 - 0.85, 0.15000000000000002)
        XCTAssertEqual(0.90 - 0.75, 0.15000000000000002)
        XCTAssertEqual(0.75 - 0.60, 0.15000000000000002)
        XCTAssertFalse(0.15000000000000002 < pins.margin)
        // A gap UNDER the margin is the ambiguous row (0.85-vs-0.90 etc.).
        XCTAssertTrue(0.90 - 0.85 < pins.margin)
        XCTAssertTrue(0.85 - 0.75 < pins.margin)
    }

    /// Row 1.00 vs 0.85 — the documented pair: name-exact STAYS strongest
    /// and resolves; the nickname-exact rival is one at-margin gap away,
    /// which is not "within" the margin.
    func testConsequenceRowNameExactBeatsNicknameExactAtMargin() {
        let nameExact = FamilyContact(name: "माइया", phone: "1", relationship: "आमा")
        let nicknameExact = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                                          nicknames: ["माइया"])
        XCTAssertEqual(resolver([nameExact, nicknameExact]).resolve("माइया"), .one(nameExact))
        // Same pair, reversed roster: the decision is the comparison's,
        // never the order's.
        XCTAssertEqual(resolver([nicknameExact, nameExact]).resolve("माइया"), .one(nameExact))
    }

    /// Row 0.90 vs 0.75 — exactly at the margin (0.15000000000000002),
    /// therefore decisive: the relationship-anchored contact wins.
    func testConsequenceRowRelationshipBeatsNicknameContainmentAtMargin() {
        let relationship = FamilyContact(name: "सुनिता", phone: "1", relationship: "आमा")
        let nicknameContainment = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                                                nicknames: ["मेरी आमा"])
        XCTAssertEqual(resolver([relationship, nicknameContainment]).resolve("आमा"), .one(relationship))
        XCTAssertEqual(resolver([nicknameContainment, relationship]).resolve("आमा"), .one(relationship))
    }

    /// Row 0.75 vs 0.60 — exactly at the margin, therefore decisive: the
    /// nickname-containment contact wins over the token-overlap one.
    func testConsequenceRowNicknameContainmentBeatsTokenOverlapAtMargin() {
        let nicknameContainment = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                                nicknames: ["सुनिता आचार्य ज्यू"])
        let tokenOverlap = FamilyContact(name: "सुनिता श्रेष्ठ", phone: "2",
                                         relationship: "बहिनी")
        XCTAssertEqual(resolver([nicknameContainment, tokenOverlap]).resolve("सुनिता आचार्य"),
                       .one(nicknameContainment))
    }

    /// Clear-margin boundary: a candidate scoring EXACTLY the accept
    /// threshold (0.60) is accepted — the threshold is inclusive.
    func testConsequenceRowCandidateAtTheAcceptFloorResolves() {
        let atFloor = FamilyContact(name: "सुनिता श्रेष्ठ", phone: "1", relationship: "बहिनी")
        XCTAssertEqual(resolver([atFloor]).resolve("सुनिता आचार्य"), .one(atFloor))
    }

    /// Below-accept row (failure path): the nearest-but-below-threshold
    /// contact is never returned — an honest miss, not a guess.
    func testConsequenceRowBelowAcceptIsAnHonestMiss() {
        let belowAccept = FamilyContact(name: "सुनिता श्रेष्ठ", phone: "1",
                                        relationship: "दिदी")
        XCTAssertEqual(resolver([belowAccept]).resolve("सुनिता आचार्य काठमाडौं"), .none)
    }

    /// Row 0.85 vs 0.85 — a shared nickname is a tie → ambiguous, never a
    /// silent pick (FR-FCU-014): the did-you-mean path gets BOTH contacts.
    func testConsequenceRowSharedNicknameIsAmbiguous() {
        let a = FamilyContact(name: "सुनिता", phone: "1", relationship: "छोरी",
                              nicknames: ["सानु"])
        let b = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                              nicknames: ["सानु"])
        let result = resolver([a, b]).resolve("सानु")
        XCTAssertEqual(ambiguousIDs(result), Set([a.id, b.id]))
        // ...and never a silent pick of either person (no wrong-person dial).
        XCTAssertNotEqual(result, .one(a))
        XCTAssertNotEqual(result, .one(b))
    }

    /// Row 0.85 vs 0.90 — a nickname colliding with the relationship
    /// signal is ambiguous too: never silently dials.
    func testConsequenceRowNicknameExactAgainstRelationshipIsAmbiguous() {
        let relationship = FamilyContact(name: "सुनिता", phone: "1", relationship: "आमा")
        let nicknameExact = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                                          nicknames: ["आमा"])
        let result = resolver([relationship, nicknameExact]).resolve("आमा")
        XCTAssertEqual(ambiguousIDs(result), Set([relationship.id, nicknameExact.id]))
    }

    /// Row 0.85 vs 0.80 — nickname-exact against name containment: both
    /// plausible, gap under the margin → ambiguous.
    func testConsequenceRowNicknameExactAgainstNameContainmentIsAmbiguous() {
        let nicknameExact = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                          nicknames: ["सुनिता"])
        let nameContainment = FamilyContact(name: "सुनिता श्रेष्ठ", phone: "2",
                                            relationship: "बहिनी")
        let result = resolver([nicknameExact, nameContainment]).resolve("सुनिता")
        XCTAssertEqual(ambiguousIDs(result), Set([nicknameExact.id, nameContainment.id]))
    }

    /// Row 0.85 vs 0.75 — nickname-exact against nickname containment:
    /// gap 0.10 < 0.15 → ambiguous (the two nickname bands never let a
    /// partial spelling out-rank a full one silently).
    func testConsequenceRowNicknameExactAgainstNicknameContainmentIsAmbiguous() {
        let nicknameExact = FamilyContact(name: "कमला", phone: "1", relationship: "दिदी",
                                          nicknames: ["सुनिता"])
        let nicknameContainment = FamilyContact(name: "गीता", phone: "2",
                                                relationship: "बहिनी",
                                                nicknames: ["सुनिता आचार्य"])
        let result = resolver([nicknameExact, nicknameContainment]).resolve("सुनिता")
        XCTAssertEqual(ambiguousIDs(result), Set([nicknameExact.id, nicknameContainment.id]))
    }

    /// Determinism: decisions follow the comparison, not the roster order —
    /// decisive rows stay decisive and ties stay ambiguous when the SAME
    /// contacts arrive in the other order.
    func testDecisionsDoNotDependOnRosterOrder() {
        let a = FamilyContact(name: "सुनिता", phone: "1", relationship: "छोरी",
                              nicknames: ["सानु"])
        let b = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                              nicknames: ["सानु"])
        let forward = resolver([a, b]).resolve("सानु")
        let reversed = resolver([b, a]).resolve("सानु")
        XCTAssertEqual(ambiguousIDs(forward), Set([a.id, b.id]))
        XCTAssertEqual(ambiguousIDs(reversed), Set([a.id, b.id]))
        XCTAssertEqual(ambiguousIDs(forward), ambiguousIDs(reversed))
    }

    /// The published-index hot path and the nil-provider test-parity path
    /// answer identically for every query shape the bands and the
    /// near-miss walk can see (fixture text is never printed).
    func testIndexProviderPathAnswersIdenticallyToTheBuiltInPath() {
        let contacts = [maiya, sunita, ram,
                        FamilyContact(name: "कमला", phone: "9", relationship: "दिदी",
                                      nicknames: ["सानु", "आमा"])]
        let indexed = indexedResolver(contacts)
        let built = resolver(contacts)
        let queries = ["माइया", "माइया ज्यू", "सुनिता", "सुनिता आचार्य", "son", "आमा",
                       "सानु", "सुनीता", "बाटो", ""]
        for (position, query) in queries.enumerated() {
            XCTAssertEqual(indexed.resolve(query), built.resolve(query), "resolve case \(position)")
            XCTAssertEqual(indexed.nearMiss(query)?.id, built.nearMiss(query)?.id,
                           "nearMiss case \(position)")
        }
    }
}

// MARK: - Devanagari grapheme pins (NFR-FCU-007)

extension ContactResolverTests {

    /// Negative pin (deliberate — house precedent: partial-word Nepali
    /// matching is a pinned REGRESSION, never "fixed"): a request that cuts
    /// a stored Devanagari name at a scalar boundary ("सुनिता" minus its
    /// final matra) is NOT a match. `String.contains` compares Character
    /// clusters, so "सुनित" ≠ "सुनिता" — the name tier and the new
    /// nickname tier behave exactly alike.
    func testGraphemeSplitTruncationDoesNotResolveTheFullName() {
        let sunita = FamilyContact(name: "सुनिता", phone: "1", relationship: "छोरी")
        XCTAssertEqual(resolver([sunita]).resolve("सुनिता"), .one(sunita))  // positive control
        XCTAssertEqual(resolver([sunita]).resolve("सुनित"), .none)         // the pin

        let nicknamed = FamilyContact(name: "कमला", phone: "2", relationship: "दिदी",
                                      nicknames: ["सुनिता"])
        XCTAssertEqual(resolver([nicknamed]).resolve("सुनिता"), .one(nicknamed))  // positive control
        XCTAssertEqual(resolver([nicknamed]).resolve("सुनित"), .none)            // nickname band, same pin
    }

    /// FR-FCU-004 scenario 2: the resolver consults the FAMILY roster only,
    /// so a contact linked to a system record yields exactly ONE spoken
    /// match — the system twin is not a candidate here.
    func testLinkedSystemTwinIsNeverASeparateCandidate() {
        let linked = FamilyContact(
            name: "सुनिता", phone: "1", relationship: "छोरी",
            systemContact: SystemContactLink(identifier: "system-1", numberKey: "9812345678")
        )
        XCTAssertEqual(resolver([linked]).resolve("सुनिता"), .one(linked))
    }
}

// MARK: - Near-miss proposals ([NEAR-MISS] 2026-10-11; nickname extension T-153)

extension ContactResolverTests {

    func testNearMissProposesSingleMatraVariant() {
        // "सुनीता" differs from "सुनिता" by ONE matra scalar —
        // resolve() rejects it, nearMiss proposes it.
        let contact = FamilyContact(name: "सुनिता", phone: "7", relationship: "छोरी")
        XCTAssertEqual(resolver([contact]).resolve("सुनीता"), .none)
        XCTAssertEqual(resolver([contact]).nearMiss("सुनीता"), contact)
    }

    func testNearMissSyanoToSanu() {
        // The field case: "स्यानु" (virama-y artefact) is two scalar
        // edits from "सानु".
        let sanu = FamilyContact(name: "सानु", phone: "8", relationship: "दिदी")
        XCTAssertEqual(resolver([sanu]).nearMiss("स्यानु"), sanu)
    }

    func testNearMissRefusesWhenTwoContactsAreWithinBudget() {
        // Same no-guess discipline as resolve: two rivals in the band →
        // no proposal, the caller keeps its honest not-found line.
        let maya = FamilyContact(name: "माया", phone: "8", relationship: "दिदी")
        let maiya = FamilyContact(name: "मइया", phone: "9", relationship: "बहिनी")
        XCTAssertNil(resolver([maya, maiya]).nearMiss("माइया"))
    }

    func testNearMissNoSignalReturnsNil() {
        // Cross-script invented names carry no signal — no proposal.
        XCTAssertNil(resolver([maiya, sunita]).nearMiss("Seema"))
        XCTAssertNil(resolver([maiya]).nearMiss(nil))
        XCTAssertNil(resolver([maiya]).nearMiss(""))
    }

    func testNearMissProposesThroughANickname() {
        // The T-153 extension: the candidate set is the name OR any
        // nickname within the edit budget. The query matches no accept
        // band (resolve is a honest miss), so the proposal path sees it.
        let contact = FamilyContact(name: "कमला", phone: "3", relationship: "दिदी",
                                    nicknames: ["सुनिता"])
        XCTAssertEqual(resolver([contact]).resolve("सुनीता"), .none)
        XCTAssertEqual(resolver([contact]).nearMiss("सुनीता"), contact)
        XCTAssertEqual(indexedResolver([contact]).nearMiss("सुनीता"), contact)
    }

    func testNearMissCountsOneContactOnceWhenNameAndNicknameAreBothInBudget() {
        // The exactly-one rule counts CONTACTS, not spellings: a contact
        // whose name AND nickname both land in budget is still ONE
        // candidate — two forms of one person are not two people.
        let contact = FamilyContact(name: "सुनिता", phone: "3", relationship: "छोरी",
                                    nicknames: ["सुनीता"])
        XCTAssertEqual(resolver([contact]).nearMiss("सुनित"), contact)
    }

    func testNearMissAbstainsWhenNameAndNicknameLandOnDifferentContacts() {
        // Design-l1 §8.3 near-miss extension: one name-near-miss plus one
        // nickname-near-miss in the same query are TWO candidates — the
        // path abstains instead of choosing a person.
        let nameNearMiss = FamilyContact(name: "सुनिता", phone: "3", relationship: "छोरी")
        let nicknameNearMiss = FamilyContact(name: "कमला", phone: "4", relationship: "दिदी",
                                             nicknames: ["सुनीता"])
        XCTAssertNil(resolver([nameNearMiss, nicknameNearMiss]).nearMiss("सुनित"))
    }
}

// MARK: - Perf ceiling (NFR-FCU-001)

extension ContactResolverTests {

    /// The production maximum: 12 contacts × 8 nicknames (96 distinct
    /// spellings). Both provider shapes are timed — the nil provider
    /// rebuilds the index per call, the published index does not; every
    /// measurement asserts the ≤ 20 ms ceiling and only DURATIONS are
    /// printed (never fixture text).
    func testVoiceResolutionStaysWithinTheTwentyMillisecondCeilingAtMaxRoster() {
        let contacts = Self.maxRoster()
        let built = resolver(contacts)
        let published = indexedResolver(contacts)
        let queries = contacts.flatMap(\.nicknames)
        XCTAssertEqual(contacts.count, 12)
        XCTAssertEqual(queries.count, 96)

        let worstPublished = measure(queries) { _ = published.resolve($0) }
        let worstBuilt = measure(queries) { _ = built.resolve($0) }
        let worstNearMiss = measure([queries[0] + "क"]) { _ = published.nearMiss($0) }
        print("[T-153] worst voice resolve @12×8 — published: \(worstPublished) ms, "
              + "built: \(worstBuilt) ms, near-miss: \(worstNearMiss) ms")
        XCTAssertLessThanOrEqual(worstPublished, 20)
        XCTAssertLessThanOrEqual(worstBuilt, 20)
        XCTAssertLessThanOrEqual(worstNearMiss, 20)
    }

    private func measure(_ queries: [String], _ body: (String) -> Void) -> Double {
        var worst = 0.0
        for query in queries {
            let start = CFAbsoluteTimeGetCurrent()
            body(query)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            worst = max(worst, ms)
            XCTAssertLessThanOrEqual(ms, 20)
        }
        return worst
    }

    private static func maxRoster() -> [FamilyContact] {
        (0..<12).map { index in
            FamilyContact(
                name: "सदस्य\(index)",
                phone: "100\(index)",
                relationship: index.isMultiple(of: 2) ? "छोरी" : "छोरा",
                nicknames: (0..<8).map { slot in "उपनाम\(index)x\(slot)" }
            )
        }
    }
}
