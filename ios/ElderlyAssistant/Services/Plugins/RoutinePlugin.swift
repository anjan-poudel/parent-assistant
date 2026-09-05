import Foundation
import SwiftUI

/// Voice intents for the generalised routine reminders (v2 pivot Phase
/// 1): "remind me to walk at 5" → `routine.set`, "what are my reminders
/// today" → `routine.query`.
///
/// Plugin-vs-core decision: routine reminders are NOT safety-critical
/// (no acknowledgement window, no escalation — those stay exclusive to
/// medication), and the plugin architecture's §5 hard boundary says
/// capability expansion lives in plugins so core files
/// (`InterpretedCommand.Action`, `IntentPrompt`'s core section,
/// `CommandRouter.dispatchInterpreted`) stop growing per feature. This
/// plugin therefore carries the routine intent vocabulary itself; the
/// scheduling/storage engine is a normal service
/// (`Services/Reminders/RoutineScheduler`), injected here at
/// registration — the same pattern as `NepaliCalendarPlugin(storage:)`.
///
/// Medication-shaped reminders are deliberately NOT claimed by the
/// prompt fragment: "remind me to take Amlodipine at 8" still goes to
/// the core `set_reminder` intent and the hardened medication pipeline.
final class RoutinePlugin: AssistantPlugin {

    let pluginID = "routine"
    let displayNameKey = "plugin.routine.name"

    private let scheduler: RoutineScheduler

    /// Today's medication reminders as ready-to-speak summary lines,
    /// folded into `routine.query` answers so "what are my reminders
    /// today" covers BOTH reminder systems (the user's mental model has
    /// one list). Injected by `AppCoordinator` after init — at
    /// plugin-registration time the coordinator's `self` is not yet
    /// fully initialised, so this is a settable closure, not an init
    /// parameter. Nil-safe: the query just answers with routine entries.
    var medicationSummaryProvider: (() -> [String])?

    init(scheduler: RoutineScheduler) {
        self.scheduler = scheduler
    }

    func isApplicable(locale: Locale) -> Bool { true }   // universal, not geography-gated

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["routine.set", "routine.query"],
            promptFragment: """
            PLUGIN CAPABILITY (daily routine reminders): if the user wants
            a recurring reminder about a daily routine or habit —
            exercise/yoga (व्यायाम, योग), walking (हिँड्ने, हिँड्न जाने),
            gym (जिम), meals/food (खाना, खाना खाने), bedtime/sleep
            (सुत्ने, सुत्ने बेला), reading (किताब पढ्ने), or calling a
            relative (आफन्तलाई फोन गर्ने) — set action to "plugin",
            pluginAction to "routine.set", and pluginEntities to
            {"category": "exercise"|"walk"|"gym"|"meal"|"bedtime"|
            "reading"|"call_relative"|"custom", "time": "<the time
            expression they used, verbatim, e.g. 'बेलुका ५ बजे'>",
            "frequency": "daily" or "weekly" (default "daily"; use
            "weekly" only if they named a weekday), "weekday": "<the
            weekday they named, verbatim, or empty>", "title": "<what to
            remind about, in their words — required for 'custom'>"}.
            IMPORTANT: medication reminders (औषधि, दवाई) are NOT this
            capability — keep using the core "set_reminder" action for
            anything about taking medicine.
            If the user asks what reminders they have, what their
            schedule is, or what they have to do today (e.g. "आज मेरा
            सम्झनाहरू के के छन्", "what are my reminders today"), set
            action to "plugin", pluginAction to "routine.query", and
            pluginEntities to {}.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        switch command.actionName {
        case "routine.set":
            return handleSet(command, context: context)
        case "routine.query":
            return handleQuery(context: context)
        default:
            return .failed(spokenApology: L10n.str("plugin.routine.unavailable",
                                                    locale: context.locale))
        }
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }

    // MARK: - routine.set

    private func handleSet(_ command: PluginCommand, context: PluginExecutionContext) -> PluginResult {
        guard let timeString = command.entities["time"], !timeString.isEmpty,
              let time = NepaliTimeParser.parse(timeString) else {
            emit(context: context, "routine_set_no_time")
            return .failed(spokenApology: L10n.str("plugin.routine.noTime",
                                                    locale: context.locale))
        }

        let category = Self.parseCategory(command.entities["category"])
        let weekday = Self.parseWeekday(command.entities["weekday"])
        let isWeekly = command.entities["frequency"] == "weekly" || weekday != nil

        // Title: the user's own words for custom reminders; nil for
        // category reminders so the display name localizes per app
        // language (RoutineEntry.titleOverride rules).
        let titleOverride: String?
        if category == .custom {
            guard let title = command.entities["title"], !title.isEmpty else {
                emit(context: context, "routine_set_no_title")
                return .failed(spokenApology: L10n.str("plugin.routine.noTime",
                                                        locale: context.locale))
            }
            titleOverride = title
        } else {
            titleOverride = nil
        }

        let entry = RoutineEntry(
            category: category,
            titleOverride: titleOverride,
            scheduleTimes: [time],
            frequency: isWeekly ? .weekly : .daily,
            weekdays: weekday.map { [$0] } ?? [],
            isEnabled: true
        )
        guard scheduler.addEntry(entry) else {
            emit(context: context, "routine_set_persistence_failed")
            return .failed(spokenApology: L10n.str("plugin.routine.unavailable",
                                                    locale: context.locale))
        }
        emit(context: context, "routine_set",
             metadata: ["category": category.rawValue])

        let spokenTime = Self.formattedTime(time, locale: context.locale)
        let title = entry.displayTitle(locale: context.locale)
        if isWeekly, let weekday {
            let weekdayName = Self.weekdayName(weekday, locale: context.locale)
            return .spoken(L10n.fmt("plugin.routine.confirmSetWeekly", locale: context.locale,
                                    title, weekdayName, spokenTime))
        }
        return .spoken(L10n.fmt("plugin.routine.confirmSet", locale: context.locale,
                                title, spokenTime))
    }

    // MARK: - routine.query

    private func handleQuery(context: PluginExecutionContext) -> PluginResult {
        var lines: [String] = scheduler.todaysOccurrences()
            .filter { $0.state == .pending }
            .compactMap { occurrence in
                guard let entry = scheduler.entry(for: occurrence.entryId) else { return nil }
                let time = occurrence.scheduledAt.formatted(
                    Date.FormatStyle(date: .omitted, time: .shortened).locale(context.locale))
                return "\(entry.displayTitle(locale: context.locale)) — \(time)"
            }
        lines.append(contentsOf: medicationSummaryProvider?() ?? [])

        guard !lines.isEmpty else {
            emit(context: context, "routine_query_empty")
            return .spoken(L10n.str("plugin.routine.noneToday", locale: context.locale))
        }
        emit(context: context, "routine_query", metadata: ["count": "\(lines.count)"])
        let intro = L10n.str("plugin.routine.todayIntro", locale: context.locale)
        return .spoken(intro + " " + lines.joined(separator: ". "))
    }

    // MARK: - Entity parsing

    private static func parseCategory(_ raw: String?) -> RoutineCategory {
        switch raw?.lowercased() {
        case "exercise", "yoga": return .exercise
        case "meal", "meals", "food": return .meal
        case "walk", "walking": return .walk
        case "gym": return .gym
        case "bedtime", "sleep": return .bedtime
        case "reading", "book": return .reading
        case "call_relative", "callrelative", "call relative", "relative": return .callRelative
        case "medication": return .medication
        default: return .custom
        }
    }

    /// Nepali + English weekday words → `Calendar` weekday numbers
    /// (1 = Sunday … 7 = Saturday). Handles the common Nepali spellings
    /// (बिहिबार/बिहीबार, मङ्गलबार/मंगलबार).
    private static func parseWeekday(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let text = NepaliTimeParser.normalise(raw)
        let table: [(Int, [String])] = [
            (1, ["sun", "आइतबार", "आइतवार"]),
            (2, ["mon", "सोमबार", "सोमवार"]),
            (3, ["tue", "मङ्गलबार", "मंगलबार", "मङ्गलवार"]),
            (4, ["wed", "बुधबार", "बुधवार"]),
            (5, ["thu", "बिहिबार", "बिहीबार", "बिहीवार"]),
            (6, ["fri", "शुक्रबार", "शुक्रवार"]),
            (7, ["sat", "शनिबार", "शनिवार"]),
        ]
        for (number, words) in table where words.contains(where: { text.contains($0) }) {
            return number
        }
        return nil
    }

    private static func weekdayName(_ weekday: Int, locale: Locale) -> String {
        // Calendar weekday 1...7 indexes DateFormatter's localized
        // weekday symbols (Sunday-first) — free localization, no keys.
        let formatter = DateFormatter()
        formatter.locale = locale
        guard let symbols = formatter.weekdaySymbols,
              weekday >= 1, weekday <= symbols.count else { return "" }
        return symbols[weekday - 1]
    }

    private static func formattedTime(_ components: DateComponents, locale: Locale) -> String {
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private func emit(context: PluginExecutionContext, _ type: String,
                      metadata: [String: String] = [:]) {
        context.observabilityBus.emit(ObservabilityEvent(
            component: "plugin_routine", eventType: type, durationMs: nil,
            outcome: "success", errorCode: nil, metadata: metadata))
    }
}
