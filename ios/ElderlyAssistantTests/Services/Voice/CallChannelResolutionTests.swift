import XCTest
@testable import ElderlyAssistant

/// The channel-resolution matrix behind an ADDRESS-BOOK row's call
/// button (Phone-tab redesign, 2026-09-07): the row's explicit pick
/// beats the global default, and a `.messenger` result that has no
/// on-file handle drops to `.phone` — a row must never resolve to a
/// channel it cannot open. Pure static seam on AppCoordinator, so the
/// whole matrix is covered without instantiating the coordinator.
final class CallChannelResolutionTests: XCTestCase {

    func testExplicitPickBeatsDefault() {
        assertResolved(explicit: .whatsApp, defaultApp: .phone, handleAvailable: true, expected: .whatsApp)
        assertResolved(explicit: .faceTime, defaultApp: .phone, handleAvailable: true, expected: .faceTime)
        assertResolved(explicit: .messenger, defaultApp: .whatsApp, handleAvailable: true, expected: .messenger)
        assertResolved(explicit: .phone, defaultApp: .messenger, handleAvailable: true, expected: .phone)
    }

    func testMissingExplicitFallsBackToDefault() {
        assertResolved(explicit: nil, defaultApp: .whatsApp, handleAvailable: true, expected: .whatsApp)
        assertResolved(explicit: nil, defaultApp: .faceTime, handleAvailable: true, expected: .faceTime)
        assertResolved(explicit: nil, defaultApp: .phone, handleAvailable: false, expected: .phone)
    }

    func testDefaultMessengerWithoutHandleDropsToPhone() {
        assertResolved(explicit: nil, defaultApp: .messenger, handleAvailable: false, expected: .phone)
    }

    func testDefaultMessengerWithHandleStaysMessenger() {
        assertResolved(explicit: nil, defaultApp: .messenger, handleAvailable: true, expected: .messenger)
    }

    func testExplicitMessengerWithoutHandleDropsToPhone() {
        // A row with no handle cannot open a Messenger thread even when
        // the user explicitly pinned Messenger — .phone is the honest
        // openable channel (contract: never resolve to a channel the
        // row cannot open).
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: false, expected: .phone)
        assertResolved(explicit: .messenger, defaultApp: .messenger, handleAvailable: false, expected: .phone)
    }

    func testExplicitMessengerWithHandleStaysMessenger() {
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: true, expected: .messenger)
    }

    func testWhatsAppFaceTimeAndPhonePassThroughWithoutHandle() {
        // The handle gate applies to Messenger only — every other
        // channel opens by phone number and is unaffected.
        assertResolved(explicit: .whatsApp, defaultApp: .phone, handleAvailable: false, expected: .whatsApp)
        assertResolved(explicit: .faceTime, defaultApp: .phone, handleAvailable: false, expected: .faceTime)
        assertResolved(explicit: .phone, defaultApp: .messenger, handleAvailable: false, expected: .phone)
        assertResolved(explicit: nil, defaultApp: .whatsApp, handleAvailable: false, expected: .whatsApp)
        assertResolved(explicit: nil, defaultApp: .faceTime, handleAvailable: false, expected: .faceTime)
        assertResolved(explicit: nil, defaultApp: .phone, handleAvailable: false, expected: .phone)
    }

    /// Drives the six-argument seam (T-146) and asserts the routed
    /// channel plus, when given, its provenance. The defaults describe
    /// the shipped row semantics the seven tests above pin: the phone
    /// floor as the secondary, WhatsApp routable as before (the probe
    /// input is a Bool here — no platform probe runs in the matrix) and
    /// any-channel vocabulary. Returns the full `Result` so callers can
    /// assert provenance themselves.
    @discardableResult
    private func assertResolved(explicit: CallApp?, defaultApp: CallApp,
                                secondaryApp: CallApp = .phone,
                                handleAvailable: Bool,
                                whatsAppInstalled: Bool = true,
                                vocabulary: CallChannelVocabulary = .anyChannel,
                                expected: CallApp,
                                expectedFellBackFrom: [CallApp]? = nil,
                                file: StaticString = #filePath, line: UInt = #line)
                                -> CallChannelChain.Result {
        let result = AppCoordinator.resolvedCallChannel(explicit: explicit,
                                                        defaultApp: defaultApp,
                                                        secondaryApp: secondaryApp,
                                                        messengerHandleAvailable: handleAvailable,
                                                        whatsAppInstalled: whatsAppInstalled,
                                                        vocabulary: vocabulary)
        let cell = "explicit: \(String(describing: explicit)), default: \(defaultApp), "
            + "secondary: \(secondaryApp), handle: \(handleAvailable), "
            + "whatsApp: \(whatsAppInstalled), vocabulary: \(vocabulary)"
        XCTAssertEqual(result.channel, expected, cell, file: file, line: line)
        if let expectedFellBackFrom {
            XCTAssertEqual(result.fellBackFrom, expectedFellBackFrom,
                           "provenance — " + cell, file: file, line: line)
        }
        return result
    }

    // MARK: - CallChannelChain core (T-145)
    //
    // Security evidence for call-dialer-primary-secondary: SA-1 (the chain
    // never dead-ends), SA-2 (the hop statics consume candidates strictly,
    // at-most-once) and the core of SA-3 (vocabulary legality). Everything
    // below drives the pure statics in `Services/Calls/CallChannelChain.swift`
    // directly — no coordinator instance, no platform probe, no clock.

    /// The four channels, ordered so a failing matrix cell names itself.
    private static let chainChannels: [CallApp] = [.faceTime, .phone, .messenger, .whatsApp]

    private let englishLocale = Locale(identifier: "en-US")
    private let nepaliLocale = Locale(identifier: "ne-NP")

    /// Both environment facts at both values — the four feasibility
    /// combinations the never-dead-ends matrix crosses with the sixteen
    /// ordered (primary, secondary) pairs (sixty-four cells).
    private func chainFeasibilityCombos() -> [(handle: Bool, whatsApp: Bool)] {
        [true, false].flatMap { handle in
            [true, false].map { whatsApp in (handle: handle, whatsApp: whatsApp) }
        }
    }

    /// SA-1 / NFR-CDP-001 — the never-dead-ends matrix: all sixteen
    /// ordered (primary, secondary) pairs across the four feasibility
    /// combinations (sixty-four cells, counted). Every cell asserts the
    /// routed channel is feasible under the supplied facts, `.phone` is
    /// contained in the attempt order, the order carries no duplicate,
    /// every returned channel is legal for the surface vocabulary
    /// (any-channel here; the audio/video surfaces are covered by
    /// `testVocabularySubstitutionCannotDeadEndTheRoute`), the provenance
    /// is exactly the skipped attempt-order prefix, and it is empty when
    /// the preferred channel was routed.
    func testEveryConfigurationResolvesToAnAttemptableChannel() {
        var cells = 0
        for preferred in Self.chainChannels {
            for secondary in Self.chainChannels {
                for combo in chainFeasibilityCombos() {
                    cells += 1
                    let feasibility = CallChannelChain.Feasibility(
                        messengerHandleAvailable: combo.handle,
                        whatsAppInstalled: combo.whatsApp)
                    let cell = "preferred: \(preferred), secondary: \(secondary), "
                        + "handle: \(combo.handle), whatsApp: \(combo.whatsApp)"
                    let order = CallChannelChain.attemptOrder(preferred: preferred,
                                                              secondary: secondary)
                    let result = CallChannelChain.route(preferred: preferred,
                                                        secondary: secondary,
                                                        feasibility: feasibility)

                    // The routed channel can actually be attempted.
                    XCTAssertTrue(CallChannelChain.isFeasible(result.channel,
                                                              feasibility: feasibility), cell)
                    XCTAssertTrue(order.contains(result.channel), cell)
                    // Containment (M-2): `.phone` is always IN the order.
                    XCTAssertTrue(order.contains(.phone), cell)
                    // Dedupe: one to three DISTINCT channels.
                    XCTAssertTrue((1...3).contains(order.count), cell)
                    XCTAssertEqual(Set(order).count, order.count, cell)
                    // Vocabulary legality of every returned channel.
                    XCTAssertTrue(CallChannelVocabulary.anyChannel.permits(result.channel), cell)
                    for skipped in result.fellBackFrom {
                        XCTAssertTrue(CallChannelVocabulary.anyChannel.permits(skipped), cell)
                        XCTAssertFalse(CallChannelChain.isFeasible(skipped,
                                                                   feasibility: feasibility), cell)
                    }
                    XCTAssertEqual(Set(result.fellBackFrom).count, result.fellBackFrom.count, cell)
                    // Provenance is the skipped prefix, in attempt order.
                    XCTAssertEqual(result.fellBackFrom,
                                   Array(order.prefix(while: { $0 != result.channel })), cell)
                    if result.channel == preferred {
                        XCTAssertTrue(result.fellBackFrom.isEmpty, cell)
                    } else {
                        XCTAssertEqual(result.fellBackFrom.first, preferred, cell)
                    }
                }
            }
        }
        XCTAssertEqual(cells, 64, "every ordered pair x feasibility combination must run")
    }

    /// SA-1 — a feasible preferred wins outright (empty provenance), and a
    /// channel that is both primary and secondary appears once (dedupe):
    /// skipped once, never twice.
    func testPreferredWinsAndEqualPicksDedupe() {
        let everythingFeasible = CallChannelChain.Feasibility(messengerHandleAvailable: true,
                                                              whatsAppInstalled: true)
        for channel in Self.chainChannels {
            let result = CallChannelChain.route(preferred: channel, secondary: channel,
                                                feasibility: everythingFeasible)
            XCTAssertEqual(result.channel, channel, "equal feasible picks route the preferred")
            XCTAssertTrue(result.fellBackFrom.isEmpty,
                          "a routed preferred never reports provenance")
            let expected: [CallApp] = channel == .phone ? [.phone] : [channel, .phone]
            XCTAssertEqual(CallChannelChain.attemptOrder(preferred: channel, secondary: channel),
                           expected)
        }
        let nothingFeasible = CallChannelChain.Feasibility(messengerHandleAvailable: false,
                                                           whatsAppInstalled: false)
        let messenger = CallChannelChain.route(preferred: .messenger, secondary: .messenger,
                                               feasibility: nothingFeasible)
        XCTAssertEqual(messenger.channel, .phone)
        XCTAssertEqual(messenger.fellBackFrom, [.messenger])
        let whatsApp = CallChannelChain.route(preferred: .whatsApp, secondary: .whatsApp,
                                              feasibility: nothingFeasible)
        XCTAssertEqual(whatsApp.channel, .phone)
        XCTAssertEqual(whatsApp.fellBackFrom, [.whatsApp])
    }

    /// SA-1 — a probe-stubbed-absent WhatsApp is skipped at routing, the
    /// secondary (or the floor) is routed, the provenance carries the
    /// skipped channel, and the order stays attemptable. The probe helper
    /// itself supplies the feasibility fact (NFR-CDP-002 — a closure, no
    /// I/O in the chain).
    func testStubbedAbsentWhatsAppStillRoutes() {
        var probedURL: URL?
        let whatsAppInstalled = CallChannelChain.whatsAppInstalled(canOpen: { url in
            probedURL = url
            return false
        })
        XCTAssertFalse(whatsAppInstalled)
        XCTAssertEqual(probedURL, CallChannelChain.whatsAppProbeURL)

        let feasibility = CallChannelChain.Feasibility(messengerHandleAvailable: true,
                                                       whatsAppInstalled: whatsAppInstalled)
        let order = CallChannelChain.attemptOrder(preferred: .whatsApp, secondary: .phone)
        let toPhone = CallChannelChain.route(preferred: .whatsApp, secondary: .phone,
                                             feasibility: feasibility)
        XCTAssertEqual(toPhone.channel, .phone)
        XCTAssertEqual(toPhone.fellBackFrom, [.whatsApp])
        XCTAssertEqual(order, [.whatsApp, .phone])
        XCTAssertTrue(CallChannelChain.isFeasible(toPhone.channel, feasibility: feasibility))
        XCTAssertTrue(order.contains(toPhone.channel))

        let toMessenger = CallChannelChain.route(preferred: .whatsApp, secondary: .messenger,
                                                 feasibility: feasibility)
        XCTAssertEqual(toMessenger.channel, .messenger)
        XCTAssertEqual(toMessenger.fellBackFrom, [.whatsApp])
        XCTAssertTrue(CallChannelChain.isFeasible(toMessenger.channel, feasibility: feasibility))
    }

    /// SA-1 / M-2 / V-6 — the renamed order test (the retired
    /// ends-with-phone name is not used anywhere). Asserts exactly the
    /// binding trio: containment of `.phone`, `isFeasible(routed)` and
    /// preferred-first. It deliberately never asserts the retired
    /// last-element property — when the preferred IS phone the order is
    /// `[.phone, secondary]`, so that property would be literally false,
    /// and the order is never reordered to satisfy the superseded wording.
    func testOrderContainsPhonePreferredFirst() {
        for preferred in Self.chainChannels {
            for secondary in Self.chainChannels {
                let order = CallChannelChain.attemptOrder(preferred: preferred,
                                                          secondary: secondary)
                let cell = "preferred: \(preferred), secondary: \(secondary)"
                XCTAssertEqual(order.first, preferred, cell)
                XCTAssertTrue(order.contains(.phone), cell)
                XCTAssertEqual(Set(order).count, order.count, cell)
                for combo in chainFeasibilityCombos() {
                    let feasibility = CallChannelChain.Feasibility(
                        messengerHandleAvailable: combo.handle,
                        whatsAppInstalled: combo.whatsApp)
                    let result = CallChannelChain.route(preferred: preferred,
                                                        secondary: secondary,
                                                        feasibility: feasibility)
                    XCTAssertTrue(CallChannelChain.isFeasible(result.channel,
                                                              feasibility: feasibility), cell)
                }
            }
        }
        // The containment exemplar from the design record: preferred phone
        // sits FIRST here — this test reads containment and first-position
        // only.
        XCTAssertEqual(CallChannelChain.attemptOrder(preferred: .phone, secondary: .whatsApp),
                       [.phone, .whatsApp])
    }

    /// SA-2 — the hop candidate list is the attempt-order suffix after the
    /// routed channel, re-applied through the surface vocabulary; when the
    /// filtered list empties the vocabulary terminal is appended unless it
    /// is the routed channel itself (design-l2 section 10.4 case table,
    /// L2-D1).
    func testHopCandidatesRespectVocabulary() {
        // any-channel: the raw suffix, every channel permitted.
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .phone,
                                                      routed: .messenger),
                       [.phone])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .faceTime, secondary: .faceTime,
                                                      routed: .faceTime),
                       [.phone])
        // audio: the FaceTime secondary is filtered (audio never FaceTime).
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .faceTime,
                                                      routed: .messenger, vocabulary: .audio),
                       [.phone])
        // video: the GSM floor is filtered and the terminal (FaceTime) is
        // appended (video never the GSM dialer).
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .phone,
                                                      routed: .messenger, vocabulary: .video),
                       [.faceTime])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .whatsApp, secondary: .phone,
                                                      routed: .whatsApp, vocabulary: .video),
                       [.faceTime])
    }

    /// SA-2 / L2-D1 — a vocabulary-SUBSTITUTED routed channel (the
    /// substitution is the surface's floor, already routed) and a routed
    /// terminal have NO candidates (design-l2 section 10.4 case table).
    func testSubstitutedTerminalHasNoCandidates() {
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .phone,
                                                      routed: .faceTime, vocabulary: .video),
                       [])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .faceTime,
                                                      routed: .phone, vocabulary: .audio),
                       [])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .phone, secondary: .phone,
                                                      routed: .phone),
                       [])
    }

    /// SA-2 — the hop statics consume candidates strictly: every step
    /// returns a channel from the remaining list, never the one that just
    /// failed and never a repeat; the list shrinks by at least one channel
    /// per step, every channel is attempted at most once, and exhaustion
    /// is `nil` (a defined state, not an error). Depth is structurally at
    /// most two over the whole matrix (design-l2 section 10.3).
    func testHopConsumesCandidatesNeverLoops() {
        // The worked example: routed messenger, candidates whatsApp then
        // the floor; consumption is messenger, whatsApp, phone, then
        // exhaustion.
        let candidates = CallChannelChain.hopCandidates(preferred: .messenger,
                                                        secondary: .whatsApp,
                                                        routed: .messenger)
        XCTAssertEqual(candidates, [.whatsApp, .phone])
        var attempted: [CallApp] = [.messenger]
        var remaining = candidates
        var failed: CallApp = .messenger
        while let next = CallChannelChain.nextLaunchFailCandidate(
            after: failed,
            attemptOrder: remaining,
            messengerHandleAvailable: true
        ) {
            XCTAssertFalse(attempted.contains(next), "a channel is attempted at most once")
            attempted.append(next)
            remaining = Array(remaining.drop(while: { $0 != next }).dropFirst())
            failed = next
        }
        XCTAssertEqual(attempted, [.messenger, .whatsApp, .phone])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(CallChannelChain.nextLaunchFailCandidate(after: .phone,
                                                             attemptOrder: remaining,
                                                             messengerHandleAvailable: true))

        // Structural sweep over the same sixty-four cells: at most two
        // candidates per routed channel, strict shrink per consumed step,
        // no repeats, and only an un-attemptable messenger can remain at
        // exhaustion.
        var cells = 0
        for preferred in Self.chainChannels {
            for secondary in Self.chainChannels {
                for combo in chainFeasibilityCombos() {
                    cells += 1
                    let cell = "preferred: \(preferred), secondary: \(secondary), "
                        + "handle: \(combo.handle), whatsApp: \(combo.whatsApp)"
                    let feasibility = CallChannelChain.Feasibility(
                        messengerHandleAvailable: combo.handle,
                        whatsAppInstalled: combo.whatsApp)
                    let routed = CallChannelChain.route(preferred: preferred,
                                                        secondary: secondary,
                                                        feasibility: feasibility).channel
                    let hopList = CallChannelChain.hopCandidates(preferred: preferred,
                                                                 secondary: secondary,
                                                                 routed: routed)
                    XCTAssertLessThanOrEqual(hopList.count, 2, cell)
                    XCTAssertFalse(hopList.contains(routed), cell)
                    XCTAssertEqual(Set(hopList).count, hopList.count, cell)

                    var remaining = hopList
                    var exhaustedAfter = routed
                    var consumed: [CallApp] = []
                    var sizes: [Int] = [remaining.count]
                    while let next = CallChannelChain.nextLaunchFailCandidate(
                        after: exhaustedAfter,
                        attemptOrder: remaining,
                        messengerHandleAvailable: combo.handle
                    ) {
                        XCTAssertTrue(remaining.contains(next), cell)
                        XCTAssertFalse(consumed.contains(next), cell)
                        consumed.append(next)
                        remaining = Array(remaining.drop(while: { $0 != next }).dropFirst())
                        sizes.append(remaining.count)
                        exhaustedAfter = next
                    }
                    for step in 1..<sizes.count {
                        XCTAssertLessThan(sizes[step], sizes[step - 1], cell)
                    }
                    XCTAssertLessThanOrEqual(consumed.count, 2, cell)
                    XCTAssertTrue(remaining.allSatisfy { $0 == .messenger && !combo.handle },
                                  cell)
                }
            }
        }
        XCTAssertEqual(cells, 64, "the depth bound must hold over every matrix cell")
    }

    /// SA-2 — the suffix filter excludes what the chain already skipped: a
    /// null-handle Messenger or a probe-absent WhatsApp passed over at
    /// routing time is never re-offered as a hop candidate. The ONE
    /// Messenger-without-handle drop lives in `nextLaunchFailCandidate`
    /// (L2-D6): the raw candidate list keeps the channel, the decision
    /// drops it, and a probe-absent WhatsApp stays attemptable (the
    /// decision carries no probe result — best-effort, structurally).
    func testSuffixFilterDropsSkippedInfeasibleChannels() {
        // A null-handle Messenger skipped at routing is not re-offered.
        let skippedMessenger = CallChannelChain.route(
            preferred: .messenger, secondary: .phone,
            feasibility: CallChannelChain.Feasibility(messengerHandleAvailable: false,
                                                      whatsAppInstalled: true))
        XCTAssertEqual(skippedMessenger.fellBackFrom, [.messenger])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .phone,
                                                      routed: skippedMessenger.channel),
                       [])
        // A probe-absent WhatsApp skipped at routing is not re-offered.
        let skippedWhatsApp = CallChannelChain.route(
            preferred: .whatsApp, secondary: .phone,
            feasibility: CallChannelChain.Feasibility(messengerHandleAvailable: true,
                                                      whatsAppInstalled: false))
        XCTAssertEqual(skippedWhatsApp.fellBackFrom, [.whatsApp])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .whatsApp, secondary: .phone,
                                                      routed: skippedWhatsApp.channel),
                       [])
        // A mid-order skip: whatsApp passed over, messenger routed; the
        // skipped channel sits before the routed one, not after it.
        let midSkip = CallChannelChain.route(
            preferred: .whatsApp, secondary: .messenger,
            feasibility: CallChannelChain.Feasibility(messengerHandleAvailable: true,
                                                      whatsAppInstalled: false))
        XCTAssertEqual(midSkip.channel, .messenger)
        XCTAssertEqual(midSkip.fellBackFrom, [.whatsApp])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .whatsApp, secondary: .messenger,
                                                      routed: .messenger),
                       [.phone])

        // L2-D6: the raw candidate list keeps a messenger it cannot open
        // yet ...
        let raw = CallChannelChain.hopCandidates(preferred: .whatsApp, secondary: .messenger,
                                                 routed: .whatsApp)
        XCTAssertEqual(raw, [.messenger, .phone])
        // ... the single handle filter drops it at decision time ...
        XCTAssertEqual(CallChannelChain.nextLaunchFailCandidate(after: .whatsApp,
                                                                attemptOrder: raw,
                                                                messengerHandleAvailable: false),
                       .phone)
        XCTAssertEqual(CallChannelChain.nextLaunchFailCandidate(after: .whatsApp,
                                                                attemptOrder: raw,
                                                                messengerHandleAvailable: true),
                       .messenger)
        // ... and a probe-absent WhatsApp stays attemptable best-effort:
        // the decision inputs carry no probe result at all.
        XCTAssertEqual(CallChannelChain.nextLaunchFailCandidate(after: .messenger,
                                                                attemptOrder: [.whatsApp, .phone],
                                                                messengerHandleAvailable: true),
                       .whatsApp)
        // Exhaustion is nil — a defined state, never an error.
        XCTAssertNil(CallChannelChain.nextLaunchFailCandidate(after: .phone, attemptOrder: [],
                                                             messengerHandleAvailable: true))
        XCTAssertNil(CallChannelChain.nextLaunchFailCandidate(after: .phone,
                                                             attemptOrder: [.phone],
                                                             messengerHandleAvailable: true))
    }

    /// SA-3 core — a routed channel outside the surface vocabulary
    /// normalises to the vocabulary terminal (phone for any-channel) and
    /// remains feasible. Every terminal is permitted AND always feasible
    /// under every combination of environment facts, so the substitution
    /// can never dead-end.
    func testVocabularySubstitutionCannotDeadEndTheRoute() {
        for vocabulary in [CallChannelVocabulary.anyChannel, .audio, .video] {
            for combo in chainFeasibilityCombos() {
                let cell = "vocabulary: \(vocabulary), handle: \(combo.handle), "
                    + "whatsApp: \(combo.whatsApp)"
                XCTAssertTrue(vocabulary.permits(vocabulary.terminal), cell)
                XCTAssertTrue(CallChannelChain.isFeasible(
                    vocabulary.terminal,
                    feasibility: CallChannelChain.Feasibility(
                        messengerHandleAvailable: combo.handle,
                        whatsAppInstalled: combo.whatsApp)), cell)
            }
        }
        XCTAssertEqual(CallChannelVocabulary.anyChannel.terminal, .phone)
        XCTAssertEqual(CallChannelVocabulary.audio.terminal, .phone)
        XCTAssertEqual(CallChannelVocabulary.video.terminal, .faceTime)

        // An out-of-vocabulary preferred normalises to the terminal.
        XCTAssertEqual(CallChannelVocabulary.audio.normalized(.faceTime), .phone)
        XCTAssertEqual(CallChannelVocabulary.video.normalized(.phone), .faceTime)
        XCTAssertEqual(CallChannelVocabulary.anyChannel.normalized(.whatsApp), .whatsApp)

        // The raw route can land on a channel the surface may not open when
        // the SECONDARY is out of vocabulary: with audio buttons, a
        // handle-less messenger preference falls to the FaceTime
        // secondary, which the audio vocabulary substitutes to the phone
        // terminal — feasible throughout.
        let feasibility = CallChannelChain.Feasibility(messengerHandleAvailable: false,
                                                       whatsAppInstalled: true)
        let audioRaw = CallChannelChain.route(preferred: .messenger, secondary: .faceTime,
                                              feasibility: feasibility)
        XCTAssertEqual(audioRaw.channel, .faceTime)
        XCTAssertFalse(CallChannelVocabulary.audio.permits(audioRaw.channel))
        let audioSubstituted = CallChannelVocabulary.audio.normalized(audioRaw.channel)
        XCTAssertEqual(audioSubstituted, CallChannelVocabulary.audio.terminal)
        XCTAssertTrue(CallChannelVocabulary.audio.permits(audioSubstituted))
        XCTAssertTrue(CallChannelChain.isFeasible(audioSubstituted, feasibility: feasibility))

        // The video path: a handle-less messenger preference falls to the
        // GSM floor, which the video vocabulary refuses — substituted to
        // FaceTime, permitted and always feasible.
        let videoRaw = CallChannelChain.route(preferred: .messenger, secondary: .phone,
                                              feasibility: feasibility)
        XCTAssertEqual(videoRaw.channel, .phone)
        let videoSubstituted = CallChannelVocabulary.video.normalized(videoRaw.channel)
        XCTAssertEqual(videoSubstituted, .faceTime)
        XCTAssertTrue(CallChannelVocabulary.video.permits(videoSubstituted))
        XCTAssertTrue(CallChannelChain.isFeasible(videoSubstituted, feasibility: feasibility))
    }

    /// NFR-CDP-002 / FR-CDP-005 — the probe is an injected closure over the
    /// compile-time literal; any `false` collapses to "not installed"
    /// immediately and the chain file performs no I/O of its own.
    func testWhatsAppProbeCollapsesToBoolOverTheLiteral() {
        XCTAssertEqual(CallChannelChain.whatsAppProbeURL, URL(string: "whatsapp://"))
        var probed: [URL] = []
        XCTAssertTrue(CallChannelChain.whatsAppInstalled(canOpen: { url in
            probed.append(url)
            return true
        }))
        XCTAssertFalse(CallChannelChain.whatsAppInstalled(canOpen: { url in
            probed.append(url)
            return false
        }))
        XCTAssertEqual(probed, [CallChannelChain.whatsAppProbeURL,
                                CallChannelChain.whatsAppProbeURL])
    }

    /// FR-CDP-012 — the channel-to-method mapping is total and its inverse
    /// collapses the audio/video variants to the one channel; callers keep
    /// their own `isVideo` because a method alone does not carry it.
    func testChannelMethodMappingsRoundTrip() {
        XCTAssertEqual(CallChannelChain.method(for: .phone, isVideo: true), .phone)
        XCTAssertEqual(CallChannelChain.method(for: .phone, isVideo: false), .phone)
        XCTAssertEqual(CallChannelChain.method(for: .faceTime, isVideo: true), .facetimeVideo)
        XCTAssertEqual(CallChannelChain.method(for: .faceTime, isVideo: false), .facetimeAudio)
        XCTAssertEqual(CallChannelChain.method(for: .messenger, isVideo: true), .messengerVideo)
        XCTAssertEqual(CallChannelChain.method(for: .messenger, isVideo: false), .messengerAudio)
        XCTAssertEqual(CallChannelChain.method(for: .whatsApp, isVideo: true), .whatsappChat)
        XCTAssertEqual(CallChannelChain.method(for: .whatsApp, isVideo: false), .whatsappChat)
        for channel in Self.chainChannels {
            for isVideo in [true, false] {
                XCTAssertEqual(CallChannelChain.channel(
                    for: CallChannelChain.method(for: channel, isVideo: isVideo)), channel)
            }
        }
    }

    /// L2-D8 — the label vocabulary is single-sourced: the shipped
    /// `app.name.*` keys verbatim, resolved through `L10n.str` against the
    /// caller's locale (the settings picker delegates here, so the two can
    /// never drift).
    func testNameKeysAndLabelResolution() {
        XCTAssertEqual(CallChannelChain.nameKey(for: .faceTime), "app.name.facetime")
        XCTAssertEqual(CallChannelChain.nameKey(for: .phone), "app.name.phone")
        XCTAssertEqual(CallChannelChain.nameKey(for: .messenger), "app.name.messenger")
        XCTAssertEqual(CallChannelChain.nameKey(for: .whatsApp), "app.name.whatsapp")
        for channel in Self.chainChannels {
            let key = CallChannelChain.nameKey(for: channel)
            let en = CallChannelChain.label(channel, locale: englishLocale)
            let ne = CallChannelChain.label(channel, locale: nepaliLocale)
            XCTAssertNotEqual(en, key, "key must resolve for en-US: \(key)")
            XCTAssertNotEqual(ne, key, "key must resolve for ne-NP: \(key)")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(en, ne, "the label must honour the caller's locale: \(key)")
        }
    }

    // MARK: - Resolution seams (T-146)
    //
    // Security evidence for call-dialer-primary-secondary at the seam
    // level: SA-2 (the probe and handle inputs route through the chain
    // with attempt-order provenance — the announce/hop input is the
    // seam's own truth) and SA-9 (equal primary and secondary picks
    // resolve to ONE attempt, no duplicate work). Everything below
    // drives `AppCoordinator.resolvedCallChannel` /
    // `resolvedMissedCallChannel` directly — pure statics, no
    // coordinator instance, no platform probe, no clock; the probe
    // result arrives as the Bool the seam takes.

    /// FR-CDP-009 / SA-2 — an explicit per-contact pick wins as the
    /// chain's preferred: with a handle on file it routes outright
    /// (empty provenance — nothing was skipped) even against a
    /// conflicting global default, and a conflicting default never
    /// displaces it.
    func testExplicitPickWinsAsPreferred() {
        assertResolved(explicit: .messenger, defaultApp: .whatsApp,
                       handleAvailable: true, expected: .messenger,
                       expectedFellBackFrom: [])
        assertResolved(explicit: .whatsApp, defaultApp: .phone,
                       handleAvailable: true, expected: .whatsApp,
                       expectedFellBackFrom: [])
        assertResolved(explicit: .phone, defaultApp: .messenger,
                       handleAvailable: true, expected: .phone,
                       expectedFellBackFrom: [])
        assertResolved(explicit: .faceTime, defaultApp: .whatsApp,
                       handleAvailable: true, expected: .faceTime,
                       expectedFellBackFrom: [])
    }

    /// FR-CDP-005 / SA-2 — the installed-app probe stubbed false: a
    /// WhatsApp-friendly preference (explicit, or via the global
    /// default) is skipped at routing, the secondary (or the phone
    /// terminal) is routed instead, and the provenance carries the
    /// skipped channel in attempt order. The probe Bool itself comes
    /// from the injected-closure static over the compile-time literal —
    /// no platform probe runs in this matrix.
    func testProbeFalseRoutesToSecondaryWithProvenance() {
        let probeOff = CallChannelChain.whatsAppInstalled(canOpen: { _ in false })
        XCTAssertFalse(probeOff)

        // Secondary route: the WhatsApp preference is skipped, the
        // WhatsApp-friendly messenger secondary opens.
        let toSecondary = assertResolved(explicit: .whatsApp, defaultApp: .phone,
                                         secondaryApp: .messenger,
                                         handleAvailable: true,
                                         whatsAppInstalled: probeOff,
                                         expected: .messenger,
                                         expectedFellBackFrom: [.whatsApp])
        XCTAssertEqual(toSecondary.fellBackFrom.first, .whatsApp)

        // Terminal route: no permitted secondary → the phone floor, with
        // the same provenance.
        let toTerminal = assertResolved(explicit: .whatsApp, defaultApp: .phone,
                                        handleAvailable: true,
                                        whatsAppInstalled: probeOff,
                                        expected: .phone,
                                        expectedFellBackFrom: [.whatsApp])
        XCTAssertEqual(toTerminal.fellBackFrom.first, .whatsApp)

        // A WhatsApp-friendly GLOBAL default falls back the same way...
        assertResolved(explicit: nil, defaultApp: .whatsApp, handleAvailable: true,
                       whatsAppInstalled: probeOff, expected: .phone,
                       expectedFellBackFrom: [.whatsApp])
        // ... and with the probe true the same preference routes outright.
        assertResolved(explicit: .whatsApp, defaultApp: .phone, handleAvailable: true,
                       whatsAppInstalled: true, expected: .whatsApp,
                       expectedFellBackFrom: [])
    }

    /// FR-CDP-004 — a Messenger preference with no usable handle on file
    /// is skipped like any other infeasible channel: the route falls to
    /// the permitted secondary when one exists, else the phone floor,
    /// and the provenance carries the skipped Messenger.
    func testMessengerPreferenceWithoutHandleDropsToFloorOrSecondary() {
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: false,
                       expected: .phone, expectedFellBackFrom: [.messenger])
        assertResolved(explicit: nil, defaultApp: .messenger, handleAvailable: false,
                       expected: .phone, expectedFellBackFrom: [.messenger])
        assertResolved(explicit: .messenger, defaultApp: .phone, secondaryApp: .whatsApp,
                       handleAvailable: false, whatsAppInstalled: true,
                       expected: .whatsApp, expectedFellBackFrom: [.messenger])
        // With a handle the same preference routes outright.
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: true,
                       expected: .messenger, expectedFellBackFrom: [])
    }

    /// SA-2 / FR-CDP-007 — the seam NEVER returns a channel outside the
    /// attempt order: across the whole (explicit, default, secondary,
    /// handle, probe) sweep the routed channel is a member of the order
    /// over (preferred, secondary), it is feasible under the supplied
    /// facts, the provenance is exactly the skipped attempt-order prefix,
    /// and a routed preferred reports no provenance. Any-channel
    /// vocabulary throughout, so no substitution can occur here (the
    /// substitution cells are tested separately below).
    func testSeamNeverReturnsAChannelOutsideTheAttemptOrder() {
        let explicits: [CallApp?] = [nil, .faceTime, .phone, .messenger, .whatsApp]
        var cells = 0
        for explicit in explicits {
            for defaultApp in Self.chainChannels {
                for secondaryApp in Self.chainChannels {
                    for combo in chainFeasibilityCombos() {
                        cells += 1
                        let cell = "explicit: \(String(describing: explicit)), "
                            + "default: \(defaultApp), secondary: \(secondaryApp), "
                            + "handle: \(combo.handle), whatsApp: \(combo.whatsApp)"
                        let preferred = explicit ?? defaultApp
                        let order = CallChannelChain.attemptOrder(preferred: preferred,
                                                                  secondary: secondaryApp)
                        let result = AppCoordinator.resolvedCallChannel(
                            explicit: explicit, defaultApp: defaultApp,
                            secondaryApp: secondaryApp,
                            messengerHandleAvailable: combo.handle,
                            whatsAppInstalled: combo.whatsApp)
                        XCTAssertTrue(order.contains(result.channel), cell)
                        XCTAssertTrue(CallChannelChain.isFeasible(
                            result.channel,
                            feasibility: CallChannelChain.Feasibility(
                                messengerHandleAvailable: combo.handle,
                                whatsAppInstalled: combo.whatsApp)), cell)
                        XCTAssertEqual(result.fellBackFrom,
                                       Array(order.prefix(while: { $0 != result.channel })),
                                       cell)
                        if result.channel == preferred {
                            XCTAssertTrue(result.fellBackFrom.isEmpty, cell)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells, 320, "the full explicit/default/secondary/environment sweep must run")
    }

    /// FR-CDP-010 / SA-3 at the seam — an out-of-vocabulary routed
    /// channel is substituted with the vocabulary terminal (phone for
    /// any/audio, FaceTime for video) and remains feasible; the
    /// substitution never fabricates provenance, and the preferred-input
    /// normalization is silent too.
    func testSeamVocabularySubstitutionRoutesToTerminal() {
        // audio: a handle-less messenger preference falls to the FaceTime
        // secondary — out of vocabulary for an audio button — and is
        // substituted to the phone terminal; provenance is untouched.
        let audio = AppCoordinator.resolvedCallChannel(
            explicit: .messenger, defaultApp: .phone, secondaryApp: .faceTime,
            messengerHandleAvailable: false, whatsAppInstalled: true,
            vocabulary: .audio)
        XCTAssertEqual(audio.channel, .phone)
        XCTAssertEqual(audio.channel, CallChannelVocabulary.audio.terminal)
        XCTAssertEqual(audio.fellBackFrom, [.messenger])
        XCTAssertTrue(CallChannelVocabulary.audio.permits(audio.channel))

        // video: the same preference falls to the GSM floor — out of
        // vocabulary for a video button — substituted to FaceTime.
        let video = AppCoordinator.resolvedCallChannel(
            explicit: .messenger, defaultApp: .phone, secondaryApp: .phone,
            messengerHandleAvailable: false, whatsAppInstalled: true,
            vocabulary: .video)
        XCTAssertEqual(video.channel, .faceTime)
        XCTAssertEqual(video.channel, CallChannelVocabulary.video.terminal)
        XCTAssertEqual(video.fellBackFrom, [.messenger])
        XCTAssertTrue(CallChannelVocabulary.video.permits(video.channel))

        // Step-1 normalization is SILENT: a FaceTime pick on an audio
        // path routes to the phone terminal with empty provenance — the
        // shipped `supportsAudio` gate also substituted without a word.
        let audioFaceTime = assertResolved(explicit: .faceTime, defaultApp: .phone,
                                           handleAvailable: true, vocabulary: .audio,
                                           expected: .phone, expectedFellBackFrom: [])
        XCTAssertTrue(audioFaceTime.fellBackFrom.isEmpty)

        // And every substituted terminal is permitted AND feasible under
        // every combination of environment facts — the substitution can
        // never dead-end.
        for vocabulary in [CallChannelVocabulary.anyChannel, .audio, .video] {
            for combo in chainFeasibilityCombos() {
                let cell = "vocabulary: \(vocabulary), handle: \(combo.handle), "
                    + "whatsApp: \(combo.whatsApp)"
                let terminal = vocabulary.terminal
                XCTAssertTrue(vocabulary.permits(terminal), cell)
                XCTAssertTrue(CallChannelChain.isFeasible(
                    terminal,
                    feasibility: CallChannelChain.Feasibility(
                        messengerHandleAvailable: combo.handle,
                        whatsAppInstalled: combo.whatsApp)), cell)
            }
        }
    }

    /// SA-9 — equal primary and secondary picks dedupe to a SINGLE
    /// attempt: a feasible equal pick routes the preferred with empty
    /// provenance and occupies one slot in the order; an infeasible
    /// equal pick is skipped once and reports ONE provenance entry,
    /// never two (no duplicate work, no doubled disclosure).
    func testSecondaryEqualsPrimaryDedupes() {
        for channel in Self.chainChannels {
            let result = AppCoordinator.resolvedCallChannel(
                explicit: channel, defaultApp: channel, secondaryApp: channel,
                messengerHandleAvailable: true, whatsAppInstalled: true)
            XCTAssertEqual(result.channel, channel,
                           "equal feasible picks route the preferred")
            XCTAssertTrue(result.fellBackFrom.isEmpty,
                          "a routed preferred never reports provenance")
            XCTAssertEqual(CallChannelChain.attemptOrder(preferred: channel,
                                                         secondary: channel).count,
                           channel == .phone ? 1 : 2,
                           "the equal pick occupies one slot, the floor its own")
        }
        // Infeasible equal messenger picks: skipped once, one entry.
        let messenger = AppCoordinator.resolvedCallChannel(
            explicit: .messenger, defaultApp: .messenger, secondaryApp: .messenger,
            messengerHandleAvailable: false, whatsAppInstalled: true)
        XCTAssertEqual(messenger.channel, .phone)
        XCTAssertEqual(messenger.fellBackFrom, [.messenger],
                       "the equal pick is attempted once, never twice")
        // The same dedupe over a probe-absent WhatsApp default.
        let whatsApp = AppCoordinator.resolvedCallChannel(
            explicit: .whatsApp, defaultApp: .phone, secondaryApp: .whatsApp,
            messengerHandleAvailable: true, whatsAppInstalled: false)
        XCTAssertEqual(whatsApp.channel, .phone)
        XCTAssertEqual(whatsApp.fellBackFrom, [.whatsApp])
    }

    /// FR-CDP-011 / ADR-CDP-03 step 4 — the missed-call seam reads the
    /// family contact's audio preference and routes through the SAME
    /// shared helper with the `.audio` vocabulary: a FaceTime
    /// preference still lands on the phone floor (silently, empty
    /// provenance), a handle-less Messenger preference with a permitted
    /// secondary routes there with its provenance, and the `Result`
    /// carries the attempt-order provenance the dial-back announcement
    /// composes from.
    func testMissedCallSeamUsesAudioVocabularyWithProvenance() {
        let faceTimeFan = FamilyContact(name: "बुबा", phone: "9841234567",
                                        relationship: "father",
                                        preferredCallApp: .faceTime)
        let routed = AppCoordinator.resolvedMissedCallChannel(
            familyContact: faceTimeFan, defaultApp: .phone, secondaryApp: .phone,
            messengerHandleAvailable: false, whatsAppInstalled: true)
        XCTAssertEqual(routed.channel, .phone)
        XCTAssertTrue(routed.fellBackFrom.isEmpty)

        let messenger = FamilyContact(name: "राम", phone: "9811111111",
                                      relationship: "son",
                                      preferredCallApp: .messenger)
        let viaSecondary = AppCoordinator.resolvedMissedCallChannel(
            familyContact: messenger, defaultApp: .phone, secondaryApp: .whatsApp,
            messengerHandleAvailable: false, whatsAppInstalled: true)
        XCTAssertEqual(viaSecondary.channel, .whatsApp)
        XCTAssertEqual(viaSecondary.fellBackFrom, [.messenger])
    }

    // MARK: - Launch-fail hop (T-149)
    //
    // Security evidence for call-dialer-primary-secondary at the HOP level
    // (design-l2 §10): SA-2 (the hop consumes its candidates strictly — at
    // most two steps, no channel repeated, exhaustion is `nil` and speaks
    // nothing beyond the already-spoken failure line), SA-5(b)/SA-6 (the
    // hop's one spoken line and its closed-token event: component,
    // eventType and the `failed:next` channel raw values, `metadata: [:]`,
    // never a name or a number) and NFR-CDP-004 (the chain is synchronous:
    // no await, no timer, no queue, no detached task).
    //
    // The decision step is driven directly — the design-l2 §28 seam names
    // `launchFailHopStep`'s boundaries — so every assertion below runs the
    // shipped code rather than a re-implementation of it (the same §28
    // access relaxation T-148 recorded for `confirmationPrompt`). The one
    // integration leg the unit bundle can honestly drive end to end is the
    // search-shaped messenger opener: an unusable handle fails WITHOUT
    // touching the platform (no URL is built, so nothing is probed and
    // nothing is opened), and every candidate these tests hand it is
    // terminal — no dial, no app switch, no probe can occur.
    //
    // The audio itself is DV territory: a unit test drives the coordinator
    // before `start()`, where `speak` is a documented no-op. What IS
    // pinned here is the single spoken-line SITE, the catalogue slots it
    // binds and the event that accompanies every hop.

    /// The fixture identity the hop announcements name — deliberately
    /// digit-free, so a digit in a captured event payload is the event's
    /// own fault (the SA-6 no-numbers pin).
    private static let hopContactName = "Maya Gurung"

    /// The usable handle the control legs pass (the shipped normalization
    /// accepts it: no `@`, allowed charset).
    private static let hopContactHandle = "maya.gurung"

    /// FR-CDP-015 / SA-2 — the hop step consumes its candidates strictly.
    /// The voice-path worked example first (design-l2 §10.4 row 1: routed
    /// messenger with the WhatsApp secondary), then the identical walk
    /// through the REAL step across the whole 64-cell matrix: every step
    /// returns a member of the remaining list and never one already
    /// attempted, the list shrinks by at least one channel per hop (the
    /// listing's suffix consumption), the walk is bounded at two hops, and
    /// exhaustion returns `nil` while emitting nothing.
    @MainActor
    func testHopStepConsumesCandidatesNeverRepeats() {
        let coordinator = makeCoordinator()
        let locale = englishLocale
        let name = Self.hopContactName

        let voiceCandidates = CallChannelChain.hopCandidates(preferred: .messenger,
                                                             secondary: .whatsApp,
                                                             routed: .messenger)
        XCTAssertEqual(voiceCandidates, [.whatsApp, .phone])
        var attempted: [CallApp] = [.messenger]
        var sizes: [Int] = [voiceCandidates.count]
        var remaining = voiceCandidates
        var failed: CallApp = .messenger
        var steps = 0
        let exampleConsole = captureConsole {
            while let step = coordinator.launchFailHopStep(after: failed,
                                                           candidates: remaining,
                                                           handle: Self.hopContactHandle,
                                                           name: name, locale: locale) {
                steps += 1
                XCTAssertFalse(attempted.contains(step.next),
                               "a channel is attempted at most once")
                XCTAssertTrue(remaining.contains(step.next),
                              "the step selects from its own remaining list")
                attempted.append(step.next)
                sizes.append(step.remaining.count)
                remaining = step.remaining
                failed = step.next
            }
        }
        XCTAssertEqual(attempted, [.messenger, .whatsApp, .phone])
        XCTAssertEqual(steps, 2, "depth is structurally at most two (design-l2 §10.3)")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(sizes, [2, 1, 0], "the candidate list strictly shrinks per hop")
        XCTAssertEqual(hopEventLines(in: exampleConsole).count, steps,
                       "one hop line per step, none at exhaustion")

        // The same walk over the whole matrix, through the real step.
        var cells = 0
        var sweepSteps = 0
        let sweepConsole = captureConsole {
            for preferred in Self.chainChannels {
                for secondary in Self.chainChannels {
                    for combo in chainFeasibilityCombos() {
                        cells += 1
                        let cell = "preferred: \(preferred), secondary: \(secondary), "
                            + "handle: \(combo.handle), whatsApp: \(combo.whatsApp)"
                        let feasibility = CallChannelChain.Feasibility(
                            messengerHandleAvailable: combo.handle,
                            whatsAppInstalled: combo.whatsApp)
                        let routed = CallChannelChain.route(preferred: preferred,
                                                            secondary: secondary,
                                                            feasibility: feasibility).channel
                        var hopList = CallChannelChain.hopCandidates(preferred: preferred,
                                                                     secondary: secondary,
                                                                     routed: routed)
                        var walkFailed = routed
                        var walkAttempted: [CallApp] = [routed]
                        while let step = coordinator.launchFailHopStep(
                            after: walkFailed,
                            candidates: hopList,
                            handle: combo.handle ? Self.hopContactHandle : nil,
                            name: name, locale: locale) {
                            sweepSteps += 1
                            XCTAssertFalse(walkAttempted.contains(step.next), cell)
                            XCTAssertTrue(hopList.contains(step.next), cell)
                            XCTAssertLessThan(step.remaining.count, hopList.count,
                                              "strictly shrinking per hop — " + cell)
                            walkAttempted.append(step.next)
                            hopList = step.remaining
                            walkFailed = step.next
                        }
                        XCTAssertLessThanOrEqual(walkAttempted.count - 1, 2, cell)
                        XCTAssertTrue(hopList.allSatisfy { $0 == .messenger && !combo.handle },
                                      cell)
                    }
                }
            }
        }
        XCTAssertEqual(cells, 64, "the depth bound must hold over every matrix cell")
        XCTAssertEqual(hopEventLines(in: sweepConsole).count, sweepSteps,
                       "one hop line per hop over the whole matrix")

        // Exhaustion — and the vocabulary-substituted case, whose candidate
        // list is empty by construction — returns nil and says NOTHING
        // beyond the caller's already-spoken failure line. The second leg
        // is the messenger filter at its extreme: a messenger-only list
        // with no handle on file is exhaustion, never a step.
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger, secondary: .phone,
                                                      routed: .faceTime, vocabulary: .video),
                       [])
        var stepsFromEmpty: Int = 0
        let emptyConsole = captureConsole {
            if coordinator.launchFailHopStep(after: .faceTime, candidates: [],
                                             handle: nil, name: name,
                                             locale: locale) != nil {
                stepsFromEmpty += 1
            }
            if coordinator.launchFailHopStep(after: .faceTime, candidates: [.messenger],
                                             handle: nil, name: name,
                                             locale: locale) != nil {
                stepsFromEmpty += 1
            }
        }
        XCTAssertEqual(stepsFromEmpty, 0)
        XCTAssertTrue(hopEventLines(in: emptyConsole).isEmpty,
                      "exhaustion speaks nothing beyond the already-spoken failure line")
    }

    /// FR-CDP-015 / SA-5(b) / SA-6 — the hop announces exactly once per hop
    /// through the ONE `call.announce.launchFailedFallback` site, and its
    /// classification event is closed tokens only: component
    /// `call_launch_fallback`, event type `hop`, outcome `<failed>:<next>`
    /// in channel raw values, `metadata: [:]` — the printed payload is
    /// pinned byte-exactly, with no name and no number. A second call over
    /// the consumed list exhausts and adds no line.
    @MainActor
    func testLaunchFailedFallbackSpokenOnce() throws {
        let coordinator = makeCoordinator()
        let locale = englishLocale
        let name = Self.hopContactName

        var first: (next: CallApp, remaining: [CallApp])?
        var second: (next: CallApp, remaining: [CallApp])?
        let console = captureConsole {
            first = coordinator.launchFailHopStep(after: .faceTime, candidates: [.phone],
                                                  handle: nil, name: name, locale: locale)
            second = coordinator.launchFailHopStep(after: .phone,
                                                   candidates: first?.remaining ?? [],
                                                   handle: nil, name: name, locale: locale)
        }
        XCTAssertEqual(first?.next, .phone)
        XCTAssertEqual(first?.remaining, [CallApp]())
        XCTAssertNil(second, "the consumed list is exhaustion: nil, nothing further said")

        let lines = hopEventLines(in: console)
        XCTAssertEqual(lines.count, 1, "exactly one hop line per hop")
        guard let line = lines.first else { return XCTFail("no hop event was captured") }
        let start = try XCTUnwrap(line.range(of: "[call_launch_fallback]"))
        let payload = String(line[start.lowerBound...])
        XCTAssertEqual(payload, "[call_launch_fallback] hop outcome=faceTime:phone metadata=[:]",
                       "the hop event is closed tokens only: component, event type and the "
                       + "failed:next channel raw values, empty metadata, nothing beyond")
        XCTAssertFalse(payload.contains(name), "no contact name rides on the event (SA-6)")
        XCTAssertFalse(payload.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) },
                       "no number rides on the event (SA-6)")

        // The single spoken-line site, pinned at the source: one key, one
        // speak call, and the catalogue's slot order (failed label, name,
        // next label).
        let source = coordinatorSource()
        XCTAssertEqual(occurrences(of: "\"call.announce.launchFailedFallback\"", in: source), 1,
                       "the hop line lives at exactly ONE site in the coordinator")
        let stepRegion = try region(between: "func launchFailHopStep(",
                                    and: "private func performLaunchFailHop(",
                                    in: source)
        XCTAssertEqual(occurrences(of: "speak(text:", in: stepRegion), 1,
                       "the hop step speaks exactly once per hop")
        XCTAssertEqual(occurrences(of: collapsed("""
            speak(text: L10n.fmt("call.announce.launchFailedFallback", locale: locale,
                                 CallChannelChain.label(failed, locale: locale),
                                 name,
                                 CallChannelChain.label(next, locale: locale)))
            """).trimmingCharacters(in: .whitespaces), in: collapsed(stepRegion)), 1,
            "the hop line names the failed channel, the contact and the next channel — "
            + "in the catalogue's slot order (FR-CDP-015)")
        for language in [AppLanguage.english, .nepali] {
            XCTAssertNotEqual(L10n.str("call.announce.launchFailedFallback", locale: language.locale),
                              "call.announce.launchFailedFallback",
                              "the hop line must resolve from the \(language.rawValue) catalog")
        }
    }

    /// FR-CDP-004 / FR-CDP-015 — a messenger candidate with no usable
    /// handle on file is dropped INSIDE the hop step (the same
    /// `nextLaunchFailCandidate` filter the chain statics use), and the
    /// next feasible candidate proceeds. The control leg proves it is a
    /// feasibility filter, not a blanket messenger ban: with a handle the
    /// same list selects messenger. A messenger-only list without a handle
    /// is exhaustion, and nothing is said.
    @MainActor
    func testMessengerWithoutHandleSkippedInHop() {
        let coordinator = makeCoordinator()
        let locale = englishLocale
        let name = Self.hopContactName

        var withoutHandle: (next: CallApp, remaining: [CallApp])?
        var withHandle: (next: CallApp, remaining: [CallApp])?
        let console = captureConsole {
            withoutHandle = coordinator.launchFailHopStep(after: .faceTime,
                                                          candidates: [.messenger, .phone],
                                                          handle: nil,
                                                          name: name, locale: locale)
            withHandle = coordinator.launchFailHopStep(after: .faceTime,
                                                       candidates: [.messenger, .phone],
                                                       handle: Self.hopContactHandle,
                                                       name: name, locale: locale)
        }
        XCTAssertEqual(withoutHandle?.next, .phone,
                       "the handle-less messenger candidate is dropped, the floor proceeds")
        XCTAssertEqual(withoutHandle?.remaining, [CallApp]())
        XCTAssertEqual(withHandle?.next, .messenger,
                       "with a handle on file the SAME list selects messenger — a filter, "
                       + "not a ban")
        XCTAssertEqual(withHandle?.remaining, [.phone], "suffix consumption past the pick")

        let lines = hopEventLines(in: console)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("outcome=faceTime:phone metadata=[:]"), lines[0])
        XCTAssertTrue(lines[1].contains("outcome=faceTime:messenger metadata=[:]"), lines[1])
        XCTAssertEqual(occurrences(of: "[call_launch_fallback]", in: console), 2,
                       "the dropped candidate is never announced — exactly one line per hop")

        var messengerOnly: (next: CallApp, remaining: [CallApp])?
        let exhausted = captureConsole {
            messengerOnly = coordinator.launchFailHopStep(after: .faceTime,
                                                          candidates: [.messenger],
                                                          handle: nil,
                                                          name: name, locale: locale)
        }
        XCTAssertNil(messengerOnly, "a filtered-out candidate leaves exhaustion")
        XCTAssertTrue(hopEventLines(in: exhausted).isEmpty)
    }

    /// FR-CDP-015 / L2-D3, design-l2 §21 — the additive fields keep the
    /// shipped call sites compiling, pinned in their POST-T-148 state. The
    /// override's amended action and BOTH log-store constructions name the
    /// five shipped labels and none of the three new fields; the voice
    /// step's construction names `fellBackFrom`/`hopCandidates` (T-148's
    /// design edit — the routed method and its provenance are built there)
    /// and none of the clock; the hop's re-entry copy (`replacing`) names
    /// `requestedAt`/`hopCandidates` and deliberately NOT `fellBackFrom`
    /// (the disclosure provenance dies with the first attempt).
    @MainActor
    func testAdditiveFieldsKeepOldCallSites() throws {
        let newFields = ["requestedAt", "fellBackFrom", "hopCandidates"]
        let shippedLabels = ["contact:", "method:", "unsupportedRequestedApp:",
                             "sourceTranscript:", "sourceCommand:"]
        let source = coordinatorSource()

        // 1. The override's amended action — the shipped five-label
        //    construction, byte-verbatim (whitespace-collapsed) and with
        //    nothing added: a stale disclosure can never be re-spoken and
        //    no hop candidate survives an override.
        let overrideRegion = try region(between: "func handleCallConfirmationOverride(",
                                        and: "func confirmationPrompt(", in: source)
        XCTAssertEqual(occurrences(of: "PendingCallAction(", in: overrideRegion), 1,
                       "the override amends through exactly one construction")
        let amended = collapsed(try region(between: "let amended = PendingCallAction(",
                                           and: "pendingCallAction = amended",
                                           in: overrideRegion))
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(amended, collapsed("""
            let amended = PendingCallAction(contact: action.contact,
                                            method: override,
                                            unsupportedRequestedApp: nil,
                                            sourceTranscript: action.sourceTranscript,
                                            sourceCommand: action.sourceCommand)
            """).trimmingCharacters(in: .whitespaces),
            "the amended construction must stay byte-identical (provenance dropped)")
        for field in newFields {
            XCTAssertFalse(amended.contains(field),
                           "the amended action must not name \(field) (L2 §8 override path)")
        }

        // 2. The two log-store constructions (IntentLogStoreTests) — the
        //    compile-time proof that the new fields are additive, pinned
        //    at the source because that file is outside this unit's
        //    ownership and must not be edited.
        let logStoreSource = logStoreTestSource()
        let logBlocks = callBlocks(in: logStoreSource,
                                  marker: "AppCoordinator.PendingCallAction(")
        XCTAssertEqual(logBlocks.count, 2, "the two shipped log-store constructions")
        for block in logBlocks {
            for label in shippedLabels {
                XCTAssertTrue(collapsed(block).contains(label),
                              "the log-store construction names \(label)")
            }
            for field in newFields {
                XCTAssertFalse(block.contains(field),
                               "the log-store construction must not name \(field) — the "
                               + "new fields are defaulted (L2-D3)")
            }
        }

        // 3. The voice step's construction — T-148's design edit: the
        //    routed method plus its provenance are built here, and the
        //    clock stays defaulted.
        let stepRegion = try region(between: "let action = PendingCallAction(contact: contact,",
                                    and: "pendingCallAction = action", in: source)
        XCTAssertTrue(stepRegion.contains("fellBackFrom: route.fellBackFrom"))
        XCTAssertTrue(stepRegion.contains("hopCandidates: CallChannelChain.hopCandidates("),
                      "the voice action carries the hop list this unit consumes")
        XCTAssertFalse(stepRegion.contains("requestedAt:"),
                       "the voice action takes the defaulted clock")

        // 4. The hop's re-entry copy — the one construction that moves the
        //    new fields, by design (L2-D3/D7).
        let replacingRegion = try region(
            between: "func replacing(method: CallMethod, hopCandidates: [CallApp]) -> PendingCallAction {",
            and: "@Published private(set) var pendingCallAction",
            in: source)
        XCTAssertTrue(replacingRegion.contains("requestedAt: requestedAt"),
                      "the hop preserves the ORIGINAL question's clock")
        XCTAssertTrue(replacingRegion.contains("hopCandidates: hopCandidates"),
                      "the hop replaces the remaining candidates")
        XCTAssertFalse(replacingRegion.contains("fellBackFrom:"),
                       "the hop copy deliberately drops the disclosure provenance")

        // 5. Additive at RUNTIME too: a five-label construction takes the
        //    defaults, and the re-entry copy carries the flywheel pair.
        let contact = FamilyContact(name: Self.hopContactName, phone: "9841234567",
                                    relationship: "daughter")
        let bare = AppCoordinator.PendingCallAction(contact: contact,
                                                    method: .phone,
                                                    unsupportedRequestedApp: nil,
                                                    sourceTranscript: "मायालाई फोन गर",
                                                    sourceCommand: nil)
        XCTAssertTrue(bare.fellBackFrom.isEmpty, "an unpassed provenance defaults empty")
        XCTAssertTrue(bare.hopCandidates.isEmpty, "an unpassed hop list defaults empty")
        let copied = bare.replacing(method: .messengerAudio, hopCandidates: [.phone])
        XCTAssertEqual(copied.requestedAt, bare.requestedAt)
        XCTAssertEqual(copied.method, .messengerAudio)
        XCTAssertEqual(copied.hopCandidates, [.phone])
        XCTAssertTrue(copied.fellBackFrom.isEmpty,
                      "the hop copy resets the provenance (no re-spoken disclosure)")
        XCTAssertEqual(copied.capture.slots?["method"], "messengerAudio",
                       "the flywheel slot follows the hopped method")
    }

    /// SA-2 / NFR-CDP-004 — no hop step re-enters the confirmation flow,
    /// and the whole hop chain is synchronous: the voice path re-enters
    /// `performCallAction` (the executor a fresh confirmation reaches) with
    /// the copied action, and nothing in the machinery awaits, schedules or
    /// queues. The one structural loop in the listing is the suffix
    /// consumption inside the step; the recursion itself is bounded by the
    /// shrinking list (pinned behaviourally above).
    func testHopNeverReEntersConfirmationOrAwaits() throws {
        let source = coordinatorSource()

        let hopRegion = try region(between: "private func hopFromCallAction(",
                                   and: "private func noteConfirmedCallExecution(", in: source)
        XCTAssertEqual(occurrences(of: "performCallAction(action.replacing(", in: hopRegion), 1,
                       "the voice hop re-enters the executor, never the confirmation flow")
        XCTAssertEqual(occurrences(of: "CallChannelChain.method(for: step.next, isVideo: isVideo)",
                                   in: hopRegion), 1)
        XCTAssertEqual(occurrences(of: "hopCandidates: step.remaining", in: hopRegion), 1,
                       "the re-entry receives the strictly shorter list")
        for forbidden in ["pendingCallAction", "requestCallConfirmation",
                          "openConfirmationWindow", "confirmationPrompt",
                          "handleConfirmationResponse", "handleCallConfirmationOverride",
                          "isAwaitingCallConfirmation"] {
            XCTAssertFalse(hopRegion.contains(forbidden),
                           "a hop never re-enters the confirmation flow: \(forbidden) "
                           + "(no re-pending, no re-prompt — the elder's yes stands)")
        }

        let machinery = try region(between: "struct LaunchHop: Equatable {",
                                   and: "private func hopFromCallAction(", in: source)
        for forbidden in ["await", "async", "Task", "DispatchQueue", "Timer",
                          "Thread.sleep", "usleep", "sleep(", "schedule"] {
            XCTAssertFalse(machinery.contains(forbidden),
                           "the hop chain is synchronous (NFR-CDP-004): \(forbidden)")
        }
        XCTAssertNil(firstMatch(of: #"\n\s*(while|for|repeat)\b"#, in: machinery),
                     "the hop machinery holds no loop statement — the recursion is bounded "
                     + "by the strictly shrinking candidate list")

        // The mechanisms stay separate: the tap path attempts through the
        // shipped openers, the voice path only through performCallAction.
        XCTAssertEqual(occurrences(of: "case .phone:", in: machinery), 1,
                       "the floor dispatch exists once")
        XCTAssertTrue(machinery.contains("performSystemContactCall(name: name, phone: phone)"),
                      "the hopped floor attempt goes through the shipped floor opener")
        XCTAssertFalse(machinery.contains("performCallAction("),
                       "the tap helper never re-enters the voice executor")
    }

    /// FR-CDP-015 / design-l2 §10.1 — the integration leg: what a hop does
    /// when it runs, driven through the SHIPPED openers. An unusable
    /// messenger handle fails without touching the platform, so the whole
    /// chain is hermetic: every candidate below is terminal (the floor's
    /// own honest line, or WhatsApp's invalid-phone data failure), and a
    /// failed open records no learning, no activity and no history —
    /// exactly as shipped.
    @MainActor
    func testHopOpenerWiringEndToEnd() throws {
        let coordinator = makeCoordinator()
        let name = Self.hopContactName

        // Arm 0 — the GSM floor opener accepts the additive parameter for
        // call-site uniformity and NEVER hops: the shipped honest line is
        // the end of that path (design-l2 §10.1, "the floor is the last
        // resort").
        let activitiesBefore = coordinator.activityLog.entries().count
        let floorConsole = captureConsole {
            coordinator.performSystemContactCall(
                name: name, phone: "",
                hop: AppCoordinator.LaunchHop(candidates: [.phone], handle: nil))
        }
        XCTAssertTrue(hopEventLines(in: floorConsole).isEmpty,
                      "the floor is terminal — a hop on board must not produce a hop")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.icon, "exclamationmark.triangle.fill",
                       "the floor reports honestly, never a success card")
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, name))

        // Arm A — a failed messenger open (empty handle: no thread URL can
        // build, so nothing is probed and nothing is opened) hops to the
        // floor: the shipped failure line and its shipped tap event come
        // FIRST, then the hop line, then the floor's own terminal honest
        // line. The floor leg carries phone "" — no tel: URL builds — so
        // nothing is dialed, and nothing is recorded.
        let hopConsole = captureConsole {
            coordinator.performSystemContactMessenger(
                name: name, handle: "",
                hop: AppCoordinator.LaunchHop(candidates: [.phone], handle: nil))
        }
        let hopLines = hopEventLines(in: hopConsole)
        XCTAssertEqual(hopLines.count, 1, "one failed open, one hop")
        XCTAssertTrue(hopLines.first?.contains("outcome=messenger:phone metadata=[:]") ?? false,
                      hopLines.first ?? "no hop line captured")
        let tapEvent = "[contact_search_channels] tap outcome=messenger:invalidHandle"
        XCTAssertEqual(occurrences(of: tapEvent, in: hopConsole), 1,
                       "the shipped tap event still fires exactly once")
        let tapRange = try XCTUnwrap(hopConsole.range(of: tapEvent))
        let hopRange = try XCTUnwrap(hopConsole.range(of: "[call_launch_fallback] "))
        XCTAssertLessThan(tapRange.lowerBound, hopRange.lowerBound,
                          "the failure's own event precedes the hop — the hop is what "
                          + "happens AFTER the honest line")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, name),
                       "the hopped floor leg ends on its own shipped honest line")
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore,
                       "a failed open records nothing — the hop included")

        // Arm B — a failed messenger open hopping to WhatsApp: the hopped
        // leg's empty phone makes it `.invalidPhone`, which §10.1 defines
        // as TERMINAL. The chain stops there and exactly one hop ever
        // spoke — the WhatsApp opener never consults its `hop`, pinned
        // here behaviourally.
        let terminalConsole = captureConsole {
            coordinator.performSystemContactMessenger(
                name: name, handle: "",
                hop: AppCoordinator.LaunchHop(candidates: [.whatsApp], handle: nil))
        }
        let terminalLines = hopEventLines(in: terminalConsole)
        XCTAssertEqual(terminalLines.count, 1, "one failed open, one hop — then terminal")
        XCTAssertTrue(terminalLines.first?.contains("outcome=messenger:whatsApp metadata=[:]")
                      ?? false, terminalLines.first ?? "no hop line captured")
        XCTAssertEqual(occurrences(of: "[contact_search_channels] tap outcome=whatsapp:invalidPhone",
                                   in: terminalConsole), 1,
                       "the hopped WhatsApp leg reports its own invalid-phone outcome")
        drainMainQueue()
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore,
                       "the terminal leg records nothing either")
    }

    // MARK: - Helpers (the house patterns the sibling suites ship)

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

    /// Seeds English BEFORE construction (the init restores through the
    /// real `AppLanguage.persisted()` seam) so the spoken-line pins are
    /// deterministic; `tearDown` restores the prior value.
    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        return AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    /// Waits out the main-queue hops (`setOutcome` dispatches async — the
    /// sentinel enqueued LAST runs after everything before it).
    private func drainMainQueue() {
        let done = expectation(description: "main drain")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Runs `body` with process stdout redirected to a temp file and
    /// returns what the console bus printed (the LiveTranslate pattern,
    /// via `DialogueCoordinatorWiringTests`). Assertions are scoped to
    /// this unit's events only.
    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/call-resolution-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    /// The hop classification lines in a captured console — component
    /// `call_launch_fallback`, event type `hop` (nothing else this unit
    /// prints matches).
    private func hopEventLines(in console: String) -> [String] {
        console.components(separatedBy: .newlines)
            .filter { $0.contains("[call_launch_fallback] hop ") }
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The sibling suite that owns the two shipped log-store
    /// constructions — read, never edited (outside this unit's ownership).
    private func logStoreTestSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistantTests/Services/Intents/IntentLogStoreTests.swift"))
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `CallConfirmationWordingTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "AppCoordinator.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences and counts survive
    /// while indentation and line breaks do not (a source pin must fail
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

    /// Every call whose text starts at `marker` (which ends with its
    /// opening parenthesis), up to and including the parenthesis that
    /// closes it — the plural of `DialogueCoordinatorWiringTests.callBlock`,
    /// so N constructions can each be pinned independently.
    private func callBlocks(in text: String, marker: String) -> [String] {
        var blocks: [String] = []
        var searchStart = text.startIndex
        while let start = text.range(of: marker, range: searchStart..<text.endIndex) {
            var depth = 1
            var index = start.upperBound
            var end: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            blocks.append(String(text[start.lowerBound...end]))
            searchStart = text.index(after: end)
        }
        return blocks
    }

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship — `ColdStartRoutingTests`,
    // `CallingSettingsSurfaceTests`, `CallConfirmationWordingTests`: the
    // coordinator's payload store only; the seam under test is the real
    // hop machinery + the real catalog.)

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
