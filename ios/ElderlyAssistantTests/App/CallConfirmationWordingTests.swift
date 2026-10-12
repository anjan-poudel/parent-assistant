import XCTest
@testable import ElderlyAssistant

/// T-148 — the confirmation utterance (C3 voice confirmation flow;
/// design-l2 §8, §15 step 5, §28). Three obligations, one home:
///
/// 1. The fallback disclosure names the skipped channel (`fellBackFrom
///    .first`), the contact and the ROUTED channel — composed through
///    the real catalog, the same `confirmationPrompt` the app speaks.
/// 2. With empty provenance the composed parts are the shipped parts,
///    byte-identically (the shipped baseline is the `confirmationPrompt`
///    at commit `eafa4bcc`, unchanged through the W4 branch point — the
///    release-1 wording FR-CDP-013 scenario 3 freezes).
/// 3. The override block stays diff-clean (FR-CDP-014; SA-4(b)): the
///    no-handle gate, the amended construction that DROPS provenance and
///    the single re-confirmation are pinned at the source, and the new
///    regions add no console write, no event and no catalog key.
///
/// The prompt is driven with a CONSTRUCTED `PendingCallAction` (the
/// design §28 seam — "`confirmationPrompt` via the real catalog"); the
/// coordinator instance exists for its locale, seeded through the real
/// `appLanguage` seam and restored around every test (the
/// `CallingSettingsSurfaceTests`/`ColdStartRoutingTests` discipline).
/// What a unit test cannot witness — the spoken audio, the window timing,
/// the device route — stays DV-2's job and is not simulated here.
final class CallConfirmationWordingTests: XCTestCase {

    /// The two languages the copy ships in (FR-CDP-017); every wording
    /// assertion runs in both, so an ne/en divergence fails here.
    private static let languages: [AppLanguage] = [.english, .nepali]

    /// One fixture contact. The name is the disclosure's `%2$@`; the
    /// phone is never read by the prompt.
    private static let maya = FamilyContact(name: "Maya Gurung",
                                            phone: "+9779812345678",
                                            relationship: "daughter")

    /// The coordinator's own language key (`AppLanguage` keeps its
    /// defaults key private; this string is the seam the app really
    /// writes). Snapshot/restore exactly like the call-preference keys.
    private static let languageKey = "appLanguage"

    private var languageBackup: Any?

    override func setUp() {
        super.setUp()
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
    }

    override func tearDown() {
        if let languageBackup {
            UserDefaults.standard.set(languageBackup, forKey: Self.languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.languageKey)
        }
        super.tearDown()
    }

    // MARK: - Scenario: the prompt discloses the skip and names the routed one

    /// The disclosure clause carries the three slots the catalog freezes
    /// (`%1$@` skipped label, `%2$@` contact name, `%3$@` routed label)
    /// and the question sentence still names the ROUTED channel — never
    /// the skipped one. Two routed-channel cases: the phone floor and a
    /// chat method, so "the routed label" cannot pass by accident.
    @MainActor
    func testDisclosureNamesSkippedAndRouted() throws {
        for language in Self.languages {
            let coordinator = makeCoordinator(language: language)
            let locale = coordinator.activeLocale
            let contact = Self.maya

            // Messenger skipped, WhatsApp also attempted and skipped —
            // the clause names fellBackFrom.first (attempt order).
            let floorAction = AppCoordinator.PendingCallAction(
                contact: contact,
                method: .phone,
                unsupportedRequestedApp: nil,
                sourceTranscript: nil,
                sourceCommand: nil,
                fellBackFrom: [.messenger, .whatsApp],
                hopCandidates: [.whatsApp])
            let floorPrompt = coordinator.confirmationPrompt(for: floorAction, isRepeat: false)

            let clause = L10n.fmt("router.call.fallbackDisclosure", locale: locale,
                                  CallChannelChain.label(.messenger, locale: locale),
                                  contact.name,
                                  CallChannelChain.label(.phone, locale: locale))
            XCTAssertTrue(floorPrompt.contains(clause),
                          "\(locale.identifier): the disclosure must name the skipped label, "
                          + "the contact and the routed label in the catalog's slots — "
                          + "got: \(floorPrompt)")
            XCTAssertFalse(clause.contains(CallChannelChain.label(.whatsApp, locale: locale)),
                           "\(locale.identifier): the clause names the FIRST skipped channel, "
                           + "not a later candidate")

            let floorQuestion = L10n.fmt("router.call.confirmQuestion", locale: locale,
                                         contact.name,
                                         L10n.str("router.call.methodPhone", locale: locale))
            XCTAssertTrue(floorPrompt.hasSuffix(floorQuestion),
                          "\(locale.identifier): the question sentence still names the routed "
                          + "channel — got: \(floorPrompt)")
            let clauseStart = try XCTUnwrap(floorPrompt.range(of: clause),
                                            "\(locale.identifier): clause missing from its own prompt")
            let questionStart = try XCTUnwrap(floorPrompt.range(of: floorQuestion),
                                              "\(locale.identifier): question missing from its own prompt")
            XCTAssertLessThan(clauseStart.lowerBound, questionStart.lowerBound,
                              "\(locale.identifier): the disclosure is spoken BEFORE the method "
                              + "sentence and question (design-l2 §8 part order)")

            // Routed = whatsAppChat while FaceTime was skipped: the clause
            // and the question both name the routed channel, and the
            // method sentence is the ROUTED method's key, not the skip's.
            let chatAction = AppCoordinator.PendingCallAction(
                contact: contact,
                method: .whatsappChat,
                unsupportedRequestedApp: nil,
                sourceTranscript: nil,
                sourceCommand: nil,
                fellBackFrom: [.faceTime])
            let chatPrompt = coordinator.confirmationPrompt(for: chatAction, isRepeat: false)
            let chatClause = L10n.fmt("router.call.fallbackDisclosure", locale: locale,
                                      CallChannelChain.label(.faceTime, locale: locale),
                                      contact.name,
                                      CallChannelChain.label(.whatsApp, locale: locale))
            XCTAssertTrue(chatPrompt.contains(chatClause),
                          "\(locale.identifier): the routed label must derive from the ROUTED "
                          + "method — got: \(chatPrompt)")
            XCTAssertTrue(chatPrompt.contains(
                L10n.fmt("router.call.confirmQuestion", locale: locale, contact.name,
                         L10n.str("router.call.methodWhatsAppChat", locale: locale))),
                "\(locale.identifier): the question must name the routed chat method — "
                + "got: \(chatPrompt)")
        }
    }

    // MARK: - Scenario: no fallback keeps the shipped prompt byte-identical

    /// Empty `fellBackFrom` composes EXACTLY the shipped part sequence
    /// [repeat notice][unsupported-app notice][question] with single-space
    /// joins — no disclosure, no extra part, no punctuation drift. The
    /// shipped composition is the pre-feature `confirmationPrompt`
    /// (commit `eafa4bcc`), so this equality is the byte-identity pin the
    /// FR-CDP-013 scenario 3 / SA-5 obligations name.
    @MainActor
    func testNoFallbackKeepsPromptByteIdentical() {
        for language in Self.languages {
            let coordinator = makeCoordinator(language: language)
            let locale = coordinator.activeLocale
            let contact = Self.maya

            let question = L10n.fmt("router.call.confirmQuestion", locale: locale,
                                    contact.name,
                                    L10n.str("router.call.methodPhone", locale: locale))
            let repeatNotice = L10n.fmt("router.call.recentRepeatNotice",
                                        locale: locale, contact.name)
            let unsupportedNotice = L10n.fmt("router.call.appUnsupportedNotice",
                                             locale: locale, "Viber")

            // The defaulted field is what makes "nothing fell back" the
            // shipped construction (L2-D3) — not a call-site convention.
            let bare = AppCoordinator.PendingCallAction(contact: contact,
                                                        method: .phone,
                                                        unsupportedRequestedApp: nil,
                                                        sourceTranscript: nil,
                                                        sourceCommand: nil)
            XCTAssertTrue(bare.fellBackFrom.isEmpty,
                          "\(locale.identifier): an unpassed fellBackFrom must default empty")
            XCTAssertEqual(coordinator.confirmationPrompt(for: bare, isRepeat: false),
                           question,
                           "\(locale.identifier): a call with no fallback speaks the shipped "
                           + "question, byte-identically (no disclosure)")

            XCTAssertEqual(coordinator.confirmationPrompt(for: bare, isRepeat: true),
                           repeatNotice + " " + question,
                           "\(locale.identifier): the repeat notice still precedes the question")

            let unsupported = AppCoordinator.PendingCallAction(contact: contact,
                                                               method: .facetimeAudio,
                                                               unsupportedRequestedApp: "Viber",
                                                               sourceTranscript: nil,
                                                               sourceCommand: nil)
            XCTAssertEqual(coordinator.confirmationPrompt(for: unsupported, isRepeat: false),
                           unsupportedNotice + " "
                           + L10n.fmt("router.call.confirmQuestion", locale: locale, contact.name,
                                      L10n.str("router.call.methodVoice", locale: locale)),
                           "\(locale.identifier): the unsupported-app notice still precedes "
                           + "the question and no disclosure is inserted")

            XCTAssertEqual(coordinator.confirmationPrompt(for: unsupported, isRepeat: true),
                           repeatNotice + " " + unsupportedNotice + " "
                           + L10n.fmt("router.call.confirmQuestion", locale: locale, contact.name,
                                      L10n.str("router.call.methodVoice", locale: locale)),
                           "\(locale.identifier): the shipped order is [repeat][unsupported]"
                           + "[question] with single-space joins")
        }
    }

    // MARK: - Scenario: the override protocol still wins pre-confirmation

    /// The override region is pinned at the source — code, comment-
    /// stripped, exact token sequences counted. A reorder, a weakened
    /// gate or a new field on the amended construction fails HERE rather
    /// than in a device session (FR-CDP-014; SA-4(b) "diff-clean").
    func testOverrideGateUntouchedPin() throws {
        let region = collapsed(try region(between: "func handleCallConfirmationOverride(",
                                          and: "func confirmationPrompt(",
                                          in: coordinatorSource()))

        // 1. The no-handle gate: the shipped refusal line, then `return
        // true` — the ORIGINAL action stays pending (the statement after
        // it is outside the gate: `pendingCallAction = amended`).
        XCTAssertEqual(occurrences(of: collapsed("""
            if override == .messengerAudio || override == .messengerVideo,
               CallLinks.messengerHandle(action.contact.messengerHandle ?? "").isEmpty {
                speak(text: L10n.fmt("router.call.messengerNoHandle", locale: activeLocale, action.contact.name))
                return true
            }
            """), in: region), 1,
            "the override no-handle gate must stay exactly as shipped (FR-CDP-014)")

        // 2. The amended action: built from the ORIGINAL action's contact
        // and flywheel pair, `unsupportedRequestedApp: nil`, and NOTHING
        // else — the provenance fields die with the amendment by
        // construction (design-l2 §8 "Override path — unchanged").
        XCTAssertEqual(occurrences(of: collapsed("""
            let amended = PendingCallAction(contact: action.contact,
                                            method: override,
                                            unsupportedRequestedApp: nil,
                                            sourceTranscript: action.sourceTranscript,
                                            sourceCommand: action.sourceCommand)
            """), in: region), 1,
            "the amended construction must stay byte-identical (provenance dropped)")

        // 3. The original capture appended as the flywheel's gold sample,
        // and exactly ONE re-confirmation over the amended action.
        XCTAssertEqual(occurrences(of: collapsed("""
            appendCapture(action.capture, .corrected,
                          path: "override",
                          correctedTo: ["method": override.rawValue])
            """), in: region), 1,
            "the override pair must still be captured as .corrected")
        XCTAssertEqual(occurrences(of:
            "speak(text: confirmationPrompt(for: amended, isRepeat: false))",
            in: region), 1,
            "the override must re-confirm exactly once over the amended action")

        // 4. Provenance never enters the region: no stale disclosure can
        // be re-spoken and no hop candidate survives an override.
        for field in ["fellBackFrom", "hopCandidates", "requestedAt"] {
            XCTAssertFalse(region.contains(field),
                           "the override region must not touch \(field) (provenance dropped)")
        }
    }

    /// The two regions this unit writes carry no console write and no
    /// event — the disclosure is SPEECH only (design-l2 §24; SA-5). The
    /// prompt's key surface is the shipped set plus the one existing
    /// disclosure key (T-155's catalog entry — no new key is minted
    /// here), and `router.call.messengerNoHandle` is no longer returned
    /// from `requestCallConfirmation`: the refusal lives on only in the
    /// override gate and the leaf stale-state guard.
    func testNewRegionsAddNoKeysOrConsoleWrites() throws {
        let text = coordinatorSource()
        let promptRegion = try region(between: "func confirmationPrompt(",
                                      and: "private func performCallAction(",
                                      in: text)
        let stepRegion = try region(between:
            "let resolved = methodResolver.resolve(contactId: contact.id,",
            and: "pendingCallAction = action", in: text)

        let consoleWrite = #"(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\s*\("#
        for (name, region) in [("confirmationPrompt", promptRegion),
                               ("requestCallConfirmation step 3", stepRegion)] {
            XCTAssertNil(firstMatch(of: consoleWrite, in: region),
                         "\(name): no console write may compile into the new code (SA-5/NFR-CDP-003)")
            XCTAssertFalse(region.contains("observabilityBus.emit"),
                           "\(name): speech only — nothing about a call is emitted here")
        }

        XCTAssertTrue(stepRegion.contains("Self.resolvedCallChannel("),
                      "step 3 must resolve through the shared chain seam")
        XCTAssertFalse(stepRegion.contains("router.call."),
                       "step 3 leaves the prompt keys to confirmationPrompt")

        // The milestone removal: requestCallConfirmation no longer early-
        // returns the no-handle refusal — the flow proceeds through the
        // chain to the floor, and the refusal line lives on only in the
        // override gate (pinned above) and the leaf stale-state guard.
        let flow = try region(between: "func requestCallConfirmation(",
                              and: "func handleCallConfirmationOverride(",
                              in: text)
        XCTAssertFalse(flow.contains("router.call.messengerNoHandle"),
                       "the messenger-no-handle early return must be gone from "
                       + "requestCallConfirmation — at that site only")

        XCTAssertEqual(matches(of: #""(router\.call\.[A-Za-z]+)""#, in: promptRegion).count, 10,
                       "the prompt's key surface is exactly the shipped nine keys plus "
                       + "router.call.fallbackDisclosure — a new literal fails here")
        XCTAssertEqual(occurrences(of: #""router.call.fallbackDisclosure""#, in: promptRegion), 1,
                       "the disclosure reads the ONE existing key (T-155's catalog entry)")

        // The disclosure key resolves in both languages — this unit adds
        // no catalog entry, it consumes T-155's.
        for language in Self.languages {
            XCTAssertNotEqual(L10n.str("router.call.fallbackDisclosure", locale: language.locale),
                              "router.call.fallbackDisclosure",
                              "the disclosure key must resolve from the \(language.rawValue) catalog")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(language: AppLanguage) -> AppCoordinator {
        // Seed BEFORE construction: the init restores through the real
        // `AppLanguage.persisted()` seam, so no didSet side-effect runs.
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        return AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `SettingsTabMappingTests.structSource` convention, adapted to a
    /// function whose type boundary is file-wide).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "AppCoordinator.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences and counts survive
    /// while indentation and line breaks do not (the source pins must fail
    /// on a weakened gate, not on a reformat).
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return nil
        }
        let search = text as NSString
        guard let match = regex.firstMatch(in: text,
                                           range: NSRange(location: 0, length: search.length)) else {
            return nil
        }
        return search.substring(with: match.range)
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return []
        }
        let search = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: search.length))
            .map { search.substring(with: $0.range) }
    }

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship — `ColdStartRoutingTests`,
    // `CallingSettingsSurfaceTests`: the coordinator's payload store only;
    // the seam under test is the real catalog + the real language store.)

    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }
}
