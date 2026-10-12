import XCTest
@testable import ElderlyAssistant

/// Unit tests for `FamilyContactIndex` (family-contacts-unify T-151 —
/// design-l1 §5.4, design-l2 §1.2/§6.1/§8.3; FR-FCU-011, FR-FCU-012,
/// NFR-FCU-001, NFR-FCU-007).
///
/// Pure logic only: fixtures are plain `FamilyContact` values (and, for
/// the migration pin, one raw legacy JSON payload), no store, no
/// coordinator — those seams belong to T-145/T-152/T-156.
///
/// The measured values the perf assertions observe are printed to the
/// test output (durations only — never fixture text, so nothing that
/// could look like PII is ever logged) for the DV record.
final class FamilyContactIndexTests: XCTestCase {

    // MARK: - Fixtures

    /// NFR-FCU-001's ceiling: build and per-query operations must stay
    /// within 20 ms, worst case, at the 12 × 8 production maximum.
    private let ceilingMs: Double = 20

    private func makeContact(name: String, nicknames: [String] = [],
                             id: UUID = UUID(),
                             relationship: String = "छोरी") -> FamilyContact {
        FamilyContact(id: id, name: name, phone: "9812345678",
                      relationship: relationship, nicknames: nicknames)
    }

    /// The design's max production roster: 12 contacts, 8 nicknames
    /// each (design-l2 §6.1) — 108 normalization calls per build. Half
    /// the spellings are Devanagari so the build exercises the NFKD/NFC
    /// path too, and every spelling is distinct (96 unique keys).
    private func maxRoster() -> [FamilyContact] {
        (0..<12).map { i in
            let nicknames = (0..<8).map { j in
                j.isMultiple(of: 2) ? "nickname-\(i)-\(j)" : "उपनाम-\(i)-\(j)"
            }
            return makeContact(name: "Contact \(i)", nicknames: nicknames,
                               relationship: "छोरा")
        }
    }

    /// Wall-clock duration of `body` in milliseconds, on the monotonic
    /// uptime clock (same idiom as `EnergyVADTests`).
    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Worst of `runs` whole-index builds of `family` — the assertion
    /// is a worst-case ceiling, never an average (the F5 note in the
    /// task is explicit about that).
    private func worstBuildMs(_ family: [FamilyContact], runs: Int = 5) -> Double {
        var worst = 0.0
        for _ in 0..<runs {
            worst = max(worst, milliseconds { _ = FamilyContactIndex(family: family) })
        }
        return worst
    }

    /// Worst of `runs` measured single calls of `body` — one query per
    /// measurement, so a stall in any single lookup would be caught.
    private func worstCallMs(runs: Int = 20, _ body: () -> Void) -> Double {
        var worst = 0.0
        for _ in 0..<runs {
            worst = max(worst, milliseconds(body))
        }
        return worst
    }

    // MARK: - Gherkin: O(1) nickname lookup via idsByNickname

    func testExactNicknameLookupIsTheMapHitAndNotAScan() {
        // "Given a family contact 'Aama' with nickname 'आमा' / When the
        // index resolves nickname 'आमा' / Then it returns the contact
        // id / And the lookup is a dictionary hit (idsByNickname), not
        // a scan": the published map answers the same question the
        // method does — the method IS the map subscript.
        let aama = makeContact(name: "Aama", nicknames: ["आमा"])
        let index = FamilyContactIndex(family: [aama])
        let key = NepaliTextNormalizer.normalize("आमा")

        XCTAssertEqual(index.idsByNickname[key], [aama.id],
                       "the normalized key is in the map (O(1) hit, not a scan)")
        XCTAssertEqual(index.exactNicknameHolders(key), [aama.id])
        XCTAssertEqual(index.nicknameEntries(for: aama.id), [key])
        XCTAssertEqual(index.entry(for: aama.id)?.normalizedName,
                       NepaliTextNormalizer.normalize("Aama"))
        XCTAssertEqual(index.entry(for: aama.id)?.rawNicknames, ["आमा"],
                       "the stored spelling is kept verbatim for containment parity")
    }

    func testExactLookupTakesThePreNormalizedKeyNotTheRawQuery() {
        // The seam contract for the tiers above (design-l2 §6.1): the
        // search layer normalizes the query ONCE and hands over the key;
        // this method does not re-normalize per call. A raw query is a
        // miss — deliberately, so a caller that forgets its one
        // `normalize` fails loudly in its own tests instead of paying
        // normalization twice on every keystroke.
        let aama = makeContact(name: "Aama", nicknames: ["Aama!"])
        let index = FamilyContactIndex(family: [aama])

        XCTAssertEqual(index.idsByNickname["aama"], [aama.id],
                       "the stored spelling is normalized at build time (case folded, '!' stripped)")
        XCTAssertEqual(index.exactNicknameHolders("AAMA"), [],
                       "a raw query is not re-normalized here")
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("AAMA")),
                       [aama.id],
                       "one normalize at the call site is the whole contract")
    }

    // MARK: - Gherkin: performance ceilings (12 contacts x 8 nicknames)

    func testMaxRosterBuildStaysUnderTheTwentyMillisecondCeiling() {
        let roster = maxRoster()
        XCTAssertEqual(roster.count, 12)

        // One untimed warm-up pass so the assertion measures the index
        // build, not the shared normalizer's first-call lazy ICU init.
        let warmUp = FamilyContactIndex(family: roster)
        XCTAssertEqual(warmUp.idsByNickname.count, 96, "all 96 spellings are distinct keys")
        XCTAssertEqual(warmUp.entries.count, 12)

        let worst = worstBuildMs(roster)
        print("[FamilyContactIndexTests] build 12x8 worst-of-5 = \(worst) ms (ceiling \(ceilingMs) ms)")

        XCTAssertLessThanOrEqual(worst, ceilingMs,
                                 "max-roster build (12 contacts x 8 nicknames) must stay within the NFR-FCU-001 ceiling, worst case")

        let index = FamilyContactIndex(family: roster)
        XCTAssertEqual(index.entries.map(\.id), roster.map(\.id), "roster order preserved")
        XCTAssertEqual(index.idsByNickname.count, 96)
    }

    func testNicknameLookupStaysUnderTheTwentyMillisecondCeilingPerQuery() {
        let roster = maxRoster()
        let index = FamilyContactIndex(family: roster) // warm-up of the hot path
        let keys = roster.flatMap { $0.nicknames.map { NepaliTextNormalizer.normalize($0) } }
        XCTAssertEqual(keys.count, 96)

        var worst = 0.0
        var resolved = 0
        for key in keys {
            var holders: [UUID] = []
            worst = max(worst, milliseconds { holders = index.exactNicknameHolders(key) })
            if !holders.isEmpty { resolved += 1 }
        }
        // A worst-case MISS with a long key: the map's rejection path
        // must be as cheap as a hit.
        let missKey = NepaliTextNormalizer.normalize(String(repeating: "क", count: 256))
        var missHolders: [UUID] = []
        worst = max(worst, milliseconds { missHolders = index.exactNicknameHolders(missKey) })
        print("[FamilyContactIndexTests] nickname lookup worst-of-\(keys.count + 1) = \(worst) ms per query (ceiling \(ceilingMs) ms)")

        XCTAssertEqual(resolved, 96, "every nickname resolves through the map")
        XCTAssertTrue(missHolders.isEmpty, "a 256-char key nobody holds resolves to []")
        XCTAssertLessThanOrEqual(worst, ceilingMs,
                                 "every single lookup, hit or miss, must stay within the NFR-FCU-001 per-query ceiling")
    }

    func testLongStringWorstCaseEntryStaysWithinTheCeilings() {
        // Gherkin (F5): "Given an index entry with a 256-character
        // nickname / When the index builds and is queried / Then both
        // operations stay within the same <= 20 ms ceilings
        // (worst-case assertion, not average-only)". The 64-char editor
        // cap (T-145/T-160) is defence-in-depth; the index must stay
        // safe for longer STORED values.
        // "सीता" is TWO grapheme clusters (सी + ता — each vowel sign
        // combines into its consonant's cluster), so 64 repetitions only
        // ever stored 128 Characters. [T-163 first-run correction] 128
        // repetitions store the 256-Character value the F5 scenario
        // (and the assertions below) name.
        let longNickname = String(repeating: "सीता", count: 128)
        let longName = String(repeating: "ज्यू", count: 256)
        XCTAssertEqual(longNickname.count, 256, "fixture guard: 128 x 2-Character clusters")
        XCTAssertEqual(longName.count, 256, "fixture guard: 256 x 1-Character multi-scalar clusters")

        let contact = makeContact(name: longName, nicknames: [longNickname])
        let roster = [contact]
        let index = FamilyContactIndex(family: roster) // warm-up

        let buildMs = worstBuildMs(roster)
        let key = NepaliTextNormalizer.normalize(longNickname)
        var holders: [UUID] = []
        let queryMs = worstCallMs { holders = index.exactNicknameHolders(key) }
        print("[FamilyContactIndexTests] 256-char worst case: build worst-of-5 = \(buildMs) ms, query worst-of-20 = \(queryMs) ms (ceiling \(ceilingMs) ms)")

        XCTAssertLessThanOrEqual(buildMs, ceilingMs, "256-char entry build stays within the ceiling")
        XCTAssertLessThanOrEqual(queryMs, ceilingMs, "256-char entry query stays within the ceiling")
        XCTAssertEqual(holders, [contact.id])
        XCTAssertEqual(index.entry(for: contact.id)?.normalizedNicknames,
                       [NepaliTextNormalizer.normalize(longNickname)],
                       "the full 256-Character spelling survives normalization unsplit")
    }

    // MARK: - Gherkin: Devanagari grapheme pins (NFR-FCU-007)

    func testDevanagariExactMatchIsThePositivePin() {
        // "Given a Devanagari nickname containing multi-scalar grapheme
        // clusters / When it is indexed and queried with an exact match
        // / Then it matches (positive pin)". "ज्यू" is ONE Character
        // built from four scalars (ज + ् + य + ू) — the cluster must
        // survive indexing intact.
        let aama = makeContact(name: "Aama", nicknames: ["आमा"])
        let jyu = makeContact(name: "Kaki", nicknames: ["ज्यू"], relationship: "आमा")
        let index = FamilyContactIndex(family: [aama, jyu])

        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("आमा")),
                       [aama.id])
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("ज्यू")),
                       [jyu.id])
        XCTAssertEqual(index.entry(for: jyu.id)?.normalizedNicknames.first?.count, 1,
                       "'ज्यू' stays ONE Character — never split into scalars")
    }

    func testDevanagariPartialWordSubstringDoesNotMatchTheNegativePin() {
        // The deliberate negative pin (house Swift-Devanagari regression
        // precedent, NFR-FCU-007): "छोर" is [छो][र] while "छोरी" is
        // [छो][री], so the one-vowel-sign-short query does NOT occur in
        // the stored string and must NOT match. This is pinned, not
        // "fixed" — moving to scalar-aware search is a deliberate
        // future decision, not a silent behaviour change. The
        // containment tier itself runs downstream (T-152); it runs over
        // the strings this index precomputes, with the same
        // `range(of:options:)` call `familyMatches` uses today.
        let daughter = makeContact(name: "Sita", nicknames: ["छोरी"])
        let index = FamilyContactIndex(family: [daughter])
        guard let entry = index.entry(for: daughter.id) else {
            return XCTFail("fixture contact must be in the index")
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        XCTAssertNil(entry.normalizedNicknames[0].range(of: "छोर", options: options),
                     "negative pin: the partial word does not match the normalized spelling")
        XCTAssertNil(entry.rawNicknames[0].range(of: "छोर", options: options),
                     "negative pin holds on the raw spelling too (containment parity)")
        XCTAssertNotNil(entry.normalizedNicknames[0].range(of: "छोरी", options: options),
                        "positive control: the whole word does match")
        XCTAssertNil(index.idsByNickname[NepaliTextNormalizer.normalize("छोर")],
                     "exact matching is exact: the partial word is not a key")
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("छोर")), [])
    }

    func testCanonicallyEquivalentSpellingsOfOneWordShareTheKey() {
        // STT output is not consistent about canonical composition
        // (`NepaliTextNormalizer` is NFC for exactly this reason). The
        // nukta pair is the sharp case: U+0958 and क + ़
        // (U+0915 U+093C) are canonically equivalent, but NFC
        // deliberately does NOT compose them (composition exclusion) —
        // the index must unify them at key level, not by byte shape.
        // It does, because Swift's String equality and hashing work on
        // canonical equivalence; this pin makes that a locked-in
        // guarantee for the map, not an accident.
        let precomposed = "\u{0958}\u{093E}\u{0932}"          // क़ ा ल, single-scalar nukta
        let decomposed = "\u{0915}\u{093C}\u{093E}\u{0932}"   // क + ़ + ा + ल
        XCTAssertNotEqual(precomposed.unicodeScalars.count, decomposed.unicodeScalars.count,
                          "fixture guard: the two spellings differ at scalar level")
        XCTAssertEqual(precomposed, decomposed, "…while being canonically equivalent")

        let contact = makeContact(name: "Kalam", nicknames: [precomposed])
        let index = FamilyContactIndex(family: [contact])

        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize(decomposed)),
                       [contact.id],
                       "the canonically-decomposed spelling resolves the stably-composed key")
        XCTAssertEqual(index.idsByNickname.count, 1,
                       "one word, one key — the variant spelling did not create a second entry")
    }

    // MARK: - Gherkin failure paths: duplicates and rebuilds

    func testDuplicateNicknameOnTwoContactsKeepsBothIDsInRosterOrder() {
        // "Given two contacts both claim nickname 'Buba' / When the
        // index is built / Then both ids are retrievable for the
        // nickname (no silent overwrite) / And the ambiguity is
        // representable for downstream callers". The two spellings
        // differ in trim/case/danda on purpose — they still land on ONE
        // normalized key.
        let first = makeContact(name: "Aama A", nicknames: ["बुवा"])
        let second = makeContact(name: "Aama B", nicknames: [" बुवा।"])
        let key = NepaliTextNormalizer.normalize("बुवा")

        let index = FamilyContactIndex(family: [first, second])
        XCTAssertEqual(index.exactNicknameHolders(key), [first.id, second.id],
                       "both holders survive, in roster order")

        // Roster order is the ordering contract, not insertion luck:
        // the reversed roster answers in reversed order.
        let reversed = FamilyContactIndex(family: [second, first])
        XCTAssertEqual(reversed.exactNicknameHolders(key), [second.id, first.id])
    }

    func testRepeatedSpellingOnOneContactKeepsOneIDAndAllSpellings() {
        // Duplicates are preserved in the entry's raw spellings (the
        // family typed the same nickname twice — that is real data),
        // but the map must not report the SAME contact twice for one
        // key: downstream tiers read "holders", not "mentions".
        let contact = makeContact(name: "Sanu", nicknames: ["Buba", "buba!", " BUBA "])
        let index = FamilyContactIndex(family: [contact])

        XCTAssertEqual(index.entry(for: contact.id)?.rawNicknames,
                       ["Buba", "buba!", "BUBA"],
                       "stored spellings preserved in order (trimmed, never deduped)")
        XCTAssertEqual(index.idsByNickname["buba"], [contact.id],
                       "one key, one id — the repeated spelling does not duplicate the holder")
    }

    func testRebuildAfterStoreChangeDropsStaleIDsWithNoTornReads() {
        // "Given the store changes (nickname edited or contact removed)
        // / When the index rebuilds / Then stale ids are absent and the
        // previous index is not used (no torn reads across rebuild)".
        // The rebuild is wholesale into a NEW value; the old value is
        // never patched, so a reader holding it cannot observe a
        // half-updated index.
        let sita = makeContact(name: "Sita", nicknames: ["सानु"])
        let ram = makeContact(name: "Ram", nicknames: ["बुबा"])
        var index = FamilyContactIndex(family: [sita, ram])
        let before = index

        let editedSita = makeContact(name: "Sita", nicknames: ["सानी"], id: sita.id)
        index = FamilyContactIndex(family: [editedSita])

        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("सानु")), [],
                       "the edited-away nickname resolves nobody after the rebuild")
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("बुबा")), [],
                       "the removed contact leaves no id behind")
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("सानी")),
                       [sita.id],
                       "the edited nickname resolves under the same contact id")
        XCTAssertNil(index.entry(for: ram.id))
        XCTAssertEqual(index.entries.count, 1)

        XCTAssertEqual(before.exactNicknameHolders(NepaliTextNormalizer.normalize("सानु")),
                       [sita.id],
                       "the pre-rebuild value still answers its own snapshot — a value copy, not a view")
        XCTAssertEqual(before.exactNicknameHolders(NepaliTextNormalizer.normalize("सानी")), [])
        XCTAssertEqual(before.entries.count, 2)
        XCTAssertNotEqual(before, index)
    }

    // MARK: - Compatibility anchor: empty and nickname-less rosters

    func testEmptyIndexReproducesTodaysNameOnlyAnchor() {
        // The parity anchor (design-l1 §5.4): an empty index behaves
        // like today's search over an empty family — nothing matches,
        // nothing is invented.
        let empty = FamilyContactIndex.empty
        XCTAssertEqual(empty, FamilyContactIndex(family: []),
                       "the static value is the same index the initializer builds")
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertTrue(empty.idsByNickname.isEmpty)
        XCTAssertNil(empty.entry(for: UUID()))
        XCTAssertEqual(empty.nicknameEntries(for: UUID()), [])
        XCTAssertEqual(empty.exactNicknameHolders(NepaliTextNormalizer.normalize("आमा")), [])
        XCTAssertEqual(empty.exactNicknameHolders(""), [])
    }

    func testRosterWithoutNicknamesDegeneratesToNameOnlyIndex() {
        // "At empty nicknames it degenerates to exactly today's
        // name-only behavior" (design-l1 §5.4). No synthetic keys are
        // invented, and names live on the entries — the `.exactName`
        // tier reads `normalizedName`, NOT the nickname map.
        let sita = makeContact(name: "Sita")
        let hari = makeContact(name: "Hari", relationship: "छोरा")
        let index = FamilyContactIndex(family: [sita, hari])

        XCTAssertTrue(index.idsByNickname.isEmpty,
                      "a roster that never used nicknames produces no nickname keys")
        XCTAssertEqual(index.entries.map(\.normalizedName), ["sita", "hari"],
                       "names are normalized once at build time")
        XCTAssertEqual(index.entry(for: sita.id)?.rawNicknames, [])
        XCTAssertEqual(index.entry(for: sita.id)?.normalizedNicknames, [])
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("Sita")), [],
                       "the nickname map never answers for names")
    }

    func testLookupsForUnknownIDsAreEmpty() {
        let index = FamilyContactIndex(family: [makeContact(name: "Sita", nicknames: ["सानु"])])
        let stranger = UUID()
        XCTAssertNil(index.entry(for: stranger))
        XCTAssertEqual(index.nicknameEntries(for: stranger), [])
        XCTAssertEqual(index.exactNicknameHolders("nobody-holds-this"), [])
    }

    // MARK: - Shape: roster order, spellings, value semantics

    func testEntriesPreserveRosterOrderAndStoredSpellings() {
        let aama = makeContact(name: "Aama", nicknames: ["आमा", "Mummy"])
        let buba = makeContact(name: "Buba", nicknames: [], relationship: "बुबा")
        let sanu = makeContact(name: "Sanu", nicknames: ["सानु"])
        let roster = [aama, buba, sanu]

        let index = FamilyContactIndex(family: roster)
        XCTAssertEqual(index.entries.map(\.id), [aama.id, buba.id, sanu.id],
                       "roster order preserved")
        XCTAssertEqual(index.entry(for: aama.id)?.rawNicknames, ["आमा", "Mummy"],
                       "stored spellings, order preserved")
        XCTAssertEqual(index.entry(for: aama.id)?.normalizedNicknames,
                       [NepaliTextNormalizer.normalize("आमा"), NepaliTextNormalizer.normalize("Mummy")],
                       "normalized spellings align 1:1 with the raw ones")
        XCTAssertEqual(index.entry(for: buba.id)?.normalizedNicknames, [])
        XCTAssertEqual(index, FamilyContactIndex(family: roster),
                       "value type: the same roster builds an equal index")
    }

    func testBlankAndPunctuationOnlySpellingsNeverBecomeKeys() {
        // Whitespace-only entries are dropped by the shared projection;
        // a punctuation-only spelling survives as a stored string but
        // normalizes to "" — and "" is never a key, or an empty query
        // would "match" everyone (today's search treats an empty query
        // as no query at all).
        let contact = makeContact(name: "Sita", nicknames: ["   ", "।।", "सीता"])
        let index = FamilyContactIndex(family: [contact])

        XCTAssertEqual(index.entry(for: contact.id)?.rawNicknames, ["।।", "सीता"],
                       "whitespace-only entries dropped, punctuation-only spelling kept verbatim")
        XCTAssertNil(index.idsByNickname[""], "the empty key is never indexed")
        XCTAssertEqual(index.exactNicknameHolders(""), [])
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("सीता")),
                       [contact.id])
    }

    // MARK: - Migration seam: a legacy `nickname` payload feeds the index

    func testIndexBuiltFromALegacyNicknameFieldResolvesTheMigratedValue() {
        // The roster reaches the index THROUGH the model: a payload
        // written before the multi-nickname shape existed (the single
        // `nickname` key) decodes to a `FamilyContact` whose
        // `nicknames` array carries the migrated value (FR-FCU-011,
        // T-145 decoder — exercised directly, the store's read IS this
        // decode). The index must index the migrated value like any
        // other entry.
        let id = UUID()
        let legacyJSON: [String: Any] = [
            "id": id.uuidString,
            "name": "राम",
            "phone": "9812345678",
            "relationship": "छोरा",
            "nickname": "सानु",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: legacyJSON),
              let contact = try? JSONDecoder().decode(FamilyContact.self, from: data) else {
            return XCTFail("the legacy payload must decode through the production model")
        }
        XCTAssertEqual(contact.nicknames, ["सानु"],
                       "the legacy single value migrated into the array")

        let index = FamilyContactIndex(family: [contact])
        XCTAssertEqual(index.exactNicknameHolders(NepaliTextNormalizer.normalize("सानु")), [id])
        XCTAssertEqual(index.entry(for: id)?.normalizedName, NepaliTextNormalizer.normalize("राम"))
    }
}
