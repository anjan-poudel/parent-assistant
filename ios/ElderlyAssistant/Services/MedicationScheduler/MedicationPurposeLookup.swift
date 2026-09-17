import Foundation

// [MED-PURPOSE-LOOKUP] (2026-09-18) "What is this medicine for?" — the
// settings-side web lookup that fills the purpose field.
//
// The family has just typed (or scanned) a name. A button asks the web what
// the medicine is for, and whatever the search returns lands in the
// purpose field, editable, to be saved by the family like any other purpose.
//
// Four rules make this honest rather than magic:
//
//  - **The existing search stack, not a new one.** The query runs through
//    `SearchTool` — the same URL, the same parsing, the same spoken-summary
//    shaping the voice tool uses — over the same `LocalToolTransport` seam.
//    There is no second Google client in this app, and no second place for a
//    credential to leak from.
//  - **The same opt-in gate as voice.** Search fires only when the credential
//    PAIR is present (`SearchConfigStore.isConfigured`, exactly the gate
//    `CommandRouter.fireWebSearchIfDue` applies) and the same daily quota
//    (`SearchQuota`) is respected, because it is the same Google quota.
//  - **Never a fabricated answer.** An unconfigured tool, an empty result
//    set and a failed round-trip are three different outcomes and all three
//    are reported as themselves (`.notConfigured` / `.noResults` /
//    `.unavailable`); none of them is ever an empty `found`.
//  - **Privacy unchanged.** The medicine NAME leaves the device — the same
//    thing the voice search does with a spoken question, under the same
//    settings line that discloses it. Nothing else does: no photo, no
//    schedule, no household data.

/// What one purpose lookup produced.
enum MedicationPurposeLookupOutcome: Equatable {
    /// A short summary of what the medicine is used for, ready to pre-fill
    /// the purpose field. Never empty — see `.noResults`.
    case found(String)
    /// No search credential pair is configured. The family sees the honest
    /// "web search is not set up" line instead of a search that never ran.
    case notConfigured
    /// Today's search budget is spent (`SearchQuota`). The shared Google
    /// quota is one budget for voice and settings alike.
    case capReached
    /// The search ran and matched nothing.
    case noResults
    /// The search ran and could not be completed (transport failure, a
    /// non-200, an unreadable body).
    case unavailable
}

/// The injectable lookup seam: production is a `SearchTool` round-trip;
/// tests script any outcome.
protocol MedicationPurposeLookingUp: AnyObject {
    /// Looks up what `name` is for. Never throws and never reports a
    /// `.found` it did not receive.
    func lookupPurpose(forMedicine name: String) async -> MedicationPurposeLookupOutcome
}

/// The shipped lookup: Google CSE through `SearchTool`.
final class MedicationPurposeLookupService: MedicationPurposeLookingUp {

    /// The credential pair the feature needs — both halves, or none. Packed
    /// as one value so "half-configured" cannot be represented here, the
    /// same way `SearchConfigStore.isConfigured` refuses it.
    struct Credentials: Equatable {
        let apiKey: String
        let searchEngineID: String
    }

    /// Seconds before the round-trip is abandoned. The same 8 seconds the
    /// router's search waits (`CommandRouter.searchFetchTimeoutSeconds`) —
    /// a caregiver is standing there watching a form, and a request that
    /// outlives the moment is one they have already given up on.
    static let fetchTimeoutSeconds: TimeInterval = 8

    /// How many hits are folded into the field. ONE: the purpose field is a
    /// short line the family edits, not a search-results page, and the
    /// second hit is a different page's guess at the same question.
    static let resultsUsed = 1

    private let credentials: () -> Credentials?
    private let transport: LocalToolTransport?
    private let locale: () -> Locale
    private let defaults: UserDefaults
    private let now: () -> Date

    init(credentials: @escaping () -> Credentials?,
         transport: LocalToolTransport?,
         locale: @escaping () -> Locale,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.transport = transport
        self.locale = locale
        self.defaults = defaults
        self.now = now
    }

    /// The query. Phrased as the question the family is asking rather than as
    /// bare drug name: CSE returns indication pages for "what is X used for"
    /// and package inserts for "X" alone. English deliberately, in both app
    /// languages: the indexed medical pages mix English and Nepali, and an
    /// English query retrieves either, while a Nepali query retrieves only
    /// one.
    static func query(forMedicine name: String) -> String {
        "what is \(name) used for"
    }

    func lookupPurpose(forMedicine name: String) async -> MedicationPurposeLookupOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank name is not an unconfigured tool and not a failed search:
        // there is nothing to ask about, and the caller's button is disabled
        // in that state anyway.
        guard !trimmed.isEmpty else { return .noResults }
        // The credential pair gate, in the same order the router applies it
        // (`fireWebSearchIfDue`): no pair → no search, before anything else
        // is even considered.
        guard let creds = credentials() else { return .notConfigured }
        guard let transport else { return .unavailable }
        guard remainingSearches() > 0 else { return .capReached }
        // Attempt-based accounting like the router's: the count ticks when
        // the search FIRES, so a failed round-trip still spent the quota it
        // spent at Google.
        _ = SearchQuota.increment(defaults: defaults, now: now())

        var request = URLRequest(url: SearchTool.requestURL(
            query: Self.query(forMedicine: trimmed),
            apiKey: creds.apiKey,
            searchEngineId: creds.searchEngineID))
        request.timeoutInterval = Self.fetchTimeoutSeconds
        do {
            let (data, response) = try await transport.fetchData(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .unavailable }
            let results = SearchTool.parseSearchJSON(data: data)
            guard let summary = SearchTool.summaryReply(
                for: Array(results.prefix(Self.resultsUsed)),
                locale: locale()) else { return .noResults }
            return .found(summary)
        } catch {
            // A raw error never reaches the family and never reaches the log
            // (C9): the outcome IS the report.
            return .unavailable
        }
    }

    /// What is left of today's budget — read through `SearchQuota`, so a
    /// caregiver's lookup and the elder's spoken question draw on one number.
    private func remainingSearches() -> Int {
        SearchQuota.remaining(today: now(),
                              count: SearchQuota.readCount(defaults: defaults),
                              limit: SearchQuota.dailyLimit,
                              defaults: defaults)
    }
}
