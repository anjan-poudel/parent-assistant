import Foundation

/// [POINT-TAP-ASK] (2026-09-19) Daily cap on point-tap-ask attempts
/// (`UserDefaults` — a counter, not a secret), a deliberate mirror of
/// `SearchQuota`: 50/day bounds the household's point-tap-ask usage so
/// a confused loop (the same object asked about again and again) cannot
/// burn through the cloud web-detection tier's paid quota in one day —
/// the expensive tier needs the hard ceiling. The barcode→OFF tier is
/// keyless and cheaper, but one shared budget keeps the whole feature
/// bounded and its Settings note honest ("50 point-and-ask questions a
/// day").
///
/// Bucket keys: "pointask.quota.day" (yyyyMMdd stamp of the bucket's
/// day), "pointask.quota.count". A count recorded on a PREVIOUS day
/// never counts against today — rollover happens on read AND on
/// increment, exactly like `SearchQuota`.
enum PointAskQuota {
    static let dailyLimit = 50
    static let dayKey = "pointask.quota.day"
    static let countKey = "pointask.quota.count"

    /// The day-bucket stamp for `date` ("20260919" for 19 Sep 2026) —
    /// local calendar, so a household that crosses midnight mid-session
    /// gets a fresh budget with the new day.
    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The RAW stored count — no day normalization. Pair with
    /// `remaining(today:count:limit:defaults:)`, which applies a
    /// previous-day count as zero.
    static func readCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: countKey)
    }

    /// How many attempts may still fire today, or 0 once the cap is hit.
    /// `count` is the raw `readCount()`; it only eats today's budget when
    /// it was recorded under `today`'s day stamp — otherwise the full
    /// `limit` applies (fresh day, fresh budget). Never negative.
    static func remaining(today: Date,
                          count: Int,
                          limit: Int,
                          defaults: UserDefaults = .standard,
                          calendar: Calendar = .current) -> Int {
        let storedDay = defaults.string(forKey: dayKey)
        let appliesToday = storedDay == dayStamp(for: today, calendar: calendar)
        let consumed = appliesToday ? max(0, count) : 0
        return max(0, limit - consumed)
    }

    /// Records one more attempt and returns the new count. Rolls the
    /// bucket over when the stored day is not today (the first attempt of
    /// a new day starts at 1, not at yesterday's total + 1).
    @discardableResult
    static func increment(defaults: UserDefaults = .standard,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> Int {
        let stamp = dayStamp(for: now, calendar: calendar)
        let current = defaults.string(forKey: dayKey) == stamp
            ? defaults.integer(forKey: countKey)
            : 0
        let next = current + 1
        defaults.set(stamp, forKey: dayKey)
        defaults.set(next, forKey: countKey)
        return next
    }

    /// Zeroes the bucket (tests; a future settings "reset" action).
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dayKey)
        defaults.removeObject(forKey: countKey)
    }
}
