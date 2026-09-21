import Foundation

/// [FOCUS-CAPTURE] The in-process, non-persisted answers of this run.
///
/// A focus capture is the same tap on the same object, done again: the elder
/// points at a notice, reads the translation, looks away, and points at it once
/// more. Every one of those is a fresh crop, a fresh OCR pass and a fresh set
/// of strings, and — without this type — a fresh set of tier calls for text the
/// app translated a few seconds ago.
///
/// **Why this is not `LabelTranslationCache`.** That type is the feature's
/// *persisted* store: it writes an encrypted payload to disk, and a focus
/// capture deliberately does not (see `CloudTranslationTier.CachePolicy` — a
/// capture reads the persisted layers but does not add to them, so pointing at
/// a private letter does not put its translation on disk for the session, let
/// alone the next one). This cache is the other half of that decision: the
/// capture's own answers still get reused, in memory only, and they are gone
/// when the process is.
///
/// **What it is, precisely.** An `NSCache` keyed by the same normalized key the
/// persisted cache uses, holding a `TranslationResult` and the moment it was
/// inserted. Three rules:
///
///  - **The TTL is checked on read, not on a timer.** `memoryCacheTTLSeconds`
///    is a statement about when an answer stops being the answer to what is on
///    screen now, and a background sweep would evict entries nobody asked about
///    while leaving the read path unguarded. A stale entry is removed by the
///    read that found it stale.
///  - **The cost bound is in characters**, matching the config's unit and the
///    feature's own bounds (`brainTranslationMaxCharacters`,
///    `cloudBatchMaxCharacters`). Cost is the source text plus the translation
///    — the string the elder would be re-asking about, both halves of it.
///  - **Eviction is the platform's.** `NSCache` may drop entries under memory
///    pressure at any time and says nothing about it. Nothing here counts
///    entries for evidence or reports a hit rate for that reason: a count this
///    type kept would be a number the platform can silently invalidate.
///
/// An actor rather than a lock: the callers are already async (the capture
/// path), the injected clock has to be read once per decision, and the
/// alternative — an `NSCache` read on the main thread from the overlay's
/// render — is the shape that made the persisted cache's own reads a
/// `@MainActor` hazard.
actor LiveTranslateMemoryCache {

    /// One cached answer: the result itself, and when it was put here.
    ///
    /// A class because `NSCache` stores objects. It holds no logic — the TTL
    /// rule lives in the actor, once, rather than being split between the entry
    /// and its reader.
    final class Entry {
        let result: TranslationResult
        let insertedAt: Date

        init(result: TranslationResult, insertedAt: Date) {
            self.result = result
            self.insertedAt = insertedAt
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private let config: LiveTranslateConfig
    /// The clock, injected for the same reason every other clock in this
    /// feature is: a TTL that can only be tested by sleeping for ten minutes is
    /// a TTL nobody tests.
    private let now: () -> Date

    init(config: LiveTranslateConfig = .default,
         now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
        // The bound is the platform's own unit: `NSCache` compares the total
        // cost of what it holds against this and evicts when it is exceeded.
        cache.totalCostLimit = max(0, config.memoryCacheMaxCost)
    }

    /// The answer for `key`, or `nil` when there is none or the one there is has
    /// outlived the TTL. A stale entry is removed by this read — see the type's
    /// note on why there is no sweeper.
    ///
    /// The read never moves the entry's timestamp: the TTL is measured from
    /// when the answer arrived and not from when someone last asked for it, so
    /// a tap cannot extend an answer's life past the window the config bounds
    /// (review finding 8). Nothing degraded is in here to begin with (`store`).
    func lookup(_ key: String) -> TranslationResult? {
        guard !key.isEmpty else { return nil }
        guard let entry = cache.object(forKey: key as NSString) else { return nil }
        let age = now().timeIntervalSince(entry.insertedAt)
        // A clock that went backwards (a test's, a device's) is not an expiry:
        // only a genuinely old entry is dropped.
        guard age >= config.memoryCacheTTLSeconds else { return entry.result }
        cache.removeObject(forKey: key as NSString)
        return nil
    }

    /// Keeps `result` under `key` for the TTL. An empty key is refused rather
    /// than stored under `""`: a key nobody can ask for is a leak with a
    /// lookup-shaped hole in it.
    ///
    /// **A degraded result is refused too** (review finding 8). The TTL is ten
    /// minutes, and the failure modes this cache exists to smooth over are the
    /// ones that *pass*: a slow tier, an overloaded model, a household that
    /// turned the cloud off for a moment. Caching the degradation made every
    /// one of those sticky — the elder fixed the cause, tapped the same sign
    /// again, and this cache answered with the outage instead of asking the
    /// tier that had recovered, and because a store is what writes the entry,
    /// each re-tap refreshed the timestamp and re-armed the whole TTL. A
    /// degradation is therefore never an answer to reuse: it is not kept, and
    /// the next tap asks again. A resolved result still caches, and a pending
    /// one never reaches here (`LiveTranslateFocusCapture.remember` stores only
    /// final outcomes).
    func store(_ result: TranslationResult, forKey key: String) {
        guard !key.isEmpty, !result.degraded else { return }
        cache.setObject(Entry(result: result, insertedAt: now()),
                        forKey: key as NSString,
                        cost: Self.cost(of: result))
    }

    /// Drops everything. Called when the session that filled it ends: the
    /// answers belong to a run, not to the app.
    func clear() {
        cache.removeAllObjects()
    }

    /// What one entry costs against `memoryCacheMaxCost`: both halves of the
    /// pair, in characters — the source the elder would be re-asking about and
    /// the translation they would be shown again.
    static func cost(of result: TranslationResult) -> Int {
        result.originalText.count + result.text.count
    }
}
