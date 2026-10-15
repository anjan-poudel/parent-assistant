import XCTest
@testable import ElderlyAssistant

/// Ack resolver and closed vocabulary (T-004 — FR-MSR-007, FR-MSR-008,
/// NFR-MSR-001, NFR-MSR-007): the HIGH-risk "never record the wrong
/// medication" container.
///
/// What these tests exist to hold:
///
/// - resolution is by what the elder said (name first, then slot), never
///   by firing order, pending order, or the order of the array handed in;
/// - a simple acknowledgement still resolves when exactly one reminder is
///   pending (and to what rang, when one of several rang — n-1);
/// - anything that does not identify exactly one reminder comes back as
///   `.ambiguous` / `.unmatched` / `.nothingPending` — a value, never a
///   guess — and every walk output carries the fixed order (`scheduledAt`,
///   canonical name, id);
/// - the pinned Devanagari grapheme-cluster behaviour is reused as-is and
///   is not "fixed" (NFR-MSR-007).
///
/// Runs under: `-only-testing:ElderlyAssistantTests/MedicationAckResolverTests`
/// (the W1 consolidated pass). No clock, no I/O, no coordinator: fixtures
/// carry fixed timestamps and fixed UUIDs so every expectation is exact.
final class MedicationAckResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func uuid(_ tail: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(tail)")!
    }

    private func candidate(name: String,
                           slot: MedicationSlot?,
                           fired: Bool = true,
                           at seconds: TimeInterval,
                           id: UUID,
                           extraVoiceKeys: [String] = []) -> MedicationAckCandidate {
        var seen = Set<String>()
        let voiceKeys = ([MedicationVoiceVocabulary.canonical(name)]
                         + extraVoiceKeys.map(MedicationVoiceVocabulary.canonical))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return MedicationAckCandidate(entryId: id,
                                      scheduledAt: Date(timeIntervalSince1970: seconds),
                                      fired: fired,
                                      slot: slot,
                                      voiceKeys: voiceKeys,
                                      medicationName: name)
    }

    /// The fixed ordering, computed independently of the resolver: the
    /// walk-output contract is `scheduledAt`, then canonical name, then id.
    private func fixedOrderIDs(_ candidates: [MedicationAckCandidate]) -> [UUID] {
        candidates.sorted { left, right in
            if left.scheduledAt != right.scheduledAt {
                return left.scheduledAt < right.scheduledAt
            }
            let leftName = MedicationVoiceVocabulary.canonical(left.medicationName)
            let rightName = MedicationVoiceVocabulary.canonical(right.medicationName)
            if leftName != rightName { return leftName < rightName }
            return left.entryId.uuidString < right.entryId.uuidString
        }.map(\.entryId)
    }

    /// Every ordering of the array handed in — "the candidate order handed
    /// in is the coordinator's canonical sort; the resolver may never read
    /// it as resolution input".
    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for index in items.indices {
            var rest = items
            let head = rest.remove(at: index)
            for tail in permutations(of: rest) {
                result.append([head] + tail)
            }
        }
        return result
    }

    // MARK: - Scenario: the elder names the medication and the slot

    func testNameAndSlotResolvesToNamedEntry() {
        // Gherkin: "Given the morning slot has a pending reminder for
        // 'Amlodipine' / When the elder says 'I have taken Amlodipine for
        // morning before meal' / Then the utterance resolves to that
        // reminder and its entry". The safety sequence (FR-MSR-009)
        // continues from this value downstream — this resolver only names
        // the entry; it never records.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning,
                                   at: 1_000, id: uuid("a1"))

        let resolution = MedicationAckResolver.resolve(
            utterance: "I have taken Amlodipine for morning before meal",
            candidates: [amlodipine])

        XCTAssertEqual(resolution, .resolved(entryId: amlodipine.entryId))
        // The meal words were present and did not have to be: the same
        // utterance without them is the same value (meal is context only).
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I have taken Amlodipine for morning",
                                          candidates: [amlodipine]),
            resolution)
    }

    // MARK: - Scenario: several medications share the slot — the named one resolves

    func testNameOnlyResolvesWhenUnique() {
        // "Then the resolution was driven by what the elder said, not by
        // firing or pending order." Metformin carries the EARLIER
        // scheduledAt, sits FIRST in the array and is the one that rang; a
        // resolver that preferred firing order, pending order or recency
        // would pick it. The elder named Amlodipine.
        let metformin = candidate(name: "Metformin", slot: .morning, fired: true,
                                  at: 900, id: uuid("b2"))
        let amlodipine = candidate(name: "Amlodipine", slot: .morning, fired: false,
                                   at: 1_000, id: uuid("a1"))

        let resolution = MedicationAckResolver.resolve(
            utterance: "I have taken Amlodipine",
            candidates: [metformin, amlodipine])

        XCTAssertEqual(resolution, .resolved(entryId: amlodipine.entryId))
    }

    func testSlotOnlyResolvesWhenUniqueInSlot() {
        // No name, slot named: the pending set narrows to that slot. The
        // legacy entry (slot nil) is pending too and never absorbs a slot
        // word — no inference over its raw clock time.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning,
                                   at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .evening,
                                  at: 900, id: uuid("b2"))
        let legacy = candidate(name: "Old pill", slot: nil,
                               at: 800, id: uuid("d4"))

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took it in the morning",
                                          candidates: [metformin, legacy, amlodipine]),
            .resolved(entryId: amlodipine.entryId))

        // The same utterance with ONLY the legacy entry pending: the slot
        // word matches no pending entry (nil is not morning) — unmatched,
        // never a fall-through to the legacy entry.
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took it in the morning",
                                          candidates: [legacy]),
            .unmatched(orderedPending: [legacy.entryId]))
    }

    // MARK: - Scenario: a simple acknowledgement still works when unambiguous

    func testSingleCandidateAckResolves() {
        // "Given exactly one reminder is pending / When the elder says
        // 'Taken' / Then the acknowledgement resolves to that pending
        // reminder / And the elder was not required to name the
        // medication." Works whether or not the reminder has rung — the
        // not-yet-rung case is the shipped early-acknowledgement behaviour.
        let notYetRung = candidate(name: "Metformin", slot: .morning, fired: false,
                                   at: 1_000, id: uuid("b2"))
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "Taken", candidates: [notYetRung]),
            .resolved(entryId: notYetRung.entryId))

        let rung = candidate(name: "Metformin", slot: .morning, fired: true,
                             at: 1_000, id: uuid("b2"))
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "Taken", candidates: [rung]),
            .resolved(entryId: rung.entryId))

        // The owner's Nepali shape works the same way.
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "औषधि खाएँ", candidates: [rung]),
            .resolved(entryId: rung.entryId))
    }

    // MARK: - Scenario: a simple acknowledgement with several sharing the slot is not guessed

    func testSimpleAckWithSharedSlotIsAmbiguous() {
        // "Given the morning slot has pending reminders for 'Amlodipine'
        // and 'Metformin' / When the elder says 'Taken' / Then no
        // medication is chosen by firing order / And the resolution is
        // ambiguous and defers to the sanctioned clarification". Nothing
        // is recorded until the clarification resolves — downstream.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning,
                                   at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .morning,
                                  at: 980, id: uuid("b2"))

        let forward = MedicationAckResolver.resolve(utterance: "Taken",
                                                    candidates: [amlodipine, metformin])
        XCTAssertEqual(forward, .ambiguous(ordered: [metformin.entryId, amlodipine.entryId]))

        // Handed in the other way round, the same value: the walk order is
        // the fixed order, never the order handed in.
        let reversed = MedicationAckResolver.resolve(utterance: "Taken",
                                                     candidates: [metformin, amlodipine])
        XCTAssertEqual(reversed, forward)

        if case .resolved = forward {
            XCTFail("a simple ack over a shared slot must never resolve to a pick")
        }

        // Neither has rung either: still ambiguous — the all-pending
        // branch must not slip into picking one.
        let noneRung = [candidate(name: "Amlodipine", slot: .morning, fired: false,
                                  at: 1_000, id: uuid("a1")),
                        candidate(name: "Metformin", slot: .morning, fired: false,
                                  at: 980, id: uuid("b2"))]
        XCTAssertEqual(MedicationAckResolver.resolve(utterance: "Taken", candidates: noneRung),
                       forward)
    }

    // MARK: - Determinism and the ordering contract

    func testResolutionIsDeterministicAcrossRepeatedCalls() {
        // FR-MSR-008: "The same ambiguous utterance against the same
        // pending set produces the same clarification, every time."
        let amlodipine = candidate(name: "Amlodipine", slot: .morning,
                                   at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .morning,
                                  at: 980, id: uuid("b2"))
        let vitamin = candidate(name: "भिटामिन", slot: .evening, fired: false,
                                at: 1_100, id: uuid("c3"))

        let cases: [(String, [MedicationAckCandidate])] = [
            ("I have taken Amlodipine for morning before meal", [amlodipine, metformin]),
            ("Taken", [amlodipine, metformin]),
            ("I took it in the evening", [amlodipine, metformin, vitamin]),
            ("I took it in the afternoon", [amlodipine, metformin, vitamin]),
            ("", [metformin])
        ]

        for (utterance, candidates) in cases {
            let first = MedicationAckResolver.resolve(utterance: utterance, candidates: candidates)
            let second = MedicationAckResolver.resolve(utterance: utterance, candidates: candidates)
            XCTAssertEqual(first, second, "same inputs, same output: \(utterance)")
        }
    }

    func testWalkOutputOrderIsScheduledAtThenNameThenId() {
        // The fixed order is a contract for every walk output, derived
        // from candidate facts alone.
        let gamma = candidate(name: "Gamma", slot: .morning, at: 400, id: uuid("c3"))
        let beta = candidate(name: "Beta", slot: .morning, at: 500, id: uuid("b2"))
        let alpha = candidate(name: "Alpha", slot: .morning, at: 500, id: uuid("a1"))

        // scheduledAt first (Gamma 400 before 500), then canonical name
        // among equal times (Alpha before Beta) — handed in the reverse
        // order on purpose.
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took it in the afternoon",
                                          candidates: [alpha, beta, gamma]),
            .unmatched(orderedPending: [gamma.entryId, alpha.entryId, beta.entryId]))

        // Equal time AND equal name: the id tiebreak keeps the order total.
        let metforminHigh = candidate(name: "Metformin", slot: .morning,
                                      at: 500, id: uuid("f1"))
        let metforminLow = candidate(name: "Metformin", slot: .morning,
                                     at: 500, id: uuid("0a"))
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "Taken",
                                          candidates: [metforminHigh, metforminLow]),
            .ambiguous(ordered: [metforminLow.entryId, metforminHigh.entryId]))
    }

    // MARK: - The property sweep

    func testNoInputEverResolvesToANonPendingEntry() {
        // The truth-table sweep: every (utterance, candidate set) pair the
        // suite can reach. `.resolved` may only ever name a pending entry;
        // `.ambiguous`/`.unmatched` may only ever list pending entries,
        // without duplicates; `.nothingPending` only when nothing is
        // pending. And rotating/reversing the handed-in array must not
        // change any value — the resolver may never read input order.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning, at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .morning, at: 900, id: uuid("b2"))
        let vitamin = candidate(name: "भिटामिन", slot: .evening, fired: false, at: 1_100, id: uuid("c3"))
        let legacy = candidate(name: "Old pill", slot: nil, fired: false, at: 800, id: uuid("d4"))

        let sets: [[MedicationAckCandidate]] = [
            [],
            [metformin],
            [amlodipine, metformin],
            [metformin, vitamin, legacy]
        ]
        let utterances = [
            "Taken",
            "",
            "   ",
            "I have taken Amlodipine for morning before meal",
            "I have taken Metformin",
            "morning",
            "I took it in the evening",
            "भिटामिन",
            "औषधि खाएँ बिहान",
            "yellow pill"
        ]

        for candidates in sets {
            let pendingIds = Set(candidates.map(\.entryId))
            for handedIn in permutations(of: candidates) {
                for utterance in utterances {
                    let result = MedicationAckResolver.resolve(utterance: utterance,
                                                              candidates: handedIn)
                    switch result {
                    case .resolved(let entryId):
                        XCTAssertTrue(pendingIds.contains(entryId),
                                      "'\(utterance)' resolved to a non-pending entry")
                    case .ambiguous(let ordered):
                        XCTAssertFalse(ordered.isEmpty, "'\(utterance)' walked over nothing")
                        XCTAssertEqual(Set(ordered).count, ordered.count,
                                       "'\(utterance)' listed a candidate twice")
                        XCTAssertTrue(Set(ordered).isSubset(of: pendingIds),
                                      "'\(utterance)' walked over a non-pending entry")
                    case .unmatched(let orderedPending):
                        XCTAssertEqual(orderedPending, fixedOrderIDs(candidates),
                                       "'\(utterance)' must carry the FULL pending set in fixed order")
                    case .nothingPending:
                        XCTAssertTrue(candidates.isEmpty,
                                      "'\(utterance)' claimed nothing pending while entries are pending")
                    }
                    XCTAssertEqual(result,
                                   MedicationAckResolver.resolve(utterance: utterance,
                                                                 candidates: handedIn),
                                   "same inputs, same output: '\(utterance)'")
                }
            }
        }
    }

    func testNothingPendingIsAValueNotAnError() {
        // The empty case is expressed by `AckResolution.nothingPending`
        // (design-l2 IF-7): no error path, nothing thrown, whatever was
        // said — including a fully named acknowledgement.
        let utterances = [
            "Taken",
            "I have taken Amlodipine for morning before meal",
            "morning",
            "औषधि खाएँ",
            "",
            "   "
        ]
        for utterance in utterances {
            XCTAssertEqual(MedicationAckResolver.resolve(utterance: utterance, candidates: []),
                           .nothingPending,
                           "'\(utterance)' with nothing pending must be the empty value")
        }
    }

    // MARK: - The Devanagari pin (NFR-MSR-007)

    func testContainmentSemanticsRespected() {
        // The shipped Character-cluster substring containment, pinned and
        // NOT "fixed": "भिटाम" ([भि][टा][म]) is one vowel sign short of
        // "भिटामिन" ([भि][टा][मि][न]), so the short spelling is a
        // different string and must NOT match — the house pin
        // ("छोर" does not occur in "छोरी"), the same discipline applied to
        // the acknowledgement vocabulary.
        XCTAssertEqual("भिटामिन".count, 4, "fixture guard: [भि][टा][मि][न]")
        XCTAssertEqual("भिटाम".count, 3, "fixture guard: [भि][टा][म]")

        XCTAssertTrue(MedicationAckVocabulary.containsKey("भिटामिन", inCanonical: "भिटामिन"))
        XCTAssertFalse(MedicationAckVocabulary.containsKey("भिटाम", inCanonical: "भिटामिन"),
                       "one vowel sign short is a different cluster and must not match")
        XCTAssertTrue(MedicationAckVocabulary.containsKey("भिटाम", inCanonical: "भिटाम"))

        // The fusion the phrase mode exists for stays intact: a
        // postposition fused onto the stem still contains the stem.
        XCTAssertTrue(MedicationAckVocabulary.containsKey("राति", inCanonical: "रातिको औषधि"))

        // And the pin holds through the resolver: the partial spelling does
        // not claim the vitamin entry (the named slot then walks both
        // morning candidates), while the exact spelling resolves it.
        let vitamin = candidate(name: "भिटामिन", slot: .morning, at: 1_000, id: uuid("c3"))
        let amlodipine = candidate(name: "Amlodipine", slot: .morning, at: 900, id: uuid("a1"))

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took भिटाम for morning",
                                          candidates: [vitamin, amlodipine]),
            .ambiguous(ordered: [amlodipine.entryId, vitamin.entryId]),
            "the one-vowel-sign-short spelling must not resolve to the stored entry")

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took भिटामिन",
                                          candidates: [vitamin, amlodipine]),
            .resolved(entryId: vitamin.entryId))
    }

    // MARK: - The remaining honest outcomes

    func testUnmatchedCarriesEveryPendingIdInFixedOrder() {
        // Slot named, nothing pending there: honest, and never a
        // fall-through to another slot. The payload is the FULL ordered
        // pending set so the caller can run the sanctioned fallback over it.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning,
                                   at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .evening,
                                  at: 900, id: uuid("b2"))

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took it in the afternoon",
                                          candidates: [amlodipine, metformin]),
            .unmatched(orderedPending: [metformin.entryId, amlodipine.entryId]))
    }

    func testSimpleAckPrefersTheFiredReminder() {
        // n-1 (accepted, review-l1): "taken" with no further information
        // refers to what rang. Exactly one of two pending has rung →
        // resolved to it; none has rung → ambiguous, never a pick.
        let rung = candidate(name: "Metformin", slot: .morning, fired: true,
                             at: 900, id: uuid("b2"))
        let notRung = candidate(name: "Amlodipine", slot: .morning, fired: false,
                                at: 1_000, id: uuid("a1"))

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "Taken", candidates: [notRung, rung]),
            .resolved(entryId: rung.entryId))

        let metforminNotRung = candidate(name: "Metformin", slot: .morning, fired: false,
                                         at: 900, id: uuid("b2"))
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "Taken",
                                          candidates: [notRung, metforminNotRung]),
            .ambiguous(ordered: [metforminNotRung.entryId, notRung.entryId]))
    }

    func testNameConflictingWithSlotStaysAmbiguous() {
        // Name matches but no name-match carries the named slot: one of
        // the two statements is wrong, so the name is not trusted over the
        // slot either — the walk asks (here with its single sanctioned
        // form, over the name-match set).
        let legacy = candidate(name: "Amlodipine", slot: nil, at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .morning, at: 900, id: uuid("b2"))

        let resolution = MedicationAckResolver.resolve(
            utterance: "I have taken Amlodipine for morning",
            candidates: [metformin, legacy])

        XCTAssertEqual(resolution, .ambiguous(ordered: [legacy.entryId]))
        if case .resolved = resolution {
            XCTFail("a name/slot conflict must never resolve")
        }
    }

    func testPurposeVoiceKeyResolvesLikeAName() {
        // Name keys come from the candidate's `voiceKeys` (IF-7), never
        // from `medicationName` on its own: the elder may say what the
        // medicine is FOR, and the purpose keys are part of the one voice
        // vocabulary.
        let bloodPressure = candidate(name: "Amlodipine", slot: .morning, at: 1_000,
                                      id: uuid("a1"),
                                      extraVoiceKeys: ["रक्तचाप", "blood pressure", "pressure"])
        let metformin = candidate(name: "Metformin", slot: .morning, at: 900, id: uuid("b2"))

        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I took my blood pressure medicine for morning",
                                          candidates: [metformin, bloodPressure]),
            .resolved(entryId: bloodPressure.entryId))

        // The same candidate with NO voice keys answers to nothing: the
        // medicationName alone is not a matching key, and the simple-ack
        // path then sees two pending and walks.
        let keyless = candidate(name: "Amlodipine", slot: .morning, at: 1_000, id: uuid("a1"))
        let muted = MedicationAckCandidate(entryId: keyless.entryId,
                                           scheduledAt: keyless.scheduledAt,
                                           fired: keyless.fired,
                                           slot: keyless.slot,
                                           voiceKeys: [],
                                           medicationName: keyless.medicationName)
        XCTAssertEqual(
            MedicationAckResolver.resolve(utterance: "I have taken Amlodipine",
                                          candidates: [metformin, muted]),
            .ambiguous(ordered: [metformin.entryId, muted.entryId]))
    }

    // MARK: - The closed vocabulary

    func testSlotWordsMirrorTheScannerFamilies() {
        // One vocabulary, not two inventions: every word family the label
        // scanner knows maps onto the resolver's slot family for that
        // word's hour (the pinned hour table, m-3: 8 → morning; 12 and 13
        // → afternoon; 19, 20 and 21 → evening).
        let slotForHour: [Int: MedicationSlot] = [8: .morning,
                                                  12: .afternoon,
                                                  13: .afternoon,
                                                  19: .evening,
                                                  20: .evening,
                                                  21: .evening]

        for row in MedicationLabelParser.timeWordHours {
            guard let slot = slotForHour[row.hour] else {
                XCTFail("scanner hour \(row.hour) is outside the pinned hour table")
                continue
            }
            for word in row.words {
                XCTAssertTrue(MedicationAckVocabulary.slotWords[slot]?.contains(word) ?? false,
                              "'\(word)' (\(row.hour):00) must live in the \(slot.rawValue) family")
            }
        }
    }

    func testMealWordsAreRecognisedButNeverDiscriminate() {
        // Recognised, both languages …
        XCTAssertEqual(MedicationAckVocabulary.mealRelation(inCanonical: "i took it before meal"),
                       .beforeMeal)
        XCTAssertEqual(MedicationAckVocabulary.mealRelation(inCanonical: "खानु अघि औषधि खाएँ"),
                       .beforeMeal)
        XCTAssertEqual(MedicationAckVocabulary.mealRelation(inCanonical: "after food"),
                       .afterMeal)
        XCTAssertEqual(MedicationAckVocabulary.mealRelation(inCanonical: "खाना खाएपछि"),
                       .afterMeal)
        XCTAssertNil(MedicationAckVocabulary.mealRelation(inCanonical: "i took it"),
                     "no meal word is no relation")
        XCTAssertNil(MedicationAckVocabulary.mealRelation(inCanonical: "before meal after meal"),
                     "both relations state no single one")
        XCTAssertNil(MedicationAckVocabulary.mealRelation(
            inCanonical: MedicationVoiceVocabulary.canonical("  ")))

        // … and never an input to resolution (OD-1): the meal words never
        // filter, discriminate or select, so adding them to an utterance
        // must not change a single outcome.
        let amlodipine = candidate(name: "Amlodipine", slot: .morning, at: 1_000, id: uuid("a1"))
        let metformin = candidate(name: "Metformin", slot: .morning, at: 900, id: uuid("b2"))
        let bases = [
            "I have taken Amlodipine for morning",
            "Taken",
            "I took it in the morning",
            "I took my blood pressure medicine"
        ]
        let suffixes = ["", " before meal", " after food", " खानु अघि", " खानु पछि"]

        for base in bases {
            let expected = MedicationAckResolver.resolve(utterance: base,
                                                         candidates: [amlodipine, metformin])
            for suffix in suffixes {
                XCTAssertEqual(
                    MedicationAckResolver.resolve(utterance: base + suffix,
                                                  candidates: [amlodipine, metformin]),
                    expected,
                    "'\(base)' must resolve the same with '\(suffix)'")
            }
        }
    }
}
