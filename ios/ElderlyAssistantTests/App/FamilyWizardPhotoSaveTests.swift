import XCTest
import UIKit
@testable import ElderlyAssistant

/// T-160 — the wizard photo step, save flow and nickname list editor
/// (family-contacts-unify; design-l2 §2.4, §2.5, §2.6, §10.2-§10.4;
/// design-l1 §10.1-§10.4, §11.1; FR-FCU-008/009/010/015, NFR-FCU-005):
///
///  1. the PURE photo-step/save-flow seam (`FamilyWizardPhotoPresentation`):
///     the source-caption rule, the post-save state mapping (the §1.5
///     table plus the §10.4 remove path), the state→label keys and the
///     remove-path recheck trigger — including the failure-path Gherkin:
///     a failed write NEVER renders "updated in system", the denied state
///     carries the honest explanation, and the remove path renders the
///     system-photo-remains remedy only for a verified clear that left a
///     photo standing;
///  2. the nickname entry rules (`FamilyWizardNicknamePresentation` +
///     the `FamilyContact` F5/§3.2 seams): the 8-entry envelope (nothing
///     stored is ever dropped), trim + whitespace-only rejection AT
///     ENTRY, the 64-char whole-grapheme cap, store-as-entered (no
///     transliteration, no case folding) and duplicates preserved;
///  3. the NEW coordinator seam `faceImageWithSource` — the displayed
///     photo's source attribution — END TO END over a scripted link
///     service on an in-memory profile channel (system bytes resolve →
///     `(image, true)`; app-local fallback → `(image, false)`; nothing →
///     `(nil, false)`; and `faceImage` is the identical resolution);
///  4. the wiring the runtime cannot reach — source pins over the
///     delivered regions (the `FeatureSourceScan` house convention,
///     comments stripped): the photo-step subview order, the
///     write-access cards' arms and frozen copy, the save-flow
///     sequencing (store write first, the photo Task, the F4
///     stay-open-on-`.written` path, the Close footer), the nickname
///     list wiring, and the F4/T-165 comment (raw text — comments are
///     what `codeText` strips).
@MainActor
final class FamilyWizardPhotoSaveTests: XCTestCase {

    // MARK: - Fakes (the coordinator seam test)

    /// In-memory stand-in for the encrypted PROFILE channel (the
    /// `CoordinatorFaceIdentityTests` shape: raw read/write, no keychain).
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        private var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)   // this fake is raw-read only
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    /// Scripted `SystemContactLinkReading`: every stored claim verifies
    /// (the honest superset), and system-photo bytes are scripted per
    /// record identifier. Lock-protected — the coordinator's refresh
    /// Tasks outlive the synchronous test steps that spawn them.
    private final class ScriptedLinkService: SystemContactLinkReading {
        private let lock = NSLock()
        private var calls = 0
        private var photoBytes: [String: Data] = [:]

        func setPhotoBytes(_ data: Data?, for identifier: String) {
            lock.withLock { photoBytes[identifier] = data }
        }

        func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot {
            let generation = lock.withLock { () -> Int in
                calls += 1
                return calls
            }
            var links: [UUID: SystemContactLink] = [:]
            var numbers: [String: [String]] = [:]
            for contact in contacts {
                guard let link = contact.systemContact else { continue }
                links[contact.id] = link
                numbers[link.identifier] = [link.numberKey]
            }
            return VerifiedLinksSnapshot(links: links,
                                         linkedRecordNumbers: numbers,
                                         generation: UInt64(generation))
        }

        func photoImageData(forIdentifier identifier: String) async -> Data? {
            lock.withLock { photoBytes[identifier] }
        }

        func invalidate(identifier: String?) async {}
    }

    // MARK: - Coordinator helpers

    private func makeCoordinator(linkService: SystemContactLinkReading? = nil) -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage(),
                       wireProfilePersonalization: false,
                       systemContactLinkService: linkService)
    }

    /// Empties the persisted roster through the coordinator's own remove
    /// path (which also deletes the photo files it wrote); the simulator
    /// host's family store is shared across tests in a run, so every test
    /// starts from this reset instead of assuming an empty store.
    private func clearRoster(_ coordinator: AppCoordinator,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for contact in coordinator.familyContactStore.load() {
            coordinator.removeFamilyContact(id: contact.id)
        }
        await waitUntil("the roster reset republishes", file: file, line: line) {
            coordinator.familyContacts.isEmpty
        }
    }

    /// Polls `condition` on the main actor — the publishes land through
    /// Tasks/DispatchQueue hops, so a bare assertion races them.
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func solidImage(_ color: UIColor, side: CGFloat = 96) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                               format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func jpegBytes(_ image: UIImage) -> Data {
        image.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - The source-caption rule (design-l2 §2.4, FR-FCU-007)

    /// The caption shows exactly when the preview displays the STORED
    /// face AND that face came from the linked system record: a picked
    /// photo, an explicit remove, or an app-local fallback all keep the
    /// caption away — an app-local photo never claims to come from the
    /// phone book.
    func testSourceCaptionShowsOnlyForTheDisplayedStoredSystemPhoto() {
        XCTAssertTrue(FamilyWizardPhotoPresentation.showsSourceSystemCaption(
            displayingStoredPhoto: true, storedPhotoIsSystem: true))
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsSourceSystemCaption(
            displayingStoredPhoto: true, storedPhotoIsSystem: false),
            "an app-local fallback must not claim the phone book's photo")
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsSourceSystemCaption(
            displayingStoredPhoto: false, storedPhotoIsSystem: true),
            "a picked photo replaces the preview — the caption goes with it")
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsSourceSystemCaption(
            displayingStoredPhoto: false, storedPhotoIsSystem: false))
    }

    // MARK: - The post-save state mapping (design-l2 §1.5/§2.6, F4)

    /// Gherkin "Photo written to the linked system contact shows the
    /// honest label (F4)": a byte-verified `.written` maps to
    /// `.updatedInSystem` — the deliberate F4 label — and every other
    /// attempt outcome maps through the total table; the unlinked skip is
    /// the one silent case (nil, today's UX).
    func testWrittenMapsToUpdatedInSystemAndTheTableIsTotal() {
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(outcome: .written,
                                                               removing: false),
                       .updatedInSystem, "F4: the verified write shows the label")
        XCTAssertNil(FamilyWizardPhotoPresentation.saveState(outcome: .skippedNoLink,
                                                             removing: false),
                     "unlinked/unverified is today's silent UX")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .skippedNoAuthorization(.notDetermined), removing: false),
            .keptOnPhone)
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .skippedNoAuthorization(.denied), removing: false),
            .keptOnPhoneAccessDenied,
            "denied carries the honest explanation state")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .skippedNoAuthorization(.limited), removing: false),
            .keptOnPhone)
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .skippedNoAuthorization(.full), removing: false),
            .keptOnPhone, "a contradictory 'full but skipped' fails closed")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(outcome: .recordGone,
                                                               removing: false),
                       .keptOnPhone)
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(outcome: .identityMismatch,
                                                               removing: false),
                       .keptOnPhone)
        for failure: SystemContactWriteFailure in [.fetchFailed, .notInGrantedSelection,
                                                   .saveRejected, .readBackMismatch] {
            XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
                outcome: .failed(failure), removing: false),
                .keptOnPhone, "\(failure) keeps the photo on the phone")
        }
    }

    /// Gherkin "Write fails after save": the failure paths NEVER render
    /// the success label — the local family photo remains (the state is
    /// the kept-on-phone family, or nil when there was nothing to say) —
    /// and a nil outcome (the contact left the roster) dismisses.
    func testFailurePathsNeverRenderUpdatedInSystem() {
        let nonSuccess: [SystemContactPhotoWriteOutcome?] = [
            .skippedNoLink,
            .skippedNoAuthorization(.notDetermined),
            .skippedNoAuthorization(.denied),
            .skippedNoAuthorization(.limited),
            .recordGone,
            .identityMismatch,
            .failed(.fetchFailed),
            .failed(.notInGrantedSelection),
            .failed(.saveRejected),
            .failed(.readBackMismatch),
            nil
        ]
        for outcome in nonSuccess {
            let state = FamilyWizardPhotoPresentation.saveState(outcome: outcome,
                                                                removing: false)
            XCTAssertNotEqual(state, .updatedInSystem,
                              "\(String(describing: outcome)) must never claim a system update")
            XCTAssertNotEqual(state, .systemPhotoRemains,
                              "the remove label never leaks into the write path")
        }
        XCTAssertNil(FamilyWizardPhotoPresentation.saveState(outcome: nil, removing: false),
                     "the contact left the roster — nothing to describe, dismiss")
    }

    /// Gherkin "Non-writable link shows the fallback card" + the §10.4
    /// remove path: a verified clear that still leaves a resolvable
    /// system photo standing renders `.systemPhotoRemains`; a clear with
    /// nothing left maps through the table (`.updatedInSystem`, F4's one
    /// success label); and the write path can never produce the remove
    /// label.
    func testRemovePathRendersSystemPhotoRemainsOnlyForAVerifiedClearLeavingAPhoto() {
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .written, removing: true, systemPhotoStillPresent: true),
            .systemPhotoRemains,
            "clear verified, a system photo still stands — the Contacts-app remedy")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .written, removing: true, systemPhotoStillPresent: false),
            .updatedInSystem,
            "the clear is what happened — mapped through the one table")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .failed(.saveRejected), removing: true, systemPhotoStillPresent: true),
            .keptOnPhone,
            "the recheck applies to a VERIFIED clear only — failures map through the table")
        XCTAssertEqual(FamilyWizardPhotoPresentation.saveState(
            outcome: .written, removing: false, systemPhotoStillPresent: true),
            .updatedInSystem,
            "the WRITE path never rechecks — a fresh write verified its own bytes")
    }

    /// The recheck trigger: exactly a remove-path VERIFIED clear — any
    /// other outcome already maps through the §1.5 table.
    func testRechecksRemovalOnlyForARemovePathVerifiedClear() {
        XCTAssertTrue(FamilyWizardPhotoPresentation.rechecksRemoval(outcome: .written,
                                                                    removing: true))
        XCTAssertFalse(FamilyWizardPhotoPresentation.rechecksRemoval(
            outcome: .failed(.saveRejected), removing: true))
        XCTAssertFalse(FamilyWizardPhotoPresentation.rechecksRemoval(
            outcome: .skippedNoAuthorization(.denied), removing: true))
        XCTAssertFalse(FamilyWizardPhotoPresentation.rechecksRemoval(outcome: .written,
                                                                     removing: false))
        XCTAssertFalse(FamilyWizardPhotoPresentation.rechecksRemoval(outcome: nil, removing: true))
    }

    // MARK: - The state→label keys (design-l2 §1.5/§7 frozen copy)

    /// Every `FamilyPhotoEditorState` case resolves to a frozen catalog
    /// key, exhaustively (the seam's switch has no default): the two
    /// kept-on-phone variants share the ONE kept-on-phone sentence — no
    /// second string is invented for F4 or the denied explanation.
    func testStateLabelKeysAreTheFourFrozenKeys() {
        XCTAssertEqual(FamilyWizardPhotoPresentation.stateLabelKey(.updatedInSystem),
                       "family.photo.state.updatedInSystem")
        XCTAssertEqual(FamilyWizardPhotoPresentation.stateLabelKey(.keptOnPhone),
                       "family.photo.state.keptOnPhone")
        XCTAssertEqual(FamilyWizardPhotoPresentation.stateLabelKey(.keptOnPhoneAccessDenied),
                       "family.photo.state.keptOnPhone",
                       "the denied state adds the explanation, not a second sentence")
        XCTAssertEqual(FamilyWizardPhotoPresentation.stateLabelKey(.systemPhotoRemains),
                       "family.photo.state.systemPhotoRemains")

        let keys = [FamilyPhotoEditorState.updatedInSystem, .keptOnPhone,
                    .keptOnPhoneAccessDenied, .systemPhotoRemains]
            .map(FamilyWizardPhotoPresentation.stateLabelKey)
        XCTAssertEqual(Set(keys).count, 3,
                       "four states, three distinct sentences — one deliberate share")
    }

    /// The access-denied body renders beside the denied state ONLY
    /// (design-l2 §2.4) — the kept-on-phone sibling stays a single line.
    func testAccessDeniedBodyRendersOnlyBesideTheDeniedState() {
        XCTAssertTrue(FamilyWizardPhotoPresentation.showsAccessDeniedBody(.keptOnPhoneAccessDenied))
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsAccessDeniedBody(.keptOnPhone))
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsAccessDeniedBody(.updatedInSystem))
        XCTAssertFalse(FamilyWizardPhotoPresentation.showsAccessDeniedBody(.systemPhotoRemains))
    }

    // MARK: - `faceImageWithSource` — the attribution seam, end to end

    /// The displayed photo's source, from the ONE precedence pass: a
    /// verified link with readable system bytes resolves `(image, true)`;
    /// without those bytes the app-local file is served with `false` —
    /// the pair the source caption derives from, so the displayed bytes
    /// and the caption can never disagree. `faceImage` returns the same
    /// image (the delegation).
    func testFaceImageWithSourceAttributesSystemBytesAndTheAppLocalFallback() async {
        let service = ScriptedLinkService()
        let coordinator = makeCoordinator(linkService: service)
        await clearRoster(coordinator)

        let id = UUID()
        let identifier = "record-\(UUID().uuidString)"
        XCTAssertTrue(coordinator.addFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "छोरी",
            link: SystemContactLink(identifier: identifier, numberKey: "9841000000")))
        await waitUntil("the linked add publishes a verified link") {
            coordinator.verifiedLinks.links[id] != nil
        }
        await waitUntil("the linked add republishes") {
            coordinator.familyContacts.first { $0.id == id } != nil
        }
        let current = coordinator.familyContacts.first { $0.id == id }!

        // 1. System bytes resolved → the SYSTEM photo, attributed true.
        service.setPhotoBytes(jpegBytes(solidImage(.systemRed)), for: identifier)
        let systemPair = await coordinator.faceImageWithSource(for: current)
        XCTAssertNotNil(systemPair.image, "the scripted system bytes must decode")
        XCTAssertTrue(systemPair.isSystemPhoto,
                      "resolved system bytes are the system source — the caption's cue")
        let viaFaceImage = await coordinator.faceImage(for: current)
        XCTAssertNotNil(viaFaceImage, "faceImage is the same resolution with the source dropped")
        XCTAssertEqual(viaFaceImage?.size, systemPair.image?.size)

        // 2. No system bytes, no app-local file → (nil, false): initials.
        service.setPhotoBytes(nil, for: identifier)
        let nothingPair = await coordinator.faceImageWithSource(for: current)
        XCTAssertNil(nothingPair.image)
        XCTAssertFalse(nothingPair.isSystemPhoto, "nothing resolved — never a system claim")

        // 3. No system bytes, but the app-local file exists → the
        //    fallback is served, attributed FALSE (the unlinked-shape
        //    service, so the link cannot verify either).
        XCTAssertTrue(coordinator.updateFamilyContact(
            id: id, name: "Sita", phone: "9841000000", relationship: "छोरी",
            messengerHandle: nil,
            photo: solidImage(.systemGreen),
            nicknames: [],
            link: SystemContactLink(identifier: identifier, numberKey: "9841000000")))
        await waitUntil("the app-local photo lands on the roster") {
            coordinator.familyContacts.first { $0.id == id }?.photoFilename != nil
        }
        let localPair = await coordinator.faceImageWithSource(
            for: coordinator.familyContacts.first { $0.id == id }!)
        XCTAssertNotNil(localPair.image, "the app-local file is the fallback's photo")
        XCTAssertFalse(localPair.isSystemPhoto,
                       "an app-local fallback must never be attributed to the phone book")

        await clearRoster(coordinator)
    }

    // MARK: - The nickname entry rules (design-l2 §2.5; FR-FCU-015, F5)

    /// The 8-entry envelope (design-l1 §8.4): the add row is offered
    /// below the cap and stops being offered AT it — nothing already
    /// stored is ever dropped to make room.
    func testNicknameEntryLimitIsEightAndNothingStoredIsEverDropped() {
        XCTAssertEqual(FamilyWizardNicknamePresentation.entryLimit, 8)
        for count in 0..<8 {
            XCTAssertTrue(FamilyWizardNicknamePresentation.canAdd(
                entries: Array(repeating: "नाम", count: count)),
                "below the cap: \(count) entries still offer the add row")
        }
        XCTAssertFalse(FamilyWizardNicknamePresentation.canAdd(
            entries: Array(repeating: "नाम", count: 8)),
            "at the cap the control stops offering")
        XCTAssertFalse(FamilyWizardNicknamePresentation.canAdd(
            entries: Array(repeating: "नाम", count: 9)),
            "above the cap stays closed — the stored entries are never dropped")
    }

    /// The entry rule (F5, design-l2 §2.5): trimmed at the Add control,
    /// whitespace-only rejected AT ENTRY, over-long values capped at 64
    /// whole graphemes, stored as entered within the bound — no
    /// transliteration, no case folding.
    func testNicknameEntryIsTrimmedRejectsBlankAndCapsAtSixtyFourGraphemes() {
        XCTAssertEqual(FamilyWizardNicknamePresentation.newEntry(from: "  आमा  "), "आमा",
                       "the entry is trimmed at the Add control")
        XCTAssertNil(FamilyWizardNicknamePresentation.newEntry(from: ""))
        XCTAssertNil(FamilyWizardNicknamePresentation.newEntry(from: "   "))
        XCTAssertNil(FamilyWizardNicknamePresentation.newEntry(from: "\n\t "),
                     "whitespace-only is rejected at entry (FR-FCU-011's rule)")

        // Store-as-entered: no transliteration, no case folding.
        XCTAssertEqual(FamilyWizardNicknamePresentation.newEntry(from: "Sita"), "Sita")
        XCTAssertEqual(FamilyWizardNicknamePresentation.newEntry(from: "सानु"), "सानु")

        // The 64-char cap is a whole-GRAPHEME prefix: repeated Devanagari
        // clusters survive without splitting (a scalar-prefix cap would).
        let cluster = "क्ष"
        let cappedCluster = FamilyWizardNicknamePresentation.newEntry(
            from: String(repeating: cluster, count: 70))
        XCTAssertEqual(cappedCluster, String(repeating: cluster, count: 64),
                       "the cap counts CHARACTERS, never Unicode scalars")
        let cappedAscii = FamilyWizardNicknamePresentation.newEntry(
            from: String(repeating: "a", count: 70))
        XCTAssertEqual(cappedAscii?.count, FamilyContact.maxNicknameLength)
        XCTAssertEqual(cappedAscii, String(repeating: "a", count: 64))
    }

    /// The save-time normalization (design-l2 §2.5/§3.2, defense in
    /// depth): order and duplicates are preserved, whitespace-only
    /// entries drop out, and each entry lands trimmed — "सानु" and
    /// "sanu" are always distinct, and a repeated spelling is real data.
    func testNicknameListNormalizationPreservesOrderDuplicatesAndTrims() {
        XCTAssertEqual(FamilyContact.normalizedNicknames(
            ["सानु", " sanu ", "सानु", "   ", "\n", "आमा"]),
            ["सानु", "sanu", "सानु", "आमा"],
            "duplicates and order survive; whitespace-only entries drop; entries trim")
        XCTAssertEqual(FamilyContact.normalizedNicknames([]), [],
                       "an emptied list is real data — removal saves as removal")
    }

    // MARK: - Source pins (the wiring the runtime cannot reach)

    /// The photo step IS the design's §2.4 subview breakdown, in order,
    /// and the caption derives from the ONE pair assignment (the face
    /// task), so it cannot disagree with the displayed bytes.
    func testPhotoStepRendersTheDesignsSubviewBreakdown() throws {
        let wizard = try wizardRegion()

        let step = try region(between: "private var photoStep: some View {",
                              and: "private var sourceCaption: some View {", in: wizard)
        var cursor = step.startIndex
        for marker in ["stepTitle(\"family.step.photo\")", "photoPreview", "sourceCaption",
                       "photoControls", "writeAccessCards", "photoStateLine"] {
            guard let found = step.range(of: marker, range: cursor..<step.endIndex) else {
                return XCTFail("`\(marker)` must render after the previous subview (§2.4 order)")
            }
            cursor = found.upperBound
        }

        let caption = try region(between: "private var sourceCaption: some View {",
                                 and: "private var writeAccessCards: some View {", in: wizard)
        XCTAssertTrue(caption.contains(
            "FamilyWizardPhotoPresentation.showsSourceSystemCaption("),
            "the caption goes through the ONE pure rule")
        XCTAssertTrue(caption.contains("displayingStoredPhoto: pickedPhoto == nil && !removingStoredPhoto"),
                      "a picked/removed preview is never described as the stored photo")
        XCTAssertTrue(caption.contains("storedPhotoIsSystem: storedPhotoIsSystem"))
        XCTAssertTrue(caption.contains("Text(\"family.photo.sourceSystem\")"))

        // The pair assignment: same task, same identity guard — the
        // displayed image and its attribution can never drift apart.
        XCTAssertTrue(wizard.contains("let face = await coordinator.faceImageWithSource(for: contact)"))
        XCTAssertTrue(wizard.contains("storedPhoto = face.image"))
        XCTAssertTrue(wizard.contains("storedPhotoIsSystem = face.isSystemPhoto"))
        XCTAssertTrue(wizard.contains("@State private var storedPhotoIsSystem = false"))
    }

    /// The write-access cards (design-l2 §2.4): linked-and-editing only,
    /// the three arms with their frozen copy, Allow running the existing
    /// `grantAccess` through the shared ask card, and the `.denied` line
    /// carrying the system-Settings link. `.limited` and `.allowed`
    /// render nothing — the write proceeds attempt-and-detect at Save.
    func testWriteAccessCardsRenderTheHonestArmsWithFrozenCopy() throws {
        let wizard = try wizardRegion()

        let cards = try region(between: "private var writeAccessCards: some View {",
                               and: "private var photoAccessDeniedLine: some View {",
                               in: wizard)
        XCTAssertTrue(cards.contains("if let contact = liveEditingContact,"),
                      "the cards need the LIVE roster row (T-159's pattern)")
        XCTAssertTrue(cards.contains("coordinator.verifiedLinks.links[contact.id] != nil"),
                      "only a VERIFIED link can be written — an ask on a dead link is a dead end")
        XCTAssertTrue(cards.contains("case .notDetermined:"))
        XCTAssertTrue(cards.contains("askCard(titleKey: \"family.photo.accessTitle\","))
        XCTAssertTrue(cards.contains("bodyKey: \"family.photo.accessBody\")"))
        XCTAssertTrue(cards.contains("case .denied:"))
        XCTAssertTrue(cards.contains("photoAccessDeniedLine"))
        XCTAssertTrue(cards.contains("case .allowed, .limited, nil:"))
        XCTAssertTrue(cards.contains("EmptyView()"))

        // The shared ask card: the frozen Allow key and the wizard's
        // EXISTING grantAccess — one ask path for both steps.
        let ask = try region(between: "private func askCard(titleKey: String, bodyKey: String) -> some View {",
                             and: "private var openSettingsButton: some View {", in: wizard)
        XCTAssertTrue(ask.contains("grantAccess()"))
        XCTAssertTrue(ask.contains("Text(\"call.search.allowButton\")"))
        XCTAssertTrue(ask.contains(".frame(minHeight: DesignTokens.minTapTargetSize)"),
                      "the Allow control is ≥44 pt (NFR-FCU-005)")

        // The denied line: the frozen honest body + the Settings door.
        let denied = try region(between: "private var photoAccessDeniedLine: some View {",
                                and: "private var photoStateLine: some View {", in: wizard)
        XCTAssertTrue(denied.contains("Text(\"family.photo.accessDeniedBody\")"))
        XCTAssertTrue(denied.contains("openSettingsButton"))

        let settings = try region(between: "private var openSettingsButton: some View {",
                                  and: "private var blockedSearchCard: some View {", in: wizard)
        XCTAssertTrue(settings.contains("UIApplication.openSettingsURLString"))
        XCTAssertTrue(settings.contains("Text(\"call.search.openSettings\")"))
    }

    /// The post-save label line (design-l2 §2.4/§1.5): the state's key
    /// through the ONE pure mapping, with the denied explanation beside
    /// the denied state only.
    func testPhotoStateLineRendersTheMappedKeyAndTheDeniedBody() throws {
        let wizard = try wizardRegion()
        let line = try region(between: "private var photoStateLine: some View {",
                              and: "private var displayedPhoto: UIImage? {", in: wizard)
        XCTAssertTrue(line.contains("if let state = photoSaveState {"))
        XCTAssertTrue(line.contains(
            "Text(LocalizedStringKey(FamilyWizardPhotoPresentation.stateLabelKey(state)))"))
        XCTAssertTrue(line.contains("if FamilyWizardPhotoPresentation.showsAccessDeniedBody(state) {"))
        XCTAssertTrue(line.contains("Text(\"family.photo.accessDeniedBody\")"))
    }

    /// The save-flow sequencing (design-l2 §2.6, §10.2): the store write
    /// runs FIRST (failure keeps the draft, no system attempt), the full
    /// nickname list and the draft id pass through, and the photo Task
    /// resolves the honest state through the ONE pure seam — `.written`
    /// (F4) keeps the sheet open exactly like every other non-nil state.
    func testSaveFlowSequencingIsPinnedAtTheSource() throws {
        let wizard = try wizardRegion()
        let save = try region(between: "private func save() {",
                              and: "private func trimmedOrNil(", in: wizard)

        XCTAssertTrue(save.contains("let savedID = editingContact?.id ?? newDraftID"),
                      "the add-case id is known BEFORE the store write (§2.6)")
        XCTAssertTrue(save.contains("guard succeeded else { return }"),
                      "a failed store write keeps the draft — no system attempt")
        XCTAssertTrue(save.contains("let photoIntent = pickedPhoto != nil || removingPhoto"))
        XCTAssertTrue(save.contains("guard photoIntent else {"),
                      "no photo changed → today's UX, no write attempted")
        XCTAssertTrue(save.contains("await coordinator.syncSystemPhoto(forContactID: savedID,"))
        XCTAssertTrue(save.contains("clearing: removingPhoto)"))

        // The store write runs BEFORE the photo task (step 1 first).
        let write = try XCTUnwrap(save.range(of: "coordinator.updateFamilyContact("))
        let task = try XCTUnwrap(save.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(write.lowerBound, task.lowerBound)

        XCTAssertTrue(save.contains("FamilyWizardPhotoPresentation.rechecksRemoval(outcome: outcome,"),
                      "the remove-path recheck (§10.4) goes through the pure trigger")
        XCTAssertTrue(save.contains(".faceImageWithSource(for: contact).isSystemPhoto"),
                      "the recheck reads the SAME precedence resolver the preview uses")
        XCTAssertTrue(save.contains("FamilyWizardPhotoPresentation.saveState("))
        XCTAssertTrue(save.contains("photoSaveState = state"))
        XCTAssertTrue(save.contains("step = .photo"),
                      "the honest label lives on the photo step")
        XCTAssertTrue(save.contains("dismiss()"),
                      "the nil state (unlinked, or the contact gone) is today's UX")

        // Both write seams carry the FULL nickname list and the saved id.
        XCTAssertEqual(occurrences(of: "nicknames: nicknames,", in: save), 2,
                       "the full list passes to add AND update (T-156's widened seam)")
        XCTAssertEqual(occurrences(of: "link: draftLink", in: save), 2,
                       "the draft link still passes through both seams (T-159)")
        XCTAssertTrue(save.contains("id: savedID, name: trimmedName, phone: phone,"),
                      "the add reuses the draft id — re-saves update the same contact")
    }

    /// The footer (design-l2 §2.6): while a post-save state is on screen
    /// the primary button becomes `common.close` and it dismisses — the
    /// sheet stays open exactly so the owner sees what happened.
    func testFooterOffersCloseWhileAPostSaveStateIsShown() throws {
        let wizard = try wizardRegion()
        let footer = try region(between: "private var primaryTitleKey: String {",
                                and: "private var primaryEnabled: Bool {", in: wizard)
        XCTAssertTrue(footer.contains("if photoSaveState != nil { return \"common.close\" }"))

        let action = try region(between: "private func primaryAction() {",
                                and: "private func loadDraft() {", in: wizard)
        XCTAssertTrue(action.contains("if photoSaveState != nil {"))
        XCTAssertTrue(action.contains("dismiss()"))
        XCTAssertTrue(action.contains("step == .nickname {"),
                      "the pre-save flow is unchanged: Save on the last step")
    }

    /// The F4 comment (unit index; design-l1 §10.2 step 3's auto-dismiss
    /// wording alignment deferred to T-165) is a COMMENT — so this pin
    /// reads the RAW file, the one place `codeText`'s comment stripping
    /// would erase the subject. The label itself is the single frozen
    /// string above; nothing second is invented.
    func testF4CommentRecordsTheDeliberateLabelAndTheT165Deferral() throws {
        let raw = try String(contentsOf: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift"),
            encoding: .utf8)
        XCTAssertTrue(raw.contains("F4"),
                      "the F4 decision must be documented at the mapping")
        XCTAssertTrue(raw.contains("T-165"),
                      "the design-doc alignment deferral to T-165 must be recorded")
        XCTAssertEqual(occurrences(of: "\"family.photo.state.updatedInSystem\"", in: raw), 1,
                       "one string only — no second label for the F4 path")
    }

    /// The nickname list wiring (design-l2 §2.5): the enumerated list
    /// (duplicates preserved), the ≥44 pt a11y-labelled remove control,
    /// the add row gated by the pure 8-cap seam and committing through
    /// the F5 seam, the hint caption, and `loadDraft` reading the FULL
    /// stored list — the interim single-field draft is gone.
    func testNicknameListWiringIsPinnedAtTheSource() throws {
        let wizard = try wizardRegion()
        let settings = settingsSource()

        XCTAssertEqual(occurrences(of: "@State private var nickname = \"\"", in: wizard), 0,
                       "the single-field draft state is gone (T-160)")
        XCTAssertTrue(wizard.contains("@State private var nicknames: [String] = []"))
        XCTAssertTrue(wizard.contains("@State private var nicknameDraft = \"\""))
        XCTAssertTrue(wizard.contains("nicknames = contact.nicknames"),
                      "loadDraft loads the FULL stored list (§2.5)")

        let list = try region(between: "private var nicknameList: some View {",
                              and: "private func nicknameRow(", in: wizard)
        XCTAssertTrue(list.contains("ForEach(Array(nicknames.enumerated()), id: \\.offset)"),
                      "one row per OCCURRENCE — duplicates preserved")

        let row = try region(between: "private func nicknameRow(_ entry: String, index: Int) -> some View {",
                             and: "private var nicknameAddRow: some View {", in: wizard)
        XCTAssertTrue(row.contains("nicknames.remove(at: index)"))
        XCTAssertTrue(row.contains(".frame(minWidth: DesignTokens.minTapTargetSize,"))
        XCTAssertTrue(row.contains("minHeight: DesignTokens.minTapTargetSize)"),
                      "the remove control is ≥44 pt (NFR-FCU-005)")
        XCTAssertTrue(row.contains("L10n.fmt(\"family.nickname.removeLabel\","),
                      "the remove control's a11y label goes through the frozen key")
        XCTAssertTrue(row.contains("locale: coordinator.activeLocale, entry)"),
                      "the formatted label carries the entry in the active locale")
        XCTAssertTrue(row.contains(".appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)"))

        let add = try region(between: "private var nicknameAddRow: some View {",
                             and: "private var nicknameHint: some View {", in: wizard)
        XCTAssertTrue(add.contains(
            "if FamilyWizardNicknamePresentation.canAdd(entries: nicknames) {"),
            "the add row hides at the 8-entry envelope")
        XCTAssertTrue(add.contains("prompt: Text(LocalizedStringKey(\"family.nickname.entryPlaceholder\")))"))
        XCTAssertTrue(add.contains(
            "guard let entry = FamilyWizardNicknamePresentation.newEntry(from: nicknameDraft)"))
        XCTAssertTrue(add.contains("nicknames.append(entry)"))
        XCTAssertTrue(add.contains("nicknameDraft = \"\""))
        XCTAssertTrue(add.contains("Text(\"family.nickname.add\")"))
        XCTAssertTrue(add.contains(".accessibilityLabel(Text(\"family.nickname.add\"))"))
        XCTAssertTrue(add.contains(".frame(minHeight: DesignTokens.minTapTargetSize)"),
                      "the Add control is ≥44 pt (NFR-FCU-005)")

        let hint = try region(between: "private var nicknameHint: some View {",
                              and: "private var footerButtons: some View {", in: wizard)
        XCTAssertTrue(hint.contains("Text(\"family.nickname.hint\")"))

        // The step renders list → add row → hint, above the unchanged
        // address/email fields.
        let step = try region(between: "private var nicknameStep: some View {",
                              and: "private var nicknameList: some View {", in: wizard)
        var cursor = step.startIndex
        for marker in ["nicknameList", "nicknameAddRow", "nicknameHint"] {
            guard let found = step.range(of: marker, range: cursor..<step.endIndex) else {
                return XCTFail("`\(marker)` must render in §2.5 order")
            }
            cursor = found.upperBound
        }
        XCTAssertFalse(step.contains("TextField(\"\", text: $nickname)"),
                       "the single free-text field is replaced by the managed list")

        // One wizard, one file — the settings source scan stays honest.
        XCTAssertFalse(settings.isEmpty)
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
    /// `FamilyWizardFindStepTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "SettingsView.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
