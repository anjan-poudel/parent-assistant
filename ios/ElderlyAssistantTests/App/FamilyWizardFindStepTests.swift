import XCTest
@testable import ElderlyAssistant

/// The wizard find step's linking behavior (family-contacts-unify T-159;
/// design-l1 §11.1, design-l2 §2.1-§2.3, §3.5, §6.4, §8.2):
///
///  1. the STEERING guard — `storedClaimant` over the roster's STORED
///     claims (verified AND stale, the superset) and the row mapping that
///     turns an already-linked result into a steering row instead of a
///     selection, so a number linked to contact A can never be silently
///     re-linked to a new contact B;
///  2. the draft-link record (`prefill`'s non-empty-identifier guard),
///     the link area's state precedence, and the book-name resolution;
///  3. the drift pin (design-l2 §6.4): the wizard's search IS
///     `UnifiedContactSearch` — the legacy `SystemContactSearch.search`
///     call is gone from the wizard region, the call carries the
///     coordinator's published roster/index/verified-links, and the
///     presentation seam maps the engine's outcome 1:1 in the engine's
///     order, so there is no parallel tier table to drift;
///  4. the T-148b wizard obligations (design-l2 §3.5): the load gates
///     read `allowsReading` and the honest limited caption sits under
///     the field inside the readable arm;
///  5. the wiring the runtime cannot reach — source pins over the
///     delivered regions (the `FeatureSourceScan` house convention,
///     comments stripped): the steering callback at the parent call
///     site, the `steerTarget` lifecycle, the unlink control's a11y and
///     ≥44 pt floors, and the draft link's pass-through at Save.
final class FamilyWizardFindStepTests: XCTestCase {

    // MARK: - Fixtures

    private func family(name: String, phone: String = "9841 000001",
                        relationship: String = "छोरी",
                        nicknames: [String] = [],
                        link: SystemContactLink? = nil) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: relationship,
                      nicknames: nicknames, systemContact: link)
    }

    private func bookRow(name: String, phone: String,
                         identifier: String) -> AddressBookEntry {
        AddressBookEntry(name: name, label: "mobile", phone: phone,
                         normalized: ContactNumberKey.normalized(phone),
                         identifier: identifier)
    }

    private func snapshot(_ links: [UUID: String]) -> VerifiedLinksSnapshot {
        VerifiedLinksSnapshot(
            links: links.mapValues { SystemContactLink(identifier: $0, numberKey: "") },
            linkedRecordNumbers: [:],
            generation: 1)
    }

    // MARK: - The steering guard (`storedClaimant`)

    /// `storedClaimant` answers the roster contact whose stored link
    /// claims the identifier — roster order, and NEVER the editing
    /// contact (its own link is the link area's subject, so re-picking
    /// its record stays selectable).
    func testStoredClaimantReturnsTheFirstRosterClaimantOutsideTheEditingContact() {
        let claim = SystemContactLink(identifier: "rec-x", numberKey: "")
        let hari = family(name: "Hari", phone: "9841 000002", link: claim)
        let sita = family(name: "Sita", phone: "9841 000003", link: claim)

        // Roster order decides between several claimants.
        XCTAssertEqual(FamilyWizardFindPresentation.storedClaimant(
            "rec-x", in: [hari, sita], editing: nil), hari)
        // The editing contact is excluded — a claimant further down wins.
        XCTAssertEqual(FamilyWizardFindPresentation.storedClaimant(
            "rec-x", in: [hari, sita], editing: hari), sita)
        // ... and an editing contact that IS the only claimant steers
        // nobody (it may re-pick its own record).
        XCTAssertNil(FamilyWizardFindPresentation.storedClaimant(
            "rec-x", in: [hari], editing: hari))
        // A different identifier, or an unlinked roster, claims nothing.
        XCTAssertNil(FamilyWizardFindPresentation.storedClaimant(
            "rec-y", in: [hari, sita], editing: nil))
        XCTAssertNil(FamilyWizardFindPresentation.storedClaimant(
            "rec-x", in: [family(name: "Ram")], editing: nil))
    }

    /// The superset rule (design-l2 §2.2): the claimant check reads the
    /// STORED claim, not the verified snapshot — a stale link steers
    /// exactly like a verified one. An empty identifier is "no linkable
    /// record" (§3.5) and never claims.
    func testStoredClaimantCoversStaleClaimsAndEmptyIdentifiersNeverClaim() {
        let stale = family(name: "Sita",
                           link: SystemContactLink(identifier: "rec-old", numberKey: ""))
        XCTAssertEqual(FamilyWizardFindPresentation.storedClaimant(
            "rec-old", in: [stale], editing: nil), stale,
            "verified or stale — the superset steers")

        let corrupt = family(name: "Sita",
                             link: SystemContactLink(identifier: "", numberKey: ""))
        XCTAssertNil(FamilyWizardFindPresentation.storedClaimant(
            "", in: [corrupt], editing: nil),
            "an empty identifier is never a claim")
    }

    /// Gherkin "Steering guard (storedClaimant)" — the VERIFIED path,
    /// end to end through the engine: a query matching only the record's
    /// book spelling surfaces the linked family contact (Pass-3
    /// synthesis, book twin dropped), and the wizard renders that row as
    /// a steering row for the claimant — nothing is selectable.
    func testVerifiedLinkedNumberSteersThroughTheSynthesizedFamilyRow() {
        let sita = family(name: "Sita", phone: "+977 9841 000001",
                          link: SystemContactLink(identifier: "rec-sita",
                                                  numberKey: "9779841000001"))
        let row = bookRow(name: "सीता शर्मा", phone: "9841 000001", identifier: "rec-sita")
        let outcome = UnifiedContactSearch.search(query: "शर्मा",
                                                  family: [sita],
                                                  index: FamilyContactIndex(family: [sita]),
                                                  in: [row],
                                                  verifiedLinks: snapshot([sita.id: "rec-sita"]))
        XCTAssertEqual(outcome.entries, [.family(sita)],
                       "the verified twin is dropped; the synthesized family row is the person")

        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: [sita],
                                                         editing: nil),
                       [.steering(sita)])
    }

    /// The STALE arm of the same guard: the stored claim is unverified
    /// (the snapshot does not carry it), so the engine keeps the book
    /// row — and the wizard still steers it to claimant A instead of
    /// letting the new contact B select and re-link the same number.
    func testStaleClaimedNumberStillSteersToItsClaimant() {
        let claimant = family(name: "Sita", phone: "9841 000001",
                              link: SystemContactLink(identifier: "rec-sita", numberKey: ""))
        let newContact = family(name: "Hari", phone: "9841 000002")
        let row = bookRow(name: "सीता शर्मा", phone: "9841 000001", identifier: "rec-sita")
        let roster = [claimant, newContact]
        let outcome = UnifiedContactSearch.search(query: "शर्मा",
                                                  family: roster,
                                                  index: FamilyContactIndex(family: roster),
                                                  in: [row])   // `.empty`: nothing verifies
        XCTAssertEqual(outcome.entries, [.addressBook(row)],
                       "stale links merge nothing (unlinked parity)")

        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: roster,
                                                         editing: newContact),
                       [.steering(claimant)],
                       "the step steers to the existing claimant, never silently re-links B")
    }

    /// Gherkin "Nickname search surfaces the contact" (FR-FCU-012): the
    /// nickname tier lives in the ENGINE, and the wizard feeds it the
    /// coordinator's published index — a nickname query surfaces the
    /// person (a steering row in the add flow), never a no-results
    /// dead end.
    func testNicknameQuerySurfacesTheContactThroughThePublishedIndex() {
        let ama = family(name: "Sita", nicknames: ["आमा"])
        let roster = [ama]
        let outcome = UnifiedContactSearch.search(query: "आमा",
                                                  family: roster,
                                                  index: FamilyContactIndex(family: roster),
                                                  in: [])
        XCTAssertEqual(outcome.entries, [.family(ama)])
        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: roster,
                                                         editing: nil),
                       [.steering(ama)])
    }

    // MARK: - The row mapping

    /// Per-row-kind rules (design-l2 §2.2): `.family` rows are steering
    /// rows — except the contact being edited, whose own row is skipped
    /// entirely; `.addressBook` rows are selectable unless another
    /// roster contact already claims their record.
    func testRowsMapEngineResultsPerKindAndSkipTheEditingContact() {
        let sita = family(name: "Sita", phone: "9841 000001")
        let hari = family(name: "Hari", phone: "9841 000002")
        let stray = bookRow(name: "Ram", phone: "9841 000009", identifier: "rec-ram")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(sita), .family(hari), .addressBook(stray)],
            moreAvailable: false)

        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: [sita, hari],
                                                         editing: hari),
                       [.steering(sita), .selectable(stray)],
                       "family → steering; the editing contact's own row → skipped; "
                       + "an unclaimed book row → selectable")
    }

    /// A book row whose record is claimed by ANOTHER roster contact is a
    /// steering row; the same row whose claim belongs to the EDITING
    /// contact stays selectable (the editor's own re-pick path).
    func testClaimedBookRowsSteerWhileTheEditingContactsOwnRecordStaysSelectable() {
        let claimant = family(name: "Sita", phone: "9841 000001",
                              link: SystemContactLink(identifier: "rec-sita", numberKey: ""))
        let editing = family(name: "Hari", phone: "9841 000002",
                             link: SystemContactLink(identifier: "rec-hari", numberKey: ""))
        let sitaRow = bookRow(name: "सीता शर्मा", phone: "9841 000001", identifier: "rec-sita")
        let hariRow = bookRow(name: "Hari Thapa", phone: "9841 000002", identifier: "rec-hari")
        let free = bookRow(name: "Ram", phone: "9841 000009", identifier: "rec-ram")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.addressBook(sitaRow), .addressBook(hariRow), .addressBook(free)],
            moreAvailable: false)

        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: [claimant, editing],
                                                         editing: editing),
                       [.steering(claimant), .selectable(hariRow), .selectable(free)])
    }

    /// One row per person: a STALE claimant can surface twice — its own
    /// family row (matched) and its book row (the engine keeps it, the
    /// link is unverified) — and the seam collapses the pair to the
    /// FIRST (the engine's ranking position), so the `ForEach` ids stay
    /// unique.
    func testRowsDeduplicateOnePersonAndKeepTheEngineOrder() {
        let claimant = family(name: "Sita", phone: "9841 000001",
                              link: SystemContactLink(identifier: "rec-sita", numberKey: ""))
        let sitaRow = bookRow(name: "सीता शर्मा", phone: "9841 000001", identifier: "rec-sita")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(claimant), .addressBook(sitaRow)],
            moreAvailable: false)

        let rows = FamilyWizardFindPresentation.rows(for: outcome,
                                                     roster: [claimant],
                                                     editing: nil)
        XCTAssertEqual(rows, [.steering(claimant)],
                       "both engine rows name one person — one steering row, first position")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count,
                       "ForEach ids are unique")
    }

    /// The presentation is a TOTAL function of the engine's list: one
    /// rendered row per engine entry (minus only the documented skip /
    /// dedupe rules), in the engine's order — the drift the §6.4 pin
    /// guards against cannot even be expressed here.
    func testThePresentationCoversEveryEngineRowKind() {
        let sita = family(name: "Sita")
        let ram = bookRow(name: "Ram", phone: "9841 000009", identifier: "rec-ram")
        let outcome = UnifiedContactSearch.Outcome(
            entries: [.family(sita), .addressBook(ram)],
            moreAvailable: false)
        XCTAssertEqual(FamilyWizardFindPresentation.rows(for: outcome,
                                                         roster: [sita],
                                                         editing: nil),
                       [.steering(sita), .selectable(ram)])
    }

    // MARK: - The draft link and the link area's states

    /// `prefill`'s draft record (design-l2 §2.2): the pick records the
    /// record's identifier plus the row's normalized number key as the
    /// fingerprint; an empty identifier is "no linkable record" (§3.5)
    /// and records nothing.
    func testDraftLinkRecordsTheRecordAndItsNumberKeyOnlyForLiveIdentifiers() {
        let row = bookRow(name: "सीता शर्मा", phone: "+977 9841 000001", identifier: "rec-sita")
        XCTAssertEqual(row.normalized, "9779841000001")
        XCTAssertEqual(FamilyWizardFindPresentation.draftLink(for: row),
                       SystemContactLink(identifier: "rec-sita", numberKey: "9779841000001"))

        // The identifier-less fixture (identifier defaults to "").
        let fixture = AddressBookEntry(name: "Sita", label: "mobile",
                                       phone: "9841 000002", normalized: "9841000002")
        XCTAssertNil(FamilyWizardFindPresentation.draftLink(for: fixture),
                     "no linkable record — no draft link")
    }

    /// The link area's precedence (design-l2 §2.2): draft → stored +
    /// verified → stored + stale → no pick — and a CLEARED roster row
    /// (the successful-unlink state) is `.noPick` even while an old
    /// snapshot still carries the id, never a phantom stale line.
    func testLinkStatePrecedenceIsDraftThenStoredVerifiedThenStoredStale() {
        let stored = SystemContactLink(identifier: "rec-sita", numberKey: "")
        let draft = SystemContactLink(identifier: "rec-draft", numberKey: "")
        let linked = family(name: "Sita", link: stored)
        let unlinked = family(name: "Hari")
        let verified = snapshot([linked.id: "rec-sita"])

        // 1. The draft beats every stored claim.
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: draft, editing: linked, verifiedLinks: verified), .draftLinked)
        // 2. Stored + verified.
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: nil, editing: linked, verifiedLinks: verified), .storedLinked)
        // 3. Stored but unverified — the stale line (the unlink still works).
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: nil, editing: linked, verifiedLinks: .empty), .storedStale)
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: nil, editing: linked, verifiedLinks: snapshot([UUID(): "other"])),
            .storedStale)
        // 4. Nothing to show: unlinked row, fresh add, or the cleared row.
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: nil, editing: unlinked, verifiedLinks: verified), .noPick)
        XCTAssertEqual(FamilyWizardFindPresentation.linkState(
            draftLink: nil, editing: nil, verifiedLinks: verified), .noPick)
    }

    /// The linked-to line's name resolves from the CURRENT sweep by the
    /// record's identifier (design-l2 §2.2); a record that left the
    /// sweep (or an empty identifier) resolves nothing — the line
    /// renders without a name, never a fabricated one.
    func testBookNameResolvesFromTheCurrentSweepAndFailsClosed() {
        let entries = [bookRow(name: "सीता शर्मा", phone: "9841 000001", identifier: "rec-sita")]
        XCTAssertEqual(FamilyWizardFindPresentation.bookName(for: "rec-sita", in: entries),
                       "सीता शर्मा")
        XCTAssertNil(FamilyWizardFindPresentation.bookName(for: "rec-sita", in: []))
        XCTAssertNil(FamilyWizardFindPresentation.bookName(for: "rec-sita", in: nil))
        XCTAssertNil(FamilyWizardFindPresentation.bookName(for: "", in: entries))
    }

    // MARK: - Drift pin (design-l2 §6.4)

    /// The wizard's search IS the unified engine, and the legacy
    /// `SystemContactSearch.search` call is gone from the wizard region
    /// — the cheap drift pin design-l2 §6.4 names. The call carries the
    /// coordinator's PUBLISHED roster, index and verified-link snapshot
    /// (the T-156 handoff), and the wizard defines no tier table of its
    /// own (`FamilyMatchTier` appears nowhere in the region): the row
    /// list is a pure function of the engine's outcome through the ONE
    /// seam, so the wizard's presentation cannot drift from the engine's
    /// list.
    func testWizardSearchUsesTheUnifiedEngineAndTheLegacyCallIsGone() throws {
        let wizard = try wizardRegion()

        XCTAssertEqual(occurrences(of: "UnifiedContactSearch.search(", in: wizard), 1,
                       "exactly the find step's one search site")
        XCTAssertEqual(occurrences(of: "SystemContactSearch.search", in: wizard), 0,
                       "the legacy pre-unification call must not survive in the wizard")

        let call = try region(between: "UnifiedContactSearch.search(",
                              and: "recency: coordinator.contactCallRecency",
                              in: wizard)
        for argument in ["family: coordinator.familyContacts",
                         "index: coordinator.familyIndex",
                         "verifiedLinks: coordinator.verifiedLinks"] {
            XCTAssertTrue(call.contains(argument),
                          "the search must carry `\(argument)` (the published seam)")
        }

        XCTAssertEqual(occurrences(of: "FamilyMatchTier", in: wizard), 0,
                       "no parallel tier table — the engine's list IS the wizard's list")
        XCTAssertTrue(wizard.contains("FamilyWizardFindPresentation.rows(for: outcome,"),
                      "the rows come through the ONE pure presentation seam")
    }

    /// The tier-list parity anchor itself (the drift pin's semantic
    /// half): the engine's tier ORDER is raw-value order (pinned by
    /// T-152's `UnifiedContactSearchTests`), and this suite pins that
    /// the wizard's mapping renders the engine's rows in the engine's
    /// ORDER — family-leading — on the REAL engine output the wizard
    /// consumes.
    func testEngineRowOrderIsTheWizardRowOrder() {
        let sita = family(name: "Sita", phone: "9841 000001")
        let ram = bookRow(name: "Ram", phone: "9841 000009", identifier: "rec-ram")
        let roster = [sita]
        let outcome = UnifiedContactSearch.search(query: "a",
                                                  family: roster,
                                                  index: FamilyContactIndex(family: roster),
                                                  in: [ram])
        // "a" contains-matches both names ("Sita" with diacritic-insensitive
        // options, "Ram") — family rows lead, book rows follow.
        XCTAssertEqual(outcome.entries.map(\.id), ["family-\(sita.id.uuidString)", ram.normalized])
        let rows = FamilyWizardFindPresentation.rows(for: outcome,
                                                     roster: roster,
                                                     editing: nil)
        XCTAssertEqual(rows.map(\.id), ["steer-\(sita.id.uuidString)", "pick-\(ram.normalized)"],
                       "1:1 in the engine's order — family-leading rank preserved")
    }

    // MARK: - The `.limited` wizard sites (T-148b obligations; design-l2 §3.5)

    /// Every wizard access gate reads `allowsReading`: `.limited` loads
    /// its granted set (relaunch and post-grant), and the honest limited
    /// caption renders once, inside the readable arm, directly under the
    /// field.
    func testWizardAccessGatesReadAllowsReadingWithTheLimitedCaptionUnderTheField() throws {
        let wizard = try wizardRegion()
        XCTAssertEqual(occurrences(of: "== .allowed", in: wizard), 0,
                       "the wizard gates on allowsReading — .limited is readable")

        let section = try region(between: "private var searchSection: some View {",
                                 and: "private var searchField: some View {",
                                 in: wizard)
        XCTAssertTrue(section.contains("case .allowed, .limited:"),
                      "the readable arm stays shared and compile-forced")
        XCTAssertEqual(occurrences(of: "call.search.accessLimited", in: section), 1,
                       "exactly one limited caption in the search section")
        let field = try XCTUnwrap(section.range(of: "searchField"))
        let caption = try XCTUnwrap(section.range(of: "call.search.accessLimited"))
        XCTAssertLessThan(field.lowerBound, caption.lowerBound,
                          "the caption sits directly under the field")

        let refresh = try region(between: "private func refreshSearchAccess() {",
                                 and: "private func grantAccess() {", in: wizard)
        XCTAssertTrue(refresh.contains("guard status.allowsReading else { return }"),
                      "a limited grant still loads its granted set")

        let grant = try region(between: "private func grantAccess() {",
                               and: "private func loadEntries() {", in: wizard)
        XCTAssertTrue(grant.contains("_ = await directory.requestAccess()"),
                      "never the binary request result (design-l2 §3.5)")
        XCTAssertTrue(grant.contains("if access?.allowsReading == true {"),
                      "the load decision reads the RE-READ status — the sheet may yield .limited")
        XCTAssertFalse(grant.contains("if granted"),
                       "the granted == false shape would collapse a limited selection")
    }

    // MARK: - Source pins (the wiring the runtime cannot reach)

    /// The steering wiring (design-l2 §2.1/§2.3): the callback parameter,
    /// the parent's in-place item swap, the `steerTarget` lifecycle
    /// (recorded by the card tap; cleared by a keystroke AND by a
    /// successful pick), the ≥44 pt card and button, and the a11y label.
    func testSteeringCallbackAndLifecycleArePinnedAtTheSource() throws {
        let settings = settingsSource()
        let wizard = try wizardRegion()

        XCTAssertTrue(wizard.contains("onSteerTo: @escaping (FamilyContact) -> Void"),
                      "the init gains the steering callback (design-l2 §2.1)")
        XCTAssertTrue(collapsed(settings).contains(collapsed("""
            FamilyContactWizardSheet(target: target) { other in
                editorTarget = .edit(other)
            }
            """)),
                      "the PARENT swaps the sheet's item in place — no dismiss/re-present race")

        XCTAssertTrue(wizard.contains("@State private var steerTarget: FamilyContact?"))
        XCTAssertTrue(wizard.contains("steerTarget = other"),
                      "the card tap records the intent")
        XCTAssertEqual(occurrences(of: "steerTarget = nil", in: wizard), 2,
                       "cleared by a keystroke (onChange of searchText) and a successful pick")
        XCTAssertTrue(wizard.contains(".onChange(of: searchText)"))

        let card = try region(between: "private func steeringResultRow(_ other: FamilyContact) -> some View {",
                              and: "private func prefill(", in: wizard)
        XCTAssertTrue(card.contains("L10n.fmt(\"family.link.alreadyLinked\""),
                      "the frozen sentence carries the other contact's name")
        XCTAssertTrue(card.contains("onSteerTo(other)"),
                      "the edit button hands the steer to the parent")
        XCTAssertTrue(card.contains(".accessibilityLabel(Text(\"settings.family.edit\"))"))
        XCTAssertEqual(occurrences(of: ".frame(minHeight: DesignTokens.minTapTargetSize)",
                                   in: card), 2,
                       "the whole card AND the button are ≥44 pt (NFR-FCU-005)")
    }

    /// The link area's wiring: the four states under the section title,
    /// the two unlink consequences (draft clears locally; a stored link
    /// commits through the ONE unlink path with the pure mode rule), the
    /// unlink control's a11y + visible hint + ≥44 pt floor, and the
    /// draft link's pass-through at Save.
    func testLinkAreaStatesAndSavePassThroughArePinnedAtTheSource() throws {
        let wizard = try wizardRegion()

        let section = try region(between: "private var linkSection: some View {",
                                 and: "private func linkedToLine(", in: wizard)
        XCTAssertTrue(section.contains("stepTitle(\"family.link.sectionTitle\")"),
                      "the section title renders in all four states")
        for stateCase in ["case .draftLinked:", "case .storedLinked:",
                          "case .storedStale:", "case .noPick:"] {
            XCTAssertTrue(section.contains(stateCase), stateCase)
        }
        XCTAssertTrue(section.contains("switch linkState {"))
        XCTAssertTrue(section.contains("unlinkButton { clearDraftLink() }"),
                      "the draft's unlink clears ONLY the draft")
        XCTAssertEqual(occurrences(of: "unlinkButton { commitUnlink() }", in: section), 2,
                       "a verified AND a stale stored link both commit")
        XCTAssertTrue(section.contains("Text(\"family.link.pickHint\")"),
                      "the no-pick state is the caption only")

        let unlink = try region(between: "private func unlinkButton(",
                                and: "private func clearDraftLink() {", in: wizard)
        XCTAssertTrue(unlink.contains(".accessibilityLabel(Text(\"family.link.unlink\"))"))
        XCTAssertTrue(unlink.contains(".accessibilityHint(Text(\"family.link.unlinkHint\"))"))
        XCTAssertTrue(unlink.contains("Text(\"family.link.unlinkHint\")"),
                      "the hint is ALSO visible under the button")
        XCTAssertTrue(unlink.contains(".frame(minHeight: DesignTokens.minTapTargetSize)"),
                      "≥44 pt (NFR-FCU-005)")

        let commit = try region(between: "private func commitUnlink() {",
                                and: "private func refreshSearchAccess() {", in: wizard)
        XCTAssertTrue(commit.contains("await coordinator.setFamilyContactLink(id: contact.id, mode: mode)"),
                      "the ONE unlink path (T-158)")
        XCTAssertTrue(commit.contains("AppCoordinator.unlinkMode("),
                      "the mode comes from the coordinator's pure rule (§2.6)")

        // The draft link reaches BOTH write seams (add + update) — and
        // nowhere else stores it.
        XCTAssertEqual(occurrences(of: "link: draftLink", in: wizard), 2,
                       "Save passes the draft through add and update (design-l2 §2.6)")
        XCTAssertTrue(wizard.contains(
            "guard let link = FamilyWizardFindPresentation.draftLink(for: entry) else { return }"),
                      "prefill records the draft through the seam's identifier guard")
        XCTAssertTrue(wizard.contains("draftLinkBookName = entry.name"),
                      "the pick-time book name is recorded alongside")

        // The face task reads the LIVE roster row, so a copy-first
        // unlink's saved photo reaches the preview (T-159 refinement).
        XCTAssertTrue(wizard.contains("liveEditingContact.map { coordinator.faceIdentity(for: $0) }"))
    }

    // MARK: - Helpers (the house source-scan patterns)

    private func settingsSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift"))
    }

    /// The `FamilyContactWizardSheet` region — from its declaration to
    /// the find-step presentation seam that follows it (code markers
    /// only; `codeText` has already stripped the comments).
    private func wizardRegion() throws -> String {
        try region(between: "private struct FamilyContactWizardSheet: View {",
                   and: "enum FamilyWizardFindPresentation {",
                   in: settingsSource())
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `MissedCallDialBackTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "SettingsView.swift has no `\(start)`")
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
