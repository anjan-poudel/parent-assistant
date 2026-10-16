import XCTest
@testable import ElderlyAssistant

/// [HERO-STATES] (2026-10-13) — the resolved hero mapping. The owner
/// reported the speak button showing the wrong visual mid-dialogue:
/// the slot window keeps the machine in `.awaitingSlotAnswer` through
/// three visually different moments (probe speaking, auto-listen
/// capture live, closed-capture wait), and the raw state mapping could
/// not tell them apart. One test per disjoint moment the fix closes,
/// plus the untouched rows.
final class TalkStageVisualsTests: XCTestCase {

    func testProbeSpeechShowsTheSpeakingFamilyDuringTheSlotWindow() {
        let visual = TalkStageVisuals.resolved(state: .awaitingSlotAnswer,
                                               isSpeaking: true,
                                               slotAnswerCaptureActive: false)
        XCTAssertEqual(visual.icon, VoiceSessionState.speaking.talkVisuals.icon,
                       "the probe's speech must show the speaking icon")
    }

    func testLiveAnswerCaptureShowsTheListeningFamily() {
        let visual = TalkStageVisuals.resolved(state: .awaitingSlotAnswer,
                                               isSpeaking: false,
                                               slotAnswerCaptureActive: true)
        XCTAssertEqual(visual.icon, VoiceSessionState.listening.talkVisuals.icon)
        XCTAssertEqual(visual.captionKey, "state.listening.button")
    }

    func testClosedCaptureWindowShowsTheTalkAffordanceNotListening() {
        let visual = TalkStageVisuals.resolved(state: .awaitingSlotAnswer,
                                               isSpeaking: false,
                                               slotAnswerCaptureActive: false)
        XCTAssertEqual(visual.icon, VoiceSessionState.idle.talkVisuals.icon,
                       "a closed capture must show the talk affordance")
        XCTAssertEqual(visual.captionKey, "state.idle.button")
        XCTAssertFalse(visual.pulses == VoiceSessionState.listening.talkVisuals.pulses
                       && visual.icon == "ear.fill",
                       "nothing about the visual may claim 'listening'")
    }

    func testReplySpeechAfterResolutionShowsSpeakingFromIdle() {
        let visual = TalkStageVisuals.resolved(state: .idle,
                                               isSpeaking: true,
                                               slotAnswerCaptureActive: false)
        XCTAssertEqual(visual.icon, VoiceSessionState.speaking.talkVisuals.icon,
                       "the reply speaking after resolution must not show idle")
    }

    func testConfirmationChipsStayUpWhileTheChallengeSpeaks() {
        let visual = TalkStageVisuals.resolved(state: .awaitingConfirmation,
                                               isSpeaking: true,
                                               slotAnswerCaptureActive: false)
        XCTAssertTrue(visual.isConfirmation,
                      "the speaking overlay never replaces the yes/no chips")
    }

    func testOrdinaryStatesAreUntouchedByTheOverlays() {
        for state in [VoiceSessionState.idle, .listening, .transcribing,
                      .understanding, .speaking, .error, .stopped] {
            let visual = TalkStageVisuals.resolved(state: state,
                                                   isSpeaking: false,
                                                   slotAnswerCaptureActive: false)
            XCTAssertEqual(visual.icon, state.talkVisuals.icon,
                           "\(state) keeps its raw mapping")
        }
    }

    func testTheSubHeroSlotIsUnconditionalInTheStageSource() throws {
        // [HERO-LAYOUT] The owner reported the button size/position
        // changing between states. The stage source must therefore carry
        // the carousel and the settings recovery inside ONE fixed slot —
        // the old conditional branches ("if visuals.showsHintCarousel")
        // shifted the stack and moved the hero.
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/HomeSubviews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("talkSubHeroSlotHeight"),
                      "the fixed sub-hero slot must be present")
        XCTAssertFalse(source.contains("if visuals.showsHintCarousel {"),
                       "the carousel must not sit in a conditional layout branch")
        XCTAssertFalse(source.contains("if visuals.isError, voice.showsOpenSettings {"),
                       "the settings recovery must not sit in a conditional layout branch")
    }
}
