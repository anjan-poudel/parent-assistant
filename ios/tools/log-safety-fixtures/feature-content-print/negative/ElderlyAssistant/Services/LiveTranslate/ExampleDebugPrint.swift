// FIXTURE (negative) — rule feature-content-print must stay quiet.
//
// Every content word the rule knows is present here as *data*: `region.text`
// and `translatedText` are read, the event names `text_change` and
// `consent_prompt_shown` are spelled, and nothing at all is rendered to a
// console. The rule is scoped to console writes, so none of this is a
// violation.
import Foundation

func publish(region: TextRegion, translation: String, events: LiveTranslateEvents, count: Int) {
    let translatedText = region.text
    events.textChange(regionCount: count)
    events.consentPromptShown()
    _ = translatedText
    _ = translation
}
