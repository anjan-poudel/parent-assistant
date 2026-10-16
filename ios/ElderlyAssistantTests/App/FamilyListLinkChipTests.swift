import XCTest
@testable import ElderlyAssistant

/// The family list's link chip, its face migration and the legacy photo
/// accessor's removal (family-contacts-unify T-162; design-l1 §11.2,
/// design-l2 §2.7, §4.4, §8.1):
///
///  1. the chip visibility rule — VERIFIED links only, driven through
///     the pure `FamilyListPresentation` seam: a stale stored claim and
///     an unlinked row both show NOTHING (the editor's link area owns
///     the stale line);
///  2. the source pins the runtime cannot reach (the `FeatureSourceScan`
///     house convention, comments stripped): the chip renders on the
///     role-chip row through the seam and opens the contact's editor —
///     the link/unlink flow's home, where the ONE copy-preserving
///     unlink lives (T-158) — with the frozen key, a >= 44 pt tap floor
///     and a non-decorative a11y label; the list's face migration is
///     ONE batch pass keyed on the identity ARRAY with the post-await
///     identity re-check (a per-row task — the regression the batch
///     pass replaced — fails the `.task` count); the editor's
///     stored-photo preview resolves through `faceImageWithSource`;
///  3. the §8.1 deletion pin `testSyncContactPhotoResolverIsRemoved`:
///     zero code references to the sync `contactPhoto(for:)` remain in
///     the production module (the named pin the unit gate runs).
final class FamilyListLinkChipTests: XCTestCase {

    // MARK: - Fixtures

    private func family(name: String, link: SystemContactLink? = nil) -> FamilyContact {
        FamilyContact(name: name, phone: "9841 000001", relationship: "छोरी",
                      nicknames: [], systemContact: link)
    }

    private func snapshot(_ links: [UUID: SystemContactLink]) -> VerifiedLinksSnapshot {
        VerifiedLinksSnapshot(links: links, linkedRecordNumbers: [:], generation: 1)
    }

    // MARK: - The chip visibility rule (design-l2 §2.7)

    /// The chip shows EXACTLY for a verified link: a stored claim the
    /// snapshot does not verify (a stale link — `systemContact` set but
    /// absent from `links`) shows NOTHING, an unlinked row shows
    /// NOTHING, and another contact's verification never leaks across
    /// ids. After an unlink the snapshot holds no entry for the id, so
    /// this same rule is what re-renders the row chip-less (the FR-FCU-005
    /// re-render the unlink tests drive at the coordinator).
    func testLinkChipVisibilityIsVerifiedOnly() {
        let claim = SystemContactLink(identifier: "rec-a", numberKey: "9841000001")
        let verified = family(name: "Sita", link: claim)
        let stale = family(name: "Hari", link: claim)
        let unlinked = family(name: "Ram")

        let links = snapshot([verified.id: claim])

        XCTAssertTrue(FamilyListPresentation.showsLinkChip(verified, verifiedLinks: links),
                      "a verified link shows the chip")
        XCTAssertFalse(FamilyListPresentation.showsLinkChip(stale, verifiedLinks: links),
                       "a stale stored claim must show NOTHING — the list never says "
                       + "'Linked' for an unverified reference (FR-FCU-006)")
        XCTAssertFalse(FamilyListPresentation.showsLinkChip(unlinked, verifiedLinks: links),
                       "an unlinked row shows no chip")
        XCTAssertFalse(FamilyListPresentation.showsLinkChip(verified, verifiedLinks: .empty),
                       "an empty snapshot verifies nothing — no chip (the post-unlink render)")
    }

    // MARK: - Source pins (the wiring the runtime cannot reach)

    /// The chip's wiring: the row renders it through the pure
    /// verified-only seam, the capsule opens the editor (the link/unlink
    /// flow's home), the frozen key is the only copy, and the tap floor
    /// plus a11y hold.
    func testChipWiringIsPinnedAtTheSource() throws {
        let list = try listRegion()

        XCTAssertTrue(collapsed(list).contains(collapsed("""
            if FamilyListPresentation.showsLinkChip(
                contact, verifiedLinks: coordinator.verifiedLinks) {
                linkChip(contact)
            }
            """)),
                      "the chip renders through the pure verified-only rule")

        let chip = try region(between: "private func linkChip(",
                              and: "private func isDoctorRelationship(", in: list)
        XCTAssertTrue(chip.contains(
            "Text(L10n.str(\"family.link.chip\", locale: coordinator.activeLocale))"),
                      "the frozen key is the chip's only copy — no inline string")
        XCTAssertTrue(chip.contains("editorTarget = .edit(contact)"),
                      "the chip affordance opens the contact's editor — where the link "
                      + "area's copy-preserving unlink lives (T-158)")
        XCTAssertTrue(chip.contains(".frame(minHeight: DesignTokens.minTapTargetSize)"),
                      ">= 44 pt tap target (implementation notes)")
        XCTAssertTrue(chip.contains(".contentShape(Rectangle())"),
                      "the whole 44 pt frame is tappable, not only the capsule")
        XCTAssertTrue(chip.contains(".accessibilityLabel("),
                      "interactive — its state is spoken")
        XCTAssertFalse(chip.contains(".accessibilityHidden(true)"),
                       "an interactive affordance must not be decorative/hidden")
    }

    /// The list's face migration (T-157, design-l2 §2.7/§4.4): ONE batch
    /// pass keyed on the ARRAY of per-contact face identities (which
    /// carry the filename, the system-photo token and the epoch), each
    /// face resolved through the coordinator's async precedence path,
    /// every assignment re-checked against the identity after the await,
    /// and the epoch never touched here — the view adds no per-row
    /// bump (the bump-exactly-once ordering is the coordinator's, pinned
    /// by `CoordinatorFaceIdentityTests`).
    func testListFaceMigrationIsPinnedAtTheSource() throws {
        let list = try listRegion()

        XCTAssertTrue(list.contains("@State private var contactPhotos: [UUID: UIImage] = [:]"),
                      "faces live in state, resolved OFF the body")
        XCTAssertTrue(list.contains(".task(id: faceIdentities)"),
                      "the pass re-runs exactly when a face identity changes")
        XCTAssertEqual(occurrences(of: ".task(id:", in: list), 1,
                       "ONE batch pass — a per-row task (the migrated-away shape) "
                       + "would add a second")
        XCTAssertTrue(list.contains(
            "coordinator.familyContacts.map { coordinator.faceIdentity(for: $0) }"),
                      "the key IS the array of per-contact face identities")
        XCTAssertTrue(collapsed(list).contains(collapsed("""
            let face = await coordinator.faceThumbnail(
                for: contact,
                diameter: DesignTokens.iconBadgeDiameter,
                displayScale: displayScale)
            """)),
                      "each face resolves through the coordinator's async precedence path")
        XCTAssertTrue(list.contains(
            "guard coordinator.faceIdentity(for: contact) == identity else { continue }"),
                      "post-await identity re-check — a superseded face is dropped, never assigned")
        XCTAssertEqual(occurrences(of: "contactPhotos = resolved", in: list), 1,
                       "one publication per pass — every row renders after the same pass")
        XCTAssertTrue(list.contains("if let photo = contactPhotos[contact.id] {"),
                      "the row reads plain state — no image-file IO in body")
        XCTAssertFalse(list.contains("faceEpoch"),
                       "the view never bumps or reads the epoch — one pass covers all rows")
    }

    /// The editor's stored-photo preview (T-160/T-162): the async
    /// precedence pass through `faceImageWithSource`, keyed on the LIVE
    /// roster row's identity and re-checked after the await — the
    /// deleted sync lookup cannot drift back in as the preview path.
    func testDraftPreviewUsesTheAsyncFacePath() throws {
        let settings = settingsSource()
        let wizard = try region(between: "private struct FamilyContactWizardSheet: View {",
                                and: "enum FamilyWizardFindPresentation {",
                                in: settings)

        XCTAssertTrue(wizard.contains(".task(id: storedFaceIdentity)"),
                      "the preview re-resolves when the identity moves")
        XCTAssertTrue(wizard.contains("liveEditingContact.map { coordinator.faceIdentity(for: $0) }"),
                      "the key reads the LIVE roster row (the unlink's copy-first "
                      + "consequence must reach the preview — T-159)")
        XCTAssertTrue(wizard.contains("await coordinator.faceImageWithSource(for: contact)"),
                      "ONE precedence pass resolves the image AND its source (T-160)")
        XCTAssertTrue(wizard.contains(
            "guard coordinator.faceIdentity(for: contact) == identity else { return }"),
                      "post-await identity re-check — a superseded face is abandoned")
        XCTAssertTrue(wizard.contains("storedPhoto = face.image"))
        XCTAssertTrue(wizard.contains("storedPhotoIsSystem = face.isSystemPhoto"),
                      "the source caption's attribution rides the same pass")
    }

    // MARK: - The §8.1 deletion pin

    /// `contactPhoto(for:)` is DELETED and stays deleted (design-l2
    /// §8.1): a scan of every production-module source — comments
    /// stripped by `codeText`, so prose about the deletion is not
    /// mistaken for the code — must find ZERO code references. The test
    /// module is exempt BY DESIGN: this pin (its assertions carry the
    /// literal) and `CoordinatorFaceIdentityTests` are the
    /// anti-regression tests the scan excludes. The compile already
    /// proves no caller can exist; this scan proves no declaration
    /// returns.
    func testSyncContactPhotoResolverIsRemoved() {
        let iosRoot = FeatureSourceScan.iosDirectory(file: #filePath)
        let files = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant")
        XCTAssertGreaterThan(files.count, 300,
                             "the scan must cover the real production tree")

        for file in files {
            let text = FeatureSourceScan.codeText(of: file)
            XCTAssertFalse(text.contains("contactPhoto(for"),
                           "a code reference to the deleted sync accessor survives: "
                           + FeatureSourceScan.relativePath(of: file))
            XCTAssertFalse(text.contains("func contactPhoto("),
                           "the sync contactPhoto(for:) resolver must stay deleted "
                           + "(design-l2 §8.1): " + FeatureSourceScan.relativePath(of: file))
        }

        // The surviving photo path is the coordinator's async precedence
        // resolver (`ContactPhotoStore.load` stays — the resolver's
        // local branch reads it).
        let coordinator = FeatureSourceScan.codeText(
            of: iosRoot.appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        XCTAssertTrue(coordinator.contains(
            "func faceImage(for contact: FamilyContact) async -> UIImage?"),
                      "the async face accessor is the surviving seam")
        XCTAssertTrue(coordinator.contains(
            "private func resolvedSystemPhoto(for contact: FamilyContact) async -> UIImage?"),
                      "the precedence resolver's system branch is intact")
    }

    // MARK: - Helpers (the house source-scan patterns)

    private func settingsSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift"))
    }

    /// The `FamilyContactsSettingsView` region — from its declaration to
    /// the wizard sheet that follows it (code markers only; `codeText`
    /// has already stripped the comments).
    private func listRegion() throws -> String {
        try region(between: "struct FamilyContactsSettingsView: View {",
                   and: "private struct FamilyContactWizardSheet: View {",
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
