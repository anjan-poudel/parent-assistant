import XCTest
@testable import ElderlyAssistant

/// The call surface's unified one-person presentation (family-contacts-unify
/// T-161; design-l1 §7.2, design-l2 §3.5, §7, §8.2):
///
///  1. the synthesized result row's alt caption — "Also in your phone book
///     as %@" — composed by the ONE pure seam (`CallResultRowText`) from the
///     search outcome's `linkedBookNames` map, so the caption parity claim
///     (one frozen key, one wording) is pinnable without a view instance:
///     book-side-only matches carry it, family-side matches and unlinked
///     pairs carry none, and an empty stored name is suppressed;
///  2. the CallView `.limited` gate shape — the T-148b LeafViews
///     obligations (design-l2 §3.5): every equality check moves to
///     `allowsReading`, `.denied` stays the only blocked arm, the honest
///     `call.search.accessLimited` caption leads the readable block, and
///     the result rows read the coordinator's PUBLISHED index + verified
///     links instead of the interim inline rebuild;
///  3. the caption/face wiring the runtime cannot reach — source pins over
///     the delivered regions (the `FeatureSourceScan` house convention,
///     comments stripped). The dial layer call-dialer contributed (the
///     channel state, the hop threading, `ContactTile`) is pinned as
///     SURVIVING here — T-161 unions with it, never replaces it.
final class CallViewFacesAndCaptionTests: XCTestCase {

    // MARK: - Fixtures

    /// The linked-pair fixture the search suites use: the family phone
    /// normalizes to "9779841000001" while the book row's is
    /// "9841000001" — only the verified link can prove one person, and
    /// only a book-SIDE query reaches the synthesized row (the family
    /// name "Sita" cannot match the Devanagari book spelling).
    private func linkedPair() -> (family: FamilyContact, bookRow: AddressBookEntry,
                                  links: VerifiedLinksSnapshot) {
        let family = FamilyContact(
            name: "Sita", phone: "+977 9841 000001", relationship: "छोरी",
            systemContact: SystemContactLink(identifier: "rec-sita",
                                             numberKey: "9779841000001"))
        let row = AddressBookEntry(name: "सीता शर्मा", label: "mobile", phone: "9841 000001",
                                   normalized: "9841000001", identifier: "rec-sita")
        return (family, row, snapshot([family.id: "rec-sita"]))
    }

    private func snapshot(_ links: [UUID: String],
                          generation: UInt64 = 1) -> VerifiedLinksSnapshot {
        VerifiedLinksSnapshot(
            links: links.mapValues { SystemContactLink(identifier: $0, numberKey: "") },
            linkedRecordNumbers: [:],
            generation: generation)
    }

    private var english: Locale { Locale(identifier: "en-US") }
    private var nepali: Locale { Locale(identifier: "ne-NP") }

    // MARK: - The synthesized-row caption (pure composition)

    /// The end-to-end shape FR-FCU-004's call-surface scenario is about:
    /// a query matching only the phone-book spelling of a VERIFIED-LINKED
    /// person yields the family row, and that row's caption names the
    /// book record — the frozen wording, the book name verbatim.
    func testBookSideOnlyMatchComposesTheFrozenCaptionWithTheBookName() throws {
        let pair = linkedPair()
        let index = FamilyContactIndex(family: [pair.family])
        let outcome = UnifiedContactSearch.search(query: "शर्मा",
                                                  family: [pair.family], index: index,
                                                  in: [pair.bookRow],
                                                  verifiedLinks: pair.links)
        XCTAssertEqual(outcome.entries, [.family(pair.family)])
        let row = try XCTUnwrap(outcome.entries.first)

        let caption = try XCTUnwrap(CallResultRowText.linkedBookCaption(
            for: row, in: outcome, locale: english))
        XCTAssertEqual(caption, "Also in your phone book as सीता शर्मा",
                       "the frozen call.search.linkedBookName wording, book name verbatim")
        XCTAssertTrue(caption.contains("सीता शर्मा"),
                      "the caption must carry the phone-book name it explains")
    }

    /// The unlinked anchor (FR-FCU-003 parity): without a verified link
    /// nothing is synthesized, the map stays empty, and NO row — family
    /// or book — earns a caption. Today's two-row outcome, today's
    /// layout exactly.
    func testUnlinkedPairKeepsTodaysRowsAndGetsNoCaption() {
        let family = FamilyContact(name: "Sita", phone: "+977 9841 000001",
                                   relationship: "छोरी")
        // The book twin's number SPELLS differently ("9841 000001" vs
        // "+977 9841 000001"), so the number rule cannot see one person
        // and no link exists — today's two-row outcome exactly (the
        // unlinked anchor the search suite pins too).
        let twin = AddressBookEntry(name: "सीता शर्मा", label: "mobile",
                                    phone: "9841 000001", normalized: "9841000001")
        let outcome = UnifiedContactSearch.search(query: "9841 000001",
                                                  family: [family],
                                                  index: FamilyContactIndex(family: [family]),
                                                  in: [twin])
        XCTAssertEqual(outcome.entries, [.family(family), .addressBook(twin)])
        XCTAssertTrue(outcome.linkedBookNames.isEmpty)
        for row in outcome.entries {
            XCTAssertNil(CallResultRowText.linkedBookCaption(for: row, in: outcome,
                                                             locale: english),
                         "no synthesized row exists to explain")
        }
    }

    /// The map is keyed by the FAMILY result id only: a hand-built
    /// outcome carrying an entry must hand exactly that family row the
    /// caption and leave the book row (id = its normalized number)
    /// untouched — a book row is never synthesized and never earns the
    /// caption.
    func testOnlyTheFamilyRowKeyedInTheMapCarriesTheCaption() {
        let family = FamilyContact(name: "Sita", phone: "9841000000", relationship: "छोरी")
        let book = AddressBookEntry(name: "Sita Sharma", label: "mobile",
                                    phone: "9841000001", normalized: "9841000001")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(family), .addressBook(book)],
            moreAvailable: false,
            linkedBookNames: ["family-\(family.id.uuidString)": "Sita Sharma"])
        XCTAssertEqual(CallResultRowText.linkedBookCaption(for: .family(family),
                                                           in: outcome, locale: english),
                       "Also in your phone book as Sita Sharma")
        XCTAssertNil(CallResultRowText.linkedBookCaption(for: .addressBook(book),
                                                         in: outcome, locale: english),
                     "the map's keys are family result ids — a book row can never match one")
    }

    /// A blank stored name is suppressed, not rendered: an empty value
    /// must never produce a dangling "…as " that claims an identity the
    /// app does not have (the honesty rule the whole feature rides on).
    func testEmptyStoredBookNameIsSuppressedNotRendered() {
        let family = FamilyContact(name: "Sita", phone: "9841000000", relationship: "छोरी")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(family)], moreAvailable: false,
            linkedBookNames: ["family-\(family.id.uuidString)": ""])
        XCTAssertNil(CallResultRowText.linkedBookCaption(for: .family(family),
                                                         in: outcome, locale: english))
    }

    /// The caption resolves through the frozen catalog key in both app
    /// languages (NFR-FCU-004): the ne wording, the book name placed by
    /// the key's own `%@`, and the two languages never agreeing.
    func testCaptionResolvesTheFrozenKeyInBothLanguages() throws {
        let family = FamilyContact(name: "Sita", phone: "9841000000", relationship: "छोरी")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(family)], moreAvailable: false,
            linkedBookNames: ["family-\(family.id.uuidString)": "सीता शर्मा"])
        let row = UnifiedContactSearch.Result.family(family)

        let en = try XCTUnwrap(CallResultRowText.linkedBookCaption(for: row, in: outcome,
                                                                   locale: english))
        let ne = try XCTUnwrap(CallResultRowText.linkedBookCaption(for: row, in: outcome,
                                                                   locale: nepali))
        XCTAssertEqual(en, "Also in your phone book as सीता शर्मा")
        XCTAssertEqual(ne, "फोनबुकमा सीता शर्मा को रूपमा पनि छ")
        XCTAssertNotEqual(en, ne)
    }

    // MARK: - The `.limited` gate shape (T-148b LeafViews obligations)

    /// Every CallView equality gate enumerated by design-l2 §3.5 reads
    /// `allowsReading`: `.limited` takes today's `.allowed` display path
    /// (field, entries, mic), `.denied` stays the only blocked arm, and
    /// no `== .allowed` comparison survives anywhere in the file — a
    /// reverted gate fails this scan.
    func testEveryCallViewReadableGateReadsAllowsReading() throws {
        let leaf = leafSource()
        XCTAssertEqual(occurrences(of: "== .allowed", in: leaf), 0,
                       "the call surface gates on allowsReading — .limited is readable")

        let searchArea = try region(between: "private var searchArea: some View {",
                                    and: "private func refreshDirectory()", in: leaf)
        XCTAssertEqual(occurrences(of: "access?.allowsReading == true", in: searchArea), 2,
                       "the field row AND the readable display block both gate on allowsReading")
        XCTAssertTrue(searchArea.contains("} else if access == .denied {"),
                      ".denied stays the only blocked arm")
        XCTAssertTrue(searchArea.contains("} else if access == .notDetermined {"),
                      "the point-of-use ask arm is untouched")
        let readableGate = try XCTUnwrap(searchArea.range(of: "access?.allowsReading == true"))
        let limitedCaption = try XCTUnwrap(searchArea.range(of: "call.search.accessLimited"))
        XCTAssertLessThan(readableGate.lowerBound, limitedCaption.lowerBound,
                          "the limited caption renders INSIDE the readable block — .limited "
                          + "can never take the blocked/ask arms")

        let refresh = try region(between: "private func refreshDirectory() {",
                                 and: "private func grantAccess() {", in: leaf)
        XCTAssertTrue(refresh.contains("guard status.allowsReading else { return }"),
                      "a limited grant still loads its granted set")

        let grant = try region(between: "private func grantAccess() {",
                               and: "private func loadEntries() {", in: leaf)
        XCTAssertTrue(grant.contains("if access?.allowsReading == true {"),
                      "the load decision reads the RE-READ status — the sheet may yield .limited")
        XCTAssertTrue(grant.contains("_ = await directory.requestAccess()"),
                      "never the binary request result (design-l2 §3.5)")
        XCTAssertFalse(grant.contains("if granted"),
                       "the granted == false shape would collapse a limited selection")

        let micVisible = try region(between: "private var micButtonVisible: Bool {",
                                    and: "private func updateMicVisibility() {", in: leaf)
        XCTAssertTrue(micVisible.contains(
            "guard !micHidden, access?.allowsReading == true else { return false }"),
                      "the mic follows the readable states")

        let announce = try region(between: "private func announceVoiceResultIfReady() {",
                                  and: "private func dial(_ result:", in: leaf)
        XCTAssertTrue(announce.contains("access?.allowsReading == true"),
                      "a voiced search announces over a limited book too")
    }

    /// The honest `.limited` caption: the frozen key rendered as the
    /// FIRST line of the readable block — directly under the field row
    /// and above the mic caption (design-l2 §3.5's decided placement),
    /// caption token, secondary color, one line.
    func testAccessLimitedCaptionLeadsTheReadableBlock() throws {
        let leaf = leafSource()
        let searchArea = try region(between: "private var searchArea: some View {",
                                    and: "private func refreshDirectory()", in: leaf)
        XCTAssertEqual(occurrences(of: "call.search.accessLimited", in: searchArea), 1,
                       "exactly one caption site in the search area")

        let fieldRow = try XCTUnwrap(searchArea.range(of: "searchField"),
                                     "the field row is the caption's anchor")
        let caption = try XCTUnwrap(searchArea.range(of: "call.search.accessLimited"))
        let micCaption = try XCTUnwrap(searchArea.range(of: "micCaption"))
        XCTAssertLessThan(fieldRow.lowerBound, caption.lowerBound,
                          "the caption sits under the field row")
        XCTAssertLessThan(caption.lowerBound, micCaption.lowerBound,
                          "the caption is the FIRST line of the readable block, above micCaption")

        XCTAssertTrue(collapsed(searchArea).contains(collapsed("""
            if access == .limited {
                Text(L10n.str("call.search.accessLimited", locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "caption token, secondary color, one line (design-l2 §3.5)")
    }

    // MARK: - Source pins (caption + row wiring the runtime cannot reach)

    /// The row's caption seam is exactly the design's: a defaulted
    /// `String?` (every existing construction keeps compiling), rendered
    /// as its own line only when non-nil, and the initials fallback
    /// stands so a photo-less row is never blank. The call-dialer dial
    /// inputs all survive — T-161 ADDS to this row, it replaces nothing
    /// (design-l1 §11.3, the exact seam contact with call-dialer).
    func testResultRowCaptionSeamAndDialInputsArePinnedAtTheSource() throws {
        let leaf = leafSource()
        let row = try region(between: "private struct UnifiedContactResultRow: View {",
                             and: "enum CallResultRowText {", in: leaf)

        XCTAssertTrue(row.contains("var caption: String? = nil"),
                      "the design-l1 §7.2 seam: defaulted, so existing constructions compile")
        XCTAssertTrue(row.contains("if let caption {"),
                      "nil renders no line — today's layout exactly")
        XCTAssertTrue(row.contains("Text(caption)"))
        XCTAssertTrue(row.contains(
            "FaceAvatar(name: result.name, diameter: Self.avatarDiameter)"),
                      "no photo anywhere → the initials avatar, never a blank circle")

        for seam in ["let channelState: RowChannelState",
                     "let dial: () -> Void",
                     "let whatsApp: () -> Void",
                     "let chooseChannel: (CallApp) -> Void",
                     "let addHandle: () -> Void"] {
            XCTAssertTrue(row.contains(seam),
                          "the call-dialer dial input `\(seam)` must survive the caption addition")
        }
    }

    /// The composition seam: `CallView` passes the caption through the
    /// ONE pure composer, fed by the outcome it is rendering — the
    /// lookup and the frozen key live in exactly one place, so the
    /// caption can never drift from the outcome's synthesized rows.
    func testTheCaptionIsComposedFromTheRenderedOutcomeInOnePlace() throws {
        let leaf = leafSource()
        let results = try region(between: "private var resultsArea: some View {",
                                 and: "private var familyArea: some View {", in: leaf)
        XCTAssertEqual(occurrences(of: "CallResultRowText.linkedBookCaption(", in: results), 1,
                       "one caption call site, keyed to the rendered outcome")
        XCTAssertTrue(collapsed(results).contains(collapsed("""
            caption: CallResultRowText.linkedBookCaption(
                for: result, in: outcome,
                locale: coordinator.activeLocale),
            """).trimmingCharacters(in: .whitespaces)),
                      "the row receives the caption composed from the SAME outcome it renders")

        let composer = try region(between: "enum CallResultRowText {",
                                  and: "struct ContactTile: View {", in: leaf)
        XCTAssertEqual(occurrences(of: "call.search.linkedBookName", in: composer), 1,
                       "the frozen key lives in the composer — nowhere else on the call surface")
        XCTAssertEqual(occurrences(of: "outcome.linkedBookNames[result.id]", in: composer), 1,
                       "the caption is the map's value for THIS row's id")
        XCTAssertTrue(composer.contains("!bookName.isEmpty"),
                      "a blank stored name is suppressed, never rendered")
        XCTAssertTrue(composer.contains(
            "return L10n.fmt(\"call.search.linkedBookName\", locale: locale, bookName)"),
                      "the frozen key, formatted with the book name")
    }

    /// The T-156 handoff discharged: every CallView search reads the
    /// coordinator's PUBLISHED index and verified-link snapshot — the
    /// interim inline `FamilyContactIndex(family:)` rebuilds are gone,
    /// so the rows, the announced name and the resolved faces can never
    /// disagree about who is linked.
    func testEveryCallViewSearchReadsThePublishedIndexAndLinks() {
        let leaf = leafSource()
        XCTAssertEqual(occurrences(of: "FamilyContactIndex(family:", in: leaf), 0,
                       "the interim inline index rebuild must not survive (T-156 handoff)")
        XCTAssertEqual(occurrences(of: "UnifiedContactSearch.search(", in: leaf), 3,
                       "three call-surface search sites: the face pass, the announce pass, the rows")
        XCTAssertEqual(occurrences(of: "index: coordinator.familyIndex", in: leaf), 3,
                       "every search site reads the published index")
        XCTAssertEqual(occurrences(of: "verifiedLinks: coordinator.verifiedLinks", in: leaf), 3,
                       "every search site reads the published verified-link snapshot")
    }

    // MARK: - Helpers (the house source-scan patterns)

    private func leafSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/LeafViews.swift"))
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `MissedCallDialBackTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "LeafViews.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences and counts survive
    /// while indentation and line breaks do not (a source pin must fail on
    /// a weakened gate, not on a reformat).
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
