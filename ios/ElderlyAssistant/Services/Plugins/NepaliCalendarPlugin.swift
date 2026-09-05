import Foundation
import SwiftUI

/// Geography-gated plugin answering questions about the Nepali calendar
/// (Bikram Sambat) and Nepali festivals — "आज नेपाली पात्रोमा के हो",
/// "यस वर्ष दशैं कहिले हो" — for Nepali-locale users only
/// (`isApplicable` checks the language code), so an English-locale
/// household's prompt never carries this vocabulary at all.
///
/// Answers are produced by a search-grounded Gemini call (the
/// `google_search` tool — verified live against this API key on
/// 2026-09-05), NOT hand-built BS/Panchanga date math, consistent with
/// the already-made "let Gemini synthesize, cache the result locally"
/// decision for appliance manuals. Results are cached locally keyed by
/// (normalized question, current year) — a festival's date, once
/// resolved for the current year, doesn't change and doesn't need
/// re-fetching.
final class NepaliCalendarPlugin: AssistantPlugin {

    let pluginID = "nepali_calendar"
    let displayNameKey = "plugin.nepaliCalendar.name"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    func isApplicable(locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "ne"
    }

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["nepali_calendar.query"],
            promptFragment: """
            PLUGIN CAPABILITY (Nepali calendar): if the user asks about
            the Nepali calendar (पात्रो/बिक्रम संवत्), today's Nepali date,
            or when a Nepali festival falls (दशैं, तिहार, तीज, नयाँ वर्ष,
            छठ, etc.), set action to "plugin", pluginAction to
            "nepali_calendar.query", and pluginEntities to
            {"question": "<their question, verbatim, in their words>"}.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        guard let question = command.entities["question"], !question.isEmpty else {
            return .failed(spokenApology: Self.localized(
                "plugin.nepaliCalendar.noQuestion", locale: context.locale))
        }

        let cacheKey = Self.cacheKey(question: question)
        if let cached = loadCachedAnswer(key: cacheKey) {
            return .spoken(cached)
        }

        let prompt = """
        You are Sahayak, a voice assistant for an elderly Nepali speaker. \
        Answer their question about the Nepali calendar (Bikram Sambat) \
        or Nepali festivals using current, correct information from web \
        search. Today's Gregorian date is \(Self.todayDescription()).
        Reply with ONLY a JSON object: {"answer": string, "confidence": number 0-1}.
        The answer must be in simple, plain Nepali, one or two short \
        sentences, warm and respectful — it will be spoken aloud to an \
        elderly person. If you cannot find a reliable answer, set \
        confidence below 0.5.
        Question: "\(question)"
        """

        do {
            let raw = try await context.geminiClient.generateJSON(prompt: prompt, useSearchGrounding: true)
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Answer.self, from: data),
                  !decoded.answer.isEmpty else {
                context.observabilityBus.emit(Self.event("nepali_calendar_parse_failed"))
                return .failed(spokenApology: Self.localized(
                    "plugin.nepaliCalendar.unavailable", locale: context.locale))
            }
            guard decoded.confidence >= 0.5 else {
                context.observabilityBus.emit(Self.event("nepali_calendar_low_confidence"))
                return .failed(spokenApology: Self.localized(
                    "plugin.nepaliCalendar.unavailable", locale: context.locale))
            }
            storeCachedAnswer(key: cacheKey, answer: decoded.answer)
            context.observabilityBus.emit(Self.event("nepali_calendar_answered"))
            return .spoken(decoded.answer)
        } catch {
            context.observabilityBus.emit(Self.event("nepali_calendar_call_failed",
                                                     errorCode: String(describing: error)))
            return .failed(spokenApology: Self.localized(
                "plugin.nepaliCalendar.unavailable", locale: context.locale))
        }
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }

    // MARK: - Cache

    private struct CachedAnswer: Codable {
        let answer: String
        let year: Int
    }

    private struct Answer: Codable {
        let answer: String
        let confidence: Double
    }

    private static func cacheKey(question: String) -> String {
        "plugin.nepali_calendar.answer.\(question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func loadCachedAnswer(key: String) -> String? {
        let currentYear = Calendar.current.component(.year, from: Date())
        guard case .success(let cached) = storage.read(key: key, type: CachedAnswer.self),
              cached.year == currentYear else { return nil }
        return cached.answer
    }

    private func storeCachedAnswer(key: String, answer: String) {
        let year = Calendar.current.component(.year, from: Date())
        _ = storage.write(key: key, value: CachedAnswer(answer: answer, year: year))
    }

    private static func todayDescription() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func localized(_ key: String, locale: Locale) -> String {
        L10n.str(key, locale: locale)
    }

    private static func event(_ type: String, errorCode: String? = nil) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_nepali_calendar",
                           eventType: type, durationMs: nil,
                           outcome: errorCode == nil ? "success" : "failure",
                           errorCode: errorCode, metadata: [:])
    }
}
