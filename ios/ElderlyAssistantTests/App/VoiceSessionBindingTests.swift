import XCTest
@testable import ElderlyAssistant

/// Guards the Talk button's localized bindings end-to-end: the state
/// machine → catalog key → Bundle.main String Catalog resolution in both
/// shipped languages. A regression here shows English on the button while
/// the rest of the app stays Nepali — hard to spot in screenshots.
final class VoiceSessionBindingTests: XCTestCase {

    func testIdleBindingsResolveInNepali() {
        let ne = Locale(identifier: "ne-NP")
        XCTAssertEqual(VoiceSessionState.idle.buttonText(locale: ne), "बोल्नुहोस्")
        XCTAssertEqual(VoiceSessionState.idle.statusText(locale: ne), "तयार छु")
    }

    func testIdleBindingsResolveInEnglish() {
        let en = Locale(identifier: "en-US")
        XCTAssertEqual(VoiceSessionState.idle.buttonText(locale: en), "Talk")
        XCTAssertEqual(VoiceSessionState.idle.statusText(locale: en), "I'm ready")
    }

    func testAllStatesResolveInBothLanguages() {
        let locales: [Locale] = [Locale(identifier: "ne-NP"), Locale(identifier: "en-US")]
        let states: [VoiceSessionState] = [
            .idle, .listening, .transcribing, .understanding, .speaking,
            .awaitingConfirmation, .error, .stopped
        ]
        for locale in locales {
            for state in states {
                let button = state.buttonText(locale: locale)
                let status = state.statusText(locale: locale)
                XCTAssertFalse(button.isEmpty, "\(state) button empty for \(locale.identifier)")
                XCTAssertFalse(status.isEmpty, "\(state) status empty for \(locale.identifier)")
                // Resolved text must not be the raw key.
                XCTAssertFalse(button.hasPrefix("state."),
                               "\(state) button unresolved for \(locale.identifier): \(button)")
                XCTAssertFalse(status.hasPrefix("state."),
                               "\(state) status unresolved for \(locale.identifier): \(status)")
            }
        }
    }
}
